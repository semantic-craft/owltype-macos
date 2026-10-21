//
//  OwlSearchControlTests.swift
//  OwltypeTests — 任意提问「联网搜索」逐家 wire format
//
//  Locks the channel resolution (providerID wins, host is the fallback) and the transport:
//  任意提问 联网只走 DeepSeek 的 `/responses`；其他供应商一律 `.none`。
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

  func testDeepSeekTransportIsGatedByModel() {
    XCTAssertEqual(
      OwlSearchControl.transport(
        providerID: "deepseek", host: "api.deepseek.com", model: OwlSearchControl.searchModel),
      .responses(.deepseek),
      "开着思考才立得住，见 OwlResponsesWire")
    XCTAssertEqual(OwlSearchControl.searchModel, "deepseek-v4-pro")
    // 型号闸：flash 收下 web_search 却不搜（v4-flash 已被映射到 V4.1 Flash），如实说自己不能搜。
    XCTAssertFalse(OwlSearchControl.supportsSearch(
      providerID: "deepseek", host: "api.deepseek.com", model: "deepseek-v4-flash"))
    XCTAssertFalse(OwlSearchControl.supportsSearch(
      providerID: "deepseek", host: "api.deepseek.com", model: "deepseek-flash"))
  }

  func testDeepSeekSearchBodyCarriesTheWebSearchTool() {
    guard case let .responses(dialect) = OwlSearchControl.transport(
      providerID: OwlSearchControl.searchProviderID, host: "") else {
      return XCTFail("the search provider must resolve to a /responses transport")
    }
    let body = OwlResponsesWire.body(
      model: "m",
      messages: [OwlDeepSeekMessage(role: "user", content: "问题")],
      stream: true,
      dialect: dialect,
      webSearch: true
    )
    XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    guard let tools = body["tools"] as? [[String: Any]], let tool = tools.first else {
      return XCTFail("DeepSeek 走 /responses 却没有 tools")
    }
    XCTAssertEqual(tool["type"] as? String, "web_search")
    XCTAssertEqual(OwlSearchControl.displayName(for: OwlSearchControl.searchProviderID), "DeepSeek")
  }
}
