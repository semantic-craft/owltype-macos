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

enum OwlResponsesWireError: Error {
  case malformedResponse
}

enum OwlResponsesWire {
  /// The Responses dialect carrying this routing's WHOLE Owltype surface (plain generation and
  /// search alike), or nil when the provider stays on chat completions. Qwen / 豆包 / DeepSeek are
  /// the full-surface Responses providers; every non-streaming skill client and the plain stream
  /// ask this one question instead of re-deriving provider checks.
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

  /// Qwen's current Responses documentation recommends `reasoning.effort` over the legacy
  /// `enable_thinking`, so interactive Owltype requests use `none`. 方舟's own switch is
  /// `thinking.type: disabled` — its Responses default burns hidden reasoning tokens before the
  /// first output character (官方示例即带 211 reasoning tokens), so it is forced OFF on every
  /// request, not just search. Owltype sends complete message history and never retrieves Responses
  /// by id, so `store: false` opts out of both providers' documented default server-side
  /// persistence (方舟 `store` 默认 true). When the UI promises a searched answer, `tool_choice:
  /// required` prevents the model from silently answering from training data.
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

}
