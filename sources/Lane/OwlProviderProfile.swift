//
//  OwlProviderProfile.swift
//  猫头鹰输入法 (Owltype) — multi-provider profile foundation
//  (task 06-22-owl-multi-provider-keychain-foundation, research B1+B2)
//
//  Turns the single hardcoded DeepSeek cloud config into a list of named provider PROFILES.
//  Each profile holds endpoint / model and a `secretName` — the Keychain account
//  the API key lives under. The key is NEVER stored in the profile JSON, UserDefaults, or logs;
//  `providers.json` is safe to inspect / back up. Storage follows Owltype's existing file-store idiom.
//
//  v1 ships ONE provider kind, `.openAICompatible` (DeepSeek's wire format already), which covers
//  OpenAI / Gemini-OpenAI-endpoint / cloud Ollama / most Chinese endpoints by endpoint+model+key
//  swap. Native Anthropic/Gemini, FoundationModels, and streaming are roadmap (B9), not v1.
//
//  The "active" provider is the single profile flagged `isDefault` — one source of truth in the
//  file, so there is no UserDefaults pointer to drift out of sync. Nothing here touches the IMK
//  hot path, the engine main lane, or engine config/deploy.
//
//  Concurrency: not `@MainActor`-isolated (matches the rest of the store layer); accessed from the
//  settings UI / delegate on the main thread.
//

import Foundation
import Security

// MARK: - Provider kind

/// Provider wire format. v1: OpenAI chat-completions compatible. Roadmap (B9) adds native
/// Anthropic/Gemini + on-device FoundationModels as new cases under the same profile model.
enum OwlProviderKind: String, Codable, CaseIterable, Sendable {
  case openAICompatible = "openai_compatible"

  var displayName: String {
    switch self {
    case .openAICompatible: return "OpenAI 兼容"
    }
  }
}

enum OwlProviderAuthHeaderStyle: String, Codable, Sendable, Equatable {
  case bearer

  func apply(to request: inout URLRequest, apiKey: String) {
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  }
}

struct OwlLLMProviderPreset: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let endpoint: String
  let model: String
  let keyHint: String
}

enum OwlLLMProviderCatalog {
  /// 未配置 Workspace 时使用的百炼通用 Responses 端点。Workspace 专属 Host 由
  /// `OwlQwenWorkspaceSettings` 在本机设置中保存，不能把某个用户的 Workspace 写死在预设里。
  static let qwenResponsesEndpoint =
    "https://dashscope.aliyuncs.com/compatible-mode/v1/responses"

  private struct Catalog: Decodable { let presets: [OwlLLMProviderPreset]; let qwenModels: [String]; let minimaxModels: [String] }
  private static let catalog: Catalog = OwlProviderCore.call("catalog")
  static let presets = catalog.presets
  static let qwenModels = catalog.qwenModels
  static let minimaxModels = catalog.minimaxModels

  static let customID = "custom"

  static func preset(id: String?) -> OwlLLMProviderPreset? {
    guard let id else { return nil }
    return presets.first { $0.id == id }
  }

  static func inferredProviderID(for profile: OwlProviderProfile?) -> String {
    OwlProviderCore.call("inferred", ["profile": profile.map(OwlAppCore.payload) ?? NSNull()])
  }

  /// Whether a resolved provider id is still routable: a preset in the catalog, or the custom id.
  /// A profile whose id has left the preset catalog (a provider retired by a newer build) is not a
  /// usable default and must fall back to the repo's default config instead of its own endpoint.
  static func isKnownProviderID(_ id: String) -> Bool {
    OwlProviderCore.call("known", ["id": id])
  }

  /// The provider id the settings form shows when editing a profile. A retired id is shown as
  /// custom so the form's endpoint stays editable and no dangling preset selection appears.
  static func formProviderID(for profile: OwlProviderProfile) -> String {
    OwlProviderCore.call("formProvider", ["profile": OwlAppCore.payload(profile)])
  }

  /// Short capability summary displayed on the provider row in AI settings.
  static func capabilitySummary(for profile: OwlProviderProfile) -> String {
    switch inferredProviderID(for: profile) {
    case "deepseek":
      return "LLM · 联网搜索 · 语音润色"
    case "qwen", "doubao", "grok", "openai", "gemini":
      return "LLM · 语音识别"
    default:
      return "LLM"
    }
  }
}

// MARK: - Qwen Workspace API Host

/// 百炼北京地域 Workspace 的 API Host 规范化与 Responses 端点生成。
///
/// 设置页允许粘贴三种等价输入：`ws-…`、完整 API Host、完整 Responses URL。只接受阿里云
/// 北京地域 Workspace Host，避免把任意用户输入直接插进 URL host。
enum OwlQwenWorkspace {
  static let beijingHostSuffix = ".cn-beijing.maas.aliyuncs.com"

  static func normalizedAPIHost(_ rawValue: String) -> String? {
    OwlProviderHost().required("workspace", ["input": rawValue])
  }

  static func responsesEndpoint(for rawValue: String) -> URL? {
    let value: String? = OwlProviderHost().required("workspaceEndpoint", ["input": rawValue])
    return value.flatMap(URL.init(string:))
  }

  static func apiHost(from endpoint: URL) -> String? {
    guard let host = endpoint.host else { return nil }
    return normalizedAPIHost(host)
  }
}

/// Workspace Host 不是密钥，放普通偏好即可。API Key 仍只存 Keychain。
enum OwlQwenWorkspaceSettings {
  static let key = "OwlQwenWorkspaceAPIHost"

  static func apiHost(defaults: UserDefaults = OwlDefaults.standard) -> String {
    defaults.string(forKey: key) ?? ""
  }

  /// 空值表示清除并回退通用端点；非法 Host 不覆盖上一次可用配置。
  @discardableResult
  static func save(
    _ rawValue: String,
    defaults: UserDefaults = OwlDefaults.standard
  ) -> Bool {
    guard let commit = prepareSave(rawValue, defaults: defaults) else { return false }
    commit()
    return true
  }

  /// Validate before a profile transaction. The returned write has no remaining validation
  /// or throwing operations, so settings cannot reject the input after profiles commit.
  static func prepareSave(
    _ rawValue: String,
    defaults: UserDefaults = OwlDefaults.standard
  ) -> (() -> Void)? {
    let host: String? = OwlProviderHost().required("prepareWorkspace", ["input": rawValue])
    guard let host else { return nil }
    return {
      if host.isEmpty { defaults.removeObject(forKey: key) }
      else { defaults.set(host, forKey: key) }
    }
  }

  static func responsesEndpoint(defaults: UserDefaults = OwlDefaults.standard) -> URL {
    let value: String = OwlProviderHost().required("storedWorkspaceEndpoint", ["input": apiHost(defaults: defaults)])
    return URL(string: value)!
  }
}

// MARK: - Errors

enum OwlProviderError: LocalizedError, Equatable {
  case emptyName
  case notFound(String)

  var errorDescription: String? {
    switch self {
    case .emptyName: return "供应商名称不能为空。"
    case let .notFound(id): return "未找到供应商配置（\(id)）。"
    }
  }
}

enum OwlProviderKeychainError: Error, Equatable {
  case unexpectedStatus(OSStatus)
}

// MARK: - Profile model

/// One named cloud provider configuration. `secretName` is the Keychain account the key lives
/// under — the key itself never appears in this struct or in `providers.json`.
struct OwlProviderProfile: Codable, Identifiable, Equatable, Sendable {
  let id: String
  var displayName: String
  var kind: OwlProviderKind
  var endpoint: URL
  var model: String
  var providerID: String?
  var secretName: String
  var isDefault: Bool
  var createdAt: Date

  init(
    id: String = UUID().uuidString,
    displayName: String,
    kind: OwlProviderKind = .openAICompatible,
    endpoint: URL,
    model: String,
    providerID: String? = nil,
    secretName: String? = nil,
    isDefault: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.endpoint = endpoint
    self.model = model
    self.providerID = providerID
    self.secretName = secretName ?? Self.defaultSecretName(for: id)
    self.isDefault = isDefault
    self.createdAt = createdAt
  }

  /// Forward-compatible decode: tolerate missing/extra fields, so a newer
  /// schema can add fields without breaking older readers and vice versa. Only `id` + `endpoint`
  /// are required; a record missing either is treated as malformed and skipped by the store.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let raw: [String: Any] = [
      "id": try c.decode(String.self, forKey: .id),
      "endpoint": try c.decode(URL.self, forKey: .endpoint).absoluteString,
      "displayName": try c.decodeIfPresent(String.self, forKey: .displayName) as Any? ?? NSNull(),
      "kind": try c.decodeIfPresent(String.self, forKey: .kind) as Any? ?? NSNull(),
      "model": try c.decodeIfPresent(String.self, forKey: .model) as Any? ?? NSNull(),
      "providerID": try c.decodeIfPresent(String.self, forKey: .providerID) as Any? ?? NSNull(),
      "secretName": try c.decodeIfPresent(String.self, forKey: .secretName) as Any? ?? NSNull(),
      "isDefault": try c.decodeIfPresent(Bool.self, forKey: .isDefault) as Any? ?? NSNull(),
      "createdAt": {
        if let doubleValue = try? c.decodeIfPresent(Double.self, forKey: .createdAt) { return doubleValue }
        if let stringValue = try? c.decodeIfPresent(String.self, forKey: .createdAt),
           let parsedDate = ISO8601DateFormatter().date(from: stringValue) {
          return parsedDate.timeIntervalSinceReferenceDate
        }
        if let dateValue = try? c.decodeIfPresent(Date.self, forKey: .createdAt) {
          return dateValue.timeIntervalSinceReferenceDate
        }
        return NSNull()
      }(),
    ]
    struct Fields: Decodable {
      let id: String; let displayName: String; let kind: OwlProviderKind; let endpoint: URL
      let model: String; let providerID: String?; let secretName: String; let isDefault: Bool; let createdAt: Date
    }
    let decoded: Fields? = OwlProviderCore.call("profileDefaults", ["profile": raw])
    guard let value = decoded else { throw OwlAppCore.Failure(code: "malformed_profile") }
    self.init(id: value.id, displayName: value.displayName, kind: value.kind, endpoint: value.endpoint,
      model: value.model, providerID: value.providerID, secretName: value.secretName,
      isDefault: value.isDefault, createdAt: value.createdAt)
  }

  /// Secret-name convention: `owltype.provider.<id>.apiKey`. Keeps every profile's key under a
  /// distinct Keychain account so multiple providers coexist.
  static func defaultSecretName(for id: String) -> String {
    OwlProviderCore.call("secretName", ["id": id])
  }
}

/// Schema-versioned on-disk wrapper. The version is on the file, not per-record — the standard
/// forward-migration seam. v1 reads/writes version 1.
struct OwlProviderProfilesFile: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var profiles: [OwlProviderProfile]

  init(schemaVersion: Int = currentSchemaVersion, profiles: [OwlProviderProfile] = []) {
    self.schemaVersion = schemaVersion
    self.profiles = profiles
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
    self.profiles = try c.decodeIfPresent([OwlProviderProfile].self, forKey: .profiles) ?? []
  }
}

// MARK: - Secret store

/// Narrow secret port so the migration / fetcher can be unit-tested with an in-memory fake instead
/// of the real Keychain (mirrors how `OwlSelectionPolishService` injects its `apiKeyProvider`).
protocol OwlSecretStoring {
  func secret(named name: String) throws -> String?
  func setSecret(_ value: String, named name: String) throws
  func deleteSecret(named name: String) throws
}

/// Live Keychain impl, keyed on the profile's `secretName`. Same upsert + not-found handling as
/// `OwlCloudKeychain`, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (device-only,
/// survives reboot, never synced to iCloud).
struct OwlProviderKeychain: OwlSecretStoring {
  static let service = "im.owltype.inputmethod.Owltype.providers"

  private func baseQuery(name: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: name,
    ]
  }

  func secret(named name: String) throws -> String? {
    guard !OwlTestStorage.isEnabled else { return nil }
    var query = baseQuery(name: name)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw OwlProviderKeychainError.unexpectedStatus(status) }
    guard let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func setSecret(_ value: String, named name: String) throws {
    guard !OwlTestStorage.isEnabled else { throw OwlProviderKeychainError.unexpectedStatus(errSecNotAvailable) }
    let data = Data(value.utf8)
    let base = baseQuery(name: name)
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw OwlProviderKeychainError.unexpectedStatus(updateStatus)
    }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw OwlProviderKeychainError.unexpectedStatus(addStatus)
    }
  }

  func deleteSecret(named name: String) throws {
    guard !OwlTestStorage.isEnabled else { throw OwlProviderKeychainError.unexpectedStatus(errSecNotAvailable) }
    let status = SecItemDelete(baseQuery(name: name) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OwlProviderKeychainError.unexpectedStatus(status)
    }
  }
}

// MARK: - Store

/// File-backed CRUD for provider profiles, persisted as a single schema-versioned `providers.json`
/// under `~/Library/Application Support/Owltype/` (pretty-printed, sorted keys, iso8601, atomic
/// write). `root` is injectable so tests point at a temp dir.
///
/// The default-profile invariant (exactly one `isDefault` when non-empty) is enforced on every
/// mutation, so callers never have to manage it.
final class OwlProviderProfileStore {
  static let shared = OwlProviderProfileStore()
  static let fileName = "providers.json"
  static let configurationDidChange = Notification.Name("OwlProviderConfigurationDidChange")

  private let root: URL

  // Fault injection at persistence boundaries; nil in production.
  var beforeSave: (() throws -> Void)?
  var afterAtomicWrite: (() throws -> Void)?

  init(root: URL = OwlApp.userDir) {
    self.root = root
  }

  var fileURL: URL { root.appendingPathComponent(Self.fileName, isDirectory: false) }

  private var host: OwlProviderHost { OwlProviderHost(store: self) }
  func load() -> OwlProviderProfilesFile { host.required("load") }
  func profiles() -> [OwlProviderProfile] { host.required("profiles") }
  func readableProfiles() -> [OwlProviderProfile]? { host.required("readable") }
  var defaultProfile: OwlProviderProfile? { host.required("defaultProfile") }
  func profile(id: String) -> OwlProviderProfile? { host.required("profile", ["id": id]) }
  @discardableResult
  func add(_ profile: OwlProviderProfile) throws -> OwlProviderProfile {
    try add(profile, replacing: []).first { $0.id == profile.id } ?? profile
  }
  @discardableResult
  func add(_ profile: OwlProviderProfile, replacing replacedIDs: [String]) throws -> [OwlProviderProfile] {
    try host.call("add", ["profile": OwlAppCore.payload(profile), "replacing": replacedIDs])
  }
  @discardableResult
  func update(_ profile: OwlProviderProfile) throws -> OwlProviderProfile {
    let values: [OwlProviderProfile] = try host.call("update", ["profile": OwlAppCore.payload(profile)])
    return values.first { $0.id == profile.id } ?? profile
  }
  @discardableResult
  func update(_ profiles: [OwlProviderProfile]) throws -> [OwlProviderProfile] {
    try host.call("batch", ["profiles": OwlAppCore.payload(profiles)])
  }
  func delete(id: String) throws {
    let _: [OwlProviderProfile] = try host.call("delete", ["id": id])
  }
  func setDefault(id: String) throws {
    let _: [OwlProviderProfile] = try host.call("default", ["id": id])
  }

}

// MARK: - Legacy migration

/// One-shot, idempotent migration of the legacy single-DeepSeek setup into a default profile.
/// Runs only when there are no profiles yet AND a legacy DeepSeek key is actually present (a fresh
/// install just has no providers; the user adds one in settings). The legacy key is copied into the
/// new per-profile `secretName`; the old `OwlCloudKeychain` entry is left intact as a fallback.
enum OwlProviderMigration {
  @discardableResult
  static func migrateLegacyDeepSeekIfNeeded(
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain(),
    legacyKeyReader: () throws -> String? = OwlCloudKeychain.readDeepSeekAPIKey,
    legacyEndpoint: URL = OwlCloudPreferences.deepSeekEndpoint,
    legacyModel: String = OwlCloudPreferences.deepSeekModel
  ) -> OwlProviderProfile? {
    withoutActuallyEscaping(legacyKeyReader) { reader in
      let host = OwlProviderHost(store: store, secrets: secrets)
      host.legacyReader = reader
      return host.required("legacyMigrate", ["endpoint": legacyEndpoint.absoluteString, "model": legacyModel])
    }
  }
}

// MARK: - Model list fetch

/// Fetches an OpenAI-compatible provider's model list (`GET {base}/models`) so the AI-config page
/// can offer live model ids instead of asking the user to type one. Curated preset models stay as
/// the always-available fallback; fetched ids enrich them. Mirrors Responsay's `probe(fetch:)` +
/// `LLMModelPresetFilter`, Owltype-sized.
enum OwlProviderModelList {
  /// Derive the models endpoint from a chat-completions endpoint: swap a trailing
  /// `/chat/completions` for `/models` (covers OpenAI, DeepSeek, and the Gemini `/openai/...`
  /// shim); otherwise append `models` to the endpoint's parent path.
  static func modelsURL(from endpoint: URL) -> URL? {
    let url: String? = OwlProviderCore.call("modelsURL", ["endpoint": endpoint.absoluteString])
    return url.flatMap(URL.init(string:)) ?? endpoint.deletingLastPathComponent().appendingPathComponent("models")
  }

  /// Model ids from an OpenAI `{ "data": [ { "id": … } ] }` payload, in server order, deduped.
  static func parseModelIDs(_ data: Data) -> [String] {
    OwlProviderCore.call("modelsParse", ["bytes": Array(data)])
  }

  /// Curated models first (the always-available fallback), then any fetched ids not already listed.
  static func merged(curated: [String], fetched: [String]) -> [String] {
    OwlProviderCore.call("modelsMerge", ["values": curated + fetched])
  }

  /// GET the provider's model list. Throws on bad URL / transport error / non-200.
  static func fetch(
    endpoint: URL,
    apiKey: String,
    authStyle: OwlProviderAuthHeaderStyle
  ) async throws -> [String] {
    guard let url = modelsURL(from: endpoint) else { throw URLError(.badURL) }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    authStyle.apply(to: &req, apiKey: apiKey)
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return parseModelIDs(data)
  }
}

// MARK: - 连通性验证

/// 「验证连通性」：拿当前这组 端点 + 模型 + Key **真发一次最小请求**，看对面回不回话。
///
/// 为什么它不是「拉取最新」的重复：`/models` 只证明主机通、Key 有效，**完全不检查你选的那个型号**。
/// 真实踩过的坑正是这一类 —— 2026-07-28 实测百炼的 `qwen3.7-plus` 在
/// `/api/v1/services/aigc/text-generation/generation` 上一律 `400 url error`，而同一把 Key 拉
/// `/models` 一切正常。「型号列表里有」「这个端点服务它」是两件事，中间这道缝只有真打一发才看得见。
///
/// 失败时必须把服务端那句话带出来：用户看到「url error」才知道是换型号，看到「Invalid API-key」
/// 才知道是换 Key —— 只报一个状态码等于让人去猜。
enum OwlProviderConnectivityCheck {
  enum Outcome: Equatable {
    /// 通了。`latencyMS` 是整轮往返，顺带让用户对这条链路的手感有个数。
    case ok(latencyMS: Int)
    /// 连上了但对面拒绝（Key 无效 / 型号不服务 / 欠费）。`message` 是服务端原话（已脱敏、截短），
    /// `code` 是它的错误码，认得就换成一句中文判断。
    case rejected(status: Int, message: String, code: String? = nil)
    /// 连都没连上：DNS、超时、证书、代理。
    case unreachable(String)
    /// 2xx 却不是一个能认的 chat 响应 —— 多半是网关/代理插进来的页面。
    case malformed
  }

  /// 最小请求体。Chat providers cap output at 16 tokens; the Responses providers (Qwen / 豆包)
  /// do not carry that old field because their compatibility references do not list it as an
  /// accepted request field.
  ///
  /// 一并合上 `OwlThinkingControl.offBody`：混合思考模型默认开着思考时，会在回第一个字前先烧几百
  /// 上千推理 token（同 任意提问 那条路的理由），验证个连通性没必要等那么久。Responses 方言的
  /// 关思考（qwen `reasoning.effort:none`、方舟 `thinking.type:disabled`）由
  /// `OwlResponsesWire.body` 统一带上。
  static func body(providerID: String, model: String, endpoint: URL? = nil) -> [String: Any] {
    OwlProviderCore.object("probeBody", ["providerID": providerID, "model": model, "host": endpoint?.host ?? ""])
  }

  static func request(
    endpoint: URL,
    providerID: String,
    model: String,
    apiKey: String,
    authStyle: OwlProviderAuthHeaderStyle
  ) throws -> URLRequest {
    let usesResponses = OwlProviderCapabilities(
      providerID: providerID, model: model, endpoint: endpoint).dialect != nil
    let requestURL = usesResponses
      ? (OwlResponsesWire.url(from: endpoint) ?? endpoint)
      : endpoint
    var req = URLRequest(url: requestURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    authStyle.apply(to: &req, apiKey: apiKey)
    req.timeoutInterval = OwlLLMCallPurpose.connectivityProbe.timeout
    req.httpBody = try JSONSerialization.data(
      withJSONObject: body(providerID: providerID, model: model, endpoint: endpoint))
    return req
  }

  /// 响应 → 结论。纯函数，测试不碰网络。
  static func outcome(data: Data, response: URLResponse?, latencyMS: Int, apiKey: String = "") -> Outcome {
    struct Result: Decodable { let kind: String; let detail: OwlServerErrorDetail? }
    let http = response as? HTTPURLResponse
    let result: Result = OwlProviderCore.call("probeOutcome", ["bytes": Array(data),
      "status": http?.statusCode as Any? ?? NSNull()])
    switch result.kind {
    case "ok": return .ok(latencyMS: latencyMS)
    case "rejected": return .rejected(status: http!.statusCode,
      message: result.detail?.sanitized(removing: apiKey) ?? "", code: result.detail?.code)
    default: return .malformed
    }
  }

  /// 真打一发。**不 throw**：连不上也是一种结论，调用方要的是一句能显示的话，不是一个错误。
  static func run(
    endpoint: URL,
    providerID: String,
    model: String,
    apiKey: String,
    authStyle: OwlProviderAuthHeaderStyle,
    transport: OwlLLMTransport = OwlURLSessionTransport(),
    clock: () -> Date = Date.init
  ) async -> Outcome {
    let started = clock()
    do {
      let request = try request(
        endpoint: endpoint, providerID: providerID, model: model,
        apiKey: apiKey, authStyle: authStyle)
      let (data, response) = try await transport.send(request)
      let elapsed = Int(clock().timeIntervalSince(started) * 1000)
      return outcome(data: data, response: response, latencyMS: elapsed, apiKey: apiKey)
    } catch {
      return .unreachable((error as? URLError)?.localizedDescription ?? error.localizedDescription)
    }
  }
}

extension OwlProviderConnectivityCheck.Outcome {
  /// 设置页那行状态字。成功一句话，失败要说清「下一步该动哪里」。
  var statusText: String {
    switch self {
    case let .ok(latencyMS):
      return "连通正常，\(latencyMS) ms 收到回复。"
    case let .rejected(status, message, code):
      let detail = message.isEmpty ? "" : "：\(message)"
      // 认得错误码就照它说；否则 401/403 几乎总是 Key，400/404 几乎总是型号或端点 —— 直接把判断
      // 给出来，别让人自己对表。
      let hint = OwlServerRefusal(code: code).map { "（\($0.message)）" }
        ?? ((status == 401 || status == 403)
          ? "（多半是 API Key 无效或没权限）"
          : (status == 400 || status == 404 ? "（多半是这个端点不服务该模型，换个型号再试）" : ""))
      return "对方拒绝了这次请求，HTTP \(status)\(hint)\(detail)"
    case let .unreachable(reason):
      return "连不上：\(reason)。检查网络、端点地址或代理。"
    case .malformed:
      return "对方回了 200，但既不是 Chat 响应也不是 Responses 响应——端点可能不是 OpenAI 兼容的 "
        + "/chat/completions 或 /responses。"
    }
  }

  var isOK: Bool { if case .ok = self { return true }; return false }
}
