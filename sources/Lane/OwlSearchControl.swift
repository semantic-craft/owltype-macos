//
//  OwlSearchControl.swift
//  法墨输入法 (Owltype) — 任意提问「联网搜索」的逐家 wire format
//
//  One "search requested" flag fans out to each provider's own request shape. Providers without
//  search support resolve to `.none`, so a caller can ask "can this one search?" without a table.
//
//  The four providers split by TRANSPORT, and the split is a type (`Transport`) rather than a
//  convention: 小米 MiMo searches on `/chat/completions` via top-level body extras, while
//  Qwen(百炼/DashScope) / 豆包(火山方舟) / OpenAI search on `/responses` — a different endpoint,
//  a different body, and a different SSE event shape (see `OwlResponsesStreamingClient`). Asking
//  a `/responses` provider to search through `extraBody` silently does nothing, which is exactly
//  why the capability is modelled instead of implied.
//
//  The field shapes are the ones 来源核验 already exercises against the live providers
//  (`OwlSelectionPolish.makeChatSearchRequest` / `makeResponsesSearchRequest`) — same parameters,
//  minus 核验-specific 强制检索/来源回传, because 任意提问 is an open question, not a verification.
//
//  Pure value logic: no network, no UserDefaults, no Keychain. Safe to call from anywhere.
//

import Foundation

enum OwlSearchControl {
  /// Which provider family's search wire format applies. `.none` = this provider can't search.
  enum Channel: Equatable {
    case dashScope
    case mimo
    /// 火山方舟 / 豆包 — search lives on `/responses` only.
    case ark
    /// OpenAI — search lives on `/responses` only, with a leaner body than 方舟's.
    case openAI
    /// DeepSeek — search lives on `/responses` only，且**必须开着思考**，见 `OwlResponsesWire`。
    case deepSeek
    case none
  }

  /// HOW a provider's search request is sent. Carried by `OwlAskSearchRoute` so the ask adapter picks
  /// the matching client instead of inferring it from the provider id at the call site.
  enum Transport: Equatable {
    /// `/chat/completions` + the top-level extras from `extraBody(providerID:host:)`.
    case chatCompletions
    /// `/responses`, with an explicit provider wire dialect.
    case responses(OwlResponsesDialect)
    /// This provider cannot search at all.
    case none
  }

  /// The transport that carries `providerID`'s web search.
  ///
  /// 百炼 no longer takes a model into account: it is Responses-only (2026-07-31 产品决定), so every
  /// 百炼 routing searches on `/responses`. The old `model` parameter existed solely to route a
  /// 百炼-hosted non-Qwen model back to `.none`; that fallback is gone with the rest of 旧模式.
  ///
  /// `model` 后来又回来了，但**不是**给百炼的：DeepSeek 的 `/responses` 目前只收
  /// `deepseek-v4-flash`（官方注明 pro 2026 年 8 月初才支持），所以配着 pro 的 DeepSeek 档案
  /// 不能搜——如实返回 `.none` 让顺位跳过它，比发出去换一个 400 强。默认空串 = 不知道型号时
  /// 按"能搜"处理，与 `OwlResponsesWire.dialect` 的 providerID 优先口径一致。
  static func transport(providerID: String, host: String, model: String = "") -> Transport {
    switch channel(providerID: providerID, host: host) {
    case .mimo:
      return .chatCompletions
    case .dashScope:
      return .responses(.qwen)
    case .ark:
      return .responses(.ark)
    case .deepSeek:
      let m = model.lowercased()
      return m.isEmpty || m.hasPrefix("deepseek-v4-flash") ? .responses(.deepseek) : .none
    case .openAI:
      return .responses(.openAI)
    case .none:
      return .none
    }
  }

  /// Extra `/chat/completions` body fields that turn on web search for `providerID`.
  ///
  /// Empty for BOTH the no-search providers and the `/responses` ones — merging an empty dict is a
  /// no-op, so the caller never has to branch. Note what this means: an empty dict is NOT "cannot
  /// search"; ask `transport(providerID:host:)` for that.
  static func extraBody(providerID: String, host: String) -> [String: Any] {
    switch channel(providerID: providerID, host: host) {
    case .mimo:
      // MiMo 的联网与思考互斥（同 `OwlSelectionPolish`）：显式关掉思考，否则搜索工具不触发。
      // 与 `OwlThinkingControl` 给 mimo 的字段同值——这里留着是因为它是**搜索能否触发**的前提，
      // 不只是省 token；两处同时写成 `{"type":"disabled"}`，合并后仍是同一个值。
      return [
        "thinking": ["type": "disabled"],
        "tool_choice": "auto",
        "tools": [[
          "type": "web_search",
          "max_keyword": 3,
          "force_search": true,
          "limit": 3,
        ]],
      ]
    case .dashScope, .ark, .openAI, .deepSeek, .none:
      // Qwen/豆包/OpenAI/DeepSeek 的搜索参数属于 `/responses` 请求体（`OwlResponsesWire.body`），
      // 不是 chat/completions 的顶层字段 —— 塞在这里会被端点静默忽略。
      return [:]
    }
  }

  /// Whether this provider can do 任意提问 联网搜索 at all, on either transport.
  static func supportsSearch(providerID: String, host: String, model: String = "") -> Bool {
    transport(providerID: providerID, host: host, model: model) != .none
  }

  /// Provider ids that support search, in the 自动 fallback priority order used by
  /// `OwlAskSearchResolver`. Qwen 优先，其后保留 MiMo Chat 与豆包/OpenAI Responses 的顺位。
  ///
  /// DeepSeek 排在最后是实测定的（2026-07-31，同五题）：它能搜，但来源 URL 中位只有 1 条
  /// （Qwen 24 条）——Owltype 的来源 chip 全靠这个；时长中位 16.6s vs Qwen 9.4s。用户显式选它时
  /// 照常用，自动兜底时 Qwen 优先。
  static let searchProviderIDs = ["qwen", "mimo", "doubao", "openai", "deepseek"]

  /// 面向用户的联网模型署名名（品牌名，比公司名更贴近用户认知）。非可联网 → nil。
  static func displayName(for providerID: String) -> String? {
    // 独立搜索层（`OwlWebSearch`）不是一家「可联网的模型」，而是「谁检索的」——它没有 Channel，
    // 但署名 chip 仍要显示，所以在按 Channel 分派之前先认掉。
    if let backend = OwlWebSearchBackend.backend(forAttributionID: providerID) {
      return backend.displayName
    }
    switch channel(providerID: providerID, host: "") {
    case .dashScope: return "通义千问"
    case .mimo:      return "MiMo"
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
    case "mimo":   return .mimo
    case "doubao": return .ark
    case "openai": return .openAI
    case "deepseek": return .deepSeek
    default: break
    }
    let h = host.lowercased()
    if h.contains("dashscope") || h.contains("aliyuncs")   { return .dashScope }
    if h.contains("xiaomimimo")                            { return .mimo }
    if h.contains("volces") || h.contains("volcengine")    { return .ark }
    if h == "api.openai.com"                               { return .openAI }
    if h.contains("deepseek")                              { return .deepSeek }
    return .none
  }
}
