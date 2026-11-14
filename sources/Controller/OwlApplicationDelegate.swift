//
//  OwlApplicationDelegate.swift
//  Owltype
//
//  Created by Leo Liu on 5/6/24.
//

import UserNotifications
import Sparkle
import AppKit
import InputMethodKit
import os

final class OwlApplicationDelegate: NSObject, NSApplicationDelegate, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
  private var installSelfCheckObserver: NSObjectProtocol?
  static let rimeWikiURL = URL(string: "https://github.com/rime/home/wiki")!
  static let updateNotificationIdentifier = "OwlUpdateNotification"
  static let notificationIdentifier = "OwlNotification"

  /// The engine, its config cache and their start/redeploy/reset ordering. One instance for
  /// the process: controllers capture it at init, so tests swap `runtime.engine`, never this.
  let runtime = EngineRuntime()
  /// The controller's read-only view of the live composition snapshot, behind the narrow
  /// `SnapshotReading` port (same composition-root pattern as `engine`). Default is the
  /// production `.shared` registry; swappable so tests can inject a scripted snapshot.
  var snapshots: SnapshotReading = OwlSnapshotRegistry.shared
  /// The controller's composition-timeline snapshot emitter, behind the narrow
  /// `SnapshotEmitting` port (same composition-root pattern as `engine`). Default is the
  /// production `.shared` emitter; swappable so tests can drive the snapshot path and assert
  /// the emitted call/args without an engine session.
  var snapshotEmitter: SnapshotEmitting = OwlSnapshotEmitter.shared
  /// The controller's explicit 润色选中 rewrite, behind the narrow `SelectionPolishing` port.
  /// Default is the production `.shared` service; swappable so tests can return scripted
  /// rewrites without DeepSeek or the keychain.
  var selectionPolish: SelectionPolishing = OwlSelectionPolishService.shared
  /// Central host-client compatibility policy. Pure and swappable in tests; controller code asks
  /// it before risky IMK/AX host reads.
  var clientCapabilityPolicy = OwlClientCapabilityPolicy()
  var clientWorkarounds = OwlClientWorkaroundSettings()
  /// SwiftUI candidate panel, created lazily on first composition (always on now — SwiftUI
  /// is the sole renderer).
  var owlPanel: OwlSwiftUICandidatePanel?
  /// SwiftUI status HUD (mode/schema toast), created lazily on first status message.
  /// Replaces the legacy AppKit OwlPanel.show(status:) path.
  var statusHUD: OwlStatusHUD?
  /// The last known-good caret anchor seen by the candidate panel, SCOPED to the host app it came
  /// from (recorded by the controller on each `showPanel`), so the status HUD and the quick-send
  /// panel can position near where the user is typing. Host-scoped because a single process-wide
  /// anchor leaked across apps: a host whose caret rect is rejected reused the previous app's
  /// anchor, which on a multi-display setup opened its panel on the other app's screen.
  private var caretAnchorMemory = OwlHostCaretAnchorMemory()

  /// Record a validated caret anchor for `host`. The controller's `showPanel` / delayed
  /// reposition are the only writers, and both pass anchors that already cleared
  /// `OwlCandidateAnchor`.
  func recordCaretAnchor(_ anchor: NSRect, host: String?) {
    caretAnchorMemory.record(anchor, host: host)
  }

  /// The last known-good caret anchor for `host` — `nil` when the stored one belongs to a
  /// different app. Callers must then run their own fallback instead of borrowing another app's
  /// caret (which is what put the candidate panel on the wrong display).
  func lastCaretAnchor(forHost host: String?) -> NSRect? {
    caretAnchorMemory.anchor(for: host)
  }

  /// The last known-good caret anchor for the app that is currently in front — the host the
  /// near-caret surfaces (status HUD toast, quick-send panel) are about to appear over. `.zero`
  /// when that app has no recorded caret: nothing composed there yet, or the only stored anchor
  /// belongs to another app. `.zero` is the "no caret known" sentinel both consumers already
  /// handle (the HUD corners its toast; the quick-send panel centres under the mouse), and
  /// falling back to it IS the fix — borrowing another app's caret is what put these surfaces on
  /// the wrong display.
  ///
  /// The frontmost app, not `activeInputController`, is the honest reading of "current host":
  /// the active controller is only re-pointed on `showPanel`, so it names the app that last
  /// COMPOSED — after an app switch, exactly the stale identity this scoping exists to drop.
  /// Both callers read this while the host is still frontmost (the quick-send panel positions
  /// itself before it orders front, and never activates Owltype).
  var currentHostCaretAnchor: NSRect {
    lastCaretAnchor(forHost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) ?? .zero
  }
  // v0.2: SwiftUI settings window, created lazily the first time 设置… is opened.
  // Purely additive UI — only forwards already-safe actions; nil until used.
  var owlSettingsWindow: OwlSettingsWindow?
  // v0.3.3: SwiftUI onboarding/welcome window, created lazily on first launch (or
  // from the menu). Purely additive UI — only forwards already-safe actions.
  var owlOnboardingWindow: OwlOnboardingWindow?
  var selectionMenuCoordinator: OwlSelectionMenuCoordinator?
  lazy var updateController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
  var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
    NSApp.setActivationPolicy(.regular)
    if !state.userInitiated {
      NSApp.dockTile.badgeLabel = "1"
      let content = UNMutableNotificationContent()
      content.title = NSLocalizedString("A new update is available", comment: "Update")
      content.body = NSLocalizedString("Version [version] is now available", comment: "Update").replacingOccurrences(of: "[version]", with: update.displayVersionString)
      let request = UNNotificationRequest(identifier: Self.updateNotificationIdentifier, content: content, trigger: nil)
      UNUserNotificationCenter.current().add(request)
    }
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    NSApp.dockTile.badgeLabel = ""
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.updateNotificationIdentifier])
  }

  func standardUserDriverWillFinishUpdateSession() {
    NSApp.setActivationPolicy(.accessory)
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    if response.notification.request.identifier == Self.updateNotificationIdentifier && response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      updateController.updater.checkForUpdates()
    }

    completionHandler()
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard !OwlApp.isShowingSettingsForUITests else { return }
    addObservers()
    selectionMenuCoordinator = OwlSelectionMenuCoordinator()
    selectionMenuCoordinator?.start()
    startHotKeyTap()
    Task { @MainActor in
      OwlVoiceInputCoordinator.shared.startGlobalMonitor()
    }
    // v0.3.3: first-run onboarding. Guarded + non-blocking (just orders the window
    // front); kept LAST so it never interferes with Rime / panel / status setup.
    if !OwlOnboarding.isDone {
      showOnboarding()
    }
    // Only a completed self-check failure can request recovery guidance; startup/version
    // changes never arm a logout prompt. The CLI writes its result before notifying this app.
    installSelfCheckObserver = DistributedNotificationCenter.default().addObserver(
      forName: OwlUpdateLogoutPrompt.selfCheckNotification, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        OwlUpdateLogoutPrompt.runIfNeeded(current: current)
      }
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    guard !OwlApp.isShowingSettingsForUITests else { return }
    // 授权后补装（2026-07-26）：启动时 AX 未授权则 tap 缺席，事后授权不会自动送达任何事件，
    // 录制热键在 Chromium/Electron 宿主失灵直到注销。用户去系统设置授权后切回法墨窗口的
    // 瞬间（设置页徽章翻绿的同一事件）补一次；已装时首行 guard 直接返回，零开销。
    hotKeyTap.startIfPossible()
  }

  func applicationWillTerminate(_ notification: Notification) {
    // swiftlint:disable:next notification_center_detachment
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
    selectionMenuCoordinator?.stop()
    selectionMenuCoordinator = nil
    stopHotKeyTap()
    MainActor.assumeIsolated {
      OwlVoiceInputCoordinator.shared.stopGlobalMonitor()
    }
    statusHUD?.hidePanel()
    owlPanel?.hidePanel()
  }



  func openLogFolder() {
    NSWorkspace.shared.open(OwlApp.logDir)
  }

  func openDataFolder() {
    NSWorkspace.shared.open(OwlApp.userDir)
  }

  /// Lazily create the SwiftUI candidate panel (the sole candidate renderer).
  func ensureOwltypePanel() -> OwlSwiftUICandidatePanel {
    if let owlPanel { return owlPanel }
    let created = OwlSwiftUICandidatePanel()
    owlPanel = created
    return created
  }

  /// Lazily create the SwiftUI status HUD (mode/schema toast). Mirrors `ensureOwltypePanel()`.
  func ensureStatusHUD() -> OwlStatusHUD {
    if let statusHUD { return statusHUD }
    let created = OwlStatusHUD()
    statusHUD = created
    return created
  }

  // MARK: - 表情/符号面板 (module 7)

  /// The floating emoji/symbol panel, created lazily on first open.
  private var owlEmojiPanel: OwlEmojiPanel?

  /// Show the emoji/symbol panel. `onPick` is where a chosen glyph goes:
  /// - From the input menu (typing into a document), the controller passes a closure that
  ///   inserts at the cursor via its live `commit(string:)`.
  /// - From the 表情符号 settings page there is no document client, so `onPick` is nil and
  ///   the panel falls back to copying to the pasteboard.
  /// Re-assigned on every show so the reused singleton always targets the latest trigger.
  func showEmojiPanel(onPick: ((String) -> Void)? = nil) {
    let trace = OwlLatencyTrace.begin("window.open.emoji")
    defer { OwlLatencyTrace.end("window.open.emoji", trace) }
    let panel = owlEmojiPanel ?? OwlEmojiPanel()
    owlEmojiPanel = panel
    OwlLatencyTrace.event("window.emoji.controllerSelected")
    panel.pickHandler = onPick
    panel.showPanel()
    OwlLatencyTrace.event("window.emoji.firstVisible")
  }

  // MARK: - 快捷短语面板 (quick-phrase picker)

  /// The floating quick-phrase panel, created lazily on first open.
  private var owlQuickSendPanel: OwlTemplatePickerPanel?

  /// The controller binds this adapter to its original IMK client. The picker transfers its
  /// captured focus to the selected invocation, including when a fill window follows.
  func showQuickSendPanel(
    onInvoke: ((OwlTemplateInvocation.Content, OwlPanelInsertionBroker, OwlTemplateInvocation.Intent) -> Void)? = nil,
    initialSegment: OwlPickerSegment = .phrase
  ) {
    let trace = OwlLatencyTrace.begin("window.open.quickSend")
    defer { OwlLatencyTrace.end("window.open.quickSend", trace) }
    OwlPromptFillSheet.shared.dismissForNewInvocation()
    let panel = owlQuickSendPanel ?? OwlTemplatePickerPanel()
    owlQuickSendPanel = panel
    OwlLatencyTrace.event("window.quickSend.controllerSelected")
    panel.invocationHandler = onInvoke
    panel.showPanel(initialSegment: initialSegment)
    OwlLatencyTrace.event("window.quickSend.firstVisible")
  }

  // NO Carbon hotkey registration here (#118 root cause): in this IMK process it registers "noErr",
  // the window server then consumes the combo system-wide, and the event is never dispatched
  // in-process — the hotkey does nothing AND steals the combo from the paths that actually work.
  //
  // Working paths, in priority order:
  // 1. `hotKeyTap` (CGEventTap, needs the AX permission 划词 already holds) — cross-host, catches
  //    combos Chromium/Electron hosts would eat before the IME.
  // 2. `OwlInputController.handle()` IMK matcher — fallback in cooperative hosts when AX is off.
  // Both read the stored combos live; no registration or reapply choreography exists anymore.

  /// Session event tap for the global hotkeys (see `OwlHotKeyEventTap`).
  private let hotKeyTap = OwlHotKeyEventTap()

  /// Wire and start the cross-host hotkey tap. Actions mirror the IMK matcher's, with the same
  /// logged gate drops.
  func startHotKeyTap() {
    hotKeyTap.onQuickSend = { [weak self] in
      guard let controller = self?.runtime.activeInputController else {
        OwlHotKeyMatcher.log.notice("quickSend fired but activeInputController=nil — dropped")
        return
      }
      controller.showOwltypeQuickSend()
    }
    hotKeyTap.onSelectionSummon = { [weak self] in
      guard let coordinator = self?.selectionMenuCoordinator else {
        OwlHotKeyMatcher.log.notice("selectionMenu fired but coordinator=nil — dropped")
        return
      }
      coordinator.summonForCurrentSelection()
    }
    hotKeyTap.startIfPossible()
  }

  func stopHotKeyTap() {
    hotKeyTap.stop()
  }

  // MARK: - v0.2 settings window

  /// Build (or reuse) the settings window, populate its state, and show it.
  /// Mirrors the `ensureOwltypePanel()` lazy-create pattern.
  func showSettings(selectedPage: OwlSettingsPage? = nil) {
    if owlSettingsWindow?.restoreIfOpen(selectedPage: selectedPage) == true { return }
    if OwlApp.isShowingSettingsForUITests {
      showSettingsForUITest()
      return
    }
    let trace = OwlLatencyTrace.begin("window.open.settings")
    defer { OwlLatencyTrace.end("window.open.settings", trace) }
    let state = OwlSettingsState()
    state.selectedPage = selectedPage ?? .keyboard
    state.schemas = loadSchemaList()
    state.currentSchemaId = currentSchemaId()
    state.currentInputSourceDisplayName = OwlInstaller.currentInputSourceDisplayName()
    // Seed the complete candidate-panel lifecycle from its single module boundary.
    OwlCandidatePanelSettings.live.seed(state)
    state.candidatePageSize = OwlKeyboardPreferences.pageSize
    // Seed the 键盘输入 option groups: every on/off switch from its catalog, the rest from
    // their single home (OwlKeyboardPreferences).
    OwlKeyboardSettingsCatalog.live.seed(into: state)
    state.keyboardInputMethod = OwlKeyboardPreferences.inputMethod
    state.keyboardDoublePinyin = OwlKeyboardPreferences.doublePinyin
    state.keyboardWubiCandidateMode = OwlKeyboardPreferences.wubiCandidateMode
    state.keyboardWubiScheme = OwlKeyboardPreferences.wubiScheme
    state.keyboardRerankEnabled = OwlExperimentalPreferences.keyboardRerankEnabled
    state.settledRerankEnabled = OwlExperimentalPreferences.settledRerankEnabled
    state.keyboardAppEnglishBundleIDsText = OwlKeyboardPreferences.appEnglishBundleIDs.joined(separator: ", ")
    // Seed Cloud lane preferences. These remain default-off and explicit-trigger only.
    state.cloudEnabled = OwlCloudPreferences.isEnabled
    state.cloudModel = OwlCloudPreferences.deepSeekModel
    // Seed selection-menu skill platform preferences.
    state.selectionMenuEnabled = OwlSelectionMenuPreferences.isEnabled
    state.askAnythingSkillEnabled = OwlSelectionMenuPreferences.askEnabled
    state.sourceVerificationSkillEnabled = OwlSelectionMenuPreferences.sourceVerificationEnabled
    state.researchAssistSkillEnabled = OwlSelectionMenuPreferences.researchAssistEnabled
    state.publishFormattingSkillEnabled = OwlSelectionMenuPreferences.publishFormattingEnabled
    state.translationSkillEnabled = OwlSelectionMenuPreferences.translationEnabled
    // Seed the engine version for the 关于 page (best-effort; empty when absent).
    state.engineVersion = engineVersion() ?? ""
    OwlLatencyTrace.event("window.settings.dataLoaded")

    let window = owlSettingsWindow ?? OwlSettingsWindow()
    owlSettingsWindow = window
    OwlLatencyTrace.event("window.settings.controllerSelected")

    window.show(
      state: state,
      onSelectSchema: { [weak self] schemaID in
        guard let self else { return }
        let deferred = self.selectSettingsSchema(schemaID) { selected in
          // Never highlight or announce the requested schema when the engine rejected it. On a clean
          // install this is the exact interval in which the dict-pack consent/download UI takes over.
          let actualSchemaID = self.currentSchemaId()
          if !actualSchemaID.isEmpty { state.currentSchemaId = actualSchemaID }
          state.statusMessage = selected
            ? NSLocalizedString("已切换方案并应用配置改动。", comment: "schema switched")
            : NSLocalizedString("方案尚不可用；请先下载完整词库或按提示重试。", comment: "schema unavailable")
        }
        if deferred { state.statusMessage = "当前输入完成后切换方案。" }
      },
      onRedeploy: { [weak self] in
        let ok = self?.runtime.redeploy() ?? false
        state.statusMessage = ok
          ? NSLocalizedString("已应用配置改动。", comment: "redeployed")
          : NSLocalizedString("应用配置失败，请查看诊断日志。", comment: "redeploy failed")
        return ok
      },
      onApplyKeyboardConfigFast: { [weak self] in
        try self?.runtime.applyKeyboardSettings(.config) ?? .init(written: [], succeeded: false)
      },
      onApplyFuzzyConfigFast: { [weak self] in
        try self?.runtime.applyKeyboardSettings(.fuzzy) ?? .init(written: [], succeeded: false)
      },
      userDataActions: .init(
        resetUserDict: { [weak self] in
          guard let self, OwlUserDictResetPrompt.confirm() else { return }
          state.statusMessage = self.runtime.resetUserDict()
        }
      ),
      onOpenDataFolder: { [weak self] in
        self?.openDataFolder()
      },
      onOpenLog: { [weak self] in
        self?.openLogFolder()
      },
      onShowOnboarding: { [weak self] in
        self?.showOnboarding()
      },
      onPanelPreferencesChanged: { [weak self] in
        guard let self else { return }
        self.runtime.applyPanelPreferences()
        self.owlPanel?.refreshPreferences()
        OwlInputStatusPanel.shared.refreshPreferences()
      }
    )
    OwlLatencyTrace.event("window.settings.firstVisible")
  }

  @objc func openSettingsFromApplicationMenu(_ sender: Any?) {
    showSettings()
  }

  private func showSettingsForUITest() {
    let state = OwlSettingsState()
    state.schemas = [SchemaItem(id: "rime_ice", name: "雾凇拼音")]
    state.currentSchemaId = "rime_ice"
    state.currentInputSourceDisplayName = "Owltype UI Test"
    state.engineVersion = "ui-test"

    let window = owlSettingsWindow ?? OwlSettingsWindow()
    owlSettingsWindow = window
    window.show(
      state: state,
      onSelectSchema: { state.currentSchemaId = $0 },
      onRedeploy: { true },
      onApplyKeyboardConfigFast: { .init(written: [], succeeded: true) },
      onApplyFuzzyConfigFast: { .init(written: [], succeeded: true) },
      userDataActions: .init(
        resetUserDict: {}
      ),
      onOpenDataFolder: {},
      onOpenLog: {},
      onShowOnboarding: {},
      onPanelPreferencesChanged: {}
    )
  }

  // MARK: - v0.3.3 onboarding window

  /// Build (or reuse) the onboarding window and show it. Mirrors `showSettings()`'s
  /// lazy-window + callback pattern. All four callbacks forward to already-safe
  /// delegate actions; none touch the key-event hot path.
  func showOnboarding() {
    let trace = OwlLatencyTrace.begin("window.open.onboarding")
    defer { OwlLatencyTrace.end("window.open.onboarding", trace) }
    let window = owlOnboardingWindow ?? OwlOnboardingWindow()
    owlOnboardingWindow = window

    window.show(
      onOpenSystemSettings: {
        // Deep-link the input-sources pane. NEEDS REAL-MACHINE VERIFICATION: the
        // exact pane URL is version-sensitive; falls back silently if it fails.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
          NSWorkspace.shared.open(url)
        }
      },
      onSelectSchema: { [weak self] schemaID in
        // 应用配置: route through the same pref-write + patch + fast-apply pipeline the
        // 键盘输入 settings page uses (see `applyOnboardingScheme`) — a raw `selectSchema`
        // alone doesn't stick, because every new session re-reads and re-enforces
        // `OwlKeyboardPreferences.preferredSchemaID`, which this never touched.
        self?.applyOnboardingScheme(schemaID)
      },
      onOpenInputSettings: { [weak self] in
        self?.showSettings()
        // Land the user on the 键盘输入 page (already the default selection).
        self?.owlSettingsWindow?.window?.makeKeyAndOrderFront(nil)
      },
      onFinish: { [weak self] in
        OwlOnboarding.isDone = true
        self?.owlOnboardingWindow?.close()
      },
      isOwltypeEnabled: {
        // Real enabled status for the 启用 step (TIS), matching OwlInstaller.register.
        !OwlInstaller().enabledModes().isEmpty
      }
    )
  }

  /// Installed schemas, via the Engine seam (`get_schema_list`). Best-effort: returns
  /// an empty list if the engine is not yet deployed.
  func loadSchemaList() -> [SchemaItem] {
    runtime.engine.schemaList().map { SchemaItem(id: $0.id, name: $0.name) }
  }

  /// Best-effort current schema id, read via the Engine's transient session. Returns ""
  /// when unavailable (e.g. before the first deploy).
  func currentSchemaId() -> String {
    runtime.engine.currentSchema()
  }

  /// the engine version string for the 关于 page, via the Engine seam (`get_version`).
  /// Returns nil when the getter or string is unavailable so the About page omits
  /// the row gracefully (never crashes).
  func engineVersion() -> String? {
    runtime.engine.version()
  }

  /// Switch the active schema (输入方式/双拼 picker, 方案切换 row). PR3: this no longer runs
  /// the heavy full `runtime.redeploy()`. Schema configs
  /// are already built, so switching is `select_schema`-only:
  ///   1. `engine.selectSchema(id)` on a transient session — the engine REMEMBERS the selection
  ///      for subsequent new sessions (e.g. the next app the user types in).
  ///   2. switch the ACTIVE controller's LIVE session in place (`select_schema(id)` re-reads
  ///      the built `build/<id>.schema.yaml`; no dict/octagram rebuild) so the current
  ///      composition window immediately uses the new schema.
  ///   3. reload style flags so the new schema's layout (linear/vertical/inline) takes effect.
  /// Wrapped in a `OwlPerf` mark. Off the IMK keystroke hot path.
  //
  // NEEDS REAL-MACHINE VERIFICATION: live typing session picking up the switched schema.
  @discardableResult
  func selectSchema(_ id: String) -> Bool {
    guard !id.isEmpty else { return false }
    let schemaTrace = OwlLatencyTrace.begin("deploy.schemaSwitch")
    defer { OwlLatencyTrace.end("deploy.schemaSwitch", schemaTrace) }
    let perf = OwlPerf.mark()
    let engineSelected = runtime.engine.selectSchema(id)          // remembered for future sessions
    let result = runtime.activeInputController?.switchLiveSessionSchema(to: id) // live session, no full deploy
    let failedID = OwlSchemaSelectionGate.failedSchemaID(
      requested: id, engineSelected: engineSelected, liveResult: result
    )
    if let failedID {
      Self.notifySchemaNotCompiled(failedID)
    }
    runtime.loadSettings()
    runtime.loadSettings(for: id)
    OwlPerf.since(perf, "fastapply.schema")
    return failedID == nil
  }

  /// Settings/onboarding entry point. Rust decides when the native idle queue may drain;
  /// the effect interface `selectSchema` remains available for explicit host/menu operations.
  /// Returns whether queued; completion reports the actual selection result after the boundary.
  @discardableResult
  func selectSettingsSchema(_ id: String, completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
    MainActor.assumeIsolated {
      runtime.requestLiveSessionRefreshWhenIdle { [weak self] in
        completion(self?.selectSchema(id) ?? false)
      }
    }
  }

  /// Onboarding's 选方案 step entry point. A raw `selectSchema(_:)` alone doesn't stick for a
  /// schema outside the bundled `default.yaml` `schema_list` (e.g. 五笔 `wubi86_jidian`):
  /// every new session reads `OwlKeyboardPreferences.preferredSchemaID` and re-enforces it on
  /// every idle keystroke, so an unset preference silently overwrites the pick back to pinyin.
  /// Rust supplies the existing onboarding preference writes. Scheme selection and settings
  /// activation share the keyboard page's idle boundary, preserving the current composition.
  func applyOnboardingScheme(_ schemaID: String) {
    let writes: [String: String] = OwlAppCore.required(["operation": "keyboard_onboarding", "schema": schemaID])
    for (key, value) in writes { OwlDefaults.standard.set(value, forKey: key) }
    selectSettingsSchema(schemaID)
    do {
      _ = try runtime.applyKeyboardSettings(.config)
    } catch {
      print("Onboarding scheme patch write failed: \(error)")
    }
  }

  func checkForUpdates() {
    OwlLatencyTrace.event("button.open.checkUpdates")
    if updateController.updater.canCheckForUpdates {
      print("Checking for updates")
      updateController.updater.checkForUpdates()
    } else {
      print("Cannot check for updates")
    }
  }

  func openWiki() {
    NSWorkspace.shared.open(Self.rimeWikiURL)
  }

  /// 用户可感反馈（决策点 1）：显式切方案失败（多因 build/<id>.schema.yaml 未编译）。走已有系统
  /// 通知，不静默——否则 UI 显示新方案而实际输出仍是旧方案（设置显示拼音 / 打字出五笔）。
  /// 抽成具名方法：dict-pack 分流后有两个调用点（同步路径 + 主线程补发）。
  static func notifySchemaNotCompiled(_ failedID: String) {
    showMessage(msgText: "无法切换到方案「\(failedID)」：请在设置里「应用配置改动」后重试；仍失败时请查看诊断日志。")
  }

  static func showMessage(msgText: String?) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .provisional]) { _, error in
      if let error = error {
        print("User notification authorization error: \(error.localizedDescription)")
      }
    }
    center.getNotificationSettings { settings in
      if (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) && settings.alertSetting == .enabled {
        let content = UNMutableNotificationContent()
        content.title = "法墨输入法"
        if let msgText = msgText {
          content.subtitle = msgText
        }
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: nil)
        center.add(request) { error in
          if let error = error {
            print("User notification request error: \(error.localizedDescription)")
          }
        }
      }
    }
  }

  func setupEngine() {
    do {
      try OwlPrivateStorage.prepareDirectory(OwlApp.userDir)
    } catch {
      print("Owltype: failed to secure user data directory: \(error)")
      createDirIfNotExist(path: OwlApp.userDir)
    }
    createDirIfNotExist(path: OwlApp.logDir)
    _ = try? OwlAutomaticExpansionRuntime.shared.reload(dataDir: OwlApp.userDir, defaults: OwlDefaults.standard)
    runtime.engine.setNotificationHandler { [weak self] sessionID, messageType, messageValue in
      guard let self else { return }
      notificationHandler(
        delegate: self,
        sessionId: sessionID,
        messageType: messageType,
        messageValue: messageValue
      )
    }
    runtime.engine.setup(
      OwlEngineTraits(
        sharedDataDir: URL(
          fileURLWithPath: Bundle.main.sharedSupportPath!,
          isDirectory: true
        ),
        userDataDir: OwlApp.userDir
      )
    )
  }

  /// Feature 1: apply 简↔繁 to the live session right away from the settings UI — no redeploy.
  /// Sets the FULL simplification/traditional option set (`transcription` for 全拼/双拼,
  /// `zh_trad` for 五笔, plus the legacy `traditional`/`traditionalization`/`simplification`)
  /// so the single「简入繁出」switch is global across every exposed schema. The pref write
  /// stays in the settings layer; this only flips the options + re-renders the in-flight
  /// composition. Seeded on session create (`createSession`) so the choice survives focus changes.
  func applyTraditionalOutputToLiveSession(_ traditional: Bool) {
    runtime.activeInputController?.setTraditionalOutputOptions(traditional)
    runtime.activeInputController?.engineUpdate()
  }

  /// 候选 emoji 开关 live 生效（仿 `applyTraditionalOutputToLiveSession`）：切当前会话的
  /// `emoji` option（rime-ice 的 emoji switch 名），立即重算候选。新会话由 `createSession` 按 pref 重新 seed。
  func applyEmojiSuggestionToLiveSession(_ enabled: Bool) {
    runtime.activeInputController?.setEngineOption(.emojiSuggestion, enabled)
    runtime.activeInputController?.engineUpdate()
  }

  /// 默认状态·中英文 live 生效：改下拉时立刻把当前会话切到 中文/英文（`ascii_mode`）。新会话由
  /// `createSession` 按 `defaultAsciiMode` pref 重新 seed。
  func applyDefaultAsciiModeToLiveSession(_ english: Bool) {
    runtime.activeInputController?.setEngineOption(.asciiMode, english)
    runtime.activeInputController?.engineUpdate()
  }

  /// 默认状态·全半角 live 生效：改下拉时立刻把当前会话切到 半角/全角（`full_shape`）。新会话由
  /// `createSession` 按 `defaultFullShape` pref 重新 seed。
  func applyDefaultFullShapeToLiveSession(_ fullShape: Bool) {
    runtime.activeInputController?.setEngineOption(.fullShape, fullShape)
    runtime.activeInputController?.engineUpdate()
  }

  // prevent freezing the system
  func problematicLaunchDetected() -> Bool {
    var detected = false
    let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("owl_launch.json", conformingTo: .json)
    // print("[DEBUG] archive: \(logFile)")
    do {
      let archive = try Data(contentsOf: logFile, options: [.uncached])
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      let previousLaunch = try decoder.decode(Date.self, from: archive)
      if previousLaunch.timeIntervalSinceNow >= -2 {
        detected = true
      }
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {

    } catch {
      print("Error occurred during processing launch time archive: \(error.localizedDescription)")
      return detected
    }
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      let record = try encoder.encode(Date.now)
      try record.write(to: logFile)
    } catch {
      print("Error occurred during saving launch time to archive: \(error.localizedDescription)")
    }
    return detected
  }

  // add an awakeFromNib item so that we can set the action method.  Note that
  // any menuItems without an action will be disabled when displayed in the Text
  // Input Menu.
  func addObservers() {
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil, using: workspaceWillPowerOff)

    let notifCenter = DistributedNotificationCenter.default()
    // Observer side of the DNC-suspension fix (2026-07-24, see Main.swift `--reload`): the
    // block API registers with the default `.coalesce` suspension behavior, and NSApplication
    // suspends DNC delivery once the app has been active and resigned — after any
    // settings-window visit a default post queues forever and the CLI notifications go dead.
    // Selector registration is the only API that exposes `suspensionBehavior`;
    // `.deliverImmediately` keeps these observers reachable from ANY poster (including an
    // older CLI binary that posts without deliverImmediately).
    notifCenter.addObserver(self, selector: #selector(engineNeedsReload(_:)), name: .init("OwlReloadNotification"), object: nil, suspensionBehavior: .deliverImmediately)
    notifCenter.addObserver(self, selector: #selector(engineToggleASCIIMode(_:)), name: .init("OwlToggleASCIIModeNotification"), object: nil, suspensionBehavior: .deliverImmediately)
    notifCenter.addObserver(self, selector: #selector(engineGetASCIIMode(_:)), name: .init("OwlGetASCIIModeNotification"), object: nil, suspensionBehavior: .deliverImmediately)
    notifCenter.addObserver(self, selector: #selector(showSettingsFromNotification(_:)), name: .init("OwlShowSettingsNotification"), object: nil, suspensionBehavior: .deliverImmediately)
    // 授权后补装 tap 的第二保险（第一保险=applicationDidBecomeActive）：TCC 辅助功能表变更时
    // 系统会广播这条 DNC（未文档化、10.9 起稳定，alt-tab 等在用）。任何 app 的授权变化都触发、
    // 无 payload——只当「该重查一次」的信号用，让用户在系统设置里勾上开关的瞬间 tap 就位，
    // 不必切回法墨窗口。通知名将来若失效，无声退化为 didBecomeActive 补装，无副作用。
    notifCenter.addObserver(self, selector: #selector(accessibilityAPIChanged(_:)), name: .init("com.apple.accessibility.api"), object: nil, suspensionBehavior: .deliverImmediately)
    notifCenter.addObserver(forName: .init(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
      self?.finalizeStrandedComposition()
      // （旧划词小菜单在此收起；工具箱是标准窗口，切输入源不需要动它——2026-07-26 重设计。）
      // S1/R5: if the selected source is a Owltype mode that is NOT truly enabled (the
      // key-swallowing dead half-state), log + surface copyable recovery guidance.
      // Not the IMK hot path: this fires only on selected-source CHANGE, not per keystroke.
      OwlInstaller().detectAndGuideIfHalfState()
    }
  }

  /// Install-time activation repair: refreshes registration without rewriting system input prefs.
  ///
  /// Invoked ONCE, only when the installed executable is launched with `--activate-once` as the
  /// login user inside the Aqua GUI session. The installer GUI process owns `TISEnableInputSource`
  /// and any macOS consent prompt; this method must not write `AppleEnabledInputSources`, because
  /// that can create duplicate TIS rows and hide Owltype from the input menu.
  func selfHealActivationIfNeeded() {
    OwlInstaller().repairRegistrationForInstalledBundle()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    print("Owltype is quitting.")
    _ = runtime.engine.finalize()
    return .terminateNow
  }

}

private func notificationHandler(
  delegate: OwlApplicationDelegate,
  sessionId: UInt64,
  messageType: String,
  messageValue: String?
) {
  if messageType == "deploy" {
    switch messageValue {
    case "start":
      OwlApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_start", comment: ""))
    case "success":
      OwlApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_success", comment: ""))
    case "failure":
      OwlApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_failure", comment: ""))
    default:
      break
    }
    return
  }

  if messageType == "option" {
    let state = messageValue?.first != "!"
    let optionName: String?
    if state {
      optionName = messageValue
    } else if let value = messageValue {
      optionName = String(value[value.index(after: value.startIndex)...])
    } else {
      optionName = nil
    }
    if let optionName = optionName {
      // The reported option `name` is an open namespace owned by Rime/the schema, so it
      // stays a String (not a EngineOption). Read its label through the Engine's session
      // wrapper for the engine-supplied session id.
      let session = delegate.runtime.engine.session(for: sessionId)
      func shortLabel() -> String? {
        session.stateLabel(option: optionName, state: state, abbreviated: true)
      }
      func longLabel() -> String? {
        session.stateLabel(option: optionName, state: state, abbreviated: false)
      }
      // Feature 5: option toggles (中英 / 全半角 / 简繁 …) only toast on 始终 (`.always`);
      // 智能 (`.appropriate`) keeps them quiet, 从不 (`.never`) suppresses everything.
      if OwlCandidatePanelSettings.live.shouldShowNotification(for: .option) {
        delegate.showStatusMessage(msgTextLong: longLabel(), msgTextShort: shortLabel())
      }
    }
    return
  }

  // Feature 5: schema switches toast on 始终 + 智能 (i.e. anything but 从不).
  if messageType == "schema",
     OwlCandidatePanelSettings.live.shouldShowNotification(for: .schema),
     let messageValue,
     let schemaName = try? /^[^\/]*\/(.*)$/.firstMatch(in: messageValue)?.output.1 {
      delegate.showStatusMessage(msgTextLong: String(schemaName), msgTextShort: String(schemaName))
      return
  }
}

private extension OwlApplicationDelegate {
  internal func showStatusMessage(msgTextLong: String?, msgTextShort: String?) {
    guard !(msgTextLong ?? "").isEmpty || !(msgTextShort ?? "").isEmpty else { return }
    let messageType = runtime.styleFlags.statusMessageType
    // The toast is an NSPanel — show it on the main thread (a Rime option/schema
    // notification can arrive off-main). The anchor is read INSIDE the hop for the same
    // reason: it now asks NSWorkspace which app is frontmost, which belongs on main.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.ensureStatusHUD().show(
        long: msgTextLong ?? "",
        short: msgTextShort ?? "",
        messageType: messageType,
        anchor: self.currentHostCaretAnchor
      )
    }
  }

  // macOS 26 does not call deactivateServer when the input source is switched
  // away by another process via TISSelectInputSource() (e.g. macism, Input
  // Source Pro): the pending composition is stranded and the candidate panel
  // is left orphaned on screen (#1140). The input-source-changed notification
  // is still delivered, so finalize the composition here as a fallback.
  // Switching via the menu bar calls deactivateServer first, making this a
  // no-op.
  func finalizeStrandedComposition() {
    let currentInputSourceID = OwlInstaller.currentInputSourceID() ?? ""
    guard !currentInputSourceID.hasPrefix(OwlInstaller.inputSourcePrefix) else { return }
    if let inputController = runtime.activeInputController {
      let trace = OwlLatencyTrace.begin("strandedComposition.finalize")
      defer { OwlLatencyTrace.end("strandedComposition.finalize", trace) }
      inputController.deactivateServer(inputController.client())
    }
  }


  func workspaceWillPowerOff(_: Notification) {
    print("Finalizing before logging out.")
    _ = self.runtime.shutdown()
  }

  @objc func engineNeedsReload(_: Notification) {
    let trace = OwlLatencyTrace.begin("reload.notification")
    defer { OwlLatencyTrace.end("reload.notification", trace) }
    print("Reloading the engine on demand.")
    // 送达凭据：通知丢失时 app 侧和 引擎侧都零日志（2026-07-24 静默 reload 排查的盲区）。
    EngineRuntime.deployLog.notice("OwlReloadNotification received — starting full deploy")
    let ok = self.runtime.redeploy()
    if ok {
      EngineRuntime.deployLog.notice("reload deploy succeeded")
    } else {
      EngineRuntime.deployLog.error("reload deploy FAILED — see the engine log in \(OwlApp.logDir.path, privacy: .public)")
    }
  }

  @objc func engineToggleASCIIMode(_ notification: Notification) {
    guard let mode = notification.object as? String else { return }
    let enableASCII = mode == "ascii"

    if enableASCII {
      NotificationCenter.default.post(name: .init("OwlSetASCIIModeNotification"), object: true)
    } else {
      NotificationCenter.default.post(name: .init("OwlSetASCIIModeNotification"), object: false)
    }
  }

  @objc func engineGetASCIIMode(_: Notification) {
    NotificationCenter.default.post(name: .init("OwlReportASCIIModeNotification"), object: nil)
  }

  @objc func showSettingsFromNotification(_: Notification) {
    DispatchQueue.main.async { [weak self] in
      self?.showSettings()
    }
  }

  @objc func accessibilityAPIChanged(_: Notification) {
    // 缓半秒再查：通知可能略早于 tccd 落库；这次仍读到未授权也无妨，didBecomeActive 兜底。
    // 绝非轮询——每次 TCC 变更只补查这一次。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.hotKeyTap.startIfPossible()
    }
  }

  func createDirIfNotExist(path: URL) {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: path.path) {
      do {
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
      } catch {
        print("Error creating user data directory: \(path.path)")
      }
    }
  }
}

extension NSApplication {
  var owlAppDelegate: OwlApplicationDelegate {
    self.delegate as! OwlApplicationDelegate
  }
}
