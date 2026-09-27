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
}
