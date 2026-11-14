//
//  OwlThemes.swift
//  法墨输入法 (Owltype) — 皮肤外观 (skin) themes
//
//  The 荔园红 (shenda) palette ships in `OwlCandidatePanelState.swift`; this file adds
//  the other eight skins from the project color source of truth
//  `packages/rime-law-config/skins/colors.md` (胡佛红 / 珞珈青 / 嘉庚蓝 / 香槟橙藏蓝 / 香槟橙燃橙 /
//  纽约紫) plus 黑文蓝 and 怀德纳红 (sourced from Yale's and Harvard's own brand guides — see their
//  doc comments), plus the `OwlSkin` enum. Persistence lives in `OwlCandidatePanelSettings`,
//  allowing the 皮肤外观 page to switch the candidate panel + settings window palette.
//
//  Colors are hardcoded from colors.md (light/dark per skin). `owlColor(hex:)` and the
//  `OwlCandidatePalette` / `OwlCandidateTheme` types live in OwlCandidatePanelState.swift.
//
//  Boundary (ADR-0001 / 0002 / 0003): UI palette only; no engine / hot-path involvement.
//

import SwiftUI

extension OwlCandidateTheme {
  /// 胡佛红 / stanford (colors.md).
  static let stanford = OwlCandidateTheme(
    cornerRadius: 13,
    light: OwlCandidatePalette(
      accent: owlColor(hex: "8C1515"), accentDeep: owlColor(hex: "820000"),
      onAccent: owlColor(hex: "FBFBFC"), card: owlColor(hex: "FBFBFC"),
      card2: owlColor(hex: "F1F2F4"), ink: owlColor(hex: "2E2D29"),
      ink2: owlColor(hex: "53565A"), ink3: owlColor(hex: "8A8D90")
    ),
    dark: OwlCandidatePalette(
      accent: owlColor(hex: "B83A4B"), accentDeep: owlColor(hex: "8C1515"),
      onAccent: owlColor(hex: "F2F2F0"), card: owlColor(hex: "26282C"),
      card2: owlColor(hex: "212327"), ink: owlColor(hex: "E8EAED"),
      ink2: owlColor(hex: "9DA1A6"), ink3: owlColor(hex: "6C7075")
    )
  )

  /// 珞珈青 / wuda (colors.md).
  static let wuda = OwlCandidateTheme(
    cornerRadius: 13,
    light: OwlCandidatePalette(
      accent: owlColor(hex: "2A8367"), accentDeep: owlColor(hex: "1F6B52"),
      onAccent: owlColor(hex: "F9FAF8"), card: owlColor(hex: "F8FBF9"),
      card2: owlColor(hex: "EFF2EE"), ink: owlColor(hex: "282D2A"),
      ink2: owlColor(hex: "565F5A"), ink3: owlColor(hex: "8A938E")
    ),
    dark: OwlCandidatePalette(
      accent: owlColor(hex: "3CA081"), accentDeep: owlColor(hex: "2A8367"),
      onAccent: owlColor(hex: "121413"), card: owlColor(hex: "212423"),
      card2: owlColor(hex: "1C1E1D"), ink: owlColor(hex: "E5EAE7"),
      ink2: owlColor(hex: "98A19C"), ink3: owlColor(hex: "66706B")
    )
  )

  /// 嘉庚蓝 / xiada (colors.md).
  static let xiada = OwlCandidateTheme(
    cornerRadius: 13,
    light: OwlCandidatePalette(
      accent: owlColor(hex: "1D4A8C"), accentDeep: owlColor(hex: "123061"),
      onAccent: owlColor(hex: "F8FAFC"), card: owlColor(hex: "F8FAFC"),
      card2: owlColor(hex: "EFF2F7"), ink: owlColor(hex: "242A36"),
      ink2: owlColor(hex: "5C6A81"), ink3: owlColor(hex: "8898AF")
    ),
    dark: OwlCandidatePalette(
      accent: owlColor(hex: "4879C5"), accentDeep: owlColor(hex: "1D4A8C"),
      onAccent: owlColor(hex: "0F141C"), card: owlColor(hex: "212429"),
      card2: owlColor(hex: "1B1E22"), ink: owlColor(hex: "E6EAF0"),
      ink2: owlColor(hex: "98A4B8"), ink3: owlColor(hex: "66758A")
    )
  )

  /// 香槟橙 / illinois — 伊利诺伊大学厄巴纳-香槟分校 (Illini Orange + Illini Blue, colors.md)。
  /// 「Block-I 正章」(2026-07-22 重设计)：暖香槟纸上，**选中胶囊 = Illini Blue 藏蓝底 + 橙字**，
  /// 正如校徽 Block-I 的橙压蓝撞色；橙描边框住、正文藏蓝。**本皮肤为双色互补有意特例**：浅色
  /// accent(选中)=藏蓝、深色=橙(夜幕橙灯)，故选中色随明暗翻转、破「暗色 accent 同色相提亮」不变式；
  /// 其余守 accentDeep_dark=accent_light 铁律(暗色描边=浅色藏蓝 accent #13294B)。
  static let illinois = OwlCandidateTheme(
    cornerRadius: 13,
    light: OwlCandidatePalette(
      accent: owlColor(hex: "13294B"), accentDeep: owlColor(hex: "CC4A00"),
      onAccent: owlColor(hex: "FF7A2E"), card: owlColor(hex: "FCF4E9"),
      card2: owlColor(hex: "FBE7D4"), ink: owlColor(hex: "13294B"),
      ink2: owlColor(hex: "6E5A3A"), ink3: owlColor(hex: "9A8A6E")
    ),
    dark: OwlCandidatePalette(
      accent: owlColor(hex: "FF7A2E"), accentDeep: owlColor(hex: "13294B"),
      onAccent: owlColor(hex: "13294B"), card: owlColor(hex: "1E2334"),
      card2: owlColor(hex: "262E44"), ink: owlColor(hex: "ECE6DC"),
      ink2: owlColor(hex: "9AA0B0"), ink3: owlColor(hex: "6A7185")
    )
  )

  /// 香槟橙（燃橙）/ illinoisflame — 「焦糖燃橙」(2026-07-24 grilling 重设计定案)。
  /// 橙自己当主角：压暗到能承米白字的焦糖橙胶囊，香槟纸、全暖单色、通身不用藏蓝；
  /// 与 illinois（藏蓝）并存为同校双皮肤。守 accentDeep_dark = accent_light 铁律 (#C24A00)；
  /// 深色循「亮胶囊承深字」：accent #FF6E24 + onAccent 深咖 #2B1707（选中字对比度浅 4.5:1 / 深 6.1:1，AA）。
  static let illinoisflame = OwlCandidateTheme(
    cornerRadius: 13,
    light: OwlCandidatePalette(
      accent: owlColor(hex: "C24A00"), accentDeep: owlColor(hex: "9A3A00"),
      onAccent: owlColor(hex: "FFF4E8"), card: owlColor(hex: "FDF6EC"),
      card2: owlColor(hex: "F6E9D4"), ink: owlColor(hex: "3A2A1B"),
      ink2: owlColor(hex: "7B6248"), ink3: owlColor(hex: "AB9174")
    ),
    dark: OwlCandidatePalette(
      accent: owlColor(hex: "FF6E24"), accentDeep: owlColor(hex: "C24A00"),
      onAccent: owlColor(hex: "2B1707"), card: owlColor(hex: "241A12"),
      card2: owlColor(hex: "2C2117"), ink: owlColor(hex: "F1E5D7"),
      ink2: owlColor(hex: "B49C85"), ink3: owlColor(hex: "7F6C59")
    )
  )

  /// 纽约紫 / nyu (colors.md). accent = 官方 NYU Violet (NYU Law Visual Identity: PMS 2597,
  /// RGB 87,6,140, #57068C)；官方三色仅紫/黑/白。暗色 accent 循全系统提亮律升为 #A274DA(同 272° 紫相)，
  /// accentDeep 仍为精确 #57068C，故 NYU Violet 亮/暗两版皆在场。
  static let nyu = OwlCandidateTheme(
    cornerRadius: 13,
    light: OwlCandidatePalette(
      accent: owlColor(hex: "57068C"), accentDeep: owlColor(hex: "3F0567"),
      onAccent: owlColor(hex: "FBF9FE"), card: owlColor(hex: "FBF9FE"),
      card2: owlColor(hex: "F2ECF9"), ink: owlColor(hex: "2A2333"),
      ink2: owlColor(hex: "655B79"), ink3: owlColor(hex: "958BAC")
    ),
    dark: OwlCandidatePalette(
      accent: owlColor(hex: "A274DA"), accentDeep: owlColor(hex: "57068C"),
      onAccent: owlColor(hex: "15101F"), card: owlColor(hex: "242029"),
      card2: owlColor(hex: "1D1A25"), ink: owlColor(hex: "EAE5F1"),
      ink2: owlColor(hex: "A99EBB"), ink3: owlColor(hex: "786C8C")
    )
  )

  /// 黑文蓝 / yale — 耶鲁大学（New Haven）。源为耶鲁自家品牌规范，非 colors.md：
  /// accent = 官方数字版 Yale Blue #00356B（yaleidentity.yale.edu 网站规范给的 hex）；
  /// accentDeep_light = #0C2340，即 licensing 品牌手册所定 Yale Blue 印刷版 PMS 289 的 hex ——
  /// 同一个 Yale Blue 的更深一版，正作描边，不另调暗。ink2/ink3 走 Yale Gray (PMS Warm Gray 7)
  /// 暖灰系（手册列其为 Yale Blue 的官方搭配色），配米白纸，与同为藏蓝的 xiada 拉开距离。
  /// 守 accentDeep_dark = accent_light 铁律 (#00356B)；深色循「亮胶囊承深字」：
  /// accent #4E86C9 + onAccent 深藏蓝 #081426（选中字对比度浅 11.7:1 / 深 4.9:1，AA）。
  static let yale = OwlCandidateTheme(
    cornerRadius: 13,
    light: OwlCandidatePalette(
      accent: owlColor(hex: "00356B"), accentDeep: owlColor(hex: "0C2340"),
      onAccent: owlColor(hex: "FBFAF7"), card: owlColor(hex: "FAF9F6"),
      card2: owlColor(hex: "F1EEE7"), ink: owlColor(hex: "20242B"),
      ink2: owlColor(hex: "6E665C"), ink3: owlColor(hex: "968C83")
    ),
    dark: OwlCandidatePalette(
      accent: owlColor(hex: "4E86C9"), accentDeep: owlColor(hex: "00356B"),
      onAccent: owlColor(hex: "081426"), card: owlColor(hex: "1D2129"),
      card2: owlColor(hex: "181B22"), ink: owlColor(hex: "EAE7E1"),
      ink2: owlColor(hex: "A69E95"), ink3: owlColor(hex: "746E66")
    )
  )

  /// 怀德纳红 / harvard — 哈佛大学（Widener Library 怀德纳图书馆，哈佛园正中心的列柱大馆）。
  /// 循胡佛红（Hoover Tower）的地标建筑命名法，而非 nyu / yale 的城市命名法 —— 哈佛所在的
  /// Cambridge 译作「剑桥」，拿来命名会被读成剑桥大学。源为哈佛自家
  /// 品牌规范 (identityguide.hms.harvard.edu/brand-design/colors)，非 colors.md：官方色逐字节
  /// 照搬四个 —— Crimson #A51C30 (PMS 187) 作选中胶囊、Black #1E1E1E 作正文墨、
  /// Parchment #F3F3F1 (Cool Gray 1) 作 card2、Mortar #8C8179 (Warm Gray 8) 作 ink3，
  /// 正是哈佛红砖配灰浆的「brick and mortar」。规范只给这一支红，故描边 accentDeep 自 Crimson
  /// 压深推出 (#811626)，ink2 同理自 Mortar 压深 (#6F6660)。三套红靠纸面分家：荔园红暖羊皮纸、
  /// 胡佛红冷蓝灰、本皮肤中性灰白纸 + 暖灰墨。守 accentDeep_dark = accent_light 铁律 (#A51C30)；
  /// 深色同 351° 红相提亮到 #CF3048 —— 再往亮里推就泛玫瑰、贴到荔园红去了，故按住饱和度。
  /// 红系循胡佛红的「深胶囊承浅字」：onAccent 明暗两版同为米白 #FBFBF9（选中字对比浅 7.3:1 /
  /// 深 4.9:1，AA）。
  static let harvard = OwlCandidateTheme(
    cornerRadius: 13,
    light: OwlCandidatePalette(
      accent: owlColor(hex: "A51C30"), accentDeep: owlColor(hex: "811626"),
      onAccent: owlColor(hex: "FBFBF9"), card: owlColor(hex: "FAFAF8"),
      card2: owlColor(hex: "F3F3F1"), ink: owlColor(hex: "1E1E1E"),
      ink2: owlColor(hex: "6F6660"), ink3: owlColor(hex: "8C8179")
    ),
    dark: OwlCandidatePalette(
      accent: owlColor(hex: "CF3048"), accentDeep: owlColor(hex: "A51C30"),
      onAccent: owlColor(hex: "FBFBF9"), card: owlColor(hex: "242121"),
      card2: owlColor(hex: "1E1C1B"), ink: owlColor(hex: "EBE8E4"),
      ink2: owlColor(hex: "A39A93"), ink3: owlColor(hex: "726A64")
    )
  )
}

/// The nine shipping skins (源 colors.md，`yale` 源耶鲁品牌规范，`harvard` 源哈佛品牌规范).
/// `deepred` (荔园红) is the
/// default; the other eight are university palettes（伊利诺伊为藏蓝 / 燃橙双皮肤）. Carries its display name,
/// university tag, swatch color (the light accent — see `swatch` for the illinois exception),
/// and the resolved `OwlCandidateTheme`.
enum OwlSkin: String, CaseIterable, Identifiable, Sendable {
  case deepred
  case stanford
  case wuda
  case xiada
  case illinois
  case illinoisflame
  case nyu
  case yale
  case harvard

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .deepred: return "荔园红"
    case .stanford: return "胡佛红"
    case .wuda: return "珞珈青"
    case .xiada: return "嘉庚蓝"
    case .illinois: return "香槟橙（藏蓝）"
    case .illinoisflame: return "香槟橙（燃橙）"
    case .nyu: return "纽约紫"
    case .yale: return "黑文蓝"
    case .harvard: return "怀德纳红"
    }
  }

  /// Resolved palette/theme for the candidate panel + settings window.
  var theme: OwlCandidateTheme {
    switch self {
    case .deepred: return .shenda
    case .stanford: return .stanford
    case .wuda: return .wuda
    case .xiada: return .xiada
    case .illinois: return .illinois
    case .illinoisflame: return .illinoisflame
    case .nyu: return .nyu
    case .yale: return .yale
    case .harvard: return .harvard
    }
  }

  /// Swatch shown on the 皮肤外观 selection card — the light accent, **except `illinois`**:
  /// its light accent is Illini Blue #13294B, but a navy chip under the name「香槟橙」reads
  /// wrong, so the card shows Illini Orange #FF5F05 (a brand color, not a palette token).
  var swatch: Color {
    switch self {
    case .deepred: return owlColor(hex: "A82C53")
    case .stanford: return owlColor(hex: "8C1515")
    case .wuda: return owlColor(hex: "2A8367")
    case .xiada: return owlColor(hex: "1D4A8C")
    case .illinois: return owlColor(hex: "FF5F05")
    case .illinoisflame: return owlColor(hex: "C24A00")
    case .nyu: return owlColor(hex: "57068C")
    case .yale: return owlColor(hex: "00356B")
    case .harvard: return owlColor(hex: "A51C30")
    }
  }
}

extension Font {
  /// 法墨标题衬线（Claude design 编辑式标题）。`.serif` design 在 macOS 以 New York +
  /// 系统中文衬线（Songti 风格）呈现，自带回退，无需硬编码字体名；正文仍用系统无衬线。
  static func owlSerif(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .serif)
  }
}
