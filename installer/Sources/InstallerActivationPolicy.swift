// InstallerActivationPolicy — 安装激活的纯决策层（无 TIS / 无 IO / 无 AppKit）。
//
// 为什么是纯函数：TIS/IMK 无法 headless 单测，所以把「该不该 enable/select」
// 与「读回验证状态机」抽成纯函数，编进 OwltypeTests 覆盖真值表（tests/InstallerActivationPolicyTests.swift，
// 参照 ActivationPolicyTests 的 pure-dispatch 风格）；TIS 副作用薄层留在 OwlInstallSession。
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
        /// 自检时通过 fresh CLI 选择猫头鹰：首装启用后选择，更新保留原模式；不与临时切出配对
        /// 。不变量：更新绝不从其它输入法手里抢当前输入源。
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
            selectOwltypeAfterInstall: !isExistingInstall || owltypeWasCurrentSource)
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

    static func successText(plan: ActivationPlan) -> String {
        plan.enableParentAndPrimaryModeOnce
            ? "✅ 已安装并启用，输入法会话自检通过。请在应用中试输入。"
            : "✅ 更新完成，会话自检通过，已保留更新前的输入法选择。"
    }
}
