//
//  OwlInputController+Session.swift
//  Owltype
//
//  Single responsibility: librime session lifecycle (create / app-options / destroy)
//  and chord-typing accumulation (timer + key buffer) for OwlInputController.
//  Moved verbatim out of OwlInputController.swift (god-object shrink, 2026-06-20);
//  no logic edits.
//

import InputMethodKit
import Foundation

extension OwlInputController {

  func debugLiveInputTrace(_ message: @autoclosure () -> String) {
    OwlLiveInputTrace.write(message)
  }

  func onChordTimer(_: Timer) {
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0, let rime, rime.sessionID != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = rime.process(keycode: chordKeyCodes[i], modifiers: chordModifiers[i] | kReleaseMask.rawValue)
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
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
    if let duration = NSApp.owlAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
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

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      OwlInputController.unknownAppCnt &+= 1
      return "UnknownApp\(OwlInputController.unknownAppCnt)"
    }()
    currentApp = app
    let newSession = NSApp.owlAppDelegate.engine.createSession()
    rime = newSession
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
      setRimeOption(.fullShape, OwlKeyboardPreferences.defaultFullShape)
      updateAppOptions()
      // Feature 1: seed 简↔繁 from the pref so Owltype's「简入繁出」choice survives focus changes /
      // new sessions (方案 reset 回简体). Seeds the full option set so it covers 全拼/双拼
      // (`transcription`) AND 五笔 (`zh_trad`) — a fresh wubi session otherwise loses 繁体.
      setTraditionalOutputOptions(OwlKeyboardPreferences.traditionalOutput)
      // 候选 emoji (rime-ice 原生 emoji switch). Owltype 出厂关；按 表情符号 设置开关 seed，
      // 让选择在焦点切换 / 新会话后保持（rime 每次新会话会 reset 回 schema 默认值）。
      setRimeOption(.emojiSuggestion, OwlEmojiPreferences.candidateEmojiEnabled)
      syncPinnedWords()
    }
    // Register as a LIVE controller so the fast settings-apply path can force this session to
    // reload the freshly-deployed `build/` (weak membership; deinit/destroy drops it). Idempotent.
    NSApp.owlAppDelegate.registerLiveController(self)
  }

  /// Guard the first real key after activation/update against librime restoring an older schema
  /// from `user.yaml`. The session is still idle here, so switching does not discard user input.
  func ensurePreferredSchemaForIdleSession() {
    guard let rime, rime.isValid else { return }
    let preferredSchema = OwlKeyboardPreferences.preferredSchemaID
    guard !preferredSchema.isEmpty else { return }
    if let input = rime.input(), !input.isEmpty {
      return
    }
    let currentSchema = rime.status()?.schemaId ?? schemaId
    switch OwlSchemaSelectionGate.idleAction(current: currentSchema, preferred: preferredSchema, knownFailed: knownFailedSchemaID) {
    case .alreadyActive:
      schemaId = currentSchema
      debugLiveInputTrace("ensurePreferred idle current=\(currentSchema) preferred=\(preferredSchema) noop")
    case .skipKnownFailed:
      // Back off: this preferred id already failed select() and config hasn't changed since. No
      // librime call, no per-key trace. The marker clears when a session recreate / config apply
      // re-runs createSession (or a later attempt succeeds).
      return
    case .attempt:
      let ascii = rime.option(.asciiMode)
      let selected = rime.selectSchema(preferredSchema)
      if selected { rime.setOption(.asciiMode, ascii) }
      knownFailedSchemaID = OwlSchemaSelectionGate.markerAfterAttempt(preferred: preferredSchema, selected: selected)
      debugLiveInputTrace("ensurePreferred idle current=\(currentSchema) preferred=\(preferredSchema) select=\(selected) after=\(rime.status()?.schemaId ?? "<nil>")")
      if selected {
        schemaId = preferredSchema
        pinnedWordsRevision = nil
        syncPinnedWords()
        MainActor.assumeIsolated { NSApp.owlAppDelegate.snapshotEmitter.noteSchemaChange() }
        NSApp.owlAppDelegate.loadSettings(for: preferredSchema)
      }
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    guard let rime else { return }
    let fallback: Bool
    if rime is OwlRustSession {
      fallback = OwlRustSchemaMap.initialASCIIMode(
        forApp: currentApp,
        englishBundleIDs: OwlKeyboardPreferences.appEnglishBundleIDs,
        defaultASCIIMode: OwlKeyboardPreferences.defaultAsciiMode
      )
    } else {
      let appOptions = NSApp.owlAppDelegate.config?.getAppOptions(currentApp) ?? [:]
      for (key, value) in appOptions where key != RimeOption.asciiMode.rawValue {
        // Other app options remain authoritative, including arbitrary user-defined keys.
        rime.setAppOption(key, value)
      }
      fallback = appOptions[RimeOption.asciiMode.rawValue]
        ?? OwlKeyboardPreferences.defaultAsciiMode
    }
    let restored = OwlAppInputMemory.shared.initialMode(app: currentApp, fallback: fallback)
    if rime.option(.asciiMode) != restored { rime.setOption(.asciiMode, restored) }
    appModeObservation.seed(restored)
    if let reportBundleID = NSApp.owlAppDelegate.config?.getBool("unsafe/report_bundleid"), reportBundleID {
      rime.setProperty(name: "client_app", value: currentApp)
    }
  }

  func destroySession() {
    finishAutomaticExpansion(replaySemicolon: false)
    // print("[DEBUG] destroySession:")
    rime?.destroy()
    rime = nil
    clearChord()
  }

  /// Resource-generation switches cannot use `rawInput` replay: Rust keeps partially selected
  /// phrase progress outside that string. The generation handoff therefore waits for an idle
  /// composition instead of recreating this session mid-selection.
  var hasInFlightComposition: Bool {
    guard let rime, rime.isValid else { return false }
    if let input = rime.input(), !input.isEmpty { return true }
    guard let composition = rime.composition() else { return false }
    return !composition.preedit.isEmpty
  }

  /// Fast settings-apply re-entry (Track 2, PR3; live-session-reload rewrite, 2026-06-22).
  /// Called for every LIVE controller after a `deploy_config_file` refreshed the compiled
  /// `build/`, or for a queued Rust generation switch after the last live session becomes idle.
  /// The latter reaches this code only from an outermost `rimeUpdate` / next-key boundary, never
  /// from the middle of `handle` / `processKey`.
  ///
  /// WHY destroy rather than `select_schema(sameId)`: a same-id reselect does NOT force librime
  /// to rebuild the cached `Schema` for that id, so the running session kept the OLD
  /// `menu/page_size` (the 8→5-not-applying bug). The old full `deploy()` only worked because
  /// `shutdownRime()` destroyed every session → the next keystroke `createSession` read fresh
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
  ///     4. replay the captured rawInput + `rimeUpdate()` so the panel re-renders with the
  ///        user's preedit intact.
  ///
  /// - BACKGROUND controller (`replayComposition == false`): a controller for an app that is NOT
  ///   front-most. We DESTROY ONLY — we do NOT eagerly `createSession()`. A backgrounded
  ///   controller has had `deactivateServer` set its `client = nil`, so an eager `createSession()`
  ///   would derive `currentApp = "UnknownApp<n>"` (losing the app's per-app ascii_mode/options
  ///   and bumping the UnknownApp counter). Destroy-only is both safe and sufficient: the
  ///   controller's `handle()` hot path already recreates the session (`rime?.isValid != true →
  ///   createSession()`) on its NEXT keystroke, by which point its `client` is live again, so the
  ///   fresh session reads the new `build/` AND derives the correct per-app options. The schema is
  ///   re-derived by the delegate's per-client schema selection on reactivation.
  ///
  /// No-op when there is no live session.
  ///
  /// - Parameter replayComposition: true only for the ACTIVE controller. Background controllers
  ///   pass `false` (destroy-only, lazy recreate on their next keystroke).
  func reapplyConfigToLiveSession(replayComposition: Bool) {
    guard let rime, rime.isValid else { return }

    // Background controller: destroy only. The next keystroke's `handle()` recreates the session
    // with a live `client`, reading the new `build/` and the correct per-app options. Eager
    // recreate here would mislabel the app (`UnknownApp<n>`) because its `client` is nil.
    guard replayComposition else {
      destroySession()
      return
    }

    let capturedSchema = schemaId
    let rawInput = rime.input() ?? ""

    // Active controller: force the session to re-read the freshly-deployed build/ by recreating
    // it (a same-id reselect would NOT pick up the new page_size). Recreating resets `schemaId`
    // to "". The active controller's `client` is live, so per-app options derive correctly.
    destroySession()
    createSession()
    guard let fresh = self.rime, fresh.isValid else { return }

    // A fresh session defaults to schema_list's first entry — restore the user's active schema
    // so the reload doesn't kick them off 五笔/双拼. This re-reads build/<id>.schema.yaml in place.
    if !capturedSchema.isEmpty {
      switchLiveSessionSchema(to: capturedSchema)
    }

    // Replay the in-flight composition so the panel re-renders under the new config without a
    // retype. (`switchLiveSessionSchema` already ran `rimeUpdate`, but it rendered an empty
    // composition; replay + a final `rimeUpdate` restores the user's preedit.)
    if !rawInput.isEmpty {
      replayRawInput(rawInput)
      rimeUpdate()
    }
  }

  /// Re-feed a previously-captured rawInput string to the live session so the composition
  /// is rebuilt under the new config. Off the keystroke hot path (only the fast-apply path
  /// and tests call it). Each ASCII byte is fed as its own rime keysym (lowercase letters /
  /// digits map 1:1 to their codepoint); non-ASCII is skipped — Owltype's raw input codes are
  /// ASCII. No-op on empty input.
  func replayRawInput(_ rawInput: String) {
    guard let rime, rime.isValid, !rawInput.isEmpty else { return }
    for scalar in rawInput.unicodeScalars where scalar.isASCII {
      _ = rime.process(keycode: scalar.value, modifiers: 0)
    }
  }

  /// Switch the active controller's LIVE session to a DIFFERENT schema (输入方式/双拼 picker),
  /// without a full `deploy()`. `select_schema(newId)` re-reads the already-built
  /// `build/<newId>.schema.yaml` in place (no dict/octagram rebuild; clears the composition).
  /// Updates the cached `schemaId` ONLY when the select actually lands, and re-renders. Off the IMK
  /// keystroke hot path. Returns `.noLiveSession` when there is no live session (the next
  /// `createSession` will pick up the switched schema, which librime remembers via the
  /// transient-session select the delegate also performs); `.selectFailed` when `select_schema`
  /// returns false (e.g. `build/<id>.schema.yaml` not compiled) — in that case `schemaId` is left
  /// untouched so the cache never claims a schema librime isn't actually on (设置显示拼音/打字出五笔).
  @discardableResult
  func switchLiveSessionSchema(to id: String) -> SchemaSwitchResult {
    guard !id.isEmpty, let rime, rime.isValid else { return .noLiveSession }
    finishAutomaticExpansion(replaySemicolon: false)
    let ascii = rime.option(.asciiMode)
    let selected = rime.selectSchema(id)   // re-reads build/<id>.schema.yaml in place; clears composition
    knownFailedSchemaID = OwlSchemaSelectionGate.markerAfterAttempt(preferred: id, selected: selected)
    if selected {
      rime.setOption(.asciiMode, ascii)
      schemaId = id                        // only cache the id librime actually switched to
      pinnedWordsRevision = nil
      syncPinnedWords()
    } else {
      debugLiveInputTrace("switchLiveSessionSchema id=\(id) select=false — schemaId NOT updated (no cache poisoning)")
    }
    rimeUpdate()                           // render librime's true post-select state either way
    return selected ? .ok : .selectFailed(schemaID: id)
  }
}
