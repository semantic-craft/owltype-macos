//
//  FamoSettingsActions+Stores.swift
//  Famo
//
//  Store-backed button actions for the settings window.
//

import Foundation

extension FamoSettingsActions {
  static func selectProject(_ project: FamoProject)
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
    store: FamoProjectStore
  ) throws -> (project: FamoProject, newProjectName: String, status: String) {
    let project = try store.create(name: name)
    return (project, "", "已新建场景词库「\(project.name)」。")
  }

  static func activateProject(
    _ project: FamoProject,
    store: FamoProjectStore
  ) throws -> (activeID: String?, status: String) {
    try store.activate(id: project.id)
    return (store.activeProjectID, "已激活「\(project.name)」。")
  }

  static func renameProject(
    _ project: FamoProject,
    to name: String,
    store: FamoProjectStore
  ) throws -> (project: FamoProject, status: String) {
    let updated = try store.rename(id: project.id, to: name)
    return (updated, "已重命名为「\(updated.name)」。")
  }

  static func saveProjectWords(
    _ project: FamoProject,
    wordsText: String,
    store: FamoProjectStore
  ) throws -> (project: FamoProject, status: String) {
    let words = wordsText
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { String($0) }
    let updated = try store.setWords(id: project.id, words: words)
    return (updated, "已保存 \(updated.normalizedWords.count) 个词条。")
  }

  static func deleteProject(
    _ project: FamoProject,
    selectedID: String?,
    store: FamoProjectStore
  ) throws -> (selectedID: String?, status: String) {
    try store.delete(id: project.id)
    return (selectedID == project.id ? nil : selectedID, "已删除「\(project.name)」。")
  }

  static func addProjectTermRule(
    to project: FamoProject,
    preferred: String,
    allowedText: String,
    forbiddenText: String,
    store: FamoProjectStore
  ) throws -> (project: FamoProject?, preferred: String, allowed: String, forbidden: String, status: String) {
    let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (nil, preferred, allowedText, forbiddenText, "首选术语不能为空。")
    }
    let rule = FamoTermRule(
      preferred: trimmed,
      allowedVariants: splitTermVariants(allowedText),
      forbiddenVariants: splitTermVariants(forbiddenText)
    )
    let updated = try store.setTermRules(id: project.id, termRules: project.termRules + [rule])
    return (updated, "", "", "", "已添加术语规则「\(rule.preferred)」（共 \(updated.termRules.count) 条）。")
  }

  static func removeProjectTermRule(
    _ rule: FamoTermRule,
    from project: FamoProject,
    store: FamoProjectStore
  ) throws -> (project: FamoProject, status: String) {
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
  /// `FamoCloudPreferences.deepSeekEndpoint` https check). The key is written to the secret store
  /// under the new profile's `secretName` only when supplied — never persisted in providers.json.
  static func addProviderProfile(
    displayName: String,
    endpoint: String,
    model: String,
    apiKey: String,
    makeDefault: Bool,
    store: FamoProviderProfileStore,
    secrets: FamoSecretStoring,
    providerID: String? = nil
  ) -> (profiles: [FamoProviderProfile], status: String) {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return (store.profiles(), "供应商名称不能为空。") }
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme == "https" else {
      return (store.profiles(), "端点必须是 https。")
    }
    let profile = FamoProviderProfile(
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

  /// Save the standalone web-search service key (豆包搜索 Global). Write-only, same contract as
  /// `saveProviderProfileKey`: the value is never read back into the UI.
  ///
  /// Not a provider key — it lives under a fixed Keychain account so the search capability is
  /// independent of which model answers (see `FamoWebSearchKeyStore`).
  static func saveWebSearchKey(
    _ apiKey: String,
    backend: FamoWebSearchBackend,
    secrets: FamoSecretStoring
  ) -> (input: String, status: String) {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return (apiKey, "请输入\(backend.displayName)的 API Key") }
    do {
      try secrets.setSecret(key, named: backend.secretName)
      return ("", "已保存到 Keychain，联网将由\(backend.displayName)检索后交给默认供应商作答。")
    } catch {
      return (apiKey, "保存 Keychain 失败")
    }
  }

  /// Clear one backend's stored key → 若它是当前选中的后端，联网退回各家模型内置的搜索工具。
  /// 只删这一家：另一家的 Key 留着，切回去不用重填。
  static func clearWebSearchKey(
    backend: FamoWebSearchBackend,
    secrets: FamoSecretStoring
  ) -> String {
    do {
      try secrets.deleteSecret(named: backend.secretName)
      return "已删除\(backend.displayName)的 API Key"
    } catch {
      return "删除 Keychain 失败"
    }
  }

  /// Edit an existing profile in place — model (and endpoint, for a custom entry) only.
  ///
  /// Why not delete+re-add: `secretName` is derived from the profile's UUID, so a re-add mints a new
  /// account name and `deleteProviderProfile` takes the old key with it. In-place keeps `id` /
  /// `secretName` / `isDefault`, so **an empty `apiKey` means "keep the stored key"** — that is what
  /// lets 换模型 work without re-pasting a key the UI can't show back.
  static func updateProviderProfile(
    _ profile: FamoProviderProfile,
    endpoint: String,
    model: String,
    apiKey: String,
    store: FamoProviderProfileStore,
    secrets: FamoSecretStoring
  ) -> (profiles: [FamoProviderProfile], status: String) {
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme == "https" else {
      return (store.profiles(), "端点必须是 https。")
    }
    var updated = profile
    updated.endpoint = url
    updated.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let saved = try store.update(updated)
      let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      if !key.isEmpty {
        try secrets.setSecret(key, named: saved.secretName)
      }
      return (store.profiles(), "已保存「\(saved.displayName)」：\(saved.model.isEmpty ? "默认模型" : saved.model)。")
    } catch {
      return (store.profiles(), "保存供应商失败。")
    }
  }

  /// Make a profile the default (the active one the cloud lane routes through).
  static func setDefaultProviderProfile(
    _ profile: FamoProviderProfile,
    store: FamoProviderProfileStore
  ) -> (profiles: [FamoProviderProfile], status: String) {
    do {
      try store.setDefault(id: profile.id)
      return (store.profiles(), "已将「\(profile.displayName)」设为默认。")
    } catch {
      return (store.profiles(), "设置默认供应商失败。")
    }
  }

  /// Delete a profile and its stored key. Promotes another to default if the deleted one was default.
  static func deleteProviderProfile(
    _ profile: FamoProviderProfile,
    store: FamoProviderProfileStore,
    secrets: FamoSecretStoring
  ) -> (profiles: [FamoProviderProfile], status: String) {
    do {
      try store.delete(id: profile.id)
      try? secrets.deleteSecret(named: profile.secretName)
      return (store.profiles(), "已删除供应商「\(profile.displayName)」。")
    } catch {
      return (store.profiles(), "删除供应商失败。")
    }
  }

  /// Save (or replace) a profile's API key. Write-only/masked: the value is never read back into the
  /// UI; the status only reflects set/cleared, never the key itself.
  static func saveProviderProfileKey(
    _ profile: FamoProviderProfile,
    apiKey: String,
    secrets: FamoSecretStoring
  ) -> (input: String, status: String) {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return (apiKey, "请输入 API Key") }
    do {
      try secrets.setSecret(key, named: profile.secretName)
      return ("", "已保存到 Keychain")
    } catch {
      return (apiKey, "保存 Keychain 失败")
    }
  }

  /// Clear a profile's stored key.
  static func clearProviderProfileKey(
    _ profile: FamoProviderProfile,
    secrets: FamoSecretStoring
  ) -> String {
    do {
      try secrets.deleteSecret(named: profile.secretName)
      return "已删除 API Key"
    } catch {
      return "删除 Keychain 失败"
    }
  }

  /// "已设置 / 未设置" status for a profile's key — never the value.
  static func providerProfileKeyStatus(
    _ profile: FamoProviderProfile,
    secrets: FamoSecretStoring
  ) -> String {
    do {
      let key = try secrets.secret(named: profile.secretName)
      return (key?.isEmpty == false) ? "已设置" : "未设置"
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
    files: [FamoManagedPatchFile],
    timestamp: String,
    apply: (FamoManagedPatchFile, String) throws -> Void,
    redeploy: () -> Bool
  ) -> String? {
    guard confirmed else { return nil }
    var written: [String] = []
    do {
      for file in files {
        try apply(file, timestamp)
        written.append(file.fileName)
      }
      return FamoWritePreviewSheet.applyStatusMessage(written: written, deploySucceeded: redeploy())
    } catch FamoConfigWriteError.refusedNeverTouch(let name) {
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
