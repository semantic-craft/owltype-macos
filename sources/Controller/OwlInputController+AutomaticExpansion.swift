import InputMethodKit
import Carbon

/// A proof about this controller's current marked text, never a license to delete document text.
final class OwlAutomaticExpansionTarget {
  weak var client: IMKTextInput?
  let start: Int
  let sessionID: UInt64
  let asciiMode: Bool
  let revision: UInt64
  let replayKeycode: UInt32
  let replayModifiers: UInt32
  var markedText = ""

  init(client: IMKTextInput, start: Int, sessionID: UInt64, asciiMode: Bool, revision: UInt64, replayKeycode: UInt32, replayModifiers: UInt32) {
    self.client = client
    self.start = start
    self.sessionID = sessionID
    self.asciiMode = asciiMode
    self.revision = revision
    self.replayKeycode = replayKeycode
    self.replayModifiers = replayModifiers
  }
}

extension OwlInputController {
  /// Called before the existing hotkeys. An interrupt restores our prefix but still passes the
  /// actual key through to those hotkeys/Rime. No global event tap or synthetic host events.
  func handleAutomaticExpansion(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    let runtime = OwlAutomaticExpansionRuntime.shared
    let input = OwlAutomaticExpansionEventInput.classify(OwlKeyEvent(event: event, lastModifiers: []))

    if automaticRecognizer.isRecognizing {
      guard let target = automaticTarget, let targetClient = target.client,
            let client, targetClient === client,
            target.sessionID == engineSession?.sessionID,
            target.revision == runtime.revision,
            target.asciiMode == engineSession?.option(.asciiMode),
            runtime.allows(bundleID: client.bundleIdentifier()),
            (engineSession?.input() ?? "").isEmpty else {
        finishAutomaticExpansion(replaySemicolon: false)
        return false
      }
      guard automaticOwns(target) else {
        discardAutomaticExpansion()
        return false // No ownership: never restore into a possibly different field/selection.
      }
    } else {
      return OwlAutomaticExpansionControllerEntry.start(input: input, bundleID: client?.bundleIdentifier(),
        runtime: runtime, engineSession: engineSession) {
        guard let client, let engineSession, preedit.isEmpty, automaticReadsAllowed(client) else { return false }
        let epoch = automaticEpoch
        let sessionID = engineSession.sessionID
        let selection = client.selectedRange()
        guard OwlAutomaticExpansionScope.valid(selection), selection.length == 0 else { return false }
        let marked = client.markedRange()
        let preceding = selection.location > 0
          ? client.attributedSubstring(from: NSRange(location: selection.location - 1, length: 1))?.string : nil
        guard OwlAutomaticExpansionScope.canStart(selection: selection, marked: marked, preceding: preceding) else { return false }
        guard case let .keyDown(replayKeycode, replayModifiers) = OwlUserActionClassifier.classify(
          OwlKeyEvent(event: event, lastModifiers: [])) else { return false }
        guard epoch == automaticEpoch, self.client === client, self.engineSession?.sessionID == sessionID else { return false }
        automaticTarget = OwlAutomaticExpansionTarget(client: client, start: selection.location,
          sessionID: sessionID, asciiMode: engineSession.option(.asciiMode), revision: runtime.revision,
          replayKeycode: replayKeycode, replayModifiers: replayModifiers)
        return applyAutomaticExpansion(automaticRecognizer.consume(input, index: runtime.index, canStart: true))
      }
    }

    let step = automaticRecognizer.consume(input, index: runtime.index, canStart: true)
    return applyAutomaticExpansion(step)
  }

  /// Returns whether the ORIGINAL key was consumed. Terminal state is cleared before side effects.
  private func applyAutomaticExpansion(_ step: OwlAutomaticExpansionRecognizer.Step) -> Bool {
    guard let target = automaticTarget, let client = target.client else {
      discardAutomaticExpansion()
      return false
    }
    switch step {
    case .passThrough: return false
    case .mark(let text):
      let previousText = target.markedText
      let epoch = automaticEpoch
      let before = automaticObservation(target, length: text.utf16.count)
      target.markedText = text
      let outcome = OwlAutomaticExpansionMarkDelivery.perform(before: before, write: {
        withAutomaticClientAction {
          show(preedit: text, selRange: NSRange(location: 0, length: text.utf16.count), caretPos: text.utf16.count)
        }
      }, isCurrent: { automaticTarget === target && automaticEpoch == epoch },
         owns: { automaticOwns(target) }, readAfter: { automaticObservation(target, length: text.utf16.count) })
      switch outcome {
      case .accepted, .sessionEnded: return true
      case .rejectedWithoutChange:
        // The failed key was not inserted. Preserve the prior owned prefix, then pass this key
        // through exactly once. On the first semicolon there is no prior text to restore.
        target.markedText = previousText
        discardAutomaticExpansion()
        if !previousText.isEmpty {
          restoreAutomaticText(previousText, target: target, replaySemicolon: previousText == ";")
        }
        return false
      case .uncertain:
        discardAutomaticExpansion()
        return true // Never repeat a write whose result the host cannot establish.
      }
    case .clear:
      discardAutomaticExpansion()
      withAutomaticClientAction { apply(.insertText(""), client: client) }
      return true
    case .restore(let text, let replaySemicolon, let consumeKey):
      discardAutomaticExpansion()
      restoreAutomaticText(text, target: target, replaySemicolon: replaySemicolon)
      return consumeKey
    case .invoke:
      // Capture the complete typed source and the smaller range actually marked before taking
      // the recognizer out of play. Shared delivery rechecks that range before any mutation.
      guard automaticOwns(target),
            let source = OwlAutomaticExpansionInvocationSource(step: step, start: target.start, markedText: target.markedText) else {
        discardAutomaticExpansion()
        return false
      }
      let runtime = OwlAutomaticExpansionRuntime.shared
      let sessionID = target.sessionID
      let asciiMode = target.asciiMode
      let revision = target.revision
      let sourceSchema = schemaId
      let bundleID = client.bundleIdentifier()
      // This proof must survive discard and the expected parameter-window transition. Do not
      // bind it to automaticTarget/automaticEpoch, which belong to recognition, not invocation.
      let validity = OwlAutomaticExpansionInvocationValidity { [weak self] in
        guard let self, let engineSession = self.engineSession, engineSession.isValid else { return false }
        return engineSession.sessionID == sessionID && engineSession.option(.asciiMode) == asciiMode
          && self.schemaId == sourceSchema && runtime.revision == revision
          && runtime.allows(bundleID: bundleID)
      }
      let automaticSource = OwlTemplateHostDelivery.AutomaticSource(originalInput: source.originalInput,
        markedRange: source.markedRange, markedText: source.markedText, isValid: { validity.isValid() })
      discardAutomaticExpansion()
      withAutomaticClientAction {
        invokeTemplate(.template(source.entry), broker: OwlPanelInsertionBroker(), capturedClient: client,
          trailingText: source.trailingText, automaticSource: automaticSource)
      }
      // Shared Invocation owns capture, optional original preservation, cancellation and one
      // result dispatch. Neither the final character nor a delimiter is replayed as a host key.
      return true
    }
  }

  /// Lifecycle/configuration callers consume pending state first, so nested IMK finalization cannot
  /// restore twice. A lost/closed/secure host is never written to as a speculative recovery action.
  func finishAutomaticExpansion(replaySemicolon: Bool) {
    automaticEpoch &+= 1
    guard let text = automaticRecognizer.takePending(), let target = automaticTarget,
          target.client != nil else { discardAutomaticExpansion(); return }
    let epoch = automaticEpoch
    let owned = automaticOwns(target)
    guard epoch == automaticEpoch, automaticTarget === target else { return }
    discardAutomaticExpansion()
    guard owned else { return }
    restoreAutomaticText(text, target: target, replaySemicolon: replaySemicolon && text == ";")
  }

  func discardAutomaticExpansion() {
    let hadTarget = automaticTarget != nil
    _ = automaticRecognizer.takePending()
    automaticTarget = nil
    if hadTarget {
      preedit = ""
      lastCommittedCharacter = nil
    }
  }

  /// Modifiers still reach Rime; preserve marked-text keepalive unless they actually change mode.
  func refreshAutomaticExpansionAfterModifiers() -> Bool {
    guard let target = automaticTarget else { return false }
    guard target.asciiMode == engineSession?.option(.asciiMode), (engineSession?.input() ?? "").isEmpty,
          automaticOwns(target) else {
      finishAutomaticExpansion(replaySemicolon: false)
      return false
    }
    withAutomaticClientAction {
      show(preedit: target.markedText, selRange: NSRange(location: 0, length: target.markedText.utf16.count),
           caretPos: target.markedText.utf16.count)
    }
    return true
  }

  /// Existing Rime/menu rendering must not overwrite a prefix that it does not own.
  func finishAutomaticExpansionBeforeClientAction() {
    guard !automaticApplyingClientAction, automaticTarget != nil else { return }
    let rendered = (preedit, selRange, caretPos)
    finishAutomaticExpansion(replaySemicolon: false)
    (preedit, selRange, caretPos) = rendered
  }

  private func restoreAutomaticText(_ text: String, target: OwlAutomaticExpansionTarget, replaySemicolon: Bool) {
    guard let client = target.client else { return }
    if replaySemicolon {
      let epoch = automaticEpoch
      // Keep the old marked text until original Rime punctuation replaces/commits it. Clearing
      // first would lose the semicolon on a synchronous focus/finalize callback.
      OwlAutomaticExpansionControllerEntry.replaySemicolon(keycode: target.replayKeycode, modifiers: target.replayModifiers,
        process: { processKey($0, modifiers: $1) }, update: { engineUpdate() },
        isCurrent: { epoch == automaticEpoch && self.client === client && engineSession?.isValid == true },
        insertLiteral: { withAutomaticClientAction { apply(.insertText(";"), client: client) } })
    } else {
      withAutomaticClientAction { apply(.insertText(text), client: client) }
    }
  }

  private func automaticObservation(_ target: OwlAutomaticExpansionTarget, length: Int) -> OwlAutomaticExpansionObservation? {
    guard let client = target.client, self.client === client, automaticReadsAllowed(client) else { return nil }
    let total = client.length()
    guard total >= target.start, total != NSNotFound else { return nil }
    let count = min(length, total - target.start)
    let nearby = count == 0 ? "" : client.attributedSubstring(from: NSRange(location: target.start, length: count))?.string
    return OwlAutomaticExpansionObservation(selection: client.selectedRange(), marked: client.markedRange(),
      documentLength: total, nearbyText: nearby)
  }

  private func automaticOwns(_ target: OwlAutomaticExpansionTarget) -> Bool {
    guard let client = target.client, let active = self.client, client === active,
          engineSession?.sessionID == target.sessionID, automaticReadsAllowed(client),
          !target.markedText.isEmpty else { return false }
    let epoch = automaticEpoch
    let marked = client.markedRange()
    guard OwlAutomaticExpansionScope.valid(marked), marked.location == target.start,
          marked.length == target.markedText.utf16.count else { return false }
    let owned = OwlAutomaticExpansionScope.owns(start: target.start, text: target.markedText, marked: marked,
      selection: client.selectedRange(), substring: client.attributedSubstring(from: marked)?.string)
    return owned && automaticEpoch == epoch && automaticTarget === target && self.client === client
  }

  private func automaticReadsAllowed(_ client: IMKTextInput) -> Bool {
    let privacy = OwlClientPrivacyState.current()
    guard !privacy.isSecureInputEnabled, !privacy.isPasswordLike else { return false }
    let bundleID = client.bundleIdentifier()
    let policy = NSApp.owlAppDelegate.clientCapabilityPolicy.evaluate(.init(
      host: .init(bundleID: bundleID, linksElectronFramework: OwlElectronHostDetector.shared.linksElectron(bundleID: bundleID)),
      privacy: privacy, workarounds: NSApp.owlAppDelegate.clientWorkarounds))
    // No bypass of denied document access. Chrome marked-only ownership remains a host-validation
    // gap; this conservative implementation cannot yet claim the three-host acceptance gate.
    return policy.selectedRange.allowed && policy.surroundingText.allowed
  }

  private func withAutomaticClientAction(_ body: () -> Void) {
    let previous = automaticApplyingClientAction
    automaticApplyingClientAction = true
    defer { automaticApplyingClientAction = previous }
    body()
  }
}

/// The production key classifier is also driven by headless value tests. Shift punctuation is
/// literal text, while modified Return/Tab retain their existing navigation/host semantics.
enum OwlAutomaticExpansionEventInput {
  static func classify(_ event: OwlKeyEvent) -> OwlAutomaticExpansionRecognizer.Input {
    guard event.type == .keyDown,
          event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return .interrupt }
    switch Int(event.keyCode) {
    case kVK_Delete: return .backspace
    case kVK_Escape: return .escape
    case kVK_Return, kVK_Tab:
      guard !event.modifierFlags.contains(.shift) else { return .interrupt }
      return .text(Int(event.keyCode) == kVK_Return ? "\n" : "\t")
    default:
      guard let text = event.characters, !text.isEmpty,
            !text.unicodeScalars.contains(where: { $0.value < 32 || (0xF700...0xF8FF).contains($0.value) }) else {
        return .interrupt
      }
      return .text(text)
    }
  }
}
