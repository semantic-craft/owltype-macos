import XCTest
import AppKit
import Carbon
@testable import Owltype

final class OwlAutomaticExpansionTests: XCTestCase {
  private func entry(_ trigger: String, body: String = "  正文\n\t🙂{clipboard}  ",
                     mode: OwlTemplateEntry.ExpansionMode = .immediate) -> OwlTemplateEntry {
    var entry = OwlTemplateEntry(title: "合成测试", body: body)
    entry.trigger = trigger
    entry.invocationMode = .automatic
    entry.expansionMode = mode
    return entry
  }

  func testImmediateMatchPreservesBodyAndConsumesLastKeyExactlyOnce() throws {
    let entry = entry(";;Ab_1-")
    let index = try OwlAutomaticExpansionIndex(entries: [entry])
    let recognizer = OwlAutomaticExpansionRecognizer()
    for char in ";;Ab_1" {
      XCTAssertEqual(recognizer.consume(.text(String(char)), index: index, canStart: true), .mark(recognizer.buffer))
    }
    XCTAssertEqual(recognizer.consume(.text("-"), index: index), .invoke(entry, trigger: ";;Ab_1-"))
    XCTAssertFalse(recognizer.isRecognizing)
    XCTAssertEqual(recognizer.consume(.text("x"), index: index), .passThrough)
    XCTAssertNil(recognizer.takePending())
  }

  func testSingleSemicolonReturnsToOriginalPunctuationBeforeCurrentKey() throws {
    let index = try OwlAutomaticExpansionIndex(entries: [entry(";;a")])
    let recognizer = OwlAutomaticExpansionRecognizer()
    XCTAssertEqual(recognizer.consume(.text(";"), index: index, canStart: true), .mark(";"))
    XCTAssertEqual(recognizer.consume(.text("x"), index: index),
                   .restore(";", replaySemicolon: true, consumeKey: false))
    XCTAssertNil(recognizer.takePending())
  }

  func testNoMatchAndInvalidCharacterRestoreWithoutDoubleTyping() throws {
    let index = try OwlAutomaticExpansionIndex(entries: [entry(";;abc")])
    let recognizer = OwlAutomaticExpansionRecognizer()
    for char in ";;a" { _ = recognizer.consume(.text(String(char)), index: index, canStart: true) }
    XCTAssertEqual(recognizer.consume(.text("z"), index: index),
                   .restore(";;az", replaySemicolon: false, consumeKey: true))
    for char in ";;a" { _ = recognizer.consume(.text(String(char)), index: index, canStart: true) }
    XCTAssertEqual(recognizer.consume(.text("?"), index: index),
                   .restore(";;a", replaySemicolon: false, consumeKey: false))
  }

  func testBackspaceOnlyEditsOwnedBufferAndEscapePreservesIt() throws {
    let index = try OwlAutomaticExpansionIndex(entries: [entry(";;abc")])
    let recognizer = OwlAutomaticExpansionRecognizer()
    for char in ";;a" { _ = recognizer.consume(.text(String(char)), index: index, canStart: true) }
    XCTAssertEqual(recognizer.consume(.backspace, index: index), .mark(";;"))
    XCTAssertEqual(recognizer.consume(.escape, index: index),
                   .restore(";;", replaySemicolon: false, consumeKey: true))
    XCTAssertEqual(recognizer.consume(.escape, index: index), .passThrough)
    _ = recognizer.consume(.text(";"), index: index, canStart: true)
    XCTAssertEqual(recognizer.consume(.backspace, index: index), .clear)
    XCTAssertEqual(recognizer.consume(.backspace, index: index), .passThrough)
  }

  func testEligibilityAndCaseAreExact() throws {
    let index = try OwlAutomaticExpansionIndex(entries: [entry(";;A")])
    let recognizer = OwlAutomaticExpansionRecognizer()
    XCTAssertEqual(recognizer.consume(.text(";"), index: index), .passThrough)
    for char in ";;" { _ = recognizer.consume(.text(String(char)), index: index, canStart: true) }
    XCTAssertEqual(recognizer.consume(.text("a"), index: index),
                   .restore(";;a", replaySemicolon: false, consumeKey: true))
  }

  func testInvalidAutomaticEntriesAndPrefixConflictsAreRejected() {
    for invalid in [";;", "x", ";;空", ";;a b", ";;a."] {
      XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: [entry(invalid)]))
    }
    XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: [entry(";;a"), entry(";;a")]))
    XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: [entry(";;a"), entry(";;ab")]))
    XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: [entry(";;ab"), entry(";;a")]))
    var dynamic = entry(";;dynamic"); dynamic.bodyType = .template
    XCTAssertNoThrow(try OwlAutomaticExpansionIndex(entries: [dynamic]))
    dynamic.body = "{argument name=}"
    XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: [dynamic]))
    var delimiter = entry(";;a"); delimiter.expansionMode = .delimiterDrop
    XCTAssertNoThrow(try OwlAutomaticExpansionIndex(entries: [delimiter]))
    var search = entry("unsupported imported keyword"); search.invocationMode = .searchOnly
    XCTAssertNoThrow(try OwlAutomaticExpansionIndex(entries: [search, entry(";;a")]))
  }

  func testInterruptedPendingIsTakenBeforeReentrantFinalize() throws {
    let index = try OwlAutomaticExpansionIndex(entries: [entry(";;abc")])
    let recognizer = OwlAutomaticExpansionRecognizer()
    for char in ";;a" { _ = recognizer.consume(.text(String(char)), index: index, canStart: true) }
    XCTAssertEqual(recognizer.takePending(), ";;a")
    XCTAssertNil(recognizer.takePending(), "Second lifecycle callback must not commit twice")
    XCTAssertEqual(recognizer.consume(.text("b"), index: index), .passThrough)
  }

  func testScopeRejectsSelectionsInvalidRangesAndWordInteriors() {
    let scope = OwlAutomaticExpansionScope.self
    let absent = NSRange(location: NSNotFound, length: NSNotFound)
    XCTAssertTrue(scope.canStart(selection: NSRange(location: 0, length: 0), marked: absent, preceding: nil))
    XCTAssertTrue(scope.canStart(selection: NSRange(location: 5, length: 0), marked: absent, preceding: " "))
    XCTAssertFalse(scope.canStart(selection: NSRange(location: 5, length: 0), marked: absent, preceding: "a"))
    XCTAssertFalse(scope.canStart(selection: NSRange(location: 5, length: 0), marked: absent, preceding: ";"))
    XCTAssertFalse(scope.canStart(selection: NSRange(location: 5, length: 0), marked: absent, preceding: nil))
    XCTAssertFalse(scope.canStart(selection: NSRange(location: 5, length: 1), marked: absent, preceding: " "))
    XCTAssertFalse(scope.canStart(selection: absent, marked: absent, preceding: " "))
    XCTAssertFalse(scope.canStart(selection: NSRange(location: 0, length: 0), marked: NSRange(location: 0, length: 1), preceding: nil))
  }

  func testMarkedOwnershipRequiresExactTextRangeAndCaret() {
    let range = NSRange(location: 8, length: 3)
    let end = NSRange(location: 11, length: 0)
    XCTAssertTrue(OwlAutomaticExpansionScope.owns(start: 8, text: ";;a", marked: range, selection: end, substring: ";;a"))
    XCTAssertFalse(OwlAutomaticExpansionScope.owns(start: 8, text: ";;a", marked: range, selection: end, substring: ";;b"))
    XCTAssertFalse(OwlAutomaticExpansionScope.owns(start: 8, text: ";;a", marked: range, selection: NSRange(location: 10, length: 0), substring: ";;a"))
    XCTAssertFalse(OwlAutomaticExpansionScope.owns(start: Int.max, text: ";;a", marked: range, selection: end, substring: ";;a"))
  }

  func testRuntimeDefaultsOffAndFailedPublishRetainsPreviousSnapshot() throws {
    let runtime = OwlAutomaticExpansionRuntime()
    XCTAssertFalse(runtime.allows(bundleID: "test.host"))
    try runtime.publish(entries: [entry(";;a")], enabled: true, disabledBundleIDs: ["test.disabled"])
    let revision = runtime.revision
    XCTAssertTrue(runtime.allows(bundleID: "test.host"))
    XCTAssertFalse(runtime.allows(bundleID: "TEST.DISABLED"))
    XCTAssertFalse(runtime.allows(bundleID: nil))
    XCTAssertThrowsError(try runtime.publish(entries: [entry("bad")], enabled: true, disabledBundleIDs: []))
    XCTAssertEqual(runtime.revision, revision)
    XCTAssertTrue(runtime.allows(bundleID: "test.host"))
  }

  func testReloadWithoutDefaultsArgumentUsesIsolatedOwlDefaults() throws {
    XCTAssertTrue(OwlDefaults.isRunningUnitTests)
    XCTAssertFalse(OwlDefaults.standard === UserDefaults.standard)
    let defaults = OwlDefaults.standard
    let key = OwlAutomaticExpansionRuntime.enabledKey
    let original = defaults.object(forKey: key)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwlAutoDefaults-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
      try? FileManager.default.removeItem(at: directory)
    }
    let runtime = OwlAutomaticExpansionRuntime()
    defaults.set(true, forKey: key)
    try runtime.reload(rimeDir: directory)
    XCTAssertTrue(runtime.enabled)
    defaults.set(false, forKey: key)
    try runtime.reload(rimeDir: directory)
    XCTAssertFalse(runtime.enabled)
  }


  private func context(_ preedit: String = "") -> RimeComposition {
    RimeComposition(preedit: preedit, selStart: 0, selEnd: preedit.utf8.count,
      cursorPos: preedit.utf8.count, commitTextPreview: preedit.isEmpty ? nil : "候选",
      candidates: [], labels: [], pageNo: 0, pageSize: 5, isLastPage: true,
      highlightedIndex: 0, numCandidates: 0)
  }

  func testControllerEntryStartsForRealIdleContextsInThreeModes() throws {
    let runtime = OwlAutomaticExpansionRuntime()
    try runtime.publish(entries: [entry(";;a")], enabled: true, disabledBundleIDs: [])
    for (schema, ascii) in [("rime_ice", false), ("wubi86", false), ("rime_ice", true)] {
      let rime = FakeRimeSession(status: RimeStatus(schemaId: schema, isASCIIMode: ascii,
        isASCIIPunct: ascii, isFullShape: false), composition: context(), input: "", optionState: [.asciiMode: ascii])
      let recognizer = OwlAutomaticExpansionRecognizer()
      var marked = ""
      let handled = OwlAutomaticExpansionControllerEntry.start(input: .text(";"), bundleID: "test.host",
        runtime: runtime, rime: rime) {
        guard case .mark(let text) = recognizer.consume(.text(";"), index: runtime.index, canStart: true) else { return false }
        marked = text
        return true
      }
      XCTAssertTrue(handled, "A valid idle context is non-nil for " + schema)
      XCTAssertEqual(marked, ";")
      XCTAssertTrue(rime.processedKeys.isEmpty, "Reserved prefix must not also reach Rime")
    }
  }

  func testControllerEntryRejectsExistingCompositionAndFailedReads() throws {
    let runtime = OwlAutomaticExpansionRuntime()
    try runtime.publish(entries: [entry(";;a")], enabled: true, disabledBundleIDs: [])
    for (raw, composition) in [(Optional("ni"), Optional(context("ni"))), (nil, Optional(context())), (Optional(""), nil)] {
      let rime = FakeRimeSession(composition: composition, input: raw)
      XCTAssertFalse(OwlAutomaticExpansionControllerEntry.start(input: .text(";"), bundleID: "test.host",
        runtime: runtime, rime: rime) { XCTFail("Must leave the original Rime/candidate path alone"); return true })
    }
  }

  func testControllerEntryDoesNotProbeHostForOrdinaryInputOrDisabledApp() throws {
    let runtime = OwlAutomaticExpansionRuntime()
    try runtime.publish(entries: [entry(";;a")], enabled: true, disabledBundleIDs: ["test.disabled"])
    let rime = FakeRimeSession(composition: context(), input: "")
    for (text, bundle) in [("ordinary", "test.host"), (";", "test.disabled")] {
      XCTAssertFalse(OwlAutomaticExpansionControllerEntry.start(input: .text(text), bundleID: bundle,
        runtime: runtime, rime: rime) { XCTFail("Ordinary input must not probe the host"); return true })
    }
  }

  private func emptyHost() -> OwlAutomaticExpansionObservation {
    OwlAutomaticExpansionObservation(selection: NSRange(location: 0, length: 0),
      marked: NSRange(location: NSNotFound, length: 0), documentLength: 0, nearbyText: "")
  }

  func testControllerMarkedWriteRefusalReturnsOriginalKeyToPunctuationPath() throws {
    let runtime = OwlAutomaticExpansionRuntime()
    try runtime.publish(entries: [entry(";;a")], enabled: true, disabledBundleIDs: [])
    let rime = FakeRimeSession(composition: context(), input: "")
    var document = ""
    let handled = OwlAutomaticExpansionControllerEntry.start(input: .text(";"), bundleID: "test.host",
      runtime: runtime, rime: rime) {
      let outcome = OwlAutomaticExpansionMarkDelivery.perform(before: emptyHost(), write: {},
        isCurrent: { true }, owns: { false }, readAfter: { emptyHost() })
      XCTAssertEqual(outcome, .rejectedWithoutChange)
      return outcome != .rejectedWithoutChange
    }
    XCTAssertFalse(handled)
    // The ordinary host/Rime path receives the key once after the unchanged refusal.
    if !handled { document += "；" }
    XCTAssertEqual(document, "；")
  }

  func testControllerMarkedWriteSynchronousFinalizeDoesNotReplayText() {
    let recognizer = OwlAutomaticExpansionRecognizer()
    let index = try! OwlAutomaticExpansionIndex(entries: [entry(";;a")])
    _ = recognizer.consume(.text(";"), index: index, canStart: true)
    var current = true
    var document = ""
    let outcome = OwlAutomaticExpansionMarkDelivery.perform(before: emptyHost(), write: {
      if let pending = recognizer.takePending() { document += pending }
      current = false
      XCTAssertNil(recognizer.takePending(), "Nested finalize must not submit twice")
    }, isCurrent: { current }, owns: { false }, readAfter: { self.emptyHost() })
    XCTAssertEqual(outcome, .sessionEnded)
    XCTAssertEqual(document, ";")
  }

  func testControllerSingleSemicolonKeepsOriginalPunctuationBeforeShift() {
    let rime = FakeRimeSession(composition: context(), input: "", optionState: [.asciiMode: false])
    var document = ""
    OwlAutomaticExpansionControllerEntry.processModifiers(pending: ";", finishSemicolon: {
      OwlAutomaticExpansionControllerEntry.replaySemicolon(keycode: 59, modifiers: 2, process: { code, modifiers in
        let handled = rime.process(keycode: code, modifiers: modifiers)
        rime.pendingCommit = rime.option(.asciiMode) ? ";" : "；"
        return handled
      }, update: { document += rime.takeCommit() ?? "" }, isCurrent: { true }, insertLiteral: { document += ";" })
    }, process: { rime.setOption(.asciiMode, true) })
    XCTAssertEqual(document, "；")
    XCTAssertEqual(rime.processedKeys.count, 1)
    XCTAssertEqual(rime.processedKeys.first?.keycode, 59)
    XCTAssertEqual(rime.processedKeys.first?.modifiers, 2)
    XCTAssertTrue(rime.option(.asciiMode))
  }

  func testControllerPunctuationCandidateRemainsInOriginalRimeFlow() {
    let rime = FakeRimeSession(composition: context(), input: "")
    var shownCandidates: [String] = []
    var inserts: [String] = []
    OwlAutomaticExpansionControllerEntry.replaySemicolon(keycode: 59, modifiers: 0, process: { code, modifiers in
      let handled = rime.process(keycode: code, modifiers: modifiers)
      rime.scriptedComposition = RimeComposition(preedit: ";", selStart: 0, selEnd: 1, cursorPos: 1,
        commitTextPreview: "；", candidates: [RimeCandidate(text: "；", comment: nil)], labels: ["1"],
        pageNo: 0, pageSize: 5, isLastPage: true, highlightedIndex: 0, numCandidates: 1)
      return handled
    }, update: { shownCandidates = rime.composition()?.candidates.map(\.text) ?? [] },
      isCurrent: { true }, insertLiteral: { inserts.append(";") })
    XCTAssertEqual(shownCandidates, ["；"])
    XCTAssertTrue(inserts.isEmpty, "A Rime punctuation menu must not also insert a literal semicolon")
  }

  func testControllerReplayDoesNotFallbackAfterSynchronousFocusLoss() {
    var current = true
    var inserted: [String] = []
    OwlAutomaticExpansionControllerEntry.replaySemicolon(keycode: 59, modifiers: 0,
      process: { _, _ in false }, update: { current = false }, isCurrent: { current },
      insertLiteral: { inserted.append(";") })
    XCTAssertTrue(inserted.isEmpty, "A fallback cannot write into a new focus after finalize")
  }


  func testControllerDoesNotWriteAfterReadbackReentersFocusChange() {
    var writes = 0
    let outcome = OwlAutomaticExpansionMarkDelivery.perform(before: emptyHost(),
      write: { writes += 1 }, isCurrent: { false }, owns: { XCTFail("stale host"); return false },
      readAfter: { XCTFail("stale host"); return nil })
    XCTAssertEqual(outcome, .sessionEnded)
    XCTAssertEqual(writes, 0, "A focus change during the pre-write read must not write into the new client")
  }


  func testControllerOrdinaryInputAndDisabledExpansionDoNotReadBundleID() throws {
    let runtime = OwlAutomaticExpansionRuntime()
    let rime = FakeRimeSession(composition: context(), input: "")
    var bundleReads = 0
    func readBundle() -> String? { bundleReads += 1; return "test.host" }
    XCTAssertFalse(OwlAutomaticExpansionControllerEntry.start(input: .text(";"), bundleID: readBundle(),
      runtime: runtime, rime: rime) { XCTFail("disabled"); return true })
    try runtime.publish(entries: [entry(";;a")], enabled: true, disabledBundleIDs: [])
    for _ in 0..<1000 {
      XCTAssertFalse(OwlAutomaticExpansionControllerEntry.start(input: .text("a"), bundleID: readBundle(),
        runtime: runtime, rime: rime) { XCTFail("ordinary input"); return true })
    }
    XCTAssertEqual(bundleReads, 0)
  }

  private let delimiters = [" ", "\t", "\n", ",", ".", "?", "!", ":", "，", "。", "？", "！", "："]

  private func type(_ text: String, into recognizer: OwlAutomaticExpansionRecognizer,
                    index: OwlAutomaticExpansionIndex) -> OwlAutomaticExpansionRecognizer.Step {
    var step = OwlAutomaticExpansionRecognizer.Step.passThrough
    for character in text { step = recognizer.consume(.text(String(character)), index: index, canStart: true) }
    return step
  }

  private func key(_ code: Int, text: String?, flags: NSEvent.ModifierFlags = []) -> OwlKeyEvent {
    OwlKeyEvent(type: .keyDown, keyCode: UInt16(code), characters: text,
                charactersIgnoringModifiers: text, modifierFlags: flags, lastModifiers: [])
  }

  func testDelimiterModesWaitForEveryExactDelimiterAndPreserveEntry() throws {
    for mode in [OwlTemplateEntry.ExpansionMode.delimiterKeep, .delimiterDrop] {
      let item = entry(";;Ab_1-", mode: mode)
      let index = try OwlAutomaticExpansionIndex(entries: [item])
      for delimiter in delimiters {
        let recognizer = OwlAutomaticExpansionRecognizer()
        XCTAssertEqual(type(";;Ab_1-", into: recognizer, index: index), .mark(";;Ab_1-"))
        let step = recognizer.consume(.text(delimiter), index: index)
        XCTAssertEqual(step, .invoke(item, trigger: ";;Ab_1-", delimiter: delimiter))
        XCTAssertEqual(step.trailingText, mode == .delimiterKeep ? delimiter : "")
        XCTAssertNil(recognizer.takePending(), "Commit state is consumed before host delivery")
        XCTAssertEqual(recognizer.consume(.text(delimiter), index: index), .passThrough)
      }
    }
  }

  func testImmediateModeDoesNotConsumeFollowingDelimiter() throws {
    let item = entry(";;a")
    let index = try OwlAutomaticExpansionIndex(entries: [item])
    for delimiter in delimiters {
      let recognizer = OwlAutomaticExpansionRecognizer()
      let step = type(";;a", into: recognizer, index: index)
      XCTAssertEqual(step, .invoke(item, trigger: ";;a"))
      XCTAssertEqual(step.trailingText, "")
      XCTAssertEqual(recognizer.consume(.text(delimiter), index: index), .passThrough)
    }
  }

  func testPrefixValidationDependsOnShorterModeInBothInsertionOrders() {
    let modes: [OwlTemplateEntry.ExpansionMode] = [.immediate, .delimiterKeep, .delimiterDrop]
    for shortMode in modes {
      for longMode in modes {
        let short = entry(";;a", mode: shortMode)
        let long = entry(";;ab", mode: longMode)
        for entries in [[short, long], [long, short]] {
          if shortMode == .immediate {
            XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: entries)) {
              XCTAssertEqual($0 as? OwlAutomaticExpansionIndex.ValidationError, .immediatePrefixConflict)
            }
          } else {
            XCTAssertNoThrow(try OwlAutomaticExpansionIndex(entries: entries))
          }
        }
        XCTAssertThrowsError(try OwlAutomaticExpansionIndex(entries: [short, entry(";;a", mode: longMode)])) {
          XCTAssertEqual($0 as? OwlAutomaticExpansionIndex.ValidationError, .duplicateTrigger)
        }
      }
    }
  }

  func testLongerWordContinuesAfterCompleteShortWordWithoutFallbackExpansion() throws {
    let short = entry(";;a", mode: .delimiterKeep)
    for longMode in [OwlTemplateEntry.ExpansionMode.immediate, .delimiterKeep, .delimiterDrop] {
      let long = entry(";;ab", mode: longMode)
      let index = try OwlAutomaticExpansionIndex(entries: [short, long])
      let recognizer = OwlAutomaticExpansionRecognizer()
      XCTAssertEqual(type(";;a", into: recognizer, index: index), .mark(";;a"))
      XCTAssertEqual(recognizer.consume(.text(" "), index: index), .invoke(short, trigger: ";;a", delimiter: " "))
      _ = type(";;a", into: recognizer, index: index)
      let step = recognizer.consume(.text("b"), index: index)
      if longMode == .immediate { XCTAssertEqual(step, .invoke(long, trigger: ";;ab")) }
      else {
        XCTAssertEqual(step, .mark(";;ab"))
        XCTAssertEqual(recognizer.consume(.text("！"), index: index), .invoke(long, trigger: ";;ab", delimiter: "！"))
      }
      _ = type(";;a", into: recognizer, index: index)
      XCTAssertEqual(recognizer.consume(.text("x"), index: index), .restore(";;ax", replaySemicolon: false, consumeKey: true))
      XCTAssertEqual(recognizer.consume(.text("\n"), index: index), .passThrough)
    }
  }

  func testUnmatchedAndSingleSemicolonDelimitersPreserveOriginalKey() throws {
    let index = try OwlAutomaticExpansionIndex(entries: [entry(";;abc", mode: .delimiterDrop)])
    for delimiter in delimiters {
      let recognizer = OwlAutomaticExpansionRecognizer()
      _ = type(";;a", into: recognizer, index: index)
      XCTAssertEqual(recognizer.consume(.text(delimiter), index: index),
                     .restore(";;a", replaySemicolon: false, consumeKey: false))
      _ = type(";", into: recognizer, index: index)
      XCTAssertEqual(recognizer.consume(.text(delimiter), index: index),
                     .restore(";", replaySemicolon: true, consumeKey: false))
      XCTAssertEqual(recognizer.consume(.text(delimiter), index: index), .passThrough)
    }
  }

  func testOtherWhitespacePunctuationAndMultiCharacterEventsDoNotConfirm() throws {
    let index = try OwlAutomaticExpansionIndex(entries: [entry(";;a", mode: .delimiterKeep)])
    for text in ["\u{00a0}", "\u{3000}", ";", "；", "/", "\r", "\r\n", "  ", "中文", "🙂"] {
      let recognizer = OwlAutomaticExpansionRecognizer()
      _ = type(";;a", into: recognizer, index: index)
      XCTAssertEqual(recognizer.consume(.text(text), index: index),
                     .restore(";;a", replaySemicolon: false, consumeKey: false))
    }
  }

  func testDelimiterWordCanBackspaceCancelAndStartFresh() throws {
    let index = try OwlAutomaticExpansionIndex(entries: [entry(";;ab", mode: .delimiterDrop)])
    let recognizer = OwlAutomaticExpansionRecognizer()
    _ = type(";;ab", into: recognizer, index: index)
    XCTAssertEqual(recognizer.consume(.backspace, index: index), .mark(";;a"))
    XCTAssertEqual(recognizer.consume(.text("b"), index: index), .mark(";;ab"))
    XCTAssertEqual(recognizer.consume(.escape, index: index), .restore(";;ab", replaySemicolon: false, consumeKey: true))
    XCTAssertEqual(recognizer.consume(.text("\n"), index: index), .passThrough)
    _ = type(";;ab", into: recognizer, index: index)
    XCTAssertEqual(recognizer.takePending(), ";;ab")
    XCTAssertNil(recognizer.takePending(), "Repeated lifecycle finalization cannot restore twice")
    XCTAssertEqual(recognizer.consume(.text("\t"), index: index), .passThrough)
    XCTAssertEqual(type(";;ab", into: recognizer, index: index), .mark(";;ab"))
  }

  func testReturnAndTabClassificationUsesTextWhileNavigationAndShortcutsInterrupt() {
    let classify = OwlAutomaticExpansionEventInput.classify
    XCTAssertEqual(classify(key(kVK_Return, text: "\r")), .text("\n"))
    XCTAssertEqual(classify(key(kVK_Tab, text: "\t")), .text("\t"))
    for flags: NSEvent.ModifierFlags in [.shift, .control, .command, .option] {
      XCTAssertEqual(classify(key(kVK_Return, text: "\r", flags: flags)), .interrupt)
      XCTAssertEqual(classify(key(kVK_Tab, text: "\t", flags: flags)), .interrupt)
    }
    XCTAssertEqual(classify(key(kVK_ANSI_KeypadEnter, text: "\u{3}")), .interrupt)
    XCTAssertEqual(classify(key(kVK_ANSI_Slash, text: "?", flags: .shift)), .text("?"))
    XCTAssertEqual(classify(key(kVK_ANSI_1, text: "!", flags: .shift)), .text("!"))
    XCTAssertEqual(classify(key(kVK_ANSI_Semicolon, text: ":", flags: .shift)), .text(":"))
    XCTAssertEqual(classify(key(kVK_ANSI_Period, text: "。")), .text("。"))
  }

  func testReturnAndTabProductionInputOnlyConfirmCompleteWords() throws {
    let item = entry(";;abc", mode: .delimiterKeep)
    let index = try OwlAutomaticExpansionIndex(entries: [item])
    for (code, text, expected) in [(kVK_Return, "\r", "\n"), (kVK_Tab, "\t", "\t")] {
      let input = OwlAutomaticExpansionEventInput.classify(key(code, text: text))
      let recognizer = OwlAutomaticExpansionRecognizer()
      XCTAssertEqual(recognizer.consume(input, index: index, canStart: true), .passThrough)
      _ = type(";;a", into: recognizer, index: index)
      XCTAssertEqual(recognizer.consume(input, index: index), .restore(";;a", replaySemicolon: false, consumeKey: false))
      _ = type(";;abc", into: recognizer, index: index)
      XCTAssertEqual(recognizer.consume(input, index: index), .invoke(item, trigger: ";;abc", delimiter: expected))
    }
  }

  func testOrdinaryTabAndReturnDoNotReadHostOrStealComposition() throws {
    let runtime = OwlAutomaticExpansionRuntime()
    try runtime.publish(entries: [entry(";;a", mode: .delimiterKeep)], enabled: true, disabledBundleIDs: [])
    let rime = FakeRimeSession(composition: context("ni"), input: "ni")
    var bundleReads = 0
    func bundle() -> String? { bundleReads += 1; return "test.host" }
    for (code, text) in [(kVK_Return, "\r"), (kVK_Tab, "\t")] {
      let input = OwlAutomaticExpansionEventInput.classify(key(code, text: text))
      XCTAssertFalse(OwlAutomaticExpansionControllerEntry.start(input: input, bundleID: bundle(), runtime: runtime,
        rime: rime) { XCTFail("Normal composition must remain with Rime"); return true })
    }
    XCTAssertEqual(bundleReads, 0)
    XCTAssertEqual(rime.input(), "ni")
    XCTAssertTrue(rime.processedKeys.isEmpty)
  }

  func testDelimiterModesRespectCaseAndWordBoundaries() throws {
    let item = entry(";;A", mode: .delimiterKeep)
    let index = try OwlAutomaticExpansionIndex(entries: [item])
    let recognizer = OwlAutomaticExpansionRecognizer()
    XCTAssertEqual(type(";;a", into: recognizer, index: index), .restore(";;a", replaySemicolon: false, consumeKey: true))
    XCTAssertEqual(recognizer.consume(.text(" "), index: index), .passThrough)
    for preceding in ["a", "0", "_", "-", "中"] {
      let canStart = OwlAutomaticExpansionScope.canStart(selection: NSRange(location: 1, length: 0),
        marked: NSRange(location: NSNotFound, length: 0), preceding: preceding)
      XCTAssertEqual(recognizer.consume(.text(";"), index: index, canStart: canStart), .passThrough)
    }
  }

  func testPendingReviewCannotExecuteOrShadowAReviewedAutomaticEntry() throws {
    var pending = entry(";;a", mode: .immediate)
    pending.reviewState = .pending
    XCTAssertTrue(try OwlAutomaticExpansionIndex(entries: [pending]).isEmpty)
    let active = entry(";;ab", mode: .delimiterKeep)
    let index = try OwlAutomaticExpansionIndex(entries: [pending, active])
    let recognizer = OwlAutomaticExpansionRecognizer()
    XCTAssertEqual(type(";;a", into: recognizer, index: index), .mark(";;a"))
    XCTAssertEqual(recognizer.consume(.text(" "), index: index), .restore(";;a", replaySemicolon: false, consumeKey: false))
    _ = type(";;ab", into: recognizer, index: index)
    XCTAssertEqual(recognizer.consume(.text(" "), index: index), .invoke(active, trigger: ";;ab", delimiter: " "))
    pending.trigger = active.trigger
    XCTAssertNoThrow(try OwlAutomaticExpansionIndex(entries: [pending, active]))
    pending.trigger = "unsupported imported keyword"
    pending.bodyType = .template
    XCTAssertTrue(try OwlAutomaticExpansionIndex(entries: [pending]).isEmpty)
  }

  func testDelimiterInvocationPreviewDeliveryAndExplicitCopyShareExactText() throws {
    let body = " \t中文👩🏽‍💻 e\u{301}\r\n  第二行\t{clipboard} {cursor}\n "
    for mode in [OwlTemplateEntry.ExpansionMode.delimiterKeep, .delimiterDrop] {
      let item = entry(";;body", body: body, mode: mode)
      let index = try OwlAutomaticExpansionIndex(entries: [item])
      for delimiter in delimiters {
        let recognizer = OwlAutomaticExpansionRecognizer()
        _ = type(";;body", into: recognizer, index: index)
        let step = recognizer.consume(.text(delimiter), index: index)
        guard case .invoke(let selected, _, _) = step else { return XCTFail("Expected match") }
        var delivered: [String] = []
        var copied: [String] = []
        let broker = OwlPanelInsertionBroker(captureFrontmost: { XCTFail("No focus window for plain text"); return nil },
          pasteboardWrite: { copied.append($0); return true })
        let invocation = OwlTemplateInvocation(content: .template(selected), broker: broker,
          deliver: { delivered.append($0.text); return .confirmed }, trailingText: step.trailingText,
          captureContext: { _ in XCTFail("Plain text must not read context"); return .init() })
        let expected = body + (mode == .delimiterKeep ? delimiter : "")
        XCTAssertEqual(Array(invocation.preview(values: [:]).text.utf8), Array(expected.utf8))
        invocation.start { _ in XCTFail("Plain text needs no input sheet") }
        XCTAssertFalse(invocation.confirm(values: [:]))
        XCTAssertEqual(delivered, [expected])
        XCTAssertEqual(invocation.retainedResult?.text, expected)
        XCTAssertTrue(copied.isEmpty, "No automatic clipboard write")
        XCTAssertTrue(invocation.copyResult())
        XCTAssertEqual(copied, [expected])
        XCTAssertEqual(selected, item, "Do not append the delimiter into the stored body")
      }
    }
  }

  func testUnverifiedDelimiterDeliveryRetainsSuffixWithoutRetryOrAutoCopy() throws {
    let item = entry(";;a", mode: .delimiterKeep)
    var deliveries = 0
    var copies: [String] = []
    var presentations = 0
    let broker = OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { copies.append($0); return true })
    let invocation = OwlTemplateInvocation(content: .template(item), broker: broker,
      deliver: { _ in deliveries += 1; return .attemptedUnverified }, trailingText: "\n")
    invocation.start { _ in presentations += 1 }
    XCTAssertEqual(deliveries, 1)
    XCTAssertEqual(presentations, 1)
    XCTAssertEqual(invocation.outcome, .attemptedUnverified)
    XCTAssertEqual(invocation.retainedResult?.text, item.body + "\n")
    XCTAssertFalse(invocation.confirm(values: [:]))
    XCTAssertEqual(deliveries, 1)
    XCTAssertTrue(copies.isEmpty)
    XCTAssertTrue(invocation.copyResult())
    XCTAssertEqual(copies, [item.body + "\n"])
  }

  @MainActor
  func testSavedExpansionModeRefreshesBoundRuntimeAndFailedConflictKeepsPreviousMode() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OwlDelimiterTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "OwlDelimiterTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    defaults.set(true, forKey: OwlAutomaticExpansionRuntime.enabledKey)
    let runtime = OwlAutomaticExpansionRuntime()
    try runtime.reload(rimeDir: root, defaults: defaults)
    let writer = OwlConfigWriter(rimeDir: root)
    var item = entry(";;a")
    for mode in [OwlTemplateEntry.ExpansionMode.immediate, .delimiterKeep, .delimiterDrop] {
      item.expansionMode = mode
      try OwlTemplateStore.save(.init(entries: [item]), writer: writer)
      XCTAssertEqual(try OwlTemplateStore.load(rimeDir: root).entries.first?.expansionMode, mode)
      let recognizer = OwlAutomaticExpansionRecognizer()
      let step = type(";;a", into: recognizer, index: runtime.index)
      if mode == .immediate { XCTAssertEqual(step, .invoke(item, trigger: ";;a")) }
      else {
        XCTAssertEqual(step, .mark(";;a"))
        XCTAssertEqual(recognizer.consume(.text("\t"), index: runtime.index), .invoke(item, trigger: ";;a", delimiter: "\t"))
      }
    }
    let revision = runtime.revision
    var conflict = item
    conflict.expansionMode = .immediate
    XCTAssertThrowsError(try OwlTemplateStore.save(.init(entries: [conflict, entry(";;ab")]), writer: writer))
    XCTAssertEqual(try OwlTemplateStore.load(rimeDir: root).entries, [item])
    XCTAssertEqual(runtime.revision, revision)
    XCTAssertTrue(runtime.allows(bundleID: "test.host"))
    try runtime.publish(entries: [item], enabled: true, disabledBundleIDs: ["TEST.HOST"])
    XCTAssertFalse(runtime.allows(bundleID: "test.host"))
  }

  func testCompleteDelimiterWordInterruptedBeforeConfirmationIsRestoredOnce() throws {
    for mode in [OwlTemplateEntry.ExpansionMode.delimiterKeep, .delimiterDrop] {
      let index = try OwlAutomaticExpansionIndex(entries: [entry(";;a", mode: mode)])
      let recognizer = OwlAutomaticExpansionRecognizer()
      _ = type(";;a", into: recognizer, index: index)
      XCTAssertEqual(recognizer.consume(.interrupt, index: index), .restore(";;a", replaySemicolon: false, consumeKey: false))
      XCTAssertNil(recognizer.takePending())
      XCTAssertEqual(recognizer.consume(.text("\n"), index: index), .passThrough)
    }
  }

}
