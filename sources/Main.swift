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
  fileprivate static let defaultUserDir = libraryDir.appending(components: "Application Support", "Owltype", directoryHint: .isDirectory)
  static var userDir: URL {
    OwlTestStorage.directory(override: "OWL_TEST_USER_DIR", child: "data", production: defaultUserDir)
  }
  // Register the bundle that is actually running: dev and pkg installs live in different roots.
  static let appDir = Bundle.main.bundleURL
  static var logDir: URL {
    OwlTestStorage.directory(override: "OWL_TEST_LOG_DIR", child: "logs", production:
      FileManager.default.temporaryDirectory.appending(component: "rime.owltype", directoryHint: .isDirectory))
  }

  fileprivate static var isRunningUnitTests: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCTestConfigurationFilePath"] != nil ||
      env["XCInjectBundle"] != nil ||
      env["XCInjectBundleInto"] != nil
  }

  static var isShowingSettingsForUITests: Bool {
    CommandLine.arguments.contains("--ui-test-show-settings")
  }

  /// The IMK endpoint (`InputMethodConnectionName`) is first-come-first-served per login session.
  /// A build-directory copy launched directly (Xcode Run, `open build/.../Owltype.app`) used to
  /// claim it while the installed copy was restarting; the installed input method then failed
  /// registration (`Operation not permitted`) and never received a key until the squatter quit
  /// (2026-09-27: 73 minutes with no candidate window). Only a bundle that sits directly in an
  /// Input Methods folder may serve IMK or start Rime against the real user data.
  static func isInstalledInputMethodBundle(_ bundleURL: URL, libraryDir: URL = libraryDir) -> Bool {
    let parent = bundleURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path
    let roots = [URL(fileURLWithPath: "/Library", isDirectory: true), libraryDir].map {
      $0.appending(component: "Input Methods", directoryHint: .isDirectory)
        .resolvingSymlinksInPath().standardizedFileURL.path
    }
    return roots.contains(parent)
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func main() {
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
          // 进挂起队列，而后台 IME 永远不会再激活去冲队列——通知就静默丢失（引擎侧因此零日志）。
          // deliverImmediately 无视挂起态直接送达所有 observer。下面各 CLI post 同理。
          DistributedNotificationCenter.default().postNotificationName(.init("OwlReloadNotification"), object: nil, userInfo: nil, deliverImmediately: true)
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
        case "--commit-install":
          do {
            guard args.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
            try OwlInstallFiles.commit(source: URL(fileURLWithPath: args[2]))
          } catch {
            fputs("INSTALL_FILES_FAILED: \(error)\n", stderr)
            exit(1)
          }
          return true
        case "--finish-install":
          do {
            guard args.count == 5, args[2] == "first" || args[2] == "update" else {
              throw OwlSessionRestart.Failure.missingContext
            }
            try OwlInstallSession.finish(firstInstall: args[2] == "first", sourceBefore: args[3], version: args[4])
          } catch {
            fputs("INSTALL_SESSION_FAILED: \(error)\n", stderr)
            // #207: the stage, the error and what the last probe saw, for install.log and the GUI.
            if let failure = error as? OwlInstallSession.SessionFailure {
              fputs("INSTALL_SESSION_DIAGNOSIS: \(failure.diagnosis.summary)\n", stderr)
            }
            exit(1)
          }
          return true
        case "--install-session-enable":
          do { try OwlInstallSession.enableForFirstInstall() } catch {
            fputs("INSTALL_ENABLE_FAILED: \(error)\n", stderr)
            exit(1)
          }
          return true
        case "--install-session-probe":
          do {
            guard args.count == 4, let excludedPID = Int32(args[2]) else {
              throw OwlSessionRestart.Failure.missingContext
            }
            print(try OwlInstallSession.probe(excluding: excludedPID, mode: args[3]))
          } catch {
            fputs("INSTALL_PROBE_FAILED: \(error)\n", stderr)
            exit(1)
          }
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
            // 法墨自家模式走原路径；其它一律按任意系统输入源 id 精确匹配选择（如
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
          // 「更新前法墨是否是当前输入法」（输出以 im.owltype.inputmethod.Owltype 开头即是）。
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
      if !runningUnitTests && !uiTestSettings && !isInstalledInputMethodBundle(main.bundleURL) {
        let message = "Owltype: refusing to run as an input method from \(main.bundlePath) — only copies in "
          + "/Library/Input Methods or ~/Library/Input Methods may claim the IMK connection. Install with "
          + "scripts/install-dev.sh; use --ui-test-show-settings for the settings UI."
        print(message)
        Logger(subsystem: "im.owltype.inputmethod.Owltype", category: "launch").error("\(message, privacy: .public)")
        exit(EX_CONFIG)
      }
      if !runningUnitTests && !uiTestSettings {
        let connectionName = main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String
        inputMethodServer = IMKServer(name: connectionName, bundleIdentifier: main.bundleIdentifier!)
      }
      // load the bundle explicitly because in this case the input method is a
      // background only application
      let app = NSApplication.shared
      let delegate = OwlApplicationDelegate()
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
        let perfEngine = OwlPerf.mark()
        delegate.setupEngine()
        delegate.runtime.start(fullCheck: false)  // maintenance, then the config cache
        OwlPerf.since(perfEngine, "coldstart.rime")  // heavy: start_maintenance — dict + octagram load
        // Agent access (#208): listens only while its switch is on; off by default.
        OwlAgentAccess.shared.start()
        OwlPerf.since(perfColdStart, "coldstart.total")
        // Activation belongs to the installer path. Public Sparkle updates are information-only and
        // send users to the standalone installer, so a plain app launch must not toggle TIS state.
        if CommandLine.arguments.contains("--activate-once") {
          NSApp.owlAppDelegate.selfHealActivationIfNeeded()
        }
        print("Owltype reporting!")
      }

      if uiTestSettings {
        DispatchQueue.main.async { delegate.showSettings() }
      }

      // finally run everything
      app.run()
      print("Owltype is quitting...")
      if !runningUnitTests {
        _ = delegate.runtime.engine.finalize()
      }
    }
    return
  }

  static let helpDoc = """
  Supported arguments:
  Perform actions:
    --quit                     quit all Owltype processes
    --reload                   deploy
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
    --ui-test-show-settings               open settings without IMK/Rime startup
  """
}

/// Test data never falls back to the daily input method's files. Explicit roots belong to
/// the caller; only the fresh, process-owned fallback is removed on normal exit.
enum OwlTestStorage {
  static let isEnabled = OwlApp.isRunningUnitTests || OwlApp.isShowingSettingsForUITests
    || ProcessInfo.processInfo.environment.keys.contains("OWL_TEST_USER_DIR")
    || ProcessInfo.processInfo.environment.keys.contains("OWL_TEST_LOG_DIR")

  static let root: URL = {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwltypeAcceptance-\(UUID().uuidString)", isDirectory: true)
    do { try OwlPrivateStorage.prepareDirectory(directory) } catch {
      fatalError("Cannot create isolated Owltype test data: \(error)")
    }
    atexit { try? FileManager.default.removeItem(at: OwlTestStorage.root) }
    return directory
  }()

  static func directory(override key: String, child: String, production: URL) -> URL {
    guard isEnabled else { return production }
    if let path = ProcessInfo.processInfo.environment[key], !path.isEmpty {
      let candidate = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
      let protected = [production, OwlApp.defaultUserDir].map {
        $0.resolvingSymlinksInPath().standardizedFileURL.path
      }
      guard path.hasPrefix("/"), !protected.contains(where: { real in
        candidate.path == real || candidate.path.hasPrefix(real + "/") || real.hasPrefix(candidate.path + "/")
      }) else {
        fputs("Test data must not overlap production storage: \(key)\n", stderr)
        exit(EX_CONFIG)
      }
      return candidate
    }
    return root.appendingPathComponent(child, isDirectory: true)
  }
}

// 测试隔离（2026-07-21）：TEST_HOST 让单测跑在 Owltype.app 进程里，OwlDefaults.standard 即真实
// 偏好域 ~/Library/Preferences/im.owltype.inputmethod.Owltype.plist——全量单测曾清掉云端开关/热键槽
// 等线上配置。Owltype 代码一律经 OwlDefaults.standard 访问偏好；测试进程（单测注入 /
// --ui-test-show-settings 启动）改写到独立 suite 并每次从空域开始，真实域零写入。
// Lives in Main.swift to avoid a project.pbxproj edit (same `Owltype` module, callable everywhere).
enum OwlDefaults {
  static let testSuiteName = "im.owltype.inputmethod.Owltype.tests.\(UUID().uuidString)"
  static var isRunningUnitTests: Bool { OwlApp.isRunningUnitTests }
  static let standard: UserDefaults = {
    guard OwlTestStorage.isEnabled else { return .standard }
    let defaults = UserDefaults(suiteName: testSuiteName)!
    defaults.removePersistentDomain(forName: testSuiteName)
    // Concurrent worktrees and XCTest hosts must never overwrite one another.
    atexit {
      let testDefaults = UserDefaults(suiteName: OwlDefaults.testSuiteName)
      testDefaults?.removePersistentDomain(forName: OwlDefaults.testSuiteName)
      testDefaults?.synchronize()
      // CFPreferences can leave an empty plist after removing a domain.
      if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
        let file = library.appendingPathComponent("Preferences", isDirectory: true)
          .appendingPathComponent("\(OwlDefaults.testSuiteName).plist")
        try? FileManager.default.removeItem(at: file)
      }
    }
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
