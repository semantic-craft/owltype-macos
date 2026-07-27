//
//  FamoDoubaoSearchClient.swift
//  法墨输入法 (Famo) — 任意提问「联网搜索」的豆包搜索 Global 版检索传输
//
//  与本目录另外两条传输的根本区别：**这家不作答**。方舟 `/responses` 与 Perplexity
//  `/chat/completions` 都是「把问题交给它，它边搜边写答案」；豆包搜索 Global 版是一个纯检索 API ——
//  给一个 query，返回网页结果（标题/URL/摘要/站点/发布时间），答案仍由**主模型**基于这些资料写。
//  所以这条线是 检索 → 注入 prompt → 走既有的普通问答流（`FamoStreamingChatService.stream`）。
//
//  为什么走这条而不是方舟的 `web_search` 工具：方舟那个工具要在控制台单独开通内容插件，没开通时
//  整条请求直接 404 `{"error":{"code":"ToolNotOpen"}}`（2026-07-27 实机）。豆包搜索是独立产品、
//  独立 API Key（`FamoSearchCredential.doubaoSearch`，取自「联网搜索控制台」而非火山方舟），每个
//  火山账号每月 500 次免费额度。方舟 `/responses` 的搜索 wire 仍保留 —— 来源核验还在用。
//
//  端点契约（docs.volcengine.com/docs/87772/2548026，2026-06-26 版）：
//    POST https://open.feedcoopapi.com/search_api/global_search
//    Authorization: Bearer <API_KEY>
//    请求 {Query(必填, 1~100字符), DocCount(≤20, 默认10), MaxSnippetLength(默认500, ≤3000)}
//    响应 {ResponseMetadata:{RequestId, Error?}, Result:{Documents[], TotalDocCount, ErrorCode, ErrorMsg}}
//
//  注意错误可以带着 **HTTP 200** 回来（`ResponseMetadata.Error` / `Result.ErrorCode` 非 0），所以
//  只看状态码不够 —— 不查这两处就会把一次失败的检索当成「搜到了 0 条」，让主模型凭训练知识作答而
//  署名 chip 仍写着「联网」。
//
//  Off the IMK hot path: only an explicit 任意提问 with 联网搜索 resolved to 豆包搜索 reaches here.
//

import Foundation

// MARK: - Errors

/// 检索失败的分类。`isRouteUnusable` 是给 `FamoAskSearchFailover` 的判据：这条路由**这次拿不出
/// 可依据的资料**，顺位到下一家联网供应商；否则如实上报给用户。
enum FamoWebRetrievalError: Error, Equatable {
  /// 非 2xx。
  case badHTTPStatus(Int)
  /// HTTP 2xx，但响应体里带着业务错误码（`ResponseMetadata.Error.Code` 或 `Result.ErrorCode`）。
  case apiError(code: Int, message: String)
  /// 响应不是预期结构（对方改了 shape / 返回了 HTML）。
  case malformedResponse
  /// 检索成功但**一条结果都没有**。不是「技术上的失败」，但对我们等于失败：注入空资料等于让主模型
  /// 凭训练知识作答，而署名 chip 却写着「联网」—— 那正是这套联网链路要避免的谎。顺位。
  case emptyResults

  /// 豆包搜索的暂时性错误码：内部错误、免费额度链路依赖失败、频率超限。稍后重试同一家仍可能成功，
  /// 所以**不**顺位（顺位只会把一个错误变成好几个）。
  static let transientCodes: Set<Int> = [10500, 10501, 700429]

  /// 该顺位到下一家吗？
  var isRouteUnusable: Bool {
    switch self {
    case let .badHTTPStatus(status):
      return FamoAskSearchFailover.isConfigurationRefusal(status: status)
    case let .apiError(code, _):
      // 10403 账号/权限、10408 功能不可用、10409 套餐模式不支持、10410 无可用套餐、10412 额度不足、
      // 700901 APIKey 无效、10400 参数错误 —— 都是「这家现在不会为你服务」，换一家才有戏。
      return !Self.transientCodes.contains(code)
    case .malformedResponse, .emptyResults:
      return true
    }
  }
}

// MARK: - 检索结果

/// 一条网页检索结果，已裁成主模型作答需要的字段（图片片段丢弃）。
struct FamoWebSearchDocument: Equatable, Sendable {
  let title: String
  let url: String
  /// 与 query 相关的正文摘要（多个文本片段已按序拼好）。
  let snippet: String
  /// 站点名，如「抖音百科」。
  let hostname: String
  /// 网页发布时间，端点没给就是空串。
  let publishTime: String
}

// MARK: - 传输端口

/// 窄接口：只有「检索」这一件事。`FamoStreamingChatService` 依赖它而非具体 client，测试用假实现
/// 脚本化结果与失败，不碰 socket（与 `FamoChatStreaming` / `FamoResponsesStreaming` 同一套路）。
protocol FamoWebRetrieving {
  /// 检索 `query`，返回结果列表。失败 throw `FamoWebRetrievalError`（网络层错误原样透出 `URLError`）。
  func retrieve(
    query: String,
    routing: FamoCloudRouting,
    apiKey: String
  ) async throws -> [FamoWebSearchDocument]
}

/// 豆包搜索 Global 版检索 client。
struct FamoDoubaoSearchClient: FamoWebRetrieving {
  /// 返回结果条数。端点上限 20、默认 10；取 5 是因为这些摘要要整段进 prompt —— 再多就是让主模型
  /// 在噪音里挑，token 也白烧。
  static let documentCount = 5
  /// 单个摘要片段的最大 tokens（端点默认 500，上限 3000，官方推荐 1000 以内）。
  static let maxSnippetLength = 500

  /// 检索的 per-request 超时（秒）。官方给的 Global 版平均时延约 1s，留足重试余量；比
  /// `FamoResponsesStreamingClient` 的 90s 短得多 —— 这一步只是取资料，之后还要等主模型写答案。
  let timeout: TimeInterval
  /// 注入的数据源。默认走 `URLSession`；测试注入脚本化的 (Data, HTTPURLResponse)。
  private let dataProvider: (URLRequest) async throws -> (Data, URLResponse)

  init(
    timeout: TimeInterval = 15,
    dataProvider: ((URLRequest) async throws -> (Data, URLResponse))? = nil
  ) {
    self.timeout = timeout
    self.dataProvider = dataProvider ?? { try await URLSession.shared.data(for: $0) }
  }

  func retrieve(
    query: String,
    routing: FamoCloudRouting,
    apiKey: String
  ) async throws -> [FamoWebSearchDocument] {
    var request = URLRequest(url: routing.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    routing.authHeaderStyle.apply(to: &request, apiKey: apiKey)
    request.timeoutInterval = timeout
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "Query": query,
      "DocCount": Self.documentCount,
      "MaxSnippetLength": Self.maxSnippetLength,
    ])

    let (data, response) = try await dataProvider(request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw FamoWebRetrievalError.badHTTPStatus(http.statusCode)
    }
    return try Self.decode(data)
  }

  /// 解析响应体（纯函数，测试直接喂 JSON）。业务错误码优先于 documents —— 见文件头「HTTP 200 也可能
  /// 是失败」。
  static func decode(_ data: Data) throws -> [FamoWebSearchDocument] {
    guard let decoded = try? JSONDecoder().decode(GlobalSearchResponse.self, from: data) else {
      throw FamoWebRetrievalError.malformedResponse
    }
    if let apiError = decoded.responseMetadata?.error {
      throw FamoWebRetrievalError.apiError(
        code: Int(apiError.code ?? "") ?? apiError.codeN ?? 0,
        message: apiError.message ?? "检索失败"
      )
    }
    guard let result = decoded.result else { throw FamoWebRetrievalError.malformedResponse }
    if let code = result.errorCode, code != 0 {
      throw FamoWebRetrievalError.apiError(code: code, message: result.errorMsg ?? "检索失败")
    }
    let documents = (result.documents ?? []).compactMap(Self.document(from:))
    guard !documents.isEmpty else { throw FamoWebRetrievalError.emptyResults }
    return documents
  }

  /// 一条 `Documents[i]` → 我们的值类型。标题与摘要都空的条目丢掉：它进 prompt 也没有可依据的内容。
  private static func document(from raw: GlobalSearchResponse.Document) -> FamoWebSearchDocument? {
    // 只要文本片段；图片片段（`Type == "image"`）对一段文字答案没有用。
    let snippet = (raw.snippet ?? [])
      .filter { $0.type != "image" }
      .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !title.isEmpty || !snippet.isEmpty else { return nil }
    return FamoWebSearchDocument(
      title: title,
      url: raw.url ?? "",
      snippet: snippet,
      hostname: raw.hostInfo?.hostname ?? "",
      publishTime: raw.documentInfo?.publishTime ?? ""
    )
  }

  /// 响应体的解码形状。每一层都 optional：对方多加字段不该让整次检索失败，而少给字段要能被上面的
  /// 校验逮住（而不是解码 throw 成一个没信息的错误）。
  struct GlobalSearchResponse: Decodable {
    struct Metadata: Decodable {
      struct APIError: Decodable {
        let code: String?
        let codeN: Int?
        let message: String?
        enum CodingKeys: String, CodingKey {
          case code = "Code"
          case codeN = "CodeN"
          case message = "Message"
        }
      }
      let error: APIError?
      enum CodingKeys: String, CodingKey { case error = "Error" }
    }

    struct Document: Decodable {
      struct Snippet: Decodable {
        let type: String?
        let text: String?
        enum CodingKeys: String, CodingKey {
          case type = "Type"
          case text = "Text"
        }
      }
      struct DocumentInfo: Decodable {
        let publishTime: String?
        enum CodingKeys: String, CodingKey { case publishTime = "PublishTime" }
      }
      struct HostInfo: Decodable {
        let hostname: String?
        enum CodingKeys: String, CodingKey { case hostname = "Hostname" }
      }
      let url: String?
      let title: String?
      let snippet: [Snippet]?
      let documentInfo: DocumentInfo?
      let hostInfo: HostInfo?
      enum CodingKeys: String, CodingKey {
        case url = "Url"
        case title = "Title"
        case snippet = "Snippet"
        case documentInfo = "DocumentInfo"
        case hostInfo = "HostInfo"
      }
    }

    struct Result: Decodable {
      let documents: [Document]?
      let errorCode: Int?
      let errorMsg: String?
      enum CodingKeys: String, CodingKey {
        case documents = "Documents"
        case errorCode = "ErrorCode"
        case errorMsg = "ErrorMsg"
      }
    }

    let responseMetadata: Metadata?
    let result: Result?
    enum CodingKeys: String, CodingKey {
      case responseMetadata = "ResponseMetadata"
      case result = "Result"
    }
  }
}

// MARK: - 注入 prompt（纯值逻辑）

/// 把检索结果变成主模型能用的资料块，并把它挂到请求上。纯函数，不发请求。
enum FamoWebRetrievalPrompt {
  /// 端点的 query 上限：1~100 字符，且「不支持多词搜索」（官方文档）。超长会被端点截断，我们自己
  /// 先截干净，免得截断点落在半个词上。
  static let maxQueryLength = 100

  /// 用户的问题 → 检索 query。折叠换行与连续空白（多行问题原样发过去等于多词搜索），再截到上限。
  static func query(from question: String) -> String {
    let collapsed = question
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard collapsed.count > maxQueryLength else { return collapsed }
    return String(collapsed.prefix(maxQueryLength))
  }

  /// 资料块。带序号/标题/站点/时间/URL，好让答案能标引用；末尾那句「资料没提到就说明」是为了不把
  /// 检索失败包装成一个自信的答案。
  static func contextBlock(documents: [FamoWebSearchDocument], sourceName: String) -> String {
    let entries = documents.enumerated().map { index, doc -> String in
      var head = "[\(index + 1)] \(doc.title.isEmpty ? doc.url : doc.title)"
      let meta = [doc.hostname, doc.publishTime].filter { !$0.isEmpty }.joined(separator: " · ")
      if !meta.isEmpty { head += "（\(meta)）" }
      var lines = [head]
      if !doc.url.isEmpty { lines.append(doc.url) }
      if !doc.snippet.isEmpty { lines.append(doc.snippet) }
      return lines.joined(separator: "\n")
    }
    return """
      【以下是「\(sourceName)」刚检索到的网页资料】
      \(entries.joined(separator: "\n\n"))

      【要求】基于上面的资料回答我下面的问题，引用处标注对应的 [序号]；资料没有提到的部分，直接说明\
      资料里没有，不要凭印象补。
      """
  }

  /// 把资料块挂到消息序列上：拼在**最后一条 user 消息**前面。
  ///
  /// 为什么不另发一条 system：多加一条 system 在各家 `/chat/completions` 上的接受度不一致（有的只
  /// 认第一条），而改写最后一问对每家都一样，且历史 `turns` 里存的仍是用户原话 —— 资料只作用于这
  /// 一次请求，不会污染后续轮次的上下文。
  static func augment(
    messages: [FamoDeepSeekMessage],
    documents: [FamoWebSearchDocument],
    sourceName: String
  ) -> [FamoDeepSeekMessage] {
    guard !documents.isEmpty else { return messages }
    let block = contextBlock(documents: documents, sourceName: sourceName)
    guard let index = messages.lastIndex(where: { $0.role == "user" }) else {
      // 没有 user 消息（理论上不会发生）——也绝不能把资料丢掉，否则署名说联网了而答案其实没依据。
      return messages + [FamoDeepSeekMessage(role: "user", content: block)]
    }
    var augmented = messages
    augmented[index] = FamoDeepSeekMessage(
      role: augmented[index].role,
      content: "\(block)\n\n\(augmented[index].content)"
    )
    return augmented
  }
}
