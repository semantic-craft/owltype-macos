//
//  OwlExperimentalPreferences.swift
//  猫头鹰输入法 (Owltype) — 实验性功能开关
//
//  UserDefaults home for default-OFF experimental toggles. Mirrors the established prefs pattern
//  (`OwlEmojiPreferences` / `OwlCloudPreferences`): the key string literal lives ONLY here; the
//  settings layer reads/writes through these accessors so there is no duplicate literal anywhere.
//
//  Boundary (ADR-0001 / 0002 / 0003): prefs layer only — never touches the IMK key-event hot
//  path (OwlInputController), the Rime main lane, or rime config/deploy.
//

import Foundation

enum OwlRerankModelKind: String, CaseIterable, Codable, Hashable, Sendable {
  case keyboard
  case settled
}

struct OwlRerankModelDescriptor: Equatable, Sendable {
  let kind: OwlRerankModelKind
  let title: String
  let fileName: String
  let expectedSize: UInt64
  let expectedSHA256: String
  let source: String
  let version: String
  let license: String

  static let keyboard = OwlRerankModelDescriptor(
    kind: .keyboard,
    title: "逐键候选重排",
    fileName: "keyboard-model.bin",
    expectedSize: 4_486_280,
    expectedSHA256: "86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1",
    source: "metasequoiaime/chinese-ime-lm",
    version: "model-v1",
    license: "Apache-2.0"
  )

  static let settled = OwlRerankModelDescriptor(
    kind: .settled,
    title: "停顿候选重排",
    fileName: "settled-model.bin",
    expectedSize: 25_480_184,
    expectedSHA256: "0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469",
    source: "metasequoiaime/chinese-ime-lm",
    version: "model-v1",
    license: "Apache-2.0"
  )

  static func descriptor(for kind: OwlRerankModelKind) -> Self {
    switch kind {
    case .keyboard: return .keyboard
    case .settled: return .settled
    }
  }

  var sha256Prefix: String {
    String(expectedSHA256.prefix(12))
  }

  func url(sharedSupportURL: URL?) -> URL? {
    sharedSupportURL?
      .appendingPathComponent("msime", isDirectory: true)
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent(fileName, isDirectory: false)
  }
}

struct OwlRerankRuntimeModelStatus: Equatable, Sendable {
  let state: String
  let error: String?
}

/// Thread-safe latest model state published by the input session that owns the FFI handle.
/// The settings window reads this snapshot only; it never calls the session itself.
final class OwlRerankRuntimeStatusRegistry: @unchecked Sendable {
  static let shared = OwlRerankRuntimeStatusRegistry()

  private let lock = NSLock()
  private var statuses: [OwlRerankModelKind: OwlRerankRuntimeModelStatus] = [:]

  private init() {}

  func update(kind: OwlRerankModelKind, state: String, error: String?) {
    lock.lock()
    statuses[kind] = OwlRerankRuntimeModelStatus(
      state: state,
      error: error?.isEmpty == false ? error : nil
    )
    lock.unlock()
  }

  func snapshot() -> [OwlRerankModelKind: OwlRerankRuntimeModelStatus] {
    lock.lock()
    defer { lock.unlock() }
    return statuses
  }

  func reset() {
    lock.lock()
    statuses.removeAll()
    lock.unlock()
  }
}

/// Single UserDefaults home for 实验性 toggles. Everything here is default-OFF: an experiment the
/// user opts into and can flip back off at any time with a complete no-op on shipping behaviour.
enum OwlExperimentalPreferences {
  private static let selectionPolishPromptVariantKey = "OwlExperimentalSelectionPolishPromptVariant"
  private static let keyboardRerankKey = "OwlExperimentalKeyboardRerankEnabled"
  private static let settledRerankKey = "OwlExperimentalSettledRerankEnabled"

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

  /// Upstream's lightweight per-key model. Default `false`; no model is loaded until the user
  /// opts in. The Rust runtime still protects exact dictionary, user-pinned, and generated
  /// candidates by their actual candidate source.
  static var keyboardRerankEnabled: Bool {
    get { boolValue(keyboardRerankKey) }
    set {
      OwlDefaults.standard.set(newValue, forKey: keyboardRerankKey)
      notifyRerankPreferencesChanged()
    }
  }

  /// Upstream's desktop model. It runs only after a 150 ms pause and never on the key path.
  /// Default `false`, matching the upstream optional-model configuration.
  static var settledRerankEnabled: Bool {
    get { boolValue(settledRerankKey) }
    set {
      OwlDefaults.standard.set(newValue, forKey: settledRerankKey)
      notifyRerankPreferencesChanged()
    }
  }

  static func rerankEnabled(for kind: OwlRerankModelKind) -> Bool {
    switch kind {
    case .keyboard: return keyboardRerankEnabled
    case .settled: return settledRerankEnabled
    }
  }

  private static func boolValue(_ key: String) -> Bool {
    OwlDefaults.standard.object(forKey: key) as? Bool ?? false
  }

  private static func notifyRerankPreferencesChanged() {
    NotificationCenter.default.post(name: .owlRerankPreferencesDidChange, object: nil)
  }

  /// Remove every experimental key — used by tests to restore the default-OFF baseline.
  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: selectionPolishPromptVariantKey)
    OwlDefaults.standard.removeObject(forKey: keyboardRerankKey)
    OwlDefaults.standard.removeObject(forKey: settledRerankKey)
    OwlRerankRuntimeStatusRegistry.shared.reset()
  }
}

extension Notification.Name {
  static let owlRerankPreferencesDidChange =
    Notification.Name("OwlExperimentalRerankPreferencesDidChange")
}
