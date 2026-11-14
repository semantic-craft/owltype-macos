//
//  OwlRustEngine.swift
//  Owltype
//
//  Swift adapter conforming to `InputEngine` / `EngineSession` on top of the Metasequoia
//  (`msime`) Rust engine via the narrow C-ABI (`owl_msime_ffi.h`, issue #249).
//

import CryptoKit
import Foundation

// MARK: - Schema Mapping

/// Native adapter for Rust-owned configuration. The catalog is decoded once.
enum OwlRustSchemaMap {
  static func initialASCIIMode(forApp bundleID: String, englishBundleIDs: [String],
                              defaultASCIIMode: Bool) -> Bool {
    OwlAppCore.initialASCIIMode(bundleID: bundleID, englishBundleIDs: englishBundleIDs,
                              defaultASCIIMode: defaultASCIIMode)
  }
  static func inputMode(forSchema id: String) -> String { configuration(id).inputMode }
  static func pinyinScheme(forSchema id: String) -> String { configuration(id).pinyinScheme }
  static func isTraditionalSchema(_ id: String) -> Bool { configuration(id).traditional }
  static func fuzzyBitmask(from snapshot: OwlFuzzySnapshot) -> UInt32 {
    OwlAppCore.fuzzyMask(snapshot)
  }
  static let supportedSchemas = OwlAppCore.keyboardCatalog.schemas.map { (id: $0.id, name: $0.name) }
  private static let configurations = Dictionary(uniqueKeysWithValues:
    OwlAppCore.keyboardCatalog.schemas.map { ($0.id, $0) })
  static func configuration(_ id: String) -> OwlAppCore.SchemaConfiguration {
    configurations[id] ?? OwlAppCore.required(["operation": "keyboard_schema", "schema": id])
  }
  static func displayName(for id: String) -> String {
    configurations[id]?.name ?? id
  }
}

// MARK: - Rerank, Traits & Controller Service Ports

enum OwlSettledRerankTiming {
  static let debounce: TimeInterval = 0.15
  static let pollInterval: TimeInterval = 1.0 / 60.0
  static let modelLoadPollInterval: TimeInterval = 0.05
}

struct OwlSettledRerankTicket: Equatable, Sendable {
  let sessionID: UInt64
  let generation: UInt64
  let rawInput: String
  let configurationEpoch: UInt64

  func isCurrent(
    sessionID: UInt64,
    generation: UInt64,
    rawInput: String,
    configurationEpoch: UInt64
  ) -> Bool {
    self.sessionID == sessionID
      && self.generation == generation
      && self.rawInput == rawInput
      && self.configurationEpoch == configurationEpoch
  }
}

struct OwlSettledRerankStartResult: Equatable, Sendable {
  let token: UInt64?
  let current: Bool
  let moved: Bool
  let error: String?

  static let noWork = OwlSettledRerankStartResult(
    token: nil,
    current: true,
    moved: false,
    error: nil
  )
}

struct OwlSettledRerankPollResult: Equatable, Sendable {
  let pending: Bool
  let current: Bool
  let moved: Bool
  let error: String?

  static let doneWithoutChange = OwlSettledRerankPollResult(
    pending: false,
    current: false,
    moved: false,
    error: nil
  )
}

struct OwlEngineTraits {
  let sharedDataDir: URL
  let userDataDir: URL
}

typealias EngineNotificationHandler = (UInt64, String, String?) -> Void

@MainActor
protocol SnapshotReading: AnyObject {
  var current: OwlCompositionSnapshot? { get }
}

extension OwlSnapshotRegistry: SnapshotReading {}

@MainActor
protocol SnapshotEmitting: AnyObject {
  func emitComposing(rawInput: String)
  func emitCleared()
}

@MainActor
protocol SelectionPolishing: AnyObject {
  func polishSelection(_ selection: String) async throws -> [String]
}

extension OwlSnapshotEmitter: SnapshotEmitting {}
extension OwlSelectionPolishService: SelectionPolishing {}

// MARK: - OwlRustSession

class OwlRustSession {
  private static let localModeEntryLetters = Set("UTKEMJYRVCS")
  var sessionID: UInt64
  private var handle: OpaquePointer?
  private weak var ownerEngine: OwlRustEngine?
  private var activeSchemaId: String
  private var pendingCommitText: String?
  private var lastCommittedRawInput: String?
  private var latestSnapshot: OwlRustSnapshotDTO?
  private var latestGeneration: UInt64 = 0
  private var caretByteOffset: Int = 0
  private var preeditCaretByteOffset: Int = 0
  private var lastAppliedPageSize: Int = 0
  private var lastAppliedASCIIPunct: Bool?
  private var lastAppliedFuzzyMask: UInt32 = 0
  private var lastAppliedWubiCandidateMode: String = ""
  /// One slot per `OwlKeyboardSettingsCatalog.engineOptions` entry, in the same order.
  private var lastAppliedEngineOptions = [Bool?](
    repeating: nil, count: OwlKeyboardSettingsCatalog.engineOptions.count
  )
  private var lastAppliedHostPhrases: String = ""
  private var lastAppliedRerankConfiguration: String?
  private var lastRerankStatusRefresh: UInt64 = 0
  private let resourceRoot: URL?
  private(set) var rerankConfigurationEpoch: UInt64 = 0
  private(set) var settledRerankReady = false
  private(set) var settledRerankLoading = false
  private var optionFlags: [EngineOption: Bool] = [
    .simplification: true,
    .linear: true
  ]
  private var properties: [String: String] = [:]
  private var shiftKeyArmed = false
  private var capsLockKeyState = OwlCapsLockKeyState()

  var generation: UInt64 {
    latestGeneration
  }

  private var isTraditionalEnabled: Bool {
    if OwlRustSchemaMap.isTraditionalSchema(activeSchemaId) {
      return true
    }
    if (optionFlags[.traditional] ?? false)
      || (optionFlags[.traditionalization] ?? false)
      || (optionFlags[.zhTrad] ?? false)
      || (optionFlags[.transcription] ?? false) {
      return true
    }
    if let simp = optionFlags[.simplification], !simp {
      return true
    }
    return false
  }

  private func convertToTraditionalIfNeeded(_ text: String, forCandidateDisplay: Bool = false) -> String {
    guard isTraditionalEnabled, !text.isEmpty else { return text }
    if text.hasPrefix(OwlTemplateStore.candidatePrefix) {
      guard forCandidateDisplay else { return text }
      if let closeBracket = text.firstIndex(of: "]") {
        let nextIdx = text.index(after: closeBracket)
        let prefix = String(text[..<nextIdx])
        let title = String(text[nextIdx...])
        let convertedTitle = OwlPinnedWords.hansToHant(title)
        return prefix + convertedTitle
      }
      return text
    }
    return OwlPinnedWords.hansToHant(text)
  }

  init(
    sessionID: UInt64,
    handle: OpaquePointer? = nil,
    ownerEngine: OwlRustEngine? = nil,
    initialSchemaId: String = "rime_ice",
    resourceRoot: URL? = nil
  ) {
    self.sessionID = sessionID
    self.resourceRoot = resourceRoot
    self.handle = handle
    self.ownerEngine = ownerEngine
    self.activeSchemaId = initialSchemaId
    if handle != nil {
      _ = selectSchema(initialSchemaId)
      refreshSnapshot()
    }
  }

  deinit {
    destroy()
  }

  var isValid: Bool {
    handle != nil
  }

  func process(keycode: UInt32, modifiers: UInt32) -> Bool {
    guard handle != nil else { return false }
    let isRelease = (modifiers & kReleaseMask.rawValue) != 0
    let isShiftKey = (keycode == UInt32(XK_Shift_L) || keycode == UInt32(XK_Shift_R))
    let isCapsLockKey = keycode == UInt32(XK_Caps_Lock)

    if isShiftKey {
      if !isRelease {
        shiftKeyArmed = OwlKeyboardPreferences.shiftSwitchCJK
      } else if shiftKeyArmed {
        shiftKeyArmed = false
        setASCIIModeCommittingRawInput(!(optionFlags[.asciiMode] ?? false))
        capsLockKeyState.resetForOtherASCIIModeSwitch()
      }
      return false
    }

    if isCapsLockKey {
      return processCapsLockKey(modifiers: modifiers, isRelease: isRelease)
    }

    if !isRelease {
      shiftKeyArmed = false
    } else {
      return false
    }

    // Mirror ascii_composer's post-Caps handling. With good_old_caps_lock off, letters under a
    // physical Caps Lock are inverted and committed by the IME; everything else passes through.
    if OwlKeyboardPreferences.shiftSwitchCJK, (modifiers & kLockMask.rawValue) != 0 {
      if !OwlKeyboardPreferences.goodOldCapsLock,
         (modifiers & (kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue)) == 0,
         let replacement = invertedASCIILetter(for: keycode) {
        pendingCommitText = convertToTraditionalIfNeeded(replacement)
        return true
      }
      return false
    }

    // Control+Shift+3 / Control+Shift+# toggles Chinese/ASCII punctuation (when: always).
    let hasControl = (modifiers & kControlMask.rawValue) != 0
    let hasShift = (modifiers & kShiftMask.rawValue) != 0
    let hasAltOrSuper = (modifiers & (kAltMask.rawValue | kSuperMask.rawValue)) != 0
    if hasControl && hasShift && !hasAltOrSuper
       && (keycode == UInt32(XK_3) || keycode == UInt32(XK_numbersign)) {
      let nextPunct = !(optionFlags[.asciiPunct] ?? false)
      setOption(.asciiPunct, nextPunct)
      return true
    }

    if let handled = processSegmentEditingChord(keycode: keycode, modifiers: modifiers) {
      return handled
    }

    let disallowedModifiers = kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue
    if (modifiers & disallowedModifiers) != 0 {
      finishNativeComposition()
      return false
    }

    let isASCII = optionFlags[.asciiMode] ?? false
    if isASCII {
      return false
    }

    let hasActiveInput = !(latestSnapshot?.rawInput.isEmpty ?? true)
    syncRuntimePreferences(includeHostPhrases: false)

    if keycode == UInt32(XK_semicolon), latestSnapshot?.spellingSymbols.contains(";") == true {
      return applyActionResponse(sendAction(["op": "insert", "ch": ";"]))
    }

    if let action = localModeInsertionAction(for: keycode) {
      return applyActionResponse(sendAction(action))
    }

    if let trigger = punctuationMenuTrigger(for: keycode, modifiers: modifiers) {
      return applyActionResponse(sendAction([
        "op": "punctuation_menu",
        "ch": trigger
      ]))
    }

    if !hasActiveInput {
      if keycode == UInt32(XK_grave)
         && activeSchemaId.hasPrefix("wubi")
         && OwlKeyboardPreferences.wubiEnglishChannel {
        return applyActionResponse(sendAction(["op": "insert", "ch": "`"]))
      }
      if keycode >= UInt32(XK_a) && keycode <= UInt32(XK_z),
         let scalar = UnicodeScalar(keycode) {
        return applyActionResponse(sendAction(["op": "insert", "ch": String(scalar)]))
      }
      if hasShift, let character = asciiKeyCharacter(for: keycode),
         Self.localModeEntryLetters.contains(character) {
        return applyActionResponse(sendAction(["op": "insert", "ch": String(character)]))
      }
      if !(optionFlags[.asciiPunct] ?? false),
         let punct = asciiPunctuationString(for: keycode) {
        return applyActionResponse(sendAction(["op": "punctuation", "ch": punct, "ascii": false]))
      }
      return false
    }

    return processActiveCompositionKey(keycode: keycode)
  }

  private func processCapsLockKey(modifiers: UInt32, isRelease: Bool) -> Bool {
    shiftKeyArmed = false
    guard OwlKeyboardPreferences.shiftSwitchCJK else {
      capsLockKeyState.resetForOtherASCIIModeSwitch()
      return false
    }
    guard !isRelease else { return false }
    let transition = capsLockKeyState.processPress(
      preFlipCapsLocked: (modifiers & kLockMask.rawValue) != 0,
      asciiMode: optionFlags[.asciiMode] ?? false,
      goodOldCapsLock: OwlKeyboardPreferences.goodOldCapsLock
    )
    switch transition {
    case .passThrough:
      return false
    case let .setASCIIMode(asciiMode, consumed):
      setASCIIModeCommittingRawInput(asciiMode)
      return consumed
    }
  }

  private func processSegmentEditingChord(keycode: UInt32, modifiers: UInt32) -> Bool? {
    // Native segment-editing chords belong to an active composition, before the
    // usual Control passthrough. The runtime owns boundaries for every scheme.
    let segmentModifiers = modifiers & (kControlMask.rawValue | kShiftMask.rawValue
      | kAltMask.rawValue | kSuperMask.rawValue)
    if !(optionFlags[.asciiMode] ?? false), !(latestSnapshot?.rawInput.isEmpty ?? true),
       segmentModifiers == kControlMask.rawValue || segmentModifiers == kShiftMask.rawValue {
      if keycode == UInt32(XK_Left) || keycode == UInt32(XK_Right) {
        return applyActionResponse(sendAction([
          "op": "segment", "target": keycode == UInt32(XK_Left) ? "left" : "right"
        ]))
      }
      if keycode == UInt32(XK_BackSpace), segmentModifiers == kControlMask.rawValue {
        return applyActionResponse(sendAction(["op": "segment", "target": "backspace"]))
      }
    }

    return nil
  }

  /// Native application chords finish the highlighted conversion before passthrough.
  /// Dedicated IME shortcuts and segment editing are resolved before this boundary.
  @discardableResult
  func finishNativeComposition(onFocusLoss: Bool = false) -> Bool {
    let action = onFocusLoss ? "finish_on_focus_loss" : "finish"
    guard let response = sendAction(["op": action]), response.isOK else { return false }
    _ = applyActionResponse(response)
    return true
  }

  func balanceHostPairedPunctuation() {
    _ = applyActionResponse(sendAction(["op": "balance_pair"]))
  }

  var acceptsHostSmartPunctuation: Bool { latestSnapshot?.localMode == "none" }
  func processHostASCIIPunctuation(_ character: String) -> Bool {
    applyActionResponse(sendAction(["op": "punctuation", "ch": character, "ascii": true]))
  }

  private func localModeInsertionAction(for keycode: UInt32) -> [String: Any]? {
    guard let snapshot = latestSnapshot,
          snapshot.localMode != "none",
          let character = asciiKeyCharacter(for: keycode) else { return nil }
    switch snapshot.localMode {
    case "unicode":
      guard character.isHexDigit || (snapshot.rawInput == "U" && character == "+") else {
        return nil
      }
    case "expression":
      guard snapshot.spellingSymbols.contains(character) else { return nil }
    default:
      return nil
    }
    return ["op": "insert", "ch": String(character)]
  }

  private func punctuationMenuTrigger(for keycode: UInt32, modifiers: UInt32) -> String? {
    guard !(optionFlags[.asciiPunct] ?? false) else { return nil }
    if keycode == UInt32(XK_4), (modifiers & kShiftMask.rawValue) != 0 {
      return "$"
    }
    if keycode == UInt32(XK_slash), OwlKeyboardPreferences.slashSymbolMenu {
      return "/"
    }
    if keycode == UInt32(XK_less), OwlKeyboardPreferences.angleSymbolMenu {
      return "<"
    }
    return nil
  }

  private func processActiveCompositionKey(keycode: UInt32) -> Bool {
    if let action = directCompositionAction(for: keycode) {
      return applyActionResponse(sendAction(action))
    }
    if isPageUpKey(keycode) {
      return changePage(up: true)
    }
    if isPageDownKey(keycode) {
      return changePage(up: false)
    }
    if let candidateIndex = candidateSelectionIndex(for: keycode) {
      return selectCandidate(candidateIndex)
    }
    if let punct = asciiPunctuationString(for: keycode) {
      let ascii = optionFlags[.asciiPunct] ?? false
      return applyActionResponse(sendAction(["op": "punctuation", "ch": punct, "ascii": ascii]))
    }
    return false
  }

  private func directCompositionAction(for keycode: UInt32) -> [String: Any]? {
    if let character = asciiKeyCharacter(for: keycode), character.isLetter {
      return ["op": "insert", "ch": String(character)]
    }
    if keycode == UInt32(XK_apostrophe) && !OwlKeyboardPreferences.select23Semicolon {
      return ["op": "insert", "ch": "'"]
    }
    if keycode == UInt32(XK_BackSpace) {
      return ["op": "backspace"]
    }
    if keycode == UInt32(XK_Delete) {
      return ["op": "delete"]
    }
    if keycode == UInt32(XK_space) {
      return ["op": "space"]
    }
    if keycode == UInt32(XK_Return) || keycode == UInt32(XK_KP_Enter) {
      return ["op": "commit_raw"]
    }
    if keycode == UInt32(XK_Escape) {
      return ["op": "clear"]
    }
    if keycode == UInt32(XK_Home) {
      return ["op": "move_caret", "target": "home"]
    }
    if keycode == UInt32(XK_End) {
      return ["op": "move_caret", "target": "end"]
    }
    let linear = optionFlags[.linear] ?? true
    // Native macOS shuangpin edits syllables when Left/Right do not navigate
    // candidates (InputController.mm:7711). Keep the candidate-navigation preference.
    if !linear && activeSchemaId.hasPrefix("double_pinyin") {
      if keycode == UInt32(XK_Left) {
        return ["op": "segment", "target": "left"]
      }
      if keycode == UInt32(XK_Right) {
        return ["op": "segment", "target": "right"]
      }
    }
    let firstCandidate = latestSnapshot?.page == 0 && latestSnapshot?.highlightedIndex == 0
    if firstCandidate && keycode == UInt32(XK_Left) {
      return ["op": "move_caret", "target": "left"]
    }
    if firstCandidate && keycode == UInt32(XK_Right)
       && caretByteOffset < (latestSnapshot?.rawInput.utf8.count ?? 0) {
      return ["op": "move_caret", "target": "right"]
    }
    if keycode == UInt32(XK_Down) || (linear && keycode == UInt32(XK_Right)) {
      return ["op": "move_highlight", "delta": 1]
    }
    if keycode == UInt32(XK_Up) || (linear && keycode == UInt32(XK_Left)) {
      return ["op": "move_highlight", "delta": -1]
    }
    if !linear && keycode == UInt32(XK_Left) {
      return ["op": "move_caret", "target": "left"]
    }
    if !linear && keycode == UInt32(XK_Right) {
      return ["op": "move_caret", "target": "right"]
    }
    return nil
  }

  private func setASCIIModeCommittingRawInput(_ asciiMode: Bool) {
    let raw = latestSnapshot?.rawInput ?? ""
    if !raw.isEmpty {
      _ = applyActionResponse(sendAction(["op": "commit_raw"]))
    }
    setOption(.asciiMode, asciiMode)
  }

  func takeCommit() -> String? {
    defer { pendingCommitText = nil }
    return pendingCommitText
  }

  func lastCommittedInput() -> String? {
    lastCommittedRawInput
  }

  func status() -> EngineStatus? {
    guard handle != nil else { return nil }
    return EngineStatus(
      schemaId: activeSchemaId,
      isASCIIMode: optionFlags[.asciiMode] ?? false,
      isASCIIPunct: optionFlags[.asciiPunct] ?? false,
      isFullShape: optionFlags[.fullShape] ?? false
    )
  }

  func composition() -> EngineComposition? {
    guard handle != nil else { return nil }
    if latestSnapshot == nil {
      refreshSnapshot()
    }
    // Like the former Rime seam's valid empty context, a cleared snapshot must reach the renderer:
    // nil only hides the panel and leaves the host's previous marked text in place.
    guard let snap = latestSnapshot else {
      return nil
    }
    let preedit = snap.preedit.isEmpty ? snap.rawInput : snap.preedit
    let utf8Count = preedit.utf8.count
    let candidates = snap.candidates.map {
      EngineCandidate(
        text: convertToTraditionalIfNeeded($0.text, forCandidateDisplay: true),
        comment: $0.comment
      )
    }
    let pageSize = max(1, snap.pageSize)
    let labels = (1...pageSize).map { "\($0)" }
    let highlighted = min(max(0, snap.highlightedIndex), max(0, candidates.count - 1))
    let preview = candidates.indices.contains(highlighted) ? candidates[highlighted].text : preedit
    let effectiveCaret = min(max(0, preeditCaretByteOffset), utf8Count)

    return EngineComposition(
      preedit: preedit,
      selStart: 0,
      selEnd: utf8Count,
      cursorPos: effectiveCaret,
      commitTextPreview: preview,
      candidates: candidates,
      labels: labels,
      pageNo: snap.page,
      pageSize: pageSize,
      isLastPage: !snap.hasMorePages,
      highlightedIndex: highlighted
    )
  }

  func input() -> String? {
    guard handle != nil else { return nil }
    if latestSnapshot == nil {
      refreshSnapshot()
    }
    return latestSnapshot?.rawInput ?? ""
  }

  func caretPos() -> Int {
    caretByteOffset
  }

  func clearComposition() {
    guard handle != nil else { return }
    _ = applyActionResponse(sendAction(["op": "clear"]))
  }

  func selectCandidate(_ index: Int) -> Bool {
    guard handle != nil, index >= 0 else { return false }
    return applyActionResponse(sendAction(["op": "select_visible", "index": index]))
  }

  func selectCandidateAbsolute(_ index: Int) -> Bool {
    guard handle != nil, index >= 0 else { return false }
    return applyActionResponse(sendAction([
      "op": "select_token",
      "index": index,
      "is_absolute": true
    ]))
  }

  func selectCandidate(_ token: OwlCandidateToken) -> Bool {
    guard handle != nil, token.candidateID >= 0 else { return false }
    if token.sessionID != 0 && token.sessionID != sessionID {
      return false
    }
    var payload: [String: Any] = [
      "op": "select_token",
      "index": token.candidateID,
      "is_absolute": token.isAbsolute
    ]
    if token.generation != 0 {
      payload["generation"] = token.generation
    }
    return applyActionResponse(sendAction(payload))
  }

  func removeCandidate(_ token: OwlCandidateToken) -> Bool {
    guard handle != nil, token.candidateID >= 0, !token.isAbsolute,
          token.sessionID == sessionID, token.generation != 0 else { return false }
    return applyActionResponse(sendAction([
      "op": "remove_token", "index": token.candidateID,
      "generation": token.generation, "is_absolute": false
    ]))
  }

  func peekCandidates(from index: Int, count: Int) -> [EngineCandidate] {
    guard handle != nil, count > 0 else { return [] }
    guard let dto = sendAction([
      "op": "peek_candidates",
      "start": max(0, index),
      "count": count
    ]), dto.isOK else {
      return []
    }
    if let gen = dto.generation {
      latestGeneration = gen
    }
    return dto.candidates.map {
      EngineCandidate(
        text: convertToTraditionalIfNeeded($0.text, forCandidateDisplay: true),
        comment: $0.comment
      )
    }
  }

  func changePage(up: Bool) -> Bool {
    guard handle != nil else { return false }
    return applyActionResponse(sendAction(["op": "turn_page", "delta": up ? -1 : 1]))
  }

  func selectSchema(_ id: String) -> Bool {
    guard handle != nil,
          OwlRustSchemaMap.supportedSchemas.contains(where: { $0.id == id }) else {
      return false
    }
    let mode = OwlRustSchemaMap.inputMode(forSchema: id)
    let scheme = OwlRustSchemaMap.pinyinScheme(forSchema: id)
    let pageSize = OwlKeyboardPreferences.pageSize
    guard sendAction(["op": "set_input_mode", "mode": mode])?.isOK == true else {
      return false
    }
    if mode == "wubi" {
      let profile = OwlRustSchemaMap.configuration(id).wubiProfile
      guard sendAction(["op": "set_wubi_profile", "profile": profile])?.isOK == true else { return false }
    }
    var schemeAction: [String: Any] = ["op": "set_pinyin_scheme", "scheme": scheme]
    if scheme == "custom" {
      guard let table = OwlRustSchemaMap.configuration(id).customProfile else {
        return false
      }
      schemeAction["custom_profile"] = table
    }
    guard sendAction(schemeAction)?.isOK == true,
          sendAction(["op": "set_page_size", "page_size": pageSize])?.isOK == true else {
      return false
    }
    lastAppliedPageSize = pageSize
    guard syncRuntimePreferences(includeHostPhrases: true),
          let cleared = sendAction(["op": "clear"]),
          cleared.isOK else {
      return false
    }
    _ = applyActionResponse(cleared)
    activeSchemaId = id
    ownerEngine?.recordSelectedSchema(id)
    return true
  }

  @discardableResult
  func syncRuntimePreferences(includeHostPhrases: Bool) -> Bool {
    guard handle != nil, applyRuntimePreferences(includeHostPhrases: includeHostPhrases) else {
      return false
    }
    syncRerankConfiguration()
    return true
  }

  private func applyRuntimePreferences(includeHostPhrases: Bool) -> Bool {
    let pageSize = OwlKeyboardPreferences.pageSize
    let fuzzyMask = OwlRustSchemaMap.fuzzyBitmask(from: OwlFuzzySnapshot.current())
    let candMode = OwlKeyboardPreferences.wubiCandidateMode.rawValue
    guard
      applyChanged(pageSize, at: \.lastAppliedPageSize,
                   action: { ["op": "set_page_size", "page_size": pageSize] }),
      applyChanged(fuzzyMask, at: \.lastAppliedFuzzyMask, requiresIdle: OwlAppCore.keyboardCatalog.idleSettings.contains("fuzzyRules"),
                   action: { ["op": "set_fuzzy_rules", "mask": fuzzyMask] }),
      applyChanged(candMode, at: \.lastAppliedWubiCandidateMode, requiresIdle: OwlAppCore.keyboardCatalog.idleSettings.contains("wubiCandidateMode"),
                   action: { ["op": "set_wubi_candidate_mode", "mode": candMode] })
    else { return false }
    guard applyEngineOptions(), applyASCIIPunctIfNeeded() else { return false }
    guard includeHostPhrases, let ownerEngine else { return true }
    let packed = ownerEngine.loadPackedHostPhrases()
    return applyChanged(packed, at: \.lastAppliedHostPhrases) {
      ["op": "set_host_phrases", "text": packed]
    }
  }

  /// Push each catalog engine option whose stored value differs from the last one sent.
  private func applyEngineOptions() -> Bool {
    let catalog = OwlKeyboardSettingsCatalog.live
    for (index, option) in OwlKeyboardSettingsCatalog.engineOptions.enumerated() {
      let value = catalog.load(option.toggle)
      guard value != lastAppliedEngineOptions[index], canApplyPreference(requiresIdle: option.requiresIdle) else { continue }
      guard let response = sendAction(["op": "set_option", "name": option.name, "value": value]),
            response.isOK else { return false }
      lastAppliedEngineOptions[index] = value
      // Quick phrases queue until the composition is idle, so their snapshot is safe to take.
      // Other options keep the snapshot they had: `wubi_z_wildcard` rebuilds the engine and
      // cancels the composition, and the host must not see that mid-keystroke.
      if option.toggle == .quickPhraseCandidates {
        _ = applyActionResponse(response)
      }
    }
    return true
  }

  private func applyASCIIPunctIfNeeded() -> Bool {
    let value = OwlKeyboardPreferences.cjkPunctToggle
    guard applyChanged(value, at: \.lastAppliedASCIIPunct, action: {
      ["op": "set_option", "name": EngineOption.asciiPunct.rawValue, "value": value]
    }) else { return false }
    optionFlags[.asciiPunct] = value
    return true
  }

  private func applyChanged<Value: Equatable>(
    _ value: Value,
    at keyPath: ReferenceWritableKeyPath<OwlRustSession, Value>,
    requiresIdle: Bool = false,
    action: () -> [String: Any]
  ) -> Bool {
    guard value != self[keyPath: keyPath], canApplyPreference(requiresIdle: requiresIdle) else { return true }
    guard sendAction(action())?.isOK == true else { return false }
    self[keyPath: keyPath] = value
    return true
  }

  private func canApplyPreference(requiresIdle: Bool) -> Bool {
    let composing = !(input() ?? "").isEmpty || !(composition()?.preedit ?? "").isEmpty
    return owl_app_keyboard_can_apply(requiresIdle ? 1 : 0, composing ? 1 : 0) != 0
  }

  func syncRerankPreferences() {
    syncRerankConfiguration(forceStatus: true)
  }

  func startSettledRerank() -> OwlSettledRerankStartResult {
    guard handle != nil, settledRerankReady else { return .noWork }
    let result = callRerankJSON(
      owl_msime_session_start_settled_rerank_json,
      fallback: OwlRustSettledRerankResponseDTO(
        status: "done",
        token: nil,
        current: false,
        moved: false,
        error: "cannot start settled rerank"
      )
    )
    let token = result.status == "pending" ? result.token : nil
    if result.current == true, result.moved == true {
      refreshSnapshot()
    }
    return OwlSettledRerankStartResult(
      token: token,
      current: result.current ?? false,
      moved: result.moved ?? false,
      error: result.error
    )
  }

  func pollSettledRerank(token: UInt64, accept: Bool) -> OwlSettledRerankPollResult {
    guard handle != nil else { return .doneWithoutChange }
    let result = callRerankJSON(
      { ptr in
        owl_msime_session_poll_settled_rerank_json(ptr, token, accept)
      },
      fallback: OwlRustSettledRerankResponseDTO(
        status: "done",
        token: nil,
        current: false,
        moved: false,
        error: "cannot poll settled rerank"
      )
    )
    if result.current == true, result.moved == true {
      refreshSnapshot()
    }
    return OwlSettledRerankPollResult(
      pending: result.status == "pending",
      current: result.current ?? false,
      moved: result.moved ?? false,
      error: result.error
    )
  }

  func option(_ option: EngineOption) -> Bool {
    optionFlags[option] ?? false
  }

  func setOption(_ option: EngineOption, _ value: Bool) {
    let previous = optionFlags[option]
    optionFlags[option] = value
    _ = sendAction(["op": "set_option", "name": option.rawValue, "value": value])
    if previous != value {
      ownerEngine?.notifyOptionChanged(sessionID: sessionID, optionName: option.rawValue, value: value)
    }
  }

  func setProperty(name: String, value: String) {
    properties[name] = value
    if name == OwlPinnedWords.property, handle != nil {
      let sources = OwlPinnedWords.traditionalSources(engineValue: value)
      if let dto = sendAction(["op": "set_pinned_words", "text": value, "traditional_sources": sources.map(\.actionPayload)]), dto.isOK {
        latestSnapshot = dto
        latestGeneration = dto.generation ?? latestGeneration
        caretByteOffset = dto.caretPosition ?? dto.rawInput.utf8.count
        preeditCaretByteOffset = dto.preeditCaretByte ?? dto.preedit.utf8.count
      }
    }
  }

  func stateLabel(option name: String, state: Bool, abbreviated: Bool) -> String? {
    switch name {
    case EngineOption.asciiMode.rawValue:
      return state ? "英" : "中"
    case EngineOption.asciiPunct.rawValue:
      return state ? ".，" : "。，"
    case EngineOption.fullShape.rawValue:
      return state ? "全" : "半"
    case EngineOption.traditional.rawValue,
         EngineOption.traditionalization.rawValue,
         EngineOption.zhTrad.rawValue,
         EngineOption.transcription.rawValue:
      return state ? "繁" : "简"
    case EngineOption.emojiSuggestion.rawValue:
      return state ? "😄" : "👍"
    default:
      return abbreviated ? nil : name
    }
  }

  func destroy() {
    if let ptr = handle {
      owl_msime_session_destroy(ptr)
      handle = nil
    }
    ownerEngine?.removeSession(id: sessionID)
  }

  // MARK: - FFI Bridge Helpers

  private func syncRerankConfiguration(forceStatus: Bool = false) {
    guard handle != nil, let ownerEngine else { return }
    let configuration = ownerEngine.rerankConfiguration(resourcesURL: resourceRoot)
    guard let serialized = configuration.serialized() else { return }
    if serialized != lastAppliedRerankConfiguration {
      lastAppliedRerankConfiguration = serialized
      rerankConfigurationEpoch &+= 1
      let status = serialized.withCString { config in
        decodeRerankStatus(owl_msime_session_configure_rerank_json(handle, config))
      }
      applyRerankStatus(status)
      lastRerankStatusRefresh = DispatchTime.now().uptimeNanoseconds
      return
    }

    let rerankingEnabled = configuration.keyboard.enabled || configuration.settled.enabled
    guard rerankingEnabled else {
      settledRerankReady = false
      settledRerankLoading = false
      return
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let throttle: UInt64 = 500_000_000
    guard forceStatus || now &- lastRerankStatusRefresh >= throttle else { return }
    lastRerankStatusRefresh = now
    let status = decodeRerankStatus(owl_msime_session_rerank_status_json(handle))
    applyRerankStatus(status)
  }

  private func applyRerankStatus(_ status: OwlRustRerankStatusDTO?) {
    guard let status else {
      settledRerankReady = false
      settledRerankLoading = false
      return
    }
    if let keyboard = status.keyboard {
      OwlRerankRuntimeStatusRegistry.shared.update(
        kind: .keyboard,
        state: keyboard.state,
        error: keyboard.error
      )
    }
    if let settled = status.settled {
      OwlRerankRuntimeStatusRegistry.shared.update(
        kind: .settled,
        state: settled.state,
        error: settled.error
      )
      settledRerankReady = settled.enabled == true
        && settled.state == "ready"
        && settled.attached == true
      settledRerankLoading = settled.enabled == true && settled.state == "loading"
    } else {
      settledRerankReady = false
      settledRerankLoading = false
    }
  }

  private func decodeRerankStatus(_ rawPtr: UnsafeMutablePointer<CChar>?) -> OwlRustRerankStatusDTO? {
    guard let rawPtr else { return nil }
    defer { owl_msime_string_free(rawPtr) }
    let data = Data(String(cString: rawPtr).utf8)
    return try? JSONDecoder().decode(OwlRustRerankStatusDTO.self, from: data)
  }

  private func callRerankJSON(
    _ call: (OpaquePointer) -> UnsafeMutablePointer<CChar>?,
    fallback: OwlRustSettledRerankResponseDTO
  ) -> OwlRustSettledRerankResponseDTO {
    guard let handle, let rawPtr = call(handle) else { return fallback }
    defer { owl_msime_string_free(rawPtr) }
    let data = Data(String(cString: rawPtr).utf8)
    return (try? JSONDecoder().decode(OwlRustSettledRerankResponseDTO.self, from: data))
      ?? fallback
  }

  private func refreshSnapshot() {
    guard let ptr = handle,
          let raw = owl_msime_session_snapshot_json(ptr) else { return }
    defer { owl_msime_string_free(raw) }
    let json = String(cString: raw)
    if let data = json.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(OwlRustSnapshotDTO.self, from: data),
       decoded.isOK {
      latestSnapshot = decoded
      latestGeneration = decoded.generation ?? latestGeneration
      caretByteOffset = decoded.caretPosition ?? decoded.rawInput.utf8.count
      preeditCaretByteOffset = decoded.preeditCaretByte ?? decoded.preedit.utf8.count
    }
  }

  private func sendAction(_ payload: [String: Any]) -> OwlRustSnapshotDTO? {
    guard let ptr = handle,
          let reqData = try? JSONSerialization.data(withJSONObject: payload),
          let reqStr = String(data: reqData, encoding: .utf8) else {
      return nil
    }
    let rawPtr = reqStr.withCString { cStr in
      owl_msime_session_handle_action_json(ptr, cStr)
    }
    guard let rawPtr else { return nil }
    defer { owl_msime_string_free(rawPtr) }
    let respStr = String(cString: rawPtr)
    guard let respData = respStr.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(OwlRustSnapshotDTO.self, from: respData)
  }

  private func applyActionResponse(_ dto: OwlRustSnapshotDTO?) -> Bool {
    guard let dto, dto.isOK else { return false }
    let priorRawInput = latestSnapshot?.rawInput
    latestSnapshot = dto
    latestGeneration = dto.generation ?? latestGeneration
    caretByteOffset = dto.caretPosition ?? dto.rawInput.utf8.count
    preeditCaretByteOffset = dto.preeditCaretByte ?? dto.preedit.utf8.count
    if let committed = dto.committedText, !committed.isEmpty {
      if let priorRawInput, !priorRawInput.isEmpty {
        lastCommittedRawInput = priorRawInput
      }
      pendingCommitText = convertToTraditionalIfNeeded(committed, forCandidateDisplay: false)
    }
    return dto.consumed ?? true
  }
}

// MARK: - OwlRustEngine

class OwlRustEngine {
  private var sharedSupportURL: URL?
  private var userDataURL: URL?
  private let activeGenerationProvider: (@Sendable () -> OwlRustResourceGeneration?)?
  private var cachedBundledGeneration: OwlRustResourceGeneration?
  private var selectedSchemaId: String = "rime_ice"
  private var nextSessionID: UInt64 = 1
  private var sessions: [UInt64: OwlRustSession] = [:]
  private var notificationHandler: EngineNotificationHandler?

  init(
    sharedSupportURL: URL? = Bundle.main.sharedSupportURL,
    userDataURL: URL? = OwlApp.userDir,
    activeGenerationProvider: (@Sendable () -> OwlRustResourceGeneration?)? = nil
  ) {
    self.sharedSupportURL = sharedSupportURL
    self.userDataURL = userDataURL
    self.activeGenerationProvider = activeGenerationProvider
  }

  static func makeConfiguredEngine() -> OwlRustEngine {
    return OwlRustEngine()
  }

  func setup(_ traits: OwlEngineTraits) {
    sharedSupportURL = traits.sharedDataDir
    userDataURL = traits.userDataDir
    cachedBundledGeneration = nil
  }

  func startMaintenance(fullCheck: Bool) -> Bool {
    _ = fullCheck
    notifyDeploy(status: "start")
    let succeeded = refreshAllSessionsPreferences(includeHostPhrases: true)
    notifyDeploy(status: succeeded ? "success" : "failure")
    return succeeded
  }

  func joinMaintenance() {}

  func deployConfigFile(_ fileName: String, versionKey: String) -> Bool {
    _ = fileName
    _ = versionKey
    return refreshAllSessionsPreferences(includeHostPhrases: true)
  }

  func setNotificationHandler(_ handler: @escaping EngineNotificationHandler) {
    notificationHandler = handler
  }

  func cleanupAllSessions() {
    let currentSessions = Array(sessions.values)
    sessions.removeAll()
    for session in currentSessions {
      session.destroy()
    }
  }

  func removeSession(id: UInt64) {
    sessions.removeValue(forKey: id)
  }

  func finalize() -> Bool {
    cleanupAllSessions()
    return owl_msime_engine_finalize()
  }

  func schemaList() -> [(id: String, name: String)] {
    OwlRustSchemaMap.supportedSchemas
  }

  func currentSchema() -> String {
    selectedSchemaId
  }

  func selectSchema(_ id: String) -> Bool {
    guard OwlRustSchemaMap.supportedSchemas.contains(where: { $0.id == id }) else {
      return false
    }
    selectedSchemaId = id
    if let name = OwlRustSchemaMap.supportedSchemas.first(where: { $0.id == id })?.name {
      notifySchemaChanged(schemaId: id, schemaName: name)
    }
    return true
  }

  func version() -> String? {
    "msime-rust-0.1"
  }

  func createSession() -> OwlRustSession {
    let id = nextSessionID
    nextSessionID &+= 1
    let userRoot = userDataURL ?? OwlApp.userDir
    let userDir = userRoot.appendingPathComponent("msime-user", isDirectory: true).path
    let cacheDir = userRoot.appendingPathComponent("msime-cache", isDirectory: true).path
    let pageSize = UInt32(OwlKeyboardPreferences.pageSize)
    let generation = resolvedSessionGeneration()

    var creationError: UnsafeMutablePointer<CChar>?
    let handle: OpaquePointer?
    if let generation {
      let auxiliaryResources = generation.resourcesURL
      handle = auxiliaryResources.path.withCString { auxiliaryCStr in
        generation.resourcesURL.path.withCString { resourcesCStr in
          userDir.withCString { userCStr in
            cacheDir.withCString { cacheCStr in
              generation.contentID.withCString { contentIDCStr in
                owl_msime_session_create_with_auxiliary_resources(
                  resourcesCStr,
                  auxiliaryCStr,
                  userCStr,
                  cacheCStr,
                  contentIDCStr,
                  pageSize,
                  &creationError
                )
              }
            }
          }
        }
      }
    } else {
      handle = nil
    }
    if let creationError {
      NSLog("OwlRustEngine: session creation failed: %s", creationError)
      owl_msime_string_free(creationError)
    }
    let session = OwlRustSession(
      sessionID: id,
      handle: handle,
      ownerEngine: self,
      initialSchemaId: selectedSchemaId,
      resourceRoot: generation?.resourcesURL
    )
    sessions[id] = session
    return session
  }

  private func resolvedSessionGeneration() -> OwlRustResourceGeneration? {
    if let activeGenerationProvider {
      if let generation = activeGenerationProvider() {
        return generation
      }
    }

    if let cachedBundledGeneration {
      return cachedBundledGeneration
    }
    guard let sharedRoot = sharedSupportURL ?? Bundle.main.sharedSupportURL else {
      NSLog("OwlRustEngine: shared support directory is unavailable")
      return nil
    }
    let environment = OwlRustResourceEnvironment.production(
      userRoot: userDataURL ?? OwlApp.userDir,
      sharedSupportURL: sharedRoot
    )
    try? environment.store.prepareMutableDirectories()
    let resourcesURL = sharedRoot.appendingPathComponent("msime", isDirectory: true)
    do {
      let digest = try Self.contentDigest(of: resourcesURL)
      let generation = OwlRustResourceGeneration(
        resourcesURL: resourcesURL,
        contentID: "seed-\(digest)"
      )
      cachedBundledGeneration = generation
      return generation
    } catch {
      NSLog("OwlRustEngine: cannot identify bundled resources: %@", error.localizedDescription)
      return nil
    }
  }

  static func contentDigest(of directory: URL) throws -> String {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    ) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let rootPrefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
    var files: [(relativePath: String, url: URL)] = []
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      let relativePath = fileURL.path.hasPrefix(rootPrefix)
        ? String(fileURL.path.dropFirst(rootPrefix.count))
        : fileURL.lastPathComponent
      files.append((relativePath, fileURL))
    }
    guard !files.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }

    var hasher = SHA256()
    let separator = Data([0])
    for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
      hasher.update(data: Data(file.relativePath.utf8))
      hasher.update(data: separator)
      let handle = try FileHandle(forReadingFrom: file.url)
      defer { try? handle.close() }
      while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      hasher.update(data: separator)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func session(for id: UInt64) -> OwlRustSession {
    if let existing = sessions[id] {
      return existing
    }
    return OwlRustSession(
      sessionID: id,
      handle: nil,
      ownerEngine: self,
      initialSchemaId: selectedSchemaId
    )
  }

  fileprivate func recordSelectedSchema(_ id: String) {
    selectedSchemaId = id
  }

  fileprivate func refreshAllSessionsPreferences(includeHostPhrases: Bool) -> Bool {
    var succeeded = true
    for session in sessions.values {
      if !session.syncRuntimePreferences(includeHostPhrases: includeHostPhrases) {
        succeeded = false
      }
    }
    return succeeded
  }

  fileprivate func rerankConfiguration(resourcesURL: URL?) -> OwlRerankConfiguration {
    OwlRerankConfiguration.current(
      sharedSupportURL: sharedSupportURL ?? Bundle.main.sharedSupportURL,
      resourcesURL: resourcesURL
    )
  }

  fileprivate func loadPackedHostPhrases() -> String {
    let userRoot = userDataURL ?? OwlApp.userDir
    var lines: [String] = []
    switch OwlTemplateStore.mode(dataDir: userRoot) {
    case .unified:
      if let library = try? OwlTemplateStore.load(dataDir: userRoot) {
        let projection = OwlTemplateStore.renderCandidateProjection(library)
        if !projection.isEmpty {
          lines.append(projection)
        }
      }
    case .empty:
      break
    case .unavailable:
      return ""
    }
    let userFile = userRoot.appendingPathComponent("custom_phrase.txt")
    if let content = try? String(contentsOf: userFile, encoding: .utf8), !content.isEmpty {
      lines.append(content)
    }
    return lines.joined(separator: "\n")
  }

  fileprivate func notifyOptionChanged(sessionID: UInt64, optionName: String, value: Bool) {
    guard let handler = notificationHandler else { return }
    let payload = value ? optionName : "!\(optionName)"
    handler(sessionID, "option", payload)
  }

  private func notifySchemaChanged(schemaId: String, schemaName: String) {
    guard let handler = notificationHandler else { return }
    let payload = "\(schemaId)/\(schemaName)"
    handler(0, "schema", payload)
  }

  private func notifyDeploy(status: String) {
    guard let handler = notificationHandler else { return }
    handler(0, "deploy", status)
  }
}
