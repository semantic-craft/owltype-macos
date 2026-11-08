// Installer — 安装、修复安装、清空修复与彻底卸载的全部副作用逻辑（无 UI）。
//
// 安全纪律（卸载与修复白名单，对齐 scripts/uninstall-owltype.sh 与 scripts/repair-owltype.sh）：
//   - 删除目标硬编码为猫头鹰自有路径，绝不触碰 Squirrel / ~/Library/Rime / im.rime /
//     Sogou / 搜狗 / Weasel 等他人输入法。
//   - 用户目录下的清理一律由登录用户进程自身通过 FileManager 执行；
//     只有 /Library/Input Methods 与 /private/var/db 下的系统级路径才走提权。

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
    private static let systemInputMethodsDir = "/Library/Input Methods"
    private static let installerStatePath = "/private/var/db/im.owltype.inputmethod.Owltype-installer"
    private static let expectedBundleID = "im.owltype.inputmethod.Owltype"
    private static let expectedTeamID = "LQAVR62TK2"
    private static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    struct AppMetadata: Equatable {
        let bundleID: String
        let shortVersion: String
        let buildVersion: String
    }

    static let inputMethodID = "im.owltype.inputmethod.Owltype"
    static let primaryModeID = "im.owltype.inputmethod.Owltype.Hans"
    private static let allSourceIDs = [
        "im.owltype.inputmethod.Owltype",
        "im.owltype.inputmethod.Owltype.Hans",
        "im.owltype.inputmethod.Owltype.Hant",
    ]

    static func embeddedOwltypeAppURL() -> URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Owltype.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func inspectPreflight() -> InstallerActivationPolicy.PreflightReport {
        let embedded = embeddedOwltypeAppURL().flatMap { try? appMetadata(at: $0) }
        let installedURL = URL(fileURLWithPath: installedAppPath)
        let installed = (try? appMetadata(at: installedURL)).flatMap {
            $0.bundleID == expectedBundleID ? $0 : nil
        }
        let strayCount = strayCopies().count
        let extraClaims = nonCanonicalLaunchServicesClaims().count
        return InstallerActivationPolicy.PreflightReport(
            installedShortVersion: installed?.shortVersion,
            installedBuildVersion: installed?.buildVersion,
            embeddedShortVersion: embedded?.shortVersion,
            embeddedBuildVersion: embedded?.buildVersion,
            strayCopyCount: strayCount,
            extraLaunchServicesClaimCount: extraClaims)
    }

    static func install() throws -> (plan: InstallerActivationPolicy.ActivationPlan,
                                     status: InstallerActivationPolicy.SessionStatus) {
        guard let embedded = embeddedOwltypeAppURL() else {
            throw InstallerError.embeddedAppNotFound
        }
        let payload = try validatePayload(at: embedded)

        let bundlePreexisted = FileManager.default.fileExists(atPath: installedAppPath + "/Contents/Info.plist")
        let wasRunning = owltypeProcessIsRunning()
        let sourceBefore = DispatchQueue.main.sync { currentSourceID() }
        let plan = InstallerActivationPolicy.plan(
            bundlePreexisted: bundlePreexisted, owltypeProcessWasRunning: wasRunning,
            owltypeWasCurrentSource: sourceBefore.hasPrefix(inputMethodID + "."))
        try rejectForeignBundleAtInstallPath()

        try removeUserStrayCopies()
        unregisterNonCanonicalLaunchServicesClaims()

        try privilegedReplace(fromAppPath: embedded.path)
        try validateInstalledApp(expected: payload)
        let status = try runFinishInstall(
            firstInstall: plan.enableParentAndPrimaryModeOnce,
            sourceBefore: sourceBefore,
            buildVersion: payload.buildVersion)
        return (plan, status)
    }

    static func repairInstall() throws -> InstallerActivationPolicy.SessionStatus {
        guard let embedded = embeddedOwltypeAppURL() else {
            throw InstallerError.embeddedAppNotFound
        }
        let payload = try validatePayload(at: embedded)
        try rejectForeignBundleAtInstallPath()

        let sourceBefore = DispatchQueue.main.sync { currentSourceID() }
        let installedExecutable = installedAppPath + "/Contents/MacOS/Owltype"
        if sourceBefore.hasPrefix(inputMethodID),
           FileManager.default.isExecutableFile(atPath: installedExecutable) {
            try? parkCurrentSource(usingOwltypeApp: URL(fileURLWithPath: installedAppPath))
        }
        disableAllOwltypeTIS()
        stopAllOwltypeProcesses()

        try removeUserStrayCopies()
        try clearUserCachesAndSelfCheckRecord()
        unregisterNonCanonicalLaunchServicesClaims()
        purgeIntlDataCaches()

        try privilegedReplaceAndCleanSystemLeftovers(fromAppPath: embedded.path)
        try validateInstalledApp(expected: payload)
        let restoreSource = sourceBefore.hasPrefix(inputMethodID + ".") ? sourceBefore : primaryModeID
        return try runFinishInstall(
            firstInstall: true,
            sourceBefore: restoreSource,
            buildVersion: payload.buildVersion)
    }

    static func clearAndRepair() throws {
        let installedURL = URL(fileURLWithPath: installedAppPath)
        let installedExecutable = installedAppPath + "/Contents/MacOS/Owltype"
        let hasValidInstalled = (try? appMetadata(at: installedURL))?.bundleID == expectedBundleID
            && FileManager.default.isExecutableFile(atPath: installedExecutable)
        if !hasValidInstalled {
            if embeddedOwltypeAppURL() != nil {
                _ = try repairInstall()
                return
            }
            throw InstallerError.validationFailed("本机尚未安装猫头鹰输入法，请点击「立即安装」。")
        }

        let sourceBefore = DispatchQueue.main.sync { currentSourceID() }
        if sourceBefore.hasPrefix(inputMethodID) {
            try? parkCurrentSource(usingOwltypeApp: installedURL)
        }
        _ = try? runProcess(installedExecutable, ["--disable-input-source"])
        disableAllOwltypeTIS()
        stopAllOwltypeProcesses()

        try removeUserStrayCopies()
        try clearUserCachesAndSelfCheckRecord()

        let systemStrays = systemStrayCopies()
        if !systemStrays.isEmpty {
            let quoted = systemStrays.map { shellQuote($0.path) }.joined(separator: " ")
            try runPrivileged("rm -rf \(quoted)")
        }

        unregisterNonCanonicalLaunchServicesClaims()
        forceRegisterCanonicalBundle()
        purgeIntlDataCaches()

        _ = try? runProcess(installedExecutable, ["--install-session-enable"])
        _ = try? runProcess(installedExecutable, ["--activate-once"])
        refreshInputMenuAgents()
        _ = try? runProcess("/usr/bin/open", ["-g", installedAppPath])
        let targetSource = sourceBefore.hasPrefix(inputMethodID + ".") ? sourceBefore : primaryModeID
        _ = try? runProcess(installedExecutable, ["--select-input-source", targetSource])
    }

    static func uninstall() throws {
        try uninstall(keepUserData: false)
    }

    static func uninstall(keepUserData: Bool) throws {
        let fileManager = FileManager.default

        let installedExecutable = installedAppPath + "/Contents/MacOS/Owltype"
        if fileManager.isExecutableFile(atPath: installedExecutable) {
            let current = (try? runProcess(installedExecutable, ["--current-input-source"])) ?? ""
            if current.hasPrefix(inputMethodID) {
                try? parkCurrentSource(usingOwltypeApp: URL(fileURLWithPath: installedAppPath))
            }
            _ = try? runProcess(installedExecutable, ["--disable-input-source"])
            _ = try? runProcess(installedExecutable, ["--quit"])
        }
        disableAllOwltypeTIS()
        stopAllOwltypeProcesses()
        unregisterAllLaunchServicesClaims()

        for url in userLevelTargets(keepUserData: keepUserData) where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try removeUserStrayCopies()
        clearSelfCheckFailureRecord()
        purgeIntlDataCaches()

        let systemStrays = systemStrayCopies()
        let receiptExists = (try? runProcess(
            "/usr/sbin/pkgutil", ["--pkg-info", expectedBundleID])) != nil
        if fileManager.fileExists(atPath: installedAppPath)
            || fileManager.fileExists(atPath: installerStatePath)
            || !systemStrays.isEmpty
            || receiptExists {
            var targets = [shellQuote(installedAppPath), shellQuote(installerStatePath)]
            targets.append(contentsOf: systemStrays.map { shellQuote($0.path) })
            var command = "rm -rf " + targets.joined(separator: " ")
            if receiptExists {
                command += " && /usr/sbin/pkgutil --forget im.owltype.inputmethod.Owltype >/dev/null"
            }
            try runPrivileged(command)
        }

        refreshInputMenuAgents()
    }

    static func activateAndOpenSettings() {
        let installedExecutable = installedAppPath + "/Contents/MacOS/Owltype"
        forceRegisterCanonicalBundle()
        if FileManager.default.isExecutableFile(atPath: installedExecutable) {
            _ = try? runProcess(installedExecutable, ["--install-session-enable"])
            _ = try? runProcess(installedExecutable, ["--enable-input-source"])
            _ = try? runProcess("/usr/bin/open", ["-g", installedAppPath])
            _ = try? runProcess(installedExecutable, ["--select-input-source", primaryModeID])
        }
        refreshInputMenuAgents()
        DistributedNotificationCenter.default().postNotificationName(
            .init("OwlShowSettingsNotification"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
    }

    static func openSystemKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func runFinishInstall(
        firstInstall: Bool,
        sourceBefore: String,
        buildVersion: String
    ) throws -> InstallerActivationPolicy.SessionStatus {
        let executable = installedAppPath + "/Contents/MacOS/Owltype"
        do {
            let output = try runProcess(executable, [
                "--finish-install", firstInstall ? "first" : "update",
                sourceBefore, buildVersion,
            ])
            if let status = InstallerActivationPolicy.parseFinishInstallStatus(output) {
                return status
            }
            return .deferred
        } catch {
            fallbackRefreshAndLaunchInstalledApp()
            return .deferred
        }
    }

    private static func fallbackRefreshAndLaunchInstalledApp() {
        forceRegisterCanonicalBundle()
        purgeIntlDataCaches()
        refreshInputMenuAgents()
        _ = try? runProcess("/usr/bin/open", ["-g", installedAppPath])
    }

    private static func disableAllOwltypeTIS() {
        let work = {
            guard let cfList = TISCreateInputSourceList(nil, true)?.takeRetainedValue(),
                  let list = cfList as? [TISInputSource] else {
                return
            }
            for source in list {
                guard let ref = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
                let id = unsafeBitCast(ref, to: CFString.self) as String
                guard id == inputMethodID || id.hasPrefix(inputMethodID + ".") || allSourceIDs.contains(id) else {
                    continue
                }
                _ = TISDeselectInputSource(source)
                _ = TISDisableInputSource(source)
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private static func stopAllOwltypeProcesses() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: expectedBundleID)
        where !app.isTerminated {
            _ = app.terminate()
        }
        terminateUserProcess(named: "Owltype", force: false)
        for _ in 0..<10 {
            if !owltypeProcessIsRunning() { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: expectedBundleID)
        where !app.isTerminated {
            _ = app.forceTerminate()
        }
        terminateUserProcess(named: "Owltype", force: true)
    }

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

    private static func currentSourceID() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let ref = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return unsafeBitCast(ref, to: CFString.self) as String
    }

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

    // MARK: - 杂散副本、LaunchServices 与输入法列表缓存清理

    private static func strayCopies() -> [URL] {
        userStrayCopies() + systemStrayCopies()
    }

    private static func userStrayCopies() -> [URL] {
        let userIMDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
        return strayCopies(in: userIMDir, excludingCanonicalPath: nil)
    }

    private static func systemStrayCopies() -> [URL] {
        let sysIMDir = URL(fileURLWithPath: systemInputMethodsDir, isDirectory: true)
        return strayCopies(in: sysIMDir, excludingCanonicalPath: installedAppPath)
    }

    private static func strayCopies(in directory: URL, excludingCanonicalPath canonical: String?) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return [] }
        return entries.filter { url in
            let path = url.standardizedFileURL.path
            if let canonical, path == URL(fileURLWithPath: canonical).standardizedFileURL.path {
                return false
            }
            let name = url.lastPathComponent
            guard !isForbiddenForeignPath(path) else { return false }
            if name.hasPrefix(".Owltype.") {
                return true
            }
            if url.pathExtension == "app",
               let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
               info["CFBundleIdentifier"] as? String == expectedBundleID {
                return true
            }
            return false
        }
    }

    private static func isForbiddenForeignPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("squirrel")
            || lower.contains("/library/rime")
            || lower.contains("im.rime")
            || lower.contains("sogou")
            || path.contains("搜狗")
            || lower.contains("weasel")
    }

    private static func removeUserStrayCopies() throws {
        let fileManager = FileManager.default
        for url in userStrayCopies() where fileManager.fileExists(atPath: url.path) {
            guard !isForbiddenForeignPath(url.path) else { continue }
            if FileManager.default.isExecutableFile(atPath: lsregisterPath) {
                _ = try? runProcess(lsregisterPath, ["-u", url.path])
            }
            try fileManager.removeItem(at: url)
        }
    }

    private static func clearUserCachesAndSelfCheckRecord() throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let cacheTargets = [
            home.appendingPathComponent("Library/Caches/im.owltype.inputmethod.Owltype"),
            home.appendingPathComponent("Library/HTTPStorages/im.owltype.inputmethod.Owltype"),
        ]
        for url in cacheTargets where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        clearSelfCheckFailureRecord()
    }

    private static func clearSelfCheckFailureRecord() {
        if let defaults = UserDefaults(suiteName: expectedBundleID) {
            defaults.removeObject(forKey: "OwlInstallSelfCheckFailedVersion")
            defaults.removeObject(forKey: "OwlInstallSelfCheckDiagnosis")
            defaults.synchronize()
        }
    }

    private static func nonCanonicalLaunchServicesClaims() -> [URL] {
        let canonical = URL(fileURLWithPath: installedAppPath).standardizedFileURL.path
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: expectedBundleID)
            .filter { $0.standardizedFileURL.path != canonical && !isForbiddenForeignPath($0.path) }
    }

    private static func unregisterNonCanonicalLaunchServicesClaims() {
        guard FileManager.default.isExecutableFile(atPath: lsregisterPath) else { return }
        for url in nonCanonicalLaunchServicesClaims() {
            _ = try? runProcess(lsregisterPath, ["-u", url.standardizedFileURL.path])
        }
    }

    private static func unregisterAllLaunchServicesClaims() {
        guard FileManager.default.isExecutableFile(atPath: lsregisterPath) else { return }
        var paths = Set(NSWorkspace.shared.urlsForApplications(withBundleIdentifier: expectedBundleID)
            .map { $0.standardizedFileURL.path })
        paths.insert(installedAppPath)
        for url in strayCopies() {
            paths.insert(url.standardizedFileURL.path)
        }
        for path in paths where !isForbiddenForeignPath(path) {
            _ = try? runProcess(lsregisterPath, ["-u", path])
        }
    }

    private static func forceRegisterCanonicalBundle() {
        guard FileManager.default.isExecutableFile(atPath: lsregisterPath),
              FileManager.default.fileExists(atPath: installedAppPath) else { return }
        _ = try? runProcess(lsregisterPath, ["-f", installedAppPath])
    }

    private static func purgeIntlDataCaches() {
        terminateUserProcess(named: "System Settings", force: false)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return }
        let cacheRoot = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        let marker = Data(expectedBundleID.utf8)
        guard let enumerator = FileManager.default.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let fileURL as URL in enumerator {
            if enumerator.level > 2 {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.lastPathComponent.hasPrefix("com.apple.IntlDataCache.le"),
                  let data = try? Data(contentsOf: fileURL),
                  data.range(of: marker) != nil,
                  FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                continue
            }
        }
    }

    private static func refreshInputMenuAgents() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-9", "TextInputMenuAgent", "TextInputSwitcher", "CursorUIViewService"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 安装包校验

    private static func validatePayload(at url: URL) throws -> AppMetadata {
        let metadata = try appMetadata(at: url)
        guard metadata.bundleID == expectedBundleID else {
            throw InstallerError.validationFailed("bundle id 应为 \(expectedBundleID)，实际为 \(metadata.bundleID)")
        }
        guard InstallerActivationPolicy.parseVersionComponents(metadata.shortVersion) != nil else {
            throw InstallerError.validationFailed("CFBundleShortVersionString 不是可比较版本号：\(metadata.shortVersion)")
        }
        guard InstallerActivationPolicy.parseVersionComponents(metadata.buildVersion) != nil else {
            throw InstallerError.validationFailed("CFBundleVersion 不是可比较版本号：\(metadata.buildVersion)")
        }
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

    private static func rejectForeignBundleAtInstallPath() throws {
        let installedURL = URL(fileURLWithPath: installedAppPath)
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return }
        if let installed = try? appMetadata(at: installedURL),
           !installed.bundleID.isEmpty,
           installed.bundleID != expectedBundleID {
            throw InstallerError.validationFailed("目标路径已有非 Owltype bundle：\(installed.bundleID)")
        }
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

    private static func privilegedReplace(fromAppPath sourcePath: String) throws {
        let executable = shellQuote(sourcePath + "/Contents/MacOS/Owltype")
        try runPrivileged("\(executable) --commit-install \(shellQuote(sourcePath))")
    }

    private static func privilegedReplaceAndCleanSystemLeftovers(fromAppPath sourcePath: String) throws {
        let executable = shellQuote(sourcePath + "/Contents/MacOS/Owltype")
        let systemStrays = systemStrayCopies()
        var command = "\(executable) --commit-install \(shellQuote(sourcePath))"
        if !systemStrays.isEmpty {
            let quoted = systemStrays.map { shellQuote($0.path) }.joined(separator: " ")
            command = "rm -rf \(quoted) && " + command
        }
        try runPrivileged(command)
    }

    /// 用户级删除白名单：全部是猫头鹰自有路径（绝不含他人输入法 / Rime）。
    private static func userLevelTargets(keepUserData: Bool) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var targets = [
            home.appendingPathComponent("Library/Caches/im.owltype.inputmethod.Owltype"),
            home.appendingPathComponent("Library/HTTPStorages/im.owltype.inputmethod.Owltype"),
            home.appendingPathComponent("Library/Logs/Owltype"),
        ]
        if !keepUserData {
            targets.insert(home.appendingPathComponent("Library/Application Support/Owltype"), at: 0)
            targets.append(home.appendingPathComponent("Library/Preferences/im.owltype.inputmethod.Owltype.plist"))
        }
        return targets
    }

    private static func terminateUserProcess(named name: String, force: Bool = false) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = force ? ["-9", name] : [name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 提权执行（NSAppleScript do-shell-script）

    private static func runPrivileged(_ command: String) throws {
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
            if code == -128 {
                throw InstallerError.userCancelled
            }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "未知错误（\(code)）"
            throw InstallerError.privilegedCommandFailed(message)
        }
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw InstallerError.validationFailed(output.isEmpty ? "\(executable) 失败" : output)
        }
        return output
    }
}
