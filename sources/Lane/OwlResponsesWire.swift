//
//  OwlResponsesWire.swift
//  法墨输入法 (Owltype) — Qwen / OpenAI / 火山方舟 / DeepSeek `/responses` wire format
//
//  `/responses` is not just a renamed `/chat/completions`: it uses `input`, emits `output`
//  items, and streams `response.output_text.delta` events. The four providers also have small
//  dialect differences, so every Responses caller shares this file instead of hand-building JSON.
//

import Foundation

enum OwlResponsesDialect: String, Codable, CaseIterable, Equatable, Sendable {
  case qwen
  case ark
  case openAI
  case deepseek
}

struct OwlResponsesSource: Codable, Equatable, Sendable {
  let title: String
  let url: String
}

struct OwlResponsesUsage: Codable, Equatable, Sendable {
  let inputTokens: Int
  let outputTokens: Int
  let totalTokens: Int
  let cachedTokens: Int
}

struct OwlResponsesResult: Codable, Equatable, Sendable {
  let text: String
  let model: String?
  let usage: OwlResponsesUsage?
  let sources: [OwlResponsesSource]
}

enum OwlResponsesWireError: Error {
  case malformedResponse
}

enum OwlResponsesWire {
  /// Whether this routing belongs to 阿里云百炼 (DashScope). Note what it does NOT look at: the
  /// **model**. 百炼 is Responses-only by product decision (2026-07-31) — 旧的 `/chat/completions`
  /// 不再兼容 — so the platform alone decides the wire, and a 百炼-hosted third-party model
  /// (`deepseek-*` / `kimi-*` / …) goes to `/responses` like everything else. It may well come back
  /// 400 there: 官方 Responses 文档只列 Qwen 系列。That upstream refusal is surfaced verbatim
  /// (「验证连通性」prints the server's own words), which is the honest outcome — the alternative
  /// was the silent fallback this guard used to perform, quietly speaking a wire we no longer
  /// support and calling it success.
  ///
  /// The host fallback preserves custom profiles created before provider ids were persisted; a nil
  /// endpoint (a form with no URL yet) leaves the provider id alone to decide.
  static func isQwen(providerID: String, endpoint: URL?) -> Bool {
    dialect(providerID: providerID, model: "", endpoint: endpoint) == .qwen
  }

  /// Whether this routing belongs to 火山方舟's Doubao service. Deliberately NOT symmetric with
  /// `isQwen`: the model prefix stays a hard requirement here, because 方舟 hosts third-party
  /// models that genuinely keep their own wire — only 百炼 was declared Responses-only. The host
  /// fallback preserves custom profiles created before provider ids were persisted.
  static func isArk(providerID: String, model: String, endpoint: URL?) -> Bool {
    let raw: String? = OwlProviderCore.call("dialect", ["providerID": providerID, "model": model, "host": endpoint?.host ?? ""])
    return raw == "ark"
  }

  static func isDeepSeek(providerID: String, model: String, endpoint: URL?) -> Bool {
    dialect(providerID: providerID, model: model, endpoint: endpoint) == .deepseek
  }

  /// The Responses dialect carrying this routing's WHOLE Owltype surface (plain generation and
  /// search alike), or nil when the provider stays on chat completions. Qwen / 豆包 / DeepSeek are
  /// the full-surface Responses providers; every non-streaming skill client and the plain stream
  /// ask this one question instead of re-deriving provider checks.
  ///
  /// 次序不是随手排的：百炼 是 Responses-only 且**不看 model**，所以一个托管在百炼上的
  /// `deepseek-*` 必须先被 `isQwen` 认走 —— 它归百炼的 wire。只有打到 `api.deepseek.com`
  /// 自家端点的才是 `.deepseek`。把 `isDeepSeek` 提到前面会把百炼的托管模型抢过来，用
  /// DeepSeek 的方言去打百炼的端点。
  static func dialect(providerID: String, model: String, endpoint: URL?) -> OwlResponsesDialect? {
    let raw: String? = OwlProviderCore.call("dialect", ["providerID": providerID, "model": model, "host": endpoint?.host ?? ""])
    return raw.flatMap(OwlResponsesDialect.init(rawValue:))
  }

  /// Rewrite a stored legacy chat endpoint to its `/responses` sibling. Already-migrated profiles
  /// and bare API base URLs are accepted as well, so existing user data needs no migration pass.
  static func url(from endpoint: URL) -> URL? {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
    components.path = OwlProviderCore.call("responsesPath", ["path": components.path])
    components.query = nil
    components.fragment = nil
    return components.url
  }

  /// Build either a plain or web-search Responses request body.
  ///
  /// Qwen's current Responses documentation recommends `reasoning.effort` over the legacy
  /// `enable_thinking`, so interactive Owltype requests use `none`. 方舟's own switch is
  /// `thinking.type: disabled` — its Responses default burns hidden reasoning tokens before the
  /// first output character (官方示例即带 211 reasoning tokens), so it is forced OFF on every
  /// request, not just search. Owltype sends complete message history and never retrieves Responses
  /// by id, so `store: false` opts out of both providers' documented default server-side
  /// persistence (方舟 `store` 默认 true). When the UI promises a searched answer, `tool_choice:
  /// required` prevents the model from silently answering from training data.
  ///
  /// `jsonObject` 只在 `.deepseek` 分支落地，见那里的注释——不是漏写，是别的方言当初迁移时就没带。
  static func body(
    model: String,
    messages: [OwlDeepSeekMessage],
    stream: Bool,
    dialect: OwlResponsesDialect,
    webSearch: Bool,
    jsonObject: Bool = false,
    temperature: Double? = nil
  ) -> [String: Any] {
    OwlProviderCore.object("responsesBody", ["model": model, "messages": OwlAppCore.payload(messages),
      "stream": stream, "dialect": dialect.rawValue, "webSearch": webSearch,
      "jsonObject": jsonObject, "temperature": temperature as Any? ?? NSNull()])
  }

  /// Build a complete JSON request from an existing provider endpoint. Keeping auth and endpoint
  /// rewriting here lets non-streaming skills use the exact same Qwen contract as streaming chat.
  static func request(
    endpoint: URL,
    model: String,
    messages: [OwlDeepSeekMessage],
    apiKey: String,
    authHeaderStyle: OwlProviderAuthHeaderStyle,
    dialect: OwlResponsesDialect,
    stream: Bool,
    webSearch: Bool,
    jsonObject: Bool = false,
    temperature: Double? = nil,
    timeout: TimeInterval
  ) throws -> URLRequest {
    guard let responsesURL = url(from: endpoint) else {
      throw OwlResponsesWireError.malformedResponse
    }
    var request = URLRequest(url: responsesURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
    authHeaderStyle.apply(to: &request, apiKey: apiKey)
    request.timeoutInterval = timeout
    request.httpBody = try JSONSerialization.data(withJSONObject: body(
      model: model,
      messages: messages,
      stream: stream,
      dialect: dialect,
      webSearch: webSearch,
      jsonObject: jsonObject,
      temperature: temperature))
    return request
  }

  /// Parse a non-streaming Responses payload: final assistant text, token accounting, and any URL
  /// sources returned by built-in web search. Source traversal is intentionally tolerant because
  /// providers may put URLs in `web_search_call.action.sources` or output-text annotations.
  static func parse(_ data: Data) throws -> OwlResponsesResult {
    let result: OwlResponsesResult? = OwlProviderCore.call("responsesParse", ["bytes": Array(data)])
    guard let result else { throw OwlResponsesWireError.malformedResponse }
    return result
  }

}
