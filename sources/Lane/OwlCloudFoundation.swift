//
//  OwlCloudFoundation.swift
//  猫头鹰输入法 (Owltype) — shared cloud foundation (preferences / Keychain / routing / wire types)
//
//  The common base every explicit cloud-AI feature builds on: 划词润色、提示词优化、流式聊天、
//  AI 对话窗. P1-lite boundary: the cloud is NEVER an always-on decoder and never sees 逐键
//  input — every request here is default-off and explicitly user-triggered. Typing candidates
//  are local-only (Rime main lane + T1 smart lane); the inline lane this file's predecessor
//  (OwlDeepSeekCloudLane.swift) was named for is gone.
//

import Foundation
import Security

enum OwlCloudProvider: String, CaseIterable, Sendable {
  case deepSeek

  var displayName: String {
    switch self {
    case .deepSeek: return "DeepSeek"
    }
  }
}

/// Single UserDefaults home for cloud preferences. Defaults are intentionally inert.
enum OwlCloudPreferences {
  private static let enabledKey = "OwlCloudLaneEnabled"
  private static let providerKey = "OwlCloudProvider"
  private static let modelKey = "OwlDeepSeekModel"
  private static let endpointKey = "OwlDeepSeekEndpoint"

  static let defaultDeepSeekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
  static let defaultDeepSeekModel = "deepseek-flash"
  static let reasonerDeepSeekModel = "deepseek-v4-pro"

  /// Explicit per-request network timeout (seconds). Bounds worst-case degrade latency so a
  /// hung cloud request never blocks the UI that triggered it. Long-output skills (提示词优化)
  /// carry their own longer timeout instead of reusing this. (G5)
  static let requestTimeout: TimeInterval = 8

  /// Default false. A caller must explicitly enable this before any network request can happen.
  /// Shared gate for the explicit cloud-AI features (划词润色 / 任意提问).
  static var isEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  static var provider: OwlCloudProvider {
    get {
      OwlCloudProvider(rawValue: OwlDefaults.standard.string(forKey: providerKey) ?? "") ?? .deepSeek
    }
    set { OwlDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
  }

  static var deepSeekModel: String {
    get {
      let stored = OwlDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return canonicalDeepSeekModel(stored)
    }
    set { OwlDefaults.standard.set(canonicalDeepSeekModel(newValue), forKey: modelKey) }
  }

  static var deepSeekEndpoint: URL {
    get {
      guard let raw = OwlDefaults.standard.string(forKey: endpointKey),
            let url = URL(string: raw),
            url.scheme == "https" else {
        return defaultDeepSeekEndpoint
      }
      return url
    }
    set { OwlDefaults.standard.set(newValue.absoluteString, forKey: endpointKey) }
  }

  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: enabledKey)
    OwlDefaults.standard.removeObject(forKey: providerKey)
    OwlDefaults.standard.removeObject(forKey: modelKey)
    OwlDefaults.standard.removeObject(forKey: endpointKey)
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
    guard let cloudError = error as? OwlCloudRequestError,
          case let .badHTTPStatus(status) = cloudError else {
      return "云端 AI 请求失败"
    }
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

enum OwlCloudKeychainError: Error, Equatable {
  case unexpectedStatus(OSStatus)
}

/// Keychain home for the DeepSeek API key. The key is never stored in UserDefaults.
enum OwlCloudKeychain {
  private static let service = "im.owltype.inputmethod.Owltype.deepseek"
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
    guard status == errSecSuccess else { throw OwlCloudKeychainError.unexpectedStatus(status) }
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
      throw OwlCloudKeychainError.unexpectedStatus(updateStatus)
    }

    var add = base
    add[kSecValueData as String] = data
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw OwlCloudKeychainError.unexpectedStatus(addStatus)
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
      throw OwlCloudKeychainError.unexpectedStatus(status)
    }
  }
}

struct OwlDeepSeekMessage: Codable, Equatable, Sendable {
  let role: String
  let content: String
}

struct OwlDeepSeekResponseFormat: Codable, Equatable, Sendable {
  let type: String
  static let jsonObject = OwlDeepSeekResponseFormat(type: "json_object")
}

/// DeepSeek hybrid-thinking control. `deepseek-v4-flash` defaults to ON, which spends hundreds of
/// hidden-reasoning completion tokens before emitting a short JSON reply — far too slow for the
/// short-output interactive skills (e.g. 划词润色). `{"type":"disabled"}` drops that to ~1s
/// (measured). DeepSeek-only field; omitted for other providers and for `.deepRewrite`
/// (which WANTS deep reasoning, routed to the pro model).
struct OwlDeepSeekThinking: Codable, Equatable, Sendable {
  let type: String
  static let disabled = OwlDeepSeekThinking(type: "disabled")
}

/// 交互延迟策略的逐家 wire format：能关闭思考时关闭，M3.1 使用 low。
///
/// Owltype 的每条链路都是短输出交互（划词润色、任意提问、来源核验），混合思考模型默认开着思考时
/// 会在吐第一个字前先烧几百上千 reasoning token：实测 qwen3.6-flash 润色一句话 948 token / 5.4s，
/// 关掉后 0.6s（2026-07-20 实盘百炼）。M3.1 不允许关闭思考，使用 low；M3 可以关闭。
///
/// 关思考的字段名各家不同，且与「联网搜索」正交（方舟的搜索插件还要求思考关掉才触发），
/// 所以这里按 providerID 给出旧 Chat 请求要合进顶层的字段。Qwen 与豆包 已统一由
/// `OwlResponsesWire` 在 Responses 请求体里关思考（qwen `reasoning.effort:none`、方舟
/// `thinking.type:disabled`）；这里的 DashScope / deepSeekStyle 分支只保留给仍走 Chat 的
/// 托管模型及兼容 payload builder。
///
/// 返回空字典 = 这家没有已知的思考开关，请求体逐字节不变（OpenAI 的 reasoning 走 `/responses`
/// 的另一套字段，不在这里管）。
enum OwlThinkingControl {
  /// Top-level fields for the provider's lowest supported thinking latency.
  ///
  /// `model` is the fallback for a custom profile whose id was never stamped — same precedence as
  /// `OwlProviderCapabilities.searchChannel(providerID:host:)`, and it keeps the pre-B1 model-prefix
  /// behaviour (`OwlSelectionPolish.chatRequest`) working unchanged.
  static func offBody(providerID: String, model: String) -> [String: Any] {
    offBody(offFields(providerID: providerID, model: model))
  }

  /// `fields` as top-level JSON, for a body built with `JSONSerialization`.
  static func offBody(_ fields: Fields) -> [String: Any] {
    var body: [String: Any] = [:]
    if let thinking = fields.thinking { body["thinking"] = ["type": thinking.type] }
    if let enabled = fields.enableThinking { body["enable_thinking"] = enabled }
    if let effort = fields.reasoningEffort { body["reasoning_effort"] = effort }
    if let split = fields.reasoningSplit { body["reasoning_split"] = split }
    return body
  }

  struct Fields {
    var thinking: OwlDeepSeekThinking?
    var enableThinking: Bool?
    var reasoningEffort: String?
    var reasoningSplit: Bool?
  }

  /// Typed equivalent for JSON-producing selection skills. Reasoning stays outside content.
  static func offFields(providerID: String, model: String) -> Fields {
    switch resolved(providerID: providerID, model: model) {
    case .deepSeekStyle: return Fields(thinking: .disabled)
    case .dashScope: return Fields(enableThinking: false)
    case .minimaxAdaptive: return Fields(reasoningEffort: "low", reasoningSplit: true)
    case .minimaxDirect: return Fields(thinking: .disabled, reasoningSplit: true)
    case .minimaxThinking: return Fields(reasoningSplit: true)
    case .none: return Fields()
    }
  }

  /// Which dialect of the thinking switch applies. Not public — callers want `offBody`/`offFields`.
  private enum Dialect { case deepSeekStyle, dashScope, minimaxAdaptive, minimaxDirect, minimaxThinking, none }

  private static func resolved(providerID: String, model: String) -> Dialect {
    switch providerID.lowercased() {
    // `{"thinking":{"type":"disabled"}}` — DeepSeek、火山方舟豆包 用的是同一种形状。
    case "deepseek", "doubao": return .deepSeekStyle
    case "qwen":               return .dashScope
    case "openai", "gemini":   return .none
    default: break
    }
    let m = model.lowercased()
    // M3.1 Flash 不能关思考，只能调深度；`-preview` 是正式版前的 ID，旧档案仍按同一形状发。
    if m == "minimax-m3.1-flash" || m == "minimax-m3.1-flash-preview" { return .minimaxAdaptive }
    if m == "minimax-m3" { return .minimaxDirect }
    if m.hasPrefix("minimax-m2") { return .minimaxThinking }
    if m.hasPrefix("deepseek") || m.hasPrefix("doubao") { return .deepSeekStyle }
    if m.hasPrefix("qwen") { return .dashScope }
    return .none
  }
}

enum OwlChatSamplingControl {
  /// Gemini 3.8 deprecated sampling controls; omit them on its OpenAI-compatible endpoint too.
  /// https://ai.google.dev/gemini-api/docs/latest-model#migration-checklist
  static func temperature(_ value: Double, model: String) -> Double? {
    model.lowercased() == "gemini-3.8-flash" ? nil : value
  }
}

struct OwlDeepSeekChatRequest: Codable, Equatable, Sendable {
  let model: String
  let messages: [OwlDeepSeekMessage]
  let temperature: Double?
  let stream: Bool
  /// DeepSeek / OpenAI-compatible JSON mode. Forces a JSON-object reply so the local parser
  /// validates `{"candidates": [...]}` instead of free text. json_object mode requires the
  /// prompt to also ask for JSON + give an example (see `OwlSelectionPolish.chatRequest`). (G5)
  let responseFormat: OwlDeepSeekResponseFormat?
  /// DeepSeek-only thinking control; nil → field omitted (other providers / deep rewrite unchanged).
  let thinking: OwlDeepSeekThinking?
  /// DashScope（qwen）的混合思考开关，语义对应 DeepSeek 的 `thinking`。qwen3.6-flash 默认开思考，
  /// 短输出前先烧几百上千 reasoning token（实测润色一句话 948 个、5.4s；关掉后 0.6s）。
  /// nil → 字段省略，非 qwen 供应商的请求体逐字节不变。
  let enableThinking: Bool?

  let reasoningEffort: String?
  let reasoningSplit: Bool?

  enum CodingKeys: String, CodingKey {
    case model, messages, temperature, stream, thinking
    case responseFormat = "response_format"
    case enableThinking = "enable_thinking"
    case reasoningEffort = "reasoning_effort"
    case reasoningSplit = "reasoning_split"
  }
}

enum OwlCloudRequestError: Error, Equatable {
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
///   1. If a default `OwlProviderProfile` exists → route from it (its endpoint/model;
///      key read via the per-profile `secretName`).
///   2. Otherwise → fall back to the legacy globals (`OwlCloudPreferences.deepSeekEndpoint/.deepSeekModel`
///      + `OwlCloudKeychain.readDeepSeekAPIKey`). This is the safety net; do not remove it.
///
/// No network, no IMK hot path; pure value resolution from the store + UserDefaults.
struct OwlCloudRouting: Equatable, Sendable {
  let providerID: String
  let endpoint: URL
  let model: String
  /// Keychain account for the active profile, or nil when falling back to the legacy DeepSeek key.
  let secretName: String?
  let authHeaderStyle: OwlProviderAuthHeaderStyle

  /// Resolve from the active provider profile, falling back to the legacy globals when none exists.
  static func resolve(profile: OwlProviderProfile?) -> OwlCloudRouting {
    if let profile {
      return OwlCloudRouting(
        providerID: OwlLLMProviderCatalog.inferredProviderID(for: profile),
        endpoint: profile.endpoint,
        model: profile.model.isEmpty ? OwlCloudPreferences.deepSeekModel : profile.model,
        secretName: profile.secretName,
        authHeaderStyle: .bearer
      )
    }
    return OwlCloudRouting(
      providerID: "deepseek",
      endpoint: OwlCloudPreferences.deepSeekEndpoint,
      model: OwlCloudPreferences.deepSeekModel,
      secretName: nil,
      authHeaderStyle: .bearer
    )
  }
}

struct OwlCloudUsageSnapshot: Codable, Equatable, Sendable {
  let model: String
  let completionTokens: Int
  let promptTokens: Int
  let promptCacheHitTokens: Int
  let promptCacheMissTokens: Int
  let totalTokens: Int
}

enum OwlCloudUsageTelemetry {
  private static let lastUsageKey = "OwlCloudLastUsageTelemetry"

  static var lastUsage: OwlCloudUsageSnapshot? {
    guard let data = OwlDefaults.standard.data(forKey: lastUsageKey) else { return nil }
    return try? JSONDecoder().decode(OwlCloudUsageSnapshot.self, from: data)
  }

  static func record(_ usage: OwlCloudUsageSnapshot) {
    guard let data = try? JSONEncoder().encode(usage) else { return }
    OwlDefaults.standard.set(data, forKey: lastUsageKey)
  }

  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: lastUsageKey)
  }
}

/// Parser for the numbered-rewrite replies the 划词「润色 · 多版本挑选」flow requests: accepts a
/// bare JSON string array, the `{"candidates": [...]}` json_object contract, or a plain
/// numbered/bulleted list, and returns the cleaned, de-duplicated rewrite strings.
enum OwlNumberedRewriteParser {
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
/// a non-streaming chat reply (划词润色 `OwlSelectionPolishClient`, 提示词优化). Kept as a
/// namespace (no instances) so the shared response/usage shapes live in one place.
enum OwlDeepSeekClient {
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
enum OwlCloudRetry {
  static let maxAttempts = 2                            // 1 initial + 1 retry
  static let backoffNanoseconds: UInt64 = 400_000_000  // ~400ms, a suspension not a block

  static func isRetryable(_ error: Error) -> Bool {
    if let cloud = error as? OwlCloudRequestError {
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
