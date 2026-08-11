//
//  FamoCandidatePanelSettingsTests.swift
//  FamoTests — #112 candidate-panel font lifecycle seam
//

import XCTest
@testable import Famo

@MainActor
final class FamoCandidatePanelSettingsTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "FamoCandidatePanelSettingsTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testFontEditPersistsReseedsSnapshotsAndAppliesToObservablePanel() throws {
    let catalog = StubCandidateFontCatalog([
      "Noto Serif CJK SC",
      "Maple Mono CN",
    ])
    let settings = FamoCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    let editingState = FamoSettingsState()
    let panelState = CandidatePanelState()
    var applyCount = 0

    let cases: [(FamoCandidateFontSelection, FamoCandidateFont.Resolution)] = [
      (.default, .system(.default)),
      (.notoSerifSC, .installedFamily("Noto Serif CJK SC")),
      (.mapleMono, .installedFamily("Maple Mono CN")),
    ]

    for (selection, resolution) in cases {
      settings.edit(.font(selection), state: editingState) {
        settings.apply(settings.snapshot(), to: panelState)
        applyCount += 1
      }

      let expected = FamoCandidateFont(selection: selection, resolution: resolution)
      XCTAssertEqual(editingState.candidateFont, expected)
      XCTAssertEqual(defaults.string(forKey: "FamoPanelFontDesign"), selection.rawValue)
      XCTAssertEqual(panelState.candidateFont, expected, "visible panel must refresh in the edit callback")

      let reopenedState = FamoSettingsState()
      settings.seed(reopenedState)
      XCTAssertEqual(reopenedState.candidateFont, expected, "reopening settings must read the persisted selection")

      let restartedSettings = FamoCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
      let runtime = FamoPanelSnapshot.current(candidatePanelSettings: restartedSettings)
      let restartedPanelState = CandidatePanelState()
      restartedSettings.apply(runtime.candidatePanelSettings, to: restartedPanelState)
      XCTAssertEqual(runtime.candidatePanelSettings.font, expected)
      XCTAssertEqual(restartedPanelState.candidateFont, expected, "runtime snapshot and panel apply must agree")
    }

    XCTAssertEqual(applyCount, cases.count)
  }

  func testSystemFontSelectionsDoNotConsultInstalledFontCatalog() {
    let catalog = StubCandidateFontCatalog([])
    let settings = FamoCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)

    XCTAssertEqual(settings.resolveFont(.default).resolution, .system(.default))
    XCTAssertEqual(settings.resolveFont(.serif).resolution, .system(.serif))
    XCTAssertEqual(settings.resolveFont(.rounded).resolution, .system(.rounded))
    XCTAssertEqual(catalog.readCount, 0)
  }

  func testInstalledNamedFontsResolveThroughSubstitutableCatalog() {
    let catalog = StubCandidateFontCatalog([
      "Maple Mono NF",
      "nOtO SeRiF cJk Sc",
      "Maple Mono CN",
    ])
    let settings = FamoCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)

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
    let settings = FamoCandidatePanelSettings(
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

private final class StubCandidateFontCatalog: FamoCandidateFontCatalog {
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
