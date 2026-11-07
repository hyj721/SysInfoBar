import SwiftUI
import AppKit
import Combine

@main
struct SysInfoBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var monitor = Monitor.shared
    @ObservedObject private var settings = AppSettings.shared

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
                .environmentObject(settings)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(tr("设置…", "Settings…")) { WindowManager.shared.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(tr("打开窗口", "Open Window")) { WindowManager.shared.showDashboard() }
                    .keyboardShortcut("n")
                Button(tr("关闭窗口", "Close Window")) { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshotter.run(into: CommandLine.arguments[i + 1]) }
            exit(0)
        }
        // Opened from Finder / Launchpad / Spotlight: show the window. Launched at login: stay in the menu bar.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        MainActor.assumeIsolated {
            if !loginLaunch && AppSettings.shared.openWindowOnLaunch {
                WindowManager.shared.showDashboard()
            }
            Monitor.shared.settingsChanged()
            if ProcessInfo.processInfo.environment["SYSINFOBAR_SELFTEST"] != nil { WindowManager.shared.selfTest() }
        }
    }

    /// Clicking the app again in Finder / Launchpad / Dock while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { WindowManager.shared.showDashboard() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// A value over time, for the window's charts.
struct Series {
    private(set) var points: [(t: TimeInterval, v: Double)] = []
    static let span: TimeInterval = 300   // keep 5 minutes

    mutating func add(_ v: Double, at t: TimeInterval) {
        points.append((t, v))
        let cutoff = t - Self.span
        if let i = points.firstIndex(where: { $0.t >= cutoff }), i > 0 { points.removeFirst(i) }
    }
    mutating func clear() { points.removeAll() }
    var maxValue: Double { points.map(\.v).max() ?? 0 }
}

struct History {
    var cpu = Series(), mem = Series(), gpu = Series(), power = Series(), down = Series(), up = Series()
    mutating func clear() { self = History() }
}

/// Samples system stats. Polls only while the panel or the window is on screen,
/// or every 5 s in the background when "record history in background" is on.
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    let info = StaticInfo.read()
    @Published private(set) var snap = Snapshot()
    @Published private(set) var history = History()

    private lazy var sampler = Sampler(info: info)
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var panelVisible = false
    private var windowVisible = false
    /// Set by the panel: returns whether its window is actually on screen.
    var isPanelVisible: () -> Bool = { false }
    private var bag: Set<AnyCancellable> = []
    private let debug = ProcessInfo.processInfo.environment["SYSINFOBAR_DEBUG"] != nil

    private init() {
        let s = AppSettings.shared
        s.$refreshInterval.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reschedule() }
        }.store(in: &bag)
        s.$recordInBackground.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reschedule() }
        }.store(in: &bag)
    }

    private func log(_ msg: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[SysInfoBar] \(msg)\n".utf8))
    }

    func setPanelVisible(_ v: Bool) {
        guard v != panelVisible else { return }
        panelVisible = v
        log("panel \(v ? "shown" : "hidden")")
        reschedule()
    }

    func setWindowVisible(_ v: Bool) {
        guard v != windowVisible else { return }
        windowVisible = v
        log("window \(v ? "shown" : "hidden")")
        reschedule()
    }

    func settingsChanged() { reschedule() }

    /// Interval to poll at now, or nil to stop.
    private var wantedInterval: TimeInterval? {
        if panelVisible || windowVisible { return AppSettings.shared.refreshInterval }
        if AppSettings.shared.recordInBackground { return max(5, AppSettings.shared.refreshInterval) }
        return nil
    }

    private func reschedule() {
        guard let interval = wantedInterval else { stop(); return }
        if timer != nil && interval == currentInterval { return }
        let fresh = timer == nil
        timer?.invalidate()
        if fresh {
            log("polling start (\(interval)s)")
            sampler.reset()
            history.clear()          // no gap-spanning lines from an earlier session
            refresh()                // baseline: static values show at once
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.timer != nil { self?.refresh() }   // first real rates
            }
        } else {
            log("polling interval -> \(interval)s")
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        currentInterval = interval
    }

    private func stop() {
        guard timer != nil else { return }
        log("polling stop")
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        // Safety net: the panel can close without a notification reaching us.
        if panelVisible && !isPanelVisible() { panelVisible = false; reschedule(); if timer == nil { return } }
        let s = sampler.sample()
        snap = s
        let now = ProcessInfo.processInfo.systemUptime
        var h = history
        h.cpu.add(s.cpuTotal, at: now)
        h.mem.add(Double(s.memUsed) / Double(max(info.memTotal, 1)), at: now)
        if let g = s.gpuUtil { h.gpu.add(g, at: now) }
        if let w = s.battery?.systemWatts { h.power.add(w, at: now) }
        h.down.add(s.netDown, at: now)
        h.up.add(s.netUp, at: now)
        history = h
        log(String(format: "tick cpu=%.0f%%", s.cpuTotal * 100))
    }

    /// Debug: take a few samples one second apart so the views have data and history.
    func debugWarmUp(samples: Int) {
        sampler.reset()
        for i in 0..<samples {
            if i > 0 { Thread.sleep(forTimeInterval: 1) }
            refresh()
        }
    }

    nonisolated static func dump() {
        let info = StaticInfo.read()
        let sampler = Sampler(info: info)
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 1)
        let s = sampler.sample()
        func mb(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }
        print("""
        Model   : \(info.modelName) [\(info.modelID)]
        OS      : \(info.osVersion)
        CPU     : \(info.cpuBrand) \(info.pCores)P+\(info.eCores)E (\(info.logicalCPUs) threads) \
        usage \(Int(s.cpuTotal * 100))%  per-core \(s.cpuPerCore.map { Int($0 * 100) })
        Memory  : \(mb(s.memUsed)) / \(mb(info.memTotal))  swap \(mb(s.swapUsed))
        MemParts: app \(mb(s.memApp)) wired \(mb(s.memWired)) compressed \(mb(s.memCompressed)) cached \(mb(s.memCached))
        GPU     : \(info.gpuName ?? "-") \(info.gpuCores.map { "\($0) cores" } ?? "") util \(s.gpuUtil.map { "\(Int($0 * 100))%" } ?? "-")
        Disk    : \(s.volumeName) used \(ByteCountFormatter.string(fromByteCount: s.diskTotal - s.diskFree, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: s.diskTotal, countStyle: .file))
        Uptime  : \(Int(s.uptime)) s
        Network : \(s.netIface ?? "-") \(s.netIP ?? "-")  down \(Int(s.netDown)) B/s  up \(Int(s.netUp)) B/s
        Status  : load \(s.status.load.map { String(format: "%.2f", $0) })  pressure \(s.status.memPressure)  thermal \(s.status.thermal.rawValue)
        Top CPU : \(s.topCPU.prefix(5).map { "\($0.name)(\($0.pid)) \(Int($0.cpu * 100))%" })
        Top Mem : \(s.topMem.prefix(5).map { "\($0.name)(\($0.pid)) \(Int($0.mem / 1048576)) MB" })
        Power   : \(s.battery.map { "system \($0.systemWatts.map { String(format: "%.1f W", $0) } ?? "-") adapter \($0.adapterWatts ?? -1) W temp \($0.temperature ?? -1) C" } ?? "-")
        Battery : \(s.battery.map { "\($0.percent)% charging=\($0.charging) plugged=\($0.pluggedIn) cycles=\($0.cycles ?? -1) health=\($0.health ?? -1)%" } ?? "none")
        """)
    }
}
