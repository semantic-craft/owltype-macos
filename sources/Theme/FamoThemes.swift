//
//  FamoThemes.swift
//  法墨输入法 (Famo) — 皮肤外观 (skin) themes + preference
//
//  The 荔园红 (shenda) palette ships in `FamoCandidatePanelState.swift`; this file adds
//  the other five skins from the project color source of truth
//  `packages/rime-law-config/skins/colors.md` (胡佛红 / 珞珈青 / 嘉庚蓝 / 香槟橙 / 纽约紫) plus the
//  `FamoSkin` enum and its UserDefaults home, so the 皮肤外观 settings page can switch
//  the whole candidate panel + settings window palette.
//
//  Colors are hardcoded from colors.md (light/dark per skin). `famoColor(hex:)` and the
//  `FamoCandidatePalette` / `FamoCandidateTheme` types live in FamoCandidatePanelState.swift.
//
//  Boundary (ADR-0001 / 0002 / 0003): UI palette only; no Rime / hot-path involvement.
//

import SwiftUI

extension FamoCandidateTheme {
  /// 胡佛红 / stanford (colors.md).
  static let stanford = FamoCandidateTheme(
    cornerRadius: 13,
    shadowRadius: 16,
    light: FamoCandidatePalette(
      accent: famoColor(hex: "8C1515"), accentDeep: famoColor(hex: "820000"),
      onAccent: famoColor(hex: "FBFBFC"), card: famoColor(hex: "FBFBFC"),
      card2: famoColor(hex: "F1F2F4"), ink: famoColor(hex: "2E2D29"),
      ink2: famoColor(hex: "53565A"), ink3: famoColor(hex: "8A8D90")
    ),
    dark: FamoCandidatePalette(
      accent: famoColor(hex: "B83A4B"), accentDeep: famoColor(hex: "8C1515"),
      onAccent: famoColor(hex: "F2F2F0"), card: famoColor(hex: "26282C"),
      card2: famoColor(hex: "212327"), ink: famoColor(hex: "E8EAED"),
      ink2: famoColor(hex: "9DA1A6"), ink3: famoColor(hex: "6C7075")
    )
  )

  /// 珞珈青 / wuda (colors.md).
  static let wuda = FamoCandidateTheme(
    cornerRadius: 13,
    shadowRadius: 16,
    light: FamoCandidatePalette(
      accent: famoColor(hex: "2A8367"), accentDeep: famoColor(hex: "1F6B52"),
      onAccent: famoColor(hex: "F9FAF8"), card: famoColor(hex: "F8FBF9"),
      card2: famoColor(hex: "EFF2EE"), ink: famoColor(hex: "282D2A"),
      ink2: famoColor(hex: "565F5A"), ink3: famoColor(hex: "8A938E")
    ),
    dark: FamoCandidatePalette(
      accent: famoColor(hex: "3CA081"), accentDeep: famoColor(hex: "2A8367"),
      onAccent: famoColor(hex: "121413"), card: famoColor(hex: "212423"),
      card2: famoColor(hex: "1C1E1D"), ink: famoColor(hex: "E5EAE7"),
      ink2: famoColor(hex: "98A19C"), ink3: famoColor(hex: "66706B")
    )
  )

  /// 嘉庚蓝 / xiada (colors.md).
  static let xiada = FamoCandidateTheme(
    cornerRadius: 13,
    shadowRadius: 16,
    light: FamoCandidatePalette(
      accent: famoColor(hex: "1D4A8C"), accentDeep: famoColor(hex: "123061"),
      onAccent: famoColor(hex: "F8FAFC"), card: famoColor(hex: "F8FAFC"),
      card2: famoColor(hex: "EFF2F7"), ink: famoColor(hex: "242A36"),
      ink2: famoColor(hex: "5C6A81"), ink3: famoColor(hex: "8898AF")
    ),
    dark: FamoCandidatePalette(
      accent: famoColor(hex: "4879C5"), accentDeep: famoColor(hex: "1D4A8C"),
      onAccent: famoColor(hex: "0F141C"), card: famoColor(hex: "212429"),
      card2: famoColor(hex: "1B1E22"), ink: famoColor(hex: "E6EAF0"),
      ink2: famoColor(hex: "98A4B8"), ink3: famoColor(hex: "66758A")
    )
  )

  /// 香槟橙 / illinois — 伊利诺伊大学厄巴纳-香槟分校 (Illini Orange + Illini Blue, colors.md)。
  /// 「Block-I 正章」(2026-07-22 重设计)：暖香槟纸上，**选中胶囊 = Illini Blue 藏蓝底 + 橙字**，
  /// 正如校徽 Block-I 的橙压蓝撞色；橙描边框住、正文藏蓝。**本皮肤为双色互补有意特例**：浅色
  /// accent(选中)=藏蓝、深色=橙(夜幕橙灯)，故选中色随明暗翻转、破「暗色 accent 同色相提亮」不变式；
  /// 其余守 accentDeep_dark=accent_light 铁律(暗色描边=浅色藏蓝 accent #13294B)。
  static let illinois = FamoCandidateTheme(
    cornerRadius: 13,
    shadowRadius: 16,
    light: FamoCandidatePalette(
      accent: famoColor(hex: "13294B"), accentDeep: famoColor(hex: "CC4A00"),
      onAccent: famoColor(hex: "FF7A2E"), card: famoColor(hex: "FCF4E9"),
      card2: famoColor(hex: "FBE7D4"), ink: famoColor(hex: "13294B"),
      ink2: famoColor(hex: "6E5A3A"), ink3: famoColor(hex: "9A8A6E")
    ),
    dark: FamoCandidatePalette(
      accent: famoColor(hex: "FF7A2E"), accentDeep: famoColor(hex: "13294B"),
      onAccent: famoColor(hex: "13294B"), card: famoColor(hex: "1E2334"),
      card2: famoColor(hex: "262E44"), ink: famoColor(hex: "ECE6DC"),
      ink2: famoColor(hex: "9AA0B0"), ink3: famoColor(hex: "6A7185")
    )
  )

  /// 纽约紫 / nyu (colors.md). accent = 官方 NYU Violet (NYU Law Visual Identity: PMS 2597,
  /// RGB 87,6,140, #57068C)；官方三色仅紫/黑/白。暗色 accent 循全系统提亮律升为 #A274DA(同 272° 紫相)，
  /// accentDeep 仍为精确 #57068C，故 NYU Violet 亮/暗两版皆在场。
  static let nyu = FamoCandidateTheme(
    cornerRadius: 13,
    shadowRadius: 16,
    light: FamoCandidatePalette(
      accent: famoColor(hex: "57068C"), accentDeep: famoColor(hex: "3F0567"),
      onAccent: famoColor(hex: "FBF9FE"), card: famoColor(hex: "FBF9FE"),
      card2: famoColor(hex: "F2ECF9"), ink: famoColor(hex: "2A2333"),
      ink2: famoColor(hex: "655B79"), ink3: famoColor(hex: "958BAC")
    ),
    dark: FamoCandidatePalette(
      accent: famoColor(hex: "A274DA"), accentDeep: famoColor(hex: "57068C"),
      onAccent: famoColor(hex: "15101F"), card: famoColor(hex: "242029"),
      card2: famoColor(hex: "1D1A25"), ink: famoColor(hex: "EAE5F1"),
      ink2: famoColor(hex: "A99EBB"), ink3: famoColor(hex: "786C8C")
    )
  )
}

/// The six shipping skins (源 colors.md). `deepred` (荔园红) is the default; the other
/// five are university palettes. Carries its display name, university tag, swatch color
/// (the light accent), and the resolved `FamoCandidateTheme`.
enum FamoSkin: String, CaseIterable, Identifiable, Sendable {
  case deepred
  case stanford
  case wuda
  case xiada
  case illinois
  case nyu

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .deepred: return "荔园红"
    case .stanford: return "胡佛红"
    case .wuda: return "珞珈青"
    case .xiada: return "嘉庚蓝"
    case .illinois: return "香槟橙"
    case .nyu: return "纽约紫"
    }
  }

  var tag: String {
    switch self {
    case .deepred: return "深圳大学"
    case .stanford: return "斯坦福大学"
    case .wuda: return "武汉大学"
    case .xiada: return "厦门大学"
    case .illinois: return "伊利诺伊大学"
    case .nyu: return "纽约大学"
    }
  }

  /// Resolved palette/theme for the candidate panel + settings window.
  var theme: FamoCandidateTheme {
    switch self {
    case .deepred: return .shenda
    case .stanford: return .stanford
    case .wuda: return .wuda
    case .xiada: return .xiada
    case .illinois: return .illinois
    case .nyu: return .nyu
    }
  }

  /// Light-accent swatch shown on the 皮肤外观 selection card.
  var swatch: Color {
    switch self {
    case .deepred: return famoColor(hex: "A82C53")
    case .stanford: return famoColor(hex: "8C1515")
    case .wuda: return famoColor(hex: "2A8367")
    case .xiada: return famoColor(hex: "1D4A8C")
    case .illinois: return famoColor(hex: "FF5F05")
    case .nyu: return famoColor(hex: "57068C")
    }
  }
}

/// Single UserDefaults home for the chosen skin (read live in the candidate panel's
/// `update(...)`, like `FamoPanelPreferences.fontSize`, so a change takes effect on the
/// next composition without a restart).
enum FamoSkinPreferences {
  private static let key = "FamoSkin"

  static var skin: FamoSkin {
    get { FamoSkin(rawValue: FamoDefaults.standard.string(forKey: key) ?? "") ?? .deepred }
    set { FamoDefaults.standard.set(newValue.rawValue, forKey: key) }
  }
}

extension Font {
  /// 法墨标题衬线（Claude design 编辑式标题）。`.serif` design 在 macOS 以 New York +
  /// 系统中文衬线（Songti 风格）呈现，自带回退，无需硬编码字体名；正文仍用系统无衬线。
  static func famoSerif(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .serif)
  }
}
