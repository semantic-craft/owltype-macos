//
//  OwlInputController+Session.swift
//  Owltype
//
//  Single responsibility: the engine session lifecycle (create / app-options / destroy)
//  and chord-typing accumulation (timer + key buffer) for OwlInputController.
//  Moved verbatim out of OwlInputController.swift (god-object shrink, 2026-06-20);
//  no logic edits.
//

import InputMethodKit
import Foundation
import ApplicationServices
import Carbon

extension OwlInputController {

  func debugLiveInputTrace(_ message: @autoclosure () -> String) {
    OwlLiveInputTrace.write(message)
  }

  func onChordTimer(_: Timer) {
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0, let engineSession, engineSession.sessionID != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = engineSession.process(keycode: chordKeyCodes[i], modifiers: chordModifiers[i] | kReleaseMask.rawValue)
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      engineUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    // print("[DEBUG] update chord: {\(chordKeyCodes)} << \(keycode)")
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      // you are cheating. only one human typist (fingers <= 10) is supported.
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    // reset timer
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = engineRuntime.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  // MARK: - Settled reranking

  func shouldArmSettledRerank(after keycode: UInt32) -> Bool {
    if keycode >= UInt32(XK_a) && keycode <= UInt32(XK_z) {
      return true
    }
    if keycode == UInt32(XK_BackSpace) || keycode == UInt32(XK_Delete) {
      return true
    }
    return keycode == UInt32(XK_apostrophe) && !OwlKeyboardPreferences.select23Semicolon
  }

  func armSettledRerankAfterInput() {
    guard !applyingSettledRerank,
          OwlExperimentalPreferences.settledRerankEnabled,
          let engineSession, engineSession.isValid,
          let input = engineSession.input(), !input.isEmpty else {
      return
    }
    settledRerankLastInputAt = settledRerankNow()
    scheduleSettledRerankDebounce(after: OwlSettledRerankTiming.debounce)
  }

  private func scheduleSettledRerankDebounce(after interval: TimeInterval) {
    settledRerankDebounceTimer?.invalidate()
    let timer = Timer(timeInterval: interval, repeats: false) {
      [weak self] _ in
      self?.settledRerankDebounceFired()
    }
    settledRerankDebounceTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  /// A new key, selection, page turn, schema switch, or focus change invalidates the pause
  /// window. An already-running job is deliberately left alive so poll can return its model.
  func invalidateSettledRerankForAction() {
    // A host action need not mutate the engine (for example, a boundary-page key).
    // Match the native host epoch so its earlier scoring can only return the model.
    settledRerankActionEpoch &+= 1
    settledRerankDebounceTimer?.invalidate()
    settledRerankDebounceTimer = nil
    settledRerankWaitingForDrain = false
  }

  func rerankPreferencesDidChange() {
    invalidateSettledRerankForAction()
    settledRerankLastInputAt = nil
    guard let engineSession, engineSession.isValid else { return }
    engineSession.syncRerankPreferences()
    if !applyingSettledRerank,
       OwlExperimentalPreferences.settledRerankEnabled,
       let input = engineSession.input(), !input.isEmpty {
      armSettledRerankAfterInput()
    }
  }

  func resetSettledRerankRuntime() {
    settledRerankDebounceTimer?.invalidate()
    settledRerankPollTimer?.invalidate()
    settledRerankDebounceTimer = nil
    settledRerankPollTimer = nil
    settledRerankJob = nil
    settledRerankLastInputAt = nil
    settledRerankWaitingForDrain = false
  }

  private func settledRerankDebounceFired() {
    settledRerankDebounceTimer = nil
    guard !applyingSettledRerank else { return }
    guard let engineSession, engineSession.isValid,
          OwlExperimentalPreferences.settledRerankEnabled else {
      return
    }

    // The model loads on the FFI worker. Querying here runs after the pause is already over and
    // lets a slow first load become ready without putting file IO on a keystroke.
    engineSession.syncRerankPreferences()
    guard let input = engineSession.input(), !input.isEmpty else { return }
    if engineSession.settledRerankLoading {
      scheduleSettledRerankDebounce(after: OwlSettledRerankTiming.modelLoadPollInterval)
      return
    }
    guard engineSession.settledRerankReady else { return }
    if settledRerankJob != nil {
      settledRerankWaitingForDrain = true
      return
    }
    startSettledRerankIfDue(session: engineSession, input: input)
  }

  private func startSettledRerankIfDue(session: EngineSession, input: String) {
    guard !applyingSettledRerank,
          session.isValid,
          session.settledRerankReady,
          !input.isEmpty,
          let lastInput = settledRerankLastInputAt else {
      return
    }
    let now = settledRerankNow()
    let debounceNanos = UInt64(OwlSettledRerankTiming.debounce * 1_000_000_000)
    guard now &- lastInput >= debounceNanos else {
      let remaining = Double(debounceNanos - (now &- lastInput)) / 1_000_000_000
      scheduleSettledRerankDebounce(after: remaining)
      return
    }

    let ticket = OwlSettledRerankTicket(
      sessionID: session.sessionID,
      generation: session.generation,
      rawInput: input,
      configurationEpoch: session.rerankConfigurationEpoch
    )
    let started = session.startSettledRerank()
    if let token = started.token {
      settledRerankJob = (token: token, ticket: ticket, actionEpoch: settledRerankActionEpoch)
      settledRerankWaitingForDrain = false
      startSettledRerankPolling()
      return
    }
    if let error = started.error {
      debugLiveInputTrace("settled rerank did not start: \(error)")
    }
    // A synchronous result may refresh the snapshot and advance generation before it returns.
    // Its current bit already vouches for the accepted result, so compare only stable identity.
    if started.current, started.moved,
       ticket.sessionID == session.sessionID,
       ticket.rawInput == (session.input() ?? ""),
       ticket.configurationEpoch == session.rerankConfigurationEpoch {
      applySettledRerankRefresh()
    }
  }

  private func startSettledRerankPolling() {
    settledRerankPollTimer?.invalidate()
    let timer = Timer(timeInterval: OwlSettledRerankTiming.pollInterval, repeats: true) {
      [weak self] _ in
      self?.settledRerankPollFired()
    }
    settledRerankPollTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func settledRerankPollFired() {
    guard let job = settledRerankJob else {
      settledRerankPollTimer?.invalidate()
      settledRerankPollTimer = nil
      return
    }
    guard let engineSession, engineSession.isValid else {
      resetSettledRerankRuntime()
      return
    }

    let input = engineSession.input() ?? ""
    let accepts = job.actionEpoch == settledRerankActionEpoch
      && OwlExperimentalPreferences.settledRerankEnabled
      && job.ticket.isCurrent(
        sessionID: engineSession.sessionID,
        generation: engineSession.generation,
        rawInput: input,
        configurationEpoch: engineSession.rerankConfigurationEpoch
      )
    let result = engineSession.pollSettledRerank(token: job.token, accept: accepts)
    if result.pending {
      return
    }

    settledRerankPollTimer?.invalidate()
    settledRerankPollTimer = nil
    settledRerankJob = nil
    if let error = result.error {
      debugLiveInputTrace("settled rerank finished with an error: \(error)")
    }
    if accepts, result.current, result.moved {
      applySettledRerankRefresh()
    }

    if settledRerankWaitingForDrain {
      settledRerankWaitingForDrain = false
      if OwlExperimentalPreferences.settledRerankEnabled,
         engineSession.isValid,
         let input = engineSession.input(), !input.isEmpty {
        startSettledRerankIfDue(session: engineSession, input: input)
      }
    }
  }

  private func applySettledRerankRefresh() {
    applyingSettledRerank = true
    defer { applyingSettledRerank = false }
    engineUpdate()
  }

  func createSession() {
    resetSettledRerankRuntime()
    let app = client?.bundleIdentifier() ?? {
      OwlInputController.unknownAppCnt &+= 1
      return "UnknownApp\(OwlInputController.unknownAppCnt)"
    }()
    currentApp = app
    let newSession = engineRuntime.engine.createSession()
    engineSession = newSession
    schemaId = ""
    pinnedWordsRevision = nil

    if newSession.isValid {
      let preferredSchema = OwlKeyboardPreferences.preferredSchemaID
      let selected = newSession.selectSchema(preferredSchema)
      debugLiveInputTrace("createSession preferred=\(preferredSchema) select=\(selected) status=\(newSession.status()?.schemaId ?? "<nil>")")
      if selected {
        schemaId = preferredSchema
      }
      // Record/clear the idle-key backoff marker: a failed preferred select here enters the "known
      // degraded" state so `ensurePreferredSchemaForIdleSession` won't retry it every keystroke.
      // Silent (no user notification) — createSession runs on every focus change; only the explicit
      // picker (`OwlApplicationDelegate.selectSchema`) surfaces a user-facing failure.
      knownFailedSchemaID = OwlSchemaSelectionGate.markerAfterAttempt(preferred: preferredSchema, selected: selected)
      // Resolve app memory and initial language once; avoid transient default-mode notifications.
      setEngineOption(.fullShape, OwlKeyboardPreferences.defaultFullShape)
      updateAppOptions()
      // Feature 1: seed 简↔繁 from the pref so Owltype's「简入繁出」choice survives focus changes /
      // new sessions (方案 reset 回简体). Seeds the full option set so it covers 全拼/双拼
      // (`transcription`) AND 五笔 (`zh_trad`) — a fresh wubi session otherwise loses 繁体.
      setTraditionalOutputOptions(OwlKeyboardPreferences.traditionalOutput)
      // 候选 emoji (rime-ice 原生 emoji switch). Owltype 出厂关；按 表情符号 设置开关 seed，
      // 让选择在焦点切换 / 新会话后保持（rime 每次新会话会 reset 回 schema 默认值）。
      setEngineOption(.emojiSuggestion, OwlEmojiPreferences.candidateEmojiEnabled)
      syncPinnedWords()
    }
    // Register as a LIVE controller so the fast settings-apply path can force this session to
    // reload the freshly-deployed `build/` (weak membership; deinit/destroy drops it). Idempotent.
    engineRuntime.registerLiveController(self)
  }

  /// Guard the first real key after activation/update against the engine restoring an older schema
  /// from `user.yaml`. The session is still idle here, so switching does not discard user input.
  func ensurePreferredSchemaForIdleSession() {
    guard let engineSession, engineSession.isValid else { return }
    let preferredSchema = OwlKeyboardPreferences.preferredSchemaID
    guard !preferredSchema.isEmpty else { return }
    guard owl_app_keyboard_can_apply(1, hasInFlightComposition ? 1 : 0) != 0 else { return }
    let currentSchema = engineSession.status()?.schemaId ?? schemaId
    switch OwlSchemaSelectionGate.idleAction(current: currentSchema, preferred: preferredSchema, knownFailed: knownFailedSchemaID) {
    case .alreadyActive:
      schemaId = currentSchema
      debugLiveInputTrace("ensurePreferred idle current=\(currentSchema) preferred=\(preferredSchema) noop")
    case .skipKnownFailed:
      // Back off: this preferred id already failed select() and config hasn't changed since. No
      // engine call, no per-key trace. The marker clears when a session recreate / config apply
      // re-runs createSession (or a later attempt succeeds).
      return
    case .attempt:
      let ascii = engineSession.option(.asciiMode)
      let selected = engineSession.selectSchema(preferredSchema)
      if selected { engineSession.setOption(.asciiMode, ascii) }
      knownFailedSchemaID = OwlSchemaSelectionGate.markerAfterAttempt(preferred: preferredSchema, selected: selected)
      debugLiveInputTrace("ensurePreferred idle current=\(currentSchema) preferred=\(preferredSchema) select=\(selected) after=\(engineSession.status()?.schemaId ?? "<nil>")")
      if selected {
        schemaId = preferredSchema
        pinnedWordsRevision = nil
        syncPinnedWords()
        MainActor.assumeIsolated { NSApp.owlAppDelegate.snapshotEmitter.noteSchemaChange() }
        engineRuntime.loadSettings(for: preferredSchema)
      }
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    guard let engineSession else { return }
    let fallback = OwlRustSchemaMap.initialASCIIMode(
      forApp: currentApp,
      englishBundleIDs: OwlKeyboardPreferences.appEnglishBundleIDs,
      defaultASCIIMode: OwlKeyboardPreferences.defaultAsciiMode
    )
    let restored = OwlAppInputMemory.shared.initialMode(app: currentApp, fallback: fallback)
    if engineSession.option(.asciiMode) != restored { engineSession.setOption(.asciiMode, restored) }
    appModeObservation.seed(restored)
    if let reportBundleID = engineRuntime.config?.getBool("unsafe/report_bundleid"), reportBundleID {
      engineSession.setProperty(name: "client_app", value: currentApp)
    }
  }

  func destroySession() {
    smartPunctuation.reset()
    finishAutomaticExpansion(replaySemicolon: false)
    resetSettledRerankRuntime()
    // print("[DEBUG] destroySession:")
    engineSession?.destroy()
    engineSession = nil
    clearChord()
  }

  /// Resource-generation switches cannot use `rawInput` replay: Rust keeps partially selected
  /// phrase progress outside that string. The generation handoff therefore waits for an idle
  /// composition instead of recreating this session mid-selection.
  var hasInFlightComposition: Bool {
    guard let engineSession, engineSession.isValid else { return false }
    if pendingPairedClosing != nil { return true }
    if let input = engineSession.input(), !input.isEmpty { return true }
    guard let composition = engineSession.composition() else { return false }
    return !composition.preedit.isEmpty
  }

  /// Fast settings-apply re-entry (Track 2, PR3; live-session-reload rewrite, 2026-06-22).
  /// Called for every LIVE controller after a `deploy_config_file` refreshed the compiled
  /// `build/`, or for a queued Rust generation switch after the last live session becomes idle.
  /// The latter reaches this code only from an outermost `engineUpdate` / next-key boundary, never
  /// from the middle of `handle` / `processKey`.
  ///
  /// WHY destroy rather than `select_schema(sameId)`: a same-id reselect does NOT force the engine
  /// to rebuild the cached `Schema` for that id, so the running session kept the OLD
  /// `menu/page_size` (the 8→5-not-applying bug). The old full `deploy()` only worked because
  /// `EngineRuntime.shutdown()` destroyed every session → the next keystroke `createSession` read fresh
  /// `build/`. We reproduce ONLY that "force the session to re-read build/" effect, WITHOUT
  /// tearing down the engine (no dict/octagram rebuild → still sub-second).
  ///
  /// Two cases, per the PRD decision (2026-06-22):
  ///
  /// - ACTIVE controller (`replayComposition == true`): the one with the visible composition.
  ///   It must refresh IMMEDIATELY so the panel re-renders under the new config (no retype):
  ///     1. capture the current rawInput BEFORE teardown clears it,
  ///     2. `destroySession()` + `createSession()` — the fresh session reads the new `build/`
  ///        (its `client` is live, so per-app options + `currentApp` are derived correctly),
  ///     3. restore the captured `schemaId` (a fresh session defaults to `schema_list`'s first
  ///        entry, so without this a 五笔/双拼 user would be kicked back to 拼音),
  ///     4. replay the captured rawInput + `engineUpdate()` so the panel re-renders with the
  ///        user's preedit intact.
  ///
  /// - BACKGROUND controller (`replayComposition == false`): a controller for an app that is NOT
  ///   front-most. We DESTROY ONLY — we do NOT eagerly `createSession()`. A backgrounded
  ///   controller has had `deactivateServer` set its `client = nil`, so an eager `createSession()`
  ///   would derive `currentApp = "UnknownApp<n>"` (losing the app's per-app ascii_mode/options
  ///   and bumping the UnknownApp counter). Destroy-only is both safe and sufficient: the
  ///   controller's `handle()` hot path already recreates the session (`engineSession?.isValid != true →
  ///   createSession()`) on its NEXT keystroke, by which point its `client` is live again, so the
  ///   fresh session reads the new `build/` AND derives the correct per-app options. The schema is
  ///   re-derived by the delegate's per-client schema selection on reactivation.
  ///
  /// No-op when there is no live session.
  ///
  /// - Parameter replayComposition: true only for the ACTIVE controller. Background controllers
  ///   pass `false` (destroy-only, lazy recreate on their next keystroke).
  func reapplyConfigToLiveSession(replayComposition: Bool) {
    guard let engineSession, engineSession.isValid else { return }

    // Background controller: destroy only. The next keystroke's `handle()` recreates the session
    // with a live `client`, reading the new `build/` and the correct per-app options. Eager
    // recreate here would mislabel the app (`UnknownApp<n>`) because its `client` is nil.
    guard replayComposition else {
      destroySession()
      return
    }

    let capturedSchema = schemaId
    let rawInput = engineSession.input() ?? ""

    // Active controller: force the session to re-read the freshly-deployed build/ by recreating
    // it (a same-id reselect would NOT pick up the new page_size). Recreating resets `schemaId`
    // to "". The active controller's `client` is live, so per-app options derive correctly.
    destroySession()
    createSession()
    guard let fresh = self.engineSession, fresh.isValid else { return }

    // A fresh session defaults to schema_list's first entry — restore the user's active schema
    // so the reload doesn't kick them off 五笔/双拼. This re-reads build/<id>.schema.yaml in place.
    if !capturedSchema.isEmpty {
      switchLiveSessionSchema(to: capturedSchema)
    }

    // Replay the in-flight composition so the panel re-renders under the new config without a
    // retype. (`switchLiveSessionSchema` already ran `engineUpdate`, but it rendered an empty
    // composition; replay + a final `engineUpdate` restores the user's preedit.)
    if !rawInput.isEmpty {
      replayRawInput(rawInput)
      engineUpdate()
    }
  }

  /// Re-feed a previously-captured rawInput string to the live session so the composition
  /// is rebuilt under the new config. Off the keystroke hot path (only the fast-apply path
  /// and tests call it). Each ASCII byte is fed as its own rime keysym (lowercase letters /
  /// digits map 1:1 to their codepoint); non-ASCII is skipped — Owltype's raw input codes are
  /// ASCII. No-op on empty input.
  func replayRawInput(_ rawInput: String) {
    guard let engineSession, engineSession.isValid, !rawInput.isEmpty else { return }
    for scalar in rawInput.unicodeScalars where scalar.isASCII {
      _ = engineSession.process(keycode: scalar.value, modifiers: 0)
    }
  }

  /// Switch the active controller's LIVE session to a DIFFERENT schema (输入方式/双拼 picker),
  /// without a full `deploy()`. `select_schema(newId)` re-reads the already-built
  /// `build/<newId>.schema.yaml` in place (no dict/octagram rebuild; clears the composition).
  /// Updates the cached `schemaId` ONLY when the select actually lands, and re-renders. Off the IMK
  /// keystroke hot path. Returns `.noLiveSession` when there is no live session (the next
  /// `createSession` will pick up the switched schema, which the engine remembers via the
  /// transient-session select the delegate also performs); `.selectFailed` when `select_schema`
  /// returns false (e.g. `build/<id>.schema.yaml` not compiled) — in that case `schemaId` is left
  /// untouched so the cache never claims a schema the engine isn't actually on (设置显示拼音/打字出五笔).
  @discardableResult
  func switchLiveSessionSchema(to id: String) -> SchemaSwitchResult {
    guard !id.isEmpty, let engineSession, engineSession.isValid else { return .noLiveSession }
    invalidateSettledRerankForAction()
    finishAutomaticExpansion(replaySemicolon: false)
    let ascii = engineSession.option(.asciiMode)
    let selected = engineSession.selectSchema(id)   // re-reads build/<id>.schema.yaml in place; clears composition
    knownFailedSchemaID = OwlSchemaSelectionGate.markerAfterAttempt(preferred: id, selected: selected)
    if selected {
      engineSession.setOption(.asciiMode, ascii)
      schemaId = id                        // only cache the id the engine actually switched to
      pinnedWordsRevision = nil
      syncPinnedWords()
    } else {
      debugLiveInputTrace("switchLiveSessionSchema id=\(id) select=false — schemaId NOT updated (no cache poisoning)")
    }
    engineUpdate()                           // render the engine's true post-select state either way
    return selected ? .ok : .selectFailed(schemaID: id)
  }
}

// MARK: - Engine options

/// Option read/write/toggle helpers and the derived status-flags tuple used by the menu
/// builder and toggle actions (merged from the former `+RimeOptions` file).
extension OwlInputController {
  typealias EngineStatusFlags = (asciiMode: Bool, traditional: Bool, asciiPunct: Bool, fullShape: Bool)

  func currentEngineStatusFlags() -> EngineStatusFlags {
    guard let engineSession, engineSession.isValid, let status = engineSession.status() else { return (false, false, false, false) }
    return (status.isASCIIMode, currentTraditionalOutputEnabled(), status.isASCIIPunct, status.isFullShape)
  }

  func setEngineOption(_ option: EngineOption, _ enabled: Bool) {
    guard let engineSession, engineSession.isValid else { return }
    engineSession.setOption(option, enabled)
  }

  func toggleEngineOption(_ option: EngineOption) {
    guard let engineSession, engineSession.isValid else { return }
    engineSession.setOption(option, !engineSession.option(option))
    engineUpdate()
  }

  func optionValue(_ option: EngineOption) -> Bool {
    guard let engineSession, engineSession.isValid else { return false }
    return engineSession.option(option)
  }

  func currentTraditionalOutputEnabled() -> Bool {
    // rime-ice 全拼/双拼走 `.traditionalization`，五笔走 `.zhTrad`；`.transcription` 是 rime_mint 类
    // 方案的简繁 option，本底座用不到但保留以兼容其他可能携带这些 option 的方案。
    optionValue(.traditional) || optionValue(.traditionalization) || optionValue(.zhTrad) || optionValue(.transcription)
  }

  /// 简↔繁 全局开关：把 Owltype 暴露的各方案用到的所有简繁 option 一次性设到当前会话，使「简入繁出」
  /// 对全拼/双拼（`transcription`）与五笔（`zh_trad`）等所有方案统一生效。不调 `engineUpdate()`，
  /// 由调用方决定是否立即重渲染（session seed 不需要、菜单/设置即时切换需要）。
  func setTraditionalOutputOptions(_ traditional: Bool) {
    setEngineOption(.traditional, traditional)
    setEngineOption(.traditionalization, traditional)
    setEngineOption(.zhTrad, traditional)
    setEngineOption(.transcription, traditional)
    setEngineOption(.simplification, !traditional)
  }

  // MARK: - AI Candidate Association (#392)

  static let aiCandidateDebounceInterval: TimeInterval = 0.12

  func armAICandidateAfterInput() {
    guard let engineSession, engineSession.isValid,
          let input = engineSession.input(), !input.isEmpty else {
      return
    }
    let isEnglish = engineSession.option(.asciiMode)
    let aiAssociationEnabled = isEnglish ? OwlAICandidatePreferences.aiEnglishCandidateEnabled : OwlAICandidatePreferences.aiAssociationEnabled
    let jevRerankEnabled = !isEnglish && OwlAICandidatePreferences.jevDiscriminativeRerankEnabled
    guard aiAssociationEnabled || jevRerankEnabled else { return }

    if isSecureInputGated() { return }

    aiCandidateDebounceTimer?.invalidate()
    let timer = Timer(timeInterval: Self.aiCandidateDebounceInterval, repeats: false) { [weak self] _ in
      self?.aiCandidateDebounceFired()
    }
    aiCandidateDebounceTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func invalidateAICandidateForAction() {
    aiCandidateActionEpoch &+= 1
    aiCandidateDebounceTimer?.invalidate()
    aiCandidateDebounceTimer = nil
    aiTasks.cancel(.cloud)
  }

  func resetAICandidateRuntime() {
    aiCandidateActionEpoch &+= 1
    aiCandidateDebounceTimer?.invalidate()
    aiCandidateDebounceTimer = nil
    aiTasks.cancel(.cloud)
    activeAICandidates = []
    activeAICandidateTicket = nil
    activeAICandidateSlot = nil
    activeJevRerankIndex = nil
    activeJevRerankTicket = nil
    activeJevLocalCandidates = []
  }

  func aiCandidateDebounceFired() {
    aiCandidateDebounceTimer = nil
    guard let engineSession, engineSession.isValid,
          let input = engineSession.input(), !input.isEmpty else {
      return
    }
    let isEnglish = engineSession.option(.asciiMode)
    let aiAssociationEnabled = isEnglish ? OwlAICandidatePreferences.aiEnglishCandidateEnabled : OwlAICandidatePreferences.aiAssociationEnabled
    let jevRerankEnabled = !isEnglish && OwlAICandidatePreferences.jevDiscriminativeRerankEnabled
    guard aiAssociationEnabled || jevRerankEnabled else { return }

    if isSecureInputGated() { return }

    let ticket = OwlAICandidateTicket(
      sessionID: engineSession.sessionID,
      generation: engineSession.generation,
      rawInput: input,
      actionEpoch: aiCandidateActionEpoch
    )

    var preContext: String?
    if let client = self.client {
      let decisions = clientCapabilityDecisions(for: client)
      if decisions.surroundingText.allowed {
        let range = NSRange(location: 0, length: 0)
        if let str = client.attributedSubstring(from: range)?.string {
          preContext = String(str.suffix(100))
        }
      }
    }

    let service = self.aiCandidateService ?? OwlAICandidateService.shared

    var localCandidates: [String] = []
    if jevRerankEnabled {
      let peeked = engineSession.peekCandidates(from: 0, count: 32).map(\.text)
      if !peeked.isEmpty {
        localCandidates = peeked
      } else if let params = lastPanelComposition {
        localCandidates = params.candidates
      }
    }

    let pinyin = lastPanelComposition?.preedit ?? input

    aiTasks.run(.cloud) { [weak self] in
      var aiCandidates: [String] = []
      var rerankedIndex: Int?

      if aiAssociationEnabled {
        aiCandidates = await service.generateCandidates(ticket: ticket, preContext: preContext)
      }

      if jevRerankEnabled, localCandidates.count >= 2 {
        rerankedIndex = try? await service.rerankCandidates(
          preContext: preContext,
          pinyin: pinyin,
          localCandidates: localCandidates,
          ticket: ticket
        )
      }

      guard let self else { return }
      guard let currentSession = self.engineSession,
            currentSession.isValid,
            currentSession.sessionID == ticket.sessionID,
            currentSession.generation == ticket.generation,
            (currentSession.input() ?? "") == ticket.rawInput,
            self.aiCandidateActionEpoch == ticket.actionEpoch else {
        return
      }

      if let params = self.lastPanelComposition, params.page > 0 || self.currentHighlightedCandidateIndex > 0 {
        return
      }

      var hasUpdate = false
      if aiAssociationEnabled, !aiCandidates.isEmpty {
        self.activeAICandidates = aiCandidates
        self.activeAICandidateTicket = ticket
        hasUpdate = true
      }

      if jevRerankEnabled, let elevatedIndex = rerankedIndex, elevatedIndex > 0 {
        self.activeJevRerankIndex = elevatedIndex
        self.activeJevRerankTicket = ticket
        self.activeJevLocalCandidates = localCandidates
        hasUpdate = true
      }

      if hasUpdate {
        self.applyAICandidatesUpdate()
      }
    }
  }

  func applyAICandidatesUpdate() {
    guard let params = lastPanelComposition else { return }
    showPanel(
      preedit: params.preedit,
      cursor: params.cursor,
      selStart: params.selStart,
      selEnd: params.selEnd,
      candidates: params.candidates,
      comments: params.comments,
      labels: params.labels,
      highlighted: params.highlighted,
      page: params.page,
      lastPage: params.lastPage,
      pageSize: params.pageSize
    )
  }

  func isSecureInputGated() -> Bool {
    if IsSecureEventInputEnabled() { return true }
    let privacy = privacyStateProvider()
    if privacy.isSecureInputEnabled || privacy.isPasswordLike { return true }
    if let app = NSWorkspace.shared.frontmostApplication,
       AXIsProcessTrusted(), !app.isTerminated {
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      var ref: CFTypeRef?
      if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
         let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
        let element = ref as! AXUIElement
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subroleStr = subrole as? String,
           subroleStr == (kAXSecureTextFieldSubrole as String) {
          return true
        }
      }
    }
    return false
  }

  func shouldInterceptForAICandidate(keycode: UInt32, modifiers: UInt32) -> Bool {
    guard let slotIndex = activeAICandidateSlot, !activeAICandidates.isEmpty else { return false }
    let blocked = kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue
    guard (modifiers & blocked) == 0 else { return false }

    let numberKey = UInt32(XK_1) + UInt32(slotIndex)
    let keypadKey = UInt32(XK_KP_1) + UInt32(slotIndex)
    if keycode == numberKey || keycode == keypadKey {
      return true
    }

    if currentHighlightedCandidateIndex == slotIndex {
      if keycode == UInt32(XK_space) || keycode == UInt32(XK_Return) || keycode == UInt32(XK_KP_Enter) {
        return true
      }
    }

    return false
  }

  func shouldInterceptForJevRerank(keycode: UInt32, modifiers: UInt32) -> Int? {
    guard activeJevRerankIndex != nil, !lastComposedCandidates.isEmpty else { return nil }
    guard let ticket = activeJevRerankTicket,
          let currentSession = engineSession,
          currentSession.isValid,
          currentSession.sessionID == ticket.sessionID,
          currentSession.generation == ticket.generation,
          (currentSession.input() ?? "") == ticket.rawInput,
          aiCandidateActionEpoch == ticket.actionEpoch else {
      return nil
    }
    let blocked = kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue
    guard (modifiers & blocked) == 0 else { return nil }

    // Space / Enter with currentHighlightedCandidateIndex
    if keycode == UInt32(XK_space) || keycode == UInt32(XK_Return) || keycode == UInt32(XK_KP_Enter) {
      if currentHighlightedCandidateIndex >= 0 && currentHighlightedCandidateIndex < lastComposedCandidates.count {
        return currentHighlightedCandidateIndex
      }
    }

    let numberKeyCodes: [UInt32] = [XK_1, XK_2, XK_3, XK_4, XK_5, XK_6, XK_7, XK_8, XK_9].map { UInt32($0) }
    let keypadKeyCodes: [UInt32] = [XK_KP_1, XK_KP_2, XK_KP_3, XK_KP_4, XK_KP_5, XK_KP_6, XK_KP_7, XK_KP_8, XK_KP_9].map { UInt32($0) }
    for (i, code) in numberKeyCodes.enumerated() where keycode == code && i < lastComposedCandidates.count {
      return i
    }
    for (i, code) in keypadKeyCodes.enumerated() where keycode == code && i < lastComposedCandidates.count {
      return i
    }

    return nil
  }

  func commitActiveAICandidate() {
    guard let aiText = activeAICandidates.first else { return }
    commitAICandidate(text: aiText)
  }

  func commitAICandidate(text: String) {
    clearHostComposition()
    activeAICandidates = []
    activeAICandidateTicket = nil
    activeAICandidateSlot = nil
    activeJevRerankIndex = nil
    activeJevRerankTicket = nil
    activeJevLocalCandidates = []
    commit(string: text)
    engineSession?.clearComposition()
    engineUpdate()
  }
}
