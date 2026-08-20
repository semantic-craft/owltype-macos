//
//  OwlCandidatePanelSettingsTests.swift
//  OwltypeTests — #112 candidate-panel font lifecycle seam
//

import XCTest
@testable import Owltype

@MainActor
final class OwlCandidatePanelSettingsTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "OwlCandidatePanelSettingsTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testEveryCandidateSettingUsesOneEditPersistReseedSnapshotAndApplyContract() {
    let catalog = StubCandidateFontCatalog(["Noto Serif CJK SC"])
    let settings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    let editingState = OwlSettingsState()
    let panelState = CandidatePanelState()
    var latestRuntime: OwlCandidatePanelSettings.Snapshot?
    var applyCount = 0

    func applyRuntimeSnapshot() {
      let runtime = settings.snapshot()
      settings.apply(runtime, to: panelState, rimeVertical: true, schemaID: "rime_ice")
      latestRuntime = runtime
      applyCount += 1
    }

    let edits: [OwlCandidatePanelSettings.Edit] = [
      .appearance(.dark),
      .skin(.wuda),
      .font(.notoSerifSC),
      .animationsEnabled(false),
      .size(.extraLarge),
      .orientation(.scroll),
      .showPreedit(false),
      .inlineCandidate(true),
      .showPaging(false),
      .showNotificationsWhen(.never),
      .candidateFormat(.candidateOnly),
      .scrollRows(2)
    ]
    for edit in edits {
      settings.edit(edit, state: editingState, onChange: applyRuntimeSnapshot)
    }

    let expectedFont = OwlCandidateFont(
      selection: .notoSerifSC,
      resolution: .installedFamily("Noto Serif CJK SC")
    )
    XCTAssertEqual(editingState.panelAppearance, .dark)
    XCTAssertEqual(editingState.skin, .wuda)
    XCTAssertEqual(editingState.candidateFont, expectedFont)
    XCTAssertFalse(editingState.panelAnimationsEnabled)
    XCTAssertEqual(editingState.panelFontSize, .extraLarge)
    XCTAssertEqual(editingState.panelOrientation, .scroll)
    XCTAssertFalse(editingState.panelShowPreedit)
    XCTAssertTrue(editingState.panelInlineCandidate)
    XCTAssertFalse(editingState.panelShowPaging)
    XCTAssertEqual(editingState.panelShowNotificationsWhen, .never)
    XCTAssertEqual(editingState.panelCandidateFormat, .candidateOnly)
    XCTAssertEqual(editingState.panelScrollRows, 2)

    XCTAssertEqual(defaults.string(forKey: "OwlPanelAppearance"), OwlPanelAppearance.dark.rawValue)
    XCTAssertEqual(defaults.string(forKey: "OwlSkin"), OwlSkin.wuda.rawValue)
    XCTAssertEqual(defaults.string(forKey: "OwlPanelFontDesign"), OwlCandidateFontSelection.notoSerifSC.rawValue)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelAnimations") as? Bool, false)
    XCTAssertEqual(defaults.string(forKey: "OwlPanelFontSize"), OwlPanelFontSize.extraLarge.rawValue)
    XCTAssertEqual(defaults.string(forKey: "OwlPanelOrientation"), OwlPanelOrientation.scroll.rawValue)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelShowPreedit") as? Bool, false)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelInlineCandidate") as? Bool, true)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelShowPaging") as? Bool, false)
    XCTAssertEqual(defaults.string(forKey: "OwlPanelShowNotificationsWhen"), OwlNotificationWhen.never.rawValue)
    XCTAssertEqual(defaults.string(forKey: "OwlPanelCandidateFormat"), OwlCandidateFormat.candidateOnly.rawValue)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelPreviewRows") as? Int, 2)
    XCTAssertTrue(settings.currentInlineCandidate())
    XCTAssertEqual(settings.currentShowNotificationsWhen(), .never)

    XCTAssertEqual(latestRuntime?.appearance, .dark)
    XCTAssertEqual(latestRuntime?.skin, .wuda)
    XCTAssertEqual(latestRuntime?.font, expectedFont)
    XCTAssertEqual(latestRuntime?.animationsEnabled, false)
    XCTAssertEqual(latestRuntime?.size, .extraLarge)
    XCTAssertEqual(latestRuntime?.orientation, .scroll)
    XCTAssertEqual(latestRuntime?.showPreedit, false)
    XCTAssertEqual(latestRuntime?.inlineCandidate, true)
    XCTAssertEqual(latestRuntime?.showPaging, false)
    XCTAssertEqual(latestRuntime?.showNotificationsWhen, .never)
    XCTAssertEqual(latestRuntime?.candidateFormat, .candidateOnly)
    XCTAssertEqual(latestRuntime?.scrollRows, 2)
    XCTAssertEqual(applyCount, edits.count, "every edit must refresh one runtime snapshot")

    XCTAssertEqual(panelState.appearance, .dark)
    XCTAssertEqual(panelState.theme, OwlSkin.wuda.theme)
    XCTAssertEqual(panelState.candidateFont, expectedFont)
    XCTAssertFalse(panelState.animationsEnabled)
    XCTAssertEqual(panelState.fontSize, OwlPanelFontSize.extraLarge.base)
    XCTAssertFalse(panelState.isVertical)
    XCTAssertTrue(panelState.isScroll)
    XCTAssertFalse(panelState.showPreedit)
    XCTAssertFalse(panelState.showPaging)
    XCTAssertEqual(panelState.candidateFormat, .candidateOnly)
    XCTAssertEqual(panelState.scrollRowLimit, 2)

    let reopenedState = OwlSettingsState()
    settings.seed(reopenedState)
    XCTAssertEqual(reopenedState.panelAppearance, .dark)
    XCTAssertEqual(reopenedState.skin, .wuda)
    XCTAssertEqual(reopenedState.candidateFont, expectedFont)
    XCTAssertFalse(reopenedState.panelAnimationsEnabled)
    XCTAssertEqual(reopenedState.panelFontSize, .extraLarge)
    XCTAssertEqual(reopenedState.panelOrientation, .scroll)
    XCTAssertFalse(reopenedState.panelShowPreedit)
    XCTAssertTrue(reopenedState.panelInlineCandidate)
    XCTAssertFalse(reopenedState.panelShowPaging)
    XCTAssertEqual(reopenedState.panelShowNotificationsWhen, .never)
    XCTAssertEqual(reopenedState.panelCandidateFormat, .candidateOnly)
    XCTAssertEqual(reopenedState.panelScrollRows, 2)

    let restartedSettings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    XCTAssertEqual(restartedSettings.snapshot(), latestRuntime)
  }

  func testNonRenderedRuntimeReadsShareModuleDefaultsWithTheFullSnapshot() {
    defaults.set("invalid", forKey: "OwlPanelInlineCandidate")
    defaults.set("invalid", forKey: "OwlPanelShowNotificationsWhen")
    let settings = OwlCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: StubCandidateFontCatalog([])
    )

    let runtime = settings.snapshot()
    XCTAssertEqual(runtime.inlineCandidate, OwlCandidatePanelSettings.defaultInlineCandidate)
    XCTAssertEqual(
      runtime.showNotificationsWhen,
      OwlCandidatePanelSettings.defaultShowNotificationsWhen
    )
    XCTAssertEqual(settings.currentInlineCandidate(), runtime.inlineCandidate)
    XCTAssertEqual(settings.currentShowNotificationsWhen(), runtime.showNotificationsWhen)
  }

  func testInlineCandidateEditReachesSessionInlineResolutionThroughRuntimeConsumer() {
    let settings = OwlCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: StubCandidateFontCatalog([])
    )
    let editingState = OwlSettingsState()
    var style = OwlStyleFlags()

    settings.edit(.inlineCandidate(true), state: editingState) {
      settings.applyInlineCandidate(to: &style)
    }

    XCTAssertTrue(style.inlineCandidate)
    XCTAssertTrue(
      OwlStyleFlags.sessionInline(
        style: style,
        noInline: false,
        inlineForced: false
      ).candidate,
      "the next composition update must consume the edited inline-candidate preference"
    )
  }

  func testNotificationEditControlsOptionAndSchemaPolicyIncludingOffMainRead() {
    let catalog = StubCandidateFontCatalog([])
    let settings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    let editingState = OwlSettingsState()

    let cases: [(OwlNotificationWhen, Bool, Bool)] = [
      (.always, true, true),
      (.appropriate, false, true),
      (.never, false, false)
    ]
    for (value, showsOption, showsSchema) in cases {
      settings.edit(.showNotificationsWhen(value), state: editingState, onChange: {})
      let observed = DispatchQueue.global(qos: .userInitiated).sync {
        (
          settings.shouldShowNotification(for: .option),
          settings.shouldShowNotification(for: .schema)
        )
      }
      XCTAssertEqual(observed.0, showsOption, "option policy for \(value)")
      XCTAssertEqual(observed.1, showsSchema, "schema policy for \(value)")
    }
    XCTAssertEqual(catalog.readCount, 0, "off-main notification policy must not resolve fonts")
  }

  func testFontEditPersistsReseedsSnapshotsAndAppliesToObservablePanel() throws {
    let catalog = StubCandidateFontCatalog([
      "Noto Serif CJK SC",
      "Maple Mono CN"
    ])
    let settings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    let editingState = OwlSettingsState()
    let panelState = CandidatePanelState()
    var applyCount = 0

    let cases: [(OwlCandidateFontSelection, OwlCandidateFont.Resolution)] = [
      (.default, .system(.default)),
      (.notoSerifSC, .installedFamily("Noto Serif CJK SC")),
      (.mapleMono, .installedFamily("Maple Mono CN"))
    ]

    for (selection, resolution) in cases {
      settings.edit(.font(selection), state: editingState) {
        settings.apply(settings.snapshot(), to: panelState)
        applyCount += 1
      }

      let expected = OwlCandidateFont(selection: selection, resolution: resolution)
      XCTAssertEqual(editingState.candidateFont, expected)
      XCTAssertEqual(defaults.string(forKey: "OwlPanelFontDesign"), selection.rawValue)
      XCTAssertEqual(panelState.candidateFont, expected, "visible panel must refresh in the edit callback")

      let reopenedState = OwlSettingsState()
      settings.seed(reopenedState)
      XCTAssertEqual(reopenedState.candidateFont, expected, "reopening settings must read the persisted selection")

      let restartedSettings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
      let runtime = restartedSettings.snapshot()
      let restartedPanelState = CandidatePanelState()
      restartedSettings.apply(runtime, to: restartedPanelState)
      XCTAssertEqual(runtime.font, expected)
      XCTAssertEqual(restartedPanelState.candidateFont, expected, "runtime snapshot and panel apply must agree")
    }

    XCTAssertEqual(applyCount, cases.count)
  }

  func testSystemFontSelectionsDoNotConsultInstalledFontCatalog() {
    let catalog = StubCandidateFontCatalog([])
    let settings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)

    XCTAssertEqual(settings.resolveFont(.default).resolution, .system(.default))
    XCTAssertEqual(settings.resolveFont(.serif).resolution, .system(.serif))
    XCTAssertEqual(settings.resolveFont(.rounded).resolution, .system(.rounded))
    XCTAssertEqual(catalog.readCount, 0)
  }

  func testInstalledNamedFontsResolveThroughSubstitutableCatalog() {
    let catalog = StubCandidateFontCatalog([
      "Maple Mono NF",
      "nOtO SeRiF cJk Sc",
      "Maple Mono CN"
    ])
    let settings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)

    XCTAssertEqual(
      settings.resolveFont(.notoSerifSC).resolution,
      .installedFamily("nOtO SeRiF cJk Sc")
    )
    XCTAssertEqual(
      settings.resolveFont(.mapleMono).resolution,
      .installedFamily("Maple Mono CN"),
      "the Chinese Maple family must win over a generic installed variant"
    )
    XCTAssertEqual(catalog.readCount, 2)
  }

  func testUnavailableNamedFontsResolveToExplicitFallbacks() {
    let settings = OwlCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: StubCandidateFontCatalog(["PingFang SC", "Menlo"])
    )

    let noto = settings.resolveFont(.notoSerifSC)
    XCTAssertEqual(noto.resolution, .fallback(.serif))
    XCTAssertEqual(noto.unavailableSelection, .notoSerifSC)

    let maple = settings.resolveFont(.mapleMono)
    XCTAssertEqual(maple.resolution, .fallback(.monospaced))
    XCTAssertEqual(maple.unavailableSelection, .mapleMono)
  }
}

private final class StubCandidateFontCatalog: OwlCandidateFontCatalog {
  private let families: [String]
  private(set) var readCount = 0

  init(_ families: [String]) {
    self.families = families
  }

  func availableFontFamilies() -> [String] {
    readCount += 1
    return families
  }
}
