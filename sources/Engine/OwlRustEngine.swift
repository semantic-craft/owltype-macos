//
//  OwlRustEngine.swift
//  Owltype
//
//  Swift adapter conforming to `RimeEngine` / `RimeSession` on top of the Metasequoia
//  (`msime`) Rust engine via the narrow C-ABI (`owl_msime_ffi.h`, issue #249).
//

import CryptoKit
import Foundation

// MARK: - Schema Mapping

private struct OwlRustShuangpinTable {
  let initials: [String: String]
  let finals: [String: String]
  let zeroInitials: [String: String]

  var actionPayload: [String: Any] {
    [
      "initials": initials.sorted { $0.key < $1.key }.map { [$0.key, $0.value] },
      "finals": finals.sorted { $0.key < $1.key }.map { [$0.key, $0.value] },
      "zero_initials": zeroInitials.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
    ]
  }
}

enum OwlRustSchemaMap {
  static func initialASCIIMode(
    forApp bundleID: String,
    englishBundleIDs: [String],
    defaultASCIIMode: Bool
  ) -> Bool {
    englishBundleIDs.contains(bundleID) ? true : defaultASCIIMode
  }

  static func inputMode(forSchema schemaId: String) -> String {
    if schemaId.hasPrefix("wubi") {
      return "wubi"
    }
    return "chinese"
  }

  static func doublePinyinScheme(forSchema schemaId: String) -> String {
    switch schemaId {
    case "double_pinyin_flypy": return "xiaohe"
    case "double_pinyin_mspy": return "microsoft"
    case "double_pinyin_shoudao": return "shoudao"
    case "double_pinyin": return "ziranma"
    case "double_pinyin_abc": return "abc"
    case "double_pinyin_sogou", "double_pinyin_ziguang", "double_pinyin_jiajia":
      return "custom"
    default: return "quanpin"
    }
  }

  fileprivate static func customShuangpinTable(forSchema schemaId: String) -> OwlRustShuangpinTable? {
    switch schemaId {
    case "double_pinyin_sogou":
      return OwlRustShuangpinTable(
        initials: ["zh": "v", "ch": "i", "sh": "u"],
        finals: [
          "a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "y",
          "ai": "l", "ei": "z", "ui": "v", "ao": "k", "ou": "b", "iu": "q",
          "ie": "x", "ve": "t", "ue": "t", "an": "j", "en": "f", "in": "n",
          "un": "p", "ang": "h", "eng": "g", "ing": ";", "ong": "s",
          "ia": "w", "ua": "w", "uo": "o", "uai": "y", "ian": "m",
          "uan": "r", "iao": "c", "iang": "d", "uang": "d", "iong": "s"
        ],
        zeroInitials: [
          "a": "oa", "ai": "ol", "an": "oj", "ang": "oh", "ao": "ok",
          "e": "oe", "ei": "oz", "en": "of", "eng": "og", "er": "or",
          "o": "oo", "ou": "ob"
        ]
      )
    case "double_pinyin_ziguang":
      return OwlRustShuangpinTable(
        initials: ["zh": "u", "ch": "a", "sh": "i"],
        finals: [
          "a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "v",
          "ai": "p", "ei": "k", "ui": "n", "ao": "q", "ou": "z", "iu": "j",
          "ie": "d", "ve": "n", "ue": "n", "an": "r", "en": "w", "in": "y",
          "un": "m", "ang": "s", "eng": "t", "ing": ";", "ong": "h",
          "ia": "x", "ua": "x", "uo": "o", "uai": "y", "ian": "f",
          "uan": "l", "iao": "b", "iang": "g", "uang": "g", "iong": "h"
        ],
        zeroInitials: [
          "a": "oa", "ai": "op", "an": "or", "ang": "os", "ao": "oq",
          "e": "oe", "ei": "ok", "en": "ow", "eng": "ot", "er": "oj",
          "o": "oo", "ou": "oz"
        ]
      )
    case "double_pinyin_jiajia":
      return OwlRustShuangpinTable(
        initials: ["zh": "v", "ch": "u", "sh": "i"],
        finals: [
          "a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "v",
          "ai": "s", "ei": "w", "ui": "v", "ao": "d", "ou": "p", "iu": "n",
          "ie": "m", "ve": "x", "ue": "x", "an": "f", "en": "r", "in": "l",
          "un": "z", "ang": "g", "eng": "t", "ing": "q", "ong": "y",
          "ia": "b", "ua": "b", "uo": "o", "uai": "x", "ian": "j",
          "uan": "c", "iao": "k", "iang": "h", "uang": "h", "iong": "y"
        ],
        zeroInitials: [
          "a": "aa", "ai": "as", "an": "af", "ang": "ag", "ao": "ad",
          "e": "ee", "ei": "ew", "en": "er", "eng": "et", "er": "eq",
          "o": "oo", "ou": "op"
        ]
      )
    default:
      return nil
    }
  }

  static func pinyinScheme(forSchema schemaId: String) -> String {
    switch schemaId {
    case "wubi86_jidian_pinyin", "wubi86_jidian_trad_pinyin":
      return "wubi_pinyin"
    case "wubi86_jidian", "wubi86_jidian_trad":
      return "wubi"
    default:
      return doublePinyinScheme(forSchema: schemaId)
    }
  }

  static func isTraditionalSchema(_ schemaId: String) -> Bool {
    schemaId == "wubi86_jidian_trad" || schemaId == "wubi86_jidian_trad_pinyin"
  }

  static func fuzzyBitmask(from snapshot: OwlFuzzySnapshot) -> UInt32 {
    var mask: UInt32 = 0
    if snapshot.zhz { mask |= (1 << 0) }
    if snapshot.chc { mask |= (1 << 1) }
    if snapshot.shs { mask |= (1 << 2) }
    if snapshot.nl { mask |= (1 << 3) }
    if snapshot.fh { mask |= (1 << 4) }
    if snapshot.rl { mask |= (1 << 5) }
    if snapshot.anang { mask |= (1 << 6) }
    if snapshot.eneng { mask |= (1 << 7) }
    if snapshot.ining { mask |= (1 << 8) }
    return mask
  }

  static let supportedSchemas: [(id: String, name: String)] = [
    (id: "rime_ice", name: "雾凇拼音"),
    (id: "double_pinyin_flypy", name: "小鹤双拼"),
    (id: "double_pinyin_mspy", name: "微软双拼"),
    (id: "double_pinyin_shoudao", name: "手心双拼"),
    (id: "double_pinyin", name: "自然码双拼"),
    (id: "double_pinyin_sogou", name: "搜狗双拼"),
    (id: "double_pinyin_abc", name: "智能ABC双拼"),
    (id: "double_pinyin_ziguang", name: "紫光双拼"),
    (id: "double_pinyin_jiajia", name: "拼音加加双拼"),
    (id: "wubi86_jidian", name: "极点五笔86"),
    (id: "wubi86_jidian_pinyin", name: "五笔拼音混输"),
    (id: "wubi86_jidian_trad", name: "五笔简入繁出"),
    (id: "wubi86_jidian_trad_pinyin", name: "五笔拼音混输·简入繁出")
  ]
}

// MARK: - OwlRustSession

final class OwlRustSession: RimeSession {
  private static let localModeEntryLetters = Set("UTKEMJYRVCS")
  let sessionID: UInt64
  private var handle: OpaquePointer?
  private weak var ownerEngine: OwlRustEngine?
  private var activeSchemaId: String
  private var pendingCommitText: String?
  private var lastCommittedRawInput: String?
  private var latestSnapshot: OwlRustSnapshotDTO?
  private var latestGeneration: UInt64 = 0
  private var caretByteOffset: Int = 0
  private var preeditCaretByteOffset: Int = 0
  private var customCaretPos: Int?
  private var lastAppliedPageSize: Int = 0
  private var lastAppliedASCIIPunct: Bool?
  private var lastAppliedFuzzyMask: UInt32 = 0
  private var lastAppliedWubiCandidateMode: String = ""
  private var lastAppliedWubiCodeHint: Bool?
  private var lastAppliedWubiAutoClear: Bool?
  private var lastAppliedWubiZReverseLookup: Bool?
  private var lastAppliedWubiEnglishChannel: Bool?
  private var lastAppliedWubiUserDictLearning: Bool?
  private var lastAppliedHostPhrases: String = ""
  private var lastAppliedRerankConfiguration: String?
  private var lastRerankStatusRefresh: UInt64 = 0
  private(set) var rerankConfigurationEpoch: UInt64 = 0
  private(set) var settledRerankReady = false
  private(set) var settledRerankLoading = false
  private var optionFlags: [RimeOption: Bool] = [
    .simplification: true,
    .linear: true
  ]
  private var appOptionFlags: [String: Bool] = [:]
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
    if text.hasPrefix(OwlPromptStore.candidateMarker) {
      return text
    }
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
    handle: OpaquePointer?,
    ownerEngine: OwlRustEngine,
    initialSchemaId: String
  ) {
    self.sessionID = sessionID
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

    let disallowedModifiers = kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue
    if (modifiers & disallowedModifiers) != 0 {
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

  func status() -> RimeStatus? {
    guard handle != nil else { return nil }
    return RimeStatus(
      schemaId: activeSchemaId,
      isASCIIMode: optionFlags[.asciiMode] ?? false,
      isASCIIPunct: optionFlags[.asciiPunct] ?? false,
      isFullShape: optionFlags[.fullShape] ?? false
    )
  }

  func composition() -> RimeComposition? {
    guard handle != nil else { return nil }
    if latestSnapshot == nil {
      refreshSnapshot()
    }
    // Like librime's valid empty context, a cleared snapshot must reach the renderer:
    // nil only hides the panel and leaves the host's previous marked text in place.
    guard let snap = latestSnapshot else {
      return nil
    }
    let preedit = snap.preedit.isEmpty ? snap.rawInput : snap.preedit
    let utf8Count = preedit.utf8.count
    let candidates = snap.candidates.map {
      RimeCandidate(
        text: convertToTraditionalIfNeeded($0.text, forCandidateDisplay: true),
        comment: $0.comment
      )
    }
    let pageSize = max(1, snap.pageSize)
    let labels = (1...pageSize).map { "\($0)" }
    let highlighted = min(max(0, snap.highlightedIndex), max(0, candidates.count - 1))
    let preview = candidates.indices.contains(highlighted) ? candidates[highlighted].text : preedit
    let effectiveCaret = min(max(0, customCaretPos ?? preeditCaretByteOffset), utf8Count)

    return RimeComposition(
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
      highlightedIndex: highlighted,
      numCandidates: candidates.count
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
    customCaretPos ?? caretByteOffset
  }

  func setCaretPos(_ pos: Int) {
    let clamped = max(0, pos)
    caretByteOffset = clamped
    customCaretPos = clamped
    if handle != nil, let dto = sendAction(["op": "set_caret", "pos": clamped]), dto.isOK {
      latestSnapshot = dto
      latestGeneration = dto.generation ?? latestGeneration
      caretByteOffset = dto.caretPosition ?? clamped
      preeditCaretByteOffset = dto.preeditCaretByte ?? dto.preedit.utf8.count
      customCaretPos = nil
    }
  }

  func clearComposition() {
    guard handle != nil else { return }
    customCaretPos = nil
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

  func peekCandidates(from index: Int, count: Int) -> [RimeCandidate] {
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
      RimeCandidate(
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
    let pageSize = max(3, min(9, OwlKeyboardPreferences.pageSize))
    guard sendAction(["op": "set_input_mode", "mode": mode])?.isOK == true else {
      return false
    }
    var schemeAction: [String: Any] = ["op": "set_pinyin_scheme", "scheme": scheme]
    if scheme == "custom" {
      guard let table = OwlRustSchemaMap.customShuangpinTable(forSchema: id) else {
        return false
      }
      schemeAction["custom_profile"] = table.actionPayload
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
    let pageSize = max(3, min(9, OwlKeyboardPreferences.pageSize))
    let fuzzyMask = OwlRustSchemaMap.fuzzyBitmask(from: OwlFuzzySnapshot.current())
    let candMode = OwlKeyboardPreferences.wubiCandidateMode.rawValue
    let booleanOptions: [(String, Bool?, ReferenceWritableKeyPath<OwlRustSession, Bool?>)] = [
      ("wubi_code_hint", OwlKeyboardPreferences.wubiCodeHint, \.lastAppliedWubiCodeHint),
      ("wubi_auto_clear", OwlKeyboardPreferences.wubiAutoClear, \.lastAppliedWubiAutoClear),
      ("wubi_z_reverse_lookup",
       OwlKeyboardPreferences.wubiZReverseLookup, \.lastAppliedWubiZReverseLookup),
      ("wubi_english_channel",
       OwlKeyboardPreferences.wubiEnglishChannel, \.lastAppliedWubiEnglishChannel),
      ("wubi_user_dict_learning",
       OwlKeyboardPreferences.wubiUserDictLearning, \.lastAppliedWubiUserDictLearning)
    ]
    guard
      applyChanged(pageSize, at: \.lastAppliedPageSize,
                   action: { ["op": "set_page_size", "page_size": pageSize] }),
      applyChanged(fuzzyMask, at: \.lastAppliedFuzzyMask,
                   action: { ["op": "set_fuzzy_rules", "mask": fuzzyMask] }),
      applyChanged(candMode, at: \.lastAppliedWubiCandidateMode,
                   action: { ["op": "set_wubi_candidate_mode", "mode": candMode] })
    else { return false }
    guard
      (booleanOptions.allSatisfy { option in
        applyChanged(option.1, at: option.2) {
          ["op": "set_option", "name": option.0, "value": option.1 as Any]
        }
      }),
      applyASCIIPunctIfNeeded()
    else { return false }
    guard includeHostPhrases, let ownerEngine else { return true }
    let packed = ownerEngine.loadPackedHostPhrases()
    return applyChanged(packed, at: \.lastAppliedHostPhrases) {
      ["op": "set_host_phrases", "text": packed]
    }
  }

  private func applyASCIIPunctIfNeeded() -> Bool {
    let value = OwlKeyboardPreferences.cjkPunctToggle
    guard applyChanged(value, at: \.lastAppliedASCIIPunct, action: {
      ["op": "set_option", "name": RimeOption.asciiPunct.rawValue, "value": value]
    }) else { return false }
    optionFlags[.asciiPunct] = value
    return true
  }

  private func applyChanged<Value: Equatable>(
    _ value: Value,
    at keyPath: ReferenceWritableKeyPath<OwlRustSession, Value>,
    action: () -> [String: Any]
  ) -> Bool {
    guard value != self[keyPath: keyPath] else { return true }
    guard sendAction(action())?.isOK == true else { return false }
    self[keyPath: keyPath] = value
    return true
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

  func option(_ option: RimeOption) -> Bool {
    optionFlags[option] ?? false
  }

  func setOption(_ option: RimeOption, _ value: Bool) {
    let previous = optionFlags[option]
    optionFlags[option] = value
    _ = sendAction(["op": "set_option", "name": option.rawValue, "value": value])
    if previous != value {
      ownerEngine?.notifyOptionChanged(sessionID: sessionID, optionName: option.rawValue, value: value)
    }
  }

  func setAppOption(_ key: String, _ value: Bool) {
    appOptionFlags[key] = value
    if let opt = RimeOption(rawValue: key) {
      setOption(opt, value)
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
    case RimeOption.asciiMode.rawValue:
      return state ? "英" : "中"
    case RimeOption.asciiPunct.rawValue:
      return state ? ".，" : "。，"
    case RimeOption.fullShape.rawValue:
      return state ? "全" : "半"
    case RimeOption.traditional.rawValue,
         RimeOption.traditionalization.rawValue,
         RimeOption.zhTrad.rawValue,
         RimeOption.transcription.rawValue:
      return state ? "繁" : "简"
    case RimeOption.emojiSuggestion.rawValue:
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
    let configuration = ownerEngine.rerankConfiguration()
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
    customCaretPos = nil
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

final class OwlRustEngine: RimeEngine {
  private var sharedSupportURL: URL?
  private var userDataURL: URL?
  private let activeGenerationProvider: (@Sendable () -> OwlRustResourceGeneration?)?
  private var cachedBundledGeneration: OwlRustResourceGeneration?
  private var selectedSchemaId: String = "rime_ice"
  private var nextSessionID: UInt64 = 1
  private var sessions: [UInt64: OwlRustSession] = [:]
  private var notificationHandler: RimeNotificationHandler?

  init(
    sharedSupportURL: URL? = Bundle.main.sharedSupportURL,
    userDataURL: URL? = OwlApp.userDir,
    activeGenerationProvider: (@Sendable () -> OwlRustResourceGeneration?)? = nil
  ) {
    self.sharedSupportURL = sharedSupportURL
    self.userDataURL = userDataURL
    self.activeGenerationProvider = activeGenerationProvider
  }

  static func makeConfiguredEngine() -> RimeEngine {
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

  func setNotificationHandler(_ handler: @escaping RimeNotificationHandler) {
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

  func createSession() -> RimeSession {
    let id = nextSessionID
    nextSessionID &+= 1
    let userRoot = userDataURL ?? OwlApp.userDir
    let userDir = userRoot.appendingPathComponent("msime-user", isDirectory: true).path
    let cacheDir = userRoot.appendingPathComponent("msime-cache", isDirectory: true).path
    let pageSize = UInt32(max(3, min(9, OwlKeyboardPreferences.pageSize)))
    let generation = resolvedSessionGeneration()

    var creationError: UnsafeMutablePointer<CChar>?
    let handle: OpaquePointer?
    if let generation, let sharedRoot = sharedSupportURL ?? Bundle.main.sharedSupportURL {
      let auxiliaryResources = sharedRoot.appendingPathComponent("msime", isDirectory: true)
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
      initialSchemaId: selectedSchemaId
    )
    sessions[id] = session
    return session
  }

  private func resolvedSessionGeneration() -> OwlRustResourceGeneration? {
    if let activeGenerationProvider {
      if let generation = activeGenerationProvider() {
        return generation
      }
    } else {
      let environment = OwlRustResourceEnvironment.production(
        userRoot: userDataURL ?? OwlApp.userDir
      )
      do {
        if let generation = try environment.activeGeneration() {
          return generation
        }
      } catch {
        NSLog(
          "OwlRustEngine: active resource generation is unusable: %@",
          error.localizedDescription
        )
      }
    }

    if let cachedBundledGeneration {
      return cachedBundledGeneration
    }
    guard let sharedRoot = sharedSupportURL ?? Bundle.main.sharedSupportURL else {
      NSLog("OwlRustEngine: shared support directory is unavailable")
      return nil
    }
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

  func session(for id: UInt64) -> RimeSession {
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

  fileprivate func rerankConfiguration() -> OwlRerankConfiguration {
    OwlRerankConfiguration.current(
      sharedSupportURL: sharedSupportURL ?? Bundle.main.sharedSupportURL
    )
  }

  fileprivate func loadPackedHostPhrases() -> String {
    let userRoot = userDataURL ?? OwlApp.userDir
    let sharedRoot = sharedSupportURL ?? Bundle.main.sharedSupportURL
    let fileNames: [String]
    switch OwlTemplateStore.mode(rimeDir: userRoot) {
    case .unified:
      fileNames = [OwlTemplateStore.dictFileName, "custom_phrase.txt"]
    case .legacy:
      fileNames = [
        OwlPromptStore.dictFileName,
        OwlQuickSendStore.dictFileName,
        "custom_phrase.txt"
      ]
    case .empty:
      fileNames = ["custom_phrase.txt"]
    case .unavailable:
      return ""
    }
    var lines: [String] = []
    for name in fileNames {
      let userFile = userRoot.appendingPathComponent(name)
      if let content = try? String(contentsOf: userFile, encoding: .utf8), !content.isEmpty {
        lines.append(content)
        continue
      }
      if name == "custom_phrase.txt",
         let sharedFile = sharedRoot?.appendingPathComponent(name),
         let content = try? String(contentsOf: sharedFile, encoding: .utf8),
         !content.isEmpty {
        lines.append(content)
      }
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
