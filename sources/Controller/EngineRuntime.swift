//
//  EngineRuntime.swift
//  Owltype
//
//  The engine runtime: the one engine, the config cache it serves, and the order in which they
//  start, redeploy, reset and hand fresh resources to live sessions. The delegate keeps only the
//  AppKit wiring; the controller and settings receive this object instead of reaching into
//  `NSApp`. Every sequence here runs off the IMK keystroke hot path except the two reads the
//  controller makes per key (`styleFlags`, `applyPendingLiveSessionRefreshIfIdle`), both of
//  which are a stored-property read or an early return.
//

import AppKit
import os

final class EngineRuntime {
  /// Deploy/reload lifecycle evidence in the unified log. `print` from an IME process goes
  /// nowhere useful, and rime's glog can't record a notification that never reached the
  /// process — this channel is the app-side proof of "reload arrived / deploy succeeded or
  /// failed". Read with:
  ///   log show --predicate 'subsystem == "im.owltype.inputmethod.Owltype" && category == "deploy"' --info
  static let deployLog = Logger(subsystem: "im.owltype.inputmethod.Owltype", category: "deploy")

  /// The single owner of the global engine lifecycle. Controllers obtain their per-composition
  /// session from it. Swappable so tests can inject a fake; replace the engine, never the runtime,
  /// because controllers hold the runtime they were created with.
  var engine: InputEngine
  /// User data root: deploy inputs, the template-migration journal and the Rust user data.
  let userDirectory: URL
  private let sharedSupportURL: URL?
  /// The last config that passed `isUsable`. Never replaced by a failed or empty reread.
  private(set) var config: OwlConfig?
  /// Candidate-window LAYOUT flags read from `style/*` (linear/vertical/inline*), read live by
  /// the IMK path. Seeded in `loadSettings()` from the global config, overridden per-schema in
  /// `loadSettings(for:)`. Not theming — the skin/colors live in `OwlThemes`.
  private(set) var styleFlags = OwlStyleFlags()
  /// The controller that composed last, set on each `showPanel`. Refreshed last (with replay)
  /// when live sessions reload the config.
  weak var activeInputController: OwlInputController?
  /// The controller IMK activated last and has not deactivated. A host field that regains focus
  /// after a template window may be served by a new controller; delivery re-binds to it.
  weak var activatedInputController: OwlInputController?
  /// Registry of every LIVE controller (one per host-app input session). WEAK members — a
  /// controller registers itself when it creates a session (and on each `showPanel`); dead
  /// controllers drop out automatically, so there is no retain cycle and no manual unregister
  /// bookkeeping. Off the IMK keystroke hot path.
  let liveControllers = NSHashTable<OwlInputController>.weakObjects()
  /// Resource activation changes the generation read by `createSession()`, not an existing
  /// session. These completions are drained at an idle composition boundary so enabling or
  /// rolling back a dict-pack never discards a partially selected phrase.
  private var liveSessionRefreshCompletions: [@MainActor () -> Void] = []

  init(
    engine: InputEngine = OwlRustEngine.makeConfiguredEngine(),
    userDirectory: URL = OwlApp.userDir,
    sharedSupportURL: URL? = Bundle.main.sharedSupportURL
  ) {
    self.engine = engine
    self.userDirectory = userDirectory
    self.sharedSupportURL = sharedSupportURL
  }

  // MARK: - Start, redeploy, stop

  /// Start maintenance and reload the config cache. Returns whether maintenance ran.
  @discardableResult
  func start(fullCheck: Bool) -> Bool {
    let ok = startEngine(fullCheck: fullCheck)
    loadSettings()
    return ok
  }

  /// Full redeploy: stop every session, restart maintenance, reload the config cache. Refuses
  /// (and leaves the engine running) while a session is still live.
  @discardableResult
  func redeploy() -> Bool {
    let trace = OwlLatencyTrace.begin("deploy.full")
    defer { OwlLatencyTrace.end("deploy.full", trace) }
    print("Start maintenance...")
    OwlLatencyTrace.event("deploy.maintenanceStart")
    guard shutdown() else {
      Self.deployLog.error("deploy BLOCKED: Rust engine still has live sessions")
      return false
    }
    let ok = startEngine(fullCheck: true)
    OwlLatencyTrace.event("deploy.restoreSettings")
    loadSettings()
    OwlLatencyTrace.event("deploy.finalUIState")
    return ok
  }

  /// The outcome of work that needs the engine stopped.
  enum StoppedRun<Value> {
    /// A session was still live, so the engine kept running and `body` never ran.
    case blocked
    /// `body` ran with the engine stopped; `restarted` says whether maintenance succeeded after.
    case finished(Result<Value, Error>, restarted: Bool)
  }

  /// Run `body` with the engine stopped, then always restart it and reload the config cache.
  ///
  /// The order is a hard constraint: the Rust SQLite journal is held by the process cache, so
  /// sessions and the cached database must be closed before files can be backed up, deleted or
  /// imported. The engine is restarted whether `body` succeeds or throws — an engine left
  /// finalized means no typing at all, which is worse than any failed reset.
  func whileStopped<Value>(_ body: () throws -> Value) -> StoppedRun<Value> {
    guard shutdown() else { return .blocked }
    let result = Result { try body() }
    let restarted = startEngine(fullCheck: true)
    loadSettings()
    return .finished(result, restarted: restarted)
  }

  /// Close the config and finalize the engine. False (and nothing closed in the engine) while a
  /// session is still live.
  @discardableResult
  func shutdown() -> Bool {
    OwlLatencyTrace.event("deploy.rimeFinalize")
    config?.close()
    return engine.finalize()
  }

  private func startEngine(fullCheck: Bool) -> Bool {
    let trace = OwlLatencyTrace.begin("deploy.startEngine")
    defer { OwlLatencyTrace.end("deploy.startEngine", trace) }
    print("Initializing the Rust input engine...")
    guard !templateRecoveryBlocksDeployment() else { return false }
    // check for configuration updates
    let maintained = engine.startMaintenance(fullCheck: fullCheck)
    if maintained {
      OwlLatencyTrace.event("deploy.maintenanceStarted")
    }
    // update Owltype frontend config — UNCONDITIONALLY: rime's detect_modifications does not
    // track owltype.custom.yaml, so a owltype-domain-only change (App 默认英文 add) leaves
    // maintenance with "nothing to do" and used to skip this deploy entirely — the write
    // then never reached build/owltype.yaml even via 重新部署 (#121 真机验收逮住).
    // config_file_update is fingerprint-gated → free when unchanged.
    _ = engine.deployConfigFile(OwlEngineIdentity.configFile, versionKey: "config_version")
    OwlLatencyTrace.event("deploy.configFile")
    if maintained {
      return true
    } else {
      print("Owltype: deploy failed during Rime maintenance.")
      Self.deployLog.error("start_maintenance failed (fullCheck=\(fullCheck, privacy: .public)) — installation_update/detect_modifications refused; see the engine log in \(OwlApp.logDir.path, privacy: .public)")
      return false
    }
  }

  /// While a template migration journal is unresolved, its target files (template dict,
  /// rime_ice.custom.yaml, …) may be half-written. Typing keeps running on the last compiled
  /// `build/`; only recompiling from those sources waits until recovery succeeds.
  private func templateRecoveryBlocksDeployment() -> Bool {
    guard OwlTemplateMigration.hasPendingRecovery(dataDir: userDirectory) else { return false }
    Self.deployLog.error("template migration recovery pending — skipped Rime deployment, serving the last build")
    return true
  }

  // MARK: - Config cache and style flags

  /// `config` 可用性判据（2026-07-12 B1/B2）：打得开且非空壳。实测 `config_open("owltype")`
  /// 在 build/owltype.yaml 缺席/重建窗口会「成功」返回空壳（一切读取失败）——只看 open 返回值不够，
  /// 必须探真内容（owltype.yaml 恒有 style 段）。
  private static func isUsable(_ config: OwlConfig?) -> Bool {
    config?.has(section: "style") ?? false
  }

  private func makeConfig() -> OwlConfig {
    OwlConfig(sharedSupportURL: sharedSupportURL, userDataURL: userDirectory)
  }

  func loadSettings() {
    // 先验后换（B1）：曾经是「先把 config 换成新对象、open 失败静默 return」——一次失败的
    // 重读（部署重写 build/ 的窗口期）就把好句柄换成毒句柄，此后每个新控制器经 loadSettings(for:)
    // 用它重算 styleFlags → 全默认（inlinePreedit=false 占位模式），且零诊断、永不自愈。
    // 现契约：candidate 全验证（open + 非空壳）通过才换 config / 重读 styleFlags；失败保留
    // 旧状态（旧而真 > 新而毒）+ trace（只记布尔，#88 §4）。
    let candidate = makeConfig()
    let opened = candidate.openBaseConfig()
    let usable = opened && Self.isUsable(candidate)
    OwlLiveInputTrace.write { "loadSettings openBase=\(opened) usable=\(usable)" }
    guard usable else {
      if config == nil {
        var flags = OwlStyleFlags(linear: true, vertical: false, inlinePreedit: true, inlineCandidate: false)
        OwlCandidatePanelSettings.live.applyInlineCandidate(to: &flags)
        styleFlags = flags
      }
      return
    }
    config = candidate
    // Layout flags from the global `style/*` (was `panel.load(...)` into OwlTheme).
    styleFlags = OwlStyleFlags.base(config: candidate)
    // Feature 3: the 内嵌候选预览 pref overrides `style/inline_candidate` without hand-editing
    // yaml. The same module method runs after live edits and every global/schema style reload.
    OwlCandidatePanelSettings.live.applyInlineCandidate(to: &styleFlags)
    OwlLiveInputTrace.write { "loadSettings styleFlags inlinePreedit=\(styleFlags.inlinePreedit) inlineCandidate=\(styleFlags.inlineCandidate)" }
  }

  func loadSettings(for schemaID: String) {
    if schemaID.count == 0 || schemaID.first == "." {
      return
    }
    // 自愈（B1/B2）：句柄缺失或空壳（历史毒化/启动竞态残留）→ 先试全量重读；仍不可用则保留现有
    // styleFlags 直接返回——宁可沿用旧值也不用全默认去踩掉内嵌旗标（那正是占位模式蔓延的路径）。
    if !Self.isUsable(config) {
      loadSettings()
    }
    guard let config, Self.isUsable(config) else {
      OwlLiveInputTrace.write { "loadSettings(for:) config unusable — keeping current styleFlags" }
      return
    }
    let schema = makeConfig()
    // Base flags from the global style, then let a per-schema `style` section override
    // (same precedence the deleted OwlTheme.load used for these layout keys).
    var flags = OwlStyleFlags.base(config: config)
    if schema.open(schemaID: schemaID, baseConfig: config) && schema.has(section: "style") {
      flags.apply(config: schema)
    }
    // Feature 3: pref override wins over both global + per-schema `style/inline_candidate`.
    OwlCandidatePanelSettings.live.applyInlineCandidate(to: &flags)
    styleFlags = flags
    schema.close()
  }

  /// Re-apply the 内嵌候选预览 preference to the cached flags after a settings-page edit.
  func applyPanelPreferences() {
    OwlCandidatePanelSettings.live.applyInlineCandidate(to: &styleFlags)
  }

  // MARK: - Keyboard settings

  /// Owns persistence and activation together; callers only choose the kind of edit.
  /// `directory` overrides where the patches are written (tests); nil means `userDirectory`.
  func applyKeyboardSettings(
    _ mode: OwlKeyboardSettingsApplication.Mode,
    snapshot: OwlKeyboardSnapshot = .current(),
    directory: URL? = nil
  ) throws -> OwlKeyboardSettingsApplication.Outcome {
    try OwlKeyboardSettingsApplication(
      engine: engine,
      directory: directory ?? userDirectory,
      refresh: {
        self.loadSettings()
        MainActor.assumeIsolated { self.requestLiveSessionRefreshWhenIdle {} }
      }
    ).apply(snapshot, mode: mode)
  }

  // MARK: - Live sessions

  /// Register a controller as live (idempotent — `NSHashTable` ignores duplicates). Called by
  /// the controller from `createSession` / `showPanel`. Off the IMK keystroke hot path.
  func registerLiveController(_ controller: OwlInputController) {
    liveControllers.add(controller)
  }

  /// Apply a resource-generation switch only when the active composition is idle.
  ///
  /// Replaying `rawInput` cannot reconstruct the Rust session's selected phrase progress
  /// (`phrase_progress`). Therefore a resource switch never tears down a session with live
  /// content: it queues one refresh, and the controller calls this again when a composition
  /// ends. The active generation pointer is already updated, so this is only the live-session
  /// handoff, not another storage transaction.
  @discardableResult
  @MainActor
  func requestLiveSessionRefreshWhenIdle(
    completion: @escaping @MainActor () -> Void
  ) -> Bool {
    liveSessionRefreshCompletions.append(completion)
    return applyPendingLiveSessionRefreshIfIdle()
  }

  /// Drain queued resource refreshes at a safe boundary. Returns true when any live session
  /// still has content and the refresh remains queued. Background sessions normally committed
  /// on `deactivateServer`; checking all live sessions protects a stale lifecycle from
  /// turning the destroy-only background branch into silent content loss.
  @discardableResult
  @MainActor
  func applyPendingLiveSessionRefreshIfIdle() -> Bool {
    // No JSON, allocation or controller scan when the native callback queue is empty.
    let pending = !liveSessionRefreshCompletions.isEmpty
    let composing = pending && liveControllers.allObjects.contains(where: \.hasInFlightComposition)
    switch owl_app_keyboard_refresh(pending ? 1 : 0, composing ? 1 : 0) {
    case 0: return false
    case 1: return true
    case 2: break
    default: preconditionFailure("Incompatible keyboard refresh plan")
    }

    let completions = liveSessionRefreshCompletions
    liveSessionRefreshCompletions.removeAll()
    reapplyToLiveSession()
    for completion in completions {
      completion()
    }
    return false
  }

  /// Re-apply the just-deployed config to EVERY live controller's session so the freshly-built
  /// `build/` actually takes effect (live-session-reload rewrite, 2026-06-22).
  ///
  /// The old implementation only touched `activeInputController` and used `select_schema(sameId)`,
  /// which does NOT force the engine to rebuild the cached `Schema` — so a changed `menu/page_size`
  /// never reached the running session (the 8→5-not-applying bug). The fix forces a real reload
  /// by destroying sessions (the engine stays up — no octagram reload → still sub-second):
  ///
  /// - Background controllers are DESTROYED ONLY. Their `client` is nil after `deactivateServer`,
  ///   so eagerly recreating now would mislabel the app (`UnknownApp<n>`) and drop its per-app
  ///   options. Instead their `handle()` hot path lazily recreates on the next keystroke (with a
  ///   live `client`), reading the new `build/` then.
  /// - The ACTIVE controller is refreshed LAST: destroy + recreate + restore its captured schema
  ///   + replay its in-flight composition, so the panel re-renders immediately under the new
  ///   config (no retype).
  ///
  /// No-op when no controller is live — the next `createSession` reads fresh `build/` anyway. Off
  /// the IMK keystroke hot path.
  func reapplyToLiveSession() {
    OwlLatencyTrace.event("deploy.sessionReapplyStart")
    let active = activeInputController
    // Snapshot first (mutating sessions during iteration; the table is weak so dead ones are
    // already gone). Background controllers (destroy-only) first, then the active one LAST so its
    // recreate + panel render wins.
    let live = liveControllers.allObjects
    for controller in live where controller !== active {
      OwlLatencyTrace.event("deploy.sessionRelease")
      controller.reapplyConfigToLiveSession(replayComposition: false)
    }
    if active != nil {
      OwlLatencyTrace.event("deploy.sessionRecreate")
    }
    active?.reapplyConfigToLiveSession(replayComposition: true)
  }
}

// MARK: - User data operations

extension EngineRuntime {
  /// 「重置用户词典…」：备份并删除 Rust 学习日志与词典代次，随后重新启动引擎。
  /// 返回给「维护与诊断」卡状态行的文案。顺序约束见 `whileStopped(_:)`。
  func resetUserDict(timestamp: String = EngineRuntime.backupTimestamp()) -> String {
    let trace = OwlLatencyTrace.begin("reset.userDict")
    defer { OwlLatencyTrace.end("reset.userDict", trace) }
    Self.deployLog.notice("reset Rust user dictionary requested")
    let run = whileStopped {
      try OwlUserDictReset.run(root: userDirectory, timestamp: timestamp)
    }
    switch run {
    case .blocked:
      Self.deployLog.error(
        "reset user dict BLOCKED: Rust engine still has live sessions; no data deleted"
      )
      return "重置失败：Rust 引擎仍有活动会话，未删除用户词典。请重新打开猫头鹰后再试。"
    case .finished(.success(let outcome), let redeployed):
      Self.deployLog.notice("""
        reset Rust user dictionary cleared \(outcome.removedItems.count, privacy: .public) item(s), \
        redeploy=\(redeployed, privacy: .public)
        """)
      return OwlUserDictReset.statusMessage(outcome: outcome, redeployed: redeployed)
    case .finished(.failure(let error), let redeployed):
      Self.deployLog.error("""
        reset user dict FAILED (restored from backup): \
        \(error.localizedDescription, privacy: .public), redeploy=\(redeployed, privacy: .public)
        """)
      return OwlUserDictReset.failureMessage(error: error, redeployed: redeployed)
    }
  }

  /// Imports Rime's stable userdb text snapshots into the Rust journal.
  ///
  /// Planning and staging happen before shutdown, so a missing or changing snapshot leaves
  /// typing untouched. Once shutdown begins, every exit path restarts the engine.
  func migrateLegacyUserData() -> String {
    let trace = OwlLatencyTrace.begin("migrate.rimeUserData")
    defer { OwlLatencyTrace.end("migrate.rimeUserData", trace) }
    let userRoot = userDirectory
    let rustUserRoot = userRoot.appendingPathComponent("msime-user", isDirectory: true)
    let staged: OwlUserMigrationStageResult
    do {
      let pinsData = try JSONEncoder().encode(OwlPinnedWords.shared.words)
      let plan = try OwlUserMigration.makePlan(
        userData: userRoot,
        pinnedWordsData: pinsData,
        syncDirectory: OwlSyncSettings(dataDir: userRoot).currentSyncDirectory()
      )
      guard !plan.captures.isEmpty || !plan.manifest.pins.isEmpty else {
        return "没有找到旧版稳定快照或置顶词；请确认旧版猫头鹰的同步目录和设置。"
      }
      try FileManager.default.createDirectory(
        at: rustUserRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      staged = try OwlUserMigrationStage.prepare(
        plan,
        in: rustUserRoot
      )
    } catch {
      let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      Self.deployLog.error(
        "legacy user migration staging FAILED: \(reason, privacy: .public)"
      )
      return "迁移准备失败，输入引擎未中断：\(reason)"
    }

    let run = whileStopped {
      try OwlUserMigrationImport.run(staged, userRoot: userRoot)
    }
    switch run {
    case .blocked:
      Self.deployLog.error(
        "legacy user migration BLOCKED: Rust engine still has live sessions; nothing imported"
      )
      return "迁移失败：Rust 引擎仍有活动会话，未写入迁移数据。请重新打开猫头鹰后再试。"
    case .finished(.success(let outcome), let restarted):
      Self.deployLog.notice("""
        legacy user migration succeeded: sources=\(outcome.report.sourceCount, privacy: .public) \
        records=\(outcome.report.recordCount, privacy: .public) \
        written=\(outcome.report.entriesWritten, privacy: .public) \
        pins=\(outcome.report.pinsWritten, privacy: .public) \
        restart=\(restarted, privacy: .public)
        """)
      return OwlUserMigrationImport.successMessage(outcome, engineRestarted: restarted)
    case .finished(.failure(let error), let restarted):
      Self.deployLog.error("""
        legacy user migration FAILED: \(error.localizedDescription, privacy: .public), \
        restart=\(restarted, privacy: .public)
        """)
      return OwlUserMigrationImport.failureMessage(error, engineRestarted: restarted)
    }
  }

  /// 备份目录名用的文件系统安全时间戳。只在用户显式点击时调用，故直接读 `Date()`。
  static func backupTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }
}
