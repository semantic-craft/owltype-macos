import AppKit
import XCTest
@testable import Owltype

@MainActor
final class OwlDynamicAutomaticTests: XCTestCase {
  private func entry(_ body: String, mode: OwlTemplateEntry.ExpansionMode = .immediate) -> OwlTemplateEntry {
    var entry = OwlTemplateEntry(title: "合成动态自动模板", body: body)
    entry.bodyType = .template
    entry.trigger = ";;dynamic"
    entry.invocationMode = .automatic
    entry.expansionMode = mode
    return entry
  }

  /// Drive the production recognizer, preserving exactly the text that reached its mark branch.
  private func source(_ entry: OwlTemplateEntry, delimiter: String? = nil) throws -> OwlAutomaticExpansionInvocationSource {
    let index = try OwlAutomaticExpansionIndex(entries: [entry])
    let recognizer = OwlAutomaticExpansionRecognizer()
    var marked = ""
    var terminal: OwlAutomaticExpansionRecognizer.Step?
    let characters = Array(entry.trigger ?? "").map(String.init) + (delimiter.map { [$0] } ?? [])
    for text in characters {
      let step = recognizer.consume(.text(text), index: index, canStart: true)
      switch step {
      case .mark(let text): marked = text
      case .invoke: terminal = step
      default: XCTFail("unexpected recognition result: \(step)")
      }
    }
    XCTAssertFalse(recognizer.isRecognizing)
    return try XCTUnwrap(OwlAutomaticExpansionInvocationSource(step: XCTUnwrap(terminal), start: 7, markedText: marked))
  }

  private func context(_ clipboard: String = "中😀e\u{301}") -> OwlTemplateEngine.FrozenContext {
    .init(clipboard: .text(clipboard), temporal: .init(date: Date(timeIntervalSince1970: 0),
      timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"),
      calendar: Calendar(identifier: .gregorian)))
  }

  func testImmediateSourcePreservesTerminalCharacterThatWasNeverMarked() throws {
    let source = try source(entry("{clipboard}"))
    XCTAssertEqual(source.originalInput, ";;dynamic")
    XCTAssertEqual(source.markedText, ";;dynami")
    XCTAssertEqual(source.markedRange, NSRange(location: 7, length: 8))
    XCTAssertEqual(source.trailingText, "")
  }

  func testAllDelimitersRemainRecoverableEvenWhenSuccessfulResultDropsThem() throws {
    for delimiter in [" ", "\t", "\n", ",", ".", "?", "!", ":", "，", "。", "？", "！", "："] {
      for mode in [OwlTemplateEntry.ExpansionMode.delimiterKeep, .delimiterDrop] {
        let source = try source(entry("{clipboard}", mode: mode), delimiter: delimiter)
        XCTAssertEqual(source.originalInput, ";;dynamic" + delimiter)
        XCTAssertEqual(source.markedText, ";;dynamic")
        XCTAssertEqual(source.markedRange, NSRange(location: 7, length: 9))
        XCTAssertEqual(source.trailingText, mode == .delimiterKeep ? delimiter : "")
      }
    }
  }

  func testHandoffRejectsWrongMarkRangeOrNonInvocationAndPendingEntry() {
    let entry = entry("{clipboard}")
    let step = OwlAutomaticExpansionRecognizer.Step.invoke(entry, trigger: ";;dynamic")
    XCTAssertNil(OwlAutomaticExpansionInvocationSource(step: step, start: 7, markedText: ";;dynamic"))
    XCTAssertNil(OwlAutomaticExpansionInvocationSource(step: step, start: NSNotFound, markedText: ";;dynami"))
    XCTAssertNil(OwlAutomaticExpansionInvocationSource(step: step, start: Int.max - 2, markedText: ";;dynami"))
    XCTAssertNil(OwlAutomaticExpansionInvocationSource(step: .mark(";;dynami"), start: 7, markedText: ";;dynami"))
    XCTAssertNil(OwlAutomaticExpansionInvocationSource(step: .invoke(entry, trigger: ";;other"), start: 7, markedText: ";;othe"))
    var pending = entry
    pending.reviewState = .pending
    XCTAssertNil(OwlAutomaticExpansionInvocationSource(step: .invoke(pending, trigger: ";;dynamic"), start: 7, markedText: ";;dynami"))
  }

  func testPendingDynamicTemplatesNeverMatchEvenWithAutomaticFlag() throws {
    var pending = entry("{clipboard}{date}{argument name=purpose}")
    pending.reviewState = .pending
    let index = try OwlAutomaticExpansionIndex(entries: [pending])
    XCTAssertTrue(index.isEmpty)
    let recognizer = OwlAutomaticExpansionRecognizer()
    for text in ";;dynamic" {
      XCTAssertEqual(recognizer.consume(.text(String(text)), index: index, canStart: true), .passThrough)
    }
    XCTAssertFalse(recognizer.isRecognizing)
  }

  func testInvalidDynamicPublishDoesNotReplaceWorkingIndex() throws {
    let runtime = OwlAutomaticExpansionRuntime()
    try runtime.publish(entries: [entry("{clipboard}")], enabled: true, disabledBundleIDs: [])
    let revision = runtime.revision
    XCTAssertThrowsError(try runtime.publish(entries: [entry("{date format=}")], enabled: true, disabledBundleIDs: []))
    XCTAssertEqual(runtime.revision, revision)
    XCTAssertTrue(runtime.allows(bundleID: "synthetic.host"))
  }

  func testDynamicTemplatesKeepExactDuplicateAndPrefixConflictRules() throws {
    let short = entry("{clipboard}")
    var longer = entry("{date}")
    longer.trigger = ";;dynamic_more"
    XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: [short, longer]))
    XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: [longer, short]))
    XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: [short, short]))
    var delimited = short
    delimited.expansionMode = .delimiterDrop
    XCTAssertNoThrow(try OwlAutomaticExpansionIndex(entries: [delimited, longer]))
    XCTAssertNoThrow(try OwlAutomaticExpansionIndex(entries: [longer, delimited]))
  }

  func testCompleteMatchFreezesOnceAndUsesSameInvocationForPreviewAndConfirmation() throws {
    for mode in [OwlTemplateEntry.ExpansionMode.immediate, .delimiterKeep, .delimiterDrop] {
      let entry = entry("{date format=yyyy-MM-dd}|{clipboard}|{argument name=purpose}|{clipboard}", mode: mode)
      let index = try OwlAutomaticExpansionIndex(entries: [entry])
      let recognizer = OwlAutomaticExpansionRecognizer()
      var reads = 0
      var requested: Set<OwlTemplateEngine.Requirement> = []
      var captured = context()
      var invocation: OwlTemplateInvocation?
      var marked = ""
      var delivered: [OwlTemplateInvocation.Result] = []
      var copies = 0
      for text in ";;dynami" {
        guard case .mark(let next) = recognizer.consume(.text(String(text)), index: index, canStart: true) else {
          return XCTFail("partial trigger must remain marked")
        }
        marked = next
      }
      XCTAssertNil(invocation)
      XCTAssertEqual(reads, 0)
      var step = recognizer.consume(.text("c"), index: index)
      if mode != .immediate {
        guard case .mark(let next) = step else { return XCTFail("delimiter mode must wait") }
        marked = next
        XCTAssertEqual(reads, 0)
        step = recognizer.consume(.text("\n"), index: index)
      }
      let source = try XCTUnwrap(OwlAutomaticExpansionInvocationSource(step: step, start: 0, markedText: marked))
      invocation = OwlTemplateInvocation(content: .template(source.entry),
        broker: OwlPanelInsertionBroker(pasteboardWrite: { _ in copies += 1; return true }),
        deliver: { delivered.append($0); return .attemptedUnverified }, trailingText: source.trailingText,
        captureContext: { requirements in reads += 1; requested = requirements; return captured })
      let call = try XCTUnwrap(invocation)
      var shown: OwlTemplateInvocation?
      call.start { shown = $0 }
      XCTAssertTrue(shown === call)
      XCTAssertEqual(reads, 1)
      XCTAssertEqual(requested, [.clipboard, .temporal])
      XCTAssertTrue(delivered.isEmpty)
      XCTAssertFalse(call.confirm(values: [:]))
      let values = ["n:purpose": "解释"]
      let evaluation = call.evaluate(values: values)
      XCTAssertEqual(evaluation.previewText, "1970-01-01|中😀e\u{301}|解释|中😀e\u{301}" + source.trailingText)
      captured = context("外部已变更")
      let updatedEvaluation = call.evaluate(values: values)
      XCTAssertEqual(updatedEvaluation.previewText, evaluation.previewText)
      XCTAssertEqual(updatedEvaluation.cursorOffset, evaluation.cursorOffset)
      XCTAssertEqual(updatedEvaluation.missingKeys, evaluation.missingKeys)
      let preview = OwlTemplateInvocation.Result(text: evaluation.previewText, cursorOffset: evaluation.cursorOffset)
      XCTAssertTrue(call.confirm(values: values))
      XCTAssertEqual(delivered, [preview])
      XCTAssertEqual(call.retainedResult, preview)
      XCTAssertEqual(reads, 1)
      XCTAssertEqual(copies, 0)
      XCTAssertFalse(call.confirm(values: values))
      call.cancel()
      XCTAssertEqual(delivered, [preview])
    }
  }

  func testReadyDynamicMatchDoesNotOpenParameterWindowOrReadUnusedContext() throws {
    for body in ["{clipboard}", "{date format=yyyy-MM-dd}", "普通{unknown}示例"] {
      let source = try source(entry(body))
      var requests: [Set<OwlTemplateEngine.Requirement>] = []
      var delivered: [String] = []
      var shown = 0
      let call = OwlTemplateInvocation(content: .template(source.entry), broker: OwlPanelInsertionBroker(),
        deliver: { delivered.append($0.text); return .confirmed }, trailingText: source.trailingText,
        captureContext: { requests.append($0); return self.context() })
      call.start { _ in shown += 1 }
      if body.contains("unknown") {
        XCTAssertEqual(shown, 1, "warnings still require UI and original-input preparation")
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
      } else {
        XCTAssertEqual(shown, 0)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(requests, [body.contains("clipboard") ? [.clipboard] : [.temporal]])
      }
    }
  }

  func testInvocationValidityCannotReviveAfterObservedSourceChange() {
    var current = true
    var checks = 0
    let validity = OwlAutomaticExpansionInvocationValidity(binding: ["current": "true"]) {
      checks += 1
      return ["current": String(current)]
    }
    XCTAssertTrue(validity.isValid())
    current = false
    XCTAssertFalse(validity.isValid())
    current = true
    XCTAssertFalse(validity.isValid())
    XCTAssertEqual(checks, 2)
  }

  func testLiveInvocationWithUnverifiedHostDeliveryRetainsResultAndCopiesOnDemand() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { controller.destroySession() }
    let client = HabitsTextClient(); client.appID = "com.apple.TextEdit"
    let source = OwlTemplateHostDelivery.AutomaticSource(
      originalInput: ";;dynamic",
      markedRange: NSRange(location: 0, length: 9),
      markedText: ";;dynamic",
      isValid: { true }
    )
    let delivery = OwlTemplateHostDelivery(
      controller: controller,
      client: client,
      automaticSource: source,
      boundApplication: .current
    )
    var copies: [String] = []
    let broker = OwlPanelInsertionBroker(
      captureFrontmost: { nil },
      pasteboardWrite: { copies.append($0); return true },
      schedule: { _, action in action() }
    )
    var presented = 0; var finished = 0
    let call = OwlTemplateInvocation(
      content: .template(entry("{argument name=purpose}", mode: .delimiterDrop)),
      broker: broker,
      delivery: delivery,
      prepareAutomaticSource: true,
      onFinish: { finished += 1 },
      captureContext: { _ in self.context() }
    )

    call.start { _ in presented += 1 }
    XCTAssertEqual(presented, 1)
    XCTAssertTrue(call.confirm(values: ["n:purpose": "result"]))
    XCTAssertEqual(call.outcome, .notAttempted(.originalNotPreserved))
    XCTAssertEqual(call.retainedResult, .init(text: "result", cursorOffset: nil))
    XCTAssertEqual(client.text.string, "")
    XCTAssertTrue(copies.isEmpty)
    XCTAssertTrue(call.copyResult())
    XCTAssertEqual(copies, ["result"])
    XCTAssertEqual(finished, 1)
    call.cancel()
    XCTAssertEqual(finished, 1)
  }

  func testInvocationExternalTransitionBlocksDeliveryWhileVerifiedRoundTripSucceeds() throws {
    for restoreAllowed in [false, true] {
      var writes = 0; var finishes = 0
      let broker = OwlPanelInsertionBroker(
        captureFrontmost: { .init(restore: {}, isRestored: { restoreAllowed }) },
        pasteboardWrite: { _ in true },
        schedule: { _, action in action() }
      )
      let call = OwlTemplateInvocation(
        content: .template(entry("{argument name=purpose}")),
        broker: broker,
        deliver: { _ in writes += 1; return .confirmed },
        isHostReady: { restoreAllowed },
        mayRestoreFocus: { restoreAllowed },
        onFinish: { finishes += 1 },
        captureContext: { _ in self.context() }
      )
      call.start { _ in }
      XCTAssertTrue(call.confirm(values: ["n:purpose": "result"]))
      if restoreAllowed {
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(call.outcome, .confirmed)
      } else {
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(call.outcome, .notAttempted(.targetChanged))
        XCTAssertEqual(call.retainedResult?.text, "result")
      }
      XCTAssertEqual(finishes, 1)
    }
  }
}
