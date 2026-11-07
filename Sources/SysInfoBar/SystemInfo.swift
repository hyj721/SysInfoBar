import Foundation
import IOKit
import Darwin

// MARK: - sysctl helpers

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func value<T>(_ name: String, as _: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard sysctlbyname(name, ptr, &size, nil, 0) == 0 else { return nil }
        return ptr.pointee
    }

    static func int(_ name: String) -> Int? {
        if let v = value(name, as: Int64.self) { return Int(v) }
        return nil
    }

    static func int32(_ name: String) -> Int? {
        if let v = value(name, as: Int32.self) { return Int(v) }
        return nil
    }
}

// MARK: - IOKit helpers

enum IOReg {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func service(_ className: String) -> io_service_t? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        return s == 0 ? nil : s
    }
}

// MARK: - Static info (read once)

struct StaticInfo {
    let modelName: String      // "MacBook Pro (16-inch, 2021)"
    let modelID: String        // "MacBookPro18,1"
    let cpuBrand: String       // "Apple M1 Pro"
    let pCores: Int
    let eCores: Int
    let logicalCPUs: Int
    let memTotal: UInt64
    let osVersion: String      // "macOS Tahoe 26.5.1 (25F80)"
    let gpuName: String?
    let gpuCores: Int?
    let hasBattery: Bool

    static func read() -> StaticInfo {
        let modelID = Sysctl.string("hw.model") ?? "Mac"
        var modelName = modelID
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if product != 0 {
            if let data = IOReg.property(product, "product-name") as? Data,
               let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters),
               !s.isEmpty {
                modelName = s
            }
            IOObjectRelease(product)
        }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        var ver = "\(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { ver += ".\(v.patchVersion)" }
        let names = [26: "Tahoe", 15: "Sequoia", 14: "Sonoma", 13: "Ventura", 12: "Monterey", 11: "Big Sur"]
        let name = names[v.majorVersion].map { " \($0)" } ?? ""
        let build = Sysctl.string("kern.osversion").map { " (\($0))" } ?? ""

        var gpuName: String?
        var gpuCores: Int?
        if let gpu = IOReg.service("AGXAccelerator") {
            gpuName = IOReg.property(gpu, "model") as? String
            gpuCores = (IOReg.property(gpu, "gpu-core-count") as? NSNumber)?.intValue
            IOObjectRelease(gpu)
        }

        var hasBattery = false
        if let b = IOReg.service("AppleSmartBattery") {
            hasBattery = (IOReg.property(b, "BatteryInstalled") as? Bool) ?? false
            IOObjectRelease(b)
        }

        return StaticInfo(
            modelName: modelName,
            modelID: modelID,
            cpuBrand: Sysctl.string("machdep.cpu.brand_string") ?? "CPU",
            pCores: Sysctl.int32("hw.perflevel0.physicalcpu") ?? 0,
            eCores: Sysctl.int32("hw.perflevel1.physicalcpu") ?? 0,
            logicalCPUs: Sysctl.int32("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            memTotal: Sysctl.value("hw.memsize", as: UInt64.self) ?? ProcessInfo.processInfo.physicalMemory,
            osVersion: "macOS\(name) \(ver)\(build)",
            gpuName: gpuName,
            gpuCores: gpuCores,
            hasBattery: hasBattery
        )
    }
}

// MARK: - Dynamic snapshot

struct Snapshot {
    var cpuTotal: Double = 0          // 0...1
    var cpuPerCore: [Double] = []
    var memUsed: UInt64 = 0
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0             // file-backed + purgeable
    var swapUsed: UInt64 = 0
    var gpuUtil: Double?              // 0...1
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var volumeName: String = "Macintosh HD"
    var uptime: TimeInterval = 0
    var battery: Battery?
    var netDown: Double = 0           // bytes/s
    var netUp: Double = 0
    var netIface: String?
    var netIP: String?
    var topCPU: [ProcStat] = []
    var topMem: [ProcStat] = []
    var status = SystemStatus()

    struct Battery {
        var percent: Int
        var charging: Bool
        var pluggedIn: Bool
        var cycles: Int?
        var health: Int?             // % of design capacity
        var minutesRemaining: Int?
        var systemWatts: Double?     // whole-machine power draw
        var adapterWatts: Int?
        var temperature: Double?     // °C
    }
}

/// Reads dynamic stats. Keeps previous CPU ticks so usage is a delta between calls.
final class Sampler {
    private let host = mach_host_self()
    private var prevTicks: [(busy: UInt64, total: UInt64)] = []
    private let pageSize = UInt64(Sysctl.int("hw.pagesize") ?? 16384)
    private var gpuService: io_service_t?
    private var batteryService: io_service_t?
    private var net = NetworkSampler()
    private var procs = ProcessSampler()

    init(info: StaticInfo) {
        gpuService = IOReg.service("AGXAccelerator")
        if info.hasBattery { batteryService = IOReg.service("AppleSmartBattery") }
    }

    deinit {
        if let g = gpuService { IOObjectRelease(g) }
        if let b = batteryService { IOObjectRelease(b) }
    }

    /// Drop previous counters so rates aren't averaged over the time the panel was closed.
    func reset() {
        prevTicks = []
        net = NetworkSampler()
        procs = ProcessSampler()
    }

    func sample() -> Snapshot {
        var s = Snapshot()
        readCPU(into: &s)
        readMemory(into: &s)
        readGPU(into: &s)
        readDisk(into: &s)
        readUptime(into: &s)
        readBattery(into: &s)
        let n = net.sample()
        s.netDown = n.down; s.netUp = n.up; s.netIface = n.iface; s.netIP = n.ip
        (s.topCPU, s.topMem) = procs.sample()
        s.status = SystemStatus.read()
        return s
    }

    private func readCPU(into s: inout Snapshot) {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [(busy: UInt64, total: UInt64)] = []
        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks.append((user + sys + nice, user + sys + nice + idle))
        }
        if prevTicks.count == ticks.count {
            var busySum: UInt64 = 0, totalSum: UInt64 = 0
            s.cpuPerCore = zip(ticks, prevTicks).map { cur, prev in
                let b = cur.busy &- prev.busy, t = cur.total &- prev.total
                busySum += b; totalSum += t
                return t > 0 ? Double(b) / Double(t) : 0
            }
            s.cpuTotal = totalSum > 0 ? Double(busySum) / Double(totalSum) : 0
        } else {
            s.cpuPerCore = Array(repeating: 0, count: ticks.count)
        }
        prevTicks = ticks
    }

    private func readMemory(into s: inout Snapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            // Same definition as Activity Monitor's "Memory Used": App + Wired + Compressed
            let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            let used = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
            s.memUsed = used * pageSize
            s.memApp = app * pageSize
            s.memWired = UInt64(stats.wire_count) * pageSize
            s.memCompressed = UInt64(stats.compressor_page_count) * pageSize
            s.memCached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * pageSize
        }
        if let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self) {
            s.swapUsed = swap.xsu_used
        }
    }

    private func readGPU(into s: inout Snapshot) {
        guard let g = gpuService,
              let perf = IOReg.property(g, "PerformanceStatistics") as? [String: Any],
              let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
        s.gpuUtil = min(max(util / 100, 0), 1)
    }

    private func readDisk(into s: inout Snapshot) {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                     .volumeAvailableCapacityForImportantUsageKey,
                                                     .volumeLocalizedNameKey]) {
            s.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            s.diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            s.volumeName = v.volumeLocalizedName ?? s.volumeName
        }
    }

    private func readUptime(into s: inout Snapshot) {
        if let boot = Sysctl.value("kern.boottime", as: timeval.self) {
            s.uptime = Date().timeIntervalSince1970 - Double(boot.tv_sec)
        }
    }

    private func readBattery(into s: inout Snapshot) {
        guard let b = batteryService else { return }
        func int(_ k: String) -> Int? { (IOReg.property(b, k) as? NSNumber)?.intValue }
        guard let cur = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 else { return }
        var health: Int?
        if let raw = int("AppleRawMaxCapacity"), let design = int("DesignCapacity"), design > 0 {
            health = Int((Double(raw) / Double(design) * 100).rounded())
        }
        let remaining = int("TimeRemaining").flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        let plugged = (IOReg.property(b, "ExternalConnected") as? Bool) ?? false
        var watts: Double?
        if let tel = IOReg.property(b, "PowerTelemetryData") as? [String: Any],
           let mw = (tel["SystemLoad"] as? NSNumber)?.doubleValue, mw > 0 {
            watts = mw / 1000
        } else if let mv = int("Voltage"), let ma = int("Amperage"), ma != 0 {
            watts = Double(mv) * Double(abs(ma)) / 1e6
        }
        let adapter = plugged ? ((IOReg.property(b, "AdapterDetails") as? [String: Any])?["Watts"] as? NSNumber)?.intValue : nil
        s.battery = .init(
            percent: Int((Double(cur) / Double(max) * 100).rounded()),
            charging: (IOReg.property(b, "IsCharging") as? Bool) ?? false,
            pluggedIn: plugged,
            cycles: int("CycleCount"),
            health: health,
            minutesRemaining: remaining,
            systemWatts: watts,
            adapterWatts: adapter,
            temperature: int("Temperature").map { Double($0) / 100 }
        )
    }
}
