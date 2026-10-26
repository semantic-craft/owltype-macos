//
//  OwlCandidatePanelAppearanceLifecycleTests.swift
//  OwltypeTests — #117 candidate-panel appearance settings lifecycle
//

import AppKit
import XCTest
import SwiftUI
@testable import Owltype

@MainActor
final class OwlPanelAppearanceLifecycleTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "OwlCandidatePanelAppearanceLifecycleTests-\(UUID().uuidString)"
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
    let settings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    let editingState = OwlSettingsState()
    let panelState = CandidatePanelState()
    var appliedAppearance: NSAppearance?
    var applyCount = 0

    func applyRuntimeSnapshot() {
      let runtime = settings.snapshot()
      settings.apply(runtime, to: panelState) {
        appliedAppearance = $0
      }
      applyCount += 1
    }

    settings.edit(.appearance(.dark), state: editingState, onChange: applyRuntimeSnapshot)
    settings.edit(.skin(.wuda), state: editingState, onChange: applyRuntimeSnapshot)
    settings.edit(.font(.notoSerifSC), state: editingState, onChange: applyRuntimeSnapshot)
    settings.edit(.animationsEnabled(false), state: editingState, onChange: applyRuntimeSnapshot)

    let expectedFont = OwlCandidateFont(
      selection: .notoSerifSC,
      resolution: .installedFamily("Noto Serif CJK SC")
    )
    XCTAssertEqual(editingState.panelAppearance, .dark)
    XCTAssertEqual(editingState.skin, .wuda)
    XCTAssertEqual(editingState.candidateFont, expectedFont)
    XCTAssertFalse(editingState.panelAnimationsEnabled)
    XCTAssertEqual(defaults.string(forKey: "OwlPanelAppearance"), OwlPanelAppearance.dark.rawValue)
    XCTAssertEqual(defaults.string(forKey: "OwlSkin"), OwlSkin.wuda.rawValue)
    XCTAssertEqual(defaults.string(forKey: "OwlPanelFontDesign"), OwlCandidateFontSelection.notoSerifSC.rawValue)
    XCTAssertEqual(defaults.object(forKey: "OwlPanelAnimations") as? Bool, false)

    XCTAssertEqual(panelState.appearance, .dark)
    XCTAssertEqual(panelState.theme, OwlSkin.wuda.theme)
    XCTAssertEqual(panelState.candidateFont, expectedFont)
    XCTAssertFalse(panelState.animationsEnabled)
    XCTAssertEqual(appliedAppearance?.name, .darkAqua)
    XCTAssertEqual(applyCount, 4, "every edit must trigger one immediate runtime apply")

    let reopenedState = OwlSettingsState()
    settings.seed(reopenedState)
    XCTAssertEqual(reopenedState.panelAppearance, .dark)
    XCTAssertEqual(reopenedState.skin, .wuda)
    XCTAssertEqual(reopenedState.candidateFont, expectedFont)
    XCTAssertFalse(reopenedState.panelAnimationsEnabled)

    let restartedSettings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    let restartedRuntime = restartedSettings.snapshot()
    XCTAssertEqual(restartedRuntime.appearance, .dark)
    XCTAssertEqual(restartedRuntime.skin, .wuda)
    XCTAssertEqual(restartedRuntime.font, expectedFont)
    XCTAssertFalse(restartedRuntime.animationsEnabled)

    let restartedPanelState = CandidatePanelState()
    var restartedAppearance: NSAppearance?
    restartedSettings.apply(restartedRuntime, to: restartedPanelState) {
      restartedAppearance = $0
    }
    XCTAssertEqual(restartedPanelState.appearance, .dark)
    XCTAssertEqual(restartedPanelState.theme, OwlSkin.wuda.theme)
    XCTAssertEqual(restartedPanelState.candidateFont, expectedFont)
    XCTAssertFalse(restartedPanelState.animationsEnabled)
    XCTAssertEqual(restartedAppearance?.name, .darkAqua)
  }

  func testSystemAppearanceClearsForcedAppearanceAndInvalidValuesUseShippingDefaults() {
    defaults.set("invalid", forKey: "OwlPanelAppearance")
    defaults.set("invalid", forKey: "OwlSkin")
    defaults.set("invalid", forKey: "OwlPanelFontDesign")
    defaults.set("invalid", forKey: "OwlPanelAnimations")
    let settings = OwlCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: AppearanceLifecycleFontCatalog([])
    )

    let snapshot = settings.snapshot()
    XCTAssertEqual(snapshot.appearance, .system)
    XCTAssertEqual(snapshot.skin, .deepred)
    XCTAssertEqual(snapshot.font, .systemDefault)
    XCTAssertTrue(snapshot.animationsEnabled)

    let editingState = OwlSettingsState()
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
    let settings = OwlCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: AppearanceLifecycleFontCatalog([])
    )
    let editingState = OwlSettingsState()
    let panelState = CandidatePanelState()

    settings.edit(.animationsEnabled(true), state: editingState) {
      settings.apply(settings.snapshot(), to: panelState)
    }

    XCTAssertTrue(panelState.animationsEnabled)
    XCTAssertTrue(panelState.animationsAllowed(reduceMotion: false))
    XCTAssertFalse(panelState.animationsAllowed(reduceMotion: true), "Reduce Motion must win")
  }
}

private struct AppearanceLifecycleFontCatalog: OwlCandidateFontCatalog {
  let families: [String]

  init(_ families: [String]) {
    self.families = families
  }

  func availableFontFamilies() -> [String] {
    families
  }
}

@MainActor
final class OwlInputStatusPanelGeometryTests: XCTestCase {
  func testDisconnectedDisplayReturnsBarToRemainingVisibleScreen() {
    let visible = NSRect(x: 0, y: 40, width: 1440, height: 830)
    let old = NSRect(x: 2300, y: 100, width: 320, height: 48)
    let result = OwlInputStatusPanel.reachableFrame(old, screens: [visible])
    XCTAssertTrue(visible.contains(result))
    XCTAssertEqual(result.size, old.size)
  }

  func testNegativeOriginDisplayKeepsUserPlacement() {
    let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
    let right = NSRect(x: 0, y: 40, width: 1440, height: 830)
    let frame = NSRect(x: -1800, y: 120, width: 320, height: 48)
    XCTAssertEqual(OwlInputStatusPanel.reachableFrame(frame, screens: [left, right]), frame)
  }

  func testPartiallyOffscreenBarIsFullyReachableAboveDock() {
    let visible = NSRect(x: 0, y: 80, width: 1440, height: 790)
    let frame = NSRect(x: 1400, y: 20, width: 320, height: 48)
    XCTAssertTrue(visible.contains(OwlInputStatusPanel.reachableFrame(frame, screens: [visible])))
  }
}

@MainActor
final class OwlInputStatusPanelRenderingTests: XCTestCase {
  func testEverySkinRendersInBothAppearances() throws {
    let settings = OwlCandidatePanelSettings.live
    // Render copied snapshots; do not edit the live settings or touch the engine.
    let base = settings.snapshot()
    for skin in OwlSkin.allCases {
      for dark in [false, true] {
        let snapshot = OwlCandidatePanelSettings.Snapshot(
          appearance: dark ? .dark : .light, skin: skin, font: base.font,
          animationsEnabled: false, size: base.size, orientation: base.orientation,
          showPreedit: base.showPreedit, inlineCandidate: base.inlineCandidate,
          showPaging: base.showPaging, showNotificationsWhen: base.showNotificationsWhen,
          candidateFormat: base.candidateFormat, scrollRows: base.scrollRows)
        let presentation = OwlInputStatusPanel.Presentation(
          schema: "wubi86_jidian_pinyin", ascii: false, punctuation: false,
          fullShape: false, traditional: false, settings: snapshot)
        let host = NSHostingView(rootView: OwlInputStatusView(presentation: presentation, action: { _ in })
          .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        XCTAssertGreaterThan(size.width, 200)
        XCTAssertLessThan(size.width, 400)
        XCTAssertLessThanOrEqual(size.height, 60)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "status-\(skin.rawValue)-\(dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
  }
}
