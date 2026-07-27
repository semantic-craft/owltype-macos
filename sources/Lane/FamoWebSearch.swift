//
//  FamoWebSearch.swift
//  法墨输入法 (Famo) — 任意提问的「先检索、再作答」搜索层
//
//  与 `FamoSearchControl` 的分工（两者并存，不是重复）：
//    - `FamoSearchControl` 走的是**模型内置**的联网工具（方舟 `web_search`、百炼 `enable_search`
//      …）：由模型自己检索、自己作答。代价是每家一套 wire format，而且要求账号在各自控制台
//      单独开通插件——实测方舟会直接 `404 ToolNotOpen`（2026-07-27）。
//    - 这里是**独立搜索服务**：我们自己拿到网页结果，再把结果作为上下文交给**任意**一家模型作答。
//      搜索与作答解耦，于是「哪家模型能联网」这个概念消失了：配了 DeepSeek 也能联网问答。
//
//  搜索后端是可插拔的（`FamoWebSearching`）。首个实现是火山引擎「豆包搜索 Global 版」，选它是因为
//  它覆盖国内站点、`open.feedcoopapi.com` 国内直连、且每个火山账号每月有 500 次免费额度。
//  Perplexity Search（`api.perplexity.ai/search`）是同类接口，将来按同一 protocol 补一个实现即可。
//
//  Pure value logic + 一个薄客户端：没有 UserDefaults，Key 由调用方传入。
//

import Foundation

// MARK: - 结果模型

/// 一条搜索结果，已归一化到各家后端的公共子集。
///
/// `snippet` 是拼接后的正文片段（豆包按 text/image 分段返回，这里只保留 text）。
/// `publishedAt` / `hostname` 可能为空——它们只用于给模型和用户标注来源，缺了不影响作答。
struct FamoWebSearchResult: Equatable, Sendable {
  let title: String
  let url: String
  let snippet: String
  let publishedAt: String?
  let hostname: String?
}

enum FamoWebSearchError: Error, Equatable {
  case missingAPIKey
  case invalidEndpoint
  case badHTTPStatus(Int)
  /// 后端在 HTTP 200 里回的业务错误（豆包就是这么干的），`code` 是它的错误码。
  case serviceError(code: String, message: String)
  case malformedResponse
  /// 检索通了但一条结果都没有。按失败处理 —— 注入空资料等于凭训练记忆作答却署着「已联网」。
  case noResults
}

extension FamoWebSearchError {
  /// 「这个后端在当前配置下不会为你服务」→ 换下一家才有意义；反之是暂时性/本地故障，如实上报。
  ///
  /// 判据与 `FamoAskSearchFailover.isConfigurationRefusal` 同源，只是这里还要认几个**带着 HTTP 200
  /// 回来**的业务码：豆包的 `700429` 是限流、`10500/10501` 是它自己内部错，这三个换一家没用；
  /// 而 `invalid_api_key` / `ToolNotOpen` / 无可用套餐 是实打实的配置问题。
  var isRouteUnusable: Bool {
    switch self {
    case .missingAPIKey, .invalidEndpoint, .noResults:
      return true
    case let .badHTTPStatus(status):
      return FamoAskSearchFailover.isConfigurationRefusal(status: status)
    case let .serviceError(code, _):
      return !Self.transientServiceCodes.contains(code)
    case .malformedResponse:
      // 回了看不懂的东西：可能是网关/代理插进来的页面。换一家不一定更好，如实上报。
      return false
    }
  }

  /// 稍后重试同一家仍可能成功的业务码（豆包限流 / 内部错，Perplexity 的限流类型）。
  private static let transientServiceCodes: Set<String> = [
    "700429", "10500", "10501", "rate_limit_error",
  ]
}

/// 搜索后端。一个后端 = 一个「给 query 返回网页列表」的服务。
protocol FamoWebSearching: Sendable {
  func search(query: String, apiKey: String, limit: Int) async throws -> [FamoWebSearchResult]
}

// MARK: - 豆包搜索 Global 版 · wire format

/// 火山引擎「豆包搜索 Global 版」的请求/响应 wire format。
///
/// 文档：docs.volcengine.com/docs/87772/2548026。注意三件与直觉相反的事：
///   1. 端点不在方舟域名下，是 `open.feedcoopapi.com`；
///   2. **Key 也不是方舟模型 Key**——要在「联网搜索控制台 → API Key 管理 → 按量后付费」单独建一把。
///      拿方舟 Key 打过去会得到 `700901 invalid_api_key`（2026-07-27 实测）；
///   3. **出错时 HTTP 仍是 200**，错误藏在 `ResponseMetadata.Error` 里。只看状态码会把报错当成空结果。
enum FamoDoubaoGlobalSearchWire {
  static let endpoint = URL(string: "https://open.feedcoopapi.com/search_api/global_search")!

  /// 文档给的上限：DocCount 最多 20 条。
  static let maxDocCount = 20

  /// 文档：Query 1~100 个字符，超长会被截断，且**不支持多词搜索**。
  static let maxQueryLength = 100

  /// 请求体。`limit` 会被夹到 1...20；Query 按文档上限截到 100 字符（按 Character 截，别把
  /// 中文截成半个码点）；`maxSnippetLength` 用文档推荐的 1000 以内。
  static func body(query: String, limit: Int) -> [String: Any] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let query = trimmed.count > maxQueryLength
      ? String(trimmed.prefix(maxQueryLength))
      : trimmed
    return [
      "Query": query,
      "DocCount": min(max(limit, 1), maxDocCount),
      "MaxSnippetLength": 800,
      // 法墨的回答窗是纯文本，取图只会白烧 token / 时延。
      "MaxImageCountPerDoc": 0,
    ]
  }

  static func request(query: String, apiKey: String, limit: Int) throws -> URLRequest {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FamoWebSearchError.missingAPIKey
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: body(query: query, limit: limit))
    return request
  }

  /// 解析响应。业务错误（HTTP 200 + body 里的 Error）会 throw，绝不静默变成空列表——
  /// 「搜到 0 条」和「Key 无效」对用户是两件事，混在一起会让人以为搜索能用只是没结果。
  static func parse(_ data: Data) throws -> [FamoWebSearchResult] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw FamoWebSearchError.malformedResponse
    }
    if let meta = root["ResponseMetadata"] as? [String: Any],
       let error = meta["Error"] as? [String: Any] {
      throw FamoWebSearchError.serviceError(
        code: (error["Code"] as? String) ?? String(describing: error["CodeN"] ?? "unknown"),
        message: (error["Message"] as? String) ?? "")
    }
    guard let result = root["Result"] as? [String: Any] else {
      throw FamoWebSearchError.malformedResponse
    }
    // Result 层还有第二个错误通道（ErrorCode != 0），同样不能当成空结果吞掉。
    if let code = result["ErrorCode"] as? Int, code != 0 {
      throw FamoWebSearchError.serviceError(
        code: String(code), message: (result["ErrorMsg"] as? String) ?? "")
    }
    let documents = (result["Documents"] as? [[String: Any]]) ?? []
    return documents.compactMap(document)
  }

  /// 一条 `GlobalSearchDocument` → 归一化结果。缺 Url/Title 的条目直接丢弃：不能引用的来源没有价值。
  private static func document(_ raw: [String: Any]) -> FamoWebSearchResult? {
    guard let url = raw["Url"] as? String, !url.isEmpty,
          let title = raw["Title"] as? String, !title.isEmpty else { return nil }
    // Snippet 是 text/image 混排的数组，只取 text 段拼起来。
    let snippet = ((raw["Snippet"] as? [[String: Any]]) ?? [])
      .filter { ($0["Type"] as? String) == "text" }
      .compactMap { $0["Text"] as? String }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let info = raw["DocumentInfo"] as? [String: Any]
    let published = (info?["PublishTime"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let host = raw["HostInfo"] as? [String: Any]
    let hostname = (host?["Hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return FamoWebSearchResult(
      title: title, url: url, snippet: snippet, publishedAt: published, hostname: hostname)
  }
}

/// 豆包搜索 Global 版的实时客户端。`session` 可注入，测试不碰网络。
struct FamoDoubaoGlobalSearchClient: FamoWebSearching {
  /// 搜索是「先检索再作答」的第一跳，超时必须比整轮问答短——文档标称平均 1053ms，给 8s 已经很宽。
  let timeout: TimeInterval
  private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(
    timeout: TimeInterval = 8,
    fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) {
    self.timeout = timeout
    self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
  }

  func search(query: String, apiKey: String, limit: Int) async throws -> [FamoWebSearchResult] {
    var request = try FamoDoubaoGlobalSearchWire.request(
      query: query, apiKey: apiKey, limit: limit)
    request.timeoutInterval = timeout
    let (data, response) = try await fetch(request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw FamoWebSearchError.badHTTPStatus(http.statusCode)
    }
    return try FamoDoubaoGlobalSearchWire.parse(data)
  }
}

// MARK: - 后端

/// 可选的搜索后端。一档 = 一个服务 + 它自己的 Key + 它自己的署名。
///
/// 两家的取舍（2026-07-27 查证）：豆包搜索基于豆包 APP 做，国内站点覆盖好、`open.feedcoopapi.com`
/// 国内直连、每账号每月 500 次免费；Perplexity 英文内容强、支持域名/时效过滤，但 `api.perplexity.ai`
/// 在国内多半要代理、且没有免费额度。法墨是中文输入法，所以默认豆包，Perplexity 作为可选项。
enum FamoWebSearchBackend: String, CaseIterable, Sendable {
  case doubaoGlobal = "doubao"
  case perplexity

  /// 设置页下拉里的名字。
  var displayName: String {
    switch self {
    case .doubaoGlobal: return "豆包搜索"
    case .perplexity:   return "Perplexity"
    }
  }

  /// 回答窗署名 chip 的 id。刻意带 `-search` 后缀，与同名的**模型**供应商区分开 ——
  /// 检索的是它，作答的可能是 DeepSeek。
  var attributionID: String {
    switch self {
    case .doubaoGlobal: return "doubao-search"
    case .perplexity:   return "perplexity-search"
    }
  }

  /// Keychain account。每家一把，换后端不会互相覆盖，切回去也不用重填。
  var secretName: String { "famo.websearch.\(rawValue).apiKey" }

  /// 设置页里告诉用户去哪儿拿 Key。两家都不是模型 Key，这句是最容易踩空的地方。
  var keyHint: String {
    switch self {
    case .doubaoGlobal:
      return "在火山引擎「联网搜索控制台 → API Key 管理 → 按量后付费」单独创建（方舟的模型 Key 在这里无效）。每个火山账号每月有 500 次免费额度。"
    case .perplexity:
      return "在 perplexity.ai 的 API 设置里创建（pplx- 开头）。国内网络访问 api.perplexity.ai 可能需要代理；英文内容检索效果更好，中文站点覆盖弱于豆包搜索。"
    }
  }

  func makeClient() -> FamoWebSearching {
    switch self {
    case .doubaoGlobal: return FamoDoubaoGlobalSearchClient()
    case .perplexity:   return FamoPerplexitySearchClient()
    }
  }

  /// 署名 id → 后端。给 `FamoSearchControl.displayName` 反查用。
  static func backend(forAttributionID id: String) -> FamoWebSearchBackend? {
    allCases.first { $0.attributionID == id }
  }
}

/// 用哪个搜索后端。默认豆包搜索（见 `FamoWebSearchBackend` 的取舍说明）。
enum FamoWebSearchBackendSettings {
  static let key = "FamoWebSearchBackend"

  static var rawValue: String {
    get { FamoDefaults.standard.string(forKey: key) ?? FamoWebSearchBackend.doubaoGlobal.rawValue }
    set { FamoDefaults.standard.set(newValue, forKey: key) }
  }

  /// 存了个不认识的值（降级安装 / 手改 plist）→ 回到默认，而不是让联网整个失灵。
  static var backend: FamoWebSearchBackend {
    FamoWebSearchBackend(rawValue: rawValue) ?? .doubaoGlobal
  }

  static func resetForTesting() {
    FamoDefaults.standard.removeObject(forKey: key)
  }
}

// MARK: - Key 存放

/// 独立搜索服务的 API Key 存放位置。
///
/// 刻意**不挂在任何一条 provider profile 下**：这把 Key 属于「搜索能力」本身，与用哪家模型作答无关
/// （配了 DeepSeek 也能用它联网）。挂在豆包/Perplexity 供应商下会造成一个假依赖——没配那家模型
/// 就不能联网。复用 `FamoProviderKeychain` 的 service，只是换一组固定 account，省一套钥匙串管道。
enum FamoWebSearchKeyStore {
  /// 该后端已配好的搜索 Key；未配 / 读取失败 → nil（调用方据此退回不联网，而不是崩）。
  static func apiKey(
    for backend: FamoWebSearchBackend,
    secrets: FamoSecretStoring = FamoProviderKeychain()
  ) -> String? {
    guard let key = try? secrets.secret(named: backend.secretName) else { return nil }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func isConfigured(
    for backend: FamoWebSearchBackend,
    secrets: FamoSecretStoring = FamoProviderKeychain()
  ) -> Bool {
    apiKey(for: backend, secrets: secrets) != nil
  }
}

// MARK: - Perplexity Search · wire format

/// Perplexity Search API 的请求/响应 wire format。
///
/// 文档：docs.perplexity.ai/api-reference/search-post。与豆包搜索的三个关键差别：
///   1. **错误走标准 HTTP 状态码**（401 认证 / 429 限流 / 4xx-5xx），不像豆包那样 200 里藏错误；
///   2. Query 没有 100 字符上限，也不禁多词；
///   3. 结果里没有站点名，只有 url —— `hostname` 从 url 里取，不然署名那栏会整片空着。
///
/// 注意这是 Search API（返回结构化结果），不是 Sonar（`/chat/completions` 带 citations 的问答）。
/// Sonar 不需要这一层：它本身就是 OpenAI 兼容端点，当普通供应商加进 `FamoProviderProfile` 即可。
enum FamoPerplexitySearchWire {
  static let endpoint = URL(string: "https://api.perplexity.ai/search")!

  static func body(query: String, limit: Int) -> [String: Any] {
    [
      "query": query.trimmingCharacters(in: .whitespacesAndNewlines),
      "max_results": max(limit, 1),
      // 短答场景不需要整页正文，high 会显著拖时延与 token。
      "search_context_size": "low",
    ]
  }

  static func request(query: String, apiKey: String, limit: Int) throws -> URLRequest {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FamoWebSearchError.missingAPIKey
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: body(query: query, limit: limit))
    return request
  }

  static func parse(_ data: Data) throws -> [FamoWebSearchResult] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw FamoWebSearchError.malformedResponse
    }
    // 非 2xx 时 body 通常是 `{"error":{"message":…,"type":…}}`。客户端已按状态码抛错，这里再兜一道，
    // 免得将来某个 200 + error 的边角情况被当成空结果。
    if let error = root["error"] as? [String: Any] {
      throw FamoWebSearchError.serviceError(
        code: (error["type"] as? String) ?? "error",
        message: (error["message"] as? String) ?? "")
    }
    guard let results = root["results"] as? [[String: Any]] else {
      throw FamoWebSearchError.malformedResponse
    }
    return results.compactMap(result)
  }

  private static func result(_ raw: [String: Any]) -> FamoWebSearchResult? {
    guard let url = raw["url"] as? String, !url.isEmpty,
          let title = raw["title"] as? String, !title.isEmpty else { return nil }
    let snippet = (raw["snippet"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // `date` 是发布日；缺了退到 `last_updated`，两个都没有就不标时间（而不是标个空的）。
    let published = [raw["date"] as? String, raw["last_updated"] as? String]
      .compactMap { $0 }
      .first { !$0.isEmpty }
    return FamoWebSearchResult(
      title: title,
      url: url,
      snippet: snippet,
      publishedAt: published,
      // Perplexity 不回站点名，从 url 里取主机名（去掉 www.）当来源标注。
      hostname: URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 })
  }
}

/// Perplexity Search 的实时客户端。`fetch` 可注入，测试不碰网络。
struct FamoPerplexitySearchClient: FamoWebSearching {
  let timeout: TimeInterval
  private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(
    timeout: TimeInterval = 8,
    fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) {
    self.timeout = timeout
    self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
  }

  func search(query: String, apiKey: String, limit: Int) async throws -> [FamoWebSearchResult] {
    var request = try FamoPerplexitySearchWire.request(
      query: query, apiKey: apiKey, limit: limit)
    request.timeoutInterval = timeout
    let (data, response) = try await fetch(request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      // 错误正文里通常有可读的 message（如 401 的认证说明），带出来比只报一个状态码好排查。
      throw Self.serviceError(from: data, status: http.statusCode)
    }
    return try FamoPerplexitySearchWire.parse(data)
  }

  /// 从错误正文里挖 message；挖不到就退回纯状态码。
  private static func serviceError(from data: Data, status: Int) -> FamoWebSearchError {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let error = root["error"] as? [String: Any] else {
      return .badHTTPStatus(status)
    }
    return .serviceError(
      code: (error["type"] as? String) ?? String(status),
      message: (error["message"] as? String) ?? "")
  }
}

// MARK: - 把搜索结果交给模型

/// 检索结果 → 注入模型的上下文。
///
/// 独立成型是因为这段文字直接决定回答质量：它既要让模型**优先采信**检索结果（否则模型会用过期的
/// 训练记忆覆盖新事实），又要让它在检索结果不相关时**照实说不知道**，而不是硬凑。
enum FamoWebSearchContext {
  /// 单条来源的编号文本。序号从 1 开始，和提示词里要求的 [1] 引用格式对齐。
  static func entry(index: Int, result: FamoWebSearchResult) -> String {
    var lines = ["[\(index)] \(result.title)"]
    if let host = result.hostname { lines.append("来源：\(host)") }
    if let published = result.publishedAt { lines.append("发布时间：\(published)") }
    lines.append("网址：\(result.url)")
    if !result.snippet.isEmpty { lines.append("摘要：\(result.snippet)") }
    return lines.joined(separator: "\n")
  }

  /// 从待发送的对话里取出「要拿去搜什么」——最后一条 user 消息。
  ///
  /// 不是拼接整段历史：豆包搜索的 Query 上限 100 字符且不支持多词，喂长文本只会让检索跑偏。
  /// 没有 user 消息（理论上不该发生）→ nil，调用方据此跳过检索直接作答。
  static func query(from messages: [FamoDeepSeekMessage]) -> String? {
    guard let last = messages.last(where: { $0.role == "user" }) else { return nil }
    let trimmed = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// 注入用的 system 消息。`results` 为空时返回 nil —— 没搜到就别骗模型说「以下是检索结果」。
  static func systemMessage(results: [FamoWebSearchResult]) -> FamoDeepSeekMessage? {
    guard !results.isEmpty else { return nil }
    let body = results.enumerated()
      .map { entry(index: $0.offset + 1, result: $0.element) }
      .joined(separator: "\n\n")
    return FamoDeepSeekMessage(
      role: "system",
      content: """
        以下是刚刚检索到的网页结果，时效性高于你的训练知识。回答时以它们为准；\
        与你的记忆冲突时，采信检索结果。引用具体事实时用 [序号] 标注来源。\
        如果这些结果都答不上用户的问题，就直说没有查到，不要编造。

        \(body)
        """)
  }

  /// 把检索结果插到对话最前面。空结果原样返回，调用方因此不必分支。
  static func injecting(
    results: [FamoWebSearchResult],
    into messages: [FamoDeepSeekMessage]
  ) -> [FamoDeepSeekMessage] {
    guard let system = systemMessage(results: results) else { return messages }
    return [system] + messages
  }
}
