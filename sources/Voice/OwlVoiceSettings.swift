//
//  OwlVoiceSettings.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

struct OwlVoiceASRPreset: Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let endpoint: String
  let defaultModel: String
  let curatedModels: [String]
  let keyLabel: String
  let keyHint: String
  let sharesProviderProfileKey: Bool
}

enum OwlVoiceASRCatalog {
  static let grok = OwlVoiceASRPreset(
    id: "grok",
    displayName: "Grok (xAI)",
    endpoint: OwlVoiceSettings.defaultXAIEndpoint,
    defaultModel: OwlVoiceSettings.defaultXAIModel,
    curatedModels: [OwlVoiceSettings.defaultXAIModel, "grok-asr"],
    keyLabel: "xAI API Key",
    keyHint: "xai-…",
    sharesProviderProfileKey: true
  )

  static let qwen = OwlVoiceASRPreset(
    id: "qwen",
    displayName: "阿里云百炼 (Qwen)",
    endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/audio/transcriptions",
    defaultModel: "qwen3-asr-flash-realtime",
    curatedModels: ["qwen3-asr-flash-realtime", "fun-asr-realtime"],
    keyLabel: "百炼 API Key",
    keyHint: "sk-…",
    sharesProviderProfileKey: true
  )

  static let doubao = OwlVoiceASRPreset(
    id: "doubao",
    displayName: "火山引擎 · 豆包",
    endpoint: "https://openspeech.bytedance.com/api/v3/sauc/bigmodel",
    defaultModel: "bigmodel",
    curatedModels: ["bigmodel", "volc.bigasr.sauc.duration"],
    keyLabel: "豆包语音 API Key",
    keyHint: "火山语音控制台 API Key",
    sharesProviderProfileKey: false
  )

  static let openai = OwlVoiceASRPreset(
    id: "openai",
    displayName: "OpenAI",
    endpoint: "https://api.openai.com/v1/audio/transcriptions",
    defaultModel: "gpt-live-transcribe",
    curatedModels: ["gpt-live-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"],
    keyLabel: "OpenAI API Key",
    keyHint: "sk-…",
    sharesProviderProfileKey: true
  )

  static let gemini = OwlVoiceASRPreset(
    id: "gemini",
    displayName: "Google Gemini",
    endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/audio/transcriptions",
    defaultModel: "gemini-3.5-transcribe-live",
    curatedModels: ["gemini-3.5-transcribe-live", "gemini-3.8-flash"],
    keyLabel: "Gemini API Key",
    keyHint: "AIza…",
    sharesProviderProfileKey: true
  )

  /// 语音识别预设目录：覆盖具备全产品线能力的 5 家供应商（Grok / 百炼 Qwen / 豆包 / OpenAI / Gemini）。
  static let presets: [OwlVoiceASRPreset] = [grok, qwen, doubao, openai, gemini]

  static func preset(id: String) -> OwlVoiceASRPreset {
    presets.first { $0.id == id } ?? grok
  }
}

enum OwlVoiceSettings {
  static let enabledKey = "OwlVoiceInputEnabled"
  static let asrProviderIDKey = "OwlVoiceASRProviderID"
  static let xaiEndpointKey = "OwlVoiceXAIEndpoint"
  static let xaiModelKey = "OwlVoiceXAIModel"
  static let polishEnabledKey = "OwlVoicePolishEnabled"
  static let deepSeekModelKey = "OwlVoiceDeepSeekModel"

  static let defaultXAIEndpoint = "https://api.x.ai/v1/audio/transcriptions"
  static let defaultXAIModel = "grok-voice-transcribe-2.0"

  static var isEnabled: Bool {
    get {
      OwlDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: enabledKey)
    }
  }

  static var asrProviderID: String {
    get {
      let raw = OwlDefaults.standard.string(forKey: asrProviderIDKey) ?? OwlVoiceASRCatalog.grok.id
      return OwlVoiceASRCatalog.preset(id: raw).id
    }
    set {
      OwlDefaults.standard.set(OwlVoiceASRCatalog.preset(id: newValue).id, forKey: asrProviderIDKey)
    }
  }

  static var xaiEndpoint: String {
    get {
      guard let raw = OwlDefaults.standard.string(forKey: xaiEndpointKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty,
        let url = URL(string: raw),
        OwlProviderRegistry.isHTTPS(url) else {
        return OwlVoiceASRCatalog.preset(id: asrProviderID).endpoint
      }
      return raw
    }
    set {
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        OwlDefaults.standard.removeObject(forKey: xaiEndpointKey)
      } else {
        OwlDefaults.standard.set(trimmed, forKey: xaiEndpointKey)
      }
    }
  }

  static var xaiEndpointURL: URL {
    URL(string: xaiEndpoint) ?? URL(string: defaultXAIEndpoint)!
  }

  static var xaiModel: String {
    get {
      guard let raw = OwlDefaults.standard.string(forKey: xaiModelKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty else {
        return OwlVoiceASRCatalog.preset(id: asrProviderID).defaultModel
      }
      return raw
    }
    set {
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        OwlDefaults.standard.removeObject(forKey: xaiModelKey)
      } else {
        OwlDefaults.standard.set(trimmed, forKey: xaiModelKey)
      }
    }
  }

  static var isPolishEnabled: Bool {
    get {
      OwlDefaults.standard.object(forKey: polishEnabledKey) as? Bool ?? false
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: polishEnabledKey)
    }
  }

  static var deepSeekModel: String {
    get {
      OwlDefaults.standard.string(forKey: deepSeekModelKey) ?? "deepseek-chat"
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: deepSeekModelKey)
    }
  }

  static var hotkey: OwlRecordedHotKey? {
    OwlHotKeySlot.voiceInput.current
  }
}
