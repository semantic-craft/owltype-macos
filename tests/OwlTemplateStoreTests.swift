import XCTest
import SwiftUI
@testable import Owltype

@MainActor
final class OwlTemplateStoreTests: XCTestCase {
  private var root: URL!
  private var writer: OwlConfigWriter { OwlConfigWriter(dataDir: root) }
  private let body = " \t中文👩🏽‍💻 e\u{301}\r\n  第二行\t{{clipboard}} {cursor}\n "

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("OwlTemplateTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func entry() -> OwlTemplateEntry { OwlTemplateEntry(title: "邮件", body: body) }
  private func read(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }

  func testSaveReopenSearchPreviewInvokeKeepsExactBytes() throws {
    let original = entry()
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [original]), writer: writer)
    let reopened = try OwlTemplateStore.load(dataDir: root)
    XCTAssertEqual(OwlTemplateStore.mode(dataDir: root), .unified)
    var picker = OwlPickerPanelModel(rows: reopened.entries.map(OwlPickerRow.template))
    picker.setQuery("第二行")
    let selected = try XCTUnwrap(reopened.entries.first { $0.id.uuidString == picker.selectedRow?.id })
    var delivered: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(selected), broker: OwlPanelInsertionBroker(), deliver: { delivered.append($0.text); return .confirmed })
    XCTAssertTrue(invocation.variables.isEmpty)
    XCTAssertEqual(Array(invocation.preview(values: ["clipboard": "不得替换"]).text.utf8), Array(body.utf8))
    invocation.start { _ in XCTFail("ordinary braces must not open a parameter sheet") }
    invocation.confirm(values: [:])
    XCTAssertEqual(delivered.count, 1)
    XCTAssertEqual(Array(try XCTUnwrap(delivered.first).utf8), Array(body.utf8))
    XCTAssertEqual(selected.id, original.id)
    XCTAssertFalse(String(decoding: try read(OwlTemplateStore.dictFileName), as: UTF8.self).contains(original.id.uuidString))
  }

  func testEditingOnlyUnicodeNormalizationStillPersistsExactNewBytes() throws {
    let editor = OwlTemplateEditorModel(writer: writer)
    editor.reload()
    editor.draft = OwlTemplateEntry(title: "Accent", body: "é")
    XCTAssertTrue(editor.save())
    editor.draft.body = "e\u{301}"
    XCTAssertTrue(editor.save())
    XCTAssertEqual(Array(try OwlTemplateStore.load(dataDir: root).entries[0].body.utf8), Array("e\u{301}".utf8))
  }

  func testLegacyMaximumLengthAliasAndSwitchToSearchOnly() throws {
    var item = entry()
    item.trigger = String(repeating: "a", count: 32)
    item.candidateAliases = ["v" + item.trigger!]
    item.invocationMode = .candidate
    let library = OwlTemplateLibrary(entries: [item])
    try OwlTemplateStore.save(library, writer: writer)
    XCTAssertEqual(OwlTemplateStore.resolveCandidate(code: item.candidateAliases[0], text: OwlTemplateStore.candidateText(item),
                                                    loadLibrary: { library }), item)
    let editor = OwlTemplateEditorModel(writer: writer)
    editor.reload(); editor.draft = item
    editor.setInvocationMode(.searchOnly)
    XCTAssertTrue(editor.save())
    XCTAssertTrue(editor.draft.candidateAliases.isEmpty)
    XCTAssertFalse(String(decoding: try read(OwlTemplateStore.dictFileName), as: UTF8.self).contains(item.id.uuidString))
  }

  func testPreparedBatchCanActivateLegacyDirectoryAfterCallerPreflight() throws {
    let old = root.appendingPathComponent(OwlQuickSendStore.fileName)
    let original = Data("original legacy bytes".utf8)
    try original.write(to: old)
    let library = OwlTemplateLibrary(entries: [entry()])
    let plan = try OwlTemplateStore.prepareWrites(library, writer: writer)
    XCTAssertEqual(plan.last?.fileName, OwlTemplateStore.stateFileName)
    XCTAssertThrowsError(try OwlTemplateStore.commitPreparedWrites(plan, library: library, writer: writer, beforeWrite: {
      if $0 == OwlTemplateStore.stateFileName { throw CocoaError(.fileWriteNoPermission) }
    }))
    XCTAssertEqual(OwlTemplateStore.mode(dataDir: root), .legacy)
    XCTAssertEqual(try Data(contentsOf: old), original)
    try OwlTemplateStore.commitPreparedWrites(plan, library: library, writer: writer)
    XCTAssertEqual(OwlTemplateStore.mode(dataDir: root), .unified)
    XCTAssertEqual(try Data(contentsOf: old), original)
  }

  func testInlineCandidatePreviewHidesInternalIdentity() {
    let item = entry()
    let composition = EngineComposition(preedit: "mail", selStart: 0, selEnd: 4, cursorPos: 4,
                                      commitTextPreview: OwlTemplateStore.candidateText(item), candidates: [], labels: [],
                                      pageNo: 0, pageSize: 5, isLastPage: true, highlightedIndex: 0, numCandidates: 0)
    let rendered = EngineCompositionRenderer.markedText(composition: composition, inlinePreedit: true, inlineCandidate: true)
    XCTAssertEqual(rendered.preedit, "📝邮件")
    XCTAssertEqual(rendered.caretPos, "📝邮件".utf16.count)
  }

  func testRenameRetainsIdentityMetadataAndCopyGetsNewIdentity() throws {
    var original = entry()
    original.tags = ["写作", "常用"]
    original.isPinned = true
    let initial = OwlTemplateLibrary(entries: [original])
    try OwlTemplateStore.save(initial, writer: writer)
    let editor = OwlTemplateEditorModel(writer: writer)
    editor.reload()
    editor.draft = original
    editor.draft.title = "新的标题"
    editor.draft.trigger = ";;mail"
    XCTAssertTrue(editor.save())
    let renamed = try XCTUnwrap(OwlTemplateStore.load(dataDir: root).entries.first)
    XCTAssertEqual(renamed.id, original.id)
    XCTAssertEqual(renamed.tags, original.tags)
    XCTAssertTrue(renamed.isPinned)
    XCTAssertEqual(Array(renamed.body.utf8), Array(original.body.utf8))
    let copy = renamed.duplicated()
    XCTAssertNotEqual(copy.id, original.id)
    XCTAssertNil(copy.trigger)
    XCTAssertEqual(copy.invocationMode, .searchOnly)
    XCTAssertEqual(copy.tags, original.tags)
  }

  func testEditorFailureKeepsDraftAndSavedLibrary() throws {
    let original = entry()
    let library = OwlTemplateLibrary(entries: [original])
    try OwlTemplateStore.save(library, writer: writer)
    let before = try read(OwlTemplateStore.fileName)
    let editor = OwlTemplateEditorModel(writer: writer, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    editor.reload()
    editor.draft = original
    editor.draft.body = "\n新草稿\t"
    XCTAssertFalse(editor.save())
    XCTAssertEqual(editor.draft.body, "\n新草稿\t")
    XCTAssertEqual(editor.library, library)
    XCTAssertEqual(try read(OwlTemplateStore.fileName), before)
    XCTAssertFalse(editor.status.isEmpty)
  }

  func testSaveFailuresRestoreAllFilesIncludingAbsentFiles() throws {
    let stages = [OwlTemplateStore.fileName, OwlTemplateStore.dictFileName, "rime_ice.custom.yaml", OwlTemplateStore.stateFileName, "completed"]
    let names = stages.dropLast() + ["owltype/rollback-manifest.json"]
    for stage in stages {
      XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry()]), writer: writer, beforeWrite: {
        if $0 == stage { throw CocoaError(.fileWriteNoPermission) }
      }))
      for name in names { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name) }
      XCTAssertEqual(OwlTemplateStore.mode(dataDir: root), .empty)
    }
    let initial = OwlTemplateLibrary(entries: [entry()])
    try OwlTemplateStore.save(initial, writer: writer)
    let before = try names.map { try read($0) }
    for stage in stages {
      XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [OwlTemplateEntry(title: "新", body: "正文")]), writer: writer, beforeWrite: {
        if $0 == stage { throw CocoaError(.fileWriteNoPermission) }
      }))
      XCTAssertEqual(try names.map { try read($0) }, before)
      XCTAssertEqual(try OwlTemplateStore.load(dataDir: root), initial)
    }
  }

  func testConcurrentCurrentLibraryReadWaitsForTheCompleteSave() throws {
    let initial = OwlTemplateLibrary(entries: [entry()])
    try OwlTemplateStore.save(initial, writer: writer)
    let next = OwlTemplateLibrary(entries: [.init(title: "New", body: "new body")])
    let directory = root!
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    try OwlTemplateStore.save(next, writer: writer, expectedLibrary: initial, beforeWrite: { name in
      guard name == OwlTemplateStore.dictFileName else { return }
      DispatchQueue.global().async {
        started.signal()
        do { let current = try OwlTemplateBackup(dataDir: directory).currentLibrary(); XCTAssertEqual(current, next) }
        catch { XCTFail("Public library read failed: \(error)") }
        finished.signal()
      }
      XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
      XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut, "A public read must not observe staged library bytes")
    })
    XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
  }

  func testConcurrentEditorDoesNotOverwriteSavedChanges() throws {
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry()]), writer: writer)
    let first = OwlTemplateEditorModel(writer: writer)
    let second = OwlTemplateEditorModel(writer: writer)
    first.reload(); second.reload()
    first.draft = OwlTemplateEntry(title: "第一窗口", body: "A")
    second.draft = OwlTemplateEntry(title: "第二窗口", body: "B")
    XCTAssertTrue(first.save())
    XCTAssertFalse(second.save())
    XCTAssertEqual(second.draft.body, "B")
    XCTAssertFalse(try OwlTemplateStore.load(dataDir: root).entries.contains { $0.title == "第二窗口" })
  }

  func testFoundationWhitespaceIsPreservedAcrossLibraryAndLegacyBoundaries() throws {
    let whitespace = "\u{200B}"
    XCTAssertThrowsError(try OwlTemplateStore.validate(.init(entries: [.init(title: whitespace, body: "body")])))
    XCTAssertThrowsError(try OwlTemplateStore.validate(.init(entries: [.init(title: "title", body: whitespace)])))
    XCTAssertEqual(try OwlPromptStore.entry(code: whitespace + "foo" + whitespace, title: "Title", body: "Body").code, "foo")
    XCTAssertEqual(try OwlQuickSendStore.entry(text: "Text", code: whitespace + "foo" + whitespace).code, "foo")
    let entries = [OwlTemplateEntry(title: "Title", body: "Body")]
    XCTAssertEqual(OwlTemplateStore.filtered(entries, query: whitespace).count, 1)
    XCTAssertEqual(OwlPickerPanelModel(rows: entries.map(OwlPickerRow.template), query: whitespace).visible.count, 1)
  }

  func testWhitespaceRejectionDoesNotTrimValidBody() throws {
    for text in ["", "\n\t \r\n", "　"] {
      XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [OwlTemplateEntry(title: "T", body: text)]), writer: writer))
    }
    for title in ["", " \t", "a\nb", "a\rb"] {
      XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [OwlTemplateEntry(title: title, body: body)]), writer: writer))
    }
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry()]), writer: writer)
    XCTAssertEqual(Array(try OwlTemplateStore.load(dataDir: root).entries[0].body.utf8), Array(body.utf8))
  }

  func testExistingLegacyFilesEvenDamagedPreventActivation() throws {
    for name in [OwlQuickSendStore.fileName, OwlQuickSendStore.dictFileName, OwlPromptStore.fileName, OwlPromptStore.dictFileName] {
      let url = root.appendingPathComponent(name)
      let bytes = Data("damaged original".utf8)
      try bytes.write(to: url)
      XCTAssertEqual(OwlTemplateStore.mode(dataDir: root), .legacy)
      XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry()]), writer: writer))
      XCTAssertEqual(try Data(contentsOf: url), bytes)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(OwlTemplateStore.fileName).path))
      try FileManager.default.removeItem(at: url)
    }
  }

  func testCorruptNewLibraryDoesNotFallBackOrOverwrite() throws {
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry()]), writer: writer)
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: root.appendingPathComponent(OwlTemplateStore.fileName))
    guard case .unavailable = OwlTemplateStore.mode(dataDir: root) else { return XCTFail("corrupt library must be unavailable") }
    XCTAssertThrowsError(try OwlTemplateStore.load(dataDir: root))
    XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(), writer: writer))
    XCTAssertEqual(try read(OwlTemplateStore.fileName), corrupt)
  }

  func testMissingActivationAndUnknownVersionAreNotEmptyLibrary() throws {
    var library = OwlTemplateLibrary(entries: [entry()])
    library.formatVersion = 2
    XCTAssertThrowsError(try OwlTemplateStore.validate(library))
    try JSONEncoder().encode(library).write(to: root.appendingPathComponent(OwlTemplateStore.fileName))
    guard case .unavailable = OwlTemplateStore.mode(dataDir: root) else { return XCTFail("must require recovery") }
    XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(), writer: writer))
  }

  func testCandidateProjectionUsesIDAndKeepsAliasesOutOfBody() throws {
    var candidate = entry()
    candidate.trigger = "mail"
    candidate.candidateAliases = ["vmail"]
    candidate.invocationMode = .candidate
    let library = OwlTemplateLibrary(entries: [candidate, OwlTemplateEntry(title: "仅搜索", body: "原文")])
    try OwlTemplateStore.save(library, writer: writer)
    let table = String(decoding: try read(OwlTemplateStore.dictFileName), as: UTF8.self)
    XCTAssertTrue(table.contains("\(OwlTemplateStore.candidateText(candidate))\tmail\t100000"))
    XCTAssertTrue(table.contains("\tvmail\t100000"))
    XCTAssertFalse(table.contains("第二行"))
    XCTAssertFalse(table.contains("仅搜索"))
    XCTAssertEqual(OwlTemplateStore.candidateDisplay(OwlTemplateStore.candidateText(candidate)), "📝邮件")
    for code in ["mail", "vmail"] {
      XCTAssertEqual(OwlTemplateStore.resolveCandidate(code: code, text: OwlTemplateStore.candidateText(candidate), loadLibrary: { library }), candidate)
    }
  }

  func testStaleCandidatesAreRejectedAndOrdinaryCommitsDoNotLoad() throws {
    var item = entry()
    item.trigger = "mail"; item.invocationMode = .candidate
    let text = OwlTemplateStore.candidateText(item)
    var reads = 0
    let load = { reads += 1; return OwlTemplateLibrary(entries: [item]) }
    XCTAssertNil(OwlTemplateStore.resolveCandidate(code: "mail", text: "普通输入", loadLibrary: load))
    XCTAssertNil(OwlTemplateStore.resolveCandidate(code: "mail", text: "🦉[invalid]", loadLibrary: load))
    XCTAssertEqual(reads, 0)
    item.title = "改名"
    XCTAssertNil(OwlTemplateStore.resolveCandidate(code: "mail", text: text, loadLibrary: load))
    item.title = "邮件"; item.trigger = "new"
    XCTAssertNil(OwlTemplateStore.resolveCandidate(code: "mail", text: text, loadLibrary: load))
    XCTAssertNil(OwlTemplateStore.resolveCandidate(code: "mail", text: text, loadLibrary: { OwlTemplateLibrary() }))
  }

  func testTriggerAndAliasConflictsRejectWithoutLosingRecords() throws {
    var first = entry(); first.trigger = "mail"; first.invocationMode = .candidate; first.candidateAliases = ["vmail"]
    var second = OwlTemplateEntry(title: "other", body: "other")
    second.trigger = "vmail"; second.invocationMode = .candidate
    XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [first, second]), writer: writer))
    second.invocationMode = .searchOnly
    XCTAssertNoThrow(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [first, second]), writer: writer))
  }

  func testLegacySyntaxPreservesSingleBracesAndAllowsExplicitEmptyParameter() {
    var item = OwlTemplateEntry(title: "迁移", body: "{clipboard} {{clipboard}} {{name}}")
    item.bodyType = .template; item.syntax = .legacyDoubleBraces
    var result: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(item), broker: OwlPanelInsertionBroker(), deliver: { result.append($0.text); return .confirmed })
    XCTAssertEqual(invocation.variables, ["clipboard", "name"])
    invocation.start { _ in }
    invocation.confirm(values: ["clipboard": "", "name": "名字"])
    XCTAssertEqual(result, ["{clipboard}  名字"])
  }

  func testInvocationRetainsSelectedVersionAndCancelDoesNotInsert() {
    var item = entry()
    var results: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(item), broker: OwlPanelInsertionBroker(), deliver: { results.append($0.text); return .confirmed })
    item.body = "new version"
    XCTAssertEqual(invocation.preview(values: [:]).text, body)
    invocation.cancel()
    invocation.confirm(values: [:])
    XCTAssertTrue(results.isEmpty)
  }

  func testSearchIncludesAllFieldsAndPinsSortBeforeTitle() {
    var first = OwlTemplateEntry(title: "Alpha", body: "BodyWord")
    first.trigger = ";;keyword"; first.tags = ["TagWord"]
    var pinned = OwlTemplateEntry(title: "Z", body: "z"); pinned.isPinned = true
    let sorted = OwlTemplateStore.sorted([first, pinned])
    XCTAssertEqual(sorted.first?.id, pinned.id)
    var model = OwlPickerPanelModel(rows: sorted.map(OwlPickerRow.template))
    for term in ["ALPHA", "bodyword", "KEYWORD", "tagword"] {
      model.setQuery(term)
      XCTAssertEqual(model.selectedRow?.id, first.id.uuidString)
    }
  }

  func testPrivatePermissionsAndNativeFieldsRoundTrip() throws {
    var item = entry()
    item.parameters = [OwlTemplateParameter(key: "name", name: "姓名", isRequired: false, defaultValue: "", options: ["", "张"])]
    item.category = .prompt
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [item]), writer: writer)
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: root).entries, [item])
    let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(OwlTemplateStore.fileName).path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testSettingsAndPickerRenderWithIsolatedData() throws {
    let item = entry()
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [item]), writer: writer)
    let theme = OwlCandidatePanelSettings.live.currentSkin().theme
    let settings = NSHostingView(rootView: OwlTemplatePage(palette: theme.palette(for: .light), writer: writer))
    settings.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    settings.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(settings.fittingSize.height, 0)
    let picker = NSHostingView(rootView: OwlTemplatePickerView(entries: [item], promptOnly: false, onPick: { _ in }, onPreview: { _ in }, onClose: {}))
    picker.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(picker.fittingSize.height, 0)
  }
}
