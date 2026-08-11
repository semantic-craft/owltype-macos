//
//  FamoCandidatePanelAppearanceLifecycleTests.swift
//  FamoTests — #117 candidate-panel appearance settings lifecycle
//

import AppKit
import XCTest
@testable import Famo

@MainActor
final class FamoPanelAppearanceLifecycleTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "FamoCandidatePanelAppearanceLifecycleTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testAppearanceFieldsEditPersistReseedSnapshotAndApplyToObservablePanel() {
    let catalog = AppearanceLifecycleFontCatalog(["Noto Serif CJK SC"])
    let settings = FamoCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    let editingState = FamoSettingsState()
    let panelState = CandidatePanelState()
    var appliedAppearance: NSAppearance?
    var applyCount = 0

    func applyRuntimeSnapshot() {
      let runtime = FamoPanelSnapshot.current(candidatePanelSettings: settings)
      settings.apply(runtime.candidatePanelSettings, to: panelState) {
        appliedAppearance = $0
      }
      applyCount += 1
    }

    settings.edit(.appearance(.dark), state: editingState, onChange: applyRuntimeSnapshot)
    settings.edit(.skin(.wuda), state: editingState, onChange: applyRuntimeSnapshot)
    settings.edit(.font(.notoSerifSC), state: editingState, onChange: applyRuntimeSnapshot)
    settings.edit(.animationsEnabled(false), state: editingState, onChange: applyRuntimeSnapshot)

    let expectedFont = FamoCandidateFont(
      selection: .notoSerifSC,
      resolution: .installedFamily("Noto Serif CJK SC")
    )
    XCTAssertEqual(editingState.panelAppearance, .dark)
    XCTAssertEqual(editingState.skin, .wuda)
    XCTAssertEqual(editingState.candidateFont, expectedFont)
    XCTAssertFalse(editingState.panelAnimationsEnabled)
    XCTAssertEqual(defaults.string(forKey: "FamoPanelAppearance"), FamoPanelAppearance.dark.rawValue)
    XCTAssertEqual(defaults.string(forKey: "FamoSkin"), FamoSkin.wuda.rawValue)
    XCTAssertEqual(defaults.string(forKey: "FamoPanelFontDesign"), FamoCandidateFontSelection.notoSerifSC.rawValue)
    XCTAssertEqual(defaults.object(forKey: "FamoPanelAnimations") as? Bool, false)

    XCTAssertEqual(panelState.appearance, .dark)
    XCTAssertEqual(panelState.theme, FamoSkin.wuda.theme)
    XCTAssertEqual(panelState.candidateFont, expectedFont)
    XCTAssertFalse(panelState.animationsEnabled)
    XCTAssertEqual(appliedAppearance?.name, .darkAqua)
    XCTAssertEqual(applyCount, 4, "every edit must trigger one immediate runtime apply")

    let reopenedState = FamoSettingsState()
    settings.seed(reopenedState)
    XCTAssertEqual(reopenedState.panelAppearance, .dark)
    XCTAssertEqual(reopenedState.skin, .wuda)
    XCTAssertEqual(reopenedState.candidateFont, expectedFont)
    XCTAssertFalse(reopenedState.panelAnimationsEnabled)

    let restartedSettings = FamoCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    let restartedRuntime = FamoPanelSnapshot.current(candidatePanelSettings: restartedSettings)
    XCTAssertEqual(restartedRuntime.candidatePanelSettings.appearance, .dark)
    XCTAssertEqual(restartedRuntime.candidatePanelSettings.skin, .wuda)
    XCTAssertEqual(restartedRuntime.candidatePanelSettings.font, expectedFont)
    XCTAssertFalse(restartedRuntime.candidatePanelSettings.animationsEnabled)

    let restartedPanelState = CandidatePanelState()
    var restartedAppearance: NSAppearance?
    restartedSettings.apply(restartedRuntime.candidatePanelSettings, to: restartedPanelState) {
      restartedAppearance = $0
    }
    XCTAssertEqual(restartedPanelState.appearance, .dark)
    XCTAssertEqual(restartedPanelState.theme, FamoSkin.wuda.theme)
    XCTAssertEqual(restartedPanelState.candidateFont, expectedFont)
    XCTAssertFalse(restartedPanelState.animationsEnabled)
    XCTAssertEqual(restartedAppearance?.name, .darkAqua)
  }

  func testSystemAppearanceClearsForcedAppearanceAndInvalidValuesUseShippingDefaults() {
    defaults.set("invalid", forKey: "FamoPanelAppearance")
    defaults.set("invalid", forKey: "FamoSkin")
    defaults.set("invalid", forKey: "FamoPanelFontDesign")
    defaults.set("invalid", forKey: "FamoPanelAnimations")
    let settings = FamoCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: AppearanceLifecycleFontCatalog([])
    )

    let snapshot = settings.snapshot()
    XCTAssertEqual(snapshot.appearance, .system)
    XCTAssertEqual(snapshot.skin, .deepred)
    XCTAssertEqual(snapshot.font, .systemDefault)
    XCTAssertTrue(snapshot.animationsEnabled)

    let editingState = FamoSettingsState()
    settings.edit(.appearance(.system), state: editingState, onChange: {})
    let panelState = CandidatePanelState()
    var appliedAppearance = NSAppearance(named: .darkAqua)
    settings.apply(settings.snapshot(), to: panelState) {
      appliedAppearance = $0
    }

    XCTAssertEqual(panelState.appearance, .system)
    XCTAssertNil(appliedAppearance, "following the system must clear a previously forced appearance")

    settings.edit(.appearance(.light), state: editingState, onChange: {})
    settings.apply(settings.snapshot(), to: panelState) {
      appliedAppearance = $0
    }
    XCTAssertEqual(panelState.appearance, .light)
    XCTAssertEqual(appliedAppearance?.name, .aqua, "forced light must use the AppKit aqua appearance")
  }

  func testReduceMotionAlwaysWinsOverPersistedAnimationChoice() {
    let settings = FamoCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: AppearanceLifecycleFontCatalog([])
    )
    let editingState = FamoSettingsState()
    let panelState = CandidatePanelState()

    settings.edit(.animationsEnabled(true), state: editingState) {
      settings.apply(settings.snapshot(), to: panelState)
    }

    XCTAssertTrue(panelState.animationsEnabled)
    XCTAssertTrue(panelState.animationsAllowed(reduceMotion: false))
    XCTAssertFalse(panelState.animationsAllowed(reduceMotion: true), "Reduce Motion must win")
  }
}

private struct AppearanceLifecycleFontCatalog: FamoCandidateFontCatalog {
  let families: [String]

  init(_ families: [String]) {
    self.families = families
  }

  func availableFontFamilies() -> [String] {
    families
  }
}
