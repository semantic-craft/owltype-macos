//
//  FamoStreamingChatClientTests.swift
//  FamoTests — OpenAI-compatible STREAMING chat transport (roadmap B9, streaming half)
//
//  Locks the streaming transport contracts with NO socket and NO real Keychain/store:
//    1. `FamoSSEChatParser` (the pure core): single delta; multiple ordered; `[DONE]` ends;
//       a delta split across two chunks reassembles; comment / blank / role-only / empty-delta
//       lines are ignored without error; a malformed-JSON `data:` line is skipped (not fatal).
//    2. `FamoStreamingChatClient` driven by an INJECTED scripted byte source: emits the expected
//       ordered deltas and finishes; a non-2xx status finishes with `FamoStreamingError.badHTTPStatus`.
//    3. `FamoStreamingChatService.readiness()`: no-default-profile + no-key → `.unconfigured`;
//       a profile with no stored key → `.missingKey`; a resolvable key → `.ready` (no network).
//
//  No network, no librime.
//

import Foundation
import XCTest
@testable import Famo

final class FamoStreamingChatClientTests: XCTestCase {

  // MARK: - Pure SSE parser

  func testParserSingleDeltaYieldsContent() {
    var parser = FamoSSEChatParser()
    let deltas = parser.consume(#"data: {"choices":[{"delta":{"content":"本"}}]}"# + "\n\n")
    XCTAssertEqual(deltas, ["本"])
    XCTAssertFalse(parser.isFinished)
  }

  func testParserMultipleEventsYieldInOrder() {
    var parser = FamoSSEChatParser()
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
    var parser = FamoSSEChatParser()
    _ = parser.consume(#"data: {"choices":[{"delta":{"content":"甲"}}]}"# + "\n")
    let tail = parser.consume("data: [DONE]\n\n")
    XCTAssertTrue(tail.isEmpty)
    XCTAssertTrue(parser.isFinished)
    // After [DONE] further input is ignored.
    let after = parser.consume(#"data: {"choices":[{"delta":{"content":"乙"}}]}"# + "\n")
    XCTAssertTrue(after.isEmpty)
  }

  func testParserReassemblesDeltaSplitAcrossTwoChunks() {
    var parser = FamoSSEChatParser()
    // First chunk cuts the data line mid-JSON; nothing is complete yet.
    let first = parser.consume(#"data: {"choices":[{"delta":{"con"#)
    XCTAssertTrue(first.isEmpty, "an incomplete line must not emit or error")
    // Second chunk completes the line.
    let second = parser.consume(#"tent":"裁定"}}]}"# + "\n\n")
    XCTAssertEqual(second, ["裁定"])
  }

  func testParserReassemblesEventSplitAtLineBoundary() {
    var parser = FamoSSEChatParser()
    // Split exactly at the newline between the data line and its blank separator.
    let first = parser.consume(#"data: {"choices":[{"delta":{"content":"管辖"}}]}"#)
    XCTAssertTrue(first.isEmpty, "no trailing newline yet → still buffered")
    let second = parser.consume("\n\n")
    XCTAssertEqual(second, ["管辖"])
  }

  func testParserIgnoresCommentBlankAndRoleOnlyAndEmptyDeltaLines() {
    var parser = FamoSSEChatParser()
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
    var parser = FamoSSEChatParser()
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
    var parser = FamoSSEChatParser()
    let body = #"data: {"choices":[{"delta":{"content":"诉讼"}}]}"# + "\r\n\r\n"
    XCTAssertEqual(parser.consume(body), ["诉讼"])
  }

  func testParserFinishFlushesTrailingLineWithoutNewline() {
    var parser = FamoSSEChatParser()
    // Endpoint omits the final newline; consume buffers it, finish() flushes it.
    let mid = parser.consume(#"data: {"choices":[{"delta":{"content":"终审"}}]}"#)
    XCTAssertTrue(mid.isEmpty)
    XCTAssertEqual(parser.finish(), ["终审"])
  }

  // MARK: - Streaming client (injected scripted byte source — no socket)

  /// Build a `FamoStreamingChatClient` whose byte source replays scripted text chunks + a chosen
  /// HTTP status, instead of opening a real `URLSession.bytes`.
  private func makeClient(status: Int, chunks: [String]) -> FamoStreamingChatClient {
    FamoStreamingChatClient(bytesProvider: { _ in
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
      return FamoStreamingBytesSource(response: http, chunks: stream)
    })
  }

  private func makeRouting() -> FamoCloudRouting {
    FamoCloudRouting(
      providerID: "openai",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      secretName: "famo.provider.unit.apiKey",
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
    } catch let error as FamoStreamingError {
      XCTAssertEqual(error, .badHTTPStatus(429))
    } catch {
      XCTFail("expected FamoStreamingError.badHTTPStatus, got \(error)")
    }
  }

  // MARK: - Request body (联网搜索 extras merged onto the wire)

  /// Capture the `URLRequest` the client builds, without opening a socket. The scripted source
  /// finishes immediately; we only care about what was about to be sent.
  private func captureRequestBody(
    routing: FamoCloudRouting,
    extraBody: [String: Any]
  ) async throws -> [String: Any] {
    let box = RequestBox()
    let client = FamoStreamingChatClient(bytesProvider: { request in
      await box.set(request)
      return FamoStreamingBytesSource(
        response: HTTPURLResponse(
          url: routing.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil),
        chunks: AsyncThrowingStream { $0.finish() })
    })
    _ = try await collect(
      client.stream(messages: [], routing: routing, apiKey: "sk-test", extraBody: extraBody))
    guard let body = await box.get()?.httpBody,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      XCTFail("expected a JSON request body")
      return [:]
    }
    return object
  }

  func testPlainChatBodyCarriesNoSearchFields() async throws {
    let object = try await captureRequestBody(routing: makeRouting(), extraBody: [:])
    XCTAssertEqual(object["model"] as? String, "gpt-4o")
    XCTAssertEqual(object["stream"] as? Bool, true)
    XCTAssertNil(object["enable_search"], "普通问答绝不带联网字段")
    XCTAssertNil(object["tools"])
  }

  func testQwenSearchExtrasNoLongerBelongOnTheChatClient() async throws {
    let routing = FamoCloudRouting(
      providerID: "qwen",
      endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
      model: "qwen3.6-flash",
      secretName: "famo.provider.qwen.apiKey",
      authHeaderStyle: .bearer
    )
    let extras = FamoSearchControl.extraBody(providerID: "qwen", host: routing.endpoint.host ?? "")
    let object = try await captureRequestBody(routing: routing, extraBody: extras)
    XCTAssertTrue(extras.isEmpty)
    XCTAssertNil(object["enable_search"], "Qwen 搜索已经迁到 Responses，不得再混入旧字段")
    XCTAssertEqual(object["model"] as? String, "qwen3.6-flash")
    XCTAssertEqual(object["stream"] as? Bool, true)
    XCTAssertNotNil(object["messages"])
  }

  func testMiMoToolsSurviveTheMergeAsStructuredJSON() async throws {
    let routing = FamoCloudRouting(
      providerID: "mimo",
      endpoint: URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!,
      model: "mimo-v2.5",
      secretName: "famo.provider.mimo.apiKey",
      authHeaderStyle: .apiKey
    )
    let extras = FamoSearchControl.extraBody(providerID: "mimo", host: routing.endpoint.host ?? "")
    let object = try await captureRequestBody(routing: routing, extraBody: extras)
    guard let tools = object["tools"] as? [[String: Any]], let tool = tools.first else {
      return XCTFail("MiMo tools must survive the JSON merge as an array of objects")
    }
    XCTAssertEqual(tool["type"] as? String, "web_search")
    XCTAssertEqual(tool["force_search"] as? Bool, true)
    XCTAssertEqual((object["thinking"] as? [String: Any])?["type"] as? String, "disabled",
                   "嵌套字典也要原样过 merge —— 思考没关掉 MiMo 就不触发搜索")
  }

  // MARK: - 强制关思考（`FamoThinkingControl`）

  /// 设置页写着「任意提问一律强制关闭深度思考」。这条断言那句话在**普通问答**上也成立 ——
  /// 之前只有划词链路和 MiMo/豆包的联网请求关了，任意提问的主链路一个字段都没带。
  func testPlainAskForcesThinkingOffForEveryKnownProvider() async throws {
    func routing(_ id: String, _ model: String, _ host: String) -> FamoCloudRouting {
      FamoCloudRouting(
        providerID: id,
        endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
        model: model,
        secretName: "famo.provider.\(id).apiKey",
        authHeaderStyle: .bearer
      )
    }

    for (id, model, host) in [
      ("deepseek", "deepseek-v4-flash", "api.deepseek.com"),
      ("mimo", "mimo-v2.5", "api.xiaomimimo.com"),
      ("doubao", "doubao-seed-2-1-turbo-260628", "ark.cn-beijing.volces.com"),
    ] {
      let object = try await captureRequestBody(routing: routing(id, model, host), extraBody: [:])
      XCTAssertEqual((object["thinking"] as? [String: Any])?["type"] as? String, "disabled",
                     "\(id) 的普通问答也必须关思考")
    }

  }

  /// OpenAI 在 `/chat/completions` 上没有思考开关：请求体必须逐字节不变，不能凭空多字段。
  func testUnknownThinkingSwitchLeavesBodyUntouched() async throws {
    let object = try await captureRequestBody(routing: makeRouting(), extraBody: [:])
    XCTAssertNil(object["thinking"])
    XCTAssertNil(object["enable_thinking"])
  }

  // MARK: - High-level service readiness (no network)

  @MainActor
  func testServiceReadyWithActiveProfileAndKey() {
    let profile = FamoProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      secretName: "famo.provider.unit.apiKey",
      isDefault: true
    )
    let service = FamoStreamingChatService(
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
    let service = FamoStreamingChatService(
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
    let profile = FamoProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      secretName: "famo.provider.unit.apiKey",
      isDefault: true
    )
    let service = FamoStreamingChatService(
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
  ) -> FamoAskAnythingModule {
    let model: String
    switch providerID {
    case "qwen": model = "qwen3.7-plus"
    // 豆包的 plain 传输按「providerID/模型前缀 + host」判方言（FamoResponsesWire.dialect），
    // 得用真实型号名才能覆盖到那条判定。
    case "doubao": model = "doubao-seed-2-1-pro-260628"
    // DeepSeek 的方言判定卡型号（`/responses` 目前只收 deepseek-v4-flash），同样得用真实型号名。
    case "deepseek": model = "deepseek-v4-flash"
    default: model = "m"
    }
    let profile = FamoProviderProfile(
      id: providerID,
      displayName: providerID,
      endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
      model: model,
      providerID: providerID,
      secretName: "famo.provider.\(providerID).apiKey",
      isDefault: true
    )
    return FamoAskAnythingModule(
      client: chat,
      responsesClient: responses,
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      searchResolver: FamoAskSearchResolver(
        isEnabled: { true },
        profilesProvider: { [profile] },
        defaultProfileProvider: { profile },
        preferredProviderID: { nil },
        secretProvider: { _ in "sk-key" }
      ),
      // 必须显式关掉独立搜索层：它的默认实现读的是**真钥匙串**。用户一旦在设置页存了搜索 Key，
      // 这些用例就会改走「先检索、再作答」并用真 URLSession 打外网 —— 表现为整套 suite 静默挂住。
      isWebSearchEnabled: { searchEnabled },
      preferredWebSearchBackend: { .doubaoGlobal },
      webSearchKeyProvider: { _ in nil }
    )
  }

  @MainActor
  func testOpenAskSendsQwenSearchThroughTheResponsesClient() {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchModule(
      providerID: "qwen", host: "dashscope.aliyuncs.com", chat: chat, responses: responses)
    guard case let .success(open) = service.open(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(open.searchProviderID, "qwen")
    XCTAssertEqual(responses.callCount, 1)
    XCTAssertEqual(responses.lastDialect, .qwen)
    XCTAssertEqual(responses.lastWebSearch, true)
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
      messages: [FamoDeepSeekMessage(role: "user", content: "你好")]) else {
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
      messages: [FamoDeepSeekMessage(role: "user", content: "你好")]) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(responses.callCount, 1)
    XCTAssertEqual(responses.lastDialect, .ark)
    XCTAssertEqual(responses.lastWebSearch, false)
    XCTAssertEqual(chat.callCount, 0)
  }

  @MainActor
  func testOpenAskSendsDoubaoThroughTheResponsesClient() {
    // 豆包 走错传输就是「搜不到但看起来搜了」—— 这条断言就是拦它的。
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchModule(
      providerID: "doubao", host: "ark.cn-beijing.volces.com", chat: chat, responses: responses)
    guard case let .success(open) = service.open(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(open.searchProviderID, "doubao")
    XCTAssertEqual(responses.callCount, 1)
    XCTAssertEqual(responses.lastDialect, .ark)
    XCTAssertEqual(responses.lastWebSearch, true)
    XCTAssertEqual(chat.callCount, 0, "/responses 那家绝不能退回 chat/completions —— 那样搜不到")
  }

  @MainActor
  func testOpenAskSendsOpenAIThroughTheResponsesClientWithItsOwnDialect() {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchModule(
      providerID: "openai", host: "api.openai.com", chat: chat, responses: responses)
    guard case let .success(open) = service.open(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(open.searchProviderID, "openai")
    XCTAssertEqual(responses.lastDialect, .openAI)
    XCTAssertEqual(chat.callCount, 0)
  }

  /// DeepSeek 迁 `/responses` 后的传输判定，与上面 qwen / 豆包 / openai 三条同构。
  /// 这条补的是原本由 DeepSeek fixture 顺带覆盖、现已换成 `chatOnlyProfile` 的那块。
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
    let service = FamoAskAnythingModule(
      client: chat,
      responsesClient: responses,
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      searchResolver: FamoAskSearchResolver(
        isEnabled: { true },
        profilesProvider: { [profile] },
        defaultProfileProvider: { profile },
        preferredProviderID: { nil },
        secretProvider: { _ in "sk-key" }
      ),
      preferredWebSearchBackend: { .doubaoGlobal },
      webSearchKeyProvider: { _ in nil }   // 同上：不让默认实现去读真钥匙串、打真网络。
    )
    guard case let .success(open) = service.open(messages: []) else {
      return XCTFail("expected a plain-chat stream")
    }
    XCTAssertNil(open.searchProviderID, "没联网就不能署名联网")
    XCTAssertEqual(chat.callCount, 1)
    XCTAssertEqual(chat.lastExtraBody?.isEmpty, true, "普通问答不带任何联网字段")
    XCTAssertEqual(responses.callCount, 0)
  }

  // MARK: - 独立搜索层（先检索、再作答）

  /// 配了搜索 Key 就走搜索层：检索结果作为 system 消息注入，作答仍是**默认供应商**的
  /// `/chat/completions`（不是方舟 `/responses`），署名是「谁检索的」。
  @MainActor
  func testConfiguredWebSearchGroundsThePromptAndKeepsAnsweringOnTheDefaultProvider() async {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let stub = StubWebSearch(results: [
      FamoWebSearchResult(
        title: "标题 A", url: "https://a", snippet: "甲",
        publishedAt: "2026-07-01", hostname: "站点A"),
    ])
    let service = makeSearchService(chat: chat, responses: responses, search: stub)

    guard case let .success(open) = service.open(
      messages: [FamoDeepSeekMessage(role: "user", content: "今天有什么新闻")]) else {
      return XCTFail("expected a grounded stream")
    }
    XCTAssertEqual(open.searchProviderID, FamoWebSearchBackend.doubaoGlobal.attributionID)
    _ = try? await collect(open.stream)   // 消费掉，让内部 Task 真的跑到 client.stream

    XCTAssertEqual(responses.callCount, 0, "搜索层不走 /responses")
    XCTAssertEqual(chat.callCount, 1)
    let sent = chat.lastMessages ?? []
    XCTAssertEqual(sent.first?.role, "system")
    XCTAssertEqual(sent.count, 2, "注入的 system + 原来的 user")
    XCTAssertTrue(sent.first?.content.contains("[1] 标题 A") == true)
    XCTAssertEqual(sent.last?.content, "今天有什么新闻")
  }

  /// 检索碰上**暂时性**故障（限流 429 / 断网）时如实上报，而不是悄悄用未接地的答案糊过去。
  ///
  /// 这是移植运行期顺位策略后的语义变更：从前是「检索失败就静默降级成普通问答」，问题在于署名仍写着
  /// 「已联网」，用户拿到的是训练记忆却以为是实时结果。现在暂时性故障如实报错，配置性拒绝（401/404）
  /// 才顺位换家、全败才退回普通问答并撤掉署名。
  @MainActor
  func testTransientSearchFailureIsReportedRatherThanAnsweringUngrounded() async {
    let chat = RecordingChatClient()
    let stub = StubWebSearch(failure: .badHTTPStatus(429))
    let service = makeSearchService(
      chat: chat, responses: RecordingResponsesClient(), search: stub)

    guard case let .success(open) = service.open(
      messages: [FamoDeepSeekMessage(role: "user", content: "今天有什么新闻")]) else {
      return XCTFail("module.open 本身仍应开出一条流，错误从流里出来")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("限流应当如实抛给调用方")
    } catch {
      XCTAssertEqual(error as? FamoWebSearchError, .badHTTPStatus(429))
    }
    XCTAssertEqual(chat.callCount, 0, "没搜到就不该拿训练记忆冒充联网答案")
  }

  /// 一条结果都没有 = 失败：注入空资料却署名联网是最隐蔽的一种谎。没有别的候选时退回普通问答。
  @MainActor
  func testZeroResultsFallsBackToPlainChatAndDropsTheSearchAttribution() async {
    let chat = RecordingChatClient()
    let service = makeSearchService(
      chat: chat, responses: RecordingResponsesClient(), search: StubWebSearch(results: []))

    guard case let .success(open) = service.open(
      messages: [FamoDeepSeekMessage(role: "user", content: "今天有什么新闻")]) else {
      return XCTFail("expected a stream")
    }
    _ = try? await collect(open.stream)

    XCTAssertEqual(chat.callCount, 1, "照常作答")
    XCTAssertEqual(chat.lastMessages?.count, 1, "没搜到就不插 system 上下文")
    XCTAssertNil(open.searchProviderID, "退回普通问答时必须撤掉联网署名")
  }

  /// 配置期「有没有 Key」与运行期「肯不肯服务」是两道闸。搜索服务的 Key 无效（HTTP 200 里回
  /// `invalid_api_key`）时必须顺位到下一家，而不是把这一问判死。
  @MainActor
  func testConfigurationRefusalFailsOverToTheNextBackendAndRewritesAttribution() async {
    let chat = RecordingChatClient()
    let service = FamoAskAnythingModule(
      client: chat,
      responsesClient: RecordingResponsesClient(),
      profileProvider: { Self.chatOnlyProfile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      searchResolver: FamoAskSearchResolver(
        isEnabled: { true }, profilesProvider: { [] },
        defaultProfileProvider: { nil }, preferredProviderID: { nil },
        secretProvider: { _ in nil }),
      preferredWebSearchBackend: { .doubaoGlobal },
      // 第二家的 Key 走注入而不是真钥匙串：这台机器配没配过百炼搜索，结果都必须一样
      // （曾经这里读真 Keychain，配过 Key 的开发机上顺位真的成功，断言就翻车了）。
      webSearchKeyProvider: {
        switch $0 {
        case .doubaoGlobal: return "sk-bad"
        case .qwen: return "sk-qwen-search"
        case .perplexity: return nil
        }
      },
      webSearchClientFactory: { backend in
        backend == .doubaoGlobal
          ? StubWebSearch(failure: .serviceError(code: "invalid_api_key", message: "invalid"))
          : StubWebSearch(results: [FamoWebSearchResult(
              title: "P", url: "https://p", snippet: "乙", publishedAt: nil, hostname: nil)])
      }
    )
    FamoAskWebSearchSettings.isEnabled = true
    guard case let .success(open) = service.open(
      messages: [FamoDeepSeekMessage(role: "user", content: "今天有什么新闻")]) else {
      return XCTFail("首家被拒不该让 module.open 失败")
    }
    _ = try? await collect(open.stream)

    XCTAssertEqual(chat.callCount, 1, "换家后仍然答出来了")
    XCTAssertEqual(chat.lastMessages?.count, 2, "第二家的检索结果作为 system 上下文插进了这一问")
    XCTAssertEqual(
      open.searchProviderID, FamoWebSearchBackend.qwen.attributionID,
      "署名必须改写成真正完成检索的那家，不能还挂着「豆包搜索」")
  }

  /// 与上一条相反：断网/限流这类**暂时**故障不顺位，如实报给用户 ——
  /// 把断网吞成「换一家」只会把一个错误变成好几个。
  func testTransientFailuresAreReportedNotFailedOver() {
    XCTAssertTrue(FamoAskSearchFailover.isConfigurationRefusal(status: 401))
    XCTAssertTrue(FamoAskSearchFailover.isConfigurationRefusal(status: 404), "方舟 ToolNotOpen")
    XCTAssertFalse(
      FamoAskSearchFailover.isConfigurationRefusal(status: 422),
      "无法确认是否与问题内容有关的拒绝不能跨供应商追加请求")
    XCTAssertFalse(FamoAskSearchFailover.isConfigurationRefusal(status: 451))
    XCTAssertFalse(FamoAskSearchFailover.isConfigurationRefusal(status: 429), "限流稍后可重试")
    XCTAssertFalse(FamoAskSearchFailover.isConfigurationRefusal(status: 408))
    XCTAssertFalse(FamoAskSearchFailover.isConfigurationRefusal(status: 500))

    XCTAssertFalse(
      FamoAskSearchFailover.shouldTryNextAttempt(
        after: URLError(.notConnectedToInternet), hasYieldedDelta: false),
      "断网如实上报")
    XCTAssertTrue(
      FamoAskSearchFailover.shouldTryNextAttempt(
        after: FamoWebSearchError.serviceError(code: "invalid_api_key", message: ""),
        hasYieldedDelta: false))
    XCTAssertFalse(
      FamoAskSearchFailover.shouldTryNextAttempt(
        after: FamoWebSearchError.serviceError(code: "700429", message: ""),
        hasYieldedDelta: false),
      "豆包的限流码带着 HTTP 200 回来，同样不该顺位")
    XCTAssertFalse(
      FamoAskSearchFailover.shouldTryNextAttempt(
        after: FamoWebSearchError.serviceError(code: "ContentPolicyViolation", message: ""),
        hasYieldedDelta: false),
      "未知业务码不能默认跨供应商追加请求")
    XCTAssertTrue(
      FamoAskSearchFailover.shouldTryNextAttempt(
        after: FamoWebSearchError.noResults, hasYieldedDelta: false),
      "一条都没搜到 → 换一家，而不是注入空资料却署名联网")
    XCTAssertTrue(
      FamoAskSearchFailover.shouldTryNextAttempt(
        after: FamoStreamingError.invalidEndpoint, hasYieldedDelta: false),
      "端点不可改写时请求尚未发出，属于候选配置不可用")
    XCTAssertFalse(
      FamoAskSearchFailover.shouldTryNextAttempt(
        after: FamoStreamingError.badHTTPStatus(401), hasYieldedDelta: true),
      "即便是明确配置拒绝，首个 delta 之后也不能再拼接另一家的答案")
  }

  /// 一个**仍然走 `/chat/completions`** 的默认供应商。独立搜索层那几条用例要的就是这个角色：
  /// 检索结果作为 system 注入、作答走默认供应商的常规通道。
  ///
  /// 曾经这里用的是 DeepSeek——它 2026-07-31 迁到 `/responses` 之后就不再是「chat 供应商」了，
  /// 断言会变成在验证 fixture 的传输方式而不是搜索层的行为。所以换成一个不属于任何 Responses
  /// 家族、也没有搜索通道的自定义档案；DeepSeek 的 Responses 路由由
  /// `testDeepSeekPlainGenerationDispatchesToResponses` 单独覆盖。
  @MainActor private static var chatOnlyProfile: FamoProviderProfile {
    FamoProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
      model: "unit-chat-v1",
      providerID: "custom",
      secretName: "famo.provider.unit.apiKey",
      isDefault: true
    )
  }

  @MainActor
  private func makeSearchService(
    chat: RecordingChatClient,
    responses: RecordingResponsesClient,
    search: FamoWebSearching
  ) -> FamoAskAnythingModule {
    // 同 `chatOnlyProfile` 的理由：这几条断言的是搜索层，作答方必须是个仍走 chat 的供应商。
    let profile = Self.chatOnlyProfile
    FamoAskWebSearchSettings.isEnabled = true
    return FamoAskAnythingModule(
      client: chat,
      responsesClient: responses,
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      // 必须给一个空的 resolver：默认实现读的是**真实的 providers.json + 真钥匙串**，
      // 开发机上真配着豆包时，搜索层失败后会顺位到那条真路由，断言就会看到「doubao」而不是
      // 预期的退回普通问答（踩过一次）。测试要自带全部输入，不能继承这台机器的配置。
      searchResolver: FamoAskSearchResolver(
        isEnabled: { true }, profilesProvider: { [] },
        defaultProfileProvider: { nil }, preferredProviderID: { nil },
        secretProvider: { _ in nil }),
      preferredWebSearchBackend: { .doubaoGlobal },
      // 顺位候选的 Key 同理不能读真钥匙串：这台机器配过百炼/Perplexity 搜索 Key 的话，
      // 首家失败会顺位到一条真实路由，断言看到的就不是「退回普通问答」了。
      webSearchKeyProvider: { $0 == .doubaoGlobal ? "sk-search" : nil },
      webSearchClientFactory: { _ in search }
    )
  }
}

/// Records which transport the 任意提问 module picked, and with what search payload. Driven synchronously
/// from the `@MainActor` tests (the stream is never consumed), so plain mutable state is enough.
private final class RecordingChatClient: FamoChatStreaming, @unchecked Sendable {
  private(set) var callCount = 0
  private(set) var lastExtraBody: [String: Any]?
  /// 独立搜索层把检索结果作为 system 消息插在最前面，所以断言要看得到发出去的 messages。
  private(set) var lastMessages: [FamoDeepSeekMessage]?

  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    extraBody: [String: Any]
  ) -> AsyncThrowingStream<String, Error> {
    callCount += 1
    lastExtraBody = extraBody
    lastMessages = messages
    return AsyncThrowingStream { $0.finish() }
  }
}

/// 可编排的搜索后端：回结果或抛错，都不碰网络。
private struct StubWebSearch: FamoWebSearching {
  let results: [FamoWebSearchResult]
  let failure: FamoWebSearchError?

  init(results: [FamoWebSearchResult] = [], failure: FamoWebSearchError? = nil) {
    self.results = results
    self.failure = failure
  }

  func search(query: String, apiKey: String, limit: Int) async throws -> [FamoWebSearchResult] {
    if let failure { throw failure }
    return results
  }
}

private final class RecordingResponsesClient: FamoResponsesStreaming, @unchecked Sendable {
  private(set) var callCount = 0
  private(set) var lastDialect: FamoResponsesDialect?
  private(set) var lastWebSearch: Bool?

  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    dialect: FamoResponsesDialect,
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

/// A `FamoChatStreaming` that must never actually be asked to stream in the readiness tests.
private struct NeverStreamingClient: FamoChatStreaming {
  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    extraBody: [String: Any]
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}
