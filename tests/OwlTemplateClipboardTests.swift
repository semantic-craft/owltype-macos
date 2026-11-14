import AppKit
import Combine
import XCTest
@testable import Owltype

@MainActor
final class OwlTemplateClipboardTests: XCTestCase {
  private func entry(_ body: String) -> OwlTemplateEntry {
    var result = OwlTemplateEntry(title: "合成模板", body: body)
    result.bodyType = .template
    result.syntax = .standard
    return result
  }

  private func invocation(_ template: OwlTemplateEntry, read: @escaping () -> String?,
                          deliver: @escaping (String) -> Void = { _ in }) -> OwlTemplateInvocation {
    OwlTemplateInvocation(content: .template(template),
      broker: OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { _ in XCTFail("ordinary insertion/cancellation must not write the clipboard"); return false }), deliver: { deliver($0.text); return .confirmed }, captureContext: { requirements in
        OwlTemplateContextCapture.capture(requirements, readClipboard: read)
      })
  }

  func testProviderReadsOnlyRequestedPlainTextOnce() {
    var reads = 0
    var source: String? = " \t合成🙂 e\u{301}\r\n{clipboard} "
    let read: () -> String? = { reads += 1; return source }
    XCTAssertEqual(OwlTemplateContextCapture.capture([], readClipboard: read).clipboard, .notRequested)
    XCTAssertEqual(OwlTemplateContextCapture.capture([.temporal], readClipboard: read).clipboard, .notRequested)
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(OwlTemplateContextCapture.capture([.clipboard], readClipboard: read).clipboard, .text(source!))
    XCTAssertEqual(reads, 1)
    source = ""
    XCTAssertEqual(OwlTemplateContextCapture.capture([.clipboard], readClipboard: read).clipboard, .empty)
    source = nil
    XCTAssertEqual(OwlTemplateContextCapture.capture([.clipboard], readClipboard: read).clipboard, .nonText)
    XCTAssertEqual(reads, 3)
  }

  func testPlainTextAdapterWithIsolatedPasteboard() {
    // Never inspect, back up, clear or write the user's general pasteboard.
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let capture = { OwlTemplateContextCapture.capture([.clipboard], readClipboard: {
      pasteboard.string(forType: .string)
    }).clipboard }
    pasteboard.clearContents()
    XCTAssertEqual(capture(), .nonText)
    XCTAssertTrue(pasteboard.setData(Data([0, 1, 2]), forType: .png))
    XCTAssertEqual(capture(), .nonText)
    XCTAssertTrue(pasteboard.setString("\t合成材料\r\n🙂 ", forType: .string))
    XCTAssertEqual(capture(), .text("\t合成材料\r\n🙂 "))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("", forType: .string))
    XCTAssertEqual(capture(), .empty)
  }

  func testRepeatedFieldsAndParameterEditsShareSnapshot() {
    let template = entry("{clipboard}\n{argument name=目标}\n{clipboard}")
    let original = " \tA🙂 e\u{301}\r\n{argument} "
    var source = original
    var reads = 0
    var delivered: [String] = []
    let call = invocation(template, read: { reads += 1; return source }, deliver: { delivered.append($0) })
    XCTAssertEqual(reads, 0)
    let fill = OwlPromptFillModel(invocation: call)
    XCTAssertFalse(fill.canConfirm)
    source = "B"
    fill.values["n:目标"] = "解释"
    let preview = fill.filledBody
    XCTAssertEqual(preview, original + "\n解释\n" + original)
    XCTAssertTrue(fill.canConfirm)
    XCTAssertTrue(call.confirm(values: fill.values))
    XCTAssertFalse(call.confirm(values: fill.values))
    XCTAssertEqual(delivered, [preview])
    XCTAssertEqual(reads, 1)
  }

  func testClipboardOnlyUsesInvocationWithoutParameterSheet() {
    var reads = 0
    var delivered: [String] = []
    let call = invocation(entry("前{clipboard}后"), read: { reads += 1; return "材料" },
                          deliver: { delivered.append($0) })
    call.start { _ in XCTFail("nonempty clipboard alone has no unresolved interaction") }
    call.start { _ in XCTFail("already submitted") }
    XCTAssertEqual(delivered, ["前材料后"])
    XCTAssertEqual(reads, 1)
  }

  func testEmptyAndNonTextRequireExplicitChoiceAndPublishRefresh() {
    for source in [nil, ""] as [String?] {
      let template = entry("前{clipboard}/{clipboard}后")
      var delivered: [String] = []
      var reads = 0
      let call = invocation(template, read: { reads += 1; return source }, deliver: { delivered.append($0) })
      var fill: OwlPromptFillModel?
      call.start { fill = OwlPromptFillModel(invocation: $0) }
      guard let fill else { return XCTFail("must present choice even without parameters") }
      XCTAssertTrue(fill.evaluation.needsEmptyClipboardDecision)
      XCTAssertEqual(fill.filledBody, template.body)
      XCTAssertFalse(fill.canConfirm)
      XCTAssertFalse(call.confirm(values: [:]))
      var changes = 0
      let subscription = fill.objectWillChange.sink { changes += 1 }
      fill.continueWithEmptyClipboard()
      withExtendedLifetime(subscription) {
        XCTAssertGreaterThan(changes, 0)
      }
      XCTAssertTrue(delivered.isEmpty, "choosing empty must not insert automatically")
      XCTAssertTrue(fill.canConfirm)
      XCTAssertFalse(fill.evaluation.needsEmptyClipboardDecision)
      XCTAssertEqual(fill.filledBody, "前/后")
      XCTAssertTrue(call.confirm(values: [:]))
      XCTAssertEqual(delivered, ["前/后"])
      XCTAssertEqual(reads, 1)
    }
  }

  func testEmptyChoiceDoesNotBypassParametersOrSyntaxErrors() {
    for body in ["{clipboard}{argument name=目标}", "{clipboard}{argument name=}"] {
      let template = entry(body)
      let call = invocation(template, read: { nil })
      let fill = OwlPromptFillModel(invocation: call)
      fill.continueWithEmptyClipboard()
      XCTAssertFalse(fill.evaluation.needsEmptyClipboardDecision)
      XCTAssertFalse(fill.canConfirm)
      XCTAssertFalse(call.confirm(values: fill.values))
    }
    let parsed = OwlTemplateEngine.parse(entry("{clipboard}"))
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: [:], decisions: .init(allowEmptyClipboard: true)).readyText,
                 "missing capture is not an empty clipboard decision")
  }

  func testWhitespaceAndBracesArePreservedWithoutRecursiveExpansion() {
    for source in [" \t\r\n ", "{{clipboard}} {clipboard} {argument name=x} 👩🏽‍💻 e\u{301}"] {
      var delivered = ""
      let call = invocation(entry("{clipboard}{clipboard}"), read: { source }, deliver: { delivered = $0 })
      call.start { _ in XCTFail("plain material must not become dynamic syntax") }
      XCTAssertEqual(Array(delivered.utf8), Array((source + source).utf8))
    }
  }

  func testCancelledClosedAndReplacedCallsDoNotReadAgainOrDeliver() {
    for reason in [OwlTemplateInvocation.Cancellation.user, .windowClosed, .replaced] {
      var source: String? = nil
      var reads = 0
      let template = entry("{clipboard}")
      let call = invocation(template, read: { reads += 1; return source }, deliver: { _ in XCTFail("cancelled") })
      call.start { _ in }
      call.cancel(reason, restoreFocus: reason != .replaced)
      source = "B"
      call.prepareForResultPreview()
      XCTAssertNil(call.evaluate(values: [:]).readyText)
      XCTAssertFalse(call.confirm(values: [:]))
      XCTAssertEqual(reads, 1)
      var delivered = ""
      let next = invocation(template, read: { reads += 1; return source }, deliver: { delivered = $0 })
      next.start { _ in XCTFail("new invocation must read B") }
      XCTAssertEqual(delivered, "B")
      XCTAssertEqual(reads, 2)
    }
  }

  func testCancelBeforePreparationNeverReadsAndEmptyChoiceDoesNotLeak() {
    var reads = 0
    let template = entry("{clipboard}")
    let first = invocation(template, read: { reads += 1; return nil })
    first.cancel()
    first.prepareForResultPreview()
    XCTAssertNil(first.evaluate(values: [:]).readyText)
    XCTAssertEqual(reads, 0)
    let second = invocation(template, read: { reads += 1; return nil })
    let fill = OwlPromptFillModel(invocation: second)
    fill.continueWithEmptyClipboard()
    XCTAssertTrue(fill.canConfirm)
    second.cancel()
    let third = invocation(template, read: { reads += 1; return nil })
    XCTAssertTrue(third.evaluate(values: [:]).needsEmptyClipboardDecision)
    XCTAssertEqual(reads, 2)
  }

  func testDeliveryReentryDoesNotReadOrInsertTwice() {
    var reads = 0
    var deliveries = 0
    var call: OwlTemplateInvocation!
    call = invocation(entry("{clipboard}"), read: { reads += 1; return "A" }, deliver: { _ in
      deliveries += 1
      XCTAssertFalse(call.confirm(values: [:]))
      XCTAssertNil(call.evaluate(values: [:]).readyText)
    })
    call.start { _ in XCTFail("no sheet") }
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(deliveries, 1)
  }

  func testPlainLegacyAndArgumentOnlyNeverReadClipboard() {
    var plain = entry("{clipboard}"); plain.bodyType = .plainText
    var legacy = entry("{clipboard}{{clipboard}}"); legacy.syntax = .legacyDoubleBraces
    for template in [plain, legacy, entry("{{clipboard}}"), entry("{argument name=clipboard default=A}")] {
      let call = invocation(template, read: { XCTFail("no dynamic clipboard field"); return nil })
      XCTAssertNotNil(call.evaluate(values: call.initialValues).readyText)
    }
  }

  func testPickerSelectionAndCandidateAliasUseSameFrozenExpansion() throws {
    var template = entry("{clipboard}/{argument name=目标 default=解释}")
    template.trigger = "sample"
    template.candidateAliases = ["vsample"]
    template.invocationMode = .candidate
    let library = OwlTemplateLibrary(entries: [template])
    var picker = OwlPickerPanelModel(rows: [.template(template)])
    picker.setQuery("clipboard")
    picker.select(0)
    let row = try XCTUnwrap(picker.selectedRow)
    let picked = try XCTUnwrap(library.entries.first { $0.id.uuidString == row.id })
    let candidateText = try XCTUnwrap(OwlTemplateStore.renderCandidateProjection(library)
      .split(separator: "\n").first { $0.hasPrefix(OwlTemplateStore.candidatePrefix) }?.split(separator: "\t").first.map(String.init))
    let candidate = try XCTUnwrap(OwlTemplateStore.resolveCandidate(
      code: "vsample", text: candidateText, loadLibrary: { library }))
    for selected in [picked, candidate] {
      var reads = 0
      var source = "A"
      var delivered = ""
      let call = invocation(selected, read: { reads += 1; return source }, deliver: { delivered = $0 })
      XCTAssertEqual(reads, 0)
      call.start { _ in }
      source = "B"
      XCTAssertEqual(call.evaluate(values: call.initialValues).previewText, "A/解释")
      XCTAssertTrue(call.confirm(values: call.initialValues))
      XCTAssertEqual(delivered, "A/解释")
      XCTAssertEqual(reads, 1)
    }
  }
}
