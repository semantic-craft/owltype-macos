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
      let preview = call.preview(values: values)
      XCTAssertEqual(preview.text, "1970-01-01|中😀e\u{301}|解释|中😀e\u{301}" + source.trailingText)
      captured = context("外部已变更")
      XCTAssertEqual(call.preview(values: values), preview)
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

  private final class Host {
    let source: OwlAutomaticExpansionInvocationSource
    var document: String
    var selection: NSRange
    var marked: NSRange
    var writes: [(String, NSRange?)] = []
    var moves = 0
    var revision: UInt64 = 0
    var rejection: OwlTemplateDeliveryOutcome.Reason?
    var readable = true
    var canReplace = true
    var sourceValid = true
    var acknowledgeWrites = true
    var restorations = 0
    var presentationFocused = false
    weak var activeDelivery: OwlTemplateHostDelivery?

    init(source: OwlAutomaticExpansionInvocationSource) {
      self.source = source
      document = "prefix " + source.markedText + " suffix"
      selection = NSRange(location: NSMaxRange(source.markedRange), length: 0)
      marked = source.markedRange
    }

    func delivery() -> OwlTemplateHostDelivery {
      let access = OwlTemplateHostDelivery.Access(
        rejection: { _ in self.rejection }, rangeIsCurrent: { self.readable }, revision: { self.revision },
        selection: { self.selection }, marked: { self.marked }, text: { range in
          guard range.location >= 0, range.location <= self.document.utf16.count,
                range.length <= self.document.utf16.count - range.location else { return nil }
          return (self.document as NSString).substring(with: range)
        }, insert: { text, explicitRange in
          self.writes.append((text, explicitRange))
          let range = explicitRange ?? (self.marked.location == NSNotFound ? self.selection : self.marked)
          self.document = (self.document as NSString).replacingCharacters(in: range, with: text)
          self.marked = NSRange(location: NSNotFound, length: 0)
          self.selection = NSRange(location: range.location + text.utf16.count, length: 0)
          if !self.acknowledgeWrites { self.readable = false }
          return true
        }, canReplace: { self.canReplace }, move: { range, _, _ in
          self.moves += 1
          self.selection = range
          return true
        }, isPresentationFocused: { self.presentationFocused })
      let delivery = OwlTemplateHostDelivery(access: access, automaticSource: .init(originalInput: source.originalInput,
        markedRange: source.markedRange, markedText: source.markedText, isValid: { self.sourceValid }))
      activeDelivery = delivery
      return delivery
    }
  }

  private func invocation(source: OwlAutomaticExpansionInvocationSource, host: Host,
                          copy: @escaping (String) -> Bool = { _ in XCTFail("no implicit copy"); return false },
                          capture: @escaping (Set<OwlTemplateEngine.Requirement>) -> OwlTemplateEngine.FrozenContext = { _ in .init() },
                          onFinish: @escaping () -> Void = {}) -> OwlTemplateInvocation {
    let delivery = host.delivery()
    let broker = OwlPanelInsertionBroker(captureFrontmost: {
      .init(restore: { host.restorations += 1 }, isRestored: { true })
    }, pasteboardWrite: copy, schedule: { _, action in action() })
    return OwlTemplateInvocation(content: .template(source.entry), broker: broker, delivery: delivery,
      trailingText: source.trailingText, prepareAutomaticSource: true, onFinish: onFinish, captureContext: capture)
  }

  func testDeferredCancellationKeepsCompleteOriginalIncludingDroppedDelimiterWithoutAnotherWrite() throws {
    for mode in [OwlTemplateEntry.ExpansionMode.immediate, .delimiterKeep, .delimiterDrop] {
      for reason in [OwlTemplateInvocation.Cancellation.user, .windowClosed, .replaced] {
        let source = try source(entry("{argument name=purpose}", mode: mode), delimiter: mode == .immediate ? nil : "\n")
        let host = Host(source: source)
        var finished = 0
        let call = invocation(source: source, host: host, onFinish: { finished += 1 })
        call.start { _ in }
        XCTAssertEqual(host.document, "prefix " + source.originalInput + " suffix")
        XCTAssertEqual(host.writes.count, 1, "only original input preservation before the window")
        call.cancel(reason, restoreFocus: false)
        call.cancel(reason, restoreFocus: false)
        XCTAssertFalse(call.confirm(values: ["n:purpose": "result"]))
        XCTAssertEqual(host.document, "prefix " + source.originalInput + " suffix")
        XCTAssertEqual(host.writes.count, 1)
        XCTAssertEqual(host.moves, 0)
        XCTAssertEqual(finished, 1)
      }
    }
  }

  func testDeferredConfirmationReplacesOnlyOriginalRangeOnceAndRetainsFrozenCursorAndSuffix() throws {
    for mode in [OwlTemplateEntry.ExpansionMode.immediate, .delimiterKeep, .delimiterDrop] {
      let source = try source(entry("{clipboard}/{argument name=purpose}{cursor}尾", mode: mode),
        delimiter: mode == .immediate ? nil : "\n")
      let host = Host(source: source)
      var current = context()
      var reads = 0
      let call = invocation(source: source, host: host, capture: { _ in reads += 1; return current })
      call.start { _ in }
      XCTAssertEqual(host.writes.count, 1)
      let values = ["n:purpose": "甲\n乙"]
      let preview = call.preview(values: values)
      XCTAssertEqual(preview.cursorOffset, 9)
      current = context("changed")
      XCTAssertTrue(call.confirm(values: values))
      XCTAssertEqual(host.document, "prefix " + preview.text + " suffix")
      XCTAssertEqual(host.writes.count, 2, "one original preservation plus one result replacement")
      XCTAssertEqual(host.writes.last?.1, NSRange(location: 7, length: source.originalInput.utf16.count))
      XCTAssertEqual(host.writes.last?.0, "中😀e\u{301}/甲\n乙尾" + source.trailingText)
      XCTAssertEqual(host.selection, NSRange(location: 16, length: 0))
      XCTAssertEqual(host.moves, 1)
      XCTAssertEqual(call.outcome, .confirmedWithCursor(.positioned))
      XCTAssertEqual(reads, 1)
      XCTAssertFalse(call.confirm(values: values))
      call.cancel()
      XCTAssertEqual(host.writes.count, 2)
    }
  }

  func testReadyDynamicResultReplacesMarkOnceAndTerminalFeedbackNeverRestoresOriginal() throws {
    let source = try source(entry("{clipboard}{cursor}尾"))
    let host = Host(source: source)
    host.acknowledgeWrites = false
    let call = invocation(source: source, host: host, capture: { _ in self.context() })
    var presented = 0
    call.start { _ in presented += 1 }
    XCTAssertEqual(host.writes.count, 1)
    XCTAssertEqual(host.writes.first?.0, "中😀e\u{301}尾")
    XCTAssertEqual(host.document, "prefix 中😀e\u{301}尾 suffix")
    XCTAssertEqual(call.outcome, .attemptedUnverified)
    XCTAssertEqual(presented, 1)
    XCTAssertEqual(host.moves, 0)
    call.cancel()
    XCTAssertFalse(call.confirm(values: [:]))
    XCTAssertEqual(host.writes.count, 1)
  }

  func testEmptyClipboardWithoutParametersPreparesOriginalBeforePromptAndDoesNotRecapture() throws {
    let source = try source(entry("前{clipboard}後", mode: .delimiterDrop), delimiter: "\t")
    let host = Host(source: source)
    var reads = 0
    let call = invocation(source: source, host: host, capture: { _ in reads += 1; return .init(clipboard: .empty) })
    var shown = 0
    call.start { _ in shown += 1 }
    XCTAssertEqual(shown, 1)
    XCTAssertEqual(host.document, "prefix ;;dynamic\t suffix")
    XCTAssertEqual(host.writes.count, 1)
    XCTAssertFalse(call.confirm(values: [:]))
    call.continueWithEmptyClipboard()
    XCTAssertTrue(call.confirm(values: [:]))
    XCTAssertEqual(host.document, "prefix 前後 suffix")
    XCTAssertEqual(host.writes.count, 2)
    XCTAssertEqual(reads, 1)
  }

  func testChangedOriginalRangeOrTargetNeverFallsBackToAppend() throws {
    for change in 0..<5 {
      let source = try source(entry("{argument name=purpose}", mode: .delimiterKeep), delimiter: " ")
      let host = Host(source: source)
      let call = invocation(source: source, host: host)
      call.start { _ in }
      switch change {
      case 0: host.document = host.document.replacingOccurrences(of: ";;dynamic", with: ";;changed")
      case 1: host.selection = NSRange(location: 0, length: 0)
      case 2: host.marked = NSRange(location: host.selection.location, length: 1)
      case 3: host.canReplace = false
      default: host.sourceValid = false
      }
      let before = host.document
      XCTAssertTrue(call.confirm(values: ["n:purpose": "result"]))
      XCTAssertEqual(host.writes.count, 1, "never append or blindly restore after losing original proof")
      XCTAssertEqual(host.document, before)
      XCTAssertNotEqual(call.outcome, .confirmed)
      XCTAssertEqual(call.retainedResult?.text, "result ")
    }
  }

  func testUnconfirmedOriginalPreservationNeverSubmitsResultOrRetriesOriginal() throws {
    let source = try source(entry("{argument name=purpose}", mode: .delimiterDrop), delimiter: "\n")
    let host = Host(source: source)
    host.acknowledgeWrites = false
    var copies: [String] = []
    let call = invocation(source: source, host: host, copy: { copies.append($0); return true })
    call.start { _ in }
    XCTAssertEqual(host.writes.count, 1)
    XCTAssertEqual(host.document, "prefix ;;dynamic\n suffix")
    XCTAssertTrue(call.confirm(values: ["n:purpose": "result"]))
    XCTAssertEqual(call.outcome, .originalPreservationUnverified)
    XCTAssertEqual(call.retainedResult?.text, "result")
    XCTAssertEqual(host.writes.count, 1)
    XCTAssertTrue(copies.isEmpty)
    XCTAssertTrue(call.copyResult())
    XCTAssertEqual(copies, ["result"])
    call.cancel()
    XCTAssertEqual(host.writes.count, 1)
  }

  func testInvocationValidityCannotReviveAfterObservedSourceChange() {
    var current = true
    var checks = 0
    let validity = OwlAutomaticExpansionInvocationValidity { checks += 1; return current }
    XCTAssertTrue(validity.isValid())
    current = false
    XCTAssertFalse(validity.isValid())
    current = true
    XCTAssertFalse(validity.isValid())
    XCTAssertEqual(checks, 2)
  }


  func testThirdApplicationRoundTripNeverRevivesInvocationOrStealsFocus() throws {
    for confirm in [false, true] {
      let source = try source(entry("{argument name=purpose}", mode: .delimiterDrop), delimiter: "\n")
      let host = Host(source: source)
      let call = invocation(source: source, host: host)
      call.start { _ in }
      let delivery = try XCTUnwrap(host.activeDelivery)
      // Nonactivating fill UI may never deactivate the host; an external app is still fatal.
      delivery.applicationDidActivate(isOriginal: false, isPresentation: false)
      delivery.applicationDidActivate(isOriginal: true, isPresentation: false)
      if confirm {
        XCTAssertTrue(call.confirm(values: ["n:purpose": "result"]))
        XCTAssertEqual(call.outcome, .notAttempted(.targetChanged))
        XCTAssertEqual(call.retainedResult?.text, "result")
      } else { call.cancel() }
      XCTAssertEqual(host.document, "prefix ;;dynamic\n suffix")
      XCTAssertEqual(host.writes.count, 1)
      XCTAssertEqual(host.restorations, 0)
      XCTAssertFalse(delivery.isReadyForDelivery())
    }
  }

  func testVerifiedParameterPanelRoundTripCanStillReplaceOriginal() throws {
    let source = try source(entry("{argument name=purpose}"))
    let host = Host(source: source)
    let call = invocation(source: source, host: host)
    call.start { _ in }
    let delivery = try XCTUnwrap(host.activeDelivery)
    delivery.endImmediateDelivery()
    host.presentationFocused = true
    delivery.hostWillDeactivate()
    host.presentationFocused = false
    delivery.hostDidActivate()
    XCTAssertTrue(call.confirm(values: ["n:purpose": "result"]))
    XCTAssertEqual(host.document, "prefix result suffix")
    XCTAssertEqual(host.writes.count, 2)
    XCTAssertEqual(host.restorations, 1)
    XCTAssertEqual(call.outcome, .confirmed)
  }

}
