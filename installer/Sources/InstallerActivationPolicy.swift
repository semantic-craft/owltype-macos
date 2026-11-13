// InstallerActivationPolicy — 安装、修复与卸载的纯决策层（无 TIS / 无 IO / 无 AppKit）。
//
// 为什么是纯函数：TIS/IMK 无法 headless 单测，所以把「该不该 enable/select」、
// 「预检状态归类」与「四合一动作完成态文案」抽成纯函数，编进 OwltypeTests 覆盖真值表
// （`tests/InstallerActivationPolicyTests.swift`）；系统副作用留在 `installer/Sources/Installer.swift`
// 与 `sources/Activation/OwlInstallSession.swift`。
// 当前策略、回归测试和历史观察边界见 `docs/operations/installation.md`。

import Foundation

enum InstallerActivationPolicy {

    static func parkingSourceID(preferredID: String?, selectableASCIIKeyboardIDs: [String]) -> String? {
        if let preferredID, selectableASCIIKeyboardIDs.contains(preferredID) { return preferredID }
        return selectableASCIIKeyboardIDs.sorted().first
    }

    // MARK: - 安装期激活计划（复合幂等判据真值表）

    struct ActivationPlan: Equatable {
        let enableParentAndPrimaryModeOnce: Bool
        let selectOwltypeAfterInstall: Bool
    }

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

    enum VersionRelation: Equatable {
        case notInstalled
        case upgrade(installed: String, embedded: String)
        case sameVersion(version: String)
        case reinstallOlder(installed: String, embedded: String)
    }

    static func parseVersionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        result.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, let value = Int(part), value >= 0 else { return nil }
            result.append(value)
        }
        return result
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = parseVersionComponents(lhs),
              let right = parseVersionComponents(rhs) else {
            return nil
        }
        for index in 0..<max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    static func versionRelation(installedBuild: String?, embeddedBuild: String?) -> VersionRelation {
        guard let installed = installedBuild, !installed.isEmpty else {
            return .notInstalled
        }
        guard let embedded = embeddedBuild, !embedded.isEmpty else {
            return .sameVersion(version: installed)
        }
        guard let order = compareVersions(embedded, installed) else {
            return .upgrade(installed: installed, embedded: embedded)
        }
        switch order {
        case .orderedDescending:
            return .upgrade(installed: installed, embedded: embedded)
        case .orderedSame:
            return .sameVersion(version: installed)
        case .orderedAscending:
            return .reinstallOlder(installed: installed, embedded: embedded)
        }
    }

    struct PreflightReport: Equatable {
        let installedShortVersion: String?
        let installedBuildVersion: String?
        let embeddedShortVersion: String?
        let embeddedBuildVersion: String?
        let strayCopyCount: Int
        let extraLaunchServicesClaimCount: Int

        var isInstalled: Bool {
            guard let installedBuildVersion else { return false }
            return !installedBuildVersion.isEmpty
        }

        var hasAnomalies: Bool {
            strayCopyCount > 0 || extraLaunchServicesClaimCount > 0
        }

        var relation: VersionRelation {
            versionRelation(installedBuild: installedBuildVersion, embeddedBuild: embeddedBuildVersion)
        }

        var primaryButtonTitle: String {
            switch relation {
            case .notInstalled:
                return "立即安装"
            case .upgrade:
                return "更新输入法"
            case .sameVersion, .reinstallOlder:
                return "重新安装"
            }
        }

        var statusHeadline: String {
            let embeddedLabel = Self.formatVersion(short: embeddedShortVersion, build: embeddedBuildVersion)
            let installedLabel = Self.formatVersion(short: installedShortVersion, build: installedBuildVersion)
            switch relation {
            case .notInstalled:
                if let embeddedLabel {
                    return "本机尚未安装 · 安装包版本 \(embeddedLabel)"
                }
                return "本机尚未安装法墨输入法"
            case .upgrade:
                if let installedLabel, let embeddedLabel {
                    return "已安装 \(installedLabel) · 可更新至 \(embeddedLabel)"
                }
                return "检测到新版本，可直接更新"
            case .sameVersion:
                if let installedLabel {
                    return "已安装 \(installedLabel)（已是当前安装包版本，支持重新安装或修复）"
                }
                return "已安装当前版本，支持重新安装或修复"
            case .reinstallOlder:
                if let installedLabel, let embeddedLabel {
                    return "本机已安装 \(installedLabel) · 安装包版本 \(embeddedLabel)（支持覆盖重装）"
                }
                return "本机已安装更高版本，支持覆盖重装或修复"
            }
        }

        var anomalyWarning: String? {
            guard hasAnomalies else { return nil }
            var clauses: [String] = []
            if strayCopyCount > 0 {
                clauses.append("\(strayCopyCount) 处非标准副本或残留目录")
            }
            if extraLaunchServicesClaimCount > 0 {
                clauses.append("\(extraLaunchServicesClaimCount) 条多余的 LaunchServices 路径注册")
            }
            return "检测到 " + clauses.joined(separator: "、") + "，可能导致输入法菜单重复或版本错乱；建议点击「修复安装」或「清空修复」。"
        }

        private static func formatVersion(short: String?, build: String?) -> String? {
            switch (short, build) {
            case let (s?, b?) where !s.isEmpty && !b.isEmpty && s != b:
                return "\(s) (\(b))"
            case let (s?, _) where !s.isEmpty:
                return s
            case let (_, b?) where !b.isEmpty:
                return b
            default:
                return nil
            }
        }
    }

    // MARK: - 会话收敛状态与四合一动作完成摘要

    enum SessionStatus: Equatable {
        case ready
        case deferred
    }

    static func parseFinishInstallStatus(_ output: String) -> SessionStatus? {
        guard output.contains("INSTALL_SESSION_OK") else { return nil }
        if output.contains("status=deferred") {
            return .deferred
        }
        return .ready
    }

    enum ActionKind: Equatable {
        case install(plan: ActivationPlan, status: SessionStatus)
        case repairInstall(status: SessionStatus)
        case clearAndRepair
        case uninstall(keepUserData: Bool)
    }

    struct CompletionSummary: Equatable {
        let title: String
        let detail: String
        let showsActivateButton: Bool
        let showsSystemSettingsButton: Bool
    }

    static func completionSummary(for action: ActionKind) -> CompletionSummary {
        switch action {
        case .install(let plan, let status):
            if status == .ready {
                return CompletionSummary(
                    title: plan.enableParentAndPrimaryModeOnce ? "安装完成" : "更新完成",
                    detail: successText(plan: plan),
                    showsActivateButton: true,
                    showsSystemSettingsButton: false)
            }
            return CompletionSummary(
                title: plan.enableParentAndPrimaryModeOnce ? "安装已完成" : "更新已完成",
                detail: "✅ 法墨输入法文件已安装就绪。若右上角输入法菜单尚未显示「法墨」，请点击下方「启用并切换到法墨」或在「系统设置 → 键盘 → 输入法」中添加。",
                showsActivateButton: true,
                showsSystemSettingsButton: true)
        case .repairInstall(let status):
            if status == .ready {
                return CompletionSummary(
                    title: "修复安装完成",
                    detail: "✅ 已清理残留副本与输入法缓存，并重新安装启用法墨输入法。你的个人词库与设置已保留。",
                    showsActivateButton: true,
                    showsSystemSettingsButton: false)
            }
            return CompletionSummary(
                title: "修复安装已完成",
                detail: "✅ 已清理残留副本与输入法缓存，并完成文件重装。请点击下方「启用并切换到法墨」完成激活。",
                showsActivateButton: true,
                showsSystemSettingsButton: true)
        case .clearAndRepair:
            return CompletionSummary(
                title: "清空修复完成",
                detail: "✅ 已清理多余副本、幽灵注册与系统输入法列表缓存，并刷新输入法菜单与后台服务。你的个人词库与配置完好保留。",
                showsActivateButton: true,
                showsSystemSettingsButton: false)
        case .uninstall(let keepUserData):
            let dataNote = keepUserData
                ? "你的个人词库与配置文件已保留在 ~/Library/Application Support/Owltype。"
                : "已同时清空个人词库、缓存与偏好设置。"
            return CompletionSummary(
                title: "卸载完成",
                detail: "✅ 法墨输入法已从本机移除，输入法菜单已刷新。\(dataNote)Squirrel、~/Library/Rime 及其他输入法未被触碰。",
                showsActivateButton: false,
                showsSystemSettingsButton: false)
        }
    }

    // MARK: - --tis-probe 自探针输出协议（fresh 进程 ↔ verifier；纯字符串，两端可单测）

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
    /// 否则返回 nil（verifier 视作本 tick 无信号）。
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
