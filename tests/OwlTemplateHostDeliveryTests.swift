import XCTest
@testable import Owltype

@MainActor
final class OwlTemplateHostDeliveryTests: XCTestCase {
  func testInvocationPreparationRunsOnlyForEditablePresentationAndFinishesOnce() {
    var prepares = 0; var finishes = 0; var writes = 0
    var entry = OwlTemplateEntry(title: "参数", body: "{argument name=x}{cursor}尾")
    entry.bodyType = .template
    let invocation = OwlTemplateInvocation(content: .template(entry), broker: OwlPanelInsertionBroker(),
      deliver: { _ in writes += 1; return .confirmed },
      preparePresentation: { prepares += 1; return .originalAttemptedUnverified }, onFinish: { finishes += 1 })
    invocation.start { _ in }
    invocation.start { _ in XCTFail("twice") }
    XCTAssertEqual(prepares, 1)
    XCTAssertTrue(invocation.confirm(values: ["n:x": "值"]))
    XCTAssertEqual(invocation.outcome, .originalPreservationUnverified)
    XCTAssertEqual(invocation.retainedResult, .init(text: "值尾", cursorOffset: 1))
    XCTAssertEqual(writes, 0); XCTAssertEqual(prepares, 1); XCTAssertEqual(finishes, 1)
    invocation.cancel()
    XCTAssertEqual(finishes, 1)
  }

  // #331: after a template window the host field came back through a new IMK controller, while
  // delivery still compared against the old controller's client and timed out as focusNotRestored.
  func testDeliveryRebindsToTheSessionActivatedForTheSameApplication() throws {
    let old = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    let new = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { old.destroySession(); new.destroySession() }
    let captured = HabitsTextClient(); captured.appID = "com.apple.TextEdit"
    let returned = HabitsTextClient(); returned.appID = "com.apple.TextEdit"
    old.client = captured
    XCTAssertNil(OwlTemplateHostDelivery.rebindTarget(controller: old, client: captured, activated: new,
      bundleID: "com.apple.TextEdit"), "a captured session that is still live is kept")
    old.client = nil
    new.client = returned
    XCTAssertTrue(OwlTemplateHostDelivery.rebindTarget(controller: old, client: captured, activated: new,
      bundleID: "com.apple.TextEdit") === new)
    XCTAssertTrue(OwlTemplateHostDelivery.rebindTarget(controller: nil, client: nil, activated: new,
      bundleID: "com.apple.TextEdit") === new, "a released capture still finds the returned field")
    XCTAssertNil(OwlTemplateHostDelivery.rebindTarget(controller: old, client: captured, activated: new,
      bundleID: "com.google.Chrome"), "never another application's session")
    new.client = nil
    XCTAssertNil(OwlTemplateHostDelivery.rebindTarget(controller: old, client: captured, activated: new,
      bundleID: "com.apple.TextEdit"), "never a deactivated session")
  }

  /// 2026-10-29 live (candidate dfbf8d6, TextEdit): candidate and automatic invocations refused with
  /// unverifiableTarget because the field was read inside the key event, while the host could not answer.
  func testFieldUnreadableDuringKeyEventIsReadAfterIt() {
    var reads = [nil, "field"] as [String?]
    var scheduled: [() -> Void] = []
    var stored: [String] = []
    OwlTemplateHostDelivery.captureOutsideKeyEvent({ reads.removeFirst() }, schedule: { scheduled.append($0) }) {
      stored.append($0)
    }
    XCTAssertEqual(stored, [], "nothing captured while the host is blocked")
    XCTAssertEqual(scheduled.count, 1)
    scheduled.removeFirst()()
    XCTAssertEqual(stored, ["field"])

    var direct: [String] = []
    OwlTemplateHostDelivery.captureOutsideKeyEvent({ "field" }, schedule: { _ in XCTFail("a readable field is not read twice") }) {
      direct.append($0)
    }
    XCTAssertEqual(direct, ["field"])

    var keyEventReads = 0
    OwlTemplateHostDelivery.captureOutsideKeyEvent({ keyEventReads += 1; return "field" },
      deferRead: true, schedule: { scheduled.append($0) }, store: { _ in })
    XCTAssertEqual(keyEventReads, 0, "ordinary key handling never probes AX synchronously")
    scheduled.removeFirst()()
    XCTAssertEqual(keyEventReads, 1)
  }

  func testActivationRegistryFollowsIMKActivation() throws {
    let first = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    let second = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { first.destroySession(); second.destroySession() }
    let client = HabitsTextClient()
    let runtime = NSApp.owlAppDelegate.runtime
    first.activateServer(client)
    XCTAssertTrue(runtime.activatedInputController === first)
    first.deactivateServer(client)
    second.activateServer(client)
    XCTAssertTrue(runtime.activatedInputController === second)
    first.deactivateServer(client)
    XCTAssertTrue(runtime.activatedInputController === second, "a stale deactivation keeps the live session")
    second.deactivateServer(client)
    XCTAssertNil(runtime.activatedInputController)
  }

  // #331: a template candidate left its code as marked text; the parameter window took focus and
  // TextEdit committed the raw `Kyshx` into the document.
  func testTemplateCandidateClearsHostMarkedTextBeforeAnyWindow() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
    let session = FakeEngineSession(pendingCommit: OwlTemplateStore.candidatePrefix + UUID().uuidString + "]验收")
    controller.engineSession = session
    let client = HabitsTextClient(); client.appID = "com.apple.TextEdit"
    controller.client = client
    controller.show(preedit: "Kyshx", selRange: NSRange(location: 0, length: 0), caretPos: 5)
    XCTAssertTrue(client.text.hasMarkedText())
    controller.consumeCommittedText()
    XCTAssertFalse(client.text.hasMarkedText())
    XCTAssertEqual(client.text.string, "", "the raw code never reaches the document")
  }

  func testLiveDeliveryEntrypointsRefuseUnverifiedHostWithoutWrites() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { controller.destroySession() }
    let client = HabitsTextClient(); client.appID = "com.apple.TextEdit"
    let delivery = OwlTemplateHostDelivery(controller: controller, client: client, boundApplication: .current)

    let prepared = expectation(description: "prepareForPresentation")
    delivery.prepareForPresentation { result in
      XCTAssertEqual(result, .ready)
      prepared.fulfill()
    }
    wait(for: [prepared], timeout: 2)

    let first = expectation(description: "first deliver")
    delivery.deliver(.init(text: "结果", cursorOffset: 1)) { outcome in
      XCTAssertEqual(outcome, .notAttempted(.missingHost))
      first.fulfill()
    }
    wait(for: [first], timeout: 2)

    let second = expectation(description: "second deliver")
    delivery.deliver(.init(text: "重复")) { outcome in
      XCTAssertEqual(outcome, .notAttempted(.missingHost))
      second.fulfill()
    }
    wait(for: [second], timeout: 2)
    XCTAssertEqual(client.text.string, "")
  }

  func testLiveAutomaticPrepareForPresentationFailsSafelyWithoutHostField() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { controller.destroySession() }
    let client = HabitsTextClient(); client.appID = "com.apple.TextEdit"
    let source = OwlTemplateHostDelivery.AutomaticSource(
      originalInput: ";;a",
      markedRange: NSRange(location: 0, length: 3),
      markedText: ";;a",
      isValid: { true }
    )
    let delivery = OwlTemplateHostDelivery(
      controller: controller,
      client: client,
      automaticSource: source,
      boundApplication: .current
    )

    let prepared = expectation(description: "automatic prepare")
    delivery.prepareForPresentation { result in
      XCTAssertEqual(result, .originalNotAttempted(.originalNotPreserved))
      prepared.fulfill()
    }
    wait(for: [prepared], timeout: 2)

    delivery.hostWillDeactivate()
    delivery.hostDidActivate()
    delivery.applicationDidActivate(isOriginal: false, isPresentation: false)
    delivery.applicationDidActivate(isOriginal: true, isPresentation: false)
    delivery.invalidate()
    XCTAssertFalse(delivery.isReadyForDelivery())

    let delivered = expectation(description: "deliver after failed prepare")
    delivery.deliver(.init(text: "正文", cursorOffset: 1)) { outcome in
      XCTAssertEqual(outcome, .notAttempted(.targetChanged))
      delivered.fulfill()
    }
    wait(for: [delivered], timeout: 2)
    XCTAssertEqual(client.text.string, "")
  }
}
