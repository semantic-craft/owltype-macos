//
//  OwlCloudFoundation.swift
//  猫头鹰输入法 (Owltype) — shared cloud foundation (preferences / Keychain / routing / wire types)
//
//  The common base every explicit cloud-AI feature builds on: 划词润色、提示词优化、流式聊天、
//  AI 对话窗. P1-lite boundary: the cloud is NEVER an always-on decoder and never sees 逐键
//  input — every request here is default-off and explicitly user-triggered. Typing candidates
//  are local-only (the engine main lane); the inline lane this file's predecessor
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
  static var requestTimeout: TimeInterval { OwlLLMCallPurpose.interactiveRewrite.timeout }

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
    OwlProviderCore.call("canonicalModel", ["model": raw ?? ""])
  }

  /// The one Chinese mapper for a refused cloud request, on every surface next to the cursor
  /// (划词技能、AI 窗). A known server code wins; otherwise the HTTP status decides.
  static func message(for error: Error) -> String {
    let status: Int
    let detail: OwlServerErrorDetail?
    switch error {
    case let OwlCloudRequestError.badHTTPStatus(code, body), let OwlStreamingError.badHTTPStatus(code, body):
      (status, detail) = (code, body)
    default: (status, detail) = (0, nil)
    }
    return OwlProviderCore.call("errorMessage", ["status": status, "code": detail?.code ?? ""])
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
    let data = try! JSONEncoder().encode(fields)
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }

  struct Fields: Codable {
    var thinking: OwlDeepSeekThinking?
    var enableThinking: Bool?
    var reasoningEffort: String?
    var reasoningSplit: Bool?
    enum CodingKeys: String, CodingKey {
      case thinking
      case enableThinking = "enable_thinking", reasoningEffort = "reasoning_effort", reasoningSplit = "reasoning_split"
    }
  }
  static func offFields(providerID: String, model: String) -> Fields {
    OwlProviderCore.call("thinking", ["providerID": providerID, "model": model])
  }
}

enum OwlChatSamplingControl {
  /// Gemini 3.8 deprecated sampling controls; omit them on its OpenAI-compatible endpoint too.
  /// https://ai.google.dev/gemini-api/docs/latest-model#migration-checklist
  static func temperature(_ value: Double, model: String) -> Double? {
    OwlProviderCore.call("temperature", ["model": model, "value": value])
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

  func encode(to encoder: Encoder) throws {
    let value: OwlJSONValue = OwlProviderCore.call("chatBody", [
      "model": model, "messages": OwlAppCore.payload(messages), "stream": stream,
      "temperature": temperature as Any? ?? NSNull(),
      "responseFormat": responseFormat.map(OwlAppCore.payload) ?? NSNull(),
      "thinking": thinking.map(OwlAppCore.payload) ?? NSNull(),
      "enableThinking": enableThinking as Any? ?? NSNull(),
      "reasoningEffort": reasoningEffort as Any? ?? NSNull(),
      "reasoningSplit": reasoningSplit as Any? ?? NSNull(),
    ])
    try value.encode(to: encoder)
  }

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
  /// A non-2xx reply. `detail` is what the error body said, nil when it said nothing readable.
  case badHTTPStatus(Int, detail: OwlServerErrorDetail? = nil)
  case emptyResponse
}

/// What a provider said when it refused a request, read from the error body. The raw `message`
/// never reaches a surface next to the cursor: `OwlCloudPreferences.message(for:)` maps `code`,
/// and only the settings connectivity probe shows `message`, after `sanitized(removing:)`.
struct OwlServerErrorDetail: Codable, Equatable, Sendable {
  /// The provider's machine-readable reason (`code`, else `type`), e.g. `invalid_api_key`.
  let code: String?
  let message: String?

  /// Reads `{"error":{...}}`, a top-level `{"code","message"}` (DashScope native), or a
  /// one-element array of either. A numeric `code` (Gemini repeats the HTTP status there) gives way
  /// to the string `status` beside it. Nil when the body has neither a code nor a message.
  static func parse(_ data: Data) -> OwlServerErrorDetail? {
    OwlProviderCore.call("errorDetail", ["bytes": Array(data)])
  }

  /// Collects a refused stream's body (bounded) and parses it. Never throws: a body that cannot
  /// be read only loses the detail, not the status.
  static func read(_ chunks: AsyncThrowingStream<String, Error>, limit: Int = 16_384) async -> OwlServerErrorDetail? {
    var body = ""
    do {
      for try await chunk in chunks {
        body += chunk
        if body.utf8.count >= limit { break }
      }
    } catch {}
    return parse(Data(body.utf8))
  }

  static func read(_ chunks: AsyncThrowingStream<Data, Error>, limit: Int = 16_384) async -> OwlServerErrorDetail? {
    var data = Data()
    do {
      for try await chunk in chunks {
        data.append(chunk.prefix(max(0, limit - data.count)))
        if data.count >= limit { break }
      }
    } catch {}
    return parse(data)
  }

  /// `message` safe to show in settings: the API key and anything shaped like one masked,
  /// whitespace collapsed, at most `maxLength` characters.
  func sanitized(removing apiKey: String, maxLength: Int = 160) -> String {
    OwlProviderCore.call("sanitize", ["message": message ?? "", "key": apiKey, "limit": maxLength])
  }
}

/// Why a provider refused, as far as its error code says. Codes come from each provider's
/// published error reference (checked 2026-10-28): 百炼 help.aliyun.com/zh/model-studio/error-code,
/// 方舟 docs.volcengine.com/docs/82379/1299023, OpenAI developers.openai.com/api/docs/guides/error-codes,
/// Gemini ai.google.dev/gemini-api/docs/api-errors. DeepSeek documents statuses only, and MiniMax
/// reports `base_resp` inside a 200, so neither adds codes here. An unknown code is nil and the
/// caller falls back to the HTTP status.
enum OwlServerRefusal: String, Equatable {
  case invalidKey
  case modelUnavailable
  case insufficientBalance
  case quotaExhausted
  case rateLimited
  case contentBlocked

  init?(code: String?) {
    let raw: String? = OwlProviderCore.call("refusal", ["code": code ?? ""])
    guard let raw, let result = Self(rawValue: raw) else { return nil }
    self = result
  }
  var message: String { OwlProviderCore.call("refusalMessage", ["kind": rawValue]) }

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
struct OwlCloudRouting: Codable, Equatable, Sendable {
  let providerID: String
  let endpoint: URL
  let model: String
  /// Keychain account for the active profile, or nil when falling back to the legacy DeepSeek key.
  let secretName: String?
  let authHeaderStyle: OwlProviderAuthHeaderStyle

  /// Resolve from the active provider profile, falling back to the legacy globals when none exists.
  static func resolve(profile: OwlProviderProfile?) -> OwlCloudRouting {
    OwlProviderCore.call("routing", ["profile": profile.map(OwlAppCore.payload) ?? NSNull(),
      "legacyEndpoint": OwlCloudPreferences.deepSeekEndpoint.absoluteString,
      "legacyModel": OwlCloudPreferences.deepSeekModel])
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
    OwlProviderCore.call("numberedRewrite", ["text": content])
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
  static var maxAttempts: Int { OwlLLMCallPurpose.interactiveRewrite.maxAttempts }
  static var backoffNanoseconds: UInt64 { OwlProviderCore.call("retryDelay") }

  static func isRetryable(_ error: Error) -> Bool {
    var kind = "other"
    var status = 0
    switch error {
    case OwlCloudRequestError.emptyResponse: kind = "empty"
    case let OwlCloudRequestError.badHTTPStatus(value, _): kind = "http"; status = value
    case let value as URLError:
      switch value.code {
      case .timedOut: kind = "timeout"
      case .networkConnectionLost: kind = "connectionLost"
      default: break
      }
    default: break
    }
    return OwlProviderCore.call("retry", ["kind": kind, "status": status])
  }
}
