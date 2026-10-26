import InputMethodKit

// Native host contract from pinned MSIME InputController.mm:8031-8135 and
// shared/apple/TextClient.mm:136ff. The engine supplies the opening mark;
// the host keeps the closing mark as a visible marked tail until commit.
extension OwlInputController {
  func trackNativePunctuationKey(_ key: UInt32, modifiers: UInt32) {
    punctuationKeyInFlight = nil
    guard (modifiers & (kControlMask.rawValue | kAltMask.rawValue
      | kSuperMask.rawValue | kReleaseMask.rawValue)) == 0,
      (32..<127).contains(key), let scalar = UnicodeScalar(key),
      let character = String(scalar).first,
      character.isPunctuation || character.isSymbol else { return }
    punctuationKeyInFlight = key
  }

  var usesNativePairedPunctuation: Bool {
    guard let session = rime as? OwlRustSession,
          session.acceptsHostSmartPunctuation,
          !session.option(.asciiMode), !session.option(.asciiPunct),
          client?.bundleIdentifier()?.caseInsensitiveCompare("com.microsoft.Excel") != .orderedSame
    else { return false }
    return OwlKeyboardPreferences.autoPairBrackets
  }

  func commitNativePairedPunctuation(_ text: String, client: IMKTextInput) {
    let pairs = ["（": "）", "【": "】", "《": "》", "“": "”", "‘": "’",
                 "〈": "〉", "「": "」", "『": "』", "〖": "〗"]
    let reopenings = ["”": "“", "’": "‘", "」": "「", "』": "『"]
    var committed = text
    // Only punctuation-key commits may open a pair from a longer commit's tail.
    // A selected candidate merely ending in a bracket is kept verbatim.
    var mark = punctuationKeyInFlight == nil ? text : text.last.map(String.init) ?? ""
    let pending = pendingPairedClosing
    var opened: String?
    if pending == nil {
      let quoteKey = text.count == 1 || [34, 39, 123, 125].contains(punctuationKeyInFlight ?? 0)
      if quoteKey, let opening = reopenings[mark] {
        committed = String(text.dropLast(mark.count)) + opening
        mark = opening
      }
      opened = pairs[mark]
      if opened != nil, mark == "《" || mark == "〈" {
        (rime as? OwlRustSession)?.balanceHostPairedPunctuation()
      }
    }
    pendingPairedClosing = opened
    if let pending { rememberPairedClosing(pending) }
    let inserted = committed + (pending ?? "")
    apply(.insertText(inserted), client: client)
    lastCommittedCharacter = inserted.last
    // rimeUpdate publishes the new marked closing after consuming this commit.
  }

  /// Pinned PairedPunctuationTracker owns at most sixteen closing marks. A host
  /// read must confirm the exact owned neighbor before a skip can replace it.
  func handleNativePairedClosing(_ event: NSEvent) -> Bool? {
    guard usesNativePairedPunctuation, let closing = pairedClosings.last,
          event.type == .keyDown,
          event.modifierFlags.intersection([.control, .option, .command]).isEmpty,
          event.characters == closing, let client,
          rime?.input()?.isEmpty != false else { return nil }
    let policy = clientCapabilityDecisions(for: client)
    let replacementTrusted = policy.replacementRange.reason == .allowedAppKitClient
      || policy.replacementRange.reason == .userForcedAllow
    guard policy.selectedRange.allowed, policy.surroundingText.allowed,
          policy.replacementRange.allowed, replacementTrusted else {
      pairedClosings.removeAll()
      return false
    }
    let selected = client.selectedRange()
    guard selected.location != NSNotFound, selected.length == 0,
          let following = client.attributedSubstring(from:
            NSRange(location: selected.location, length: closing.utf16.count))?.string,
          following == closing else { pairedClosings.removeAll(); return false }
    pairedClosings.removeLast()
    apply(.insertTextInRange(closing,
      replacementRange: NSRange(location: selected.location, length: closing.utf16.count)), client: client)
    return true
  }

  func finishPairBeforeChangingClient(to incoming: IMKTextInput?) {
    guard let incoming, let previous = client, incoming !== previous else { return }
    if pendingPairedClosing != nil {
      (rime as? OwlRustSession)?.finishNativeComposition()
      rimeUpdate()
      flushPendingPairedClosing()
    }
    pairedClosings.removeAll()
  }

  func rememberPairedClosing(_ closing: String) {
    if pairedClosings.count == 16 { pairedClosings.removeFirst() }
    pairedClosings.append(closing)
  }

  func flushPendingPairedClosing() {
    guard let closing = pendingPairedClosing, let client else { return }
    pendingPairedClosing = nil
    rememberPairedClosing(closing)
    apply(.insertText(closing), client: client)
    preedit = ""
  }
}
