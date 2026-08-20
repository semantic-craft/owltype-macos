// main.swift — OwltypeInstaller 显式入口（1.3.32-fix2）。
//
// 为什么不用 @main：`--tis-probe` 自探针必须在 SwiftUI App 生命周期启动之前拦截——
// fresh 进程直查 TIS、单行输出 `parent=… hans=… hansSelectCapable=…` 后 exit(0)，
// 不创建 NSApplication/窗口/Dock 图标。verifier 每 tick 以此读回 consent 后的 TIS 真值
// （安装器老进程 TIS 快照陈旧，进程内读回已退役，见 InstallerTISProbe.swift）。

import Foundation

if CommandLine.arguments.dropFirst().contains("--tis-probe") {
    print(InstallerTISProbe.output())
    exit(0)
}

OwltypeInstallerApp.main()
