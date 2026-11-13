// OwltypeInstaller — 法墨输入法独立首装安装器（运行在用户 Aqua GUI 会话）。
//
// 设计要点（首装免注销专题 07-02，微信法首装免注销）：
//   - 普通带窗口 App（非 agent），单窗一键安装 + 一个卸载。
//   - 提权仅用于把内嵌的 Owltype.app 拷进 /Library/Input Methods/（NSAppleScript admin）。
//   - TIS register + enable「父条目」都在本进程内做（登录用户 Aqua 会话已签名 GUI 进程，满足
//     enable 的全部真必要条件）；是否 enable 由复合幂等判据决定（InstallerActivationPolicy）。
//   - 拷贝完成后跑 `Owltype --activate-once` + `open Owltype.app` 发布 IMK endpoint，再由
//     OwlInstallSession 在用户会话完成启用、选择读回、服务刷新和进程自检。
//   - 更新/修复也走同一安装器路径，不要求先卸载旧版本；更新整段跳过 enable（防幽灵态）。

import SwiftUI
import AppKit

// 入口在 main.swift（不用 @main）：`--tis-probe` 自探针要在 SwiftUI 生命周期启动前被拦截。
struct OwltypeInstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("法墨安装器") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

/// 让安装器成为前台可见 App，并在最后一个窗口关闭时退出。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
