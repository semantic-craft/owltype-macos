import AppKit
import ApplicationServices
import InputMethodKit

enum OwlTemplateDeliveryOutcome: Equatable {
  enum Reason: String, Equatable {
    case missingHost, focusNotRestored, targetChanged, unverifiableTarget, secureInput
    case originalNotPreserved, selectionNotPrepared
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
    case .notAttempted(.selectionNotPrepared): return "未能确认原触发文本的选区，未插入。结果已保留，可复制使用。"
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
    var committed = false
  }

  /// Inject the same boundaries used by production; tests assert content/geometry and write counts.
  struct Access {
    var rejection: (Bool) -> OwlTemplateDeliveryOutcome.Reason?
    var rangeIsCurrent: () -> Bool
    var revision: () -> UInt64
    var selection: () -> NSRange?
    var marked: () -> NSRange?
    var text: (NSRange) -> String?
    /// True only when the native insert call was made; this is not host acceptance.
    var insert: (String, NSRange?) -> Bool
    var canReplace: () -> Bool
    var move: (NSRange, NSRange, String) -> Bool
    var isPresentationFocused: () -> Bool = { false }
    var canRestore: () -> Bool = { true }
    /// Runs the post-insert checks once the host has processed the insert. The host may need this
    /// process to answer while it handles the insert, so production waits a turn; tests run inline.
    var settle: (@escaping () -> Void) -> Void = { $0() }
    var needsSelectionPreparation: () -> Bool = { false }
    var select: (NSRange) -> Bool = { _ in false }
    var nextTurn: (@escaping () -> Void) -> Void = { $0() }
  }

  private weak var controller: OwlInputController?
  private weak var client: IMKTextInput?
  private var generation: UInt64 = 0
  private var application: NSRunningApplication?
  struct Field { let element: AXUIElement; let isSecure: Bool }
  private var field: Field?
  private var access: Access!
  private let source: AutomaticSource?
  private weak var presentationWindow: NSWindow?
  private var activationObserver: NSObjectProtocol?
  private static let readLimit = 65_536

  init(controller: OwlInputController, client: IMKTextInput?, automaticSource: AutomaticSource? = nil,
       boundField: Field? = nil, boundApplication: NSRunningApplication? = nil) {
    self.controller = controller
    self.client = client
    source = automaticSource
    generation = controller.templateHostGeneration
    field = boundField
    let app = boundApplication ?? NSWorkspace.shared.frontmostApplication
    application = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    if let application, field == nil {
      let captureBinding = OwlAutomaticExpansionInvocationValidity(binding: ["event": String(controller.hostEventGeneration),
        "host": String(controller.templateHostGeneration)], current: { [weak controller] in
          guard let controller else { return [:] }
          return ["event": String(controller.hostEventGeneration), "host": String(controller.templateHostGeneration)]
        })
      Self.captureOutsideKeyEvent({ Self.focusedField(application) }, deferRead: controller.isHandlingKeyEvent) { [weak self] captured in
        guard let self, self.field == nil, !self.resultReserved, !self.invalid else { return }
        guard captureBinding.isValid() else { self.invalidate(); return }
        self.field = captured
      }
    }
    access = Access(
      rejection: { [weak self] immediate in
        guard let self else { return .missingHost }; return self.liveRejection(immediate: immediate)
      },
      rangeIsCurrent: { [weak self] in self?.nativeRangesAllowed() == true },
      // Read the bound controller and client at call time: delivery may re-bind them.
      revision: { [weak self] in self?.controller?.templateHostGeneration ?? UInt64.max },
      selection: { [weak self] in self?.nativeSelection() },
      marked: { [weak self] in self?.nativeMarked() },
      text: { [weak self] range in self?.nativeText(range) },
      insert: { [weak self] text, range in
        guard let controller = self?.controller, let client = self?.client else { return false }
        let previous = controller.automaticApplyingClientAction
        controller.automaticApplyingClientAction = true
        defer { controller.automaticApplyingClientAction = previous }
        if let range {
          controller.apply(.insertTextInRange(text, replacementRange: range), client: client)
        } else { controller.apply(.insertText(text), client: client) }
        return true
      }, canReplace: { [weak self] in self?.nativeReplacementAllowed() == true },
      move: { [weak self] target, inserted, text in self?.moveCursor(target, inserted: inserted, text: text) == true },
      isPresentationFocused: { [weak self] in self?.presentationWindow?.isKeyWindow == true },
      canRestore: { [weak self] in
        guard let self, let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier == self.application?.processIdentifier ||
          (front.processIdentifier == ProcessInfo.processInfo.processIdentifier && self.presentationWindow?.isKeyWindow == true)
      },
      settle: { [weak self] next in self?.awaitReadableHost(polls: Self.settlePolls, next) },
      needsSelectionPreparation: { [weak self] in self?.policyAllowsRanges(replacement: true) == false },
      select: { [weak self] range in
        guard let field = self?.axField() else { return false }
        return Self.axSetSelection(field.element, range: range)
      },
      nextTurn: { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: next) })
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

  private lazy var core: OwlAppSession = try! OwlAppSession("delivery", args: ["source": source.map {
    ["original": $0.originalInput, "marked": $0.markedText, "range": [$0.markedRange.location, $0.markedRange.length], "committed": $0.committed] as [String: Any]
  } as Any? ?? NSNull()])
  private var immediate: Bool { core.call("immediate") }
  private var invalid: Bool { core.call("invalid") }
  private var resultReserved: Bool { core.call("reserved") }

  private struct Effect: Decodable {
    var action: String?
    var token: UInt64?
    var outcome: String?
    var ignored: Bool?
    var text: String?
    var origin: [Int]?
    var replacement: [Int]?
    var target: [Int]?
    var inserted: [Int]?
  }
  private static func nativeRange(_ value: [Int]?) -> NSRange? {
    guard let value, value.count == 2 else { return nil }
    return NSRange(location: value[0], length: value[1])
  }
  private static func wireRange(_ value: NSRange?) -> Any {
    value.map { [$0.location, $0.length] } as Any? ?? NSNull()
  }
  private func facts(read range: NSRange? = nil, planning: Bool = false) -> [String: Any] {
    if invalid { return ["sourceValid": false, "rejection": "targetChanged"] }
    let rejection = access.rejection(immediate)
    let ranges = access.rangeIsCurrent()
    let marked = ranges ? access.marked() : nil
    var facts: [String: Any] = ["sourceValid": source?.isValid() ?? true,
      "rejection": rejection?.rawValue as Any? ?? NSNull(), "revision": access.revision(),
      "ranges": ranges, "marked": Self.wireRange(marked),
      "selection": Self.wireRange(ranges ? access.selection() : nil), "replace": access.canReplace(),
      "needsSelection": access.needsSelectionPreparation()]
    var requested = range
    if planning {
      let raw: [Int]? = core.call("read_range", ["marked": Self.wireRange(marked)])
      requested = Self.nativeRange(raw)
    }
    if ranges, let requested, OwlTemplateCursorPlacement.valid(requested), requested.length <= Self.readLimit,
       let text = access.text(requested), text.utf16.count == requested.length { facts["text"] = text }
    // AX/text queries can reenter. Always finish with the live binding, after every planning read.
    facts["rejection"] = (invalid ? OwlTemplateDeliveryOutcome.Reason.targetChanged : access.rejection(immediate))?.rawValue as Any? ?? NSNull()
    facts["sourceValid"] = source?.isValid() ?? true
    facts["revision"] = access.revision()
    return facts
  }
  /// Final native binding sample occurs after planning reads, before each native effect.
  private func admit(_ kind: String, read range: NSRange? = nil) -> Effect {
    var observation = range.map { facts(read: $0) } ?? [:]
    let rejection = invalid ? OwlTemplateDeliveryOutcome.Reason.targetChanged : access.rejection(immediate)
    observation["kind"] = kind
    observation["sourceValid"] = source?.isValid() ?? true
    observation["rejection"] = rejection?.rawValue as Any? ?? NSNull()
    observation["revision"] = access.revision()
    let effect: Effect = core.call("admit", observation)
    traceEffect("admit_" + kind, effect)
    return effect
  }
  private static func outcome(_ code: String?) -> OwlTemplateDeliveryOutcome {
    switch code {
    case "confirmed": return .confirmed
    case "positioned": return .confirmedWithCursor(.positioned)
    case "leftAtEnd": return .confirmedWithCursor(.leftAtEnd)
    case "positionUnverified": return .confirmedWithCursor(.positionUnverified)
    case "attemptedUnverified": return .attemptedUnverified
    default: return .notAttempted(.init(rawValue: code ?? "") ?? .targetChanged)
    }
  }
  private static func preparation(_ code: String?) -> OwlTemplatePresentationPreparation {
    switch code {
    case "ready": return .ready
    case "originalAttemptedUnverified": return .originalAttemptedUnverified
    default: return .originalNotAttempted(.init(rawValue: code ?? "") ?? .originalNotPreserved)
    }
  }
  func endImmediateDelivery() { let _: Bool = core.call("end_immediate") }
  func invalidate() {
    Self.trace("id=\(ObjectIdentifier(self)) invalidated")
    let _: Bool = core.call("invalidate")
  }
  func mayRestoreFocus() -> Bool {
    core.call("restore", ["sourceValid": source?.isValid() ?? true, "canRestore": access.canRestore()])
  }
  func presentationTransition(window: NSWindow, active: Bool) {
    let accepted: Bool = core.call("presentation", ["active": active])
    if accepted { presentationWindow = window }
  }
  func applicationDidActivate(isOriginal: Bool, isPresentation: Bool) {
    let _: Bool = core.call("application", ["original": isOriginal, "presentation": isPresentation])
  }
  func hostWillDeactivate() {
    let _: Bool = core.call("deactivate", ["canRestore": access.canRestore(), "presentationFocused": access.isPresentationFocused()])
  }
  func hostDidActivate() {
    let _: Bool = core.call("activate", ["sourceValid": source?.isValid() ?? true,
      "rejection": access.rejection(false)?.rawValue as Any? ?? NSNull()])
  }
  func isReadyForDelivery() -> Bool {
    core.call("ready", ["sourceValid": source?.isValid() ?? true,
      "rejection": access.rejection(immediate)?.rawValue as Any? ?? NSNull()])
  }

  func prepareForPresentation() -> OwlTemplatePresentationPreparation {
    var preparation = OwlTemplatePresentationPreparation.originalAttemptedUnverified
    prepareForPresentation { preparation = $0 }
    return preparation
  }
  func prepareForPresentation(completion: @escaping (OwlTemplatePresentationPreparation) -> Void) {
    let effect: Effect = core.call("prepare", facts(planning: true))
    if let code = effect.outcome { completion(Self.preparation(code)); return }
    guard let text = effect.text, let origin = Self.nativeRange(effect.origin) else {
      completion(.originalNotAttempted(.originalNotPreserved)); return
    }
    if let code = admit("original").outcome { completion(Self.preparation(code)); return }
    let dispatched = access.insert(text, nil)
    Self.trace("original_write dispatched=\(dispatched)")
    let receipt: Effect = core.call("write_receipt", ["kind": "original", "dispatched": dispatched])
    traceEffect("original_receipt", receipt)
    guard receipt.ignored != true else { return }
    if let code = receipt.outcome { completion(Self.preparation(code)); return }
    let finish = { [self] in
      let range = OwlTemplateCursorPlacement.insertedRange(text: text, base: origin.location)
      let result: Effect = core.call("prepared", facts(read: range))
      guard result.ignored != true else { return }
      completion(Self.preparation(result.outcome))
    }
    access.settle(finish)
  }

  func deliver(_ result: OwlTemplateInvocation.Result) -> OwlTemplateDeliveryOutcome {
    var outcome = OwlTemplateDeliveryOutcome.attemptedUnverified
    deliver(result) { outcome = $0 }
    return outcome
  }
  func deliver(_ result: OwlTemplateInvocation.Result, completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
    // Stream UTF-8 scalar chunks: expanded output may exceed the bounded request ABI.
    let accepted: Bool = core.call("result_begin", ["cursorOffset": result.cursorOffset as Any? ?? NSNull()])
    guard accepted else { completion(.notAttempted(.targetChanged)); return }
    var chunk = String()
    for scalar in result.text.unicodeScalars {
      chunk.unicodeScalars.append(scalar)
      if chunk.utf8.count >= 65_536 {
        let _: Bool = core.call("result_chunk", ["text": chunk]); chunk = ""
      }
    }
    if !chunk.isEmpty { let _: Bool = core.call("result_chunk", ["text": chunk]) }
    let effect: Effect = core.call("plan", facts(planning: true))
    performDelivery(effect, result: result, completion: completion)
  }

  private func performDelivery(_ effect: Effect, result: OwlTemplateInvocation.Result,
                               completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
    traceEffect("delivery", effect)
    guard effect.ignored != true else { return }
    if let code = effect.outcome { completion(Self.outcome(code)); return }
    let origin = Self.nativeRange(effect.origin)
    switch effect.action {
    case "select":
      guard let origin else { completion(.notAttempted(.selectionNotPrepared)); return }
      if let code = admit("selection", read: origin).outcome { completion(Self.outcome(code)); return }
      let accepted = access.select(origin)
      Self.trace("selection_set accepted=\(accepted)")
      let next: Effect = core.call("selection_set", ["accepted": accepted])
      performDelivery(next, result: result, completion: completion)
    case "wait_selection":
      access.nextTurn { [self] in
        var observation = facts(read: origin)
        observation["token"] = effect.token
        let next: Effect = core.call("selection_poll", observation)
        traceEffect("selection_ack", next)
        performDelivery(next, result: result, completion: completion)
      }
    default:
      if let code = admit("result", read: origin).outcome { completion(Self.outcome(code)); return }
      let replacement = Self.nativeRange(effect.replacement)
      let dispatched = access.insert(result.text, replacement)
      Self.trace("result_write dispatched=\(dispatched) explicit_range=\(replacement != nil)")
      let receipt: Effect = core.call("write_receipt", ["kind": "result", "dispatched": dispatched])
      traceEffect("result_receipt", receipt)
      guard receipt.ignored != true else { return }
      if let code = receipt.outcome { completion(Self.outcome(code)); return }
      guard let origin else { completion(.attemptedUnverified); return }
      verifyDelivery(result, origin: origin, completion: completion)
    }
  }

  private func verifyDelivery(_ result: OwlTemplateInvocation.Result, origin: NSRange,
                              completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
    let verify = { [self] in
      let inserted = OwlTemplateCursorPlacement.insertedRange(text: result.text, base: origin.location)
      let effect: Effect = core.call("verify", facts(read: inserted))
      traceEffect("verify", effect)
      guard effect.ignored != true else { return }
      if let code = effect.outcome { completion(Self.outcome(code)); return }
      guard let target = Self.nativeRange(effect.target), let inserted = Self.nativeRange(effect.inserted) else {
        completion(.confirmedWithCursor(.positionUnverified)); return
      }
      if let code = admit("cursor").outcome { completion(Self.outcome(code)); return }
      let moved = access.move(target, inserted, result.text)
      var observation = facts()
      observation["target"] = Self.wireRange(target); observation["moved"] = moved
      let outcome: Effect = core.call("moved", observation)
      traceEffect("cursor", outcome)
      completion(Self.outcome(outcome.outcome))
    }
    if immediate && controller == nil { verify() } else { access.settle(verify) }
  }

  private func liveRejection(immediate: Bool) -> OwlTemplateDeliveryOutcome.Reason? {
    guard let application, !application.isTerminated else { return .missingHost }
    if !immediate { rebindToActivatedClient(application) }
    guard let controller, let client else { return .missingHost }
    let current = controller.isHandlingKeyEvent ? nil : Self.focusedField(application)
    guard !OwlClientPrivacyState.current().isSecureInputEnabled,
          field?.isSecure != true, current?.isSecure != true else { return .secureInput }
    guard application.isActive,
          let bundle = client.bundleIdentifier(), bundle == application.bundleIdentifier else { return .targetChanged }
    let sameActiveClient = controller.client.map { ($0 as AnyObject) === (client as AnyObject) } ?? false
    if !(immediate && controller.isHandlingKeyEvent && sameActiveClient && generation == controller.templateHostGeneration) {
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
                                            deferRead: Bool = false,
                                            schedule: (@escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: $0) },
                                            store: @escaping (Value) -> Void) {
    if !deferRead, let value = read() { store(value); return }
    trace("host field unreadable during the key event; reading it after the event")
    schedule {
      guard let value = read() else { trace("host field still unreadable after the key event"); return }
      store(value)
    }
  }

  /// The existing opt-in sink receives only phase names, enum outcomes and tokens; never text.
  private func traceEffect(_ phase: String, _ effect: Effect) {
    Self.trace("id=\(ObjectIdentifier(self)) phase=\(phase) action=\(effect.action ?? "none") outcome=\(effect.outcome ?? "none") ignored=\(effect.ignored == true) token=\(effect.token ?? 0)")
  }

  static func trace(_ message: @autoclosure () -> String) {
    OwlLiveInputTrace.write({ "template delivery " + message() })
  }

  /// AX identity, readable UTF-16 coordinates and settable selection are independent facts.
  /// IMK deniedChromiumClient stays intact. Never sample AX while the host waits for a key.
  private func axField() -> Field? {
    guard let client, Self.usesAXFallback(client), controller?.isHandlingKeyEvent != true,
          liveRejection(immediate: false) == nil,
          let field, !field.isSecure else { return nil }
    return field
  }
  static func usesAXFallback(_ client: IMKTextInput) -> Bool {
    let bundle = client.bundleIdentifier()
    let policy = NSApp.owlAppDelegate.clientCapabilityPolicy.evaluate(.init(
      // Chromium is identified by the policy's bundle facts; no filesystem discovery on keys.
      host: .init(bundleID: bundle), privacy: .current(), workarounds: NSApp.owlAppDelegate.clientWorkarounds))
    return OwlAutomaticExpansionScope.rule("ax_fallback", ["selected": policy.selectedRange.reason.rawValue,
      "surrounding": policy.surroundingText.reason.rawValue])
  }
  private func nativeRangesAllowed() -> Bool {
    if policyAllowsRanges() { return liveRangesAllowed() }
    guard let field = axField(), let selection = Self.axSelection(field.element),
          let length = Self.axLength(field.element), NSMaxRange(selection) <= length else { return false }
    return Self.axText(field.element, range: selection) != nil
  }
  private func nativeSelection() -> NSRange? {
    if policyAllowsRanges() { return client?.selectedRange() }
    return axField().flatMap { Self.axSelection($0.element) }
  }
  private func nativeMarked() -> NSRange? {
    if policyAllowsRanges() { return client?.markedRange() }
    // The AX path only starts after our composition has ended or observes committed text.
    guard let controller, controller.preedit.isEmpty, axField() != nil else { return nil }
    return NSRange(location: NSNotFound, length: 0)
  }
  private func nativeText(_ range: NSRange) -> String? {
    if policyAllowsRanges() { return client?.attributedSubstring(from: range)?.string }
    return axField().flatMap { Self.axText($0.element, range: range) }
  }
  private func nativeReplacementAllowed() -> Bool {
    if policyAllowsRanges(replacement: true) { return liveRangesAllowed(replacement: true) }
    guard let field = axField(), nativeRangesAllowed() else { return false }
    return Self.axSelectionSettable(field.element)
  }
  static func axSelectionSettable(_ field: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(field, kAXSelectedTextRangeAttribute as CFString, &settable) == .success && settable.boolValue
  }
  static func axSetSelection(_ field: AXUIElement, range: NSRange) -> Bool {
    var range = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &range) else { return false }
    return AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success
  }
  static func axLength(_ field: AXUIElement) -> Int? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
          let length = value as? Int, length >= 0, length != NSNotFound else { return nil }
    return length
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
    guard !invalid, nativeRangesAllowed(), let application, let field,
          let current = Self.focusedField(application), CFEqual(field.element, current.element),
          client != nil else { Self.trace("cursor: host field or range policy unavailable"); return false }
    guard OwlTemplateCursorPlacement.selectionIsAtEnd(Self.axSelection(field.element), inserted: inserted),
          OwlTemplateCursorPlacement.selectionIsAtEnd(nativeSelection(), inserted: inserted) else {
      Self.trace("cursor: selection is not at the end of the insert"); return false
    }
    guard let axText = Self.axText(field.element, range: inserted), OwlTemplateCursorPlacement.equalText(axText, text) else {
      Self.trace("cursor: accessible text does not match the insert"); return false
    }
    // Check the actual local composed-character boundary, including host neighbors. No full document read.
    let length = policyAllowsRanges() ? (client?.length() ?? NSNotFound) : (Self.axLength(field.element) ?? NSNotFound)
    guard length >= NSMaxRange(inserted), length != NSNotFound else { return false }
    let start = max(0, target.location - 32)
    let count = min(length - start, target.location - start + 32)
    guard let context = Self.axText(field.element, range: NSRange(location: start, length: count)),
          context.utf16.count == count,
          OwlTemplateCursorPlacement.isHostBoundary(target.location - start, in: context,
            startsAtDocumentStart: start == 0), liveRejection(immediate: false) == nil,
          OwlTemplateCursorPlacement.selectionIsAtEnd(Self.axSelection(field.element), inserted: inserted),
          OwlTemplateCursorPlacement.selectionIsAtEnd(nativeSelection(), inserted: inserted) else {
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
          OwlTemplateCursorPlacement.selectionIsAtEnd(nativeSelection(), inserted: inserted),
          AXUIElementSetAttributeValue(field.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
      Self.trace("cursor: setting the host selection failed"); return false
    }
    return Self.axSelection(field.element) == target
  }

  static func axSelection(_ field: AXUIElement) -> NSRange? {
    var reference: CFTypeRef?
    guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &reference) == .success,
          let reference, CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(reference as! AXValue, .cfRange, &range) else { return nil }
    let result = NSRange(location: range.location, length: range.length)
    return OwlTemplateCursorPlacement.valid(result) ? result : nil
  }

  static func axText(_ field: AXUIElement, range: NSRange) -> String? {
    guard OwlTemplateCursorPlacement.valid(range), range.length <= readLimit else { return nil }
    var cfRange = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &cfRange) else { return nil }
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success,
          let text = result as? String, text.utf16.count == range.length else { return nil }
    return text
  }

  static func focusedField(_ application: NSRunningApplication) -> Field? {
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
