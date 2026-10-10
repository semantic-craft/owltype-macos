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

    /// Return only after file validation and the user-session self-check both succeed.
    static func install() throws -> InstallerActivationPolicy.ActivationPlan {
        guard let embedded = embeddedOwltypeAppURL() else {
            throw InstallerError.embeddedAppNotFound
        }
        let payload = try validatePayload(at: embedded)

        let bundlePreexisted = FileManager.default.fileExists(atPath: installedAppPath)
        let wasRunning = owltypeProcessIsRunning()
        let sourceBefore = DispatchQueue.main.sync { currentSourceID() }
        let plan = InstallerActivationPolicy.plan(
            bundlePreexisted: bundlePreexisted, owltypeProcessWasRunning: wasRunning,
            owltypeWasCurrentSource: sourceBefore.hasPrefix(inputMethodID + "."))
        _ = try installKind(for: payload)
        // Leave the old server alive while Contents is staged and exchanged.
        try privilegedReplace(fromAppPath: embedded.path)
        try validateInstalledApp(expected: payload)
        do {
            let output = try runProcess(installedAppPath + "/Contents/MacOS/Owltype", [
                "--finish-install", plan.enableParentAndPrimaryModeOnce ? "first" : "update",
                sourceBefore, payload.buildVersion,
            ])
            guard output.contains("INSTALL_SESSION_OK ") else {
                throw InstallerError.activationFailed("安装后的会话自检未返回成功结果。")
            }
        } catch {
            throw InstallerError.activationFailed(error.localizedDescription)
        }
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
    private static func currentSourceID() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let ref = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return unsafeBitCast(ref, to: CFString.self) as String
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

    static let inputMethodID = "im.owltype.inputmethod.Owltype"
    static let primaryModeID = "im.owltype.inputmethod.Owltype.Hans"

    /// 唯一需要 root 的一步：把内嵌 Owltype.app 事务替换到 /Library/Input Methods/。
    private static func privilegedReplace(fromAppPath sourcePath: String) throws {
        let executable = shellQuote(sourcePath + "/Contents/MacOS/Owltype")
        try runPrivileged("\(executable) --commit-install \(shellQuote(sourcePath))")
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

    /// Run a checked CLI command; drain stdout before waiting to avoid pipe deadlock.
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
