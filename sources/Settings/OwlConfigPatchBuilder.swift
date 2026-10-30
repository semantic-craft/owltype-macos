// Native snapshots and export transport. The retained YAML preview/export contract is
// implemented in owl-app-core/keyboard_export.rs. Normal settings activation does not
// write or deploy these YAML patches; OwlKeyboardSettingsApplication executes Rust plans.

import Foundation

/// A plain, `Sendable` snapshot of the keyboard preferences, decoupled from
/// UserDefaults so `owlDefaultCustomYAML(from:)` is a pure value→string function.
/// Mirrors only preferences that Owltype currently exports to Rime.
struct OwlKeyboardSnapshot: Sendable, Encodable {
  // 输入方式
  let inputMethod: OwlInputMethod
  let doublePinyin: OwlDoublePinyin
  // 中英文状态切换
  let shiftSwitchCJK: Bool
  let cjkPunctToggle: Bool
  // 候选个数 — Rime menu/page_size (G8)
  let pageSize: Int
  // 候选翻页快捷键
  let pageMinusEquals: Bool
  let pageBrackets: Bool
  let pageCommaPeriod: Bool
  // 候选快速选词
  let select23Semicolon: Bool
  // 模糊拼音 (v0.3.5) — the nine fuzzy pairs, snapshotted from `OwlFuzzyPreferences`.
  let fuzzy: OwlFuzzySnapshot
  // 五笔方案级开关 — written to wubi86_jidian*.custom.yaml.
  let wubiCodeHint: Bool
  let wubiAutoClear: Bool
  let wubiCandidateMode: OwlWubiCandidateMode
  // App 默认英文 — additional bundle IDs mapped to Rime's existing app_options/ascii_mode.
  let appEnglishBundleIDs: [String]
  // 经典 Caps Lock 切换西文 (`ascii_composer/good_old_caps_lock`). `var` + default so it joins
  // the synthesized memberwise initializer as a DEFAULTED param (a `let` with a default is
  // excluded), keeping every existing memberwise call site (selfCheck / tests) compiling
  // unchanged; only `current()` threads the live pref.
  var goodOldCapsLock = OwlKeyboardSwitch.goodOldCapsLock.defaultValue
  // 五笔方案 (86/拼音混输) + z 临时拼音反查. `var` + defaults so they join the memberwise init
  // as DEFAULTED params, keeping existing call sites (selfCheck / tests) compiling unchanged.
  var wubiScheme = OwlWubiScheme(rawValue: OwlAppCore.defaultKeyboard.wubiScheme)!
  var wubiZReverseLookup = OwlKeyboardSwitch.wubiZReverseLookup.defaultValue
  // 记住我常用的词（个性化）→ `translator/enable_user_dict`。`var`+默认，作 DEFAULTED 参，保现有
  // memberwise 调用点（selfCheck / tests）不动。
  var wubiUserDictLearning = OwlAppCore.keyboardCatalog.exportDefaults["wubiUserDictLearning"]!
  // 「<」键弹出符号选单 → `punctuator/half_shape/<` 列表。`var`+默认，作 DEFAULTED 参，
  // 保现有 memberwise 调用点（selfCheck / tests）不动。
  var angleSymbolMenu = OwlKeyboardSwitch.angleSymbolMenu.defaultValue
  // 「/」键弹出符号选单 → half/full-shape 都覆盖为 [、 / ／ ÷]。默认关；`var`+默认同上。
  var slashSymbolMenu = OwlKeyboardSwitch.slashSymbolMenu.defaultValue
  // ` 临时英文（五笔前缀英文通道）→ 五笔 4 变体 custom.yaml 的 melt_eng 接线。`var`+默认同上。
  var wubiEnglishChannel = OwlKeyboardSwitch.wubiEnglishChannel.defaultValue

  /// Read the live preferences into a value snapshot. This is the single UserDefaults
  /// touch in the patch-builder file; the builder itself stays pure.
  static func current() -> OwlKeyboardSnapshot {
    OwlKeyboardSnapshot(
      inputMethod: OwlKeyboardPreferences.inputMethod,
      doublePinyin: OwlKeyboardPreferences.doublePinyin,
      shiftSwitchCJK: OwlKeyboardPreferences.shiftSwitchCJK,
      cjkPunctToggle: OwlKeyboardPreferences.cjkPunctToggle,
      pageSize: OwlKeyboardPreferences.pageSize,
      pageMinusEquals: OwlKeyboardPreferences.pageMinusEquals,
      pageBrackets: OwlKeyboardPreferences.pageBrackets,
      pageCommaPeriod: OwlKeyboardPreferences.pageCommaPeriod,
      select23Semicolon: OwlKeyboardPreferences.select23Semicolon,
      fuzzy: OwlFuzzySnapshot.current(),
      wubiCodeHint: OwlKeyboardPreferences.wubiCodeHint,
      wubiAutoClear: OwlKeyboardPreferences.wubiAutoClear,
      wubiCandidateMode: OwlKeyboardPreferences.wubiCandidateMode,
      appEnglishBundleIDs: OwlKeyboardPreferences.appEnglishBundleIDs,
      goodOldCapsLock: OwlKeyboardPreferences.goodOldCapsLock,
      wubiScheme: OwlKeyboardPreferences.wubiScheme,
      wubiZReverseLookup: OwlKeyboardPreferences.wubiZReverseLookup,
      wubiUserDictLearning: OwlKeyboardPreferences.wubiUserDictLearning,
      angleSymbolMenu: OwlKeyboardPreferences.angleSymbolMenu,
      slashSymbolMenu: OwlKeyboardPreferences.slashSymbolMenu,
      wubiEnglishChannel: OwlKeyboardPreferences.wubiEnglishChannel
    )
  }
}

struct OwlWubiPatchTarget: Sendable, Codable {
  let schemaID: String
  let fileName: String
  let displayName: String
}

let owlWubiPatchTargets = OwlAppCore.keyboardCatalog.exportTargets

private func keyboardExport(_ kind: String, snapshot: OwlKeyboardSnapshot,
                            target: OwlWubiPatchTarget? = nil) -> String {
  var request: [String: Any] = ["operation": "keyboard_export", "kind": kind,
                               "snapshot": OwlAppCore.payload(snapshot)]
  if let target { request["target"] = OwlAppCore.payload(target) }
  return OwlAppCore.required(request)
}

func owlDefaultCustomYAML(from snapshot: OwlKeyboardSnapshot) -> String {
  keyboardExport("default", snapshot: snapshot)
}

func owlAppOptionsCustomYAML(from snapshot: OwlKeyboardSnapshot) -> String {
  keyboardExport("apps", snapshot: snapshot)
}

func owlRimeIceCustomYAML(from snapshot: OwlKeyboardSnapshot) -> String {
  keyboardExport("fuzzy", snapshot: snapshot)
}

func owlWubiCustomYAML(from snapshot: OwlKeyboardSnapshot, target: OwlWubiPatchTarget) -> String {
  keyboardExport("wubi", snapshot: snapshot, target: target)
}

#if DEBUG
/// Cheap, Debug-only sanity check for the generator. Trips an `assert` if the
/// default-prefs output loses its core structure. Non-fatal in Release (the whole
/// function is compiled out). Call once from the preview sheet presentation.
func owlPatchBuilderSelfCheck() {
  // Default prefs: pinyin, shift切换 on, 减号等号 + 左右中括号 翻页 on, 模糊拼音 all off.
  // The output must keep the `patch:` root and the live `key_binder` bindings block,
  // and — since every fuzzy pair is off — MUST NOT carry a `speller/algebra/+` block.
  let fuzzyOff = OwlFuzzySnapshot(
    zhz: false, chc: false, shs: false, nl: false, rl: false,
    fh: false, anang: false, eneng: false, ining: false
  )
  let defaults = OwlKeyboardSnapshot(
    inputMethod: .pinyin,
    doublePinyin: .flypy,
    shiftSwitchCJK: true,
    cjkPunctToggle: false,
    pageSize: 8,
    pageMinusEquals: true,
    pageBrackets: true,
    pageCommaPeriod: false,
    select23Semicolon: false,
    fuzzy: fuzzyOff,
    wubiCodeHint: false,
    wubiAutoClear: false,
    wubiCandidateMode: .normal,
    appEnglishBundleIDs: []
  )
  // default.custom.yaml: keeps the `patch:` root + the live `key_binder` bindings, and
  // — since fuzzy is schema-level now — must NOT carry any `speller/algebra` block.
  let yaml = owlDefaultCustomYAML(from: defaults)
  assert(yaml.contains("patch:"), "Owltype patch builder: missing patch: root")
  assert(yaml.contains("key_binder"), "Owltype patch builder: missing key_binder block")
  assert(yaml.contains("ascii_composer/switch_key/Shift_L"), "Owltype patch builder: missing Shift_L switch key")
  assert(yaml.contains("ascii_composer/switch_key/Shift_R"), "Owltype patch builder: missing Shift_R switch key")
  assert(yaml.contains("ascii_composer/switch_key/Caps_Lock"), "Owltype patch builder: missing Caps_Lock switch key")
  assert(yaml.contains("ascii_composer/good_old_caps_lock"), "Owltype patch builder: missing good_old_caps_lock")
  assert(!yaml.contains("speller/algebra"), "Owltype patch builder: speller/algebra must not be in default.custom.yaml")

  // v0.5 转正: with [] 翻页 + 快速选词 + `/`/`<` 符号选单 + 中英标点切换 all on,
  // the default output must carry the now-LIVE keys (Q1–Q4), and the bindings list must
  // contain no duplicate lines (the double-written shifted keys are dedup'd).
  var promoted = OwlKeyboardSnapshot(
    inputMethod: .doublePinyin,
    doublePinyin: .flypy,
    shiftSwitchCJK: true,
    cjkPunctToggle: true,
    pageSize: 8,
    pageMinusEquals: false,
    pageBrackets: true,
    pageCommaPeriod: false,
    select23Semicolon: true,
    fuzzy: fuzzyOff,
    wubiCodeHint: true,
    wubiAutoClear: true,
    wubiCandidateMode: .singleFirst,
    appEnglishBundleIDs: ["com.example.Editor"]
  )
  promoted.angleSymbolMenu = true
  promoted.slashSymbolMenu = true
  let promotedYAML = owlDefaultCustomYAML(from: promoted)
  assert(promotedYAML.contains("select_first_character"), "Owltype patch builder: missing [] 以词定字 disable")
  assert(promotedYAML.contains("bracketleft"), "Owltype patch builder: missing [] 翻页 binding")
  assert(promotedYAML.contains("send: 2"), "Owltype patch builder: missing ; 选第 2 位 binding")
  assert(promotedYAML.contains("\"/\": [\"、\", \"/\", \"／\", \"÷\"]"), "Owltype patch builder: missing `/` 符号选单 punctuator")
  assert(promotedYAML.contains("punctuator/half_shape/<"), "Owltype patch builder: missing `<` 符号选单 punctuator")
  assert(promotedYAML.contains("toggle: ascii_punct"), "Owltype patch builder: missing ascii_punct toggle")
  // app_options moved to the owltype domain (task 07-08): default.custom.yaml must NOT carry it; the
  // dedicated owltype.custom.yaml builder must.
  assert(!promotedYAML.contains("app_options/"), "Owltype patch builder: app_options must NOT be in default.custom.yaml")
  assert(owlAppOptionsCustomYAML(from: promoted).contains("app_options/com.example.Editor/ascii_mode"), "Owltype patch builder: missing app_options in owltype.custom.yaml")
  // 双拼=小鹤: schema_list must put double_pinyin_flypy first.
  assert(promotedYAML.contains("schema: double_pinyin_flypy"), "Owltype patch builder: missing 双拼置顶 schema_list")
  // De-dup: no `key_binder/bindings/+` list line (the `- { ... }` entries) repeats.
  let bindingLines = promotedYAML
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
    .filter { $0.hasPrefix("    - { ") }
  assert(bindingLines.count == Set(bindingLines).count, "Owltype patch builder: duplicate key_binder binding line")

  // rime_ice.custom.yaml with all fuzzy off: header-only, no `speller/algebra`.
  let rimeIceOff = owlRimeIceCustomYAML(from: defaults)
  assert(!rimeIceOff.contains("speller/algebra"), "Owltype patch builder: fuzzy block present with all pairs off")

  // With a couple fuzzy pairs on, the rime_ice.custom.yaml `speller/algebra/+` block +
  // the chosen derives must appear (and only the chosen ones — zh/z but not ch/c when
  // only zhz is on); default.custom.yaml stays free of `speller/algebra`.
  var fuzzyOn = fuzzyOff
  fuzzyOn = OwlFuzzySnapshot(
    zhz: true, chc: false, shs: false, nl: false, rl: false,
    fh: false, anang: true, eneng: false, ining: false
  )
  let withFuzzy = OwlKeyboardSnapshot(
    inputMethod: .pinyin,
    doublePinyin: .flypy,
    shiftSwitchCJK: true,
    cjkPunctToggle: false,
    pageSize: 8,
    pageMinusEquals: true,
    pageBrackets: true,
    pageCommaPeriod: false,
    select23Semicolon: false,
    fuzzy: fuzzyOn,
    wubiCodeHint: false,
    wubiAutoClear: false,
    wubiCandidateMode: .normal,
    appEnglishBundleIDs: []
  )
  let defaultWithFuzzy = owlDefaultCustomYAML(from: withFuzzy)
  assert(!defaultWithFuzzy.contains("speller/algebra"), "Owltype patch builder: fuzzy leaked into default.custom.yaml")

  let rimeIceYaml = owlRimeIceCustomYAML(from: withFuzzy)
  assert(rimeIceYaml.contains("speller/algebra/+"), "Owltype patch builder: missing fuzzy algebra block")
  assert(rimeIceYaml.contains("derive/^zh/z/"), "Owltype patch builder: missing enabled zh/z derive")
  assert(rimeIceYaml.contains("derive/an$/ang/"), "Owltype patch builder: missing enabled an/ang derive")
  assert(!rimeIceYaml.contains("derive/^ch/c/"), "Owltype patch builder: emitted ch/c derive when disabled")

  // user_dict 个性化（wubi 方案级）：默认 off → 无 enable_user_dict；on → translator/enable_user_dict: true。
  let wubiTarget = owlWubiPatchTargets[0]
  assert(!owlWubiCustomYAML(from: defaults, target: wubiTarget).contains("enable_user_dict"),
         "Owltype patch builder: enable_user_dict present when personalization off")
  var udOn = defaults
  udOn.wubiUserDictLearning = true
  assert(owlWubiCustomYAML(from: udOn, target: wubiTarget).contains("\"translator/enable_user_dict\": true"),
         "Owltype patch builder: missing enable_user_dict when personalization on")
}
#endif
