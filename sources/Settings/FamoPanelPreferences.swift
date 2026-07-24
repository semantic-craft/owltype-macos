//
//  FamoPanelPreferences.swift
//  法墨输入法 (Famo) — SwiftUI candidate panel preferences
//
//  v0.2.2: user-customizable appearance for the SwiftUI candidate panel.
//  Several prefs persisted in UserDefaults (Famo-namespaced): appearance mode
//  (跟随系统/浅色/深色), candidate font size (小/中/大), orientation, typeface, animations.
//  NOT written to the user's `famo.custom.yaml`.
//
//  Single key home: the `"FamoPanelAppearance"` / `"FamoPanelFontSize"` (etc.)
//  UserDefaults string literals live ONLY in this file. The live panel and the
//  settings layer read/write through these accessors.
//
//  Boundary (ADR-0001 / 0002 / 0003): prefs/panel layer only — never touches
//  the IMK key-event hot path.
//
//  Concurrency: plain `Sendable` value enums; the accessors run on the main
//  thread like the rest of the candidate / settings UI.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Candidate-panel appearance mode. `system` follows `@Environment(\.colorScheme)`
/// as before; `light` / `dark` force the panel's `NSAppearance` (which makes the
/// hosted SwiftUI `colorScheme` resolve accordingly).
enum FamoPanelAppearance: String, CaseIterable, Sendable {
  case system
  case light
  case dark
}

/// Candidate-panel font size. `base` is the candidate text point size; the view
/// derives preedit (≈ base − 2) and paging chevrons (≈ base − 3) from it.
enum FamoPanelFontSize: String, CaseIterable, Sendable {
  case small
  case medium
  case large

  /// Base candidate text point size (小 = 16 / 中 = 19 / 大 = 23).
  var base: CGFloat {
    switch self {
    case .small: 16
    case .medium: 19
    case .large: 23
    }
  }
}

/// Candidate-window orientation (G8 候选显示). `auto` keeps Rime's `_vertical` option
/// and Famo's schema-aware defaults; `horizontal` / `vertical` override it from settings.
enum FamoPanelOrientation: String, CaseIterable, Sendable {
  case auto
  case horizontal
  case vertical
  /// 横排折行（多行矩形）：横排的一种，候选排满一行折到下一行、堆成矩形（鼠鬚管
  /// 0.15.0 起「候选折行」同款）。`isVertical` 仍为 false；`wraps` 才是它与单行横排的区别。
  case flow

  /// Resolve to the panel's `isVertical`, given Rime's `_vertical` option for `.auto`.
  ///
  /// `.auto` follows ONLY Rime's `_vertical` option — i.e. horizontal by default unless the
  /// active rime scheme explicitly requests vertical. `schemaID` is accepted (and ignored for
  /// `.auto`) so existing call sites need no change; there is no per-schema vertical default
  /// anymore (the old Wubi-forces-vertical special case was removed, 2026-06-22). The user can
  /// still pick 横排/竖排 explicitly to override.
  func isVertical(rimeVertical: Bool, schemaID _: String = "") -> Bool {
    switch self {
    case .auto: rimeVertical
    case .horizontal: false
    case .vertical: true
    case .flow: false   // 折行是横排的一种（多行矩形），不是竖排
    }
  }

  /// 是否横排折行（多行矩形）。仅显式 `.flow` 为真；`auto/横排/竖排` 均不折行，
  /// 既有默认行为零变化。`isVertical` 为真时此值被忽略（竖排永不折行）。
  var wraps: Bool { self == .flow }
}

/// Candidate text typeface family (G8 候选显示). System choices map to SwiftUI
/// `Font.Design`; `notoSerifSC` requests Google's Simplified Chinese serif when installed.
enum FamoPanelFontDesign: String, CaseIterable, Sendable {
  case `default`
  case serif
  case rounded
  case notoSerifSC

  var design: Font.Design {
    switch self {
    case .default: .default
    case .serif: .serif
    case .rounded: .rounded
    case .notoSerifSC: .serif
    }
  }

  static let notoSerifSCDownloadURL = URL(string: "https://github.com/googlefonts/noto-cjk/raw/main/Serif/Variable/OTF/NotoSerifCJKsc-VF.otf")!

  private static let notoSerifSCFamilies = [
    "Noto Serif SC",
    "Noto Serif CJK SC",
    "Noto Serif CJK SC VF",
  ]

  static var isNotoSerifSCInstalled: Bool {
    installedNotoSerifSCFamily(in: NSFontManager.shared.availableFontFamilies) != nil
  }

  static func installedNotoSerifSCFamily(in availableFamilies: [String]) -> String? {
    let installed = Set(availableFamilies.map { $0.lowercased() })
    return notoSerifSCFamilies.first { installed.contains($0.lowercased()) }
  }

  func candidateFont(size: CGFloat) -> Font {
    guard self == .notoSerifSC else {
      return .system(size: size, design: design)
    }
    guard let family = Self.installedNotoSerifSCFamily(in: NSFontManager.shared.availableFontFamilies) else {
      return .system(size: size, design: .serif)
    }
    return .custom(family, size: size)
  }
}

/// When the status HUD (方案 / 中英 / 简繁 切换提示) pops. Maps Rime's
/// `show_notifications_when` (always / never / appropriate) to Famo's self-drawn HUD:
/// `.always` shows both option + schema toasts; `.appropriate` shows schema switches only
/// (option toggles stay quiet); `.never` suppresses all (deploy 提示 is independent, stays on).
enum FamoNotificationWhen: String, CaseIterable, Sendable {
  case always
  case appropriate
  case never
}

/// Candidate cell layout preset (Feature 7). Famo draws label + text + comment itself, so
/// `squirrel.yaml candidate_format` is inert — these presets drive the SwiftUI panel directly.
/// 法务徽章「法」/ citation source line / provenance tags are NOT governed here (design core).
enum FamoCandidateFormat: String, CaseIterable, Sendable {
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

/// Single home for the SwiftUI candidate-panel appearance preferences. The key
/// string literals appear ONLY here; the live panel and settings UI read/write
/// through these accessors so there are no duplicate literals.
enum FamoPanelPreferences {
  /// Appearance mode. Key `"FamoPanelAppearance"`, default `.system`.
  static var appearance: FamoPanelAppearance {
    get {
      FamoPanelAppearance(rawValue: FamoDefaults.standard.string(forKey: "FamoPanelAppearance") ?? "") ?? .system
    }
    set {
      FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoPanelAppearance")
    }
  }

  /// Candidate font size. Key `"FamoPanelFontSize"`, default `.medium`.
  static var fontSize: FamoPanelFontSize {
    get {
      FamoPanelFontSize(rawValue: FamoDefaults.standard.string(forKey: "FamoPanelFontSize") ?? "") ?? .medium
    }
    set {
      FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoPanelFontSize")
    }
  }

  /// Candidate-window orientation. Key `"FamoPanelOrientation"`, default `.auto`.
  ///
  /// 迁移（2026-07-22，「默认形态 单行/卷轴」并入排列方向）：老的「卷轴」= 每次组字默认展开成
  /// 纵向候选列表，其渲染与 `.vertical` 完全相同（`showsFullList` 同走 `verticalList`）。故**未显式
  /// 选过排列方向**、但开过 legacy `FamoPanelExpandedByDefault` 的用户回落到 `.vertical`，保住其展开
  /// 纵列观感；一旦显式选任一方向即以新键为准（getter 内惰性迁移，仿 `FamoKeyboardPreferences.wubiScheme`）。
  static var orientation: FamoPanelOrientation {
    get {
      if let raw = FamoDefaults.standard.string(forKey: "FamoPanelOrientation"),
         let value = FamoPanelOrientation(rawValue: raw) {
        return value
      }
      if FamoDefaults.standard.object(forKey: "FamoPanelExpandedByDefault") as? Bool == true {
        return .vertical
      }
      return .auto
    }
    set {
      FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoPanelOrientation")
    }
  }

  /// Candidate text typeface. Key `"FamoPanelFontDesign"`, default `.default`.
  static var fontDesign: FamoPanelFontDesign {
    get {
      FamoPanelFontDesign(rawValue: FamoDefaults.standard.string(forKey: "FamoPanelFontDesign") ?? "") ?? .default
    }
    set {
      FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoPanelFontDesign")
    }
  }

  /// Candidate-bar animations (highlight slide / expand). Key `"FamoPanelAnimations"`,
  /// default `true`. Reduce Motion still wins when the user has it on.
  static var animationsEnabled: Bool {
    get { FamoDefaults.standard.object(forKey: "FamoPanelAnimations") as? Bool ?? true }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoPanelAnimations") }
  }

  /// Whether the panel renders its own preedit header (输入串 + 虚线下划线 + 闪烁光标).
  /// Off → rely on the host app's inline marked text only, dropping the duplicate pinyin
  /// string inside the panel. Key `"FamoPanelShowPreedit"`, default `true`.
  static var showPreedit: Bool {
    get { FamoDefaults.standard.object(forKey: "FamoPanelShowPreedit") as? Bool ?? true }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoPanelShowPreedit") }
  }

  /// 内嵌候选预览 (inline_candidate). Key `"FamoPanelInlineCandidate"`, default `false`.
  /// Overrides `styleFlags.inlineCandidate` (read in `loadSettings`) so the host-app inline
  /// preview shows the highlighted candidate. Feature 3.
  static var inlineCandidate: Bool {
    get { FamoDefaults.standard.object(forKey: "FamoPanelInlineCandidate") as? Bool ?? false }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoPanelInlineCandidate") }
  }

  /// 候选条翻页箭头 (show_paging). Key `"FamoPanelShowPaging"`, default `true`.
  /// Gates the compact bar's 上/下页 page dots (the only mouse-paging affordance). Feature 4.
  static var showPaging: Bool {
    get { FamoDefaults.standard.object(forKey: "FamoPanelShowPaging") as? Bool ?? true }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoPanelShowPaging") }
  }

  /// 预览后页（三行候选·方向④做法Ⓑ「等大淡显」）. Key `"FamoPanelPreviewPages"`,
  /// default `false`（现状零变化）. On → 横排紧凑条下方以等大、淡显、无序号、不可交互的
  /// 预览行显示后面 1–2 页；数据来自 librime 候选列表只读枚举（不真翻页）。竖排/折行/
  /// 展开列表不叠加预览。
  static var previewPages: Bool {
    get { FamoDefaults.standard.object(forKey: "FamoPanelPreviewPages") as? Bool ?? false }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoPanelPreviewPages") }
  }

  /// 预览行数（1 或 2）. Key `"FamoPanelPreviewRows"`, default `2`. 读取时钳到 1...2，
  /// 抵御手改 defaults 写出的越界值。
  static var previewRows: Int {
    get { min(2, max(1, FamoDefaults.standard.object(forKey: "FamoPanelPreviewRows") as? Int ?? 2)) }
    set { FamoDefaults.standard.set(min(2, max(1, newValue)), forKey: "FamoPanelPreviewRows") }
  }

  /// 切换提示通知 (show_notifications_when). Key `"FamoPanelShowNotificationsWhen"`,
  /// default `.always` (preserves shipping behavior). Feature 5.
  static var showNotificationsWhen: FamoNotificationWhen {
    get { FamoNotificationWhen(rawValue: FamoDefaults.standard.string(forKey: "FamoPanelShowNotificationsWhen") ?? "") ?? .always }
    set { FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoPanelShowNotificationsWhen") }
  }

  /// 候选格式 (candidate_format preset). Key `"FamoPanelCandidateFormat"`, default `.full`.
  /// Drives the SwiftUI panel's label / comment visibility. Feature 7.
  static var candidateFormat: FamoCandidateFormat {
    get { FamoCandidateFormat(rawValue: FamoDefaults.standard.string(forKey: "FamoPanelCandidateFormat") ?? "") ?? .full }
    set { FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoPanelCandidateFormat") }
  }
}

/// The panel's visual preferences frozen at one instant, injected into the candidate panel so it
/// renders from a value instead of reaching into `FamoPanelPreferences` / `FamoSkinPreferences`
/// live mid-render (C3, task 07-05-famo-composition-render-seam). Mirrors the `FamoFuzzySnapshot`
/// / `FamoKeyboardSnapshot` precedent (Sendable value + `current()` factory). Carries the 9 fields
/// `FamoSwiftUICandidatePanel` applies; `orientation` stays raw — the panel resolves it against the
/// composition's `isVertical` + `schemaID`. Distinct from the domain **Snapshot** (a Composition
/// capture for stale-work rejection); this is a Preferences snapshot, domain-qualified by name.
struct FamoPanelSnapshot: Sendable, Equatable {
  let orientation: FamoPanelOrientation
  let fontSize: FamoPanelFontSize
  let fontDesign: FamoPanelFontDesign
  let animationsEnabled: Bool
  let showPreedit: Bool
  let showPaging: Bool
  let candidateFormat: FamoCandidateFormat
  let theme: FamoCandidateTheme
  let appearance: FamoPanelAppearance
  /// 预览后页 + 预览行数（三行候选·方向④Ⓑ）。控制器在 `showPanel` 里据此决定是否
  /// 预取后页候选；面板/视图只消费取好的 `previewRows` 数据，不再读这两个偏好。
  let previewPages: Bool
  let previewRows: Int

  /// Read every backing preference once. Called by the controller (in `showPanel`) per composition,
  /// and by the panel's `refreshPreferences()` on a settings-driven look change.
  static func current() -> FamoPanelSnapshot {
    FamoPanelSnapshot(
      orientation: FamoPanelPreferences.orientation,
      fontSize: FamoPanelPreferences.fontSize,
      fontDesign: FamoPanelPreferences.fontDesign,
      animationsEnabled: FamoPanelPreferences.animationsEnabled,
      showPreedit: FamoPanelPreferences.showPreedit,
      showPaging: FamoPanelPreferences.showPaging,
      candidateFormat: FamoPanelPreferences.candidateFormat,
      theme: FamoSkinPreferences.skin.theme,
      appearance: FamoPanelPreferences.appearance,
      previewPages: FamoPanelPreferences.previewPages,
      previewRows: FamoPanelPreferences.previewRows)
  }
}
