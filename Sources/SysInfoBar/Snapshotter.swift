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
                       size: NSSize(width: 780, height: 900), dark: dark, to: "\(dir)/dashboard-\(tag).png")
                render(SettingsView().environmentObject(s),
                       size: NSSize(width: 480, height: 1100), dark: dark, to: "\(dir)/settings-\(tag).png")
            }
        }
        s.language = savedLang
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
