//
//  FamoResponsesWire.swift
//  法墨输入法 (Famo) — Qwen / OpenAI / 火山方舟 `/responses` wire format
//
//  `/responses` is not just a renamed `/chat/completions`: it uses `input`, emits `output`
//  items, and streams `response.output_text.delta` events. The three providers also have small
//  dialect differences, so every Responses caller shares this file instead of hand-building JSON.
//

import Foundation

enum FamoResponsesDialect: CaseIterable, Equatable, Sendable {
  case qwen
  case ark
  case openAI
}

struct FamoResponsesSource: Equatable, Sendable {
  let title: String
  let url: String
}

struct FamoResponsesUsage: Equatable, Sendable {
  let inputTokens: Int
  let outputTokens: Int
  let totalTokens: Int
  let cachedTokens: Int
}

struct FamoResponsesResult: Equatable, Sendable {
  let text: String
  let model: String?
  let usage: FamoResponsesUsage?
  let sources: [FamoResponsesSource]
}

enum FamoResponsesWireError: Error {
  case malformedResponse
}

enum FamoResponsesWire {
  /// Whether this routing belongs to DashScope's Qwen service. The host fallback preserves custom
  /// profiles created before provider ids were persisted.
  static func isQwen(providerID: String, model: String, endpoint: URL) -> Bool {
    guard model.lowercased().hasPrefix("qwen") else { return false }
    if providerID.lowercased() == "qwen" { return true }
    let host = endpoint.host?.lowercased() ?? ""
    return host.contains("dashscope") || host.contains("aliyuncs")
  }

  /// Whether this routing belongs to 火山方舟's Doubao service. Mirrors `isQwen`: the model prefix
  /// is the hard requirement (a custom Ark-hosted third-party model keeps its own wire), the host
  /// fallback preserves custom profiles created before provider ids were persisted.
  static func isArk(providerID: String, model: String, endpoint: URL) -> Bool {
    guard model.lowercased().hasPrefix("doubao") else { return false }
    if providerID.lowercased() == "doubao" { return true }
    let host = endpoint.host?.lowercased() ?? ""
    return host.contains("volces") || host.contains("volcengine")
  }

  /// The Responses dialect carrying this routing's WHOLE Famo surface (plain generation and
  /// search alike), or nil when the provider stays on chat completions. Qwen 与豆包 are the two
  /// full-surface Responses providers; every non-streaming skill client and the plain stream ask
  /// this one question instead of re-deriving provider checks.
  static func dialect(providerID: String, model: String, endpoint: URL) -> FamoResponsesDialect? {
    if isQwen(providerID: providerID, model: model, endpoint: endpoint) { return .qwen }
    if isArk(providerID: providerID, model: model, endpoint: endpoint) { return .ark }
    return nil
  }

  /// Rewrite a stored legacy chat endpoint to its `/responses` sibling. Already-migrated profiles
  /// and bare API base URLs are accepted as well, so existing user data needs no migration pass.
  static func url(from endpoint: URL) -> URL? {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      return nil
    }
    var path = components.path
    if path.hasSuffix("/chat/completions") {
      path.removeLast("/chat/completions".count)
      path += "/responses"
    } else if !path.hasSuffix("/responses") {
      path += path.hasSuffix("/") ? "responses" : "/responses"
    }
    components.path = path
    components.query = nil
    components.fragment = nil
    return components.url
  }

  /// Qwen explicitly accepts the familiar Chat-format `{role, content}` message array as
  /// Responses `input`. Ark requires every carried history item to be an `input_text` part
  /// (otherwise it asks for output-item id/status fields), and OpenAI accepts that EasyInputMessage
  /// shape as well.
  static func inputMessage(
    role: String,
    text: String,
    dialect: FamoResponsesDialect
  ) -> [String: Any] {
    if dialect == .qwen { return ["role": role, "content": text] }
    return [
      "role": role,
      "content": [["type": "input_text", "text": text]],
    ]
  }

  /// Compatibility overload for Ark/OpenAI callers that only need an input item.
  static func inputMessage(role: String, text: String) -> [String: Any] {
    inputMessage(role: role, text: text, dialect: .ark)
  }

  /// Build either a plain or web-search Responses request body.
  ///
  /// Qwen's current Responses documentation recommends `reasoning.effort` over the legacy
  /// `enable_thinking`, so interactive Famo requests use `none`. 方舟's own switch is
  /// `thinking.type: disabled` — its Responses default burns hidden reasoning tokens before the
  /// first output character (官方示例即带 211 reasoning tokens), so it is forced OFF on every
  /// request, not just search. Famo sends complete message history and never retrieves Responses
  /// by id, so `store: false` opts out of both providers' documented default server-side
  /// persistence (方舟 `store` 默认 true). When the UI promises a searched answer, `tool_choice:
  /// required` prevents the model from silently answering from training data.
  static func body(
    model: String,
    messages: [FamoDeepSeekMessage],
    stream: Bool,
    dialect: FamoResponsesDialect,
    webSearch: Bool,
    temperature: Double? = nil
  ) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "input": messages.map {
        inputMessage(role: $0.role, text: $0.content, dialect: dialect)
      },
      "stream": stream,
    ]
    if let temperature { body["temperature"] = temperature }

    switch dialect {
    case .qwen:
      body["store"] = false
      body["reasoning"] = ["effort": "none"]
      if webSearch {
        // 官方 Responses 文档建议 web_search 搭配 web_extractor「以取得最佳效果」，但它开不进
        // 这个形态（2026-07-31 对 qwen3.7-plus 实测）：`effort: none` 下直接 400「Normal mode
        // does not support web_extractor」；开思考后 `tool_choice: required` 又只准挂一个工具
        // （字符串与 allowed_tools 对象两种写法都 400）。要 extractor 就得同时放弃非思考
        // （实测 16.7s vs 5.4s）和强制检索 —— 两条都不让，所以维持单 web_search。
        body["tools"] = [["type": "web_search"]]
        body["tool_choice"] = "required"
      }
    case .ark:
      body["store"] = false
      body["thinking"] = ["type": "disabled"]
      if webSearch {
        body["tools"] = [["type": "web_search", "max_keyword": 2, "limit": 3]]
        body["max_tool_calls"] = 3
      }
    case .openAI:
      if webSearch { body["tools"] = [["type": "web_search"]] }
    }
    return body
  }

  /// Build a complete JSON request from an existing provider endpoint. Keeping auth and endpoint
  /// rewriting here lets non-streaming skills use the exact same Qwen contract as streaming chat.
  static func request(
    endpoint: URL,
    model: String,
    messages: [FamoDeepSeekMessage],
    apiKey: String,
    authHeaderStyle: FamoProviderAuthHeaderStyle,
    dialect: FamoResponsesDialect,
    stream: Bool,
    webSearch: Bool,
    temperature: Double? = nil,
    timeout: TimeInterval
  ) throws -> URLRequest {
    guard let responsesURL = url(from: endpoint) else {
      throw FamoResponsesWireError.malformedResponse
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
      temperature: temperature))
    return request
  }

  /// Parse a non-streaming Responses payload: final assistant text, token accounting, and any URL
  /// sources returned by built-in web search. Source traversal is intentionally tolerant because
  /// providers may put URLs in `web_search_call.action.sources` or output-text annotations.
  static func parse(_ data: Data) throws -> FamoResponsesResult {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FamoResponsesWireError.malformedResponse
    }
    let text = outputText(in: root).trimmingCharacters(in: .whitespacesAndNewlines)
    let usage = parseUsage(root["usage"] as? [String: Any])
    return FamoResponsesResult(
      text: text,
      model: root["model"] as? String,
      usage: usage,
      sources: collectSources(in: root)
    )
  }

  private static func outputText(in root: [String: Any]) -> String {
    if let convenience = root["output_text"] as? String, !convenience.isEmpty {
      return convenience
    }
    guard let output = root["output"] as? [[String: Any]] else { return "" }
    var pieces: [String] = []
    for item in output where item["type"] as? String == "message" {
      guard let content = item["content"] as? [[String: Any]] else { continue }
      for part in content where part["type"] as? String == "output_text" {
        if let text = part["text"] as? String, !text.isEmpty { pieces.append(text) }
      }
    }
    return pieces.joined()
  }

  private static func parseUsage(_ raw: [String: Any]?) -> FamoResponsesUsage? {
    guard let raw else { return nil }
    let input = raw["input_tokens"] as? Int ?? 0
    let output = raw["output_tokens"] as? Int ?? 0
    let total = raw["total_tokens"] as? Int ?? input + output
    let details = raw["input_tokens_details"] as? [String: Any]
    return FamoResponsesUsage(
      inputTokens: input,
      outputTokens: output,
      totalTokens: total,
      cachedTokens: details?["cached_tokens"] as? Int ?? 0
    )
  }

  private static func collectSources(in object: Any) -> [FamoResponsesSource] {
    var sources: [FamoResponsesSource] = []
    var seen = Set<String>()
    collectSources(in: object, into: &sources, seen: &seen)
    return sources
  }

  private static func collectSources(
    in object: Any,
    into sources: inout [FamoResponsesSource],
    seen: inout Set<String>
  ) {
    if let dictionary = object as? [String: Any] {
      let url = (dictionary["url"] ?? dictionary["link"] ?? dictionary["source_url"]
        ?? dictionary["uri"]) as? String
      if let url, url.hasPrefix("http"), seen.insert(url).inserted {
        let title = (dictionary["title"] ?? dictionary["name"] ?? dictionary["site_name"])
          as? String ?? ""
        sources.append(FamoResponsesSource(title: title, url: url))
      }
      for value in dictionary.values {
        collectSources(in: value, into: &sources, seen: &seen)
      }
    } else if let array = object as? [Any] {
      for value in array { collectSources(in: value, into: &sources, seen: &seen) }
    }
  }
}
