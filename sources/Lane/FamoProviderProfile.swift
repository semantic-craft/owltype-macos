//
//  FamoProviderProfile.swift
//  法墨输入法 (Famo) — multi-provider profile foundation
//  (task 06-22-famo-multi-provider-keychain-foundation, research B1+B2)
//
//  Turns the single hardcoded DeepSeek cloud config into a list of named provider PROFILES.
//  Each profile holds endpoint / model and a `secretName` — the Keychain account
//  the API key lives under. The key is NEVER stored in the profile JSON, UserDefaults, or logs;
//  `providers.json` is safe to inspect / back up. Storage follows Famo's existing file-store idiom.
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
enum FamoProviderKind: String, Codable, CaseIterable, Sendable {
  case openAICompatible = "openai_compatible"

  var displayName: String {
    switch self {
    case .openAICompatible: return "OpenAI 兼容"
    }
  }
}

enum FamoProviderAuthHeaderStyle: String, Codable, Sendable, Equatable {
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

enum FamoProviderSourceSupport: String, Codable, Sendable, Equatable {
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

struct FamoLLMProviderPreset: Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let endpoint: String
  let model: String
  let keyHint: String
  let sourceSupport: FamoProviderSourceSupport
  let authHeaderStyle: FamoProviderAuthHeaderStyle
}

enum FamoLLMProviderCatalog {
  static let presets: [FamoLLMProviderPreset] = [
    FamoLLMProviderPreset(
      id: "qwen",
      displayName: "阿里云百炼",
      endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
      model: "qwen3.6-flash",
      keyHint: "按量付费 sk-…；Token Plan 请改用 token-plan.cn-beijing.maas.aliyuncs.com",
      sourceSupport: .sourceResults,
      authHeaderStyle: .bearer
    ),
    FamoLLMProviderPreset(
      id: "doubao",
      displayName: "火山引擎 · 豆包 Seed",
      endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: "doubao-seed-2-1-turbo-260628",
      keyHint: "火山方舟 API Key",
      sourceSupport: .sourceResults,
      authHeaderStyle: .bearer
    ),
    FamoLLMProviderPreset(
      id: "mimo",
      displayName: "小米 MiMo",
      endpoint: "https://api.xiaomimimo.com/v1/chat/completions",
      model: "mimo-v2.5",
      keyHint: "按量付费 sk-…；Token Plan 填 tp-…",
      sourceSupport: .sourceResults,
      authHeaderStyle: .apiKey
    ),
    FamoLLMProviderPreset(
      id: "zhipu",
      displayName: "智谱 GLM",
      endpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
      model: "glm-5-turbo",
      keyHint: "智谱 API Key",
      sourceSupport: .sourceResults,
      authHeaderStyle: .bearer
    ),
    FamoLLMProviderPreset(
      id: "deepseek",
      displayName: "DeepSeek",
      endpoint: "https://api.deepseek.com/v1/chat/completions",
      model: "deepseek-v4-flash",
      keyHint: "sk-…",
      sourceSupport: .searchPlanOnly,
      authHeaderStyle: .bearer
    ),
    FamoLLMProviderPreset(
      id: "minimax",
      displayName: "MiniMax",
      endpoint: "https://api.minimaxi.com/v1/chat/completions",
      model: "MiniMax-M2.7-highspeed",
      keyHint: "MiniMax API Key",
      sourceSupport: .searchPlanOnly,
      authHeaderStyle: .bearer
    ),
    FamoLLMProviderPreset(
      id: "gemini",
      displayName: "Google Gemini",
      endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      model: "gemini-3.5-flash-lite",
      keyHint: "AIza…",
      sourceSupport: .searchPlanOnly,
      authHeaderStyle: .bearer
    ),
    FamoLLMProviderPreset(
      id: "openai",
      displayName: "OpenAI",
      endpoint: "https://api.openai.com/v1/chat/completions",
      model: "chat-latest",
      keyHint: "sk-…",
      sourceSupport: .sourceResults,
      authHeaderStyle: .bearer
    ),
  ]

  static let customID = "custom"

  static func preset(id: String?) -> FamoLLMProviderPreset? {
    guard let id else { return nil }
    return presets.first { $0.id == id }
  }

  static func inferredProviderID(for profile: FamoProviderProfile?) -> String {
    guard let profile else { return "deepseek" }
    if let stored = profile.providerID, !stored.isEmpty { return stored }
    let host = profile.endpoint.host?.lowercased() ?? ""
    let name = profile.displayName.lowercased()
    if host.contains("dashscope") || host.contains("aliyuncs") || name.contains("百炼") || name.contains("qwen") { return "qwen" }
    if host.contains("volces") || host.contains("volcengine") || name.contains("豆包") { return "doubao" }
    if host.contains("xiaomimimo") || name.contains("mimo") { return "mimo" }
    if host.contains("bigmodel") || name.contains("智谱") || name.contains("glm") { return "zhipu" }
    if host.contains("deepseek") || name.contains("deepseek") { return "deepseek" }
    if host.contains("minimax") || name.contains("minimax") { return "minimax" }
    if host.contains("generativelanguage") || name.contains("gemini") { return "gemini" }
    if host == "api.openai.com" || name.contains("openai") { return "openai" }
    return customID
  }

  static func authHeaderStyle(for profile: FamoProviderProfile?) -> FamoProviderAuthHeaderStyle {
    guard let profile else { return .bearer }
    let providerID = inferredProviderID(for: profile)
    return preset(id: providerID)?.authHeaderStyle ?? .bearer
  }

  static func sourceSupport(for profile: FamoProviderProfile?) -> FamoProviderSourceSupport {
    guard let profile else { return .searchPlanOnly }
    let providerID = inferredProviderID(for: profile)
    return preset(id: providerID)?.sourceSupport ?? .searchPlanOnly
  }
}

// MARK: - Errors

enum FamoProviderError: LocalizedError, Equatable {
  case emptyName
  case notFound(String)

  var errorDescription: String? {
    switch self {
    case .emptyName: return "供应商名称不能为空。"
    case let .notFound(id): return "未找到供应商配置（\(id)）。"
    }
  }
}

enum FamoProviderKeychainError: Error, Equatable {
  case unexpectedStatus(OSStatus)
}

// MARK: - Profile model

/// One named cloud provider configuration. `secretName` is the Keychain account the key lives
/// under — the key itself never appears in this struct or in `providers.json`.
struct FamoProviderProfile: Codable, Identifiable, Equatable, Sendable {
  let id: String
  var displayName: String
  var kind: FamoProviderKind
  var endpoint: URL
  var model: String
  var providerID: String?
  var secretName: String
  var isDefault: Bool
  var createdAt: Date

  init(
    id: String = UUID().uuidString,
    displayName: String,
    kind: FamoProviderKind = .openAICompatible,
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

  /// Forward-compatible decode: tolerate missing/extra fields (matches `FamoProject`), so a newer
  /// schema can add fields without breaking older readers and vice versa. Only `id` + `endpoint`
  /// are required; a record missing either is treated as malformed and skipped by the store.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let id = try c.decode(String.self, forKey: .id)
    self.id = id
    self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Provider"
    self.kind = try c.decodeIfPresent(FamoProviderKind.self, forKey: .kind) ?? .openAICompatible
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
struct FamoProviderProfilesFile: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var profiles: [FamoProviderProfile]

  init(schemaVersion: Int = currentSchemaVersion, profiles: [FamoProviderProfile] = []) {
    self.schemaVersion = schemaVersion
    self.profiles = profiles
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
    self.profiles = try c.decodeIfPresent([FamoProviderProfile].self, forKey: .profiles) ?? []
  }
}

// MARK: - Secret store

/// Narrow secret port so the migration / fetcher can be unit-tested with an in-memory fake instead
/// of the real Keychain (mirrors how `FamoSelectionPolishService` injects its `apiKeyProvider`).
protocol FamoSecretStoring {
  func secret(named name: String) throws -> String?
  func setSecret(_ value: String, named name: String) throws
  func deleteSecret(named name: String) throws
}

/// Live Keychain impl, keyed on the profile's `secretName`. Same upsert + not-found handling as
/// `FamoCloudKeychain`, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (device-only,
/// survives reboot, never synced to iCloud).
struct FamoProviderKeychain: FamoSecretStoring {
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
    guard status == errSecSuccess else { throw FamoProviderKeychainError.unexpectedStatus(status) }
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
      throw FamoProviderKeychainError.unexpectedStatus(updateStatus)
    }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw FamoProviderKeychainError.unexpectedStatus(addStatus)
    }
  }

  func deleteSecret(named name: String) throws {
    let status = SecItemDelete(baseQuery(name: name) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw FamoProviderKeychainError.unexpectedStatus(status)
    }
  }
}

// MARK: - Store

/// File-backed CRUD for provider profiles, persisted as a single schema-versioned `providers.json`
/// under `~/Library/Application Support/Famo/`. Clone of `FamoProjectStore`'s pattern (pretty-printed,
/// sorted keys, iso8601, atomic write). `root` is injectable so tests point at a temp dir.
///
/// The default-profile invariant (exactly one `isDefault` when non-empty) is enforced on every
/// mutation, so callers never have to manage it.
final class FamoProviderProfileStore {
  static let shared = FamoProviderProfileStore()
  static let fileName = "providers.json"

  private let root: URL

  init(root: URL = FamoApp.userDir) {
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
  func load() -> FamoProviderProfilesFile {
    guard let data = try? Data(contentsOf: fileURL),
          let file = try? Self.makeDecoder().decode(FamoProviderProfilesFile.self, from: data) else {
      return FamoProviderProfilesFile()
    }
    return file
  }

  /// Profiles in a stable order (createdAt, then id as a same-second tiebreaker).
  func profiles() -> [FamoProviderProfile] {
    load().profiles.sorted {
      $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
    }
  }

  /// The active provider — the single profile flagged `isDefault`, or nil when none configured.
  var defaultProfile: FamoProviderProfile? {
    load().profiles.first { $0.isDefault }
  }

  func profile(id: String) -> FamoProviderProfile? {
    load().profiles.first { $0.id == id }
  }

  // MARK: Write

  private func save(_ profiles: [FamoProviderProfile]) throws {
    try FamoPrivateStorage.prepareDirectory(root)
    let file = FamoProviderProfilesFile(profiles: profiles)
    let data = try Self.makeEncoder().encode(file)
    try data.write(to: fileURL, options: .atomic)
    try FamoPrivateStorage.hardenFile(fileURL)
  }

  /// Force exactly one default when non-empty: prefer `preferred`, else keep the existing default,
  /// else promote the first.
  private func enforcingSingleDefault(
    _ profiles: [FamoProviderProfile],
    preferred: String?
  ) -> [FamoProviderProfile] {
    guard !profiles.isEmpty else { return profiles }
    let defaultID = preferred
      ?? profiles.first(where: { $0.isDefault })?.id
      ?? profiles[0].id
    return profiles.map { var p = $0; p.isDefault = (p.id == defaultID); return p }
  }

  /// Append a profile. A brand-new profile becomes default if it asked to be, or if no profile is
  /// default yet (first-profile case).
  @discardableResult
  func add(_ profile: FamoProviderProfile) throws -> FamoProviderProfile {
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
  func update(_ profile: FamoProviderProfile) throws -> FamoProviderProfile {
    var all = load().profiles
    guard all.contains(where: { $0.id == profile.id }) else { throw FamoProviderError.notFound(profile.id) }
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
    guard all.contains(where: { $0.id == id }) else { throw FamoProviderError.notFound(id) }
    try save(enforcingSingleDefault(all, preferred: id))
  }
}

// MARK: - Legacy migration

/// One-shot, idempotent migration of the legacy single-DeepSeek setup into a default profile.
/// Runs only when there are no profiles yet AND a legacy DeepSeek key is actually present (a fresh
/// install just has no providers; the user adds one in settings). The legacy key is copied into the
/// new per-profile `secretName`; the old `FamoCloudKeychain` entry is left intact as a fallback.
enum FamoProviderMigration {
  @discardableResult
  static func migrateLegacyDeepSeekIfNeeded(
    store: FamoProviderProfileStore = .shared,
    secrets: FamoSecretStoring = FamoProviderKeychain(),
    legacyKeyReader: () throws -> String? = FamoCloudKeychain.readDeepSeekAPIKey,
    legacyEndpoint: URL = FamoCloudPreferences.deepSeekEndpoint,
    legacyModel: String = FamoCloudPreferences.deepSeekModel
  ) -> FamoProviderProfile? {
    guard store.profiles().isEmpty else { return nil }
    let legacyKey = (try? legacyKeyReader())?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let legacyKey, !legacyKey.isEmpty else { return nil }

    let profile = FamoProviderProfile(
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
/// `LLMModelPresetFilter`, Famo-sized.
enum FamoProviderModelList {
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
    authStyle: FamoProviderAuthHeaderStyle
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
