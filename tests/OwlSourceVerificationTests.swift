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
    XCTAssertEqual((body["Query"] as? String)?.count, 100)
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
      OwlWebSearchResult(
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
    OwlWebSearchResult(
      title: "百科转载", url: "https://baike.example.com/a", snippet: "民法典施行日期",
      publishedAt: nil, hostname: "baike.example.com"),
    OwlWebSearchResult(
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
    XCTAssertEqual(messages.first?.role, "system")
    XCTAssertTrue(messages.first?.content.contains("核验") == true)
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

  func testCitedFirstIgnoresOutOfRangeAndRepeatedCitations() async throws {
    let sources = (1...3).map {
      OwlWebSearchResult(
        title: "\($0)", url: "https://\($0)", snippet: "摘要\($0)",
        publishedAt: nil, hostname: nil)
    }
    let outcome = try await makeService(
      search: StubSearch(results: sources),
      transport: StubTransport(deltas: ["见 [3]、[9]、[3] 与 [1]"])
    ).verifyStructured(Self.claim)
    XCTAssertEqual(outcome.sources.map(\.title), ["3", "1", "2"])
  }

  // MARK: - DeepSeek 搜索

  private static let deepSeekResults = [
    OwlWebSearchResult(
      title: "国家法律法规数据库", url: "https://flk.npc.gov.cn/x", snippet: "民法典 2021年1月1日施行",
      publishedAt: "2020-05-28", hostname: "国家法律法规数据库"),
    OwlWebSearchResult(
      title: "人大网重复", url: "https://www.npc.gov.cn/a", snippet: "重复网址",
      publishedAt: nil, hostname: nil),
  ]

  func testDeepSeekAloneSearchesAndFlashJudges() async throws {
    let search = StubSearch(results: Self.results)
    let deepSeek = StubDeepSeekSearch([.success(Self.deepSeekResults)])
    let transport = StubTransport(deltas: ["属实，见 [1]。"])
    let outcome = try await makeService(
      search: search, transport: transport, searchKey: nil, deepSeek: deepSeek, routes: 1
    ).verifyStructured(Self.claim)

    XCTAssertTrue(search.queries.isEmpty, "没配豆包 Key 就不调豆包")
    XCTAssertEqual(deepSeek.queries, [Self.claim])
    XCTAssertEqual(deepSeek.endpoints.map(\.absoluteString), ["https://api.deepseek.com/v1/tools/search"])
    XCTAssertEqual(transport.apiKeys, ["sk-ds-0"], "搜索认过的 DeepSeek 档案来判断，不交默认供应商")
    XCTAssertEqual(transport.models, [OwlSearchControl.searchModel])
    XCTAssertEqual(outcome.content, "属实，见 [1]。")
    XCTAssertEqual(outcome.sources.map(\.url), ["https://flk.npc.gov.cn/x", "https://www.npc.gov.cn/a"])
  }

  func testBothSearchesAreMergedByURLAndNumberedOnce() async throws {
    let transport = StubTransport(deltas: ["依据 [3]。"])
    let outcome = try await makeService(
      search: StubSearch(results: Self.results), transport: transport,
      deepSeek: StubDeepSeekSearch([.success(Self.deepSeekResults)]), routes: 1
    ).verifyStructured(Self.claim)

    let user = try XCTUnwrap(transport.calls.first?.last?.content)
    XCTAssertTrue(user.contains("[1] 国家法律法规数据库"))
    XCTAssertTrue(user.contains("[2] 人大网重复"))
    XCTAssertTrue(user.contains("[3] 百科转载"))
    XCTAssertEqual(user.components(separatedBy: "https://www.npc.gov.cn/a").count, 2, "DeepSeek 在前，重复网址只留先到的一条")
    XCTAssertEqual(
      outcome.sources.map(\.url),
      ["https://baike.example.com/a", "https://flk.npc.gov.cn/x", "https://www.npc.gov.cn/a"],
      "被引用的 [3] 排第一，其余保留合并去重顺序")
  }

  func testDoubaoFailureFallsThroughToDeepSeek() async throws {
    let failure = OwlDoubaoSearchError.serviceError(code: "10409", message: "plan")
    let outcome = try await makeService(
      search: StubSearch(failure: failure), transport: StubTransport(deltas: ["属实。"]),
      deepSeek: StubDeepSeekSearch([.success(Self.deepSeekResults)]), routes: 1
    ).verifyStructured(Self.claim)
    XCTAssertEqual(outcome.sources.first?.url, "https://flk.npc.gov.cn/x")
  }

  func testRefusedDeepSeekSearchFailsOverToTheNextProfile() async throws {
    let deepSeek = StubDeepSeekSearch([
      .failure(OwlDeepSeekSearchError.badHTTPStatus(401)), .success(Self.deepSeekResults),
    ])
    let transport = StubTransport(deltas: ["属实。"])
    _ = try await makeService(
      search: StubSearch(), transport: transport, searchKey: nil, deepSeek: deepSeek, routes: 2
    ).verifyStructured(Self.claim)
    XCTAssertEqual(deepSeek.apiKeys, ["sk-ds-0", "sk-ds-1"])
    XCTAssertEqual(transport.apiKeys, ["sk-ds-1"])
  }

  func testAllDeepSeekProfilesRefusedFallsBackToDoubaoAndTheDefaultProvider() async throws {
    let transport = StubTransport(deltas: ["依据 [2]。"])
    let outcome = try await makeService(
      search: StubSearch(results: Self.results), transport: transport,
      deepSeek: StubDeepSeekSearch([.failure(OwlDeepSeekSearchError.badHTTPStatus(402))]), routes: 1
    ).verifyStructured(Self.claim)
    XCTAssertEqual(transport.apiKeys, ["sk-model"])
    XCTAssertEqual(outcome.sources.first?.url, "https://www.npc.gov.cn/a")
  }

  func testAllDeepSeekProfilesRefusedWithoutDoubaoReportsTheStatus() async {
    await assertThrows(
      makeService(
        search: StubSearch(), transport: StubTransport(), searchKey: nil,
        deepSeek: StubDeepSeekSearch([.failure(OwlDeepSeekSearchError.badHTTPStatus(402))]),
        routes: 1),
      .badHTTPStatus(402))
  }

  func testDeepSeekServerErrorDoesNotTryAnotherProfile() async throws {
    let deepSeek = StubDeepSeekSearch([
      .failure(OwlDeepSeekSearchError.badHTTPStatus(500)), .success(Self.deepSeekResults),
    ])
    let transport = StubTransport(deltas: ["依据 [2]。"])
    _ = try await makeService(
      search: StubSearch(results: Self.results), transport: transport, deepSeek: deepSeek, routes: 2
    ).verifyStructured(Self.claim)
    XCTAssertEqual(deepSeek.apiKeys, ["sk-ds-0"], "非配置拒绝不换家")
    XCTAssertEqual(transport.apiKeys, ["sk-model"], "豆包结果仍可由默认供应商判断")
  }

  func testRefusedDeepSeekJudgeFallsBackToTheDefaultProvider() async throws {
    let transport = StubTransport(deltas: ["属实。"], failFirst: OwlStreamingError.badHTTPStatus(402))
    let outcome = try await makeService(
      search: StubSearch(), transport: transport, searchKey: nil,
      deepSeek: StubDeepSeekSearch([.success(Self.deepSeekResults)]), routes: 1
    ).verifyStructured(Self.claim)
    XCTAssertEqual(transport.apiKeys, ["sk-ds-0", "sk-model"])
    XCTAssertEqual(outcome.content, "属实。")
  }

  func testEmptySearchesNeverReachAModel() async {
    let transport = StubTransport(deltas: ["不应出现"])
    await assertThrows(
      makeService(
        search: StubSearch(), transport: transport,
        deepSeek: StubDeepSeekSearch([.success([])]), routes: 1),
      .emptyResponse)
    XCTAssertTrue(transport.calls.isEmpty, "没有检索结果就不让模型凭记忆判断")
  }

  // MARK: - Helpers

  private func makeService(
    search: StubSearch,
    transport: StubTransport,
    searchKey: String? = "sk-search",
    deepSeek: StubDeepSeekSearch = StubDeepSeekSearch(),
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
      deepSeekSearchClient: deepSeek,
      deepSeekRoutesProvider: { Self.deepSeekRoutes(count: routes) },
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-model" },
      legacyKeyProvider: { nil },
      transport: transport)
  }

  private static func deepSeekRoutes(count: Int) -> [OwlAskSearchRoute] {
    (0..<count).map {
      OwlAskSearchRoute(
        routing: OwlCloudRouting(
          providerID: "deepseek",
          endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
          model: OwlSearchControl.searchModel,
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

/// 按顺序回放 DeepSeek 搜索结果，脚本用完后回空列表。
private final class StubDeepSeekSearch: OwlDeepSeekSearching, @unchecked Sendable {
  private var outcomes: [Result<[OwlWebSearchResult], Error>]
  private(set) var queries: [String] = []
  private(set) var apiKeys: [String] = []
  private(set) var endpoints: [URL] = []

  init(_ outcomes: [Result<[OwlWebSearchResult], Error>] = []) { self.outcomes = outcomes }

  func search(
    query: String, endpoint: URL, apiKey: String, limit: Int
  ) async throws -> [OwlWebSearchResult] {
    queries.append(query)
    apiKeys.append(apiKey)
    endpoints.append(endpoint)
    guard !outcomes.isEmpty else { return [] }
    return try outcomes.removeFirst().get()
  }
}

private final class StubSearch: OwlDoubaoSearching, @unchecked Sendable {
  private let results: [OwlWebSearchResult]
  private let failure: OwlDoubaoSearchError?
  private(set) var queries: [String] = []
  private(set) var lastKey: String?

  init(results: [OwlWebSearchResult] = [], failure: OwlDoubaoSearchError? = nil) {
    self.results = results
    self.failure = failure
  }

  func search(query: String, apiKey: String, limit: Int) async throws -> [OwlWebSearchResult] {
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
  private var failFirst: Error?
  private(set) var calls: [[OwlDeepSeekMessage]] = []
  private(set) var apiKeys: [String] = []
  private(set) var models: [String] = []

  init(deltas: [String] = [], failure: Error? = nil, failFirst: Error? = nil) {
    self.deltas = deltas
    self.failure = failure
    self.failFirst = failFirst
  }

  func streamPlain(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    calls.append(messages)
    apiKeys.append(apiKey)
    models.append(routing.model)
    if let first = failFirst {
      failFirst = nil
      return AsyncThrowingStream { $0.finish(throwing: first) }
    }
    let deltas = deltas
    let failure = failure
    return AsyncThrowingStream { continuation in
      for delta in deltas { continuation.yield(delta) }
      continuation.finish(throwing: failure)
    }
  }

  func streamWebSearch(
    messages: [OwlDeepSeekMessage],
    routing: OwlCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>? {
    XCTFail("来源核验自己检索，不走任意提问的联网流")
    return nil
  }
}
