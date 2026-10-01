// Installer — 安装/卸载的全部副作用逻辑（无 UI）。
//
// 安全纪律（卸载白名单，照搬 scripts/uninstall-owltype.sh 精神）：
//   - 删除目标 **硬编码** 为猫头鹰自有路径，绝不触碰 Squirrel / ~/Library/Rime / im.rime /
//     Sogou / 搜狗 / Weasel 等他人输入法。
//   - root 陷阱：`do shell script ... with administrator privileges` 以 root 运行，$HOME 会变成
//     /var/root，所以用户目录下的清理 **绝不** 交给 root 跑——用安装器进程自身（= 登录用户）的
//     FileManager 删；只有 /Library/Input Methods 下的系统级 bundle 才走提权。

import Foundation
import Carbon
import AppKit

enum InstallerError: LocalizedError {
    case embeddedAppNotFound
    case userCancelled
    case validationFailed(String)
    case privilegedCommandFailed(String)
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .embeddedAppNotFound:
            return "未找到内嵌 Owltype.app（打包问题）"
        case .userCancelled:
            return "已取消"
        case .validationFailed(let message):
            return "安装包校验失败：\(message)"
        case .privilegedCommandFailed(let message):
            return "授权步骤失败：\(message)"
        case .activationFailed(let message):
            return "输入法激活失败：\(message)"
        }
    }
}

enum Installer {
    /// 系统输入法目录里的猫头鹰安装位置。
    static let installedAppPath = "/Library/Input Methods/Owltype.app"
    private static let installerStatePath = "/private/var/db/im.owltype.inputmethod.Owltype-installer"
    private static let expectedBundleID = "im.owltype.inputmethod.Owltype"
    private static let expectedTeamID = "LQAVR62TK2"

    private struct AppMetadata {
        let bundleID: String
        let shortVersion: String
        let buildVersion: String
    }

    private enum InstallKind {
        case firstInstall
        case update
        case repair
        case replaceInvalidExisting
    }

    // MARK: - 内嵌 Owltype.app 定位

    /// 内嵌的 Owltype.app = 安装器自身 Contents/Library/Owltype.app（由 P3 打包时放入）。
    /// 放 Contents/Library（Apple 约定的嵌套代码位置），不放 Contents/Resources——避免真公证
    /// 时对 Resources 里嵌套可执行代码的潜在拒绝（WeChat/Sogou 也不把裸 .app 放 Resources）。
    /// P2 阶段它尚不存在，运行到 install() 会按预期报「未找到内嵌 Owltype.app」。
    static func embeddedOwltypeAppURL() -> URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Owltype.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 安装

    /// 安装/更新主流程。返回激活计划：调用方（ViewModel）据此在主 runloop 上启动
    /// `InstallerActivationVerifier`（consent 等待 + 读回验证 + best-effort select 重试）。
    static func install() throws -> InstallerActivationPolicy.ActivationPlan {
        guard let embedded = embeddedOwltypeAppURL() else {
            throw InstallerError.embeddedAppNotFound
        }
        let payload = try validatePayload(at: embedded)

        // —— 复合幂等判据采样（定律 11）：三个信号都必须在下面的 killall 与提权拷贝（会把旧 bundle
        // 挪走）之前取到，否则被本安装流程自己污染（Sparkle 先杀宿主的同型顺序陷阱）。绝不用
        // kTISPropertyInputSourceIsEnabled 当判据（定律 4：对 default-on 的 Hans 恒 true）。
        let bundlePreexisted = FileManager.default.fileExists(atPath: installedAppPath)
        let owltypeWasRunning = owltypeProcessIsRunning()
        let owltypeWasCurrentSource = DispatchQueue.main.sync { currentSourceIsOwltype() }
        let plan = InstallerActivationPolicy.plan(
            bundlePreexisted: bundlePreexisted,
            owltypeProcessWasRunning: owltypeWasRunning,
            owltypeWasCurrentSource: owltypeWasCurrentSource)

        // 降级拒绝 / 嵌套坏包等既有校验仍走 installKind（分类本身不再驱动 enable/select——那由
        // 上面的复合判据 plan 决定）。
        _ = try installKind(for: payload)

        // 定律 12：kill 当前选中的 IME 前先切出到可用的系统英文键盘，否则重启后菜单可能不显示；装完由
        // verifier 的 select 重试配对切回。
        if plan.parkOnKeyboardBeforeReplace {
            try parkCurrentSource(usingOwltypeApp: embedded)
        }

        terminateUserProcess(named: "Owltype")
        try privilegedReplace(fromAppPath: embedded.path)
        try validateInstalledApp(expected: payload)
        // 校验提权拷贝确实以 root 跑成（用户实测过「没问密码 / 没拷成」却假报成功的情况）。
        let installedExecutable = installedAppPath + "/Contents/MacOS/Owltype"
        guard FileManager.default.isExecutableFile(atPath: installedExecutable),
              !FileManager.default.fileExists(atPath: installedAppPath + "/Owltype.app") else {
            throw InstallerError.privilegedCommandFailed(
                "拷贝后未发现有效的 \(installedAppPath)（提权可能未执行，或旧包未删除干净）")
        }
        // TIS register/enable 都在「安装器进程」内做：本进程
        // 就是登录用户 Aqua 会话里的已签名 GUI App，满足 enable 的全部真必要条件（见首装免注销专题 07-02
        // research/web-cross-validation-no-logout.md——「必须 IME 自身进程」系已证伪的误归因）。
        // TIS API 必须在主线程调用（后台线程调 TISCreateInputSourceList 会 dispatch_assert_queue_fail
        // 崩溃），install() 跑在后台队列，故 main.sync 切回主线程（不会死锁）。select 不在这里做
        // （定律 2：嵌套 runloop 里 select 必 -50），由 verifier 排到正常主 runloop 重试。
        try DispatchQueue.main.sync {
            try registerAndEnableInputSources(plan: plan)
        }
        // 先触发 Owltype.app 自带的 install-once registration repair，再无参数启动 Owltype.app 让它注册
        // InputMethodKit Mach endpoint。`--activate-once` 是 CLI 修复命令，会立即退出，不能
        // 单独承担“可打字”的验收；微信/搜狗的关键差异是安装后有 live IMK server。
        try launchInstalledAppForActivation()
        return plan
    }

    /// pgrep 登录用户域的 Owltype 进程（复合判据副信号）：进程活着 ⟺ 已被 register+enable 过
    /// （IMK 只拉起已启用的输入法——fcitx5 幂等判据，比会撒谎的 IsEnabled 可靠）。
    private static func owltypeProcessIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-U", "\(getuid())", "-x", "Owltype"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 当前系统输入源是否猫头鹰（只读 TIS；主线程调用）。
    private static func currentSourceIsOwltype() -> Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let ref = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return false
        }
        return (unsafeBitCast(ref, to: CFString.self) as String).hasPrefix(inputMethodID)
    }

    /// Only choose an enabled ASCII keyboard actually present on this Mac (US is not ABC).
    /// Read TIS on the main thread; select in a fresh CLI process to avoid nested-runloop failure.
    /// Verify readback because the existing CLI also exits successfully when selection fails.
    private static func parkCurrentSource(usingOwltypeApp app: URL) throws {
        let sourceID: String? = DispatchQueue.main.sync {
            let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout,
                          kTISPropertyInputSourceIsASCIICapable: kCFBooleanTrue!,
                          kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue!,
                          kTISPropertyInputSourceIsEnabled: kCFBooleanTrue!] as CFDictionary
            let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
            func id(_ source: TISInputSource) -> String? {
                guard let ref = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
                return unsafeBitCast(ref, to: CFString.self) as String
            }
            let preferred = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
            return InstallerActivationPolicy.parkingSourceID(
                preferredID: id(preferred), selectableASCIIKeyboardIDs: sources.compactMap(id))
        }
        guard let sourceID else {
            throw InstallerError.activationFailed("未找到可用的英文键盘输入源，未替换猫头鹰。请先启用系统英文键盘。")
        }
        let owl = app.appendingPathComponent("Contents/MacOS/Owltype")
        _ = try runProcess(owl.path, ["--select-input-source", sourceID])
        let selected = try runProcess(owl.path, ["--current-input-source"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected == sourceID else {
            throw InstallerError.activationFailed("未能切换到系统英文键盘，已停止操作。请切换后重试。")
        }
    }

    // MARK: - 安装包校验 / 更新分类

    private static func validatePayload(at url: URL) throws -> AppMetadata {
        let metadata = try appMetadata(at: url)
        guard metadata.bundleID == expectedBundleID else {
            throw InstallerError.validationFailed("bundle id 应为 \(expectedBundleID)，实际为 \(metadata.bundleID)")
        }
        _ = try versionComponents(metadata.shortVersion, label: "CFBundleShortVersionString")
        _ = try versionComponents(metadata.buildVersion, label: "CFBundleVersion")
        guard FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/Owltype").path) else {
            throw InstallerError.validationFailed("缺少可执行文件 Contents/MacOS/Owltype")
        }
        guard !FileManager.default.fileExists(atPath: url.appendingPathComponent("Owltype.app").path) else {
            throw InstallerError.validationFailed("发现嵌套的 Owltype.app")
        }
        try verifyCodeSignature(at: url)
        return metadata
    }

    private static func validateInstalledApp(expected: AppMetadata) throws {
        let url = URL(fileURLWithPath: installedAppPath)
        let metadata = try appMetadata(at: url)
        guard metadata.bundleID == expected.bundleID,
              metadata.shortVersion == expected.shortVersion,
              metadata.buildVersion == expected.buildVersion else {
            throw InstallerError.privilegedCommandFailed("替换后版本/身份不一致")
        }
        try verifyCodeSignature(at: url)
    }

    private static func installKind(for payload: AppMetadata) throws -> InstallKind {
        let installedURL = URL(fileURLWithPath: installedAppPath)
        guard FileManager.default.fileExists(atPath: installedURL.path) else {
            return .firstInstall
        }
        guard !FileManager.default.fileExists(atPath: installedURL.appendingPathComponent("Owltype.app").path) else {
            return .replaceInvalidExisting
        }
        let installed: AppMetadata
        do {
            installed = try appMetadata(at: installedURL)
        } catch {
            return .replaceInvalidExisting
        }
        guard installed.bundleID == expectedBundleID else {
            throw InstallerError.validationFailed("目标路径已有非 Owltype bundle：\(installed.bundleID)")
        }
        let order: ComparisonResult
        do {
            order = try compareVersions(payload.buildVersion, installed.buildVersion)
        } catch {
            return .replaceInvalidExisting
        }
        if order == .orderedAscending {
            throw InstallerError.validationFailed(
                "拒绝降级：已安装 \(installed.buildVersion)，安装包 \(payload.buildVersion)")
        }
        return order == .orderedSame ? .repair : .update
    }

    private static func appMetadata(at url: URL) throws -> AppMetadata {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw InstallerError.validationFailed("无法读取 \(infoURL.path)")
        }
        return AppMetadata(
            bundleID: try plistString("CFBundleIdentifier", from: plist, at: infoURL),
            shortVersion: try plistString("CFBundleShortVersionString", from: plist, at: infoURL),
            buildVersion: try plistString("CFBundleVersion", from: plist, at: infoURL))
    }

    private static func plistString(_ key: String, from plist: [String: Any], at url: URL) throws -> String {
        guard let value = plist[key] as? String, !value.isEmpty else {
            throw InstallerError.validationFailed("\(url.path) 缺少 \(key)")
        }
        return value
    }

    private static func versionComponents(_ version: String, label: String) throws -> [Int] {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            throw InstallerError.validationFailed("\(label) 为空")
        }
        return try parts.map { part in
            guard !part.isEmpty, let value = Int(part), value >= 0 else {
                throw InstallerError.validationFailed("\(label) 不是可比较版本号：\(version)")
            }
            return value
        }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) throws -> ComparisonResult {
        let left = try versionComponents(lhs, label: "CFBundleVersion")
        let right = try versionComponents(rhs, label: "已安装 CFBundleVersion")
        for index in 0..<max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func verifyCodeSignature(at url: URL) throws {
        try runProcess("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", url.path])
        let details = try runProcess("/usr/bin/codesign", ["-dv", "--verbose=4", url.path])
        guard details.contains("Authority=Developer ID Application:"),
              details.contains("Authority=Developer ID Certification Authority"),
              details.contains("Authority=Apple Root CA"),
              details.contains("TeamIdentifier=\(expectedTeamID)") else {
            throw InstallerError.validationFailed("签名不是预期 Developer ID / TeamIdentifier \(expectedTeamID)")
        }
    }

    // MARK: - 输入法菜单激活（register + enable 都在安装器进程内）

    /// 「父输入法」的 Input Source ID = 输入菜单的显示开关（真机确认：菜单看父项启用态，不是单个模式）。
    static let inputMethodID = "im.owltype.inputmethod.Owltype"

    /// 猫头鹰主输入模式（简体）的 Input Source ID。父项启用后再启用此模式。
    static let primaryModeID = "im.owltype.inputmethod.Owltype.Hans"

    /// 从一份「刚取的」输入源列表里按 ID 找源。每次操作都要重取，避免拿旧引用。
    /// `TISRegisterInputSource` 之后，系统输入源列表有传播延迟（尤其首次安装、冷启动），
    /// 一次取不到就转一圈 runloop 再重试，而不是直接判失败——这是「装好却不显示」最常见的真因。
    /// 这里用有界轮询（约 3 秒）等待注册传播；若真机仍偶发取不到，再升级成通知观察者。
    private static func freshSource(_ id: String) throws -> TISInputSource {
        for attempt in 0..<30 {
            if let cfList = TISCreateInputSourceList(nil, true)?.takeRetainedValue(),
               let list = cfList as? [TISInputSource],
               let source = list.first(where: {
                   guard let r = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else {
                       return false
                   }
                   return (unsafeBitCast(r, to: CFString.self) as String) == id
               }) {
                return source
            }
            if attempt < 29 {
                // 转一圈主 runloop，让 TIS 把刚注册的源刷进列表，再重试。
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
        }
        throw InstallerError.activationFailed("未找到输入源 \(id)（注册后等待超时）")
    }

    /// register + （仅干净首装）enable「父条目 + Hans 主模式」各一次——全部在安装器进程主线程做。
    ///
    /// 修正后配方（首装免注销专题 07-02 的 research + 1.3.32 首装 QA 真机实证）：
    ///   - enable 的必要条件是登录用户身份、Aqua GUI 会话与已签名 App；本安装器进程三条全满足。
    ///   - enable「父条目 + Hans 模式条目」各一次（定律 13，暂定待 DIAG 探针定谳）：macOS 26 真机上
    ///     enable 父条目**不级联** default-on 的 Hans 模式——1.3.32 QA 现场=菜单有「猫头鹰」行
    ///     （菜单看父条目启用态）但点不中（select 需要模式条目的启用记录，Hans 从未被 enable）。
    ///     顺序=先父后模式（Apple 头文件：mode 的父项必须先启用）。Owltype 的 Squirrel 系 plist
    ///     带 `tsInputModeDefaultStateKey`，因此父条目与主模式需要分别启用。
    ///   - 是否 enable 由复合幂等判据决定（`InstallerActivationPolicy.plan`，定律 4/11）：已有安装
    ///     整段跳过——对已启用条目二次 TISEnableInputSource 会打成 "error" 幽灵态（fcitx5 PR#4）。
    ///     定律 11 的「一次且仅一次」针对**同一条目**的二次 enable；父与 Hans 两个不同条目各
    ///     enable 一次不违反。
    ///   - enable 立即返回 0，真生效等用户点「允许」同意框（定律 1，异步）；select 不在这里做
    ///     （定律 2：嵌套 runloop 里必 -50），由 `InstallerActivationVerifier` 排到正常主 runloop
    ///     best-effort 重试，并做 enabled 读回验证（过程信号；最终验收 = 真人看菜单，定律 3）。
    static func registerAndEnableInputSources(plan: InstallerActivationPolicy.ActivationPlan) throws {
        try check(TISRegisterInputSource(URL(fileURLWithPath: installedAppPath) as CFURL), "注册 Owltype.app")

        // 等注册传播：源进入 TIS 列表后再 enable，避免「装好却不显示」（定律 5）。
        _ = try freshSource(primaryModeID)

        if plan.enableParentAndPrimaryModeOnce {
            let parent = try freshSource(inputMethodID)
            try check(TISEnableInputSource(parent), "启用父输入法 \(inputMethodID)")
            // 每次 TIS 变更后重取引用（spec：read fresh after every mutation），不复用旧引用。
            let hans = try freshSource(primaryModeID)
            try check(TISEnableInputSource(hans), "启用主输入模式 \(primaryModeID)")
        }

        // 这次广播+刷代理打在 consent **之前**（enable 刚调、用户还没点「允许」），对 consent
        // 之后的世界无效——保留作无害的即时刷新；真正让菜单代理 + 已运行 App 认到猫头鹰的是
        // verifier 在 verified 时刻补发的组合拳（InstallerActivationVerifier.performVerifiedRefresh，
        // 1.3.32-fix2：QA 真机的「菜单点不中 / 装前已开 App 打不出」刷新缺口即缺那一次）。
        let center = CFNotificationCenterGetDistributedCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(kTISNotifyEnabledKeyboardInputSourcesChanged),
            nil, nil, true)
        refreshInputMenuAgents()
    }

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            throw InstallerError.activationFailed("\(action) 返回 \(status)")
        }
    }

    /// 强制输入菜单代理重读；launchd 会自动重启这些进程。best-effort。
    static func refreshInputMenuAgents() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-9", "pboard", "TextInputMenuAgent", "TextInputSwitcher"]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Run the activation command, then launch the installed input method in the current Aqua
    /// session so it registers its InputMethodKit Mach endpoint. The command form
    /// (`Owltype --activate-once`) exits before `IMKServer` is created; the plain app launch is what
    /// makes the selected input source usable immediately after install/update.
    ///
    /// endpoint 5s 轮询**不是硬门**（1.3.32-fix2 拆除）：endpoint 发布与 enable 是否生效正交
    /// （QA 真机：endpoint 判据超时时 Hans 其实已 enabled 可选），此前的 throw 会绕过 verifier
    /// 直接进失败 UI。现在没等到只记录，流程照常进 verifier，由 fresh 进程探针定成败。
    private static func launchInstalledAppForActivation() throws {
        try runCheckedProcess(
            URL(fileURLWithPath: installedAppPath + "/Contents/MacOS/Owltype"),
            ["--activate-once"],
            launchFailure: "无法启动 Owltype.app --activate-once",
            nonZeroFailure: "Owltype.app --activate-once 启动失败")

        try runCheckedProcess(
            URL(fileURLWithPath: "/usr/bin/open"),
            ["-g", installedAppPath],
            launchFailure: "无法通过 open 启动 Owltype.app",
            nonZeroFailure: "open Owltype.app 失败")

        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: expectedBundleID)
                .contains(where: { !$0.isTerminated })
            if running, owltypeEndpointIsPublished() {
                return
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        NSLog("OwltypeInstaller: Owltype IMK endpoint 未在 5s 内确认发布（不作硬门，交给 verifier 继续观察）")
    }

    /// IMK Mach endpoint 是否已发布。只能全域 dump 后 contains 查找——收窄不可行：endpoint 不是
    /// service label，`launchctl print gui/$uid/im.owltype.inputmethod.Owltype_Connection` 实测返回
    /// "Could not find service"（2026-07-02，Owltype 运行中、endpoint 明明在全域 dump 里也找不到）。
    /// 全域 dump 实测 131KB > 64KB 管道缓冲：本调用正是 1.3.32 首装 QA Bug A 的死锁触发点，
    /// 依赖 runProcess 的「先排空再等退出」次序保命；外层轮询有 5s deadline（调用方）。
    private static func owltypeEndpointIsPublished() -> Bool {
        let output = (try? runProcess("/bin/launchctl", ["print", "gui/\(getuid())"])) ?? ""
        return output.contains("im.owltype.inputmethod.Owltype_Connection")
    }

    private static func runCheckedProcess(
        _ executableURL: URL,
        _ arguments: [String],
        launchFailure: String,
        nonZeroFailure: String
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw InstallerError.activationFailed("\(launchFailure)：\(error.localizedDescription)")
        }
        // 同 runProcess：先排空管道到 EOF 再 waitUntilExit（管道满死锁，1.3.32 Bug A 同病同修）。
        // 成功路径也必须排空——否则大输出子进程在成功前就把双方锁死。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            throw InstallerError.activationFailed(output.isEmpty ? nonZeroFailure : output)
        }
    }

    /// 唯一需要 root 的一步：把内嵌 Owltype.app 事务替换到 /Library/Input Methods/。
    private static func privilegedReplace(fromAppPath sourcePath: String) throws {
        let source = shellQuote(sourcePath)
        let dest = shellQuote(installedAppPath)
        let token = shellQuote("owl-\(UUID().uuidString)")
        let command = [
            "set -e",
            "src=\(source)",
            "dest=\(dest)",
            "parent='/Library/Input Methods'",
            "token=\(token)",
            "stage=\"$parent/.Owltype.app.new.$token\"",
            "old=\"$parent/.Owltype.app.old.$token\"",
            "rm -rf \"$stage\" \"$old\"",
            "find \"$parent\" -maxdepth 1 -name '.Owltype.app.old.*' -exec rm -rf {} +",
            "rm -rf \"$parent/Owltype.swiftmodule\"",
            "/usr/bin/ditto \"$src\" \"$stage\"",
            "test -x \"$stage/Contents/MacOS/Owltype\"",
            "test ! -e \"$stage/Owltype.app\"",
            "/usr/bin/codesign --verify --strict \"$stage\"",
            // ponytail: root swap only. In-place Contents replacement hits com.apple.macl on real systems.
            "if [ -e \"$dest\" ]; then mv \"$dest\" \"$old\"; fi",
            "if mv \"$stage\" \"$dest\"; then :; else if [ -e \"$old\" ]; then mv \"$old\" \"$dest\"; fi; exit 1; fi",
            "chown -R root:staff \"$dest\"",
            "chmod -R 755 \"$dest\"",
            "xattr -d -r com.apple.quarantine \"$dest\" 2>/dev/null || true",
            "xattr -d -r com.apple.macl \"$dest\" 2>/dev/null || true",
            "if ! /usr/bin/codesign --verify --strict \"$dest\"; then rm -rf \"$dest\"; if [ -e \"$old\" ]; then mv \"$old\" \"$dest\"; fi; exit 1; fi",
            "rm -rf \"$old\"",
            // 刷新菜单栏（微信 install.sh / 搜狗 install.sh 同款）：以 root 杀掉登录用户的 SystemUIServer，
            // launchd 立即重启，重启后重读输入源列表。失败不致命。
            "killall SystemUIServer 2>/dev/null || true"
        ].joined(separator: "; ")
        try runPrivileged(command)
    }

    // MARK: - 卸载

    /// 用户级删除白名单：全部是猫头鹰自有路径（绝不含他人输入法 / Rime）。
    private static func userLevelTargets() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/Owltype"),
            home.appendingPathComponent("Library/Caches/im.owltype.inputmethod.Owltype"),
            home.appendingPathComponent("Library/Preferences/im.owltype.inputmethod.Owltype.plist"),
            home.appendingPathComponent("Library/HTTPStorages/im.owltype.inputmethod.Owltype"),
            home.appendingPathComponent("Library/Logs/Owltype")
        ]
    }

    static func uninstall() throws {
        let fileManager = FileManager.default

        // 1) 若当前输入源是猫头鹰，先停到可用的系统英文键盘；随后停用 TIS 条目再退出。否则只删 bundle 会在
        // 当前登录会话留下一个 enabled 但不可启动的幽灵输入源，直到注销后才消失。
        let installedExecutable = installedAppPath + "/Contents/MacOS/Owltype"
        if fileManager.isExecutableFile(atPath: installedExecutable) {
            let current = (try? runProcess(installedExecutable, ["--current-input-source"])) ?? ""
            if current.hasPrefix(inputMethodID) {
                try parkCurrentSource(usingOwltypeApp: URL(fileURLWithPath: installedAppPath))
            }
            _ = try? runProcess(installedExecutable, ["--disable-input-source"])
            _ = try? runProcess(installedExecutable, ["--quit"])
        }
        terminateUserProcess(named: "Owltype")

        // 2) 用户级清理：安装器进程本身就是登录用户，直接用 FileManager 删，避免 root 的 $HOME 陷阱。
        for url in userLevelTargets() where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        // 3) 提权级：只删两个硬编码的 Owltype 系统路径（bundle + root-owned 安装状态）。
        //    二者都不存在时不弹授权框，避免干净机器卸载时无谓地要密码。
        let receiptExists = (try? runProcess(
            "/usr/sbin/pkgutil", ["--pkg-info", expectedBundleID])) != nil
        if fileManager.fileExists(atPath: installedAppPath)
            || fileManager.fileExists(atPath: installerStatePath)
            || receiptExists {
            let dest = shellQuote(installedAppPath)
            let state = shellQuote(installerStatePath)
            var command = "rm -rf \(dest) \(state)"
            if receiptExists {
                command += " && /usr/sbin/pkgutil --forget im.owltype.inputmethod.Owltype >/dev/null"
            }
            try runPrivileged(command)
        }
    }

    /// 用户级 killall（不提权）。退出码忽略：进程不存在属正常。
    private static func terminateUserProcess(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = [name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 提权执行（NSAppleScript do-shell-script）

    /// 通过 NSAppleScript `with administrator privileges` 以 root 跑一条 shell 命令。
    /// 用户在系统授权框输密码 / Touch ID；取消 → InstallerError.userCancelled。
    private static func runPrivileged(_ command: String) throws {
        // command 内的反斜杠与双引号需为 AppleScript 字符串字面量转义。
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            throw InstallerError.privilegedCommandFailed("无法构造授权脚本")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            // -128 = userCancelledErr（用户在授权框点了取消）。
            if code == -128 {
                throw InstallerError.userCancelled
            }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "未知错误（\(code)）"
            throw InstallerError.privilegedCommandFailed(message)
        }
    }

    /// 单引号包裹路径并转义内部单引号，安全嵌入 shell 命令（再经 runPrivileged 做 AppleScript 转义）。
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// internal（非 private）：InstallerActivationVerifier 复用它 spawn `--tis-probe` 自探针
    /// 与 verified 时刻的 Owltype CLI select（fresh 进程，1.3.32-fix2）。
    @discardableResult
    static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw InstallerError.validationFailed(error.localizedDescription)
        }
        // 先排空管道到 EOF，再 waitUntilExit —— 顺序绝不可倒（1.3.32 首装 QA Bug A 根因）：
        // 匿名管道缓冲上限 64KB；子进程输出更大时（launchctl print gui/$uid 实测 131KB）会阻塞在
        // write(2) 等父进程消费，父进程若先 waitUntilExit 则双方互等 = 无 deadline 的永久死锁
        // （安装器卡死在「正在安装猫头鹰…」，verifier 层的 30s 超时降级根本没机会启动）。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw InstallerError.validationFailed(output.isEmpty ? "\(executable) 失败" : output)
        }
        return output
    }
}
