//
//  FamoAIConversationModel.swift
//  法墨输入法 (Famo) — AI conversation window view model (roadmap B10, v1)
//
//  The `@MainActor` state machine behind `FamoAIWindow`. It keeps only user-explicit text,
//  resolves provider readiness, assembles messages via
//  `FamoAIContextAssembler`, and consumes a streamed answer from an injected `FamoChatStreaming`
//  façade. No socket is touched until `submit(question:)`; cancellation and regenerate live here
//  so the SwiftUI view stays a thin render of `state`.
//
//  Reuses (by reference): `FamoStreamingChatService` (readiness + stream), `FamoAIContextAssembler`
//  (context assembly). Tests drive it with a scripted fake streamer — see
//  `tests/FamoAIConversationModelTests.swift`.
//
//  Off the IMK hot path: only an explicit AI-window trigger constructs/drives this.
//

import Foundation

// MARK: - Streaming façade seam

/// Narrow port over `FamoStreamingChatService` so the view model can be tested with a fake that
/// scripts readiness + a delta stream — no `URLSession`, no Keychain. The live default is the
/// shared service. Exposes ONLY the two members the window needs (readiness, stream), not the
/// service's profile/key internals (ISP, same idiom as `SnapshotReading` etc.).
@MainActor
protocol FamoConversationStreaming {
  /// Resolve whether a provider + key are configured, with no network (so the window can show an
  /// "unconfigured" state before any send).
  func readiness() -> FamoStreamingReadiness
  /// Stream an answer for `messages`, or the typed readiness failure when nothing is configured.
  func stream(messages: [FamoDeepSeekMessage]) -> Result<AsyncThrowingStream<String, Error>, FamoStreamingReadiness>
  /// 任意提问 entry: like `stream`, but may route through a 联网搜索 provider and reports which one
  /// answered (nil = plain chat).
  func openAsk(messages: [FamoDeepSeekMessage]) -> Result<FamoAskStreamOpen, FamoStreamingReadiness>
}

extension FamoConversationStreaming {
  /// Default = plain chat, no search. The live service overrides this; a fake that doesn't care
  /// about 联网搜索 inherits "never searched" without restating it.
  func openAsk(messages: [FamoDeepSeekMessage]) -> Result<FamoAskStreamOpen, FamoStreamingReadiness> {
    stream(messages: messages).map { FamoAskStreamOpen(stream: $0, searchProviderID: nil) }
  }
}

extension FamoStreamingChatService: FamoConversationStreaming {}

// MARK: - State

/// The conversation's render state. The window switches its controls / body on this.
enum FamoAIConversationState: Equatable {
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
final class FamoAIConversationModel {
  /// The streaming façade (injected; live default is the shared service).
  private let streamer: FamoConversationStreaming

  /// Optional selected text captured by the global selection menu. It is explicit-action context,
  /// sent only when the user picks a menu action, and reused for regenerate.
  private let capturedSelectedText: String?
  /// The last question the user submitted, kept so `regenerate()` can replay it against the same
  /// captured context.
  private(set) var lastQuestion: String = ""
  /// 气泡展示用的最后一问（任务卡把 scaffold 藏起来时展示「任务名：用户补充」而非全文）。
  /// nil = 直接展示 `lastQuestion`。发给模型的永远是 `lastQuestion` 全文。
  private(set) var lastDisplayQuestion: String?

  /// 已完成的问答轮，按序喂回后续请求（issue #137）。上下文包不在此列——它只在装配时注入一次。
  private(set) var turns: [FamoConversationTurn] = []

  /// 历史轮上限。每轮请求都要重发全部历史，不设上限则 token 随轮数线性膨胀直到打满上下文窗口；
  /// 超出时丢最早的轮，保留离当前话题最近的对话。
  static let maxHistoryTurns = 10

  /// 面向用户的联网模型署名（通义千问 / 智谱 / MiMo），或 nil 表示这一问没走联网搜索。Set per submit
  /// (and per regenerate — a route can change between attempts if the user configures a key
  /// mid-conversation), read by the window's 署名 chip.
  private(set) var searchAttribution: String?

  /// Current render state. The view observes this via the `onStateChange` callback.
  private(set) var state: FamoAIConversationState {
    didSet { onStateChange?(state) }
  }
  /// Pushed on every `state` change so the SwiftUI host can re-render. Set by the window.
  var onStateChange: ((FamoAIConversationState) -> Void)?

  /// The in-flight stream consumer, so `stop()` / a new `submit` can cancel it.
  private var streamTask: Task<Void, Never>?

  /// `streamer` defaults to nil → the shared service is resolved INSIDE the (`@MainActor`) init, so
  /// the `@MainActor`-isolated `.shared` is never referenced from the nonisolated default-argument
  /// context (Swift 6-clean; same `client: … ? = nil` idiom as `FamoStreamingChatService`).
  init(
    selectedText: String? = nil,
    initialState: FamoAIConversationState = .idle,
    streamer: FamoConversationStreaming? = nil
  ) {
    self.capturedSelectedText = selectedText
    self.state = initialState
    self.streamer = streamer ?? FamoStreamingChatService.shared
  }

  /// A short one-line summary of the explicit selection shown in the window header.
  var capturedContextSummary: String {
    return FamoAIContextAssembler.selectionSummary(capturedSelectedText)
  }

  /// Resolve the provider route for the window's header ("local / cloud / unconfigured"). No network.
  func currentReadiness() -> FamoStreamingReadiness {
    streamer.readiness()
  }

  /// Submit a question. Resolves readiness FIRST (no network if unconfigured), assembles messages,
  /// then consumes the delta stream into `state`. Cancels any prior stream.
  /// `displayQuestion`: 气泡展示用的短文本（任务卡 / autoSubmit 技能）；nil = 展示全文。
  func submit(question: String, displayQuestion: String? = nil) {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    lastQuestion = trimmed
    lastDisplayQuestion = displayQuestion
    start(question: trimmed)
  }

  /// 重放最后一问，明确选中的文本与更早的历史都保持不变。
  ///
  /// 摘掉最后一轮是必须的：那一问已经作为历史留在 `turns` 里，不摘就会既当历史、又当新问题
  /// 出现两次，模型会看到自己刚答过的问题被重复提问。重放成功后 `finish` 会把它加回去。
  func regenerate() {
    guard !lastQuestion.isEmpty else { return }
    if turns.last?.question == lastQuestion { turns.removeLast() }
    start(question: lastQuestion)
  }

  /// Cancel the in-flight stream. Whatever was accumulated becomes the `done` answer (so a partial
  /// answer the user stopped is still usable / copyable); an empty partial returns to `idle`.
  func stop() {
    streamTask?.cancel()
    streamTask = nil
    if case let .streaming(partial) = state {
      if partial.isEmpty {
        state = .idle
      } else {
        finish(answer: partial)
      }
    }
  }

  /// Tear down on window close — cancel any in-flight stream and drop the callback retain.
  func teardown() {
    streamTask?.cancel()
    streamTask = nil
    onStateChange = nil
  }

  func replaceState(_ next: FamoAIConversationState) {
    streamTask?.cancel()
    streamTask = nil
    state = next
  }

  // MARK: - Private

  /// 收束一轮：落 `.done` 并把这轮问答记进历史。正常读完、报错但已有部分答案、用户 stop() 三条
  /// 路径都汇到这里——凡是用户在窗口里看得见的答案，就必须进历史，否则下一轮的上下文与屏幕
  /// 上显示的对话对不上。
  private func finish(answer: String) {
    state = .done(answer: answer)
    guard !lastQuestion.isEmpty, !answer.isEmpty else { return }
    turns.append(FamoConversationTurn(
      question: lastQuestion, answer: answer, displayQuestion: lastDisplayQuestion))
    if turns.count > Self.maxHistoryTurns {
      turns.removeFirst(turns.count - Self.maxHistoryTurns)
    }
  }

  /// 开一段新对话：清空历史与最后一问，回到空白态。窗口由划词入口打开时，用户明确选中的
  /// 文本仍保持不变。
  func newConversation() {
    streamTask?.cancel()
    streamTask = nil
    turns.removeAll()
    lastQuestion = ""
    lastDisplayQuestion = nil
    searchAttribution = nil
    state = .idle
  }

  private func start(question: String) {
    // Cancel any prior in-flight stream before starting a new one.
    streamTask?.cancel()
    streamTask = nil

    // Assemble messages from explicit user content only.
    let messages = FamoAIContextAssembler.assemble(
      selectedText: capturedSelectedText,
      history: turns,
      question: question
    )

    // Resolve a stream. `unconfigured` / `missingKey` produce NO network call. `openAsk` may route
    // through a 联网搜索 provider; when none is configured it silently falls back to plain chat.
    let stream: AsyncThrowingStream<String, Error>
    switch streamer.openAsk(messages: messages) {
    case let .success(open):
      stream = open.stream
      searchAttribution = open.searchProviderID.flatMap(FamoSearchControl.displayName(for:))
    case .failure:
      searchAttribution = nil
      state = .unconfigured
      return
    }

    state = .streaming(partialAnswer: "")
    streamTask = Task { [weak self] in
      do {
        for try await delta in stream {
          guard let self else { return }
          if Task.isCancelled { return }
          // Accumulate in order. Only fold a delta in while still streaming (a stop() may have
          // already transitioned us away).
          if case let .streaming(partial) = self.state {
            self.state = .streaming(partialAnswer: partial + delta)
          }
        }
        guard let self, !Task.isCancelled else { return }
        if case let .streaming(partial) = self.state {
          self.finish(answer: partial)
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        // A cancellation is not a user-facing failure — stop() already moved state.
        if error is CancellationError { return }
        let partial: String
        if case let .streaming(p) = self.state { partial = p } else { partial = "" }
        // Keep any partial answer the user already received; surface the failure too.
        if partial.isEmpty {
          self.state = .failed(message: FamoCloudPreferences.message(for: error))
        } else {
          self.finish(answer: partial)
        }
      }
    }
  }
}
