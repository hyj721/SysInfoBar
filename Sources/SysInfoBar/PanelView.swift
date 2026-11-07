import SwiftUI
import AppKit

struct PanelView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        let info = m.info, s = m.snap
        VStack(alignment: .leading, spacing: 14) {
            header(info)
            StatusLine(status: s.status)

            Divider()

            MetricRow(icon: "cpu", title: "CPU",
                      subtitle: "\(info.cpuBrand) · \(info.pCores)P + \(info.eCores)E",
                      value: percent(s.cpuTotal), fraction: s.cpuTotal) {
                CoreBars(values: s.cpuPerCore, pCores: info.pCores, eCores: info.eCores)
            }

            MetricRow(icon: "memorychip", title: "内存",
                      subtitle: "Swap \(mem(s.swapUsed))",
                      value: "\(mem(s.memUsed)) / \(mem(info.memTotal))",
                      fraction: Double(s.memUsed) / Double(max(info.memTotal, 1)))

            if let gpu = info.gpuName {
                MetricRow(icon: "rectangle.3.group", title: "GPU",
                          subtitle: info.gpuCores.map { "\(gpu) · \($0) 核" } ?? gpu,
                          value: s.gpuUtil.map(percent) ?? "—",
                          fraction: s.gpuUtil ?? 0)
            }

            MetricRow(icon: "internaldrive", title: "磁盘",
                      subtitle: "\(s.volumeName) · 可用 \(disk(s.diskFree))",
                      value: "\(disk(s.diskTotal - s.diskFree)) / \(disk(s.diskTotal))",
                      fraction: s.diskTotal > 0 ? Double(s.diskTotal - s.diskFree) / Double(s.diskTotal) : 0)

            MetricRow(icon: "network", title: "网络",
                      subtitle: [s.netIface, s.netIP].compactMap { $0 }.joined(separator: " · ").ifEmpty("未连接"),
                      value: "↓ \(rate(s.netDown))   ↑ \(rate(s.netUp))",
                      fraction: nil, tint: .indigo)

            if let b = s.battery {
                MetricRow(icon: batteryIcon(b), title: "电池",
                          subtitle: batterySubtitle(b),
                          value: "\(b.percent)%",
                          fraction: Double(b.percent) / 100,
                          tint: b.percent <= 20 && !b.pluggedIn ? .red : .green)
                if let w = b.systemWatts {
                    MetricRow(icon: "bolt.fill", title: "功耗",
                              subtitle: powerSubtitle(b),
                              value: String(format: "%.1f W", w),
                              fraction: nil, tint: .yellow)
                }
            }

            Divider()

            ProcessTable(cpu: s.topCPU, mem: s.topMem)

            Divider()

            footer(s)
        }
        .padding(16)
        .frame(width: 320)
        .background(VisibilityReporter(onChange: { m.setVisible($0) },
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
        HStack(spacing: 10) {
            Label(uptime(s.uptime), systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Spacer()
            Toggle("开机启动", isOn: Binding(get: { m.launchAtLogin },
                                          set: { m.toggleLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("退出")
        }
    }

    // MARK: formatting

    private func rate(_ b: Double) -> String {
        switch b {
        case ..<1_000: return "\(Int(b)) B/s"
        case ..<1_000_000: return String(format: "%.0f KB/s", b / 1_000)
        default: return String(format: "%.1f MB/s", b / 1_000_000)
        }
    }
    private func powerSubtitle(_ b: Snapshot.Battery) -> String {
        var parts: [String] = []
        if let a = b.adapterWatts { parts.append("充电器 \(a) W") }
        if let t = b.temperature { parts.append(String(format: "电池 %.1f °C", t)) }
        return parts.isEmpty ? "整机" : "整机 · " + parts.joined(separator: " · ")
    }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func mem(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
    private func disk(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    private func uptime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "已运行 \(d) 天 \(h) 小时" }
        if h > 0 { return "已运行 \(h) 小时 \(mm) 分" }
        return "已运行 \(mm) 分钟"
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
        if b.charging { parts.append("充电中") }
        else if b.pluggedIn { parts.append("已接电源") }
        else if let r = b.minutesRemaining { parts.append("剩余 \(r / 60):\(String(format: "%02d", r % 60))") }
        else { parts.append("使用电池") }
        if let h = b.health { parts.append("健康 \(h)%") }
        if let c = b.cycles { parts.append("循环 \(c)") }
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
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// Tiny per-core bars. Efficiency cores come first in macOS core numbering on Apple Silicon.
struct CoreBars: View {
    let values: [Double]
    let pCores: Int
    let eCores: Int
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
        .animation(.easeOut(duration: 0.4), value: values)
        .padding(.top, 2)
        .help("每个核心的使用率（青色为能效核）")
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
    var body: some View {
        HStack(spacing: 6) {
            chip("负载", status.load.map { String(format: "%.1f", $0) }.joined(separator: " "), loadColor)
            chip("内存压力", pressure.0, pressure.1)
            chip("温控", thermal.0, thermal.1)
        }
        .help("负载：1 / 5 / 15 分钟平均；温控：系统热状态，偏热以上会降频")
    }

    private var loadColor: Color {
        let per = status.load[0] / Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        return per < 0.7 ? .green : per < 1 ? .orange : .red
    }
    private var pressure: (String, Color) {
        switch status.memPressure {
        case 4: return ("严重", .red)
        case 2: return ("紧张", .orange)
        default: return ("正常", .green)
        }
    }
    private var thermal: (String, Color) {
        switch status.thermal {
        case .nominal: return ("正常", .green)
        case .fair: return ("偏热", .yellow)
        case .serious: return ("很热", .orange)
        case .critical: return ("严重", .red)
        @unknown default: return ("—", .gray)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                Text("我的进程").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            HStack(alignment: .top, spacing: 14) {
                column("CPU", cpu) { "\(Int(($0 * 100).rounded()))%" }
                column("内存", mem) { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }
            }
        }
        .help("只统计当前用户的进程；系统进程需要管理员权限才能读取")
    }

    private func column(_ title: String, _ items: [ProcStat], _ fmt: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("…").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(items) { p in
                HStack(spacing: 4) {
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    Text(fmt(p.value)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
