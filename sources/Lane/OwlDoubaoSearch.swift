//
//  OwlDoubaoSearch.swift
//  猫头鹰输入法 (Owltype) — 来源核验的检索层：火山引擎「豆包搜索 Global 版」
//
//  来源核验先用豆包搜索取回网页（标题 / URL / 站点 / 发布时间 / 摘要），再把结果交给**默认供应商**
//  对照判断。检索与判断解耦：默认配的是 DeepSeek、MiniMax 也能核验，来源只来自搜索结果本身，
//  不依赖哪家模型自带联网工具。与本机 research-infra 的 `doubao-search` CLI 用的是同一个接口。
//
//  Pure value logic + 一个薄客户端：没有 UserDefaults，Key 由调用方传入。
//

import Foundation

/// 一条搜索结果（豆包与 DeepSeek 搜索共用）。`publishedAt` / `hostname` 可能为空——只用于标注来源，缺了不影响核验。
struct OwlWebSearchResult: Codable, Equatable, Sendable {
  let title: String
  let url: String
  let snippet: String
  let publishedAt: String?
  let hostname: String?
}

enum OwlDoubaoSearchError: Error, Equatable {
  case missingAPIKey
  case badHTTPStatus(Int)
  /// 豆包在 HTTP 200 里回的业务错误，`code` 是它的错误码。
  case serviceError(code: String, message: String)
  case malformedResponse
}

protocol OwlDoubaoSearching: Sendable {
  func search(query: String, apiKey: String, limit: Int) async throws -> [OwlWebSearchResult]
}

// MARK: - Wire format

/// 「豆包搜索 Global 版」的请求/响应 wire format。
///
/// 文档：docs.volcengine.com/docs/87772/2548026。三件与直觉相反的事：
///   1. 端点不在方舟域名下，是 `open.feedcoopapi.com`；
///   2. **Key 不是方舟模型 Key**——要在「联网搜索控制台 → API Key 管理 → 按量后付费」单独建一把。
///      拿方舟 Key 打过去会得到 `700901 invalid_api_key`；订阅套餐的 Key 会得到 `10409`；
///   3. **出错时 HTTP 仍是 200**，错误藏在 `ResponseMetadata.Error` 或 `Result.ErrorCode` 里。
enum OwlDoubaoSearchWire {
  static let endpoint = URL(string: "https://open.feedcoopapi.com/search_api/global_search")!

  /// 文档上限：DocCount 最多 20 条。
  static let maxDocCount = 20

  /// 文档：Query 1~100 个字符，超长会被截断。按 Character 截，别把中文截成半个码点。
  static let maxQueryLength = 100

  static func body(query: String, limit: Int) -> [String: Any] {
    OwlProviderCore.object("searchBody", ["query": query, "limit": limit, "doubao": true])
  }

  static func request(query: String, apiKey: String, limit: Int) throws -> URLRequest {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OwlDoubaoSearchError.missingAPIKey
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: body(query: query, limit: limit))
    return request
  }

  /// 业务错误一律 throw，绝不静默变成空列表——「搜到 0 条」和「Key 无效」对用户是两件事。
  static func parse(_ data: Data) throws -> [OwlWebSearchResult] {
    let reply: OwlSearchWireReply = OwlProviderCore.call("searchParse", ["bytes": Array(data), "doubao": true])
    if reply.error == "service" { throw OwlDoubaoSearchError.serviceError(code: reply.code ?? "unknown", message: reply.message ?? "") }
    guard let values = reply.values else { throw OwlDoubaoSearchError.malformedResponse }
    return values
  }

}

/// 豆包搜索的实时客户端。`fetch` 可注入，测试不碰网络。
struct OwlDoubaoSearchClient: OwlDoubaoSearching {
  /// 文档标称平均约 1 秒，给 10 秒已经很宽；核验的大头在后面的模型判断。
  let timeout: TimeInterval
  private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(
    timeout: TimeInterval = 10,
    fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) {
    self.timeout = timeout
    self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
  }

  func search(query: String, apiKey: String, limit: Int) async throws -> [OwlWebSearchResult] {
    var request = try OwlDoubaoSearchWire.request(query: query, apiKey: apiKey, limit: limit)
    request.timeoutInterval = timeout
    let (data, response) = try await fetch(request)
    if let http = response as? HTTPURLResponse, !OwlProviderCore.httpAccepted(http.statusCode) {
      throw OwlDoubaoSearchError.badHTTPStatus(http.statusCode)
    }
    return try OwlDoubaoSearchWire.parse(data)
  }
}

// MARK: - Key

/// 豆包搜索 Key 的钥匙串位置。复用 `OwlProviderKeychain` 的 service，只换一个固定 account；
/// account 沿用旧版独立搜索层的名字，之前存过豆包搜索 Key 的用户不用重填。
enum OwlDoubaoSearchKeyStore {
  static let secretName = "owltype.websearch.doubao.apiKey"

  static func apiKey(secrets: OwlSecretStoring = OwlProviderKeychain()) -> String? {
    guard let key = try? secrets.secret(named: secretName) else { return nil }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func isConfigured(secrets: OwlSecretStoring = OwlProviderKeychain()) -> Bool {
    apiKey(secrets: secrets) != nil
  }
}

struct OwlSearchWireReply: Decodable {
  let values: [OwlWebSearchResult]?
  let error: String?
  let code: String?
  let message: String?
}
