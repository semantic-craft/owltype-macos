//
//  OwlSearchControl.swift
//  猫头鹰输入法 (Owltype) — 任意提问「联网搜索」的 wire format
//
//  任意提问的联网只走 DeepSeek：`/responses` + 内置 `web_search`，dialect 见 `OwlResponsesWire`。
//  其他供应商一律 `.none` —— 调用方问「这家能不能搜」时不需要再查一张表。
//
//  （来源核验另有自己的检索路径，见 `OwlSelectionPolish.makeResponsesSearchRequest`，不受这里约束。）
//
//  Pure value logic: no network, no UserDefaults, no Keychain. Safe to call from anywhere.
//

import Foundation

enum OwlSearchControl {
  /// Which provider family's search wire format applies. `.none` = this provider can't search.
  enum Channel: Equatable {
    /// DeepSeek — search lives on `/responses` only，且**必须开着思考**，见 `OwlResponsesWire`。
    case deepSeek
    case none
  }

  /// How a search-capable provider's request is sent: `/responses` with a provider-specific
  /// dialect, or `.none` when the provider cannot search at all. Carried by `OwlAskSearchRoute`
  /// so the ask adapter dispatches from this type instead of re-deriving it from the provider id.
  enum Transport: Equatable {
    /// `/responses`, with an explicit provider wire dialect.
    case responses(OwlResponsesDialect)
    /// This provider cannot search at all.
    case none
  }

  /// The transport that carries `providerID`'s web search: `.responses(.deepseek)` for a
  /// search-capable DeepSeek profile, `.none` otherwise.
  ///
  /// Search capability is distinct from Responses generation support. DeepSeek's `/responses`
  /// search only serves `deepseek-v4-flash` (V4.1 Flash ignores built-in web_search tools), so
  /// `model` gates which DeepSeek models may search.
  static func transport(providerID: String, host: String, model: String = "") -> Transport {
    switch channel(providerID: providerID, host: host) {
    case .deepSeek:
      // V4.1 Flash accepts Responses, but ignores built-in web_search tools.
      // Do not mistake generation support for a usable search route.
      let m = model.lowercased()
      if m == "deepseek-flash" { return .none }
      return m.isEmpty || m.hasPrefix("deepseek-v4-flash") ? .responses(.deepseek) : .none
    case .none:
      return .none
    }
  }

  /// Whether this provider can do 任意提问 联网搜索 at all.
  static func supportsSearch(providerID: String, host: String, model: String = "") -> Bool {
    transport(providerID: providerID, host: host, model: model) != .none
  }

  /// The one provider id 任意提问 联网搜索 routes to.
  static let searchProviderID = "deepseek"

  /// 面向用户的联网署名名。非可联网 → nil。
  static func displayName(for providerID: String) -> String? {
    switch channel(providerID: providerID, host: "") {
    case .deepSeek: return "DeepSeek"
    case .none:     return nil
    }
  }

  /// Resolve the search channel. `providerID` wins; `host` is the fallback for a custom profile
  /// whose id was never stamped — same precedence as `OwlLLMProviderCatalog.inferredProviderID`.
  static func channel(providerID: String, host: String) -> Channel {
    if providerID.lowercased() == searchProviderID { return .deepSeek }
    return host.lowercased().contains("deepseek") ? .deepSeek : .none
  }
}
