//
//  OwlKeyboardSettingsCatalog.swift
//  猫头鹰输入法 (Owltype) — 键盘输入 on/off switches as one declarative table
//
//  Every boolean keyboard switch is one row: its UserDefaults key, its default, the
//  `OwlSettingsState` mirror it seeds, and how a change reaches input. The settings seed, the
//  page toggles and the Rust session's option sync all iterate this table, so adding a switch
//  costs one `case` and one row (plus the state mirror and any hot-path reader).
//
//  The keys and stored values are user data: never rename a key or change how a value is stored.
//  Multi-valued preferences (input method, schemes, page size, App 默认英文) keep their own
//  migrations in `OwlKeyboardPreferences`.
//

import Foundation

/// One boolean switch on the 键盘输入 page.
enum OwlKeyboardSwitch: Int, CaseIterable, Sendable {
  case wubiAutoCommitUnique
  case wubiFifthCodeTopCommit
  case wubiCodeHint
  case wubiZWildcard
  case wubiAutoClear
  case wubiZReverseLookup
  case wubiEnglishChannel
  case wubiUserDictLearning
  case quickPhraseCandidates
  case cjkPunctToggle
  case shiftSwitchCJK
  case goodOldCapsLock
  case pageMinusEquals
  case pageBrackets
  case pageCommaPeriod
  case select23Semicolon
  case slashSymbolMenu
  case angleSymbolMenu
  case traditionalOutput
  case defaultAsciiMode
  case defaultFullShape
  case autoPairBrackets
  case smartPunctuation
  case smartPunctuationRepeat
  case smartPunctuationSpace
  case cjkEnglishSpacing
  case cjkNumberSpacing

  /// How a stored change reaches input.
  enum Application: Equatable {
    /// The Rust session sends `set_option` with this name when the value changes.
    case engineOption(String)
    /// The Rust session owns this Rime option and re-asserts it on every sync
    /// (`applyASCIIPunctIfNeeded`), because the session's option flags must follow it too.
    case sessionOption(EngineOption)
    /// Host code reads the preference when it needs it; nothing is pushed.
    case host
  }

  struct Row {
    let key: String
    let defaultValue: Bool
    let mirror: ReferenceWritableKeyPath<OwlSettingsState, Bool>
    let application: Application
    /// The page re-applies the keyboard configuration after the toggle and reports the outcome
    /// in its status line.
    let reappliesConfiguration: Bool

    init(
      _ key: String,
      _ defaultValue: Bool,
      _ mirror: ReferenceWritableKeyPath<OwlSettingsState, Bool>,
      _ application: Application,
      reapplies: Bool
    ) {
      self.key = key
      self.defaultValue = defaultValue
      self.mirror = mirror
      self.application = application
      self.reappliesConfiguration = reapplies
    }
  }

  /// Built once: hot-path readers index this table instead of rebuilding a row per read.
  private static let rows = allCases.map(\.makeRow)

  var row: Row { Self.rows[rawValue] }
  var key: String { row.key }
  var defaultValue: Bool { row.defaultValue }

  // One row per switch: key, default, state mirror, application, page re-apply.
  // swiftlint:disable line_length
  private var makeRow: Row {
    switch self {
    case .wubiAutoCommitUnique: return Row("OwlKeyboardWubiAutoCommitUnique", true, \.keyboardWubiAutoCommitUnique, .engineOption("wubi_auto_commit_unique"), reapplies: true)
    case .wubiFifthCodeTopCommit: return Row("OwlKeyboardWubiFifthCodeTopCommit", true, \.keyboardWubiFifthCodeTopCommit, .engineOption("wubi_fifth_code_top_commit"), reapplies: true)
    case .wubiCodeHint: return Row("OwlKeyboardWubiCodeHint", true, \.keyboardWubiCodeHint, .engineOption("wubi_code_hint"), reapplies: true)
    case .wubiZWildcard: return Row("OwlKeyboardWubiZWildcard", false, \.keyboardWubiZWildcard, .engineOption("wubi_z_wildcard"), reapplies: true)
    case .wubiAutoClear: return Row("OwlKeyboardWubiAutoClear", false, \.keyboardWubiAutoClear, .engineOption("wubi_auto_clear"), reapplies: true)
    case .wubiZReverseLookup: return Row("OwlKeyboardWubiZReverseLookup", true, \.keyboardWubiZReverseLookup, .engineOption("wubi_z_reverse_lookup"), reapplies: true)
    case .wubiEnglishChannel: return Row("OwlKeyboardWubiEnglishChannel", false, \.keyboardWubiEnglishChannel, .engineOption("wubi_english_channel"), reapplies: true)
    case .wubiUserDictLearning: return Row("OwlKeyboardWubiUserDictLearning", true, \.keyboardWubiUserDictLearning, .engineOption("wubi_user_dict_learning"), reapplies: true)
    case .quickPhraseCandidates: return Row("OwlKeyboardPinyinQuickPhraseCandidates", false, \.quickPhraseCandidates, .engineOption("quick_phrase_candidates"), reapplies: false)
    case .cjkPunctToggle: return Row("OwlKeyboardCJKPunctToggle", false, \.keyboardCJKPunctToggle, .sessionOption(.asciiPunct), reapplies: true)
    case .shiftSwitchCJK: return Row("OwlKeyboardShiftSwitchCJK", true, \.keyboardShiftSwitchCJK, .host, reapplies: true)
    case .goodOldCapsLock: return Row("OwlKeyboardGoodOldCapsLock", true, \.keyboardGoodOldCapsLock, .host, reapplies: true)
    case .pageMinusEquals: return Row("OwlKeyboardPageMinusEquals", true, \.keyboardPageMinusEquals, .host, reapplies: true)
    case .pageBrackets: return Row("OwlKeyboardPageBrackets", true, \.keyboardPageBrackets, .host, reapplies: true)
    case .pageCommaPeriod: return Row("OwlKeyboardPageCommaPeriod", false, \.keyboardPageCommaPeriod, .host, reapplies: true)
    case .select23Semicolon: return Row("OwlKeyboardSelect23Semicolon", false, \.keyboardSelect23Semicolon, .host, reapplies: true)
    case .slashSymbolMenu: return Row("OwlKeyboardSlashSymbolMenu", false, \.keyboardSlashSymbolMenu, .host, reapplies: true)
    case .angleSymbolMenu: return Row("OwlKeyboardAngleSymbolMenu", false, \.keyboardAngleSymbolMenu, .host, reapplies: true)
    case .traditionalOutput: return Row("OwlKeyboardTraditionalOutput", false, \.keyboardTraditionalOutput, .host, reapplies: false)
    case .defaultAsciiMode: return Row("OwlKeyboardDefaultAsciiMode", false, \.keyboardDefaultAsciiMode, .host, reapplies: false)
    case .defaultFullShape: return Row("OwlKeyboardDefaultFullShape", false, \.keyboardDefaultFullShape, .host, reapplies: false)
    case .autoPairBrackets: return Row("OwlKeyboardAutoPairBrackets", true, \.keyboardAutoPairBrackets, .host, reapplies: false)
    case .smartPunctuation: return Row("OwlKeyboardSmartPunctuation", true, \.keyboardSmartPunctuation, .host, reapplies: false)
    case .smartPunctuationRepeat: return Row("OwlKeyboardSmartPunctuationRepeat", true, \.keyboardSmartPunctuationRepeat, .host, reapplies: false)
    case .smartPunctuationSpace: return Row("OwlKeyboardSmartPunctuationSpace", false, \.keyboardSmartPunctuationSpace, .host, reapplies: false)
    case .cjkEnglishSpacing: return Row("OwlKeyboardCJKEnglishSpacing", false, \.keyboardCJKEnglishSpacing, .host, reapplies: false)
    case .cjkNumberSpacing: return Row("OwlKeyboardCJKNumberSpacing", false, \.keyboardCJKNumberSpacing, .host, reapplies: false)
    }
  }
  // swiftlint:enable line_length
}

/// The 键盘输入 switches as one module: load, seed the settings state, set, and the engine
/// options the Rust session syncs. Mirrors `OwlCandidatePanelSettings.live.seed(state)`.
struct OwlKeyboardSettingsCatalog {
  /// The engine-option switches in catalog order. The Rust session keeps one last-applied slot
  /// per entry, so the per-keystroke sync allocates nothing and hashes no strings.
  static let engineOptions: [(name: String, toggle: OwlKeyboardSwitch)] =
    OwlKeyboardSwitch.allCases.compactMap { toggle in
      guard case .engineOption(let name) = toggle.row.application else { return nil }
      return (name, toggle)
    }

  static let live = OwlKeyboardSettingsCatalog(
    defaults: OwlDefaults.standard,
    didSet: OwlKeyboardPreferences.refreshCache
  )

  private let defaults: UserDefaults
  private let didSet: (OwlKeyboardSwitch, Bool) -> Void

  init(defaults: UserDefaults, didSet: @escaping (OwlKeyboardSwitch, Bool) -> Void = { _, _ in }) {
    self.defaults = defaults
    self.didSet = didSet
  }

  /// The stored value, or the row's default when the key was never written (not
  /// UserDefaults' implicit `false`).
  func load(_ toggle: OwlKeyboardSwitch) -> Bool {
    let row = toggle.row
    return defaults.object(forKey: row.key) == nil ? row.defaultValue : defaults.bool(forKey: row.key)
  }

  /// Every switch's current value.
  func load() -> [OwlKeyboardSwitch: Bool] {
    Dictionary(uniqueKeysWithValues: OwlKeyboardSwitch.allCases.map { ($0, load($0)) })
  }

  /// Settings-window seed: every switch mirror, plus the one UI switch derived from two keys.
  func seed(into state: OwlSettingsState) {
    for toggle in OwlKeyboardSwitch.allCases {
      state[keyPath: toggle.row.mirror] = load(toggle)
    }
    state.keyboardCJKAlnumSpacing = state.keyboardCJKEnglishSpacing || state.keyboardCJKNumberSpacing
  }

  /// Persist one switch. Hot-path caches are refreshed through `didSet`.
  func set(_ toggle: OwlKeyboardSwitch, _ value: Bool) {
    defaults.set(value, forKey: toggle.key)
    didSet(toggle, value)
  }
}
