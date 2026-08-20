//
//  OwlExperimentalPreferences.swift
//  猫头鹰输入法 (Owltype) — 实验性功能开关 (task 06-22-backspace-typo-correction)
//
//  UserDefaults home for default-OFF experimental toggles. Current tenant: 退格 LM 纠错
//  (`backspaceCorrectionEnabled`). Mirrors the established prefs pattern (`OwlEmojiPreferences` /
//  `OwlCloudPreferences`): the key string literal lives ONLY here; the settings layer and the
//  smart-lane wiring read/write through these accessors so there is no duplicate literal anywhere.
//
//  Boundary (ADR-0001 / 0002 / 0003): prefs layer only — never touches the IMK key-event hot
//  path (OwlInputController), the Rime main lane, or rime config/deploy.
//

import Foundation

/// Single UserDefaults home for 实验性 toggles. Everything here is default-OFF: an experiment the
/// user opts into and can flip back off at any time with a complete no-op on shipping behaviour.
enum OwlExperimentalPreferences {
  private static let backspaceCorrectionKey = "OwlExperimentalBackspaceCorrectionEnabled"
  private static let selectionPolishPromptVariantKey = "OwlExperimentalSelectionPolishPromptVariant"

  /// 退格 LM 纠错 (smart lane only). Default `false`. When on, backspacing over just-converted
  /// Chinese text requests an on-device CSC (macbert4csc) pass on the remaining run; if the model
  /// proposes a different character string it is surfaced as a smart-lane correction candidate
  /// through the snapshotID-gated upsert. When off — or when no model is bundled — this is a
  /// complete no-op (no scorer built, no candidate). The Rime main lane and the IMK hot path are
  /// untouched. Persisted in UserDefaults.
  static var backspaceCorrectionEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: backspaceCorrectionKey) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: backspaceCorrectionKey) }
  }

  /// 润色提示词 A/B 变体 id (issue #136). Default `nil` — 未设置即 v1-legacy 出厂行为，与其他
  /// 实验开关同样的 default-OFF 纪律。This is a dumb raw-string accessor on purpose: resolution
  /// and the unknown-value → v1 fallback live in `OwlPolishPromptCatalog.variant(id:)`, so a
  /// stale or mistyped value can never crash the polish path. Persisted in UserDefaults.
  static var selectionPolishPromptVariant: String? {
    get { OwlDefaults.standard.string(forKey: selectionPolishPromptVariantKey) }
    set {
      if let newValue {
        OwlDefaults.standard.set(newValue, forKey: selectionPolishPromptVariantKey)
      } else {
        OwlDefaults.standard.removeObject(forKey: selectionPolishPromptVariantKey)
      }
    }
  }

  /// Remove every experimental key — used by tests to restore the default-OFF baseline.
  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: backspaceCorrectionKey)
    OwlDefaults.standard.removeObject(forKey: selectionPolishPromptVariantKey)
  }
}
