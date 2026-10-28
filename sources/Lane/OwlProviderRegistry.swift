//
//  OwlProviderRegistry.swift
//  猫头鹰输入法 (Owltype) — one unit of provider profile, key and verification marker
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
  private var probedPair: SHA256Digest?

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
  struct Form: Equatable {
    var providerID: String
    var displayName: String
    var endpoint: String
    var model: String
    var qwenWorkspace: String? = nil
  }

  // MARK: Rules

  /// The HTTPS check shared by save, model fetch and connectivity probe; scheme is case-insensitive.
  static func isHTTPS(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
  }

  private static func origin(_ url: URL) -> (String?, String?, Int?) {
    let scheme = url.scheme?.lowercased()
    let port: Int? = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    return (scheme, url.host?.lowercased(), port)
  }

  /// A stored key may follow its profile only within the same scheme, host and port. Moving to
  /// another origin needs a key the user typed for it, so the old key never reaches a new server.
  static func needsReplacementKey(current: OwlProviderProfile, endpoint: URL, key: String) -> Bool {
    key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && origin(endpoint) != origin(current.endpoint)
  }

  /// One profile per vendor: a known preset by its provider id, a custom entry by endpoint host.
  static func vendorKey(providerID: String, host: String?) -> String {
    providerID.isEmpty || providerID == OwlLLMProviderCatalog.customID
      ? "host:\(host ?? "")"
      : "id:\(providerID)"
  }

  private static func vendorKey(of profile: OwlProviderProfile) -> String {
    vendorKey(providerID: OwlLLMProviderCatalog.inferredProviderID(for: profile), host: profile.endpoint.host)
  }

  // MARK: Key state

  enum KeyState: Equatable {
    case missing
    /// The Keychain holds a value that has not yet answered a real call.
    case unverified
    case verified
    case unreadable
  }

  /// Never includes the key itself.
  func keyState(for profile: OwlProviderProfile) -> KeyState {
    do {
      guard try secrets.secret(named: profile.secretName)?.isEmpty == false else { return .missing }
      return OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName) == nil
        ? .unverified : .verified
    } catch {
      return .unreadable
    }
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
    let typed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard typed.isEmpty else { return .key(typed) }
    guard let profile else { return .missing }
    let current = store.profile(id: profile.id) ?? profile
    if Self.needsReplacementKey(current: current, endpoint: endpoint, key: typed) {
      return .needsReplacementKey
    }
    guard let stored = try? secrets.secret(named: current.secretName), !stored.isEmpty else {
      return .missing
    }
    return .key(stored)
  }

  /// A probe with this endpoint and key got a real answer. A saved profile that already stores
  /// exactly this pair is marked now; otherwise the next save of the pair is.
  func probeSucceeded(endpoint: URL, key: String, editing profile: OwlProviderProfile?) {
    probedPair = Self.digest(endpoint: endpoint, key: key)
    guard let profile, let current = store.profile(id: profile.id), current.endpoint == endpoint,
          (try? secrets.secret(named: current.secretName)) == key else { return }
    markVerified(current)
  }

  private static func digest(endpoint: URL, key: String) -> SHA256Digest {
    SHA256.hash(data: Data((endpoint.absoluteString + "\n" + key).utf8))
  }

  /// Marks `saved` verified when a probe already proved the endpoint and key it now stores.
  private func applyProbe(to saved: OwlProviderProfile, typedKey: String) {
    guard let probed = probedPair else { return }
    probedPair = nil
    let key = typedKey.isEmpty ? ((try? secrets.secret(named: saved.secretName)) ?? nil) : typedKey
    guard let key, !key.isEmpty, Self.digest(endpoint: saved.endpoint, key: key) == probed else { return }
    markVerified(saved)
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
    let name = form.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return Change(outcome: .blankName, profiles: profiles) }
    guard let url = URL(string: form.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
          Self.isHTTPS(url) else {
      return Change(outcome: .insecureEndpoint, profiles: profiles)
    }
    var commitWorkspace: (() -> Void)?
    if form.providerID == "qwen", let workspace = form.qwenWorkspace {
      guard let commit = OwlQwenWorkspaceSettings.prepareSave(workspace, defaults: defaults) else {
        return Change(outcome: .invalidWorkspace, profiles: profiles)
      }
      commitWorkspace = commit
    }
    let profile = OwlProviderProfile(
      displayName: name,
      endpoint: url,
      model: form.model.trimmingCharacters(in: .whitespacesAndNewlines),
      providerID: form.providerID.isEmpty ? nil : form.providerID,
      isDefault: makeDefault
    )
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let vendor = Self.vendorKey(providerID: form.providerID, host: url.host)
    let replaced = profiles.filter { Self.vendorKey(of: $0) == vendor }
    let outcome = commit(
      staging: key.isEmpty ? [] : [(profile.secretName, key)],
      expecting: [profile],
      replacing: replaced,
      write: { try self.store.add(profile, replacing: replaced.map(\.id)) })
    guard case let .committed(saved) = outcome,
          let added = saved.first(where: { $0.id == profile.id }) else {
      return Change(outcome: .failed, profiles: profiles)
    }
    commitWorkspace?()
    applyProbe(to: added, typedKey: key)
    return Change(outcome: .added(added), profiles: profiles)
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
    guard let current = store.profile(id: profile.id) else {
      return Change(outcome: .failed, profiles: profiles)
    }
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return Change(outcome: .insecureEndpoint, profiles: profiles)
    }
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if Self.needsReplacementKey(current: current, endpoint: url, key: key) {
      return Change(outcome: .needsReplacementKey, profiles: profiles)
    }
    guard Self.isHTTPS(url) else { return Change(outcome: .insecureEndpoint, profiles: profiles) }
    let commitWorkspace = qwenWorkspace.flatMap {
      OwlQwenWorkspaceSettings.prepareSave($0, defaults: defaults)
    }
    var updated = current
    if !OwlLLMProviderCatalog.isKnownProviderID(OwlLLMProviderCatalog.inferredProviderID(for: current)) {
      updated.providerID = OwlLLMProviderCatalog.customID
    }
    updated.endpoint = url
    updated.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    var staging: [(name: String, key: String)] = []
    if !key.isEmpty {
      updated.secretName = OwlProviderProfile.defaultSecretName(for: UUID().uuidString)
      staging = [(updated.secretName, key)]
    }
    let target = updated
    let outcome = commit(
      staging: staging,
      expecting: [target],
      replacing: key.isEmpty ? [] : [current],
      write: {
        _ = try self.store.update(target)
        return self.store.profiles()
      })
    // A write that threw after landing is still reported as failed; both keys stay, and the
    // retry refreshes its profile from the returned list.
    guard case .committed = outcome else { return Change(outcome: .failed, profiles: profiles) }
    commitWorkspace?()
    applyProbe(to: target, typedKey: key)
    return Change(outcome: .saved(target), profiles: profiles)
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
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let commitWorkspace = OwlQwenWorkspaceSettings.prepareSave(trimmed, defaults: defaults),
          let endpoint = trimmed.isEmpty
            ? URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)
            : OwlQwenWorkspace.responsesEndpoint(for: trimmed) else {
      return Change(outcome: .invalidInput, profiles: profiles)
    }
    guard let all = store.readableProfiles() else { return Change(outcome: .failed, profiles: profiles) }
    let qwen = all.filter { OwlLLMProviderCatalog.inferredProviderID(for: $0) == "qwen" }
    if qwen.contains(where: { Self.needsReplacementKey(current: $0, endpoint: endpoint, key: key) }) {
      return Change(outcome: .needsReplacementKey, profiles: profiles)
    }
    // Asking with an empty key names the profiles whose origin changes.
    let changing = qwen.filter { Self.needsReplacementKey(current: $0, endpoint: endpoint, key: "") }
    var staging: [(name: String, key: String)] = []
    let updated = qwen.map { profile -> OwlProviderProfile in
      var next = profile
      next.endpoint = endpoint
      if changing.contains(where: { $0.id == profile.id }) {
        // Independent names keep deleting one profile from removing another profile's key.
        next.secretName = OwlProviderProfile.defaultSecretName(for: UUID().uuidString)
        staging.append((next.secretName, key))
      }
      return next
    }
    let outcome = commit(
      staging: staging, expecting: updated, replacing: changing,
      write: { try self.store.update(updated) })
    let saved: [OwlProviderProfile]
    switch outcome {
    case let .committed(profiles):
      saved = profiles
    case let .landedAfterError(profiles):
      // The batch is on disk; finish it like a clean commit.
      settle(staged: staging.map(\.name), replacing: changing, in: profiles)
      saved = profiles
    case .notCommitted:
      return Change(outcome: .failed, profiles: profiles)
    }
    commitWorkspace()
    return Change(outcome: .saved(cleared: trimmed.isEmpty), profiles: Self.sorted(saved))
  }

  // MARK: Default and delete

  enum DefaultOutcome: Equatable {
    case set(OwlProviderProfile)
    /// A retired provider must be edited into a current one before it can route requests.
    case needsEdit
    case failed
  }

  func setDefault(_ profile: OwlProviderProfile) -> Change<DefaultOutcome> {
    guard OwlLLMProviderCatalog.isKnownProviderID(OwlLLMProviderCatalog.inferredProviderID(for: profile)) else {
      return Change(outcome: .needsEdit, profiles: profiles)
    }
    do {
      try store.setDefault(id: profile.id)
      return Change(outcome: .set(profile), profiles: profiles)
    } catch {
      return Change(outcome: .failed, profiles: profiles)
    }
  }

  enum DeleteOutcome: Equatable {
    case deleted(OwlProviderProfile)
    case failed
  }

  /// Delete a profile, then its key and marker unless another profile still names that key.
  func delete(_ profile: OwlProviderProfile) -> Change<DeleteOutcome> {
    do {
      try store.delete(id: profile.id)
    } catch {
      return Change(outcome: .failed, profiles: profiles)
    }
    let remaining = profiles
    settle(staged: [], replacing: [profile], in: remaining)
    return Change(outcome: .deleted(profile), profiles: remaining)
  }

  // MARK: Staged commit

  private enum CommitOutcome {
    case committed([OwlProviderProfile])
    /// The write threw, but rereading shows every expected profile on disk.
    case landedAfterError([OwlProviderProfile])
    case notCommitted
  }

  /// Stage keys under their new names, write the profiles, and on a clean write retire what the
  /// write replaced. On failure a staged key is removed only when a readable file proves the write
  /// did not land: every replaced profile still holds its old name and nothing names a staged key.
  /// An unreadable file is ambiguous, so every key stays.
  private func commit(
    staging: [(name: String, key: String)],
    expecting expected: [OwlProviderProfile],
    replacing replaced: [OwlProviderProfile],
    write: () throws -> [OwlProviderProfile]
  ) -> CommitOutcome {
    var staged: [String] = []
    do {
      for entry in staging {
        staged.append(entry.name)
        try secrets.setSecret(entry.key, named: entry.name)
      }
    } catch {
      for name in staged { try? secrets.deleteSecret(named: name) }
      return .notCommitted
    }
    do {
      let saved = try write()
      settle(staged: staged, replacing: replaced, in: saved)
      return .committed(saved)
    } catch {
      guard let reread = store.readableProfiles() else { return .notCommitted }
      let landed = expected.allSatisfy { target in
        reread.contains {
          $0.id == target.id && $0.endpoint == target.endpoint && $0.secretName == target.secretName
        }
      }
      if landed { return .landedAfterError(reread) }
      let untouched = replaced.allSatisfy { old in
        reread.first(where: { $0.id == old.id })?.secretName == old.secretName
      } && !reread.contains(where: { staged.contains($0.secretName) })
      if untouched {
        for name in staged { try? secrets.deleteSecret(named: name) }
      }
      return .notCommitted
    }
  }

  /// After a confirmed write: fresh keys start unverified, and a replaced key that no profile
  /// names any more is deleted with its marker.
  private func settle(staged: [String], replacing replaced: [OwlProviderProfile], in saved: [OwlProviderProfile]) {
    for name in staged { OwlProviderKeyVerification.clear(secretName: name) }
    for old in replaced where !saved.contains(where: { $0.secretName == old.secretName }) {
      try? secrets.deleteSecret(named: old.secretName)
      OwlProviderKeyVerification.clear(secretName: old.secretName)
    }
  }

  private static func sorted(_ profiles: [OwlProviderProfile]) -> [OwlProviderProfile] {
    profiles.sorted {
      $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
    }
  }
}
