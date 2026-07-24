// ContentView — 极简单窗 UI：标题 + 说明 + 「安装」/「卸载」 + 一行进度/结果。
// 所有副作用都在 Installer.swift / InstallerActivationVerifier.swift；本文件只管展示与派活：
// 安装 = 后台队列跑 Installer.install() → 主 runloop 跑 verifier（consent 等待 + 读回验证）。
// 文案双态（PRD R1）：成功 = 新开应用立即可用（QA 三轮拍板：不领「无需注销」绝对承诺）；
// 验证超时 = 注销重登引导，绝不伪装成功。

import SwiftUI

/// 安装/卸载的状态机。副作用在后台队列跑，结果回主线程更新 @Published。
/// 不用 @MainActor：背景任务经 DispatchQueue.main.async 回主线程，避免并发隔离噪声。
final class InstallerViewModel: ObservableObject {
    enum Phase {
        case idle
        case working
        /// 文件已就位，正在等 macOS consent + fresh 进程探针读回验证（软超时 ~30s）。
        case verifying
        case success
        /// 软超时未确认 → 注销重登引导（不算 success 也不算 failure）。**非终态**（fix2）：
        /// verifier 后台继续观察到扩展截止，迟到 consent 会自动翻成 success。
        case needsLogout
        case failure
    }

    @Published var phase: Phase = .idle
    @Published var statusText: String = "点击「安装」把法墨输入法安装到本机。"
    @Published var isBusy: Bool = false

    func install() {
        // 同 uninstall()：橙窗期间重装，先终止旧 verifier（不能只靠 start() 内置的 cancel——
        // Installer.install() 在后台要跑数秒，期间旧会话的迟到回调会覆盖「正在安装」状态）。
        InstallerActivationVerifier.cancel()
        isBusy = true
        phase = .working
        statusText = "正在安装法墨…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let plan = try Installer.install()
                DispatchQueue.main.async {
                    self?.phase = .verifying
                    self?.statusText = InstallerActivationPolicy.verifyingText
                    // verifier 必须在正常主 runloop 上跑；isBusy 在软超时前保持 true（按钮禁用）。
                    // onState 可能回调多次（fix2 迟到自愈）：软超时先落 needsLogout 橙窗（非终态，
                    // verifier 后台继续 tick），迟到 consent 一到再翻 success 绿窗。
                    InstallerActivationVerifier.start(selectFamo: plan.selectFamoAfterInstall) { state in
                        self?.isBusy = false
                        switch state {
                        case .verified:
                            self?.phase = .success
                            self?.statusText = InstallerActivationPolicy.successText(plan: plan)
                        case .needsLogout(let stillTrying):
                            self?.phase = .needsLogout
                            self?.statusText =
                                InstallerActivationPolicy.needsLogoutText(stillTrying: stillTrying)
                        case .waiting:
                            break // verifier 不回调 waiting
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.phase = .failure
                    self?.statusText = Self.failureText(for: error)
                }
            }
        }
    }

    /// 失败文案分层：激活阶段失败时文件其实已拷好 → 补注销引导；拷贝/校验/取消则报错本身。
    static func failureText(for error: Error) -> String {
        if case InstallerError.activationFailed = error {
            return "❌ " + error.localizedDescription
                + "\n文件已安装：注销并重新登录后即可在输入法菜单使用法墨。"
        }
        return "❌ " + error.localizedDescription
    }

    func uninstall() {
        // 橙窗（needsLogout(stillTrying: true)）期间按钮已恢复可点：先静默终止仍在后台 tick 的
        // verifier，否则它的迟到回调会把「已卸载」文案覆盖回注销引导。install 路径由
        // InstallerActivationVerifier.start() 内置的 cancel() 顶替。
        InstallerActivationVerifier.cancel()
        run(progressText: "正在卸载法墨…") {
            try Installer.uninstall()
        } onSuccess: { [weak self] in
            self?.phase = .success
            self?.statusText = "✅ 法墨已卸载。Squirrel、~/Library/Rime 及你的其他输入法未被触碰。"
                + "登出再登录可彻底刷新输入菜单。钥匙串里的 DeepSeek key 如需删除请手动移除。"
        }
    }

    private func run(progressText: String,
                     _ work: @escaping () throws -> Void,
                     onSuccess: @escaping () -> Void) {
        isBusy = true
        phase = .working
        statusText = progressText
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try work()
                DispatchQueue.main.async {
                    self?.isBusy = false
                    onSuccess()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.phase = .failure
                    self?.statusText = "❌ " + error.localizedDescription
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = InstallerViewModel()

    var body: some View {
        VStack(spacing: 18) {
            Text("法墨输入法")
                .font(.system(size: 28, weight: .bold))

            Text("安装或更新法墨输入法：输入管理员密码 → 弹出「允许启用输入法」对话框时点「允许」→ 在右上角输入法菜单选择「法墨」。新打开的应用立即可用；已打开的应用请重新打开。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // 隐私说明：接住 macOS「可访问你键入的任何内容」这一系统安全框——那段文案 Apple 写死、
            // 对所有第三方输入法统一显示，App 无法改写或免除。此处如实说明法墨如何处理数据，措辞须与代码
            // 一致（开源可审计，见 sources/Lane/*、Famo.entitlements）：基础输入本地；AI 为 default-off
            // 的可选功能（FamoAIPage「default-off Smart/Cloud lanes」），用用户自备 Key 直连服务商，
            // 法墨自身无中转服务器。切勿写成「不访问任何数据」——启用 AI 后确有文本发往所选服务商。
            Text("基础输入在本机完成、不联网。AI 为可选功能，需你自行填入大模型 API Key；启用后，相关文本会直接从本机发送给你选择的服务商（如 DeepSeek），法墨没有自己的服务器、不中转、也不留存你的数据。代码完全开源，可自行审计。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Text(model.statusText)
                .font(.system(size: 12))
                .foregroundColor(statusColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Button {
                    model.install()
                } label: {
                    Text("安装").frame(minWidth: 100)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.isBusy)

                Button {
                    model.uninstall()
                } label: {
                    Text("卸载").frame(minWidth: 100)
                }
                .controlSize(.large)
                .disabled(model.isBusy)
            }
        }
        .padding(36)
        .frame(width: 460, height: 410)
    }

    private var statusColor: Color {
        switch model.phase {
        case .failure: return .red
        case .needsLogout: return .orange
        case .success: return .green
        default: return .secondary
        }
    }
}
