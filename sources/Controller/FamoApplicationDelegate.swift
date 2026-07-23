//
//  FamoApplicationDelegate.swift
//  Famo

import UserNotifications
import AppKit
import InputMethodKit

final class FamoApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  static let rimeWikiURL = URL(string: "https://github.com/rime/home/wiki")!
  static let notificationIdentifier = "FamoNotification"

  /// The single owner of the global librime lifecycle. The input controller obtains its
  /// per-composition Session from this engine (via `NSApp.famoAppDelegate.engine`), the
  /// same indirection pattern as `ensureFamoPanel`. Swappable so tests can inject a fake.
  var engine: RimeEngine = LiveRimeEngine()
  /// The controller's read-only view of the live composition snapshot, behind the narrow
  /// `SnapshotReading` port (same composition-root pattern as `engine`). Default is the
  /// production `.shared` registry; swappable so tests can inject a scripted snapshot.
  var snapshots: SnapshotReading = FamoSnapshotRegistry.shared
  /// The controller's composition-timeline snapshot emitter, behind the narrow
  /// `SnapshotEmitting` port (same composition-root pattern as `engine`). Default is the
  /// production `.shared` emitter; swappable so tests can drive the snapshot path and assert
  /// the emitted call/args without a librime session.
  var snapshotEmitter: SnapshotEmitting = FamoSnapshotEmitter.shared
  /// The controller's prompt-commit resolver, behind the narrow `PromptResolving` port. Given the
  /// originating trigger code + committed candidate title, returns the matching 提示词 entry (or
  /// nil). Default is the production `.shared` resolver (reads famo_prompts.json on a 📝 commit);
  /// swappable so tests can return a scripted entry without disk.
  var promptStore: PromptResolving = FamoPromptResolver.shared
  var suppressOnboarding = false
  var config: FamoConfig?
  /// Candidate-window LAYOUT flags read from Rime `style/*` (linear/vertical/inline*),
  /// read live by the IMK path (was `panel.linear` etc. on the deleted FamoPanel/FamoTheme).
  /// Seeded in `loadSettings` from the global config, overridden per-schema in
  /// `loadSettings(for:)`. Not theming — the skin/colors live in `FamoThemes`.
  var styleFlags = FamoStyleFlags()
  /// The active input controller (was `panel.inputController`), set by the controller on
  /// each `showPanel`. Used by `finalizeStrandedComposition` to finalize a stranded
  /// composition when the input source is switched away.
  weak var activeInputController: FamoInputController?
  /// Registry of every LIVE controller (one per host-app input session). WEAK members — a
  /// controller registers itself when it creates a session (and on each `showPanel`); dead
  /// controllers drop out automatically via `NSHashTable.weakObjects()` + `destroySession`,
  /// so there is no retain cycle and no manual unregister bookkeeping. The fast settings-apply
  /// path (`reapplyToLiveSession`) iterates this to force EVERY live session to reload the
  /// freshly-deployed `build/` (a fresh session reads the new config; a same-id reselect does
  /// NOT, which was the page_size-not-applying bug). Off the IMK keystroke hot path.
  let liveControllers = NSHashTable<FamoInputController>.weakObjects()

  /// Register a controller as live (idempotent — `NSHashTable` ignores duplicates). Called by
  /// the controller from `createSession` / `showPanel`. Off the IMK keystroke hot path.
  func registerLiveController(_ controller: FamoInputController) {
    liveControllers.add(controller)
  }
  /// SwiftUI candidate panel, created lazily on first composition (always on now — SwiftUI
  /// is the sole renderer).
  var famoPanel: FamoSwiftUICandidatePanel?
  /// SwiftUI status HUD (mode/schema toast), created lazily on first status message.
  /// Replaces the legacy AppKit FamoPanel.show(status:) path.
  var statusHUD: FamoStatusHUD?
  /// The last caret anchor seen by the candidate panel (set by the controller on each
  /// `showPanel`), so the status HUD can position its toast near where the user is typing.
  var lastCaretAnchor: NSRect = .zero
  // v0.2: SwiftUI settings window, created lazily the first time 设置… is opened.
  // Purely additive UI — only forwards already-safe actions; nil until used.
  var famoSettingsWindow: FamoSettingsWindow?
  // v0.3.3: SwiftUI onboarding/welcome window, created lazily on first launch (or
  // from the menu). Purely additive UI — only forwards already-safe actions.
  var famoOnboardingWindow: FamoOnboardingWindow?
  func applicationWillFinishLaunching(_ notification: Notification) {
    addObservers()
    // v0.3.3: first-run onboarding. Guarded + non-blocking (just orders the window
    // front); kept LAST so it never interferes with Rime / panel / status setup.
    if !suppressOnboarding && !FamoOnboarding.isDone {
      showOnboarding()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // swiftlint:disable:next notification_center_detachment
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
    statusHUD?.hidePanel()
    famoPanel?.hidePanel()
  }

  @discardableResult
  func deploy() -> Bool {
    let trace = FamoLatencyTrace.begin("deploy.full")
    defer { FamoLatencyTrace.end("deploy.full", trace) }
    print("Start maintenance...")
    FamoLatencyTrace.event("deploy.maintenanceStart")
    self.shutdownRime()
    let ok = self.startRime(fullCheck: true)
    FamoLatencyTrace.event("deploy.restoreSettings")
    self.loadSettings()
    FamoLatencyTrace.event("deploy.finalUIState")
    return ok
  }

  // Fast settings-apply (Track 2 / PR3) lives in `FamoApplicationDelegate+FastApply.swift`.

  func syncUserData() {
    let trace = FamoLatencyTrace.begin("sync.userData")
    defer { FamoLatencyTrace.end("sync.userData", trace) }
    print("Sync Famo user data")
    _ = engine.syncUserData()
  }

  func chooseSyncDirectory(for state: FamoSettingsState) {
    let settings = FamoRimeSyncSettings()
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
      print("Failed to set Famo sync directory: \(error)")
    }
  }

  func openLogFolder() {
    NSWorkspace.shared.open(FamoApp.logDir)
  }

  func openRimeFolder() {
    NSWorkspace.shared.open(FamoApp.userDir)
  }

  /// Lazily create the SwiftUI candidate panel (the sole candidate renderer).
  func ensureFamoPanel() -> FamoSwiftUICandidatePanel {
    if let famoPanel { return famoPanel }
    let created = FamoSwiftUICandidatePanel()
    famoPanel = created
    return created
  }

  /// Lazily create the SwiftUI status HUD (mode/schema toast). Mirrors `ensureFamoPanel()`.
  func ensureStatusHUD() -> FamoStatusHUD {
    if let statusHUD { return statusHUD }
    let created = FamoStatusHUD()
    statusHUD = created
    return created
  }

  // MARK: - 表情/符号面板 (module 7)

  /// The floating emoji/symbol panel, created lazily on first open.
  private var famoEmojiPanel: FamoEmojiPanel?

  /// Show the emoji/symbol panel. `onPick` is where a chosen glyph goes:
  /// - From the input menu (typing into a document), the controller passes a closure that
  ///   inserts at the cursor via its live `commit(string:)`.
  /// - From the 表情符号 settings page there is no document client, so `onPick` is nil and
  ///   the panel falls back to copying to the pasteboard.
  /// Re-assigned on every show so the reused singleton always targets the latest trigger.
  func showEmojiPanel(onPick: ((String) -> Void)? = nil) {
    let trace = FamoLatencyTrace.begin("window.open.emoji")
    defer { FamoLatencyTrace.end("window.open.emoji", trace) }
    let panel = famoEmojiPanel ?? FamoEmojiPanel()
    famoEmojiPanel = panel
    FamoLatencyTrace.event("window.emoji.controllerSelected")
    panel.pickHandler = onPick
    panel.showPanel()
    FamoLatencyTrace.event("window.emoji.firstVisible")
  }

  // MARK: - 快捷短语面板 (quick-phrase picker)

  /// The floating quick-phrase panel, created lazily on first open.
  private var famoQuickSendPanel: FamoQuickSendPanel?

  /// Show the 短语/提示词 panel. `onPickPhrase` / `onPickPrompt` are where a chosen 短语 / 提示词 goes —
  /// from the input menu the controller passes closures that insert at the cursor via the client it
  /// captured up-front; without a document client the 短语 path falls back to copying to the
  /// pasteboard. Both are re-assigned on every show so the reused singleton always targets the latest
  /// trigger.
  func showQuickSendPanel(
    onPickPhrase: ((String) -> Void)? = nil,
    onPickPrompt: ((FamoPromptEntry) -> Void)? = nil,
    initialSegment: FamoPickerSegment = .phrase
  ) {
    let trace = FamoLatencyTrace.begin("window.open.quickSend")
    defer { FamoLatencyTrace.end("window.open.quickSend", trace) }
    let panel = famoQuickSendPanel ?? FamoQuickSendPanel()
    famoQuickSendPanel = panel
    FamoLatencyTrace.event("window.quickSend.controllerSelected")
    panel.phrasePickHandler = onPickPhrase
    panel.promptPickHandler = onPickPrompt
    panel.showPanel(initialSegment: initialSegment)
    FamoLatencyTrace.event("window.quickSend.firstVisible")
  }

  // MARK: - v0.2 settings window

  /// Build (or reuse) the settings window, populate its state, and show it.
  /// Mirrors the `ensureFamoPanel()` lazy-create pattern.
  func showSettings(selectedPage: FamoSettingsPage = .keyboard) {
    let trace = FamoLatencyTrace.begin("window.open.settings")
    defer { FamoLatencyTrace.end("window.open.settings", trace) }
    let state = FamoSettingsState()
    state.selectedPage = selectedPage
    state.schemas = loadSchemaList()
    state.currentSchemaId = currentSchemaId()
    state.currentInputSourceDisplayName = FamoInstaller.currentInputSourceDisplayName()
    // Seed the candidate-panel appearance prefs from their single home.
    state.panelAppearance = FamoPanelPreferences.appearance
    state.panelFontSize = FamoPanelPreferences.fontSize
    // Seed the G8 候选显示 prefs from their single homes.
    state.panelOrientation = FamoPanelPreferences.orientation
    state.panelFontDesign = FamoPanelPreferences.fontDesign
    state.panelAnimationsEnabled = FamoPanelPreferences.animationsEnabled
    state.panelShowPreedit = FamoPanelPreferences.showPreedit
    state.panelInlineCandidate = FamoPanelPreferences.inlineCandidate
    state.panelShowPaging = FamoPanelPreferences.showPaging
    state.panelShowNotificationsWhen = FamoPanelPreferences.showNotificationsWhen
    state.panelCandidateFormat = FamoPanelPreferences.candidateFormat
    state.candidatePageSize = FamoKeyboardPreferences.pageSize
    // Seed the 键盘输入 option groups from their single home (FamoKeyboardPreferences).
    state.keyboardInputMethod = FamoKeyboardPreferences.inputMethod
    state.keyboardDoublePinyin = FamoKeyboardPreferences.doublePinyin
    state.keyboardWubiCodeHint = FamoKeyboardPreferences.wubiCodeHint
    state.keyboardWubiAutoClear = FamoKeyboardPreferences.wubiAutoClear
    state.keyboardWubiCandidateMode = FamoKeyboardPreferences.wubiCandidateMode
    state.keyboardWubiScheme = FamoKeyboardPreferences.wubiScheme
    state.keyboardWubiZReverseLookup = FamoKeyboardPreferences.wubiZReverseLookup
    state.keyboardWubiEnglishChannel = FamoKeyboardPreferences.wubiEnglishChannel
    state.keyboardWubiUserDictLearning = FamoKeyboardPreferences.wubiUserDictLearning
    state.keyboardShiftSwitchCJK = FamoKeyboardPreferences.shiftSwitchCJK
    state.keyboardCJKPunctToggle = FamoKeyboardPreferences.cjkPunctToggle
    state.keyboardTraditionalOutput = FamoKeyboardPreferences.traditionalOutput
    state.keyboardDefaultAsciiMode = FamoKeyboardPreferences.defaultAsciiMode
    state.keyboardDefaultFullShape = FamoKeyboardPreferences.defaultFullShape
    state.keyboardGoodOldCapsLock = FamoKeyboardPreferences.goodOldCapsLock
    state.keyboardPageMinusEquals = FamoKeyboardPreferences.pageMinusEquals
    state.keyboardPageBrackets = FamoKeyboardPreferences.pageBrackets
    state.keyboardPageCommaPeriod = FamoKeyboardPreferences.pageCommaPeriod
    state.keyboardSelect23Semicolon = FamoKeyboardPreferences.select23Semicolon
    state.keyboardAngleSymbolMenu = FamoKeyboardPreferences.angleSymbolMenu
    state.keyboardCJKAlnumSpacing = FamoKeyboardPreferences.cjkAlnumSpacing
    state.keyboardCJKEnglishSpacing = FamoKeyboardPreferences.cjkEnglishSpacing
    state.keyboardCJKNumberSpacing = FamoKeyboardPreferences.cjkNumberSpacing
    state.keyboardAppEnglishBundleIDsText = FamoKeyboardPreferences.appEnglishBundleIDs.joined(separator: ", ")
    // Seed the librime version for the 关于 page (best-effort; empty when absent).
    state.librimeVersion = rimeVersion() ?? ""
    state.syncDirectoryDisplayPath = FamoRimeSyncSettings().syncDirectoryDisplayPath
    FamoLatencyTrace.event("window.settings.dataLoaded")

    let window = famoSettingsWindow ?? FamoSettingsWindow()
    famoSettingsWindow = window
    FamoLatencyTrace.event("window.settings.controllerSelected")

    window.show(
      state: state,
      onSelectSchema: { [weak self] schemaID in
        guard let self else { return }
        self.selectSchema(schemaID)
        // Refresh the highlighted row after the deploy triggered by the switch.
        state.currentSchemaId = self.currentSchemaId().isEmpty ? schemaID : self.currentSchemaId()
        state.statusMessage = NSLocalizedString("已切换方案并应用配置改动。", comment: "schema switched")
      },
      onRedeploy: { [weak self] in
        let ok = self?.deploy() ?? false
        state.statusMessage = ok
          ? NSLocalizedString("已应用配置改动。", comment: "redeployed")
          : NSLocalizedString("应用配置失败，请查看诊断日志。", comment: "redeploy failed")
        return ok
      },
      onApplyKeyboardConfigFast: { [weak self] in
        self?.applyKeyboardConfigFast() ?? false
      },
      onApplyFuzzyConfigFast: { [weak self] in
        self?.applyFuzzyConfigFast() ?? false
      },
      onSyncUserData: { [weak self] in
        self?.syncUserData()
        state.statusMessage = NSLocalizedString("已请求同步用户数据。", comment: "sync user data")
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
        self?.famoPanel?.refreshPreferences()
      }
    )
    FamoLatencyTrace.event("window.settings.firstVisible")
  }

  func showSettingsForUITest() {
    let state = FamoSettingsState()
    state.schemas = [SchemaItem(id: "rime_ice", name: "雾凇拼音")]
    state.currentSchemaId = "rime_ice"
    state.currentInputSourceDisplayName = "Famo UI Test"
    state.librimeVersion = "ui-test"
    state.syncDirectoryDisplayPath = FamoRimeSyncSettings().syncDirectoryDisplayPath

    let window = famoSettingsWindow ?? FamoSettingsWindow()
    famoSettingsWindow = window
    window.show(
      state: state,
      onSelectSchema: { state.currentSchemaId = $0 },
      onRedeploy: { true },
      onApplyKeyboardConfigFast: { true },
      onApplyFuzzyConfigFast: { true },
      onSyncUserData: {},
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
    let trace = FamoLatencyTrace.begin("window.open.onboarding")
    defer { FamoLatencyTrace.end("window.open.onboarding", trace) }
    let window = famoOnboardingWindow ?? FamoOnboardingWindow()
    famoOnboardingWindow = window

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
        // `FamoKeyboardPreferences.preferredSchemaID`, which this never touched.
        self?.applyOnboardingScheme(schemaID)
      },
      onOpenInputSettings: { [weak self] in
        self?.showSettings()
        // Land the user on the 键盘输入 page (already the default selection).
        self?.famoSettingsWindow?.window?.makeKeyAndOrderFront(nil)
      },
      onFinish: { [weak self] in
        FamoOnboarding.isDone = true
        self?.famoOnboardingWindow?.close()
      },
      isFamoEnabled: {
        // Real enabled status for the 启用 step (TIS), matching FamoInstaller.register.
        !FamoInstaller().enabledModes().isEmpty
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
  ///      the built `build/<id>.schema.yaml`; no full dictionary rebuild) so the current
  ///      composition window immediately uses the new schema.
  ///   3. reload style flags so the new schema's layout (linear/vertical/inline) takes effect.
  /// Wrapped in a `FamoPerf` mark. Off the IMK keystroke hot path.
  //
  // NEEDS REAL-MACHINE VERIFICATION: live typing session picking up the switched schema.
  func selectSchema(_ id: String) {
    guard !id.isEmpty else { return }
    let schemaTrace = FamoLatencyTrace.begin("deploy.schemaSwitch")
    defer { FamoLatencyTrace.end("deploy.schemaSwitch", schemaTrace) }
    let perf = FamoPerf.mark()
    engine.selectSchema(id)                              // remembered for future sessions
    let result = activeInputController?.switchLiveSessionSchema(to: id) // live session, no full deploy
    if case .selectFailed(let failedID)? = result {
      // 用户可感反馈（决策点 1）：显式切方案失败（多因 build/<id>.schema.yaml 未编译）。走已有系统
      // 通知，不静默——否则 UI 显示新方案而实际输出仍是旧方案（设置显示拼音 / 打字出五笔）。
      Self.showMessage(msgText: "无法切换到方案「\(failedID)」：该方案可能尚未编译。请在设置里「应用配置改动」后重试，或运行 Famo --diagnose-rime-config 排查。")
    }
    loadSettings()
    loadSettings(for: id)
    FamoPerf.since(perf, "fastapply.schema")
  }

  /// Onboarding's 选方案 step entry point. A raw `selectSchema(_:)` alone doesn't stick for a
  /// schema outside the bundled `default.yaml` `schema_list` (e.g. 五笔 `wubi86_jidian`):
  /// every new session reads `FamoKeyboardPreferences.preferredSchemaID` and re-enforces it on
  /// every idle keystroke, so an unset preference silently overwrites the pick back to pinyin.
  /// Mirrors `FamoSettingsActions.selectInputMethod` — write the pref, select, then patch
  /// `default.custom.yaml`'s `schema_list` + fast-apply, exactly like the 键盘输入 page.
  func applyOnboardingScheme(_ schemaID: String) {
    switch schemaID {
    case "double_pinyin":
      FamoKeyboardPreferences.inputMethod = .doublePinyin
      FamoKeyboardPreferences.doublePinyin = .ziranma
    default:
      FamoKeyboardPreferences.inputMethod = .pinyin
    }
    selectSchema(schemaID)
    do {
      _ = try FamoManagedKeyboardPatchPlan.apply(snapshot: FamoKeyboardSnapshot.current())
    } catch {
      print("Onboarding scheme patch write failed: \(error)")
    }
    applyKeyboardConfigFast()
  }

  func openWiki() {
    NSWorkspace.shared.open(Self.rimeWikiURL)
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

  func setupRime() {
    do {
      try FamoPrivateStorage.prepareDirectory(FamoApp.userDir)
    } catch {
      print("Famo: failed to secure user data directory: \(error)")
      createDirIfNotExist(path: FamoApp.userDir)
    }
    createDirIfNotExist(path: FamoApp.logDir)
    seedUserDirIfNeeded()
    // Bug fix: the seeded `default.custom.yaml` is bare (schema_list + page_size only) and the
    // Famo managed keyboard blocks (both Shift_L AND Shift_R = commit_code, key_binder paging/
    // select, punctuator, switcher/save_options) used to be written ONLY when the user round-tripped
    // a settings toggle. On a fresh install (or upgrade) that left right-Shift on rime-ice's
    // `Shift_R: noop` default and the Famo keyboard defaults inactive OOTB. Write the managed
    // blocks from the CURRENT prefs here — AFTER the seed, BEFORE the initial deploy (startRime in
    // Main.swift / deploy()) — so the first `start_maintenance` compiles them into build/. The
    // managed blocks are marker-delimited, so this is idempotent and runs cheaply on every launch
    // (not gated by the seed marker), which also fixes existing upgraders.
    _ = try? FamoManagedKeyboardPatchPlan.apply(snapshot: FamoKeyboardSnapshot.current())
    // swiftlint:disable identifier_name
    let notification_handler: RimeNotificationHandler = notificationHandler
    let context_object = Unmanaged.passUnretained(self).toOpaque()
    // swiftlint:enable identifier_name
    engine.setNotificationHandler(notification_handler, context: context_object)

    var famoTraits = RimeTraits.rimeStructInit()
    famoTraits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
    famoTraits.setCString(FamoApp.userDir.path, to: \.user_data_dir)
    famoTraits.setCString(FamoApp.logDir.path, to: \.log_dir)
    famoTraits.setCString("Famo", to: \.distribution_code_name)
    famoTraits.setCString("法墨输入法", to: \.distribution_name)
    famoTraits.setCString(Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as! String, to: \.distribution_version)
    famoTraits.setCString(FamoRimeIdentity.appName, to: \.app_name)
    engine.setup(&famoTraits)
  }

  /// ADR-0004 cycle 3: on first run, seed Famo's OWN `user_data_dir`
  /// (`~/Library/Application Support/Famo`) from the bundled `SharedSupport/_user_seed`
  /// (`*.custom.yaml` selecting the 法墨 schema_list / 深大红 / 法学 opt-in), so the next
  /// `deploy()` compiles them against the bundled rime-ice + 五笔 shared data. Idempotent
  /// via a version marker; never overwrites a file the user already has. Writes ONLY to
  /// Famo's own dir — never the user's `~/Library/Rime` (ADR-0004).
  private func seedUserDirIfNeeded() {
    let fm = FileManager.default
    guard let sharedSupport = Bundle.main.sharedSupportPath else { return }
    let seedDir = URL(fileURLWithPath: sharedSupport).appending(component: "_user_seed", directoryHint: .isDirectory)
    migrateLegacyFamoCustomConfigIfNeeded()
    let marker = FamoApp.userDir.appending(component: FamoRimeIdentity.seedMarkerFile, directoryHint: .notDirectory)
    guard fm.fileExists(atPath: seedDir.path), !fm.fileExists(atPath: marker.path) else { return }
    do {
      for src in try fm.contentsOfDirectory(at: seedDir, includingPropertiesForKeys: nil) {
        let dst = FamoApp.userDir.appending(component: src.lastPathComponent, directoryHint: .notDirectory)
        if !fm.fileExists(atPath: dst.path) {
          try fm.copyItem(at: src, to: dst)
        }
      }
      try? Data("famo seed v1\n".utf8).write(to: marker)
      print("Famo: seeded user_data_dir from bundled _user_seed.")
    } catch {
      print("Famo: user-dir seed failed: \(error)")
    }
  }

  private func migrateLegacyFamoCustomConfigIfNeeded() {
    let fm = FileManager.default
    let legacy = FamoApp.userDir.appending(component: FamoRimeIdentity.legacyCustomConfigFile, directoryHint: .notDirectory)
    let current = FamoApp.userDir.appending(component: FamoRimeIdentity.customConfigFile, directoryHint: .notDirectory)
    guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
    do {
      try fm.copyItem(at: legacy, to: current)
      print("Famo: migrated legacy \(FamoRimeIdentity.legacyCustomConfigFile) to \(FamoRimeIdentity.customConfigFile) in Famo user_data_dir.")
    } catch {
      print("Famo: legacy custom config migration failed: \(error)")
    }
  }

  @discardableResult
  func startRime(fullCheck: Bool) -> Bool {
    let trace = FamoLatencyTrace.begin("deploy.startRime")
    defer { FamoLatencyTrace.end("deploy.startRime", trace) }
    print("Initializing la rime...")
    engine.initialize(nil)
    // check for configuration updates
    let maintained = engine.startMaintenance(fullCheck: fullCheck)
    if maintained {
      FamoLatencyTrace.event("deploy.maintenanceStarted")
    }
    // update Famo frontend config — UNCONDITIONALLY: rime's detect_modifications does not
    // track famo.custom.yaml, so a famo-domain-only change (App 默认英文 add) leaves
    // maintenance with "nothing to do" and used to skip this deploy entirely — the write
    // then never reached build/famo.yaml even via 重新部署 (#121 真机验收逮住).
    // config_file_update is fingerprint-gated → free when unchanged.
    _ = engine.deployConfigFile(FamoRimeIdentity.configFile, versionKey: "config_version")
    FamoLatencyTrace.event("deploy.configFile")
    if maintained {
      return true
    } else {
      // print("[DEBUG] maintenance fails")
      print("Famo: deploy failed during Rime maintenance.")
      return false
    }
  }

  /// `self.config` 可用性判据（2026-07-12 B1/B2）：打得开且非空壳。实测 `config_open("famo")`
  /// 在 build/famo.yaml 缺席/重建窗口会「成功」返回空壳（一切读取失败）——只看 open 返回值不够，
  /// 必须探真内容（famo.yaml 恒有 style 段）。
  private static func isUsable(_ config: FamoConfig?) -> Bool {
    config?.has(section: "style") ?? false
  }

  func loadSettings() {
    // 先验后换（B1）：曾经是「先把 self.config 换成新对象、open 失败静默 return」——一次失败的
    // 重读（部署重写 build/ 的窗口期）就把好句柄换成毒句柄，此后每个新控制器经 loadSettings(for:)
    // 用它重算 styleFlags → 全默认（inlinePreedit=false 占位模式），且零诊断、永不自愈。
    // 现契约：candidate 全验证（open + 非空壳）通过才换 self.config / 重读 styleFlags；失败保留
    // 旧状态（旧而真 > 新而毒）+ trace（只记布尔，#88 §4）。
    let candidate = FamoConfig()
    let opened = candidate.openBaseConfig()
    let usable = opened && Self.isUsable(candidate)
    FamoLiveInputTrace.write { "loadSettings openBase=\(opened) usable=\(usable)" }
    guard usable else { return }
    config = candidate
    // Layout flags from the global `style/*` (was `panel.load(...)` into FamoTheme).
    styleFlags = FamoStyleFlags.base(config: candidate)
    // Feature 3: the 内嵌候选预览 pref overrides `style/inline_candidate` so the toggle
    // drives the inline preview without hand-editing yaml (takes effect on schema reload).
    styleFlags.inlineCandidate = FamoPanelPreferences.inlineCandidate
    FamoLiveInputTrace.write { "loadSettings styleFlags inlinePreedit=\(styleFlags.inlinePreedit) inlineCandidate=\(styleFlags.inlineCandidate)" }
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
      FamoLiveInputTrace.write { "loadSettings(for:) config unusable — keeping current styleFlags" }
      return
    }
    let schema = FamoConfig()
    // Base flags from the global style, then let a per-schema `style` section override
    // (same precedence the deleted FamoTheme.load used for these layout keys).
    var flags = FamoStyleFlags.base(config: config)
    if schema.open(schemaID: schemaID, baseConfig: config) && schema.has(section: "style") {
      flags.apply(config: schema)
    }
    // Feature 3: pref override wins over both global + per-schema `style/inline_candidate`.
    flags.inlineCandidate = FamoPanelPreferences.inlineCandidate
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
    let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("famo_launch.json", conformingTo: .json)
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
    notifCenter.addObserver(forName: .init("FamoReloadNotification"), object: nil, queue: nil, using: rimeNeedsReload)
    notifCenter.addObserver(forName: .init("FamoSyncNotification"), object: nil, queue: nil, using: rimeNeedsSync)
    notifCenter.addObserver(forName: .init("FamoToggleASCIIModeNotification"), object: nil, queue: nil, using: rimeToggleASCIIMode)
    notifCenter.addObserver(forName: .init("FamoGetASCIIModeNotification"), object: nil, queue: nil, using: rimeGetASCIIMode)
    notifCenter.addObserver(forName: .init(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
      self?.finalizeStrandedComposition()
      // S1/R5: if the selected source is a Famo mode that is NOT truly enabled (the
      // key-swallowing dead half-state), log + surface copyable recovery guidance.
      // Not the IMK hot path: this fires only on selected-source CHANGE, not per keystroke.
      FamoInstaller().detectAndGuideIfHalfState()
    }
  }

  /// Install-time activation repair: refreshes registration without rewriting system input prefs.
  ///
  /// Invoked ONCE, only when the installed executable is launched with `--activate-once` as the
  /// login user inside the Aqua GUI session. The installer GUI process owns `TISEnableInputSource`
  /// and any macOS consent prompt; this method must not write `AppleEnabledInputSources`, because
  /// that can create duplicate TIS rows and hide Famo from the input menu.
  func selfHealActivationIfNeeded() {
    FamoInstaller().repairRegistrationForInstalledBundle()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    print("Famo is quitting.")
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
  let delegate: FamoApplicationDelegate = Unmanaged<FamoApplicationDelegate>.fromOpaque(contextObject!).takeUnretainedValue()

  let messageType = messageTypeC.map { String(cString: $0) }
  let messageValue = messageValueC.map { String(cString: $0) }
  if messageType == "deploy" {
    switch messageValue {
    case "start":
      FamoApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_start", comment: ""))
    case "success":
      FamoApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_success", comment: ""))
    case "failure":
      FamoApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_failure", comment: ""))
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
      if FamoPanelPreferences.showNotificationsWhen == .always {
        delegate.showStatusMessage(msgTextLong: longLabel(), msgTextShort: shortLabel())
      }
    }
    return
  }

  // Feature 5: schema switches toast on 始终 + 智能 (i.e. anything but 从不).
  if FamoPanelPreferences.showNotificationsWhen != .never {
    if messageType == "schema", let messageValue = messageValue, let schemaName = try? /^[^\/]*\/(.*)$/.firstMatch(in: messageValue)?.output.1 {
      delegate.showStatusMessage(msgTextLong: String(schemaName), msgTextShort: String(schemaName))
      return
    }
  }
}

private extension FamoApplicationDelegate {
  func showStatusMessage(msgTextLong: String?, msgTextShort: String?) {
    guard !(msgTextLong ?? "").isEmpty || !(msgTextShort ?? "").isEmpty else { return }
    let messageType = styleFlags.statusMessageType
    let anchor = lastCaretAnchor
    // The toast is an NSPanel — show it on the main thread (a Rime option/schema
    // notification can arrive off-main).
    DispatchQueue.main.async { [weak self] in
      self?.ensureStatusHUD().show(
        long: msgTextLong ?? "",
        short: msgTextShort ?? "",
        messageType: messageType,
        anchor: anchor
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
    let currentInputSourceID = FamoInstaller.currentInputSourceID() ?? ""
    guard !currentInputSourceID.hasPrefix(FamoInstaller.inputSourcePrefix) else { return }
    if let inputController = activeInputController {
      let trace = FamoLatencyTrace.begin("strandedComposition.finalize")
      defer { FamoLatencyTrace.end("strandedComposition.finalize", trace) }
      inputController.deactivateServer(inputController.client())
    }
  }

  func shutdownRime() {
    FamoLatencyTrace.event("deploy.rimeFinalize")
    config?.close()
    engine.finalize()
  }

  func workspaceWillPowerOff(_: Notification) {
    print("Finalizing before logging out.")
    self.shutdownRime()
  }

  func rimeNeedsReload(_: Notification) {
    let trace = FamoLatencyTrace.begin("reload.notification")
    defer { FamoLatencyTrace.end("reload.notification", trace) }
    print("Reloading rime on demand.")
    self.deploy()
  }

  func rimeNeedsSync(_: Notification) {
    print("Sync rime on demand.")
    self.syncUserData()
  }

  func rimeToggleASCIIMode(_ notification: Notification) {
    guard let mode = notification.object as? String else { return }
    let enableASCII = mode == "ascii"

    if enableASCII {
      NotificationCenter.default.post(name: .init("FamoSetASCIIModeNotification"), object: true)
    } else {
      NotificationCenter.default.post(name: .init("FamoSetASCIIModeNotification"), object: false)
    }
  }

  func rimeGetASCIIMode(_: Notification) {
    NotificationCenter.default.post(name: .init("FamoReportASCIIModeNotification"), object: nil)
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
  var famoAppDelegate: FamoApplicationDelegate {
    self.delegate as! FamoApplicationDelegate
  }
}
