// ContentView — 两步式向导 UI（对齐微信输入法安装体验 + 四合一「安装 / 修复安装 / 清空修复 / 彻底卸载」）。
// 所有系统副作用集中在 Installer.swift 与 OwlInstallSession.swift；本文件负责预检展示、
// 四合一动作派发与第二步完成向导。

import SwiftUI
import AppKit

final class InstallerViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        case completed(InstallerActivationPolicy.CompletionSummary)
        case failure
    }

    @Published var preflight: InstallerActivationPolicy.PreflightReport = Installer.inspectPreflight()
    @Published var phase: Phase = .idle
    @Published var statusText: String = "支持一键安装、覆盖更新、修复安装、清空修复与彻底卸载。"
    @Published var isBusy: Bool = false
    @Published var showUninstallConfirmation: Bool = false

    func refreshPreflight() {
        let report = Installer.inspectPreflight()
        DispatchQueue.main.async {
            self.preflight = report
        }
    }

    func install() {
        runAction(progressText: "正在安装并配置法墨输入法…") {
            let result = try Installer.install()
            return InstallerActivationPolicy.completionSummary(
                for: .install(plan: result.plan, status: result.status))
        }
    }

    func repairInstall() {
        runAction(progressText: "正在清理残留、重置缓存并执行修复安装…") {
            let status = try Installer.repairInstall()
            return InstallerActivationPolicy.completionSummary(
                for: .repairInstall(status: status))
        }
    }

    func clearAndRepair() {
        runAction(progressText: "正在清理非标准副本、幽灵注册与系统输入法列表缓存…") {
            try Installer.clearAndRepair()
            return InstallerActivationPolicy.completionSummary(for: .clearAndRepair)
        }
    }

    func uninstall(keepUserData: Bool) {
        let progress = keepUserData
            ? "正在卸载法墨输入法（保留个人词库与设置）…"
            : "正在彻底卸载法墨输入法并清空用户数据…"
        runAction(progressText: progress) {
            try Installer.uninstall(keepUserData: keepUserData)
            return InstallerActivationPolicy.completionSummary(
                for: .uninstall(keepUserData: keepUserData))
        }
    }

    func activateAndOpenSettings() {
        DispatchQueue.global(qos: .userInitiated).async {
            Installer.activateAndOpenSettings()
            DispatchQueue.main.async {
                self.statusText = "✅ 已请求切换到法墨输入法并打开设置窗口。"
            }
        }
    }

    func openSystemKeyboardSettings() {
        Installer.openSystemKeyboardSettings()
    }

    func returnToMain() {
        refreshPreflight()
        phase = .idle
        statusText = "支持一键安装、覆盖更新、修复安装、清空修复与彻底卸载。"
    }

    static func failureText(for error: Error) -> String {
        if case InstallerError.userCancelled = error {
            return "已取消授权，未对系统做任何更改。"
        }
        if case InstallerError.activationFailed(let message) = error, message.contains("inputSourceNotEnabled") {
            return "❌ 系统尚未允许启用法墨输入法。\n"
                + "请点击「清空修复」或在「系统设置 → 键盘 → 输入法」中添加「法墨」。"
        }
        return "❌ " + error.localizedDescription
    }

    private func runAction(
        progressText: String,
        work: @escaping () throws -> InstallerActivationPolicy.CompletionSummary
    ) {
        isBusy = true
        phase = .working
        statusText = progressText
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let summary = try work()
                let updatedPreflight = Installer.inspectPreflight()
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.preflight = updatedPreflight
                    self?.phase = .completed(summary)
                    self?.statusText = summary.detail
                }
            } catch {
                let updatedPreflight = Installer.inspectPreflight()
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.preflight = updatedPreflight
                    if case InstallerError.userCancelled = error {
                        self?.phase = .idle
                        self?.statusText = Self.failureText(for: error)
                    } else {
                        self?.phase = .failure
                        self?.statusText = Self.failureText(for: error)
                    }
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = InstallerViewModel()

    var body: some View {
        Group {
            if case .completed(let summary) = model.phase {
                completionStepView(summary)
            } else {
                mainStepView
            }
        }
        .padding(32)
        .frame(width: 520, height: 470)
        .onAppear {
            model.refreshPreflight()
        }
        .confirmationDialog(
            "选择卸载方式",
            isPresented: $model.showUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("卸载但保留个人词库与设置") {
                model.uninstall(keepUserData: true)
            }
            Button("彻底卸载并清空全部词库与配置", role: .destructive) {
                model.uninstall(keepUserData: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("卸载只会清理法墨自有文件与系统注册记录，绝不触碰 Squirrel、~/Library/Rime 或其他输入法。")
        }
    }

    private var mainStepView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 56, height: 56)

                Text("法墨输入法")
                    .font(.system(size: 24, weight: .bold))

                Text(model.preflight.statusHeadline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let warning = model.preflight.anomalyWarning {
                Text("⚠️ " + warning)
                    .font(.system(size: 11.5))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.leading)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10))
                    .cornerRadius(8)
            }

            Text("基础输入在本机完成、不联网。AI 为默认关闭的可选功能，需自行填入大模型 API Key；启用后相关文本直接发往所选服务商，法墨无自建服务器、不中转也不留存数据。")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.install()
            } label: {
                HStack(spacing: 8) {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.preflight.primaryButtonTitle)
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(minWidth: 200, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(model.isBusy)

            Text(model.statusText)
                .font(.system(size: 12))
                .foregroundColor(statusColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(spacing: 8) {
                Text("维护与修复工具")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button {
                        model.repairInstall()
                    } label: {
                        Text("修复安装").frame(minWidth: 96)
                    }
                    .help("清理残留进程、杂散副本与输入法缓存后，强制重装当前安装包并重新启用（保留个人词库）")
                    .disabled(model.isBusy)

                    Button {
                        model.clearAndRepair()
                    } label: {
                        Text("清空修复").frame(minWidth: 96)
                    }
                    .help("不删除个人词库，清理多余副本、LaunchServices 幽灵注册与系统输入法列表缓存并刷新菜单")
                    .disabled(model.isBusy)

                    Button {
                        model.showUninstallConfirmation = true
                    } label: {
                        Text("彻底卸载").frame(minWidth: 96)
                    }
                    .help("停用输入源、结束进程并移除法墨输入法，可选保留或清空个人词库")
                    .disabled(model.isBusy)
                }
                .controlSize(.regular)
            }
        }
    }

    private func completionStepView(_ summary: InstallerActivationPolicy.CompletionSummary) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)

            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .frame(width: 52, height: 52)
                .foregroundColor(.green)

            Text(summary.title)
                .font(.system(size: 24, weight: .bold))

            Text(summary.detail)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            if summary.showsActivateButton {
                Button {
                    model.activateAndOpenSettings()
                } label: {
                    Text("切换到法墨并打开设置")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 220, minHeight: 26)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }

            if summary.showsSystemSettingsButton {
                Button {
                    model.openSystemKeyboardSettings()
                } label: {
                    Text("打开「系统设置 → 键盘 → 输入法」")
                        .frame(minWidth: 220)
                }
                .controlSize(.regular)
            }

            Spacer(minLength: 8)

            Divider()

            HStack(spacing: 16) {
                Button("返回维护面板") {
                    model.returnToMain()
                }
                .controlSize(.regular)

                Button("完成退出") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.regular)
            }
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .failure:
            return .red
        case .completed:
            return .green
        default:
            return .secondary
        }
    }
}
