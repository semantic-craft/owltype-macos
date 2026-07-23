//
//  FamoCandidatePanelState.swift
//  法墨输入法 (Famo) — SwiftUI candidate panel
//
//  This SwiftUI candidate panel renders the candidate UI only; key events, marked
//  text, and commit stay on the native IMK hot path (FamoInputController).
//
//  Boundary (ADR-0001 / 0002): SwiftUI renders the candidate UI only.
//

import Foundation
import SwiftUI
import Observation

/// Observable snapshot of the current composition + candidate page.
/// Not `@MainActor`-isolated (matches the existing non-isolated `FamoPanel`); all access
/// happens on the main thread via the IMK callbacks, like the rest of the candidate UI.
@Observable
final class CandidatePanelState {
  var preedit: String = ""
  /// Caret position within `preedit`, as a UTF-16 offset (0…`preedit.utf16.count`). Splits the
  /// header so the blinking bar sits at librime's real cursor while arrow keys edit the pinyin,
  /// instead of always at the tail. Seeded each composition from `cursor_pos` (see
  /// `RimeCompositionRenderer.preeditCaretUTF16`); the panel clamps it before slicing.
  var cursor: Int = 0
  /// Highlight span within `preedit` (the syllable being converted), UTF-16 offsets. The header
  /// tints [selStart, selEnd) with the accent color. Both 0 when there is no active selection.
  var selStart: Int = 0
  var selEnd: Int = 0
  var candidates: [CandidateViewModel] = []
  var highlightedIndex: Int = 0
  var page: Int = 0
  var hasPrevPage: Bool = false
  var hasNextPage: Bool = false
  var isVertical: Bool = false
  /// 横排折行（多行矩形）模式：候选横向排布、排满一行折到下一行。仅当用户显式选 `.flow`
  /// 排列方向时为真（`FamoPanelOrientation.wraps`）。与 `isVertical` 互斥——竖排永不折行；
  /// `isVertical` / `isExpanded` 为真时本值被忽略（走竖排/展开列表）。
  var isFlow: Bool = false
  /// Active Rime schema id. The compact horizontal bar uses it to keep Wubi code hints visible
  /// without showing noisy pinyin readings for ordinary pinyin schemas.
  var schemaID: String = ""
  /// Whether the horizontal pill bar is expanded into the full wrapped/vertical list.
  /// Toggled by the trailing expand chevron in `FamoCandidatePanelView`; reset to
  /// false at the start of each new composition (in `FamoSwiftUICandidatePanel.update`)
  /// so every composition begins compact. Ignored when `isVertical` is true.
  var isExpanded: Bool = false
  var theme: FamoCandidateTheme = .deepred
  /// Base candidate text point size. The view derives preedit (base − 2) and
  /// paging chevrons (base − 3) from it. Seeded from `FamoPanelPreferences.fontSize`
  /// on the live panel; defaults to 中 (16).
  var fontSize: CGFloat = 16
  /// Candidate text typeface family (G8). Seeded from `FamoPanelPreferences.fontDesign`.
  var fontDesign: FamoPanelFontDesign = .default
  /// Whether candidate-bar animations run (G8). Seeded from `FamoPanelPreferences`;
  /// the view ANDs this with `!reduceMotion` so Reduce Motion always wins.
  var animationsEnabled: Bool = true
  /// Whether the panel renders its own preedit header (输入串). Off → host inline
  /// marked text only. Seeded from `FamoPanelPreferences.showPreedit`.
  var showPreedit: Bool = true
  /// 候选条翻页箭头 (Feature 4). Off → the compact bar's 上/下页 dots are hidden.
  /// Seeded from `FamoPanelPreferences.showPaging`.
  var showPaging: Bool = true
  /// 候选格式预设 (Feature 7). Drives label / comment visibility in both forms.
  /// Seeded from `FamoPanelPreferences.candidateFormat`.
  var candidateFormat: FamoCandidateFormat = .full

  var isWubiSchema: Bool {
    schemaID.hasPrefix("wubi86_")
  }

  func showsCompactComment(for candidate: CandidateViewModel) -> Bool {
    candidateFormat.showsComment && isWubiSchema && candidate.comment?.isEmpty == false
  }
}

/// One candidate row. `Sendable` so a snapshot can be built off the hot path and
/// handed to the panel without sharing mutable Rime state.
struct CandidateViewModel: Identifiable, Sendable, Equatable {
  let id: Int
  let label: String
  let text: String
  let comment: String?
  /// Law-citation candidate (from `law_citation.lua`, shape 《…》第…条…) → render the
  /// small 「法」 badge in the vertical list (the Claude Design "citation" variant).
  let badge: Bool
  /// Citation source line shown under the word in the vertical list; nil for ordinary
  /// candidates (whose reading/释义 stays in `comment`).
  let source: String?
  /// G3: user-visible provenance (个人/项目/规则/已核验). `nil` = ordinary main-lane
  /// Rime pinyin candidate → no label rendered (avoids per-candidate noise).
  let provenance: FamoProvenance?

  init(id: Int, label: String, text: String, comment: String? = nil, badge: Bool = false, source: String? = nil, provenance: FamoProvenance? = nil) {
    self.id = id
    self.label = label
    self.text = text
    self.comment = comment
    self.badge = badge
    self.source = source
    self.provenance = provenance
  }
}

/// sRGB color built from a `#RRGGBB` hex string (no alpha). Used by the 深大红 theme.
/// Falls back to opaque black for malformed input — values here are all hardcoded and valid.
func famoColor(hex: String) -> Color {
  var value: UInt64 = 0
  let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
  Scanner(string: trimmed).scanHexInt64(&value)
  let r = Double((value & 0xFF0000) >> 16) / 255.0
  let g = Double((value & 0x00FF00) >> 8) / 255.0
  let b = Double(value & 0x0000FF) / 255.0
  return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
}

/// One resolved palette (light or dark) of the deep-red theme.
/// The eight tokens below are the palette's single source of truth.
struct FamoCandidatePalette: Sendable, Equatable {
  let accent: Color
  let accentDeep: Color
  let onAccent: Color
  let card: Color
  let card2: Color
  let ink: Color
  let ink2: Color
  let ink3: Color
}

/// Visual theme parameters + the deep-red color palettes (light / dark).
///
/// Colors are bundled here rather than read from configuration at runtime.
/// Pick light/dark via `@Environment(\.colorScheme)`.
///
/// Token → use mapping:
///   panel bg = card; selected candidate pill = accent, its text/label = onAccent;
///   normal candidate text = ink; label/comment = ink3; preedit = ink2 on card2;
///   border = accentDeep.
struct FamoCandidateTheme: Sendable, Equatable {
  var cornerRadius: CGFloat
  var shadowRadius: CGFloat
  var light: FamoCandidatePalette
  var dark: FamoCandidatePalette

  /// Pick the palette for the active color scheme.
  func palette(for scheme: ColorScheme) -> FamoCandidatePalette {
    scheme == .dark ? dark : light
  }

  static let deepred = FamoCandidateTheme(
    cornerRadius: 13,
    shadowRadius: 16,
    light: FamoCandidatePalette(
      accent: famoColor(hex: "A82C53"),
      accentDeep: famoColor(hex: "8E2447"),
      onAccent: famoColor(hex: "FBF9F5"),
      card: famoColor(hex: "FBF9F5"),
      card2: famoColor(hex: "F3EFE7"),
      ink: famoColor(hex: "2A2622"),
      ink2: famoColor(hex: "6B6A64"),
      ink3: famoColor(hex: "9A9387")
    ),
    dark: FamoCandidatePalette(
      accent: famoColor(hex: "E06A8E"),
      accentDeep: famoColor(hex: "C24E72"),
      onAccent: famoColor(hex: "1A1816"),
      card: famoColor(hex: "262321"),
      card2: famoColor(hex: "211E1C"),
      ink: famoColor(hex: "ECE4D8"),
      ink2: famoColor(hex: "A89E90"),
      ink3: famoColor(hex: "766D62")
    )
  )
}

/// G3 候选来源标签（provenance）。
enum FamoProvenanceColor {
  static let personal = famoColor(hex: "5E7F6B")  // 个人
  static let project  = famoColor(hex: "3F6E9C")  // 场景
  static let rule     = famoColor(hex: "9A7234")  // 规则
  static let verified = famoColor(hex: "3C7A52")  // 已核验
}

/// G3 候选来源。由 `EnhancedCandidate` 的 lane/source 经纯函数派生
/// (`EnhancedCandidate.provenance(...)`)；`nil` 表示普通拼音候选，不渲染标签。
/// 展示名 + token 颜色都在此集中，视图层不散落硬编码 hex。
enum FamoProvenance: String, Sendable, Equatable, CaseIterable {
  case personal   // 个人 — 本地词频/个人词库
  case project    // 场景 — 当前场景词库排序
  case rule       // 规则 — 本地法律对象/引注（版本未知）
  case verified   // 已核验 — 法律对象且字段完整、版本已知

  /// Short pill label.
  var displayName: String {
    switch self {
    case .personal: return "个人"
    case .project:  return "场景"
    case .rule:     return "规则"
    case .verified: return "已核验"
    }
  }

  /// Token color (provenance §07 / colors.md). Selected-state inversion is the view's job.
  var color: Color {
    switch self {
    case .personal: return FamoProvenanceColor.personal
    case .project:  return FamoProvenanceColor.project
    case .rule:     return FamoProvenanceColor.rule
    case .verified: return FamoProvenanceColor.verified
    }
  }

  var needsConfirmation: Bool { false }
}
