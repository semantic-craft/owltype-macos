//
//  OwlHostCaretAnchorMemoryTests.swift
//  OwltypeTests — host-scoped last-good caret anchor
//
//  Locks the NEW semantics introduced to stop the candidate panel from opening on another
//  display: the "last known-good caret anchor" belongs to the host app that produced it, and a
//  different host must NOT be able to read it back.
//
//  The bug this pins down: the anchor used to be one process-wide `NSRect` that no lifecycle
//  callback ever reset. WeChat's caret rect is rejected by the B3 cascade, so it fell through to
//  that shared rect — left behind by whatever app typed last — and `OwlFloatingPanelPositioner`
//  faithfully placed the panel on the screen holding it. Two-display setup, WeChat up top, last
//  app down below → candidate bar on the bottom screen.
//
//  The validation cascade itself (`OwlCandidateAnchor`) is covered by OwlCandidateAnchorTests;
//  the last test here is the seam between the two — a foreign host's anchor must not merely be
//  "not preferred", it must be absent, so the cascade goes on to the caller's safe fallback.
//
//  Pure value type: fabricated rects and bundle IDs, no delegate, no IMK client, no NSScreen.
//

import CoreGraphics
import XCTest
@testable import Owltype

final class OwlHostCaretAnchorMemoryTests: XCTestCase {

  private let weChat = "com.tencent.xinWeChat"
  private let editor = "com.apple.TextEdit"

  /// A caret on the built-in display.
  private let anchorOnMainScreen = CGRect(x: 400, y: 300, width: 1, height: 18)
  /// A caret on a second display mounted ABOVE the built-in one (negative-origin coordinate
  /// space is what a real stacked-display arrangement reports).
  private let anchorOnSecondScreen = CGRect(x: 400, y: 1400, width: 1, height: 18)

  // MARK: same host — the fallback still works

  func testRecordedAnchorIsReadableByTheSameHost() {
    var memory = OwlHostCaretAnchorMemory()
    memory.record(anchorOnMainScreen, host: editor)
    XCTAssertEqual(memory.anchor(for: editor), anchorOnMainScreen)
  }

  func testRecordingAgainForTheSameHostUpdatesTheAnchor() {
    var memory = OwlHostCaretAnchorMemory()
    memory.record(anchorOnMainScreen, host: editor)
    memory.record(anchorOnSecondScreen, host: editor)
    XCTAssertEqual(memory.anchor(for: editor), anchorOnSecondScreen,
                   "the same host's newer caret must win")
  }

  func testFreshMemoryHasNothingForAnyHost() {
    let memory = OwlHostCaretAnchorMemory()
    XCTAssertNil(memory.anchor(for: editor))
    XCTAssertNil(memory.anchor(for: nil))
  }

  // MARK: host switch — the regression

  func testAnotherHostCannotReadTheRecordedAnchor() {
    var memory = OwlHostCaretAnchorMemory()
    memory.record(anchorOnSecondScreen, host: editor)
    XCTAssertNil(memory.anchor(for: weChat),
                 "WeChat must not inherit the anchor TextEdit left behind")
  }

  func testSwitchingHostsForgetsThePreviousHostsAnchor() {
    var memory = OwlHostCaretAnchorMemory()
    memory.record(anchorOnSecondScreen, host: editor)
    memory.record(anchorOnMainScreen, host: weChat)
    XCTAssertEqual(memory.anchor(for: weChat), anchorOnMainScreen)
    XCTAssertNil(memory.anchor(for: editor),
                 "single slot: the previous host's anchor is dropped, not kept alongside")
  }

  func testSwitchingAwayAndBackDoesNotResurrectTheOldAnchor() {
    var memory = OwlHostCaretAnchorMemory()
    memory.record(anchorOnSecondScreen, host: editor)
    memory.record(anchorOnMainScreen, host: weChat)
    XCTAssertNil(memory.anchor(for: editor),
                 "returning to a host does not bring its stale caret back")
  }

  // MARK: unnamed hosts

  func testEmptyHostIsTheSameIdentityAsNoHost() {
    // The controller passes `client.bundleIdentifier() ?? currentApp`, and `currentApp` starts
    // as "" — the two spellings of "this client reports no identity" must not disagree.
    var memory = OwlHostCaretAnchorMemory()
    memory.record(anchorOnMainScreen, host: "")
    XCTAssertEqual(memory.anchor(for: nil), anchorOnMainScreen)

    var other = OwlHostCaretAnchorMemory()
    other.record(anchorOnMainScreen, host: nil)
    XCTAssertEqual(other.anchor(for: ""), anchorOnMainScreen)
  }

  func testNamedHostCannotReadAnUnnamedHostsAnchor() {
    var memory = OwlHostCaretAnchorMemory()
    memory.record(anchorOnSecondScreen, host: nil)
    XCTAssertNil(memory.anchor(for: weChat))
  }

  func testUnnamedHostCannotReadANamedHostsAnchor() {
    var memory = OwlHostCaretAnchorMemory()
    memory.record(anchorOnSecondScreen, host: editor)
    XCTAssertNil(memory.anchor(for: nil))
  }

  // MARK: seam with the B3 cascade

  func testForeignHostAnchorDoesNotSurviveTheResolveCascade() {
    // The live shape of the bug, one layer up: two stacked displays, TextEdit typed on the
    // upper one, WeChat now hands back a junk rect. Feeding the cascade the HOST-SCOPED
    // `previous` makes it return nil → the controller falls to `safeFallbackAnchor()`, instead
    // of returning TextEdit's rect and dragging the panel onto the upper screen.
    let builtIn = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let upper = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
    let screens = [builtIn, upper]
    let junkFromWeChat = CGRect.zero

    var memory = OwlHostCaretAnchorMemory()
    memory.record(anchorOnSecondScreen, host: editor)
    XCTAssertTrue(OwlCandidateAnchor.isUsable(anchorOnSecondScreen, screens: screens),
                  "sanity: TextEdit's anchor is a perfectly valid rect — scoping is what excludes it")

    XCTAssertNil(OwlCandidateAnchor.resolve(candidates: [junkFromWeChat],
                                             previous: memory.anchor(for: weChat),
                                             screens: screens),
                 "junk fresh rect + foreign last-good → no anchor, caller uses its safe fallback")

    XCTAssertEqual(OwlCandidateAnchor.resolve(candidates: [junkFromWeChat],
                                               previous: memory.anchor(for: editor),
                                               screens: screens),
                   anchorOnSecondScreen,
                   "same host still gets its last-good rect — the fallback is scoped, not removed")
  }
}
