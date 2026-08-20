//
//  OwlProviderProfile.swift
//  法墨输入法 (Owltype) — multi-provider profile foundation
//  (task 06-22-famo-multi-provider-keychain-foundation, research B1+B2)
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
//  hot path, the Rime main lane, or rime config/deploy.
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
  case apiKey

  func apply(to request: inout URLRequest, apiKey: String) {
    switch self {
    case .bearer:
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    case .apiKey:
      request.setValue(apiKey, forHTTPHeaderField: "api-key")
    }
  }
}

enum OwlProviderSourceSupport: String, Codable, Sendable, Equatable {
  case sourceResults
  case searchPlanOnly

  var supportsSourceVerification: Bool { self == .sourceResults }

  var displayName: String {
    switch self {
    case .sourceResults: return "支持来源核验"
    case .searchPlanOnly: return "辅助检索"
    }
  }
}

struct OwlLLMProviderPreset: Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let endpoint: String
  let model: String
  let keyHint: String
  let sourceSupport: OwlProviderSourceSupport
  let authHeaderStyle: OwlProviderAuthHeaderStyle
}

enum OwlLLMProviderCatalog {
  /// 未配置 Workspace 时使用的百炼通用 Responses 端点。Workspace 专属 Host 由
  /// `OwlQwenWorkspaceSettings` 在本机设置中保存，不能把某个用户的 Workspace 写死在预设里。
  static let qwenResponsesEndpoint =
    "https://dashscope.aliyuncs.com/compatible-mode/v1/responses"

  static let presets: [OwlLLMProviderPreset] = [
    OwlLLMProviderPreset(
      id: "qwen",
      displayName: "阿里云百炼",
      endpoint: qwenResponsesEndpoint,
      model: "qwen3.7-plus",
      keyHint: "按量付费 sk-…；Token Plan 请改用 token-plan.cn-beijing.maas.aliyuncs.com",
      sourceSupport: .sourceResults,
      authHeaderStyle: .bearer
    ),
    OwlLLMProviderPreset(
      id: "doubao",
      displayName: "火山引擎 · 豆包 Seed",
      endpoint: "https://ark.cn-beijing.volces.com/api/v3/responses",
      model: "doubao-seed-2-1-pro-260628",
      keyHint: "火山方舟 API Key",
      sourceSupport: .sourceResults,
      authHeaderStyle: .bearer
    ),
    OwlLLMProviderPreset(
      id: "mimo",
      displayName: "小米 MiMo",
      endpoint: "https://api.xiaomimimo.com/v1/chat/completions",
      model: "mimo-v2.5",
      keyHint: "按量付费 sk-…；Token Plan 填 tp-…",
      sourceSupport: .sourceResults,
      authHeaderStyle: .apiKey
    ),
    OwlLLMProviderPreset(
      id: "deepseek",
      displayName: "DeepSeek",
      endpoint: "https://api.deepseek.com/v1/chat/completions",
      model: "deepseek-v4-flash",
      keyHint: "sk-…",
      sourceSupport: .searchPlanOnly,
      authHeaderStyle: .bearer
    ),
    OwlLLMProviderPreset(
      id: "minimax",
      displayName: "MiniMax",
      endpoint: "https://api.minimaxi.com/v1/chat/completions",
      model: "MiniMax-M2.7-highspeed",
      keyHint: "MiniMax API Key",
      sourceSupport: .searchPlanOnly,
      authHeaderStyle: .bearer
    ),
    OwlLLMProviderPreset(
      id: "gemini",
      displayName: "Google Gemini",
      endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      model: "gemini-3.5-flash-lite",
      keyHint: "AIza…",
      sourceSupport: .searchPlanOnly,
      authHeaderStyle: .bearer
    ),
    OwlLLMProviderPreset(
      id: "openai",
      displayName: "OpenAI",
      endpoint: "https://api.openai.com/v1/chat/completions",
      model: "chat-latest",
      keyHint: "sk-…",
      sourceSupport: .sourceResults,
      authHeaderStyle: .bearer
    ),
  ]

  /// 百炼可选模型，默认在前。第一个必须与上面 qwen 预设的 `model` 一致（下拉里选不到默认值很怪）。
  ///
  /// 为什么要列一串而不是像别家那样只写一个：阿里的型号迭代比法墨发版快，设置页下拉里只出现一个
  /// 型号会让人以为「只能用这个」。真正的全量清单靠设置页的「拉取最新」按钮从 `/models` 拉，这里
  /// 只兜住没联网/没拉取时的常用几个。
  ///
  /// 只列产品正式支持的两档（2026-07-31 产品决定）：`qwen3.7-plus` 默认基线、`qwen3.7-max`
  /// 高质量档，均取自阿里云模型总表。Flash 型号不再作为内置推荐或质量基线——想用的用户仍可
  /// 手动输入或经「拉取最新」从 `/models` 选到，法墨只是不替它背书。**没有**顺手补 qwen3.6-plus /
  /// qwen3.6-max —— 模型总表里已经查不到任何 `qwen3.6-*` 条目，凭命名规律推出来的 id 塞进下拉，
  /// 用户选中就是一个 400。
  static let qwenModels = [
    "qwen3.7-plus",
    "qwen3.7-max",
  ]

  static let customID = "custom"

  static func preset(id: String?) -> OwlLLMProviderPreset? {
    guard let id else { return nil }
    return presets.first { $0.id == id }
  }

  static func inferredProviderID(for profile: OwlProviderProfile?) -> String {
    guard let profile else { return "deepseek" }
    if let stored = profile.providerID, !stored.isEmpty { return stored }
    let host = profile.endpoint.host?.lowercased() ?? ""
    let name = profile.displayName.lowercased()
    if host.contains("dashscope") || host.contains("aliyuncs") || name.contains("百炼") || name.contains("qwen") { return "qwen" }
    if host.contains("volces") || host.contains("volcengine") || name.contains("豆包") { return "doubao" }
    if host.contains("xiaomimimo") || name.contains("mimo") { return "mimo" }
    if host.contains("deepseek") || name.contains("deepseek") { return "deepseek" }
    if host.contains("minimax") || name.contains("minimax") { return "minimax" }
    if host.contains("generativelanguage") || name.contains("gemini") { return "gemini" }
    if host == "api.openai.com" || name.contains("openai") { return "openai" }
    return customID
  }

  static func authHeaderStyle(for profile: OwlProviderProfile?) -> OwlProviderAuthHeaderStyle {
    guard let profile else { return .bearer }
    let providerID = inferredProviderID(for: profile)
    return preset(id: providerID)?.authHeaderStyle ?? .bearer
  }

  /// 百炼档案不再按型号降级：它整体是 Responses 供应商，来源核验走 `/responses` 的内置
  /// `web_search`，能力属于**平台**而非某个型号。型号真不被服务时上游会拒，那句话如实报给用户，
  /// 比这里先猜一个「辅助检索」更贴近真相。
  static func sourceSupport(for profile: OwlProviderProfile?) -> OwlProviderSourceSupport {
    guard let profile else { return .searchPlanOnly }
    return preset(id: inferredProviderID(for: profile))?.sourceSupport ?? .searchPlanOnly
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
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return nil }

    let candidate: String
    if trimmed.contains("://") {
      guard let url = URL(string: trimmed),
            url.scheme == "https",
            url.user == nil,
            url.password == nil,
            url.port == nil,
            let host = url.host else { return nil }
      candidate = host
    } else {
      guard !trimmed.contains("/"), !trimmed.contains("@"), !trimmed.contains(":") else {
        return nil
      }
      candidate = trimmed.contains(".") ? trimmed : trimmed + beijingHostSuffix
    }

    guard candidate.hasPrefix("ws-"), candidate.hasSuffix(beijingHostSuffix) else { return nil }
    let workspaceID = String(candidate.dropLast(beijingHostSuffix.count))
    guard workspaceID.count > 3,
          workspaceID.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
          }) else { return nil }
    return candidate
  }

  static func responsesEndpoint(for rawValue: String) -> URL? {
    guard let host = normalizedAPIHost(rawValue) else { return nil }
    return URL(string: "https://\(host)/compatible-mode/v1/responses")
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
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      defaults.removeObject(forKey: key)
      return true
    }
    guard let host = OwlQwenWorkspace.normalizedAPIHost(trimmed) else { return false }
    defaults.set(host, forKey: key)
    return true
  }

  static func responsesEndpoint(defaults: UserDefaults = OwlDefaults.standard) -> URL {
    if let endpoint = OwlQwenWorkspace.responsesEndpoint(for: apiHost(defaults: defaults)) {
      return endpoint
    }
    return URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)!
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

  /// Forward-compatible decode: tolerate missing/extra fields (matches `OwlProject`), so a newer
  /// schema can add fields without breaking older readers and vice versa. Only `id` + `endpoint`
  /// are required; a record missing either is treated as malformed and skipped by the store.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let id = try c.decode(String.self, forKey: .id)
    self.id = id
    self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Provider"
    self.kind = try c.decodeIfPresent(OwlProviderKind.self, forKey: .kind) ?? .openAICompatible
    self.endpoint = try c.decode(URL.self, forKey: .endpoint)
    self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
    self.providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
    self.secretName = try c.decodeIfPresent(String.self, forKey: .secretName) ?? Self.defaultSecretName(for: id)
    self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
  }

  /// Secret-name convention: `famo.provider.<id>.apiKey`. Keeps every profile's key under a
  /// distinct Keychain account so multiple providers coexist.
  static func defaultSecretName(for id: String) -> String { "famo.provider.\(id).apiKey" }
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
  static let service = "im.famo.inputmethod.Famo.providers"

  private func baseQuery(name: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: name,
    ]
  }

  func secret(named name: String) throws -> String? {
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
    let status = SecItemDelete(baseQuery(name: name) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OwlProviderKeychainError.unexpectedStatus(status)
    }
  }
}

// MARK: - Store

/// File-backed CRUD for provider profiles, persisted as a single schema-versioned `providers.json`
/// under `~/Library/Application Support/Owltype/`. Clone of `OwlProjectStore`'s pattern (pretty-printed,
/// sorted keys, iso8601, atomic write). `root` is injectable so tests point at a temp dir.
///
/// The default-profile invariant (exactly one `isDefault` when non-empty) is enforced on every
/// mutation, so callers never have to manage it.
final class OwlProviderProfileStore {
  static let shared = OwlProviderProfileStore()
  static let fileName = "providers.json"

  private let root: URL

  init(root: URL = OwlApp.userDir) {
    self.root = root
  }

  var fileURL: URL { root.appendingPathComponent(Self.fileName, isDirectory: false) }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  // MARK: Read

  /// The whole file, or an empty default when the file is missing / malformed (never crashes the
  /// settings page on a corrupt `providers.json`).
  func load() -> OwlProviderProfilesFile {
    guard let data = try? Data(contentsOf: fileURL),
          let file = try? Self.makeDecoder().decode(OwlProviderProfilesFile.self, from: data) else {
      return OwlProviderProfilesFile()
    }
    return file
  }

  /// Profiles in a stable order (createdAt, then id as a same-second tiebreaker).
  func profiles() -> [OwlProviderProfile] {
    load().profiles.sorted {
      $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
    }
  }

  /// The active provider — the single profile flagged `isDefault`, or nil when none configured.
  var defaultProfile: OwlProviderProfile? {
    load().profiles.first { $0.isDefault }
  }

  func profile(id: String) -> OwlProviderProfile? {
    load().profiles.first { $0.id == id }
  }

  // MARK: Write

  private func save(_ profiles: [OwlProviderProfile]) throws {
    try OwlPrivateStorage.prepareDirectory(root)
    let file = OwlProviderProfilesFile(profiles: profiles)
    let data = try Self.makeEncoder().encode(file)
    try data.write(to: fileURL, options: .atomic)
    try OwlPrivateStorage.hardenFile(fileURL)
  }

  /// Force exactly one default when non-empty: prefer `preferred`, else keep the existing default,
  /// else promote the first.
  private func enforcingSingleDefault(
    _ profiles: [OwlProviderProfile],
    preferred: String?
  ) -> [OwlProviderProfile] {
    guard !profiles.isEmpty else { return profiles }
    let defaultID = preferred
      ?? profiles.first(where: { $0.isDefault })?.id
      ?? profiles[0].id
    return profiles.map { var p = $0; p.isDefault = (p.id == defaultID); return p }
  }

  /// Append a profile. A brand-new profile becomes default if it asked to be, or if no profile is
  /// default yet (first-profile case).
  @discardableResult
  func add(_ profile: OwlProviderProfile) throws -> OwlProviderProfile {
    var all = load().profiles
    let prefer = (profile.isDefault || !all.contains { $0.isDefault }) ? profile.id : nil
    all.append(profile)
    let normalized = enforcingSingleDefault(all, preferred: prefer)
    try save(normalized)
    return normalized.first { $0.id == profile.id } ?? profile
  }

  /// Replace an existing profile (by id). Throws `.notFound` for an unknown id. If the incoming
  /// profile is flagged default, it wins the default slot.
  @discardableResult
  func update(_ profile: OwlProviderProfile) throws -> OwlProviderProfile {
    var all = load().profiles
    guard all.contains(where: { $0.id == profile.id }) else { throw OwlProviderError.notFound(profile.id) }
    all = all.map { $0.id == profile.id ? profile : $0 }
    let normalized = enforcingSingleDefault(all, preferred: profile.isDefault ? profile.id : nil)
    try save(normalized)
    return normalized.first { $0.id == profile.id } ?? profile
  }

  /// Delete a profile. If it was the default and others remain, the first is promoted.
  func delete(id: String) throws {
    var all = load().profiles
    all.removeAll { $0.id == id }
    try save(enforcingSingleDefault(all, preferred: nil))
  }

  /// Make `id` the default. Throws `.notFound` for an unknown id.
  func setDefault(id: String) throws {
    let all = load().profiles
    guard all.contains(where: { $0.id == id }) else { throw OwlProviderError.notFound(id) }
    try save(enforcingSingleDefault(all, preferred: id))
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
    guard store.profiles().isEmpty else { return nil }
    let legacyKey = (try? legacyKeyReader())?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let legacyKey, !legacyKey.isEmpty else { return nil }

    let profile = OwlProviderProfile(
      displayName: "DeepSeek",
      kind: .openAICompatible,
      endpoint: legacyEndpoint,
      model: legacyModel,
      providerID: "deepseek",
      isDefault: true
    )
    do {
      try secrets.setSecret(legacyKey, named: profile.secretName)
      return try store.add(profile)
    } catch {
      return nil
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
    let s = endpoint.absoluteString
    if let r = s.range(of: "/chat/completions", options: .backwards) {
      return URL(string: s.replacingCharacters(in: r, with: "/models"))
    }
    return endpoint.deletingLastPathComponent().appendingPathComponent("models")
  }

  /// Model ids from an OpenAI `{ "data": [ { "id": … } ] }` payload, in server order, deduped.
  static func parseModelIDs(_ data: Data) -> [String] {
    struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
    guard let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
    var seen = Set<String>()
    return list.data.map(\.id).filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// Curated models first (the always-available fallback), then any fetched ids not already listed.
  static func merged(curated: [String], fetched: [String]) -> [String] {
    var seen = Set<String>()
    return (curated + fetched).filter { !$0.isEmpty && seen.insert($0).inserted }
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
    /// 连上了但对面拒绝（Key 无效 / 型号不服务 / 欠费）。`message` 是服务端原话。
    case rejected(status: Int, message: String)
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
    let dialect: OwlResponsesDialect? = endpoint.flatMap {
      OwlResponsesWire.dialect(providerID: providerID, model: model, endpoint: $0)
    } ?? { () -> OwlResponsesDialect? in
      // 没有端点可判时只剩 providerID。百炼整体是 Responses 供应商，不看型号；方舟与 DeepSeek
      // 仍看型号，与 `OwlResponsesWire.isArk` / `.isDeepSeek` 的口径一致（那边写了为何不对称，
      // DeepSeek 那道型号闸是因为 `/responses` 目前只收 deepseek-v4-flash）。
      let id = providerID.lowercased()
      if id == "qwen" { return .qwen }
      if id == "doubao", model.lowercased().hasPrefix("doubao") { return .ark }
      if id == "deepseek", model.lowercased().hasPrefix("deepseek-v4-flash") { return .deepseek }
      return nil
    }()
    if let dialect {
      return OwlResponsesWire.body(
        model: model,
        messages: [OwlDeepSeekMessage(role: "user", content: "ping")],
        stream: false,
        dialect: dialect,
        webSearch: false)
    }
    var body: [String: Any] = [
      "model": model,
      "messages": [["role": "user", "content": "ping"]],
      "max_tokens": 16,
      "stream": false,
    ]
    body.merge(OwlThinkingControl.offBody(providerID: providerID, model: model)) { _, off in off }
    return body
  }

  static func request(
    endpoint: URL,
    providerID: String,
    model: String,
    apiKey: String,
    authStyle: OwlProviderAuthHeaderStyle
  ) throws -> URLRequest {
    let usesResponses = OwlResponsesWire.dialect(
      providerID: providerID, model: model, endpoint: endpoint) != nil
    let requestURL = usesResponses
      ? (OwlResponsesWire.url(from: endpoint) ?? endpoint)
      : endpoint
    var req = URLRequest(url: requestURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    authStyle.apply(to: &req, apiKey: apiKey)
    req.timeoutInterval = 20
    req.httpBody = try JSONSerialization.data(
      withJSONObject: body(providerID: providerID, model: model, endpoint: endpoint))
    return req
  }

  /// 响应 → 结论。纯函数，测试不碰网络。
  static func outcome(data: Data, response: URLResponse?, latencyMS: Int) -> Outcome {
    guard let http = response as? HTTPURLResponse else { return .malformed }
    guard (200...299).contains(http.statusCode) else {
      return .rejected(status: http.statusCode, message: errorMessage(in: data))
    }
    // Recognize either protocol shell: Qwen uses Responses `output`; other providers remain chat.
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          root["choices"] != nil || root["output"] != nil else {
      return .malformed
    }
    return .ok(latencyMS: latencyMS)
  }

  /// 从错误正文里挖那句人话。两种壳都认：OpenAI 风格的 `error.message`，
  /// 与 DashScope 原生风格的顶层 `message`。挖不到就留空，由调用方退回纯状态码。
  static func errorMessage(in data: Data) -> String {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return ""
    }
    if let error = root["error"] as? [String: Any],
       let message = error["message"] as? String, !message.isEmpty {
      return message
    }
    if let message = root["message"] as? String, !message.isEmpty { return message }
    return ""
  }

  /// 真打一发。**不 throw**：连不上也是一种结论，调用方要的是一句能显示的话，不是一个错误。
  static func run(
    endpoint: URL,
    providerID: String,
    model: String,
    apiKey: String,
    authStyle: OwlProviderAuthHeaderStyle,
    fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
    clock: () -> Date = Date.init
  ) async -> Outcome {
    let started = clock()
    do {
      let request = try request(
        endpoint: endpoint, providerID: providerID, model: model,
        apiKey: apiKey, authStyle: authStyle)
      let (data, response) = try await fetch(request)
      let elapsed = Int(clock().timeIntervalSince(started) * 1000)
      return outcome(data: data, response: response, latencyMS: elapsed)
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
    case let .rejected(status, message):
      let detail = message.isEmpty ? "" : "：\(message)"
      // 401/403 几乎总是 Key，400/404 几乎总是型号或端点 —— 直接把判断给出来，别让人自己对表。
      let hint = (status == 401 || status == 403)
        ? "（多半是 API Key 无效或没权限）"
        : (status == 400 || status == 404 ? "（多半是这个端点不服务该模型，换个型号再试）" : "")
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
