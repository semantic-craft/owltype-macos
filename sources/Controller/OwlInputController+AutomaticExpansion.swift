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
  private let binding: OwlAppSession

  init(client: IMKTextInput, start: Int, sessionID: UInt64, asciiMode: Bool, revision: UInt64, replayKeycode: UInt32, replayModifiers: UInt32) {
    binding = try! OwlAppSession("binding", args: ["session": String(sessionID), "ascii": String(asciiMode),
      "revision": String(revision), "allowed": "true", "input": ""])
    self.client = client
    self.start = start
    self.sessionID = sessionID
    self.asciiMode = asciiMode
    self.revision = revision
    self.replayKeycode = replayKeycode
    self.replayModifiers = replayModifiers
  }
  func isCurrent(sessionID: UInt64?, asciiMode: Bool?, revision: UInt64, allowed: Bool, input: String?) -> Bool {
    binding.call("binding", ["session": sessionID.map(String.init) ?? "", "ascii": asciiMode.map(String.init) ?? "",
      "revision": String(revision), "allowed": String(allowed), "input": input ?? ""])
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
            target.isCurrent(sessionID: engineSession?.sessionID, asciiMode: engineSession?.option(.asciiMode),
              revision: runtime.revision, allowed: runtime.allows(bundleID: client.bundleIdentifier()),
              input: engineSession?.input()) else {
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
      let revision = runtime.policyRevision
      let sourceSchema = schemaId
      let bundleID = client.bundleIdentifier()
      // This proof must survive discard and the expected parameter-window transition. Do not
      // bind it to automaticTarget/automaticEpoch, which belong to recognition, not invocation.
      let validity = OwlAutomaticExpansionInvocationValidity(binding: [
        "session": String(sessionID), "ascii": String(asciiMode), "schema": sourceSchema,
        "revision": String(revision), "allowed": "true", "live": "true"
      ].merging(runtime.binding(for: source.entry)) { _, new in new }, current: { [weak self] in
        guard let self, let engineSession = self.engineSession else { return [:] }
        return ["session": String(engineSession.sessionID), "ascii": String(engineSession.option(.asciiMode)),
          "schema": self.schemaId, "revision": String(runtime.policyRevision),
          "allowed": String(runtime.allows(bundleID: bundleID)), "live": String(engineSession.isValid)]
          .merging(runtime.binding(for: source.entry)) { _, new in new }
      })
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
    // This marked-text path only uses permitted IMK ranges. Chromium observes committed
    // literal text after the key event through the independent AX adapter below.
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

/// Native identity/coordinate capture only; the shared Rust recognizer owns recognition.
/// No intercepted keys and no replay: unsupported fields keep their ordinary host input.
final class OwlCommittedAutomaticCapture {
  let sessionID: UInt64
  let asciiMode: Bool
  let application: NSRunningApplication
  private let binding: OwlAutomaticExpansionInvocationValidity
  func isCurrent() -> Bool { binding.isValid() }
  var field: OwlTemplateHostDelivery.Field?
  var start: Int?
  init(sessionID: UInt64, asciiMode: Bool, application: NSRunningApplication,
       current: @escaping () -> [String: String]) {
    binding = OwlAutomaticExpansionInvocationValidity(binding: current(), current: current)
    self.sessionID = sessionID; self.asciiMode = asciiMode
    self.application = application
  }
}

extension OwlInputController {
  /// Called at the end of handle, but every AX operation is scheduled after handle returns.
  /// A host may have already handled Return/Tab: a changed field/selection then fails closed.
  func observeCommittedAutomaticExpansion(_ event: NSEvent) {
    guard event.type == .keyDown else { return }
    let runtime = OwlAutomaticExpansionRuntime.shared
    guard let client, let session = engineSession else { return }
    let admitted: Bool = OwlAutomaticExpansionScope.rule("committed_observe", [
      "axFallback": OwlTemplateHostDelivery.usesAXFallback(client), "allowed": runtime.allows(bundleID: client.bundleIdentifier()),
      "engineValid": session.isValid, "input": session.input() as Any? ?? NSNull(), "preedit": preedit])
    guard admitted else {
      _ = committedAutomaticRecognizer.takePending(); committedAutomaticCapture = nil; return
    }
    if let capture = committedAutomaticCapture, !capture.isCurrent() {
      _ = committedAutomaticRecognizer.takePending(); committedAutomaticCapture = nil
    }
    let input = OwlAutomaticExpansionEventInput.classify(OwlKeyEvent(event: event, lastModifiers: []))
    let step = committedAutomaticRecognizer.consume(input, index: runtime.index, canStart: true)
    let eventGeneration = hostEventGeneration
    let eventBinding = OwlAutomaticExpansionInvocationValidity(binding: ["event": String(eventGeneration)],
      current: { [weak self] in ["event": self.map { String($0.hostEventGeneration) } ?? ""] })
    switch step {
    case .mark(let text):
      guard text == ";", let application = NSWorkspace.shared.frontmostApplication,
            application.bundleIdentifier == client.bundleIdentifier() else { return }
      let capture = OwlCommittedAutomaticCapture(sessionID: session.sessionID,
        asciiMode: session.option(.asciiMode), application: application,
        current: { [weak self] in
          guard let self, let session = self.engineSession else { return [:] }
          return ["generation": String(self.templateHostGeneration), "session": String(session.sessionID),
            "ascii": String(session.option(.asciiMode)), "revision": String(runtime.revision), "schema": self.schemaId,
            "live": String(session.isValid)]
        })
      committedAutomaticCapture = capture
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self, weak client] in
        guard let self, let client, self.client === client, self.committedAutomaticCapture === capture,
              eventBinding.isValid(), capture.isCurrent(),
              application.isActive, !OwlClientPrivacyState.current().isSecureInputEnabled,
              let field = OwlTemplateHostDelivery.focusedField(application), !field.isSecure,
              let selection = OwlTemplateHostDelivery.axSelection(field.element), selection.length == 0, selection.location > 0,
              OwlTemplateHostDelivery.axText(field.element, range: NSRange(location: selection.location - 1, length: 1)) == ";" else { return }
        let start = selection.location - 1
        let preceding = start > 0 ? OwlTemplateHostDelivery.axText(field.element, range: NSRange(location: start - 1, length: 1)) : nil
        guard OwlAutomaticExpansionScope.canStart(selection: NSRange(location: start, length: 0),
          marked: NSRange(location: NSNotFound, length: 0), preceding: preceding),
          eventBinding.isValid(), capture.isCurrent() else { return }
        capture.field = field; capture.start = start
      }
    case .invoke(let entry, let trigger, let delimiter):
      let capture = committedAutomaticCapture
      committedAutomaticCapture = nil
      guard let capture else {
        OwlTemplateHostDelivery.trace("committed automatic trigger has no bound field; original retained")
        return
      }
      let original: String = OwlAutomaticExpansionScope.rule("committed_original", [
        "trigger": trigger, "delimiter": delimiter as Any? ?? NSNull()])
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self, weak client] in
        guard let self, let client, self.client === client, eventBinding.isValid(), capture.isCurrent(),
              capture.application.isActive, !OwlClientPrivacyState.current().isSecureInputEnabled,
              let field = capture.field, let start = capture.start,
              let current = OwlTemplateHostDelivery.focusedField(capture.application), !current.isSecure,
              CFEqual(field.element, current.element) else {
          OwlTemplateHostDelivery.trace("committed automatic target changed; original retained")
          return
        }
        let range = NSRange(location: start, length: original.utf16.count)
        guard OwlTemplateHostDelivery.axSelection(current.element) == NSRange(location: NSMaxRange(range), length: 0),
              OwlTemplateHostDelivery.axText(current.element, range: range) == original,
              OwlTemplateHostDelivery.axSelectionSettable(current.element), eventBinding.isValid(), capture.isCurrent() else {
          OwlTemplateHostDelivery.trace("committed automatic text/selection capability unverified; original retained")
          return
        }
        let sourceSchema = self.schemaId
        let sourcePolicy = runtime.policyRevision
        let binding = { [weak self] () -> [String: String] in
          guard let self, let session = self.engineSession else { return [:] }
          return ["session": String(session.sessionID), "ascii": String(session.option(.asciiMode)),
            "schema": self.schemaId, "policy": String(runtime.policyRevision),
            "allowed": String(runtime.allows(bundleID: client.bundleIdentifier())), "live": String(session.isValid)]
            .merging(runtime.binding(for: entry)) { _, new in new }
        }
        let validity = OwlAutomaticExpansionInvocationValidity(binding: [
          "session": String(capture.sessionID), "ascii": String(capture.asciiMode), "schema": sourceSchema,
          "policy": String(sourcePolicy), "allowed": "true", "live": "true"
        ].merging(runtime.binding(for: entry)) { _, new in new }, current: binding)
        let source = OwlTemplateHostDelivery.AutomaticSource(originalInput: original, markedRange: range,
          markedText: original, isValid: { validity.isValid() }, committed: true)
        let delivery = OwlTemplateHostDelivery(controller: self, client: client, automaticSource: source,
          boundField: current, boundApplication: capture.application)
        self.invokeTemplate(.template(entry), broker: OwlPanelInsertionBroker(), capturedClient: client,
          trailingText: step.trailingText, target: delivery, automaticSource: source)
      }
    default:
      committedAutomaticCapture = nil
    }
  }
}
