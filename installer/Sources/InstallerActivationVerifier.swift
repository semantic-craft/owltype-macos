// InstallerActivationVerifier — consent 异步等待 + fresh 进程自探针读回 + 迟到自愈（1.3.32-fix2）。
//
// 全部跑在「正常主 runloop」上（DispatchQueue.main.asyncAfter tick）：
//   - 定律 1：TISEnableInputSource 立即返回 0，真生效要等用户点 macOS 的「允许」同意框（异步）。
//   - 读回**不再用本进程 TIS**（fix2 核心改动）：安装器老进程的 TIS 快照陈旧，读不到 consent
//     之后的变更（QA 真机：装前已开的 App 打不出、新开 App 能打——同机理）→ 旧 verifier 假阴性，
//     Hans 明明已 enabled 仍误弹注销引导。改为每 tick spawn 自身可执行文件 `--tis-probe`
//     （fresh 进程直查 TIS，QA 探针实证 fresh 进程读值为真），解析单行输出拿 parent/Hans 信号。
//   - needsLogout 非吸收态（fix2）：软超时（30s）到点照样显示注销引导橙窗，但后台继续 tick 到
//     扩展截止（300s / 窗口关闭）；迟到 consent 信号一到 → 翻 verified 绿窗（人点「允许」可以
//     晚于 30s——fix1 QA 假阴性的时序一半）。
//   - verified 时刻的刷新组合拳（fix2）：kTISNotify 分布式广播 + refreshInputMenuAgents() +
//     （按 plan.selectOwltypeAfterInstall）用已装 Owltype CLI fresh 进程 select Hans（QA 探针实证
//     fresh 进程 TISSelectInputSource(Hans)→0；本进程 select 因快照陈旧不可靠，已退役——
//     定律 2 的嵌套 runloop -50 问题也一并绕开）。install() 里 enable 后那次广播打在 consent
//     之前、对 consent 后的世界无效，真正让菜单代理 + 已运行 App 认到猫头鹰的是这一次。
//   - 这些都只是过程信号：最终验收 = 干净机真人看菜单 + 宿主 handle() 收键（定律 3/10）。
//
// 同时注册 kTISNotifyEnabledKeyboardInputSourcesChanged 分布式通知 observer：用户点「允许」的瞬间
// 触发一次立即检查，不必等下一个轮询 tick。

import Foundation
import Carbon

final class InstallerActivationVerifier {
    /// 保活当前验证会话（终态后释放）。单窗单任务 UI，同一时刻至多一个。
    /// fix2 后 needsLogout(stillTrying: true) 橙窗期间按钮已恢复可点：用户重新点「安装」/「卸载」
    /// 必须先 cancel() 旧会话（start() 内置；uninstall 由 ViewModel 调）——否则旧会话的 observer
    /// 泄漏在 DNC 里，且其迟到回调会覆盖新动作的 UI 文案（如把「已卸载」翻回注销引导）。
    private static var current: InstallerActivationVerifier?

    private let softDeadline: Date
    private let extendedDeadline: Date
    private let selectOwltype: Bool
    private let onState: (InstallerActivationPolicy.VerificationState) -> Void
    private var finished = false
    private var reportedInterimNeedsLogout = false
    private var probeInFlight = false
    private var observer: NSObjectProtocol?

    /// 必须在主线程调用（ViewModel 从 main queue 发起）。`onState` 可能回调多次：
    /// 软超时先落 needsLogout(stillTrying: true)（非终态，窗口继续自动更新），
    /// 之后要么迟到信号翻 verified，要么扩展截止落 needsLogout(stillTrying: false)。
    static func start(
        selectOwltype: Bool,
        softTimeout: TimeInterval = 30,
        extendedTimeout: TimeInterval = 300,
        onState: @escaping (InstallerActivationPolicy.VerificationState) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        let verifier = InstallerActivationVerifier(
            selectOwltype: selectOwltype,
            softTimeout: softTimeout,
            extendedTimeout: extendedTimeout,
            onState: onState)
        current = verifier
        verifier.begin()
    }

    /// 静默终止当前验证会话（不回调 onState）：注销 observer、断 tick 链、释放保活引用。
    /// 供「橙窗期间用户发起新动作」调用——旧会话若不终止，其迟到回调会覆盖新动作的 UI。
    static func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        current?.stopSilently()
        current = nil
    }

    private func stopSilently() {
        finished = true
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
    }

    private init(
        selectOwltype: Bool,
        softTimeout: TimeInterval,
        extendedTimeout: TimeInterval,
        onState: @escaping (InstallerActivationPolicy.VerificationState) -> Void
    ) {
        self.selectOwltype = selectOwltype
        self.softDeadline = Date(timeIntervalSinceNow: softTimeout)
        self.extendedDeadline = Date(timeIntervalSinceNow: extendedTimeout)
        self.onState = onState
    }

    private func begin() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    /// 探针在后台队列跑（spawn + 排空 + 等退出会阻塞数百毫秒，不占主线程），结果回主线程评估。
    /// probeInFlight 防重入：通知触发的 tick 撞上在途探针时直接跳过，评估后总会再排下一轮。
    private func tick() {
        guard !finished, !probeInFlight else { return }
        probeInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let signals = Self.runSelfProbe()
            DispatchQueue.main.async {
                guard let self else { return }
                self.probeInFlight = false
                self.evaluate(signals)
            }
        }
    }

    private func evaluate(_ signals: InstallerActivationPolicy.ProbeSignals?) {
        guard !finished else { return }
        let state = InstallerActivationPolicy.verificationState(
            parentEnabledObserved: signals?.parentEnabled ?? false,
            primaryModeEnabledObserved: signals?.primaryModeEnabled ?? false,
            deadlineReached: Date() >= softDeadline,
            extendedDeadlineReached: Date() >= extendedDeadline)
        switch state {
        case .waiting:
            scheduleNextTick()
        case .needsLogout(stillTrying: true):
            // 软超时：橙窗只报一次（重复回调无意义），后台继续 tick 等迟到 consent。
            if !reportedInterimNeedsLogout {
                reportedInterimNeedsLogout = true
                onState(state)
            }
            scheduleNextTick()
        case .verified, .needsLogout(stillTrying: false):
            finish(with: state)
        }
    }

    private func scheduleNextTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.tick()
        }
    }

    private func finish(with state: InstallerActivationPolicy.VerificationState) {
        guard !finished else { return }
        stopSilently()
        if state == .verified {
            let selectOwltype = self.selectOwltype
            DispatchQueue.global(qos: .userInitiated).async {
                Self.performVerifiedRefresh(selectOwltype: selectOwltype)
            }
        }
        onState(state)
        Self.current = nil
    }

    // MARK: - fresh 进程自探针

    /// spawn 自身可执行文件带 `--tis-probe`（main.swift 在 SwiftUI 前拦截，直查 TIS 后 exit(0)）。
    /// runProcess 内部先排空管道再等退出（1.3.32 Bug A 同病同修）；输出坏/进程失败 → nil = 本 tick
    /// 无信号，绝不误判成功。
    private static func runSelfProbe() -> InstallerActivationPolicy.ProbeSignals? {
        guard let executable = Bundle.main.executablePath else { return nil }
        guard let output = try? Installer.runProcess(executable, ["--tis-probe"]) else { return nil }
        return InstallerActivationPolicy.parseProbeOutput(output)
    }

    // MARK: - verified 时刻的刷新组合拳（consent 真生效后才对世界有意义）

    private static func performVerifiedRefresh(selectOwltype: Bool) {
        // 补发分布式广播 + 刷菜单代理：enable 后那次打在 consent 之前无人受益；这一次
        // TextInputMenuAgent 与已运行 App 才能重新 query 到已启用的猫头鹰（QA：菜单点不中、
        // 装前已开 App 打不出的刷新缺口正是缺这一步）。
        let center = CFNotificationCenterGetDistributedCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(kTISNotifyEnabledKeyboardInputSourcesChanged),
            nil, nil, true)
        Installer.refreshInputMenuAgents()
        if selectOwltype {
            // fresh 进程 select（1.3.32 CLI 起认任意源 id；QA 探针实证 fresh 进程 select→0）。
            // best-effort：失败不改判——verified 已由探针读回定谳，select 只是把当前源切过去。
            _ = try? Installer.runProcess(
                Installer.installedAppPath + "/Contents/MacOS/Owltype",
                ["--select-input-source", Installer.primaryModeID])
        }
    }
}
