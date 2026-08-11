//
//  FamoWebSearch.swift
//  法墨输入法 (Famo) — 任意提问的「先检索、再作答」搜索层
//
//  与 `FamoSearchControl` 的分工（两者并存，不是重复）：
//    - `FamoSearchControl` 走的是**模型内置**的联网工具（方舟/百炼 Responses `web_search`
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
  /// 回来**的业务码。除明确的 `noResults`（必须换后端才能避免空材料却署名联网）外，只有已知
  /// 鉴权/套餐/固定参数错误可以顺位；未知码原样上报，避免把同一问题在不能确认必要性时继续
  /// 发给另一家供应商。
  var isRouteUnusable: Bool {
    switch self {
    case .missingAPIKey, .invalidEndpoint, .noResults:
      return true
    case let .badHTTPStatus(status):
      return FamoAskSearchFailover.isConfigurationRefusal(status: status)
    case let .serviceError(code, _):
      return Self.configurationServiceCodes.contains(code)
    case .malformedResponse:
      // 回了看不懂的东西：可能是网关/代理插进来的页面。换一家不一定更好，如实上报。
      return false
    }
  }

  /// 三个后端已经观测或文档化的固定配置拒绝；新增错误码默认不顺位，须确认语义后再列入。
  private static let configurationServiceCodes: Set<String> = [
    "invalid_api_key", "700901", "10410",
    "authentication_error", "InvalidApiKey", "InvalidParameter",
    "ToolNotOpen", "insufficient_quota",
  ]
}

/// 搜索后端。一个后端 = 一个「给 query 返回网页列表」的服务。
protocol FamoWebSearching: Sendable {
  func search(query: String, apiKey: String, limit: Int) async throws -> [FamoWebSearchResult]
}

// MARK: - 响应清洗

enum FamoWebSearchPayload {
  /// 把响应里的 C0 控制字符（0x00–0x1F）统一换成空格，然后才交给 `JSONSerialization`。
  ///
  /// 为什么必须做：两家的摘要都是从真实网页正文里抠出来的，正文里混进裸控制字符时，它们**不转义**
  /// 就直接塞进 JSON 字符串 —— 那不是合法 JSON，`JSONSerialization` 会直接拒收（实测确认：默认与
  /// `.fragmentsAllowed` 都拒）。而解析失败在我们这里被归类为「不顺位、如实报错」，于是这一问就
  /// **整个失败**。2026-07-27 实盘打 Perplexity 时复现过：同一条 query 连打三次，有一次的
  /// `search_context_size=medium/high` 响应就带着裸控制字符。
  ///
  /// 换成空格是安全的：JSON 的结构性空白（\t\n\r）本来就等价于空格；字符串里合法的换行是
  /// `\` + `n` 两个字节（都 ≥ 0x20，不受影响）；UTF-8 的续字节 ≥ 0x80，也不受影响。
  /// 代价只是摘要里的换行变成空格 —— 比整问失败好得多。
  static func sanitized(_ data: Data) -> Data {
    Data(data.map { $0 < 0x20 ? 0x20 : $0 })
  }

  /// `sanitized` + 顶层对象解析。两家共用。
  static func object(from data: Data) throws -> [String: Any] {
    guard let root = (try? JSONSerialization.jsonObject(with: sanitized(data)))
            as? [String: Any] else {
      throw FamoWebSearchError.malformedResponse
    }
    return root
  }
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
      // 法墨的回答窗是纯文本，图片段解析时就丢掉了。但**这里不能填 0**：文档写的是「传入值 > 0 时
      // 生效」，0 会被当成没传而落回默认的 3 张/条（2026-07-27 实测：0 与不传都拿到 4 个图片段，
      // 填 1 才降到 2 个）。所以取 1 —— 这是「关不掉的情况下最省的那档」。
      "MaxImageCountPerDoc": 1,
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
    let root = try FamoWebSearchPayload.object(from: data)
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
/// 三家的取舍（豆包/Perplexity 2026-07-27 查证，通义千问 2026-07-28 补）：豆包搜索基于豆包 APP 做，
/// 国内站点覆盖好、`open.feedcoopapi.com` 国内直连、每账号每月 500 次免费；Perplexity 英文内容强、
/// 支持域名/时效过滤，但 `api.perplexity.ai` 在国内多半要代理、且没有免费额度；通义千问复用你已经有的
/// 百炼 Key（不用再开一个搜索账号），代价是它的来源**不带正文摘要**——见 `FamoDashScopeSearchWire`。
/// 法墨是中文输入法，所以默认豆包，另外两家作为可选项。
enum FamoWebSearchBackend: String, CaseIterable, Hashable, Sendable {
  case doubaoGlobal = "doubao"
  /// 阿里云百炼（通义千问）。国内第二档，排在 Perplexity 前面。
  case qwen

  case perplexity

  /// 独立搜索后端的尝试顺序。设置偏好只把对应后端移到最前，不删除任何其他候选；Key
  /// 是否可用由任意提问 module 逐项过滤，避免「首选未配 Key」误伤已配置的后备服务。
  static func orderedCandidates(preferred: FamoWebSearchBackend) -> [FamoWebSearchBackend] {
    [preferred] + allCases.filter { $0 != preferred }
  }

  /// 设置页下拉里的名字。
  var displayName: String {
    switch self {
    case .doubaoGlobal: return "豆包搜索"
    // 刻意不叫「通义千问」：那是「联网模型」下拉里 qwen 自己检索自己作答的那一档的名字，而这里
    // qwen 只负责检索、作答的可能是 DeepSeek。用平台名（阿里云百炼）与模型名（通义千问）区分开，
    // 署名 chip 才看得出是哪条路 —— 与「豆包搜索」/「豆包」同一个用意。
    case .qwen:         return "阿里云百炼"
    case .perplexity:   return "Perplexity"
    }
  }

  /// 回答窗署名 chip 的 id。刻意带 `-search` 后缀，与同名的**模型**供应商区分开 ——
  /// 检索的是它，作答的可能是 DeepSeek。（`qwen-search` 与内置联网的 `qwen` 因此不会撞车。）
  var attributionID: String {
    switch self {
    case .doubaoGlobal: return "doubao-search"
    case .qwen:         return "qwen-search"
    case .perplexity:   return "perplexity-search"
    }
  }

  /// Keychain account。每家一把，换后端不会互相覆盖，切回去也不用重填。
  var secretName: String { "famo.websearch.\(rawValue).apiKey" }

  /// 设置页里告诉用户去哪儿拿 Key。豆包/Perplexity 都**不是**模型 Key，这句是最容易踩空的地方；
  /// 通义千问相反 —— 它就是百炼的模型 Key，但仍单独存一份（理由见 `FamoWebSearchKeyStore`）。
  var keyHint: String {
    switch self {
    case .doubaoGlobal:
      return "在火山引擎「联网搜索控制台 → API Key 管理 → 按量后付费」单独创建（方舟的模型 Key 在这里无效）。每个火山账号每月有 500 次免费额度。"
    case .qwen:
      return "就是阿里云百炼的模型 Key（sk- 开头），与上面「供应商」里那把同源，在这里再填一次即可。注意它取回的来源只有标题与网址、没有正文摘要，接地效果弱于豆包搜索。"
    case .perplexity:
      return "在 perplexity.ai 的 API 设置里创建（pplx- 开头）。国内网络访问 api.perplexity.ai 可能需要代理；英文内容检索效果更好，中文站点覆盖弱于豆包搜索。"
    }
  }

  func makeClient() -> FamoWebSearching {
    switch self {
    case .doubaoGlobal: return FamoDoubaoGlobalSearchClient()
    case .qwen:         return FamoDashScopeSearchClient()
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
      // 实测定的 high（2026-07-27，同一 query 各打 3 次）：
      //   low    5 条里只有 1 条有摘要，共 355 字 —— 接地基本没发生，模型拿到的只有标题和网址
      //   medium 3 条有摘要，765 字
      //   high   5 条全有摘要，2549 字
      // 而三档时延**没有差别**（0.72 / 0.65 / 0.65s），所以低档省不到时间，只是把接地省没了。
      "search_context_size": "high",
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
    let root = try FamoWebSearchPayload.object(from: data)
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

// MARK: - 阿里云百炼（通义千问）· wire format

/// 百炼 Responses `web_search` wire format，当作独立检索器用。Responses 原生返回
/// `web_search_call.action.sources`，因此不再需要旧 generation 端点的 `search_info` 方言，也没有
/// 文本/多模态端点与模型必须配对的陷阱。
enum FamoDashScopeSearchWire {
  /// 与 Qwen 供应商共用设置页里的 Workspace API Host；留空时走通用 Responses 域名。
  static var endpoint: URL { FamoQwenWorkspaceSettings.responsesEndpoint() }

  /// 检索用的模型。**不跟设置页那个模型下拉走**：那个下拉决定谁作答，这里决定谁检索，是两件事
  /// —— 检索器钉在这儿，不妨碍你把百炼档案设成别的型号。
  ///
  /// 该型号在 Responses 与内置 web_search 的支持清单内。检索器型号独立于默认作答档案。
  static let model = "qwen3.7-plus"

  /// We only consume sources. Ask for no prose; the compatibility reference does not document an
  /// output-token cap as an accepted request parameter, so do not rely on a silently ignored field.
  static func body(query: String) -> [String: Any] {
    FamoResponsesWire.body(
      model: model,
      messages: [FamoDeepSeekMessage(
        role: "user",
        content: "只执行联网检索，不要撰写答案。检索词：\(query.trimmingCharacters(in: .whitespacesAndNewlines))")],
      stream: false,
      dialect: .qwen,
      webSearch: true)
  }

  static func request(
    query: String,
    apiKey: String,
    endpoint: URL = endpoint
  ) throws -> URLRequest {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FamoWebSearchError.missingAPIKey
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body(query: query))
    return request
  }

  /// Responses errors use `error.{code,type,message}`; success sources may have no title, so use
  /// their hostname as the stable display fallback.
  static func parse(_ data: Data, limit: Int) throws -> [FamoWebSearchResult] {
    let root = try FamoWebSearchPayload.object(from: data)
    if let error = root["error"] as? [String: Any] {
      throw FamoWebSearchError.serviceError(
        code: (error["code"] as? String) ?? (error["type"] as? String) ?? "responses_error",
        message: (error["message"] as? String) ?? "")
    }
    let parsed = try FamoResponsesWire.parse(data)
    return parsed.sources.prefix(limit).map { source in
      let hostname = URL(string: source.url)?.host
      let title = source.title.isEmpty ? (hostname ?? source.url) : source.title
      return FamoWebSearchResult(
        title: title, url: source.url, snippet: "", publishedAt: nil, hostname: hostname)
    }
  }
}

/// 百炼检索的实时客户端。`fetch` 可注入，测试不碰网络。
struct FamoDashScopeSearchClient: FamoWebSearching {
  /// 比另外两家的 8s 略宽：这一跳不是一次检索，而是一次带联网的模型调用（见 wire 第 3 点）。
  /// 12s 是在实测 2.6–3.9s 之上留的余量；再宽没意义 —— 与其让人干等 20s 再报错，
  /// 不如早点失败、退回普通问答。
  let timeout: TimeInterval
  private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(
    timeout: TimeInterval = 12,
    fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) {
    self.timeout = timeout
    self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
  }

  func search(query: String, apiKey: String, limit: Int) async throws -> [FamoWebSearchResult] {
    var request = try FamoDashScopeSearchWire.request(query: query, apiKey: apiKey)
    request.timeoutInterval = timeout
    let (data, response) = try await fetch(request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw Self.serviceError(from: data, status: http.statusCode)
    }
    return try FamoDashScopeSearchWire.parse(data, limit: limit)
  }

  /// Non-2xx Responses errors nest the useful code/message under `error`.
  private static func serviceError(from data: Data, status: Int) -> FamoWebSearchError {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let error = root["error"] as? [String: Any] else {
      return .badHTTPStatus(status)
    }
    return .serviceError(
      code: (error["code"] as? String) ?? (error["type"] as? String) ?? String(status),
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
