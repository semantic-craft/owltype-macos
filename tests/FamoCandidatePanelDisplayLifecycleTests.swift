//
//  FamoCandidatePanelDisplayLifecycleTests.swift
//  FamoTests — #118 candidate-panel display settings lifecycle
//

import XCTest
@testable import Famo

@MainActor
final class FamoCandidatePanelDisplayLifecycleTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "FamoCandidatePanelDisplayLifecycleTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testDisplayEditsPersistReseedSnapshotAndImmediatelyApplyToObservablePanel() {
    let settings = FamoCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: DisplayLifecycleFontCatalog()
    )
    let editingState = FamoSettingsState()
    let panelState = CandidatePanelState()
    var applyCount = 0

    func applyRuntimeSnapshot() {
      let runtime = settings.snapshot()
      settings.apply(
        runtime,
        to: panelState,
        rimeVertical: true,
        schemaID: "rime_ice"
      )
      applyCount += 1
    }

    settings.edit(.size(.extraLarge), state: editingState, onChange: applyRuntimeSnapshot)
    XCTAssertEqual(panelState.fontSize, FamoPanelFontSize.extraLarge.base)
    settings.edit(.orientation(.scroll), state: editingState, onChange: applyRuntimeSnapshot)
    XCTAssertFalse(panelState.isVertical, "scroll remains horizontal even when Rime requests vertical")
    XCTAssertTrue(panelState.isScroll)
    settings.edit(.showPreedit(false), state: editingState, onChange: applyRuntimeSnapshot)
    XCTAssertFalse(panelState.showPreedit)
    settings.edit(.showPaging(false), state: editingState, onChange: applyRuntimeSnapshot)
    XCTAssertFalse(panelState.showPaging)
    settings.edit(.candidateFormat(.candidateOnly), state: editingState, onChange: applyRuntimeSnapshot)
    XCTAssertEqual(panelState.candidateFormat, .candidateOnly)
    settings.edit(.scrollRows(2), state: editingState, onChange: applyRuntimeSnapshot)
    XCTAssertEqual(panelState.scrollRowLimit, 2)

    XCTAssertEqual(editingState.panelFontSize, .extraLarge)
    XCTAssertEqual(editingState.panelOrientation, .scroll)
    XCTAssertFalse(editingState.panelShowPreedit)
    XCTAssertFalse(editingState.panelShowPaging)
    XCTAssertEqual(editingState.panelCandidateFormat, .candidateOnly)
    XCTAssertEqual(editingState.panelScrollRows, 2)

    XCTAssertEqual(defaults.string(forKey: "FamoPanelFontSize"), FamoPanelFontSize.extraLarge.rawValue)
    XCTAssertEqual(defaults.string(forKey: "FamoPanelOrientation"), FamoPanelOrientation.scroll.rawValue)
    XCTAssertEqual(defaults.object(forKey: "FamoPanelShowPreedit") as? Bool, false)
    XCTAssertEqual(defaults.object(forKey: "FamoPanelShowPaging") as? Bool, false)
    XCTAssertEqual(defaults.string(forKey: "FamoPanelCandidateFormat"), FamoCandidateFormat.candidateOnly.rawValue)
    XCTAssertEqual(defaults.object(forKey: "FamoPanelPreviewRows") as? Int, 2)

    XCTAssertEqual(panelState.fontSize, FamoPanelFontSize.extraLarge.base)
    XCTAssertFalse(panelState.isVertical)
    XCTAssertTrue(panelState.isScroll)
    XCTAssertFalse(panelState.showPreedit)
    XCTAssertFalse(panelState.showPaging)
    XCTAssertEqual(panelState.candidateFormat, .candidateOnly)
    XCTAssertEqual(panelState.scrollRowLimit, 2)
    XCTAssertEqual(applyCount, 6, "every display edit must immediately apply one runtime snapshot")

    let reopenedState = FamoSettingsState()
    settings.seed(reopenedState)
    XCTAssertEqual(reopenedState.panelFontSize, .extraLarge)
    XCTAssertEqual(reopenedState.panelOrientation, .scroll)
    XCTAssertFalse(reopenedState.panelShowPreedit)
    XCTAssertFalse(reopenedState.panelShowPaging)
    XCTAssertEqual(reopenedState.panelCandidateFormat, .candidateOnly)
    XCTAssertEqual(reopenedState.panelScrollRows, 2)

    let restartedSettings = FamoCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: DisplayLifecycleFontCatalog()
    )
    let restartedRuntime = restartedSettings.snapshot()
    XCTAssertEqual(restartedRuntime.size, .extraLarge)
    XCTAssertEqual(restartedRuntime.orientation, .scroll)
    XCTAssertFalse(restartedRuntime.showPreedit)
    XCTAssertFalse(restartedRuntime.showPaging)
    XCTAssertEqual(restartedRuntime.candidateFormat, .candidateOnly)
    XCTAssertEqual(restartedRuntime.scrollRows, 2)

    let restartedPanelState = CandidatePanelState()
    restartedSettings.apply(
      restartedRuntime,
      to: restartedPanelState,
      rimeVertical: true,
      schemaID: "rime_ice"
    )
    XCTAssertEqual(restartedPanelState.fontSize, FamoPanelFontSize.extraLarge.base)
    XCTAssertFalse(restartedPanelState.isVertical)
    XCTAssertTrue(restartedPanelState.isScroll)
    XCTAssertFalse(restartedPanelState.showPreedit)
    XCTAssertFalse(restartedPanelState.showPaging)
    XCTAssertEqual(restartedPanelState.candidateFormat, .candidateOnly)
    XCTAssertEqual(restartedPanelState.scrollRowLimit, 2)
  }

  func testDisplayDefaultsAndConstraintsAreOwnedByTheModule() {
    defaults.set("invalid", forKey: "FamoPanelFontSize")
    defaults.set("invalid", forKey: "FamoPanelOrientation")
    defaults.set("invalid", forKey: "FamoPanelShowPreedit")
    defaults.set("invalid", forKey: "FamoPanelShowPaging")
    defaults.set("invalid", forKey: "FamoPanelCandidateFormat")
    defaults.set(99, forKey: "FamoPanelPreviewRows")
    let settings = FamoCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: DisplayLifecycleFontCatalog()
    )

    var snapshot = settings.snapshot()
    XCTAssertEqual(snapshot.size, .medium)
    XCTAssertEqual(snapshot.orientation, .auto)
    XCTAssertTrue(snapshot.showPreedit)
    XCTAssertTrue(snapshot.showPaging)
    XCTAssertEqual(snapshot.candidateFormat, .full)
    XCTAssertEqual(snapshot.scrollRows, 4)

    let editingState = FamoSettingsState()
    let panelState = CandidatePanelState()
    panelState.page = 1
    panelState.scrollRows = [0, 2, 3, 4, 5].map { FamoScrollRow(id: $0, candidates: []) }
    settings.edit(.scrollRows(0), state: editingState) {
      settings.apply(settings.snapshot(), to: panelState)
    }
    snapshot = settings.snapshot()
    XCTAssertEqual(editingState.panelScrollRows, 1)
    XCTAssertEqual(defaults.object(forKey: "FamoPanelPreviewRows") as? Int, 1)
    XCTAssertEqual(snapshot.scrollRows, 1)
    XCTAssertEqual(panelState.visibleScrollRows.map(\.id), [0, 2])

    settings.edit(.scrollRows(9), state: editingState) {
      settings.apply(settings.snapshot(), to: panelState)
    }
    snapshot = settings.snapshot()
    XCTAssertEqual(editingState.panelScrollRows, 4)
    XCTAssertEqual(defaults.object(forKey: "FamoPanelPreviewRows") as? Int, 4)
    XCTAssertEqual(snapshot.scrollRows, 4)
    XCTAssertEqual(
      panelState.visibleScrollRows.map(\.id),
      [0, 2, 3, 4, 5],
      "raising the limit must reveal prefetched rows on the visible panel immediately"
    )
  }
}

private struct DisplayLifecycleFontCatalog: FamoCandidateFontCatalog {
  func availableFontFamilies() -> [String] { [] }
}
