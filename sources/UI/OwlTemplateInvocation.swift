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

  struct Result: Equatable {
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
  private var frozenContext: OwlTemplateEngine.FrozenContext?
  private(set) var decisions = OwlTemplateEngine.Decisions()
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
  private var started = false
  /// Writes a result into the host and reports once, possibly after the host has processed it.
  typealias HostDelivery = (Result, @escaping (OwlTemplateDeliveryOutcome) -> Void) -> Void
  private var deliver: HostDelivery?
  private let isHostReady: () -> Bool
  private let mayRestoreFocus: () -> Bool
  private let presentationTransition: ((NSWindow, Bool) -> Void)?
  private let trailingText: String
  let intent: Intent
  private var presentation: ((OwlTemplateInvocation) -> Void)?
  private var dispatchStarted = false
  private var preparePresentation: (() -> OwlTemplatePresentationPreparation)?
  private var onFinish: (() -> Void)?
  private(set) var preparationFailure: OwlTemplateDeliveryOutcome?

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
  }

  func valueKey(for parameter: OwlTemplateEngine.Parameter) -> String {
    usesLegacyKeys ? parameter.name : parameter.key
  }

  var initialValues: [String: String] {
    var values: [String: String] = [:]
    for parameter in parsed.parameters {
      if let value = parsed.initialValues[parameter.key] { values[valueKey(for: parameter)] = value }
    }
    return values
  }

  /// Called only for an explicit result preview/use; search and raw-body preview never call it.
  func prepareForResultPreview() {
    guard state == .awaitingConfirmation, frozenContext == nil,
          !parsed.diagnostics.contains(where: { $0.severity == .error }) else { return }
    let context = parsed.contextRequirements.isEmpty ? OwlTemplateEngine.FrozenContext() : captureContext(parsed.contextRequirements)
    guard state == .awaitingConfirmation else { return }
    frozenContext = context
  }

  func evaluate(values: [String: String]) -> OwlTemplateEngine.Evaluation {
    guard state == .awaitingConfirmation else {
      let text: String
      if let result = retainedResult { text = result.text } else { text = content.body + trailingText }
      return .init(previewText: text, diagnostics: [
        .init(severity: .error, range: NSRange(location: 0, length: 0), message: "本次调用已结束，请重新调用模板。")
      ], missingKeys: [])
    }
    prepareForResultPreview()
    var keyed: [String: String] = [:]
    for parameter in parsed.parameters {
      if let value = values[valueKey(for: parameter)] { keyed[parameter.key] = value }
    }
    let evaluation = OwlTemplateEngine.render(parsed, values: keyed, context: frozenContext ?? .init(), decisions: decisions)
    let text = evaluation.previewText + trailingText
    var diagnostics = evaluation.diagnostics
    if let offset = evaluation.cursorOffset, evaluation.readyText != nil,
       !OwlTemplateCursorPlacement.isBoundary(offset, in: text) {
      diagnostics.append(.init(severity: .error, range: NSRange(location: 0, length: 0),
        message: "光标位置与保留的分隔符组成同一字符，请调整模板。"))
    }
    return .init(previewText: text, diagnostics: diagnostics, missingKeys: evaluation.missingKeys,
      needsEmptyClipboardDecision: evaluation.needsEmptyClipboardDecision, cursorOffset: evaluation.cursorOffset)
  }

  /// A decision applies only to already captured missing text; never starts a new capture.
  func continueWithEmptyClipboard() {
    guard state == .awaitingConfirmation, let clipboard = frozenContext?.clipboard else { return }
    switch clipboard {
    case .empty, .nonText, .text(""): decisions.allowEmptyClipboard = true
    case .notRequested, .text: break
    }
  }

  func preview(values: [String: String]) -> Result {
    let evaluation = evaluate(values: values)
    return Result(text: evaluation.previewText, cursorOffset: evaluation.cursorOffset)
  }

  func start(presentFill: @escaping (OwlTemplateInvocation) -> Void) {
    guard state == .awaitingConfirmation, !started else { return }
    started = true
    presentation = presentFill
    let evaluation = evaluate(values: initialValues)
    guard state == .awaitingConfirmation else { return }
    if intent == .insert && parsed.parameters.isEmpty && evaluation.diagnostics.isEmpty && evaluation.readyText != nil {
      confirm(values: initialValues)
    } else {
      let prepare = preparePresentation
      preparePresentation = nil // consume before a possible synchronous client callback
      if !parsed.diagnostics.contains(where: { $0.severity == .error }), let prepare {
        let result = prepare()
        guard state == .awaitingConfirmation else { return }
        switch result {
        case .ready: break
        case .originalNotAttempted(let reason): preparationFailure = .notAttempted(reason)
        case .originalAttemptedUnverified: preparationFailure = .originalPreservationUnverified
        }
      }
      guard state == .awaitingConfirmation else { return }
      presentFill(self)
    }
  }

  /// Admission is not delivery success. Occupy the one dispatch slot before restoring focus.
  @discardableResult
  func confirm(values: [String: String]) -> Bool {
    guard state == .awaitingConfirmation else { return false }
    let evaluation = evaluate(values: values)
    guard let text = evaluation.readyText, state == .awaitingConfirmation else { return false }
    let result = Result(text: text, cursorOffset: evaluation.cursorOffset)
    state = .delivering(result)
    frozenContext = nil
    let failure = preparationFailure
    let host: HostDelivery?
    if let failure { host = { $1(failure) } } else { host = deliver }
    deliver = nil
    if failure != nil { broker.drop() }
    let guardedHost: HostDelivery? = host.map { host in
      { [weak self] result, completion in
        guard let self, case .delivering = self.state, !self.dispatchStarted else {
          completion(.notAttempted(.targetChanged)); return
        }
        self.dispatchStarted = true
        host(result, completion)
      }
    }
    if !mayRestoreFocus(), failure == nil {
      broker.drop()
      state = .completed(result, .notAttempted(.targetChanged))
      finishOnce()
      presentation?(self)
      presentation = nil
      return true
    }
    broker.restoreAndDeliver(result, host: guardedHost, isHostReady: isHostReady, isPending: { [weak self] in
      guard let self, case .delivering = self.state else { return false }
      return !self.dispatchStarted
    }, completion: { [self] outcome in
      guard case .delivering = state else { return }
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
    guard state == .awaitingConfirmation else { return }
    presentationTransition?(window, active)
  }

  private func finishOnce() {
    let finish = onFinish
    onFinish = nil
    preparePresentation = nil
    finish?()
  }

  func cancel(_ reason: Cancellation = .user, restoreFocus: Bool = true) {
    switch state {
    case .awaitingConfirmation: break
    case .delivering where !dispatchStarted: break
    default: return
    }
    let shouldRestore = restoreFocus && mayRestoreFocus()
    state = .cancelled(reason)
    finishOnce()
    frozenContext = nil
    deliver = nil
    presentation = nil
    if shouldRestore { broker.restoreFocus() } else { broker.drop() }
  }
}
