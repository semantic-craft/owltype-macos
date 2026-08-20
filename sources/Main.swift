//
//  Main.swift
//  Owltype
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit
import os

/// File-system boundary for user-authored input data. macOS normally protects the user's home
/// directory, but Owltype also makes its own data root private so clipboard history, prompts,
/// project terms, provider metadata, and Rime learning data are not world-readable if parent
/// directory permissions are relaxed.
enum OwlPrivateStorage {
  static func prepareDirectory(_ url: URL, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  static func hardenFile(_ url: URL, fileManager: FileManager = .default) throws {
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

enum OwlRimeIdentity {
  static let appName = "rime.owltype"
  static let builderAppName = "rime.owltype-builder"
  static let baseConfig = "owltype"
  static let configFile = "owltype.yaml"
  static let customConfigFile = "owltype.custom.yaml"
  static let legacyCustomConfigFile = "squirrel.custom.yaml"
  static let seedMarkerFile = ".owl-seed-v2"
}

@main
struct OwlApp {
  private static var inputMethodServer: IMKServer?

  // Robust ~/Library detection (getpwuid first, FileManager fallback).
  private static let libraryDir: URL = if let pwuid = getpwuid(getuid()) {
    URL(fileURLWithFileSystemRepresentation: pwuid.pointee.pw_dir, isDirectory: true, relativeTo: nil)
      .appending(component: "Library", directoryHint: .isDirectory)
  } else {
    try! FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
  }
  // ADR-0004: Owltype is self-contained — its Rime user_data_dir is its OWN directory,
  // NOT the shared ~/Library/Rime. This keeps Owltype isolated from the user's existing
  // Coexists with the user's other Rime input methods without clobbering them.
  private static let defaultUserDir = libraryDir.appending(components: "Application Support", "Owltype", directoryHint: .isDirectory)
  static var userDir: URL {
    if let override = ProcessInfo.processInfo.environment["OWL_TEST_USER_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return defaultUserDir
  }
  /// 改名工程 P4 的迁移源：上一代品牌的数据根，与 `defaultUserDir` 同父（目录名由
  /// `OwlLegacyDataMigration.legacyDirectoryName` 持有 —— 旧标识字面量只许住在那一个文件里）。
  /// `OWL_TEST_USER_DIR` 覆盖数据根时返回 nil —— 开发 / 测试沙箱里不该搬真实旧数据
  /// （见 `OwlLegacyDataMigration.runIfNeeded`）。
  static var legacyUserDir: URL? {
    if let override = ProcessInfo.processInfo.environment["OWL_TEST_USER_DIR"], !override.isEmpty {
      return nil
    }
    return defaultUserDir
      .deletingLastPathComponent()
      .appendingPathComponent(OwlLegacyDataMigration.legacyDirectoryName, isDirectory: true)
  }
  // Register the bundle that is actually running: dev and pkg installs live in different roots.
  static let appDir = Bundle.main.bundleURL
  static var logDir: URL {
    if let override = ProcessInfo.processInfo.environment["OWL_TEST_LOG_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.temporaryDirectory.appending(component: "rime.owltype", directoryHint: .isDirectory)
  }

  fileprivate static var isRunningUnitTests: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCTestConfigurationFilePath"] != nil ||
      env["XCInjectBundle"] != nil ||
      env["XCInjectBundleInto"] != nil
  }

  fileprivate static var isShowingSettingsForUITests: Bool {
    CommandLine.arguments.contains("--ui-test-show-settings")
  }

  /// Builder traits for `--build`. Must carry the SAME directory triple as the main launch
  /// path (setupRime): librime resolves every unset directory trait against the process cwd,
  /// so an app_name-only traits struct made `Owltype --build` scatter installation.yaml + build/
  /// into whatever directory it was run from while the real user dir stayed unbuilt (2026-07-24).
  static func makeBuilderTraits() -> RimeTraits {
    var builderTraits = RimeTraits.rimeStructInit()
    builderTraits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
    builderTraits.setCString(userDir.path, to: \.user_data_dir)
    builderTraits.setCString(logDir.path, to: \.log_dir)
    builderTraits.setCString(OwlRimeIdentity.builderAppName, to: \.app_name)
    return builderTraits
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func main() {
    let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee

    let handled = autoreleasepool {
      let installer = OwlInstaller()
      let args = CommandLine.arguments
      if args.count > 1 {
        switch args[1] {
        case "--quit":
          let bundleId = Bundle.main.bundleIdentifier!
          let runningOwltypeApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
          runningOwltypeApps.forEach { $0.terminate() }
          return true
        case "--reload":
          // deliverImmediately（2026-07-24 静默 reload 根因）：NSApplication 在 app 激活过又失活后
          // （任何一次设置/引导窗口访问）自动挂起本进程的分布式通知投递；默认 post 会被 coalesce
          // 进挂起队列，而后台 IME 永远不会再激活去冲队列——通知就静默丢失（librime 侧因此零日志）。
          // deliverImmediately 无视挂起态直接送达所有 observer。下面各 CLI post 同理。
          DistributedNotificationCenter.default().postNotificationName(.init("OwlReloadNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          return true
        case "--apply-keyboard-patch":
          do {
            let written = try OwlManagedKeyboardPatchPlan.apply(snapshot: OwlKeyboardSnapshot.current())
            print("Applied Owltype managed keyboard patch: \(written.joined(separator: ", "))")
            DistributedNotificationCenter.default().postNotificationName(.init("OwlReloadNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          } catch {
            fputs("Failed to apply Owltype managed keyboard patch: \(error)\n", stderr)
            exit(1)
          }
          return true
        case "--register-input-source", "--install":
          installer.register()
          return true
        case "--enable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { OwlInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.enable(modes: modes)
              return true
            }
          }
          installer.enable()
          return true
        case "--activate-once":
          print("Owltype: repair registration and refresh input menu agents.")
          installer.repairRegistrationForInstalledBundle()
          return true
        case "--disable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { OwlInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.disable(modes: modes)
              return true
            }
          }
          installer.disable()
          return true
        case "--select-input-source":
          if args.count > 2 {
            // 猫头鹰自家模式走原路径；其它一律按任意系统输入源 id 精确匹配选择（如
            // com.apple.keylayout.ABC —— postinstall 更新序列在 kill 旧进程前切出用）。
            switch OwlInstaller.selectTarget(for: args[2]) {
            case .owlMode(let mode):
              installer.select(mode: mode)
            case .systemSource(let sourceID):
              installer.select(sourceID: sourceID)
            }
          } else {
            installer.select()
          }
          return true
        case "--current-input-source":
          // postinstall 更新序列用：打印当前系统输入源 id（只读 TIS，不改任何状态），供探测
          // 「更新前猫头鹰是否是当前输入法」（输出以 im.owltype.inputmethod.Owltype 开头即是）。
          print(OwlInstaller.currentInputSourceID() ?? "")
          return true
        case "--detect-activation":
          // S1/R5: detect the "selected-but-not-truly-enabled" dead half-state and print
          // copyable System Settings recovery guidance. Safe to call from postinstall.
          let diagnosis = installer.detectAndGuideIfHalfState()
          if !diagnosis.brokenHalfState {
            print(OwlInstaller.activationStatusText())
          }
          return true
        case "--diagnose-rime-config":
          // 07-07-schema-consistency-guard: read-only schema-consistency diagnosis as JSON — prefs ↔
          // running-bundle seed ↔ user build/ ↔ user schema_list ↔ default.yaml shadow, plus a
          // ~/Library/Rime advisory (系统 Rime 目录，猫头鹰不读它) + OWL-SCHEMA-* codes. Never mutates
          // config. Honours OWL_TEST_USER_DIR so it can be pointed at a drift sample.
          let rimeConfigEncoder = JSONEncoder()
          rimeConfigEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          if let data = try? rimeConfigEncoder.encode(OwlRimeConfigDiagnostics.buildReport()),
             let json = String(data: data, encoding: .utf8) {
            print(json)
          }
          return true
        case "--diagnose-tis":
          // W1.4: read-only six-layer TIS diagnosis as JSON (register/enumerate/enable/select/menu/
          // client-attach + OWL-* codes + install identity + data-root + who else claims the
          // bundle id). Fresh process ⇒ Law 4.
          // Never mutates any input-source state. Consumed by check-installed.sh / live smoke.
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          if let data = try? encoder.encode(OwlTISDiagnostics.buildReport()),
             let json = String(data: data, encoding: .utf8) {
            print(json)
          }
          return true
        case "--build":
          // Notification
          OwlApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_update", comment: ""))
          // Build all schemas into Owltype's own data root — never the process cwd (see makeBuilderTraits).
          // P4 迁移必须先于建目录：它的触发条件是「新目录还不存在」，先 prepareDirectory 就把
          // 门关死了。postinstall 不走 --build，但开发者手跑一次就会永久锁掉迁移，故此处也挂。
          OwlLegacyDataMigration.runIfNeeded()
          try? OwlPrivateStorage.prepareDirectory(userDir)
          try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
          var builderTraits = makeBuilderTraits()
          rimeAPI.setup(&builderTraits)
          rimeAPI.deployer_initialize(nil)
          _ = rimeAPI.deploy()
          return true
        case "--sync":
          DistributedNotificationCenter.default().postNotificationName(.init("OwlSyncNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          return true
        case "--ascii":
          DistributedNotificationCenter.default().postNotificationName(.init("OwlToggleASCIIModeNotification"), object: "ascii", userInfo: nil, deliverImmediately: true)
          return true
        case "--nascii":
          DistributedNotificationCenter.default().postNotificationName(.init("OwlToggleASCIIModeNotification"), object: "nascii", userInfo: nil, deliverImmediately: true)
          return true
        case "--getascii":
          var responseReceived = false
          var asciiStatus = ""
          let observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("OwlASCIIModeResponse"),
            object: nil,
            queue: .main
          ) { notification in
            if let status = notification.object as? String {
              asciiStatus = status
              responseReceived = true
            }
          }
          DistributedNotificationCenter.default().postNotificationName(.init("OwlGetASCIIModeNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          let timeout = Date().addingTimeInterval(2.0)
          while !responseReceived && Date() < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
          }
          DistributedNotificationCenter.default().removeObserver(observer)
          if responseReceived {
            print(asciiStatus)
          } else {
            print("nascii")
          }
          return true
        case "--help":
          print(helpDoc)
          return true
        default:
          break
        }
      }
      return false
    }
    if handled {
      return
    }

    autoreleasepool {
      // ponytail: dev perf埋点 — cold-start baseline. Read via `log stream` (see OwlPerf).
      let perfColdStart = OwlPerf.mark()
      let runningUnitTests = isRunningUnitTests
      let uiTestSettings = isShowingSettingsForUITests
      // find the bundle identifier and then initialize the input method server
      let main = Bundle.main
      if !runningUnitTests {
        let connectionName = main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String
        inputMethodServer = IMKServer(name: connectionName, bundleIdentifier: main.bundleIdentifier!)
      }
      // load the bundle explicitly because in this case the input method is a
      // background only application
      let app = NSApplication.shared
      let delegate = OwlApplicationDelegate()
      delegate.suppressOnboarding = uiTestSettings
      app.delegate = delegate
      app.setActivationPolicy(uiTestSettings ? .regular : .accessory)

      // opencc will be configured with relative dictionary paths
      FileManager.default.changeCurrentDirectoryPath(main.sharedSupportPath!)

      if runningUnitTests || uiTestSettings {
        print("Owltype test host: skipping IMK/Rime startup.")
      } else if NSApp.owlAppDelegate.problematicLaunchDetected() {
        print("Problematic launch detected!")
        let args = ["Problematic launch detected! Owltype may be suffering a crash due to improper configuration. Revert previous modifications to see if the problem recurs."]
        let task = Process()
        task.executableURL = "/usr/bin/say".withCString { dir in
          URL(fileURLWithFileSystemRepresentation: dir, isDirectory: false, relativeTo: nil)
        }
        task.arguments = args
        try? task.run()
      } else {
        let perfRime = OwlPerf.mark()
        NSApp.owlAppDelegate.setupRime()
        NSApp.owlAppDelegate.startRime(fullCheck: false)
        OwlPerf.since(perfRime, "coldstart.rime")  // heavy: start_maintenance — dict + octagram load
        NSApp.owlAppDelegate.loadSettings()
        // 方案B：公开包只带清洁室词库种子；完整词库在用户知情同意后按 pin 拉取（不阻塞冷启动，
        // 下载完成后自动 deploy() 编译）。已装 / 用户自备 / 已提示过时这里只刷新状态。
        OwlDictPackCenter.shared.promptOrFetchIfNeeded()
        OwlPerf.since(perfColdStart, "coldstart.total")
        // Activation belongs to the installer path. Public Sparkle updates are information-only and
        // send users to the standalone installer, so a plain app launch must not toggle TIS state.
        if CommandLine.arguments.contains("--activate-once") {
          NSApp.owlAppDelegate.selfHealActivationIfNeeded()
        }
        print("Owltype reporting!")
      }

      if uiTestSettings {
        DispatchQueue.main.async { delegate.showSettingsForUITest() }
      }

      // finally run everything
      app.run()
      print("Owltype is quitting...")
      if !runningUnitTests {
        rimeAPI.finalize()
      }
    }
    return
  }

  static let helpDoc = """
  Supported arguments:
  Perform actions:
    --quit                     quit all Owltype processes
    --reload                   deploy
    --apply-keyboard-patch     write Owltype managed keyboard patch, then request deploy
    --sync                     sync user data
    --build                    build all schemas into Owltype's user data dir
    --ascii                    turn on ASCII mode
    --nascii                   turn off ASCII mode
    --getascii                 get current ASCII mode status
  Install Owltype:
    --install, --register-input-source    register input source
    --enable-input-source [source id...]  input source list optional
    --activate-once                       repair install-time menu activation, then exit
    --disable-input-source [source id...] input source list optional
    --select-input-source [source id]     input source optional; also accepts any system
                                          input source id (e.g. com.apple.keylayout.ABC)
    --current-input-source                print the current system input source id
    --detect-activation                   diagnose selected-but-not-enabled dead half-state
    --diagnose-tis                        print read-only six-layer TIS activation diagnosis (JSON)
    --diagnose-rime-config                print read-only schema-consistency diagnosis (JSON)
    --ui-test-show-settings               open settings without IMK/Rime startup
  """
}

// 测试隔离（2026-07-21）：TEST_HOST 让单测跑在 Owltype.app 进程里，OwlDefaults.standard 即真实
// 偏好域 ~/Library/Preferences/im.owltype.inputmethod.Owltype.plist——全量单测曾清掉云端开关/热键槽
// 等线上配置。Owltype 代码一律经 OwlDefaults.standard 访问偏好；测试进程（单测注入 /
// --ui-test-show-settings 启动）改写到独立 suite 并每次从空域开始，真实域零写入。
// Lives in Main.swift to avoid a project.pbxproj edit (same `Owltype` module, callable everywhere).
enum OwlDefaults {
  static let testSuiteName = "im.owltype.inputmethod.Owltype.tests"
  static var isRunningUnitTests: Bool { OwlApp.isRunningUnitTests }
  static let standard: UserDefaults = {
    guard OwlApp.isRunningUnitTests || OwlApp.isShowingSettingsForUITests else { return .standard }
    let defaults = UserDefaults(suiteName: testSuiteName)!
    defaults.removePersistentDomain(forName: testSuiteName)
    return defaults
  }()
}

// ponytail: dev-only perf埋点, NOT a product feature — delete when the baseline is captured.
// Lives in Main.swift to avoid a project.pbxproj edit (same `Owltype` module, callable everywhere).
// Read on the real machine (no Instruments needed):
//   log stream --predicate 'subsystem == "im.owltype.inputmethod.Owltype" && category == "perf"' --info
// RSS is measured externally (no code): ps -o rss= -p $(pgrep -xi owltype)   # KB
enum OwlPerf {
  static let log = Logger(subsystem: "im.owltype.inputmethod.Owltype", category: "perf")
  /// Monotonic start mark (nanoseconds).
  static func mark() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  /// Log elapsed milliseconds since `t0` under `label`.
  static func since(_ t0: UInt64, _ label: String) {
    let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
    log.info("\(label, privacy: .public): \(ms, format: .fixed(precision: 2), privacy: .public) ms")
  }
}
