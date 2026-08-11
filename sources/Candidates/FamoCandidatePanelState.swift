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
  /// 卷轴的前/后页行：主行（`candidates` = librime 当前页）之外预取的整页——紧邻的前 1 页
  /// + 后 1–4 页，视图按页号排序合并进同一列。空 = 单行（没翻过页 / 非卷轴方向 / 竖排
  /// ——控制器侧已按偏好与「翻页才展开」旗标门控，这里只消费数据）。
  var scrollRows: [FamoScrollRow] = []
  var highlightedIndex: Int = 0
  var page: Int = 0
  var hasPrevPage: Bool = false
  var hasNextPage: Bool = false
  var isVertical: Bool = false
  /// 卷轴模式：主行 = 当前页，下方跟 `scrollRows`。仅当用户显式选 `.scroll` 排列方向时为真
  /// （`FamoPanelOrientation.scrolls`）。与 `isVertical` 互斥——竖排不叠加后页行；
  /// `isVertical` / `isExpanded` 为真时本值被忽略（走竖排/展开列表）。
  var isScroll: Bool = false
  /// Active Rime schema id. The compact horizontal bar uses it to keep Wubi code hints visible
  /// without showing noisy pinyin readings for ordinary pinyin schemas.
  var schemaID: String = ""
  /// Whether the horizontal pill bar is expanded into the full wrapped/vertical list.
  /// Toggled by the trailing expand chevron in `FamoCandidatePanelView`; reset to
  /// false at the start of each new composition (in `FamoSwiftUICandidatePanel.update`)
  /// so every composition begins compact. Ignored when `isVertical` is true.
  var isExpanded: Bool = false
  /// Persisted appearance intent. The hosting panel applies it to `NSWindow.appearance`; retaining
  /// it in observable state also makes the complete appearance snapshot externally verifiable.
  var appearance: FamoPanelAppearance = .system
  var theme: FamoCandidateTheme = .shenda
  /// Base candidate text point size. The view derives preedit (base − 2), paging chevrons
  /// (base − 3) and **every padding** from it — 留白由 resolved geometry 以中档为锚
  /// 等比换算，所以这一个数就是「候选窗尺寸」那一档。Applied from the complete candidate-panel
  /// settings snapshot on the live panel.
  ///
  /// 默认写成 `.medium.base` 而不是裸数：原来的注释说「defaults to 中」而值是 16（那是小档的
  /// 点数），四档化后留白也跟着它走，默认档一错整块面板的边距就跟着错。
  var fontSize: CGFloat = FamoCandidatePanelSettings.defaultSize.base
  /// Resolved candidate font (system / installed family / explicit fallback). Applied as one value
  /// by `FamoCandidatePanelSettings`; the renderer never performs installation detection.
  var candidateFont: FamoCandidateFont = .systemDefault
  /// Whether candidate-bar animations run (G8). Applied by `FamoCandidatePanelSettings`;
  /// the view ANDs this with `!reduceMotion` so Reduce Motion always wins.
  var animationsEnabled: Bool = true
  /// Whether the panel renders its own preedit header (输入串). Off → host inline marked text only.
  var showPreedit = FamoCandidatePanelSettings.defaultShowPreedit
  /// 候选条翻页箭头 (Feature 4). Off → the compact bar's 上/下页 dots are hidden.
  var showPaging = FamoCandidatePanelSettings.defaultShowPaging
  /// 候选格式预设 (Feature 7). Drives label / comment visibility in both forms.
  var candidateFormat = FamoCandidatePanelSettings.defaultCandidateFormat
  /// Configured number of following pages for scroll mode. The controller bounded-prefetches the
  /// module maximum; retaining the active limit here lets one complete settings apply reveal or
  /// hide already-fetched rows without confusing the preference with the `scrollRows` data.
  var scrollRowLimit = FamoCandidatePanelSettings.defaultScrollRows

  /// Rows visible under the current scroll setting. The preceding page remains a fixed one-row
  /// history; only following pages are limited. The controller keeps the bounded maximum prefetched
  /// so changing this limit can reveal or hide rows immediately without another Rime interaction.
  var visibleScrollRows: [FamoScrollRow] {
    let preceding = scrollRows.filter { $0.id < page }
    let following = scrollRows.filter { $0.id > page }.prefix(scrollRowLimit)
    return preceding + Array(following)
  }

  /// Candidate animations run only when both the user preference and system accessibility policy
  /// allow them. Keeping this decision here gives rendering and lifecycle tests one rule.
  func animationsAllowed(reduceMotion: Bool) -> Bool {
    animationsEnabled && !reduceMotion
  }

  var isWubiSchema: Bool {
    schemaID.hasPrefix("wubi86_")
  }

  func showsCompactComment(for candidate: CandidateViewModel) -> Bool {
    candidateFormat.showsComment && isWubiSchema && candidate.comment?.isEmpty == false
  }
}

/// 卷轴里的一整页候选（前页行或后页行）。`id` 取 librime 的**页号**，这是卷轴动画的关键：
/// 翻一页后行集合从 [p−1, p, p+1, …] 变成 [p, p+1, p+2, …]，页号不变的行保住 SwiftUI
/// 身份、于是被动画成「上滚一行」，而不是整块闪替。
///
/// `candidates` 里的 `id` 是**候选在整张候选列表里的绝对下标**（不是页内偏移）——前/后页行
/// 的点击要走 `select_candidate(绝对下标)`，页内下标在那里是错的。
struct FamoScrollRow: Identifiable, Sendable, Equatable {
  let id: Int
  let candidates: [CandidateViewModel]
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
  /// G3: user-visible provenance (个人/项目/规则/已核验/AI). `nil` = ordinary main-lane
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

/// One resolved palette (light or dark) of the 深大红 (shenda) theme.
/// 8 tokens; source of truth `packages/rime-law-config/skins/colors.md` (shenda).
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

/// Visual theme parameters + the 深大红 (shenda) color palettes (light / dark).
///
/// Colors are hardcoded from the project color source of truth
/// `packages/rime-law-config/skins/colors.md` (shenda) — v0.1.1 does not read
/// them live from famo.custom.yaml. Pick light/dark via `@Environment(\.colorScheme)`.
///
/// Token → use mapping:
///   panel bg = card; selected candidate pill = accent, its text/label = onAccent;
///   normal candidate text = ink; label/comment = ink3; preedit = ink2 on card2;
///   border = accentDeep.
struct FamoCandidateTheme: Sendable, Equatable {
  var cornerRadius: CGFloat
  var light: FamoCandidatePalette
  var dark: FamoCandidatePalette

  /// Pick the palette for the active color scheme.
  func palette(for scheme: ColorScheme) -> FamoCandidatePalette {
    scheme == .dark ? dark : light
  }

  static let shenda = FamoCandidateTheme(
    cornerRadius: 13,
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

/// G3 候选来源标签五色（provenance）。G2 在此预留命名位，G3 负责把它们渲染进候选窗。
/// AI 与 Claude design accent 同值 (#C96442)，确保 AI 候选与强调色一致。
/// 单一真相源 `packages/rime-law-config/skins/colors.md`（provenance 段）。
enum FamoProvenanceColor {
  static let personal = famoColor(hex: "5E7F6B")  // 个人
  static let project  = famoColor(hex: "3F6E9C")  // 场景
  static let rule     = famoColor(hex: "9A7234")  // 规则
  static let verified = famoColor(hex: "3C7A52")  // 已核验
  static let ai       = famoColor(hex: "C96442")  // AI（= Claude accent）
}

/// G3 候选来源（五类）。由 `EnhancedCandidate` 的 lane/source 经纯函数派生
/// (`EnhancedCandidate.provenance(...)`)；`nil` 表示普通拼音候选，不渲染标签。
/// 展示名 + token 颜色都在此集中，视图层不散落硬编码 hex。
enum FamoProvenance: String, Sendable, Equatable, CaseIterable {
  case personal   // 个人 — 本地词频/个人词库
  case project    // 场景 — 当前场景词库排序
  case rule       // 规则 — 本地法律对象/引注（版本未知）
  case verified   // 已核验 — 法律对象且字段完整、版本已知
  case ai         // AI — DeepSeek/cloud lane，始终需确认、不自动上屏/学习

  /// Short pill label.
  var displayName: String {
    switch self {
    case .personal: return "个人"
    case .project:  return "场景"
    case .rule:     return "规则"
    case .verified: return "已核验"
    case .ai:       return "AI"
    }
  }

  /// Token color (provenance §07 / colors.md). Selected-state inversion is the view's job.
  var color: Color {
    switch self {
    case .personal: return FamoProvenanceColor.personal
    case .project:  return FamoProvenanceColor.project
    case .rule:     return FamoProvenanceColor.rule
    case .verified: return FamoProvenanceColor.verified
    case .ai:       return FamoProvenanceColor.ai
    }
  }

  /// AI candidates carry a "需确认" affordance and never auto-commit/learn.
  var needsConfirmation: Bool { self == .ai }
}
