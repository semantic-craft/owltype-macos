//
//  OwlInputController.swift
//  Owltype
//
//  Created by Leo Liu on 5/7/24.
//
//  Core (god-object shrink, 2026-06-20): stored state, the IMK key-event hot path
//  (`handle()` / `processKey`), candidate navigation, and the controller's init/deinit.
//  Cohesive clusters live in same-module extension files:
//    OwlInputController+Menu.swift       — menu() + @objc actions
//    OwlInputController+RimeUpdate.swift  — rimeUpdate/commit/show/showPanel
//    OwlInputController+Lifecycle.swift   — IMK lifecycle overrides + notification handlers
//    OwlInputController+Session.swift     — librime session + chord typing
//    OwlInputController+RimeOptions.swift — RimeOption helpers
//

import InputMethodKit

final class OwlInputController: IMKInputController {
  // seam: was private; internal so OwlInputController+Session.swift can reach it across files.
  static let keyRollOver = 50
  // seam: was private; internal so OwlInputController+Session.swift can reach it across files.
  static var unknownAppCnt: UInt = 0

  // seam: was private; internal so the Menu/RimeUpdate/Lifecycle/Session extensions can reach it across files.
  weak var client: IMKTextInput?
  var templateHostGeneration: UInt64 = 0
  weak var pendingTemplateDelivery: OwlTemplateHostDelivery?
  let automaticRecognizer = OwlAutomaticExpansionRecognizer()
  var automaticTarget: OwlAutomaticExpansionTarget?
  var automaticApplyingClientAction = false
  var automaticEpoch: UInt64 = 0
  let smartPunctuation = OwlSmartPunctuation()
  /// The current composition's Session, vended by the Engine seam. `nil` (or `!isValid`)
  /// means "no live session — recreate before use". Swappable so PR2 can inject a fake;
  /// the live default comes from `NSApp.owlAppDelegate.engine` (same indirection as
  /// `ensureOwltypePanel`). All access is on the IMK input thread.
  var rime: RimeSession?
  // seam: was private; internal so OwlInputController+RimeUpdate.swift / +Lifecycle.swift can reach it across files.
  var preedit: String = ""
  // seam: was private; internal so OwlInputController+RimeUpdate.swift can reach it across files.
  var selRange: NSRange = .empty
  // seam: was private; internal so OwlInputController+RimeUpdate.swift can reach it across files.
  var caretPos: Int = 0
  // Cross-commit auto-spacing seed: the trailing char of the last inserted text, threaded into
  // OwlCommitTransform so a space lands at a 中文|英文 boundary that spans two commits. Reset on
  // deactivateServer (focus change). seam: internal for +RimeUpdate.swift / +Lifecycle.swift.
  // ponytail: goes stale if the cursor moves (arrow/click/manual space) between commits — query the
  // document via the client instead if that ever becomes a real complaint.
  var lastCommittedCharacter: Character?
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  // seam: was private; internal so OwlInputController+RimeUpdate.swift / +Session.swift can reach it across files.
  var schemaId: String = ""
  // 07-07-schema-consistency-guard: the last preferredSchemaID whose `select_schema` failed and has
  // NOT been cleared by a later success / session recreate. Drives `OwlSchemaSelectionGate`'s
  // idle-key backoff so a doomed select isn't retried on every keystroke. nil = none known-failed.
  // Off the IMK hot path (only touched by createSession / ensurePreferred / switchLiveSessionSchema).
  var knownFailedSchemaID: String?
  // seam: was private; internal so OwlInputController+RimeUpdate.swift can reach it across files.
  var inlinePreedit = false
  // seam: was private; internal so OwlInputController+RimeUpdate.swift can reach it across files.
  var inlineCandidate = false
  // 多行的「本次组字翻过页」旗标（2026-07-28 翻页才展开）：showPanel 见 page > 0 时置位，
  // 组字结束（空 menu 的 showPanel）复位。展开后整个组字期内保持——翻回第一页、追打字母
  // 都不收起；只有提交/清空才回到单行。只被 showPanel 读写，不在按键判定路径上。
  var scrollDidPage = false
  // 首轮旗标同步哨兵（2026-07-12 B3 破闩锁）：inline 旗标改为每轮 rimeUpdate 重算——原先只在
  // schema 变化时算一次，delegate styleFlags 事后恢复了老控制器也永远用不上；soft_cursor 只在
  // 首轮或值变化时下发。false = 本控制器还没做过第一次同步。
  var styleFlagsSynced = false
  // for chord-typing
  // seam: was private; internal so OwlInputController+Session.swift can reach it across files.
  var chordKeyCodes: [UInt32] = .init(repeating: 0, count: OwlInputController.keyRollOver)
  // seam: was private; internal so OwlInputController+Session.swift can reach it across files.
  var chordModifiers: [UInt32] = .init(repeating: 0, count: OwlInputController.keyRollOver)
  // seam: was private; internal so OwlInputController+Session.swift can reach it across files.
  var chordKeyCount: Int = 0
  // seam: was private; internal so OwlInputController+Session.swift can reach it across files.
  var chordTimer: Timer?
  // seam: was private; internal so OwlInputController+Session.swift can reach it across files.
  var chordDuration: TimeInterval = 0
  // seam: was private; internal so OwlInputController+Session.swift can reach it across files.
  var currentApp: String = ""
  var appModeObservation = OwlAppModeObservation()
  var pinnedWordsRevision: UInt64?
  // ponytail: dev perf埋点 — log the very first real keystroke of the process once
  // (cold first-key latency: incl. first createSession + get_context + panel show).
  private static var loggedFirstKey = false
  private static var recordedFirstHostKeyEvent = false

  // B8: per-lane supervisor for the explicit AI menu actions (off the IMK hot path). A new request
  // on a lane cancels the prior in-flight one on that lane so a superseded DeepSeek/local request
  // stops instead of running to completion (wasted tokens); cancelled on session teardown / deinit.
  // seam: internal so OwlInputController+Menu.swift / +Lifecycle.swift can reach it across files.
  let aiTasks = OwlLaneTasks()

  // Settled reranking is owned by this controller/session. Timers run on the IMK thread's
  // run loop; the Rust model forward pass itself runs on its own worker.
  var settledRerankDebounceTimer: Timer?
  var settledRerankPollTimer: Timer?
  var settledRerankJob: (token: UInt64, ticket: OwlSettledRerankTicket)?
  var settledRerankLastInputAt: UInt64?
  var settledRerankWaitingForDrain = false
  var applyingSettledRerank = false

  // Tokens of the block-based NotificationCenter observers registered in init. Block observers are
  // NOT covered by `removeObserver(self)` — the token must be removed explicitly in deinit, or every
  // dead controller (one per input session, in a process that lives for weeks) stays registered in
  // NotificationCenter forever and observer count grows without bound.
  private var notificationTokens: [NSObjectProtocol] = []

  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == OwlSmartPunctuation.postedEventTag { return false }
    if event.type == .keyDown { pendingTemplateDelivery?.invalidate() }
    OwlLatencyTrace.event("key.received")
    let handleTrace = OwlLatencyTrace.begin("handle")
    defer { OwlLatencyTrace.end("handle", handleTrace) }
    if !Self.recordedFirstHostKeyEvent {
      Self.recordedFirstHostKeyEvent = true
      OwlActivationHealth.recordHostKeyEventOnce()
    }
    debugLiveInputTrace("handle enter type=\(event.type.rawValue) key=\(event.keyCode) hasClient=\(sender != nil)")
    let perfFirstKey = Self.loggedFirstKey ? nil : OwlPerf.mark()
    defer { if let perfFirstKey { OwlPerf.since(perfFirstKey, "firstkey.handle"); Self.loggedFirstKey = true } }

    // Return true to indicate the key input was received and dealt with. Key processing will not
    // continue in that case (the system will not deliver a key down event to the application).
    // Returning false means the original key down will be passed on to the client.

    if self.client == nil { self.client = sender as? IMKTextInput }
    if rime?.isValid != true {
      createSession()
      if rime?.isValid != true {
        return false
      }
    }
    // A Rust resource switch that arrived mid-composition is queued. If the host or a
    // previous command already completed it, switch before this key reaches the old session.
    MainActor.assumeIsolated {
      NSApp.owlAppDelegate.applyPendingLiveSessionRefreshIfIdle()
    }

    if let incoming = sender as? IMKTextInput, let previous = self.client, incoming !== previous {
      // The old field is no longer the target; never recover into the new field.
      templateHostGeneration &+= 1
      automaticEpoch &+= 1
      discardAutomaticExpansion()
    }
    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }
    ensurePreferredSchemaForIdleSession()
    syncPinnedWords()
    if event.type == .keyDown, handlePinHotKey(event) { return true }

    if handleAutomaticExpansion(event) { return true }

    // 全局热键的唯一路径（#118）: 快捷短语面板与划词菜单召唤只在猫头鹰为活跃输入法时有意义 —— 此时
    // 每个 keyDown 本来就流经这里，直接匹配。绝不可回退到 Carbon RegisterEventHotKey：在本 IMK
    // 进程它注册返回 noErr 后窗口服务器会全局吞掉该组合，但事件永不进程内派发（真机实证）——
    // 热键不响应，还把组合键从所有应用（包括本匹配器）手里偷走。
    if event.type == .keyDown, handleGlobalHotKeyViaIMK(event) {
      return true
    }

    // PURE pipeline (task 06-22): de-platform the NSEvent → classify (pure) → feed librime.
    let action = OwlUserActionClassifier.classify(OwlKeyEvent(event: event, lastModifiers: lastModifiers))
    debugLiveInputTrace("handle classified type=\(event.type.rawValue) key=\(event.keyCode)")
    return apply(userAction: action)
  }

  /// Feed a classified `OwlUserAction` to librime (the only stateful step) and refresh IMK.
  /// This is the controller-side dispatch of the pure classification: it performs the
  /// `processKey` side effects in the same order the old `handle()` switch did, stores the new
  /// `lastModifiers`, and runs `rimeUpdate()`. Returns the same `handled` value the old code did.
  private func apply(userAction action: OwlUserAction) -> Bool {
    switch action {
    case .flagsUnchanged:
      return true

    case let .flagsChanged(capsLockRevert, events, updateLastModifiers, handled):
      // print("[DEBUG] FLAGSCHANGED modifiers: \(updateLastModifiers)")
      var capsLockHandled = false
      OwlAutomaticExpansionControllerEntry.processModifiers(pending: automaticRecognizer.buffer,
        finishSemicolon: { finishAutomaticExpansion(replaySemicolon: true) }, process: {
        if let revert = capsLockRevert {
          capsLockHandled = processKey(revert.keycode, modifiers: revert.modifiers)
        }
        for event in events {
          _ = processKey(event.keycode, modifiers: event.modifiers)
        }
      })
      lastModifiers = updateLastModifiers
      if !refreshAutomaticExpansionAfterModifiers() { rimeUpdate() }
      // `handled` mirrors the original: true only for the couldn't-infer bail; false on the
      // normal modifier path so the host app still receives the modifier event. Caps Lock may
      // additionally be consumed by the session when good_old_caps_lock is off.
      return handled || capsLockHandled

    case let .keyDown(rimeKeycode, rimeModifiers):
      invalidateSettledRerankForAction()
      let handled = processKey(rimeKeycode, modifiers: rimeModifiers)
      rimeUpdate()
      if shouldArmSettledRerank(after: rimeKeycode) {
        armSettledRerankAfterInput()
      }
      return handled

    case .commandPassthrough, .ignored:
      return false
    }
  }

  func selectCandidate(_ index: Int) -> Bool {
    guard let rime else { return false }
    invalidateSettledRerankForAction()
    let success = rime.selectCandidate(index)
    if success {
      rimeUpdate()
    }
    return success
  }

  /// Commit a candidate by its absolute index into the whole candidate list — the 多行后页行
  /// click path, where the clicked candidate is visible but not on librime's current page.
  func selectCandidateAbsolute(_ index: Int) -> Bool {
    guard let rime else { return false }
    invalidateSettledRerankForAction()
    let success = rime.selectCandidateAbsolute(index)
    if success {
      rimeUpdate()
    }
    return success
  }

  func selectCandidate(_ token: OwlCandidateToken) -> Bool {
    guard let rime else { return false }
    invalidateSettledRerankForAction()
    let success = rime.selectCandidate(token)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    guard let rime else { return false }
    invalidateSettledRerankForAction()
    var handled = false
    handled = rime.changePage(up: up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    // print("[DEBUG] initWithServer: \(server ?? .init()) delegate: \(delegate ?? "nil") client:\(client ?? "nil")")
    super.init(server: server, delegate: delegate, client: client)
    debugLiveInputTrace("controller init hasClient=\(client != nil)")
    createSession()

    notificationTokens.append(NotificationCenter.default.addObserver(
      forName: OwlAutomaticExpansionRuntime.willChange,
      object: OwlAutomaticExpansionRuntime.shared,
      queue: nil
    ) { [weak self] _ in self?.finishAutomaticExpansion(replaySemicolon: true) })

    // Listen for ASCII mode toggle notifications
    notificationTokens.append(NotificationCenter.default.addObserver(
      forName: .init("OwlSetASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.handleASCIIModeToggle(notification)
    })

    // Listen for ASCII mode status requests
    notificationTokens.append(NotificationCenter.default.addObserver(
      forName: .init("OwlReportASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.reportASCIIMode(notification)
    })
    notificationTokens.append(NotificationCenter.default.addObserver(
      forName: .init("OwlToggleTraditionalInputNotification"),
      object: nil,
      queue: nil
    ) { [weak self] _ in self?.toggleTraditionalInputFromMenu() })
    notificationTokens.append(NotificationCenter.default.addObserver(
      forName: .init("OwlToggleASCIIPunctuationNotification"),
      object: nil,
      queue: nil
    ) { [weak self] _ in self?.toggleASCIIPunctuationFromMenu() })
    notificationTokens.append(NotificationCenter.default.addObserver(
      forName: .init("OwlToggleFullShapeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] _ in self?.toggleFullShapeFromMenu() })
    notificationTokens.append(NotificationCenter.default.addObserver(
      forName: .owlRerankPreferencesDidChange,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      if Thread.isMainThread {
        self.rerankPreferencesDidChange()
      } else {
        DispatchQueue.main.async { [weak self] in self?.rerankPreferencesDidChange() }
      }
    })
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    // TODO add special key event preprocessing here
    guard let rime else { return false }

    if handleSmartPunctuation(rimeKeycode, modifiers: rimeModifiers) { return true }

    // '/' → English, globally & schema-agnostically (programming convenience), unless the user
    // explicitly enabled the slash symbol menu. That opt-in lets the event fall through to Rime's
    // punctuator candidate list without committing the composition or changing ascii_mode.
    // A bare slash in Chinese mode commits the highlighted candidate (commit_text_preview),
    // flips to ASCII mode, then FALLS THROUGH to `rime.process` below so the slash is emitted
    // as a literal ASCII '/': in ASCII mode librime either rejects it (the host types '/') or
    // commits it (rimeUpdate inserts '/') — either path yields exactly one ASCII slash. Sits
    // above the active schema, so pinyin / wubi / any schema behave identically. The bare-slash
    // gate is the pure `OwlKeycode.slashSwitchesToEnglish` (unit-tested).
    if OwlKeycode.slashSwitchesToEnglish(
      keycode: rimeKeycode,
      modifiers: rimeModifiers,
      asciiMode: rime.option(.asciiMode),
      symbolMenuEnabled: OwlKeyboardPreferences.slashSymbolMenu
    ) {
      if let preview = rime.composition()?.commitTextPreview, !preview.isEmpty {
        commit(string: preview)
        rime.clearComposition()
      }
      rime.setOption(.asciiMode, true)
    }

    // with linear candidate list, arrow keys may behave differently.
    let styleFlags = NSApp.owlAppDelegate.styleFlags
    if styleFlags.linear != rime.option(.linear) {
      rime.setOption(.linear, styleFlags.linear)
    }
    // with vertical text, arrow keys may behave differently.
    if styleFlags.vertical != rime.option(.vertical) {
      rime.setOption(.vertical, styleFlags.vertical)
    }

    debugLiveInputTrace("process before schema=\(rime.status()?.schemaId ?? "<nil>") key=\(rimeKeycode) mods=\(rimeModifiers)")
    let processTrace = OwlLatencyTrace.begin("session.process")
    let handled = rime.process(keycode: rimeKeycode, modifiers: rimeModifiers)
    OwlLatencyTrace.end("session.process", processTrace)
    debugLiveInputTrace("process after handled=\(handled) schema=\(rime.status()?.schemaId ?? "<nil>")")
    // print("[DEBUG] rime_keycode: \(rimeKeycode), rime_modifiers: \(rimeModifiers), handled = \(handled)")

    // TODO add special key event postprocessing here

    if !handled {
      let hasControl = rimeModifiers & kControlMask.rawValue != 0
      let isVimCommandKey = rimeKeycode == UInt32(XK_c)
        || rimeKeycode == UInt32(XK_C)
        || rimeKeycode == UInt32(XK_bracketleft)
      let isVimBackInCommandMode = rimeKeycode == UInt32(XK_Escape)
        || (hasControl && isVimCommandKey)
      if isVimBackInCommandMode && rime.option(.vimMode) &&
          !rime.option(.asciiMode) {
        rime.setOption(.asciiMode, true)
        // print("[DEBUG] turned Chinese mode off in vim-like editor's command mode")
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rime.option(.chordTyping) {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        // non-chording key pressed
        clearChord()
      }
    }

    if !handled, rimeKeycode >= 32, rimeKeycode < 127,
       (rimeModifiers & (kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue | kReleaseMask.rawValue)) == 0 {
      smartPunctuation.shadow = UnicodeScalar(rimeKeycode).map(String.init)
      smartPunctuation.expectedCaret = nil
    }
    return handled
  }

  deinit {
    discardAutomaticExpansion()
    resetSettledRerankRuntime()
    // B8: cancel any in-flight AI lane tasks for this session (nonisolated deinit — `cancelAll()`
    // only calls `Task.cancel()`, which is thread safe and needs no main actor).
    aiTasks.cancelAll()
    // Unregister the block observers from init (see notificationTokens); removeObserver(token) is
    // thread safe, fine from a nonisolated deinit.
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
    destroySession()
  }
}
