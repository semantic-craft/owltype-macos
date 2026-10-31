//
//  OwlDictPackCenter.swift
//  Owltype
//
//  完整词库的生命周期（MainActor）：把随包 msime 资源复制成一个 Rust 资源代次（prepare）、
//  用户确认后启用（activate）、可回退到上一代（rollback），并决定首启是否需要征求同意
//  （needsPrompt）。只看 Rust 资源状态；旧版 Rime YAML 词库与其装机记录不参与任何判定，
//  也不会被读写。IO 在后台 Task 里经 `OwlDictPackCenterRustBackend` 做，本类只做状态机。
//
//  本文件承载提示线三个类型（同一功能、同居一处，对齐 OwlUpdateLogoutPrompt 的做法）：
//    - `OwlDictPackCenter`            状态机 + 资源代次编排
//    - `OwlDictPackPrompt`            纯判定 + 文案 + 呈现
//    - `OwlDictPackPromptScheduler`   首启安全时机门控（复用 OwlLogoutPromptTiming）
//

import AppKit
import CoreGraphics
import Observation
import os

struct OwlDictPackCenterRustBackend: Sendable {
  typealias Prepare = @Sendable (
    OwlRustResourceEnvironment,
    (@Sendable (Double) -> Void)?
  ) async throws -> OwlRustDictPackPreparedResources
  typealias Activate = @Sendable (
    OwlRustResourceEnvironment,
    OwlRustResourcePrepared
  ) async throws -> OwlRustResourceInstallResult
  typealias Rollback = @Sendable (
    OwlRustResourceEnvironment,
    OwlRustResourceInputKind
  ) async throws -> OwlRustResourceActiveState

  let environment: OwlRustResourceEnvironment
  let prepare: Prepare
  let activate: Activate
  let rollback: Rollback

  static func production(
    userRoot: URL = OwlApp.userDir,
    sharedSupport: URL? = Bundle.main.sharedSupportURL
  ) -> Self {
    let environment = OwlRustResourceEnvironment.production(userRoot: userRoot)
    return Self(
      environment: environment,
      prepare: { environment, progress in
        let store = try environment.makeStore()
        guard let sharedSupport else {
          throw OwlRustResourceError.invalidConfiguration("bundled resources unavailable")
        }
        let temporary = environment.packageRoot.deletingLastPathComponent()
          .appendingPathComponent("compatible-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try await store.prepareBundled(sharedSupport: sharedSupport, at: temporary, progress: progress)
      },
      activate: { environment, prepared in
        let store = try environment.makeStore()
        return try await store.activate(prepared)
      },
      rollback: { environment, inputKind in
        let store = try environment.makeStore()
        return try await store.rollback(inputKind: inputKind)
      }
    )
  }
}

typealias OwlDictPackLiveSessionRefresh = @MainActor (
  _ completion: @escaping @MainActor () -> Void
) -> Bool

@Observable
@MainActor
final class OwlDictPackCenter {
  static let shared = OwlDictPackCenter()

  private(set) var status: OwlDictPackStatus = .notInstalled
  private(set) var preparedCandidate: OwlDictPackCandidate?
  private(set) var rollbackTargetVersion: Int?
  /// The transaction is committed, but the active session is waiting for its current
  /// composition to finish before it can switch without dropping selected phrase progress.
  private(set) var isAwaitingLiveSessionRefresh = false

  private let core = try! OwlAppSession("resourceCenter")
  private let rustBackend: OwlDictPackCenterRustBackend
  private let liveSessionRefresh: OwlDictPackLiveSessionRefresh

  private struct Snapshot: Decodable {
    let action: String
    let phase: String
    let version: Int?
    let progress: Double
    let message: String
    let prepared: OwlRustDictPackPreparedResources?
    let rollback: Int?
    let awaiting: Bool
  }
  private func event(_ name: String, _ args: [String: Any] = [:]) -> Snapshot {
    let snapshot: Snapshot = core.call(name, args)
    preparedCandidate = snapshot.prepared.map(OwlDictPackCandidate.init)
    rollbackTargetVersion = snapshot.rollback
    isAwaitingLiveSessionRefresh = snapshot.awaiting
    switch snapshot.phase {
    case "preparing": status = .preparing(progress: snapshot.progress)
    case "prepared": status = .prepared(version: snapshot.version!)
    case "activating": status = .activating
    case "rollingBack": status = .rollingBack
    case "installed": status = .installed(version: snapshot.version!)
    case "failed": status = .failed(snapshot.message)
    default: status = .notInstalled
    }
    return snapshot
  }

  init(
    rustBackend: OwlDictPackCenterRustBackend = .production(),
    liveSessionRefresh: @escaping OwlDictPackLiveSessionRefresh = { completion in
      NSApp.owlAppDelegate.runtime.requestLiveSessionRefreshWhenIdle(completion: completion)
    }
  ) {
    self.rustBackend = rustBackend
    self.liveSessionRefresh = liveSessionRefresh
  }

  func refresh() {
    let allowed: Bool = core.call("can_refresh")
    guard allowed else { return }
    do {
      let state = try rustBackend.environment.activeState()
      if let state {
        do {
          _ = try rustBackend.environment.activeGeneration()
        } catch where state.current.manifest.version < OwlRustCompatibleResources.packageVersion {
          _ = event("refreshed", ["state": NSNull()])
          return
        }
      }
      _ = event("refreshed", ["state": state.map(OwlAppCore.payload) ?? NSNull()])
    } catch { _ = event("refreshed", ["error": error.localizedDescription]) }
  }

  /// 提示调度器用：是否仍需提示。轮询期间用户可能已从设置页手动启用，届时静默收摊。
  var needsPrompt: Bool {
    Self.needsPrompt(activeVersion: (try? rustBackend.environment.activeState())?.current.manifest.version)
  }

  /// 只按 Rust 资源判定：没有可读的启用代次，或启用的代次旧于本二进制随包的版本，就该问。
  nonisolated static func needsPrompt(
    activeVersion: Int?, bundledVersion: Int = OwlRustCompatibleResources.packageVersion
  ) -> Bool {
    OwlAppCore.required(["operation": "resource_rule", "rule": "needs_prompt", "args": ["active": activeVersion as Any? ?? NSNull(), "bundled": bundledVersion]])
  }

  var canRollback: Bool {
    rollbackTargetVersion != nil
  }

  /// 启动时机（Main.swift，loadSettings 之后）调用。不静默准备——需要时**武装提示调度器**，
  /// 等安全时机弹窗征求同意；`autoFetch` 开关打开＝用户显式授权免提示直接准备。
  ///
  /// 引导待办时让路：新手引导有自己的「词库」步骤，讲同一件事、写同一个 `promptShown`
  /// （见 `OwlOnboardingView` 的 dict 步骤）。此处再武装调度器就会在引导窗上再弹一次模态
  /// 问同一个问题。本函数在 `applicationWillFinishLaunching` 弹引导之前跑（Main.swift 在
  /// `app.run()` 前调用），所以这里读到的 isDone=false ⟺ 本次启动引导会接手。
  func promptOrFetchIfNeeded() {
    refresh()
    switch OwlDictPackPrompt.launchAction(
      needsFetch: needsPrompt,
      autoFetch: OwlDictPackPreferences.autoFetch,
      promptShown: OwlDictPackPreferences.promptShown,
      onboardingDone: OwlOnboarding.isDone
    ) {
    case .doNothing:
      return
    case .fetchSilently:
      prepare()
    case .deferToOnboarding:
      OwlDictPackPrompt.log.log("first-run consent deferred to onboarding's dict step")
    case .armPrompt:
      OwlDictPackPromptScheduler.shared.arm()
    }
  }

  /// 同意 → 开始准备并把用户送到设置页「完整词库」卡（那里有进度、启用和重试）。
  /// 引导里不走这条：引导的词库步骤自带进度显示，把用户甩进设置窗会打断向导（用 `prepare()`）。
  func acceptAndPrepare() {
    NSApp.owlAppDelegate.showSettings(selectedPage: .keyboard)
    prepare()
  }

  /// Copies the bundled resources into a verified, not yet active generation.
  /// Idempotent: does nothing while an operation runs or a candidate awaits confirmation.
  func prepare() { execute(event("prepare")) }
  func activate() { execute(event("activate")) }
  func rollback() { execute(event("rollback")) }
  func retryFailedOperation() { execute(event("retry")) }

  private func execute(_ snapshot: Snapshot) {
    let backend = rustBackend
    switch snapshot.action {
    case "prepare":
      Task.detached(priority: .utility) { [self] in
        do {
          let prepared = try await backend.prepare(backend.environment) { fraction in
            Task { @MainActor [weak self] in _ = self?.event("progress", ["fraction": fraction]) }
          }
          await MainActor.run { _ = self.event("prepared", OwlAppCore.payload(prepared) as! [String: Any]) }
        } catch { await fail(error, operation: "prepare") }
      }
    case "activate":
      guard let resource = snapshot.prepared?.resource else { return }
      Task.detached(priority: .utility) { [self] in
        do {
          let result = try await backend.activate(backend.environment, resource)
          await MainActor.run { self.execute(self.event("activated", OwlAppCore.payload(result.state) as! [String: Any])) }
        } catch { await fail(error, operation: "activate") }
      }
    case "rollback":
      Task.detached(priority: .utility) { [self] in
        do {
          let state = try await backend.rollback(backend.environment, OwlRustResourceEnvironment.activeInputKind)
          await MainActor.run { self.execute(self.event("rolledBack", OwlAppCore.payload(state) as! [String: Any])) }
        } catch { await fail(error, operation: "rollback") }
      }
    case "refresh":
      let deferred = liveSessionRefresh { [weak self] in _ = self?.event("refresh_done") }
      if !deferred { _ = event("refresh_done") }
    default: break
    }
  }
  private func fail(_ error: Error, operation: String) {
    let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    let snapshot = event("failed", ["operation": operation, "message": reason])
    OwlDictPackPrompt.log.error("\(snapshot.message, privacy: .public)")
  }

}

/// 知情同意提示（2026-07-27 改版）：完整词库来自第三方开源项目（rime-ice / KyleBing 极点五笔86），
/// 方案B 为避免版权争议不随安装包分发；改版后也**不再由猫头鹰静默替用户下载**——先弹窗说明缘由，
/// 用户点「同意并下载」才拉。判定是纯函数，XCTest 可锁：真机上「切到包外方案」这条分支只在用户
/// 恰好切到未随包分发的方案时才走到，手测覆盖不到。
enum OwlDictPackPrompt {
  static let log = Logger(subsystem: "im.owltype.inputmethod.Owltype", category: "dictPack")

  enum Choice {
    case download
    case later
  }

  /// 启动时该做什么（纯判定，`promptOrFetchIfNeeded` 的全部分支逻辑）。
  enum LaunchAction: String, Equatable {
    /// 已启用当前版本 / 已问过 —— 只刷新状态。
    case doNothing
    /// 用户显式开了 autoFetch 开关＝授权免提示直接准备。
    case fetchSilently
    /// 引导本次会接手（它的词库步骤讲同一件事、写同一个 promptShown）—— 别再弹一次模态。
    case deferToOnboarding
    /// 常规首启告知：武装安全时机调度器。
    case armPrompt
  }

  /// - Parameter onboardingDone: 读 `OwlOnboarding.isDone`。false ⟺ 本次启动引导会弹出
  ///   （`promptOrFetchIfNeeded` 跑在 `applicationWillFinishLaunching` 之前）。
  static func launchAction(
    needsFetch: Bool, autoFetch: Bool, promptShown: Bool, onboardingDone: Bool
  ) -> LaunchAction {
    let result: String = OwlAppCore.required(["operation": "resource_rule", "rule": "launch", "args": [
      "needsFetch": needsFetch, "autoFetch": autoFetch, "promptShown": promptShown, "onboardingDone": onboardingDone,
    ]])
    return LaunchAction(rawValue: result)!
  }

  /// 方案是否由 dict-pack 管理。**纯 manifest 查询、不碰运行期状态**，因此非隔离可调——
  /// 调用方 `selectSchema` 是 nonisolated，需要先同步分流再决定要不要进主线程呈现。
  static func isDictPackManagedSchema(
    _ schemaID: String, manifest: OwlDictPackManifest = .current
  ) -> Bool {
    OwlAppCore.required(["operation": "resource_rule", "rule": "managed_schema", "args": ["schema": schemaID, "destinations": manifest.files.map(\.dest)]])
  }

  /// 切方案失败是不是「dict-pack 未安装」造成的。
  ///
  /// 真值才该弹版权说明；否则维持既有的「该方案可能尚未编译」提示——后者对 dict-pack 缺失是
  /// **误导**（叫用户去「应用配置改动」，可方案文件压根不在磁盘上，照做也没用）。
  /// 准备、启用或回退中不弹：用户已经同意过，再弹一次纯噪音。
  static func isAbsentDictPackSchema(
    schemaID: String,
    manifest: OwlDictPackManifest = .current,
    status: OwlDictPackStatus
  ) -> Bool {
    switch status {
    case .installed, .preparing, .prepared, .activating, .rollingBack:
      return false
    case .notInstalled, .failed: break
    }
    return isDictPackManagedSchema(schemaID, manifest: manifest)
  }

  /// dict-pack 清单内方案的中文名；不认识的回落到 id 本身（宁可显示 id 也不显示空）。
  static func displayName(for schemaID: String) -> String {
    switch schemaID {
    case "wubi86_jidian": return "极点五笔86"
    case "wubi86_jidian_pinyin": return "五笔拼音混输"
    case "wubi86_jidian_trad": return "五笔简入繁出"
    case "wubi86_jidian_trad_pinyin": return "五笔拼音混输·简入繁出"
    case "pinyin_simp": return "简体拼音"
    case "double_pinyin_flypy": return "小鹤双拼"
    case "radical_pinyin": return "部件拼音反查"
    case "melt_eng": return "英文"
    default:
      return schemaID.hasPrefix("double_pinyin") ? "双拼" : schemaID
    }
  }

  /// 版权说明对话框。**只返回用户选择、不自己执行动作**——记录已处置与执行下载由调用方统一
  /// 编排（对齐 OwlUpdateLogoutPrompt 的 A1「记录在执行之前」）。
  /// - Parameter schemaID: 由「切到缺失方案」触发时传方案 id，用于点名；首启告知传 nil。
  @MainActor
  static func presentAlert(schemaID: String?) -> Choice {
    let alert = NSAlert()
    if let schemaID {
      alert.messageText = "方案「\(displayName(for: schemaID))」需要先下载完整词库"
    } else {
      alert.messageText = "猫头鹰当前使用的是精简词库"
    }
    alert.informativeText = """
    猫头鹰安装包只内置了自建的清洁室精简词库。五笔、简体拼音、小鹤双拼等方案的词库来自第三方开源项目（雾凇拼音 rime-ice、极点五笔86），为避免版权争议，猫头鹰不随安装包分发它们，也不会在你不知情的情况下替你下载。

    点「同意并下载」后，猫头鹰会从这些项目的官方仓库按固定版本获取（约 90 MB），校验通过后自动编译启用。

    你也可以选「稍后」，之后随时在「设置 → 键盘输入 → 完整词库」里下载。
    """
    alert.addButton(withTitle: "同意并下载（约 90 MB）")  // 第一个 = 默认
    alert.addButton(withTitle: "稍后")
    return alert.runModal() == .alertFirstButtonReturn ? .download : .later
  }

  /// 「切到缺失方案」路径的完整编排：判定 → 弹窗 → 处置。返回是否已由本函数接管提示
  /// （true = 调用方不要再发那条「尚未编译」的通知）。
  @MainActor
  static func handleAbsentSchema(_ schemaID: String) -> Bool {
    guard isAbsentDictPackSchema(schemaID: schemaID, status: OwlDictPackCenter.shared.status) else {
      return false
    }
    log.log("absent dict-pack schema: \(schemaID, privacy: .public) — presenting consent alert")
    // 首启告知与本次点名说的是同一件事，弹过一次就别再重复问候。
    OwlDictPackPreferences.promptShown = true
    switch presentAlert(schemaID: schemaID) {
    case .download:
      OwlDictPackCenter.shared.acceptAndPrepare()
    case .later:
      log.log("user deferred dict-pack download for \(schemaID, privacy: .public)")
    }
    return true
  }
}

/// 首启告知的安全时机门控。直接复用注销提示线沉淀的纯判定层 `OwlLogoutPromptTiming`——
/// #109 真机教训同样适用：**启动回调里同步 runModal 会在用户开始输入后中途夺焦点、打断输入**。
/// 等无合成 + 输入空闲再激活猫头鹰自身弹窗；选「稍后」还原宿主焦点。
/// 观测：`log show --predicate 'subsystem == "im.owltype.inputmethod.Owltype" AND category == "dictPack"'`
@MainActor
final class OwlDictPackPromptScheduler {
  static let shared = OwlDictPackPromptScheduler()
  private init() {}

  private var armed = false
  private var timer: Timer?
  private var snapshotBlock = OwlLogoutPromptTiming.SnapshotBlockTracker()
  private var capturedApp: NSRunningApplication?

  /// 武装：启动低频轮询。同次启动只处理一次。
  func arm() {
    guard !armed else { return }
    armed = true
    snapshotBlock = OwlLogoutPromptTiming.SnapshotBlockTracker()
    capturedApp = nil
    OwlDictPackPrompt.log.log("first-run consent prompt armed")
    let poll = Timer(timeInterval: OwlLogoutPromptTiming.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(poll, forMode: .common)
    timer = poll
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    // 期间用户可能已从设置页手动装好，或走了「切到缺失方案」那条路 —— 都不必再告知一次。
    guard !OwlDictPackPreferences.promptShown,
          OwlDictPackCenter.shared.needsPrompt else {
      stopTimer()
      return
    }
    let input = readSafeInput()
    let blockedTicks = snapshotBlock.observe(input.snapshotID)
    guard case .safe = OwlLogoutPromptTiming.safeVerdict(input, blockedTicks: blockedTicks) else {
      return
    }
    stopTimer()
    capturedApp = NSWorkspace.shared.frontmostApplication
    NSApp.activate(ignoringOtherApps: true)
    // A1：处置前先落盘。弹窗未处置就被杀掉时下次启动重弹优于永久静默，但正常路径必须只弹一次。
    OwlDictPackPreferences.promptShown = true
    switch OwlDictPackPrompt.presentAlert(schemaID: nil) {
    case .download:
      OwlDictPackCenter.shared.acceptAndPrepare()
    case .later:
      OwlDictPackPrompt.log.log("user deferred dict-pack download at first run")
      capturedApp?.activate()  // 还原宿主焦点，别把用户晾在猫头鹰这边
    }
    capturedApp = nil
  }

  private func readSafeInput() -> OwlLogoutPromptTiming.SafeInput {
    let snapshotID = OwlSnapshotRegistry.shared.current?.id
    // 读不到空闲态时【不】据此阻塞——「条件读不到 → 永久静默」正是 #131 要消灭的失败类别。
    var idle: TimeInterval?
    if let anyInput = CGEventType(rawValue: ~0) {
      idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
    let isLoginWindow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    return OwlLogoutPromptTiming.SafeInput(snapshotID: snapshotID, idleSeconds: idle, isLoginWindow: isLoginWindow)
  }
}
