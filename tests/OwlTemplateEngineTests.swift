import XCTest
@testable import Owltype

final class OwlTemplateEngineTests: XCTestCase {
  private func entry(_ body: String, legacy: Bool = false) -> OwlTemplateEntry {
    var entry = OwlTemplateEntry(title: "测试", body: body)
    entry.bodyType = .template
    entry.syntax = legacy ? .legacyDoubleBraces : .standard
    return entry
  }

  func testAdjacentRepeatedAnonymousAndUnicode() {
    let parsed = OwlTemplateEngine.parse(entry("🙂{argument name=目标}{argument}{argument}{argument}{argument}{{目标}}"))
    XCTAssertEqual(parsed.parameters.map(\.key), ["n:目标", "a:1", "a:2", "a:3", "a:4"])
    let result = OwlTemplateEngine.render(parsed, values: ["n:目标": "中文", "a:1": "1", "a:2": "2", "a:3": "3", "a:4": "e\u{301}"])
    XCTAssertEqual(result.readyText, "🙂中文123e\u{301}中文")
    XCTAssertEqual(parsed.tokens[1].range.location, 2)
  }

  func testMissingEmptyOptionalAndOptions() {
    var template = entry("{argument name=x options=甲,乙} / {argument name=y}")
    template.parameters = [.init(key: "n:y", name: "y", isRequired: false)]
    let parsed = OwlTemplateEngine.parse(template)
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: [:]).readyText)
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: ["n:x": " ", "n:y": ""]).readyText)
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: ["n:x": "丙", "n:y": ""]).readyText)
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: ["n:x": "甲"]).readyText)
    XCTAssertEqual(OwlTemplateEngine.render(parsed, values: ["n:x": "甲", "n:y": ""]).readyText, "甲 / ")
  }

  func testDefaultsAndConflicts() {
    let parsed = OwlTemplateEngine.parse(entry("{argument name=x default=甲 options=甲,乙}{argument name=x}"))
    XCTAssertEqual(parsed.initialValues, ["n:x": "甲"])
    XCTAssertEqual(OwlTemplateEngine.render(parsed, values: parsed.initialValues).readyText, "甲甲")
    for body in ["{argument name=x default=a}{argument name=x default=b}", "{argument default=x options=a,b}", "{argument name=x name=y}", "{argument name=}", "{argument name=\"oops}", "{argument wat=x}"] {
      XCTAssertTrue(OwlTemplateEngine.parse(entry(body)).diagnostics.contains { $0.severity == .error }, body)
    }
  }

  func testUnknownPreservedAndValuesNotReparsed() {
    let parsed = OwlTemplateEngine.parse(entry("{wat} {argument name=x}"))
    let result = OwlTemplateEngine.render(parsed, values: ["n:x": "{clipboard}"])
    XCTAssertEqual(result.previewText, "{wat} {clipboard}")
    XCTAssertEqual(result.readyText, result.previewText)
    XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning })
    XCTAssertTrue(parsed.contextRequirements.isEmpty)
  }

  func testLegacyAndPlainPreserveSingleBraces() {
    let body = " {{clipboard}}/{clipboard}/{date}/{argument} {{}}\n\t"
    let legacy = OwlTemplateEngine.parse(entry(body, legacy: true))
    XCTAssertEqual(legacy.parameters.map(\.key), ["n:clipboard"])
    XCTAssertEqual(legacy.initialValues, ["n:clipboard": ""])
    XCTAssertTrue(legacy.contextRequirements.isEmpty)
    XCTAssertTrue(legacy.diagnostics.isEmpty)
    XCTAssertEqual(OwlTemplateEngine.render(legacy, values: [:]).previewText, body)
    var plain = entry(body)
    plain.bodyType = .plainText
    let parsed = OwlTemplateEngine.parse(plain)
    XCTAssertTrue(parsed.parameters.isEmpty)
    XCTAssertEqual(OwlTemplateEngine.render(parsed, values: [:]).readyText, body)
  }

  func testDynamicRequirementsReservedAndBlocked() {
    let parsed = OwlTemplateEngine.parse(entry("{clipboard}{clipboard}{date format=yyyy-MM-dd}{time}{datetime}"))
    XCTAssertEqual(parsed.contextRequirements, [.clipboard, .temporal])
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: [:]).readyText)
  }

  func testQuotedBraceEscapesAndLiteralWhitespace() {
    let parsed = OwlTemplateEngine.parse(entry(" \n{argument default=\"a}b\\\"c\"}\t"))
    XCTAssertEqual(OwlTemplateEngine.render(parsed, values: parsed.initialValues).readyText, " \na}b\"c\t")
  }

  func testInvocationBlocksThenDeliversOnceAndFreezesContext() {
    var captures = 0
    var delivered: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(entry("{argument name=x}")),
      broker: OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { _ in true }),
      deliver: { delivered.append($0.text); return .confirmed }, captureContext: { _ in captures += 1; return .init() })
    var presentations = 0
    invocation.start { _ in presentations += 1 }
    XCTAssertEqual(presentations, 1)
    XCTAssertFalse(invocation.confirm(values: [:]))
    XCTAssertEqual(invocation.state, .awaitingConfirmation)
    let preview = invocation.preview(values: ["n:x": "🙂"])
    XCTAssertTrue(invocation.confirm(values: ["n:x": "🙂"]))
    XCTAssertFalse(invocation.confirm(values: ["n:x": "again"]))
    XCTAssertEqual(delivered, [preview.text])
    XCTAssertEqual(captures, 0)

    let dynamic = OwlTemplateInvocation(content: .template(entry("{clipboard}{date}")),
      broker: OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { _ in true }), deliver: nil,
      captureContext: { requirements in
        captures += 1
        XCTAssertEqual(requirements, [.clipboard, .temporal])
        return .init()
      })
    XCTAssertEqual(captures, 0)
    _ = dynamic.preview(values: [:])
    _ = dynamic.preview(values: [:])
    XCTAssertFalse(dynamic.confirm(values: [:]))
    XCTAssertEqual(captures, 1)
  }

  func testQuotedLegacyTextIsNotAField() {
    let parsed = OwlTemplateEngine.parse(entry("{argument name=x default=\"{{raw}}\"}"))
    XCTAssertEqual(parsed.parameters.map(\.key), ["n:x"])
    XCTAssertEqual(OwlTemplateEngine.render(parsed, values: parsed.initialValues).readyText, "{{raw}}")
  }

  func testEditorKeepsDistinctNamedIdentitiesAndResetsAnonymousSettings() {
    let model = OwlTemplateEditorModel(write: { _, _ in })
    model.draft = entry("{argument name=x}{argument name=\"n:x\"}")
    model.draft.parameters = [.init(key: "n:x", name: "x", isRequired: false)]
    let second = model.parsed.parameters[1]
    XCTAssertTrue(model.updateParameter(second, required: true, defaultValue: nil, options: ""))
    XCTAssertFalse(model.parsed.parameters[0].isRequired)
    model.draft = entry("{argument}{argument}")
    model.draft.parameters = [.init(key: "a:1", name: "参数 1", isRequired: false)]
    model.setBody("{argument}")
    XCTAssertTrue(model.draft.parameters.isEmpty)
    XCTAssertTrue(model.parsed.parameters[0].isRequired)
    XCTAssertFalse(model.status.isEmpty)
  }

  func testLegacyValuesAndCancelKeepSameInvocationBoundary() {
    for template in [entry("{{clipboard}}-{clipboard}", legacy: true), entry("{{name}}{{name}}", legacy: true)] {
      var deliveries: [String] = []
      let invocation = OwlTemplateInvocation(content: .template(template),
        broker: OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { _ in true }),
        deliver: { deliveries.append($0.text); return .confirmed })
      let fill = OwlPromptFillModel(template: template, invocation: invocation)
      XCTAssertTrue(fill.canConfirm)
      let preview = fill.filledBody
      XCTAssertTrue(invocation.confirm(values: fill.values))
      XCTAssertEqual(deliveries, [preview])
      invocation.cancel(.windowClosed)
      XCTAssertEqual(deliveries.count, 1)
    }
    for reason in [OwlTemplateInvocation.Cancellation.user, .windowClosed, .replaced] {
      let invocation = OwlTemplateInvocation(content: .template(entry("{argument name=x}")),
        broker: OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { _ in true }),
        deliver: { _ in XCTFail("cancel must not deliver"); return .notAttempted(.missingHost) })
      invocation.cancel(reason)
      XCTAssertFalse(invocation.confirm(values: ["n:x": "value"]))
    }
  }

  func testParameterEditsSynchronizeDeclarationsAndMetadata() {
    let model = OwlTemplateEditorModel(write: { _, _ in })
    model.draft = entry("{argument name=x default=a options=a,b}/{argument name=x}")
    XCTAssertTrue(model.updateParameter(model.parsed.parameters[0], required: false, defaultValue: nil, options: ""))
    XCTAssertFalse(model.parsed.parameters[0].isRequired)
    XCTAssertNil(model.parsed.parameters[0].defaultValue)
    XCTAssertTrue(model.parsed.parameters[0].options.isEmpty)
    XCTAssertFalse(model.draft.body.contains("default="))
    XCTAssertFalse(model.draft.body.contains("options="))
  }

  func testCandidateAliasAndPanelUseSameStandardParameterSession() {
    var template = entry("{argument name=目标 default=甲}\n{argument name=目标}")
    template.trigger = "mail"
    template.candidateAliases = ["vmail"]
    template.invocationMode = .candidate
    let library = OwlTemplateLibrary(entries: [template])
    for code in ["mail", "vmail"] {
      let resolved = OwlTemplateStore.resolveCandidate(code: code, text: OwlTemplateStore.candidateText(template), loadLibrary: { library })
      XCTAssertEqual(resolved, template)
      guard let resolved else { return }
      for selected in [template, resolved] {
        var deliveries: [String] = []
        let invocation = OwlTemplateInvocation(content: .template(selected),
          broker: OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { _ in true }),
          deliver: { deliveries.append($0.text); return .confirmed })
        let fill = OwlPromptFillModel(template: selected, invocation: invocation)
        XCTAssertEqual(fill.parameters.count, 1)
        XCTAssertEqual(fill.filledBody, "甲\n甲")
        fill.values["n:目标"] = "🙂\n正文"
        let preview = fill.filledBody
        XCTAssertTrue(invocation.confirm(values: fill.values))
        XCTAssertEqual(deliveries, [preview])
      }
    }
  }

  func testEditorInsertionAndSaveThroughEngine() {
    let model = OwlTemplateEditorModel(write: { _, _ in })
    model.draft = entry("正文")
    XCTAssertTrue(model.insertParameter(name: "目标", required: true, defaultValue: "甲", options: "甲, 乙"))
    XCTAssertTrue(model.save())
    let parsed = OwlTemplateEngine.parse(model.library.entries[0])
    XCTAssertEqual(parsed.initialValues, ["n:目标": "甲"])
    XCTAssertEqual(OwlTemplateEngine.render(parsed, values: parsed.initialValues).readyText, "正文甲")
    model.draft.body += "{argument name=broken"
    XCTAssertFalse(model.save())
    XCTAssertEqual(model.library.entries.count, 1)
  }
}
