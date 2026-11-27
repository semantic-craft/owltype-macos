//
//  OwlCandidatePanelAppearanceLifecycleTests.swift
//  OwltypeTests — #117 candidate-panel appearance settings lifecycle
//

import AppKit
import XCTest
import SwiftUI
@testable import Owltype

@MainActor
final class OwlCandidatePanelAppearanceLifecycleTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = makeIsolatedDefaults(prefix: "OwlCandidatePanelAppearanceLifecycleTests")
  }

  override func tearDown() {
    defaults = nil
    super.tearDown()
  }

  func testHostFacingPanelsCannotBecomeKeyOrMain() {
    let candidate = OwlSwiftUICandidatePanel()
    let status = OwlInputStatusPanel.shared
    let voice = OwlVoiceCapsulePanel()
    let delivery = OwlAgentDeliveryPanel()
    for panel in [candidate, status, voice, delivery] as [NSPanel] {
      let name = String(describing: type(of: panel))
      XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), name)
      XCTAssertFalse(panel.canBecomeKey, name)
      XCTAssertFalse(panel.canBecomeMain, name)
    }
    XCTAssertTrue(voice.ignoresMouseEvents, "The display-only capsule must let clicks reach the host")
    XCTAssertFalse(candidate.ignoresMouseEvents)
    XCTAssertFalse(status.ignoresMouseEvents)
    XCTAssertFalse(delivery.ignoresMouseEvents)
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

  func testCandidatePanelHideClearsRenderedCompositionAndReshowsCleanly() {
    let state = CandidatePanelState()
    state.preedit = "nihao"
    state.cursor = 5
    state.selStart = 0
    state.selEnd = 5
    state.candidates = [CandidateViewModel(id: 0, label: "1", text: "你好")]
    state.scrollRows = [OwlScrollRow(id: 1, candidates: [CandidateViewModel(id: 5, label: "", text: "拟好")])]
    state.highlightedIndex = 2
    state.page = 1
    state.hasPrevPage = true
    state.hasNextPage = true
    state.isExpanded = true

    state.resetComposition()
    XCTAssertEqual(state.preedit, "")
    XCTAssertEqual(state.cursor, 0)
    XCTAssertEqual(state.selStart, 0)
    XCTAssertEqual(state.selEnd, 0)
    XCTAssertTrue(state.candidates.isEmpty)
    XCTAssertTrue(state.scrollRows.isEmpty)
    XCTAssertEqual(state.highlightedIndex, 0)
    XCTAssertEqual(state.page, 0)
    XCTAssertFalse(state.hasPrevPage)
    XCTAssertFalse(state.hasNextPage)
    XCTAssertFalse(state.isExpanded)

    let panel = OwlSwiftUICandidatePanel()
    XCTAssertFalse(panel.hasRenderedComposition)

    let snapshot = OwlCandidatePanelSettings(
      defaults: defaults,
      fontCatalog: AppearanceLifecycleFontCatalog([])
    ).snapshot()
    let content = OwlPanelContent(
      preedit: "nihao",
      cursor: 5,
      selStart: 0,
      selEnd: 5,
      candidates: [
        CandidateViewModel(id: 0, label: "1", text: "你好"),
        CandidateViewModel(id: 1, label: "2", text: "拟好"),
      ],
      highlightedIndex: 0,
      page: 0,
      hasPrevPage: false,
      hasNextPage: true,
      isVertical: false,
      schemaID: "rime_ice",
      anchor: NSRect(x: 200, y: 200, width: 1, height: 18)
    )

    XCTAssertTrue(panel.update(content, settings: snapshot))
    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(panel.hasRenderedComposition)

    panel.hidePanel()
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.hasRenderedComposition)

    XCTAssertTrue(panel.update(content, settings: snapshot), "re-showing after hide must render again")
    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(panel.hasRenderedComposition)
    panel.hidePanel()
    XCTAssertFalse(panel.hasRenderedComposition)
  }

  func testSwitchingOrientationFromVerticalToAutoClearsVerticalAfterRefreshPreferences() throws {
    let delegate = NSApp.owlAppDelegate
    let previousOrientation = OwlDefaults.standard.object(forKey: "OwlPanelOrientation")
    let previousEngine = delegate.runtime.engine
    let previousPanel = delegate.owlPanel
    let previousEmitter = delegate.snapshotEmitter
    let previousActivated = delegate.runtime.activatedInputController

    let panel = OwlSwiftUICandidatePanel()
    delegate.runtime.engine = FakeInputEngine()
    delegate.snapshotEmitter = FakeSnapshotEmitter()
    delegate.owlPanel = panel
    defer {
      panel.hidePanel()
      if let previousOrientation {
        OwlDefaults.standard.set(previousOrientation, forKey: "OwlPanelOrientation")
      } else {
        OwlDefaults.standard.removeObject(forKey: "OwlPanelOrientation")
      }
      delegate.runtime.applyPanelPreferences()
      delegate.owlPanel = previousPanel
      delegate.snapshotEmitter = previousEmitter
      delegate.runtime.activatedInputController = previousActivated
      delegate.runtime.engine = previousEngine
    }

    OwlDefaults.standard.set(OwlPanelOrientation.vertical.rawValue, forKey: "OwlPanelOrientation")
    delegate.runtime.applyPanelPreferences()

    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { controller.destroySession() }
    controller.destroySession()
    let session = FakeEngineSession(sessionID: 95, optionState: [.vertical: true])
    controller.engineSession = session
    let client = HabitsTextClient()
    controller.client = client

    controller.showPanel(
      preedit: "ni",
      cursor: 2,
      selStart: 0,
      selEnd: 2,
      candidates: ["你"],
      comments: [""],
      labels: ["1"],
      highlighted: 0,
      page: 0,
      lastPage: true,
      pageSize: 5
    )
    XCTAssertTrue(panel.panelState.isVertical, "explicit vertical setting must render vertically")

    OwlDefaults.standard.set(OwlPanelOrientation.auto.rawValue, forKey: "OwlPanelOrientation")
    delegate.runtime.applyPanelPreferences()
    panel.refreshPreferences()

    XCTAssertFalse(
      panel.panelState.isVertical,
      "switching orientation from vertical to auto must clear vertical instead of feeding engineSession.option(.vertical) back"
    )
  }

  func testOnboardingAndSettingsWindowsTearDownContentViewOnCloseAndReopenCleanly() {
    let onboarding = OwlOnboardingWindow()
    onboarding.show(
      onOpenSystemSettings: {},
      onSelectSchema: { _ in },
      onOpenInputSettings: {},
      onFinish: {},
      isOwltypeEnabled: { true }
    )
    XCTAssertNotNil(onboarding.window?.contentView)
    onboarding.close()
    XCTAssertNil(onboarding.window?.contentView, "closing onboarding must detach its SwiftUI hosting view")

    onboarding.show(
      onOpenSystemSettings: {},
      onSelectSchema: { _ in },
      onOpenInputSettings: {},
      onFinish: {},
      isOwltypeEnabled: { true }
    )
    XCTAssertNotNil(onboarding.window?.contentView, "reopening onboarding must reattach its content view")
    onboarding.close()

    let settings = OwlSettingsWindow()
    let firstState = OwlSettingsState()
    firstState.schemas = [SchemaItem(id: "rime_ice", name: "雾凇拼音")]
    settings.show(
      state: firstState,
      onSelectSchema: { _ in },
      onRedeploy: { true },
      onTemplatesChanged: {},
      onApplyKeyboardConfigFast: { .init(written: [], succeeded: true) },
      onApplyFuzzyConfigFast: { .init(written: [], succeeded: true) },
      userDataActions: .init(resetUserDict: {}),
      onOpenDataFolder: {},
      onOpenLog: {},
      onShowOnboarding: {},
      onPanelPreferencesChanged: {}
    )
    XCTAssertNotNil(settings.window?.contentView)
    XCTAssertTrue(settings.restoreIfOpen(selectedPage: .ai))
    XCTAssertEqual(firstState.selectedPage, .ai)

    settings.close()
    XCTAssertNil(settings.window?.contentView, "closing settings must detach its SwiftUI hosting view")
    XCTAssertFalse(settings.restoreIfOpen(), "closed settings window must not report as open")

    let secondState = OwlSettingsState()
    secondState.schemas = [SchemaItem(id: "rime_ice", name: "雾凇拼音")]
    settings.show(
      state: secondState,
      onSelectSchema: { _ in },
      onRedeploy: { true },
      onTemplatesChanged: {},
      onApplyKeyboardConfigFast: { .init(written: [], succeeded: true) },
      onApplyFuzzyConfigFast: { .init(written: [], succeeded: true) },
      userDataActions: .init(resetUserDict: {}),
      onOpenDataFolder: {},
      onOpenLog: {},
      onShowOnboarding: {},
      onPanelPreferencesChanged: {}
    )
    XCTAssertNotNil(settings.window?.contentView, "reopening settings must reattach its content view")
    XCTAssertTrue(settings.restoreIfOpen(selectedPage: .keyboard))
    XCTAssertEqual(secondState.selectedPage, .keyboard)
    settings.close()
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
