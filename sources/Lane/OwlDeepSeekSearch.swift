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
  static let path: String = OwlProviderCore.call("searchPath")

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
    OwlProviderCore.call("searchQuery", ["text": text])
  }

  static func body(query: String, limit: Int) -> [String: Any] {
    OwlProviderCore.object("searchBody", ["query": query, "limit": limit, "doubao": false])
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
    let reply: OwlSearchWireReply = OwlProviderCore.call("searchParse", ["bytes": Array(data), "doubao": false])
    guard let values = reply.values else { throw OwlDeepSeekSearchError.malformedResponse }
    return values.map { value in
      OwlWebSearchResult(title: value.title, url: value.url, snippet: value.snippet,
        publishedAt: value.publishedAt, hostname: value.hostname ?? URL(string: value.url)?.host)
    }
  }

  static func withoutFragment(_ url: String) -> String {
    OwlProviderCore.call("withoutFragment", ["url": url])
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
    self.fetch = fetch ?? { try await URLSession.shared.data(for: $0, delegate: OwlURLSessionTransport.noRedirectDelegate) }
  }

  func search(
    query: String, endpoint: URL, apiKey: String, limit: Int
  ) async throws -> [OwlWebSearchResult] {
    var request = try OwlDeepSeekSearchWire.request(
      query: query, endpoint: endpoint, apiKey: apiKey, limit: limit)
    request.timeoutInterval = timeout
    let (data, response) = try await fetch(request)
    if let http = response as? HTTPURLResponse, !OwlProviderCore.httpAccepted(http.statusCode) {
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
    OwlProviderCore.call("numbered", ["results": OwlAppCore.payload(results)])
  }

  static func askSystemPrompt(_ results: [OwlWebSearchResult], today: Date = Date()) -> String {
    OwlProviderCore.call("groundingPrompt", ["results": OwlAppCore.payload(results),
      "day": today.formatted(.iso8601.year().month().day())])
  }

  /// 检索结果放在最前面的 system 消息里，会话原样跟在后面。
  static func askMessages(
    _ messages: [OwlDeepSeekMessage], results: [OwlWebSearchResult], today: Date = Date()
  ) -> [OwlDeepSeekMessage] {
    [OwlDeepSeekMessage(role: "system", content: askSystemPrompt(results, today: today))] + messages
  }

  /// 答案里 `[n]` 引到的结果，按引用顺序、去重。
  static func cited(_ results: [OwlWebSearchResult], in content: String) -> [OwlWebSearchResult] {
    OwlProviderCore.call("cited", ["results": OwlAppCore.payload(results), "answer": content])
  }

  /// 答案末尾的来源列表，由检索结果生成，不让模型自己写网址。保留原编号，与正文 `[n]` 对得上；
  /// 一条都没引用时列出前三条检索结果。
  static func sourcesFooter(_ results: [OwlWebSearchResult], answer: String) -> String {
    OwlProviderCore.call("footer", ["results": OwlAppCore.payload(results), "answer": answer])
  }
}
