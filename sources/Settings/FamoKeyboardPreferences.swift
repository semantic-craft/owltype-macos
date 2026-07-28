//
//  FamoKeyboardPreferences.swift
//  法墨输入法 (Famo) — 键盘输入 settings preferences
//
//  v0.3.1: the option-group choices shown on the 键盘输入 page (输入方式 / 中英文切换
//  / 翻页键 / 快速选词 / 符号). Persisted in UserDefaults (Famo-namespaced), mirroring
//  `FamoPanelPreferences`: every key string literal lives ONLY in this file, and the
//  settings layer reads/writes through these accessors so there are no duplicate
//  literals anywhere else.
//
//  Persistence boundary (see `.trellis/spec/frontend/famo-modern-ui-direction.md`):
//  these options ultimately map to Rime YAML. Preferences stay in UserDefaults; the
//  explicit write preview sheet is the only path that writes Famo's user_data_dir and
//  calls deploy after the user confirms.
//
//  Boundary (ADR-0001 / 0002 / 0003): prefs layer only. Runtime convenience helpers
//  must stay pure string transforms when called from FamoInputController.
//
//  Concurrency: plain `Sendable` value enums; the accessors run on the main thread
//  like the rest of the candidate / settings UI.
//

import Foundation

/// Input method family. These are the first-class local modes shown on the 键盘输入 page.
/// Eventual Rime mapping: the active `schema_id` + mode-specific Rime patch.
enum FamoInputMethod: String, CaseIterable, Sendable {
  case pinyin
  case doublePinyin
  /// 五笔输入 (参照微信). The 86/拼音混输 sub-choice moved into the `FamoWubiScheme` dropdown,
  /// replacing the former `.wubi86` / `.wubiPinyin` radios (migrated in `inputMethod`'s getter).
  case wubi

  var displayName: String {
    switch self {
    case .pinyin: return "拼音输入"
    case .doublePinyin: return "双拼输入"
    case .wubi: return "五笔输入"
    }
  }

  func schemaId(doublePinyin: FamoDoublePinyin, wubiScheme: FamoWubiScheme) -> String {
    switch self {
    case .pinyin: return "rime_ice"
    case .doublePinyin: return doublePinyin.schemaId
    case .wubi: return wubiScheme.schemaId
    }
  }
}

/// 五笔方案 sub-selection shown in the 输入方式 dropdown when 五笔输入 is active — mirrors the
/// 双拼 dropdown pattern. Only the two non-繁 wubi schemas are exposed here; the 简入繁出
/// variants (`wubi86_jidian_trad*`) stay reachable via the global 简入繁出 toggle.
enum FamoWubiScheme: String, CaseIterable, Sendable {
  case jidian86
  case pinyinMix

  var displayName: String {
    switch self {
    case .jidian86: return "86 版五笔"
    case .pinyinMix: return "五笔拼音混输"
    }
  }

  var schemaId: String {
    switch self {
    case .jidian86: return "wubi86_jidian"
    case .pinyinMix: return "wubi86_jidian_pinyin"
    }
  }
}

enum FamoWubiCandidateMode: String, CaseIterable, Sendable {
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
    switch self {
    case .normal: return nil
    case .singleFirst: return "lua_filter@*wubi86_jidian_single_char_first_filter"
    case .singleOnly: return "lua_filter@*wubi86_jidian_single_char_only"
    }
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
enum FamoDoublePinyin: String, CaseIterable, Sendable {
  /// 小鹤双拼 — rime-ice `schema_id`: `double_pinyin_flypy`. Famo default.
  case flypy
  /// 微软双拼 — rime-ice `schema_id`: `double_pinyin_mspy`.
  case mspy
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
    switch self {
    case .flypy: return "double_pinyin_flypy"
    case .mspy: return "double_pinyin_mspy"
    case .ziranma: return "double_pinyin"
    case .sogou: return "double_pinyin_sogou"
    case .abc: return "double_pinyin_abc"
    case .ziguang: return "double_pinyin_ziguang"
    case .jiajia: return "double_pinyin_jiajia"
    }
  }
}

/// Single home for the 键盘输入 page preferences. The UserDefaults key string literals
/// appear ONLY here; `FamoSettingsState` mirrors the values and the page writes back
/// through these accessors, so there are no duplicate literals.
///
/// Bool accessors use `object(forKey:) == nil ? <default> : bool(forKey:)` so the
/// reference defaults (shift 切换 / 减号等号 / 左右中括号 / 符号替换 = on)
/// apply on first read instead of UserDefaults' implicit `false`.
enum FamoKeyboardPreferences {
  // MARK: - 输入方式

  /// 拼音 / 双拼. Key `"FamoKeyboardInputMethod"`, default `.pinyin`.
  /// Eventual Rime mapping: active `schema_id` + `speller/algebra`.
  static var inputMethod: FamoInputMethod {
    get {
      switch FamoDefaults.standard.string(forKey: "FamoKeyboardInputMethod") {
      case "doublePinyin": return .doublePinyin
      // legacy（已发行）: 两个独立五笔单选并入 .wubi；子方案由 wubiScheme 还原。
      case "wubi", "wubi86", "wubiPinyin": return .wubi
      default: return .pinyin
      }
    }
    set {
      FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoKeyboardInputMethod")
    }
  }

  /// 五笔方案. Key `"FamoKeyboardWubiScheme"`, default `.jidian86`.
  /// 迁移：key 未写且 legacy inputMethod 原值为 `"wubiPinyin"` 时回到 `.pinyinMix`，保住老用户的混输选择。
  static var wubiScheme: FamoWubiScheme {
    get {
      if let raw = FamoDefaults.standard.string(forKey: "FamoKeyboardWubiScheme"),
         let scheme = FamoWubiScheme(rawValue: raw) {
        return scheme
      }
      return FamoDefaults.standard.string(forKey: "FamoKeyboardInputMethod") == "wubiPinyin" ? .pinyinMix : .jidian86
    }
    set {
      FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoKeyboardWubiScheme")
    }
  }

  /// 候选个数 — Rime `menu/page_size` (G8). Key `"FamoKeyboardPageSize"`, default 8
  /// (the Famo baseline). Clamped to 3…9 so the candidate window stays usable; flows
  /// through the keyboard patch (`famoDefaultCustomYAML`) + 应用配置改动, not the live panel.
  static var pageSize: Int {
    get {
      let stored = FamoDefaults.standard.integer(forKey: "FamoKeyboardPageSize")
      return stored == 0 ? 8 : min(max(stored, 3), 9)
    }
    set {
      FamoDefaults.standard.set(min(max(newValue, 3), 9), forKey: "FamoKeyboardPageSize")
    }
  }

  /// 双拼方案. Key `"FamoKeyboardDoublePinyin"`, default `.flypy` (小鹤双拼).
  /// Eventual Rime mapping: the chosen scheme's `schema_id`.
  static var doublePinyin: FamoDoublePinyin {
    get {
      FamoDoublePinyin(rawValue: FamoDefaults.standard.string(forKey: "FamoKeyboardDoublePinyin") ?? "") ?? .flypy
    }
    set {
      FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoKeyboardDoublePinyin")
    }
  }

  /// The schema a new librime session must use to match the settings source of truth.
  /// Keeps stale `user.yaml` `previously_selected_schema` values from overriding Famo prefs.
  static var preferredSchemaID: String {
    inputMethod.schemaId(doublePinyin: doublePinyin, wubiScheme: wubiScheme)
  }

  // MARK: - 五笔

  /// 候选编码提示. Key `"FamoKeyboardWubiCodeHint"`, default `false`.
  /// Rime mapping: `translator/comment_format`（只管五笔那一路）。z 临时拼音反查的五笔编码
  /// 注释是练习用的，恒开，不受本开关影响——见 `famoWubiCustomYAML`。
  static var wubiCodeHint: Bool {
    get { boolValue("FamoKeyboardWubiCodeHint", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardWubiCodeHint") }
  }

  /// 空码自动清码. Key `"FamoKeyboardWubiAutoClear"`, default `false`.
  /// Eventual Rime mapping: `speller/auto_clear: max_length`.
  static var wubiAutoClear: Bool {
    get { boolValue("FamoKeyboardWubiAutoClear", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardWubiAutoClear") }
  }

  /// 单字候选模式. Key `"FamoKeyboardWubiCandidateMode"`, default `.normal`.
  /// Eventual Rime mapping: one of the bundled `wubi86_jidian_*` Lua filters.
  static var wubiCandidateMode: FamoWubiCandidateMode {
    get {
      FamoWubiCandidateMode(rawValue: FamoDefaults.standard.string(forKey: "FamoKeyboardWubiCandidateMode") ?? "") ?? .normal
    }
    set {
      FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoKeyboardWubiCandidateMode")
    }
  }

  /// z 临时拼音反查. Key `"FamoKeyboardWubiZReverseLookup"`, default `true`.
  /// Rime mapping: `recognizer/patterns/reverse_lookup`（关闭时清空反查正则，z 不再触发拼音反查）.
  static var wubiZReverseLookup: Bool {
    get { boolValue("FamoKeyboardWubiZReverseLookup", default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardWubiZReverseLookup") }
  }

  /// ` 临时英文（五笔前缀英文通道）. Key `"FamoKeyboardWubiEnglishChannel"`, default `false`（出厂关）.
  /// Rime mapping: 仿 z 反查的前缀通道——` 进 speller/alphabet + affix_segmentor@melt_eng +
  /// table_translator@melt_eng（词库 melt_eng，拼音线正在用的同一份）+ recognizer 正则。
  /// 前缀段不受五笔四码上屏影响（z+拼音 >4 码同理，活先例）。
  static var wubiEnglishChannel: Bool {
    get { boolValue("FamoKeyboardWubiEnglishChannel", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardWubiEnglishChannel") }
  }

  /// 记住我常用的词（个性化）. Key `"FamoKeyboardWubiUserDictLearning"`, default `false`.
  /// Rime mapping: `translator/enable_user_dict: true`（词频学习；userdb 由引擎自建自管，法墨写入层不碰）.
  static var wubiUserDictLearning: Bool {
    get { boolValue("FamoKeyboardWubiUserDictLearning", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardWubiUserDictLearning") }
  }

  // MARK: - 中英文状态切换

  /// 使用 Shift 切换中英文. Key `"FamoKeyboardShiftSwitchCJK"`, default `true`.
  /// Eventual Rime mapping: `ascii_composer/switch_key/Shift_L` + `Shift_R`（左/右 Shift 都切）.
  static var shiftSwitchCJK: Bool {
    get { boolValue("FamoKeyboardShiftSwitchCJK", default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardShiftSwitchCJK") }
  }

  /// 中文下中英标点切换. Key `"FamoKeyboardCJKPunctToggle"`, default `false`.
  /// Eventual Rime mapping: `ascii_punct` switch.
  static var cjkPunctToggle: Bool {
    get { boolValue("FamoKeyboardCJKPunctToggle", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardCJKPunctToggle") }
  }

  /// 简入繁出 (简↔繁), 全局开关. Key `"FamoKeyboardTraditionalOutput"`, default `false` (简体).
  /// Runtime Rime mapping: the FULL simplification option set — `transcription` (全拼/双拼
  /// `simplifier@transcription_cc`) AND `zh_trad` (五笔 `simplifier@tradition`), plus the legacy
  /// `traditional`/`traditionalization`/`simplification` — so one switch covers every exposed
  /// schema. NOT a patch key — applied live via `setTraditionalOutputOptions(…)` + seeded on
  /// session create.
  static var traditionalOutput: Bool {
    get { boolValue("FamoKeyboardTraditionalOutput", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardTraditionalOutput") }
  }

  // MARK: - 默认状态 (搜狗式：新会话 / 切 App 时的初始态)

  /// 中英文默认态. Key `"FamoKeyboardDefaultAsciiMode"`, default `false` (中文).
  /// `true` = 英文 (`ascii_mode` on). Seeded on session create BEFORE `updateAppOptions()`,
  /// so per-app「默认英文」(app_options) still wins where listed.
  static var defaultAsciiMode: Bool {
    get { boolValue("FamoKeyboardDefaultAsciiMode", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardDefaultAsciiMode") }
  }

  /// 全半角默认态. Key `"FamoKeyboardDefaultFullShape"`, default `false` (半角).
  /// `true` = 全角 (`full_shape` on). Seeded on session create so the choice survives focus changes.
  static var defaultFullShape: Bool {
    get { boolValue("FamoKeyboardDefaultFullShape", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardDefaultFullShape") }
  }

  // MARK: - 中英文切换键动作 (ascii_composer/switch_key)

  /// 经典 Caps Lock 切换西文. Key `"FamoKeyboardGoodOldCapsLock"`, default `true` (经典 Caps Lock 行为).
  /// Rime mapping: `ascii_composer/good_old_caps_lock`. Only written when `shiftSwitchCJK` is on.
  static var goodOldCapsLock: Bool {
    get { boolValue("FamoKeyboardGoodOldCapsLock", default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardGoodOldCapsLock") }
  }

  // MARK: - 候选翻页快捷键

  /// 减号等号翻页. Key `"FamoKeyboardPageMinusEquals"`, default `true`.
  /// Eventual Rime mapping: `key_binder` page_up `minus` / page_down `equal`.
  static var pageMinusEquals: Bool {
    get { boolValue("FamoKeyboardPageMinusEquals", default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardPageMinusEquals") }
  }

  /// 左右中括号翻页. Key `"FamoKeyboardPageBrackets"`, default `true`.
  /// Eventual Rime mapping: `key_binder` page_up `bracketleft` / page_down `bracketright`.
  static var pageBrackets: Bool {
    get { boolValue("FamoKeyboardPageBrackets", default: true) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardPageBrackets") }
  }

  /// 逗号句号翻页. Key `"FamoKeyboardPageCommaPeriod"`, default `false`.
  /// Eventual Rime mapping: `key_binder` page_up `comma` / page_down `period`.
  static var pageCommaPeriod: Bool {
    get { boolValue("FamoKeyboardPageCommaPeriod", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardPageCommaPeriod") }
  }

  // MARK: - 候选快速选词

  /// 分号引号选 2/3 位. Key `"FamoKeyboardSelect23Semicolon"`, default `false`.
  /// Eventual Rime mapping: `key_binder` select 2nd (`semicolon`) / 3rd (`apostrophe`).
  static var select23Semicolon: Bool {
    get { boolValue("FamoKeyboardSelect23Semicolon", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardSelect23Semicolon") }
  }

  // MARK: - 符号

  // slash→顿号（FamoKeyboardSlashToDun）已于 07-21 按机主拍板整体下线：设置行与 patch 产出一并
  // 移除，`/` 回归 rime-ice 原生行为；遗留的 UserDefaults 键无害、不迁移。

  /// 输入中文时 "<" 弹出符号选单（《〈 ASCII< 「【）。Key `"FamoKeyboardAngleSymbolMenu"`,
  /// default `false`（出厂关，与成对输入家族同策：不惊扰存量用户的 `<`→《 直上屏）。
  /// Eventual Rime mapping: `punctuator/half_shape/<` → 单字符候选列表（拼音/五笔 schema 均
  /// import_preset: default，一份 patch 通吃）；选出 ASCII `<` 后由自动配对（已含 ASCII 表）补对。
  static var angleSymbolMenu: Bool {
    get { boolValue("FamoKeyboardAngleSymbolMenu", default: false) }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardAngleSymbolMenu") }
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

  /// 中英文自动空格. Key `"FamoKeyboardCJKEnglishSpacing"`, default `false`.
  /// Runtime mapping: cached flag + pure commit-text transform in `FamoCommitTransform`.
  static var cjkEnglishSpacing: Bool {
    get { cachedCJKEnglishSpacing }
    set {
      cachedCJKEnglishSpacing = newValue
      FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardCJKEnglishSpacing")
    }
  }

  /// 中文与数字自动空格. Key `"FamoKeyboardCJKNumberSpacing"`, default `false`.
  /// Runtime mapping: cached flag + pure commit-text transform in `FamoCommitTransform`.
  static var cjkNumberSpacing: Bool {
    get { cachedCJKNumberSpacing }
    set {
      cachedCJKNumberSpacing = newValue
      FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardCJKNumberSpacing")
    }
  }

  /// 自动配对括号 (task 07-02). Key `"FamoKeyboardAutoPairBrackets"`, default `false`
  /// (PRD D3: 兼容性未大面积真机验证前默认关). Runtime mapping: cached flag + pure pair
  /// decision in `FamoAutoPair`, executed at the commit seam — hot-effective, NO Rime
  /// apply/deploy. OFF must stay byte-identical to today's commit behavior.
  static var autoPairBrackets: Bool {
    get { cachedAutoPairBrackets }
    set {
      cachedAutoPairBrackets = newValue
      FamoDefaults.standard.set(newValue, forKey: "FamoKeyboardAutoPairBrackets")
    }
  }

  /// 这些 App 默认英文. Key `"FamoKeyboardAppEnglishBundleIDs"`, default `[]`.
  /// Runtime mapping: generated Rime `app_options/<bundle id>/ascii_mode: true`.
  static var appEnglishBundleIDs: [String] {
    get { FamoDefaults.standard.stringArray(forKey: "FamoKeyboardAppEnglishBundleIDs") ?? [] }
    set {
      FamoDefaults.standard.set(
        normalizedAppEnglishBundleIDs(from: newValue.joined(separator: "\n")),
        forKey: "FamoKeyboardAppEnglishBundleIDs"
      )
    }
  }

  static func normalizedAppEnglishBundleIDs(from raw: String) -> [String] {
    var seen = Set<String>()
    return raw.split { ",;\n\r\t ".contains($0) }
      .map(String.init)
      .filter(isSafeBundleID)
      .filter { seen.insert($0).inserted }
  }

  // MARK: - Helpers

  private static var cachedCJKEnglishSpacing = boolValue("FamoKeyboardCJKEnglishSpacing", default: false)
  private static var cachedCJKNumberSpacing = boolValue("FamoKeyboardCJKNumberSpacing", default: false)
  private static var cachedAutoPairBrackets = boolValue("FamoKeyboardAutoPairBrackets", default: false)

  /// Read a Bool that defaults to `defaultValue` when the key was never written,
  /// instead of UserDefaults' implicit `false`.
  private static func boolValue(_ key: String, default defaultValue: Bool) -> Bool {
    FamoDefaults.standard.object(forKey: key) == nil
      ? defaultValue
      : FamoDefaults.standard.bool(forKey: key)
  }

  private static func isSafeBundleID(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy {
      switch $0.value {
      case 45, 46, 48...57, 65...90, 95, 97...122:
        return true
      default:
        return false
      }
    }
  }
}

enum FamoCommitTransform {
  static func apply(to text: String, previous previousCharacter: Character? = nil) -> String {
    let cjkAlnumSpacing = FamoKeyboardPreferences.cjkAlnumSpacing
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
    var result = ""
    if cjkEnglishSpacing || cjkNumberSpacing {
      // `previousCharacter` seeds the boundary with the trailing char of the PRIOR commit so a
      // space lands at a commit boundary (中文|英文), where the string-only loop alone is blind.
      var previous: BoundaryKind? = previousCharacter.flatMap(BoundaryKind.init)

      for character in text {
        let current = BoundaryKind(character)
        if let previous, let current, needsSpace(previous, current, cjkEnglishSpacing: cjkEnglishSpacing, cjkNumberSpacing: cjkNumberSpacing),
           !result.hasSuffix(" ") {
          result.append(" ")
        }
        result.append(character)
        previous = current
      }
    } else {
      result = text
    }

    return result
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
