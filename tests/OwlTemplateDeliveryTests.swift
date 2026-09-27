import AppKit
import Combine
import XCTest
@testable import Owltype

@MainActor
final class OwlTemplateDeliveryTests: XCTestCase {
  private func entry(_ body: String) -> OwlTemplateEntry {
    var entry = OwlTemplateEntry(title: "合成预览", body: body)
    entry.bodyType = .template
    return entry
  }

  private func context(_ text: String = "材料A") -> OwlTemplateEngine.FrozenContext {
    .init(clipboard: .text(text), temporal: .init(date: Date(timeIntervalSince1970: 0),
      timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"),
      calendar: Calendar(identifier: .gregorian)))
  }

  func testExplicitPreviewPresentsNoParameterDynamicTemplatesWithoutDelivery() {
    for body in ["{clipboard}", "{date format=yyyy-MM-dd}", "{date format=yyyy-MM-dd}/{clipboard}"] {
      var reads = 0
      var delivered: [OwlTemplateInvocation.Result] = []
      var shown: OwlTemplateInvocation?
      var source = context()
      let invocation = OwlTemplateInvocation(content: .template(entry(body)), broker: OwlPanelInsertionBroker(),
        deliver: { delivered.append($0); return .confirmed }, intent: .resultPreview,
        captureContext: { _ in reads += 1; return source })
      XCTAssertEqual(reads, 0)
      invocation.start { shown = $0 }
      XCTAssertTrue(shown === invocation)
      XCTAssertEqual(reads, 1)
      XCTAssertTrue(delivered.isEmpty)
      let expected = invocation.preview(values: [:])
      source = context("材料B")
      for _ in 0..<3 { XCTAssertEqual(invocation.preview(values: [:]), expected) }
      XCTAssertTrue(invocation.confirm(values: [:]))
      XCTAssertEqual(delivered, [expected])
      XCTAssertEqual(reads, 1)
    }
  }

  func testInsertIntentStillImmediatelyDeliversNoParameterTemplate() {
    var delivered: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(entry("{clipboard}")), broker: OwlPanelInsertionBroker(),
      deliver: { delivered.append($0.text); return .confirmed }, captureContext: { _ in self.context() })
    invocation.start { _ in XCTFail("insert intent should not force preview") }
    XCTAssertEqual(delivered, ["材料A"])
  }

  func testPlainTextResultPreviewNeverCapturesContext() {
    var shown = 0
    let text = " \t{clipboard}\n{date}🙂  "
    let invocation = OwlTemplateInvocation(content: .plainText(text), broker: OwlPanelInsertionBroker(),
      deliver: nil, intent: .resultPreview, captureContext: { _ in XCTFail("plain text"); return .init() })
    invocation.start { _ in shown += 1 }
    XCTAssertEqual(shown, 1)
    XCTAssertEqual(invocation.preview(values: [:]).text, text)
    XCTAssertEqual(invocation.state, .awaitingConfirmation)
  }

  func testParseErrorsNeverReadAnyContextOrPermitConfirmation() {
    for body in ["{clipboard}{argument name=}", "{date format=yyyy-MM-dd}{argument wat=bad}"] {
      var reads = 0
      var writes = 0
      let invocation = OwlTemplateInvocation(content: .template(entry(body)), broker: OwlPanelInsertionBroker(),
        deliver: { _ in writes += 1; return .confirmed }, intent: .resultPreview,
        captureContext: { _ in reads += 1; return self.context() })
      XCTAssertTrue(invocation.parsed.diagnostics.contains { $0.severity == .error })
      invocation.start { _ in }
      invocation.prepareForResultPreview()
      XCTAssertFalse(invocation.confirm(values: [:]))
      XCTAssertEqual(reads, 0)
      XCTAssertEqual(writes, 0)
    }
  }

  func testTrailingTextBelongsToPreviewDeliveryRetentionAndExplicitCopy() {
    let suffix = "\n\t{clipboard}"
    var reads = 0
    var dispatched: [OwlTemplateInvocation.Result] = []
    var copies: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(entry("{clipboard}/{argument name=目的}")),
      broker: OwlPanelInsertionBroker(pasteboardWrite: { copies.append($0); return true }),
      deliver: { dispatched.append($0); return .attemptedUnverified }, trailingText: suffix, intent: .resultPreview,
      captureContext: { _ in reads += 1; return self.context() })
    invocation.start { _ in }
    let values = ["n:目的": "解释"]
    let expected = invocation.preview(values: values)
    XCTAssertEqual(expected.text, "材料A/解释" + suffix)
    XCTAssertNil(expected.cursorOffset)
    XCTAssertFalse(invocation.copyResult(), "preview is not an implicit clipboard write")
    XCTAssertTrue(invocation.confirm(values: values))
    XCTAssertEqual(dispatched, [expected])
    XCTAssertEqual(invocation.retainedResult, expected)
    XCTAssertTrue(copies.isEmpty)
    XCTAssertTrue(invocation.copyResult())
    XCTAssertEqual(copies, [expected.text])
    XCTAssertEqual(reads, 1)
    XCTAssertFalse(invocation.confirm(values: values))
    XCTAssertEqual(dispatched.count, 1)
  }

  func testPlainSuffixIsNotParsedOrTrimmed() {
    var results: [String] = []
    let invocation = OwlTemplateInvocation(content: .plainText("body"), broker: OwlPanelInsertionBroker(),
      deliver: { results.append($0.text); return .confirmed }, trailingText: "\t\n{date}  ",
      captureContext: { _ in XCTFail("suffix must not parse"); return .init() })
    invocation.start { _ in XCTFail("no parameters") }
    XCTAssertEqual(results, ["body\t\n{date}  "])
  }

  func testUnverifiableOrChangedTargetRetainsResultWithoutRetryOrCopy() {
    for reason in [OwlTemplateDeliveryOutcome.Reason.targetChanged, .unverifiableTarget, .secureInput, .missingHost] {
      var attempts = 0
      var presentations = 0
      let invocation = OwlTemplateInvocation(content: .plainText("result"),
        broker: OwlPanelInsertionBroker(pasteboardWrite: { _ in XCTFail("no implicit copy"); return false }),
        deliver: { _ in attempts += 1; return .notAttempted(reason) })
      invocation.start { _ in presentations += 1 }
      XCTAssertEqual(invocation.outcome, .notAttempted(reason))
      XCTAssertEqual(invocation.retainedResult?.text, "result")
      invocation.start { _ in XCTFail("must not retry") }
      XCTAssertFalse(invocation.confirm(values: [:]))
      XCTAssertEqual(attempts, 1)
      XCTAssertEqual(presentations, 1)
    }
  }

  func testExplicitCopyFailureLeavesResultAndReportsFailure() {
    let invocation = OwlTemplateInvocation(content: .plainText("result"),
      broker: OwlPanelInsertionBroker(pasteboardWrite: { _ in false }), deliver: nil)
    invocation.start { _ in }
    let model = OwlPromptFillModel(invocation: invocation)
    model.copyResult()
    XCTAssertEqual(model.copyStatus, "复制失败，结果仍保留。请重试复制。")
    XCTAssertEqual(model.filledBody, "result")
    XCTAssertFalse(model.canConfirm)
  }

  func testCancelledPreviewNeverCopiesAndNewInvocationCapturesAgain() {
    var reads = 0
    var text = "A"
    func make() -> OwlTemplateInvocation {
      OwlTemplateInvocation(content: .template(entry("{clipboard}")),
        broker: OwlPanelInsertionBroker(pasteboardWrite: { _ in XCTFail("no copy"); return false }),
        deliver: { _ in XCTFail("cancelled"); return .confirmed }, intent: .resultPreview,
        captureContext: { _ in reads += 1; return self.context(text) })
    }
    let first = make()
    first.start { _ in }
    first.cancel(.windowClosed)
    XCTAssertFalse(first.copyResult())
    XCTAssertFalse(first.confirm(values: [:]))
    text = "B"
    let second = make()
    second.start { _ in }
    XCTAssertEqual(second.preview(values: [:]).text, "B")
    XCTAssertEqual(reads, 2)
  }
  func testDismissAndCloseReleasePreviewAndRetainedResult() {
    for preview in [true, false] {
      for closesWindow in [true, false] {
        let sheet = OwlPromptFillSheet(showsWindows: false)
        weak var retained: OwlTemplateInvocation?
        autoreleasepool {
          let invocation = OwlTemplateInvocation(content: .plainText("合成敏感结果"), broker: OwlPanelInsertionBroker(),
            deliver: nil, intent: preview ? .resultPreview : .insert)
          retained = invocation
          sheet.begin(invocation: invocation)
          XCTAssertNotNil(sheet.window?.contentView)
          if closesWindow {
            sheet.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: sheet.window))
          } else { sheet.dismissForNewInvocation() }
          XCTAssertNil(sheet.window?.contentView)
        }
        XCTAssertNil(retained, "reused NSWindow must not retain closed invocation/context")
      }
    }
  }

  func testConfirmedAsyncDeliveryReleasesSheetOwnership() {
    let sheet = OwlPromptFillSheet(showsWindows: false)
    var queue: [() -> Void] = []
    var ready = false
    weak var retained: OwlTemplateInvocation?
    autoreleasepool {
      let broker = OwlPanelInsertionBroker(captureFrontmost: {
        .init(restore: {}, isRestored: { ready })
      }, schedule: { _, work in queue.append(work) })
      broker.capture()
      let invocation = OwlTemplateInvocation(content: .plainText("text"), broker: broker, deliver: { _ in .confirmed })
      retained = invocation
      sheet.begin(invocation: invocation)
    }
    XCTAssertNotNil(retained)
    ready = true
    autoreleasepool { queue.removeFirst()() }
    XCTAssertNil(retained)
    XCTAssertNil(sheet.window?.contentView)
  }

  func testStateObserversCannotReenterConfirmationBeforeDispatchGuard() {
    var writes = 0
    let invocation = OwlTemplateInvocation(content: .plainText("text"), broker: OwlPanelInsertionBroker(),
      deliver: { _ in writes += 1; return .confirmed })
    let observation = invocation.stateChanges.sink { state in
      if case .delivering = state { XCTAssertFalse(invocation.confirm(values: [:])) }
    }
    invocation.start { _ in }
    XCTAssertEqual(writes, 1)
    withExtendedLifetime(observation) {}
  }

  func testStateObserverCanCancelBeforeActualDispatch() {
    var writes = 0
    let invocation = OwlTemplateInvocation(content: .plainText("text"), broker: OwlPanelInsertionBroker(),
      deliver: { _ in writes += 1; return .confirmed })
    let observation = invocation.stateChanges.sink { state in
      if case .delivering = state { invocation.cancel(.windowClosed) }
    }
    invocation.start { _ in XCTFail("cancelled") }
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(invocation.state, .cancelled(.windowClosed))
    withExtendedLifetime(observation) {}
  }

  func testCancellationDuringCaptureCannotReopenPresentation() {
    var presentations = 0
    var deliveries = 0
    var invocation: OwlTemplateInvocation!
    invocation = OwlTemplateInvocation(content: .template(entry("{clipboard}")), broker: OwlPanelInsertionBroker(),
      deliver: { _ in deliveries += 1; return .confirmed }, intent: .resultPreview,
      captureContext: { _ in invocation.cancel(.windowClosed); return self.context() })
    invocation.start { _ in presentations += 1 }
    XCTAssertEqual(presentations, 0)
    XCTAssertEqual(deliveries, 0)
    XCTAssertEqual(invocation.state, .cancelled(.windowClosed))
  }

  func testCompletedInvocationCannotClearReentrantNewPreview() {
    let sheet = OwlPromptFillSheet(showsWindows: false)
    let next = OwlTemplateInvocation(content: .plainText("B"), broker: OwlPanelInsertionBroker(),
      deliver: nil, intent: .resultPreview)
    let first = OwlTemplateInvocation(content: .plainText("A"), broker: OwlPanelInsertionBroker(),
      deliver: { _ in .confirmed })
    let observation = first.stateChanges.sink { state in
      if case .completed = state { sheet.begin(invocation: next) }
    }
    sheet.begin(invocation: first)
    XCTAssertEqual(next.state, .awaitingConfirmation)
    XCTAssertNotNil(sheet.window?.contentView)
    XCTAssertTrue(next.confirm(values: [:]))
    XCTAssertEqual(next.retainedResult?.text, "B")
    withExtendedLifetime(observation) {}
    sheet.dismissForNewInvocation()
  }

}
