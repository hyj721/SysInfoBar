# SysInfoBar

极简 macOS 原生系统信息工具（Swift + SwiftUI），中英文界面。有三个入口：

- **菜单栏面板**：点菜单栏的仪表盘图标，快速瞄一眼
- **仪表盘窗口**：在启动台 / 访达 / Spotlight 里打开应用，或点面板底部的窗口按钮。比面板多出最近 5 分钟的历史曲线、CPU 核心分组、内存构成、网络曲线和前 10 个进程（可按 CPU / 内存排序），支持置顶
- **设置**：面板或窗口里的齿轮按钮，或 ⌘,

面板显示的内容（每一项都能在设置里隐藏）：

- 机型（如 MacBook Pro (16-inch, 2021)）、macOS 版本和 build 号
- CPU：型号、P/E 核数、总使用率，以及每个核心的小柱状图（青色为能效核）
- 内存：已用 / 总量（口径与「活动监视器」的“已使用内存”一致：App + 联动 + 压缩），以及 Swap
- GPU：型号、核心数、使用率
- 磁盘：启动卷已用 / 总量、可用空间
- 网络：en* 网卡（Wi‑Fi / 有线）实时下载 / 上传速度、局域网 IP
- 电池：电量、充电状态、健康度、循环次数（台式机自动隐藏）
- 功耗：整机实时功率、充电器瓦数、电池温度
- 状态：系统负载（1/5/15 分钟）、内存压力、温控状态（偏热以上会降频）
- 我的进程：CPU 和内存占用最高的前 3 个进程（只统计当前用户的进程，系统进程需要管理员权限才能读）
- 运行时间，以及打开窗口、设置、退出按钮

设置项：语言（跟随系统 / 简体中文 / English）、登录时启动、打开应用时是否显示窗口、温度单位、刷新间隔（1 / 2 / 5 秒）、后台记录历史、面板显示哪些项、窗口置顶。

数据全部在本地读取（`sysctl`、`host_processor_info`、`host_statistics64`、`getifaddrs`、`proc_pid_rusage`、IOKit、`URLResourceValues`），不联网。
只在面板或窗口打开时按设置的间隔刷新，都关上后停止轮询、不占 CPU（除非打开了「后台记录历史」，那样会每 5 秒采样一次）。
平时只在菜单栏，窗口打开时才在程序坞显示图标；跟随系统浅色/深色模式。

## 构建

只需要 Xcode Command Line Tools（不需要完整 Xcode），要求 macOS 14+、Apple Silicon。

```bash
./build.sh            # 生成 build/SysInfoBar.app
./build.sh install    # 生成后复制到 /Applications 并启动
```

应用图标在 `Resources/AppIcon.icns`，由 `swift scripts/make-icon.swift` 生成（改图标后重新运行它）；菜单栏图标在 `Sources/SysInfoBar/MenuBarIcon.swift` 里用代码绘制。

## 运行

```bash
open build/SysInfoBar.app
```

命令行查看一次数据（不启动界面，用于自检）：

```bash
build/SysInfoBar.app/Contents/MacOS/SysInfoBar --dump
```

调试工具：

- `SYSINFOBAR_DEBUG=1 build/SysInfoBar.app/Contents/MacOS/SysInfoBar`：在 stderr 打印 `polling start / tick / polling stop`
- 再加 `SYSINFOBAR_SELFTEST=1`：自动开关窗口并打印程序坞图标 / 轮询状态
- `build/SysInfoBar.app/Contents/MacOS/SysInfoBar --snapshot <目录>`：把面板、窗口、设置按中英文 × 浅色深色渲染成 PNG，不需要屏幕录制权限

## 开机自启

先 `./build.sh install` 把应用放进 /Applications，然后任选一种：

1. 打开设置，打开「登录时启动」（使用 `SMAppService`）。首次打开后系统可能会在
   「系统设置 → 通用 → 登录项与扩展」里要求你允许一下。
2. 或者手动：「系统设置 → 通用 → 登录项与扩展 → 登录时打开」点 `+`，选 /Applications/SysInfoBar.app。

## 退出 / 卸载

面板右下角电源按钮，或设置底部「退出 SysInfoBar」。卸载：先关掉「登录时启动」，再删除 /Applications/SysInfoBar.app。

## 发布（GitHub Actions）

推送 `v` 开头的 tag 就会自动构建并发布 Release，附带 `SysInfoBar-<版本>.zip`：

```bash
git tag v1.0.0
git push origin v1.0.0
```

也可以在 GitHub 仓库的 Actions 页面手动运行「Release」，填入版本号。
工作流在 `.github/workflows/release.yml`，跑在 GitHub 的 Apple Silicon macOS runner 上，用的是 `./build.sh zip`。
本地打包同样可以：`VERSION=1.0.0 ./build.sh zip`，生成 `build/SysInfoBar-1.0.0.zip`。

下载的应用没有经过 Apple 公证，首次打开前需执行一次：

```bash
xattr -dr com.apple.quarantine /Applications/SysInfoBar.app
```
