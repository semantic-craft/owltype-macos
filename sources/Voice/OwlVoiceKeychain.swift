//
//  OwlVoiceKeychain.swift
//  Owltype — Voice Input Subsystem
//

import Foundation
import Security

public enum OwlVoiceKeychain {
  private static let service = "im.owltype.inputmethod.Owltype.voice"
  private static let xaiAccount = "xAIAPIKey"

  public static func readXAIAPIKey() throws -> String? {
    guard !OwlTestStorage.isEnabled else { return nil }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: xaiAccount,
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

  public static func saveXAIAPIKey(_ key: String) throws {
    guard !OwlTestStorage.isEnabled else { throw OwlCloudKeychainError.unexpectedStatus(errSecNotAvailable) }
    let data = Data(key.utf8)
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: xaiAccount
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

  public static func deleteXAIAPIKey() throws {
    guard !OwlTestStorage.isEnabled else { throw OwlCloudKeychainError.unexpectedStatus(errSecNotAvailable) }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: xaiAccount
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OwlCloudKeychainError.unexpectedStatus(status)
    }
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
    return try OwlCloudKeychain.readDeepSeekAPIKey()
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
