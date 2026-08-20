//
//  OwlCandidatePanelDisplayLifecycleTests.swift
//  OwltypeTests — #118 candidate-panel display settings lifecycle
//

import XCTest
@testable import Owltype

@MainActor
final class OwlCandidatePanelDisplayLifecycleTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "OwlCandidatePanelDisplayLifecycleTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testDisplayEditsPersistReseedSnapshotAndImmediatelyApplyToObservablePanel() {
    let settings = OwlCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: DisplayLifecycleFontCatalog()
    )
    let editingState = OwlSettingsState()
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
    XCTAssertEqual(panelState.fontSize, OwlPanelFontSize.extraLarge.base)
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

    XCTAssertEqual(defaults.string(forKey: "OwlPanelFontSize"), OwlPanelFontSize.extraLarge.rawValue)
    XCTAssertEqual(defaults.string(forKey: "OwlPanelOrientation"), OwlPanelOrientation.scroll.rawValue)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelShowPreedit") as? Bool, false)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelShowPaging") as? Bool, false)
    XCTAssertEqual(defaults.string(forKey: "OwlPanelCandidateFormat"), OwlCandidateFormat.candidateOnly.rawValue)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelPreviewRows") as? Int, 2)

    XCTAssertEqual(panelState.fontSize, OwlPanelFontSize.extraLarge.base)
    XCTAssertFalse(panelState.isVertical)
    XCTAssertTrue(panelState.isScroll)
    XCTAssertFalse(panelState.showPreedit)
    XCTAssertFalse(panelState.showPaging)
    XCTAssertEqual(panelState.candidateFormat, .candidateOnly)
    XCTAssertEqual(panelState.scrollRowLimit, 2)
    XCTAssertEqual(applyCount, 6, "every display edit must immediately apply one runtime snapshot")

    let reopenedState = OwlSettingsState()
    settings.seed(reopenedState)
    XCTAssertEqual(reopenedState.panelFontSize, .extraLarge)
    XCTAssertEqual(reopenedState.panelOrientation, .scroll)
    XCTAssertFalse(reopenedState.panelShowPreedit)
    XCTAssertFalse(reopenedState.panelShowPaging)
    XCTAssertEqual(reopenedState.panelCandidateFormat, .candidateOnly)
    XCTAssertEqual(reopenedState.panelScrollRows, 2)

    let restartedSettings = OwlCandidatePanelSettings(
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
    XCTAssertEqual(restartedPanelState.fontSize, OwlPanelFontSize.extraLarge.base)
    XCTAssertFalse(restartedPanelState.isVertical)
    XCTAssertTrue(restartedPanelState.isScroll)
    XCTAssertFalse(restartedPanelState.showPreedit)
    XCTAssertFalse(restartedPanelState.showPaging)
    XCTAssertEqual(restartedPanelState.candidateFormat, .candidateOnly)
    XCTAssertEqual(restartedPanelState.scrollRowLimit, 2)
  }

  func testDisplayDefaultsAndConstraintsAreOwnedByTheModule() {
    defaults.set("invalid", forKey: "OwlPanelFontSize")
    defaults.set("invalid", forKey: "OwlPanelOrientation")
    defaults.set("invalid", forKey: "OwlPanelShowPreedit")
    defaults.set("invalid", forKey: "OwlPanelShowPaging")
    defaults.set("invalid", forKey: "OwlPanelCandidateFormat")
    defaults.set(99, forKey: "OwlPanelPreviewRows")
    let settings = OwlCandidatePanelSettings(
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

    let editingState = OwlSettingsState()
    let panelState = CandidatePanelState()
    panelState.page = 1
    panelState.scrollRows = [0, 2, 3, 4, 5].map { OwlScrollRow(id: $0, candidates: []) }
    settings.edit(.scrollRows(0), state: editingState) {
      settings.apply(settings.snapshot(), to: panelState)
    }
    snapshot = settings.snapshot()
    XCTAssertEqual(editingState.panelScrollRows, 1)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelPreviewRows") as? Int, 1)
    XCTAssertEqual(snapshot.scrollRows, 1)
    XCTAssertEqual(panelState.visibleScrollRows.map(\.id), [0, 2])

    settings.edit(.scrollRows(9), state: editingState) {
      settings.apply(settings.snapshot(), to: panelState)
    }
    snapshot = settings.snapshot()
    XCTAssertEqual(editingState.panelScrollRows, 4)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelPreviewRows") as? Int, 4)
    XCTAssertEqual(snapshot.scrollRows, 4)
    XCTAssertEqual(
      panelState.visibleScrollRows.map(\.id),
      [0, 2, 3, 4, 5],
      "raising the limit must reveal prefetched rows on the visible panel immediately"
    )
  }
}

private struct DisplayLifecycleFontCatalog: OwlCandidateFontCatalog {
  func availableFontFamilies() -> [String] { [] }
}
