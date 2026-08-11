//
//  FamoCandidatePanelSettings.swift
//  法墨输入法 (Famo) — candidate-panel settings lifecycle seam
//

import AppKit
import SwiftUI

/// Candidate-panel appearance mode. `system` follows the host environment; `light` / `dark`
/// force the hosting panel's AppKit appearance and therefore SwiftUI color scheme.
enum FamoPanelAppearance: String, CaseIterable, Sendable {
  case system
  case light
  case dark
}

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

/// Deep module for candidate-panel settings. Every rendered preference crosses one
/// seed/edit/snapshot/apply boundary; callers do not mirror persistence, constraints, or
/// visible-panel refresh rules.
struct FamoCandidatePanelSettings {
  struct Snapshot: Sendable, Equatable {
    let appearance: FamoPanelAppearance
    let skin: FamoSkin
    let font: FamoCandidateFont
    let animationsEnabled: Bool
    let size: FamoPanelFontSize
    let orientation: FamoPanelOrientation
    let showPreedit: Bool
    let showPaging: Bool
    let candidateFormat: FamoCandidateFormat
    let scrollRows: Int
  }

  enum Edit: Sendable, Equatable {
    case appearance(FamoPanelAppearance)
    case skin(FamoSkin)
    case font(FamoCandidateFontSelection)
    case animationsEnabled(Bool)
    case size(FamoPanelFontSize)
    case orientation(FamoPanelOrientation)
    case showPreedit(Bool)
    case showPaging(Bool)
    case candidateFormat(FamoCandidateFormat)
    case scrollRows(Int)
  }

  static let defaultSize: FamoPanelFontSize = .medium
  static let defaultOrientation: FamoPanelOrientation = .auto
  static let defaultShowPreedit = true
  static let defaultShowPaging = true
  static let defaultCandidateFormat: FamoCandidateFormat = .full
  static let minimumScrollRows = 1
  static let maximumScrollRows = 4
  static let defaultScrollRows = maximumScrollRows

  static let live = FamoCandidatePanelSettings(
    defaults: FamoDefaults.standard,
    fontCatalog: FamoLocalCandidateFontCatalog()
  )

  private static let appearanceKey = "FamoPanelAppearance"
  private static let skinKey = "FamoSkin"
  private static let fontSelectionKey = "FamoPanelFontDesign"
  private static let animationsEnabledKey = "FamoPanelAnimations"
  private static let sizeKey = "FamoPanelFontSize"
  private static let orientationKey = "FamoPanelOrientation"
  private static let showPreeditKey = "FamoPanelShowPreedit"
  private static let showPagingKey = "FamoPanelShowPaging"
  private static let candidateFormatKey = "FamoPanelCandidateFormat"
  private static let scrollRowsKey = "FamoPanelPreviewRows"
  private static let scrollRowsRange = minimumScrollRows...maximumScrollRows
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
    let snapshot = snapshot()
    state.panelAppearance = snapshot.appearance
    state.skin = snapshot.skin
    state.candidateFont = snapshot.font
    state.panelAnimationsEnabled = snapshot.animationsEnabled
    state.panelFontSize = snapshot.size
    state.panelOrientation = snapshot.orientation
    state.panelShowPreedit = snapshot.showPreedit
    state.panelShowPaging = snapshot.showPaging
    state.panelCandidateFormat = snapshot.candidateFormat
    state.panelScrollRows = snapshot.scrollRows
  }

  /// The only edit path for rendered candidate-panel fields: update observable editing state,
  /// persist, then notify the owner to refresh any visible panel from a new runtime snapshot.
  func edit(
    _ edit: Edit,
    state: FamoSettingsState,
    onChange: () -> Void
  ) {
    switch edit {
    case .appearance(let appearance):
      state.panelAppearance = appearance
      defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
    case .skin(let skin):
      state.skin = skin
      defaults.set(skin.rawValue, forKey: Self.skinKey)
    case .font(let selection):
      state.candidateFont = resolveFont(selection)
      defaults.set(selection.rawValue, forKey: Self.fontSelectionKey)
    case .animationsEnabled(let enabled):
      state.panelAnimationsEnabled = enabled
      defaults.set(enabled, forKey: Self.animationsEnabledKey)
    case .size(let size):
      state.panelFontSize = size
      defaults.set(size.rawValue, forKey: Self.sizeKey)
    case .orientation(let orientation):
      state.panelOrientation = orientation
      defaults.set(orientation.rawValue, forKey: Self.orientationKey)
    case .showPreedit(let show):
      state.panelShowPreedit = show
      defaults.set(show, forKey: Self.showPreeditKey)
    case .showPaging(let show):
      state.panelShowPaging = show
      defaults.set(show, forKey: Self.showPagingKey)
    case .candidateFormat(let format):
      state.panelCandidateFormat = format
      defaults.set(format.rawValue, forKey: Self.candidateFormatKey)
    case .scrollRows(let rows):
      let constrained = constrainedScrollRows(rows)
      state.panelScrollRows = constrained
      defaults.set(constrained, forKey: Self.scrollRowsKey)
    }
    onChange()
  }

  /// Runtime snapshot boundary. Availability is re-read here so installing a font while Famo is
  /// running is observed by the next settings seed or panel refresh.
  func snapshot() -> Snapshot {
    let raw = defaults.string(forKey: Self.fontSelectionKey) ?? ""
    let selection = FamoCandidateFontSelection(rawValue: raw) ?? .default
    return Snapshot(
      appearance: FamoPanelAppearance(
        rawValue: defaults.string(forKey: Self.appearanceKey) ?? ""
      ) ?? .system,
      skin: currentSkin(),
      font: resolveFont(selection),
      animationsEnabled: defaults.object(forKey: Self.animationsEnabledKey) as? Bool ?? true,
      size: FamoPanelFontSize(
        rawValue: defaults.string(forKey: Self.sizeKey) ?? ""
      ) ?? Self.defaultSize,
      orientation: FamoPanelOrientation(
        rawValue: defaults.string(forKey: Self.orientationKey) ?? ""
      ) ?? Self.defaultOrientation,
      showPreedit: defaults.object(forKey: Self.showPreeditKey) as? Bool ?? Self.defaultShowPreedit,
      showPaging: defaults.object(forKey: Self.showPagingKey) as? Bool ?? Self.defaultShowPaging,
      candidateFormat: FamoCandidateFormat(
        rawValue: defaults.string(forKey: Self.candidateFormatKey) ?? ""
      ) ?? Self.defaultCandidateFormat,
      scrollRows: constrainedScrollRows(
        defaults.object(forKey: Self.scrollRowsKey) as? Int ?? Self.defaultScrollRows
      )
    )
  }

  /// Lightweight read for companion surfaces that share the selected palette but do not render
  /// candidates. The candidate panel itself always consumes the complete runtime snapshot.
  func currentSkin() -> FamoSkin {
    FamoSkin(rawValue: defaults.string(forKey: Self.skinKey) ?? "") ?? .deepred
  }

  /// Panel-apply boundary. The observable rendering state and hosting-window appearance are applied
  /// from the same module snapshot, so forced light/dark and following-system cannot drift.
  func apply(
    _ snapshot: Snapshot,
    to state: CandidatePanelState,
    rimeVertical: Bool = false,
    schemaID: String = "",
    setAppearance: (NSAppearance?) -> Void = { _ in }
  ) {
    state.schemaID = schemaID
    state.isVertical = snapshot.orientation.isVertical(
      rimeVertical: rimeVertical,
      schemaID: schemaID
    )
    state.isScroll = snapshot.orientation.scrolls
    state.fontSize = snapshot.size.base
    state.appearance = snapshot.appearance
    state.theme = snapshot.skin.theme
    state.candidateFont = snapshot.font
    state.animationsEnabled = snapshot.animationsEnabled
    state.showPreedit = snapshot.showPreedit
    state.showPaging = snapshot.showPaging
    state.candidateFormat = snapshot.candidateFormat
    state.scrollRowLimit = snapshot.scrollRows
    setAppearance(appKitAppearance(for: snapshot))
  }

  func appKitAppearance(for snapshot: Snapshot) -> NSAppearance? {
    resolvedAppearance(snapshot.appearance)
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

  private func resolvedAppearance(_ appearance: FamoPanelAppearance) -> NSAppearance? {
    switch appearance {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  private func constrainedScrollRows(_ rows: Int) -> Int {
    min(Self.scrollRowsRange.upperBound, max(Self.scrollRowsRange.lowerBound, rows))
  }
}
