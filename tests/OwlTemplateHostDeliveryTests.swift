import XCTest
@testable import Owltype

@MainActor
final class OwlTemplateHostDeliveryTests: XCTestCase {
  private final class Host {
    var text: NSString = "左;;a右"
    var marked = NSRange(location: 1, length: 3)
    var selection = NSRange(location: 4, length: 0)
    var presentationFocused = false
    var beforeMove: (() -> Void)?
    var current = true
    var writable = true
    var acceptsMove = true
    var acceptsText = true
    var writes: [(String, NSRange?)] = []
    var moves = 0
    var epoch: UInt64 = 0
    var onWrite: (() -> Void)?
    var access: OwlTemplateHostDelivery.Access {
      .init(rejection: { _ in self.current ? nil : .targetChanged }, rangeIsCurrent: { self.current },
        revision: { self.epoch }, selection: { self.selection }, marked: { self.marked },
        text: { range in
          guard OwlTemplateCursorPlacement.valid(range), NSMaxRange(range) <= self.text.length else { return nil }
          return self.text.substring(with: range)
        }, insert: { text, explicit in
          self.writes.append((text, explicit))
          if self.acceptsText {
            let replacement = explicit ?? (self.marked.location == NSNotFound ? self.selection : self.marked)
            self.text = self.text.replacingCharacters(in: replacement, with: text) as NSString
            self.marked = NSRange(location: NSNotFound, length: 0)
            self.selection = NSRange(location: replacement.location + text.utf16.count, length: 0)
          }
          self.onWrite?()
        }, canReplace: { self.writable }, move: { range, inserted, _ in
          self.beforeMove?()
          guard OwlTemplateCursorPlacement.selectionIsAtEnd(self.selection, inserted: inserted),
            OwlTemplateCursorPlacement.isHostBoundary(range.location, in: self.text as String,
              startsAtDocumentStart: true) else { return false }
          if range == self.selection { return true }
          self.moves += 1
          if self.acceptsMove { self.selection = range }
          return self.acceptsMove
        }, isPresentationFocused: { self.presentationFocused })
    }
    func source(_ original: String = ";;ab\n", valid: @escaping () -> Bool = { true }) -> OwlTemplateHostDelivery.AutomaticSource {
      .init(originalInput: original, markedRange: marked, markedText: text.substring(with: marked), isValid: valid)
    }
  }

  func testMarkedCandidateUsesMarkedStartEvenWithCaretInside() {
    let host = Host(); host.selection = NSRange(location: 2, length: 0)
    let delivery = OwlTemplateHostDelivery(access: host.access)
    XCTAssertEqual(delivery.deliver(.init(text: "中😀尾", cursorOffset: 3)), .confirmedWithCursor(.positioned))
    XCTAssertEqual(host.text as String, "左中😀尾右")
    XCTAssertEqual(host.selection, NSRange(location: 4, length: 0))
    XCTAssertEqual(host.writes.count, 1); XCTAssertEqual(host.moves, 1)
    _ = delivery.deliver(.init(text: "重复", cursorOffset: 0))
    XCTAssertEqual(host.writes.count, 1)
  }

  /// 2026-10-29 live (candidate cb9314f, TextEdit, all three entries): the host could not answer
  /// accessibility in the same turn as the insert, so every readback failed and the cursor stayed at the end.
  func testVerificationWaitsUntilTheHostHasProcessedTheInsert() {
    let host = Host(); host.marked = NSRange(location: NSNotFound, length: 0); host.selection = NSRange(location: 1, length: 0)
    var settled: [() -> Void] = []
    var access = host.access
    let readable = access.text
    var hostBusy = false
    access.text = { hostBusy ? nil : readable($0) }
    access.settle = { settled.append($0) }
    host.onWrite = { hostBusy = true }
    let delivery = OwlTemplateHostDelivery(access: access)
    delivery.endImmediateDelivery()
    var outcomes: [OwlTemplateDeliveryOutcome] = []
    delivery.deliver(.init(text: "前后", cursorOffset: 1)) { outcomes.append($0) }
    XCTAssertEqual(outcomes, [], "nothing is reported while the host is still processing the insert")
    XCTAssertEqual(host.writes.count, 1)
    hostBusy = false
    settled.removeFirst()()
    XCTAssertEqual(outcomes, [.confirmedWithCursor(.positioned)])
    XCTAssertEqual(host.text as String, "左前后;;a右")
    XCTAssertEqual(host.selection, NSRange(location: 2, length: 0))
    XCTAssertEqual(host.writes.count, 1)
  }

  /// PR #337 review: a template without parameters is delivered inside the key event. Deferring its
  /// verification ended the active-session exception it relies on, so it reported unverified.
  func testImmediateDeliveryVerifiesInTheSameTurn() {
    let host = Host(); host.marked = NSRange(location: NSNotFound, length: 0); host.selection = NSRange(location: 1, length: 0)
    var access = host.access
    access.settle = { _ in XCTFail("an immediate delivery does not wait") }
    let delivery = OwlTemplateHostDelivery(access: access)
    var outcomes: [OwlTemplateDeliveryOutcome] = []
    delivery.deliver(.init(text: "前后", cursorOffset: 1)) { outcomes.append($0) }
    XCTAssertEqual(outcomes, [.confirmedWithCursor(.positioned)])
    XCTAssertEqual(host.writes.count, 1)
  }

  /// PR #344 review: agent text carried no cursor offset, so the delivery never captured an origin
  /// and every deliver_text into a readable field came back unverified.
  func testAgentTextIsReadBackAndVerified() {
    for (result, expected) in [(OwlAgentLiveDeliveryHost.deliveryResult("你好😀"), OwlTemplateDeliveryOutcome.confirmedWithCursor(.positioned)),
                               (OwlTemplateInvocation.Result(text: "你好😀"), .attemptedUnverified)] {
      let host = Host(); host.marked = NSRange(location: NSNotFound, length: 0); host.selection = NSRange(location: 1, length: 0)
      let delivery = OwlTemplateHostDelivery(access: host.access)
      delivery.endImmediateDelivery()
      XCTAssertEqual(delivery.deliver(result), expected)
      XCTAssertEqual(host.text as String, "左你好😀;;a右")
      XCTAssertEqual(host.writes.count, 1)
      XCTAssertEqual(host.moves, 0, "the caret is already after the text")
    }
    XCTAssertEqual(OwlAgentDeliveryCoordinator.status(for: .confirmedWithCursor(.positioned), targetQuit: false), .delivered(verified: true))
  }

  func testReactivatedSessionMustStillProveTheSameField() {
    for sameField in [true, false] {
      let host = Host(); host.marked = NSRange(location: NSNotFound, length: 0); host.selection = NSRange(location: 1, length: 0)
      var access = host.access
      var reactivated = false
      access.rejection = { _ in reactivated && !sameField ? .targetChanged : nil }
      access.settle = { next in host.epoch += 1; reactivated = true; next() }
      let delivery = OwlTemplateHostDelivery(access: access)
      delivery.endImmediateDelivery()
      XCTAssertEqual(delivery.deliver(.init(text: "前后", cursorOffset: 1)),
                     sameField ? .confirmedWithCursor(.positioned) : .attemptedUnverified)
      XCTAssertEqual(host.writes.count, 1)
    }
  }

  func testLateDuplicateReadbackCannotMoveTheCursorAgain() {
    let host = Host()
    var callbacks: [() -> Void] = []
    var access = host.access
    access.settle = { callbacks.append($0) }
    let delivery = OwlTemplateHostDelivery(access: access)
    delivery.endImmediateDelivery()
    var completions = 0
    delivery.deliver(.init(text: "正文", cursorOffset: 1)) { _ in completions += 1 }
    let callback = callbacks.removeFirst()
    callback()
    host.selection = NSRange(location: 3, length: 0)
    callback()
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(host.moves, 1, "a late duplicate receipt cannot repeat the cursor effect")
    XCTAssertEqual(host.selection, NSRange(location: 3, length: 0))
    XCTAssertEqual(host.writes.count, 1)
  }

  func testPlacementFailureKeepsCompleteTextAndDoesNotRepeatIt() {
    let host = Host(); host.acceptsMove = false
    let delivery = OwlTemplateHostDelivery(access: host.access)
    XCTAssertEqual(delivery.deliver(.init(text: "正文", cursorOffset: 0)), .confirmedWithCursor(.leftAtEnd))
    XCTAssertEqual(host.text as String, "左正文右")
    XCTAssertEqual(host.writes.count, 1)
    XCTAssertFalse(OwlTemplateDeliveryOutcome.confirmedWithCursor(.leftAtEnd).finishesPresentation)
    XCTAssertTrue(OwlTemplateDeliveryOutcome.confirmedWithCursor(.leftAtEnd).keepsHostFocus)
  }

  func testReadbackFailureNeverMovesOrRepeats() {
    let host = Host(); host.acceptsText = false
    let delivery = OwlTemplateHostDelivery(access: host.access)
    XCTAssertEqual(delivery.deliver(.init(text: "正文", cursorOffset: 1)), .attemptedUnverified)
    XCTAssertEqual(host.writes.count, 1); XCTAssertEqual(host.moves, 0)
  }

  func testVerifiedCommittedTriggerIsPreservedAndReplacedWithoutIMKRanges() {
    let host = Host()
    host.text = "左;;ab\n右"
    host.marked = NSRange(location: NSNotFound, length: 0)
    host.selection = NSRange(location: 6, length: 0)
    let source = OwlTemplateHostDelivery.AutomaticSource(originalInput: ";;ab\n",
      markedRange: NSRange(location: 1, length: 5), markedText: ";;ab\n", isValid: { true }, committed: true)
    let delivery = OwlTemplateHostDelivery(access: host.access, automaticSource: source)
    XCTAssertEqual(delivery.prepareForPresentation(), .ready)
    XCTAssertEqual(host.writes.count, 0, "the host already owns the complete original input")
    XCTAssertEqual(delivery.deliver(.init(text: "中😀尾", cursorOffset: 3)), .confirmedWithCursor(.positioned))
    XCTAssertEqual(host.text as String, "左中😀尾右")
    XCTAssertEqual(host.selection, NSRange(location: 4, length: 0))
    XCTAssertEqual(host.writes.count, 1)
  }

  func testExpandedResultLargerThanRequestLimitStillWritesOnce() {
    let host = Host()
    let delivery = OwlTemplateHostDelivery(access: host.access)
    let text = String(repeating: "x", count: 5 * 1024 * 1024)
    XCTAssertEqual(delivery.deliver(.init(text: text)), .attemptedUnverified)
    XCTAssertEqual(host.writes.count, 1)
    XCTAssertEqual(host.text.length, text.utf16.count + 2)
    XCTAssertEqual(delivery.deliver(.init(text: "again")), .notAttempted(.targetChanged))
    XCTAssertEqual(host.writes.count, 1)
  }

  func testAutomaticPreparationPreservesCompleteOriginalThenReplacesItsRangeOnce() {
    let host = Host()
    let delivery = OwlTemplateHostDelivery(access: host.access, automaticSource: host.source())
    XCTAssertEqual(delivery.prepareForPresentation(), .ready)
    XCTAssertEqual(delivery.prepareForPresentation(), .ready)
    XCTAssertEqual(host.text as String, "左;;ab\n右")
    XCTAssertEqual(host.writes.count, 1)
    delivery.endImmediateDelivery()
    host.presentationFocused = true
    delivery.hostWillDeactivate(); delivery.hostDidActivate()
    XCTAssertEqual(delivery.deliver(.init(text: "参数😀\n", cursorOffset: 2)), .confirmedWithCursor(.positioned))
    XCTAssertEqual(host.text as String, "左参数😀\n右")
    XCTAssertEqual(host.writes.count, 2)
    XCTAssertEqual(host.writes.last?.1, NSRange(location: 1, length: 5))
  }

  func testDeactivationWithoutBoundPresentationInvalidatesOriginalTicket() {
    let host = Host()
    let delivery = OwlTemplateHostDelivery(access: host.access, automaticSource: host.source())
    XCTAssertEqual(delivery.prepareForPresentation(), .ready)
    delivery.hostWillDeactivate(); delivery.hostDidActivate()
    XCTAssertFalse(delivery.mayRestoreFocus())
    XCTAssertEqual(delivery.deliver(.init(text: "不能写")), .notAttempted(.targetChanged))
    XCTAssertEqual(host.writes.count, 1)
  }

  func testSelectionChangeBeforeMoveIsNotOverwritten() {
    let host = Host()
    host.beforeMove = { host.selection = NSRange(location: 0, length: 0) }
    let delivery = OwlTemplateHostDelivery(access: host.access)
    XCTAssertEqual(delivery.deliver(.init(text: "正文", cursorOffset: 1)), .confirmedWithCursor(.positionUnverified))
    XCTAssertEqual(host.selection, NSRange(location: 0, length: 0))
    XCTAssertEqual(host.moves, 0); XCTAssertEqual(host.writes.count, 1)
  }

  func testEndMarkerStillValidatesHostSuffixAndDoesNotMutateSelection() {
    for suffix in ["右", "\u{301}"] {
      let host = Host(); host.text = ("左;;a" + suffix) as NSString
      let delivery = OwlTemplateHostDelivery(access: host.access)
      XCTAssertEqual(delivery.deliver(.init(text: "e", cursorOffset: 1)),
        .confirmedWithCursor(suffix == "右" ? .positioned : .leftAtEnd))
      XCTAssertEqual(host.moves, 0); XCTAssertEqual(host.writes.count, 1)
    }
  }

  func testCancelAfterPreparationHasNoRecoveryWrite() {
    let host = Host()
    let delivery = OwlTemplateHostDelivery(access: host.access, automaticSource: host.source())
    XCTAssertEqual(delivery.prepareForPresentation(), .ready)
    delivery.invalidate()
    XCTAssertEqual(delivery.deliver(.init(text: "结果")), .notAttempted(.targetChanged))
    XCTAssertEqual(host.writes.count, 1)
    XCTAssertEqual(host.text as String, "左;;ab\n右")
  }

  func testOriginalPreservationWaitsBeforePresentingAndDiscardsCancelledReceipt() {
    for cancel in [false, true] {
      let host = Host()
      var settled: [() -> Void] = []
      var access = host.access
      access.settle = { settled.append($0) }
      let delivery = OwlTemplateHostDelivery(access: access, automaticSource: host.source())
      var entry = OwlTemplateEntry(title: "参数", body: "{argument name=x}")
      entry.bodyType = .template
      let invocation = OwlTemplateInvocation(content: .template(entry), broker: OwlPanelInsertionBroker(),
        delivery: delivery, prepareAutomaticSource: true)
      var presentations = 0
      invocation.start { _ in presentations += 1 }
      XCTAssertEqual(presentations, 0)
      XCTAssertEqual(host.text as String, "左;;ab\n右")
      if cancel { invocation.cancel() }
      let callback = settled.removeFirst()
      callback()
      callback()
      XCTAssertEqual(presentations, cancel ? 0 : 1)
      XCTAssertEqual(host.writes.count, 1)
    }
  }

  func testOriginalRangeEditAndRuntimeInvalidationRefuseReplacement() {
    for edit in [true, false] {
      let host = Host(); var valid = true
      let delivery = OwlTemplateHostDelivery(access: host.access, automaticSource: host.source(valid: { valid }))
      XCTAssertEqual(delivery.prepareForPresentation(), .ready)
      if edit { host.text = "左different右" } else { valid = false }
      XCTAssertEqual(delivery.deliver(.init(text: "不能写")), .notAttempted(.targetChanged))
      XCTAssertEqual(host.writes.count, 1)
    }
  }

  func testUncertainPreservationIsNotRetriedOrMisreportedAsResultDelivery() {
    let host = Host(); host.acceptsText = false
    let delivery = OwlTemplateHostDelivery(access: host.access, automaticSource: host.source())
    XCTAssertEqual(delivery.prepareForPresentation(), .originalAttemptedUnverified)
    XCTAssertEqual(delivery.prepareForPresentation(), .originalAttemptedUnverified)
    XCTAssertEqual(delivery.deliver(.init(text: "结果")), .notAttempted(.targetChanged))
    XCTAssertEqual(host.writes.count, 1)
  }

  func testSynchronousImmediateResultDoesNotFirstCommitOriginal() {
    let host = Host()
    let delivery = OwlTemplateHostDelivery(access: host.access, automaticSource: host.source())
    XCTAssertEqual(delivery.deliver(.init(text: "直接结果\n")), .confirmed)
    XCTAssertEqual(host.text as String, "左直接结果\n右")
    XCTAssertEqual(host.writes.count, 1)
  }

  func testReentrantPreservationAndResultDispatchHaveIndependentSingleSlots() {
    let host = Host()
    let delivery = OwlTemplateHostDelivery(access: host.access, automaticSource: host.source())
    host.onWrite = { _ = delivery.prepareForPresentation() }
    XCTAssertEqual(delivery.prepareForPresentation(), .ready)
    host.onWrite = { _ = delivery.deliver(.init(text: "nested")) }
    XCTAssertEqual(delivery.deliver(.init(text: "done")), .confirmed)
    XCTAssertEqual(host.writes.count, 2)
    XCTAssertEqual(host.text as String, "左done右")
  }

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
}
