//
//  OwlStreamingChatClientTests.swift
//  OwltypeTests — OpenAI-compatible STREAMING chat transport (roadmap B9, streaming half)
//
//  Locks the streaming transport contracts with NO socket and NO real Keychain/store:
//    1. `OwlSSEChatParser` (the pure core): single delta; multiple ordered; `[DONE]` ends;
//       a delta split across two chunks reassembles; comment / blank / role-only / empty-delta
//       lines are ignored without error; a malformed-JSON `data:` line is skipped (not fatal).
//    2. `OwlStreamingChatClient` driven by an INJECTED scripted byte source: emits the expected
//       ordered deltas and finishes; a non-2xx status finishes with `OwlStreamingError.badHTTPStatus`.
//    3. `OwlStreamingChatService.readiness()`: no-default-profile + no-key → `.unconfigured`;
//       a profile with no stored key → `.missingKey`; a resolvable key → `.ready` (no network).
//
//  No network, no librime.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlStreamingChatClientTests: XCTestCase {

  // MARK: - Pure SSE parser

  func testParserSingleDeltaYieldsContent() {
    var parser = OwlSSEChatParser()
    let deltas = parser.consume(#"data: {"choices":[{"delta":{"content":"本"}}]}"# + "\n\n")
    XCTAssertEqual(deltas, ["本"])
    XCTAssertFalse(parser.isFinished)
  }

  func testParserMultipleEventsYieldInOrder() {
    var parser = OwlSSEChatParser()
    let body = [
      #"data: {"choices":[{"delta":{"content":"本"}}]}"#,
      "",
      #"data: {"choices":[{"delta":{"content":"院"}}]}"#,
      "",
      #"data: {"choices":[{"delta":{"content":"认为"}}]}"#,
      "",
    ].joined(separator: "\n") + "\n"
    let deltas = parser.consume(body)
    XCTAssertEqual(deltas, ["本", "院", "认为"])
  }

  func testParserDoneEndsTheStream() {
    var parser = OwlSSEChatParser()
    _ = parser.consume(#"data: {"choices":[{"delta":{"content":"甲"}}]}"# + "\n")
    let tail = parser.consume("data: [DONE]\n\n")
    XCTAssertTrue(tail.isEmpty)
    XCTAssertTrue(parser.isFinished)
    // After [DONE] further input is ignored.
    let after = parser.consume(#"data: {"choices":[{"delta":{"content":"乙"}}]}"# + "\n")
    XCTAssertTrue(after.isEmpty)
  }

  func testParserReassemblesDeltaSplitAcrossTwoChunks() {
    var parser = OwlSSEChatParser()
    // First chunk cuts the data line mid-JSON; nothing is complete yet.
    let first = parser.consume(#"data: {"choices":[{"delta":{"con"#)
    XCTAssertTrue(first.isEmpty, "an incomplete line must not emit or error")
    // Second chunk completes the line.
    let second = parser.consume(#"tent":"裁定"}}]}"# + "\n\n")
    XCTAssertEqual(second, ["裁定"])
  }

  func testParserReassemblesEventSplitAtLineBoundary() {
    var parser = OwlSSEChatParser()
    // Split exactly at the newline between the data line and its blank separator.
    let first = parser.consume(#"data: {"choices":[{"delta":{"content":"管辖"}}]}"#)
    XCTAssertTrue(first.isEmpty, "no trailing newline yet → still buffered")
    let second = parser.consume("\n\n")
    XCTAssertEqual(second, ["管辖"])
  }

  func testParserIgnoresCommentBlankAndRoleOnlyAndEmptyDeltaLines() {
    var parser = OwlSSEChatParser()
    let body = [
      ": this is an SSE keepalive comment",
      "",
      #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,   // role-only first chunk
      "",
      #"data: {"choices":[{"delta":{"content":""}}]}"#,          // empty-delta chunk
      "",
      #"data: {"choices":[{"delta":{"content":"驳回"}}]}"#,      // the only real delta
      "",
      #"data: {"choices":[{"finish_reason":"stop","delta":{}}]}"#, // finish-only chunk
      "",
    ].joined(separator: "\n") + "\n"
    let deltas = parser.consume(body)
    XCTAssertEqual(deltas, ["驳回"], "comments / blanks / role-only / empty / finish-only are ignored without error")
    XCTAssertFalse(parser.isFinished)
  }

  func testParserSkipsMalformedJSONLineWithoutCrashing() {
    var parser = OwlSSEChatParser()
    let body = [
      #"data: {"choices":[{"delta":{"content":"上诉"#,   // truncated / malformed JSON (line complete)
      "",
      #"data: {"choices":[{"delta":{"content":"成立"}}]}"#,
      "",
    ].joined(separator: "\n") + "\n"
    let deltas = parser.consume(body)
    XCTAssertEqual(deltas, ["成立"], "a malformed data line is skipped, the next valid one still emits")
  }

  func testParserHandlesCRLFFraming() {
    var parser = OwlSSEChatParser()
    let body = #"data: {"choices":[{"delta":{"content":"诉讼"}}]}"# + "\r\n\r\n"
    XCTAssertEqual(parser.consume(body), ["诉讼"])
  }

  func testParserFinishFlushesTrailingLineWithoutNewline() {
    var parser = OwlSSEChatParser()
    // Endpoint omits the final newline; consume buffers it, finish() flushes it.
    let mid = parser.consume(#"data: {"choices":[{"delta":{"content":"终审"}}]}"#)
    XCTAssertTrue(mid.isEmpty)
    XCTAssertEqual(parser.finish(), ["终审"])
  }

  // MARK: - Streaming client (injected scripted byte source — no socket)

  /// Build a `OwlStreamingChatClient` whose byte source replays scripted text chunks + a chosen
  /// HTTP status, instead of opening a real `URLSession.bytes`.
  private func makeClient(status: Int, chunks: [String]) -> OwlStreamingChatClient {
    OwlStreamingChatClient(bytesProvider: { _ in
      let http = HTTPURLResponse(
        url: URL(string: "https://api.openai.com/v1/chat/completions")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
      )
      let stream = AsyncThrowingStream<String, Error> { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }
      return OwlStreamingBytesSource(response: http, chunks: stream)
    })
  }

  private func makeRouting() -> OwlCloudRouting {
    OwlCloudRouting(
      providerID: "openai",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      secretName: "owltype.provider.unit.apiKey",
      authHeaderStyle: .bearer
    )
  }

  private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var out: [String] = []
    for try await delta in stream { out.append(delta) }
    return out
  }

  func testClientEmitsOrderedDeltasAndFinishes() async throws {
    let client = makeClient(status: 200, chunks: [
      #"data: {"choices":[{"delta":{"role":"assistant"}}]}"# + "\n\n",
      #"data: {"choices":[{"delta":{"content":"本院"}}]}"# + "\n\n",
      #"data: {"choices":[{"delta":{"content":"认为"}}]}"# + "\n\n",
      "data: [DONE]\n\n",
    ])
    let deltas = try await collect(client.stream(messages: [], routing: makeRouting(), apiKey: "sk-test"))
    XCTAssertEqual(deltas, ["本院", "认为"])
  }

  func testClientReassemblesDeltaSplitAcrossNetworkChunks() async throws {
    // Same delta arrives in two transport chunks; the client must re-frame via the parser.
    let client = makeClient(status: 200, chunks: [
      #"data: {"choices":[{"delta":{"content":"裁"#,
      #"定书"}}]}"# + "\n\n",
      "data: [DONE]\n\n",
    ])
    let deltas = try await collect(client.stream(messages: [], routing: makeRouting(), apiKey: "sk-test"))
    XCTAssertEqual(deltas, ["裁定书"])
  }

  func testClientNon2xxFinishesWithBadHTTPStatus() async {
    let client = makeClient(status: 429, chunks: [])
    do {
      _ = try await collect(client.stream(messages: [], routing: makeRouting(), apiKey: "sk-test"))
      XCTFail("a non-2xx status must finish the stream with an error")
    } catch let error as OwlStreamingError {
      XCTAssertEqual(error, .badHTTPStatus(429))
    } catch {
      XCTFail("expected OwlStreamingError.badHTTPStatus, got \(error)")
    }
  }

  // MARK: - Request body (关思考 extras merged onto the wire)

  /// Capture the `URLRequest` the client builds, without opening a socket. The scripted source
  /// finishes immediately; we only care about what was about to be sent.
  private func captureRequestBody(
    routing: OwlCloudRouting
  ) async throws -> [String: Any] {
    let box = RequestBox()
    let client = OwlStreamingChatClient(bytesProvider: { request in
      await box.set(request)
      return OwlStreamingBytesSource(
        response: HTTPURLResponse(
          url: routing.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil),
        chunks: AsyncThrowingStream { $0.finish() })
    })
    _ = try await collect(
      client.stream(messages: [], routing: routing, apiKey: "sk-test"))
    guard let body = await box.get()?.httpBody,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      XCTFail("expected a JSON request body")
      return [:]
    }
    return object
  }

  func testPlainChatBodyCarriesNoSearchFields() async throws {
    let object = try await captureRequestBody(routing: makeRouting())
    XCTAssertEqual(object["model"] as? String, "gpt-4o")
    XCTAssertEqual(object["stream"] as? Bool, true)
    XCTAssertEqual(object["temperature"] as? Double, 0.2)
    XCTAssertNil(object["enable_search"], "普通问答绝不带联网字段")
    XCTAssertNil(object["tools"])
  }

  func testGemini38StreamOmitsSamplingParameters() async throws {
    let routing = OwlCloudRouting(
      providerID: "gemini",
      endpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!,
      model: "gemini-3.8-flash", secretName: nil, authHeaderStyle: .bearer)
    let body = try await captureRequestBody(routing: routing)
    XCTAssertNil(body["temperature"])
    XCTAssertNil(body["top_p"])
    XCTAssertNil(body["top_k"])
    XCTAssertNil(body["thinking_level"])
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["model"] as? String, routing.model)
    XCTAssertNotNil(body["messages"])
  }

  // MARK: - 强制关思考（`OwlThinkingControl`）

  /// 设置页写着「任意提问一律强制关闭深度思考」。这条断言那句话在**普通问答**上也成立 ——
  /// 之前只有划词链路和豆包的联网请求关了，任意提问的主链路一个字段都没带。
  func testPlainAskForcesThinkingOffForEveryKnownProvider() async throws {
    func routing(_ id: String, _ model: String, _ host: String) -> OwlCloudRouting {
      OwlCloudRouting(
        providerID: id,
        endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
        model: model,
        secretName: "owltype.provider.\(id).apiKey",
        authHeaderStyle: .bearer
      )
    }

    for (id, model, host) in [
      ("deepseek", "deepseek-v4-flash", "api.deepseek.com"),
      ("doubao", "doubao-seed-2-1-turbo-260628", "ark.cn-beijing.volces.com"),
    ] {
      let object = try await captureRequestBody(routing: routing(id, model, host))
      XCTAssertEqual((object["thinking"] as? [String: Any])?["type"] as? String, "disabled",
                     "\(id) 的普通问答也必须关思考")
    }

  }

  /// OpenAI 在 `/chat/completions` 上没有思考开关：请求体必须逐字节不变，不能凭空多字段。
  func testUnknownThinkingSwitchLeavesBodyUntouched() async throws {
    let object = try await captureRequestBody(routing: makeRouting())
    XCTAssertNil(object["thinking"])
    XCTAssertNil(object["enable_thinking"])
  }

  func testMiniMaxStreamUsesLowReasoningAndOnlyEmitsAnswer() async throws {
    let routing = OwlCloudRouting(
      providerID: "minimax", endpoint: URL(string: "https://api.minimax.cn/v1/chat/completions")!,
      model: "MiniMax-M3.1-Flash", secretName: nil, authHeaderStyle: .bearer)
    let body = try await captureRequestBody(routing: routing)
    XCTAssertEqual(body["reasoning_effort"] as? String, "low")
    XCTAssertEqual(body["reasoning_split"] as? Bool, true)
    XCTAssertNil(body["thinking"])
    var parser = OwlSSEChatParser()
    let deltas = parser.consume("""
      data: {"choices":[{"delta":{"reasoning_content":"private reasoning"}}]}
      data: {"choices":[{"delta":{"content":"最终答案"}}]}
      data: [DONE]

      """)
    XCTAssertEqual(deltas, ["最终答案"])
  }

  // MARK: - High-level service readiness (no network)

  @MainActor
  func testServiceReadyWithActiveProfileAndKey() {
    let profile = OwlProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      secretName: "owltype.provider.unit.apiKey",
      isDefault: true
    )
    let service = OwlStreamingChatService(
      client: NeverStreamingClient(),
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-profile-key" },
      legacyKeyProvider: { XCTFail("active profile must not read the legacy key"); return nil }
    )
    guard case let .ready(routing, apiKey) = service.readiness() else {
      return XCTFail("a profile with a stored key must be .ready")
    }
    XCTAssertEqual(routing.model, "gpt-4o")
    XCTAssertEqual(apiKey, "sk-profile-key")
  }

  @MainActor
  func testServiceUnconfiguredWhenNoProfileAndNoLegacyKey() {
    let service = OwlStreamingChatService(
      client: NeverStreamingClient(),
      profileProvider: { nil },
      profileSecretProvider: { _ in XCTFail("no profile → per-profile secret reader unused"); return nil },
      legacyKeyProvider: { nil }
    )
    XCTAssertEqual(service.readiness(), .unconfigured)
    // And stream(...) returns the typed failure rather than opening anything.
    if case .success = service.stream(messages: []) {
      XCTFail("unconfigured must not produce a stream")
    }
  }

  @MainActor
  func testServiceMissingKeyWhenProfileHasNoStoredSecret() {
    let profile = OwlProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      secretName: "owltype.provider.unit.apiKey",
      isDefault: true
    )
    let service = OwlStreamingChatService(
      client: NeverStreamingClient(),
      profileProvider: { profile },
      profileSecretProvider: { _ in nil },   // profile active but no key stored yet
      legacyKeyProvider: { XCTFail("active profile must not read the legacy key"); return nil }
    )
    XCTAssertEqual(service.readiness(), .missingKey)
  }

  // MARK: - 任意提问 module transport dispatch (no network)

  /// A module whose 联网搜索 resolves to `providerID` at `host`, with both transports' clients
  /// recording which one was actually asked to stream.
  @MainActor
  private func makeDispatchModule(
    providerID: String,
    host: String,
    chat: RecordingChatClient,
    responses: RecordingResponsesClient,
    searchEnabled: Bool = true
  ) -> OwlAskAnythingModule {
    let model: String
    switch providerID {
    case "qwen": model = "qwen3.7-plus"
    // 豆包的 plain 传输按「providerID/模型前缀 + host」判方言（OwlResponsesWire.dialect），
    // 得用真实型号名才能覆盖到那条判定。
    case "doubao": model = "doubao-seed-2-1-pro-260628"
    // DeepSeek 的方言判定卡型号（`/responses` 目前只收 deepseek-v4-flash），同样得用真实型号名。
    case "deepseek": model = "deepseek-v4-flash"
    default: model = "m"
    }
    let profile = OwlProviderProfile(
      id: providerID,
      displayName: providerID,
      endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
      model: model,
      providerID: providerID,
      secretName: "owltype.provider.\(providerID).apiKey",
      isDefault: true
    )
    return OwlAskAnythingModule(
      client: chat,
      responsesClient: responses,
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      searchResolver: OwlAskSearchResolver(
        isEnabled: { searchEnabled },
        profilesProvider: { [profile] },
        defaultProfileProvider: { profile },
        secretProvider: { _ in "sk-key" }
      )
    )
  }

  @MainActor
  func testQwenNeverSearchesEvenWhenAskSearchIsOn() {
    // 任意提问联网只走 DeepSeek：千问是默认供应商时，开着联网也只做它的普通 Responses 生成。
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchModule(
      providerID: "qwen", host: "dashscope.aliyuncs.com", chat: chat, responses: responses)
    guard case let .success(open) = service.open(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertNil(open.searchProviderID)
    XCTAssertEqual(responses.callCount, 1)
    XCTAssertEqual(responses.lastDialect, .qwen)
    XCTAssertEqual(responses.lastWebSearch, false)
    XCTAssertEqual(chat.callCount, 0)
  }

  @MainActor
  func testPlainQwenGenerationAlsoUsesResponsesWithoutSearch() {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchModule(
      providerID: "qwen", host: "dashscope.aliyuncs.com", chat: chat, responses: responses,
      searchEnabled: false)
    guard case .success = service.open(
      messages: [OwlDeepSeekMessage(role: "user", content: "你好")]) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(responses.callCount, 1)
    XCTAssertEqual(responses.lastDialect, .qwen)
    XCTAssertEqual(responses.lastWebSearch, false)
    XCTAssertEqual(chat.callCount, 0)
  }

  @MainActor
  func testPlainDoubaoGenerationAlsoUsesResponsesWithoutSearch() {
    // 2026-07-31 起 豆包 与 Qwen 一样全面走 Responses：普通生成也不许退回 chat/completions，
    // 否则 store=false 与 thinking:{disabled} 全部丢失（方舟 Responses 默认存响应且开思考）。
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchModule(
      providerID: "doubao", host: "ark.cn-beijing.volces.com", chat: chat, responses: responses,
      searchEnabled: false)
    guard case .success = service.open(
      messages: [OwlDeepSeekMessage(role: "user", content: "你好")]) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(responses.callCount, 1)
    XCTAssertEqual(responses.lastDialect, .ark)
    XCTAssertEqual(responses.lastWebSearch, false)
    XCTAssertEqual(chat.callCount, 0)
  }

  @MainActor
  func testDoubaoNeverSearchesEvenWhenAskSearchIsOn() {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchModule(
      providerID: "doubao", host: "ark.cn-beijing.volces.com", chat: chat, responses: responses)
    guard case let .success(open) = service.open(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertNil(open.searchProviderID)
    XCTAssertEqual(responses.callCount, 1)
    XCTAssertEqual(responses.lastDialect, .ark)
    XCTAssertEqual(responses.lastWebSearch, false)
    XCTAssertEqual(chat.callCount, 0, "/responses 那家绝不能退回 chat/completions —— 那样搜不到")
  }

  @MainActor
  func testOpenAIAnswersPlainWithoutSearch() {
    // OpenAI 不承担任意提问的联网：普通问答照旧走 chat/completions，不挂联网署名。
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchModule(
      providerID: "openai", host: "api.openai.com", chat: chat, responses: responses)
    guard case let .success(open) = service.open(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertNil(open.searchProviderID)
    XCTAssertEqual(responses.callCount, 0)
    XCTAssertEqual(chat.callCount, 1)
  }


  /// DeepSeek 迁 `/responses` 后的传输判定，也是任意提问唯一的联网通道。
  @MainActor
  func testDeepSeekDispatchesToResponsesAndSignsItsSearch() {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchModule(
      providerID: "deepseek", host: "api.deepseek.com", chat: chat, responses: responses)
    guard case let .success(open) = service.open(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(responses.lastDialect, .deepseek)
    XCTAssertEqual(chat.callCount, 0, "还在打 chat/completions = 迁移漏了这条链路")
    XCTAssertEqual(open.searchProviderID, "deepseek", "2026-07-31 起它能联网了，署名要挂上")
  }

  @MainActor
  func testOpenAskWithoutASearchRouteFallsBackToPlainChat() {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    // 同 `chatOnlyProfile`：这条钉的是「没有搜索通道 → 退回普通问答」，作答方得是个 chat 供应商。
    let profile = Self.chatOnlyProfile
    let service = OwlAskAnythingModule(
      client: chat,
      responsesClient: responses,
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      searchResolver: OwlAskSearchResolver(
        isEnabled: { true },
        profilesProvider: { [profile] },
        defaultProfileProvider: { profile },
        secretProvider: { _ in "sk-key" }
      )
    )
    guard case let .success(open) = service.open(messages: []) else {
      return XCTFail("expected a plain-chat stream")
    }
    XCTAssertNil(open.searchProviderID, "没联网就不能署名联网")
    XCTAssertEqual(chat.callCount, 1)
    XCTAssertEqual(responses.callCount, 0)
  }

  /// 断网/限流这类**暂时**故障不顺位，如实报给用户 ——
  /// 把断网吞成「换一家」只会把一个错误变成好几个。
  func testTransientFailuresAreReportedNotFailedOver() {
    XCTAssertFalse(
      OwlAskSearchFailover.isConfigurationRefusal(status: 400),
      "generic request rejections may depend on user content")
    XCTAssertTrue(OwlAskSearchFailover.isConfigurationRefusal(status: 401))
    XCTAssertTrue(OwlAskSearchFailover.isConfigurationRefusal(status: 404), "方舟 ToolNotOpen")
    XCTAssertFalse(
      OwlAskSearchFailover.isConfigurationRefusal(status: 422),
      "无法确认是否与问题内容有关的拒绝不能跨供应商追加请求")
    XCTAssertFalse(OwlAskSearchFailover.isConfigurationRefusal(status: 451))
    XCTAssertFalse(OwlAskSearchFailover.isConfigurationRefusal(status: 429), "限流稍后可重试")
    XCTAssertFalse(OwlAskSearchFailover.isConfigurationRefusal(status: 408))
    XCTAssertFalse(OwlAskSearchFailover.isConfigurationRefusal(status: 500))

    XCTAssertFalse(
      OwlAskSearchFailover.shouldTryNextAttempt(
        after: URLError(.notConnectedToInternet), hasYieldedDelta: false),
      "断网如实上报")
    XCTAssertTrue(
      OwlAskSearchFailover.shouldTryNextAttempt(
        after: OwlStreamingError.invalidEndpoint, hasYieldedDelta: false),
      "端点不可改写时请求尚未发出，属于候选配置不可用")
    XCTAssertFalse(
      OwlAskSearchFailover.shouldTryNextAttempt(
        after: OwlStreamingError.badHTTPStatus(401), hasYieldedDelta: true),
      "即便是明确配置拒绝，首个 delta 之后也不能再拼接另一家的答案")
  }

  /// 一个**仍然走 `/chat/completions`** 的默认供应商：没有搜索通道时退回普通问答的那个角色。
  ///
  /// 曾经这里用的是 DeepSeek——它 2026-07-31 迁到 `/responses` 之后就不再是「chat 供应商」了，
  /// 断言会变成在验证 fixture 的传输方式而不是搜索层的行为。所以换成一个不属于任何 Responses
  /// 家族、也没有搜索通道的自定义档案；DeepSeek 的 Responses 路由由
  /// `testDeepSeekDispatchesToResponsesAndSignsItsSearch` 单独覆盖。
  @MainActor private static var chatOnlyProfile: OwlProviderProfile {
    OwlProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
      model: "unit-chat-v1",
      providerID: "custom",
      secretName: "owltype.provider.unit.apiKey",
      isDefault: true
    )
  }
}

/// Records which transport the 任意提问 module picked. Driven synchronously
/// from the `@MainActor` tests (the stream is never consumed), so plain mutable state is enough.
private final class RecordingChatClient: OwlChatStreaming, @unchecked Sendable {
  private(set) var callCount = 0
  private(set) var lastMessages: [OwlDeepSeekMessage]?

  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    callCount += 1
    lastMessages = messages
    return AsyncThrowingStream { $0.finish() }
  }
}

private final class RecordingResponsesClient: OwlResponsesStreaming, @unchecked Sendable {
  private(set) var callCount = 0
  private(set) var lastDialect: OwlResponsesDialect?
  private(set) var lastWebSearch: Bool?

  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String,
    dialect: OwlResponsesDialect,
    webSearch: Bool
  ) -> AsyncThrowingStream<String, Error> {
    callCount += 1
    lastDialect = dialect
    lastWebSearch = webSearch
    return AsyncThrowingStream { $0.finish() }
  }
}

/// Carries the captured `URLRequest` out of the (concurrent) bytes provider closure.
private actor RequestBox {
  private var request: URLRequest?
  func set(_ request: URLRequest) { self.request = request }
  func get() -> URLRequest? { request }
}

/// A `OwlChatStreaming` that must never actually be asked to stream in the readiness tests.
private struct NeverStreamingClient: OwlChatStreaming {
  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}
