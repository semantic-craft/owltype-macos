//
//  OwlSettingsActions+Stores.swift
//  Owltype
//
//  Store-backed button actions for the settings window.
//

import Foundation

// MARK: - 「这把 Key 真的能用」的标记

/// 记下某个 Keychain 账号下的密钥**曾经成功通过一次真实调用**（拉取模型列表）。
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

extension OwlSettingsActions {
  static func selectProject(_ project: OwlProject)
    -> (selectedID: String, renameDraft: String, wordsDraft: String, status: String)
  {
    (
      project.id,
      project.name,
      project.normalizedWords.joined(separator: "\n"),
      ""
    )
  }

  static func createProject(
    name: String,
    store: OwlProjectStore
  ) throws -> (project: OwlProject, newProjectName: String, status: String) {
    let project = try store.create(name: name)
    return (project, "", "已新建场景词库「\(project.name)」。")
  }

  static func activateProject(
    _ project: OwlProject,
    store: OwlProjectStore
  ) throws -> (activeID: String?, status: String) {
    try store.activate(id: project.id)
    return (store.activeProjectID, "已激活「\(project.name)」。")
  }

  static func renameProject(
    _ project: OwlProject,
    to name: String,
    store: OwlProjectStore
  ) throws -> (project: OwlProject, status: String) {
    let updated = try store.rename(id: project.id, to: name)
    return (updated, "已重命名为「\(updated.name)」。")
  }

  static func saveProjectWords(
    _ project: OwlProject,
    wordsText: String,
    store: OwlProjectStore
  ) throws -> (project: OwlProject, status: String) {
    let words = wordsText
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { String($0) }
    let updated = try store.setWords(id: project.id, words: words)
    return (updated, "已保存 \(updated.normalizedWords.count) 个词条。")
  }

  static func deleteProject(
    _ project: OwlProject,
    selectedID: String?,
    store: OwlProjectStore
  ) throws -> (selectedID: String?, status: String) {
    try store.delete(id: project.id)
    return (selectedID == project.id ? nil : selectedID, "已删除「\(project.name)」。")
  }

  static func addProjectTermRule(
    to project: OwlProject,
    preferred: String,
    allowedText: String,
    forbiddenText: String,
    store: OwlProjectStore
  ) throws -> (project: OwlProject?, preferred: String, allowed: String, forbidden: String, status: String) {
    let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (nil, preferred, allowedText, forbiddenText, "首选术语不能为空。")
    }
    let rule = OwlTermRule(
      preferred: trimmed,
      allowedVariants: splitTermVariants(allowedText),
      forbiddenVariants: splitTermVariants(forbiddenText)
    )
    let updated = try store.setTermRules(id: project.id, termRules: project.termRules + [rule])
    return (updated, "", "", "", "已添加术语规则「\(rule.preferred)」（共 \(updated.termRules.count) 条）。")
  }

  static func removeProjectTermRule(
    _ rule: OwlTermRule,
    from project: OwlProject,
    store: OwlProjectStore
  ) throws -> (project: OwlProject, status: String) {
    let remaining = project.termRules.filter { $0.id != rule.id }
    let updated = try store.setTermRules(id: project.id, termRules: remaining)
    return (updated, "已删除术语规则「\(rule.preferred)」。")
  }

  static func deepSeekAPIKeyStatus(read: () throws -> String?) -> String {
    do {
      let key = try read()
      return key?.isEmpty == false ? "已配置 Keychain API Key" : "未配置 API Key"
    } catch {
      return "无法读取 Keychain"
    }
  }

  static func saveDeepSeekAPIKey(
    _ input: String,
    save: (String) throws -> Void
  ) -> (input: String, status: String) {
    let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return (input, "请输入 API Key") }
    do {
      try save(key)
      return ("", "已保存到 Keychain")
    } catch {
      return (input, "保存 Keychain 失败")
    }
  }

  static func deleteDeepSeekAPIKey(
    input: String,
    delete: () throws -> Void
  ) -> (input: String, status: String) {
    do {
      try delete()
      return ("", "已删除 API Key")
    } catch {
      return (input, "删除 Keychain 失败")
    }
  }

  // MARK: - AI provider profiles (multi-provider foundation, B1)

  /// Add a new OpenAI-compatible provider profile. Endpoint must be https (mirrors the existing
  /// `OwlCloudPreferences.deepSeekEndpoint` https check). The key is written to the secret store
  /// under the new profile's `secretName` only when supplied — never persisted in providers.json.
  static func addProviderProfile(
    displayName: String,
    endpoint: String,
    model: String,
    apiKey: String,
    makeDefault: Bool,
    store: OwlProviderProfileStore,
    secrets: OwlSecretStoring,
    providerID: String? = nil
  ) -> (profiles: [OwlProviderProfile], status: String) {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return (store.profiles(), "供应商名称不能为空。") }
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
          isHTTPSEndpoint(url) else {
      return (store.profiles(), "端点必须是 https。")
    }
    let profile = OwlProviderProfile(
      displayName: name,
      endpoint: url,
      model: model.trimmingCharacters(in: .whitespacesAndNewlines),
      providerID: providerID,
      isDefault: makeDefault
    )
    do {
      let added = try store.add(profile)
      let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      if !key.isEmpty {
        try secrets.setSecret(key, named: added.secretName)
      }
      return (store.profiles(), "已添加供应商「\(added.displayName)」。")
    } catch {
      return (store.profiles(), "添加供应商失败。")
    }
  }

  /// Save the shared Qwen Workspace API Host and keep every existing Qwen profile on the same
  /// Responses endpoint, so profiles added at different times never drift to different workspaces.
  static func saveQwenWorkspace(
    _ input: String,
    apiKey: String,
    store: OwlProviderProfileStore,
    secrets: OwlSecretStoring,
    defaults: UserDefaults = OwlDefaults.standard
  ) -> (profiles: [OwlProviderProfile], status: String, saved: Bool) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let commitWorkspace = OwlQwenWorkspaceSettings.prepareSave(trimmed, defaults: defaults),
          let endpoint = trimmed.isEmpty
            ? URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)
            : OwlQwenWorkspace.responsesEndpoint(for: trimmed) else {
      return (store.profiles(), "Workspace ID / API Host 格式无效，未覆盖原配置。", false)
    }
    guard let profiles = store.readableProfiles() else {
      return (store.profiles(), "保存 Workspace API Host 失败。", false)
    }
    let qwenProfiles = profiles.filter {
      OwlLLMProviderCatalog.inferredProviderID(for: $0) == "qwen"
    }
    for profile in qwenProfiles {
      if let rejection = originChangeKeyRejection(current: profile, endpoint: endpoint, apiKey: key) {
        return (store.profiles(), rejection, false)
      }
    }
    // Ask the shared guard with an empty key to identify which profiles need replacement.
    let changing = qwenProfiles.filter {
      originChangeKeyRejection(current: $0, endpoint: endpoint, apiKey: "") != nil
    }
    var stagedNames: [String] = []
    var committing = false
    var updated = qwenProfiles
    func finishCommit(_ profiles: [OwlProviderProfile])
      -> (profiles: [OwlProviderProfile], status: String, saved: Bool) {
      commitWorkspace()
      for name in stagedNames { OwlProviderKeyVerification.clear(secretName: name) }
      for old in changing where !profiles.contains(where: { $0.secretName == old.secretName }) {
        try? secrets.deleteSecret(named: old.secretName)
        OwlProviderKeyVerification.clear(secretName: old.secretName)
      }
      let status = trimmed.isEmpty
        ? "已清除 Workspace，百炼将使用通用 Responses 端点。"
        : "已保存 Workspace API Host，所有 Qwen 供应商将共用。"
      let ordered = profiles.sorted {
        $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
      }
      return (ordered, status, true)
    }
    do {
      for index in updated.indices {
        updated[index].endpoint = endpoint
        if changing.contains(where: { $0.id == updated[index].id }) {
          // Independent names keep deleting one profile from removing another profile's key.
          let name = OwlProviderProfile.defaultSecretName(for: UUID().uuidString)
          stagedNames.append(name)
          try secrets.setSecret(key, named: name)
          updated[index].secretName = name
        }
      }
      committing = true
      let profiles = try store.update(updated)
      return finishCommit(profiles)
    } catch {
      if !committing {
        for name in stagedNames { try? secrets.deleteSecret(named: name) }
        return (store.profiles(), "保存 Workspace API Host 失败。", false)
      }
      guard let profiles = store.readableProfiles() else {
        return (store.profiles(), "保存 Workspace API Host 失败。", false)
      }
      let committed = updated.allSatisfy { expected in
        profiles.contains {
          $0.id == expected.id && $0.endpoint == expected.endpoint
            && $0.secretName == expected.secretName
        }
      }
      if committed { return finishCommit(profiles) }
      // Only readable old references with no staged references permit key cleanup.
      let unchanged = changing.allSatisfy { old in
        profiles.first(where: { $0.id == old.id })?.secretName == old.secretName
      } && !profiles.contains(where: { stagedNames.contains($0.secretName) })
      if unchanged {
        for name in stagedNames { try? secrets.deleteSecret(named: name) }
      }
      return (profiles, "保存 Workspace API Host 失败。", false)
    }
  }

  /// 保存与「拉取最新」「验证连通性」共用的 HTTPS 判断，scheme 不区分大小写。
  static func isHTTPSEndpoint(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
  }

  private static func origin(_ url: URL) -> (String?, String?, Int?) {
    let scheme = url.scheme?.lowercased()
    let port: Int? = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    return (scheme, url.host?.lowercased(), port)
  }

  static func originChangeKeyRejection(
    current: OwlProviderProfile,
    endpoint: URL,
    apiKey: String
  ) -> String? {
    guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          origin(endpoint) != origin(current.endpoint) else { return nil }
    return "更换地址后请重新填写 API Key。"
  }

  /// 「拉取最新」「验证连通性」要用的 Key。
  static func providerProbeKey(
    editing profile: OwlProviderProfile?,
    endpoint: URL,
    typedKey: String,
    store: OwlProviderProfileStore,
    secrets: OwlSecretStoring
  ) -> (key: String?, status: String?) {
    let typed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard typed.isEmpty else { return (typed, nil) }
    guard let profile else { return (nil, nil) }
    let current = store.profile(id: profile.id) ?? profile
    if let rejection = originChangeKeyRejection(current: current, endpoint: endpoint, apiKey: typed) {
      return (nil, rejection)
    }
    guard let stored = try? secrets.secret(named: current.secretName),
          !stored.isEmpty else { return (nil, nil) }
    return (stored, nil)
  }

  /// Edit the persisted profile; a blank key is allowed only within the same origin.
  /// A replacement key gets an independent reference before the endpoint is committed.
  static func updateProviderProfile(
    _ profile: OwlProviderProfile,
    endpoint: String,
    model: String,
    apiKey: String,
    store: OwlProviderProfileStore,
    secrets: OwlSecretStoring
  ) -> (profiles: [OwlProviderProfile], status: String) {
    guard let current = store.profile(id: profile.id) else {
      return (store.profiles(), "保存供应商失败。")
    }
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return (store.profiles(), "端点必须是 https。")
    }
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if let rejection = originChangeKeyRejection(current: current, endpoint: url, apiKey: key) {
      return (store.profiles(), rejection)
    }
    guard isHTTPSEndpoint(url) else {
      return (store.profiles(), "端点必须是 https。")
    }
    var updated = current
    if !OwlLLMProviderCatalog.isKnownProviderID(OwlLLMProviderCatalog.inferredProviderID(for: current)) {
      updated.providerID = OwlLLMProviderCatalog.customID
    }
    updated.endpoint = url
    updated.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let oldSecretName = current.secretName
    var stagedSecretName: String?
    do {
      if !key.isEmpty {
        // Commit the endpoint and its replacement key reference together.
        updated.secretName = OwlProviderProfile.defaultSecretName(for: UUID().uuidString)
        stagedSecretName = updated.secretName
        try secrets.setSecret(key, named: updated.secretName)
      }
      let saved = try store.update(updated)
      if !key.isEmpty {
        OwlProviderKeyVerification.clear(secretName: saved.secretName)
        if !store.profiles().contains(where: { $0.secretName == oldSecretName }) {
          try? secrets.deleteSecret(named: oldSecretName)
          OwlProviderKeyVerification.clear(secretName: oldSecretName)
        }
      }
      return (store.profiles(), "已保存「\(saved.displayName)」：\(saved.model.isEmpty ? "默认模型" : saved.model)。")
    } catch {
      let profiles = store.profiles()
      // A readable old reference proves this replacement did not commit. Missing or
      // unreadable configuration is ambiguous, so retain the staged key in that case.
      if let stagedSecretName,
         profiles.first(where: { $0.id == current.id })?.secretName == oldSecretName,
         !profiles.contains(where: { $0.secretName == stagedSecretName }) {
        try? secrets.deleteSecret(named: stagedSecretName)
      }
      return (profiles, "保存供应商失败。")
    }
  }

  static func providerProfileForRetry(
    _ profile: OwlProviderProfile, profiles: [OwlProviderProfile]
  ) -> OwlProviderProfile? {
    profiles.first { $0.id == profile.id }
  }

  static func editingProfileAfterWorkspaceSave(
    _ editing: OwlProviderProfile?, profiles: [OwlProviderProfile]
  ) -> OwlProviderProfile? {
    guard let editing else { return nil }
    return providerProfileForRetry(editing, profiles: profiles) ?? editing
  }

  /// Make a profile the default (the active one the cloud lane routes through).
  static func setDefaultProviderProfile(
    _ profile: OwlProviderProfile,
    store: OwlProviderProfileStore
  ) -> (profiles: [OwlProviderProfile], status: String) {
    guard OwlLLMProviderCatalog.isKnownProviderID(OwlLLMProviderCatalog.inferredProviderID(for: profile)) else {
      return (store.profiles(), "请先编辑并保存该供应商，再设为默认。")
    }
    do {
      try store.setDefault(id: profile.id)
      return (store.profiles(), "已将「\(profile.displayName)」设为默认。")
    } catch {
      return (store.profiles(), "设置默认供应商失败。")
    }
  }

  /// Delete a profile and its stored key. Promotes another to default if the deleted one was default.
  static func deleteProviderProfile(
    _ profile: OwlProviderProfile,
    store: OwlProviderProfileStore,
    secrets: OwlSecretStoring
  ) -> (profiles: [OwlProviderProfile], status: String) {
    do {
      try store.delete(id: profile.id)
      try? secrets.deleteSecret(named: profile.secretName)
      OwlProviderKeyVerification.clear(secretName: profile.secretName)
      return (store.profiles(), "已删除供应商「\(profile.displayName)」。")
    } catch {
      return (store.profiles(), "删除供应商失败。")
    }
  }

  /// Save (or replace) a profile's API key. Write-only/masked: the value is never read back into the
  /// UI; the status only reflects set/cleared, never the key itself.
  static func saveProviderProfileKey(
    _ profile: OwlProviderProfile,
    apiKey: String,
    secrets: OwlSecretStoring
  ) -> (input: String, status: String) {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return (apiKey, "请输入 API Key") }
    do {
      try secrets.setSecret(key, named: profile.secretName)
      // 换了钥匙，之前那次验证就不作数了。
      OwlProviderKeyVerification.clear(secretName: profile.secretName)
      return ("", "已保存到 Keychain")
    } catch {
      return (apiKey, "保存 Keychain 失败")
    }
  }

  /// Clear a profile's stored key.
  static func clearProviderProfileKey(
    _ profile: OwlProviderProfile,
    secrets: OwlSecretStoring
  ) -> String {
    do {
      try secrets.deleteSecret(named: profile.secretName)
      OwlProviderKeyVerification.clear(secretName: profile.secretName)
      return "已删除 API Key"
    } catch {
      return "删除 Keychain 失败"
    }
  }

  /// 记下「这把 Key 刚刚真的调通了一次」（`拉取最新` 成功时调用）。
  static func markProviderProfileKeyVerified(_ profile: OwlProviderProfile) {
    OwlProviderKeyVerification.markVerified(secretName: profile.secretName)
  }

  /// 一个 profile 的密钥状态 —— 永远不含密钥本身。
  ///
  /// 三档而不是两档：「已验证」= 用这把 Key 真的调通过一次；「已设置」= Keychain 里有值但没验证过
  /// （可能已失效，实机踩过：Key 401 了，设置页仍写「已设置」）；「未设置」= 没有值。
  /// 把「有值」直接说成配好了，是让用户查不出失效密钥的根因。
  static func providerProfileKeyStatus(
    _ profile: OwlProviderProfile,
    secrets: OwlSecretStoring
  ) -> String {
    do {
      let key = try secrets.secret(named: profile.secretName)
      guard key?.isEmpty == false else { return "未设置" }
      return OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName) == nil
        ? "已设置·未验证"
        : "已验证"
    } catch {
      return "无法读取 Keychain"
    }
  }

  static func splitTermVariants(_ raw: String) -> [String] {
    raw
      .split(whereSeparator: { $0 == "," || $0 == "，" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  @discardableResult
  static func selectSchemaRow(
    _ schema: SchemaItem,
    currentSchemaID: String,
    onSelectSchema: (String) -> Void
  ) -> Bool {
    guard schema.id != currentSchemaID else { return false }
    onSelectSchema(schema.id)
    return true
  }

  static func copyPreviewText(_ text: String, copy: (String) -> Void) {
    copy(text)
  }

  static func applyWritePreview(
    confirmed: Bool,
    files: [OwlManagedPatchFile],
    timestamp: String,
    apply: (OwlManagedPatchFile, String) throws -> Void,
    redeploy: () -> Bool
  ) -> String? {
    guard confirmed else { return nil }
    var written: [String] = []
    do {
      for file in files {
        try apply(file, timestamp)
        written.append(file.fileName)
      }
      return OwlWritePreviewSheet.applyStatusMessage(written: written, deploySucceeded: redeploy())
    } catch OwlConfigWriteError.refusedNeverTouch(let name) {
      return "已拒绝写入受保护文件：\(name)。"
    } catch {
      return "写入失败：\(error.localizedDescription)。已写入：\(written.joined(separator: "、"))。"
    }
  }

  static func rollbackWritePreview(
    confirmed: Bool,
    rollback: () throws -> Void,
    redeploy: () -> Bool
  ) -> String? {
    guard confirmed else { return nil }
    do {
      try rollback()
      return redeploy()
        ? "已按 manifest 回滚最近一次写入并应用配置改动。"
        : "已按 manifest 回滚最近一次写入；应用配置失败，请查看诊断日志。"
    } catch {
      return "回滚失败：\(error.localizedDescription)。"
    }
  }
}
