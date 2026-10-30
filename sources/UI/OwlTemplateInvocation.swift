import AppKit
import Combine

/// One invocation owns the exact selected value (the legacy stores have no revision IDs),
/// captured host/focus, parameter requirements and terminal outcome. No storage reads.
/// Explicit preview/use captures only the requested context, once.
/// Main-thread only, like the IMK controller and its non-activating panels.
final class OwlTemplateInvocation: ObservableObject {
  enum Intent: Equatable { case insert, resultPreview }
  enum Content: Equatable {
    case plainText(String)
    case prompt(OwlPromptEntry)
    case template(OwlTemplateEntry)

    var body: String {
      switch self {
      case .plainText(let text): return text
      case .prompt(let entry): return entry.body
      case .template(let entry): return entry.body
      }
    }
  }

  struct Result: Equatable, Codable {
    let text: String
    // UTF-16 offset in the final expanded text. Never a simulated Return key.
    let cursorOffset: Int?
    init(text: String, cursorOffset: Int? = nil) { self.text = text; self.cursorOffset = cursorOffset }
  }

  enum Cancellation: Equatable { case user, windowClosed, replaced }
  enum State: Equatable {
    case awaitingConfirmation
    case delivering(Result)
    case completed(Result, OwlTemplateDeliveryOutcome)
    case cancelled(Cancellation)
  }

  var retainedResult: Result? {
    switch state {
    case .delivering(let result), .completed(let result, _): return result
    default: return nil
    }
  }
  var outcome: OwlTemplateDeliveryOutcome? {
    if case .completed(_, let outcome) = state { return outcome }
    return nil
  }

  let content: Content
  let variables: [String]
  let parsed: OwlTemplateEngine.Parsed
  private let usesLegacyKeys: Bool
  private let captureContext: (Set<OwlTemplateEngine.Requirement>) -> OwlTemplateEngine.FrozenContext
  private let core: OwlAppSession
  var decisions: OwlTemplateEngine.Decisions { .init(allowEmptyClipboard: core.call("allow_empty")) }
  let objectWillChange = ObservableObjectPublisher()
  private let statePublisher = PassthroughSubject<State, Never>()
  var stateChanges: AnyPublisher<State, Never> { statePublisher.eraseToAnyPublisher() }
  // Publish AFTER the state is stored: a synchronous observer must see the dispatch guard.
  private(set) var state: State = .awaitingConfirmation {
    didSet {
      objectWillChange.send()
      statePublisher.send(state)
    }
  }
  private let broker: OwlPanelInsertionBroker
  /// Writes a result into the host and reports once, possibly after the host has processed it.
  typealias HostDelivery = (Result, @escaping (OwlTemplateDeliveryOutcome) -> Void) -> Void
  private var deliver: HostDelivery?
  private let isHostReady: () -> Bool
  private let mayRestoreFocus: () -> Bool
  private let presentationTransition: ((NSWindow, Bool) -> Void)?
  private let trailingText: String
  let intent: Intent
  private var presentation: ((OwlTemplateInvocation) -> Void)?
  private var preparePresentation: (() -> OwlTemplatePresentationPreparation)?
  private var onFinish: (() -> Void)?
  private(set) var preparationFailure: OwlTemplateDeliveryOutcome?

  /// Shared production wiring. Host refusal is a delivery outcome, not cancellation of the
  /// user's preview: a failed original-text preservation must still retain a copyable result.
  convenience init(content: Content, broker: OwlPanelInsertionBroker, delivery: OwlTemplateHostDelivery,
                   trailingText: String = "", intent: Intent = .insert, prepareAutomaticSource: Bool = false,
                   onFinish: @escaping () -> Void = {},
                   captureContext: @escaping (Set<OwlTemplateEngine.Requirement>) -> OwlTemplateEngine.FrozenContext = { OwlTemplateContextCapture.capture($0) }) {
    let prepare: (() -> OwlTemplatePresentationPreparation)? = prepareAutomaticSource ? {
      broker.capture()
      return delivery.prepareForPresentation()
    } : nil
    self.init(content: content, broker: broker, hostDelivery: { delivery.deliver($0, completion: $1) },
      trailingText: trailingText, intent: intent, isHostReady: { delivery.isReadyForDelivery() },
      mayRestoreFocus: { delivery.mayRestoreFocus() },
      presentationTransition: { delivery.presentationTransition(window: $0, active: $1) },
      preparePresentation: prepare, onFinish: { delivery.invalidate(); onFinish() }, captureContext: captureContext)
  }

  convenience init(content: Content, broker: OwlPanelInsertionBroker, deliver: ((Result) -> OwlTemplateDeliveryOutcome)?,
                   trailingText: String = "", intent: Intent = .insert,
                   isHostReady: @escaping () -> Bool = { true },
                   mayRestoreFocus: @escaping () -> Bool = { true },
                   presentationTransition: ((NSWindow, Bool) -> Void)? = nil,
                   preparePresentation: (() -> OwlTemplatePresentationPreparation)? = nil,
                   onFinish: (() -> Void)? = nil,
                   captureContext: @escaping (Set<OwlTemplateEngine.Requirement>) -> OwlTemplateEngine.FrozenContext = { OwlTemplateContextCapture.capture($0) }) {
    self.init(content: content, broker: broker, hostDelivery: deliver.map { deliver in { $1(deliver($0)) } },
              trailingText: trailingText, intent: intent, isHostReady: isHostReady, mayRestoreFocus: mayRestoreFocus,
              presentationTransition: presentationTransition, preparePresentation: preparePresentation,
              onFinish: onFinish, captureContext: captureContext)
  }

  init(content: Content, broker: OwlPanelInsertionBroker, hostDelivery deliver: HostDelivery?,
       trailingText: String = "", intent: Intent = .insert,
       isHostReady: @escaping () -> Bool = { true },
       mayRestoreFocus: @escaping () -> Bool = { true },
       presentationTransition: ((NSWindow, Bool) -> Void)? = nil,
       preparePresentation: (() -> OwlTemplatePresentationPreparation)? = nil,
       onFinish: (() -> Void)? = nil,
       captureContext: @escaping (Set<OwlTemplateEngine.Requirement>) -> OwlTemplateEngine.FrozenContext = { OwlTemplateContextCapture.capture($0) }) {
    self.content = content
    self.broker = broker
    self.deliver = deliver
    self.isHostReady = isHostReady
    self.mayRestoreFocus = mayRestoreFocus
    self.presentationTransition = presentationTransition
    self.preparePresentation = preparePresentation
    self.onFinish = onFinish
    self.trailingText = trailingText
    self.intent = intent
    self.captureContext = captureContext
    switch content {
    case .plainText(let text):
      parsed = OwlTemplateEngine.parse(body: text, bodyType: .plainText)
      usesLegacyKeys = false
    case .prompt(let entry):
      parsed = OwlTemplateEngine.parse(body: entry.body, syntax: .legacyDoubleBraces)
      usesLegacyKeys = true
    case .template(let entry):
      parsed = OwlTemplateEngine.parse(entry)
      usesLegacyKeys = entry.syntax == .legacyDoubleBraces
    }
    let legacyKeys = usesLegacyKeys
    variables = parsed.parameters.map { legacyKeys ? $0.name : $0.key }
    core = (try? OwlAppSession("invocation", args: ["parsed": OwlAppCore.payload(parsed),
      "body": content.body, "legacy": usesLegacyKeys, "trailing": trailingText,
      "preview": intent == .resultPreview,
      "binding": Self.binding(content: content)])) ?? (try! OwlAppSession("invocation", args: [
        "parsed": OwlAppCore.payload(OwlTemplateEngine.Parsed(diagnostics: [Self.transportFailure])),
        "binding": Self.binding(content: content)]))
  }

  func valueKey(for parameter: OwlTemplateEngine.Parameter) -> String {
    usesLegacyKeys ? parameter.name : parameter.key
  }

  private static func binding(content: Content) -> [String: String] {
    var facts: [String: String] = ["matches": "true"]
    if case .template(let entry) = content {
      facts.merge(OwlAutomaticExpansionRuntime.shared.binding(for: entry)) { _, new in new }
    }
    return facts
  }

  /// Committed library facts are sampled at native boundaries; Rust latches any mismatch.
  @discardableResult
  private func refreshBinding() -> Bool {
    let valid: Bool = core.call("binding", Self.binding(content: content))
    let invalidated: Bool = core.call("invalidated")
    if invalidated, state != .cancelled(.replaced) {
      state = .cancelled(.replaced)
      finishOnce()
      deliver = nil
      presentation = nil
      broker.drop()
    }
    return valid
  }

  private var awaiting: Bool { core.call("awaiting") }

  private static var transportFailure: OwlTemplateEngine.Diagnostic {
    .init(severity: .error, range: NSRange(location: 0, length: 0), message: "模板数据超出处理范围或无法读取，请缩短内容后重试。")
  }

  var initialValues: [String: String] { core.call("initial") }

  /// Native context facts are captured once at Rust's request; Rust retains the frozen values.
  func prepareForResultPreview() {
    guard refreshBinding() else { return }
    let needs: Bool = core.call("needs_context")
    guard needs else { return }
    let context = parsed.contextRequirements.isEmpty ? OwlTemplateEngine.FrozenContext() : captureContext(parsed.contextRequirements)
    guard refreshBinding() else { return }
    do { let _: Bool = try core.request("freeze", OwlTemplateEngine.contextFacts(parsed, context: context)) }
    catch { let _: Bool = core.call("fail") }
  }

  func evaluate(values: [String: String]) -> OwlTemplateEngine.Evaluation {
    prepareForResultPreview()
    return (try? core.request("evaluate", ["values": values])) ?? .init(previewText: content.body + trailingText,
      diagnostics: [Self.transportFailure], missingKeys: [])
  }

  func continueWithEmptyClipboard() {
    let _: Bool = core.call("empty")
  }

  func preview(values: [String: String]) -> Result {
    let evaluation = evaluate(values: values)
    return Result(text: evaluation.previewText, cursorOffset: evaluation.cursorOffset)
  }

  func start(presentFill: @escaping (OwlTemplateInvocation) -> Void) {
    let accepted: Bool = core.call("start")
    guard accepted else { return }
    presentation = presentFill
    _ = evaluate(values: initialValues)
    guard awaiting else { return }
    let immediate: Bool = (try? core.request("immediate", ["values": initialValues])) ?? false
    if immediate {
      confirm(values: initialValues)
    } else {
      let prepare = preparePresentation
      preparePresentation = nil // consume before a possible synchronous client callback
      let canPrepare: Bool = core.call("prepare")
      if canPrepare, let prepare {
        let result = prepare()
        guard awaiting else { return }
        switch result {
        case .ready: break
        case .originalNotAttempted(let reason): preparationFailure = .notAttempted(reason)
        case .originalAttemptedUnverified: preparationFailure = .originalPreservationUnverified
        }
      }
      guard awaiting else { return }
      presentFill(self)
    }
  }

  /// Admission is not delivery success. Occupy the one dispatch slot before restoring focus.
  @discardableResult
  func confirm(values: [String: String]) -> Bool {
    prepareForResultPreview()
    let accepted: Bool = (try? core.request("confirm", ["values": values])) ?? false
    guard accepted else { return false }
    struct Snapshot: Decodable { let result: Result; let generation: UInt64 }
    let snapshot: Snapshot = core.call("snapshot")
    let result = snapshot.result
    state = .delivering(result)
    let failure = preparationFailure
    let host: HostDelivery?
    if let failure { host = { $1(failure) } } else { host = deliver }
    deliver = nil
    if failure != nil { broker.drop() }
    let guardedHost: HostDelivery? = host.map { host in
      { [weak self] result, completion in
        guard let self else { completion(.notAttempted(.targetChanged)); return }
        guard self.refreshBinding() else { completion(.notAttempted(.targetChanged)); return }
        let accepted: Bool = self.core.call("dispatch")
        guard accepted else {
          completion(.notAttempted(.targetChanged)); return
        }
        host(result, completion)
      }
    }
    if !mayRestoreFocus(), failure == nil {
      broker.drop()
      let accepted: Bool = core.call("complete", ["generation": snapshot.generation])
      guard accepted else { return true }
      state = .completed(result, .notAttempted(.targetChanged))
      finishOnce()
      presentation?(self)
      presentation = nil
      return true
    }
    broker.restoreAndDeliver(result, host: guardedHost, isHostReady: isHostReady, isPending: { [weak self] in
      guard let self, self.refreshBinding() else { return false }
      return self.core.call("pending")
    }, completion: { [self] outcome in
      guard refreshBinding() else { return }
      let accepted: Bool = core.call("complete", ["generation": snapshot.generation])
      guard accepted else { return }
      self.state = .completed(result, outcome)
      self.finishOnce()
      if !outcome.finishesPresentation { self.presentation?(self) }
      self.presentation = nil
    })
    return true
  }

  /// This is the only clipboard write exposed by a template invocation.
  @discardableResult
  func copyResult() -> Bool {
    guard case .completed(let result, _) = state else { return false }
    return broker.copyResult(result)
  }

  func notePresentationTransition(window: NSWindow, active: Bool) {
    guard awaiting else { return }
    presentationTransition?(window, active)
  }

  private func finishOnce() {
    let finish = onFinish
    onFinish = nil
    preparePresentation = nil
    finish?()
  }

  func cancel(_ reason: Cancellation = .user, restoreFocus: Bool = true) {
    let accepted: Bool = core.call("cancel")
    guard accepted else { return }
    let shouldRestore = restoreFocus && mayRestoreFocus()
    state = .cancelled(reason)
    finishOnce()
    deliver = nil
    presentation = nil
    if shouldRestore { broker.restoreFocus() } else { broker.drop() }
  }
}
