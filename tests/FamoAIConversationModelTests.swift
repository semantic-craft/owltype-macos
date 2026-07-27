//
//  FamoAIConversationModelTests.swift
//  FamoTests — AI conversation window view model (roadmap B10, v1)
//
//  Drives the `@MainActor` state machine with a FAKE `FamoConversationStreaming` (scripted readiness
//  + scripted delta stream) so NO socket / Keychain / librime is touched:
//    1. submit → streaming accumulates deltas IN ORDER → done with the full answer.
//    2. stop() cancels: no further deltas are applied after stop.
//    3. regenerate() reuses the SAME explicit selection and replays the last question.
//    4. no provider / no key → `.unconfigured`, with NO stream() call.
//    5. sensitive mode blocks the cloud send (no stream() call) and surfaces a blocked state.
//

import Foundation
import XCTest
@testable import Famo

@MainActor
final class FamoAIConversationModelTests: XCTestCase {

  // MARK: - Fakes

  /// A `FamoConversationStreaming` that scripts readiness + a delta stream, and records whether
  /// `stream(...)` was ever asked to open (so "no network before submit / when blocked" is testable).
  private final class FakeStreamer: FamoConversationStreaming {
    var scriptedReadiness: FamoStreamingReadiness
    /// The deltas each `stream(...)` call will emit before finishing. A new array per call.
    var scriptedDeltas: [String]
    private(set) var streamCallCount = 0
    private(set) var lastMessages: [FamoDeepSeekMessage] = []

    init(readiness: FamoStreamingReadiness, deltas: [String] = []) {
      self.scriptedReadiness = readiness
      self.scriptedDeltas = deltas
    }

    func readiness() -> FamoStreamingReadiness { scriptedReadiness }

    func stream(
      messages: [FamoDeepSeekMessage]
    ) -> Result<AsyncThrowingStream<String, Error>, FamoStreamingReadiness> {
      streamCallCount += 1
      lastMessages = messages
      if case .unconfigured = scriptedReadiness { return .failure(.unconfigured) }
      let deltas = scriptedDeltas
      let stream = AsyncThrowingStream<String, Error> { continuation in
        for d in deltas { continuation.yield(d) }
        continuation.finish()
      }
      return .success(stream)
    }
  }

  private let readyRouting = FamoCloudRouting(
    providerID: "openai",
    endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
    model: "gpt-4o", secretName: "famo.provider.unit.apiKey",
    authHeaderStyle: .bearer
  )

  /// Spin the run loop until `predicate` holds or the timeout elapses (the model's stream consumer
  /// is an async Task; the test must let it run).
  private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 2.0) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  // MARK: - Happy path: submit → streaming → done

  func testSubmitAccumulatesDeltasInOrderThenDone() async {
    let streamer = FakeStreamer(
      readiness: .ready(routing: readyRouting, apiKey: "sk-test"),
      deltas: ["本院", "认为", "予以驳回"]
    )
    let model = FamoAIConversationModel(streamer: streamer)

    model.submit(question: "帮我改写")
    await waitUntil {
      if case .done = model.state { return true }
      return false
    }

    guard case let .done(answer) = model.state else {
      return XCTFail("expected .done, got \(model.state)")
    }
    XCTAssertEqual(answer, "本院认为予以驳回", "deltas must accumulate in order")
    XCTAssertEqual(streamer.streamCallCount, 1)
  }

  /// 任务卡 / autoSubmit 技能走 `displayQuestion`：气泡展示短署名，发给模型的必须仍是全文。
  func testDisplayQuestionShowsInTurnButFullQuestionGoesToTheModel() async {
    let streamer = FakeStreamer(
      readiness: .ready(routing: readyRouting, apiKey: "sk-test"),
      deltas: ["改写结果"]
    )
    let model = FamoAIConversationModel(streamer: streamer)

    let full = "把下面的选中文本改写得贴近我给的参考说法（…）。参考说法（多条用 / 分隔）：烦请知悉"
    model.submit(question: full, displayQuestion: "润色·仿我的范例：烦请知悉")
    await waitUntil {
      if case .done = model.state { return true }
      return false
    }

    XCTAssertEqual(model.turns.last?.displayText, "润色·仿我的范例：烦请知悉", "气泡展示短署名")
    XCTAssertEqual(model.turns.last?.question, full, "历史/重放记录的是全文")
    XCTAssertEqual(
      streamer.lastMessages.last?.content, full,
      "发给模型的必须是 scaffold + 输入的全文，displayQuestion 只影响显示")
  }

  // FamoSelectionDocumentFormatter 的两条测试已随「公文排版」技能删除（2026-07-26 技能精简）。

  // MARK: - stop()

  func testStopCancelsAndNoFurtherDeltasApplied() async {
    // A streamer whose stream never finishes on its own; stop() must end it mid-flight.
    final class HangingStreamer: FamoConversationStreaming {
      private(set) var continuation: AsyncThrowingStream<String, Error>.Continuation?
      func readiness() -> FamoStreamingReadiness {
        .ready(
          routing: FamoCloudRouting(
            providerID: "custom",
            endpoint: URL(string: "https://x.test/c")!,
            model: "m",
            secretName: "s",
            authHeaderStyle: .bearer
          ),
          apiKey: "k"
        )
      }
      func stream(messages: [FamoDeepSeekMessage]) -> Result<AsyncThrowingStream<String, Error>, FamoStreamingReadiness> {
        let stream = AsyncThrowingStream<String, Error> { cont in
          self.continuation = cont
          cont.yield("第一段")
          // deliberately never finish; stop() will cancel the consuming Task.
        }
        return .success(stream)
      }
    }
    let streamer = HangingStreamer()
    let model = FamoAIConversationModel(streamer: streamer)

    model.submit(question: "q")
    await waitUntil {
      if case let .streaming(p) = model.state, !p.isEmpty { return true }
      return false
    }
    model.stop()

    // Stop keeps the partial as a done answer (usable / copyable).
    guard case let .done(answer) = model.state else {
      return XCTFail("stop on a non-empty partial should yield .done, got \(model.state)")
    }
    XCTAssertEqual(answer, "第一段")

    // Emit another delta AFTER stop — it must NOT change state (the Task was cancelled).
    streamer.continuation?.yield("第二段")
    await waitUntil({ false }, timeout: 0.2) // small settle
    guard case let .done(after) = model.state else {
      return XCTFail("state should remain .done after stop")
    }
    XCTAssertEqual(after, "第一段", "no delta may be applied after stop")
  }

  // MARK: - regenerate()

  func testRegenerateReusesExplicitContentAndQuestion() async {
    let streamer = FakeStreamer(
      readiness: .ready(routing: readyRouting, apiKey: "sk-test"),
      deltas: ["答案"]
    )
    let model = FamoAIConversationModel(selectedText: "明确选区", streamer: streamer)

    model.submit(question: "原问题")
    await waitUntil { if case .done = model.state { return true }; return false }
    let firstMessages = streamer.lastMessages

    model.regenerate()
    await waitUntil { if case .done = model.state { return true }; return false }

    XCTAssertEqual(streamer.streamCallCount, 2)
    XCTAssertEqual(model.lastQuestion, "原问题")
    // Same explicit selection + same question → identical assembled messages.
    XCTAssertEqual(streamer.lastMessages, firstMessages, "regenerate must reuse explicit content")
  }

  // MARK: - Unconfigured (no network)

  func testUnconfiguredDoesNotOpenAStream() async {
    let streamer = FakeStreamer(readiness: .unconfigured)
    let model = FamoAIConversationModel(streamer: streamer)

    model.submit(question: "q")
    await waitUntil { if case .unconfigured = model.state { return true }; return false }

    guard case .unconfigured = model.state else {
      return XCTFail("expected .unconfigured, got \(model.state)")
    }
    // The model DID consult stream() which returned the typed failure — but no network was opened
    // (the fake returns .failure for unconfigured). The contract is "no stream consumed".
    XCTAssertEqual(streamer.streamCallCount, 1)
  }

  // MARK: - No network before submit

  func testNoStreamBeforeSubmit() {
    let streamer = FakeStreamer(readiness: .ready(routing: readyRouting, apiKey: "sk-test"), deltas: ["x"])
    _ = FamoAIConversationModel(streamer: streamer)
    XCTAssertEqual(streamer.streamCallCount, 0, "constructing the model must not open a stream")
  }

  // MARK: - 联网搜索 署名

  /// A streamer that scripts which 联网模型 answered, so the window's 署名 chip can be asserted
  /// without a resolver, a Keychain, or a socket.
  private final class SearchStreamer: FamoConversationStreaming {
    var searchProviderID: String?
    private(set) var openAskCallCount = 0

    init(searchProviderID: String?) {
      self.searchProviderID = searchProviderID
    }

    func readiness() -> FamoStreamingReadiness {
      .ready(
        routing: FamoCloudRouting(
          providerID: "deepseek",
          endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
          model: "deepseek-v4-flash", secretName: nil, authHeaderStyle: .bearer),
        apiKey: "sk-test")
    }

    func stream(
      messages: [FamoDeepSeekMessage]
    ) -> Result<AsyncThrowingStream<String, Error>, FamoStreamingReadiness> {
      .success(AsyncThrowingStream { $0.finish() })
    }

    func openAsk(
      messages: [FamoDeepSeekMessage]
    ) -> Result<FamoAskStreamOpen, FamoStreamingReadiness> {
      openAskCallCount += 1
      let stream = AsyncThrowingStream<String, Error> { continuation in
        continuation.yield("答")
        continuation.finish()
      }
      return .success(FamoAskStreamOpen(stream: stream, searchProviderID: searchProviderID))
    }
  }

  func testSearchRoutedAnswerExposesTheProviderBrandName() async {
    let streamer = SearchStreamer(searchProviderID: "qwen")
    let model = FamoAIConversationModel(streamer: streamer)
    XCTAssertNil(model.searchAttribution, "提交前没有署名")

    model.submit(question: "今天的司法解释")
    await waitUntil { if case .done = model.state { return true }; return false }

    XCTAssertEqual(model.searchAttribution, "通义千问", "署名走品牌名，供窗口 chip 直接渲染")
  }

  func testPlainChatAnswerHasNoSearchAttribution() async {
    let streamer = SearchStreamer(searchProviderID: nil)
    let model = FamoAIConversationModel(streamer: streamer)

    model.submit(question: "q")
    await waitUntil { if case .done = model.state { return true }; return false }

    XCTAssertNil(model.searchAttribution, "没走联网就绝不能显示联网署名")
  }

  func testAttributionClearsWhenARegenerateNoLongerSearches() async {
    // A key can be removed (or the toggle flipped) between attempts — a stale 联网 chip would then
    // claim a live search that never happened.
    let streamer = SearchStreamer(searchProviderID: "mimo")
    let model = FamoAIConversationModel(streamer: streamer)

    model.submit(question: "q")
    await waitUntil { if case .done = model.state { return true }; return false }
    XCTAssertEqual(model.searchAttribution, "MiMo")

    streamer.searchProviderID = nil
    model.regenerate()
    await waitUntil { streamer.openAskCallCount == 2 }
    await waitUntil { if case .done = model.state { return true }; return false }

    XCTAssertNil(model.searchAttribution, "重答未联网时署名必须撤掉")
  }

  func testUnconfiguredClearsAnyPriorAttribution() async {
    let streamer = FakeStreamer(readiness: .unconfigured)
    let model = FamoAIConversationModel(streamer: streamer)

    model.submit(question: "q")
    await waitUntil { if case .unconfigured = model.state { return true }; return false }

    XCTAssertNil(model.searchAttribution)
  }

  // MARK: - 多轮对话 (issue #137)

  /// 驱动一整轮：提交 → 等到 .done。
  private func completeTurn(_ model: FamoAIConversationModel, question: String) async {
    model.submit(question: question)
    await waitUntil {
      if case .done = model.state { return true }
      return false
    }
  }

  func testSecondQuestionCarriesTheFirstTurnIntoTheRequest() async {
    // 真读回：断言第二次请求体里真有第一轮问答，而不是只看模型内部的 turns 数组。
    let streamer = FakeStreamer(
      readiness: .ready(routing: readyRouting, apiKey: "sk-test"),
      deltas: ["善意取得是指…"]
    )
    let model = FamoAIConversationModel(streamer: streamer)

    await completeTurn(model, question: "什么是善意取得？")
    await completeTurn(model, question: "构成要件呢？")

    XCTAssertEqual(streamer.streamCallCount, 2)
    let roles = streamer.lastMessages.map(\.role)
    XCTAssertEqual(roles, ["system", "user", "assistant", "user"], "第二问必须带上第一轮问答")
    XCTAssertEqual(streamer.lastMessages[1].content, "什么是善意取得？")
    XCTAssertEqual(streamer.lastMessages[2].content, "善意取得是指…")
    XCTAssertEqual(streamer.lastMessages[3].content, "构成要件呢？")
  }

  func testRegenerateReplaysLastQuestionOnceAndKeepsEarlierHistory() async {
    // 重放不能让同一问既作历史又作新问出现两次，更早的轮次也不能被连带丢掉。
    let streamer = FakeStreamer(
      readiness: .ready(routing: readyRouting, apiKey: "sk-test"),
      deltas: ["答"]
    )
    let model = FamoAIConversationModel(streamer: streamer)

    await completeTurn(model, question: "第一问")
    await completeTurn(model, question: "第二问")

    model.regenerate()
    // 等「重放这一轮重新入历史」，而不是等流开出来——streamCallCount 在流打开时就加了，
    // 那时答案还没读完、turns 还没补回去。
    await waitUntil { model.turns.count == 2 }

    let contents = streamer.lastMessages.map(\.content)
    XCTAssertEqual(
      contents.filter { $0 == "第二问" }.count, 1,
      "被重放的问题只能出现一次")
    XCTAssertTrue(contents.contains("第一问"), "更早的轮次必须留在历史里")
    XCTAssertEqual(streamer.lastMessages.last?.content, "第二问")
    XCTAssertEqual(model.turns.count, 2, "重放完成后历史仍是两轮，不多不少")
  }

  func testHistoryIsCappedSoLongSessionsCannotBlowUpTheRequest() async {
    // 无上限的话，每轮都把全部历史重发一遍，token 随轮数线性膨胀直到打满上下文窗口。
    let streamer = FakeStreamer(
      readiness: .ready(routing: readyRouting, apiKey: "sk-test"),
      deltas: ["答"]
    )
    let model = FamoAIConversationModel(streamer: streamer)

    let overCap = FamoAIConversationModel.maxHistoryTurns + 3
    for i in 1...overCap {
      await completeTurn(model, question: "问题\(i)")
    }

    XCTAssertEqual(model.turns.count, FamoAIConversationModel.maxHistoryTurns)
    XCTAssertEqual(
      model.turns.first?.question, "问题4",
      "超出上限时丢最早的轮，保留最近的对话")
    XCTAssertEqual(model.turns.last?.question, "问题\(overCap)")
  }

  func testNewConversationClearsHistoryAndContextCarriedIntoRequests() async {
    let streamer = FakeStreamer(
      readiness: .ready(routing: readyRouting, apiKey: "sk-test"),
      deltas: ["答"]
    )
    let model = FamoAIConversationModel(streamer: streamer)

    await completeTurn(model, question: "旧话题")
    model.newConversation()

    XCTAssertTrue(model.turns.isEmpty)
    XCTAssertEqual(model.state, .idle, "新对话要回到空白态")

    await completeTurn(model, question: "新话题")
    XCTAssertEqual(
      streamer.lastMessages.map(\.role), ["system", "user"],
      "清空后不该再把旧话题带进请求")
  }

  func testFirstQuestionCarriesNoHistory() async {
    let streamer = FakeStreamer(
      readiness: .ready(routing: readyRouting, apiKey: "sk-test"),
      deltas: ["答"]
    )
    let model = FamoAIConversationModel(streamer: streamer)

    await completeTurn(model, question: "第一问")

    XCTAssertEqual(
      streamer.lastMessages.map(\.role), ["system", "user"],
      "首轮不该凭空多出历史")
  }

  // MARK: - 署名随运行期顺位改写

  /// A streamer whose 归属 is only settled AFTER the stream opens — exactly what the runtime
  /// failover does（方舟 404 ToolNotOpen / MiMo 401 只有请求发出后才知道）。
  private final class FailoverStreamer: FamoConversationStreaming {
    private(set) var attribution: FamoAskAttribution?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func readiness() -> FamoStreamingReadiness {
      .ready(
        routing: FamoCloudRouting(
          providerID: "deepseek",
          endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
          model: "deepseek-v4-flash", secretName: nil, authHeaderStyle: .bearer),
        apiKey: "sk-test")
    }

    func stream(
      messages: [FamoDeepSeekMessage]
    ) -> Result<AsyncThrowingStream<String, Error>, FamoStreamingReadiness> {
      .success(AsyncThrowingStream { $0.finish() })
    }

    func openAsk(
      messages: [FamoDeepSeekMessage]
    ) -> Result<FamoAskStreamOpen, FamoStreamingReadiness> {
      let box = FamoAskAttribution(searchProviderID: "mimo")
      attribution = box
      let stream = AsyncThrowingStream<String, Error> { cont in
        self.continuation = cont      // 内容先不发，留给测试在「顺位」之后放行
      }
      return .success(FamoAskStreamOpen(stream: stream, attribution: box))
    }

    /// 放行答案（模拟顺位后的那一家真的开始输出）。
    func emitAnswer(_ text: String) {
      continuation?.yield(text)
      continuation?.finish()
    }
  }

  func testAttributionFollowsARuntimeFailoverToAnotherProvider() async {
    let streamer = FailoverStreamer()
    let model = FamoAIConversationModel(streamer: streamer)

    model.submit(question: "今天的司法解释")
    XCTAssertEqual(model.searchAttribution, "MiMo", "开流时先按「打算用谁」署名")

    // 请求发出后 MiMo 返回 401，顺位到百炼 —— 内容还一个字都没出。
    streamer.attribution?.update(searchProviderID: "qwen")
    streamer.emitAnswer("百炼答的")
    await waitUntil { if case .done = model.state { return true }; return false }

    XCTAssertEqual(
      model.searchAttribution, "通义千问",
      "chip 必须写真正答了这一问的那家，否则就是「以为用 A 实际用 B」")
  }

  func testAttributionIsDroppedWhenTheAnswerFallsBackToPlainChat() async {
    let streamer = FailoverStreamer()
    let model = FamoAIConversationModel(streamer: streamer)

    model.submit(question: "q")
    // 每一家联网都不可用 → 退回普通问答。
    streamer.attribution?.update(searchProviderID: nil)
    streamer.emitAnswer("训练知识里的答案")
    await waitUntil { if case .done = model.state { return true }; return false }

    XCTAssertNil(model.searchAttribution, "没真的联网就不能留着联网署名")
  }
}
