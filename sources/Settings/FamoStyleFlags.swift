//
//  FamoStyleFlags.swift
//  法墨输入法 (Famo) — Rime `style/*` layout flags (not theming)
//
//  The candidate-window LAYOUT flags the IMK path needs from Rime config:
//    linear / vertical → which Rime options the hot path (`processKey`) syncs;
//    inlinePreedit / inlineCandidate → how `rimeUpdate` assembles the inline preview;
//    statusMessageType → how the status HUD picks long vs. short labels.
//
//  These used to live on `FamoTheme` (deleted when SwiftUI became the sole renderer).
//  They are NOT colors/skins — those moved to `FamoThemes` (`FamoSkin`). This is a
//  tiny value-type reader over `FamoConfig`'s string/bool API, preserving the
//  precedence FamoTheme used for these keys: global `style/*`, overridden by a
//  per-schema `style/*` section when the active schema declares one.
//  Note: the legacy per-`color_scheme` override of layout flags
//  (`preset_color_schemes/<scheme>/...`) is intentionally NOT carried over — that was
//  part of the dropped Rime-yaml theming path and is runtime-inert at the shipped
//  default (`color_scheme: native`, which the old code skipped too).
//
//  Read off the IMK hot path (on schema change, in `loadSettings(for:)`); the live
//  default is the global config. The struct itself is `Sendable` plain data.
//

import Foundation

/// Candidate-window layout flags read from Rime `style/*` (default = legacy FamoTheme defaults).
struct FamoStyleFlags: Sendable, Equatable {
  var linear = false
  var vertical = false
  var inlinePreedit = false
  var inlineCandidate = false
  /// Default `.mix` matches the legacy `FamoTheme.statusMessageType` default.
  var statusMessageType: FamoStatusMessageType = .mix

  /// Read the layout flags from a `FamoConfig`. Reproduces `FamoTheme.load`'s reads for
  /// exactly these keys (`?=` only overrides when the key is present, so absent keys keep
  /// the current value — same as the old theme load over global → per-schema).
  mutating func apply(config: FamoConfig) {
    linear ?= config.getString("style/candidate_list_layout").map { $0 == "linear" }
    vertical ?= config.getString("style/text_orientation").map { $0 == "vertical" }
    inlinePreedit ?= config.getBool("style/inline_preedit")
    inlineCandidate ?= config.getBool("style/inline_candidate")
    statusMessageType ?= FamoStatusMessageType(rawValue: config.getString("style/status_message_type") ?? "")
  }

  /// The base flags read from the global config.
  static func base(config: FamoConfig) -> FamoStyleFlags {
    var flags = FamoStyleFlags()
    flags.apply(config: config)
    return flags
  }

  /// Per-session inline flag resolution（2026-07-12，从 `rimeUpdate` 提出来的纯函数，把优先级
  /// 锁死）：全局 `style/*` ∧ ¬`no_inline`，其中 app_options 的 `inline` 强制覆盖只对 preedit
  /// 生效（Chromium omnibox 规避，squirrel#435 先例——`inline: true` 必须压过全局 style 与
  /// `no_inline`）；`inline` 不强制 candidate 内嵌预览。
  static func sessionInline(
    style: FamoStyleFlags, noInline: Bool, inlineForced: Bool
  ) -> (preedit: Bool, candidate: Bool) {
    ((style.inlinePreedit && !noInline) || inlineForced,
     style.inlineCandidate && !noInline)
  }
}
