//
//  OwlAskAnythingModuleTests.swift
//  OwltypeTests — 任意提问统一尝试矩阵与首 delta 前 failover（issue #113）
//
//  The module is driven through in-memory chat / Responses adapters. The tests exercise the public
//  ask seam while recording the full attempt matrix: key filtering, DeepSeek profile order,
//  transport, first-delta boundary, plain fallback, cancellation, and final attribution.
//  任意提问联网只走 DeepSeek，所以候选都是 DeepSeek 档案；别家档案只出现在普通问答里。
//

import Foundation
import XCTest
@testable import Owltype

@MainActor
final class OwlAskAnythingModuleTests: XCTestCase {

  func testConfiguredDeepSeekSearchStreamsThroughTheSeamAndKeepsAttribution() async throws {
    let transport = InMemoryAskTransport(
      builtInStream: Self.stream(deltas: ["本院", "认为"]))
    let module = makeModule(searchEnabled: true, transport: transport)

    guard case let .success(open) = module.open(
      messages: [OwlDeepSeekMessage(role: "user", content: "今天有什么新规？")]) else {
      return XCTFail("configured DeepSeek search should open")
    }

    XCTAssertEqual(open.searchProviderID, "deepseek")
    XCTAssertEqual(transport.calls, [.webSearch(providerID: "deepseek")])
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["本院", "认为"])
    XCTAssertEqual(open.searchProviderID, "deepseek", "stream completion must keep the actual signer")
  }

  func testSearchOffUsesPlainAnswerWithoutSearchAttribution() async throws {
    let transport = InMemoryAskTransport(plainStream: Self.stream(deltas: ["普通回答"]))
    let module = makeModule(searchEnabled: false, transport: transport)

    guard case let .success(open) = module.open(
      messages: [OwlDeepSeekMessage(role: "user", content: "解释一下")]) else {
      return XCTFail("plain ask should still open")
    }

    XCTAssertNil(open.searchProviderID)
    XCTAssertEqual(transport.calls, [.plain(providerID: "deepseek")])
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["普通回答"])
  }

  func testMissingConfigurationReturnsReadinessWithoutOpeningATransport() {
    let transport = InMemoryAskTransport()
    let gate = OwlProviderAuthGate(
      profileProvider: { nil },
      profileSecretProvider: { _ in XCTFail("no profile means no profile secret read"); return nil },
      legacyKeyProvider: { nil })
    let resolver = OwlAskSearchResolver(
      isEnabled: { true }, profilesProvider: { [] }, defaultProfileProvider: { nil },
      secretProvider: { _ in nil })
    let module = OwlAskAnythingModule(gate: gate, transport: transport, searchResolver: resolver)

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
      transport.calls, [.webSearch(providerID: "deepseek")],
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
      return XCTFail("configured DeepSeek search should open")
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
      transport.calls, [.webSearch(providerID: "deepseek")],
      "cancellation must not open a retry or plain fallback")
  }

  func testOtherProvidersWithKeysNeverSearchAndAnswerPlain() async throws {
    // 默认供应商是通义千问，豆包也配了 Key —— 都不承担联网，这一问直接走默认档案的普通问答。
    let qwen = Self.qwenProfile
    let doubao = Self.doubaoProfile
    let responses = ScriptedResponsesClient(streams: [Self.stream(deltas: ["普通回答"])])
    let chat = ScriptedChatClient()
    let module = makeMatrixModule(
      gateProfile: qwen,
      builtInProfiles: [qwen, doubao],
      builtInKeys: [qwen.secretName: "sk-qwen", doubao.secretName: "sk-doubao"],
      transport: Self.adapter(chat, responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("plain ask should open")
    }
    XCTAssertNil(open.searchProviderID, "没有 DeepSeek 档案就没有联网署名")
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["普通回答"])
    XCTAssertEqual(
      responses.calls, [.init(providerID: "qwen", dialect: .qwen, webSearch: false)])
    XCTAssertTrue(chat.calls.isEmpty)
  }

  func testFailsOverBetweenDeepSeekProfilesBeforeFirstDelta() async throws {
    let first = Self.deepSeekProfile(id: "ds-a")
    let second = Self.deepSeekProfile(id: "ds-b")
    let responses = ScriptedResponsesClient(streams: [
      Self.failingStream(OwlStreamingError.badHTTPStatus(401)),
      Self.stream(deltas: ["DeepSeek 回答"]),
    ])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["不应出现"])])
    let module = makeMatrixModule(
      gateProfile: Self.chatOnlyProfile,
      builtInProfiles: [first, second],
      builtInKeys: [first.secretName: "sk-a", second.secretName: "sk-b"],
      transport: Self.adapter(chat, responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the DeepSeek matrix should open")
    }
    XCTAssertEqual(open.searchProviderID, "deepseek")

    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["DeepSeek 回答"])
    XCTAssertEqual(
      responses.calls,
      [
        .init(providerID: "deepseek", dialect: .deepseek, webSearch: false),
        .init(providerID: "deepseek", dialect: .deepseek, webSearch: false),
      ])
    XCTAssertTrue(chat.calls.isEmpty, "deepseek-flash answers on /responses, without the built-in tool")
    XCTAssertEqual(open.searchProviderID, "deepseek", "attribution follows the route that yielded")
  }

  func testGenericHTTP400IsReportedWithoutOpeningAnotherProfile() async {
    let first = Self.deepSeekProfile(id: "ds-a")
    let second = Self.deepSeekProfile(id: "ds-b")
    let responses = ScriptedResponsesClient(streams: [
      Self.failingStream(OwlStreamingError.badHTTPStatus(400)),
    ])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["不应出现"])])
    let module: OwlAskAnythingOpening = makeMatrixModule(
      gateProfile: first,
      builtInProfiles: [first, second],
      builtInKeys: [first.secretName: "sk-a", second.secretName: "sk-b"],
      transport: Self.adapter(chat, responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the first DeepSeek profile should open")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("a generic request rejection must surface without another attempt")
    } catch {
      XCTAssertEqual(error as? OwlStreamingError, .badHTTPStatus(400))
    }

    XCTAssertEqual(
      responses.calls, [.init(providerID: "deepseek", dialect: .deepseek, webSearch: false)])
    XCTAssertTrue(chat.calls.isEmpty, "generic HTTP 400 must not reach plain fallback")
    XCTAssertEqual(open.searchProviderID, "deepseek")
  }

  func testEmptyStreamIsReportedWithoutOpeningAnotherProfile() async {
    let first = Self.deepSeekProfile(id: "ds-a")
    let second = Self.deepSeekProfile(id: "ds-b")
    let responses = ScriptedResponsesClient(streams: [Self.stream(deltas: [])])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["不应出现"])])
    let module = makeMatrixModule(
      gateProfile: first,
      builtInProfiles: [first, second],
      builtInKeys: [first.secretName: "sk-a", second.secretName: "sk-b"],
      transport: Self.adapter(chat, responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the first route should open")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("zero deltas must not masquerade as a successful online answer")
    } catch {
      XCTAssertEqual(error as? OwlStreamingError, .emptyResponse)
    }
    XCTAssertEqual(responses.calls.count, 1, "an empty answer is not a proven configuration refusal")
    XCTAssertTrue(chat.calls.isEmpty)
    XCTAssertEqual(open.searchProviderID, "deepseek")
  }

  func testConfigurationRefusalAfterFirstDeltaIsReportedWithoutOpeningNextAttempt() async {
    let first = Self.deepSeekProfile(id: "ds-a")
    let second = Self.deepSeekProfile(id: "ds-b")
    let responses = ScriptedResponsesClient(streams: [
      Self.stream(deltas: ["半句"], failure: OwlStreamingError.badHTTPStatus(401)),
    ])
    let chat = ScriptedChatClient(streams: [Self.stream(deltas: ["不应出现"])])
    let module = makeMatrixModule(
      gateProfile: first,
      builtInProfiles: [first, second],
      builtInKeys: [first.secretName: "sk-a", second.secretName: "sk-b"],
      transport: Self.adapter(chat, responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the first route should open")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("a failure after output starts must surface")
    } catch {
      XCTAssertEqual(error as? OwlStreamingError, .badHTTPStatus(401))
    }
    XCTAssertEqual(responses.calls.count, 1, "first delta permanently closes the failover gate")
    XCTAssertTrue(chat.calls.isEmpty)
    XCTAssertEqual(open.searchProviderID, "deepseek")
  }

  func testEveryOnlineRefusalFallsBackToPlainAndClearsAttribution() async throws {
    let first = Self.deepSeekProfile(id: "ds-a")
    let second = Self.deepSeekProfile(id: "ds-b")
    let responses = ScriptedResponsesClient(streams: [
      Self.failingStream(OwlStreamingError.badHTTPStatus(401)),
      Self.failingStream(OwlStreamingError.badHTTPStatus(403)),
    ])
    let chat = ScriptedChatClient(streams: [
      Self.stream(deltas: ["普通回答"]),
    ])
    let module = makeMatrixModule(
      gateProfile: Self.chatOnlyProfile,
      builtInProfiles: [first, second],
      builtInKeys: [first.secretName: "sk-a", second.secretName: "sk-b"],
      transport: Self.adapter(chat, responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the matrix should open before runtime refusals are known")
    }
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["普通回答"])
    XCTAssertNil(open.searchProviderID, "plain fallback must remove every online attribution")
    XCTAssertEqual(responses.calls.count, 2)
    XCTAssertEqual(chat.calls, [.init(providerID: "custom")])
  }

  func testEveryOnlineAttemptAndPlainAnswerFailThroughTheInterface() async {
    let first = Self.deepSeekProfile(id: "ds-a")
    let second = Self.deepSeekProfile(id: "ds-b")
    let responses = ScriptedResponsesClient(streams: [
      Self.failingStream(OwlStreamingError.badHTTPStatus(401)),
      Self.failingStream(OwlStreamingError.badHTTPStatus(403)),
    ])
    let chat = ScriptedChatClient(streams: [
      Self.failingStream(OwlStreamingError.badHTTPStatus(503)),
    ])
    let module: OwlAskAnythingOpening = makeMatrixModule(
      gateProfile: Self.chatOnlyProfile,
      builtInProfiles: [first, second],
      builtInKeys: [first.secretName: "sk-a", second.secretName: "sk-b"],
      transport: Self.adapter(chat, responses))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("configured attempts should open through the interface")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("the final plain transport failure must surface")
    } catch {
      XCTAssertEqual(error as? OwlStreamingError, .badHTTPStatus(503))
    }

    XCTAssertNil(open.searchProviderID, "plain fallback clears every online attribution")
    XCTAssertEqual(responses.calls.count, 2)
    XCTAssertEqual(chat.calls, [.init(providerID: "custom")])
  }

  private static func adapter(
    _ chat: ScriptedChatClient,
    _ responses: ScriptedResponsesClient,
    search: ScriptedSearchClient = ScriptedSearchClient()
  ) -> OwlAskAnythingTransportAdapter {
    OwlAskAnythingTransportAdapter(
      gateway: OwlLLMGateway(chatStreamer: chat, responsesStreamer: responses),
      searchClient: search)
  }

  /// 搜索请求被拒（Key 欠费）同样在首个 delta 前换档案；作答依据编号结果，脚注只列被引用的网页。
  func testSearchRefusalFailsOverAndTheAnswerIsFootedWithCitedResults() async throws {
    let first = Self.deepSeekProfile(id: "ds-a")
    let second = Self.deepSeekProfile(id: "ds-b")
    let results = [
      OwlWebSearchResult(title: "人大", url: "https://npc.gov.cn/a", snippet: "2021年1月1日施行",
                         publishedAt: nil, hostname: nil),
      OwlWebSearchResult(title: "百科", url: "https://baike.example.com/b", snippet: "",
                         publishedAt: nil, hostname: nil),
    ]
    let search = ScriptedSearchClient([
      .failure(OwlDeepSeekSearchError.badHTTPStatus(402)), .success(results),
    ])
    let responses = ScriptedResponsesClient(streams: [Self.stream(deltas: ["2021 年起施行 [1]。"])])
    let chat = ScriptedChatClient()
    let module = makeMatrixModule(
      gateProfile: Self.chatOnlyProfile,
      builtInProfiles: [first, second],
      builtInKeys: [first.secretName: "sk-a", second.secretName: "sk-b"],
      transport: Self.adapter(chat, responses, search: search))

    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("the DeepSeek matrix should open")
    }
    let deltas = try await collect(open.stream)

    XCTAssertEqual(search.apiKeys, ["sk-a", "sk-b"])
    XCTAssertEqual(search.endpoints.map(\.absoluteString), Array(
      repeating: "https://api.deepseek.com/v1/tools/search", count: 2))
    XCTAssertEqual(
      responses.calls, [.init(providerID: "deepseek", dialect: .deepseek, webSearch: false)],
      "被拒的那家不发作答请求")
    XCTAssertEqual(responses.lastMessages.first?.role, "system")
    XCTAssertTrue(responses.lastMessages.first?.content.contains("[1] 人大") == true)
    XCTAssertEqual(
      deltas, ["2021 年起施行 [1]。", "\n\n来源：\n[1] [人大](https://npc.gov.cn/a)"])
    XCTAssertEqual(open.searchProviderID, "deepseek")
  }

  /// 检索结果的网址不经模型改写：没有引用时也只列真取回的网页。
  func testSearchedAnswerNeverCarriesModelInventedSources() async throws {
    let profile = Self.deepSeekProfile(id: "ds-a")
    let search = ScriptedSearchClient([.success([])])
    let responses = ScriptedResponsesClient(streams: [Self.stream(deltas: ["没搜到。"])])
    let module = makeMatrixModule(
      gateProfile: profile,
      builtInProfiles: [profile],
      builtInKeys: [profile.secretName: "sk-a"],
      transport: Self.adapter(ScriptedChatClient(), responses, search: search))
    guard case let .success(open) = module.open(messages: Self.question) else {
      return XCTFail("should open")
    }
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["没搜到。"])
    XCTAssertTrue(responses.lastMessages.first?.content.contains("未检索到相关网页") == true)
  }

  private func makeModule(
    searchEnabled: Bool,
    transport: InMemoryAskTransport
  ) -> OwlAskAnythingModule {
    let profile = Self.deepSeekProfile(id: "deepseek", isDefault: true)
    let gate = OwlProviderAuthGate(
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-deepseek" },
      legacyKeyProvider: { nil })
    let resolver = OwlAskSearchResolver(
      isEnabled: { searchEnabled },
      profilesProvider: { [profile] },
      defaultProfileProvider: { profile },
      secretProvider: { _ in "sk-deepseek" })
    return OwlAskAnythingModule(gate: gate, transport: transport, searchResolver: resolver)
  }

  private func makeMatrixModule(
    gateProfile: OwlProviderProfile,
    builtInProfiles: [OwlProviderProfile],
    builtInKeys: [String: String],
    transport: OwlAskAnythingTransporting
  ) -> OwlAskAnythingModule {
    let gate = OwlProviderAuthGate(
      profileProvider: { gateProfile },
      profileSecretProvider: { _ in "sk-answer" },
      legacyKeyProvider: { nil })
    let resolver = OwlAskSearchResolver(
      isEnabled: { true },
      profilesProvider: { builtInProfiles },
      defaultProfileProvider: { nil },
      secretProvider: { builtInKeys[$0] })
    return OwlAskAnythingModule(gate: gate, transport: transport, searchResolver: resolver)
  }

  private static func deepSeekProfile(id: String, isDefault: Bool = false) -> OwlProviderProfile {
    OwlProviderProfile(
      id: id,
      displayName: "DeepSeek",
      endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
      model: "deepseek-v4-flash",
      providerID: "deepseek",
      secretName: "owltype.provider.\(id).apiKey",
      isDefault: isDefault)
  }

  private static var qwenProfile: OwlProviderProfile {
    OwlProviderProfile(
      id: "qwen",
      displayName: "通义千问",
      endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")!,
      model: "qwen3.7-plus",
      providerID: "qwen",
      secretName: "owltype.provider.qwen.apiKey",
      isDefault: true)
  }

  private static var doubaoProfile: OwlProviderProfile {
    OwlProviderProfile(
      id: "doubao",
      displayName: "豆包",
      endpoint: URL(string: "https://ark.cn-beijing.volces.com/api/v3/responses")!,
      model: "doubao-seed-2-1-pro-260628",
      providerID: "doubao",
      secretName: "owltype.provider.doubao.apiKey")
  }

  private static var chatOnlyProfile: OwlProviderProfile {
    OwlProviderProfile(
      id: "plain",
      displayName: "Plain",
      endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
      model: "plain-v1",
      providerID: "custom",
      secretName: "owltype.provider.plain.apiKey",
      isDefault: true)
  }

  private static var question: [OwlDeepSeekMessage] {
    [OwlDeepSeekMessage(role: "user", content: "问题")]
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
private final class InMemoryAskTransport: OwlAskAnythingTransporting {
  enum Call: Equatable {
    case plain(providerID: String)
    case webSearch(providerID: String)
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
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    calls.append(.plain(providerID: routing.providerID))
    return plainStream
  }

  func streamWebSearch(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>? {
    calls.append(.webSearch(providerID: routing.providerID))
    return builtInStream
  }
}

private final class ScriptedChatClient: OwlChatStreaming, @unchecked Sendable {
  struct Call: Equatable {
    let providerID: String
  }

  private var streams: [AsyncThrowingStream<String, Error>]
  private(set) var calls: [Call] = []

  init(streams: [AsyncThrowingStream<String, Error>] = []) {
    self.streams = streams
  }

  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    calls.append(.init(providerID: routing.providerID))
    guard !streams.isEmpty else {
      return AsyncThrowingStream { $0.finish() }
    }
    return streams.removeFirst()
  }
}

private final class ScriptedResponsesClient: OwlResponsesStreaming, @unchecked Sendable {
  struct Call: Equatable {
    let providerID: String
    let dialect: OwlResponsesDialect
    let webSearch: Bool
  }

  private var streams: [AsyncThrowingStream<String, Error>]
  private(set) var calls: [Call] = []
  private(set) var lastMessages: [OwlDeepSeekMessage] = []

  init(streams: [AsyncThrowingStream<String, Error>] = []) {
    self.streams = streams
  }

  func stream(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String,
    dialect: OwlResponsesDialect,
    webSearch: Bool
  ) -> AsyncThrowingStream<String, Error> {
    calls.append(.init(providerID: routing.providerID, dialect: dialect, webSearch: webSearch))
    lastMessages = messages
    guard !streams.isEmpty else {
      return AsyncThrowingStream { $0.finish() }
    }
    return streams.removeFirst()
  }
}

/// Scripted DeepSeek Search: one outcome per call, `[]` once the script runs out.
private final class ScriptedSearchClient: OwlDeepSeekSearching, @unchecked Sendable {
  private var outcomes: [Result<[OwlWebSearchResult], Error>]
  private(set) var apiKeys: [String] = []
  private(set) var endpoints: [URL] = []

  init(_ outcomes: [Result<[OwlWebSearchResult], Error>] = []) {
    self.outcomes = outcomes
  }

  func search(
    query: String, endpoint: URL, apiKey: String, limit: Int
  ) async throws -> [OwlWebSearchResult] {
    apiKeys.append(apiKey)
    endpoints.append(endpoint)
    guard !outcomes.isEmpty else { return [] }
    return try outcomes.removeFirst().get()
  }
}
