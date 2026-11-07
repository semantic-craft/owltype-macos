//
//  OwlKeyboardPreferences.swift
//  猫头鹰输入法 (Owltype) — 键盘输入 settings preferences
//
//  v0.3.1: the option-group choices shown on the 键盘输入 page (输入方式 / 中英文切换
//  / 翻页键 / 快速选词 / 符号). Persisted in UserDefaults (Owltype-namespaced), mirroring
//  `OwlCandidatePanelSettings`: every key string literal lives ONLY in this file, and the
//  settings layer reads/writes through these accessors so there are no duplicate
//  literals anywhere else.
//
//  Persistence boundary (see `.trellis/spec/frontend/owl-modern-ui-direction.md`):
//  these options ultimately map to Rime YAML. Preferences stay in UserDefaults; the
//  explicit write preview sheet is the only path that writes Owltype's user_data_dir and
//  calls deploy after the user confirms.
//
//  Boundary (ADR-0001 / 0002 / 0003): prefs layer only. Runtime convenience helpers
//  must stay pure string transforms when called from OwlInputController.
//
//  Concurrency: plain `Sendable` value enums; the accessors run on the main thread
//  like the rest of the candidate / settings UI.
//

import Foundation

/// Input method family. These are the first-class local modes shown on the 键盘输入 page.
/// Eventual Rime mapping: the active `schema_id` + mode-specific Rime patch.
enum OwlInputMethod: String, CaseIterable, Sendable, Encodable {
  case pinyin
  case doublePinyin
  /// 五笔输入 (参照微信). The 86/拼音混输 sub-choice moved into the `OwlWubiScheme` dropdown,
  /// replacing the former `.wubi86` / `.wubiPinyin` radios (migrated in `inputMethod`'s getter).
  case wubi

  var displayName: String {
    switch self {
    case .pinyin: return "拼音输入"
    case .doublePinyin: return "双拼输入"
    case .wubi: return "五笔输入"
    }
  }

  func schemaId(doublePinyin: OwlDoublePinyin, wubiScheme: OwlWubiScheme) -> String {
    let value: OwlAppCore.EffectiveKeyboard = OwlAppCore.required([
      "operation": "keyboard_effective", "raw": ["inputMethod": rawValue,
        "doublePinyin": doublePinyin.rawValue, "wubiScheme": wubiScheme.rawValue]])
    return value.preferredSchemaID
  }
}

/// 五笔方案 sub-selection shown in the 输入方式 dropdown when 五笔输入 is active — mirrors the
/// 双拼 dropdown pattern. 简入繁出 remains available through the global toggle.
enum OwlWubiScheme: String, CaseIterable, Sendable, Encodable {
  case jidian86
  case pinyinMix
  case jidian98
  case pinyinMix98

  var displayName: String {
    switch self {
    case .jidian86: return "86 版五笔"
    case .pinyinMix: return "86 版五笔拼音混输"
    case .jidian98: return "98 版五笔"
    case .pinyinMix98: return "98 版五笔拼音混输"
    }
  }

  var schemaId: String {
    OwlAppCore.keyboardCatalog.wubiSchemas[rawValue]!
  }
}

enum OwlWubiCandidateMode: String, CaseIterable, Sendable, Encodable {
  case normal
  case singleFirst
  case singleOnly

  var displayName: String {
    switch self {
    case .normal: return "默认"
    case .singleFirst: return "单字优先"
    case .singleOnly: return "纯单字"
    }
  }

  var luaFilter: String? {
    OwlAppCore.keyboardCatalog.candidateFilters[rawValue] ?? nil
  }
}

/// 双拼 scheme. Display the 中文 name; expose the rime-ice `schema_id` as a real
/// computed property (used by the patch builder's commented schema hint). The 7 cases
/// match rime-ice's bundled double-pinyin schemas exactly (verified against
/// `rime_ice.schema.yaml`, see `packages/rime-law-config/CONFIG-DESIGN.md`):
/// 自然码 is the base `double_pinyin` (NOT `double_pinyin_ziranma`), and 拼音加加 is
/// `double_pinyin_jiajia` (there is no `double_pinyin_pyjj`).
///
/// These prefs are unreleased, so the `String` raw values may change freely.
enum OwlDoublePinyin: String, CaseIterable, Sendable, Encodable {
  /// 小鹤双拼 — rime-ice `schema_id`: `double_pinyin_flypy`. Owltype default.
  case flypy
  /// 微软双拼 — rime-ice `schema_id`: `double_pinyin_mspy`.
  case mspy
  /// 手心双拼 — pinned upstream built-in profile.
  case shoudao
  /// 自然码双拼 — rime-ice `schema_id`: `double_pinyin` (the base double-pinyin schema).
  case ziranma
  /// 搜狗双拼 — rime-ice `schema_id`: `double_pinyin_sogou`.
  case sogou
  /// 智能ABC双拼 — rime-ice `schema_id`: `double_pinyin_abc`.
  case abc
  /// 紫光双拼 — rime-ice `schema_id`: `double_pinyin_ziguang`.
  case ziguang
  /// 拼音加加双拼 — rime-ice `schema_id`: `double_pinyin_jiajia`.
  case jiajia

  /// 中文 menu label.
  var displayName: String {
    switch self {
    case .flypy: return "小鹤双拼"
    case .mspy: return "微软双拼"
    case .shoudao: return "手心双拼"
    case .ziranma: return "自然码双拼"
    case .sogou: return "搜狗双拼"
    case .abc: return "智能ABC双拼"
    case .ziguang: return "紫光双拼"
    case .jiajia: return "拼音加加双拼"
    }
  }

  /// rime-ice `schema_id` — the real schema id used by the commented schema hint in
  /// the generated `default.custom.yaml` patch.
  var schemaId: String {
    OwlAppCore.keyboardCatalog.doublePinyinSchemas[rawValue]!
  }
}

/// Single home for the 键盘输入 page preferences. Multi-valued preferences keep their keys and
/// migrations here; every on/off switch is a row of `OwlKeyboardSettingsCatalog`, and its
/// accessor below only forwards, so callers keep reading `OwlKeyboardPreferences.x`.
enum OwlKeyboardPreferences {
  // MARK: - 输入方式

  /// 拼音 / 双拼. Key `"OwlKeyboardInputMethod"`, default `.pinyin`.
  /// Eventual Rime mapping: active `schema_id` + `speller/algebra`.
  static var inputMethod: OwlInputMethod {
    get {
      OwlInputMethod(rawValue: OwlAppCore.effectiveKeyboard.inputMethod)!
    }
    set {
      OwlDefaults.standard.set(newValue.rawValue, forKey: "OwlKeyboardInputMethod")
    }
  }

  /// 五笔方案. Key `"OwlKeyboardWubiScheme"`, default `.jidian86`.
  /// 迁移：key 未写且 legacy inputMethod 原值为 `"wubiPinyin"` 时回到 `.pinyinMix`，保住老用户的混输选择。
  static var wubiScheme: OwlWubiScheme {
    get {
      OwlWubiScheme(rawValue: OwlAppCore.effectiveKeyboard.wubiScheme)!
    }
    set {
      OwlDefaults.standard.set(newValue.rawValue, forKey: "OwlKeyboardWubiScheme")
    }
  }

  static var pageSize: Int {
    get {
      OwlAppCore.effectiveKeyboard.pageSize
    }
    set {
      let value: Int = OwlAppCore.required(["operation": "keyboard_page_size_write", "value": newValue])
      OwlDefaults.standard.set(value, forKey: "OwlKeyboardPageSize")
    }
  }

  /// 双拼方案. Key `"OwlKeyboardDoublePinyin"`, default `.flypy` (小鹤双拼).
  /// Eventual Rime mapping: the chosen scheme's `schema_id`.
  static var doublePinyin: OwlDoublePinyin {
    get {
      OwlDoublePinyin(rawValue: OwlAppCore.effectiveKeyboard.doublePinyin)!
    }
    set {
      OwlDefaults.standard.set(newValue.rawValue, forKey: "OwlKeyboardDoublePinyin")
    }
  }

  /// The schema a new engine session must use to match the settings source of truth.
  /// Keeps stale `user.yaml` `previously_selected_schema` values from overriding Owltype prefs.
  static var preferredSchemaID: String {
    OwlAppCore.effectiveKeyboard.preferredSchemaID
  }

  // MARK: - 五笔

  /// 五笔完整四码只有一个候选时自动提交；与水杉默认值一致。
  static var wubiAutoCommitUnique: Bool {
    get { catalog.load(.wubiAutoCommitUnique) }
    set { catalog.set(.wubiAutoCommitUnique, newValue) }
  }

  /// 完整四码后的字母顶字上屏。关闭只影响五笔拼音混输，纯五笔仍顶字保留第五码。
  static var wubiFifthCodeTopCommit: Bool {
    get { catalog.load(.wubiFifthCodeTopCommit) }
    set { catalog.set(.wubiFifthCodeTopCommit, newValue) }
  }

  /// 优先显示候选尚未输入的五笔编码；无剩余码时沿用引擎完整编码注释。
  static var wubiCodeHint: Bool {
    get { catalog.load(.wubiCodeHint) }
    set { catalog.set(.wubiCodeHint, newValue) }
  }

  /// z 匹配未知码位；开启时由引擎暂停临时拼音反查，与水杉默认关闭一致。
  static var wubiZWildcard: Bool {
    get { catalog.load(.wubiZWildcard) }
    set { catalog.set(.wubiZWildcard, newValue) }
  }

  /// 空码自动清码. Key `"OwlKeyboardWubiAutoClear"`, default `false`.
  /// Eventual Rime mapping: `speller/auto_clear: max_length`.
  static var wubiAutoClear: Bool {
    get { catalog.load(.wubiAutoClear) }
    set { catalog.set(.wubiAutoClear, newValue) }
  }

  /// 单字候选模式. Key `"OwlKeyboardWubiCandidateMode"`, default `.normal`.
  /// Eventual Rime mapping: one of the bundled `wubi86_jidian_*` Lua filters.
  static var wubiCandidateMode: OwlWubiCandidateMode {
    get {
      OwlWubiCandidateMode(rawValue: OwlAppCore.effectiveKeyboard.candidateMode)!
    }
    set {
      OwlDefaults.standard.set(newValue.rawValue, forKey: "OwlKeyboardWubiCandidateMode")
    }
  }

  /// z 临时拼音反查. Key `"OwlKeyboardWubiZReverseLookup"`, default `true`.
  /// Rime mapping: `recognizer/patterns/reverse_lookup`（关闭时清空反查正则，z 不再触发拼音反查）.
  static var wubiZReverseLookup: Bool {
    get { catalog.load(.wubiZReverseLookup) }
    set { catalog.set(.wubiZReverseLookup, newValue) }
  }

  /// ` 临时英文（五笔前缀英文通道）. Key `"OwlKeyboardWubiEnglishChannel"`, default `false`（出厂关）.
  /// Rime mapping: 仿 z 反查的前缀通道——` 进 speller/alphabet + affix_segmentor@melt_eng +
  /// table_translator@melt_eng（词库 melt_eng，拼音线正在用的同一份）+ recognizer 正则。
  /// 前缀段不受五笔四码上屏影响（z+拼音 >4 码同理，活先例）。
  static var wubiEnglishChannel: Bool {
    get { catalog.load(.wubiEnglishChannel) }
    set { catalog.set(.wubiEnglishChannel, newValue) }
  }

  /// 记住我常用的词（个性化）. Key `"OwlKeyboardWubiUserDictLearning"`, default `true` (native MSIME).
  /// Rust learning and its shared journal own selection frequency, composed words and restart replay.
  static var wubiUserDictLearning: Bool {
    get { catalog.load(.wubiUserDictLearning) }
    set { catalog.set(.wubiUserDictLearning, newValue) }
  }

  // MARK: - 中英文状态切换

  /// 使用 Shift 切换中英文. Key `"OwlKeyboardShiftSwitchCJK"`, default `true`.
  /// Eventual Rime mapping: `ascii_composer/switch_key/Shift_L` + `Shift_R`（左/右 Shift 都切）.
  static var shiftSwitchCJK: Bool {
    get { catalog.load(.shiftSwitchCJK) }
    set { catalog.set(.shiftSwitchCJK, newValue) }
  }

  /// 中文下中英标点切换. Key `"OwlKeyboardCJKPunctToggle"`, default `false`.
  /// Eventual Rime mapping: `ascii_punct` switch.
  static var cjkPunctToggle: Bool {
    get { catalog.load(.cjkPunctToggle) }
    set { catalog.set(.cjkPunctToggle, newValue) }
  }

  /// 简入繁出 (简↔繁), 全局开关. Key `"OwlKeyboardTraditionalOutput"`, default `false` (简体).
  /// Runtime Rime mapping: the FULL simplification option set — `transcription` (全拼/双拼
  /// `simplifier@transcription_cc`) AND `zh_trad` (五笔 `simplifier@tradition`), plus the legacy
  /// `traditional`/`traditionalization`/`simplification` — so one switch covers every exposed
  /// schema. NOT a patch key — applied live via `setTraditionalOutputOptions(…)` + seeded on
  /// session create.
  static var traditionalOutput: Bool {
    get { catalog.load(.traditionalOutput) }
    set { catalog.set(.traditionalOutput, newValue) }
  }

  // MARK: - 默认状态 (搜狗式：新会话 / 切 App 时的初始态)

  /// 中英文默认态. Key `"OwlKeyboardDefaultAsciiMode"`, default `false` (中文).
  /// `true` = 英文 (`ascii_mode` on). Seeded on session create BEFORE `updateAppOptions()`,
  /// so per-app「默认英文」(app_options) still wins where listed.
  static var defaultAsciiMode: Bool {
    get { catalog.load(.defaultAsciiMode) }
    set { catalog.set(.defaultAsciiMode, newValue) }
  }

  /// 全半角默认态. Key `"OwlKeyboardDefaultFullShape"`, default `false` (半角).
  /// `true` = 全角 (`full_shape` on). Seeded on session create so the choice survives focus changes.
  static var defaultFullShape: Bool {
    get { catalog.load(.defaultFullShape) }
    set { catalog.set(.defaultFullShape, newValue) }
  }

  // MARK: - 中英文切换键动作 (ascii_composer/switch_key)

  /// 经典 Caps Lock 切换西文. Key `"OwlKeyboardGoodOldCapsLock"`, default `true` (经典 Caps Lock 行为).
  /// Rime mapping: `ascii_composer/good_old_caps_lock`. Only written when `shiftSwitchCJK` is on.
  static var goodOldCapsLock: Bool {
    get { catalog.load(.goodOldCapsLock) }
    set { catalog.set(.goodOldCapsLock, newValue) }
  }

  // MARK: - 候选翻页快捷键

  /// 减号等号翻页. Key `"OwlKeyboardPageMinusEquals"`, default `true`.
  /// Eventual Rime mapping: `key_binder` page_up `minus` / page_down `equal`.
  static var pageMinusEquals: Bool {
    get { catalog.load(.pageMinusEquals) }
    set { catalog.set(.pageMinusEquals, newValue) }
  }

  /// 左右中括号翻页. Key `"OwlKeyboardPageBrackets"`, default `false`
  /// (水杉 keeps `[` `]` for 以词定字; #315).
  /// Eventual Rime mapping: `key_binder` page_up `bracketleft` / page_down `bracketright`.
  static var pageBrackets: Bool {
    get { catalog.load(.pageBrackets) }
    set { catalog.set(.pageBrackets, newValue) }
  }

  /// 逗号句号翻页. Key `"OwlKeyboardPageCommaPeriod"`, default `true`
  /// (水杉 default; #315).
  /// Eventual Rime mapping: `key_binder` page_up `comma` / page_down `period`.
  static var pageCommaPeriod: Bool {
    get { catalog.load(.pageCommaPeriod) }
    set { catalog.set(.pageCommaPeriod, newValue) }
  }

  // MARK: - 候选快速选词

  /// 分号引号选 2/3 位. Key `"OwlKeyboardSelect23Semicolon"`, default `false`.
  /// Eventual Rime mapping: `key_binder` select 2nd (`semicolon`) / 3rd (`apostrophe`).
  static var select23Semicolon: Bool {
    get { catalog.load(.select23Semicolon) }
    set { catalog.set(.select23Semicolon, newValue) }
  }

  // MARK: - 符号

  /// 输入中文时 "/" 弹出符号选单（、/／÷）。Key `"OwlKeyboardSlashSymbolMenu"`,
  /// default `false`：关闭时维持猫头鹰的编程便利行为——裸 `/` 提交当前中文候选、切到英文并
  /// 输出 ASCII `/`；打开后前端不再抢占该键，交给 Rime punctuator 显示候选。
  /// Runtime reads the cached value on the key-event hot path; the generated default patch supplies
  /// both half/full-shape candidate lists.
  static var slashSymbolMenu: Bool {
    get { cachedSlashSymbolMenu }
    set { catalog.set(.slashSymbolMenu, newValue) }
  }

  /// 输入中文时 "<" 弹出符号选单（《〈 ASCII< 「【）。Key `"OwlKeyboardAngleSymbolMenu"`,
  /// default `false`（出厂关，与成对输入家族同策：不惊扰存量用户的 `<`→《 直上屏）。
  /// Eventual Rime mapping: `punctuator/half_shape/<` → 单字符候选列表（拼音/五笔 schema 均
  /// import_preset: default，一份 patch 通吃）；选出 ASCII `<` 后由自动配对（已含 ASCII 表）补对。
  static var angleSymbolMenu: Bool {
    get { catalog.load(.angleSymbolMenu) }
    set { catalog.set(.angleSymbolMenu, newValue) }
  }

  // MARK: - 本地便捷输入

  /// 中文与英文间加入空格. One UI switch, backed by the two legacy runtime flags.
  static var cjkAlnumSpacing: Bool {
    get { cjkEnglishSpacing || cjkNumberSpacing }
    set {
      cjkEnglishSpacing = newValue
      cjkNumberSpacing = newValue
    }
  }

  /// 中英文自动空格. Key `"OwlKeyboardCJKEnglishSpacing"`, default `false`.
  /// Runtime mapping: cached flag + pure commit-text transform in `OwlCommitTransform`.
  static var cjkEnglishSpacing: Bool {
    get { cachedCJKEnglishSpacing }
    set { catalog.set(.cjkEnglishSpacing, newValue) }
  }

  /// 中文与数字自动空格. Key `"OwlKeyboardCJKNumberSpacing"`, default `false`.
  /// Runtime mapping: cached flag + pure commit-text transform in `OwlCommitTransform`.
  static var cjkNumberSpacing: Bool {
    get { cachedCJKNumberSpacing }
    set { catalog.set(.cjkNumberSpacing, newValue) }
  }

  /// 自动配对括号 (task 07-02). Key `"OwlKeyboardAutoPairBrackets"`, native pinyin default `true`
  /// Native pinyin keeps a marked closing tail; Wubi retains its original opt-in
  /// pair decision. The setting applies immediately without an engine deployment.
  /// Shared native mixed_input.quick_phrase preference; retain the original persisted key.
  /// Fresh installs default off for all schemes; K browsing stays available.
  static var quickPhraseCandidates: Bool {
    get { catalog.load(.quickPhraseCandidates) }
    set { catalog.set(.quickPhraseCandidates, newValue) }
  }

  static var smartPunctuation: Bool {
    get { catalog.load(.smartPunctuation) }
    set { catalog.set(.smartPunctuation, newValue) }
  }
  static var smartPunctuationRepeat: Bool {
    get { catalog.load(.smartPunctuationRepeat) }
    set { catalog.set(.smartPunctuationRepeat, newValue) }
  }
  static var smartPunctuationSpace: Bool {
    get { catalog.load(.smartPunctuationSpace) }
    set { catalog.set(.smartPunctuationSpace, newValue) }
  }

  static var autoPairBrackets: Bool {
    get {
      if OwlDefaults.standard.object(forKey: OwlKeyboardSwitch.autoPairBrackets.key) == nil {
        return OwlKeyboardSwitch.autoPairBrackets.defaultValue
      }
      return cachedAutoPairBrackets
    }
    set { catalog.set(.autoPairBrackets, newValue) }
  }

  /// 这些 App 默认英文. Key `"OwlKeyboardAppEnglishBundleIDs"`, default `[]`.
  /// Runtime mapping: generated Rime `app_options/<bundle id>/ascii_mode: true`.
  static var appEnglishBundleIDs: [String] {
    get { OwlDefaults.standard.stringArray(forKey: "OwlKeyboardAppEnglishBundleIDs") ?? [] }
    set {
      OwlDefaults.standard.set(
        normalizedAppEnglishBundleIDs(from: newValue.joined(separator: "\n")),
        forKey: "OwlKeyboardAppEnglishBundleIDs"
      )
    }
  }

  static func normalizedAppEnglishBundleIDs(from raw: String) -> [String] {
    OwlAppCore.required(["operation": "keyboard_bundle_ids", "raw": raw])
  }

  // MARK: - Helpers

  /// The switches' keys, defaults and persistence live in the catalog; these accessors forward.
  private static var catalog: OwlKeyboardSettingsCatalog { .live }

  // Read on the key-event hot path, so they are cached rather than read from defaults.
  private static var cachedCJKEnglishSpacing = catalog.load(.cjkEnglishSpacing)
  private static var cachedCJKNumberSpacing = catalog.load(.cjkNumberSpacing)
  private static var cachedAutoPairBrackets = catalog.load(.autoPairBrackets)
  private static var cachedSlashSymbolMenu = catalog.load(.slashSymbolMenu)

  /// The live catalog calls this after every write so the hot-path caches follow defaults.
  static func refreshCache(_ toggle: OwlKeyboardSwitch, _ value: Bool) {
    switch toggle {
    case .cjkEnglishSpacing: cachedCJKEnglishSpacing = value
    case .cjkNumberSpacing: cachedCJKNumberSpacing = value
    case .autoPairBrackets: cachedAutoPairBrackets = value
    case .slashSymbolMenu: cachedSlashSymbolMenu = value
    default: break
    }
  }


}

enum OwlCommitTransform {
  static func apply(to text: String, previous previousCharacter: Character? = nil) -> String {
    let cjkAlnumSpacing = OwlKeyboardPreferences.cjkAlnumSpacing
    return apply(
      to: text,
      cjkEnglishSpacing: cjkAlnumSpacing,
      cjkNumberSpacing: cjkAlnumSpacing,
      previous: previousCharacter
    )
  }

  static func apply(
    to text: String,
    cjkEnglishSpacing: Bool,
    cjkNumberSpacing: Bool,
    previous previousCharacter: Character? = nil
  ) -> String {
    OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "commit_transform_apply",
      "args": [
        "text": text,
        "cjk_english_spacing": cjkEnglishSpacing,
        "cjk_number_spacing": cjkNumberSpacing,
        "previous": previousCharacter.map(String.init) as Any? ?? NSNull()
      ]
    ])
  }

  private enum BoundaryKind {
    case cjk
    case latin
    case digit

    init?(_ character: Character) {
      let scalars = character.unicodeScalars
      if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
        return nil
      }
      if scalars.contains(where: Self.isCJK) {
        self = .cjk
      } else if scalars.allSatisfy(Self.isASCIILetter) {
        self = .latin
      } else if scalars.allSatisfy(Self.isASCIIDigit) {
        self = .digit
      } else {
        return nil
      }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
      switch scalar.value {
      case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
        return true
      default:
        return false
      }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
      switch scalar.value {
      case 65...90, 97...122:
        return true
      default:
        return false
      }
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
      (48...57).contains(scalar.value)
    }
  }

  private static func needsSpace(
    _ left: BoundaryKind,
    _ right: BoundaryKind,
    cjkEnglishSpacing: Bool,
    cjkNumberSpacing: Bool
  ) -> Bool {
    switch (left, right) {
    case (.cjk, .latin), (.latin, .cjk):
      return cjkEnglishSpacing
    case (.cjk, .digit), (.digit, .cjk):
      return cjkNumberSpacing
    default:
      return false
    }
  }
}
