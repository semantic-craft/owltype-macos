//
//  OwlVoiceKeychain.swift
//  Owltype — Voice Input Subsystem
//

import Foundation
import Security

public enum OwlVoiceKeychain {
  private static let service = "im.owltype.inputmethod.Owltype.voice"
  private static let xaiAccount = "xAIAPIKey"

  static func accountName(forProviderID providerID: String) -> String {
    switch OwlVoiceASRCatalog.preset(id: providerID).id {
    case "qwen": return "QwenASRAPIKey"
    case "doubao": return "DoubaoASRAPIKey"
    case "openai": return "OpenAIASRAPIKey"
    case "gemini": return "GeminiASRAPIKey"
    default: return xaiAccount
    }
  }

  public static func readDedicatedAPIKey(forProviderID providerID: String) throws -> String? {
    guard !OwlTestStorage.isEnabled else { return nil }
    let account = accountName(forProviderID: providerID)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw OwlCloudKeychainError.unexpectedStatus(status) }
    guard let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func readConfiguredProfileKey(
    forProviderID providerID: String,
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) -> String? {
    let targetID = providerID == "deepseek" ? "deepseek" : OwlVoiceASRCatalog.preset(id: providerID).id
    if targetID != "deepseek" && !OwlVoiceASRCatalog.preset(id: targetID).sharesProviderProfileKey {
      return nil
    }
    let profiles = store.profiles()
    let activeID = store.defaultProfile?.id
    let ordered = profiles.sorted { lhs, rhs in
      (lhs.id == activeID ? 0 : 1) < (rhs.id == activeID ? 0 : 1)
    }
    for profile in ordered where OwlLLMProviderCatalog.inferredProviderID(for: profile) == targetID {
      if let raw = try? secrets.secret(named: profile.secretName) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }

  static func readAPIKey(
    forProviderID providerID: String = OwlVoiceSettings.asrProviderID,
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) throws -> String? {
    if let dedicated = try readDedicatedAPIKey(forProviderID: providerID)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !dedicated.isEmpty {
      return dedicated
    }
    return readConfiguredProfileKey(forProviderID: providerID, store: store, secrets: secrets)
  }

  public static func saveAPIKey(_ key: String, forProviderID providerID: String) throws {
    guard !OwlTestStorage.isEnabled else { throw OwlCloudKeychainError.unexpectedStatus(errSecNotAvailable) }
    let data = Data(key.utf8)
    let account = accountName(forProviderID: providerID)
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw OwlCloudKeychainError.unexpectedStatus(updateStatus)
    }

    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw OwlCloudKeychainError.unexpectedStatus(addStatus)
    }
  }

  public static func deleteAPIKey(forProviderID providerID: String) throws {
    guard !OwlTestStorage.isEnabled else { throw OwlCloudKeychainError.unexpectedStatus(errSecNotAvailable) }
    let account = accountName(forProviderID: providerID)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OwlCloudKeychainError.unexpectedStatus(status)
    }
  }

  public static func readActiveASRAPIKey() throws -> String? {
    try readAPIKey(forProviderID: OwlVoiceSettings.asrProviderID)
  }

  public static func readXAIAPIKey() throws -> String? {
    try readAPIKey(forProviderID: "grok")
  }

  public static func saveXAIAPIKey(_ key: String) throws {
    try saveAPIKey(key, forProviderID: "grok")
  }

  public static func deleteXAIAPIKey() throws {
    try deleteAPIKey(forProviderID: "grok")
  }

  public static func isXAIKeyConfigured(read: () throws -> String? = readXAIAPIKey) -> Bool {
    guard let key = try? read() else { return false }
    return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func isASRKeyConfigured(
    forProviderID providerID: String = OwlVoiceSettings.asrProviderID,
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) -> Bool {
    guard let key = try? readAPIKey(forProviderID: providerID, store: store, secrets: secrets) else {
      return false
    }
    return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static let deepSeekAccount = "DeepSeekAPIKey"

  public static func readDeepSeekAPIKey() throws -> String? {
    guard !OwlTestStorage.isEnabled else { return nil }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: deepSeekAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
      return key
    }
    if status != errSecItemNotFound && status != errSecSuccess {
      throw OwlCloudKeychainError.unexpectedStatus(status)
    }
    if let profileKey = readConfiguredDeepSeekProfileKey() {
      return profileKey
    }
    return try OwlCloudKeychain.readDeepSeekAPIKey()
  }

  static func readConfiguredDeepSeekProfileKey(
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) -> String? {
    readConfiguredProfileKey(forProviderID: "deepseek", store: store, secrets: secrets)
  }

  public static func saveDeepSeekAPIKey(_ key: String) throws {
    guard !OwlTestStorage.isEnabled else { throw OwlCloudKeychainError.unexpectedStatus(errSecNotAvailable) }
    let data = Data(key.utf8)
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: deepSeekAccount
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw OwlCloudKeychainError.unexpectedStatus(updateStatus)
    }

    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw OwlCloudKeychainError.unexpectedStatus(addStatus)
    }
  }

  public static func deleteDeepSeekAPIKey() throws {
    guard !OwlTestStorage.isEnabled else { throw OwlCloudKeychainError.unexpectedStatus(errSecNotAvailable) }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: deepSeekAccount
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OwlCloudKeychainError.unexpectedStatus(status)
    }
  }
}
