import SwiftUI
import ServiceManagement

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en
    var id: String { rawValue }
}

enum TempUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
}

/// Sections of the menu bar panel that can be shown or hidden.
enum PanelSection: String, CaseIterable, Identifiable {
    case status, cpu, memory, gpu, disk, network, battery, power, processes
    case thermals, diskIO, wifi, peripherals, displays
    var id: String { rawValue }

    /// Sections added later that start hidden in the panel (shown in the window).
    static let hiddenByDefault: Set<PanelSection> = [.displays]

    var title: String {
        switch self {
        case .status: return tr("状态条", "Status bar")
        case .cpu: return "CPU"
        case .memory: return tr("内存", "Memory")
        case .gpu: return "GPU"
        case .disk: return tr("磁盘", "Disk")
        case .network: return tr("网络", "Network")
        case .battery: return tr("电池", "Battery")
        case .power: return tr("功耗", "Power")
        case .processes: return tr("我的进程", "My processes")
        case .thermals: return tr("温度与风扇", "Temperature and fans")
        case .diskIO: return tr("磁盘读写", "Disk activity")
        case .wifi: return "Wi‑Fi"
        case .peripherals: return tr("外设电量", "Peripheral batteries")
        case .displays: return tr("显示器", "Displays")
        }
    }
}

/// Optional cards in the dashboard window (the core cards are always shown).
enum WindowSection: String, CaseIterable, Identifiable {
    case thermals, diskIO, wifi, peripherals, displays, processNetwork
    var id: String { rawValue }

    var title: String {
        switch self {
        case .thermals: return tr("温度与风扇", "Temperature and fans")
        case .diskIO: return tr("磁盘读写", "Disk activity")
        case .wifi: return "Wi‑Fi"
        case .peripherals: return tr("外设电量", "Peripheral batteries")
        case .displays: return tr("显示器", "Displays")
        case .processNetwork: return tr("进程网络流量", "Network by process")
        }
    }

    var panelCounterpart: PanelSection? {
        switch self {
        case .thermals: return .thermals
        case .diskIO: return .diskIO
        case .wifi: return .wifi
        case .peripherals: return .peripherals
        case .displays: return .displays
        case .processNetwork: return nil
        }
    }
}

/// User preferences, persisted in UserDefaults. Views observe it so a language change re-renders at once.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var language: AppLanguage { didSet { d.set(language.rawValue, forKey: "language") } }
    /// Seconds between refreshes while the panel or window is open.
    @Published var refreshInterval: Double { didSet { d.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var tempUnit: TempUnit { didSet { d.set(tempUnit.rawValue, forKey: "tempUnit") } }
    @Published var hiddenSections: Set<PanelSection> {
        didSet { d.set(hiddenSections.map(\.rawValue), forKey: "hiddenSections") }
    }
    @Published var hiddenWindowSections: Set<WindowSection> {
        didSet { d.set(hiddenWindowSections.map(\.rawValue), forKey: "hiddenWindowSections") }
    }
    @Published var windowOnTop: Bool { didSet { d.set(windowOnTop, forKey: "windowOnTop") } }
    @Published var openWindowOnLaunch: Bool { didSet { d.set(openWindowOnLaunch, forKey: "openWindowOnLaunch") } }
    /// Keep sampling (every 5 s) while nothing is open, so the window's charts already have history.
    @Published var recordInBackground: Bool { didSet { d.set(recordInBackground, forKey: "recordInBackground") } }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private init() {
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        let r = d.double(forKey: "refreshInterval")
        refreshInterval = [1, 2, 5].contains(r) ? r : 2
        tempUnit = TempUnit(rawValue: d.string(forKey: "tempUnit") ?? "") ?? .celsius
        var hidden = Set((d.stringArray(forKey: "hiddenSections") ?? []).compactMap(PanelSection.init))
        // Sections introduced in version 2 of the layout: hide the default-hidden ones once.
        if d.integer(forKey: "sectionsVersion") < 2 {
            hidden.formUnion(PanelSection.hiddenByDefault)
            d.set(hidden.map(\.rawValue), forKey: "hiddenSections")
            d.set(2, forKey: "sectionsVersion")
        }
        hiddenSections = hidden
        hiddenWindowSections = Set((d.stringArray(forKey: "hiddenWindowSections") ?? []).compactMap(WindowSection.init))
        windowOnTop = d.bool(forKey: "windowOnTop")
        openWindowOnLaunch = d.object(forKey: "openWindowOnLaunch") as? Bool ?? true
        recordInBackground = d.bool(forKey: "recordInBackground")
    }

    var isChinese: Bool { AppLanguage.resolveChinese(language) }

    func shows(_ s: PanelSection) -> Bool { !hiddenSections.contains(s) }

    func setSection(_ s: PanelSection, visible: Bool) {
        if visible { hiddenSections.remove(s) } else { hiddenSections.insert(s) }
    }

    func windowShows(_ s: WindowSection) -> Bool { !hiddenWindowSections.contains(s) }

    func setWindowSection(_ s: WindowSection, visible: Bool) {
        if visible { hiddenWindowSections.remove(s) } else { hiddenWindowSections.insert(s) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SysInfoBar: launch-at-login change failed: \(error)")
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }

    /// Compact form for tight spots: "52°".
    func temperatureShort(_ celsius: Double) -> String {
        tempUnit == .celsius ? "\(Int(celsius.rounded()))°" : "\(Int((celsius * 9 / 5 + 32).rounded()))°"
    }

    func temperature(_ celsius: Double) -> String {
        switch tempUnit {
        case .celsius: return String(format: "%.1f °C", celsius)
        case .fahrenheit: return String(format: "%.1f °F", celsius * 9 / 5 + 32)
        }
    }
}

extension AppLanguage {
    static func resolveChinese(_ l: AppLanguage) -> Bool {
        switch l {
        case .zh: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }
}

/// Pick the Chinese or English string for the current language setting.
/// Reads UserDefaults (an in-memory cache) so it can be called from any context.
func tr(_ zh: String, _ en: String) -> String {
    let l = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
    return AppLanguage.resolveChinese(l) ? zh : en
}
