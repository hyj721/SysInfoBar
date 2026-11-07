# SysInfoBar

极简 macOS 原生菜单栏系统信息工具（Swift + SwiftUI `MenuBarExtra`）。点击菜单栏的仪表盘图标，弹出面板显示：

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
- 运行时间、开机启动开关、退出按钮

数据全部在本地读取（`sysctl`、`host_processor_info`、`host_statistics64`、`getifaddrs`、`proc_pid_rusage`、IOKit、`URLResourceValues`），不联网。
只在面板打开时每 1.5 秒刷新，关闭后停止轮询。不在 Dock 显示（`LSUIElement`），跟随系统浅色/深色模式。

## 构建

只需要 Xcode Command Line Tools（不需要完整 Xcode），要求 macOS 14+、Apple Silicon。

```bash
./build.sh            # 生成 build/SysInfoBar.app
./build.sh install    # 生成后复制到 /Applications 并启动
```

## 运行

```bash
open build/SysInfoBar.app
```

命令行查看一次数据（不启动界面，用于自检）：

```bash
build/SysInfoBar.app/Contents/MacOS/SysInfoBar --dump
```

调试轮询：`SYSINFOBAR_DEBUG=1 build/SysInfoBar.app/Contents/MacOS/SysInfoBar` 会在 stderr 打印 `polling start / tick / polling stop`。

## 开机自启

先 `./build.sh install` 把应用放进 /Applications，然后任选一种：

1. 打开面板，勾选右下角的「开机启动」（使用 `SMAppService`）。首次勾选后系统可能会在
   「系统设置 → 通用 → 登录项与扩展」里要求你允许一下。
2. 或者手动：「系统设置 → 通用 → 登录项与扩展 → 登录时打开」点 `+`，选 /Applications/SysInfoBar.app。

## 退出 / 卸载

面板右下角电源按钮退出。卸载：取消勾选开机启动后删除 /Applications/SysInfoBar.app。

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
