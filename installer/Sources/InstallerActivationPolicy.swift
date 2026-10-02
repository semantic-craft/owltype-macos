// InstallerActivationPolicy — 安装激活的纯决策层（无 TIS / 无 IO / 无 AppKit）。
//
// 为什么是纯函数：TIS/IMK 无法 headless 单测，所以把「该不该 enable/select」
// 与「读回验证状态机」抽成纯函数，编进 OwltypeTests 覆盖真值表（tests/InstallerActivationPolicyTests.swift，
// 参照 ActivationPolicyTests 的 pure-dispatch 风格）；TIS 副作用薄层留在 Installer / Verifier。
//
// 当前策略、回归测试和历史观察边界见 `docs/operations/installation.md`。
// 更新判据是替换前的 bundle/进程状态；不以主模式 IsEnabled 单独判断。
// 首装计划启用父条目与主模式各一次，更新不重复启用。

import Foundation

enum InstallerActivationPolicy {

    static func parkingSourceID(preferredID: String?, selectableASCIIKeyboardIDs: [String]) -> String? {
        if let preferredID, selectableASCIIKeyboardIDs.contains(preferredID) { return preferredID }
        return selectableASCIIKeyboardIDs.sorted().first
    }

    // MARK: - 安装期激活计划（复合幂等判据真值表）

    struct ActivationPlan: Equatable {
        /// 干净首装 → 在安装器进程（登录用户 Aqua 会话里的已签名 GUI 进程，满足 enable 的全部
        /// 真必要条件）enable「父条目 + Hans 主模式」各一次（历史观察：父条目 enable 不级联模式；
        /// 父=菜单显形，Hans=select 需要的模式启用记录）。已有安装 → 整段跳过（避免历史重复启用问题）。
        let enableParentAndPrimaryModeOnce: Bool
        /// 更新前猫头鹰是当前输入法 → kill 前先切出到可用的系统英文键盘（历史观察：kill 当前选中的 IME 会让
        /// 重启后菜单不显示），装完由 `selectOwltypeAfterInstall` 配对切回。
        let parkOnKeyboardBeforeReplace: Bool
        /// 装完后 best-effort select 猫头鹰（验证后通过 fresh CLI 尝试）：首装锦上添花，或与切出配对
        /// 的切回。不变量：更新绝不从其它输入法手里抢当前输入源。
        let selectOwltypeAfterInstall: Bool
    }

    /// 三个输入信号都必须在 killall Owltype / 提权拷贝之前采样（顺序陷阱：晚一步就全被自己污染）。
    static func plan(
        bundlePreexisted: Bool,
        owltypeProcessWasRunning: Bool,
        owltypeWasCurrentSource: Bool
    ) -> ActivationPlan {
        let isExistingInstall = bundlePreexisted || owltypeProcessWasRunning
        return ActivationPlan(
            enableParentAndPrimaryModeOnce: !isExistingInstall,
            parkOnKeyboardBeforeReplace: owltypeWasCurrentSource,
            selectOwltypeAfterInstall: !isExistingInstall || owltypeWasCurrentSource)
    }

    // MARK: - consent 等待 + 读回验证状态机

    enum VerificationState: Equatable {
        /// 完整信号未凑齐且软超时未到 → 继续等（consent 框可能还没被点；或父已启用、Hans 还没
        /// 跟上——1.3.32 QA 的幽灵组合，绝不能提前判 verified）。
        case waiting
        /// fresh 进程探针读回「父条目 enabled ∧ Hans 在 enabled-only 列表」—— 过程信号（最终验收
        /// = 干净机真人看菜单 + 宿主 handle() 收键），但足以对用户报安装成功。
        /// 迟到信号同样翻 verified：人点「允许」可以晚于软超时（1.3.32-fix1 QA 假阴性的时序一半）。
        case verified
        /// 软超时未凑齐信号 → 诚实引导「注销重登」，绝不伪装成功（R1）。**非吸收态**（fix2）：
        /// stillTrying=true 时 verifier 后台继续 tick 到扩展截止，迟到 consent 一到就翻 verified；
        /// stillTrying=false = 扩展截止已过，终态。
        case needsLogout(stillTrying: Bool)
    }

    /// 纯转移函数（1.3.32-fix2 修订）：
    ///   - 信号 =「父条目 enabled ∧ Hans 在 enabled-only 列表」，由 `--tis-probe` fresh 进程探针
    ///     读回（安装器老进程的 TIS 快照陈旧，读不到 consent 之后的变更——与「装前已开的 App
    ///     打不出、新开 App 能打」同机理，进程内读回已退役）。本进程 select 信号随之退役：
    ///     select 改在 verified 时刻由 fresh 进程 Owltype CLI 执行，不再是输入信号。
    ///   - 信号优先于任何截止（迟到自愈：用户晚点「允许」照样翻绿）；
    ///   - 软超时（deadlineReached）→ needsLogout(stillTrying: true)，显示引导但继续等；
    ///   - 扩展截止（extendedDeadlineReached）→ needsLogout(stillTrying: false)，终态。
    static func verificationState(
        parentEnabledObserved: Bool,
        primaryModeEnabledObserved: Bool,
        deadlineReached: Bool,
        extendedDeadlineReached: Bool
    ) -> VerificationState {
        if parentEnabledObserved && primaryModeEnabledObserved {
            return .verified
        }
        if extendedDeadlineReached {
            return .needsLogout(stillTrying: false)
        }
        return deadlineReached ? .needsLogout(stillTrying: true) : .waiting
    }

    // MARK: - --tis-probe 自探针输出协议（fresh 进程 ↔ verifier；纯字符串，两端可单测）

    /// fresh 进程 TIS 真值三元组。parent = 父条目 IsEnabled 位（父无 tsInputModeDefaultStateKey，
    /// 该位可信）；primaryMode(hans) = enabled-only 列表成员资格（绝不看 Hans 的 IsEnabled 位——
    /// 历史上观察到恒真）；hansSelectCapable = Hans 的 IsSelectCapable 位（诊断参考，不进 verified 判定）。
    struct ProbeSignals: Equatable {
        let parentEnabled: Bool
        let primaryModeEnabled: Bool
        let primaryModeSelectCapable: Bool
    }

    /// 机器可读单行输出，如 `parent=1 hans=1 hansSelectCapable=1`。
    static func probeOutput(_ signals: ProbeSignals) -> String {
        "parent=\(signals.parentEnabled ? 1 : 0)"
            + " hans=\(signals.primaryModeEnabled ? 1 : 0)"
            + " hansSelectCapable=\(signals.primaryModeSelectCapable ? 1 : 0)"
    }

    /// 解析探针输出。容忍首尾空白/换行与多余 token；parent/hans 两键必须在且取值 0/1，
    /// 否则返回 nil（verifier 视作本 tick 无信号——坏输出绝不能被当成功）。
    static func parseProbeOutput(_ output: String) -> ProbeSignals? {
        var values: [String: String] = [:]
        for token in output.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        guard let parent = values["parent"], parent == "0" || parent == "1",
              let hans = values["hans"], hans == "0" || hans == "1" else {
            return nil
        }
        return ProbeSignals(
            parentEnabled: parent == "1",
            primaryModeEnabled: hans == "1",
            primaryModeSelectCapable: values["hansSelectCapable"] == "1")
    }

    // MARK: - 用户可见文案（双态：成功=新开应用立即可用；失败=注销引导）

    static let verifyingText = "正在等待 macOS 确认启用…若弹出「允许启用输入法」对话框，请点「允许」。"

    /// QA 三轮拍板（07-02）：领句只承诺「新打开的应用立即可用」，不领「无需注销」绝对承诺——
    /// 装前已开的 App 上下文陈旧（squirrel#68 边界），重开该应用即好；仍打不出才走注销兜底。
    static func successText(plan: ActivationPlan) -> String {
        if plan.enableParentAndPrimaryModeOnce {
            return "✅ 已安装并启用：新打开的应用立即可用。"
                + "安装前已打开的个别应用请重新打开该应用；若仍打不出，注销一次即可。"
        }
        return "✅ 更新完成：猫头鹰已原地更新，未改动你的输入法选择。"
    }

    /// stillTrying=true（软超时橙窗，verifier 仍在后台等迟到 consent）才承诺「本窗口会自动更新」；
    /// 扩展截止终态（stillTrying=false）verifier 已停，再作此承诺就是假话（R1 诚实兜底）。
    static func needsLogoutText(stillTrying: Bool) -> String {
        let base = "⚠️ 文件已安装，但未能确认猫头鹰进入输入法列表。"
            + "注销并重新登录后即可使用；或在 系统设置 → 键盘 → 输入法 里手动添加一次「猫头鹰」。"
        return stillTrying ? base + "若你刚点了「允许」，本窗口会自动更新。" : base
    }
}
