//
//  FamoExperimentalPreferences.swift
//  法墨输入法 (Famo) — 实验性功能开关 (task 06-22-backspace-typo-correction)
//
//  UserDefaults home for default-OFF experimental toggles. Current tenant: 退格 LM 纠错
//  (`backspaceCorrectionEnabled`). Mirrors the established prefs pattern (`FamoEmojiPreferences` /
//  `FamoCloudPreferences`): the key string literal lives ONLY here; the settings layer and the
//  smart-lane wiring read/write through these accessors so there is no duplicate literal anywhere.
//
//  Boundary (ADR-0001 / 0002 / 0003): prefs layer only — never touches the IMK key-event hot
//  path (FamoInputController), the Rime main lane, or rime config/deploy.
//

import Foundation

/// Single UserDefaults home for 实验性 toggles. Everything here is default-OFF: an experiment the
/// user opts into and can flip back off at any time with a complete no-op on shipping behaviour.
enum FamoExperimentalPreferences {
  private static let backspaceCorrectionKey = "FamoExperimentalBackspaceCorrectionEnabled"
  private static let selectionPolishPromptVariantKey = "FamoExperimentalSelectionPolishPromptVariant"

  /// 退格 LM 纠错 (smart lane only). Default `false`. When on, backspacing over just-converted
  /// Chinese text requests an on-device CSC (macbert4csc) pass on the remaining run; if the model
  /// proposes a different character string it is surfaced as a smart-lane correction candidate
  /// through the snapshotID-gated upsert. When off — or when no model is bundled — this is a
  /// complete no-op (no scorer built, no candidate). The Rime main lane and the IMK hot path are
  /// untouched. Persisted in UserDefaults.
  static var backspaceCorrectionEnabled: Bool {
    get { FamoDefaults.standard.object(forKey: backspaceCorrectionKey) as? Bool ?? false }
    set { FamoDefaults.standard.set(newValue, forKey: backspaceCorrectionKey) }
  }

  /// 润色提示词 A/B 变体 id (issue #136). Default `nil` — 未设置即 v1-legacy 出厂行为，与其他
  /// 实验开关同样的 default-OFF 纪律。This is a dumb raw-string accessor on purpose: resolution
  /// and the unknown-value → v1 fallback live in `FamoPolishPromptCatalog.variant(id:)`, so a
  /// stale or mistyped value can never crash the polish path. Persisted in UserDefaults.
  static var selectionPolishPromptVariant: String? {
    get { FamoDefaults.standard.string(forKey: selectionPolishPromptVariantKey) }
    set {
      if let newValue {
        FamoDefaults.standard.set(newValue, forKey: selectionPolishPromptVariantKey)
      } else {
        FamoDefaults.standard.removeObject(forKey: selectionPolishPromptVariantKey)
      }
    }
  }

  /// Remove every experimental key — used by tests to restore the default-OFF baseline.
  static func resetForTesting() {
    FamoDefaults.standard.removeObject(forKey: backspaceCorrectionKey)
    FamoDefaults.standard.removeObject(forKey: selectionPolishPromptVariantKey)
  }
}
