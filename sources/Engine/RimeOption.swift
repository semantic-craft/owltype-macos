//
//  RimeOption.swift
//  Owltype
//
//  The closed set of Rime engine options Owltype *drives* (set / get / toggle) on a
//  session. Option keys used to be bare string literals scattered across
//  OwlInputController, where a typo would silently no-op. This enum is the single
//  source of truth so the compiler catches the typo instead.
//
//  Scope note: option *names that librime reports back* (e.g. in the notification
//  handler's `get_state_label_abbreviated(session, name, …)`) are an open namespace
//  owned by Rime/the schema, not by Owltype — those intentionally stay `String` and are
//  NOT RimeOptions. See CONTEXT.md (repo root) → "Option".
//

/// A Rime session option Owltype drives. `rawValue` is the librime option key.
enum RimeOption: String, CaseIterable {
  // Engine-standard options.
  case asciiMode = "ascii_mode"
  case asciiPunct = "ascii_punct"
  case fullShape = "full_shape"
  case traditional
  case traditionalization
  case zhTrad = "zh_trad"
  case simplification
  /// rime-ice (雾凇拼音) 的 全拼/双拼 简↔繁 走 `traditionalization`（见上）。`transcription`
  /// 是某些方案（如 rime_mint）用 `simplifier@transcription_cc` 驱动的简繁 option；Owltype 底座
  /// 是 rime-ice 用不到它，但保留该 case 以兼容可能携带它的方案。Live runtime option（无需 redeploy）。
  case transcription
  /// rime 原生「候选 emoji」开关。rime-ice 的 switch 名是 `emoji`（其 `simplifier@emoji` 过滤器据此开关）。
  /// Owltype 出厂把 schema switch reset 1→0（owl-seed.sh），默认关；由 表情符号 设置开关 live 驱动。
  case emojiSuggestion = "emoji"
  case vimMode = "vim_mode"

  // Front-end (Squirrel/Owltype) presentation conventions — `_`-prefixed by Rime
  // convention to mark them as client-set rather than schema-defined.
  case linear = "_linear"
  case vertical = "_vertical"
  case chordTyping = "_chord_typing"
  case noInline = "no_inline"
  case inline
  case softCursor = "soft_cursor"
}
