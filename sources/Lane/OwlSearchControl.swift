//
//  OwlSearchControl.swift
//  猫头鹰输入法 (Owltype) — 任意提问「联网搜索」的逐家 wire format
//
//  One "search requested" flag fans out to each provider's own request shape. Providers without
//  search support resolve to `.none`, so a caller can ask "can this one search?" without a table.
//
//  Every search-capable provider — Qwen(百炼/DashScope) / 豆包(火山方舟) / OpenAI / DeepSeek —
//  searches on `/responses`; the per-provider differences are carried by `OwlResponsesDialect`
//  (see `OwlResponsesWire` and `OwlResponsesStreamingClient`), not by a separate endpoint or
//  transport.
//
//  The field shapes are the ones 来源核验 already exercises against the live providers
//  (`OwlSelectionPolish.makeResponsesSearchRequest`) — same parameters, minus 核验-specific
//  强制检索/来源回传, because 任意提问 is an open question, not a verification.
//
//  Pure value logic: no network, no UserDefaults, no Keychain. Safe to call from anywhere.
//

import Foundation

enum OwlSearchControl {
  /// Which provider family's search wire format applies. `.none` = this provider can't search.
  enum Channel: Equatable {
    case dashScope
    /// 火山方舟 / 豆包 — search lives on `/responses` only.
    case ark
    /// OpenAI — search lives on `/responses` only, with a leaner body than 方舟's.
    case openAI
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

  /// The transport that carries `providerID`'s web search: `.responses(dialect)` for a
  /// search-capable provider, `.none` otherwise.
  ///
  /// Search capability is distinct from Responses generation support. DeepSeek's `/responses`
  /// search only serves `deepseek-v4-flash` (V4.1 Flash ignores built-in web_search tools), so
  /// `model` gates which DeepSeek models may enter the search-provider queue.
  static func transport(providerID: String, host: String, model: String = "") -> Transport {
    switch channel(providerID: providerID, host: host) {
    case .dashScope:
      return .responses(.qwen)
    case .ark:
      return .responses(.ark)
    case .deepSeek:
      // V4.1 Flash accepts Responses, but ignores built-in web_search tools.
      // Do not mistake generation support for a usable search route.
      let m = model.lowercased()
      if m == "deepseek-flash" { return .none }
      return m.isEmpty || m.hasPrefix("deepseek-v4-flash") ? .responses(.deepseek) : .none
    case .openAI:
      return .responses(.openAI)
    case .none:
      return .none
    }
  }

  /// Whether this provider can do 任意提问 联网搜索 at all.
  static func supportsSearch(providerID: String, host: String, model: String = "") -> Bool {
    transport(providerID: providerID, host: host, model: model) != .none
  }

  /// Provider ids that support search, in the 自动 fallback priority order used by
  /// `OwlAskSearchResolver`. Qwen 优先，其后是豆包/OpenAI/DeepSeek 的 Responses 顺位。
  ///
  /// DeepSeek 排在最后是实测定的（2026-07-31，同五题）：它能搜，但来源 URL 中位只有 1 条
  /// （Qwen 24 条）——Owltype 的来源 chip 全靠这个；时长中位 16.6s vs Qwen 9.4s。用户显式选它时
  /// 照常用，自动兜底时 Qwen 优先。
  static let searchProviderIDs = ["qwen", "doubao", "openai", "deepseek"]

  /// 面向用户的联网模型署名名（品牌名，比公司名更贴近用户认知）。非可联网 → nil。
  static func displayName(for providerID: String) -> String? {
    // 独立搜索层（`OwlWebSearch`）不是一家「可联网的模型」，而是「谁检索的」——它没有 Channel，
    // 但署名 chip 仍要显示，所以在按 Channel 分派之前先认掉。
    if let backend = OwlWebSearchBackend.backend(forAttributionID: providerID) {
      return backend.displayName
    }
    switch channel(providerID: providerID, host: "") {
    case .dashScope: return "通义千问"
    case .ark:       return "豆包"
    case .openAI:    return "OpenAI"
    case .deepSeek:  return "DeepSeek"
    case .none:      return nil
    }
  }

  /// Resolve the search channel. `providerID` wins; `host` is the fallback for a custom profile
  /// whose id was never stamped — same precedence as `OwlLLMProviderCatalog.inferredProviderID`.
  static func channel(providerID: String, host: String) -> Channel {
    switch providerID.lowercased() {
    case "qwen":   return .dashScope
    case "doubao": return .ark
    case "openai": return .openAI
    case "deepseek": return .deepSeek
    default: break
    }
    let h = host.lowercased()
    if h.contains("dashscope") || h.contains("aliyuncs")   { return .dashScope }
    if h.contains("volces") || h.contains("volcengine")    { return .ark }
    if h == "api.openai.com"                               { return .openAI }
    if h.contains("deepseek")                              { return .deepSeek }
    return .none
  }
}
