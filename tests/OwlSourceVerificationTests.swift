//
//  OwlSourceVerificationTests.swift
//  OwltypeTests — 来源核验：豆包搜索取来源 + 默认供应商对照判断
//
//  检索与判断都走注入的替身，不碰网络、不碰真钥匙串。
//

import Foundation
import XCTest
@testable import Owltype

final class OwlDoubaoSearchWireTests: XCTestCase {

  func testBodyTrimsAndCapsQueryAndClampsDocCount() {
    let long = String(repeating: "民", count: 150)
    let body = OwlDoubaoSearchWire.body(query: "  \(long)\n", limit: 99)
    XCTAssertEqual((body["Query"] as? String)?.count, OwlDoubaoSearchWire.maxQueryLength)
    XCTAssertEqual(body["DocCount"] as? Int, 20)
    XCTAssertEqual(body["MaxImageCountPerDoc"] as? Int, 1, "0 会落回默认 3 张")
    XCTAssertEqual(OwlDoubaoSearchWire.body(query: "q", limit: 0)["DocCount"] as? Int, 1)
  }

  func testRequestUsesGlobalSearchEndpointWithBearerKey() throws {
    let request = try OwlDoubaoSearchWire.request(query: "民法典", apiKey: "sk-search", limit: 5)
    XCTAssertEqual(
      request.url?.absoluteString, "https://open.feedcoopapi.com/search_api/global_search")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-search")
    XCTAssertThrowsError(try OwlDoubaoSearchWire.request(query: "q", apiKey: " ", limit: 5)) {
      XCTAssertEqual($0 as? OwlDoubaoSearchError, .missingAPIKey)
    }
  }

  func testParseKeepsTextSnippetsAndDropsUnlinkableDocuments() throws {
    let json = """
    {"Result": {"ErrorCode": 0, "Documents": [
      {"Title": "中华人民共和国民法典", "Url": "https://www.npc.gov.cn/a",
       "Snippet": [{"Type": "text", "Text": "自2021年1月1日起施行"}, {"Type": "image", "Text": "x"}],
       "DocumentInfo": {"PublishTime": "2020-06-01"}, "HostInfo": {"Hostname": "中国人大网"}},
      {"Title": "没有链接", "Url": ""},
      {"Title": "", "Url": "https://example.com/untitled"}
    ]}}
    """
    let results = try OwlDoubaoSearchWire.parse(Data(json.utf8))
    XCTAssertEqual(results, [
      OwlDoubaoSearchResult(
        title: "中华人民共和国民法典", url: "https://www.npc.gov.cn/a",
        snippet: "自2021年1月1日起施行", publishedAt: "2020-06-01", hostname: "中国人大网"),
    ])
  }

  func testParseSurfacesBothErrorChannelsInsteadOfAnEmptyList() {
    let metaError = #"{"ResponseMetadata": {"Error": {"Code": "700901", "Message": "invalid"}}}"#
    XCTAssertThrowsError(try OwlDoubaoSearchWire.parse(Data(metaError.utf8))) {
      XCTAssertEqual($0 as? OwlDoubaoSearchError, .serviceError(code: "700901", message: "invalid"))
    }
    let resultError = #"{"Result": {"ErrorCode": 10409, "ErrorMsg": "plan key"}}"#
    XCTAssertThrowsError(try OwlDoubaoSearchWire.parse(Data(resultError.utf8))) {
      XCTAssertEqual($0 as? OwlDoubaoSearchError, .serviceError(code: "10409", message: "plan key"))
    }
    XCTAssertThrowsError(try OwlDoubaoSearchWire.parse(Data("<html>".utf8))) {
      XCTAssertEqual($0 as? OwlDoubaoSearchError, .malformedResponse)
    }
  }

  func testParseToleratesRawControlCharactersInSnippets() throws {
    let json = "{\"Result\": {\"Documents\": [{\"Title\": \"T\", \"Url\": \"https://a\", "
      + "\"Snippet\": [{\"Type\": \"text\", \"Text\": \"甲\u{01}乙\"}]}]}}"
    let results = try OwlDoubaoSearchWire.parse(Data(json.utf8))
    XCTAssertEqual(results.first?.snippet, "甲 乙")
  }

  func testKeyStoreReadsTheSharedAccountAndIgnoresBlankKeys() throws {
    let secrets = OwlInMemorySecretStore()
    XCTAssertFalse(OwlDoubaoSearchKeyStore.isConfigured(secrets: secrets))
    try secrets.setSecret("  ", named: OwlDoubaoSearchKeyStore.secretName)
    XCTAssertNil(OwlDoubaoSearchKeyStore.apiKey(secrets: secrets))
    try secrets.setSecret(" sk-search ", named: "owltype.websearch.doubao.apiKey")
    XCTAssertEqual(
      OwlDoubaoSearchKeyStore.apiKey(secrets: secrets), "sk-search",
      "沿用旧独立搜索层的 account，存过 Key 的用户不用重填")
  }

  func testSettingsActionsSaveTrimmedKeyAndClearIt() {
    let secrets = OwlInMemorySecretStore()
    let blank = OwlSettingsActions.saveDoubaoSearchKey("   ", secrets: secrets)
    XCTAssertEqual(blank.status, "请输入豆包搜索的 API Key")
    XCTAssertFalse(OwlDoubaoSearchKeyStore.isConfigured(secrets: secrets))

    let saved = OwlSettingsActions.saveDoubaoSearchKey(" sk-search \n", secrets: secrets)
    XCTAssertEqual(saved.input, "", "保存后清空输入框，Key 不留在界面上")
    XCTAssertEqual(OwlDoubaoSearchKeyStore.apiKey(secrets: secrets), "sk-search")

    _ = OwlSettingsActions.clearDoubaoSearchKey(secrets: secrets)
    XCTAssertFalse(OwlDoubaoSearchKeyStore.isConfigured(secrets: secrets))
  }
}

@MainActor
final class OwlSourceVerificationServiceTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    OwlCloudPreferences.resetForTesting()
    OwlCloudPreferences.isEnabled = true
  }

  override func tearDown() async throws {
    OwlCloudPreferences.resetForTesting()
    try await super.tearDown()
  }

  private static let claim = "《中华人民共和国民法典》自2021年1月1日起施行。"

  private static let results = [
    OwlDoubaoSearchResult(
      title: "百科转载", url: "https://baike.example.com/a", snippet: "民法典施行日期",
      publishedAt: nil, hostname: "baike.example.com"),
    OwlDoubaoSearchResult(
      title: "中华人民共和国民法典", url: "https://www.npc.gov.cn/a",
      snippet: "本法自2021年1月1日起施行", publishedAt: "2020-06-01", hostname: "中国人大网"),
  ]

  func testSearchesWithTheSelectionAndJudgesOnTheDefaultProvider() async throws {
    let search = StubSearch(results: Self.results)
    let transport = StubTransport(deltas: ["属实。", "依据 [2] 第1260条。"])
    let service = makeService(search: search, transport: transport)

    let outcome = try await service.verifyStructured(Self.claim)

    XCTAssertEqual(search.queries, [Self.claim])
    XCTAssertEqual(search.lastKey, "sk-search")
    XCTAssertEqual(outcome.content, "属实。依据 [2] 第1260条。")
    XCTAssertEqual(
      outcome.sources.map(\.url), ["https://www.npc.gov.cn/a", "https://baike.example.com/a"],
      "模型引用的那条排第一：回执卡拿第一条当核到的来源")

    XCTAssertEqual(transport.calls.count, 1)
    let messages = try XCTUnwrap(transport.calls.first)
    XCTAssertEqual(messages.first?.content, OwlSourceVerificationService.systemPrompt)
    let user = try XCTUnwrap(messages.last?.content)
    XCTAssertTrue(user.contains(Self.claim))
    XCTAssertTrue(user.contains("[2] 中华人民共和国民法典"))
    XCTAssertTrue(user.contains("网址：https://www.npc.gov.cn/a"))
    XCTAssertTrue(user.contains("发布时间：2020-06-01"))
  }

  func testMissingSearchKeyFailsBeforeAnyRequest() async {
    let search = StubSearch(results: Self.results)
    let transport = StubTransport(deltas: ["不应出现"])
    let service = makeService(search: search, transport: transport, searchKey: nil)

    await assertThrows(service, .missingSearchKey)
    XCTAssertTrue(search.queries.isEmpty)
    XCTAssertTrue(transport.calls.isEmpty)
    let hint = OwlSourceVerificationService.message(
      for: OwlSourceVerificationError.missingSearchKey)
    XCTAssertTrue(hint.contains("豆包搜索") && hint.contains("DeepSeek"))
  }

  func testCloudOffFailsBeforeAnyRequest() async {
    OwlCloudPreferences.isEnabled = false
    let search = StubSearch(results: Self.results)
    await assertThrows(makeService(search: search, transport: StubTransport()), .disabled)
    XCTAssertTrue(search.queries.isEmpty)
  }

  func testNoSearchResultsIsNotFoundWithoutAskingTheModel() async {
    let transport = StubTransport(deltas: ["不应出现"])
    await assertThrows(
      makeService(search: StubSearch(results: []), transport: transport), .emptyResponse)
    XCTAssertTrue(transport.calls.isEmpty, "没有来源就不让模型凭记忆判断")
  }

  func testSearchServiceErrorIsReportedWithAKeyHint() async {
    let failure = OwlDoubaoSearchError.serviceError(code: "700901", message: "invalid")
    let transport = StubTransport()
    await assertThrows(
      makeService(search: StubSearch(failure: failure), transport: transport), .search(failure))
    XCTAssertTrue(transport.calls.isEmpty)
    XCTAssertTrue(
      OwlSourceVerificationService.message(for: OwlSourceVerificationError.search(failure))
        .contains("按量后付费"))
  }

  func testWithoutADefaultProviderReturnsSourcesForManualReview() async throws {
    let transport = StubTransport(deltas: ["不应出现"])
    let service = makeService(
      search: StubSearch(results: Self.results), transport: transport, profile: nil)

    let outcome = try await service.verifyStructured(Self.claim)

    XCTAssertEqual(outcome.content, "")
    XCTAssertEqual(outcome.sources.count, 2)
    XCTAssertTrue(transport.calls.isEmpty)
  }

  func testJudgingHTTPErrorIsReported() async {
    let transport = StubTransport(failure: OwlStreamingError.badHTTPStatus(401))
    await assertThrows(
      makeService(search: StubSearch(results: Self.results), transport: transport),
      .badHTTPStatus(401))
  }

  func testCitedFirstIgnoresOutOfRangeAndRepeatedCitations() {
    let sources = (1...3).map { OwlVerifiedSource(title: "\($0)", url: "https://\($0)") }
    XCTAssertEqual(
      OwlSourceVerificationService.citedFirst(sources, in: "见 [3]、[9]、[3] 与 [1]").map(\.title),
      ["3", "1", "2"])
    XCTAssertEqual(OwlSourceVerificationService.citedFirst([], in: "[1]"), [])
  }

  // MARK: - DeepSeek 内置联网

  private static let deepSeekPayload = #"""
    {
      "model":"deepseek-v4-flash",
      "output":[
        {"type":"web_search_call","action":{"sources":[{"type":"url","url":"https://flk.npc.gov.cn/x"}]}},
        {"type":"message","content":[{"type":"output_text",
          "text":"属实。见 [2] 与 [国家法律法规数据库](https://flk.npc.gov.cn/x)、[新华网](https://news.cn/y)。"}]}
      ],
      "usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}
    }
    """#

  func testDeepSeekAloneSearchesAndJudgesInOneCall() async throws {
    let search = StubSearch(results: Self.results)
    let transport = StubTransport(deltas: ["不应出现"])
    let web = StubWebSearch([(200, Self.deepSeekPayload)])
    let service = makeService(
      search: search, transport: transport, searchKey: nil, webSearch: web, routes: 1)

    let outcome = try await service.verifyStructured(Self.claim)

    XCTAssertTrue(search.queries.isEmpty, "没配豆包 Key 就不调豆包")
    XCTAssertTrue(transport.calls.isEmpty, "DeepSeek 自己判断，不再交默认供应商")
    XCTAssertTrue(outcome.content.hasPrefix("属实。"))
    XCTAssertEqual(
      outcome.sources,
      [
        OwlVerifiedSource(title: "flk.npc.gov.cn", url: "https://flk.npc.gov.cn/x"),
        OwlVerifiedSource(title: "新华网", url: "https://news.cn/y"),
      ],
      "结构化来源与正文链接合并去重，空标题用域名顶上")

    let request = try XCTUnwrap(web.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/responses")
    XCTAssertEqual(request.timeoutInterval, OwlSourceVerificationService.webSearchTimeout)
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "deepseek-v4-flash")
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search")
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    XCTAssertEqual(Self.text(of: input.first), OwlSourceVerificationService.webSearchSystemPrompt)
    XCTAssertEqual(
      Self.text(of: input.last), OwlSourceVerificationService.webSearchUserPrompt(for: Self.claim))
  }

  func testBothSearchesFeedDoubaoResultsToDeepSeek() async throws {
    let search = StubSearch(results: Self.results)
    let transport = StubTransport(deltas: ["不应出现"])
    let web = StubWebSearch([(200, Self.deepSeekPayload)])
    let service = makeService(search: search, transport: transport, webSearch: web, routes: 1)

    let outcome = try await service.verifyStructured(Self.claim)

    XCTAssertEqual(search.queries, [Self.claim])
    XCTAssertTrue(transport.calls.isEmpty)
    XCTAssertEqual(
      outcome.sources.map(\.url),
      [
        "https://www.npc.gov.cn/a", "https://baike.example.com/a",
        "https://flk.npc.gov.cn/x", "https://news.cn/y",
      ],
      "豆包结果按 [序号] 引用排前，DeepSeek 自己搜到的接在后面")
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(web.requests.first?.httpBody)) as? [String: Any])
    let user = try XCTUnwrap(Self.text(of: (body["input"] as? [[String: Any]])?.last))
    XCTAssertEqual(user, OwlSourceVerificationService.userPrompt(for: Self.claim, results: Self.results))
  }

  func testDoubaoFailureFallsThroughToDeepSeek() async throws {
    let failure = OwlDoubaoSearchError.serviceError(code: "10409", message: "plan")
    let web = StubWebSearch([(200, Self.deepSeekPayload)])
    let outcome = try await makeService(
      search: StubSearch(failure: failure), transport: StubTransport(), webSearch: web, routes: 1
    ).verifyStructured(Self.claim)
    XCTAssertEqual(outcome.sources.first?.url, "https://flk.npc.gov.cn/x")
  }

  func testRefusedDeepSeekProfileFailsOverToTheNextOne() async throws {
    let web = StubWebSearch([(401, "{}"), (200, Self.deepSeekPayload)])
    let outcome = try await makeService(
      search: StubSearch(), transport: StubTransport(), searchKey: nil, webSearch: web, routes: 2
    ).verifyStructured(Self.claim)
    XCTAssertEqual(web.requests.count, 2)
    XCTAssertEqual(web.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                   ["Bearer sk-ds-0", "Bearer sk-ds-1"])
    XCTAssertTrue(outcome.content.hasPrefix("属实。"))
  }

  func testAllDeepSeekProfilesRefusedFallsBackToDoubaoJudging() async throws {
    let transport = StubTransport(deltas: ["依据 [2]。"])
    let web = StubWebSearch([(402, "{}")])
    let outcome = try await makeService(
      search: StubSearch(results: Self.results), transport: transport, webSearch: web, routes: 1
    ).verifyStructured(Self.claim)
    XCTAssertEqual(transport.calls.count, 1)
    XCTAssertEqual(outcome.sources.first?.url, "https://www.npc.gov.cn/a")
  }

  func testAllDeepSeekProfilesRefusedWithoutDoubaoReportsTheStatus() async {
    let web = StubWebSearch([(402, "{}")])
    await assertThrows(
      makeService(
        search: StubSearch(), transport: StubTransport(), searchKey: nil, webSearch: web, routes: 1),
      .badHTTPStatus(402))
  }

  func testDeepSeekServerErrorIsReportedWithoutTryingAnotherProfile() async {
    let transport = StubTransport(deltas: ["不应出现"])
    let web = StubWebSearch([(500, "{}"), (200, Self.deepSeekPayload)])
    await assertThrows(
      makeService(
        search: StubSearch(results: Self.results), transport: transport, webSearch: web, routes: 2),
      .badHTTPStatus(500))
    XCTAssertEqual(web.requests.count, 1, "非配置拒绝不换家，也不再把选区发给默认供应商")
    XCTAssertTrue(transport.calls.isEmpty)
  }

  func testLinkedSourcesReadsMarkdownLinksOnly() {
    XCTAssertEqual(
      OwlSourceVerificationService.linkedSources(
        in: "见 [人大网](https://npc.gov.cn/a) 与 https://bare.example.com 和 [2]"),
      [OwlVerifiedSource(title: "人大网", url: "https://npc.gov.cn/a")])
  }

  // MARK: - Helpers

  private func makeService(
    search: StubSearch,
    transport: StubTransport,
    searchKey: String? = "sk-search",
    webSearch: StubWebSearch? = nil,
    routes: Int = 0,
    profile: OwlProviderProfile? = OwlProviderProfile(
      displayName: "DeepSeek",
      endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
      model: "deepseek-v4-flash",
      providerID: "deepseek",
      secretName: "owltype.provider.unit.apiKey",
      isDefault: true)
  ) -> OwlSourceVerificationService {
    OwlSourceVerificationService(
      searchClient: search,
      searchKeyProvider: { searchKey },
      webSearchRoutesProvider: { Self.deepSeekRoutes(count: routes) },
      webSearchFetch: webSearch.map { stub in { try await stub.fetch($0) } },
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-model" },
      legacyKeyProvider: { nil },
      transport: transport)
  }

  /// DeepSeek 方言的 input 是 `input_text` 内容块，取出其中的文字。
  private static func text(of message: [String: Any]?) -> String? {
    (message?["content"] as? [[String: Any]])?.first?["text"] as? String
  }

  private static func deepSeekRoutes(count: Int) -> [OwlAskSearchRoute] {
    (0..<count).map {
      OwlAskSearchRoute(
        routing: OwlCloudRouting(
          providerID: "deepseek",
          endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
          model: "deepseek-v4-flash",
          secretName: "owltype.provider.ds\($0).apiKey",
          authHeaderStyle: .bearer),
        apiKey: "sk-ds-\($0)")
    }
  }

  private func assertThrows(
    _ service: OwlSourceVerificationService,
    _ expected: OwlSourceVerificationError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await service.verifyStructured(Self.claim)
      XCTFail("expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? OwlSourceVerificationError, expected, file: file, line: line)
    }
  }
}

/// 按顺序回放 (HTTP 状态, 响应体)，记下发出的请求。
private final class StubWebSearch: @unchecked Sendable {
  private var replies: [(Int, String)]
  private(set) var requests: [URLRequest] = []

  init(_ replies: [(Int, String)]) { self.replies = replies }

  func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let (status, body) = replies.removeFirst()
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
  }
}

private final class StubSearch: OwlDoubaoSearching, @unchecked Sendable {
  private let results: [OwlDoubaoSearchResult]
  private let failure: OwlDoubaoSearchError?
  private(set) var queries: [String] = []
  private(set) var lastKey: String?

  init(results: [OwlDoubaoSearchResult] = [], failure: OwlDoubaoSearchError? = nil) {
    self.results = results
    self.failure = failure
  }

  func search(query: String, apiKey: String, limit: Int) async throws -> [OwlDoubaoSearchResult] {
    queries.append(query)
    lastKey = apiKey
    if let failure { throw failure }
    return results
  }
}

@MainActor
private final class StubTransport: OwlAskAnythingTransporting {
  private let deltas: [String]
  private let failure: Error?
  private(set) var calls: [[OwlDeepSeekMessage]] = []

  init(deltas: [String] = [], failure: Error? = nil) {
    self.deltas = deltas
    self.failure = failure
  }

  func streamPlain(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    calls.append(messages)
    let deltas = deltas
    let failure = failure
    return AsyncThrowingStream { continuation in
      for delta in deltas { continuation.yield(delta) }
      continuation.finish(throwing: failure)
    }
  }

  func streamBuiltInSearch(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>? {
    XCTFail("来源核验不走模型内置搜索")
    return nil
  }
}
