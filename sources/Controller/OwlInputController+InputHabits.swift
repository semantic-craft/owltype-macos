import InputMethodKit

extension OwlInputController {
  func rememberAppInputMode() {
    guard client != nil, let rime, rime.isValid else { return }
    let ascii = rime.option(.asciiMode)
    if appModeObservation.changed(to: ascii) {
      OwlAppInputMemory.shared.remember(app: currentApp, ascii: ascii)
    }
  }

  func syncPinnedWords() {
    guard let rime, rime.isValid else { return }
    let pins = OwlPinnedWords.shared
    guard pinnedWordsRevision != pins.revision else { return }
    rime.setProperty(name: OwlPinnedWords.property, value: pins.engineValue)
    pinnedWordsRevision = pins.revision
  }

  func pinnedTarget(text: String) -> OwlPinnedWord? {
    guard OwlPinyinCandidateDeployment.available, let rime, rime.isValid,
          !rime.option(.asciiMode), let composition = rime.composition() else { return nil }
    return OwlPinnedWords.target(schema: schemaId, input: rime.input() ?? "", composition: composition,
      candidate: text, traditional: currentTraditionalOutputEnabled(), caret: rime.caretPos())
  }

  func handlePinHotKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    guard flags.rawValue.nonzeroBitCount >= 2, !OwlHotKeyEventTap.isSuppressed,
          let combo = OwlHotKeySlot.pinCandidate.current?.carbonCombo,
          OwlHotKeyMatcher.matches(combo, keyCode: event.keyCode, flags: event.modifierFlags),
          let composition = rime?.composition(),
          composition.candidates.indices.contains(composition.highlightedIndex) else { return false }
    let text = composition.candidates[composition.highlightedIndex].text
    guard pinnedTarget(text: text) != nil else { return false }
    togglePinnedWord(text: text)
    return true
  }

  func togglePinnedWord(text: String) {
    guard let target = pinnedTarget(text: text), let rime else { return }
    let pinned = OwlPinnedWords.shared.toggle(target)
    syncPinnedWords()
    // Eligibility requires a wholly unconfirmed ASCII pinyin composition, caret at the end.
    // Replaying just those letters refreshes Rime's authoritative menu, including number keys.
    rime.clearComposition()
    for byte in target.code.utf8 { _ = rime.process(keycode: UInt32(byte), modifiers: 0) }
    rimeUpdate()
    NSApp.owlAppDelegate.showStatusMessage(msgTextLong: pinned ? "已置顶「\(text)」" : "已取消置顶「\(text)」",
      msgTextShort: pinned ? "置顶" : "取消置顶")
  }
}
