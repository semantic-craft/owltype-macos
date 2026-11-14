import Foundation

public struct OwlVoiceASRPreset: Identifiable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let endpoint: String
  public let defaultModel: String
  public let curatedModels: [String]
  public let keyLabel: String
  public let keyHint: String
  public let sharesProviderProfileKey: Bool

  public init(
    id: String,
    displayName: String,
    endpoint: String,
    defaultModel: String,
    curatedModels: [String],
    keyLabel: String,
    keyHint: String,
    sharesProviderProfileKey: Bool = true
  ) {
    self.id = id
    self.displayName = displayName
    self.endpoint = endpoint
    self.defaultModel = defaultModel
    self.curatedModels = curatedModels
    self.keyLabel = keyLabel
    self.keyHint = keyHint
    self.sharesProviderProfileKey = sharesProviderProfileKey
  }

  public var requiresAPIKey: Bool { true }
}

public enum OwlVoiceASRCatalog {
  public static let openai = OwlVoiceASRPreset(
    id: "openai",
    displayName: "OpenAI",
    endpoint: "https://api.openai.com/v1/audio/transcriptions",
    defaultModel: "gpt-transcribe",
    curatedModels: [
      "gpt-transcribe",
      "gpt-4o-transcribe",
      "gpt-4o-mini-transcribe",
      "whisper-1",
    ],
    keyLabel: "OpenAI API Key",
    keyHint: "sk-..."
  )

  public static let gemini = OwlVoiceASRPreset(
    id: "gemini",
    displayName: "Google Gemini",
    endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
    defaultModel: "gemini-3.5-transcribe",
    curatedModels: [
      "gemini-3.5-transcribe",
      "gemini-3.8-flash",
      "gemini-3.0-flash",
    ],
    keyLabel: "Gemini API Key",
    keyHint: "AIza..."
  )

  public static let deepseek = OwlVoiceASRPreset(
    id: "deepseek",
    displayName: "DeepSeek",
    endpoint: "https://api.deepseek.com/v1/tools/asr",
    defaultModel: "",
    curatedModels: [],
    keyLabel: "DeepSeek API Key",
    keyHint: "sk-..."
  )

  public static let presets: [OwlVoiceASRPreset] = [openai, gemini, deepseek]

  public static func preset(id: String) -> OwlVoiceASRPreset {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return presets.first(where: { $0.id == trimmed }) ?? openai
  }
}

public enum OwlVoiceSettings {
  public static let enabledKey = "OwlVoiceInputEnabled"
  public static let polishEnabledKey = "OwlVoicePolishEnabled"
  public static let holdRightOptionKey = "OwlVoiceHoldRightOptionEnabled"
  public static let asrProviderIDKey = "OwlVoiceASRProviderID"
  public static let asrEndpointKey = "OwlVoiceASREndpoint"
  public static let asrModelKey = "OwlVoiceASRModel"

  public static let defaultASRProviderID = OwlVoiceASRCatalog.openai.id
  public static let defaultASREndpoint = OwlVoiceASRCatalog.openai.endpoint
  public static let defaultASRModel = OwlVoiceASRCatalog.openai.defaultModel

  private static let knownPresetEndpoints: Set<String> = Set(
    OwlVoiceASRCatalog.presets.map(\.endpoint) + ["https://api.x.ai/v1/audio/transcriptions"]
  )
  private static let knownPresetModels: Set<String> = Set(
    OwlVoiceASRCatalog.presets.flatMap(\.curatedModels) + ["grok-2-vision-1212", "grok-asr-1", "chatgpt-dictation"]
  )

  public static var isEnabled: Bool {
    get { OwlDefaults.standard.bool(forKey: enabledKey) }
    set { OwlDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  public static var isPolishEnabled: Bool {
    get { OwlDefaults.standard.bool(forKey: polishEnabledKey) }
    set { OwlDefaults.standard.set(newValue, forKey: polishEnabledKey) }
  }

  public static var holdRightOptionEnabled: Bool {
    get {
      if OwlDefaults.standard.object(forKey: holdRightOptionKey) == nil {
        return true
      }
      return OwlDefaults.standard.bool(forKey: holdRightOptionKey)
    }
    set { OwlDefaults.standard.set(newValue, forKey: holdRightOptionKey) }
  }

  static func resolvedASRProviderID(
    defaults: UserDefaults = OwlDefaults.standard,
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) -> String {
    let explicitRaw = defaults.string(forKey: asrProviderIDKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if let explicitRaw,
       let explicitPreset = OwlVoiceASRCatalog.presets.first(where: { $0.id == explicitRaw }),
       isASRKeyConfigured(forProviderID: explicitPreset.id, store: store, secrets: secrets) {
      return explicitPreset.id
    }

    if let defaultProfile = store.defaultProfile {
      let defaultID = OwlLLMProviderCatalog.inferredProviderID(for: defaultProfile)
      if OwlVoiceASRCatalog.presets.contains(where: { $0.id == defaultID }),
         isASRKeyConfigured(forProviderID: defaultID, store: store, secrets: secrets) {
        return defaultID
      }
    }
    for profile in store.profiles() {
      let inferred = OwlLLMProviderCatalog.inferredProviderID(for: profile)
      if OwlVoiceASRCatalog.presets.contains(where: { $0.id == inferred }),
         isASRKeyConfigured(forProviderID: inferred, store: store, secrets: secrets) {
        return inferred
      }
    }

    if let explicitRaw {
      return OwlVoiceASRCatalog.preset(id: explicitRaw).id
    }
    return defaultASRProviderID
  }

  public static var asrProviderID: String {
    get { resolvedASRProviderID() }
    set {
      let preset = OwlVoiceASRCatalog.preset(id: newValue)
      OwlDefaults.standard.set(preset.id, forKey: asrProviderIDKey)
    }
  }

  public static var asrPreset: OwlVoiceASRPreset {
    OwlVoiceASRCatalog.preset(id: asrProviderID)
  }

  public static var asrEndpoint: String {
    get {
      let preset = asrPreset
      guard let raw = OwlDefaults.standard.string(forKey: asrEndpointKey) else {
        return preset.endpoint
      }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return preset.endpoint
      }
      if trimmed != preset.endpoint && knownPresetEndpoints.contains(trimmed) {
        return preset.endpoint
      }
      return trimmed
    }
    set {
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let preset = asrPreset
      OwlDefaults.standard.set(trimmed.isEmpty ? preset.endpoint : trimmed, forKey: asrEndpointKey)
    }
  }

  public static var asrModel: String {
    get {
      let preset = asrPreset
      guard let raw = OwlDefaults.standard.string(forKey: asrModelKey) else {
        return preset.defaultModel
      }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return preset.defaultModel
      }
      if !preset.curatedModels.contains(trimmed) && knownPresetModels.contains(trimmed) {
        return preset.defaultModel
      }
      return trimmed
    }
    set {
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let preset = asrPreset
      OwlDefaults.standard.set(trimmed.isEmpty ? preset.defaultModel : trimmed, forKey: asrModelKey)
    }
  }

  public static var resolvedASREndpointURL: URL {
    let preset = asrPreset
    if let url = URL(string: asrEndpoint),
       let scheme = url.scheme?.lowercased(),
       scheme == "https" {
      return url
    }
    return URL(string: preset.endpoint)!
  }

  public static var resolvedASRModel: String {
    let m = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
    return m.isEmpty ? asrPreset.defaultModel : m
  }

  static func asrSecretName(forProviderID providerID: String) -> String {
    let preset = OwlVoiceASRCatalog.preset(id: providerID)
    return "owltype.voice.asr.\(preset.id).apiKey"
  }

  static func readDedicatedASRAPIKey(
    forProviderID providerID: String,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) throws -> String? {
    let trimmed = (try secrets.secret(named: asrSecretName(forProviderID: providerID)))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  static func readConfiguredProfileKey(
    forProviderID providerID: String,
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) -> String? {
    let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    let candidates = store.profiles().filter { profile in
      OwlLLMProviderCatalog.inferredProviderID(for: profile) == normalized
    }
    let ordered = candidates.filter(\.isDefault) + candidates.filter { !$0.isDefault }
    for profile in ordered {
      if let raw = try? secrets.secret(named: profile.secretName) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    }
    return nil
  }

  static func readASRAPIKey(
    forProviderID providerID: String = asrProviderID,
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) throws -> String? {
    let preset = OwlVoiceASRCatalog.preset(id: providerID)
    if let dedicated = try readDedicatedASRAPIKey(forProviderID: preset.id, secrets: secrets) {
      return dedicated
    }
    if preset.sharesProviderProfileKey,
       let shared = readConfiguredProfileKey(forProviderID: preset.id, store: store, secrets: secrets) {
      return shared
    }
    return nil
  }

  static func readActiveASRAPIKey(
    defaults: UserDefaults = OwlDefaults.standard,
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) throws -> String? {
    let providerID = resolvedASRProviderID(defaults: defaults, store: store, secrets: secrets)
    return try readASRAPIKey(forProviderID: providerID, store: store, secrets: secrets)
  }

  static func isASRKeyConfigured(
    forProviderID providerID: String = asrProviderID,
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) -> Bool {
    guard let key = try? readASRAPIKey(forProviderID: providerID, store: store, secrets: secrets) else {
      return false
    }
    return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func saveASRAPIKey(
    _ key: String,
    forProviderID providerID: String = OwlVoiceASRCatalog.openai.id,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) throws {
    try secrets.setSecret(key, named: asrSecretName(forProviderID: providerID))
  }

  static func deleteASRAPIKey(
    forProviderID providerID: String = OwlVoiceASRCatalog.openai.id,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) throws {
    try secrets.deleteSecret(named: asrSecretName(forProviderID: providerID))
  }

  public static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: enabledKey)
    OwlDefaults.standard.removeObject(forKey: polishEnabledKey)
    OwlDefaults.standard.removeObject(forKey: holdRightOptionKey)
    OwlDefaults.standard.removeObject(forKey: asrProviderIDKey)
    OwlDefaults.standard.removeObject(forKey: asrEndpointKey)
    OwlDefaults.standard.removeObject(forKey: asrModelKey)
  }
}
