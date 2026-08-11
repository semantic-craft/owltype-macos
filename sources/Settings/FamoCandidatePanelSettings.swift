//
//  FamoCandidatePanelSettings.swift
//  法墨输入法 (Famo) — candidate-panel settings lifecycle seam
//

import AppKit
import SwiftUI

/// The user-visible candidate typeface choice. This is persisted; the runtime panel receives a
/// resolved `FamoCandidateFont` so it never needs to know how installed-family fallback works.
enum FamoCandidateFontSelection: String, CaseIterable, Sendable {
  case `default`
  case serif
  case rounded
  case notoSerifSC
  case mapleMono

  static let notoSerifSCDownloadURL = URL(
    string: "https://github.com/googlefonts/noto-cjk/raw/main/Serif/Variable/OTF/NotoSerifCJKsc-VF.otf"
  )!
  static let mapleMonoDownloadURL = URL(
    string: "https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-CN.zip"
  )!
}

/// Runtime candidate-font value. Named-font availability is resolved before this value crosses
/// the panel seam, and an unavailable choice remains explicit instead of becoming an invisible UI
/// branch. Tests can therefore assert system, installed-family, and fallback semantics directly.
struct FamoCandidateFont: Sendable, Equatable {
  enum SystemDesign: Sendable, Equatable {
    case `default`
    case serif
    case rounded
    case monospaced

    fileprivate var swiftUIDesign: Font.Design {
      switch self {
      case .default: .default
      case .serif: .serif
      case .rounded: .rounded
      case .monospaced: .monospaced
      }
    }
  }

  enum Resolution: Sendable, Equatable {
    case system(SystemDesign)
    case installedFamily(String)
    case fallback(SystemDesign)
  }

  let selection: FamoCandidateFontSelection
  let resolution: Resolution

  static let systemDefault = FamoCandidateFont(selection: .default, resolution: .system(.default))

  /// Present only when a named font was requested but is not installed locally.
  var unavailableSelection: FamoCandidateFontSelection? {
    guard case .fallback = resolution else { return nil }
    return selection
  }

  func font(size: CGFloat) -> Font {
    switch resolution {
    case .system(let design), .fallback(let design):
      .system(size: size, design: design.swiftUIDesign)
    case .installedFamily(let family):
      .custom(family, size: size)
    }
  }
}

/// Local font-discovery boundary. The AppKit adapter is the only place that reads
/// `NSFontManager.shared`; lifecycle tests substitute a deterministic in-memory catalog.
protocol FamoCandidateFontCatalog {
  func availableFontFamilies() -> [String]
}

struct FamoLocalCandidateFontCatalog: FamoCandidateFontCatalog {
  func availableFontFamilies() -> [String] {
    NSFontManager.shared.availableFontFamilies
  }
}

/// Deep module for candidate-panel settings. #112 establishes the complete lifecycle with font;
/// #117/#118 can move their fields behind the same seed/edit/snapshot/apply boundary without the
/// callers learning persistence or synchronization rules.
struct FamoCandidatePanelSettings {
  struct Snapshot: Sendable, Equatable {
    let font: FamoCandidateFont
  }

  static let live = FamoCandidatePanelSettings(
    defaults: FamoDefaults.standard,
    fontCatalog: FamoLocalCandidateFontCatalog()
  )

  private static let fontSelectionKey = "FamoPanelFontDesign"
  private static let notoSerifSCFamilies = [
    "Noto Serif SC",
    "Noto Serif CJK SC",
    "Noto Serif CJK SC VF",
  ]
  private static let mapleMonoFamilies = [
    "Maple Mono CN",
    "Maple Mono NF CN",
    "Maple Mono Normal CN",
    "Maple Mono Normal NF CN",
    "Maple Mono",
    "Maple Mono NF",
    "Maple Mono Normal",
    "Maple Mono Normal NF",
  ]

  private let defaults: UserDefaults
  private let fontCatalog: any FamoCandidateFontCatalog

  init(defaults: UserDefaults, fontCatalog: any FamoCandidateFontCatalog) {
    self.defaults = defaults
    self.fontCatalog = fontCatalog
  }

  /// Settings-window reopen/reseed boundary.
  func seed(_ state: FamoSettingsState) {
    state.candidateFont = snapshot().font
  }

  /// The only edit path for candidate font: resolve, update observable editing state, persist, then
  /// notify the owner to refresh any visible panel from a new runtime snapshot.
  func editFont(
    _ selection: FamoCandidateFontSelection,
    state: FamoSettingsState,
    onChange: () -> Void
  ) {
    let font = resolveFont(selection)
    state.candidateFont = font
    defaults.set(selection.rawValue, forKey: Self.fontSelectionKey)
    onChange()
  }

  /// Runtime snapshot boundary. Availability is re-read here so installing a font while Famo is
  /// running is observed by the next settings seed or panel refresh.
  func snapshot() -> Snapshot {
    let raw = defaults.string(forKey: Self.fontSelectionKey) ?? ""
    let selection = FamoCandidateFontSelection(rawValue: raw) ?? .default
    return Snapshot(font: resolveFont(selection))
  }

  /// Panel-apply boundary. Callers apply the module snapshot as one value and never mirror fields.
  func apply(_ snapshot: Snapshot, to state: CandidatePanelState) {
    state.candidateFont = snapshot.font
  }

  func resolveFont(_ selection: FamoCandidateFontSelection) -> FamoCandidateFont {
    switch selection {
    case .default:
      FamoCandidateFont(selection: selection, resolution: .system(.default))
    case .serif:
      FamoCandidateFont(selection: selection, resolution: .system(.serif))
    case .rounded:
      FamoCandidateFont(selection: selection, resolution: .system(.rounded))
    case .notoSerifSC:
      resolveNamedFont(selection, preferredFamilies: Self.notoSerifSCFamilies, fallback: .serif)
    case .mapleMono:
      resolveNamedFont(selection, preferredFamilies: Self.mapleMonoFamilies, fallback: .monospaced)
    }
  }

  private func resolveNamedFont(
    _ selection: FamoCandidateFontSelection,
    preferredFamilies: [String],
    fallback: FamoCandidateFont.SystemDesign
  ) -> FamoCandidateFont {
    let available = fontCatalog.availableFontFamilies()
    let family = preferredFamilies.lazy.compactMap { preferred in
      available.first { $0.caseInsensitiveCompare(preferred) == .orderedSame }
    }.first
    let resolution: FamoCandidateFont.Resolution = family.map { .installedFamily($0) }
      ?? .fallback(fallback)
    return FamoCandidateFont(selection: selection, resolution: resolution)
  }
}
