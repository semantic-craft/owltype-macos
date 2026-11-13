//
//  OwlProviderRegistry.swift
//  法墨输入法 (Owltype) — one unit of provider profile, key and verification marker
//
//  A provider the user configured lives in three stores: the profile in `providers.json`, its key
//  in the Keychain account the profile's `secretName` names, and the verification marker in
//  UserDefaults. Every write that touches more than one of them goes through this registry, so the
//  three stay consistent: a replacement key is staged under an independent name before the profile
//  points at it, and an old key is retired only after the profile write is confirmed and no profile
//  references it any more.
//
//  Results are typed; the settings page maps them to its Chinese copy. Never on the input hot path.
//

import CryptoKit
import Foundation

// MARK: - Verification marker

/// 记下某个 Keychain 账号下的密钥**曾经成功通过一次真实调用**（拉取模型列表或验证连通性）。
///
/// 为什么需要它：设置页原先只能回答「Keychain 里有没有值」，而有值 ≠ 能用 —— 2026-07-27 实机踩到的
/// 就是 Key 已失效（401 invalid_key），设置页仍写「已设置」，用户以为配好了，直到提问失败也
/// 想不到是密钥的问题。存的是**时间戳**，不是密钥本身；密钥被改写或删除时标记随之作废（旧标记配新
/// 密钥就是假验证）。
enum OwlProviderKeyVerification {
  static let key = "OwlProviderKeyVerifiedAt"

  /// secretName → 验证通过的时刻（`timeIntervalSince1970`）。
  private static var table: [String: Double] {
    get { OwlDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
    set { OwlDefaults.standard.set(newValue, forKey: key) }
  }

  static func markVerified(secretName: String, at date: Date = Date()) {
    var next = table
    next[secretName] = date.timeIntervalSince1970
    table = next
  }

  static func verifiedAt(secretName: String) -> Date? {
    guard let stamp = table[secretName] else { return nil }
    return Date(timeIntervalSince1970: stamp)
  }

  /// 密钥变了 / 被删了 → 之前那次验证不再代表当前这把 Key。
  static func clear(secretName: String) {
    var next = table
    next.removeValue(forKey: secretName)
    table = next
  }

  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: key)
  }
}

// MARK: - Registry

final class OwlProviderRegistry {
  let store: OwlProviderProfileStore
  let secrets: OwlSecretStoring
  /// Where the shared Qwen Workspace host is saved (not a secret).
  private let defaults: UserDefaults
  /// Digest of the endpoint and key the last successful probe used. The next save that stores
  /// the same pair marks its key verified; the key itself is never held.
  private let session = try! OwlAppSession("providerRegistry")

  init(
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain(),
    defaults: UserDefaults = OwlDefaults.standard
  ) {
    self.store = store
    self.secrets = secrets
    self.defaults = defaults
  }

  var profiles: [OwlProviderProfile] { store.profiles() }
  var defaultProfile: OwlProviderProfile? { store.defaultProfile }

  /// An operation's outcome together with the profile list to show afterwards.
  struct Change<Outcome: Equatable>: Equatable {
    let outcome: Outcome
    let profiles: [OwlProviderProfile]
  }

  /// The add form as typed. `providerID` is the form's preset id (`customID` for a custom entry);
  /// `qwenWorkspace` is the Workspace input the Qwen endpoint was derived from.
  struct Form: Codable, Equatable {
    var providerID: String
    var displayName: String
    var endpoint: String
    var model: String
    var qwenWorkspace: String? = nil
  }

  // MARK: Rules

  /// The HTTPS check shared by save, model fetch and connectivity probe; scheme is case-insensitive.
  static func isHTTPS(_ url: URL) -> Bool {
    OwlProviderCore.call("isHTTPS", ["scheme": url.scheme ?? ""])
  }

  static func needsReplacementKey(current: OwlProviderProfile, endpoint: URL, key: String) -> Bool {
    OwlProviderHost().required("replacement", ["profile": OwlAppCore.payload(current),
      "endpoint": endpoint.absoluteString, "keyEmpty": normalizedKey(key).isEmpty])
  }

  /// One profile per vendor: a known preset by its provider id, a custom entry by endpoint host.
  static func vendorKey(providerID: String, host: String?) -> String {
    OwlProviderCore.call("vendorKey", ["providerID": providerID, "host": host ?? ""])
  }

  private static func vendorKey(of profile: OwlProviderProfile) -> String {
    vendorKey(providerID: OwlLLMProviderCatalog.inferredProviderID(for: profile), host: profile.endpoint.host)
  }

  // MARK: Key state

  enum KeyState: String, Equatable {
    case missing
    /// The Keychain holds a value that has not yet answered a real call.
    case unverified
    case verified
    case unreadable
  }

  /// Never includes the key itself.
  func keyState(for profile: OwlProviderProfile) -> KeyState {
    let raw: String = host().required("keyState", ["profile": OwlAppCore.payload(profile)])
    return KeyState(rawValue: raw) ?? .unreadable
  }

  func markVerified(_ profile: OwlProviderProfile) {
    OwlProviderKeyVerification.markVerified(secretName: profile.secretName)
  }

  // MARK: Probe

  enum ProbeKey: Equatable {
    case key(String)
    case missing
    case needsReplacementKey
  }

  /// The key 「拉取最新」 and 「验证连通性」 send: the typed key, else the editing profile's stored
  /// key when the endpoint keeps its origin. Cross-origin probes never read the Keychain.
  func probeKey(editing profile: OwlProviderProfile?, endpoint: URL, typedKey: String) -> ProbeKey {
    let native = host(key: Self.normalizedKey(typedKey))
    let result: Reply = native.required("probeKey", ["profile": profile.map(OwlAppCore.payload) ?? NSNull(),
      "endpoint": endpoint.absoluteString, "keyEmpty": native.keys["typed"]?.isEmpty ?? true])
    switch result.outcome {
    case "key": return .key(native.keys[result.reference ?? ""] ?? "")
    case "needsReplacementKey": return .needsReplacementKey
    default: return .missing
    }
  }

  /// A probe with this endpoint and key got a real answer. A saved profile that already stores
  /// exactly this pair is marked now; otherwise the next save of the pair is.
  func probeSucceeded(endpoint: URL, key: String, editing profile: OwlProviderProfile?) {
    let _: Bool = host(key: key).required("probeSucceeded", ["endpoint": endpoint.absoluteString,
      "profile": profile.map(OwlAppCore.payload) ?? NSNull()])
  }

  // MARK: Add

  enum UpsertOutcome: Equatable {
    case added(OwlProviderProfile)
    case blankName
    case insecureEndpoint
    case invalidWorkspace
    case failed
  }

  /// Add a provider and drop the earlier profile of the same vendor in the same file write. The
  /// key is staged first; the replaced profiles' keys are retired only after the write is
  /// confirmed, so a failed add leaves the previous provider and its key as they were.
  func upsert(_ form: Form, key rawKey: String, makeDefault: Bool = true) -> Change<UpsertOutcome> {
    let result = perform("upsert", ["form": OwlAppCore.payload(form), "makeDefault": makeDefault], key: rawKey)
    let outcome: UpsertOutcome
    switch result.outcome {
    case "added": outcome = result.profile.map(UpsertOutcome.added) ?? .failed
    case "blankName": outcome = .blankName
    case "insecureEndpoint": outcome = .insecureEndpoint
    case "invalidWorkspace": outcome = .invalidWorkspace
    default: outcome = .failed
    }
    return Change(outcome: outcome, profiles: result.profiles ?? [])
  }

  // MARK: Edit

  enum EditOutcome: Equatable {
    case saved(OwlProviderProfile)
    case insecureEndpoint
    case needsReplacementKey
    case failed
  }

  /// Edit the persisted profile in place. A blank key keeps the stored one, allowed only within
  /// the same origin; a typed key gets an independent name committed together with the endpoint.
  func replaceEndpoint(
    of profile: OwlProviderProfile,
    endpoint: String,
    model: String,
    key rawKey: String,
    qwenWorkspace: String? = nil
  ) -> Change<EditOutcome> {
    let result = perform("replace", ["profile": OwlAppCore.payload(profile), "endpoint": endpoint,
      "model": model, "qwenWorkspace": qwenWorkspace as Any? ?? NSNull()], key: rawKey)
    let outcome: EditOutcome
    switch result.outcome {
    case "saved": outcome = result.profile.map(EditOutcome.saved) ?? .failed
    case "insecureEndpoint": outcome = .insecureEndpoint
    case "needsReplacementKey": outcome = .needsReplacementKey
    default: outcome = .failed
    }
    return Change(outcome: outcome, profiles: result.profiles ?? [])
  }

  // MARK: Qwen Workspace

  enum WorkspaceOutcome: Equatable {
    case saved(cleared: Bool)
    case invalidInput
    case needsReplacementKey
    case failed
  }

  /// Save the shared Qwen Workspace host and move every Qwen profile onto its Responses endpoint
  /// in one file write, so profiles added at different times never drift to different workspaces.
  func applyQwenWorkspace(_ input: String, key rawKey: String) -> Change<WorkspaceOutcome> {
    let result = perform("applyWorkspace", ["input": input], key: rawKey)
    let outcome: WorkspaceOutcome
    switch result.outcome {
    case "saved": outcome = .saved(cleared: result.cleared ?? false)
    case "invalidInput": outcome = .invalidInput
    case "needsReplacementKey": outcome = .needsReplacementKey
    default: outcome = .failed
    }
    return Change(outcome: outcome, profiles: result.profiles ?? [])
  }

  // MARK: Default and delete

  enum DefaultOutcome: Equatable {
    case set(OwlProviderProfile)
    /// A retired provider must be edited into a current one before it can route requests.
    case needsEdit
    case failed
  }

  func setDefault(_ profile: OwlProviderProfile) -> Change<DefaultOutcome> {
    let result = perform("setDefault", ["profile": OwlAppCore.payload(profile)])
    let outcome: DefaultOutcome
    switch result.outcome {
    case "set": outcome = .set(profile)
    case "needsEdit": outcome = .needsEdit
    default: outcome = .failed
    }
    return Change(outcome: outcome, profiles: result.profiles ?? [])
  }

  enum DeleteOutcome: Equatable {
    case deleted(OwlProviderProfile)
    case failed
  }

  /// Delete a profile, then its key and marker unless another profile still names that key.
  func delete(_ profile: OwlProviderProfile) -> Change<DeleteOutcome> {
    let result = perform("remove", ["profile": OwlAppCore.payload(profile)])
    return Change(outcome: result.outcome == "deleted" ? .deleted(profile) : .failed, profiles: result.profiles ?? [])
  }

  private struct Reply: Decodable {
    let outcome: String
    let profile: OwlProviderProfile?
    let profiles: [OwlProviderProfile]?
    let reference: String?
    let cleared: Bool?
  }
  private static func normalizedKey(_ key: String) -> String {
    OwlProviderCore.call("trim", ["text": key])
  }
  private func host(key: String = "") -> OwlProviderHost {
    OwlProviderHost(store: store, secrets: secrets, defaults: defaults, session: session, key: key)
  }
  private func perform(_ operation: String, _ args: [String: Any], key: String = "") -> Reply {
    let native = host(key: Self.normalizedKey(key))
    var args = args; args["keyEmpty"] = native.keys["typed"]?.isEmpty ?? true
    do { return try native.call(operation, args) }
    catch { return Reply(outcome: "failed", profile: nil, profiles: profiles, reference: nil, cleared: nil) }
  }

}

/// Raw native effects for synchronous Rust provider transactions. Keys stay in this call's
/// native reference table; neither the profile JSON nor Rust session state contains them.
final class OwlProviderHost {
  let store: OwlProviderProfileStore?
  let secrets: OwlSecretStoring?
  let defaults: UserDefaults
  let session: OwlAppSession?
  var keys: [String: String] = [:]
  private var errors: [String: Error] = [:]
  private var responseBuffer: UnsafeMutablePointer<CChar>?
  private var wroteProfiles = false
  init(store: OwlProviderProfileStore? = nil, secrets: OwlSecretStoring? = nil,
       defaults: UserDefaults = OwlDefaults.standard, session: OwlAppSession? = nil, key: String = "") {
    self.store = store; self.secrets = secrets; self.defaults = defaults; self.session = session
    keys["typed"] = key
  }
  deinit { free(responseBuffer) }
  private struct Envelope<T: Decodable>: Decodable { let result: T }
  private struct Response<T: Decodable>: Decodable { let ok: Bool; let value: Envelope<T>?; let error: String? }
  func call<T: Decodable>(_ operation: String, _ args: [String: Any] = [:]) throws -> T {
    defer {
      if wroteProfiles, store === OwlProviderProfileStore.shared {
        wroteProfiles = false
        NotificationCenter.default.post(name: OwlProviderProfileStore.configurationDidChange, object: nil)
      }
    }
    let bytes = try JSONSerialization.data(withJSONObject: ["operation": "provider_" + operation, "args": args])
    let pointer = bytes.withUnsafeBytes { buffer in
      owl_msime_host_effect_call(OwlAppCore.abiVersion, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count,
        Unmanaged.passUnretained(self).toOpaque()) { context, request in
          guard let context, let request else { return nil }
          return Unmanaged<OwlProviderHost>.fromOpaque(context).takeUnretainedValue().respond(request)
        }
    }
    guard let pointer else { throw OwlAppCore.Failure(code: "missing_response") }
    defer { owl_msime_string_free(pointer) }
    let response = try JSONDecoder().decode(Response<T>.self, from: Data(bytes: pointer, count: strlen(pointer)))
    guard response.ok, let value = response.value else {
      let code = response.error ?? "invalid_response"
      if let error = errors[code] { throw error }
      if code.hasPrefix("provider_notFound:") { throw OwlProviderError.notFound(String(code.dropFirst(18))) }
      throw OwlAppCore.Failure(code: code)
    }
    return value.result
  }
  func required<T: Decodable>(_ operation: String, _ args: [String: Any] = [:]) -> T {
    do { return try call(operation, args) } catch { preconditionFailure("Incompatible provider core ABI") }
  }
  private func respond(_ request: UnsafePointer<CChar>) -> UnsafePointer<CChar>? {
    let response: [String: Any]
    do {
      let raw = try JSONSerialization.jsonObject(with: Data(bytes: request, count: strlen(request))) as? [String: Any] ?? [:]
      let value = try effect(raw["operation"] as? String ?? "", raw["args"] as? [String: Any] ?? [:])
      response = ["ok": true, "value": value]
    } catch {
      let token = "native_error_\(errors.count)"; errors[token] = error
      response = ["ok": false, "error": token]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: response), let text = String(data: data, encoding: .utf8) else { return nil }
    free(responseBuffer); responseBuffer = strdup(text)
    return responseBuffer.map { UnsafePointer($0) }
  }
  private func effect(_ operation: String, _ args: [String: Any]) throws -> Any {
    switch operation {
    case "provider_read", "provider_write": return try fileEffect(operation, args)
    case "date_parse", "date_format", "url_facts", "uuid", "now": return try factEffect(operation, args)
    case "secret_read", "secret_write", "secret_delete", "key_digest": return try keyEffect(operation, args)
    default: return try preferenceEffect(operation, args)
    }
  }
  private func fileEffect(_ operation: String, _ args: [String: Any]) throws -> Any {
    switch operation {
    case "provider_read":
      guard let store else { throw OwlAppCore.Failure(code: "missing_store") }
      do { return Array(try Data(contentsOf: store.fileURL)) }
      catch let error as CocoaError where error.code == .fileReadNoSuchFile { return NSNull() }
    case "provider_write":
      guard let store else { throw OwlAppCore.Failure(code: "missing_store") }
      try store.beforeSave?()
      try OwlPrivateStorage.prepareDirectory(store.fileURL.deletingLastPathComponent())
      try Data(args["bytes"] as? [UInt8] ?? []).write(to: store.fileURL, options: .atomic)
      wroteProfiles = true
      try store.afterAtomicWrite?()
      try OwlPrivateStorage.hardenFile(store.fileURL)
      return true
    default: throw OwlAppCore.Failure(code: "unknown_provider_effect")
    }
  }
  private func factEffect(_ operation: String, _ args: [String: Any]) throws -> Any {
    switch operation {
    case "date_parse":
      guard let text = args["text"] as? String,
            let date = ISO8601DateFormatter().date(from: text) else { throw OwlAppCore.Failure(code: "invalid_date") }
      return date.timeIntervalSinceReferenceDate
    case "date_format":
      return ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: args["value"] as? Double ?? 0))
    case "url_facts":
      guard let url = URL(string: args["text"] as? String ?? "") else { return NSNull() }
      return ["absolute": url.absoluteString, "scheme": url.scheme ?? "", "host": url.host ?? "",
              "port": url.port as Any? ?? NSNull(), "hasUser": url.user != nil, "hasPassword": url.password != nil]
    case "uuid": return UUID().uuidString
    case "now": return Date().timeIntervalSinceReferenceDate
    default: throw OwlAppCore.Failure(code: "unknown_provider_effect")
    }
  }
  private func keyEffect(_ operation: String, _ args: [String: Any]) throws -> Any {
    let name = args["name"] as? String ?? ""
    switch operation {
    case "secret_read":
      guard let value = try secrets?.secret(named: name), !value.isEmpty else { return NSNull() }
      let reference = "read_\(keys.count)"; keys[reference] = value; return reference
    case "secret_write":
      guard let value = keys[args["reference"] as? String ?? ""], let secrets else { throw OwlAppCore.Failure(code: "missing_key_reference") }
      try secrets.setSecret(value, named: name); return true
    case "secret_delete": try secrets?.deleteSecret(named: name); return true
    case "key_digest":
      guard let value = keys[args["reference"] as? String ?? ""] else { return NSNull() }
      return SHA256.hash(data: Data(((args["endpoint"] as? String ?? "") + "\n" + value).utf8)).map { String(format: "%02x", $0) }.joined()
    default: throw OwlAppCore.Failure(code: "unknown_provider_effect")
    }
  }
  private func preferenceEffect(_ operation: String, _ args: [String: Any]) throws -> Any {
    let name = args["name"] as? String ?? ""
    switch operation {
    case "verification_clear": OwlProviderKeyVerification.clear(secretName: name); return true
    case "verification_mark": OwlProviderKeyVerification.markVerified(secretName: name); return true
    case "verification_get": return OwlProviderKeyVerification.verifiedAt(secretName: name)?.timeIntervalSince1970 as Any? ?? NSNull()
    case "workspace_write":
      let host = args["host"] as? String ?? ""
      if host.isEmpty { defaults.removeObject(forKey: OwlQwenWorkspaceSettings.key) }
      else { defaults.set(host, forKey: OwlQwenWorkspaceSettings.key) }
      return true
    case "probe_set":
      let result: Bool = session?.call("set", ["digest": args["digest"] ?? NSNull()]) ?? false
      return result
    case "probe_take":
      struct Probe: Decodable { let digest: String? }
      let value: Probe? = session?.call("take")
      return value?.digest as Any? ?? NSNull()
    default: throw OwlAppCore.Failure(code: "unknown_provider_effect")
    }
  }
}
