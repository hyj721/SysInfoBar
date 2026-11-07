import SwiftUI
import AppKit

struct PanelView: View {
    @EnvironmentObject var m: Monitor
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let info = m.info, s = m.snap
        VStack(alignment: .leading, spacing: 14) {
            header(info)
            if settings.shows(.status) { StatusLine(status: s.status, lang: settings.language) }

            Divider()

            if settings.shows(.cpu) {
                MetricRow(icon: "cpu", title: "CPU",
                          subtitle: "\(info.cpuBrand) · \(info.pCores)P + \(info.eCores)E",
                          value: Fmt.percent(s.cpuTotal), fraction: s.cpuTotal) {
                    CoreBars(values: s.cpuPerCore, pCores: info.pCores, eCores: info.eCores, lang: settings.language)
                }
            }

            if settings.shows(.memory) {
                MetricRow(icon: "memorychip", title: tr("内存", "Memory"),
                          subtitle: "Swap \(Fmt.mem(s.swapUsed)) · " + tr("压力 ", "Pressure ") + pressureText(s.status.memPressure),
                          value: "\(Fmt.mem(s.memUsed)) / \(Fmt.mem(info.memTotal))",
                          fraction: Double(s.memUsed) / Double(max(info.memTotal, 1)))
            }

            if settings.shows(.gpu), let gpu = info.gpuName {
                MetricRow(icon: "rectangle.3.group", title: "GPU",
                          subtitle: info.gpuCores.map { "\(gpu) · " + tr("\($0) 核", "\($0) cores") } ?? gpu,
                          value: s.gpuUtil.map(Fmt.percent) ?? "—",
                          fraction: s.gpuUtil ?? 0)
            }

            if settings.shows(.thermals), let t = s.thermals {
                MetricRow(icon: "thermometer.medium", title: tr("温度与风扇", "Temperature"),
                          subtitle: fanText(t),
                          value: thermalValue(t),
                          fraction: (t.cpuAvg ?? 0) / 100,
                          tint: tempColor(t.cpuMax ?? t.cpuAvg ?? 0))
            }

            if settings.shows(.disk) {
                MetricRow(icon: "internaldrive", title: tr("磁盘", "Disk"),
                          subtitle: "\(s.volumeName) · " + tr("可用 ", "Free ") + Fmt.disk(s.diskFree),
                          value: "\(Fmt.disk(s.diskTotal - s.diskFree)) / \(Fmt.disk(s.diskTotal))",
                          fraction: s.diskTotal > 0 ? Double(s.diskTotal - s.diskFree) / Double(s.diskTotal) : 0)
            }

            if settings.shows(.diskIO) {
                MetricRow(icon: "arrow.up.arrow.down.circle", title: tr("磁盘读写", "Disk activity"),
                          subtitle: s.volumes.isEmpty ? tr("无外接磁盘", "No external drives")
                            : tr("外接：", "External: ") + s.volumes.map(\.name).joined(separator: ", "),
                          value: tr("读 ", "R ") + Fmt.rate(s.diskRead) + "  " + tr("写 ", "W ") + Fmt.rate(s.diskWrite),
                          fraction: nil, tint: .mint)
            }

            if settings.shows(.network) {
                MetricRow(icon: "network", title: tr("网络", "Network"),
                          subtitle: [s.netIface, s.netIP].compactMap { $0 }.joined(separator: " · ")
                            .ifEmpty(tr("未连接", "Not connected")),
                          value: "↓ \(Fmt.rate(s.netDown))   ↑ \(Fmt.rate(s.netUp))",
                          fraction: nil, tint: .indigo)
            }

            if settings.shows(.wifi), let w = s.wifi {
                MetricRow(icon: "wifi", title: "Wi‑Fi",
                          subtitle: wifiSubtitle(w),
                          value: "\(w.rssi) dBm · " + signalText(w.rssi),
                          fraction: signalFraction(w.rssi), tint: signalColor(w.rssi))
            }

            if let b = s.battery {
                if settings.shows(.battery) {
                    MetricRow(icon: batteryIcon(b), title: tr("电池", "Battery"),
                              subtitle: batterySubtitle(b),
                              value: "\(b.percent)%",
                              fraction: Double(b.percent) / 100,
                              tint: b.percent <= 20 && !b.pluggedIn ? .red : .green)
                }
                if settings.shows(.power), let w = b.systemWatts {
                    MetricRow(icon: "bolt.fill", title: tr("功耗", "Power"),
                              subtitle: powerSubtitle(b),
                              value: String(format: "%.1f W", w),
                              fraction: nil, tint: .yellow)
                }
            }

            if settings.shows(.peripherals), !s.peripherals.isEmpty {
                MetricRow(icon: "computermouse", title: tr("外设电量", "Peripherals"),
                          subtitle: s.peripherals.map { "\($0.name) \($0.percent)%" }.joined(separator: " · "),
                          value: "\(s.peripherals.map(\.percent).min() ?? 0)%",
                          fraction: Double(s.peripherals.map(\.percent).min() ?? 0) / 100,
                          tint: (s.peripherals.map(\.percent).min() ?? 100) <= 20 ? .red : .green)
            }

            if settings.shows(.displays), !s.displays.isEmpty {
                MetricRow(icon: "display", title: tr("显示器", "Displays"),
                          subtitle: s.displays.map { "\($0.name) \($0.pixelWidth)×\($0.pixelHeight) \($0.refresh) Hz" }
                            .joined(separator: " · "),
                          value: tr("\(s.displays.count) 台", "\(s.displays.count)"),
                          fraction: nil, tint: .cyan)
            }

            if settings.shows(.processes) {
                Divider()
                ProcessTable(cpu: Array(s.topCPU.prefix(3)), mem: Array(s.topMem.prefix(3)), lang: settings.language)
            }

            Divider()

            footer(s)
        }
        .padding(16)
        .frame(width: 320)
        .background(VisibilityReporter(onChange: { m.setPanelVisible($0) },
                                       register: { m.isPanelVisible = $0 }))
    }

    // MARK: pieces

    private func header(_ info: StaticInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: info.modelID.hasPrefix("MacBook") ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.modelName).font(.headline)
                Text(info.osVersion).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func footer(_ s: Snapshot) -> some View {
        HStack(spacing: 12) {
            Label(Fmt.uptime(s.uptime), systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Spacer()
            Button { WindowManager.shared.showDashboard() } label: { Image(systemName: "macwindow") }
                .help(tr("打开窗口", "Open window"))
            Button { WindowManager.shared.showSettings() } label: { Image(systemName: "gearshape") }
                .help(tr("设置", "Settings"))
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help(tr("退出", "Quit"))
        }
        .buttonStyle(.borderless)
    }

    // MARK: formatting

    private func thermalValue(_ t: Thermals) -> String {
        var parts: [String] = []
        if let c = t.cpuAvg { parts.append("CPU " + settings.temperatureShort(c)) }
        if let g = t.gpuAvg { parts.append("GPU " + settings.temperatureShort(g)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
    private func fanText(_ t: Thermals) -> String {
        var parts: [String] = []
        if let m = t.cpuMax { parts.append(tr("最高 ", "Peak ") + settings.temperatureShort(m)) }
        if t.fans.isEmpty { parts.append(tr("无风扇", "No fans")) }
        else if t.fans.allSatisfy({ $0.rpm < 1 }) { parts.append(tr("风扇停转", "Fans off")) }
        else { parts.append(tr("风扇 ", "Fans ") + t.fans.map { "\(Int($0.rpm))" }.joined(separator: " / ") + " RPM") }
        return parts.joined(separator: " · ")
    }
    private func wifiSubtitle(_ w: WiFiInfo) -> String {
        var parts: [String] = []
        if let b = w.bandGHz { parts.append("\(b) GHz") }
        if let c = w.channel { parts.append(tr("信道 \(c)", "Ch \(c)")) }
        parts.append("\(Int(w.txRate)) Mbps")
        if let std = w.standard { parts.append(std) }
        return parts.joined(separator: " · ")
    }

    private func powerSubtitle(_ b: Snapshot.Battery) -> String {
        var parts: [String] = []
        if let a = b.adapterWatts { parts.append(tr("充电器 \(a) W", "\(a) W charger")) }
        if let t = b.temperature { parts.append(tr("电池 ", "Battery ") + settings.temperature(t)) }
        let whole = tr("整机", "Whole system")
        return parts.isEmpty ? whole : whole + " · " + parts.joined(separator: " · ")
    }
    private func batteryIcon(_ b: Snapshot.Battery) -> String {
        if b.charging || b.pluggedIn { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    private func batterySubtitle(_ b: Snapshot.Battery) -> String {
        var parts: [String] = []
        if b.charging { parts.append(tr("充电中", "Charging")) }
        else if b.pluggedIn { parts.append(tr("已接电源", "Plugged in")) }
        else if let r = b.minutesRemaining {
            parts.append(tr("剩余 ", "") + "\(r / 60):\(String(format: "%02d", r % 60))" + tr("", " left"))
        }
        else { parts.append(tr("使用电池", "On battery")) }
        if let h = b.health { parts.append(tr("健康 \(h)%", "Health \(h)%")) }
        if let c = b.cycles { parts.append(tr("循环 \(c)", "\(c) cycles")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Components

struct MetricRow<Extra: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let value: String
    let fraction: Double?
    var tint: Color? = nil
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(value).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                if let fraction { Bar(fraction: fraction, color: color) }
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                extra()
            }
        }
    }

    private var color: Color {
        if let tint { return tint }
        switch fraction ?? 0 {
        case ..<0.6: return .accentColor
        case ..<0.85: return .orange
        default: return .red
        }
    }
}

extension MetricRow where Extra == EmptyView {
    init(icon: String, title: String, subtitle: String, value: String, fraction: Double?, tint: Color? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle, value: value,
                  fraction: fraction, tint: tint, extra: { EmptyView() })
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.gradient)
                    .frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

/// Tiny per-core bars. Efficiency cores come first in macOS core numbering on Apple Silicon.
struct CoreBars: View {
    let values: [Double]
    let pCores: Int
    let eCores: Int
    let lang: AppLanguage
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < eCores ? Color.teal : Color.accentColor)
                        .frame(height: max(1, 16 * v))
                }
                .frame(height: 16)
            }
        }
        .padding(.top, 2)
        .help(tr("每个核心的使用率（青色为能效核）", "Per-core usage (teal = efficiency cores)"))
    }
}

// MARK: - Visibility tracking

/// Reports whether the panel window is on screen, so polling runs only while it is open.
/// Starts polling when the window shows / becomes key, stops when it resigns key, is hidden or closes.
/// Also hands the monitor a probe so each tick can double-check the window is still on screen.
struct VisibilityReporter: NSViewRepresentable {
    let onChange: (Bool) -> Void
    let register: (@escaping () -> Bool) -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView(onChange: onChange, register: register) }
    func updateNSView(_ nsView: TrackingView, context: Context) { nsView.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void
        let register: (@escaping () -> Bool) -> Void
        private var tokens: [NSObjectProtocol] = []
        init(onChange: @escaping (Bool) -> Void, register: @escaping (@escaping () -> Bool) -> Void) {
            self.onChange = onChange
            self.register = register
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        private static func shown(_ w: NSWindow?) -> Bool {
            guard let w else { return false }
            return w.isVisible && w.occlusionState.contains(.visible)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let w = window else { onChange(false); return }
            register { [weak w] in Self.shown(w) }
            let nc = NotificationCenter.default
            func on(_ name: Notification.Name, _ visible: @escaping (NSWindow) -> Bool) {
                tokens.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self, weak w] _ in
                    guard let self, let w else { return }
                    self.onChange(visible(w))
                })
            }
            on(NSWindow.didBecomeKeyNotification) { _ in true }
            on(NSWindow.didResignKeyNotification) { _ in false }
            on(NSWindow.didChangeOcclusionStateNotification) { Self.shown($0) }
            on(NSWindow.willCloseNotification) { _ in false }
            onChange(Self.shown(w))
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Status chips: load average, memory pressure, thermal state

struct StatusLine: View {
    let status: SystemStatus
    let lang: AppLanguage
    var body: some View {
        HStack(spacing: 6) {
            chip(tr("负载", "Load"), status.load.map { String(format: "%.1f", $0) }.joined(separator: " "), loadColor)
            chip(tr("内存压力", "Memory"), pressureText(status.memPressure), pressureColor)
            chip(tr("温控", "Thermal"), thermalText(status.thermal), thermalColor)
        }
        .help(tr("负载：1 / 5 / 15 分钟平均；温控：系统热状态，偏热以上会降频",
                 "Load: 1 / 5 / 15 minute averages. Thermal: system thermal state; above Normal the CPU throttles"))
    }

    private var loadColor: Color {
        let per = status.load[0] / Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        return per < 0.7 ? .green : per < 1 ? .orange : .red
    }
    private var pressureColor: Color {
        switch status.memPressure {
        case 4: return .red
        case 2: return .orange
        default: return .green
        }
    }
    private var thermalColor: Color {
        switch status.thermal {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    private func chip(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .lineLimit(1)
    }
}

// MARK: - Top processes

struct ProcessTable: View {
    let cpu: [ProcStat]
    let mem: [ProcStat]
    let lang: AppLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                Text(tr("我的进程", "My processes")).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            HStack(alignment: .top, spacing: 14) {
                column("CPU", cpu) { "\(Int(($0.cpu * 100).rounded()))%" }
                column(tr("内存", "Memory"), mem) { Fmt.mem($0.mem) }
            }
        }
        .help(tr("只统计当前用户的进程；系统进程需要管理员权限才能读取",
                 "Only your own processes; system processes need admin rights to read"))
    }

    private func column(_ title: String, _ items: [ProcStat], _ fmt: @escaping (ProcStat) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("…").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(items) { p in
                HStack(spacing: 4) {
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    Text(fmt(p)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared helpers for temperature and Wi‑Fi

func tempColor(_ c: Double) -> Color { c < 70 ? .green : c < 85 ? .orange : .red }

func signalFraction(_ rssi: Int) -> Double { min(max(Double(rssi + 90) / 60, 0), 1) }   // -90 dBm … -30 dBm

func signalText(_ rssi: Int) -> String {
    switch rssi {
    case (-50)...: return tr("极好", "Excellent")
    case (-60)...: return tr("良好", "Good")
    case (-70)...: return tr("一般", "Fair")
    default: return tr("较弱", "Weak")
    }
}

func signalColor(_ rssi: Int) -> Color { rssi >= -60 ? .green : rssi >= -70 ? .orange : .red }
