//
//  OwlPanelPreferences.swift
//  法墨输入法 (Owltype) — candidate panel preference value types
//
//  v0.2.2: user-customizable appearance for the SwiftUI candidate panel.
//  Persistence and runtime snapshots live exclusively in `OwlCandidatePanelSettings`.
//  NOT written to the user's `owltype.custom.yaml`.
//
//  Boundary (ADR-0001 / 0002 / 0003): prefs/panel layer only — never touches
//  the IMK key-event hot path.
//
//  Concurrency: plain `Sendable` value enums shared by settings and runtime snapshots.
//

import CoreGraphics
import Foundation

/// 候选窗尺寸（设置里的「候选窗尺寸」四档）。`base` 是候选正文的基准点数：面板里其余字号
/// （preedit ≈ base − 2、展开箭头 ≈ base − 5）**与全部留白**都由它派生，所以这一档拨的是整块
/// 面板的大小，不只是字。完整点数只由 `OwlCandidatePanelGeometry` 一次解析。
///
/// 类型名与 UserDefaults 键都保留 `FontSize`：`base` 本身确实是个字号，且键名一动老用户的
/// 小/中/大就白丢。
enum OwlPanelFontSize: String, CaseIterable, Sendable {
  case small
  case medium
  case large
  case extraLarge

  /// Base candidate text point size (小 = 16 / 中 = 19 / 大 = 23 / 特大 = 27).
  /// 步进比 1.19 / 1.21 / 1.17，是一条均匀的几何阶梯；小/中/大三个点数与四档化之前逐字相同。
  var base: CGFloat {
    switch self {
    case .small: 16
    case .medium: 19
    case .large: 23
    case .extraLarge: 27
    }
  }
}

/// Candidate-window orientation (G8 候选显示). `auto` keeps Rime's `_vertical` option
/// and Owltype's schema-aware defaults; `horizontal` / `vertical` override it from settings.
enum OwlPanelOrientation: String, CaseIterable, Sendable {
  case auto
  case horizontal
  case vertical
  /// 多行：每行显示一整页，翻页后保留上一页，并显示后续 1–4 页。
  /// 数字键只选择当前页；`scroll` 是已持久化的设置值。
  case scroll

  /// Resolve to the panel's `isVertical`, given Rime's `_vertical` option for `.auto`.
  ///
  /// `.auto` follows ONLY Rime's `_vertical` option — i.e. horizontal by default unless the
  /// active rime scheme explicitly requests vertical. `schemaID` is accepted (and ignored for
  /// `.auto`) so existing call sites need no change; there is no per-schema vertical default
  /// anymore (the old Wubi-forces-vertical special case was removed, 2026-06-22). The user can
  /// still pick 横排/竖排 explicitly to override.
  func isVertical(engineVertical: Bool, schemaID _: String = "") -> Bool {
    switch self {
    case .auto: engineVertical
    case .horizontal: false
    case .vertical: true
    case .scroll: false   // 多行是横排的一种（多行页），不是竖排
    }
  }

  /// 是否多行（主行 + 后页行）。仅显式 `.scroll` 为真；`auto/横排/竖排` 均为单行/纵列，
  /// 既有默认行为零变化。`isVertical` 为真时此值被忽略（竖排不叠加后页行）。
  var scrolls: Bool { self == .scroll }
}

/// When the status HUD (方案 / 中英 / 简繁 切换提示) pops. Maps Rime's
/// `show_notifications_when` (always / never / appropriate) to Owltype's self-drawn HUD:
/// `.always` shows both option + schema toasts; `.appropriate` shows schema switches only
/// (option toggles stay quiet); `.never` suppresses all (deploy 提示 is independent, stays on).
enum OwlNotificationWhen: String, CaseIterable, Sendable {
  case always
  case appropriate
  case never
}

/// Candidate cell layout preset (Feature 7). Owltype draws label + text + comment itself, so
/// `squirrel.yaml candidate_format` is inert — these presets drive the SwiftUI panel directly.
/// Provenance tags are NOT governed here (design core).
enum OwlCandidateFormat: String, CaseIterable, Sendable {
  /// 标签 + 候选 + 注释 (the shipping default).
  case full
  /// 标签 + 候选，隐藏注释（拼音/释义）.
  case noComment
  /// 仅候选：隐藏序号标签与注释.
  case candidateOnly

  /// Whether the序号/字母 label is rendered.
  var showsLabel: Bool { self != .candidateOnly }
  /// Whether the comment (reading / 释义) is rendered.
  var showsComment: Bool { self == .full }
}
