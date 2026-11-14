import XCTest
import SwiftUI
@testable import Owltype

@MainActor
final class OwlTemplateStoreTests: XCTestCase {
  private var root: URL!
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
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [original]), dataDir: root)
    let reopened = try OwlTemplateStore.load(dataDir: root)
    XCTAssertEqual(OwlTemplateStore.mode(dataDir: root), .unified)
    var picker = OwlPickerPanelModel(rows: reopened.entries.map(OwlPickerRow.template))
    picker.setQuery("第二行")
    let selected = try XCTUnwrap(reopened.entries.first { $0.id.uuidString == picker.selectedRow?.id })
    var delivered: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(selected), broker: OwlPanelInsertionBroker(), deliver: { delivered.append($0.text); return .confirmed })
    XCTAssertTrue(invocation.variables.isEmpty)
    XCTAssertEqual(Array(invocation.evaluate(values: ["clipboard": "不得替换"]).previewText.utf8), Array(body.utf8))
    invocation.start { _ in XCTFail("ordinary braces must not open a parameter sheet") }
    invocation.confirm(values: [:])
    XCTAssertEqual(delivered.count, 1)
    XCTAssertEqual(Array(try XCTUnwrap(delivered.first).utf8), Array(body.utf8))
    XCTAssertEqual(selected.id, original.id)
    XCTAssertFalse(OwlTemplateStore.renderCandidateProjection(reopened).contains(original.id.uuidString))
  }

  func testEditingOnlyUnicodeNormalizationStillPersistsExactNewBytes() async throws {
    let editor = OwlTemplateEditorModel(dataDir: root)
    await editor.loadLibraryForEditing()
    editor.draft = OwlTemplateEntry(title: "Accent", body: "é")
    XCTAssertTrue(editor.save())
    editor.draft.body = "e\u{301}"
    XCTAssertTrue(editor.save())
    XCTAssertEqual(Array(try OwlTemplateStore.load(dataDir: root).entries[0].body.utf8), Array("e\u{301}".utf8))
  }

  func testLegacyMaximumLengthAliasAndSwitchToSearchOnly() async throws {
    var item = entry()
    item.trigger = String(repeating: "a", count: 32)
    item.candidateAliases = ["v" + item.trigger!]
    item.invocationMode = .candidate
    let library = OwlTemplateLibrary(entries: [item])
    try OwlTemplateStore.save(library, dataDir: root)
    let projectedText = try XCTUnwrap(OwlTemplateStore.renderCandidateProjection(library)
      .split(separator: "\n").first?.split(separator: "\t").first.map(String.init))
    XCTAssertEqual(OwlTemplateStore.resolveCandidate(code: item.candidateAliases[0], text: projectedText,
                                                    loadLibrary: { library }), item)
    let editor = OwlTemplateEditorModel(dataDir: root)
    await editor.loadLibraryForEditing(); editor.draft = item
    editor.setInvocationMode(.searchOnly)
    XCTAssertTrue(editor.save())
    XCTAssertTrue(editor.draft.candidateAliases.isEmpty)
    XCTAssertFalse(OwlTemplateStore.renderCandidateProjection(editor.library).contains(item.id.uuidString))
  }

  func testInlineCandidatePreviewHidesInternalIdentity() {
    let item = entry()
    let candidateText = "\(OwlTemplateStore.candidatePrefix)\(item.id.uuidString)]\(item.title)"
    let composition = EngineComposition(preedit: "mail", selStart: 0, selEnd: 4, cursorPos: 4,
                                      commitTextPreview: candidateText, candidates: [], labels: [],
                                      pageNo: 0, pageSize: 5, isLastPage: true, highlightedIndex: 0, numCandidates: 0)
    let rendered = EngineCompositionRenderer.markedText(composition: composition, inlinePreedit: true, inlineCandidate: true)
    XCTAssertEqual(rendered.preedit, "📝邮件")
    XCTAssertEqual(rendered.caretPos, "📝邮件".utf16.count)
  }

  func testRenameRetainsIdentityMetadataAndCopyGetsNewIdentity() async throws {
    var original = entry()
    original.tags = ["写作", "常用"]
    original.isPinned = true
    let initial = OwlTemplateLibrary(entries: [original])
    try OwlTemplateStore.save(initial, dataDir: root)
    let editor = OwlTemplateEditorModel(dataDir: root)
    await editor.loadLibraryForEditing()
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

  func testEditorFailureKeepsDraftAndSavedLibrary() async throws {
    let original = entry()
    let library = OwlTemplateLibrary(entries: [original])
    try OwlTemplateStore.save(library, dataDir: root)
    let before = try read(OwlTemplateStore.fileName)
    let editor = OwlTemplateEditorModel(dataDir: root, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    await editor.loadLibraryForEditing()
    editor.draft = original
    editor.draft.body = "\n新草稿\t"
    XCTAssertFalse(editor.save())
    XCTAssertEqual(editor.draft.body, "\n新草稿\t")
    XCTAssertEqual(editor.library, library)
    XCTAssertEqual(try read(OwlTemplateStore.fileName), before)
    XCTAssertFalse(editor.status.isEmpty)
  }

  func testSaveFailuresRestoreAllFilesIncludingAbsentFiles() throws {
    XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry()]), dataDir: root, beforeWrite: {
      if $0 == OwlTemplateStore.fileName { throw CocoaError(.fileWriteNoPermission) }
    }))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(OwlTemplateStore.fileName).path))
    XCTAssertEqual(OwlTemplateStore.mode(dataDir: root), .empty)

    let initial = OwlTemplateLibrary(entries: [entry()])
    try OwlTemplateStore.save(initial, dataDir: root)
    let before = try read(OwlTemplateStore.fileName)
    XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [OwlTemplateEntry(title: "新", body: "正文")]), dataDir: root, beforeWrite: {
      if $0 == OwlTemplateStore.fileName { throw CocoaError(.fileWriteNoPermission) }
    }))
    XCTAssertEqual(try read(OwlTemplateStore.fileName), before)
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: root), initial)
  }

  func testConcurrentCurrentLibraryReadWaitsForTheCompleteSave() throws {
    let initial = OwlTemplateLibrary(entries: [entry()])
    try OwlTemplateStore.save(initial, dataDir: root)
    let next = OwlTemplateLibrary(entries: [.init(title: "New", body: "new body")])
    let directory = root!
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    try OwlTemplateStore.save(next, dataDir: root, expectedLibrary: initial, beforeWrite: { name in
      guard name == OwlTemplateStore.fileName else { return }
      DispatchQueue.global().async {
        started.signal()
        do { let current = try OwlTemplateStore.load(dataDir: directory); XCTAssertEqual(current, next) }
        catch { XCTFail("Public library read failed: \(error)") }
        finished.signal()
      }
      XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
      XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut, "A public read must not observe staged library bytes")
    })
    XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
  }

  func testConcurrentEditorDoesNotOverwriteSavedChanges() async throws {
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry()]), dataDir: root)
    let first = OwlTemplateEditorModel(dataDir: root)
    let second = OwlTemplateEditorModel(dataDir: root)
    await first.loadLibraryForEditing(); await second.loadLibraryForEditing()
    first.draft = OwlTemplateEntry(title: "第一窗口", body: "A")
    second.draft = OwlTemplateEntry(title: "第二窗口", body: "B")
    XCTAssertTrue(first.save())
    XCTAssertFalse(second.save())
    XCTAssertEqual(second.draft.body, "B")
    XCTAssertFalse(try OwlTemplateStore.load(dataDir: root).entries.contains { $0.title == "第二窗口" })
  }

  func testFoundationWhitespaceIsPreservedAcrossLibraryBoundaries() throws {
    let whitespace = "\u{200B}"
    XCTAssertThrowsError(try OwlTemplateStore.save(.init(entries: [.init(title: whitespace, body: "body")]), dataDir: root))
    XCTAssertThrowsError(try OwlTemplateStore.save(.init(entries: [.init(title: "title", body: whitespace)]), dataDir: root))
    let entries = [OwlTemplateEntry(title: "Title", body: "Body")]
    XCTAssertEqual(OwlTemplateStore.filtered(entries, query: whitespace).count, 1)
    XCTAssertEqual(OwlPickerPanelModel(rows: entries.map(OwlPickerRow.template), query: whitespace).visible.count, 1)
  }

  func testWhitespaceRejectionDoesNotTrimValidBody() throws {
    for text in ["", "\n\t \r\n", "　"] {
      XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [OwlTemplateEntry(title: "T", body: text)]), dataDir: root))
    }
    for title in ["", " \t", "a\nb", "a\rb"] {
      XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [OwlTemplateEntry(title: title, body: body)]), dataDir: root))
    }
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry()]), dataDir: root)
    XCTAssertEqual(Array(try OwlTemplateStore.load(dataDir: root).entries[0].body.utf8), Array(body.utf8))
  }

  func testCorruptNewLibraryDoesNotFallBackOrOverwrite() throws {
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry()]), dataDir: root)
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: root.appendingPathComponent(OwlTemplateStore.fileName))
    guard case .unavailable = OwlTemplateStore.mode(dataDir: root) else { return XCTFail("corrupt library must be unavailable") }
    XCTAssertThrowsError(try OwlTemplateStore.load(dataDir: root))
    XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(), dataDir: root))
    XCTAssertEqual(try read(OwlTemplateStore.fileName), corrupt)
  }

  func testUnknownVersionIsNotEmptyLibrary() throws {
    var library = OwlTemplateLibrary(entries: [entry()])
    library.formatVersion = 2
    XCTAssertThrowsError(try OwlTemplateStore.save(library, dataDir: root))
    try JSONEncoder().encode(library).write(to: root.appendingPathComponent(OwlTemplateStore.fileName))
    guard case .unavailable = OwlTemplateStore.mode(dataDir: root) else { return XCTFail("must require recovery") }
    XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(), dataDir: root))
  }

  func testCandidateProjectionUsesIDAndKeepsAliasesOutOfBody() throws {
    var candidate = entry()
    candidate.trigger = "mail"
    candidate.candidateAliases = ["vmail"]
    candidate.invocationMode = .candidate
    let library = OwlTemplateLibrary(entries: [candidate, OwlTemplateEntry(title: "仅搜索", body: "原文")])
    try OwlTemplateStore.save(library, dataDir: root)
    let table = OwlTemplateStore.renderCandidateProjection(library)
    let projectedText = try XCTUnwrap(table.split(separator: "\n").first?.split(separator: "\t").first.map(String.init))
    XCTAssertTrue(table.contains("\(projectedText)\tmail\t100000"))
    XCTAssertTrue(table.contains("\tvmail\t100000"))
    XCTAssertFalse(table.contains("第二行"))
    XCTAssertFalse(table.contains("仅搜索"))
    XCTAssertEqual(OwlTemplateStore.candidateDisplay(projectedText), "📝邮件")
    for code in ["mail", "vmail"] {
      XCTAssertEqual(OwlTemplateStore.resolveCandidate(code: code, text: projectedText, loadLibrary: { library }), candidate)
    }
  }

  func testStaleCandidatesAreRejectedAndOrdinaryCommitsDoNotLoad() throws {
    var item = entry()
    item.trigger = "mail"; item.invocationMode = .candidate
    let text = try XCTUnwrap(OwlTemplateStore.renderCandidateProjection(OwlTemplateLibrary(entries: [item]))
      .split(separator: "\n").first?.split(separator: "\t").first.map(String.init))
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
    XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [first, second]), dataDir: root))
    second.invocationMode = .searchOnly
    XCTAssertNoThrow(try OwlTemplateStore.save(OwlTemplateLibrary(entries: [first, second]), dataDir: root))
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
    XCTAssertEqual(invocation.evaluate(values: [:]).previewText, body)
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
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [item]), dataDir: root)
    XCTAssertEqual(try OwlTemplateStore.load(dataDir: root).entries, [item])
    let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(OwlTemplateStore.fileName).path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testSettingsAndPickerRenderWithIsolatedData() throws {
    let item = entry()
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [item]), dataDir: root)
    let theme = OwlCandidatePanelSettings.live.currentSkin().theme
    let settings = NSHostingView(rootView: OwlTemplatePage(palette: theme.palette(for: .light), dataDir: root))
    settings.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    settings.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(settings.fittingSize.height, 0)
    let picker = NSHostingView(rootView: OwlTemplatePickerView(entries: [item], promptOnly: false, onPick: { _ in }, onPreview: { _ in }, onClose: {}))
    picker.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(picker.fittingSize.height, 0)
  }
}
