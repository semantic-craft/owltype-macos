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

  func testSearchExtraBodyIsMergedAsTopLevelFields() async throws {
    // The whole point of the feature: the provider's search switch must actually reach the wire.
    let routing = FamoCloudRouting(
      providerID: "qwen",
      endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
      model: "qwen3.6-flash",
      secretName: "famo.provider.qwen.apiKey",
      authHeaderStyle: .bearer
    )
    let extras = FamoSearchControl.extraBody(providerID: "qwen", host: routing.endpoint.host ?? "")
    let object = try await captureRequestBody(routing: routing, extraBody: extras)
    XCTAssertEqual(object["enable_search"] as? Bool, true, "联网开关必须真的进了请求体")
    // …and the base fields survive the merge.
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

  // MARK: - openAsk transport dispatch (no network)

  /// A service whose 联网搜索 resolves to `providerID` at `host`, with both transports' clients
  /// recording which one was actually asked to stream.
  @MainActor
  private func makeDispatchService(
    providerID: String,
    host: String,
    chat: RecordingChatClient,
    responses: RecordingResponsesClient
  ) -> FamoStreamingChatService {
    let profile = FamoProviderProfile(
      id: providerID,
      displayName: providerID,
      endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
      model: "m",
      providerID: providerID,
      secretName: "famo.provider.\(providerID).apiKey",
      isDefault: true
    )
    return FamoStreamingChatService(
      client: chat,
      responsesClient: responses,
      retriever: UnusedRetriever(),
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      searchResolver: FamoAskSearchResolver(
        isEnabled: { true },
        profilesProvider: { [profile] },
        defaultProfileProvider: { profile },
        preferredProviderID: { nil },
        // 只有**供应商**密钥算已配置：这几条测的是「配了某家对话供应商时走哪条传输」，把
        // `famo.search.*` 也当成有值，等于替用户配好了联网搜索专用 Key，换了另一个前提。
        secretProvider: { $0.hasPrefix("famo.provider.") ? "sk-key" : nil }
      )
    )
  }

  @MainActor
  func testOpenAskSendsAChatCompletionsProviderThroughTheChatClient() {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchService(
      providerID: "qwen", host: "dashscope.aliyuncs.com", chat: chat, responses: responses)
    guard case let .success(open) = service.openAsk(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(open.searchProviderID, "qwen")
    XCTAssertEqual(chat.callCount, 1)
    XCTAssertEqual(chat.lastExtraBody?["enable_search"] as? Bool, true)
    XCTAssertEqual(responses.callCount, 0, "chat/completions 那家不能走 /responses 客户端")
  }

  @MainActor
  func testOpenAskSendsAnArkProfileThroughPlainChatBecauseItIsNoLongerASearchCandidate() {
    // 方舟的 web_search 要另开内容插件（没开 = 404 ToolNotOpen），已退出任意提问的联网候选。
    // 配着方舟档案时这一问就是普通问答 —— 关键是**不能**署名联网。
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchService(
      providerID: "doubao", host: "ark.cn-beijing.volces.com", chat: chat, responses: responses)
    guard case let .success(open) = service.openAsk(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertNil(open.searchProviderID, "没联网就绝不能署名联网")
    XCTAssertEqual(responses.callCount, 0)
    XCTAssertEqual(chat.callCount, 1)
    XCTAssertEqual(chat.lastExtraBody?.isEmpty, true)
  }

  @MainActor
  func testOpenAskSendsOpenAIThroughTheResponsesClientWithItsOwnDialect() {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchService(
      providerID: "openai", host: "api.openai.com", chat: chat, responses: responses)
    guard case let .success(open) = service.openAsk(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(open.searchProviderID, "openai")
    XCTAssertEqual(responses.lastIsOpenAI, true)
    XCTAssertEqual(chat.callCount, 0)
  }

  @MainActor
  func testOpenAskWithoutASearchRouteFallsBackToPlainChat() {
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let profile = FamoProviderProfile(
      id: "deepseek",
      displayName: "deepseek",
      endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
      model: "deepseek-v4-flash",
      providerID: "deepseek",
      secretName: "famo.provider.deepseek.apiKey",
      isDefault: true
    )
    let service = FamoStreamingChatService(
      client: chat,
      responsesClient: responses,
      retriever: UnusedRetriever(),
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      searchResolver: FamoAskSearchResolver(
        isEnabled: { true },
        profilesProvider: { [profile] },
        defaultProfileProvider: { profile },
        preferredProviderID: { nil },
        secretProvider: { $0.hasPrefix("famo.provider.") ? "sk-key" : nil }
      )
    )
    guard case let .success(open) = service.openAsk(messages: []) else {
      return XCTFail("expected a plain-chat stream")
    }
    XCTAssertNil(open.searchProviderID, "没联网就不能署名联网")
    XCTAssertEqual(chat.callCount, 1)
    XCTAssertEqual(chat.lastExtraBody?.isEmpty, true, "普通问答不带任何联网字段")
    XCTAssertEqual(responses.callCount, 0)
  }

  // MARK: - 运行期顺位降级（配置期挑出的候选，请求发出后才知道对方肯不肯服务）

  private func profile(
    _ providerID: String, host: String, isDefault: Bool = false
  ) -> FamoProviderProfile {
    FamoProviderProfile(
      id: providerID,
      displayName: providerID,
      endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
      model: "\(providerID)-model",
      providerID: providerID,
      secretName: "famo.provider.\(providerID).apiKey",
      isDefault: isDefault
    )
  }

  /// A service whose 联网 candidates come from `profiles` + `keys`, with a scripted chat client and
  /// retriever. `defaultProfile` is what plain chat (the final fallback) would use.
  @MainActor
  private func makeFailoverService(
    chat: FamoChatStreaming,
    retriever: FamoWebRetrieving = ScriptedRetriever(),
    profiles: [FamoProviderProfile],
    defaultProfile: FamoProviderProfile?,
    keys: [String: String]
  ) -> FamoStreamingChatService {
    FamoStreamingChatService(
      client: chat,
      responsesClient: RecordingResponsesClient(),
      retriever: retriever,
      profileProvider: { defaultProfile },
      profileSecretProvider: { keys[$0] },
      legacyKeyProvider: { nil },
      searchResolver: FamoAskSearchResolver(
        isEnabled: { true },
        profilesProvider: { profiles },
        defaultProfileProvider: { defaultProfile },
        preferredProviderID: { nil },
        secretProvider: { keys[$0] }
      )
    )
  }

  /// Drain an opened stream into either the full text or the error it failed with.
  @MainActor
  private func collect(_ open: FamoAskStreamOpen) async -> Result<String, Error> {
    do {
      var text = ""
      for try await delta in open.stream { text += delta }
      return .success(text)
    } catch {
      return .failure(error)
    }
  }

  @MainActor
  func testFirstProviderRefusingWithA4xxFailsOverToTheNextConfiguredOne() async {
    // 2026-07-27 实机：MiMo 的 Key 已失效（401 invalid_key）。以前这一问直接失败，现在应换下一家。
    let chat = ScriptedChatClient()
    chat.behaviors = [
      "api.xiaomimimo.com": .fail(FamoStreamingError.badHTTPStatus(401)),
      "dashscope.aliyuncs.com": .deltas(["百炼", "的答案"]),
    ]
    let qwen = profile("qwen", host: "dashscope.aliyuncs.com")
    let mimo = profile("mimo", host: "api.xiaomimimo.com", isDefault: true)
    let service = makeFailoverService(
      chat: chat,
      profiles: [qwen, mimo],
      defaultProfile: mimo,
      keys: [
        "famo.provider.qwen.apiKey": "sk-qwen",
        "famo.provider.mimo.apiKey": "sk-dead",
      ]
    )

    guard case let .success(open) = service.openAsk(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(open.searchProviderID, "mimo", "开流那一刻的归属是「打算用谁」")

    let result = await collect(open)
    XCTAssertEqual(try? result.get(), "百炼的答案")
    XCTAssertEqual(chat.hosts, ["api.xiaomimimo.com", "dashscope.aliyuncs.com"])
    XCTAssertEqual(open.searchProviderID, "qwen", "署名必须改写成真正答了这一问的那家")
  }

  @MainActor
  func testEveryProviderRefusingFallsBackToPlainChatAndDropsTheAttribution() async {
    // 设置页承诺的降级：全都不可用时退回普通问答，而不是让这一问失败。
    let chat = ScriptedChatClient()
    chat.behaviors = [
      "dashscope.aliyuncs.com": .fail(FamoStreamingError.badHTTPStatus(403)),
      "api.xiaomimimo.com": .fail(FamoStreamingError.badHTTPStatus(404)),
      "api.deepseek.com": .deltas(["普通问答的结果"]),
    ]
    let qwen = profile("qwen", host: "dashscope.aliyuncs.com")
    let mimo = profile("mimo", host: "api.xiaomimimo.com")
    let deepseek = profile("deepseek", host: "api.deepseek.com", isDefault: true)
    let service = makeFailoverService(
      chat: chat,
      profiles: [qwen, mimo, deepseek],
      defaultProfile: deepseek,
      keys: [
        "famo.provider.qwen.apiKey": "sk-qwen",
        "famo.provider.mimo.apiKey": "sk-mimo",
        "famo.provider.deepseek.apiKey": "sk-deepseek",
      ]
    )

    guard case let .success(open) = service.openAsk(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    let result = await collect(open)
    XCTAssertEqual(try? result.get(), "普通问答的结果")
    XCTAssertEqual(chat.hosts.last, "api.deepseek.com")
    XCTAssertNil(open.searchProviderID, "退回普通问答后绝不能留着联网署名")
  }

  @MainActor
  func testNetworkFailureIsReportedInsteadOfSilentlyTryingAnotherProvider() async {
    // 用户断网时换一家只会把一个错误变成好几个，而且掩盖了真实原因。
    let chat = ScriptedChatClient()
    chat.behaviors = [
      "dashscope.aliyuncs.com": .fail(URLError(.notConnectedToInternet)),
      "api.xiaomimimo.com": .deltas(["不该被用到"]),
    ]
    let qwen = profile("qwen", host: "dashscope.aliyuncs.com")
    let mimo = profile("mimo", host: "api.xiaomimimo.com")
    let service = makeFailoverService(
      chat: chat,
      profiles: [qwen, mimo],
      defaultProfile: qwen,
      keys: [
        "famo.provider.qwen.apiKey": "sk-qwen",
        "famo.provider.mimo.apiKey": "sk-mimo",
      ]
    )

    guard case let .success(open) = service.openAsk(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    let result = await collect(open)
    guard case let .failure(error) = result else {
      return XCTFail("断网必须如实失败，而不是换一家")
    }
    XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
    XCTAssertEqual(chat.hosts, ["dashscope.aliyuncs.com"], "只试了这一家")
  }

  @MainActor
  func testAFailureAfterContentIsNotRetriedWithAnotherProvider() async {
    // 顺位的硬边界：已经有内容送进窗口后再换家，会把两半答案拼在一起。
    let chat = ScriptedChatClient()
    chat.behaviors = [
      "dashscope.aliyuncs.com": .deltasThenFail(["已经写了一半"], FamoStreamingError.badHTTPStatus(401)),
      "api.xiaomimimo.com": .deltas(["不该被用到"]),
    ]
    let qwen = profile("qwen", host: "dashscope.aliyuncs.com")
    let mimo = profile("mimo", host: "api.xiaomimimo.com")
    let service = makeFailoverService(
      chat: chat,
      profiles: [qwen, mimo],
      defaultProfile: qwen,
      keys: [
        "famo.provider.qwen.apiKey": "sk-qwen",
        "famo.provider.mimo.apiKey": "sk-mimo",
      ]
    )

    guard case let .success(open) = service.openAsk(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    var received = ""
    do {
      for try await delta in open.stream { received += delta }
      XCTFail("中途失败必须冒出来")
    } catch {
      XCTAssertEqual(error as? FamoStreamingError, .badHTTPStatus(401))
    }
    XCTAssertEqual(received, "已经写了一半", "已送达的部分要留住")
    XCTAssertEqual(chat.hosts, ["dashscope.aliyuncs.com"], "有内容之后不能再换家")
  }

  // MARK: - 豆包搜索（检索 → 主模型作答）

  @MainActor
  func testDoubaoSearchRetrievesThenLetsTheMainModelAnswerWithTheDocuments() async {
    let chat = ScriptedChatClient()
    chat.behaviors = ["api.deepseek.com": .deltas(["基于资料的答案"])]
    let retriever = ScriptedRetriever()
    retriever.result = .success([
      FamoWebSearchDocument(
        title: "最高法发布新司法解释",
        url: "https://court.example/1",
        snippet: "自 2026 年 8 月 1 日起施行",
        hostname: "人民法院报",
        publishTime: "2026-07-20"
      )
    ])
    let deepseek = profile("deepseek", host: "api.deepseek.com", isDefault: true)
    let service = makeFailoverService(
      chat: chat,
      retriever: retriever,
      profiles: [deepseek],
      defaultProfile: deepseek,
      keys: [
        "famo.provider.deepseek.apiKey": "sk-deepseek",
        FamoSearchCredential.doubaoSearch.secretName: "sk-doubao-search",
      ]
    )

    let messages = [
      FamoDeepSeekMessage(role: "system", content: "系统提示"),
      FamoDeepSeekMessage(role: "user", content: "新司法解释什么时候施行？"),
    ]
    guard case let .success(open) = service.openAsk(messages: messages) else {
      return XCTFail("expected an opened stream")
    }
    let result = await collect(open)

    XCTAssertEqual(try? result.get(), "基于资料的答案")
    XCTAssertEqual(retriever.callCount, 1)
    XCTAssertEqual(retriever.lastQuery, "新司法解释什么时候施行？", "检索用的是用户原话")
    XCTAssertEqual(open.searchProviderID, "doubao_search", "署名要写明这一问真的联网了")
    XCTAssertEqual(chat.lastMessages?.first?.content, "系统提示", "system 消息不受影响")
    let lastUserMessage = chat.lastMessages?.last?.content ?? ""
    XCTAssertTrue(lastUserMessage.contains("自 2026 年 8 月 1 日起施行"), "检索到的资料必须真的进请求")
    XCTAssertTrue(lastUserMessage.hasSuffix("新司法解释什么时候施行？"), "用户原话仍在最后")
  }

  @MainActor
  func testDoubaoSearchRefusalFailsOverToTheNextProvider() async {
    // 豆包搜索没开通/额度用尽（HTTP 200 + 业务错误码）时，这一问该由下一家联网接手。
    let chat = ScriptedChatClient()
    chat.behaviors = ["dashscope.aliyuncs.com": .deltas(["百炼接手"])]
    let retriever = ScriptedRetriever()
    retriever.result = .failure(FamoWebRetrievalError.apiError(code: 10410, message: "no package"))
    let qwen = profile("qwen", host: "dashscope.aliyuncs.com", isDefault: true)
    let service = makeFailoverService(
      chat: chat,
      retriever: retriever,
      profiles: [qwen],
      defaultProfile: qwen,
      keys: [
        "famo.provider.qwen.apiKey": "sk-qwen",
        FamoSearchCredential.doubaoSearch.secretName: "sk-doubao-search",
      ]
    )

    guard case let .success(open) = service.openAsk(messages: [
      FamoDeepSeekMessage(role: "user", content: "问题"),
    ]) else {
      return XCTFail("expected an opened stream")
    }
    let result = await collect(open)
    XCTAssertEqual(try? result.get(), "百炼接手")
    XCTAssertEqual(open.searchProviderID, "qwen")
  }

  @MainActor
  func testRetrievalRouteIsDroppedWhenNoMainModelCanAnswer() async {
    // 豆包搜索自己不作答 —— 主模型没配好时它拿到资料也没人写答案。这时应如实返回「未配置」，
    // 而不是先白白检索一次再报一个跟「没配供应商」无关的错。
    let chat = ScriptedChatClient()
    let retriever = ScriptedRetriever()
    let service = makeFailoverService(
      chat: chat,
      retriever: retriever,
      profiles: [],
      defaultProfile: nil,
      keys: [FamoSearchCredential.doubaoSearch.secretName: "sk-doubao-search"]
    )

    if case .success = service.openAsk(messages: []) {
      XCTFail("没有主模型时不该开出流")
    }
    XCTAssertEqual(retriever.callCount, 0, "一次检索都不该发生")
  }
}

/// A chat client scripted PER ENDPOINT HOST — the failover tests need each candidate to behave
/// differently within one run.
private final class ScriptedChatClient: FamoChatStreaming, @unchecked Sendable {
  enum Behavior {
    case deltas([String])
    case fail(Error)
    /// 先吐内容再失败：顺位的硬边界。
    case deltasThenFail([String], Error)
  }

  var behaviors: [String: Behavior] = [:]
  /// The endpoint hosts this client was asked to stream, in order.
  private(set) var hosts: [String] = []
  private(set) var lastMessages: [FamoDeepSeekMessage]?

  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    extraBody: [String: Any]
  ) -> AsyncThrowingStream<String, Error> {
    let host = routing.endpoint.host ?? ""
    hosts.append(host)
    lastMessages = messages
    let behavior = behaviors[host] ?? .deltas([])
    return AsyncThrowingStream { continuation in
      switch behavior {
      case let .deltas(deltas):
        for delta in deltas { continuation.yield(delta) }
        continuation.finish()
      case let .fail(error):
        continuation.finish(throwing: error)
      case let .deltasThenFail(deltas, error):
        for delta in deltas { continuation.yield(delta) }
        continuation.finish(throwing: error)
      }
    }
  }
}

/// 守卫：单元测试里绝不能真的去检索。服务默认的 `FamoDoubaoSearchClient` 会发真网络请求（并把整条
/// 测试挂在超时上），所以凡是「不该走检索路由」的用例都注入这个。
private final class UnusedRetriever: FamoWebRetrieving {
  func retrieve(
    query: String,
    routing: FamoCloudRouting,
    apiKey: String
  ) async throws -> [FamoWebSearchDocument] {
    XCTFail("这条用例不该走到检索路由")
    return []
  }
}

private final class ScriptedRetriever: FamoWebRetrieving, @unchecked Sendable {
  var result: Result<[FamoWebSearchDocument], Error> = .success([])
  private(set) var callCount = 0
  private(set) var lastQuery = ""

  func retrieve(
    query: String,
    routing: FamoCloudRouting,
    apiKey: String
  ) async throws -> [FamoWebSearchDocument] {
    callCount += 1
    lastQuery = query
    return try result.get()
  }
}

/// Records which transport `openAsk` picked, and with what search payload. Driven synchronously
/// from the `@MainActor` tests (the stream is never consumed), so plain mutable state is enough.
private final class RecordingChatClient: FamoChatStreaming, @unchecked Sendable {
  private(set) var callCount = 0
  private(set) var lastExtraBody: [String: Any]?

  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    extraBody: [String: Any]
  ) -> AsyncThrowingStream<String, Error> {
    callCount += 1
    lastExtraBody = extraBody
    return AsyncThrowingStream { $0.finish() }
  }
}

private final class RecordingResponsesClient: FamoResponsesStreaming, @unchecked Sendable {
  private(set) var callCount = 0
  private(set) var lastIsOpenAI: Bool?

  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    isOpenAI: Bool
  ) -> AsyncThrowingStream<String, Error> {
    callCount += 1
    lastIsOpenAI = isOpenAI
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
