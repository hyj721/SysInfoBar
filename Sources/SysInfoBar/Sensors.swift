import Foundation
import IOKit
import CoreWLAN
import AppKit

// MARK: - Models

struct Fan: Equatable { var rpm: Double; var min: Double; var max: Double }

struct Thermals: Equatable {
    var cpuAvg: Double?
    var cpuMax: Double?
    var gpuAvg: Double?
    var fans: [Fan] = []
}

struct VolumeInfo: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let ejectable: Bool
    var id: String { url.path }
}

struct WiFiInfo: Equatable {
    var iface: String
    var rssi: Int
    var noise: Int
    var txRate: Double        // Mbps
    var channel: Int?
    var bandGHz: String?      // "2.4" / "5" / "6"
    var standard: String?     // "Wi‑Fi 6"
}

struct Peripheral: Identifiable, Equatable {
    let name: String
    let percent: Int
    var id: String { name }
}

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Int
    let builtIn: Bool
}

struct NetProc: Identifiable, Equatable {
    let name: String
    let pid: Int
    let down: Double          // bytes/s
    let up: Double
    var id: Int { pid }
}

/// What to read on a given tick: only what some visible view shows.
struct SampleOptions: Equatable {
    var thermals = false
    var diskIO = false
    var volumes = false
    var wifi = false
    var peripherals = false
    var displays = false

    static let all = SampleOptions(thermals: true, diskIO: true, volumes: true, wifi: true, peripherals: true, displays: true)
}

// MARK: - SMC (temperatures and fans)

/// Reads the System Management Controller through the AppleSMC user client (no root needed).
/// Temperature key names differ per chip, so the keys are discovered once and cached per model.
final class SMCReader {
    private var conn: io_connect_t = 0
    private var keyInfo: [UInt32: (size: UInt32, type: UInt32)] = [:]
    private var cpuKeys: [UInt32] = []
    private var gpuKeys: [UInt32] = []
    private var fanCount = 0
    private var discovering = false
    private let modelID: String

    init(modelID: String) {
        self.modelID = modelID
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if svc != 0 {
            IOServiceOpen(svc, mach_task_self_, 0, &conn)
            IOObjectRelease(svc)
        }
        loadCachedKeys()
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    var available: Bool { conn != 0 }

    func read() -> Thermals? {
        guard available else { return nil }
        if cpuKeys.isEmpty && gpuKeys.isEmpty && fanCount == 0 {
            discoverInBackground()
            return nil
        }
        var t = Thermals()
        let cpu = cpuKeys.compactMap(value).filter { $0 > 5 && $0 < 130 }
        if !cpu.isEmpty { t.cpuAvg = cpu.reduce(0, +) / Double(cpu.count); t.cpuMax = cpu.max() }
        let gpu = gpuKeys.compactMap(value).filter { $0 > 5 && $0 < 130 }
        if !gpu.isEmpty { t.gpuAvg = gpu.reduce(0, +) / Double(gpu.count) }
        for i in 0..<fanCount {
            if let rpm = value(Self.fourcc("F\(i)Ac")) {
                t.fans.append(Fan(rpm: rpm, min: value(Self.fourcc("F\(i)Mn")) ?? 0, max: value(Self.fourcc("F\(i)Mx")) ?? 0))
            }
        }
        return t
    }

    // MARK: discovery

    private var cacheKey: String { "smcKeys.v1.\(modelID)" }

    private func loadCachedKeys() {
        guard let d = UserDefaults.standard.dictionary(forKey: cacheKey),
              let cpu = d["cpu"] as? [String], let gpu = d["gpu"] as? [String], let fans = d["fans"] as? Int else { return }
        cpuKeys = cpu.map(Self.fourcc); gpuKeys = gpu.map(Self.fourcc); fanCount = fans
    }

    private func discoverInBackground() {
        guard !discovering else { return }
        discovering = true
        let model = modelID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scan = SMCReader(modelID: model + ".scan")   // separate connection for the background thread
            let found = scan.scanKeys()
            DispatchQueue.main.async {
                guard let self else { return }
                self.cpuKeys = found.cpu.map(Self.fourcc)
                self.gpuKeys = found.gpu.map(Self.fourcc)
                self.fanCount = found.fans
                self.discovering = false
                UserDefaults.standard.set(["cpu": found.cpu, "gpu": found.gpu, "fans": found.fans], forKey: self.cacheKey)
            }
        }
    }

    /// Apple Silicon: Tp* = performance cores, Te* = efficiency cores, Tg* = GPU.
    /// Intel: TC0P / TC0D / TC0E (CPU), TG0P / TG0D (GPU).
    private func scanKeys() -> (cpu: [String], gpu: [String], fans: Int) {
        var cpu: [String] = [], gpu: [String] = []
        let count = readRaw(Self.fourcc("#KEY")).map { $0.bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } } ?? 0
        for i in 0..<count {
            guard let k = keyAt(i) else { continue }
            let s = Self.string(k)
            let isCPU = s.hasPrefix("Tp") || s.hasPrefix("Te") || ["TC0P", "TC0D", "TC0E", "TC0F"].contains(s)
            let isGPU = s.hasPrefix("Tg") || ["TG0P", "TG0D"].contains(s)
            guard isCPU || isGPU, let v = value(k), v > 5, v < 130 else { continue }
            if isCPU { cpu.append(s) } else { gpu.append(s) }
        }
        let fans = readRaw(Self.fourcc("FNum")).flatMap { $0.bytes.first }.map(Int.init) ?? 0
        return (cpu, gpu, fans)
    }

    // MARK: low level

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let r = IOConnectCallStructMethod(conn, 2, input, 80, &out, &outSize)
        return r == kIOReturnSuccess && out[40] == 0 ? out : nil
    }

    private func info(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        if let hit = keyInfo[key] { return hit }
        var i = [UInt8](repeating: 0, count: 80)
        Self.put32(&i, 0, key); i[42] = 9   // kSMCGetKeyInfo
        guard let o = call(i) else { return nil }
        let v = (Self.get32(o, 28), Self.get32(o, 32))
        keyInfo[key] = v
        return v
    }

    private func readRaw(_ key: UInt32) -> (type: UInt32, bytes: [UInt8])? {
        guard let (size, type) = info(key), size > 0, size <= 32 else { return nil }
        var i = [UInt8](repeating: 0, count: 80)
        Self.put32(&i, 0, key); Self.put32(&i, 28, size); i[42] = 5   // kSMCReadKey
        guard let o = call(i) else { return nil }
        return (type, Array(o[48..<48 + Int(size)]))
    }

    private func keyAt(_ index: UInt32) -> UInt32? {
        var i = [UInt8](repeating: 0, count: 80)
        Self.put32(&i, 44, index); i[42] = 8   // kSMCGetKeyFromIndex
        return call(i).map { Self.get32($0, 0) }
    }

    private func value(_ key: UInt32) -> Double? {
        guard let (type, b) = readRaw(key) else { return nil }
        switch Self.string(type) {
        case "flt ": return b.count == 4 ? Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) : nil
        case "fpe2": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        case "sp78": return b.count >= 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256 : nil
        case "ui8 ": return b.first.map(Double.init)
        default: return nil
        }
    }

    static func fourcc(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    static func string(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
    }
    private static func put32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        for i in 0..<4 { b[off + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) }
    }
    private static func get32(_ b: [UInt8], _ off: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(b[off + $1]) << (8 * UInt32($1)) }
    }
}

// MARK: - Disk I/O

final class DiskIOSampler {
    private var prev: (r: UInt64, w: UInt64, at: TimeInterval)?

    func sample() -> (read: Double, write: Double) {
        var r: UInt64 = 0, w: UInt64 = 0
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else {
            return (0, 0)
        }
        while case let s = IOIteratorNext(it), s != 0 {
            if let st = IOReg.property(s, "Statistics") as? [String: Any] {
                r &+= (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w &+= (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(s)
        }
        IOObjectRelease(it)
        let now = ProcessInfo.processInfo.systemUptime
        defer { prev = (r, w, now) }
        guard let p = prev, now > p.at, r >= p.r, w >= p.w else { return (0, 0) }
        return (Double(r - p.r) / (now - p.at), Double(w - p.w) / (now - p.at))
    }
}

enum Volumes {
    /// Mounted volumes other than the startup disk (external drives, USB sticks, disk images).
    static func external() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard u.path != "/", let v = try? u.resourceValues(forKeys: Set(keys)),
                  v.volumeIsBrowsable == true, v.volumeIsLocal == true,
                  v.volumeIsInternal == false || v.volumeIsEjectable == true || v.volumeIsRemovable == true
            else { return nil }
            // Skip app-provided virtual volumes (e.g. OrbStack) that can't be ejected and live under the home folder.
            if u.path.hasPrefix(NSHomeDirectory()) && v.volumeIsEjectable != true { return nil }
            return VolumeInfo(url: u, name: v.volumeName ?? u.lastPathComponent,
                              total: Int64(v.volumeTotalCapacity ?? 0), free: Int64(v.volumeAvailableCapacity ?? 0),
                              ejectable: v.volumeIsEjectable == true || v.volumeIsRemovable == true)
        }
    }
}

// MARK: - Wi‑Fi

enum WiFiReader {
    static func read() -> WiFiInfo? {
        guard let w = CWWiFiClient.shared().interface(), w.powerOn(), w.rssiValue() != 0 else { return nil }
        var band: String?
        switch w.wlanChannel()?.channelBand {
        case .band2GHz: band = "2.4"
        case .band5GHz: band = "5"
        case .band6GHz: band = "6"
        default: band = nil
        }
        var std: String?
        switch w.activePHYMode() {
        case .mode11n: std = "Wi‑Fi 4"
        case .mode11ac: std = "Wi‑Fi 5"
        case .mode11ax: std = band == "6" ? "Wi‑Fi 6E" : "Wi‑Fi 6"
        case .mode11a, .mode11b, .mode11g: std = "802.11"
        default: std = (w.activePHYMode().rawValue == 7) ? "Wi‑Fi 7" : nil
        }
        return WiFiInfo(iface: w.interfaceName ?? "en0", rssi: w.rssiValue(), noise: w.noiseMeasurement(),
                        txRate: w.transmitRate(), channel: w.wlanChannel()?.channelNumber, bandGHz: band, standard: std)
    }
}

// MARK: - Bluetooth / HID peripheral batteries

enum PeripheralReader {
    static func read() -> [Peripheral] {
        var out: [Peripheral] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &it) == KERN_SUCCESS else {
            return []
        }
        while case let s = IOIteratorNext(it), s != 0 {
            if let pct = (IOReg.property(s, "BatteryPercent") as? NSNumber)?.intValue,
               let name = IOReg.property(s, "Product") as? String,
               !out.contains(where: { $0.name == name }) {
                out.append(Peripheral(name: name, percent: pct))
            }
            IOObjectRelease(s)
        }
        IOObjectRelease(it)
        return out
    }
}

// MARK: - Displays

enum DisplayReader {
    static func read() -> [DisplayInfo] {
        NSScreen.screens.compactMap { sc in
            guard let id = sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(id: id, name: sc.localizedName,
                               pixelWidth: mode?.pixelWidth ?? Int(sc.frame.width * sc.backingScaleFactor),
                               pixelHeight: mode?.pixelHeight ?? Int(sc.frame.height * sc.backingScaleFactor),
                               refresh: sc.maximumFramesPerSecond, builtIn: CGDisplayIsBuiltin(id) != 0)
        }
    }
}

// MARK: - Per-process network (nettop)

/// Per-process network rates while the window shows them. Each refresh runs a one-shot
/// `nettop -L 1` (cumulative bytes per process) off the main thread and diffs it with the previous run.
/// (Streaming mode `-L 0` busy-loops at >100% CPU on macOS 26, so it is not used.)
final class NetTopRunner {
    private let lock = NSLock()
    private var active = false
    private var inFlight = false
    private var prev: [Int: (inB: Double, outB: Double)] = [:]
    private var prevAt: TimeInterval = 0
    private var latest: [NetProc] = []

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return active }

    func start() {
        lock.lock(); active = true; lock.unlock()
    }

    func stop() {
        lock.lock(); active = false; prev = [:]; latest = []; lock.unlock()
    }

    /// Kick off one measurement in the background; results show up in `top(_:)` on a later tick.
    func poll() {
        lock.lock()
        guard active, !inFlight else { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rows = Self.runOnce()
            let now = ProcessInfo.processInfo.systemUptime
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.inFlight = false
            guard self.active else { return }
            var current: [Int: (inB: Double, outB: Double)] = [:]
            var rates: [NetProc] = []
            let dt = now - self.prevAt
            for r in rows {
                current[r.pid] = (r.inB, r.outB)
                if let p = self.prev[r.pid], dt > 0, r.inB >= p.inB, r.outB >= p.outB {
                    let down = (r.inB - p.inB) / dt, up = (r.outB - p.outB) / dt
                    if down + up > 0 { rates.append(NetProc(name: r.name, pid: r.pid, down: down, up: up)) }
                }
            }
            if !self.prev.isEmpty { self.latest = rates.sorted { $0.down + $0.up > $1.down + $1.up } }
            self.prev = current
            self.prevAt = now
        }
    }

    func top(_ n: Int) -> [NetProc] {
        lock.lock(); defer { lock.unlock() }
        return Array(latest.prefix(n))
    }

    private static func runOnce() -> [(name: String, pid: Int, inB: Double, outB: Double)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [(String, Int, Double, Double)] = []
        for line in text.split(separator: "\n") where !line.hasPrefix(",") {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3, let dot = parts[0].lastIndex(of: "."),
                  let pid = Int(parts[0][parts[0].index(after: dot)...]),
                  let inB = Double(parts[1]), let outB = Double(parts[2]) else { continue }
            out.append((String(parts[0][..<dot]), pid, inB, outB))
        }
        return out
    }
}
