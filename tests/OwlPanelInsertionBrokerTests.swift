import XCTest
@testable import Owltype

final class OwlPanelInsertionBrokerTests: XCTestCase {
  func testRestoreFocusReactivatesCapturedHostOnce() {
    var activations = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: { activations += 1 }, isRestored: { true })
    }, pasteboardWrite: { _ in XCTFail("no copy"); return false })
    broker.capture()
    broker.restoreFocus()
    broker.restoreFocus()
    XCTAssertEqual(activations, 1)
  }

  func testNoFrontmostMeansRestoreIsNoop() {
    let broker = OwlPanelInsertionBroker(captureFrontmost: { nil })
    broker.capture()
    broker.restoreFocus()
  }

  func testDropSkipsRestore() {
    var activations = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: { activations += 1 }, isRestored: { true })
    })
    broker.capture()
    broker.drop()
    broker.restoreFocus()
    XCTAssertEqual(activations, 0)
  }

  func testDeliverRestoresBeforeInserting() {
    var events: [String] = []
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: { events.append("restore") }, isRestored: { true })
    }, pasteboardWrite: { _ in XCTFail("no copy"); return false })
    broker.capture()
    broker.restoreAndDeliver(.init(text: "你好"), host: { result, completion in
      events.append(result.text); completion(.attemptedUnverified)
    }, isPending: { true }, completion: { XCTAssertEqual($0, .attemptedUnverified) })
    XCTAssertEqual(events, ["restore", "你好"])
  }

  func testNoHostRetainsTextWithoutAutomaticCopy() {
    var copied: [String] = []
    let invocation = OwlTemplateInvocation(content: .plainText("SSRN\n正文"),
      broker: OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { copied.append($0); return true }), deliver: nil)
    var presentations = 0
    invocation.start { _ in presentations += 1 }
    XCTAssertEqual(invocation.outcome, .notAttempted(.missingHost))
    XCTAssertEqual(invocation.retainedResult?.text, "SSRN\n正文")
    XCTAssertEqual(presentations, 1)
    XCTAssertTrue(copied.isEmpty)
    XCTAssertTrue(invocation.copyResult())
    XCTAssertEqual(copied, ["SSRN\n正文"])
  }

  func testPickerTransfersOriginalHostThroughFillWithoutRecapture() {
    var events: [String] = []
    var captures = 0
    let picker = OwlPanelInsertionBroker(captureFrontmost: {
      captures += 1
      return .init(restore: { events.append("original host") }, isRestored: { true })
    }, pasteboardWrite: { _ in XCTFail("must not copy"); return false })
    picker.capture()
    let invocation = OwlTemplateInvocation(
      content: .prompt(OwlPromptEntry(code: "a", title: "A", body: "{{value}}")),
      broker: picker.transferCapture(), deliver: { events.append($0.text); return .confirmed })
    invocation.start { _ in events.append("fill shown") }
    picker.restoreFocus()
    XCTAssertEqual(events, ["fill shown"])
    invocation.confirm(values: ["value": "final\ntext"])
    XCTAssertEqual(events, ["fill shown", "original host", "final\ntext"])
    XCTAssertEqual(captures, 1)
  }

  func testReentrantDeliveryCannotSubmitTwice() {
    var count = 0
    var invocation: OwlTemplateInvocation!
    invocation = OwlTemplateInvocation(content: .plainText("text"),
      broker: OwlPanelInsertionBroker(captureFrontmost: { nil }), deliver: { _ in
        count += 1
        XCTAssertFalse(invocation.confirm(values: [:]))
        invocation.cancel(.windowClosed) // an in-progress write cannot be undone
        return .attemptedUnverified
      })
    invocation.start { _ in }
    XCTAssertEqual(count, 1)
    XCTAssertEqual(invocation.outcome, .attemptedUnverified)
  }

  func testActivationRequestAloneDoesNotPermitInsertion() {
    var writes = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: {}, isRestored: { false })
    }, pasteboardWrite: { _ in XCTFail("no copy"); return false }, schedule: { _, work in work() })
    broker.capture()
    let invocation = OwlTemplateInvocation(content: .plainText("retained"), broker: broker,
      deliver: { _ in writes += 1; return .confirmed })
    invocation.start { _ in }
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(invocation.outcome, .notAttempted(.focusNotRestored))
    XCTAssertEqual(invocation.retainedResult?.text, "retained")
  }

  func testCancelDuringRestorationPreventsLaterCallbackDelivery() {
    var queue: [() -> Void] = []
    var restored = false
    var writes = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: {}, isRestored: { restored })
    }, schedule: { _, work in queue.append(work) })
    broker.capture()
    let invocation = OwlTemplateInvocation(content: .plainText("text"), broker: broker,
      deliver: { _ in writes += 1; return .confirmed })
    invocation.start { _ in XCTFail("cancelled restoration must not present") }
    XCTAssertFalse(invocation.confirm(values: [:]))
    invocation.cancel(.replaced, restoreFocus: false)
    restored = true
    queue.removeFirst()()
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(invocation.state, .cancelled(.replaced))
  }

  func testRestorationRechecksTargetAndCanFinishOnlyOnce() {
    var queue: [() -> Void] = []
    var restored = false
    var writes = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: {}, isRestored: { restored })
    }, schedule: { _, work in queue.append(work) })
    broker.capture()
    let invocation = OwlTemplateInvocation(content: .plainText("text"), broker: broker,
      deliver: { _ in writes += 1; return .attemptedUnverified })
    invocation.start { _ in }
    XCTAssertEqual(writes, 0)
    restored = true
    let callback = queue.removeFirst()
    callback()
    callback()
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(invocation.outcome, .attemptedUnverified)
  }
  func testCancellationDuringHostReadinessDoesNotDispatch() {
    var pending = true
    var writes = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: {}, isRestored: { true })
    })
    broker.capture()
    broker.restoreAndDeliver(.init(text: "retained"), host: { _, _ in writes += 1 },
      isHostReady: { pending = false; return true }, isPending: { pending },
      completion: { _ in XCTFail("cancelled request has no completion") })
    XCTAssertEqual(writes, 0)
  }

  func testAppActivationWaitsForOriginalFieldReadiness() {
    var queue: [() -> Void] = []
    var fieldReady = false
    var writes = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: {}, isRestored: { true })
    }, schedule: { _, work in queue.append(work) })
    broker.capture()
    let invocation = OwlTemplateInvocation(content: .plainText("text"), broker: broker,
      deliver: { _ in writes += 1; return .confirmed }, isHostReady: { fieldReady })
    invocation.start { _ in XCTFail("no result until ready") }
    XCTAssertEqual(writes, 0)
    fieldReady = true
    queue.removeFirst()()
    XCTAssertEqual(writes, 1)
  }

  // #331: an application that came back but whose field never verified was reported as a focus
  // failure. The host now refuses on its own terms, without writing.
  func testRestoredApplicationReportsTheHostsOwnRefusal() {
    var queue: [() -> Void] = []
    var attempts = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: {}, isRestored: { true })
    }, pasteboardWrite: { _ in XCTFail("no copy"); return false }, schedule: { _, work in queue.append(work) })
    broker.capture()
    let invocation = OwlTemplateInvocation(content: .plainText("text"), broker: broker,
      deliver: { _ in attempts += 1; return .notAttempted(.targetChanged) }, isHostReady: { false })
    invocation.start { _ in }
    while !queue.isEmpty { queue.removeFirst()() }
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(invocation.outcome, .notAttempted(.targetChanged))
  }
}
