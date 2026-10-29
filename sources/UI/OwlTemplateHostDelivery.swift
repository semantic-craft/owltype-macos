import AppKit
import ApplicationServices
import InputMethodKit

enum OwlTemplateDeliveryOutcome: Equatable {
  enum Reason: Equatable {
    case missingHost, focusNotRestored, targetChanged, unverifiableTarget, secureInput
    case originalNotPreserved
  }
  enum Cursor: Equatable { case positioned, leftAtEnd, positionUnverified }
  case notAttempted(Reason)
  case attemptedUnverified
  case confirmed
  case confirmedWithCursor(Cursor)
  // The uncertain write was original trigger preservation, NOT template result delivery.
  case originalPreservationUnverified

  var finishesPresentation: Bool {
    self == .confirmed || self == .confirmedWithCursor(.positioned)
  }
  var keepsHostFocus: Bool {
    switch self {
    case .attemptedUnverified, .originalPreservationUnverified, .confirmed, .confirmedWithCursor: return true
    case .notAttempted: return false
    }
  }
  var message: String {
    switch self {
    case .confirmed: return "已确认插入。"
    case .confirmedWithCursor(.positioned): return "已插入，光标已定位。"
    case .confirmedWithCursor(.leftAtEnd): return "正文已插入，光标仍在末尾；此输入框未完成指定位置定位。"
    case .confirmedWithCursor(.positionUnverified): return "正文已插入，光标位置未能确认；请检查原输入框。"
    case .attemptedUnverified: return "已尝试插入，暂无法确认。若有光标字段，定位也未确认。请先检查原输入框；需要时复制结果。"
    case .originalPreservationUnverified: return "已尝试保留原触发文本，暂无法确认；模板结果未插入。请检查原输入框，结果可复制使用。"
    case .notAttempted(.originalNotPreserved): return "未能安全保留原触发文本，模板结果未插入；请检查原输入框，结果可复制使用。"
    case .notAttempted(.missingHost): return "没有可用的原输入框，未插入。结果已保留，可复制使用。"
    case .notAttempted(.focusNotRestored): return "未能恢复原应用焦点，未插入。结果已保留，可复制使用。"
    case .notAttempted(.targetChanged): return "原输入目标已改变，未插入。结果已保留，可复制使用。"
    case .notAttempted(.unverifiableTarget): return "无法确认原输入框，未插入。结果已保留，可复制使用。"
    case .notAttempted(.secureInput): return "当前输入环境不能安全插入。结果已保留，可复制使用。"
    }
  }
}

enum OwlTemplatePresentationPreparation: Equatable {
  case ready
  case originalNotAttempted(OwlTemplateDeliveryOutcome.Reason)
  case originalAttemptedUnverified
}

/// One invocation's text ownership. Original-input preservation and result delivery each have
/// one write slot. AX is used only for existing-permission field identity and cursor selection.
final class OwlTemplateHostDelivery {
  struct AutomaticSource {
    let originalInput: String
    let markedRange: NSRange
    let markedText: String
    let isValid: () -> Bool
  }

  /// Inject the same boundaries used by production; tests assert content/geometry and write counts.
  struct Access {
    var rejection: (Bool) -> OwlTemplateDeliveryOutcome.Reason?
    var rangeIsCurrent: () -> Bool
    var revision: () -> UInt64
    var selection: () -> NSRange?
    var marked: () -> NSRange?
    var text: (NSRange) -> String?
    var insert: (String, NSRange?) -> Void
    var canReplace: () -> Bool
    var move: (NSRange, NSRange, String) -> Bool
    var isPresentationFocused: () -> Bool = { false }
    var canRestore: () -> Bool = { true }
    /// Runs the post-insert checks once the host has processed the insert. The host may need this
    /// process to answer while it handles the insert, so production waits a turn; tests run inline.
    var settle: (@escaping () -> Void) -> Void = { $0() }
  }

  private weak var controller: OwlInputController?
  private weak var client: IMKTextInput?
  private var generation: UInt64 = 0
  private var application: NSRunningApplication?
  private struct Field { let element: AXUIElement; let isSecure: Bool }
  private var field: Field?
  private var access: Access!
  private let source: AutomaticSource?
  private var immediate = true
  private var invalid = false
  private var resultDispatched = false
  private var preparationStarted = false
  private var preparation: OwlTemplatePresentationPreparation?
  private var committedOriginal: NSRange?
  private weak var presentationWindow: NSWindow?
  private var isPresentingWindow = false
  private var activationObserver: NSObjectProtocol?
  private var suspendedForPanel = false
  private static let readLimit = 65_536

  init(controller: OwlInputController, client: IMKTextInput?, automaticSource: AutomaticSource? = nil) {
    self.controller = controller
    self.client = client
    source = automaticSource
    generation = controller.templateHostGeneration
    let app = NSWorkspace.shared.frontmostApplication
    application = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    if let application {
      Self.captureOutsideKeyEvent({ Self.focusedField(application) }) { [weak self] captured in
        guard let self, self.field == nil, !self.resultDispatched, !self.invalid else { return }
        self.field = captured
      }
    }
    access = Access(
      rejection: { [weak self] immediate in
        guard let self else { return .missingHost }; return self.liveRejection(immediate: immediate)
      },
      rangeIsCurrent: { [weak self] in self?.liveRangesAllowed() == true },
      // Read the bound controller and client at call time: delivery may re-bind them.
      revision: { [weak self] in self?.controller?.templateHostGeneration ?? UInt64.max },
      selection: { [weak self] in self?.client?.selectedRange() },
      marked: { [weak self] in self?.client?.markedRange() },
      text: { [weak self] range in self?.client?.attributedSubstring(from: range)?.string },
      insert: { [weak self] text, range in
        guard let controller = self?.controller, let client = self?.client else { return }
        let previous = controller.automaticApplyingClientAction
        controller.automaticApplyingClientAction = true
        defer { controller.automaticApplyingClientAction = previous }
        if let range { controller.apply(.insertTextInRange(text, replacementRange: range), client: client) }
        else { controller.apply(.insertText(text), client: client) }
      }, canReplace: { [weak self] in self?.liveRangesAllowed(replacement: true) == true },
      move: { [weak self] target, inserted, text in self?.moveCursor(target, inserted: inserted, text: text) == true },
      isPresentationFocused: { [weak self] in self?.presentationWindow?.isKeyWindow == true },
      canRestore: { [weak self] in
        guard let self, let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier == self.application?.processIdentifier ||
          (front.processIdentifier == ProcessInfo.processInfo.processIdentifier && self.presentationWindow?.isKeyWindow == true)
      },
      settle: { [weak self] next in self?.awaitReadableHost(polls: Self.settlePolls, next) })
    if automaticSource != nil {
      controller.pendingTemplateDelivery?.invalidate()
      controller.pendingTemplateDelivery = self
      activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
          guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
          self.applicationDidActivate(isOriginal: app.processIdentifier == self.application?.processIdentifier,
            isPresentation: app.processIdentifier == ProcessInfo.processInfo.processIdentifier && self.presentationWindow?.isKeyWindow == true)
        }
    }
  }

  init(access: Access, automaticSource: AutomaticSource? = nil) {
    self.access = access
    source = automaticSource
  }

  deinit { if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) } }

  func endImmediateDelivery() { immediate = false }
  func invalidate() { invalid = true; isPresentingWindow = false; suspendedForPanel = false }

  func mayRestoreFocus() -> Bool {
    source == nil || (!invalid && source?.isValid() == true && access.canRestore())
  }

  func presentationTransition(window: NSWindow, active: Bool) {
    guard source != nil, preparation == .ready, !invalid else { return }
    presentationWindow = window
    isPresentingWindow = active
  }

  func applicationDidActivate(isOriginal: Bool, isPresentation: Bool) {
    if !isOriginal && !isPresentation { invalidate() }
  }

  func hostWillDeactivate() {
    if preparation == .ready, !invalid, access.canRestore(),
       isPresentingWindow || access.isPresentationFocused() { suspendedForPanel = true }
    else { invalidate() }
  }

  func hostDidActivate() {
    guard suspendedForPanel else { invalidate(); return }
    suspendedForPanel = false
    if source?.isValid() != true { invalidate(); return }
    // Restoration can announce activation before the accessible field becomes readable.
    if let reason = access.rejection(false), reason != .unverifiableTarget { invalidate() }
  }

  func isReadyForDelivery() -> Bool {
    !invalid && !resultDispatched && (source?.isValid() ?? true) && access.rejection(immediate) == nil
  }

  private func read(_ range: NSRange) -> String? {
    guard OwlTemplateCursorPlacement.valid(range), range.length <= Self.readLimit,
          access.rangeIsCurrent(), let text = access.text(range), text.utf16.count == range.length else { return nil }
    return text
  }

  private func noMarkedText() -> Bool {
    guard let marked = access.marked() else { return false }
    return marked.location == NSNotFound || (OwlTemplateCursorPlacement.valid(marked) && marked.length == 0)
  }

  private func ownsSource(_ source: AutomaticSource) -> Bool {
    guard isReadyForDelivery(), source.isValid(), access.rangeIsCurrent(),
          OwlTemplateCursorPlacement.valid(source.markedRange), !source.markedText.isEmpty,
          source.markedRange.length == source.markedText.utf16.count,
          access.marked() == source.markedRange,
          let selection = access.selection(), OwlTemplateCursorPlacement.valid(selection), selection.length == 0,
          selection.location == NSMaxRange(source.markedRange),
          let text = read(source.markedRange) else { return false }
    return OwlTemplateCursorPlacement.equalText(text, source.markedText) && isReadyForDelivery()
  }

  /// Called only before an editable window, never by a terminal retained-result presentation.
  func prepareForPresentation() -> OwlTemplatePresentationPreparation {
    guard let source else { return .ready }
    if let preparation { return preparation }
    guard !preparationStarted else { return .originalNotAttempted(.targetChanged) }
    preparationStarted = true
    guard ownsSource(source) else {
      preparation = .originalNotAttempted(.originalNotPreserved)
      invalidate()
      return preparation!
    }
    let revision = access.revision()
    // Mark the slot BEFORE a synchronous IMK callback can reenter this method.
    preparation = .originalAttemptedUnverified
    access.insert(source.originalInput, nil)
    guard isReadyForDelivery(), access.revision() == revision,
          let range = OwlTemplateCursorPlacement.insertedRange(text: source.originalInput, base: source.markedRange.location),
          confirmedText(source.originalInput, in: range) else {
      invalidate()
      return .originalAttemptedUnverified
    }
    committedOriginal = range
    preparation = .ready
    return .ready
  }

  private func confirmedText(_ text: String, in range: NSRange) -> Bool {
    guard let actual = read(range) else { Self.trace("readback: \(range) unreadable; \(bindingState())"); return false }
    guard OwlTemplateCursorPlacement.equalText(actual, text) else {
      Self.trace("readback: \(range) holds \(actual.utf16.count) different units"); return false
    }
    let selection = access.selection()
    guard selection == NSRange(location: NSMaxRange(range), length: 0) else {
      Self.trace("readback: selection \(String(describing: selection)) is not at \(NSMaxRange(range))"); return false
    }
    guard noMarkedText() else { Self.trace("readback: marked text \(String(describing: access.marked())) remains"); return false }
    if let reason = access.rejection(immediate) { Self.trace("readback: host refused \(reason)"); return false }
    return !invalid && (source?.isValid() ?? true)
  }

  private func bindingState() -> String {
    let live = controller?.client.map { ($0 as AnyObject) === (client as AnyObject?) } ?? false
    return "controller=\(controller != nil) client=\(client != nil) live=\(live) policy=\(policyAllowsRanges())"
  }

  /// For candidates, IMK's marked replacement range, not its caret, is the insertion origin.
  private func insertionRange() -> NSRange? {
    guard access.rangeIsCurrent() else { Self.trace("origin: host ranges not trusted; \(bindingState())"); return nil }
    guard let selection = access.selection(), OwlTemplateCursorPlacement.valid(selection),
          let marked = access.marked() else {
      Self.trace("origin: selection \(String(describing: access.selection())) marked \(String(describing: access.marked()))")
      return nil
    }
    if marked.location == NSNotFound || marked.length == 0 { return selection }
    guard OwlTemplateCursorPlacement.valid(marked), selection.location >= marked.location,
          NSMaxRange(selection) <= NSMaxRange(marked), read(marked) != nil else {
      Self.trace("origin: selection \(selection) outside readable marked \(marked)"); return nil
    }
    return marked
  }

  /// Synchronous form for callers whose access settles inline (tests).
  func deliver(_ result: OwlTemplateInvocation.Result) -> OwlTemplateDeliveryOutcome {
    var outcome = OwlTemplateDeliveryOutcome.attemptedUnverified
    deliver(result) { outcome = $0 }
    return outcome
  }

  /// Inserts at most once, then verifies after the host has processed the insert.
  func deliver(_ result: OwlTemplateInvocation.Result, completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
    guard !resultDispatched else { completion(.notAttempted(.targetChanged)); return }
    guard isReadyForDelivery() else {
      let reason = access.rejection(immediate) ?? .targetChanged
      Self.trace("refused before insert: \(reason)")
      completion(.notAttempted(reason))
      return
    }
    guard let plan = insertionPlan(for: result) else { completion(.notAttempted(.targetChanged)); return }
    let (origin, replacement) = plan
    guard isReadyForDelivery() else { completion(.notAttempted(.targetChanged)); return }
    let revision = access.revision()
    resultDispatched = true
    access.insert(result.text, replacement)
    // Even a successful Void dispatch is unverified until the bounded readback agrees.
    guard let origin else { Self.trace("inserted without a readable origin"); completion(.attemptedUnverified); return }
    // An immediate result is written while the key event is still being answered, through the
    // session that is handling it; it verifies in that same turn. Waiting would end the
    // active-session exception it relies on.
    if immediate { completion(verify(result, origin: origin, revision: revision)); return }
    access.settle { [self] in completion(verify(result, origin: origin, revision: revision)) }
  }

  /// The origin to verify against (nil when unreadable) and the range to replace, or nil to refuse.
  private func insertionPlan(for result: OwlTemplateInvocation.Result) -> (NSRange?, NSRange?)? {
    if let source {
      if let original = committedOriginal {
        guard access.canReplace(), confirmedText(source.originalInput, in: original) else { return nil }
        return (original, original)
      }
      guard ownsSource(source) else { return nil }
      return (source.markedRange, nil)
    }
    return (result.cursorOffset != nil ? insertionRange() : nil, nil)
  }

  private func verify(_ result: OwlTemplateInvocation.Result, origin: NSRange, revision: UInt64) -> OwlTemplateDeliveryOutcome {
    // Restoring the host may re-activate the same field's session. The readback below still has
    // to prove the same accessible field, a live client, the inserted text and the caret.
    if access.revision() != revision {
      guard access.rejection(false) == nil else { Self.trace("host session changed during insert"); return .attemptedUnverified }
      Self.trace("host session re-activated on the same field during insert")
    }
    guard let inserted = OwlTemplateCursorPlacement.insertedRange(text: result.text, base: origin.location),
          confirmedText(result.text, in: inserted) else { Self.trace("readback did not match the insert"); return .attemptedUnverified }
    guard let offset = result.cursorOffset else { return .confirmed }
    guard let selection = access.selection(), let target = OwlTemplateCursorPlacement.target(text: result.text,
      offset: offset, base: origin.location, selection: selection, readback: result.text) else {
      return .confirmedWithCursor(.positionUnverified)
    }
    let settled = access.revision()
    let moved = access.move(target, inserted, result.text)
    if !moved { Self.trace("cursor placement refused") }
    guard !invalid, access.revision() == settled, access.rejection(immediate) == nil else {
      return .confirmedWithCursor(.positionUnverified)
    }
    if moved, access.selection() == target { return .confirmedWithCursor(.positioned) }
    return .confirmedWithCursor(access.selection() == selection ? .leftAtEnd : .positionUnverified)
  }

  private func liveRejection(immediate: Bool) -> OwlTemplateDeliveryOutcome.Reason? {
    guard let application, !application.isTerminated else { return .missingHost }
    if !immediate { rebindToActivatedClient(application) }
    guard let controller, let client else { return .missingHost }
    let current = Self.focusedField(application)
    guard !OwlClientPrivacyState.current().isSecureInputEnabled,
          field?.isSecure != true, current?.isSecure != true else { return .secureInput }
    guard application.isActive,
          let bundle = client.bundleIdentifier(), bundle == application.bundleIdentifier else { return .targetChanged }
    let sameActiveClient = controller.client.map { ($0 as AnyObject) === (client as AnyObject) } ?? false
    if !(immediate && sameActiveClient && generation == controller.templateHostGeneration) {
      guard let field else { Self.trace("no host field captured at invocation"); return .unverifiableTarget }
      guard let current else { Self.trace("host field unreadable now"); return .unverifiableTarget }
      guard CFEqual(field.element, current.element), sameActiveClient else { return .targetChanged }
    }
    return nil
  }

  /// A window over the host deactivates its input session. When the field regains focus IMK may
  /// serve it through a new controller or client proxy, so the captured pair no longer matches.
  /// Re-bind only to the session IMK activated for the captured application; the caller still
  /// requires the focused accessibility field to be the one captured before the window.
  private func rebindToActivatedClient(_ application: NSRunningApplication) {
    guard let activated = Self.rebindTarget(controller: controller, client: client,
      activated: NSApp.owlAppDelegate.runtime.activatedInputController, bundleID: application.bundleIdentifier) else { return }
    Self.trace("rebind to activated session")
    controller = activated
    client = activated.client
  }

  /// The activated controller to adopt, or nil while the captured pair is still live.
  static func rebindTarget(controller: OwlInputController?, client: IMKTextInput?,
                           activated: OwlInputController?, bundleID: String?) -> OwlInputController? {
    if let controller, let client, let live = controller.client, live === client { return nil }
    guard let activated, let live = activated.client, let bundleID,
          live.bundleIdentifier() == bundleID else { return nil }
    return activated
  }

  /// 25 ms polls for the host to answer accessibility again after an insert.
  static let settlePolls = 8

  private func awaitReadableHost(polls: Int, _ next: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
      guard let self else { return }
      if polls > 0, let application = self.application, Self.focusedField(application) == nil {
        self.awaitReadableHost(polls: polls - 1, next)
      } else {
        next()
      }
    }
  }

  /// Candidate and automatic invocations start inside `handle()`, while the host waits on this
  /// process for the key event's answer and cannot serve accessibility. Read the focused field
  /// again once the key event has returned, before any window can move focus in the host.
  static func captureOutsideKeyEvent<Value>(_ read: @escaping () -> Value?,
                                            schedule: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
                                            store: @escaping (Value) -> Void) {
    if let value = read() { store(value); return }
    trace("host field unreadable during the key event; reading it after the event")
    schedule {
      guard let value = read() else { trace("host field still unreadable after the key event"); return }
      store(value)
    }
  }

  static func trace(_ message: @autoclosure () -> String) {
    OwlLiveInputTrace.write({ "template delivery " + message() })
  }

  private func liveRangesAllowed(replacement: Bool = false) -> Bool {
    liveRejection(immediate: immediate) == nil && policyAllowsRanges(replacement: replacement)
  }

  private func policyAllowsRanges(replacement: Bool = false) -> Bool {
    guard let client else { return false }
    let bundle = client.bundleIdentifier()
    let policy = NSApp.owlAppDelegate.clientCapabilityPolicy.evaluate(.init(
      host: .init(bundleID: bundle, linksElectronFramework: OwlElectronHostDetector.shared.linksElectron(bundleID: bundle)),
      privacy: .current(), workarounds: NSApp.owlAppDelegate.clientWorkarounds))
    return policy.selectedRange.allowed && policy.surroundingText.allowed && (!replacement || policy.replacementRange.allowed)
  }

  private func moveCursor(_ target: NSRange, inserted: NSRange, text: String) -> Bool {
    guard !invalid, liveRangesAllowed(replacement: true), let application, let field,
          let current = Self.focusedField(application), CFEqual(field.element, current.element),
          let client else { Self.trace("cursor: host field or range policy unavailable"); return false }
    guard OwlTemplateCursorPlacement.selectionIsAtEnd(Self.axSelection(field.element), inserted: inserted),
          OwlTemplateCursorPlacement.selectionIsAtEnd(client.selectedRange(), inserted: inserted) else {
      Self.trace("cursor: selection is not at the end of the insert"); return false
    }
    guard let axText = Self.axText(field.element, range: inserted), OwlTemplateCursorPlacement.equalText(axText, text) else {
      Self.trace("cursor: accessible text does not match the insert"); return false
    }
    // Check the actual local composed-character boundary, including host neighbors. No full document read.
    let length = client.length()
    guard length >= NSMaxRange(inserted), length != NSNotFound else { return false }
    let start = max(0, target.location - 32)
    let count = min(length - start, target.location - start + 32)
    guard let context = Self.axText(field.element, range: NSRange(location: start, length: count)),
          context.utf16.count == count,
          OwlTemplateCursorPlacement.isHostBoundary(target.location - start, in: context,
            startsAtDocumentStart: start == 0), liveRejection(immediate: false) == nil,
          OwlTemplateCursorPlacement.selectionIsAtEnd(Self.axSelection(field.element), inserted: inserted),
          OwlTemplateCursorPlacement.selectionIsAtEnd(client.selectedRange(), inserted: inserted) else {
      Self.trace("cursor: target is not a character boundary in the host"); return false
    }
    // End markers need the same identity/context proof, but no selection mutation.
    if target == NSRange(location: NSMaxRange(inserted), length: 0) { return true }
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(field.element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
          settable.boolValue, liveRejection(immediate: false) == nil else {
      Self.trace("cursor: host selection is not settable"); return false
    }
    var range = CFRange(location: target.location, length: 0)
    guard let value = AXValueCreate(.cfRange, &range) else { return false }
    guard !invalid, liveRejection(immediate: false) == nil,
          OwlTemplateCursorPlacement.selectionIsAtEnd(Self.axSelection(field.element), inserted: inserted),
          OwlTemplateCursorPlacement.selectionIsAtEnd(client.selectedRange(), inserted: inserted),
          AXUIElementSetAttributeValue(field.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
      Self.trace("cursor: setting the host selection failed"); return false
    }
    return Self.axSelection(field.element) == target
  }

  private static func axSelection(_ field: AXUIElement) -> NSRange? {
    var reference: CFTypeRef?
    guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &reference) == .success,
          let reference, CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(reference as! AXValue, .cfRange, &range) else { return nil }
    let result = NSRange(location: range.location, length: range.length)
    return OwlTemplateCursorPlacement.valid(result) ? result : nil
  }

  private static func axText(_ field: AXUIElement, range: NSRange) -> String? {
    guard OwlTemplateCursorPlacement.valid(range), range.length <= readLimit else { return nil }
    var cfRange = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &cfRange) else { return nil }
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success,
          let text = result as? String, text.utf16.count == range.length else { return nil }
    return text
  }

  private static func focusedField(_ application: NSRunningApplication) -> Field? {
    guard AXIsProcessTrusted(), !application.isTerminated else { return nil }
    let app = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.05)
    var reference: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &reference) == .success,
          let reference, CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
    let element = reference as! AXUIElement
    AXUIElementSetMessagingTimeout(element, 0.05)
    var role: CFTypeRef?
    var subrole: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
          let role = role as? String, [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }
    _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
    return Field(element: element, isSecure: subrole as? String == kAXSecureTextFieldSubrole)
  }
}
