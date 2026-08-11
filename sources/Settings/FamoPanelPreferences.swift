//
//  FamoPanelPreferences.swift
//  法墨输入法 (Famo) — SwiftUI candidate panel preferences
//
//  v0.2.2: user-customizable appearance for the SwiftUI candidate panel.
//  Several prefs persisted in UserDefaults (Famo-namespaced): appearance mode
//  (跟随系统/浅色/深色), candidate panel size (小/中/大/特大), orientation, typeface, animations.
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

/// 候选窗尺寸（设置里的「候选窗尺寸」四档）。`base` 是候选正文的基准点数：面板里其余字号
/// （preedit ≈ base − 2、展开箭头 ≈ base − 5）**与全部留白**都由它派生，所以这一档拨的是整块
/// 面板的大小，不只是字。留白的换算走 `metric(_:base:)`。
///
/// 类型名与 UserDefaults 键都保留 `FontSize`：`base` 本身确实是个字号，且键名一动老用户的
/// 小/中/大就白丢——同 `"FamoPanelPreviewRows"` 那格保留旧键名的处置。
enum FamoPanelFontSize: String, CaseIterable, Sendable {
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

  /// 把在「中」档（base 19）下定好的一个留白值等比换算到 `base` 档，四舍五入到整点。
  ///
  /// 面板的留白常数全部写在「中」的坐标系里，锚点即 `medium.base`——所以中档（默认档，绝大多数
  /// 用户）换算后与四档化之前**逐像素相同**，其余档位的边距跟着字一起走。四档化之前边距是死的：
  /// 大档字撑大而边距不动会挤，小档小字配大边距会虚胖，那正是「调不动窗格尺寸」的根因。
  ///
  /// 只用于留白 / 间距 / 最小宽度。**不**用于 1pt 描边与发丝线（缩放只会变糊）、页点的 18pt
  /// 命中区（再缩就点不中）、皮肤自己定义的面板圆角。
  static func metric(_ atMedium: CGFloat, base: CGFloat) -> CGFloat {
    (atMedium * base / medium.base).rounded()
  }
}

/// Candidate-window orientation (G8 候选显示). `auto` keeps Rime's `_vertical` option
/// and Famo's schema-aware defaults; `horizontal` / `vertical` override it from settings.
enum FamoPanelOrientation: String, CaseIterable, Sendable {
  case auto
  case horizontal
  case vertical
  /// 卷轴（搜狗式按页对齐的多行候选）：主行是 librime 当前页、下方跟 1–2 行后页，翻页时整块
  /// 上滚一行。`isVertical` 仍为 false；`scrolls` 才是它与单行横排的区别。
  ///
  /// 取代了 0.x 的 `.flow`「横排折行」（2026-07-26 退役）：折行把**同一页**折成矩形——候选一个
  /// 不多、白占高度、行数随候选宽度抖动，且页点/展开箭头作为流式元素会飘到矩形里的随机位置。
  /// 卷轴换成「一行 = 一整页」，行数固定、序号语义不变（数字键只管主行）。
  case scroll

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
    case .scroll: false   // 卷轴是横排的一种（多行页），不是竖排
    }
  }

  /// 是否卷轴（主行 + 后页行）。仅显式 `.scroll` 为真；`auto/横排/竖排` 均为单行/纵列，
  /// 既有默认行为零变化。`isVertical` 为真时此值被忽略（竖排不叠加后页行）。
  var scrolls: Bool { self == .scroll }
}

/// Candidate text typeface family (G8 候选显示). System choices map to SwiftUI
/// `Font.Design`; named families use the installed font and fall back to the closest system design.
enum FamoPanelFontDesign: String, CaseIterable, Sendable {
  case `default`
  case serif
  case rounded
  case notoSerifSC
  case mapleMono

  var design: Font.Design {
    switch self {
    case .default: .default
    case .serif: .serif
    case .rounded: .rounded
    case .notoSerifSC: .serif
    case .mapleMono: .monospaced
    }
  }

  static let notoSerifSCDownloadURL = URL(string: "https://github.com/googlefonts/noto-cjk/raw/main/Serif/Variable/OTF/NotoSerifCJKsc-VF.otf")!
  static let mapleMonoDownloadURL = URL(
    string: "https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-CN.zip"
  )!

  private static let notoSerifSCFamilies = [
    "Noto Serif SC",
    "Noto Serif CJK SC",
    "Noto Serif CJK SC VF",
  ]

  /// Prefer the CJK builds for Chinese candidates, while accepting the regular and Nerd Font
  /// families users may already have installed for editors or terminals.
  private static let mapleMonoFamilies = [
    "Maple Mono CN",
    "Maple Mono NF CN",
    "Maple Mono Normal CN",
    "Maple Mono Normal NF CN",
    "Maple Mono",
    "Maple Mono NF",
    "Maple Mono Normal",
    "Maple Mono Normal NF"
  ]

  static var isNotoSerifSCInstalled: Bool {
    installedNotoSerifSCFamily(in: NSFontManager.shared.availableFontFamilies) != nil
  }

  static var isMapleMonoInstalled: Bool {
    installedMapleMonoFamily(in: NSFontManager.shared.availableFontFamilies) != nil
  }

  static func installedNotoSerifSCFamily(in availableFamilies: [String]) -> String? {
    let installed = Set(availableFamilies.map { $0.lowercased() })
    return notoSerifSCFamilies.first { installed.contains($0.lowercased()) }
  }

  static func installedMapleMonoFamily(in availableFamilies: [String]) -> String? {
    mapleMonoFamilies.lazy.compactMap { preferred in
      availableFamilies.first { $0.caseInsensitiveCompare(preferred) == .orderedSame }
    }.first
  }

  func candidateFont(size: CGFloat) -> Font {
    switch self {
    case .notoSerifSC:
      guard let family = Self.installedNotoSerifSCFamily(in: NSFontManager.shared.availableFontFamilies) else {
        return .system(size: size, design: .serif)
      }
      return .custom(family, size: size)
    case .mapleMono:
      guard let family = Self.installedMapleMonoFamily(in: NSFontManager.shared.availableFontFamilies) else {
        return .system(size: size, design: .monospaced)
      }
      return .custom(family, size: size)
    default:
      return .system(size: size, design: design)
    }
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

  /// 候选窗尺寸（字号 + 留白同步缩放）. Key `"FamoPanelFontSize"`, default `.medium`.
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
  /// 迁移①（2026-07-22，「默认形态 单行/卷轴」并入排列方向）：老的「卷轴」= 每次组字默认展开成
  /// 纵向候选列表，其渲染与 `.vertical` 完全相同（`showsFullList` 同走 `verticalList`）。故**未显式
  /// 选过排列方向**、但开过 legacy `FamoPanelExpandedByDefault` 的用户回落到 `.vertical`，保住其展开
  /// 纵列观感；一旦显式选任一方向即以新键为准（getter 内惰性迁移，仿 `FamoKeyboardPreferences.wubiScheme`）。
  ///
  /// 迁移②（2026-07-26，卷轴取代折行、并吸收「预览后页」开关）：
  /// - 存过 `"flow"`（折行退役）→ `.scroll`。`FamoPanelOrientation(rawValue:)` 已不认这个串，
  ///   故落到裸串比对这一支。
  /// - 开过 legacy `FamoPanelPreviewPages`（主行 + 淡显后页）→ `.scroll`，因为卷轴就是它转正。
  ///   这一支**排在已存方向之前**，否则显式选过「横排」+ 开着预览后页的用户会静默丢掉后页行；
  ///   竖排下预览本就被门控掉，所以 `.vertical` 明确排除、维持竖排。
  static var orientation: FamoPanelOrientation {
    get {
      let raw = FamoDefaults.standard.string(forKey: "FamoPanelOrientation")
      let stored = raw.flatMap(FamoPanelOrientation.init(rawValue:))
      if stored == nil, raw == "flow" { return .scroll }
      if stored != .vertical,
         FamoDefaults.standard.object(forKey: "FamoPanelPreviewPages") as? Bool == true {
        return .scroll
      }
      if let stored { return stored }
      if FamoDefaults.standard.object(forKey: "FamoPanelExpandedByDefault") as? Bool == true {
        return .vertical
      }
      return .auto
    }
    set {
      FamoDefaults.standard.set(newValue.rawValue, forKey: "FamoPanelOrientation")
      // 显式选过方向即视迁移②完成，清掉 legacy 开关——否则 getter 会把之后选的「横排」
      // 又映射回卷轴，用户再也回不到单行横排。
      FamoDefaults.standard.removeObject(forKey: "FamoPanelPreviewPages")
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

  /// 卷轴的后页行数（1–4；展开后总行数 = 前页 1 行 + 主行 + 它）. Key `"FamoPanelPreviewRows"`,
  /// default `4`（2026-07-28 截图定案：主行下方跟 4 页）。读取时钳到 1...4，抵御手改 defaults
  /// 写出的越界值；老用户存过的 1/2 落在新区间内，原样生效。
  ///
  /// 键名保留 `Preview` 前缀：它就是老「预览行数」那一格，卷轴吸收「预览后页」后只换了语义
  /// （后页行现在可点、稍淡、仍无序号），改键名只会让老用户的选择白丢。开关键
  /// `"FamoPanelPreviewPages"` 则已退役，只剩 `orientation` getter 里的迁移②读它一次。
  static var scrollRows: Int {
    get { min(4, max(1, FamoDefaults.standard.object(forKey: "FamoPanelPreviewRows") as? Int ?? 4)) }
    set { FamoDefaults.standard.set(min(4, max(1, newValue)), forKey: "FamoPanelPreviewRows") }
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
  /// 卷轴的后页行数。控制器在 `showPanel` 里据此决定预取多少后页候选；面板/视图只消费
  /// 取好的 `scrollRows` 数据，不再读这个偏好。是否卷轴由 `orientation.scrolls` 决定。
  let scrollRows: Int

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
      scrollRows: FamoPanelPreferences.scrollRows)
  }
}
