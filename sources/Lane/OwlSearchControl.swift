//
//  OwlSearchControl.swift
//  猫头鹰输入法 (Owltype) — 任意提问「联网搜索」的 wire format
//
//  任意提问的联网只走 DeepSeek：先调 DeepSeek Search 接口取回网页（`OwlDeepSeekSearch`），再由
//  `searchModel` 依据编号结果作答。其他供应商一律 `.none` —— 调用方问「这家能不能搜」时不需要再查一张表。
//
//  来源核验用同一个检索接口，另可叠加豆包搜索，见 `OwlSourceVerificationService`。
//
//  Pure value logic: no network, no UserDefaults, no Keychain. Safe to call from anywhere.
//

import Foundation

enum OwlSearchControl {
  /// Which provider family's search applies. `.none` = this provider can't search.
  enum Channel: Equatable {
    case deepSeek
    case none
  }

  /// How a search-capable provider's search is carried. Carried by `OwlAskSearchRoute` so the ask
  /// adapter dispatches from this type instead of re-deriving it from the provider id.
  enum Transport: Equatable {
    /// 先 `POST /v1/tools/search` 取回网页，再把编号结果交给作答模型。
    case deepSeekSearchAPI
    /// This provider cannot search at all.
    case none
  }

  /// 联网与作答型号无关：检索是一次独立的 HTTP 请求，任何 DeepSeek 型号都能依据结果作答。
  /// 不靠模型内置的 `web_search` 工具——2026-10-21 实测 V4.1 Flash 收下工具却不搜，凭记忆作答。
  /// The channel itself is `OwlProviderCapabilities.searchChannel(providerID:host:)`.
  static func transport(providerID: String, host: String) -> Transport {
    switch OwlProviderCapabilities.searchChannel(providerID: providerID, host: host) {
    case .deepSeek: return .deepSeekSearchAPI
    case .none:     return .none
    }
  }

  /// Whether this provider can do 任意提问 联网搜索 at all.
  static func supportsSearch(providerID: String, host: String) -> Bool {
    transport(providerID: providerID, host: host) != .none
  }

  /// The one provider id 任意提问 联网搜索 routes to.
  static let searchProviderID = "deepseek"

  /// 官方端点上依据检索结果作答的型号：V4.1 Flash，便宜、约 1 秒出首字。档案选的作答型号只管普通问答；
  /// 代理端点保留档案型号（代理不一定提供这个型号）。
  static let searchModel: String = OwlAIBusinessCore.call("searchModel", ["host": "api.deepseek.com"])
}
