//
//  FamoAskAnythingModuleTests.swift
//  FamoTests — 任意提问统一尝试矩阵与首 delta 前 failover（issue #113）
//
//  The module is driven through in-memory chat / Responses / standalone-search adapters. The tests
//  exercise the public ask seam while recording the full attempt matrix: key filtering, provider
//  order, transport, first-delta boundary, plain fallback, cancellation, and final attribution.
//

import Foundation
import XCTest
@testable import Famo

@MainActor
final class FamoAskAnythingModuleTests: XCTestCase {

  func testConfiguredQwenSearchStreamsThroughTheSeamAndKeepsAttribution() async throws {
    let transport = InMemoryAskTransport(
      builtInStream: Self.stream(deltas: ["本院", "认为"]))
    let module = makeModule(searchEnabled: true, transport: transport)

    guard case let .success(open) = module.open(
      messages: [FamoDeepSeekMessage(role: "user", content: "今天有什么新规？")]) else {
      return XCTFail("configured Qwen search should open")
    }

    XCTAssertEqual(open.searchProviderID, "qwen")
    XCTAssertEqual(transport.calls, [.builtInSearch(providerID: "qwen")])
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["本院", "认为"])
    XCTAssertEqual(open.searchProviderID, "qwen", "stream completion must keep the actual signer")
  }

  func testSearchOffUsesPlainAnswerWithoutSearchAttribution() async throws {
    let transport = InMemoryAskTransport(plainStream: Self.stream(deltas: ["普通回答"]))
    let module = makeModule(searchEnabled: false, transport: transport)

    guard case let .success(open) = module.open(
      messages: [FamoDeepSeekMessage(role: "user", content: "解释一下")]) else {
      return XCTFail("plain ask should still open")
    }

    XCTAssertNil(open.searchProviderID)
    XCTAssertEqual(transport.calls, [.plain(providerID: "qwen")])
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["普通回答"])
  }

  func testMissingConfigurationReturnsReadinessWithoutOpeningATransport() {
    let transport = InMemoryAskTransport()
    let gate = FamoProviderAuthGate(
      profileProvider: { nil },
      profileSecretProvider: { _ in XCTFail("no profile means no profile secret read"); return nil },
      legacyKeyProvider: { nil })
    let resolver = FamoAskSearchResolver(
      isEnabled: { true }, profilesProvider: { [] }, defaultProfileProvider: { nil },
      preferredProviderID: { nil }, secretProvider: { _ in nil })
    let module = FamoAskAnythingModule(
      gate: gate,
      transport: transport,
      searchResolver: resolver,
      isWebSearchEnabled: { true },
      preferredWebSearchBackend: { .doubaoGlobal },
      webSearchKeyProvider: { _ in nil })

    guard case let .failure(readiness) = module.open(messages: []) else {
      return XCTFail("missing configuration must not open a stream")
    }
    XCTAssertEqual(readiness, .unconfigured)
    XCTAssertTrue(transport.calls.isEmpty, "readiness failures must have zero network side effects")
  }

  func testRequestErrorDoesNotOpenFallbackOrAnotherTransport() async {
    let transport = InMemoryAskTransport(
      builtInStream: Self.failingStream(URLError(.notConnectedToInternet)),
      plainStream: Self.stream(deltas: ["不应出现"]))
    let module = makeModule(searchEnabled: true, transport: transport)

    guard case let .success(open) = module.open(messages: []) else {
      return XCTFail("transport failures surface from the opened stream")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("the transport error should surface")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
    }
    XCTAssertEqual(
      transport.calls, [.builtInSearch(providerID: "qwen")],
      "a real request error must not fan out into fallback requests")
  }

  func testCancellationStopsTheActiveAdapterWithoutOpeningFallback() async {
    let innerCancelled = expectation(description: "active in-memory adapter cancelled")
    let consumerStarted = expectation(description: "consumer is waiting on the active adapter")
    let inner = AsyncThrowingStream<String, Error> { continuation in
      continuation.yield("第一段")
      continuation.onTermination = { _ in innerCancelled.fulfill() }
    }
    let transport = InMemoryAskTransport(
      builtInStream: inner,
      plainStream: Self.stream(deltas: ["不应出现"]))
    let module = makeModule(searchEnabled: true, transport: transport)

    guard case let .success(open) = module.open(messages: []) else {
      return XCTFail("configured Qwen search should open")
    }
    let consumer = Task {
      var iterator = open.stream.makeAsyncIterator()
      let first = try await iterator.next()
      XCTAssertEqual(first, "第一段")
      consumerStarted.fulfill()
      return try await iterator.next()
    }
    await fulfillment(of: [consumerStarted], timeout: 1)
    consumer.cancel()
    _ = try? await consumer.value
    await fulfillment(of: [innerCancelled], timeout: 1)

    XCTAssertEqual(
      transport.calls, [.builtInSearch(providerID: "qwen")],
      "cancellation must not open a retry or plain fallback")
  }

  func testStandalonePreferenceOnlyReordersAndConfiguredBackendUsesPlainResponses() async throws {
    let responses = ScriptedResponsesClient(streams: [Self.stream(deltas: ["接地回答"])])
    let transport = FamoAskAnythingTransportAdapter(
      chatClient: ScriptedChatClient(), responsesClient: responses)
    let searches = WebSearchRecorder(results: [Self.searchResult])
    let module = makeMatrixModule(
      gateProfile: Self.qwenProfile,
      builtInProfiles: [],
      builtInKeys: [:],
      transport: transport,
      preferredWebSearchBackend: .doubaoGlobal,
      webSearchKeys: [
        .qwen: "  sk-qwen-search  ",
        .perplexity: "   ",
      ],
      searches: searches)

    guard case let .success(open) = module.open(
      messages: [FamoDeepSeekMessage(role: "user", content: "今天有什么新规？")]) else {
      return XCTFail("a configured non-preferred backend should still open")
    }

    XCTAssertEqual(open.searchProviderID, FamoWebSearchBackend.qwen.attributionID)
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["接地回答"])
    XCTAssertEqual(
      searches.calls,
      [.init(backend: .qwen, query: "今天有什么新规？", apiKey: "sk-qwen-search", limit: 5)],
      "the missing preferred key and blank Perplexity key must filter only those candidates")
    XCTAssertEqual(
      responses.calls,
      [.init(providerID: "qwen", dialect: .qwen, webSearch: false)],
      "standalone search injects context, then the default Qwen profile answers on plain Responses")
  }

  func testBuiltInMatrixFailsOverFromResponsesToChatBeforeFirstDelta() async throws {
    let qwen = Self.qwenProfile
    let mimo = Self.mimoProfile
    let responses = ScriptedResponsesClient(streams: [
      Self.failingStream(FamoStreamingError.badHTTPStatus(404)),
    ])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["MiMo 回答"])])
    let module = makeMatrixModule(
      gateProfile: qwen,
      builtInProfiles: [mimo, qwen],
      builtInKeys: [qwen.secretName: "sk-qwen", mimo.secretName: "sk-mimo"],
      transport: FamoAskAnythingTransportAdapter(chatClient: chat, responsesClient: responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the built-in matrix should open")
    }
    XCTAssertEqual(open.searchProviderID, "qwen", "Qwen is first in the canonical provider order")

    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["MiMo 回答"])
    XCTAssertEqual(
      responses.calls, [.init(providerID: "qwen", dialect: .qwen, webSearch: true)])
    XCTAssertEqual(chat.calls, [.init(providerID: "mimo", carriesSearchFields: true)])
    XCTAssertEqual(open.searchProviderID, "mimo", "attribution follows the route that yielded")
  }

  func testGenericHTTP400IsReportedWithoutOpeningAnotherBuiltInProvider() async {
    let qwen = Self.qwenProfile
    let mimo = Self.mimoProfile
    let responses = ScriptedResponsesClient(streams: [
      Self.failingStream(FamoStreamingError.badHTTPStatus(400)),
    ])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["不应出现"])])
    let module: FamoAskAnythingOpening = makeMatrixModule(
      gateProfile: qwen,
      builtInProfiles: [qwen, mimo],
      builtInKeys: [qwen.secretName: "sk-qwen", mimo.secretName: "sk-mimo"],
      transport: FamoAskAnythingTransportAdapter(chatClient: chat, responsesClient: responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the first built-in provider should open")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("a generic request rejection must surface without crossing providers")
    } catch {
      XCTAssertEqual(error as? FamoStreamingError, .badHTTPStatus(400))
    }

    XCTAssertEqual(
      responses.calls, [.init(providerID: "qwen", dialect: .qwen, webSearch: true)])
    XCTAssertTrue(chat.calls.isEmpty, "generic HTTP 400 must not reach the second provider")
    XCTAssertEqual(open.searchProviderID, "qwen")
  }

  func testGenericInvalidParameterIsReportedWithoutAnotherSearchOrProvider() async {
    await assertInvalidParameterIsReportedWithoutAnotherAttempt(message: "invalid parameter")
  }

  func testContentRelatedInvalidParameterIsReportedWithoutAnotherSearchOrProvider() async {
    await assertInvalidParameterIsReportedWithoutAnotherAttempt(
      message: "the submitted URL or question content is invalid")
  }

  func testExplicitStandaloneConfigurationCodesStillFailOverBeforeFirstDelta() async throws {
    let refusals: [(code: String, purpose: String)] = [
      ("invalid_api_key", "authentication"),
      ("10410", "package entitlement"),
      ("ToolNotOpen", "search plugin enablement"),
    ]

    for refusal in refusals {
      let searches = WebSearchRecorder(
        results: [Self.searchResult],
        failures: [
          .doubaoGlobal: .serviceError(code: refusal.code, message: refusal.purpose),
        ])
      let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["接地回答"])])
      let responses = ScriptedResponsesClient()
      let module: FamoAskAnythingOpening = makeMatrixModule(
        gateProfile: Self.chatOnlyProfile,
        builtInProfiles: [],
        builtInKeys: [:],
        transport: FamoAskAnythingTransportAdapter(
          chatClient: chat, responsesClient: responses),
        webSearchKeys: [.doubaoGlobal: "sk-doubao", .qwen: "sk-qwen"],
        searches: searches)

      guard case let .success(open) = module.open(messages: Self.question) else {
        XCTFail("the first standalone search should open for \(refusal.purpose)")
        continue
      }
      let deltas = try await collect(open.stream)

      XCTAssertEqual(deltas, ["接地回答"], refusal.purpose)
      XCTAssertEqual(
        searches.calls.map(\.backend), [.doubaoGlobal, .qwen], refusal.purpose)
      XCTAssertEqual(
        chat.calls, [.init(providerID: "custom", carriesSearchFields: false)],
        refusal.purpose)
      XCTAssertTrue(responses.calls.isEmpty, refusal.purpose)
      XCTAssertEqual(
        open.searchProviderID, FamoWebSearchBackend.qwen.attributionID, refusal.purpose)
    }
  }

  func testEmptyStreamIsReportedWithoutOpeningAnotherProvider() async {
    let qwen = Self.qwenProfile
    let mimo = Self.mimoProfile
    let responses = ScriptedResponsesClient(streams: [Self.stream(deltas: [])])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["不应出现"])])
    let module = makeMatrixModule(
      gateProfile: qwen,
      builtInProfiles: [qwen, mimo],
      builtInKeys: [qwen.secretName: "sk-qwen", mimo.secretName: "sk-mimo"],
      transport: FamoAskAnythingTransportAdapter(chatClient: chat, responsesClient: responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the first route should open")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("zero deltas must not masquerade as a successful online answer")
    } catch {
      XCTAssertEqual(error as? FamoStreamingError, .emptyResponse)
    }
    XCTAssertTrue(chat.calls.isEmpty, "an empty answer is not a proven configuration refusal")
    XCTAssertEqual(open.searchProviderID, "qwen")
  }

  func testConfigurationRefusalAfterFirstDeltaIsReportedWithoutOpeningNextAttempt() async {
    let qwen = Self.qwenProfile
    let mimo = Self.mimoProfile
    let responses = ScriptedResponsesClient(streams: [
      Self.stream(deltas: ["半句"], failure: FamoStreamingError.badHTTPStatus(401)),
    ])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["不应出现"])])
    let module = makeMatrixModule(
      gateProfile: qwen,
      builtInProfiles: [qwen, mimo],
      builtInKeys: [qwen.secretName: "sk-qwen", mimo.secretName: "sk-mimo"],
      transport: FamoAskAnythingTransportAdapter(chatClient: chat, responsesClient: responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the first route should open")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("a failure after output starts must surface")
    } catch {
      XCTAssertEqual(error as? FamoStreamingError, .badHTTPStatus(401))
    }
    XCTAssertTrue(chat.calls.isEmpty, "first delta permanently closes the failover gate")
    XCTAssertEqual(open.searchProviderID, "qwen")
  }

  func testEveryOnlineRefusalFallsBackToPlainAndClearsAttribution() async throws {
    let qwen = Self.qwenProfile
    let mimo = Self.mimoProfile
    let responses = ScriptedResponsesClient(streams: [
      Self.failingStream(FamoStreamingError.badHTTPStatus(401)),
    ])
    let chat = ScriptedChatClient(streams: [
      Self.failingStream(FamoStreamingError.badHTTPStatus(403)),
      Self.stream(deltas: ["普通回答"]),
    ])
    let module = makeMatrixModule(
      gateProfile: Self.chatOnlyProfile,
      builtInProfiles: [mimo, qwen],
      builtInKeys: [qwen.secretName: "sk-qwen", mimo.secretName: "sk-mimo"],
      transport: FamoAskAnythingTransportAdapter(chatClient: chat, responsesClient: responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the matrix should open before runtime refusals are known")
    }
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["普通回答"])
    XCTAssertNil(open.searchProviderID, "plain fallback must remove every online attribution")
    XCTAssertEqual(
      responses.calls, [.init(providerID: "qwen", dialect: .qwen, webSearch: true)])
    XCTAssertEqual(
      chat.calls,
      [
        .init(providerID: "mimo", carriesSearchFields: true),
        .init(providerID: "custom", carriesSearchFields: false),
      ])
  }

  func testCompleteAttemptMatrixFallsFromStandaloneThroughResponsesAndChatToPlain() async throws {
    let qwen = Self.qwenProfile
    let mimo = Self.mimoProfile
    let searches = WebSearchRecorder(
      results: [],
      failures: [.doubaoGlobal: .serviceError(code: "invalid_api_key", message: "invalid")])
    let responses = ScriptedResponsesClient(streams: [
      Self.failingStream(FamoStreamingError.badHTTPStatus(404)),
    ])
    let chat = ScriptedChatClient(streams: [
      Self.failingStream(FamoStreamingError.badHTTPStatus(401)),
      Self.stream(deltas: ["普通回答"]),
    ])
    let module = makeMatrixModule(
      gateProfile: Self.chatOnlyProfile,
      builtInProfiles: [mimo, qwen],
      builtInKeys: [qwen.secretName: "sk-qwen", mimo.secretName: "sk-mimo"],
      transport: FamoAskAnythingTransportAdapter(chatClient: chat, responsesClient: responses),
      webSearchKeys: [.doubaoGlobal: "sk-search"],
      searches: searches)

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the complete attempt matrix should open")
    }
    XCTAssertEqual(open.searchProviderID, FamoWebSearchBackend.doubaoGlobal.attributionID)
    let deltas = try await collect(open.stream)

    XCTAssertEqual(deltas, ["普通回答"])
    XCTAssertEqual(
      searches.calls,
      [.init(backend: .doubaoGlobal, query: "问题", apiKey: "sk-search", limit: 5)])
    XCTAssertEqual(
      responses.calls, [.init(providerID: "qwen", dialect: .qwen, webSearch: true)])
    XCTAssertEqual(
      chat.calls,
      [
        .init(providerID: "mimo", carriesSearchFields: true),
        .init(providerID: "custom", carriesSearchFields: false),
      ])
    XCTAssertNil(open.searchProviderID, "the final plain attempt must clear online attribution")
  }

  func testEveryOnlineAttemptAndPlainAnswerFailThroughTheInterface() async {
    let qwen = Self.qwenProfile
    let mimo = Self.mimoProfile
    let responses = ScriptedResponsesClient(streams: [
      Self.failingStream(FamoStreamingError.badHTTPStatus(401)),
    ])
    let chat = ScriptedChatClient(streams: [
      Self.failingStream(FamoStreamingError.badHTTPStatus(403)),
      Self.failingStream(FamoStreamingError.badHTTPStatus(503)),
    ])
    let module: FamoAskAnythingOpening = makeMatrixModule(
      gateProfile: Self.chatOnlyProfile,
      builtInProfiles: [qwen, mimo],
      builtInKeys: [qwen.secretName: "sk-qwen", mimo.secretName: "sk-mimo"],
      transport: FamoAskAnythingTransportAdapter(chatClient: chat, responsesClient: responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("configured attempts should open through the interface")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("the final plain transport failure must surface")
    } catch {
      XCTAssertEqual(error as? FamoStreamingError, .badHTTPStatus(503))
    }

    XCTAssertNil(open.searchProviderID, "plain fallback clears every online attribution")
    XCTAssertEqual(
      responses.calls, [.init(providerID: "qwen", dialect: .qwen, webSearch: true)])
    XCTAssertEqual(
      chat.calls,
      [
        .init(providerID: "mimo", carriesSearchFields: true),
        .init(providerID: "custom", carriesSearchFields: false),
      ])
  }

  func testCancellationDuringStandaloneSearchDoesNotOpenAnyLaterAttempt() async {
    let searchStarted = expectation(description: "standalone search started")
    let searchCancelled = expectation(description: "standalone search cancelled")
    let searches = CancellableWebSearchRecorder(
      started: searchStarted, cancelled: searchCancelled)
    let responses = ScriptedResponsesClient(streams: [Self.stream(deltas: ["不应出现"])])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["不应出现"])])
    let qwen = Self.qwenProfile
    let mimo = Self.mimoProfile
    let module = makeMatrixModule(
      gateProfile: Self.chatOnlyProfile,
      builtInProfiles: [qwen, mimo],
      builtInKeys: [qwen.secretName: "sk-qwen", mimo.secretName: "sk-mimo"],
      transport: FamoAskAnythingTransportAdapter(chatClient: chat, responsesClient: responses),
      webSearchKeys: [.doubaoGlobal: "sk-search"],
      searches: searches)

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the standalone attempt should open")
    }
    let consumer = Task { try await collect(open.stream) }
    await fulfillment(of: [searchStarted], timeout: 1)
    consumer.cancel()
    _ = try? await consumer.value
    await fulfillment(of: [searchCancelled], timeout: 1)

    XCTAssertEqual(searches.calls, [.doubaoGlobal])
    XCTAssertTrue(responses.calls.isEmpty, "cancellation must not open the Responses candidate")
    XCTAssertTrue(chat.calls.isEmpty, "cancellation must not open Chat or plain fallback")
  }

  private func makeModule(
    searchEnabled: Bool,
    transport: InMemoryAskTransport
  ) -> FamoAskAnythingModule {
    let profile = Self.qwenProfile
    let gate = FamoProviderAuthGate(
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-qwen" },
      legacyKeyProvider: { nil })
    let resolver = FamoAskSearchResolver(
      isEnabled: { searchEnabled },
      profilesProvider: { [profile] },
      defaultProfileProvider: { profile },
      preferredProviderID: { nil },
      secretProvider: { _ in "sk-qwen" })
    return FamoAskAnythingModule(
      gate: gate,
      transport: transport,
      searchResolver: resolver,
      isWebSearchEnabled: { searchEnabled },
      preferredWebSearchBackend: { .doubaoGlobal },
      webSearchKeyProvider: { _ in nil })
  }

  private func assertInvalidParameterIsReportedWithoutAnotherAttempt(
    message: String
  ) async {
    let qwen = Self.qwenProfile
    let mimo = Self.mimoProfile
    let expected = FamoWebSearchError.serviceError(
      code: "InvalidParameter", message: message)
    let searches = WebSearchRecorder(
      results: [Self.searchResult], failures: [.doubaoGlobal: expected])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["不应出现"])])
    let responses = ScriptedResponsesClient(streams: [Self.stream(deltas: ["不应出现"])])
    let module: FamoAskAnythingOpening = makeMatrixModule(
      gateProfile: Self.chatOnlyProfile,
      builtInProfiles: [qwen, mimo],
      builtInKeys: [qwen.secretName: "sk-qwen", mimo.secretName: "sk-mimo"],
      transport: FamoAskAnythingTransportAdapter(
        chatClient: chat, responsesClient: responses),
      webSearchKeys: [.doubaoGlobal: "sk-doubao", .qwen: "sk-qwen-search"],
      searches: searches)

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the first standalone search should open")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("generic InvalidParameter must surface without another online attempt")
    } catch {
      XCTAssertEqual(error as? FamoWebSearchError, expected)
    }

    XCTAssertEqual(searches.calls.map(\.backend), [.doubaoGlobal])
    XCTAssertTrue(responses.calls.isEmpty, "InvalidParameter must not reach a model provider")
    XCTAssertTrue(chat.calls.isEmpty, "InvalidParameter must not open another search or plain ask")
    XCTAssertEqual(open.searchProviderID, FamoWebSearchBackend.doubaoGlobal.attributionID)
  }

  private func makeMatrixModule(
    gateProfile: FamoProviderProfile,
    builtInProfiles: [FamoProviderProfile],
    builtInKeys: [String: String],
    transport: FamoAskAnythingTransporting,
    preferredWebSearchBackend: FamoWebSearchBackend = .doubaoGlobal,
    webSearchKeys: [FamoWebSearchBackend: String] = [:],
    searches: WebSearchClientRecording = WebSearchRecorder(results: [])
  ) -> FamoAskAnythingModule {
    let gate = FamoProviderAuthGate(
      profileProvider: { gateProfile },
      profileSecretProvider: { _ in "sk-answer" },
      legacyKeyProvider: { nil })
    let resolver = FamoAskSearchResolver(
      isEnabled: { true },
      profilesProvider: { builtInProfiles },
      defaultProfileProvider: { nil },
      preferredProviderID: { nil },
      secretProvider: { builtInKeys[$0] })
    return FamoAskAnythingModule(
      gate: gate,
      transport: transport,
      searchResolver: resolver,
      isWebSearchEnabled: { true },
      preferredWebSearchBackend: { preferredWebSearchBackend },
      webSearchKeyProvider: { webSearchKeys[$0] },
      webSearchClientFactory: { searches.client(for: $0) })
  }

  private static var qwenProfile: FamoProviderProfile {
    FamoProviderProfile(
      id: "qwen",
      displayName: "通义千问",
      endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")!,
      model: "qwen3.7-plus",
      providerID: "qwen",
      secretName: "famo.provider.qwen.apiKey",
      isDefault: true)
  }

  private static var mimoProfile: FamoProviderProfile {
    FamoProviderProfile(
      id: "mimo",
      displayName: "MiMo",
      endpoint: URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!,
      model: "mimo-v2.5",
      providerID: "mimo",
      secretName: "famo.provider.mimo.apiKey")
  }

  private static var chatOnlyProfile: FamoProviderProfile {
    FamoProviderProfile(
      id: "plain",
      displayName: "Plain",
      endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
      model: "plain-v1",
      providerID: "custom",
      secretName: "famo.provider.plain.apiKey",
      isDefault: true)
  }

  private static var question: [FamoDeepSeekMessage] {
    [FamoDeepSeekMessage(role: "user", content: "问题")]
  }

  private static var searchResult: FamoWebSearchResult {
    FamoWebSearchResult(
      title: "来源", url: "https://example.com", snippet: "材料",
      publishedAt: nil, hostname: "example.com")
  }

  private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var output: [String] = []
    for try await delta in stream { output.append(delta) }
    return output
  }

  private static func stream(
    deltas: [String],
    failure: Error? = nil
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      for delta in deltas { continuation.yield(delta) }
      if let failure {
        continuation.finish(throwing: failure)
      } else {
        continuation.finish()
      }
    }
  }

  private static func failingStream(_ error: Error) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish(throwing: error) }
  }
}

@MainActor
private final class InMemoryAskTransport: FamoAskAnythingTransporting {
  enum Call: Equatable {
    case plain(providerID: String)
    case builtInSearch(providerID: String)
  }

  private(set) var calls: [Call] = []
  private let plainStream: AsyncThrowingStream<String, Error>
  private let builtInStream: AsyncThrowingStream<String, Error>?

  init(
    builtInStream: AsyncThrowingStream<String, Error>? = nil,
    plainStream: AsyncThrowingStream<String, Error> = AsyncThrowingStream { $0.finish() }
  ) {
    self.builtInStream = builtInStream
    self.plainStream = plainStream
  }

  func streamPlain(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    calls.append(.plain(providerID: routing.providerID))
    return plainStream
  }

  func streamBuiltInSearch(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>? {
    calls.append(.builtInSearch(providerID: routing.providerID))
    return builtInStream
  }
}

private final class ScriptedChatClient: FamoChatStreaming, @unchecked Sendable {
  struct Call: Equatable {
    let providerID: String
    let carriesSearchFields: Bool
  }

  private var streams: [AsyncThrowingStream<String, Error>]
  private(set) var calls: [Call] = []

  init(streams: [AsyncThrowingStream<String, Error>] = []) {
    self.streams = streams
  }

  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    extraBody: [String: Any]
  ) -> AsyncThrowingStream<String, Error> {
    calls.append(.init(providerID: routing.providerID, carriesSearchFields: !extraBody.isEmpty))
    guard !streams.isEmpty else {
      return AsyncThrowingStream { $0.finish() }
    }
    return streams.removeFirst()
  }
}

private final class ScriptedResponsesClient: FamoResponsesStreaming, @unchecked Sendable {
  struct Call: Equatable {
    let providerID: String
    let dialect: FamoResponsesDialect
    let webSearch: Bool
  }

  private var streams: [AsyncThrowingStream<String, Error>]
  private(set) var calls: [Call] = []

  init(streams: [AsyncThrowingStream<String, Error>] = []) {
    self.streams = streams
  }

  func stream(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String,
    dialect: FamoResponsesDialect,
    webSearch: Bool
  ) -> AsyncThrowingStream<String, Error> {
    calls.append(.init(providerID: routing.providerID, dialect: dialect, webSearch: webSearch))
    guard !streams.isEmpty else {
      return AsyncThrowingStream { $0.finish() }
    }
    return streams.removeFirst()
  }
}

private protocol WebSearchClientRecording {
  func client(for backend: FamoWebSearchBackend) -> FamoWebSearching
}

private final class WebSearchRecorder: WebSearchClientRecording, @unchecked Sendable {
  struct Call: Equatable {
    let backend: FamoWebSearchBackend
    let query: String
    let apiKey: String
    let limit: Int
  }

  private let results: [FamoWebSearchResult]
  private let failures: [FamoWebSearchBackend: FamoWebSearchError]
  private(set) var calls: [Call] = []

  init(
    results: [FamoWebSearchResult],
    failures: [FamoWebSearchBackend: FamoWebSearchError] = [:]
  ) {
    self.results = results
    self.failures = failures
  }

  func client(for backend: FamoWebSearchBackend) -> FamoWebSearching {
    RecordingWebSearch(backend: backend, recorder: self)
  }

  private struct RecordingWebSearch: FamoWebSearching {
    let backend: FamoWebSearchBackend
    let recorder: WebSearchRecorder

    func search(
      query: String,
      apiKey: String,
      limit: Int
    ) async throws -> [FamoWebSearchResult] {
      recorder.calls.append(.init(
        backend: backend, query: query, apiKey: apiKey, limit: limit))
      if let failure = recorder.failures[backend] { throw failure }
      return recorder.results
    }
  }
}

private final class CancellableWebSearchRecorder: WebSearchClientRecording, @unchecked Sendable {
  private(set) var calls: [FamoWebSearchBackend] = []
  private let started: XCTestExpectation
  private let cancelled: XCTestExpectation

  init(started: XCTestExpectation, cancelled: XCTestExpectation) {
    self.started = started
    self.cancelled = cancelled
  }

  func client(for backend: FamoWebSearchBackend) -> FamoWebSearching {
    CancellableWebSearch(backend: backend, recorder: self)
  }

  private struct CancellableWebSearch: FamoWebSearching {
    let backend: FamoWebSearchBackend
    let recorder: CancellableWebSearchRecorder

    func search(
      query: String,
      apiKey: String,
      limit: Int
    ) async throws -> [FamoWebSearchResult] {
      recorder.calls.append(backend)
      recorder.started.fulfill()
      do {
        try await Task.sleep(nanoseconds: 60_000_000_000)
      } catch {
        recorder.cancelled.fulfill()
        throw error
      }
      return []
    }
  }
}
