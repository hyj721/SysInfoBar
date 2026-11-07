import SwiftUI
import AppKit

// MARK: - Shared formatting

enum Fmt {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func mem(_ b: UInt64) -> String {
        b < 1024 ? "0 MB" : ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
    static func mem(_ b: Double) -> String { mem(UInt64(max(b, 0))) }
    static func disk(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func rate(_ b: Double) -> String {
        switch b {
        case ..<1_000: return "\(Int(b)) B/s"
        case ..<1_000_000: return String(format: "%.0f KB/s", b / 1_000)
        default: return String(format: "%.1f MB/s", b / 1_000_000)
        }
    }
    static func uptime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return tr("已运行 \(d) 天 \(h) 小时", "Up \(d)d \(h)h") }
        if h > 0 { return tr("已运行 \(h) 小时 \(mm) 分", "Up \(h)h \(mm)m") }
        return tr("已运行 \(mm) 分钟", "Up \(mm) min")
    }
}

// MARK: - Dashboard window

struct DashboardView: View {
    @EnvironmentObject var m: Monitor
    @EnvironmentObject var settings: AppSettings
    @State private var sort: ProcSort = .cpu

    var body: some View {
        let info = m.info, s = m.snap, h = m.history
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(info, s)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    Tile(title: "CPU", value: Fmt.percent(s.cpuTotal), unit: nil,
                         series: h.cpu, maxValue: 1, color: .blue)
                    Tile(title: tr("内存", "Memory"), value: Fmt.mem(s.memUsed), unit: "/ " + Fmt.mem(info.memTotal),
                         series: h.mem, maxValue: 1, color: .purple)
                    Tile(title: "GPU", value: s.gpuUtil.map(Fmt.percent) ?? "—", unit: nil,
                         series: h.gpu, maxValue: 1, color: .teal)
                    if let w = s.battery?.systemWatts {
                        Tile(title: tr("功耗", "Power"), value: String(format: "%.1f", w), unit: "W",
                             series: h.power, maxValue: max(h.power.maxValue * 1.2, 10), color: .orange)
                    } else {
                        Tile(title: tr("下载", "Download"), value: Fmt.rate(s.netDown), unit: nil,
                             series: h.down, maxValue: max(h.down.maxValue * 1.2, 50_000), color: .indigo)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Card(title: tr("CPU 核心", "CPU cores"),
                         trailing: tr("负载 ", "Load ") + String(format: "%.1f", s.status.load.first ?? 0)
                            + " · " + tr("温控 ", "Thermal ") + thermalText(s.status.thermal)) {
                        CoreGroups(values: s.cpuPerCore, eCores: info.eCores, lang: settings.language)
                    }
                    Card(title: tr("内存构成", "Memory breakdown"),
                         trailing: tr("压力 ", "Pressure ") + pressureText(s.status.memPressure)
                            + " · Swap " + Fmt.mem(s.swapUsed)) {
                        MemoryBreakdown(s: s, total: info.memTotal, lang: settings.language)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Card(title: tr("网络", "Network") + ([s.netIface, s.netIP].compactMap { $0 }.isEmpty ? ""
                            : " · " + [s.netIface, s.netIP].compactMap { $0 }.joined(separator: " ")),
                         trailing: "↓ \(Fmt.rate(s.netDown))  ↑ \(Fmt.rate(s.netUp))") {
                        NetworkChart(down: h.down, up: h.up, lang: settings.language)
                    }
                    Card(title: tr("磁盘与电池", "Disk and battery"),
                         trailing: Fmt.disk(s.diskTotal - s.diskFree) + " / " + Fmt.disk(s.diskTotal)) {
                        diskBattery(s)
                    }
                }

                optionalCards(s, h)

                Card(title: tr("进程", "Processes"), trailing: nil) {
                    ProcessList(cpu: s.topCPU, mem: s.topMem, net: s.netProcs,
                                showNetwork: settings.windowShows(.processNetwork),
                                sort: $sort, lang: settings.language)
                        .equatable()
                }

                Text(tr("曲线显示最近 5 分钟 · 数据只在本机读取，不联网",
                        "Charts show the last 5 minutes · All data is read locally, nothing goes online"))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(18)
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    private func header(_ info: StaticInfo, _ s: Snapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: info.modelID.hasPrefix("MacBook") ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.modelName).font(.title3.weight(.semibold))
                Text("\(info.cpuBrand) · \(Fmt.mem(info.memTotal)) · \(info.osVersion) · \(Fmt.uptime(s.uptime))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker(selection: $settings.refreshInterval) {
                Text(tr("1 秒", "1s")).tag(1.0)
                Text(tr("2 秒", "2s")).tag(2.0)
                Text(tr("5 秒", "5s")).tag(5.0)
            } label: { EmptyView() }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(tr("刷新间隔", "Refresh interval"))
            Toggle(isOn: $settings.windowOnTop) {
                Image(systemName: settings.windowOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .help(tr("窗口置顶", "Keep window on top"))
            Button { WindowManager.shared.showSettings() } label: { Image(systemName: "gearshape") }
                .help(tr("设置", "Settings"))
        }
    }

    /// Optional cards, two per row; hidden or unavailable ones leave no gap.
    @ViewBuilder private func optionalCards(_ s: Snapshot, _ h: History) -> some View {
        let cards = optionalCardList(s, h)
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: cards.count, by: 2)), id: \.self) { i in
                HStack(alignment: .top, spacing: 12) {
                    cards[i].view
                    if i + 1 < cards.count { cards[i + 1].view }
                }
            }
        }
    }

    private struct OptionalCard { let view: AnyView }

    private func optionalCardList(_ s: Snapshot, _ h: History) -> [OptionalCard] {
        var out: [OptionalCard] = []
        if settings.windowShows(.thermals), let t = s.thermals {
            out.append(OptionalCard(view: AnyView(
                Card(title: tr("温度与风扇", "Temperature and fans"),
                     trailing: t.cpuMax.map { tr("最高 ", "Peak ") + settings.temperature($0) }) {
                    ThermalsView(t: t, history: h.cpuTemp, settings: settings)
                })))
        }
        if settings.windowShows(.diskIO) {
            out.append(OptionalCard(view: AnyView(
                Card(title: tr("磁盘读写", "Disk activity"),
                     trailing: tr("读 ", "R ") + Fmt.rate(s.diskRead) + "  " + tr("写 ", "W ") + Fmt.rate(s.diskWrite)) {
                    DiskIOView(read: h.diskRead, write: h.diskWrite, volumes: s.volumes, lang: settings.language)
                })))
        }
        if settings.windowShows(.wifi), let w = s.wifi {
            out.append(OptionalCard(view: AnyView(
                Card(title: "Wi‑Fi", trailing: "\(w.rssi) dBm · " + signalText(w.rssi)) {
                    WiFiView(w: w, lang: settings.language).equatable()
                })))
        }
        let showPeriph = settings.windowShows(.peripherals)
        let showDisplays = settings.windowShows(.displays) && !s.displays.isEmpty
        if showPeriph || showDisplays {
            let title = showPeriph && showDisplays ? tr("外设与显示器", "Peripherals and displays")
                : showPeriph ? tr("外设电量", "Peripheral batteries") : tr("显示器", "Displays")
            out.append(OptionalCard(view: AnyView(
                Card(title: title, trailing: nil) {
                    DevicesView(peripherals: showPeriph ? s.peripherals : nil,
                                displays: showDisplays ? s.displays : [], lang: settings.language)
                        .equatable()
                })))
        }
        return out
    }

    @ViewBuilder private func diskBattery(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let used = s.diskTotal > 0 ? Double(s.diskTotal - s.diskFree) / Double(s.diskTotal) : 0
            Bar(fraction: used, color: used < 0.85 ? .blue : .red)
            Text("\(s.volumeName) · " + tr("可用 ", "Free ") + Fmt.disk(s.diskFree))
                .font(.caption).foregroundStyle(.secondary)
            if let b = s.battery {
                Divider().padding(.vertical, 2)
                HStack(spacing: 6) {
                    Image(systemName: b.pluggedIn ? "battery.100percent.bolt" : "battery.75percent")
                        .foregroundStyle(b.percent <= 20 && !b.pluggedIn ? .red : .green)
                    Text("\(b.percent)%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text(b.charging ? tr("充电中", "Charging") : b.pluggedIn ? tr("已接电源", "Plugged in") : tr("使用电池", "On battery"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(batteryDetails(b)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func batteryDetails(_ b: Snapshot.Battery) -> String {
        var parts: [String] = []
        if let a = b.adapterWatts { parts.append(tr("充电器 \(a) W", "\(a) W charger")) }
        if let h = b.health { parts.append(tr("健康 \(h)%", "Health \(h)%")) }
        if let c = b.cycles { parts.append(tr("循环 \(c)", "\(c) cycles")) }
        if let t = b.temperature { parts.append(settings.temperature(t)) }
        return parts.joined(separator: " · ")
    }
}

func thermalText(_ t: ProcessInfo.ThermalState) -> String {
    switch t {
    case .nominal: return tr("正常", "Normal")
    case .fair: return tr("偏热", "Warm")
    case .serious: return tr("很热", "Hot")
    case .critical: return tr("严重", "Critical")
    @unknown default: return "—"
    }
}

func pressureText(_ p: Int) -> String {
    switch p {
    case 4: return tr("严重", "Critical")
    case 2: return tr("紧张", "Warning")
    default: return tr("正常", "Normal")
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
    }
}

struct Tile: View {
    let title: String
    let value: String
    let unit: String?
    let series: Series
    let maxValue: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).lineLimit(1)
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .minimumScaleFactor(0.7)
            Sparkline(series: series, maxValue: maxValue, color: color).frame(height: 34)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
    }
}

/// Line + soft area for one series over the last `Series.span` seconds, right-aligned to the newest point.
struct Sparkline: View {
    let series: Series
    let maxValue: Double
    let color: Color
    var fill = true

    var body: some View {
        GeometryReader { g in
            let pts = points(in: g.size)
            ZStack {
                if fill, pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.14))
                }
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard let first = series.points.first?.t, let last = series.points.last?.t, maxValue > 0 else { return [] }
        // Fill the width from 30 s of data on, then scroll within the 5-minute window.
        let span = min(max(last - first, 30), Series.span)
        // At most ~120 points per line: enough detail for a small chart, bounded drawing cost.
        let step = max(1, series.points.count / 120)
        let pts = step == 1 ? series.points : stride(from: 0, to: series.points.count, by: step).map { series.points[$0] }
        return pts.map { pt in
            let x = size.width * (1 - CGFloat((last - pt.t) / span))
            let y = size.height * (1 - CGFloat(min(pt.v / maxValue, 1)))
            return CGPoint(x: x, y: max(1, y))
        }
    }
}

struct CoreGroups: View {
    let values: [Double]
    let eCores: Int
    let lang: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    group(Array(values.prefix(eCores)), color: .teal)
                    Text(tr("能效核", "Efficiency")).fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    group(Array(values.dropFirst(eCores)), color: .blue)
                    Text(tr("性能核", "Performance")).fixedSize()
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func group(_ vals: [Double], color: Color) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(vals.enumerated()), id: \.offset) { _, v in
                GeometryReader { g in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 3).fill(color)
                            .frame(height: max(2, g.size.height * v))
                    }
                }
                .frame(width: 18, height: 64)
                .help("\(Int((v * 100).rounded()))%")
            }
        }
    }
}

struct MemoryBreakdown: View {
    let s: Snapshot
    let total: UInt64
    let lang: AppLanguage

    var body: some View {
        let parts: [(String, UInt64, Color)] = [
            (tr("App", "App"), s.memApp, .purple),
            (tr("联动", "Wired"), s.memWired, .orange),
            (tr("压缩", "Compressed"), s.memCompressed, .pink),
            (tr("缓存文件", "Cached files"), s.memCached, .gray),
        ]
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2)
                            .frame(width: g.size.width * CGFloat(Double(p.1) / Double(max(total, 1))))
                    }
                    Spacer(minLength: 0)
                }
                .background(.quaternary)
                .clipShape(Capsule())
            }
            .frame(height: 12)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 4) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 8, height: 8)
                        Text("\(p.0) \(Fmt.mem(p.1))").monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(tr("已使用 ", "Used ") + Fmt.mem(s.memUsed) + " / " + Fmt.mem(total))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NetworkChart: View {
    let down: Series
    let up: Series
    let lang: AppLanguage

    var body: some View {
        let top = max(down.maxValue, up.maxValue, 50_000) * 1.15
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Sparkline(series: down, maxValue: top, color: .blue)
                Sparkline(series: up, maxValue: top, color: .orange, fill: false)
            }
            .frame(height: 70)
            HStack(spacing: 12) {
                legend(.blue, tr("下载", "Download"))
                legend(.orange, tr("上传", "Upload"))
                Spacer()
                Text(tr("峰值 ", "Peak ") + Fmt.rate(max(down.maxValue, up.maxValue)))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(t) }
    }
}

enum ProcSort: Hashable { case cpu, mem, net }

struct ProcessList: View, Equatable {
    /// Skip re-rendering when the rows haven't changed (they refresh every 3 s, the window every 1–2 s).
    static func == (a: ProcessList, b: ProcessList) -> Bool {
        a.cpu == b.cpu && a.mem == b.mem && a.net == b.net && a.showNetwork == b.showNetwork
            && a.sort == b.sort && a.lang == b.lang
    }

    let cpu: [ProcStat]
    let mem: [ProcStat]
    let net: [NetProc]
    let showNetwork: Bool
    @Binding var sort: ProcSort
    let lang: AppLanguage

    var body: some View {
        let mode: ProcSort = (sort == .net && !showNetwork) ? .cpu : sort
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(selection: $sort) {
                    Text(tr("按 CPU", "By CPU")).tag(ProcSort.cpu)
                    Text(tr("按内存", "By memory")).tag(ProcSort.mem)
                    if showNetwork { Text(tr("按网络", "By network")).tag(ProcSort.net) }
                } label: { EmptyView() }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: {
                    Label(tr("活动监视器", "Activity Monitor"), systemImage: "arrow.up.forward.app")
                }
            }
            if mode == .net { netTable } else { usageTable(mode == .mem ? mem : cpu) }
            Text(mode == .net
                 ? tr("包含系统进程；数据来自系统自带的 nettop，只在窗口打开时运行",
                      "Includes system processes; read with the built-in nettop tool, only while the window is open")
                 : tr("只统计当前用户的进程；系统进程需要管理员权限才能读取",
                      "Only your own processes are listed; system processes need admin rights to read"))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func nameCell(_ pid: pid_t, _ name: String) -> some View {
        HStack(spacing: 6) {
            if let icon = AppIcons.icon(for: pid) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "gearshape").frame(width: 16, height: 16).foregroundStyle(.tertiary)
            }
            Text(name).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageTable(_ rows: [ProcStat]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                Text(tr("名称", "Name"))
                Text("PID").gridColumnAlignment(.trailing)
                Text("CPU").gridColumnAlignment(.trailing)
                Text(tr("内存", "Memory")).gridColumnAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider().gridCellColumns(4)
            if rows.isEmpty { Text("…").foregroundStyle(.tertiary) }
            ForEach(rows) { p in
                GridRow {
                    nameCell(p.pid, p.name)
                    Text("\(p.pid)").foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", p.cpu * 100))
                    Text(Fmt.mem(p.mem))
                }
                .font(.system(size: 12).monospacedDigit())
            }
        }
    }

    private var netTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                Text(tr("名称", "Name"))
                Text("PID").gridColumnAlignment(.trailing)
                Text(tr("下载", "Down")).gridColumnAlignment(.trailing)
                Text(tr("上传", "Up")).gridColumnAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider().gridCellColumns(4)
            if net.isEmpty {
                Text(tr("正在收集数据…", "Collecting data…")).foregroundStyle(.tertiary).gridCellColumns(4)
            }
            ForEach(net) { p in
                GridRow {
                    nameCell(pid_t(p.pid), p.name)
                    Text("\(p.pid)").foregroundStyle(.secondary)
                    Text(Fmt.rate(p.down))
                    Text(Fmt.rate(p.up))
                }
                .font(.system(size: 12).monospacedDigit())
            }
        }
    }
}

// MARK: - Optional cards

struct ThermalsView: View {
    let t: Thermals
    let history: Series
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                reading("CPU", t.cpuAvg)
                reading("GPU", t.gpuAvg)
                Spacer()
            }
            Sparkline(series: history, maxValue: 100, color: tempColor(t.cpuMax ?? 0)).frame(height: 34)
            if t.fans.isEmpty {
                Text(tr("这台 Mac 没有风扇", "This Mac has no fans")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(t.fans.enumerated()), id: \.offset) { i, f in
                HStack(spacing: 8) {
                    Image(systemName: "fan").foregroundStyle(.secondary)
                    Text(tr("风扇 \(i + 1)", "Fan \(i + 1)")).font(.caption)
                    Bar(fraction: f.max > 0 ? f.rpm / f.max : 0, color: .teal)
                    Text(f.rpm < 1 ? tr("停转", "Off") : "\(Int(f.rpm)) RPM")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
    }

    private func reading(_ label: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(v.map(settings.temperature) ?? "—")
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(v.map(tempColor) ?? .secondary)
        }
    }
}

struct DiskIOView: View {
    let read: Series
    let write: Series
    let volumes: [VolumeInfo]
    let lang: AppLanguage
    @State private var ejectError: String?

    var body: some View {
        let top = max(read.maxValue, write.maxValue, 1_000_000) * 1.15
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Sparkline(series: read, maxValue: top, color: .mint)
                Sparkline(series: write, maxValue: top, color: .pink, fill: false)
            }
            .frame(height: 50)
            HStack(spacing: 12) {
                legend(.mint, tr("读取", "Read"))
                legend(.pink, tr("写入", "Write"))
                Spacer()
                Text(tr("峰值 ", "Peak ") + Fmt.rate(max(read.maxValue, write.maxValue)))
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            if volumes.isEmpty {
                Text(tr("没有外接磁盘", "No external drives")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(volumes) { v in
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text(v.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(tr("可用 ", "Free ") + Fmt.disk(v.free) + " / " + Fmt.disk(v.total))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if v.ejectable {
                        Button {
                            do { try NSWorkspace.shared.unmountAndEjectDevice(at: v.url); ejectError = nil }
                            catch { ejectError = tr("无法推出「\(v.name)」，可能正在使用", "Couldn't eject \(v.name). It may be in use.") }
                        } label: { Image(systemName: "eject") }
                        .buttonStyle(.borderless)
                        .help(tr("推出", "Eject"))
                    }
                }
            }
            if let ejectError { Text(ejectError).font(.caption).foregroundStyle(.red) }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(t) }
    }
}

struct WiFiView: View, Equatable {
    let w: WiFiInfo
    let lang: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Bar(fraction: signalFraction(w.rssi), color: signalColor(w.rssi))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row(tr("信号", "Signal"), "\(w.rssi) dBm")
                row(tr("噪声", "Noise"), "\(w.noise) dBm")
                row(tr("信噪比", "SNR"), "\(w.rssi - w.noise) dB")
                row(tr("连接速率", "Link rate"), "\(Int(w.txRate)) Mbps")
                row(tr("频段 / 信道", "Band / channel"),
                    [w.bandGHz.map { "\($0) GHz" }, w.channel.map { "\($0)" }].compactMap { $0 }.joined(separator: " / "))
                if let std = w.standard { row(tr("标准", "Standard"), std) }
                row(tr("网卡", "Interface"), w.iface)
            }
            .font(.caption)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit()
        }
    }
}

struct DevicesView: View, Equatable {
    let peripherals: [Peripheral]?
    let displays: [DisplayInfo]
    let lang: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let peripherals {
                if peripherals.isEmpty {
                    Text(tr("没有连接带电池的蓝牙外设", "No Bluetooth peripherals with a battery"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(peripherals) { p in
                    HStack(spacing: 6) {
                        Image(systemName: icon(p.name)).foregroundStyle(.secondary).frame(width: 18)
                        Text(p.name).font(.caption).lineLimit(1)
                        Spacer()
                        Bar(fraction: Double(p.percent) / 100, color: p.percent <= 20 ? .red : .green).frame(width: 60)
                        Text("\(p.percent)%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                    }
                }
                if !displays.isEmpty { Divider() }
            }
            ForEach(displays) { d in
                HStack(spacing: 6) {
                    Image(systemName: d.builtIn ? "laptopcomputer" : "display").foregroundStyle(.secondary).frame(width: 18)
                    Text(d.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text("\(d.pixelWidth)×\(d.pixelHeight) · \(d.refresh) Hz")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func icon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("mouse") { return "computermouse" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return "dot.radiowaves.left.and.right"
    }
}

/// App icons by pid, looked up once per process (the process list redraws every refresh).
@MainActor
enum AppIcons {
    private static var cache: [pid_t: NSImage?] = [:]
    static func icon(for pid: pid_t) -> NSImage? {
        if let hit = cache[pid] { return hit }
        if cache.count > 200 { cache.removeAll() }
        let img = NSRunningApplication(processIdentifier: pid)?.icon
        cache[pid] = img
        return img
    }
}
