//
//  FamoSearchControlTests.swift
//  FamoTests — 任意提问「联网搜索」逐家 wire format
//
//  Locks the remaining `/chat/completions` provider's search fields FIELD BY FIELD (a provider that
//  silently loses `enable_search` / `tools` answers from its training cutoff while the UI claims it
//  searched — the exact failure mode this feature exists to prevent), the channel resolution
//  (providerID wins, host is the fallback), and — since 二期 — WHICH TRANSPORT each provider's
//  search rides on, because 豆包/OpenAI search only on `/responses` and would silently no-op if
//  their parameters were routed through `extraBody`. Qwen joined that Responses path when
//  DashScope exposed its OpenAI Responses-compatible endpoint.
//
//  Pure value logic: no network, no UserDefaults, no Keychain.
//

import Foundation
import XCTest
@testable import Famo

final class FamoSearchControlTests: XCTestCase {

  // MARK: - Channel resolution

  func testChannelResolvesByProviderID() {
    XCTAssertEqual(FamoSearchControl.channel(providerID: "qwen", host: ""), .dashScope)
    XCTAssertEqual(FamoSearchControl.channel(providerID: "mimo", host: ""), .mimo)
    XCTAssertEqual(FamoSearchControl.channel(providerID: "doubao", host: ""), .ark)
    XCTAssertEqual(FamoSearchControl.channel(providerID: "openai", host: ""), .openAI)
  }

  func testChannelFallsBackToHostWhenProviderIDIsUnknown() {
    // A custom profile whose id was never stamped still resolves by endpoint host.
    XCTAssertEqual(
      FamoSearchControl.channel(providerID: "custom", host: "dashscope.aliyuncs.com"), .dashScope)
    XCTAssertEqual(
      FamoSearchControl.channel(providerID: "custom", host: "api.xiaomimimo.com"), .mimo)
    XCTAssertEqual(
      FamoSearchControl.channel(providerID: "custom", host: "ark.cn-beijing.volces.com"), .ark)
    XCTAssertEqual(
      FamoSearchControl.channel(providerID: "custom", host: "api.openai.com"), .openAI)
  }

  func testChannelIsNoneForProvidersWithoutSearch() {
    // 智谱已下架：残留档案（或手填 bigmodel 端点）只当普通对话，不得再走联网。
    XCTAssertEqual(FamoSearchControl.channel(providerID: "zhipu", host: "open.bigmodel.cn"), .none)
    XCTAssertEqual(FamoSearchControl.channel(providerID: "gemini", host: "generativelanguage.googleapis.com"), .none)
    XCTAssertEqual(FamoSearchControl.channel(providerID: "minimax", host: "api.minimax.chat"), .none)
  }

  // MARK: - Transport (WHICH endpoint carries the search)

  func testTransportSplitsChatCompletionsFromResponses() {
    // MiMo 仍走 /chat/completions 顶层字段；其余三家的搜索走 /responses，把它们的参数
    // 塞进 chat/completions 会被端点静默忽略 —— 所以能力是类型，不是约定。
    XCTAssertEqual(FamoSearchControl.transport(providerID: "qwen", host: ""), .responses(.qwen))
    XCTAssertEqual(FamoSearchControl.transport(providerID: "mimo", host: ""), .chatCompletions)
    XCTAssertEqual(FamoSearchControl.transport(providerID: "doubao", host: ""), .responses(.ark))
    XCTAssertEqual(FamoSearchControl.transport(providerID: "openai", host: ""), .responses(.openAI))
    XCTAssertEqual(
      FamoSearchControl.transport(
        providerID: "deepseek", host: "api.deepseek.com", model: "deepseek-v4-flash"),
      .responses(.deepseek),
      "DeepSeek 2026-07-31 起接入联网——开着思考才立得住，见 FamoResponsesWire")
    XCTAssertEqual(
      FamoSearchControl.transport(providerID: "qwen", host: "dashscope.aliyuncs.com"),
      .responses(.qwen),
      "百炼整体是 Responses 供应商——联网也走 /responses，不再按型号回退")
  }

  func testSupportsSearchMatchesTheTransport() {
    XCTAssertTrue(FamoSearchControl.supportsSearch(providerID: "qwen", host: ""))
    XCTAssertTrue(FamoSearchControl.supportsSearch(providerID: "mimo", host: ""))
    XCTAssertTrue(FamoSearchControl.supportsSearch(providerID: "doubao", host: ""))
    XCTAssertTrue(FamoSearchControl.supportsSearch(providerID: "openai", host: ""))
    XCTAssertTrue(FamoSearchControl.supportsSearch(
      providerID: "deepseek", host: "api.deepseek.com", model: "deepseek-v4-flash"))
    // 型号闸：`/responses` 只收 flash，配着 pro 的 DeepSeek 档案如实说自己不能搜。
    XCTAssertFalse(FamoSearchControl.supportsSearch(
      providerID: "deepseek", host: "api.deepseek.com", model: "deepseek-v4-pro"))
  }

  // MARK: - Wire format (field-by-field)

  func testQwenExtraBodyIsEmptyBecauseSearchLivesOnResponses() {
    let body = FamoSearchControl.extraBody(providerID: "qwen", host: "dashscope.aliyuncs.com")
    XCTAssertTrue(body.isEmpty, "Qwen 的联网工具属于 /responses，不得再塞旧 enable_search 字段")
  }

  func testMimoExtraBodyForcesSearchAndDisablesThinking() {
    let body = FamoSearchControl.extraBody(providerID: "mimo", host: "api.xiaomimimo.com")
    XCTAssertEqual(body["tool_choice"] as? String, "auto")
    // MiMo 的联网与思考互斥：thinking 必须显式关掉，否则搜索工具不触发。
    XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
    guard let tools = body["tools"] as? [[String: Any]], let tool = tools.first else {
      return XCTFail("MiMo must carry a tools array")
    }
    XCTAssertEqual(tool["type"] as? String, "web_search")
    XCTAssertEqual(tool["force_search"] as? Bool, true)
    XCTAssertEqual(tool["max_keyword"] as? Int, 3)
    XCTAssertEqual(tool["limit"] as? Int, 3)
  }

  func testExtraBodyIsEmptyForNonChatCompletionsProviders() {
    // Empty = merging is a no-op, so the caller never has to branch on capability. Note the two
    // different reasons: DeepSeek can't search at all, while Qwen/豆包/OpenAI CAN — just not here.
    XCTAssertTrue(FamoSearchControl.extraBody(providerID: "deepseek", host: "api.deepseek.com").isEmpty)
    XCTAssertTrue(
      FamoSearchControl.extraBody(providerID: "qwen", host: "dashscope.aliyuncs.com").isEmpty,
      "Qwen 的联网参数属于 /responses 请求体")
    XCTAssertTrue(
      FamoSearchControl.extraBody(providerID: "openai", host: "api.openai.com").isEmpty,
      "OpenAI 的联网参数属于 /responses 请求体，不是 chat/completions 顶层字段")
    XCTAssertTrue(
      FamoSearchControl.extraBody(providerID: "doubao", host: "ark.cn-beijing.volces.com").isEmpty,
      "豆包 同上 —— 塞在这里会被端点静默忽略")
  }

  func testEveryExtraBodyIsJSONSerializable() {
    // The merge path runs these through JSONSerialization; a non-JSON value would fail silently
    // there (the request falls back to un-merged = no search), so pin it here instead.
    for providerID in FamoSearchControl.searchProviderIDs {
      let body = FamoSearchControl.extraBody(providerID: providerID, host: "")
      XCTAssertTrue(
        JSONSerialization.isValidJSONObject(body),
        "\(providerID) extraBody must be JSON-serializable")
    }
  }

  // MARK: - `/responses` wire (Qwen / 豆包 / OpenAI)

  func testResponsesSearchBodyIsJSONSerializableForEveryDialect() {
    // Same reasoning as above, one layer down: `FamoResponsesStreamingClient` serializes this
    // body directly, and a non-JSON value there would throw the whole question away.
    for dialect in FamoResponsesDialect.allCases {
      let body = FamoResponsesWire.body(
        model: "m",
        messages: [FamoDeepSeekMessage(role: "user", content: "问题")],
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
    XCTAssertEqual(FamoSearchControl.displayName(for: "qwen"), "通义千问")
    XCTAssertEqual(FamoSearchControl.displayName(for: "mimo"), "MiMo")
    XCTAssertEqual(FamoSearchControl.displayName(for: "doubao"), "豆包")
    XCTAssertEqual(FamoSearchControl.displayName(for: "openai"), "OpenAI")
    XCTAssertEqual(FamoSearchControl.displayName(for: "deepseek"), "DeepSeek")
    XCTAssertNil(FamoSearchControl.displayName(for: "minimax"), "不能联网的就不该有联网署名")
  }

  func testEverySearchProviderContributesRealSearchFieldsOnItsOwnTransport() {
    // The 自动 fallback order (and the「联网模型」Picker, which lists exactly these) must never
    // carry a provider that resolves to a request with no search in it. Checked PER TRANSPORT:
    // chat/completions proves it via non-empty extras, /responses via a tools array in its body.
    for providerID in FamoSearchControl.searchProviderIDs {
      switch FamoSearchControl.transport(providerID: providerID, host: "") {
      case .chatCompletions:
        XCTAssertFalse(
          FamoSearchControl.extraBody(providerID: providerID, host: "").isEmpty,
          "\(providerID) 走 chat/completions 却没有任何联网字段")
      case let .responses(dialect):
        let body = FamoResponsesWire.body(
          model: "m",
          messages: [FamoDeepSeekMessage(role: "user", content: "问题")],
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
    for providerID in FamoSearchControl.searchProviderIDs {
      XCTAssertNotNil(
        FamoSearchControl.displayName(for: providerID),
        "\(providerID) 会出现在「联网模型」下拉里，必须有品牌名")
    }
  }
}
