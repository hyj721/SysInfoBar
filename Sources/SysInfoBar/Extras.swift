import Foundation
import Darwin

// MARK: - Network throughput (sum of en* interfaces) + local IPv4

final class NetworkSampler {
    private var prev: (rx: UInt32, tx: UInt32, at: TimeInterval)?

    struct Result { var down: Double; var up: Double; var iface: String?; var ip: String? }

    func sample() -> Result {
        var rx: UInt32 = 0, tx: UInt32 = 0
        var ips: [(name: String, ip: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return Result(down: 0, up: 0) }
        defer { freeifaddrs(head) }

        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr,
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }   // Wi‑Fi / Ethernet / USB‑LAN
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                if let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    rx &+= data.pointee.ifi_ibytes
                    tx &+= data.pointee.ifi_obytes
                }
            case AF_INET:
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var a = $0.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
                }
                ips.append((name, String(cString: buf)))
            default: break
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        var r = Result(down: 0, up: 0)
        if let prev, now > prev.at {
            // 32-bit counters: wrapping subtraction handles rollover
            r.down = Double(rx &- prev.rx) / (now - prev.at)
            r.up = Double(tx &- prev.tx) / (now - prev.at)
        }
        prev = (rx, tx, now)
        if let best = ips.min(by: { $0.name.count != $1.name.count ? $0.name.count < $1.name.count : $0.name < $1.name }) {
            r.iface = best.name
            r.ip = best.ip
        }
        return r
    }
}

// MARK: - Top processes (current user's processes; others need root)

struct ProcStat: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let cpu: Double     // fraction of one core (can exceed 1)
    let mem: Double     // bytes (physical footprint)
    var id: pid_t { pid }
}

final class ProcessSampler {
    private var prevCPU: [pid_t: UInt64] = [:]   // ns
    private var prevAt: TimeInterval = 0
    private let ticksToNs: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private var pids = [pid_t](repeating: 0, count: 2048)

    func sample(top n: Int = 10) -> (cpu: [ProcStat], mem: [ProcStat]) {
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        if bytes <= 0 { return ([], []) }
        let count = min(Int(bytes), pids.count)
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - prevAt
        var cpuNow: [pid_t: UInt64] = [:]
        cpuNow.reserveCapacity(count)
        struct Row { let pid: pid_t; let cpu: Double; let mem: Double }
        var rows: [Row] = []
        rows.reserveCapacity(count)
        let haveDelta = !prevCPU.isEmpty && dt > 0

        for pid in pids.prefix(count) where pid > 0 {
            var ri = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0 else { continue }
            let t = UInt64(Double(ri.ri_user_time + ri.ri_system_time) * ticksToNs)
            cpuNow[pid] = t
            var c = 0.0
            if haveDelta, let old = prevCPU[pid], t >= old { c = Double(t - old) / 1e9 / dt }
            rows.append(Row(pid: pid, cpu: c, mem: Double(ri.ri_phys_footprint)))
        }
        prevCPU = cpuNow
        prevAt = now

        var names: [pid_t: String] = [:]
        func top(_ key: KeyPath<Row, Double>) -> [ProcStat] {
            rows.sorted { $0[keyPath: key] > $1[keyPath: key] }.prefix(n).map { r in
                let name = names[r.pid] ?? Self.name(of: r.pid)
                names[r.pid] = name
                return ProcStat(pid: r.pid, name: name, cpu: r.cpu, mem: r.mem)
            }
        }
        return (haveDelta ? top(\.cpu) : [], top(\.mem))
    }

    private static func name(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            return (String(cString: buf) as NSString).lastPathComponent
        }
        var short = [CChar](repeating: 0, count: 64)
        proc_name(pid, &short, UInt32(short.count))
        let s = String(cString: short)
        return s.isEmpty ? "pid \(pid)" : s
    }
}

// MARK: - System load / pressure / thermal

struct SystemStatus: Equatable {
    var load: [Double] = [0, 0, 0]
    var memPressure: Int = 1          // 1 normal, 2 warning, 4 critical
    var thermal: ProcessInfo.ThermalState = .nominal

    static func read() -> SystemStatus {
        var s = SystemStatus()
        var l = [Double](repeating: 0, count: 3)
        if getloadavg(&l, 3) == 3 { s.load = l }
        s.memPressure = Sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1
        s.thermal = ProcessInfo.processInfo.thermalState
        return s
    }
}
