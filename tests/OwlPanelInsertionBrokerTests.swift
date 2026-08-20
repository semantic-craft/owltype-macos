//
//  OwlPanelInsertionBrokerTests.swift
//  OwltypeTests — panel focus capture / restore choreography (C4)
//
//  Locks the shared broker the quick-send / prompt-fill panels use to hand focus back to the host
//  before inserting: capture → restore-first → idempotent clear → drop (skip) → pasteboard fallback.
//  Frontmost read + pasteboard write injected as spies, so no live NSWorkspace / NSPasteboard.
//

import XCTest
@testable import Owltype

final class OwlPanelInsertionBrokerTests: XCTestCase {

  func testRestoreFocusReactivatesCapturedHostOnce() {
    var activateCount = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: { { activateCount += 1 } },
                                          pasteboardWrite: { _ in })
    broker.capture()
    broker.restoreFocus()
    XCTAssertEqual(activateCount, 1)
    broker.restoreFocus()   // idempotent — the captured host was already cleared
    XCTAssertEqual(activateCount, 1, "a second restore must not re-activate")
  }

  func testNoFrontmostMeansRestoreIsNoop() {
    var activateCount = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: { nil },   // nothing frontmost
                                          pasteboardWrite: { _ in })
    broker.capture()
    broker.restoreFocus()
    XCTAssertEqual(activateCount, 0)
  }

  func testDropSkipsRestore() {
    var activateCount = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: { { activateCount += 1 } },
                                          pasteboardWrite: { _ in })
    broker.capture()
    broker.drop()
    broker.restoreFocus()
    XCTAssertEqual(activateCount, 0, "drop() forgets the host so restore does nothing")
  }

  func testDeliverRestoresBeforeInserting() {
    var events: [String] = []
    let broker = OwlPanelInsertionBroker(captureFrontmost: { { events.append("restore") } },
                                          pasteboardWrite: { _ in events.append("pasteboard") })
    broker.capture()
    broker.restoreAndDeliver("你好", host: { _ in events.append("host") })
    XCTAssertEqual(events, ["restore", "host"], "focus must be restored before the host inserts")
  }

  func testDeliverFallsBackToPasteboardWithoutHost() {
    var events: [String] = []
    var pasted: String?
    let broker = OwlPanelInsertionBroker(captureFrontmost: { { events.append("restore") } },
                                          pasteboardWrite: { pasted = $0; events.append("pasteboard") })
    broker.capture()
    broker.restoreAndDeliver("SSRN", host: nil)
    XCTAssertEqual(events, ["restore", "pasteboard"])
    XCTAssertEqual(pasted, "SSRN")
  }
}
