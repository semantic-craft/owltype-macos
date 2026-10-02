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
  static let rimeWikiURL = URL(string: "https://github.com/rime/home/wiki")!
  static let updateNotificationIdentifier = "OwlUpdateNotification"
  static let notificationIdentifier = "OwlNotification"
  /// Deploy/reload lifecycle evidence in the unified log. `print` from an IME process goes
  /// nowhere useful, and rime's glog can't record a notification that never reached the
  /// process — this channel is the app-side proof of "reload arrived / deploy succeeded or
  /// failed". Read with:
  ///   log show --predicate 'subsystem == "im.owltype.inputmethod.Owltype" && category == "deploy"' --info
  static let deployLog = Logger(subsystem: "im.owltype.inputmethod.Owltype", category: "deploy")

  /// The single owner of the global librime lifecycle. The input controller obtains its
  /// per-composition Session from this engine (via `NSApp.owlAppDelegate.engine`), the
  /// same indirection pattern as `ensureOwltypePanel`. Swappable so tests can inject a fake.
  var engine: RimeEngine = LiveRimeEngine()
  /// The controller's read-only view of the live composition snapshot, behind the narrow
  /// `SnapshotReading` port (same composition-root pattern as `engine`). Default is the
  /// production `.shared` registry; swappable so tests can inject a scripted snapshot.
  var snapshots: SnapshotReading = OwlSnapshotRegistry.shared
  /// The controller's composition-timeline snapshot emitter, behind the narrow
  /// `SnapshotEmitting` port (same composition-root pattern as `engine`). Default is the
  /// production `.shared` emitter; swappable so tests can drive the snapshot path and assert
  /// the emitted call/args without a librime session.
  var snapshotEmitter: SnapshotEmitting = OwlSnapshotEmitter.shared
  /// The controller's explicit 润色选中 rewrite, behind the narrow `SelectionPolishing` port.
  /// Default is the production `.shared` service; swappable so tests can return scripted
  /// rewrites without DeepSeek or the keychain.
  var selectionPolish: SelectionPolishing = OwlSelectionPolishService.shared
  /// The controller's prompt-commit resolver, behind the narrow `PromptResolving` port. Given the
  /// originating trigger code + committed candidate title, returns the matching 提示词 entry (or
  /// nil). Default is the production `.shared` resolver (reads owl_prompts.json on a 📝 commit);
  /// swappable so tests can return a scripted entry without disk.
  var promptStore: PromptResolving = OwlPromptResolver.shared
  /// Central host-client compatibility policy. Pure and swappable in tests; controller code asks
  /// it before risky IMK/AX host reads.
  var clientCapabilityPolicy = OwlClientCapabilityPolicy()
  var clientWorkarounds = OwlClientWorkaroundSettings()
  var suppressOnboarding = false
  var config: OwlConfig?
  /// Candidate-window LAYOUT flags read from Rime `style/*` (linear/vertical/inline*),
  /// read live by the IMK path (was `panel.linear` etc. on the deleted OwlPanel/OwlTheme).
  /// Seeded in `loadSettings` from the global config, overridden per-schema in
  /// `loadSettings(for:)`. Not theming — the skin/colors live in `OwlThemes`.
  var styleFlags = OwlStyleFlags()
  /// The active input controller (was `panel.inputController`), set by the controller on
  /// each `showPanel`. Used by `finalizeStrandedComposition` to finalize a stranded
  /// composition when the input source is switched away.
  weak var activeInputController: OwlInputController?
  /// Registry of every LIVE controller (one per host-app input session). WEAK members — a
  /// controller registers itself when it creates a session (and on each `showPanel`); dead
  /// controllers drop out automatically via `NSHashTable.weakObjects()` + `destroySession`,
  /// so there is no retain cycle and no manual unregister bookkeeping. The fast settings-apply
  /// path (`reapplyToLiveSession`) iterates this to force EVERY live session to reload the
  /// freshly-deployed `build/` (a fresh session reads the new config; a same-id reselect does
  /// NOT, which was the page_size-not-applying bug). Off the IMK keystroke hot path.
  let liveControllers = NSHashTable<OwlInputController>.weakObjects()

  /// Register a controller as live (idempotent — `NSHashTable` ignores duplicates). Called by
  /// the controller from `createSession` / `showPanel`. Off the IMK keystroke hot path.
  func registerLiveController(_ controller: OwlInputController) {
    liveControllers.add(controller)
  }
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
    addObservers()
    selectionMenuCoordinator = OwlSelectionMenuCoordinator()
    selectionMenuCoordinator?.start()
    startHotKeyTap()
    // v0.3.3: first-run onboarding. Guarded + non-blocking (just orders the window
    // front); kept LAST so it never interferes with Rime / panel / status setup.
    if !suppressOnboarding && !OwlOnboarding.isDone {
      showOnboarding()
    }
    // #16 新方向：更新后强推注销（免注销自动保持选中态真机不可靠）。首启不弹（首装走 pkg RequireLogout）。
    let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    OwlUpdateLogoutPrompt.runIfNeeded(current: currentVersion)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    // 授权后补装（2026-07-26）：启动时 AX 未授权则 tap 缺席，事后授权不会自动送达任何事件，
    // 录制热键在 Chromium/Electron 宿主失灵直到注销。用户去系统设置授权后切回猫头鹰窗口的
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
    statusHUD?.hidePanel()
    owlPanel?.hidePanel()
  }

  @discardableResult
  func deploy() -> Bool {
    let trace = OwlLatencyTrace.begin("deploy.full")
    defer { OwlLatencyTrace.end("deploy.full", trace) }
    print("Start maintenance...")
    OwlLatencyTrace.event("deploy.maintenanceStart")
    self.shutdownRime()
    let ok = self.startRime(fullCheck: true)
    OwlLatencyTrace.event("deploy.restoreSettings")
    self.loadSettings()
    OwlLatencyTrace.event("deploy.finalUIState")
    return ok
  }

  // Fast settings-apply (Track 2 / PR3) lives in `OwlApplicationDelegate+FastApply.swift`.

  func syncUserData() {
    let trace = OwlLatencyTrace.begin("sync.userData")
    defer { OwlLatencyTrace.end("sync.userData", trace) }
    print("Sync Owltype user data")
    _ = engine.syncUserData()
  }

  /// 「重置用户词典…」(#37)：整目录备份 `*.userdb` → 删除 → 重新部署，Rime 重建空库。
  /// 返回给「维护与诊断」卡状态行的文案。
  ///
  /// 顺序是硬约束，不是风格选择：userdb 的 LevelDB 被**猫头鹰自己这个进程**独占锁着
  /// （2026-07-25 实测，外部 `rime_dict_manager -e` 报 `Error opening db read-only`），
  /// 所以必须先 `finalize()` 放锁才删得动。`deploy()` 已经在跑同一条
  /// shutdownRime → startRime(fullCheck:) → loadSettings 的路，这里只是在中间插入删除。
  ///
  /// 无论删除成败都把引擎重新拉起来：半死在「已 finalize」状态会让输入法整个不能打字，
  /// 比重置失败严重得多。
  func resetUserDict() -> String {
    let trace = OwlLatencyTrace.begin("reset.userDict")
    defer { OwlLatencyTrace.end("reset.userDict", trace) }
    Self.deployLog.notice("reset user dict requested — finalizing rime to release the userdb lock")
    shutdownRime()

    let result = Result {
      try OwlUserDictReset.run(root: OwlApp.userDir, timestamp: Self.backupTimestamp())
    }

    let redeployed = startRime(fullCheck: true)
    loadSettings()

    switch result {
    case .success(let outcome):
      Self.deployLog.notice("""
        reset user dict cleared \(outcome.schemaIDs.count, privacy: .public) schema(s), \
        redeploy=\(redeployed, privacy: .public)
        """)
      return OwlUserDictReset.statusMessage(outcome: outcome, redeployed: redeployed)
    case .failure(let error):
      Self.deployLog.error("""
        reset user dict FAILED (restored from backup): \
        \(error.localizedDescription, privacy: .public), redeploy=\(redeployed, privacy: .public)
        """)
      return OwlUserDictReset.failureMessage(error: error, redeployed: redeployed)
    }
  }

  /// 备份目录名用的文件系统安全时间戳。只在用户显式点击时调用，故直接读 `Date()`。
  private static func backupTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  func chooseSyncDirectory(for state: OwlSettingsState) {
    let settings = OwlRimeSyncSettings()
    let panel = NSOpenPanel()
    panel.title = NSLocalizedString("选择同步目录", comment: "choose Rime user-data sync directory")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = settings.currentSyncDirectory()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try settings.setSyncDirectory(url)
      state.syncDirectoryDisplayPath = settings.syncDirectoryDisplayPath
      state.statusMessage = NSLocalizedString("已设置同步目录。再次点击同步用户数据即可写入快照。", comment: "sync dir set")
    } catch {
      state.statusMessage = NSLocalizedString("设置同步目录失败，请查看诊断日志。", comment: "sync dir failed")
      print("Failed to set Owltype sync directory: \(error)")
    }
  }

  func openLogFolder() {
    NSWorkspace.shared.open(OwlApp.logDir)
  }

  func openRimeFolder() {
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
  private var owlQuickSendPanel: OwlQuickSendPanel?

  /// The controller binds this adapter to its original IMK client. The picker transfers its
  /// captured focus to the selected invocation, including when a fill window follows.
  func showQuickSendPanel(
    onInvoke: ((OwlTemplateInvocation.Content, OwlPanelInsertionBroker, OwlTemplateInvocation.Intent) -> Void)? = nil,
    initialSegment: OwlPickerSegment = .phrase
  ) {
    let trace = OwlLatencyTrace.begin("window.open.quickSend")
    defer { OwlLatencyTrace.end("window.open.quickSend", trace) }
    OwlPromptFillSheet.shared.dismissForNewInvocation()
    let panel = owlQuickSendPanel ?? OwlQuickSendPanel()
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
      guard let controller = self?.activeInputController else {
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
    hotKeyTap.onPromptAssistant = { [weak self] in
      guard let controller = self?.activeInputController else {
        OwlHotKeyMatcher.log.notice("promptAssistant fired but activeInputController=nil — dropped")
        return
      }
      controller.showOwltypePromptPicker(initialSegment: .prompt)
    }
    hotKeyTap.startIfPossible()
  }

  func stopHotKeyTap() {
    hotKeyTap.stop()
  }

  // MARK: - v0.2 settings window

  /// Build (or reuse) the settings window, populate its state, and show it.
  /// Mirrors the `ensureOwltypePanel()` lazy-create pattern.
  func showSettings(selectedPage: OwlSettingsPage = .keyboard) {
    let trace = OwlLatencyTrace.begin("window.open.settings")
    defer { OwlLatencyTrace.end("window.open.settings", trace) }
    let state = OwlSettingsState()
    state.selectedPage = selectedPage
    state.schemas = loadSchemaList()
    state.currentSchemaId = currentSchemaId()
    state.currentInputSourceDisplayName = OwlInstaller.currentInputSourceDisplayName()
    // Seed the complete candidate-panel lifecycle from its single module boundary.
    OwlCandidatePanelSettings.live.seed(state)
    state.candidatePageSize = OwlKeyboardPreferences.pageSize
    // Seed the 键盘输入 option groups from their single home (OwlKeyboardPreferences).
    state.keyboardInputMethod = OwlKeyboardPreferences.inputMethod
    state.keyboardDoublePinyin = OwlKeyboardPreferences.doublePinyin
    state.keyboardWubiCodeHint = OwlKeyboardPreferences.wubiCodeHint
    state.keyboardWubiAutoClear = OwlKeyboardPreferences.wubiAutoClear
    state.keyboardWubiCandidateMode = OwlKeyboardPreferences.wubiCandidateMode
    state.keyboardWubiScheme = OwlKeyboardPreferences.wubiScheme
    state.keyboardWubiZReverseLookup = OwlKeyboardPreferences.wubiZReverseLookup
    state.keyboardWubiEnglishChannel = OwlKeyboardPreferences.wubiEnglishChannel
    state.keyboardWubiUserDictLearning = OwlKeyboardPreferences.wubiUserDictLearning
    state.keyboardShiftSwitchCJK = OwlKeyboardPreferences.shiftSwitchCJK
    state.keyboardCJKPunctToggle = OwlKeyboardPreferences.cjkPunctToggle
    state.keyboardTraditionalOutput = OwlKeyboardPreferences.traditionalOutput
    state.keyboardDefaultAsciiMode = OwlKeyboardPreferences.defaultAsciiMode
    state.keyboardDefaultFullShape = OwlKeyboardPreferences.defaultFullShape
    state.keyboardGoodOldCapsLock = OwlKeyboardPreferences.goodOldCapsLock
    state.keyboardPageMinusEquals = OwlKeyboardPreferences.pageMinusEquals
    state.keyboardPageBrackets = OwlKeyboardPreferences.pageBrackets
    state.keyboardPageCommaPeriod = OwlKeyboardPreferences.pageCommaPeriod
    state.keyboardSelect23Semicolon = OwlKeyboardPreferences.select23Semicolon
    state.keyboardSlashSymbolMenu = OwlKeyboardPreferences.slashSymbolMenu
    state.keyboardAngleSymbolMenu = OwlKeyboardPreferences.angleSymbolMenu
    state.keyboardCJKAlnumSpacing = OwlKeyboardPreferences.cjkAlnumSpacing
    state.keyboardCJKEnglishSpacing = OwlKeyboardPreferences.cjkEnglishSpacing
    state.keyboardCJKNumberSpacing = OwlKeyboardPreferences.cjkNumberSpacing
    state.keyboardAutoPairBrackets = OwlKeyboardPreferences.autoPairBrackets
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
    // Seed the librime version for the 关于 page (best-effort; empty when absent).
    state.librimeVersion = rimeVersion() ?? ""
    state.syncDirectoryDisplayPath = OwlRimeSyncSettings().syncDirectoryDisplayPath
    OwlLatencyTrace.event("window.settings.dataLoaded")

    let window = owlSettingsWindow ?? OwlSettingsWindow()
    owlSettingsWindow = window
    OwlLatencyTrace.event("window.settings.controllerSelected")

    window.show(
      state: state,
      onSelectSchema: { [weak self] schemaID in
        guard let self else { return }
        let selected = self.selectSchema(schemaID)
        // Never highlight or announce the requested schema when librime rejected it. On a clean
        // install this is the exact interval in which the dict-pack consent/download UI takes over.
        let actualSchemaID = self.currentSchemaId()
        if !actualSchemaID.isEmpty { state.currentSchemaId = actualSchemaID }
        state.statusMessage = selected
          ? NSLocalizedString("已切换方案并应用配置改动。", comment: "schema switched")
          : NSLocalizedString("方案尚不可用；请先下载完整词库或按提示重试。", comment: "schema unavailable")
      },
      onRedeploy: { [weak self] in
        let ok = self?.deploy() ?? false
        state.statusMessage = ok
          ? NSLocalizedString("已应用配置改动。", comment: "redeployed")
          : NSLocalizedString("应用配置失败，请查看诊断日志。", comment: "redeploy failed")
        return ok
      },
      onApplyKeyboardConfigFast: { [weak self] in
        try self?.applyKeyboardSettings(.config) ?? .init(written: [], succeeded: false)
      },
      onApplyFuzzyConfigFast: { [weak self] in
        try self?.applyKeyboardSettings(.fuzzy) ?? .init(written: [], succeeded: false)
      },
      onSyncUserData: { [weak self] in
        self?.syncUserData()
        state.statusMessage = NSLocalizedString("已请求同步用户数据。", comment: "sync user data")
      },
      onResetUserDict: { [weak self] in
        guard let self, OwlUserDictResetPrompt.confirm() else { return }
        state.statusMessage = self.resetUserDict()
      },
      onChooseSyncDirectory: { [weak self] in
        self?.chooseSyncDirectory(for: state)
      },
      onOpenRimeFolder: { [weak self] in
        self?.openRimeFolder()
      },
      onOpenLog: { [weak self] in
        self?.openLogFolder()
      },
      onShowOnboarding: { [weak self] in
        self?.showOnboarding()
      },
      onPanelPreferencesChanged: { [weak self] in
        guard let self else { return }
        OwlCandidatePanelSettings.live.applyInlineCandidate(to: &self.styleFlags)
        self.owlPanel?.refreshPreferences()
      }
    )
    OwlLatencyTrace.event("window.settings.firstVisible")
  }

  func showSettingsForUITest() {
    let state = OwlSettingsState()
    state.schemas = [SchemaItem(id: "rime_ice", name: "雾凇拼音")]
    state.currentSchemaId = "rime_ice"
    state.currentInputSourceDisplayName = "Owltype UI Test"
    state.librimeVersion = "ui-test"
    state.syncDirectoryDisplayPath = OwlRimeSyncSettings().syncDirectoryDisplayPath

    let window = owlSettingsWindow ?? OwlSettingsWindow()
    owlSettingsWindow = window
    window.show(
      state: state,
      onSelectSchema: { state.currentSchemaId = $0 },
      onRedeploy: { true },
      onApplyKeyboardConfigFast: { .init(written: [], succeeded: true) },
      onApplyFuzzyConfigFast: { .init(written: [], succeeded: true) },
      onSyncUserData: {},
      onResetUserDict: {},
      onChooseSyncDirectory: {},
      onOpenRimeFolder: {},
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
  /// an empty list if librime is not yet deployed.
  func loadSchemaList() -> [SchemaItem] {
    engine.schemaList().map { SchemaItem(id: $0.id, name: $0.name) }
  }

  /// Best-effort current schema id, read via the Engine's transient session. Returns ""
  /// when unavailable (e.g. before the first deploy).
  func currentSchemaId() -> String {
    engine.currentSchema()
  }

  /// librime version string for the 关于 page, via the Engine seam (`get_version`).
  /// Returns nil when the getter or string is unavailable so the About page omits
  /// the row gracefully (never crashes).
  func rimeVersion() -> String? {
    engine.version()
  }

  /// Switch the active schema (输入方式/双拼 picker, 方案切换 row). PR3: this no longer runs
  /// the heavy full `deploy()` (`shutdownRime` + `startRime(fullCheck:true)`). Schema configs
  /// are already built, so switching is `select_schema`-only:
  ///   1. `engine.selectSchema(id)` on a transient session — librime REMEMBERS the selection
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
    let engineSelected = engine.selectSchema(id)          // remembered for future sessions
    let result = activeInputController?.switchLiveSessionSchema(to: id) // live session, no full deploy
    let failedID = OwlSchemaSelectionGate.failedSchemaID(
      requested: id, engineSelected: engineSelected, liveResult: result
    )
    if let failedID {
      // 方案B 分流：失败若是「该方案的词库根本没随包分发」（dict-pack 未装），下面那条通知是**误导**
      // ——它叫用户去「应用配置改动」，可方案文件压根不在磁盘上，照做也没用。改弹版权说明并引导下载。
      // 这里只做纯 manifest 判定（本方法 nonisolated）；读运行期状态与弹窗都在主线程做，
      // 已装却选失败（真·未编译）时由 handleAbsentSchema 返回 false 补发原通知。必须同时
      // 检查 transient engine 的返回值：设置窗打开但没有活动输入框时 result == nil，过去
      // 正是在这里把全新安装的缺词库失败静默吞掉了。
      if OwlDictPackPrompt.isDictPackManagedSchema(failedID) {
        Task { @MainActor in
          // A newer picker action may have replaced this failed request before the task runs.
          // Do not let an obsolete Wubi failure pop over a later successful Pinyin selection.
          guard OwlKeyboardPreferences.preferredSchemaID == failedID else { return }
          if !OwlDictPackPrompt.handleAbsentSchema(failedID) {
            Self.notifySchemaNotCompiled(failedID)
          }
        }
      } else {
        Self.notifySchemaNotCompiled(failedID)
      }
    }
    loadSettings()
    loadSettings(for: id)
    OwlPerf.since(perf, "fastapply.schema")
    return failedID == nil
  }

  /// Onboarding's 选方案 step entry point. A raw `selectSchema(_:)` alone doesn't stick for a
  /// schema outside the bundled `default.yaml` `schema_list` (e.g. 五笔 `wubi86_jidian`):
  /// every new session reads `OwlKeyboardPreferences.preferredSchemaID` and re-enforces it on
  /// every idle keystroke, so an unset preference silently overwrites the pick back to pinyin.
  /// Mirrors `OwlSettingsActions.selectInputMethod` — write the pref, select, then patch
  /// `default.custom.yaml`'s `schema_list` + fast-apply, exactly like the 键盘输入 page.
  func applyOnboardingScheme(_ schemaID: String) {
    switch schemaID {
    case "wubi86_jidian":
      OwlKeyboardPreferences.inputMethod = .wubi
      OwlKeyboardPreferences.wubiScheme = .jidian86
    case "double_pinyin":
      OwlKeyboardPreferences.inputMethod = .doublePinyin
      OwlKeyboardPreferences.doublePinyin = .ziranma
    default:
      OwlKeyboardPreferences.inputMethod = .pinyin
    }
    _ = selectSchema(schemaID)
    do {
      _ = try applyKeyboardSettings(.config)
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
    showMessage(msgText: "无法切换到方案「\(failedID)」：该方案可能尚未编译。请在设置里「应用配置改动」后重试，或运行 Owltype --diagnose-rime-config 排查。")
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
        content.title = "猫头鹰输入法"
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

  func setupRime() {
    do {
      try OwlPrivateStorage.prepareDirectory(OwlApp.userDir)
    } catch {
      print("Owltype: failed to secure user data directory: \(error)")
      createDirIfNotExist(path: OwlApp.userDir)
    }
    createDirIfNotExist(path: OwlApp.logDir)
    // Recover before any seed/managed patch can change the shared rollback manifest.
    // Failure leaves originals and the durable journal intact; the settings route exposes retry.
    var templateRecoveryReady = true
    do { try OwlTemplateMigration(rimeDir: OwlApp.userDir).recoverIfNeeded() }
    catch { templateRecoveryReady = false }
    if templateRecoveryReady { seedUserDirIfNeeded() }
    // Bug fix: the seeded `default.custom.yaml` is bare (schema_list + page_size only) and the
    // Owltype managed keyboard blocks (both Shift_L AND Shift_R = commit_code, key_binder paging/
    // select, punctuator, switcher/save_options) used to be written ONLY when the user round-tripped
    // a settings toggle. On a fresh install (or upgrade) that left right-Shift on rime-ice's
    // `Shift_R: noop` default and the Owltype keyboard defaults inactive OOTB. Write the managed
    // blocks from the CURRENT prefs here — AFTER the seed, BEFORE the initial deploy (startRime in
    // Main.swift / deploy()) — so the first `start_maintenance` compiles them into build/. The
    // managed blocks are marker-delimited, so this is idempotent and runs cheaply on every launch
    // (not gated by the seed marker), which also fixes existing upgraders.
    if templateRecoveryReady {
      // Only valid, conflict-free raw data is migrated automatically. Never replay a tolerant
      // legacy loader into its source JSON before this audit.
      _ = try? OwlTemplateMigration(rimeDir: OwlApp.userDir).runAutomatically()
      if !OwlTemplateMigration.hasPendingRecovery(rimeDir: OwlApp.userDir) {
        _ = try? OwlManagedKeyboardPatchPlan.apply(snapshot: OwlKeyboardSnapshot.current())
      }
    }
    // Bind the committed template directory after migration/recovery. reload closes the
    // in-memory index on unavailable/legacy state; UI tests use the isolated defaults source.
    _ = try? OwlAutomaticExpansionRuntime.shared.reload(rimeDir: OwlApp.userDir, defaults: OwlDefaults.standard)
    // B1: one-shot, idempotent migration of a legacy single-DeepSeek setup into a default provider
    // profile. No-op on a fresh install (no legacy key) or once a profile already exists. Off the
    // IMK hot path — runs only here at app launch.
    OwlProviderMigration.migrateLegacyDeepSeekIfNeeded()
    // swiftlint:disable identifier_name
    let notification_handler: RimeNotificationHandler = notificationHandler
    let context_object = Unmanaged.passUnretained(self).toOpaque()
    // swiftlint:enable identifier_name
    engine.setNotificationHandler(notification_handler, context: context_object)

    var owlTraits = RimeTraits.rimeStructInit()
    owlTraits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
    owlTraits.setCString(OwlApp.userDir.path, to: \.user_data_dir)
    owlTraits.setCString(OwlApp.logDir.path, to: \.log_dir)
    owlTraits.setCString("Owltype", to: \.distribution_code_name)
    owlTraits.setCString("猫头鹰输入法", to: \.distribution_name)
    owlTraits.setCString(Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as! String, to: \.distribution_version)
    owlTraits.setCString(OwlRimeIdentity.appName, to: \.app_name)
    engine.setup(&owlTraits)
  }

  /// ADR-0004 cycle 3: on first run, seed Owltype's OWN `user_data_dir`
  /// (`~/Library/Application Support/Owltype`) from the bundled `SharedSupport/_user_seed`
  /// (`*.custom.yaml` selecting the 猫头鹰 schema_list / 深大红 / 法学 opt-in), so the next
  /// `deploy()` compiles them against the bundled rime-ice + 五笔 shared data. Idempotent
  /// via a version marker; never overwrites a file the user already has. Writes ONLY to
  /// Owltype's own dir — never the user's `~/Library/Rime` (ADR-0004).
  private func seedUserDirIfNeeded() {
    let fm = FileManager.default
    guard let sharedSupport = Bundle.main.sharedSupportPath else { return }
    let seedDir = URL(fileURLWithPath: sharedSupport).appending(component: "_user_seed", directoryHint: .isDirectory)
    migrateLegacyOwltypeCustomConfigIfNeeded()
    let marker = OwlApp.userDir.appending(component: OwlRimeIdentity.seedMarkerFile, directoryHint: .notDirectory)
    guard fm.fileExists(atPath: seedDir.path), !fm.fileExists(atPath: marker.path) else { return }
    do {
      for src in try fm.contentsOfDirectory(at: seedDir, includingPropertiesForKeys: nil) {
        let dst = OwlApp.userDir.appending(component: src.lastPathComponent, directoryHint: .notDirectory)
        if !fm.fileExists(atPath: dst.path) {
          try fm.copyItem(at: src, to: dst)
        }
      }
      try? Data("owltype seed v1\n".utf8).write(to: marker)
      print("Owltype: seeded user_data_dir from bundled _user_seed.")
    } catch {
      print("Owltype: user-dir seed failed: \(error)")
    }
  }

  private func migrateLegacyOwltypeCustomConfigIfNeeded() {
    let fm = FileManager.default
    let legacy = OwlApp.userDir.appending(component: OwlRimeIdentity.legacyCustomConfigFile, directoryHint: .notDirectory)
    let current = OwlApp.userDir.appending(component: OwlRimeIdentity.customConfigFile, directoryHint: .notDirectory)
    guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
    do {
      try fm.copyItem(at: legacy, to: current)
      print("Owltype: migrated legacy \(OwlRimeIdentity.legacyCustomConfigFile) to \(OwlRimeIdentity.customConfigFile) in Owltype user_data_dir.")
    } catch {
      print("Owltype: legacy custom config migration failed: \(error)")
    }
  }

  @discardableResult
  func startRime(fullCheck: Bool, migrationDirectory: URL = OwlApp.userDir) -> Bool {
    let trace = OwlLatencyTrace.begin("deploy.startRime")
    defer { OwlLatencyTrace.end("deploy.startRime", trace) }
    print("Initializing la rime...")
    // Always bring the engine up: returning before initialize left every session dead, and
    // deploy() had already called shutdownRime — one unfinished migration meant no input at all.
    engine.initialize(nil)
    guard !templateRecoveryBlocksDeployment(migrationDirectory) else { return false }
    do {
      if let sharedSupport = Bundle.main.sharedSupportURL {
        try OwlPinyinMixedInput.apply(userDir: migrationDirectory, sharedDir: sharedSupport)
        do { try OwlPinnedWordsDeployment.apply(userDir: migrationDirectory, sharedDir: sharedSupport) } catch {
          Self.deployLog.error("Pinned candidates unavailable: \(error.localizedDescription, privacy: .public)")
        }
      }
    } catch {
      Self.deployLog.error("English candidate configuration failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
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
    _ = engine.deployConfigFile(OwlRimeIdentity.configFile, versionKey: "config_version")
    OwlLatencyTrace.event("deploy.configFile")
    if maintained {
      return true
    } else {
      // print("[DEBUG] maintenance fails")
      print("Owltype: deploy failed during Rime maintenance.")
      Self.deployLog.error("start_maintenance failed (fullCheck=\(fullCheck, privacy: .public)) — installation_update/detect_modifications refused; see rime glog in \(OwlApp.logDir.path, privacy: .public)")
      return false
    }
  }

  /// While a template migration journal is unresolved, its target files (template dict,
  /// rime_ice.custom.yaml, …) may be half-written. Typing keeps running on the last compiled
  /// `build/`; only recompiling from those sources waits until recovery succeeds.
  func templateRecoveryBlocksDeployment(_ directory: URL = OwlApp.userDir) -> Bool {
    guard OwlTemplateMigration.hasPendingRecovery(rimeDir: directory) else { return false }
    Self.deployLog.error("template migration recovery pending — skipped Rime deployment, serving the last build")
    return true
  }

  /// `self.config` 可用性判据（2026-07-12 B1/B2）：打得开且非空壳。实测 `config_open("owltype")`
  /// 在 build/owltype.yaml 缺席/重建窗口会「成功」返回空壳（一切读取失败）——只看 open 返回值不够，
  /// 必须探真内容（owltype.yaml 恒有 style 段）。
  private static func isUsable(_ config: OwlConfig?) -> Bool {
    config?.has(section: "style") ?? false
  }

  func loadSettings() {
    // 先验后换（B1）：曾经是「先把 self.config 换成新对象、open 失败静默 return」——一次失败的
    // 重读（部署重写 build/ 的窗口期）就把好句柄换成毒句柄，此后每个新控制器经 loadSettings(for:)
    // 用它重算 styleFlags → 全默认（inlinePreedit=false 占位模式），且零诊断、永不自愈。
    // 现契约：candidate 全验证（open + 非空壳）通过才换 self.config / 重读 styleFlags；失败保留
    // 旧状态（旧而真 > 新而毒）+ trace（只记布尔，#88 §4）。
    let candidate = OwlConfig()
    let opened = candidate.openBaseConfig()
    let usable = opened && Self.isUsable(candidate)
    OwlLiveInputTrace.write { "loadSettings openBase=\(opened) usable=\(usable)" }
    guard usable else { return }
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
    guard let config = self.config, Self.isUsable(config) else {
      OwlLiveInputTrace.write { "loadSettings(for:) config unusable — keeping current styleFlags" }
      return
    }
    let schema = OwlConfig()
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

  /// Feature 1: apply 简↔繁 to the live session right away from the settings UI — no redeploy.
  /// Sets the FULL simplification/traditional option set (`transcription` for 全拼/双拼,
  /// `zh_trad` for 五笔, plus the legacy `traditional`/`traditionalization`/`simplification`)
  /// so the single「简入繁出」switch is global across every exposed schema. The pref write
  /// stays in the settings layer; this only flips the options + re-renders the in-flight
  /// composition. Seeded on session create (`createSession`) so the choice survives focus changes.
  func applyTraditionalOutputToLiveSession(_ traditional: Bool) {
    activeInputController?.setTraditionalOutputOptions(traditional)
    activeInputController?.rimeUpdate()
  }

  /// 候选 emoji 开关 live 生效（仿 `applyTraditionalOutputToLiveSession`）：切当前会话的
  /// `emoji` option（rime-ice 的 emoji switch 名），立即重算候选。新会话由 `createSession` 按 pref 重新 seed。
  func applyEmojiSuggestionToLiveSession(_ enabled: Bool) {
    activeInputController?.setRimeOption(.emojiSuggestion, enabled)
    activeInputController?.rimeUpdate()
  }

  /// 默认状态·中英文 live 生效：改下拉时立刻把当前会话切到 中文/英文（`ascii_mode`）。新会话由
  /// `createSession` 按 `defaultAsciiMode` pref 重新 seed。
  func applyDefaultAsciiModeToLiveSession(_ english: Bool) {
    activeInputController?.setRimeOption(.asciiMode, english)
    activeInputController?.rimeUpdate()
  }

  /// 默认状态·全半角 live 生效：改下拉时立刻把当前会话切到 半角/全角（`full_shape`）。新会话由
  /// `createSession` 按 `defaultFullShape` pref 重新 seed。
  func applyDefaultFullShapeToLiveSession(_ fullShape: Bool) {
    activeInputController?.setRimeOption(.fullShape, fullShape)
    activeInputController?.rimeUpdate()
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
    notifCenter.addObserver(self, selector: #selector(rimeNeedsReload(_:)), name: .init("OwlReloadNotification"), object: nil, suspensionBehavior: .deliverImmediately)
    notifCenter.addObserver(self, selector: #selector(rimeNeedsSync(_:)), name: .init("OwlSyncNotification"), object: nil, suspensionBehavior: .deliverImmediately)
    notifCenter.addObserver(self, selector: #selector(rimeToggleASCIIMode(_:)), name: .init("OwlToggleASCIIModeNotification"), object: nil, suspensionBehavior: .deliverImmediately)
    notifCenter.addObserver(self, selector: #selector(rimeGetASCIIMode(_:)), name: .init("OwlGetASCIIModeNotification"), object: nil, suspensionBehavior: .deliverImmediately)
    // 授权后补装 tap 的第二保险（第一保险=applicationDidBecomeActive）：TCC 辅助功能表变更时
    // 系统会广播这条 DNC（未文档化、10.9 起稳定，alt-tab 等在用）。任何 app 的授权变化都触发、
    // 无 payload——只当「该重查一次」的信号用，让用户在系统设置里勾上开关的瞬间 tap 就位，
    // 不必切回猫头鹰窗口。通知名将来若失效，无声退化为 didBecomeActive 补装，无副作用。
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
    engine.cleanupAllSessions()
    return .terminateNow
  }

}

extension RimeStringSlice {
  /// Bridge the slice's pointer + length to a Swift String, honoring `.length`.
  /// librime clips `.length` to the first Unicode character for abbreviated labels
  /// when no explicit `abbrev:` field is defined, so reading past `.length` (e.g. with
  /// `String(cString:)`) would incorrectly return the full `states:` value.
  var asString: String? {
    guard let ptr = str else { return nil }
    let data = Data(bytes: UnsafeRawPointer(ptr), count: Int(length))
    return String(data: data, encoding: .utf8)
  }
}

private func notificationHandler(contextObject: UnsafeMutableRawPointer?, sessionId: RimeSessionId, messageTypeC: UnsafePointer<CChar>?, messageValueC: UnsafePointer<CChar>?) {
  let delegate: OwlApplicationDelegate = Unmanaged<OwlApplicationDelegate>.fromOpaque(contextObject!).takeUnretainedValue()

  let messageType = messageTypeC.map { String(cString: $0) }
  let messageValue = messageValueC.map { String(cString: $0) }
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
    // dict-pack 等编译真实结束的唯一信号（通知来自 librime 维护线程，跳回 MainActor）。
    // Center 只在自己处于 .deploying 时消费 —— 日常 deploy 到那里是 no-op。
    if messageValue == "success" || messageValue == "failure" {
      let succeeded = messageValue == "success"
      Task { @MainActor in
        OwlDictPackCenter.shared.noteDeployFinished(success: succeeded)
      }
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
      // stays a String (not a RimeOption). Read its label through the Engine's session
      // wrapper for the librime-supplied session id.
      let session = delegate.engine.session(for: sessionId)
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
    let messageType = styleFlags.statusMessageType
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
    if let inputController = activeInputController {
      let trace = OwlLatencyTrace.begin("strandedComposition.finalize")
      defer { OwlLatencyTrace.end("strandedComposition.finalize", trace) }
      inputController.deactivateServer(inputController.client())
    }
  }

  func shutdownRime() {
    OwlLatencyTrace.event("deploy.rimeFinalize")
    config?.close()
    engine.finalize()
  }

  func workspaceWillPowerOff(_: Notification) {
    print("Finalizing before logging out.")
    self.shutdownRime()
  }

  @objc func rimeNeedsReload(_: Notification) {
    let trace = OwlLatencyTrace.begin("reload.notification")
    defer { OwlLatencyTrace.end("reload.notification", trace) }
    print("Reloading rime on demand.")
    // 送达凭据：通知丢失时 app 侧和 librime 侧都零日志（2026-07-24 静默 reload 排查的盲区）。
    OwlApplicationDelegate.deployLog.notice("OwlReloadNotification received — starting full deploy")
    let ok = self.deploy()
    if ok {
      OwlApplicationDelegate.deployLog.notice("reload deploy succeeded")
    } else {
      OwlApplicationDelegate.deployLog.error("reload deploy FAILED — see rime glog in \(OwlApp.logDir.path, privacy: .public)")
    }
  }

  @objc func rimeNeedsSync(_: Notification) {
    print("Sync rime on demand.")
    self.syncUserData()
  }

  @objc func rimeToggleASCIIMode(_ notification: Notification) {
    guard let mode = notification.object as? String else { return }
    let enableASCII = mode == "ascii"

    if enableASCII {
      NotificationCenter.default.post(name: .init("OwlSetASCIIModeNotification"), object: true)
    } else {
      NotificationCenter.default.post(name: .init("OwlSetASCIIModeNotification"), object: false)
    }
  }

  @objc func rimeGetASCIIMode(_: Notification) {
    NotificationCenter.default.post(name: .init("OwlReportASCIIModeNotification"), object: nil)
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
