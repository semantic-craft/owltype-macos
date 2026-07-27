//
//  FamoSearchControl.swift
//  法墨输入法 (Famo) — 任意提问「联网搜索」的逐家 wire format
//
//  One "search requested" flag fans out to each provider's own request shape. Providers without
//  search support resolve to `.none`, so a caller can ask "can this one search?" without a table.
//
//  The providers split by TRANSPORT, and the split is a type (`Transport`) rather than a
//  convention: Qwen(百炼/DashScope) / 小米MiMo / Perplexity search on `/chat/completions` (via
//  top-level body extras, or none at all for Perplexity), 豆包(火山方舟) / OpenAI search ONLY on
//  `/responses` — a different endpoint, a different body, and a different SSE event shape (see
//  `FamoResponsesStreamingClient`) — and 豆包搜索 is not a chat endpoint at all: it RETRIEVES web
//  results that the main model then answers from. Asking a `/responses` provider to search through
//  `extraBody` silently does nothing, which is exactly why the capability is modelled, not implied.
//
//  The field shapes are the ones 来源核验 already exercises against the live providers
//  (`FamoSelectionPolish.makeChatSearchRequest` / `makeResponsesSearchRequest`) — same parameters,
//  minus 核验-specific 强制检索/来源回传, because 任意提问 is an open question, not a verification.
//
//  Pure value logic: no network, no UserDefaults, no Keychain. Safe to call from anywhere.
//

import Foundation

// MARK: - 联网搜索专用凭据

/// 「联网搜索专用 Key」：与主模型供应商解耦的检索账号。
///
/// 为什么不复用 `providers.json` 里的供应商档案：这两家都不是用来当主模型的 —— 豆包搜索 Global 版
/// 只返回网页结果（答案仍由主模型写），它的 Key 也来自「联网搜索控制台」而不是火山方舟；Perplexity
/// 则是另一套账号。把它们混进主模型列表，会让「默认供应商」多出不能当主模型用的条目。所以它们只在
/// 设置的联网搜索区块出现，Keychain 用 `famo.search.*` 命名空间与 `famo.provider.*` 分开 —— 删掉
/// 某家对话供应商不会连带删掉搜索凭据。
///
/// Pure descriptor: an id / 端点 / Keychain 账号名，**不含**密钥本身。
enum FamoSearchCredential: String, CaseIterable, Sendable {
  /// 豆包搜索 Global 版（`open.feedcoopapi.com/search_api/global_search`）——纯检索，自己不作答。
  /// Key 取自「联网搜索控制台 - API Key 管理 - 按量后付费」，**不是**火山方舟的模型 Key。
  case doubaoSearch = "doubao_search"
  /// Perplexity Sonar —— OpenAI 兼容的 `/chat/completions`，联网是模型的默认行为（要关掉才需显式传
  /// `disable_search`），所以它一个 `extraBody` 字段都不需要。
  case perplexity = "perplexity"

  var providerID: String { rawValue }

  var displayName: String {
    switch self {
    case .doubaoSearch: return "豆包搜索"
    case .perplexity:   return "Perplexity"
    }
  }

  var endpoint: URL {
    switch self {
    case .doubaoSearch: return URL(string: "https://open.feedcoopapi.com/search_api/global_search")!
    case .perplexity:   return URL(string: "https://api.perplexity.ai/chat/completions")!
    }
  }

  /// 模型名。豆包搜索没有「模型」概念（检索 API），这里只是个不为空的标识，不进请求体。
  var model: String {
    switch self {
    case .doubaoSearch: return "global_search"
    case .perplexity:   return "sonar-pro"
    }
  }

  /// Keychain 账号名。与供应商档案的 `famo.provider.<id>.apiKey` 刻意分属两个命名空间。
  var secretName: String { "famo.search.\(rawValue).apiKey" }

  var keyHint: String {
    switch self {
    case .doubaoSearch: return "联网搜索控制台的 API Key，不是方舟模型 Key"
    case .perplexity:   return "pplx-…"
    }
  }

  /// 合成的路由 —— 专用凭据没有 `providers.json` 档案可解析，端点/模型都由这里定死。
  var routing: FamoCloudRouting {
    FamoCloudRouting(
      providerID: providerID,
      endpoint: endpoint,
      model: model,
      secretName: secretName,
      authHeaderStyle: .bearer
    )
  }

  init?(providerID: String) {
    guard let match = Self(rawValue: providerID.lowercased()) else { return nil }
    self = match
  }
}

enum FamoSearchControl {
  /// Which provider family's search wire format applies. `.none` = this provider can't search.
  enum Channel: Equatable {
    case dashScope
    case mimo
    /// 火山方舟 / 豆包 — search lives on `/responses` only.
    case ark
    /// OpenAI — search lives on `/responses` only, with a leaner body than 方舟's.
    case openAI
    /// Perplexity Sonar — `/chat/completions`, search always on, no extra body fields.
    case perplexity
    /// 豆包搜索 Global 版 — a RETRIEVAL API: returns web documents, generates no answer.
    case doubaoSearch
    case none
  }

  /// HOW a provider's search request is sent. Carried by `FamoAskSearchRoute` so `openAsk` picks
  /// the matching client instead of inferring it from the provider id at the call site.
  enum Transport: Equatable {
    /// `/chat/completions` + the top-level extras from `extraBody(providerID:host:)`.
    case chatCompletions
    /// `/responses`. `isOpenAI` picks the body dialect: OpenAI's `web_search` tool takes none of
    /// 方舟's `max_keyword`/`limit` extras (they 400), and OpenAI has no `thinking` field.
    case responses(isOpenAI: Bool)
    /// 先检索、再由**主模型**作答（豆包搜索 Global 版）。与上面两条的关键区别：这家不产出答案，
    /// 所以这条路走通还额外要求主模型自己是 ready 的。
    case retrieval
    /// This provider cannot search at all.
    case none
  }

  /// The transport that carries `providerID`'s web search.
  static func transport(providerID: String, host: String) -> Transport {
    switch channel(providerID: providerID, host: host) {
    case .dashScope, .mimo, .perplexity:
      return .chatCompletions
    case .ark:
      return .responses(isOpenAI: false)
    case .openAI:
      return .responses(isOpenAI: true)
    case .doubaoSearch:
      return .retrieval
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
    case .dashScope:
      return ["enable_search": true]
    case .mimo:
      // MiMo 的联网与思考互斥（同 `FamoSelectionPolish`）：显式关掉思考，否则搜索工具不触发。
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
    case .perplexity:
      // Perplexity 的联网是模型的默认行为（关掉才要传 `disable_search`）—— 一个字段都不用加。
      return [:]
    case .ark, .openAI, .doubaoSearch, .none:
      // 豆包/OpenAI 的搜索参数属于 `/responses` 请求体（`FamoResponsesWire.searchBody`），不是
      // chat/completions 的顶层字段 —— 塞在这里会被端点静默忽略。豆包搜索根本不是 chat 端点。
      return [:]
    }
  }

  /// Whether this provider can do 任意提问 联网搜索 at all, on either transport.
  static func supportsSearch(providerID: String, host: String) -> Bool {
    transport(providerID: providerID, host: host) != .none
  }

  /// Provider ids that support search, in the 自动 fallback priority order used by
  /// `FamoAskSearchResolver`.
  ///
  /// 1. 「联网搜索专用 Key」两家在最前：用户专门为联网填的凭据，意图比「顺手复用某家对话密钥」明确。
  /// 2. 然后是内建搜索的对话供应商：`/chat/completions` 的百炼/MiMo（一期已实机验证）在前，
  ///    `/responses` 的 OpenAI 在后。
  ///
  /// 豆包(方舟)**不在**这条列表里：方舟 `/responses` 的 `web_search` 工具要单独开通内容插件，没开通
  /// 时整条请求 404 `ToolNotOpen`；豆包这条线改走独立的「豆包搜索」检索 API（`.doubaoSearch`）。方舟
  /// 的 `/responses` 搜索 wire 仍留着——来源核验还在用（`FamoSelectionPolish`）。
  static let searchProviderIDs =
    FamoSearchCredential.allCases.map(\.providerID) + ["qwen", "mimo", "openai"]

  /// 面向用户的联网模型署名名（品牌名，比公司名更贴近用户认知）。非可联网 → nil。
  static func displayName(for providerID: String) -> String? {
    switch channel(providerID: providerID, host: "") {
    case .dashScope:    return "通义千问"
    case .mimo:         return "MiMo"
    case .ark:          return "豆包"
    case .openAI:       return "OpenAI"
    case .perplexity:   return FamoSearchCredential.perplexity.displayName
    case .doubaoSearch: return FamoSearchCredential.doubaoSearch.displayName
    case .none:         return nil
    }
  }

  /// Resolve the search channel. `providerID` wins; `host` is the fallback for a custom profile
  /// whose id was never stamped — same precedence as `FamoLLMProviderCatalog.inferredProviderID`.
  static func channel(providerID: String, host: String) -> Channel {
    switch providerID.lowercased() {
    case "qwen":                                    return .dashScope
    case "mimo":                                    return .mimo
    case "doubao":                                  return .ark
    case "openai":                                  return .openAI
    case FamoSearchCredential.perplexity.rawValue:  return .perplexity
    case FamoSearchCredential.doubaoSearch.rawValue: return .doubaoSearch
    default: break
    }
    let h = host.lowercased()
    if h.contains("dashscope") || h.contains("aliyuncs")   { return .dashScope }
    if h.contains("xiaomimimo")                            { return .mimo }
    if h.contains("perplexity")                            { return .perplexity }
    if h.contains("feedcoopapi")                           { return .doubaoSearch }
    if h.contains("volces") || h.contains("volcengine")    { return .ark }
    if h == "api.openai.com"                               { return .openAI }
    return .none
  }
}
