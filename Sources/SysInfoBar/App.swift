import SwiftUI
import AppKit
import ServiceManagement

@main
struct SysInfoBarApp: App {
    @StateObject private var monitor = Monitor()

    init() {
        // `SysInfoBar --dump`: print one snapshot to stdout and exit (for testing without the UI)
        if CommandLine.arguments.contains("--dump") {
            Monitor.dump()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(monitor)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Polls only while the panel is visible.
@MainActor
final class Monitor: ObservableObject {
    let info = StaticInfo.read()
    @Published private(set) var snap = Snapshot()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private lazy var sampler = Sampler(info: info)
    private var timer: Timer?
    /// Set by the panel: returns whether its window is actually on screen.
    var isPanelVisible: () -> Bool = { true }
    private let debug = ProcessInfo.processInfo.environment["SYSINFOBAR_DEBUG"] != nil

    private func log(_ msg: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[SysInfoBar] \(msg)\n".utf8))
    }

    func setVisible(_ visible: Bool) {
        if visible { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        log("polling start")
        sampler.reset()
        refresh()   // baseline (static values show at once)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.timer != nil { self?.refresh() }   // first real rates
        }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func stop() {
        guard timer != nil else { return }
        log("polling stop")
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard isPanelVisible() else { stop(); return }
        snap = sampler.sample()
        log(String(format: "tick cpu=%.0f%%", snap.cpuTotal * 100))
    }

    func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SysInfoBar: launch-at-login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    nonisolated static func dump() {
        let info = StaticInfo.read()
        let sampler = Sampler(info: info)
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 1)
        let s = sampler.sample()
        let mem = ByteCountFormatter.string(fromByteCount: Int64(s.memUsed), countStyle: .memory)
        let memT = ByteCountFormatter.string(fromByteCount: Int64(info.memTotal), countStyle: .memory)
        print("""
        Model   : \(info.modelName) [\(info.modelID)]
        OS      : \(info.osVersion)
        CPU     : \(info.cpuBrand) \(info.pCores)P+\(info.eCores)E (\(info.logicalCPUs) threads) \
        usage \(Int(s.cpuTotal * 100))%  per-core \(s.cpuPerCore.map { Int($0 * 100) })
        Memory  : \(mem) / \(memT)  swap \(ByteCountFormatter.string(fromByteCount: Int64(s.swapUsed), countStyle: .memory))
        GPU     : \(info.gpuName ?? "-") \(info.gpuCores.map { "\($0) cores" } ?? "") util \(s.gpuUtil.map { "\(Int($0 * 100))%" } ?? "-")
        Disk    : \(s.volumeName) used \(ByteCountFormatter.string(fromByteCount: s.diskTotal - s.diskFree, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: s.diskTotal, countStyle: .file))
        Uptime  : \(Int(s.uptime)) s
        Network : \(s.netIface ?? "-") \(s.netIP ?? "-")  down \(Int(s.netDown)) B/s  up \(Int(s.netUp)) B/s
        Status  : load \(s.status.load.map { String(format: "%.2f", $0) })  pressure \(s.status.memPressure)  thermal \(s.status.thermal.rawValue)
        Top CPU : \(s.topCPU.map { "\($0.name)(\($0.pid)) \(Int($0.value * 100))%" })
        Top Mem : \(s.topMem.map { "\($0.name)(\($0.pid)) \(Int($0.value / 1048576)) MB" })
        Power   : \(s.battery.map { "system \($0.systemWatts.map { String(format: "%.1f W", $0) } ?? "-") adapter \($0.adapterWatts ?? -1) W temp \($0.temperature ?? -1) C" } ?? "-")
        Battery : \(s.battery.map { "\($0.percent)% charging=\($0.charging) plugged=\($0.pluggedIn) cycles=\($0.cycles ?? -1) health=\($0.health ?? -1)%" } ?? "none")
        """)
    }
}
