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

  func testZhipuToolsSurviveTheMergeAsStructuredJSON() async throws {
    let routing = FamoCloudRouting(
      providerID: "zhipu",
      endpoint: URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")!,
      model: "glm-5-turbo",
      secretName: "famo.provider.zhipu.apiKey",
      authHeaderStyle: .bearer
    )
    let extras = FamoSearchControl.extraBody(providerID: "zhipu", host: routing.endpoint.host ?? "")
    let object = try await captureRequestBody(routing: routing, extraBody: extras)
    guard let tools = object["tools"] as? [[String: Any]], let tool = tools.first else {
      return XCTFail("智谱 tools must survive the JSON merge as an array of objects")
    }
    XCTAssertEqual(tool["type"] as? String, "web_search")
    XCTAssertEqual((tool["web_search"] as? [String: Any])?["search_engine"] as? String, "search_pro")
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
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      searchResolver: FamoAskSearchResolver(
        isEnabled: { true },
        profilesProvider: { [profile] },
        defaultProfileProvider: { profile },
        preferredProviderID: { nil },
        secretProvider: { _ in "sk-key" }
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
  func testOpenAskSendsDoubaoThroughTheResponsesClient() {
    // 豆包 走错传输就是「搜不到但看起来搜了」—— 这条断言就是拦它的。
    let chat = RecordingChatClient()
    let responses = RecordingResponsesClient()
    let service = makeDispatchService(
      providerID: "doubao", host: "ark.cn-beijing.volces.com", chat: chat, responses: responses)
    guard case let .success(open) = service.openAsk(messages: []) else {
      return XCTFail("expected an opened stream")
    }
    XCTAssertEqual(open.searchProviderID, "doubao")
    XCTAssertEqual(responses.callCount, 1)
    XCTAssertEqual(responses.lastIsOpenAI, false, "方舟 dialect, not OpenAI's")
    XCTAssertEqual(chat.callCount, 0, "/responses 那家绝不能退回 chat/completions —— 那样搜不到")
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
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-key" },
      legacyKeyProvider: { nil },
      searchResolver: FamoAskSearchResolver(
        isEnabled: { true },
        profilesProvider: { [profile] },
        defaultProfileProvider: { profile },
        preferredProviderID: { nil },
        secretProvider: { _ in "sk-key" }
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
