import AppKit
import Carbon
import InputMethodKit

/// Document ownership stays in the native host; policy stays in pinned client-core.
final class OwlSmartPunctuation {
  static let postedEventTag: Int64 = 0x4F574C50554E4354
  var repeatSnapshot: Any?
  var spaceSnapshot: Any?
  var revert: (ascii: UInt8, chinese: String, timestamp: UInt64)?
  var shadow: String?
  var generation: UInt64 = 0
  var expectedCaret: Int?
  weak var owner: AnyObject?
  var source: UInt8?
  // Isolated host tests substitute only the native event-posting boundary.
  var postRewrite: ((IMKTextInput, String) -> Bool)?

  func reset() {
    repeatSnapshot = nil; spaceSnapshot = nil; revert = nil; shadow = nil
    source = nil; expectedCaret = nil; owner = nil; generation &+= 1
  }

  func policy(_ request: [String: Any]) -> [String: Any] {
    guard let data = try? JSONSerialization.data(withJSONObject: request),
          let json = String(data: data, encoding: .utf8),
          let result = json.withCString({ owl_msime_smart_punctuation_json($0) }) else { return [:] }
    defer { owl_msime_string_free(result) }
    return (try? JSONSerialization.jsonObject(with: Data(String(cString: result).utf8))) as? [String: Any] ?? [:]
  }

  var timestamp: UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }
}

extension OwlInputController {
  /// Runs before engine punctuation so document context never changes candidate identities.
  func handleSmartPunctuation(_ key: UInt32, modifiers: UInt32) -> Bool {
    guard (modifiers & kReleaseMask.rawValue) == 0 else { return false }
    let state = smartPunctuation
    state.source = nil
    guard let client, let session = engineSession,
          !session.option(.asciiMode), session.acceptsHostSmartPunctuation, pendingPairedClosing == nil,
          (modifiers & (kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue)) == 0,
          key >= 32, key < 127 else { state.reset(); return false }
    let policy = clientCapabilityDecisions(for: client)
    guard policy.selectedRange.allowed, policy.surroundingText.allowed else {
      state.reset(); return false
    }
    let selected = client.selectedRange()
    if state.owner !== client || (state.expectedCaret != nil && state.expectedCaret != selected.location) {
      state.reset()
    }
    state.owner = client
    let composing = !(session.input()?.isEmpty ?? true)
    let candidates = session.composition()?.candidates.count ?? 0
    let character = UInt8(key)
    let text = String(UnicodeScalar(key)!)
    var preceding: String?
    if selected.location != NSNotFound, selected.length == 0, selected.location > 0 {
      preceding = client.attributedSubstring(from: NSRange(location: selected.location - 1, length: 1))?.string
    }
    let documentPreceding = preceding
    if preceding?.isEmpty != false { preceding = state.shadow }
    var context: [String: Any] = [
      "character": character, "preceding": preceding ?? "", "has_composition": composing,
      "candidate_count": candidates, "timestamp_ms": state.timestamp, "editor_generation": state.generation,
      "smart": OwlKeyboardPreferences.smartPunctuation,
      "repeat_enabled": OwlKeyboardPreferences.smartPunctuationRepeat,
      "chinese": !session.option(.asciiPunct)
    ]
    func replace(_ expected: String, _ replacement: String) -> Bool {
      guard !composing, selected.length == 0 else { return false }
      if documentPreceding == expected, selected.location != NSNotFound, selected.location > 0,
         policy.replacementRange.allowed {
        apply(.insertTextInRange(replacement, replacementRange: NSRange(location: selected.location - 1, length: 1)), client: client)
      } else {
        // Same upstream fallback: no readable document, an exact shadow, collapsed/unknown caret.
        guard documentPreceding?.isEmpty != false, state.shadow == expected,
              (selected.location == NSNotFound || selected.location == 0),
              !(selected.location == 0 && (client.attributedSubstring(from: NSRange(location: 0, length: 1))?.length ?? 0) > 0),
              (state.postRewrite?(client, replacement) ?? postSmartPunctuationRewrite(replacement, client: client)) else { return false }
      }
      state.shadow = replacement
      state.expectedCaret = selected.location == NSNotFound ? nil : selected.location
      lastCommittedCharacter = replacement.last
      return true
    }
    let revert = state.revert
    state.revert = nil
    if let revert, revert.ascii == character, OwlKeyboardPreferences.smartPunctuation,
       OwlKeyboardPreferences.smartPunctuationRepeat, !session.option(.fullShape), !composing, candidates == 0,
       state.timestamp >= revert.timestamp, state.timestamp - revert.timestamp <= 2000,
       preceding == text, replace(text, revert.chinese) { return true }
    if let snapshot = state.spaceSnapshot {
      state.spaceSnapshot = nil
      if OwlKeyboardPreferences.smartPunctuation, OwlKeyboardPreferences.smartPunctuationSpace,
         !session.option(.fullShape), (modifiers & kShiftMask.rawValue) == 0 {
        context["op"] = "space"; context["snapshot"] = snapshot
        if let replacement = state.policy(context)["replacement"] as? String,
           let preceding, replace(preceding, replacement) {
          state.revert = (replacement.utf8.first!, preceding, state.timestamp)
          return true
        }
      }
    }
    if let snapshot = state.repeatSnapshot {
      context["op"] = "repeat"; context["snapshot"] = snapshot
      if let replacement = state.policy(context)["replacement"] as? String,
         let preceding, replace(preceding, replacement) {
        state.repeatSnapshot = nil
        return true
      }
    }
    state.repeatSnapshot = nil
    state.source = text.first?.isPunctuation == true || text.first?.isSymbol == true ? character : nil
    guard character == 44 || character == 46 || character == 58 else {
      state.spaceSnapshot = nil
      if !composing { state.shadow = nil }
      return false
    }
    // The macOS oracle also considers an English/numeric highlighted candidate's tail.
    if composing, let composition = session.composition(),
       composition.candidates.indices.contains(composition.highlightedIndex),
       let tail = composition.candidates[composition.highlightedIndex].text.last,
       tail.isASCII, tail.isLetter || tail.isNumber {
      context["preceding"] = String(tail)
      context["has_composition"] = false
    }
    context["op"] = "route"
    context["available"] = preceding?.isEmpty == false || composing
    guard state.policy(context)["ascii"] as? Bool == true else { return false }
    if composing {
      let handled = session.processHostASCIIPunctuation(text)
      if handled, session.option(.fullShape), let committed = session.takeCommit() {
        let output = committed.hasSuffix(text)
          ? String(committed.dropLast()) + String(UnicodeScalar(key + 0xFEE0)!) : committed
        commit(string: output)
      }
      return handled
    }
    let literal = session.option(.fullShape) ? String(UnicodeScalar(key + 0xFEE0)!) : text
    commit(string: literal)
    return true
  }

  func noteSmartPunctuationCommit(_ committed: String) {
    let state = smartPunctuation
    state.shadow = committed.last.map(String.init)
    guard let client else { state.reset(); return }
    state.owner = client
    let policy = clientCapabilityDecisions(for: client)
    let selected = policy.selectedRange.allowed ? client.selectedRange() : NSRange(location: NSNotFound, length: 0)
    state.expectedCaret = selected.location == NSNotFound ? nil : selected.location
    guard let source = state.source else {
      state.repeatSnapshot = nil; state.spaceSnapshot = nil; return
    }
    let armed = state.policy([
      "op": "arm", "character": source, "commit": committed,
      "timestamp_ms": state.timestamp, "editor_generation": state.generation,
      "smart": OwlKeyboardPreferences.smartPunctuation,
      "repeat_enabled": OwlKeyboardPreferences.smartPunctuationRepeat,
      "space_enabled": OwlKeyboardPreferences.smartPunctuationSpace,
      "chinese": !(engineSession?.option(.asciiPunct) ?? false),
      "auto_closed_pair": OwlKeyboardPreferences.autoPairBrackets && committed.count == 1 && committed.first.map { OwlAutoPair.pairs[$0] != nil } == true
    ])
    state.repeatSnapshot = armed["repeat"] is NSNull ? nil : armed["repeat"]
    state.spaceSnapshot = armed["space"] is NSNull ? nil : armed["space"]
  }

  func postSmartPunctuationRewrite(_ replacement: String, client: IMKTextInput) -> Bool {
    guard CGPreflightPostEventAccess(), let scalar = replacement.utf16.first,
          let bundle = client.bundleIdentifier(), !bundle.isEmpty,
          let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundle,
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
    var events: [CGEvent] = []
    for unicode in [false, true] {
      for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: unicode ? 0 : 51, keyDown: down) else { return false }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: OwlSmartPunctuation.postedEventTag)
        if unicode { var unit = scalar; event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit) }
        events.append(event)
      }
    }
    guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          ProcessInfo.processInfo.systemUptime <= deadline else { return false }
    for event in events { event.postToPid(app.processIdentifier) }
    return true
  }
}
