//
//  OwlWebSearchTests.swift
//  OwltypeTests — 任意提问「先检索、再作答」的搜索层
//
//  钉住三件在实盘上咬过人的事（2026-07-27 对 open.feedcoopapi.com 实测）：
//    1. 豆包搜索**出错时 HTTP 仍是 200**，错误藏在 body 里 —— 只看状态码会把「Key 无效」当成
//       「没搜到」，用户会以为搜索能用只是没结果。
//    2. Query 有 100 字符上限且不支持多词，长提问必须截断。
//    3. 检索失败绝不能让这一问失败（联网是加分项）。
//
//  No network: 客户端的 fetch 闭包被注入。
//

import Foundation
import XCTest
@testable import Owltype

final class OwlWebSearchTests: XCTestCase {

  // MARK: - 请求 wire format

  func testRequestCarriesBearerKeyAndDocumentedFields() throws {
    let request = try OwlDoubaoGlobalSearchWire.request(
      query: "北京周边游玩景点推荐", apiKey: "sk-search", limit: 5)
    XCTAssertEqual(request.url, OwlDoubaoGlobalSearchWire.endpoint)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-search")
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(object["Query"] as? String, "北京周边游玩景点推荐")
    XCTAssertEqual(object["DocCount"] as? Int, 5)
  }

  func testMissingKeyThrowsBeforeAnyRequestIsBuilt() {
    XCTAssertThrowsError(
      try OwlDoubaoGlobalSearchWire.request(query: "q", apiKey: "   ", limit: 5)
    ) { error in
      XCTAssertEqual(error as? OwlWebSearchError, .missingAPIKey)
    }
  }

  /// 文档：DocCount 最多 20。越界的请求会被服务端拒，夹在本地更省一次往返。
  func testDocCountIsClampedToTheDocumentedRange() {
    XCTAssertEqual(
      OwlDoubaoGlobalSearchWire.body(query: "q", limit: 999)["DocCount"] as? Int, 20)
    XCTAssertEqual(
      OwlDoubaoGlobalSearchWire.body(query: "q", limit: 0)["DocCount"] as? Int, 1)
  }

  /// Query 上限 100 字符。按 Character 截，别把中文截成半个码点。
  func testLongQueryIsTruncatedByCharacterNotByte() {
    let long = String(repeating: "北", count: 150)
    let query = try! XCTUnwrap(
      OwlDoubaoGlobalSearchWire.body(query: long, limit: 5)["Query"] as? String)
    XCTAssertEqual(query.count, 100)
    XCTAssertEqual(query, String(repeating: "北", count: 100))
  }

  // MARK: - 响应解析

  func testParseExtractsDocumentsAndJoinsOnlyTextSnippets() throws {
    let json = """
      {"ResponseMetadata":{"RequestId":"r1"},
       "Result":{"TotalDocCount":20,"ErrorCode":0,"ErrorMsg":"",
       "Documents":[{"Rank":0,"Url":"https://example.com/a","Title":"标题 A",
         "Snippet":[{"Type":"text","Text":"第一段"},
                    {"Type":"image","Image":{"ImageUrl":"https://img"}},
                    {"Type":"text","Text":"第二段"}],
         "DocumentInfo":{"PublishTime":"2026-07-01","Filetype":"webpage"},
         "HostInfo":{"Hostname":"抖音百科"}}]}}
      """
    let results = try OwlDoubaoGlobalSearchWire.parse(Data(json.utf8))
    XCTAssertEqual(results.count, 1)
    let first = try XCTUnwrap(results.first)
    XCTAssertEqual(first.title, "标题 A")
    XCTAssertEqual(first.url, "https://example.com/a")
    XCTAssertEqual(first.snippet, "第一段\n第二段", "图片段不进摘要，只留 text")
    XCTAssertEqual(first.publishedAt, "2026-07-01")
    XCTAssertEqual(first.hostname, "抖音百科")
  }

  /// 回归：实测 `700901 invalid_api_key` 就是这么回的 —— HTTP 200，错误在 body。
  func testServiceErrorInsideHTTP200IsThrownNotSwallowedAsEmpty() {
    let json = """
      {"ResponseMetadata":{"RequestId":"r1",
        "Error":{"CodeN":700901,"Code":"invalid_api_key","Message":"invalid api key"}},
       "Result":null}
      """
    XCTAssertThrowsError(try OwlDoubaoGlobalSearchWire.parse(Data(json.utf8))) { error in
      XCTAssertEqual(
        error as? OwlWebSearchError,
        .serviceError(code: "invalid_api_key", message: "invalid api key"))
    }
  }

  /// Result 层还有第二个错误通道，同样不能吞成空结果。
  func testResultLevelErrorCodeIsThrown() {
    let json = """
      {"ResponseMetadata":{"RequestId":"r1"},
       "Result":{"Documents":[],"ErrorCode":10410,"ErrorMsg":"no package"}}
      """
    XCTAssertThrowsError(try OwlDoubaoGlobalSearchWire.parse(Data(json.utf8))) { error in
      XCTAssertEqual(error as? OwlWebSearchError, .serviceError(code: "10410", message: "no package"))
    }
  }

  /// 没有 Url / Title 的条目引用不了，丢弃而不是留个空壳给模型。
  func testDocumentsWithoutURLOrTitleAreDropped() throws {
    let json = """
      {"ResponseMetadata":{"RequestId":"r1"},
       "Result":{"ErrorCode":0,"Documents":[
         {"Rank":0,"Url":"","Title":"无网址"},
         {"Rank":1,"Url":"https://ok","Title":""},
         {"Rank":2,"Url":"https://ok2","Title":"好的"}]}}
      """
    let results = try OwlDoubaoGlobalSearchWire.parse(Data(json.utf8))
    XCTAssertEqual(results.map(\.title), ["好的"])
  }

  // MARK: - 客户端

  func testClientSurfacesNon2xxAsBadHTTPStatus() async {
    let client = OwlDoubaoGlobalSearchClient(fetch: { request in
      (Data(), HTTPURLResponse(
        url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    })
    do {
      _ = try await client.search(query: "q", apiKey: "sk", limit: 3)
      XCTFail("expected a thrown error")
    } catch {
      XCTAssertEqual(error as? OwlWebSearchError, .badHTTPStatus(500))
    }
  }

  func testClientReturnsParsedResultsOn200() async throws {
    let json = """
      {"ResponseMetadata":{"RequestId":"r1"},
       "Result":{"ErrorCode":0,"Documents":[
         {"Rank":0,"Url":"https://a","Title":"A","Snippet":[{"Type":"text","Text":"甲"}]}]}}
      """
    let client = OwlDoubaoGlobalSearchClient(fetch: { request in
      (Data(json.utf8), HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let results = try await client.search(query: "q", apiKey: "sk", limit: 3)
    XCTAssertEqual(results.map(\.url), ["https://a"])
  }

  // MARK: - 注入模型的上下文

  func testQueryIsTheLastUserMessage() {
    let messages = [
      OwlDeepSeekMessage(role: "system", content: "你是助手"),
      OwlDeepSeekMessage(role: "user", content: "第一问"),
      OwlDeepSeekMessage(role: "assistant", content: "第一答"),
      OwlDeepSeekMessage(role: "user", content: "  第二问  "),
    ]
    XCTAssertEqual(OwlWebSearchContext.query(from: messages), "第二问")
    XCTAssertNil(OwlWebSearchContext.query(from: [
      OwlDeepSeekMessage(role: "system", content: "只有系统消息"),
    ]))
  }

  func testEmptyResultsInjectNothing() {
    let messages = [OwlDeepSeekMessage(role: "user", content: "问题")]
    XCTAssertNil(OwlWebSearchContext.systemMessage(results: []))
    XCTAssertEqual(
      OwlWebSearchContext.injecting(results: [], into: messages).count, 1,
      "没搜到就别插一条『以下是检索结果』的空壳")
  }

  func testInjectedContextLeadsWithNumberedSourcesAndKeepsOriginalMessages() throws {
    let results = [
      OwlWebSearchResult(
        title: "标题 A", url: "https://a", snippet: "甲",
        publishedAt: "2026-07-01", hostname: "站点A"),
      OwlWebSearchResult(
        title: "标题 B", url: "https://b", snippet: "乙",
        publishedAt: nil, hostname: nil),
    ]
    let original = [OwlDeepSeekMessage(role: "user", content: "问题")]
    let injected = OwlWebSearchContext.injecting(results: results, into: original)
    XCTAssertEqual(injected.count, 2)
    let system = try XCTUnwrap(injected.first)
    XCTAssertEqual(system.role, "system")
    XCTAssertTrue(system.content.contains("[1] 标题 A"))
    XCTAssertTrue(system.content.contains("[2] 标题 B"))
    XCTAssertTrue(system.content.contains("https://a"))
    XCTAssertTrue(system.content.contains("发布时间：2026-07-01"))
    XCTAssertFalse(
      system.content.contains("发布时间：\n"), "缺失的字段整行省略，不留空标签")
    XCTAssertEqual(injected.last?.content, "问题", "原消息原样保留在后面")
  }

  // MARK: - Perplexity Search

  func testPerplexityRequestMatchesDocumentedShape() throws {
    let request = try OwlPerplexitySearchWire.request(
      query: "latest AI developments", apiKey: "pplx-test", limit: 5)
    XCTAssertEqual(request.url, OwlPerplexitySearchWire.endpoint)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pplx-test")
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(object["query"] as? String, "latest AI developments")
    XCTAssertEqual(object["max_results"] as? Int, 5)
    XCTAssertNil(object["Query"], "别把豆包的大写字段名带过来")
  }

  /// Perplexity 不回站点名，只有 url —— hostname 得自己从 url 取，否则来源那栏整片空着。
  func testPerplexityDerivesHostnameFromURLAndStripsWWW() throws {
    let json = """
      {"id":"s1","results":[
        {"title":"A","url":"https://www.example.com/a","snippet":"甲","date":"2026-07-01"},
        {"title":"B","url":"https://news.ycombinator.com/b","snippet":"","last_updated":"2026-07-02"}]}
      """
    let results = try OwlPerplexitySearchWire.parse(Data(json.utf8))
    XCTAssertEqual(results.map(\.hostname), ["example.com", "news.ycombinator.com"])
    XCTAssertEqual(results.first?.publishedAt, "2026-07-01")
    XCTAssertEqual(
      results.last?.publishedAt, "2026-07-02", "没有 date 时退到 last_updated")
  }

  /// 与豆包相反：Perplexity 用标准状态码。401 要带出可读 message，不能只报个数字。
  func testPerplexityNon2xxSurfacesServiceMessage() async {
    let json = #"{"error":{"message":"Invalid API key","type":"authentication_error"}}"#
    let client = OwlPerplexitySearchClient(fetch: { request in
      (Data(json.utf8), HTTPURLResponse(
        url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    })
    do {
      _ = try await client.search(query: "q", apiKey: "pplx", limit: 3)
      XCTFail("expected a thrown error")
    } catch {
      XCTAssertEqual(
        error as? OwlWebSearchError,
        .serviceError(code: "authentication_error", message: "Invalid API key"))
    }
  }

  func testPerplexityBareStatusWhenErrorBodyIsUnparseable() async {
    let client = OwlPerplexitySearchClient(fetch: { request in
      (Data("nope".utf8), HTTPURLResponse(
        url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
    })
    do {
      _ = try await client.search(query: "q", apiKey: "pplx", limit: 3)
      XCTFail("expected a thrown error")
    } catch {
      XCTAssertEqual(error as? OwlWebSearchError, .badHTTPStatus(429))
    }
  }

  // MARK: - 裸控制字符（实盘偶发）

  /// 回归：两家的摘要都抠自真实网页正文，正文里混进裸控制字符时它们**不转义**就塞进 JSON 字符串。
  /// 那不是合法 JSON，`JSONSerialization` 直接拒收（实测：默认与 .fragmentsAllowed 都拒），而解析
  /// 失败在我们这里归类为「不顺位、如实报错」—— 于是这一问整个失败。2026-07-27 打 Perplexity 时
  /// 复现过。清洗后必须能正常解析出结果。
  func testRawControlCharactersInSnippetsDoNotBreakParsing() throws {
    let control = "\u{0008}"   // 退格符：合法 JSON 字符串里绝不能裸着出现
    let pplx = """
      {"id":"s1","results":[{"title":"标题","url":"https://a","snippet":"第一行\(control)第二行"}]}
      """
    XCTAssertNil(
      try? JSONSerialization.jsonObject(with: Data(pplx.utf8)),
      "前提：裸控制字符确实会让 JSONSerialization 拒收")

    let results = try OwlPerplexitySearchWire.parse(Data(pplx.utf8))
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.snippet, "第一行 第二行", "控制字符换成空格，内容不丢")

    let doubao = """
      {"ResponseMetadata":{"RequestId":"r"},"Result":{"ErrorCode":0,"Documents":[
        {"Rank":0,"Url":"https://b","Title":"标题B","Snippet":[{"Type":"text","Text":"甲\(control)乙"}]}]}}
      """
    let dResults = try OwlDoubaoGlobalSearchWire.parse(Data(doubao.utf8))
    XCTAssertEqual(dResults.first?.snippet, "甲 乙", "豆包同一条路径也要清洗")
  }

  /// 清洗不能破坏正常内容：合法的转义换行、中文、emoji 都得原样出来。
  func testSanitizingLeavesLegitimateContentIntact() throws {
    let json = """
      {"id":"s1","results":[{"title":"标题 🙂","url":"https://a","snippet":"第一行\\n第二行"}]}
      """
    let results = try OwlPerplexitySearchWire.parse(Data(json.utf8))
    XCTAssertEqual(results.first?.title, "标题 🙂", "多字节字符不受影响")
    XCTAssertEqual(
      results.first?.snippet, "第一行\n第二行",
      "合法的 \\n 是两个 ASCII 字节，不该被当成控制字符改掉")
  }

  /// 回归：`MaxImageCountPerDoc` 填 0 等于没填 —— 文档是「传入值 > 0 时生效」，0 会落回默认 3 张/条
  /// （2026-07-27 实测：0 与不传都拿到 4 个图片段，填 1 才降到 2 个）。图片关不掉，只能取最省的一档。
  func testDoubaoAsksForTheFewestImagesThatActuallyTakesEffect() {
    let body = OwlDoubaoGlobalSearchWire.body(query: "q", limit: 5)
    XCTAssertEqual(
      body["MaxImageCountPerDoc"] as? Int, 1,
      "0 会被服务端忽略并落回默认 3；1 才是真正生效的最小值")
  }

  /// 实测定的默认档：low 只有 1/5 有摘要，high 是 5/5，而三档时延一样。
  func testPerplexityAsksForFullPageContext() {
    XCTAssertEqual(
      OwlPerplexitySearchWire.body(query: "q", limit: 5)["search_context_size"] as? String,
      "high",
      "低档省不到时延，只会把接地省没了")
  }

  // MARK: - 百炼（通义千问）wire format

  func testDashScopeUsesTheResponsesEndpoint() throws {
    let endpoint = try XCTUnwrap(
      OwlQwenWorkspace.responsesEndpoint(for: "ws-test123abc"))
    let request = try OwlDashScopeSearchWire.request(
      query: "杭州明天天气", apiKey: "sk-qwen", endpoint: endpoint)
    XCTAssertEqual(request.url?.host, "ws-test123abc.cn-beijing.maas.aliyuncs.com")
    XCTAssertEqual(request.url?.path, "/compatible-mode/v1/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-qwen")
  }

  func testDashScopeFallsBackToTheGenericResponsesEndpointWithoutAWorkspace() throws {
    let request = try OwlDashScopeSearchWire.request(
      query: "杭州明天天气",
      apiKey: "sk-qwen",
      endpoint: URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)!)
    XCTAssertEqual(request.url?.host, "dashscope.aliyuncs.com")
    XCTAssertEqual(request.url?.path, "/compatible-mode/v1/responses")
  }

  func testDashScopeResponsesForcesTheBuiltInSearchTool() throws {
    let body = OwlDashScopeSearchWire.body(query: "杭州明天天气")
    XCTAssertEqual(body["model"] as? String, OwlDashScopeSearchWire.model)
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    XCTAssertEqual(input.first?["role"] as? String, "user")
    XCTAssertTrue((input.first?["content"] as? String)?.contains("杭州明天天气") == true)
    let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.count, 1)
    XCTAssertEqual(tools.first?["type"] as? String, "web_search")
    XCTAssertEqual(tools.first?.count, 1)
    XCTAssertEqual(body["tool_choice"] as? String, "required", "作为检索器不能让模型自行跳过搜索")
    XCTAssertEqual(
      body["store"] as? Bool, false,
      "独立检索不使用 Response ID，不得沿用百炼默认 store=true")
    XCTAssertNil(body["parameters"], "不得再混入旧 generation 参数壳")
  }

  func testDashScopeDisablesReasoningWithoutSendingUndocumentedTokenFields() throws {
    let body = OwlDashScopeSearchWire.body(query: "q")
    XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
    XCTAssertNil(body["max_output_tokens"])
    XCTAssertNil(body["enable_thinking"])
    XCTAssertNil(body["max_tokens"])
  }

  func testDashScopeMissingKeyThrowsBeforeAnyRequestIsBuilt() {
    XCTAssertThrowsError(
      try OwlDashScopeSearchWire.request(query: "q", apiKey: " ")
    ) { error in
      XCTAssertEqual(error as? OwlWebSearchError, .missingAPIKey)
    }
  }

  func testDashScopeParseExtractsResponsesSearchSourcesThatCarryNoSnippet() throws {
    let json = """
      {"model":"qwen3.7-plus","output":[
        {"type":"web_search_call","action":{"type":"search","sources":[
          {"type":"url","url":"https://cj.sina.com.cn/a"}
        ]}},
        {"type":"message","content":[{"type":"output_text","text":"明天杭州多云。"}]}
      ]}
      """
    let results = try OwlDashScopeSearchWire.parse(Data(json.utf8), limit: 5)
    XCTAssertEqual(results.count, 1)
    let first = try XCTUnwrap(results.first)
    XCTAssertEqual(first.title, "cj.sina.com.cn", "Responses 来源只有 URL 时用 host 作标题")
    XCTAssertEqual(first.url, "https://cj.sina.com.cn/a")
    XCTAssertEqual(first.hostname, "cj.sina.com.cn")
    XCTAssertEqual(first.snippet, "", "Responses web_search 来源不保证正文摘要")
    XCTAssertNil(first.publishedAt, "也不回发布时间，宁可不标也不标个空的")
  }

  func testDashScopeParseDeduplicatesAndTruncatesSources() throws {
    let entries = (1...8).map { "{\"type\":\"url\",\"url\":\"https://e.com/\($0)\"}" }
      .joined(separator: ",")
    let json = "{\"output\":[{\"type\":\"web_search_call\",\"action\":{\"sources\":[\(entries),{\"type\":\"url\",\"url\":\"https://e.com/1\"}]}}]}"
    let results = try OwlDashScopeSearchWire.parse(Data(json.utf8), limit: 3)
    XCTAssertEqual(results.map(\.url), ["https://e.com/1", "https://e.com/2", "https://e.com/3"])
  }

  func testDashScopeMissingSearchSourcesIsZeroResultsNotMalformed() throws {
    let json = """
      {"output":[{"type":"message","content":[{"type":"output_text","text":"我不知道。"}]}]}
      """
    XCTAssertEqual(try OwlDashScopeSearchWire.parse(Data(json.utf8), limit: 5).count, 0)
  }

  func testDashScopeResponsesErrorIsThrown() {
    let json = """
      {"error":{"code":"InvalidApiKey","type":"authentication_error","message":"Invalid API-key provided."}}
      """
    XCTAssertThrowsError(try OwlDashScopeSearchWire.parse(Data(json.utf8), limit: 5)) { error in
      XCTAssertEqual(
        error as? OwlWebSearchError,
        .serviceError(code: "InvalidApiKey", message: "Invalid API-key provided."))
    }
  }

  func testDashScopeClientPreservesGenericInvalidParameterWithoutMarkingTheRouteUnusable() async {
    let client = OwlDashScopeSearchClient(fetch: { request in
      let body = Data(#"{"error":{"code":"InvalidParameter","message":"bad tool choice"}}"#.utf8)
      return (body, HTTPURLResponse(
        url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
    })
    do {
      _ = try await client.search(query: "q", apiKey: "sk", limit: 3)
      XCTFail("expected a thrown error")
    } catch {
      XCTAssertEqual(
        error as? OwlWebSearchError,
        .serviceError(code: "InvalidParameter", message: "bad tool choice"))
      XCTAssertFalse(
        (error as? OwlWebSearchError)?.isRouteUnusable ?? true,
        "generic InvalidParameter may describe this question and must not fan out")
    }
  }

  /// 限流不是「这家不给你用」：客户端一读到 `code` 就把状态码换成了 `serviceError`，
  /// 按状态码判 429 的那条规则在这里失效，必须靠错误码认回来，否则会白白顺位到同样被限流的下一家。
  func testDashScopeThrottlingIsTransientRatherThanARouteSwap() {
    XCTAssertFalse(
      OwlWebSearchError.serviceError(code: "Throttling.RateQuota", message: "").isRouteUnusable)
    XCTAssertFalse(
      OwlWebSearchError.serviceError(code: "InternalError", message: "").isRouteUnusable)
  }

  func testUnknownServiceErrorIsReportedInsteadOfFanningOut() {
    XCTAssertFalse(
      OwlWebSearchError.serviceError(
        code: "ContentPolicyViolation", message: "request-specific refusal"
      ).isRouteUnusable)
  }

  // MARK: - 署名

  /// 署名要说「豆包搜索」/「Perplexity」而不是同名的**模型**供应商：检索的是它，作答的可能是 DeepSeek。
  func testEachBackendHasItsOwnAttributionSeparateFromTheModelProvider() {
    XCTAssertEqual(
      OwlSearchControl.displayName(for: OwlWebSearchBackend.doubaoGlobal.attributionID),
      "豆包搜索")
    XCTAssertEqual(
      OwlSearchControl.displayName(for: OwlWebSearchBackend.perplexity.attributionID),
      "Perplexity")
    XCTAssertEqual(
      OwlSearchControl.displayName(for: OwlWebSearchBackend.qwen.attributionID),
      "阿里云百炼")
    XCTAssertEqual(OwlSearchControl.displayName(for: "doubao"), "豆包", "模型供应商的署名不变")
    XCTAssertEqual(
      OwlSearchControl.displayName(for: "qwen"), "通义千问",
      "qwen 自己检索自己作答的那一档，与只负责检索的『阿里云百炼』必须能分辨")
    for backend in OwlWebSearchBackend.allCases {
      XCTAssertNotEqual(backend.attributionID, backend.rawValue)
    }
  }

  // MARK: - 后端选择

  func testBackendPreferenceDefaultsToDoubaoAndIgnoresUnknownValues() {
    OwlWebSearchBackendSettings.resetForTesting()
    XCTAssertEqual(OwlWebSearchBackendSettings.backend, .doubaoGlobal)

    OwlWebSearchBackendSettings.rawValue = "perplexity"
    XCTAssertEqual(OwlWebSearchBackendSettings.backend, .perplexity)

    OwlWebSearchBackendSettings.rawValue = "bing"
    XCTAssertEqual(
      OwlWebSearchBackendSettings.backend, .doubaoGlobal,
      "不认识的值回到默认，而不是让联网整个失灵")
    OwlWebSearchBackendSettings.resetForTesting()
  }

  func testPreferredBackendOnlyMovesToFrontOfTheCompleteCandidateOrder() {
    XCTAssertEqual(
      OwlWebSearchBackend.orderedCandidates(preferred: .perplexity),
      [.perplexity, .doubaoGlobal, .qwen, .minimax])
    XCTAssertEqual(
      OwlWebSearchBackend.orderedCandidates(preferred: .qwen),
      [.qwen, .doubaoGlobal, .perplexity, .minimax])
  }

  // MARK: - Key 存放

  func testKeyStoreReadsTrimmedKeyAndTreatsBlankAsUnconfigured() throws {
    let secrets = OwlInMemorySecretStore()
    XCTAssertFalse(OwlWebSearchKeyStore.isConfigured(for: .doubaoGlobal, secrets: secrets))

    try secrets.setSecret("  sk-search  ", named: OwlWebSearchBackend.doubaoGlobal.secretName)
    XCTAssertEqual(OwlWebSearchKeyStore.apiKey(for: .doubaoGlobal, secrets: secrets), "sk-search")
    XCTAssertTrue(OwlWebSearchKeyStore.isConfigured(for: .doubaoGlobal, secrets: secrets))

    try secrets.setSecret("   ", named: OwlWebSearchBackend.doubaoGlobal.secretName)
    XCTAssertNil(
      OwlWebSearchKeyStore.apiKey(for: .doubaoGlobal, secrets: secrets), "空白 Key 等于没配")
  }

  /// 两家的 Key 分开存：切后端不该看到上一家的 Key，切回来也不该要求重填。
  func testBackendKeysAreStoredIndependently() {
    let secrets = OwlInMemorySecretStore()
    _ = OwlSettingsActions.saveWebSearchKey("sk-doubao", backend: .doubaoGlobal, secrets: secrets)
    _ = OwlSettingsActions.saveWebSearchKey("pplx-key", backend: .perplexity, secrets: secrets)

    XCTAssertEqual(OwlWebSearchKeyStore.apiKey(for: .doubaoGlobal, secrets: secrets), "sk-doubao")
    XCTAssertEqual(OwlWebSearchKeyStore.apiKey(for: .perplexity, secrets: secrets), "pplx-key")

    _ = OwlSettingsActions.clearWebSearchKey(backend: .perplexity, secrets: secrets)
    XCTAssertNil(OwlWebSearchKeyStore.apiKey(for: .perplexity, secrets: secrets))
    XCTAssertEqual(
      OwlWebSearchKeyStore.apiKey(for: .doubaoGlobal, secrets: secrets), "sk-doubao",
      "删一家不能把另一家的 Key 带走")
  }

  /// 搜索 Key 用固定账号，不能和任何一条 provider profile 的 Key 撞。
  func testSearchKeyAccountsAreNotProviderAccounts() {
    var seen = Set<String>()
    for backend in OwlWebSearchBackend.allCases {
      XCTAssertFalse(
        backend.secretName.hasPrefix("owltype.provider."),
        "搜索能力独立于供应商，Key 不该落在 provider 的账号命名空间里")
      XCTAssertTrue(seen.insert(backend.secretName).inserted, "两家不能共用一个 Keychain 账号")
    }
  }

  func testSaveAndClearWebSearchKeyRoundTrip() {
    let secrets = OwlInMemorySecretStore()
    let blank = OwlSettingsActions.saveWebSearchKey("   ", backend: .perplexity, secrets: secrets)
    XCTAssertEqual(blank.status, "请输入Perplexity的 API Key")
    XCTAssertFalse(OwlWebSearchKeyStore.isConfigured(for: .perplexity, secrets: secrets))

    let saved = OwlSettingsActions.saveWebSearchKey(
      " pplx-key ", backend: .perplexity, secrets: secrets)
    XCTAssertEqual(saved.input, "", "保存后输入框清空，值不回显")
    XCTAssertTrue(saved.status.hasPrefix("已保存"))
    XCTAssertEqual(OwlWebSearchKeyStore.apiKey(for: .perplexity, secrets: secrets), "pplx-key")

    _ = OwlSettingsActions.clearWebSearchKey(backend: .perplexity, secrets: secrets)
    XCTAssertFalse(OwlWebSearchKeyStore.isConfigured(for: .perplexity, secrets: secrets))
  }
}

final class OwlMiniMaxSearchTests: XCTestCase {
  func testSearchMapsSourcesAndSendsSubscriptionContract() async throws {
    let client = OwlMiniMaxSearchClient { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.minimax.cn/v1/coding_plan/search")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
      let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
      XCTAssertEqual(body, ["q": "MiniMax 官方文档"])
      let data = Data(#"{"base_resp":{"status_code":0},"organic":[{"title":"文档","link":"https://example.com/docs","snippet":"正文摘要","date":"2026-10-01"},{"link":"javascript:alert(1)"}]}"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let results = try await client.search(query: "MiniMax 官方文档", apiKey: "test-key", limit: 3)
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.snippet, "正文摘要")
    XCTAssertEqual(results.first?.publishedAt, "2026-10-01")
    XCTAssertEqual(OwlSearchControl.displayName(for: "minimax-search"), "MiniMax 搜索（国内站）")
  }

  func testBusinessErrorsAndEmptyResultsCannotClaimSearchedAnswer() async throws {
    for (payload, expected) in [
      (#"{"base_resp":{"status_code":1004,"status_msg":"invalid key"}}"#,
       OwlWebSearchError.serviceError(code: "minimax_1004", message: "invalid key")),
      (#"{"base_resp":{"status_code":0},"organic":[]}"#, .noResults),
      (#"{"organic":[]}"#, .malformedResponse)
    ] {
      let client = OwlMiniMaxSearchClient { request in
        (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      }
      do {
        _ = try await client.search(query: "test", apiKey: "test-key", limit: 3)
        XCTFail("must reject unusable search result")
      } catch {
        XCTAssertEqual(error as? OwlWebSearchError, expected)
      }
    }
  }
}
