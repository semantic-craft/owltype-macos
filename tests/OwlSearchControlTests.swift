//
//  OwlSearchControlTests.swift
//  OwltypeTests — 任意提问「联网搜索」逐家 wire format
//
//  Locks the channel resolution (providerID wins, host is the fallback) and the per-provider
//  transport: every search-capable provider searches on `/responses` with a provider-specific
//  `OwlResponsesDialect`; anything else resolves to `.none`. The capability is modelled as a type
//  rather than implied, so a caller can ask "can this one search?" without a per-provider table.
//
//  Pure value logic: no network, no UserDefaults, no Keychain.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlSearchControlTests: XCTestCase {

  // MARK: - Channel resolution

  func testChannelResolvesByProviderID() {
    XCTAssertEqual(OwlSearchControl.channel(providerID: "qwen", host: ""), .dashScope)
    XCTAssertEqual(OwlSearchControl.channel(providerID: "doubao", host: ""), .ark)
    XCTAssertEqual(OwlSearchControl.channel(providerID: "openai", host: ""), .openAI)
  }

  func testChannelFallsBackToHostWhenProviderIDIsUnknown() {
    // A custom profile whose id was never stamped still resolves by endpoint host.
    XCTAssertEqual(
      OwlSearchControl.channel(providerID: "custom", host: "dashscope.aliyuncs.com"), .dashScope)
    XCTAssertEqual(
      OwlSearchControl.channel(providerID: "custom", host: "ark.cn-beijing.volces.com"), .ark)
    XCTAssertEqual(
      OwlSearchControl.channel(providerID: "custom", host: "api.openai.com"), .openAI)
  }

  func testChannelIsNoneForProvidersWithoutSearch() {
    // 智谱已下架：残留档案（或手填 bigmodel 端点）只当普通对话，不得再走联网。
    XCTAssertEqual(OwlSearchControl.channel(providerID: "zhipu", host: "open.bigmodel.cn"), .none)
    XCTAssertEqual(OwlSearchControl.channel(providerID: "gemini", host: "generativelanguage.googleapis.com"), .none)
    XCTAssertEqual(OwlSearchControl.channel(providerID: "minimax", host: "api.minimax.chat"), .none)
  }

  // MARK: - Transport (search wire dialect)

  func testTransportRoutesEverySearchProviderThroughResponses() {
    XCTAssertEqual(OwlSearchControl.transport(providerID: "qwen", host: ""), .responses(.qwen))
    XCTAssertEqual(OwlSearchControl.transport(providerID: "doubao", host: ""), .responses(.ark))
    XCTAssertEqual(OwlSearchControl.transport(providerID: "openai", host: ""), .responses(.openAI))
    XCTAssertEqual(
      OwlSearchControl.transport(
        providerID: "deepseek", host: "api.deepseek.com", model: "deepseek-v4-flash"),
      .responses(.deepseek),
      "DeepSeek 2026-07-31 起接入联网——开着思考才立得住，见 OwlResponsesWire")
    XCTAssertEqual(
      OwlSearchControl.transport(providerID: "qwen", host: "dashscope.aliyuncs.com"),
      .responses(.qwen),
      "百炼整体是 Responses 供应商——联网也走 /responses，不再按型号回退")
  }

  func testSupportsSearchMatchesTheTransport() {
    XCTAssertTrue(OwlSearchControl.supportsSearch(providerID: "qwen", host: ""))
    XCTAssertTrue(OwlSearchControl.supportsSearch(providerID: "doubao", host: ""))
    XCTAssertTrue(OwlSearchControl.supportsSearch(providerID: "openai", host: ""))
    XCTAssertTrue(OwlSearchControl.supportsSearch(
      providerID: "deepseek", host: "api.deepseek.com", model: "deepseek-v4-flash"))
    // 型号闸：`/responses` 只收 flash，配着 pro 的 DeepSeek 档案如实说自己不能搜。
    XCTAssertFalse(OwlSearchControl.supportsSearch(
      providerID: "deepseek", host: "api.deepseek.com", model: "deepseek-v4-pro"))
  }

  // MARK: - `/responses` wire (Qwen / 豆包 / OpenAI / DeepSeek)

  func testResponsesSearchBodyIsJSONSerializableForEveryDialect() {
    // `OwlResponsesStreamingClient` serializes this body directly, and a non-JSON value there would
    // throw the whole question away.
    for dialect in OwlResponsesDialect.allCases {
      let body = OwlResponsesWire.body(
        model: "m",
        messages: [OwlDeepSeekMessage(role: "user", content: "问题")],
        stream: true,
        dialect: dialect,
        webSearch: true
      )
      XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
      XCTAssertNotNil(body["tools"], "dialect=\(dialect) 必须带 web_search 工具")
    }
  }

  // MARK: - 署名

  func testDisplayNameUsesBrandNamesForSearchProviders() {
    XCTAssertEqual(OwlSearchControl.displayName(for: "qwen"), "通义千问")
    XCTAssertEqual(OwlSearchControl.displayName(for: "doubao"), "豆包")
    XCTAssertEqual(OwlSearchControl.displayName(for: "openai"), "OpenAI")
    XCTAssertEqual(OwlSearchControl.displayName(for: "deepseek"), "DeepSeek")
    XCTAssertNil(OwlSearchControl.displayName(for: "minimax"), "不能联网的就不该有联网署名")
  }

  func testEverySearchProviderContributesRealSearchFieldsOnItsOwnTransport() {
    // The 自动 fallback order (and the「联网模型」Picker, which lists exactly these) must never
    // carry a provider that resolves to a request with no search in it. Checked per provider:
    // /responses proves search via a tools array in its body.
    for providerID in OwlSearchControl.searchProviderIDs {
      switch OwlSearchControl.transport(providerID: providerID, host: "") {
      case let .responses(dialect):
        let body = OwlResponsesWire.body(
          model: "m",
          messages: [OwlDeepSeekMessage(role: "user", content: "问题")],
          stream: true,
          dialect: dialect,
          webSearch: true
        )
        guard let tools = body["tools"] as? [[String: Any]], let tool = tools.first else {
          return XCTFail("\(providerID) 走 /responses 却没有 tools")
        }
        XCTAssertEqual(tool["type"] as? String, "web_search")
      case .none:
        XCTFail("\(providerID) is listed as a search candidate but cannot search")
      }
    }
  }

  func testEverySearchProviderHasAUserFacingName() {
    // The Picker renders these; a missing name would show a raw provider id.
    for providerID in OwlSearchControl.searchProviderIDs {
      XCTAssertNotNil(
        OwlSearchControl.displayName(for: providerID),
        "\(providerID) 会出现在「联网模型」下拉里，必须有品牌名")
    }
  }
}
