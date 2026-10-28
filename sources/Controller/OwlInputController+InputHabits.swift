import InputMethodKit

extension OwlInputController {
  func rememberAppInputMode() {
    guard client != nil, let engineSession, engineSession.isValid else { return }
    let ascii = engineSession.option(.asciiMode)
    if appModeObservation.changed(to: ascii) {
      OwlAppInputMemory.shared.remember(app: currentApp, ascii: ascii)
    }
  }

  func syncPinnedWords() {
    guard let engineSession, engineSession.isValid else { return }
    let pins = OwlPinnedWords.shared
    guard pinnedWordsRevision != pins.revision else { return }
    engineSession.setProperty(name: OwlPinnedWords.property, value: pins.engineValue)
    pinnedWordsRevision = pins.revision
  }

  func pinnedTarget(text: String) -> OwlPinnedWord? {
    guard let engineSession, engineSession.isValid,
          !engineSession.option(.asciiMode), let composition = engineSession.composition() else { return nil }
    return OwlPinnedWords.target(schema: schemaId, input: engineSession.input() ?? "", composition: composition,
      candidate: text, traditional: currentTraditionalOutputEnabled(), caret: engineSession.caretPos())
  }

  /// Pinned macOS MSIME reserves Ctrl-Option-Shift + physical number row 1...8.
  func handleCandidateDeletionHotKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]
    guard flags == [.control, .option, .shift],
          let index = codes.firstIndex(of: event.keyCode),
          let engineSession, let composition = engineSession.composition(),
          !composition.candidates.isEmpty else { return false }
    if !event.isARepeat, composition.candidates.indices.contains(index) {
      _ = removeCandidate(OwlCandidateToken(sessionID: engineSession.sessionID,
        generation: engineSession.generation, candidateID: index))
    }
    return true
  }

  @discardableResult
  func removeCandidate(_ token: OwlCandidateToken) -> Bool {
    guard let engineSession else { return false }
    invalidateSettledRerankForAction()
    let removed = engineSession.removeCandidate(token)
    if removed { engineUpdate() }
    return removed
  }

  func handlePinHotKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    guard flags.rawValue.nonzeroBitCount >= 2, !OwlHotKeyEventTap.isSuppressed,
          let combo = OwlHotKeySlot.pinCandidate.current?.carbonCombo,
          OwlHotKeyMatcher.matches(combo, keyCode: event.keyCode, flags: event.modifierFlags),
          let composition = engineSession?.composition(),
          composition.candidates.indices.contains(composition.highlightedIndex) else { return false }
    let text = composition.candidates[composition.highlightedIndex].text
    guard pinnedTarget(text: text) != nil else { return false }
    togglePinnedWord(text: text)
    return true
  }

  func togglePinnedWord(text: String) {
    guard let target = pinnedTarget(text: text), let engineSession else { return }
    let pinned = OwlPinnedWords.shared.toggle(target)
    syncPinnedWords()
    // Eligibility requires a wholly unconfirmed ASCII pinyin composition, caret at the end.
    // Replaying just those letters refreshes the engine's authoritative menu, including number keys.
    engineSession.clearComposition()
    for byte in target.code.utf8 { _ = engineSession.process(keycode: UInt32(byte), modifiers: 0) }
    engineUpdate()
    NSApp.owlAppDelegate.showStatusMessage(msgTextLong: pinned ? "已置顶「\(text)」" : "已取消置顶「\(text)」",
      msgTextShort: pinned ? "置顶" : "取消置顶")
  }
}
