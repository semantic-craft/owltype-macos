//
//  OwlVoiceSettings.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

enum OwlVoiceSettings {
  static let enabledKey = "OwlVoiceInputEnabled"
  static let xaiModelKey = "OwlVoiceXAIModel"
  static let polishEnabledKey = "OwlVoicePolishEnabled"
  static let deepSeekModelKey = "OwlVoiceDeepSeekModel"

  static var isEnabled: Bool {
    get {
      OwlDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: enabledKey)
    }
  }

  static var xaiModel: String {
    get {
      OwlDefaults.standard.string(forKey: xaiModelKey) ?? "grok-asr"
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: xaiModelKey)
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
