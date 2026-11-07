import SwiftUI
import AppKit
import Combine

/// Owns the dashboard and settings windows. While either is open the app shows a Dock icon
/// and a main menu; when both close it goes back to being a menu-bar-only app.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var dashboard: NSWindow?
    private var settingsWindow: NSWindow?
    private var bag: Set<AnyCancellable> = []

    private override init() {
        super.init()
        AppSettings.shared.$windowOnTop.sink { [weak self] onTop in
            self?.dashboard?.level = onTop ? .floating : .normal
        }.store(in: &bag)
        AppSettings.shared.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitles() }
        }.store(in: &bag)
    }

    func showDashboard() {
        if dashboard == nil {
            let root = DashboardView()
                .environmentObject(Monitor.shared)
                .environmentObject(AppSettings.shared)
            let w = makeWindow(root, size: NSSize(width: 780, height: 720), autosave: "SysInfoBarDashboard")
            w.minSize = NSSize(width: 680, height: 560)
            w.styleMask.insert([.resizable, .miniaturizable])
            w.level = AppSettings.shared.windowOnTop ? .floating : .normal
            dashboard = w
        }
        present(dashboard!)
        Monitor.shared.setWindowVisible(true)
        updateTitles()
    }

    func showSettings() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(AppSettings.shared)
            settingsWindow = makeWindow(root, size: NSSize(width: 480, height: 600), autosave: "SysInfoBarSettings")
        }
        AppSettings.shared.refreshLaunchAtLogin()
        present(settingsWindow!)
        updateTitles()
    }

    private func makeWindow<V: View>(_ root: V, size: NSSize, autosave: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName(autosave)
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func updateTitles() {
        dashboard?.title = "SysInfoBar"
        settingsWindow?.title = tr("SysInfoBar 设置", "SysInfoBar Settings")
    }

    /// Debug: open / close the windows on a timer and log what happens (SYSINFOBAR_SELFTEST=1).
    func selfTest() {
        func log(_ m: String) {
            let policy = NSApp.activationPolicy() == .regular ? "regular(dock)" : "accessory"
            FileHandle.standardError.write(Data("[selftest] \(m) | policy=\(policy) dashboard=\(dashboard != nil) settings=\(settingsWindow != nil)\n".utf8))
        }
        let steps: [(Double, String, () -> Void)] = [
            (3, "show dashboard", { self.showDashboard() }),
            (6, "close dashboard", { self.dashboard?.performClose(nil) }),
            (10, "show settings", { self.showSettings() }),
            (13, "close settings", { self.settingsWindow?.performClose(nil) }),
            (16, "reopen (like clicking the app)", { _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false) }),
            (19, "close dashboard", { self.dashboard?.performClose(nil) }),
        ]
        for (t, name, act) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { act(); log(name) }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 1) { log("1s after \(name)") }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === dashboard {
            Monitor.shared.setWindowVisible(false)
            dashboard = nil           // free the SwiftUI view tree while closed
        } else if w === settingsWindow {
            settingsWindow = nil
        }
        DispatchQueue.main.async {
            if self.dashboard == nil && self.settingsWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Minimised or fully covered: stop sampling for the window until it shows again.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === dashboard else { return }
        Monitor.shared.setWindowVisible(w.occlusionState.contains(.visible))
    }
}
