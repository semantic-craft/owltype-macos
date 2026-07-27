//
//  FamoCloudFoundation.swift
//  法墨输入法 (Famo) — shared cloud foundation (preferences / Keychain / routing / wire types)
//
//  The common base every explicit cloud-AI feature builds on: 划词润色、提示词优化、流式聊天、
//  AI 对话窗. P1-lite boundary: the cloud is NEVER an always-on decoder and never sees 逐键
//  input — every request here is default-off and explicitly user-triggered. Typing candidates
//  are local-only (Rime main lane + T1 smart lane); the inline lane this file's predecessor
//  (FamoDeepSeekCloudLane.swift) was named for is gone.
//

import Foundation
import Security

enum FamoCloudProvider: String, CaseIterable, Sendable {
  case deepSeek

  var displayName: String {
    switch self {
    case .deepSeek: return "DeepSeek"
    }
  }
}

/// Single UserDefaults home for cloud preferences. Defaults are intentionally inert.
enum FamoCloudPreferences {
  private static let enabledKey = "FamoCloudLaneEnabled"
  private static let providerKey = "FamoCloudProvider"
  private static let modelKey = "FamoDeepSeekModel"
  private static let endpointKey = "FamoDeepSeekEndpoint"

  static let defaultDeepSeekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
  static let defaultDeepSeekModel = "deepseek-v4-flash"
  static let reasonerDeepSeekModel = "deepseek-v4-pro"

  /// Explicit per-request network timeout (seconds). Bounds worst-case degrade latency so a
  /// hung cloud request never blocks the UI that triggered it. Long-output skills (提示词优化)
  /// carry their own longer timeout instead of reusing this. (G5)
  static let requestTimeout: TimeInterval = 8

  /// Default false. A caller must explicitly enable this before any network request can happen.
  /// Shared gate for the explicit cloud-AI features (划词润色 / 任意提问).
  static var isEnabled: Bool {
    get { FamoDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
    set { FamoDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  static var provider: FamoCloudProvider {
    get {
      FamoCloudProvider(rawValue: FamoDefaults.standard.string(forKey: providerKey) ?? "") ?? .deepSeek
    }
    set { FamoDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
  }

  static var deepSeekModel: String {
    get {
      let stored = FamoDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return canonicalDeepSeekModel(stored)
    }
    set { FamoDefaults.standard.set(canonicalDeepSeekModel(newValue), forKey: modelKey) }
  }

  static var deepSeekEndpoint: URL {
    get {
      guard let raw = FamoDefaults.standard.string(forKey: endpointKey),
            let url = URL(string: raw),
            url.scheme == "https" else {
        return defaultDeepSeekEndpoint
      }
      return url
    }
    set { FamoDefaults.standard.set(newValue.absoluteString, forKey: endpointKey) }
  }

  static func resetForTesting() {
    FamoDefaults.standard.removeObject(forKey: enabledKey)
    FamoDefaults.standard.removeObject(forKey: providerKey)
    FamoDefaults.standard.removeObject(forKey: modelKey)
    FamoDefaults.standard.removeObject(forKey: endpointKey)
  }

  static func canonicalDeepSeekModel(_ raw: String?) -> String {
    let model = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch model {
    case "", "deepseek-chat":
      return defaultDeepSeekModel
    case "deepseek-reasoner":
      return reasonerDeepSeekModel
    default:
      return model
    }
  }

  static func message(for error: Error) -> String {
    // 流式与检索两条路各有自己的错误类型（`FamoStreamingError` / `FamoWebRetrievalError`）。不映射的
    // 话，任意提问全链路失败后只会显示一句没信息的「云端 AI 请求失败」，用户既不知道是 Key 失效还是
    // 断网，也不知道该去哪儿改。
    if let streamingError = error as? FamoStreamingError {
      switch streamingError {
      case let .badHTTPStatus(status):
        return message(forStatus: status)
      case let .upstreamFailure(detail):
        return "云端 AI 中断：\(detail)"
      case .invalidEndpoint:
        return "云端 AI 端点不支持此请求"
      case .nonHTTPResponse:
        return "云端 AI 请求失败"
      }
    }
    if let retrievalError = error as? FamoWebRetrievalError {
      switch retrievalError {
      case let .badHTTPStatus(status):
        return message(forStatus: status)
      case let .apiError(code, detail):
        return "联网检索失败（\(code)）：\(detail)"
      case .malformedResponse:
        return "联网检索返回了无法解析的内容"
      case .emptyResults:
        return "联网检索没有找到相关网页"
      }
    }
    guard let cloudError = error as? FamoCloudRequestError,
          case let .badHTTPStatus(status) = cloudError else {
      return "云端 AI 请求失败"
    }
    return message(forStatus: status)
  }

  /// HTTP 状态码 → 面向用户的一句话。三种错误类型共用（都是同一批状态码，说法没有理由不一致）。
  private static func message(forStatus status: Int) -> String {
    switch status {
    case 400:
      return "云端 AI 拒绝了此请求"
    case 401:
      return "云端 AI 的 API Key 无效"
    case 402:
      return "云端 AI 账户余额不足"
    case 422:
      return "云端 AI 不支持的请求格式"
    case 429:
      return "云端 AI 请求过于频繁，请稍后再试"
    case 500:
      return "云端 AI 服务器错误，请稍后重试"
    case 503:
      return "云端 AI 服务繁忙，请稍后重试"
    default:
      return "云端 AI 请求失败（\(status)）"
    }
  }
}

enum FamoCloudKeychainError: Error, Equatable {
  case unexpectedStatus(OSStatus)
}

/// Keychain home for the DeepSeek API key. The key is never stored in UserDefaults.
enum FamoCloudKeychain {
  private static let service = "im.famo.inputmethod.Famo.deepseek"
  private static let account = "DeepSeekAPIKey"

  static func readDeepSeekAPIKey() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw FamoCloudKeychainError.unexpectedStatus(status) }
    guard let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func saveDeepSeekAPIKey(_ key: String) throws {
    let data = Data(key.utf8)
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw FamoCloudKeychainError.unexpectedStatus(updateStatus)
    }

    var add = base
    add[kSecValueData as String] = data
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw FamoCloudKeychainError.unexpectedStatus(addStatus)
    }
  }

  static func deleteDeepSeekAPIKey() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw FamoCloudKeychainError.unexpectedStatus(status)
    }
  }
}

struct FamoDeepSeekMessage: Codable, Equatable, Sendable {
  let role: String
  let content: String
}

struct FamoDeepSeekResponseFormat: Codable, Equatable, Sendable {
  let type: String
  static let jsonObject = FamoDeepSeekResponseFormat(type: "json_object")
}

/// DeepSeek hybrid-thinking control. `deepseek-v4-flash` defaults to ON, which spends hundreds of
/// hidden-reasoning completion tokens before emitting a short JSON reply — far too slow for the
/// short-output interactive skills (e.g. 划词润色). `{"type":"disabled"}` drops that to ~1s
/// (measured). DeepSeek-only field; omitted for other providers and for `.deepRewrite`
/// (which WANTS deep reasoning, routed to the pro model).
struct FamoDeepSeekThinking: Codable, Equatable, Sendable {
  let type: String
  static let disabled = FamoDeepSeekThinking(type: "disabled")
}

struct FamoDeepSeekChatRequest: Codable, Equatable, Sendable {
  let model: String
  let messages: [FamoDeepSeekMessage]
  let temperature: Double
  let stream: Bool
  /// DeepSeek / OpenAI-compatible JSON mode. Forces a JSON-object reply so the local parser
  /// validates `{"candidates": [...]}` instead of free text. json_object mode requires the
  /// prompt to also ask for JSON + give an example (see `FamoSelectionPolish.chatRequest`). (G5)
  let responseFormat: FamoDeepSeekResponseFormat
  /// DeepSeek-only thinking control; nil → field omitted (other providers / deep rewrite unchanged).
  let thinking: FamoDeepSeekThinking?
  /// DashScope（qwen）的混合思考开关，语义对应 DeepSeek 的 `thinking`。qwen3.6-flash 默认开思考，
  /// 短输出前先烧几百上千 reasoning token（实测润色一句话 948 个、5.4s；关掉后 0.6s）。
  /// nil → 字段省略，非 qwen 供应商的请求体逐字节不变。
  let enableThinking: Bool?

  enum CodingKeys: String, CodingKey {
    case model, messages, temperature, stream, thinking
    case responseFormat = "response_format"
    case enableThinking = "enable_thinking"
  }
}

enum FamoCloudRequestError: Error, Equatable {
  case disabled
  case missingAPIKey
  case unsupportedProvider
  case badHTTPStatus(Int)
  case emptyResponse
}

/// Resolved routing for one cloud request: endpoint / model + the Keychain account
/// (`secretName`) the API key lives under. This is the single point where the active provider profile
/// (B1) is collapsed into the concrete values the fetcher uses, with a legacy fallback so a
/// pre-migration user keeps working unchanged.
///
/// Resolution order:
///   1. If a default `FamoProviderProfile` exists → route from it (its endpoint/model;
///      key read via the per-profile `secretName`).
///   2. Otherwise → fall back to the legacy globals (`FamoCloudPreferences.deepSeekEndpoint/.deepSeekModel`
///      + `FamoCloudKeychain.readDeepSeekAPIKey`). This is the safety net; do not remove it.
///
/// No network, no IMK hot path; pure value resolution from the store + UserDefaults.
struct FamoCloudRouting: Equatable, Sendable {
  let providerID: String
  let endpoint: URL
  let model: String
  /// Keychain account for the active profile, or nil when falling back to the legacy DeepSeek key.
  let secretName: String?
  let authHeaderStyle: FamoProviderAuthHeaderStyle

  /// Resolve from the active provider profile, falling back to the legacy globals when none exists.
  static func resolve(profile: FamoProviderProfile?) -> FamoCloudRouting {
    if let profile {
      return FamoCloudRouting(
        providerID: FamoLLMProviderCatalog.inferredProviderID(for: profile),
        endpoint: profile.endpoint,
        model: profile.model.isEmpty ? FamoCloudPreferences.deepSeekModel : profile.model,
        secretName: profile.secretName,
        authHeaderStyle: FamoLLMProviderCatalog.authHeaderStyle(for: profile)
      )
    }
    return FamoCloudRouting(
      providerID: "deepseek",
      endpoint: FamoCloudPreferences.deepSeekEndpoint,
      model: FamoCloudPreferences.deepSeekModel,
      secretName: nil,
      authHeaderStyle: .bearer
    )
  }
}

struct FamoCloudUsageSnapshot: Codable, Equatable, Sendable {
  let model: String
  let completionTokens: Int
  let promptTokens: Int
  let promptCacheHitTokens: Int
  let promptCacheMissTokens: Int
  let totalTokens: Int
}

enum FamoCloudUsageTelemetry {
  private static let lastUsageKey = "FamoCloudLastUsageTelemetry"

  static var lastUsage: FamoCloudUsageSnapshot? {
    guard let data = FamoDefaults.standard.data(forKey: lastUsageKey) else { return nil }
    return try? JSONDecoder().decode(FamoCloudUsageSnapshot.self, from: data)
  }

  static func record(_ usage: FamoCloudUsageSnapshot) {
    guard let data = try? JSONEncoder().encode(usage) else { return }
    FamoDefaults.standard.set(data, forKey: lastUsageKey)
  }

  static func resetForTesting() {
    FamoDefaults.standard.removeObject(forKey: lastUsageKey)
  }
}

/// Parser for the numbered-rewrite replies the 划词「润色 · 多版本挑选」flow requests: accepts a
/// bare JSON string array, the `{"candidates": [...]}` json_object contract, or a plain
/// numbered/bulleted list, and returns the cleaned, de-duplicated rewrite strings.
enum FamoNumberedRewriteParser {
  static func parse(_ content: String) -> [String] {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
       let array = try? JSONDecoder().decode([String].self, from: data) {
      return cleaned(array)
    }
    if let data = trimmed.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let array = object["candidates"] as? [String] {
      return cleaned(array)
    }
    if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { return [] }
    return cleaned(
      trimmed
        .split(whereSeparator: \.isNewline)
        .map { line in
          line.trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789.、 \t"))
        }
    )
  }

  private static func cleaned(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, seen.insert(text).inserted else { return nil }
      return text
    }
  }
}

/// DeepSeek (OpenAI-compatible) chat-completions response shape, shared by every skill that decodes
/// a non-streaming chat reply (划词润色 `FamoSelectionPolishClient`, 提示词优化). Kept as a
/// namespace (no instances) so the shared response/usage shapes live in one place.
enum FamoDeepSeekClient {
  struct Usage: Decodable {
    let completionTokens: Int
    let promptTokens: Int
    /// DeepSeek 特有的缓存命中/未命中计数。**必须可选**：阿里云百炼等 OpenAI 兼容供应商的
    /// `usage` 里根本没有这两个键，设成必填会让整个响应解码抛错——不是少一项遥测，而是这条
    /// 解码器上的所有技能（划词润色、提示词优化）在该供应商上全部失效。
    /// 2026-07-20 打真实百炼时才暴露：mock fetcher 永远喂的是 DeepSeek 形状的响应。
    let promptCacheHitTokens: Int?
    let promptCacheMissTokens: Int?
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
      case completionTokens = "completion_tokens"
      case promptTokens = "prompt_tokens"
      case promptCacheHitTokens = "prompt_cache_hit_tokens"
      case promptCacheMissTokens = "prompt_cache_miss_tokens"
      case totalTokens = "total_tokens"
    }
  }

  struct Response: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable {
        let content: String
      }

      let message: Message
    }

    let choices: [Choice]
    let model: String?
    let usage: Usage?
  }
}

/// G5: which cloud failures earn one bounded retry. Transient / idempotent only —
/// timeouts, dropped connections, 500/503, and empty content. Client errors (4xx) and
/// decode failures are never retried (an identical second request won't change them).
enum FamoCloudRetry {
  static let maxAttempts = 2                            // 1 initial + 1 retry
  static let backoffNanoseconds: UInt64 = 400_000_000  // ~400ms, a suspension not a block

  static func isRetryable(_ error: Error) -> Bool {
    if let cloud = error as? FamoCloudRequestError {
      switch cloud {
      case .emptyResponse: return true
      case .badHTTPStatus(let status): return status == 500 || status == 503
      default: return false
      }
    }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut, .networkConnectionLost: return true
      default: return false
      }
    }
    return false
  }
}
