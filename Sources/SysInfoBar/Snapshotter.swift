import SwiftUI
import AppKit

/// Debug aid: `SysInfoBar --snapshot <dir>` renders the panel, dashboard and settings
/// (Chinese / English, light / dark) to PNG files, then quits. No screen-recording permission needed.
@MainActor
enum Snapshotter {
    static func run(into dir: String) {
        let m = Monitor.shared
        m.debugWarmUp(samples: 6)
        let s = AppSettings.shared
        let savedLang = s.language
        for lang in [AppLanguage.zh, .en] {
            s.language = lang
            for dark in [false, true] {
                let tag = "\(lang.rawValue)-\(dark ? "dark" : "light")"
                render(PanelView().environmentObject(m).environmentObject(s),
                       size: nil, dark: dark, to: "\(dir)/panel-\(tag).png")
                render(DashboardView().environmentObject(m).environmentObject(s),
                       size: NSSize(width: 780, height: 1500), dark: dark, to: "\(dir)/dashboard-\(tag).png")
                render(SettingsView().environmentObject(s),
                       size: NSSize(width: 480, height: 1500), dark: dark, to: "\(dir)/settings-\(tag).png")
            }
        }
        s.language = savedLang
    }

    /// `--bench`: CPU time per refresh for sampling and for re-rendering the dashboard and panel.
    static func bench() {
        let m = Monitor.shared
        m.debugWarmUp(samples: 2)
        func cpuNow() -> Double {
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        let s = AppSettings.shared
        func host<V: View>(_ v: V, _ size: NSSize) -> NSHostingView<AnyView> {
            let h = NSHostingView(rootView: AnyView(v))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = h
            h.frame = NSRect(origin: .zero, size: size)
            return h
        }
        let only = ProcessInfo.processInfo.environment["BENCH_ONLY"]
        var hosts: [NSView] = []
        if only != "panel" && only != "none" { hosts.append(host(DashboardView().environmentObject(m).environmentObject(s), NSSize(width: 780, height: 1500))) }
        if only != "dashboard" && only != "none" { hosts.append(host(PanelView().environmentObject(m).environmentObject(s), NSSize(width: 320, height: 1400))) }
        var sampleT = 0.0, renderT = 0.0
        let n = 20
        for _ in 0..<n {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let t0 = cpuNow()
            m.debugTick()
            let t1 = cpuNow()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // let SwiftUI apply the update
            for h in hosts { h.layoutSubtreeIfNeeded() }
            let t2 = cpuNow()
            sampleT += t1 - t0; renderT += t2 - t1
        }
        print(String(format: "per tick: sampling %.1f ms, SwiftUI update+layout (dashboard+panel) %.1f ms (avg of %d)", sampleT / Double(n) * 1000, renderT / Double(n) * 1000, n))
    }

    private static func render<V: View>(_ view: V, size: NSSize?, dark: Bool, to path: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let fit = size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fit), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: fit)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
