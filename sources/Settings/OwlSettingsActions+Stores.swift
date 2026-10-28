//
//  OwlSettingsActions+Stores.swift
//  Owltype
//
//  Store-backed button actions for the settings window.
//

import Foundation

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

  /// Save the 豆包搜索 key used by 来源核验. Stored apart from model keys: the search console
  /// issues its own key, and an Ark model key is rejected (`700901`).
  static func saveDoubaoSearchKey(
    _ apiKey: String,
    secrets: OwlSecretStoring
  ) -> (input: String, status: String) {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return (apiKey, "请输入豆包搜索的 API Key") }
    do {
      try secrets.setSecret(key, named: OwlDoubaoSearchKeyStore.secretName)
      return ("", "已保存到 Keychain，来源核验将用豆包搜索取来源。")
    } catch {
      return (apiKey, "保存 Keychain 失败")
    }
  }

  static func clearDoubaoSearchKey(secrets: OwlSecretStoring) -> String {
    do {
      try secrets.deleteSecret(named: OwlDoubaoSearchKeyStore.secretName)
      return "已删除豆包搜索的 API Key，来源核验只保留跳库查询。"
    } catch {
      return "删除 Keychain 失败"
    }
  }

  // MARK: - AI provider profiles

  // Persistence goes through `OwlProviderRegistry`; these keep the form's editing snapshot current.

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

// MARK: - Provider registry copy

// The settings page's words for each registry outcome. Kept beside the other settings strings so
// the registry stays free of copy and every string stays as users already know it.

extension OwlProviderRegistry.UpsertOutcome {
  var statusText: String {
    switch self {
    case let .added(profile): return "已添加供应商「\(profile.displayName)」。"
    case .blankName: return "供应商名称不能为空。"
    case .insecureEndpoint: return "端点必须是 https。"
    case .invalidWorkspace: return "Workspace ID / API Host 格式无效。"
    case .failed: return "添加供应商失败。"
    }
  }
}

extension OwlProviderRegistry.EditOutcome {
  var statusText: String {
    switch self {
    case let .saved(profile):
      return "已保存「\(profile.displayName)」：\(profile.model.isEmpty ? "默认模型" : profile.model)。"
    case .insecureEndpoint: return "端点必须是 https。"
    case .needsReplacementKey: return OwlProviderRegistry.ProbeKey.replacementKeyPrompt
    case .failed: return "保存供应商失败。"
    }
  }
}

extension OwlProviderRegistry.WorkspaceOutcome {
  var statusText: String {
    switch self {
    case .saved(cleared: true): return "已清除 Workspace，百炼将使用通用 Responses 端点。"
    case .saved(cleared: false): return "已保存 Workspace API Host，所有 Qwen 供应商将共用。"
    case .invalidInput: return "Workspace ID / API Host 格式无效，未覆盖原配置。"
    case .needsReplacementKey: return OwlProviderRegistry.ProbeKey.replacementKeyPrompt
    case .failed: return "保存 Workspace API Host 失败。"
    }
  }
}

extension OwlProviderRegistry.DefaultOutcome {
  var statusText: String {
    switch self {
    case let .set(profile): return "已将「\(profile.displayName)」设为默认。"
    case .needsEdit: return "请先编辑并保存该供应商，再设为默认。"
    case .failed: return "设置默认供应商失败。"
    }
  }
}

extension OwlProviderRegistry.DeleteOutcome {
  var statusText: String {
    switch self {
    case let .deleted(profile): return "已删除供应商「\(profile.displayName)」。"
    case .failed: return "删除供应商失败。"
    }
  }
}

extension OwlProviderRegistry.KeyState {
  /// 三档而不是两档：「已验证」= 用这把 Key 真的调通过一次；「已设置」= Keychain 里有值但没验证过
  /// （可能已失效，实机踩过：Key 401 了，设置页仍写「已设置」）；「未设置」= 没有值。
  var statusText: String {
    switch self {
    case .missing: return "未设置"
    case .unverified: return "已设置·未验证"
    case .verified: return "已验证"
    case .unreadable: return "无法读取 Keychain"
    }
  }
}

extension OwlProviderRegistry.ProbeKey {
  static let replacementKeyPrompt = "更换地址后请重新填写 API Key。"
}
