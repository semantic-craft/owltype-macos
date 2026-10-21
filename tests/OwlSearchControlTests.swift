//
//  OwlSearchControlTests.swift
//  OwltypeTests — 任意提问「联网搜索」逐家 wire format
//
//  Locks the channel resolution (providerID wins, host is the fallback), the transport
//  (任意提问 联网只走 DeepSeek Search 接口；其他供应商一律 `.none`), the search wire format and
//  the grounding that turns results into prompt text and a sources footer.
//
//  Pure value logic: no network, no UserDefaults, no Keychain.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlSearchControlTests: XCTestCase {

  func testChannelResolvesDeepSeekByProviderIDOrHost() {
    XCTAssertEqual(OwlSearchControl.channel(providerID: "deepseek", host: ""), .deepSeek)
    XCTAssertEqual(
      OwlSearchControl.channel(providerID: "custom", host: "api.deepseek.com"), .deepSeek,
      "未盖 id 的自定义档案按 host 兜底")
  }

  func testEveryOtherProviderCannotSearch() {
    for (providerID, host) in [
      ("qwen", "dashscope.aliyuncs.com"),
      ("doubao", "ark.cn-beijing.volces.com"),
      ("openai", "api.openai.com"),
      ("gemini", "generativelanguage.googleapis.com"),
      ("minimax", "api.minimax.cn"),
      ("zhipu", "open.bigmodel.cn"),
    ] {
      XCTAssertEqual(OwlSearchControl.channel(providerID: providerID, host: host), .none, providerID)
      XCTAssertEqual(OwlSearchControl.transport(providerID: providerID, host: host), .none, providerID)
      XCTAssertNil(OwlSearchControl.displayName(for: providerID), "不能联网的就不该有联网署名：\(providerID)")
    }
  }

  /// 联网与作答型号无关：检索是独立请求，flash 也能依据结果作答。
  func testDeepSeekSearchesThroughTheSearchAPIWhateverTheModel() {
    XCTAssertEqual(
      OwlSearchControl.transport(providerID: "deepseek", host: "api.deepseek.com"),
      .deepSeekSearchAPI)
    XCTAssertEqual(OwlSearchControl.searchModel, "deepseek-flash")
    XCTAssertEqual(OwlSearchControl.displayName(for: OwlSearchControl.searchProviderID), "DeepSeek")
  }

  func testSearchEndpointSitsOnTheChatHost() {
    XCTAssertEqual(
      OwlDeepSeekSearchWire.endpoint(
        for: URL(string: "https://api.deepseek.com/chat/completions")!)?.absoluteString,
      "https://api.deepseek.com/v1/tools/search")
    XCTAssertEqual(
      OwlDeepSeekSearchWire.endpoint(
        for: URL(string: "https://proxy.example.com:8443/deepseek/v1/chat/completions?x=1")!)?
        .absoluteString,
      "https://proxy.example.com:8443/v1/tools/search")
  }

  func testSearchBodyCollapsesWhitespaceAndRespectsTheQueryLimit() throws {
    let long = "民法典\n\n  施行" + String(repeating: "字", count: 200)
    let request = try OwlDeepSeekSearchWire.request(
      query: long, endpoint: URL(string: "https://api.deepseek.com/v1/tools/search")!,
      apiKey: "sk-test", limit: 99)
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    let query = try XCTUnwrap(body["query"] as? String)
    XCTAssertTrue(query.hasPrefix("民法典 施行字"))
    XCTAssertEqual(query.count, OwlDeepSeekSearchWire.maxQueryLength)
    XCTAssertEqual(body["ori_question"] as? String, query)
    XCTAssertEqual(body["count"] as? Int, OwlDeepSeekSearchWire.maxCount)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
  }

  /// 响应形状取自 2026-10-21 实测（`/v1/tools/search`，query「民法典 施行日期」）。
  func testParseKeepsUsableResultsAndPrefersTheSummary() throws {
    let data = Data("""
      {"results":[
        {"rerank_score":1.97,"title":"中国民法典诞生！","url":"http://www.npc.gov.cn/a.html",
         "snippet":"短","summary":"长摘要","content":"","site_name":"中国人大网",
         "site_icon":null,"date":"2020-05-27T16:00:00+00:00","authority":4},
        {"title":"","url":"https://x.example.com","snippet":"无标题","summary":"","date":null},
        {"title":"只有短摘要","url":"https://www.court.gov.cn/b.html#1","snippet":"短摘要",
         "summary":"","site_name":null,"date":null}
      ]}
      """.utf8)
    let results = try OwlDeepSeekSearchWire.parse(data)
    XCTAssertEqual(results.map(\.url), ["http://www.npc.gov.cn/a.html", "https://www.court.gov.cn/b.html"])
    XCTAssertEqual(results[0].snippet, "长摘要")
    XCTAssertEqual(results[0].publishedAt, "2020-05-27")
    XCTAssertEqual(results[0].hostname, "中国人大网")
    XCTAssertEqual(results[1].snippet, "短摘要")
    XCTAssertEqual(results[1].hostname, "www.court.gov.cn", "缺站点名时用域名")
    // 实测接口在网址后挂 `#1`；去掉后才能与豆包的同一网页按网址去重。
    XCTAssertThrowsError(try OwlDeepSeekSearchWire.parse(Data("{\"error\":{}}".utf8)))
  }

  func testClientMapsHTTPFailureToItsStatus() async {
    let client = OwlDeepSeekSearchClient { request in
      (Data(), HTTPURLResponse(url: request.url!, statusCode: 402, httpVersion: nil, headerFields: nil)!)
    }
    do {
      _ = try await client.search(
        query: "q", endpoint: URL(string: "https://api.deepseek.com/v1/tools/search")!,
        apiKey: "sk", limit: 3)
      XCTFail("expected a failure")
    } catch {
      XCTAssertEqual(error as? OwlDeepSeekSearchError, .badHTTPStatus(402))
    }
  }

  func testAskGroundingPutsNumberedResultsFirstAndFootsCitedSources() {
    let results = [
      OwlWebSearchResult(title: "人大", url: "https://npc.gov.cn/a", snippet: "2021年1月1日施行",
                         publishedAt: "2020-05-28", hostname: "中国人大网"),
      OwlWebSearchResult(title: "百科", url: "https://baike.example.com/b", snippet: "",
                         publishedAt: nil, hostname: nil),
    ]
    let conversation = [OwlDeepSeekMessage(role: "user", content: "民法典何时施行？")]
    let messages = OwlWebSearchGrounding.askMessages(conversation, results: results)
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].role, "system")
    XCTAssertTrue(messages[0].content.contains("[1] 人大\n来源：中国人大网\n发布时间：2020-05-28\n网址：https://npc.gov.cn/a"))
    XCTAssertEqual(messages[1], conversation[0])

    XCTAssertEqual(
      OwlWebSearchGrounding.sourcesFooter(results, answer: "2021 年起施行 [2][1][1][9]。"),
      "\n\n来源：\n[2] [百科](https://baike.example.com/b)\n[1] [人大](https://npc.gov.cn/a)",
      "按引用顺序、保留原编号、越界编号不算")
    XCTAssertEqual(
      OwlWebSearchGrounding.sourcesFooter(results, answer: "没有引用"),
      "\n\n检索到的网页：\n[1] [人大](https://npc.gov.cn/a)\n[2] [百科](https://baike.example.com/b)")
    XCTAssertEqual(OwlWebSearchGrounding.sourcesFooter([], answer: "[1]"), "")
    XCTAssertTrue(OwlWebSearchGrounding.askSystemPrompt([]).contains("未检索到相关网页"))
  }
}
