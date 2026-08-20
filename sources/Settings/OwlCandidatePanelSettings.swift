//
//  OwlCandidatePanelSettings.swift
//  猫头鹰输入法 (Owltype) — candidate-panel settings lifecycle seam
//

import AppKit
import SwiftUI

/// Candidate-panel appearance mode. `system` follows the host environment; `light` / `dark`
/// force the hosting panel's AppKit appearance and therefore SwiftUI color scheme.
enum OwlPanelAppearance: String, CaseIterable, Sendable {
  case system
  case light
  case dark
}

/// The user-visible candidate typeface choice. This is persisted; the runtime panel receives a
/// resolved `OwlCandidateFont` so it never needs to know how installed-family fallback works.
enum OwlCandidateFontSelection: String, CaseIterable, Sendable {
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
struct OwlCandidateFont: Sendable, Equatable {
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

  let selection: OwlCandidateFontSelection
  let resolution: Resolution

  static let systemDefault = OwlCandidateFont(selection: .default, resolution: .system(.default))

  /// Present only when a named font was requested but is not installed locally.
  var unavailableSelection: OwlCandidateFontSelection? {
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
protocol OwlCandidateFontCatalog {
  func availableFontFamilies() -> [String]
}

struct OwlLocalCandidateFontCatalog: OwlCandidateFontCatalog {
  func availableFontFamilies() -> [String] {
    NSFontManager.shared.availableFontFamilies
  }
}

/// Deep module for candidate-panel settings. Every preference crosses one seed/edit/snapshot
/// lifecycle and its runtime consumer boundary; callers do not mirror persistence, constraints,
/// or refresh rules.
struct OwlCandidatePanelSettings {
  struct Snapshot: Sendable, Equatable {
    let appearance: OwlPanelAppearance
    let skin: OwlSkin
    let font: OwlCandidateFont
    let animationsEnabled: Bool
    let size: OwlPanelFontSize
    let orientation: OwlPanelOrientation
    let showPreedit: Bool
    let inlineCandidate: Bool
    let showPaging: Bool
    let showNotificationsWhen: OwlNotificationWhen
    let candidateFormat: OwlCandidateFormat
    let scrollRows: Int
  }

  enum Edit: Sendable, Equatable {
    case appearance(OwlPanelAppearance)
    case skin(OwlSkin)
    case font(OwlCandidateFontSelection)
    case animationsEnabled(Bool)
    case size(OwlPanelFontSize)
    case orientation(OwlPanelOrientation)
    case showPreedit(Bool)
    case inlineCandidate(Bool)
    case showPaging(Bool)
    case showNotificationsWhen(OwlNotificationWhen)
    case candidateFormat(OwlCandidateFormat)
    case scrollRows(Int)
  }

  enum NotificationEvent: Sendable, Equatable {
    case option
    case schema
  }

  static let defaultSize: OwlPanelFontSize = .medium
  static let defaultOrientation: OwlPanelOrientation = .auto
  static let defaultShowPreedit = true
  static let defaultInlineCandidate = false
  static let defaultShowPaging = true
  static let defaultShowNotificationsWhen: OwlNotificationWhen = .always
  static let defaultCandidateFormat: OwlCandidateFormat = .full
  static let minimumScrollRows = 1
  static let maximumScrollRows = 4
  static let defaultScrollRows = maximumScrollRows

  static let live = OwlCandidatePanelSettings(
    defaults: OwlDefaults.standard,
    fontCatalog: OwlLocalCandidateFontCatalog()
  )

  private static let appearanceKey = "OwlPanelAppearance"
  private static let skinKey = "OwlSkin"
  private static let fontSelectionKey = "OwlPanelFontDesign"
  private static let animationsEnabledKey = "OwlPanelAnimations"
  private static let sizeKey = "OwlPanelFontSize"
  private static let orientationKey = "OwlPanelOrientation"
  private static let showPreeditKey = "OwlPanelShowPreedit"
  private static let inlineCandidateKey = "OwlPanelInlineCandidate"
  private static let showPagingKey = "OwlPanelShowPaging"
  private static let showNotificationsWhenKey = "OwlPanelShowNotificationsWhen"
  private static let candidateFormatKey = "OwlPanelCandidateFormat"
  private static let scrollRowsKey = "OwlPanelPreviewRows"
  private static let scrollRowsRange = minimumScrollRows...maximumScrollRows
  private static let notoSerifSCFamilies = [
    "Noto Serif SC",
    "Noto Serif CJK SC",
    "Noto Serif CJK SC VF"
  ]
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

  private let defaults: UserDefaults
  private let fontCatalog: any OwlCandidateFontCatalog

  init(defaults: UserDefaults, fontCatalog: any OwlCandidateFontCatalog) {
    self.defaults = defaults
    self.fontCatalog = fontCatalog
  }

  /// Settings-window reopen/reseed boundary.
  func seed(_ state: OwlSettingsState) {
    let snapshot = snapshot()
    state.panelAppearance = snapshot.appearance
    state.skin = snapshot.skin
    state.candidateFont = snapshot.font
    state.panelAnimationsEnabled = snapshot.animationsEnabled
    state.panelFontSize = snapshot.size
    state.panelOrientation = snapshot.orientation
    state.panelShowPreedit = snapshot.showPreedit
    state.panelInlineCandidate = snapshot.inlineCandidate
    state.panelShowPaging = snapshot.showPaging
    state.panelShowNotificationsWhen = snapshot.showNotificationsWhen
    state.panelCandidateFormat = snapshot.candidateFormat
    state.panelScrollRows = snapshot.scrollRows
  }

  // Twelve explicit cases are the lifecycle contract; splitting them would duplicate dispatch.
  // swiftlint:disable cyclomatic_complexity
  /// The only edit path for candidate-window fields: update observable editing state, persist,
  /// then notify runtime consumers to refresh from the new module snapshot.
  func edit(
    _ edit: Edit,
    state: OwlSettingsState,
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
    case .inlineCandidate(let show):
      state.panelInlineCandidate = show
      defaults.set(show, forKey: Self.inlineCandidateKey)
    case .showPaging(let show):
      state.panelShowPaging = show
      defaults.set(show, forKey: Self.showPagingKey)
    case .showNotificationsWhen(let when):
      state.panelShowNotificationsWhen = when
      defaults.set(when.rawValue, forKey: Self.showNotificationsWhenKey)
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
  // swiftlint:enable cyclomatic_complexity

  /// Runtime snapshot boundary. Availability is re-read here so installing a font while Owltype is
  /// running is observed by the next settings seed or panel refresh.
  func snapshot() -> Snapshot {
    let raw = defaults.string(forKey: Self.fontSelectionKey) ?? ""
    let selection = OwlCandidateFontSelection(rawValue: raw) ?? .default
    return Snapshot(
      appearance: OwlPanelAppearance(
        rawValue: defaults.string(forKey: Self.appearanceKey) ?? ""
      ) ?? .system,
      skin: currentSkin(),
      font: resolveFont(selection),
      animationsEnabled: defaults.object(forKey: Self.animationsEnabledKey) as? Bool ?? true,
      size: OwlPanelFontSize(
        rawValue: defaults.string(forKey: Self.sizeKey) ?? ""
      ) ?? Self.defaultSize,
      orientation: OwlPanelOrientation(
        rawValue: defaults.string(forKey: Self.orientationKey) ?? ""
      ) ?? Self.defaultOrientation,
      showPreedit: defaults.object(forKey: Self.showPreeditKey) as? Bool ?? Self.defaultShowPreedit,
      inlineCandidate: currentInlineCandidate(),
      showPaging: defaults.object(forKey: Self.showPagingKey) as? Bool ?? Self.defaultShowPaging,
      showNotificationsWhen: currentShowNotificationsWhen(),
      candidateFormat: OwlCandidateFormat(
        rawValue: defaults.string(forKey: Self.candidateFormatKey) ?? ""
      ) ?? Self.defaultCandidateFormat,
      scrollRows: constrainedScrollRows(
        defaults.object(forKey: Self.scrollRowsKey) as? Int ?? Self.defaultScrollRows
      )
    )
  }

  /// Lightweight read for companion surfaces that share the selected palette but do not render
  /// candidates. The candidate panel itself always consumes the complete runtime snapshot.
  func currentSkin() -> OwlSkin {
    OwlSkin(rawValue: defaults.string(forKey: Self.skinKey) ?? "") ?? .deepred
  }

  /// Lightweight runtime read for the IMK composition path. Unlike `snapshot()`, this does not
  /// resolve installed fonts, so schema reloads never make an AppKit font-catalog call.
  func currentInlineCandidate() -> Bool {
    defaults.object(forKey: Self.inlineCandidateKey) as? Bool ?? Self.defaultInlineCandidate
  }

  /// Apply the persisted inline-preview override to the flags consumed on every composition
  /// update. This is also called after any candidate-setting edit, so the next input round does
  /// not wait for a schema reload to observe the toggle.
  func applyInlineCandidate(to style: inout OwlStyleFlags) {
    style.inlineCandidate = currentInlineCandidate()
  }

  /// Lightweight runtime read for librime notifications, which may arrive off the main thread.
  /// Keeping it on this seam avoids touching the AppKit-backed font catalog in `snapshot()`.
  func currentShowNotificationsWhen() -> OwlNotificationWhen {
    OwlNotificationWhen(
      rawValue: defaults.string(forKey: Self.showNotificationsWhenKey) ?? ""
    ) ?? Self.defaultShowNotificationsWhen
  }

  /// Runtime policy consumed by the librime notification callback. This stays lightweight because
  /// notifications may arrive off-main and must never resolve the AppKit-backed font catalog.
  func shouldShowNotification(for event: NotificationEvent) -> Bool {
    switch (currentShowNotificationsWhen(), event) {
    case (.always, _), (.appropriate, .schema): true
    case (.appropriate, .option), (.never, _): false
    }
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

  func resolveFont(_ selection: OwlCandidateFontSelection) -> OwlCandidateFont {
    switch selection {
    case .default:
      OwlCandidateFont(selection: selection, resolution: .system(.default))
    case .serif:
      OwlCandidateFont(selection: selection, resolution: .system(.serif))
    case .rounded:
      OwlCandidateFont(selection: selection, resolution: .system(.rounded))
    case .notoSerifSC:
      resolveNamedFont(selection, preferredFamilies: Self.notoSerifSCFamilies, fallback: .serif)
    case .mapleMono:
      resolveNamedFont(selection, preferredFamilies: Self.mapleMonoFamilies, fallback: .monospaced)
    }
  }

  private func resolveNamedFont(
    _ selection: OwlCandidateFontSelection,
    preferredFamilies: [String],
    fallback: OwlCandidateFont.SystemDesign
  ) -> OwlCandidateFont {
    let available = fontCatalog.availableFontFamilies()
    let family = preferredFamilies.lazy.compactMap { preferred in
      available.first { $0.caseInsensitiveCompare(preferred) == .orderedSame }
    }.first
    let resolution: OwlCandidateFont.Resolution = family.map { .installedFamily($0) }
      ?? .fallback(fallback)
    return OwlCandidateFont(selection: selection, resolution: resolution)
  }

  private func resolvedAppearance(_ appearance: OwlPanelAppearance) -> NSAppearance? {
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
