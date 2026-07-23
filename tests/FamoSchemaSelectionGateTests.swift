//
//  FamoSchemaSelectionGateTests.swift
//  FamoTests — 方案 select 尝试/退避的纯决策 (task 07-07-schema-consistency-guard)
//
//  Locks the PURE decisions in `FamoSchemaSelectionGate`:
//    - idleAction: adopt when already on preferred; attempt when a fresh preferred differs; back
//      off when the preferred id is the known-failed one; re-attempt when config moved to a
//      different id (so a fixed/changed config is never permanently suppressed);
//    - markerAfterAttempt: a failed select remembers the id, a success clears the mark.
//
//  No IMK, no librime, no disk: pure value logic, mirrors FamoForcedFinalizeTests / FamoAutoPairTests.
//

import Foundation
import XCTest
@testable import Famo

final class FamoSchemaSelectionGateTests: XCTestCase {

  // MARK: - idleAction

  // Session already on the preferred schema → adopt it, no librime call.
  func testIdleAlreadyActiveWhenCurrentEqualsPreferred() {
    XCTAssertEqual(
      FamoSchemaSelectionGate.idleAction(current: "rime_ice", preferred: "rime_ice", knownFailed: nil),
      .alreadyActive
    )
  }

  // Preferred differs, nothing known-failed → attempt the select.
  func testIdleAttemptWhenPreferredDiffersAndNoKnownFailure() {
    XCTAssertEqual(
      FamoSchemaSelectionGate.idleAction(current: "wubi86_jidian", preferred: "rime_ice", knownFailed: nil),
      .attempt
    )
  }

  // Preferred equals the known-failed id → back off (no per-key retry, no trace spam).
  func testIdleSkipsWhenPreferredIsKnownFailed() {
    XCTAssertEqual(
      FamoSchemaSelectionGate.idleAction(current: "wubi86_jidian", preferred: "rime_ice", knownFailed: "rime_ice"),
      .skipKnownFailed
    )
  }

  // Config moved to a DIFFERENT id than the known-failed one → attempt again (never permanently
  // suppressed once the user changes the preference away from the broken schema).
  func testIdleReattemptsWhenPreferredMovedOffKnownFailed() {
    XCTAssertEqual(
      FamoSchemaSelectionGate.idleAction(current: "wubi86_jidian", preferred: "double_pinyin", knownFailed: "rime_ice"),
      .attempt
    )
  }

  // Already-active takes precedence even over a stale known-failed mark for the same id.
  func testIdleAlreadyActiveWinsOverKnownFailed() {
    XCTAssertEqual(
      FamoSchemaSelectionGate.idleAction(current: "rime_ice", preferred: "rime_ice", knownFailed: "rime_ice"),
      .alreadyActive
    )
  }

  // MARK: - markerAfterAttempt

  // Failed select → remember the attempted id (so the idle guard backs off next key).
  func testMarkerRemembersFailedPreferred() {
    XCTAssertEqual(
      FamoSchemaSelectionGate.markerAfterAttempt(preferred: "rime_ice", selected: false),
      "rime_ice"
    )
  }

  // Successful select → clear any mark (config is now consistent).
  func testMarkerClearsOnSuccess() {
    XCTAssertNil(
      FamoSchemaSelectionGate.markerAfterAttempt(preferred: "rime_ice", selected: true)
    )
  }

  // MARK: - sequence (fail → back off → config change re-attempts → success clears)

  func testFailThenBackoffThenConfigChangeReattempts() {
    // 1. attempt rime_ice, it fails → marker = rime_ice
    var marker = FamoSchemaSelectionGate.markerAfterAttempt(preferred: "rime_ice", selected: false)
    XCTAssertEqual(marker, "rime_ice")
    // 2. same preferred next idle key → back off, no librime call
    XCTAssertEqual(
      FamoSchemaSelectionGate.idleAction(current: "wubi86_jidian", preferred: "rime_ice", knownFailed: marker),
      .skipKnownFailed
    )
    // 3. user switches preferred to double_pinyin (config change) → attempt again
    XCTAssertEqual(
      FamoSchemaSelectionGate.idleAction(current: "wubi86_jidian", preferred: "double_pinyin", knownFailed: marker),
      .attempt
    )
    // 4. that attempt succeeds → marker cleared
    marker = FamoSchemaSelectionGate.markerAfterAttempt(preferred: "double_pinyin", selected: true)
    XCTAssertNil(marker)
  }
}
