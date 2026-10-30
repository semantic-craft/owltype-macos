//
//  OwlAIConversationModel.swift
//  猫头鹰输入法 (Owltype) — AI conversation window view model (roadmap B10, v1)
//
//  The `@MainActor` state machine behind `OwlAIWindow`. It keeps only user-explicit text,
//  reports 任意提问 readiness, assembles messages via `OwlAIContextAssembler`, and consumes a
//  streamed answer through the module's small interface. No socket is touched until
//  `submit(question:)`; cancellation and regenerate live here so the SwiftUI view stays a thin
//  render of `state`.
//
//  Reuses (by reference): `OwlAskAnythingOpening` (readiness + answer), `OwlAIContextAssembler`
//  (context assembly). Tests drive it with a scripted fake module — see
//  `tests/OwlAIConversationModelTests.swift`.
//
//  Off the IMK hot path: only an explicit AI-window trigger constructs/drives this.
//

import Foundation

// MARK: - State

/// The conversation's render state. The window switches its controls / body on this.
enum OwlAIConversationState: Equatable {
  /// No question submitted yet (an explicit selection may exist; the window is idle).
  case idle
  /// A question was submitted and deltas are accumulating. The associated value is the answer so far.
  case streaming(partialAnswer: String)
  /// The stream finished. The associated value is the full answer.
  case done(answer: String)
  /// The stream failed (network / HTTP). The associated value is a user-facing message.
  case failed(message: String)
  /// No provider / no key — the window must prompt the user to configure one. No network was touched.
  case unconfigured
}

// MARK: - View model

@MainActor
final class OwlAIConversationModel {
  private let askAnything: OwlAskAnythingOpening
  private let capturedSelectedText: String?
  private let core: OwlAITextSession
  private var projection: Projection
  private var streamTask: Task<Void, Never>?
  private var providerObserver: NSObjectProtocol?
  static let maxHistoryTurns: Int = OwlAIBusinessCore.call("limit", ["id": "history"])
  var onStateChange: ((OwlAIConversationState) -> Void)?

  private struct RenderState: Codable { let kind: String; var text: String? }
  private struct Projection: Decodable {
    let generation: UInt64
    let lastQuestion: String
    let lastDisplayQuestion: String?
    let turns: [OwlConversationTurn]
    let state: RenderState
    let attribution: String?
    let start: Bool
    let accepted: Bool
    let messages: [OwlDeepSeekMessage]
  }
  var lastQuestion: String { projection.lastQuestion }
  var lastDisplayQuestion: String? { projection.lastDisplayQuestion }
  var turns: [OwlConversationTurn] { projection.turns }
  var searchAttribution: String? { projection.attribution }
  var state: OwlAIConversationState {
    switch projection.state.kind {
    case "streaming": return .streaming(partialAnswer: projection.state.text ?? "")
    case "done": return .done(answer: projection.state.text ?? "")
    case "failed": return .failed(message: projection.state.text ?? "")
    case "unconfigured": return .unconfigured
    default: return .idle
    }
  }
  private static func render(_ state: OwlAIConversationState) -> RenderState {
    switch state {
    case .idle: return RenderState(kind: "idle")
    case let .streaming(text): return RenderState(kind: "streaming", text: text)
    case let .done(text): return RenderState(kind: "done", text: text)
    case let .failed(text): return RenderState(kind: "failed", text: text)
    case .unconfigured: return RenderState(kind: "unconfigured")
    }
  }
  init(selectedText: String? = nil, initialState: OwlAIConversationState = .idle,
       askAnything: OwlAskAnythingOpening? = nil) {
    capturedSelectedText = selectedText
    self.askAnything = askAnything ?? OwlAskAnythingModule.shared
    core = try! OwlAITextSession("conversation", args: ["selectedText": selectedText as Any? ?? NSNull(),
      "state": OwlAIBusinessCore.json(Self.render(initialState))])
    projection = core.call("snapshot")
    providerObserver = NotificationCenter.default.addObserver(
      forName: OwlProviderProfileStore.configurationDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.cancelTask()
        self?.transition("providerChanged")
      }
    }
  }
  deinit {
    if let providerObserver { NotificationCenter.default.removeObserver(providerObserver) }
  }
  var capturedContextSummary: String { OwlAIContextAssembler.selectionSummary(capturedSelectedText) }
  func currentReadiness() -> OwlStreamingReadiness { askAnything.readiness() }

  func submit(question: String, displayQuestion: String? = nil) {
    transition("submit", ["question": question, "displayQuestion": displayQuestion as Any? ?? NSNull()])
    if projection.start { start() }
  }
  func regenerate() {
    transition("regenerate")
    if projection.start { start() }
  }
  func stop() { cancelTask(); transition("stop") }
  func teardown() {
    cancelTask()
    if let providerObserver { NotificationCenter.default.removeObserver(providerObserver) }
    providerObserver = nil
    onStateChange = nil
    transition("teardown")
  }
  func replaceState(_ next: OwlAIConversationState) {
    cancelTask(); transition("replace", ["state": OwlAIBusinessCore.json(Self.render(next))])
  }
  func newConversation() { cancelTask(); transition("new") }
  private func cancelTask() { streamTask?.cancel(); streamTask = nil }
  private func transition(_ event: String, _ args: [String: Any] = [:]) {
    projection = core.call(event, args)
    if projection.accepted { onStateChange?(state) }
  }
  private func receive(_ event: String, generation: UInt64, open: OwlAskStreamOpen, text: String = "") {
    let attribution = open.searchProviderID.flatMap(OwlProviderCapabilities.searchDisplayName(providerID:))
    transition(event, ["generation": generation, "text": text, "attribution": attribution as Any? ?? NSNull()])
  }
  /// Task owns only asynchronous effect execution. Every callback is admitted by Rust generation.
  private func start() {
    cancelTask()
    let generation = projection.generation
    let open: OwlAskStreamOpen
    switch askAnything.open(messages: projection.messages) {
    case let .success(value): open = value
    case .failure:
      transition("unconfigured", ["generation": generation]); return
    }
    receive("opened", generation: generation, open: open)
    streamTask = Task { [weak self] in
      do {
        for try await delta in open.stream {
          guard let self, !Task.isCancelled else { return }
          self.receive("delta", generation: generation, open: open, text: delta)
        }
        guard let self, !Task.isCancelled else { return }
        self.receive("complete", generation: generation, open: open)
      } catch {
        guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
        self.receive("failure", generation: generation, open: open, text: OwlCloudPreferences.message(for: error))
      }
    }
  }
}
