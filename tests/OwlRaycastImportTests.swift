import XCTest
@testable import Owltype

@MainActor
final class OwlRaycastImportTests: XCTestCase {
  private var root: URL!
  private var importer: OwlRaycastImport { OwlRaycastImport(dataDir: root) }
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("OwlRaycastImportTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  private func data(_ rows: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: rows) }
  private func snapshot() throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in [OwlTemplateStore.fileName] {
      let url = root.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) { result[name] = try Data(contentsOf: url) }
    }
    return result
  }
  func testSingleCursorImportsAndMultipleCursorsRemainPending() throws {
    let preview = try importer.preview(data: data([
      ["name": "单光标", "text": "前{cursor}后"],
      ["name": "重复光标", "text": "前{cursor}中{cursor}后"]
    ]))
    XCTAssertFalse(try XCTUnwrap(preview.rows[0].entry).isPendingReview)
    XCTAssertTrue(try XCTUnwrap(preview.rows[1].entry).isPendingReview)
    XCTAssertEqual(preview.selectedCount, 1)
    let result = try importer.commit(preview)
    let item = try XCTUnwrap(result.entries.first)
    let evaluation = OwlTemplateEngine.render(OwlTemplateEngine.parse(item), values: [:])
    XCTAssertEqual(evaluation.readyText, "前后")
    XCTAssertEqual(evaluation.cursorOffset, 1)
  }
  func testMixedRowsAreVisibleAndPreviewOrCancelDoesNotWrite() throws {
    let before = try snapshot()
    let preview = try importer.preview(data: data([
      ["name": "有效", "text": "正文"], ["name": "", "text": "正文"],
      ["name": "缺正文"], ["name": "数字", "text": 42], ["name": "null", "text": "正文", "keyword": NSNull()]
    ]))
    XCTAssertEqual(preview.rows.count, 5)
    XCTAssertEqual(preview.rows.filter { !$0.fieldErrors.isEmpty }.count, 4)
    XCTAssertEqual(preview.selectedCount, 1)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertThrowsError(try importer.preview(data: Data("{}".utf8)))
    XCTAssertThrowsError(try importer.preview(data: Data("[".utf8)))
  }
  func testEmptySelectionDoesNotCreateLibraryOrBackup() throws {
    let preview = try importer.preview(data: Data("[]".utf8))
    _ = try importer.commit(preview)
    XCTAssertTrue(try snapshot().isEmpty)
  }
  func testLiteralUTF8MarkdownAndMetadataBoundarySurviveReopen() throws {
    let text = "  # 中文 👩🏽‍💻 e\u{301}\r\n\t代码：{\"key\": 1}  "
    let preview = try importer.preview(data: data([["name": "多行", "text": text, "keyword": ";;literal", "tags": ["未支持"]]]))
    XCTAssertEqual(preview.rows[0].unsupportedKeys, ["tags"])
    _ = try importer.commit(preview)
    let entry = try XCTUnwrap(OwlTemplateStore.load(dataDir: root).entries.first)
    XCTAssertEqual(Data(entry.body.utf8), Data(text.utf8))
    XCTAssertEqual(entry.bodyType, .plainText)
    XCTAssertEqual(entry.trigger, ";;literal")
    XCTAssertEqual(entry.invocationMode, .searchOnly)
    XCTAssertTrue(entry.tags.isEmpty)
    XCTAssertFalse(OwlTemplateStore.renderCandidateProjection(.init(entries: [entry])).contains(entry.id.uuidString))
  }
  func testSameFileAndLocallyEditedSourceNeverCreateCopies() throws {
    let source = try data([["name": "原名", "text": "原文", "keyword": ";;source"]])
    _ = try importer.commit(importer.preview(data: source))
    var library = try OwlTemplateStore.load(dataDir: root)
    let id = library.entries[0].id
    library.entries[0].title = "我的修改"
    library.entries[0].body = "不同正文"
    library.entries[0].trigger = "changed"
    try OwlTemplateStore.save(library, dataDir: root)
    let before = try snapshot()
    let repeated = try importer.preview(data: source)
    XCTAssertEqual(repeated.duplicateKind(at: 0), .alreadyImported)
    XCTAssertEqual(repeated.selectedCount, 0)
    _ = try importer.commit(repeated)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: root).entries.first?.id, id)
  }
  func testBatchDuplicateCanUseSecondRowWhenFirstSkipped() throws {
    var preview = try importer.preview(data: data([
      ["name": "同", "text": "一", "keyword": ""], ["name": "同", "text": "一"]
    ]))
    XCTAssertEqual(preview.selectedCount, 1)
    XCTAssertEqual(preview.duplicateKind(at: 1), .identical)
    preview.rows[0].selected = false
    preview.rows[1].selected = true
    XCTAssertEqual(preview.selectedCount, 1)
    _ = try importer.commit(preview)
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: root).entries.count, 1)
  }
  func testSameTextDifferentBodySemanticsIsNotAnExactDuplicate() throws {
    var entry = OwlTemplateEntry(title: "参数", body: "{argument}")
    entry.trigger = ";;arg"
    try OwlTemplateStore.save(.init(entries: [entry]), dataDir: root)
    let preview = try importer.preview(data: data([["name": "参数", "text": "{argument}", "keyword": ";;arg"]]))
    XCTAssertNil(preview.duplicateKind(at: 0))
    XCTAssertFalse(preview.conflicts(at: 0).isEmpty)
  }
  func testConflictSearchOnlyPreservesSourceSearchAndReimportIdentity() throws {
    var existing = OwlTemplateEntry(title: "旧", body: "旧正文")
    existing.trigger = "code"; existing.invocationMode = .candidate; existing.candidateAliases = ["vcode"]
    try OwlTemplateStore.save(.init(entries: [existing]), dataDir: root)
    let source = try data([["name": "新", "text": "新正文", "keyword": "vcode"]])
    var preview = try importer.preview(data: source)
    XCTAssertFalse(preview.conflicts(at: 0).isEmpty)
    XCTAssertThrowsError(try importer.commit(preview))
    preview.makeSearchOnly(at: 0)
    _ = try importer.commit(preview)
    let library = try OwlTemplateStore.load(dataDir: root)
    let imported = try XCTUnwrap(library.entries.first { $0.id != existing.id })
    XCTAssertNil(imported.trigger)
    XCTAssertEqual(imported.importSource?.originalKeyword, "vcode")
    XCTAssertTrue(OwlTemplateStore.filtered(library.entries, query: "vcode").contains { $0.id == imported.id })
    XCTAssertEqual(try importer.preview(data: source).selectedCount, 0)
    XCTAssertEqual(library.entries.first { $0.id == existing.id }, existing)
  }
  func testPendingBlocksEveryEngineInvocationAndCandidateEvenWithForcedMode() throws {
    let source = try data([["name": "待处理", "text": "{clipboard} {unsupported}", "keyword": "pending"]])
    var preview = try importer.preview(data: source)
    XCTAssertTrue(try XCTUnwrap(preview.rows[0].entry).isPendingReview)
    XCTAssertEqual(preview.selectedCount, 0)
    preview.rows[0].selected = true
    _ = try importer.commit(preview)
    var entry = try XCTUnwrap(OwlTemplateStore.load(dataDir: root).entries.first)
    entry.invocationMode = .candidate
    let parsed = OwlTemplateEngine.parse(entry)
    XCTAssertTrue(parsed.contextRequirements.isEmpty)
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: [:]).readyText)
    XCTAssertFalse(OwlTemplateStore.renderCandidateProjection(.init(entries: [entry])).contains(entry.id.uuidString))
    XCTAssertNil(OwlTemplateStore.resolveCandidate(code: "pending", text: OwlTemplateStore.candidateText(entry), loadLibrary: { .init(entries: [entry]) }))
    var captures = 0
    var delivered: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(entry), broker: OwlPanelInsertionBroker(), deliver: { delivered.append($0.text); return .confirmed }, captureContext: { _ in captures += 1; return .init() })
    _ = invocation.evaluate(values: [:])
    XCTAssertFalse(invocation.confirm(values: [:]))
    XCTAssertEqual(captures, 0); XCTAssertTrue(delivered.isEmpty)
  }
  func testUnsupportedAndAmbiguousSyntaxRetainsRawText() throws {
    for body in ["{unsupported}", "{snippet name=\"x\"}", "{clipboard | trim}", "{clipboard offset=1}",
                 "{calculator}", "{selection}", "{date locale=\"fr-FR\"}", "{{字面内容}}", "{argument name=\"未闭合}"] {
      let preview = try importer.preview(data: data([["name": "待核对", "text": body]]))
      let entry = try XCTUnwrap(preview.rows[0].entry)
      XCTAssertTrue(entry.isPendingReview, body)
      XCTAssertEqual(Data(entry.body.utf8), Data(body.utf8))
      XCTAssertFalse(preview.rows[0].syntaxIssues.isEmpty)
    }
  }
  func testUnsupportedImportExplainsPendingExecutionGate() throws {
    let preview = try importer.preview(data: data([["name": "待处理", "text": "{unsupported}"]]))
    XCTAssertTrue(preview.rows[0].syntaxIssues.contains { $0.message == "含尚未支持的字段，保留待处理，不能执行。" })
    XCTAssertFalse(preview.rows[0].syntaxIssues.contains { $0.message == "未支持的字段将原样插入。" })
  }

  func testPendingImportEditorDiagnosticPreservesErrorsAndOrdinaryLiteralSemantics() throws {
    let preview = try importer.preview(data: data([["name": "待处理", "text": "{selection}{cursor}{cursor}"]]))
    let model = OwlTemplateEditorModel(dataDir: root)
    model.draft = try XCTUnwrap(preview.rows[0].entry)
    let diagnostics = OwlTemplateEngine.render(model.parsed, values: [:]).diagnostics
    let unknown = try XCTUnwrap(diagnostics.first { $0.message == "未支持的字段将原样插入。" })
    let error = try XCTUnwrap(diagnostics.first { $0.severity == .error })
    XCTAssertEqual(model.diagnosticMessage(unknown), "含尚未支持的字段，保留待处理，不能执行。")
    XCTAssertEqual(model.diagnosticMessage(error), error.message)
    XCTAssertEqual(unknown.range, NSRange(location: 0, length: 11))
    XCTAssertFalse(OwlRaycastImport.enableAfterReview(&model.draft))

    model.draft.importSource = nil
    XCTAssertEqual(model.diagnosticMessage(unknown), unknown.message)
    model.draft.reviewState = nil
    model.draft.body = "{selection}"
    XCTAssertEqual(OwlTemplateEngine.render(model.parsed, values: [:]).readyText, "{selection}")
    XCTAssertEqual(model.diagnosticMessage(unknown), unknown.message)
  }

  func testExplicitPlainTextConversionAndReimportRemainLiteralAndUnique() throws {
    let source = try data([["name": "字面", "text": "{{字面内容}} {unsupported}"]])
    var preview = try importer.preview(data: source)
    preview.convertToPlainText(at: 0)
    _ = try importer.commit(preview)
    let entry = try XCTUnwrap(OwlTemplateStore.load(dataDir: root).entries.first)
    XCTAssertFalse(entry.isPendingReview)
    XCTAssertEqual(OwlTemplateEngine.render(OwlTemplateEngine.parse(entry), values: [:]).readyText, entry.body)
    XCTAssertEqual(try importer.preview(data: source).selectedCount, 0)
  }
  func testDefaultsOptionsNamedReuseAndMoreThanThreeAnonymousArguments() throws {
    let text = "{argument name=\"称呼\" default=\"同事\" options=\"同事,朋友\"}/{argument name=\"称呼\"}/{argument default=\"\"}/{argument}/{argument}/{argument}"
    let preview = try importer.preview(data: data([["name": "参数", "text": text]]))
    let entry = try XCTUnwrap(preview.rows[0].entry)
    XCTAssertFalse(entry.isPendingReview)
    let parsed = OwlTemplateEngine.parse(entry)
    XCTAssertEqual(parsed.parameters.count, 5)
    XCTAssertFalse(try XCTUnwrap(parsed.parameters.first { $0.key == "n:称呼" }).isRequired)
    XCTAssertFalse(try XCTUnwrap(parsed.parameters.first { $0.key == "a:1" }).isRequired)
    var values = parsed.initialValues
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: values).readyText)
    values["a:2"] = "甲"; values["a:3"] = "乙"; values["a:4"] = "丙"
    XCTAssertEqual(OwlTemplateEngine.render(parsed, values: values).readyText, "同事/同事//甲/乙/丙")
    values["n:称呼"] = "陌生人"
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: values).readyText)
  }
  func testImportedDynamicTemplateReopensAndUsesOneFrozenContext() throws {
    let text = "{date format=\"yyyy-MM-dd HH:mm\" offset=\"+1M +1m\"}|{clipboard}|{argument name=\"目标\"}"
    _ = try importer.commit(importer.preview(data: data([["name": "动态", "text": text]])))
    let entry = try XCTUnwrap(OwlTemplateStore.load(dataDir: root).entries.first)
    var captures = 0
    var delivered: [String] = []
    let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-01-30T23:45:00Z"))
    let invocation = OwlTemplateInvocation(content: .template(entry), broker: OwlPanelInsertionBroker(), deliver: { delivered.append($0.text); return .confirmed }, captureContext: { requirements in
      captures += 1
      XCTAssertEqual(requirements, [.clipboard, .temporal])
      return .init(clipboard: .text("合成材料"), temporal: .init(date: date, timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"), calendar: Calendar(identifier: .gregorian)))
    })
    XCTAssertEqual(invocation.evaluate(values: ["n:目标": "摘要"]).readyText, "2024-02-29 23:46|合成材料|摘要")
    XCTAssertTrue(invocation.confirm(values: ["n:目标": "摘要"]))
    XCTAssertFalse(invocation.confirm(values: ["n:目标": "摘要"]))
    XCTAssertEqual(captures, 1)
    XCTAssertEqual(delivered, ["2024-02-29 23:46|合成材料|摘要"])
  }
  func testJSONRoundTripKeepsPendingSource() throws {
    var preview = try importer.preview(data: data([["name": "待核对", "text": "{unsupported}", "keyword": ";;p"]]))
    preview.rows[0].selected = true
    _ = try importer.commit(preview)
    let library = try OwlTemplateStore.load(dataDir: root)
    let encoded = try OwlTemplateStore.encoded(library)
    let decoded = try JSONDecoder().decode(OwlTemplateLibrary.self, from: encoded)
    XCTAssertEqual(try OwlTemplateStore.encoded(decoded), encoded)
  }
  func testStalePreviewRejectsWithoutOverwritingConcurrentEdit() throws {
    let preview = try importer.preview(data: data([["name": "导入", "text": "新文"]]))
    try OwlTemplateStore.save(.init(entries: [.init(title: "同时编辑", body: "留住")]), dataDir: root)
    let before = try snapshot()
    XCTAssertThrowsError(try importer.commit(preview))
    XCTAssertEqual(try snapshot(), before)
  }
  func testCommitWriteFailureRollsBackAndRetryDoesNotDuplicate() throws {
    struct Injected: Error {}
    try OwlTemplateStore.save(.init(entries: [.init(title: "原条目", body: "原文")]), dataDir: root)
    let preview = try importer.preview(data: data([["name": "导入", "text": "正文"]]))
    let before = try snapshot()
    XCTAssertThrowsError(try importer.commit(preview, checkpoint: { if $0 == OwlTemplateStore.fileName { throw Injected() } }))
    XCTAssertEqual(try snapshot(), before)
    _ = try importer.commit(preview)
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: root).entries.count, 2)
    XCTAssertEqual(try importer.preview(data: data([["name": "导入", "text": "正文"]])).selectedCount, 0)
  }

  func testEditedPendingCanRenameParameterThenExplicitlyEnable() throws {
    var preview = try importer.preview(data: data([["name": "待修正", "text": "{argument name=\"old\"} {unsupported}"]]))
    preview.rows[0].selected = true
    _ = try importer.commit(preview)
    let suite = "OwlRaycastImportTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = OwlTemplateEditorModel(dataDir: root, defaults: defaults,
                                      automaticRuntime: OwlAutomaticExpansionRuntime())
    model.reload(); model.draft = try XCTUnwrap(model.library.entries.first)
    model.setBody("{argument name=\"new\" default=\"新值\"}")
    XCTAssertTrue(model.draft.isPendingReview)
    XCTAssertTrue(model.save())
    XCTAssertNil(OwlTemplateEngine.render(OwlTemplateEngine.parse(model.draft), values: [:]).readyText)
    XCTAssertTrue(model.enableReviewedDraft())
    XCTAssertEqual(model.draft.parameters.map(\.key), ["n:new"])
    XCTAssertFalse(model.draft.parameters[0].isRequired)
    XCTAssertTrue(model.save())
    let reopened = try XCTUnwrap(OwlTemplateStore.load(dataDir: root).entries.first)
    let parsed = OwlTemplateEngine.parse(reopened)
    XCTAssertEqual(OwlTemplateEngine.render(parsed, values: parsed.initialValues).readyText, "新值")
    XCTAssertEqual(reopened.importSource?.originalBody, "{argument name=\"old\"} {unsupported}")
  }

  func testInvalidReviewLeavesDraftAndPendingUntouchedAndDuplicateStaysGated() throws {
    let preview = try importer.preview(data: data([["name": "pending", "text": "{argument name=\"x\"} {unsupported}"]]))
    var entry = try XCTUnwrap(preview.rows[0].entry)
    entry.body = "{argument name=\"new\"} {unsupported}"
    let original = entry
    XCTAssertFalse(OwlRaycastImport.enableAfterReview(&entry))
    XCTAssertEqual(entry, original)
    let copy = entry.duplicated()
    XCTAssertTrue(copy.isPendingReview); XCTAssertNil(copy.importSource)
    XCTAssertNil(OwlTemplateEngine.render(OwlTemplateEngine.parse(copy), values: [:]).readyText)
  }

  func testChangedKeywordAndPlainDecisionRetainIdentityAfterFileReordering() throws {
    let rows: [[String: Any]] = [["name": "A", "text": "{unsupported}", "keyword": ";;a"],
                               ["name": "B", "text": "原文", "keyword": ";;b"]]
    var preview = try importer.preview(data: data(rows))
    preview.convertToPlainText(at: 0)
    preview.changeTrigger(at: 0, to: "mycode")
    preview.makeSearchOnly(at: 1)
    _ = try importer.commit(preview)
    let repeated = try importer.preview(data: data(Array(rows.reversed())))
    XCTAssertEqual(repeated.selectedCount, 0)
    XCTAssertEqual(repeated.assessment.duplicates.count, 2)
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: root).entries.count, 2)
  }

  func testDuplicateComparisonPreservesDifferentUTF8Normalization() throws {
    let first = "é", second = "e\u{301}"
    XCTAssertEqual(first, second)
    let preview = try importer.preview(data: data([["name": "同名", "text": first], ["name": "同名", "text": second]]))
    XCTAssertEqual(preview.selectedCount, 2)
    _ = try importer.commit(preview)
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: root).entries.map { Data($0.body.utf8) }, [Data(first.utf8), Data(second.utf8)])
  }

  func testCandidateRequiresExplicitChoiceAndValidCode() throws {
    var preview = try importer.preview(data: data([["name": "普通", "text": "正文", "keyword": ";;literal"]]))
    XCTAssertEqual(preview.rows[0].entry?.invocationMode, .searchOnly)
    preview.rows[0].entry?.invocationMode = .candidate
    XCTAssertNotNil(preview.validationMessage)
    preview.changeTrigger(at: 0, to: "valid1")
    XCTAssertNil(preview.validationMessage)
    _ = try importer.commit(preview)
    let entry = try XCTUnwrap(OwlTemplateStore.load(dataDir: root).entries.first)
    XCTAssertEqual(entry.invocationMode, .candidate)
    XCTAssertTrue(OwlTemplateStore.renderCandidateProjection(.init(entries: [entry])).contains("\tvalid1\t"))
  }

  func testBatchConflictRecomputesAfterSkipAndRename() throws {
    var preview = try importer.preview(data: data([["name": "一", "text": "甲", "keyword": ";;same"],
                                                  ["name": "二", "text": "乙", "keyword": ";;same"]]))
    XCTAssertEqual(preview.assessment.conflicts.count, 2)
    preview.rows[1].selected = false
    XCTAssertNil(preview.validationMessage)
    preview.rows[1].selected = true
    preview.changeTrigger(at: 1, to: ";;other")
    XCTAssertTrue(preview.assessment.conflicts.isEmpty)
    _ = try importer.commit(preview)
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: root).entries.count, 2)
  }

  func testOfficialDateFormatExamplesUseRealEngineAfterConversion() throws {
    let examples = [("EEEE, MMM d, yyyy", "Tuesday, Jan 30, 2024"),
                    ("MM/dd/yyyy", "01/30/2024"), ("MM-dd-yyyy HH:mm", "01-30-2024 23:45"),
                    ("MMM d, h:mm a", "Jan 30, 11:45 PM"), ("MMMM yyyy", "January 2024"),
                    ("E, d MMM yyyy HH:mm:ss Z", "Tue, 30 Jan 2024 23:45:06 +0000"),
                    ("yyyy-MM-dd'T'HH:mm:ssZ", "2024-01-30T23:45:06+0000"), ("dd.MM.yy", "30.01.24"),
                    ("HH:mm:ss.SSS", "23:45:06.000")]
    let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-01-30T23:45:06Z"))
    let context = OwlTemplateEngine.FrozenContext(temporal: .init(date: date, timeZone: TimeZone(secondsFromGMT: 0)!,
      locale: Locale(identifier: "en_US_POSIX"), calendar: Calendar(identifier: .gregorian)))
    for (format, expected) in examples {
      let preview = try importer.preview(data: data([["name": format, "text": "{date format=" + OwlTemplateEngine.quoted(format) + "}"]]))
      let entry = try XCTUnwrap(preview.rows[0].entry)
      XCTAssertFalse(entry.isPendingReview, format)
      XCTAssertEqual(OwlTemplateEngine.render(OwlTemplateEngine.parse(entry), values: [:], context: context).readyText, expected, format)
    }
  }

  func testBulkAssessmentUsesOneSharedSnapshotWithCorrectChoices() throws {
    var rows = (0..<500).map { ["name": "记录\($0)", "text": "正文\($0)", "keyword": ";;key\($0)"] }
    rows.append(rows[0])
    rows.append(["name": "冲突", "text": "其他正文", "keyword": ";;key1"])
    let preview = try importer.preview(data: data(rows))
    let review = preview.assessment
    XCTAssertEqual(review.selectedIndices.count, 501)
    XCTAssertEqual(review.duplicates[500], .identical)
    XCTAssertEqual(Set(review.conflicts.keys), [1, 501])
    XCTAssertNotNil(preview.validationMessage(for: review))
  }
}
