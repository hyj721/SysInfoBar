import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    private func displayRow(_ title: String, panel: PanelSection?, window: WindowSection?) -> some View {
        HStack {
            Text(title)
            Spacer()
            check(panel.map { p in Binding(get: { settings.shows(p) }, set: { settings.setSection(p, visible: $0) }) })
            check(window.map { w in Binding(get: { settings.windowShows(w) }, set: { settings.setWindowSection(w, visible: $0) }) })
        }
    }

    @ViewBuilder private func check(_ b: Binding<Bool>?) -> some View {
        Group {
            if let b { Toggle("", isOn: b).toggleStyle(.checkbox).labelsHidden() }
            else { Text("—").foregroundStyle(.tertiary) }
        }
        .frame(width: 52)
    }

    var body: some View {
        Form {
            Section(tr("通用", "General")) {
                Picker(tr("语言", "Language"), selection: $settings.language) {
                    Text(tr("跟随系统", "System default")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.zh)
                    Text("English").tag(AppLanguage.en)
                }
                Toggle(tr("登录时启动", "Launch at login"),
                       isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                Toggle(tr("打开应用时显示窗口", "Show window when the app is opened"), isOn: $settings.openWindowOnLaunch)
                Picker(tr("温度单位", "Temperature unit"), selection: $settings.tempUnit) {
                    Text(tr("摄氏度 °C", "Celsius °C")).tag(TempUnit.celsius)
                    Text(tr("华氏度 °F", "Fahrenheit °F")).tag(TempUnit.fahrenheit)
                }
            }

            Section {
                Picker(tr("刷新间隔", "Refresh interval"), selection: $settings.refreshInterval) {
                    Text(tr("1 秒", "1 second")).tag(1.0)
                    Text(tr("2 秒", "2 seconds")).tag(2.0)
                    Text(tr("5 秒", "5 seconds")).tag(5.0)
                }
                Toggle(tr("后台记录历史", "Record history in background"), isOn: $settings.recordInBackground)
            } header: {
                Text(tr("刷新", "Refresh"))
            } footer: {
                Text(tr("默认只在面板或窗口打开时读取数据，关上后完全不占 CPU。打开「后台记录历史」后，关着时也会每 5 秒采样一次，窗口一打开就能看到最近 5 分钟的曲线。",
                        "By default, data is read only while the panel or window is open, so nothing runs when they're closed. With background recording on, it also samples every 5 seconds while closed, so the window shows the last 5 minutes as soon as it opens."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(tr("项目", "Item")).foregroundStyle(.secondary)
                    Spacer()
                    Text(tr("面板", "Panel")).foregroundStyle(.secondary).frame(width: 52)
                    Text(tr("窗口", "Window")).foregroundStyle(.secondary).frame(width: 52)
                }
                .font(.caption)
                ForEach(PanelSection.allCases) { p in
                    displayRow(p.title, panel: p, window: WindowSection.allCases.first { $0.panelCounterpart == p })
                }
                displayRow(WindowSection.processNetwork.title, panel: nil, window: .processNetwork)
            } header: {
                Text(tr("显示内容", "What to show"))
            } footer: {
                Text(tr("只有打开的面板或窗口里勾选的项才会读取，没勾选的不占资源。窗口里 CPU、内存、网络等核心卡片始终显示。",
                        "Only items checked for an open panel or window are read; unchecked ones cost nothing. The window always shows the core cards such as CPU, memory and network."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(tr("窗口", "Window")) {
                Toggle(tr("窗口置顶", "Keep window on top"), isOn: $settings.windowOnTop)
                Button(tr("打开仪表盘窗口", "Open dashboard window")) { WindowManager.shared.showDashboard() }
            }

            Section(tr("关于", "About")) {
                LabeledContent(tr("版本", "Version"), value: version)
                LabeledContent(tr("数据来源", "Data source")) {
                    Text(tr("全部本地读取，不联网", "Read locally, never goes online")).foregroundStyle(.secondary)
                }
                Link(destination: URL(string: "https://github.com/hyj721/SysInfoBar")!) {
                    Label("GitHub", systemImage: "arrow.up.forward.square")
                }
                Button(tr("退出 SysInfoBar", "Quit SysInfoBar"), role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
        // The language picker changes every string; re-render the whole form.
        .id(settings.language)
    }
}
