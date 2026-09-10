//
//  OwlResponsesWire.swift
//  猫头鹰输入法 (Owltype) — Qwen / OpenAI / 火山方舟 / DeepSeek `/responses` wire format
//
//  `/responses` is not just a renamed `/chat/completions`: it uses `input`, emits `output`
//  items, and streams `response.output_text.delta` events. The four providers also have small
//  dialect differences, so every Responses caller shares this file instead of hand-building JSON.
//

import Foundation

enum OwlResponsesDialect: CaseIterable, Equatable, Sendable {
  case qwen
  case ark
  case openAI
  case deepseek
}

struct OwlResponsesSource: Equatable, Sendable {
  let title: String
  let url: String
}

struct OwlResponsesUsage: Equatable, Sendable {
  let inputTokens: Int
  let outputTokens: Int
  let totalTokens: Int
  let cachedTokens: Int
}

struct OwlResponsesResult: Equatable, Sendable {
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
  /// The host fallback preserves custom profiles created before provider ids were persisted.
  static func isQwen(providerID: String, endpoint: URL) -> Bool {
    if providerID.lowercased() == "qwen" { return true }
    let host = endpoint.host?.lowercased() ?? ""
    return host.contains("dashscope") || host.contains("aliyuncs")
  }

  /// Whether this routing belongs to 火山方舟's Doubao service. Deliberately NOT symmetric with
  /// `isQwen`: the model prefix stays a hard requirement here, because 方舟 hosts third-party
  /// models that genuinely keep their own wire — only 百炼 was declared Responses-only. The host
  /// fallback preserves custom profiles created before provider ids were persisted.
  static func isArk(providerID: String, model: String, endpoint: URL) -> Bool {
    guard model.lowercased().hasPrefix("doubao") else { return false }
    if providerID.lowercased() == "doubao" { return true }
    let host = endpoint.host?.lowercased() ?? ""
    return host.contains("volces") || host.contains("volcengine")
  }

  /// DeepSeek V4.1 Flash uses `deepseek-flash` on Responses as well as Chat.
  /// Existing explicitly configured V4 Flash model names still reach the same wire.
  static func supportsDeepSeekModel(_ model: String) -> Bool {
    let name = model.lowercased()
    return name == "deepseek-flash" || name.hasPrefix("deepseek-v4-flash")
  }

  static func isDeepSeek(providerID: String, model: String, endpoint: URL) -> Bool {
    guard supportsDeepSeekModel(model) else { return false }
    if providerID.lowercased() == "deepseek" { return true }
    let host = endpoint.host?.lowercased() ?? ""
    return host.contains("deepseek")
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
  static func dialect(providerID: String, model: String, endpoint: URL) -> OwlResponsesDialect? {
    if isQwen(providerID: providerID, endpoint: endpoint) { return .qwen }
    if isArk(providerID: providerID, model: model, endpoint: endpoint) { return .ark }
    if isDeepSeek(providerID: providerID, model: model, endpoint: endpoint) { return .deepseek }
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
  /// shape as well. DeepSeek 两种都收（官方兼容表：content 支持字符串和 `input_text` 内容块），
  /// 所以它跟着走这条 `input_text` 分支，方言之间少一种形状要维护。
  static func inputMessage(
    role: String,
    text: String,
    dialect: OwlResponsesDialect
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
    case .deepseek:
      if webSearch {
        // **这一支故意不发 `reasoning`**，也就是让 DeepSeek 保持它自己的默认「思考开、effort
        // high」——与本文件其余每一条「全链路强制关思考」的策略相反，理由是实测出来的硬约束，
        // 不是偏好（2026-07-31，同五题）：
        //
        //   关思考 + required → 0/5 出正文。搜 11~17 轮、`output` 里一个 message 都没有、
        //     输入烧 78k~105k token。DeepSeek 忽略 `max_tool_calls`，这个循环封不了顶。
        //   开思考 + required → 5/5 出正文，搜索次数中位 3 次、时长中位 16.6s、输入 15.8k。
        //
        // 机制：agentic 循环在两次检索之间的盘算总得有个去处。关思考时它只能挤进可见的
        // `output_text`（于是 5/5 带过程旁白「我来帮你搜索…让我整理一下」），而且循环收敛不了；
        // 开思考后它走 `response.reasoning_text.*` 事件，`OwlResponsesStreamParser` 本来就忽略
        // 那类事件，用户看到的正文因此是干净的（旁白降到 1/5）。
        //
        // 别顺手「对齐」成 Qwen 那样加 `reasoning.effort:none`——那等于把这条链路改回 0/5 出正文。
        // 反过来也别把 Qwen 改成开思考：百炼在思考模式下**拒绝** `tool_choice: required`，
        // 实测 5/5 报 400「The tool_choice parameter does not support being set to required or
        // object in thinking mode」。两家的可用配置不重叠，所以逐家硬编码，没有统一开关。
        body["tools"] = [["type": "web_search"]]
        body["tool_choice"] = "required"
      } else {
        // 非搜索链路（划词润色 / 提示词优化 / 任务书 / 普通问答）照旧强制关思考。思考默认开着、
        // effort 默认 high（官方《思考模式》），而 Chat 那套 `thinking:{type:disabled}` 在
        // Responses 上属「静默忽略」参数——唯一管用的开关是 `reasoning.effort: none`。
        // 2026-07-31 实测 deepseek-v4-flash：不传时 reasoning_tokens 9~37，传 none 后恒为 0。
        body["reasoning"] = ["effort": "none"]
      }
      // `store` 官方标注不支持（响应恒 store:false），所以干脆不发。
      // `text.format` 官方标注「完整支持」，2026-07-31 实测返回干净 JSON。于是 DeepSeek 这条链路
      // 把 Chat 时代的 `response_format: json_object` 护栏原样带过来了——Qwen/豆包 当初迁 Responses
      // 时是把它丢掉的，只靠提示词 + 宽松 parser 兜。
      if jsonObject { body["text"] = ["format": ["type": "json_object"]] }
    }
    return body
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
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OwlResponsesWireError.malformedResponse
    }
    let text = outputText(in: root).trimmingCharacters(in: .whitespacesAndNewlines)
    let usage = parseUsage(root["usage"] as? [String: Any])
    return OwlResponsesResult(
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

  private static func parseUsage(_ raw: [String: Any]?) -> OwlResponsesUsage? {
    guard let raw else { return nil }
    let input = raw["input_tokens"] as? Int ?? 0
    let output = raw["output_tokens"] as? Int ?? 0
    let total = raw["total_tokens"] as? Int ?? input + output
    let details = raw["input_tokens_details"] as? [String: Any]
    return OwlResponsesUsage(
      inputTokens: input,
      outputTokens: output,
      totalTokens: total,
      cachedTokens: details?["cached_tokens"] as? Int ?? 0
    )
  }

  private static func collectSources(in object: Any) -> [OwlResponsesSource] {
    var sources: [OwlResponsesSource] = []
    var seen = Set<String>()
    collectSources(in: object, into: &sources, seen: &seen)
    return sources
  }

  private static func collectSources(
    in object: Any,
    into sources: inout [OwlResponsesSource],
    seen: inout Set<String>
  ) {
    if let dictionary = object as? [String: Any] {
      let url = (dictionary["url"] ?? dictionary["link"] ?? dictionary["source_url"]
        ?? dictionary["uri"]) as? String
      if let url, url.hasPrefix("http"), seen.insert(url).inserted {
        let title = (dictionary["title"] ?? dictionary["name"] ?? dictionary["site_name"])
          as? String ?? ""
        sources.append(OwlResponsesSource(title: title, url: url))
      }
      for value in dictionary.values {
        collectSources(in: value, into: &sources, seen: &seen)
      }
    } else if let array = object as? [Any] {
      for value in array { collectSources(in: value, into: &sources, seen: &seen) }
    }
  }
}
