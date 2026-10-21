//
//  OwlDeepSeekSearch.swift
//  猫头鹰输入法 (Owltype) — DeepSeek 联网的检索层：DeepSeek Search 接口
//
//  任意提问联网与来源核验都先用 `POST /v1/tools/search` 取回网页，再把编号结果交给
//  `deepseek-flash` 依据作答。检索与作答分开：模型收下内置 `web_search` 工具却不搜（V4.1 Flash
//  实测如此）时，用户会以为搜过了；这里搜没搜由一次 HTTP 请求决定，来源也只来自返回的结果。
//
//  文档：api-docs.deepseek.com/zh-cn/guides/search。Pure value logic + 一个薄客户端。
//

import Foundation

enum OwlDeepSeekSearchError: Error, Equatable {
  case badHTTPStatus(Int)
  case malformedResponse
}

protocol OwlDeepSeekSearching: Sendable {
  func search(
    query: String, endpoint: URL, apiKey: String, limit: Int
  ) async throws -> [OwlWebSearchResult]
}

// MARK: - Wire format

enum OwlDeepSeekSearchWire {
  static let path = "/v1/tools/search"

  /// 文档：query 与 ori_question 都是 1~128 个 Unicode 字符。按 Character 截，别截出半个码点。
  static let maxQueryLength = 128
  /// 文档：count 1~50。
  static let maxCount = 50

  /// 搜索接口挂在作答端点的同一主机下：`https://api.deepseek.com/chat/completions` →
  /// `https://api.deepseek.com/v1/tools/search`。代理没有这个接口时会回 404，交给顺位规则换下一家。
  static func endpoint(for chatEndpoint: URL) -> URL? {
    guard var components = URLComponents(url: chatEndpoint, resolvingAgainstBaseURL: false),
          components.host != nil else { return nil }
    components.path = path
    components.query = nil
    components.fragment = nil
    return components.url
  }

  /// 空白折成单个空格后截断。整句提问直接当检索词：接口按 `ori_question` 理解意图，不必另造关键词。
  static func query(from text: String) -> String {
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return String(collapsed.prefix(maxQueryLength))
  }

  static func body(query: String, limit: Int) -> [String: Any] {
    let trimmed = Self.query(from: query)
    return [
      "query": trimmed,
      "ori_question": trimmed,
      "count": min(max(limit, 1), maxCount),
    ]
  }

  static func request(query: String, endpoint: URL, apiKey: String, limit: Int) throws -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body(query: query, limit: limit))
    return request
  }

  /// `summary`（600~800 字的长摘要，文档说「适用于给模型阅读」）优先，缺了用 `snippet`。
  /// 网址去掉片段：接口会在网址后挂 `#1` 之类的序号，留着会让同一网页与豆包结果去不了重。
  static func parse(_ data: Data) throws -> [OwlWebSearchResult] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let results = root["results"] as? [[String: Any]] else {
      throw OwlDeepSeekSearchError.malformedResponse
    }
    return results.compactMap { raw in
      guard let url = (raw["url"] as? String).map(withoutFragment), url.hasPrefix("http"),
            let title = raw["title"] as? String, !title.isEmpty else { return nil }
      let summary = (raw["summary"] as? String) ?? ""
      let snippet = summary.isEmpty ? ((raw["snippet"] as? String) ?? "") : summary
      return OwlWebSearchResult(
        title: title,
        url: url,
        snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines),
        publishedAt: (raw["date"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(10)) },
        hostname: (raw["site_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
          ?? URL(string: url)?.host)
    }
  }

  static func withoutFragment(_ url: String) -> String {
    guard let hash = url.firstIndex(of: "#") else { return url }
    return String(url[..<hash])
  }
}

/// DeepSeek Search 的实时客户端。`fetch` 可注入，测试不碰网络。
struct OwlDeepSeekSearchClient: OwlDeepSeekSearching {
  /// 实测 0.5 秒左右返回；10 秒已经很宽。
  let timeout: TimeInterval
  private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(
    timeout: TimeInterval = 10,
    fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) {
    self.timeout = timeout
    self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
  }

  func search(
    query: String, endpoint: URL, apiKey: String, limit: Int
  ) async throws -> [OwlWebSearchResult] {
    var request = try OwlDeepSeekSearchWire.request(
      query: query, endpoint: endpoint, apiKey: apiKey, limit: limit)
    request.timeoutInterval = timeout
    let (data, response) = try await fetch(request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw OwlDeepSeekSearchError.badHTTPStatus(http.statusCode)
    }
    return try OwlDeepSeekSearchWire.parse(data)
  }
}

// MARK: - Grounding

/// 把检索结果交给作答模型的共用写法：编号正文、任意提问的提示词、来源脚注。来源核验与任意提问
/// 用同一套编号，`[序号]` 在两边都指向同一份结果。
enum OwlWebSearchGrounding {
  /// 任意提问每次取回的网页数。
  static let askResultCount = 8

  /// `[1] 标题 / 来源 / 发布时间 / 网址 / 摘要`，结果之间空一行。
  static func numbered(_ results: [OwlWebSearchResult]) -> String {
    results.enumerated().map { index, result in
      var lines = ["[\(index + 1)] \(result.title)"]
      if let host = result.hostname { lines.append("来源：\(host)") }
      if let published = result.publishedAt { lines.append("发布时间：\(published)") }
      lines.append("网址：\(result.url)")
      if !result.snippet.isEmpty { lines.append("摘要：\(result.snippet)") }
      return lines.joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  static func askSystemPrompt(_ results: [OwlWebSearchResult], today: Date = Date()) -> String {
    let day = today.formatted(.iso8601.year().month().day())
    let header =
      "已为用户的最后一个问题联网检索（\(day)）。依据检索结果作答，涉及事实处用 [序号] 标注出处；"
      + "优先采信一手官方来源；结果不足以回答时如实说明，不要凭记忆补来源或编造网址。"
    guard !results.isEmpty else { return header + "\n\n检索结果：无（未检索到相关网页）。" }
    return header + "\n\n检索结果：\n" + numbered(results)
  }

  /// 检索结果放在最前面的 system 消息里，会话原样跟在后面。
  static func askMessages(
    _ messages: [OwlDeepSeekMessage], results: [OwlWebSearchResult]
  ) -> [OwlDeepSeekMessage] {
    [OwlDeepSeekMessage(role: "system", content: askSystemPrompt(results))] + messages
  }

  /// 答案里 `[n]` 引到的结果，按引用顺序、去重。
  static func cited(_ results: [OwlWebSearchResult], in content: String) -> [OwlWebSearchResult] {
    var seen: [Int] = []
    for match in content.matches(of: /\[(\d{1,2})\]/) {
      if let number = Int(match.1), results.indices.contains(number - 1), !seen.contains(number) {
        seen.append(number)
      }
    }
    return seen.map { results[$0 - 1] }
  }

  /// 答案末尾的来源列表，由检索结果生成，不让模型自己写网址。保留原编号，与正文 `[n]` 对得上；
  /// 一条都没引用时列出前三条检索结果。
  static func sourcesFooter(_ results: [OwlWebSearchResult], answer: String) -> String {
    guard !results.isEmpty else { return "" }
    let cited = cited(results, in: answer)
    let listed = cited.isEmpty ? Array(results.prefix(3)) : cited
    let lines = listed.map { result -> String in
      let number = (results.firstIndex(of: result) ?? 0) + 1
      return "[\(number)] [\(result.title)](\(result.url))"
    }
    return "\n\n" + (cited.isEmpty ? "检索到的网页：" : "来源：") + "\n" + lines.joined(separator: "\n")
  }
}
