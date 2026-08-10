//
//  FamoRimePatchBuilder.swift
//  法墨输入法 (Famo) — Rime patch generators (default.custom.yaml + rime_ice.custom.yaml)
//
//  v0.3.2: turn the 键盘输入 choices (persisted in `FamoKeyboardPreferences`) into a
//  copyable patch string, shown in a preview sheet with a 复制 button. THIS FILE is PURE
//  GENERATION — it never writes Famo's user_data_dir and never calls `deploy()`. The actual
//  write + deploy now runs automatically from the live 键盘输入 toggles via
//  `FamoConfigWriter.apply` + the fast `config_file` deploy path (no longer deferred).
//
//  v0.4-app-fix: the fuzzy `speller/algebra` block is SCHEMA-level (it patches
//  `rime_ice.schema.yaml`), so it must go in `rime_ice.custom.yaml`, NOT
//  `default.custom.yaml` (see `packages/rime-law-config/CONFIG-DESIGN.md`). The
//  generator is split into two pure builders:
//  - `famoDefaultCustomYAML(from:)` — the SHARED keys (ascii_composer/switch_key hint,
//    key_binder/bindings paging + select, punctuator hints, the commented 双拼 schema
//    hint). NO `speller/algebra` here.
//  - `famoRimeIceCustomYAML(from:)` — the 全拼方案级 fuzzy `speller/algebra/+` derives,
//    headed `# rime_ice.custom.yaml`. Empty (a header-only "无模糊音" note) when no
//    fuzzy pair is on.
//
//  v0.5 (patch-builder 转正, first batch): the conservatively-COMMENTED mappings in
//  `famoDefaultCustomYAML` graduate to the confirmed-correct rime-ice keys, per the
//  ChatGPT Pro 回包 (`famo-rime-config-law-implementation.html` Q1–Q6):
//  - `[]` 翻页 first disables rime-ice 以词定字 (`key_binder/select_first|last_character: ""`,
//    a Lua processor that runs BEFORE key_binder) then sends Page_Up/Down.
//  - 快速选词 → `send: 2/3` (not `select:`); Command stays commented (Squirrel 不稳, 需真机).
//  - `/` 符号选单 → default-off 的 half/full-shape punctuator 候选；关闭时不产出 patch，
//    由 Famo 前端维持「提交当前候选、切英文、输出 ASCII slash」。
//  - 全半角 / 中英标点 → `toggle: full_shape|ascii_punct` bindings (Squirrel/Weasel
//    shifted-key names double-written; the generator DEDUPS) + `switcher/save_options/+`.
//  - 默认方案顺序 → live `schema_list` (chosen 双拼 first) + `menu/page_size: 8`.
//  The `key_binder/bindings/+` list is assembled as a DE-DUPLICATED array before
//  serializing, so the double-written shifted keys never repeat.
//
//  Design contract:
//  - `FamoKeyboardSnapshot` is a plain `Sendable` value struct for supported exportable prefs.
//    `FamoKeyboardSnapshot.current()` is the ONLY UserDefaults touch in this file
//    (reads `FamoKeyboardPreferences`); both builders below are pure value→string
//    functions with no UserDefaults / disk / network access inside.
//  - Both builders are CONSERVATIVE: they only emit Rime mappings that are clearly
//    correct, gate each block by its pref, and prefer a COMMENTED hint over a guessed
//    key when the exact rime-ice key isn't certain. Correctness over completeness —
//    the output is a 草案 (draft) the user applies + verifies manually.
//
//  Boundary (ADR-0001 / 0002 / 0003): generation/prefs layer only — never touches the
//  IMK key-event hot path (FamoInputController).
//
//  Concurrency: pure value types + free functions; safe to call off any thread. The
//  `current()` accessor runs on the main thread like the rest of the settings UI.
//

import Foundation

/// A plain, `Sendable` snapshot of the keyboard preferences, decoupled from
/// UserDefaults so `famoDefaultCustomYAML(from:)` is a pure value→string function.
/// Mirrors only preferences that Famo currently exports to Rime.
struct FamoKeyboardSnapshot: Sendable {
  // 输入方式
  let inputMethod: FamoInputMethod
  let doublePinyin: FamoDoublePinyin
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
  // 模糊拼音 (v0.3.5) — the nine fuzzy pairs, snapshotted from `FamoFuzzyPreferences`.
  let fuzzy: FamoFuzzySnapshot
  // 五笔方案级开关 — written to wubi86_jidian*.custom.yaml.
  let wubiCodeHint: Bool
  let wubiAutoClear: Bool
  let wubiCandidateMode: FamoWubiCandidateMode
  // App 默认英文 — additional bundle IDs mapped to Rime's existing app_options/ascii_mode.
  let appEnglishBundleIDs: [String]
  // 经典 Caps Lock 切换西文 (`ascii_composer/good_old_caps_lock`). `var` + default so it joins
  // the synthesized memberwise initializer as a DEFAULTED param (a `let` with a default is
  // excluded), keeping every existing memberwise call site (selfCheck / tests) compiling
  // unchanged; only `current()` threads the live pref.
  var goodOldCapsLock: Bool = true
  // 五笔方案 (86/拼音混输) + z 临时拼音反查. `var` + defaults so they join the memberwise init
  // as DEFAULTED params, keeping existing call sites (selfCheck / tests) compiling unchanged.
  var wubiScheme: FamoWubiScheme = .jidian86
  var wubiZReverseLookup: Bool = true
  // 记住我常用的词（个性化）→ `translator/enable_user_dict`。`var`+默认，作 DEFAULTED 参，保现有
  // memberwise 调用点（selfCheck / tests）不动。
  var wubiUserDictLearning: Bool = false
  // 「<」键弹出符号选单 → `punctuator/half_shape/<` 列表。`var`+默认，作 DEFAULTED 参，
  // 保现有 memberwise 调用点（selfCheck / tests）不动。
  var angleSymbolMenu: Bool = false
  // 「/」键弹出符号选单 → half/full-shape 都覆盖为 [、 / ／ ÷]。默认关；`var`+默认同上。
  var slashSymbolMenu: Bool = false
  // ` 临时英文（五笔前缀英文通道）→ 五笔 4 变体 custom.yaml 的 melt_eng 接线。`var`+默认同上。
  var wubiEnglishChannel: Bool = false

  /// Read the live preferences into a value snapshot. This is the single UserDefaults
  /// touch in the patch-builder file; the builder itself stays pure.
  static func current() -> FamoKeyboardSnapshot {
    FamoKeyboardSnapshot(
      inputMethod: FamoKeyboardPreferences.inputMethod,
      doublePinyin: FamoKeyboardPreferences.doublePinyin,
      shiftSwitchCJK: FamoKeyboardPreferences.shiftSwitchCJK,
      cjkPunctToggle: FamoKeyboardPreferences.cjkPunctToggle,
      pageSize: FamoKeyboardPreferences.pageSize,
      pageMinusEquals: FamoKeyboardPreferences.pageMinusEquals,
      pageBrackets: FamoKeyboardPreferences.pageBrackets,
      pageCommaPeriod: FamoKeyboardPreferences.pageCommaPeriod,
      select23Semicolon: FamoKeyboardPreferences.select23Semicolon,
      fuzzy: FamoFuzzySnapshot.current(),
      wubiCodeHint: FamoKeyboardPreferences.wubiCodeHint,
      wubiAutoClear: FamoKeyboardPreferences.wubiAutoClear,
      wubiCandidateMode: FamoKeyboardPreferences.wubiCandidateMode,
      appEnglishBundleIDs: FamoKeyboardPreferences.appEnglishBundleIDs,
      goodOldCapsLock: FamoKeyboardPreferences.goodOldCapsLock,
      wubiScheme: FamoKeyboardPreferences.wubiScheme,
      wubiZReverseLookup: FamoKeyboardPreferences.wubiZReverseLookup,
      wubiUserDictLearning: FamoKeyboardPreferences.wubiUserDictLearning,
      angleSymbolMenu: FamoKeyboardPreferences.angleSymbolMenu,
      slashSymbolMenu: FamoKeyboardPreferences.slashSymbolMenu,
      wubiEnglishChannel: FamoKeyboardPreferences.wubiEnglishChannel
    )
  }
}

struct FamoWubiPatchTarget: Sendable {
  let schemaID: String
  let fileName: String
  let displayName: String
}

let famoWubiPatchTargets: [FamoWubiPatchTarget] = [
  FamoWubiPatchTarget(schemaID: "wubi86_jidian", fileName: "wubi86_jidian.custom.yaml", displayName: "极点五笔86"),
  FamoWubiPatchTarget(schemaID: "wubi86_jidian_pinyin", fileName: "wubi86_jidian_pinyin.custom.yaml", displayName: "五笔拼音混输"),
  FamoWubiPatchTarget(schemaID: "wubi86_jidian_trad", fileName: "wubi86_jidian_trad.custom.yaml", displayName: "五笔简入繁出"),
  FamoWubiPatchTarget(schemaID: "wubi86_jidian_trad_pinyin", fileName: "wubi86_jidian_trad_pinyin.custom.yaml", displayName: "五笔拼音混输·简入繁出"),
]

/// Build a `default.custom.yaml` patch string from a keyboard snapshot.
///
/// PURE: value → string, no side effects. Every block is gated by its pref. v0.5 emits
/// the confirmed-correct rime-ice keys (Q1–Q6 of the 回包) as LIVE keys; only the
/// 需真机 items (Command-select) stay COMMENTED. 2-space indent.
///
/// This file covers the SHARED keys only. The fuzzy `speller/algebra` block is
/// schema-level and lives in `famoRimeIceCustomYAML(from:)` (→ `rime_ice.custom.yaml`).
///
/// The result is a 草案 — the header says so, and the UI labels it "需真机验证后写入".
func famoDefaultCustomYAML(from s: FamoKeyboardSnapshot) -> String {
  var lines: [String] = []

  // Header — always present, states the draft + verification boundary.
  lines.append("# 法墨生成（草案）— 应用前请真机验证")
    lines.append("# 写入 ~/Library/Application Support/Famo/default.custom.yaml 后需在法墨设置里「应用配置改动」")
  lines.append("patch:")

  // MARK: - 默认方案顺序 — live `schema_list` (Q5).
  // Put the selected first-class local mode first. Famo owns this generated block, so
  // the settings page can promote pinyin / 双拼 / 五笔 / 五笔拼音 without hand-editing YAML.
  if s.inputMethod == .pinyin {
    lines.append("  # 默认方案顺序：全拼 rime_ice 置顶（首项=新会话默认方案）")
    lines.append("  schema_list:")
    lines.append("    - { schema: rime_ice }             # 雾凇全拼")
    lines.append("    - { schema: pinyin_simp }          # 简体拼音")
    lines.append("    - { schema: wubi86_jidian }        # 极点五笔86")
    lines.append("    - { schema: wubi86_jidian_pinyin } # 五笔拼音混输")
    lines.append("    - { schema: wubi86_jidian_trad }   # 五笔简入繁出")
    lines.append("    - { schema: wubi86_jidian_trad_pinyin } # 五笔拼音混输·简入繁出")
    lines.append("  \"menu/page_size\": \(s.pageSize)")
  } else if s.inputMethod == .doublePinyin {
    lines.append("  # 默认方案顺序：把所选双拼置顶（首项=新会话默认方案）")
    lines.append("  schema_list:")
    lines.append("    - { schema: \(s.doublePinyin.schemaId) }  # \(s.doublePinyin.displayName)")
    lines.append("    - { schema: rime_ice }             # 雾凇全拼")
    lines.append("    - { schema: wubi86_jidian }        # 极点五笔86")
    lines.append("    - { schema: wubi86_jidian_pinyin } # 五笔拼音混输")
    lines.append("    - { schema: wubi86_jidian_trad }   # 五笔简入繁出")
    lines.append("    - { schema: wubi86_jidian_trad_pinyin } # 五笔拼音混输·简入繁出")
    lines.append("  \"menu/page_size\": \(s.pageSize)")
  } else if s.inputMethod == .wubi {
    // 五笔输入：所选子方案（86 / 拼音混输）置顶，另一个紧随；trad 两个仍在表里（由全局简入繁出/手动切换可达）。
    let primary = s.wubiScheme == .pinyinMix ? "wubi86_jidian_pinyin" : "wubi86_jidian"
    let secondary = s.wubiScheme == .pinyinMix ? "wubi86_jidian" : "wubi86_jidian_pinyin"
    lines.append("  # 默认方案顺序：\(s.wubiScheme.displayName) 置顶（首项=新会话默认方案）")
    lines.append("  schema_list:")
    lines.append("    - { schema: \(primary) }")
    lines.append("    - { schema: \(secondary) }")
    lines.append("    - { schema: wubi86_jidian_trad }   # 五笔简入繁出")
    lines.append("    - { schema: wubi86_jidian_trad_pinyin } # 五笔拼音混输·简入繁出")
    lines.append("    - { schema: rime_ice }             # 雾凇全拼")
    lines.append("    - { schema: pinyin_simp }          # 简体拼音")
    lines.append("  \"menu/page_size\": \(s.pageSize)")
  }

  // MARK: - 中英文切换键: Shift_L / Shift_R / Caps_Lock + good_old_caps_lock.
  // `shiftSwitchCJK` is the master gate; OFF restores the bundled `default.yaml` seed (and
  // keeps the contract that Famo writes NO switch_key override when the user turns it off).
  // 左/右 Shift 都切中英（commit_code）；Caps_Lock 也 commit_code；good_old_caps_lock 由开关驱动。
  if s.shiftSwitchCJK {
    lines.append("  # 中英文切换键：左/右 Shift 都切中英文（commit_code）")
    lines.append("  \"ascii_composer/switch_key/Shift_L\": commit_code")
    lines.append("  \"ascii_composer/switch_key/Shift_R\": commit_code")
    lines.append("  \"ascii_composer/switch_key/Caps_Lock\": commit_code")
    lines.append("  \"ascii_composer/good_old_caps_lock\": \(s.goodOldCapsLock)")
  }

  // App 默认英文 (app_options) 现写入 famo 域（famo.custom.yaml），不再进 default 域——
  // 只有 config_open("famo") 域被 FamoConfig.getAppOptions 读到；写 default 域会让用户手动
  // 加的 App 静默失效（域裂缝，task 07-08）。见 famoAppOptionsCustomYAML(from:)。

  // MARK: - `[]` 翻页 disables 以词定字 (Q1).
  // rime-ice's `[`/`]` are a `lua_processor@*select_character` Lua step that reads
  // `key_binder/select_first|last_character` and runs BEFORE key_binder. Just adding a
  // bracket→Page binding fights it, so first blank those two keys (disable 以词定字);
  // the Page_Up/Down bindings themselves go in the key_binder/bindings list below.
  if s.pageBrackets {
    lines.append("  # [] 翻页：先停用 rime-ice 以词定字（select_character Lua 处理器在 key_binder 前执行），")
    lines.append("  # 置空这两个键后 [ ] 才会落到下面的 key_binder 翻页绑定。")
    lines.append("  \"key_binder/select_first_character\": \"\"")
    lines.append("  \"key_binder/select_last_character\": \"\"")
  }

  lines.append(contentsOf: punctuatorPatchLines(from: s))

  // MARK: - 候选翻页 / 快速选词 / 全半角·中英标点 — live `key_binder/bindings/+`.
  // Assembled as a DE-DUPLICATED array (the shifted-key names below are double-written
  // for Squirrel/Weasel compat; the generator dedups so they never repeat). Only emit
  // the key when ≥1 binding is present; never emit an empty key.
  let bindings = keyBinderBindings(from: s)
  if !bindings.isEmpty {
    lines.append("  # 候选翻页 / 快速选词 / 全半角·中英标点热键（追加，不替换用户已有 bindings；已去重）")
    lines.append("  \"key_binder/bindings/+\":")
    lines.append(contentsOf: bindings)
  }

  // MARK: - 让方案选单记住 full_shape / ascii_punct 开关 (Q4, optional).
  // Emit only the switch(es) whose toggle is on, so we don't widen save_options beyond
  // what the user actually wired a hotkey for.
  let savedOptions = saveOptions(from: s)
  if !savedOptions.isEmpty {
    lines.append("  # 让方案选单记住这些开关状态")
    lines.append("  \"switcher/save_options/+\":")
    lines.append(contentsOf: savedOptions.map { "    - \($0)" })
  }

  // 模糊拼音 is SCHEMA-level (`speller/algebra`) → it lives in
  // `famoRimeIceCustomYAML(from:)` (→ rime_ice.custom.yaml), NOT here. Do not emit
  // any `speller/algebra` key in default.custom.yaml.

  // Always end with a trailing newline so the patch concatenates cleanly.
  return lines.joined(separator: "\n") + "\n"
}

/// Build a `famo.custom.yaml` patch string carrying per-app `app_options`.
///
/// PURE: value → string, no side effects. app_options MUST live in the FAMO config domain
/// (`config_open("famo")` = famo.yaml + famo.custom.yaml) because that is the ONLY domain
/// `FamoConfig.getAppOptions` reads. The pre-fix behaviour wrote them into default.custom.yaml
/// (the `default` domain), which `getAppOptions` never opens → user-added apps silently had
/// no effect (config 域裂缝, task 07-08). Factory presets stay in the `famo.yaml` base; user
/// additions are this patch — patch-over-base within a single authoritative domain.
///
/// Empty list → bare `patch:` so the managed block becomes empty and clears any app_options
/// Famo wrote before (same self-clearing contract as `famoRimeIceCustomYAML`).
func famoAppOptionsCustomYAML(from s: FamoKeyboardSnapshot) -> String {
  var lines: [String] = []
  lines.append("# 法墨生成（草案）— 应用前请真机验证")
  lines.append("# 写入 ~/Library/Application Support/Famo/famo.custom.yaml 后需在法墨设置里「应用配置改动」")
  lines.append("patch:")

  let appEnglishBundleIDs = FamoKeyboardPreferences.normalizedAppEnglishBundleIDs(
    from: s.appEnglishBundleIDs.joined(separator: "\n")
  )
  if !appEnglishBundleIDs.isEmpty {
    lines.append("  # App 默认英文：复用 Rime/Squirrel app_options，只追加用户指定的 bundle id（famo 域，与出厂预设同域）")
    for bundleID in appEnglishBundleIDs {
      lines.append("  \"app_options/\(bundleID)/ascii_mode\": true")
    }
  }

  // Always end with a trailing newline so the patch concatenates cleanly.
  return lines.joined(separator: "\n") + "\n"
}

/// Build a `rime_ice.custom.yaml` patch string from a keyboard snapshot.
///
/// PURE: value → string, no side effects. This is the 全拼方案级 patch — it targets
/// `rime_ice.schema.yaml`, so the fuzzy `speller/algebra/+` derives belong HERE, not in
/// `default.custom.yaml`.
///
/// Returns a header-only "无模糊音" note when no fuzzy pair is enabled (the preview omits
/// this section entirely in that case). 2-space indent for the `patch:` body.
func famoRimeIceCustomYAML(from s: FamoKeyboardSnapshot) -> String {
  var lines: [String] = []

  // Header — names the target file + the 全拼方案级（模糊音）scope.
  lines.append("# rime_ice.custom.yaml — 雾凇全拼方案级（模糊音）")
  lines.append("# 法墨生成（草案）— 应用前请真机验证")
    lines.append("# 写入 ~/Library/Application Support/Famo/rime_ice.custom.yaml 后需在法墨设置里「应用配置改动」")

  // MARK: - 模糊拼音 (v0.3.5) — live `speller/algebra/+` derives, gated by each pair.
  // The derive rules themselves are standard rime; what is UNCERTAIN is the append
  // semantics — `speller/algebra/+` appends to rime_ice's existing algebra, and
  // ordering relative to that algebra can matter (abbrev/derive interplay). The block
  // header carries the 真机验证 caveat. Emitted ONLY when ≥1 pair is enabled.
  let fuzzyDerives = fuzzyAlgebraDerives(from: s.fuzzy)
  if fuzzyDerives.isEmpty {
    lines.append("# 当前未开启任何模糊音；无需 rime_ice.custom.yaml。")
    return lines.joined(separator: "\n") + "\n"
  }

  lines.append("patch:")
  lines.append("  # 模糊拼音（追加到 speller/algebra；注意与方案既有 algebra 的顺序，建议真机验证）")
  lines.append("  \"speller/algebra/+\":")
  lines.append(contentsOf: fuzzyDerives)

  // Always end with a trailing newline so the patch concatenates cleanly.
  return lines.joined(separator: "\n") + "\n"
}

func famoWubiCustomYAML(from s: FamoKeyboardSnapshot, target: FamoWubiPatchTarget) -> String {
  var lines: [String] = []

  lines.append("# \(target.fileName) — \(target.displayName) 方案级")
  lines.append("# 法墨生成（草案）— 应用前请真机验证")
  lines.append("# 写入 ~/Library/Application Support/Famo/\(target.fileName) 后需在法墨设置里「应用配置改动」")
  lines.append("patch:")

  lines.append("  # 候选编码提示：默认隐藏五笔候选的编码。")
  if s.wubiCodeHint {
    lines.append("  \"translator/comment_format\": []")
  } else {
    lines.append("  \"translator/comment_format\":")
    lines.append("    - xform/.+//")
  }

  // z 临时拼音那一路的注释不是拼音，而是 librime 拿候选文本回主方案词典反查出的五笔编码
  // （reverse_lookup_translator 的 rev_dict 默认 target = translator，即 wubi86_jidian）。
  // 那正是「打拼音顺带认五笔码」的练习价值，所以刻意不跟「候选编码提示」联动——后者只管
  // 五笔本身那一路。恒写空规则表，压掉方案里可能存在的 comment_format。
  lines.append("  # z 临时拼音反查始终显示五笔编码（练习用），不受上面的候选编码提示影响。")
  lines.append("  \"reverse_lookup/comment_format\": []")

  lines.append("  # 空码自动清码：打开后空码到最大码长时自动清空。")
  lines.append("  \"speller/auto_clear\": \(s.wubiAutoClear ? "max_length" : "\"\"")")

  if let filter = s.wubiCandidateMode.luaFilter {
    lines.append("  # 单字候选：两个 Lua filter 互斥，只追加当前选择。")
    lines.append("  \"engine/filters/+\":")
    lines.append("    - \(filter)")
  }

  if s.wubiZReverseLookup {
    lines.append("  # z 临时拼音反查：统一 86 / 拼音混输 / 繁体变体使用 z 前缀。")
    lines.append("  \"reverse_lookup/prefix\": \"z\"")
    lines.append("  \"reverse_lookup/suffix\": \"'\"")
    lines.append("  \"reverse_lookup/tips\": [拼音]")
    lines.append("  \"recognizer/patterns/reverse_lookup\": \"^z[a-z]*'?$\"")
  } else {
    lines.append("  # z 临时拼音反查：关闭时清空 recognizer 反查正则，z 不再触发拼音反查。")
    lines.append("  \"recognizer/patterns/reverse_lookup\": \"\"")
  }

  if s.wubiUserDictLearning {
    lines.append("  # 个性化：记住你常用的词并按你的词频重排（user_dict）。userdb 由引擎自建自管，法墨不碰。")
    lines.append("  \"translator/enable_user_dict\": true")
  }

  if s.wubiEnglishChannel {
    // ` 临时英文：仿 z 反查的前缀通道。` 追加进 speller/alphabet（4 变体均未显式定义 alphabet，
    // 基线 = librime 默认 zyxwvutsrqponmlkjihgfedcba，2026-07-21 核对）；segmentors 整表替换而非
    // `/+` 追加——追加会落到 fallback_segmentor 之后永远不执行，affix_segmentor 必须排在
    // abc_segmentor 之前（4 变体 stock 列表完全一致，2026-07-21 核对）。词库 melt_eng 与拼音线
    // 同一份（seed 已随 *.dict.yaml 打包进 SharedSupport）。前缀段不受四码上屏影响（z 反查同理）。
    lines.append("  # ` 临时英文（melt_eng）：` 进入英文组句，五笔四码上屏不受影响。")
    lines.append("  \"speller/alphabet\": \"zyxwvutsrqponmlkjihgfedcba`\"")
    lines.append("  \"engine/segmentors\":")
    lines.append("    - ascii_segmentor")
    lines.append("    - matcher")
    lines.append("    - affix_segmentor@melt_eng")
    lines.append("    - abc_segmentor")
    lines.append("    - punct_segmentor")
    lines.append("    - fallback_segmentor")
    lines.append("  \"engine/translators/+\":")
    lines.append("    - table_translator@melt_eng")
    lines.append("  melt_eng:")
    lines.append("    tag: melt_eng")
    lines.append("    dictionary: melt_eng")
    lines.append("    prefix: \"`\"")
    lines.append("    tips: 〔英文〕")
    lines.append("    closing_tips: 〔英文〕")
    lines.append("    enable_completion: true")
    lines.append("    enable_sentence: false")
    lines.append("    initial_quality: 1")
    lines.append("  \"recognizer/patterns/melt_eng\": \"^`[A-Za-z]*$\"")
  }

  return lines.joined(separator: "\n") + "\n"
}

/// Build the `speller/algebra/+` derive list entries (already 2-space + list indented)
/// for the enabled 模糊拼音 pairs. Returns an empty array when none are enabled so the
/// caller can omit the key entirely. Each derive is a standard rime `speller/algebra`
/// rule; the append-into-existing-algebra semantics are the caller's caveat, not these.
private func fuzzyAlgebraDerives(from f: FamoFuzzySnapshot) -> [String] {
  var entries: [String] = []

  func append(_ rule: String, comment: String) {
    entries.append("    - \(rule)  # \(comment)")
  }

  // 翘舌：zh/ch/sh → z/c/s（各自独立开关，只追加被勾选的那几条）
  if f.zhz { append("derive/^zh/z/", comment: "zh → z") }
  if f.chc { append("derive/^ch/c/", comment: "ch → c") }
  if f.shs { append("derive/^sh/s/", comment: "sh → s") }
  // 声母 n/l 互转
  if f.nl {
    append("derive/^n/l/", comment: "n → l")
    append("derive/^l/n/", comment: "l → n")
  }
  // 声母 r → l
  if f.rl { append("derive/^r/l/", comment: "r → l") }
  // 声母 f/h 互转
  if f.fh {
    append("derive/^f/h/", comment: "f → h")
    append("derive/^h/f/", comment: "h → f")
  }
  // 韵母 an/ang 互转
  if f.anang {
    append("derive/an$/ang/", comment: "an → ang")
    append("derive/ang$/an/", comment: "ang → an")
  }
  // 韵母 en/eng 互转
  if f.eneng {
    append("derive/en$/eng/", comment: "en → eng")
    append("derive/eng$/en/", comment: "eng → en")
  }
  // 韵母 in/ing 互转
  if f.ining {
    append("derive/in$/ing/", comment: "in → ing")
    append("derive/ing$/in/", comment: "ing → in")
  }

  return entries
}

/// Punctuator overrides shared by every bundled schema that imports `default`.
private func punctuatorPatchLines(from s: FamoKeyboardSnapshot) -> [String] {
  var lines: [String] = []
  if s.slashSymbolMenu {
    // `/` is a path separator in Rime patch keys, so it cannot be addressed as
    // `punctuator/half_shape//`; merge a map containing the literal key instead. Patch both shape
    // modes so this explicit option behaves consistently when the user toggles full-width mode.
    lines.append("  # 符号：/ 弹出候选（、 ASCII/ 全角／ ÷）；关闭本开关时法墨改为切英文并直接输出 /")
    lines.append("  \"punctuator/half_shape/+\":")
    lines.append("    \"/\": [\"、\", \"/\", \"／\", \"÷\"]")
    lines.append("  \"punctuator/full_shape/+\":")
    lines.append("    \"/\": [\"、\", \"/\", \"／\", \"÷\"]")
  }
  if s.angleSymbolMenu {
    // 只动 `<`（开括号），`>` 保持标量 `》` 直上屏——`>` 若变列表，每次闭合都弹菜单，且菜单确认
    // 的提交在 commit seam 会因 preedit 非空跳过右邻读，自动配对的 skip-over 就死了（见
    // FamoInputController+RimeUpdate 的 gate 注释）。选出 ASCII `<` 后由自动配对（ASCII 表）补对。
    // 整键替换（非 /+ 合并）：rime-ice half_shape 的 `<` 是标量 `《`，标量→列表类型不兼容合并。
    lines.append("  # 符号：< 弹出符号选单（《 〈 ASCII< 「 弯引号“；首选仍是《，继续打字自动上屏首选）")
    lines.append("  # 每项都是单字符开括号——选中后由「自动配对括号」补成对并居中光标（弯引号同表）。")
    lines.append("  \"punctuator/half_shape/<\": [\"《\", \"〈\", \"<\", \"「\", \"“\"]")
  }
  return lines
}

/// Build the `key_binder/bindings/+` list entries (already 2-space + list indented) for
/// the enabled 翻页 / 快速选词 / 全半角·中英标点 toggles. Returns an empty array when
/// none are enabled so the caller can omit the key entirely.
///
/// DE-DUPLICATED: the full/half-shape and ascii_punct toggles are double-written with
/// both shifted-key spellings (`Control+Shift+3` vs `Control+Shift+numbersign`, etc.)
/// for Squirrel/Weasel compat. A binding is keyed by its `{accept, send|toggle}` pair,
/// so even if two prefs request the same binding it is emitted exactly once.
///
/// NOTE: `-`/`=` are rime-ice defaults — emitting them again is harmless dedup-wise but
/// per the 回包 we only add the keys the user explicitly chose.
private func keyBinderBindings(from s: FamoKeyboardSnapshot) -> [String] {
  // A binding's identity is its (accept, action) pair — `when` and the trailing comment
  // are presentation, not identity, so two requests for the same key collapse to one.
  var seen = Set<String>()
  var entries: [String] = []

  func add(when: String, accept: String, action: String, comment: String) {
    let identity = "\(accept)|\(action)"
    guard seen.insert(identity).inserted else { return }
    entries.append("    - { when: \(when), accept: \(accept), \(action) }  # \(comment)")
  }

  // 减号 / 等号 翻页 (rime-ice default; only when chosen)
  if s.pageMinusEquals {
    add(when: "has_menu", accept: "minus", action: "send: Page_Up", comment: "减号上一页")
    add(when: "has_menu", accept: "equal", action: "send: Page_Down", comment: "等号下一页")
  }
  // 左右中括号 翻页 (paired with the select_character disable in the caller, Q1)
  if s.pageBrackets {
    add(when: "has_menu", accept: "bracketleft", action: "send: Page_Up", comment: "左括号上一页")
    add(when: "has_menu", accept: "bracketright", action: "send: Page_Down", comment: "右括号下一页")
  }
  // 逗号 / 句号 翻页
  if s.pageCommaPeriod {
    add(when: "has_menu", accept: "comma", action: "send: Page_Up", comment: "逗号上一页")
    add(when: "has_menu", accept: "period", action: "send: Page_Down", comment: "句号下一页")
  }
  // 分号 / 引号 选 2/3 位 — send: 2/3 (NOT select:, which is for schema switching) (Q2)
  if s.select23Semicolon {
    add(when: "has_menu", accept: "semicolon", action: "send: 2", comment: "分号选第 2 位")
    add(when: "has_menu", accept: "apostrophe", action: "send: 3", comment: "引号选第 3 位")
  }
  // 中英标点切换 ascii_punct — 始终绑定，快捷键不随默认开关存废（开关只决定默认状态，菜单/设置才是持久路径）。
  // double-written shifted-key names for Squirrel/Weasel (Q4)
  add(when: "always", accept: "Control+Shift+3", action: "toggle: ascii_punct", comment: "中英标点切换")
  add(when: "always", accept: "Control+Shift+numbersign", action: "toggle: ascii_punct", comment: "中英标点切换（shifted 键名兼容）")

  return entries
}

/// The `switcher/save_options/+` option names whose toggles the user actually wired (Q4).
/// Emitted only when the matching pref is on, so save_options isn't widened needlessly.
private func saveOptions(from s: FamoKeyboardSnapshot) -> [String] {
  var options: [String] = []
  if s.cjkPunctToggle { options.append("ascii_punct") }
  return options
}

#if DEBUG
/// Cheap, Debug-only sanity check for the generator. Trips an `assert` if the
/// default-prefs output loses its core structure. Non-fatal in Release (the whole
/// function is compiled out). Call once from the preview sheet presentation.
func famoPatchBuilderSelfCheck() {
  // Default prefs: pinyin, shift切换 on, 减号等号 + 左右中括号 翻页 on, 模糊拼音 all off.
  // The output must keep the `patch:` root and the live `key_binder` bindings block,
  // and — since every fuzzy pair is off — MUST NOT carry a `speller/algebra/+` block.
  let fuzzyOff = FamoFuzzySnapshot(
    zhz: false, chc: false, shs: false, nl: false, rl: false,
    fh: false, anang: false, eneng: false, ining: false
  )
  let defaults = FamoKeyboardSnapshot(
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
  let yaml = famoDefaultCustomYAML(from: defaults)
  assert(yaml.contains("patch:"), "Famo patch builder: missing patch: root")
  assert(yaml.contains("key_binder"), "Famo patch builder: missing key_binder block")
  assert(yaml.contains("ascii_composer/switch_key/Shift_L"), "Famo patch builder: missing Shift_L switch key")
  assert(yaml.contains("ascii_composer/switch_key/Shift_R"), "Famo patch builder: missing Shift_R switch key")
  assert(yaml.contains("ascii_composer/switch_key/Caps_Lock"), "Famo patch builder: missing Caps_Lock switch key")
  assert(yaml.contains("ascii_composer/good_old_caps_lock"), "Famo patch builder: missing good_old_caps_lock")
  assert(!yaml.contains("speller/algebra"), "Famo patch builder: speller/algebra must not be in default.custom.yaml")

  // v0.5 转正: with [] 翻页 + 快速选词 + `/`/`<` 符号选单 + 中英标点切换 all on,
  // the default output must carry the now-LIVE keys (Q1–Q4), and the bindings list must
  // contain no duplicate lines (the double-written shifted keys are dedup'd).
  var promoted = FamoKeyboardSnapshot(
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
  let promotedYAML = famoDefaultCustomYAML(from: promoted)
  assert(promotedYAML.contains("select_first_character"), "Famo patch builder: missing [] 以词定字 disable")
  assert(promotedYAML.contains("bracketleft"), "Famo patch builder: missing [] 翻页 binding")
  assert(promotedYAML.contains("send: 2"), "Famo patch builder: missing ; 选第 2 位 binding")
  assert(promotedYAML.contains("\"/\": [\"、\", \"/\", \"／\", \"÷\"]"), "Famo patch builder: missing `/` 符号选单 punctuator")
  assert(promotedYAML.contains("punctuator/half_shape/<"), "Famo patch builder: missing `<` 符号选单 punctuator")
  assert(promotedYAML.contains("toggle: ascii_punct"), "Famo patch builder: missing ascii_punct toggle")
  // app_options moved to the famo domain (task 07-08): default.custom.yaml must NOT carry it; the
  // dedicated famo.custom.yaml builder must.
  assert(!promotedYAML.contains("app_options/"), "Famo patch builder: app_options must NOT be in default.custom.yaml")
  assert(famoAppOptionsCustomYAML(from: promoted).contains("app_options/com.example.Editor/ascii_mode"), "Famo patch builder: missing app_options in famo.custom.yaml")
  // 双拼=小鹤: schema_list must put double_pinyin_flypy first.
  assert(promotedYAML.contains("schema: double_pinyin_flypy"), "Famo patch builder: missing 双拼置顶 schema_list")
  // De-dup: no `key_binder/bindings/+` list line (the `- { ... }` entries) repeats.
  let bindingLines = promotedYAML
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
    .filter { $0.hasPrefix("    - { ") }
  assert(bindingLines.count == Set(bindingLines).count, "Famo patch builder: duplicate key_binder binding line")

  // rime_ice.custom.yaml with all fuzzy off: header-only, no `speller/algebra`.
  let rimeIceOff = famoRimeIceCustomYAML(from: defaults)
  assert(!rimeIceOff.contains("speller/algebra"), "Famo patch builder: fuzzy block present with all pairs off")

  // With a couple fuzzy pairs on, the rime_ice.custom.yaml `speller/algebra/+` block +
  // the chosen derives must appear (and only the chosen ones — zh/z but not ch/c when
  // only zhz is on); default.custom.yaml stays free of `speller/algebra`.
  var fuzzyOn = fuzzyOff
  fuzzyOn = FamoFuzzySnapshot(
    zhz: true, chc: false, shs: false, nl: false, rl: false,
    fh: false, anang: true, eneng: false, ining: false
  )
  let withFuzzy = FamoKeyboardSnapshot(
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
  let defaultWithFuzzy = famoDefaultCustomYAML(from: withFuzzy)
  assert(!defaultWithFuzzy.contains("speller/algebra"), "Famo patch builder: fuzzy leaked into default.custom.yaml")

  let rimeIceYaml = famoRimeIceCustomYAML(from: withFuzzy)
  assert(rimeIceYaml.contains("speller/algebra/+"), "Famo patch builder: missing fuzzy algebra block")
  assert(rimeIceYaml.contains("derive/^zh/z/"), "Famo patch builder: missing enabled zh/z derive")
  assert(rimeIceYaml.contains("derive/an$/ang/"), "Famo patch builder: missing enabled an/ang derive")
  assert(!rimeIceYaml.contains("derive/^ch/c/"), "Famo patch builder: emitted ch/c derive when disabled")

  // user_dict 个性化（wubi 方案级）：默认 off → 无 enable_user_dict；on → translator/enable_user_dict: true。
  let wubiTarget = famoWubiPatchTargets[0]
  assert(!famoWubiCustomYAML(from: defaults, target: wubiTarget).contains("enable_user_dict"),
         "Famo patch builder: enable_user_dict present when personalization off")
  var udOn = defaults
  udOn.wubiUserDictLearning = true
  assert(famoWubiCustomYAML(from: udOn, target: wubiTarget).contains("\"translator/enable_user_dict\": true"),
         "Famo patch builder: missing enable_user_dict when personalization on")
}
#endif
