//
//  OwlSettingsActions+Stores.swift
//  Owltype
//
//  Store-backed button actions for the settings window.
//

import Foundation

extension OwlSettingsActions {
  static func deepSeekAPIKeyStatus(read: () throws -> String?) -> String {
    do {
      let key = try read()
      return credentialForm("read", present: key?.isEmpty == false).status
    } catch { return credentialForm("read", failure: true).status }
  }

  static func saveDeepSeekAPIKey(
    _ input: String,
    save: (String) throws -> Void
  ) -> (input: String, status: String) {
    let plan = credentialForm("save", text: input)
    guard plan.execute else { return (plan.input, plan.status) }
    do {
      try save(plan.key)
      let result = credentialForm("saved")
      return (result.input, result.status)
    } catch {
      let result = credentialForm("saved", text: input, failure: true)
      return (result.input, result.status)
    }
  }

  static func deleteDeepSeekAPIKey(
    input: String,
    delete: () throws -> Void
  ) -> (input: String, status: String) {
    do {
      try delete()
      let result = credentialForm("deleted")
      return (result.input, result.status)
    } catch {
      let result = credentialForm("deleted", text: input, failure: true)
      return (result.input, result.status)
    }
  }

  /// Save the 豆包搜索 key used by 来源核验. Stored apart from model keys: the search console
  /// issues its own key, and an Ark model key is rejected (`700901`).
  static func saveDoubaoSearchKey(
    _ apiKey: String,
    secrets: OwlSecretStoring
  ) -> (input: String, status: String) {
    let plan = credentialForm("save", text: apiKey, doubao: true)
    guard plan.execute else { return (plan.input, plan.status) }
    do {
      try secrets.setSecret(plan.key, named: OwlDoubaoSearchKeyStore.secretName)
      let result = credentialForm("saved", doubao: true)
      return (result.input, result.status)
    } catch {
      let result = credentialForm("saved", text: apiKey, doubao: true, failure: true)
      return (result.input, result.status)
    }
  }

  static func clearDoubaoSearchKey(secrets: OwlSecretStoring) -> String {
    do {
      try secrets.deleteSecret(named: OwlDoubaoSearchKeyStore.secretName)
      return credentialForm("deleted", doubao: true).status
    } catch { return credentialForm("deleted", doubao: true, failure: true).status }
  }

  struct VoiceASRSaveResult: Equatable {
    let input: String
    let endpoint: String
    let model: String
    let status: String
  }

  static func saveVoiceASRSettings(
    providerID: String = OwlVoiceSettings.asrProviderID,
    endpoint: String,
    model: String,
    apiKey: String,
    isKeyAlreadyConfigured: Bool,
    saveKey: ((String) throws -> Void)? = nil,
    defaults: UserDefaults = OwlDefaults.standard
  ) -> VoiceASRSaveResult {
    let preset = OwlVoiceASRCatalog.preset(id: providerID)
    let trimmedEndpoint = OwlProviderCore.call("trim", ["text": endpoint]) as String
    let effectiveEndpoint = trimmedEndpoint.isEmpty ? preset.endpoint : trimmedEndpoint
    guard let url = URL(string: effectiveEndpoint), OwlProviderRegistry.isHTTPS(url) else {
      return VoiceASRSaveResult(input: apiKey, endpoint: endpoint, model: model, status: "端点必须是 https。")
    }
    let trimmedModel = OwlProviderCore.call("trim", ["text": model]) as String
    let effectiveModel = trimmedModel.isEmpty ? preset.defaultModel : trimmedModel
    let trimmedKey = OwlProviderCore.call("trim", ["text": apiKey]) as String

    if trimmedKey.isEmpty && !isKeyAlreadyConfigured {
      return VoiceASRSaveResult(
        input: "", endpoint: effectiveEndpoint, model: effectiveModel, status: "请输入 \(preset.keyLabel)")
    }

    if !trimmedKey.isEmpty {
      do {
        if let saveKey {
          try saveKey(trimmedKey)
        } else {
          try OwlVoiceSettings.saveASRAPIKey(trimmedKey, forProviderID: preset.id)
        }
      } catch {
        return VoiceASRSaveResult(
          input: apiKey, endpoint: effectiveEndpoint, model: effectiveModel, status: "保存 Keychain 失败")
      }
    }

    defaults.set(preset.id, forKey: OwlVoiceSettings.asrProviderIDKey)
    defaults.set(effectiveEndpoint, forKey: OwlVoiceSettings.asrEndpointKey)
    defaults.set(effectiveModel, forKey: OwlVoiceSettings.asrModelKey)

    let status = trimmedKey.isEmpty
      ? "已保存语音识别配置（\(effectiveModel)）。"
      : "已保存 \(preset.displayName) 密钥与语音识别配置（\(effectiveModel)）。"
    return VoiceASRSaveResult(input: "", endpoint: effectiveEndpoint, model: effectiveModel, status: status)
  }

  static func clearVoiceASRAPIKey(
    providerID: String = OwlVoiceASRCatalog.openai.id,
    deleteKey: (() throws -> Void)? = nil
  ) -> String {
    let preset = OwlVoiceASRCatalog.preset(id: providerID)
    do {
      if let deleteKey {
        try deleteKey()
      } else {
        try OwlVoiceSettings.deleteASRAPIKey(forProviderID: preset.id)
      }
      return "已清除 \(preset.keyLabel)。"
    } catch {
      return "删除 Keychain 失败"
    }
  }

  // MARK: - AI provider profiles

  // Persistence goes through `OwlProviderRegistry`; these keep the form's editing snapshot current.

  static func providerProfileForRetry(
    _ profile: OwlProviderProfile, profiles: [OwlProviderProfile]
  ) -> OwlProviderProfile? {
    struct Reply: Decodable { let index: Int? }
    let reply: Reply = OwlAIBusinessCore.call("profileRetry", ["id": profile.id, "ids": profiles.map { $0.id }])
    return reply.index.map { profiles[$0] }
  }

  static func editingProfileAfterWorkspaceSave(
    _ editing: OwlProviderProfile?, profiles: [OwlProviderProfile]
  ) -> OwlProviderProfile? {
    guard let editing else { return nil }
    return providerProfileForRetry(editing, profiles: profiles) ?? editing
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

  private struct CredentialForm: Decodable {
    let status: String
    let input: String
    let key: String
    let execute: Bool
  }
  private static func credentialForm(_ action: String, text: String = "", doubao: Bool = false,
                                     present: Bool = false, failure: Bool = false) -> CredentialForm {
    OwlAIBusinessCore.call("credentialForm", ["action": action, "text": text, "doubao": doubao,
      "present": present, "failure": failure])
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
