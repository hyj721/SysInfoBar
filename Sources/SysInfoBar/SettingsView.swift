import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
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
                ForEach(PanelSection.allCases) { s in
                    Toggle(s.title, isOn: Binding(get: { settings.shows(s) },
                                                  set: { settings.setSection(s, visible: $0) }))
                }
            } header: {
                Text(tr("菜单栏面板显示", "Show in menu bar panel"))
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
