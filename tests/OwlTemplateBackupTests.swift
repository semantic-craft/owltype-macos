import XCTest
import Darwin
@testable import Owltype

@MainActor
final class OwlTemplateBackupTests: XCTestCase {
  private var root: URL!
  private var writer: OwlConfigWriter { OwlConfigWriter(rimeDir: root) }
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("OwlTemplateBackupTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  private func sample() -> OwlTemplateEntry {
    var entry = OwlTemplateEntry(title: "同名", body: " \t中文👩🏽‍💻 e\u{301}\r\n {clipboard}\n ")
    entry.tags = ["写作", "Mail, Draft"]; entry.isPinned = true
    entry.trigger = "code"; entry.candidateAliases = ["vcode"]; entry.invocationMode = .candidate
    entry.syntax = .legacyDoubleBraces; entry.category = .prompt; entry.expansionMode = .delimiterKeep
    entry.parameters = [.init(key: "n:空", name: "空", isRequired: false, defaultValue: "", options: []),
                        .init(key: "n:未设", name: "未设", defaultValue: nil, options: ["甲", "乙"])]
    entry.migrationSource = .init(sourceFile: "synthetic.json", record: 2, originalCode: "OldCode")
    return entry
  }
  private func snapshot() throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in [OwlTemplateStore.fileName, OwlTemplateStore.dictFileName, OwlTemplateStore.stateFileName,
                 "rime_ice.custom.yaml", "owltype/rollback-manifest.json"] {
      let url = root.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) { result[name] = try Data(contentsOf: url) }
    }
    return result
  }

  func testExportDeleteRestoreReopenSearchAndInvoke() throws {
    let original = sample()
    // Use one fixed identity throughout the real persistence path.
    let saved = OwlTemplateLibrary(entries: [original])
    try OwlTemplateStore.save(saved, writer: writer)
    let backup = OwlTemplateBackup(rimeDir: root)
    let exportURL = root.appendingPathComponent("export.json")
    try backup.export(to: exportURL)
    XCTAssertEqual(try OwlTemplateStore.encoded(OwlTemplateBackup.decode(Data(contentsOf: exportURL))), try OwlTemplateStore.encoded(saved))
    let removed = try backup.delete(id: original.id, expected: saved)
    XCTAssertNotNil(removed.backupURL)
    XCTAssertTrue(try OwlTemplateStore.load(rimeDir: root).entries.isEmpty)
    let preview = try backup.preview(data: Data(contentsOf: exportURL))
    XCTAssertEqual(preview.rows.first?.kind, .new)
    _ = try backup.restore(preview)
    let reopened = try OwlTemplateStore.load(rimeDir: root)
    XCTAssertEqual(try OwlTemplateStore.encoded(reopened), try OwlTemplateStore.encoded(saved))
    XCTAssertEqual(OwlTemplateStore.filtered(reopened.entries, query: "oldcode", tag: "写作").first?.id, original.id)
    var delivered: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(try XCTUnwrap(reopened.entries.first)),
      broker: OwlPanelInsertionBroker(), deliver: { delivered.append($0.text); return .confirmed })
    invocation.start { _ in XCTFail("plain text must not ask for parameters") }
    XCTAssertEqual(delivered.map { Data($0.utf8) }, [Data(original.body.utf8)])
  }

  func testSameIDUpdateRequiresChoiceAndRepeatIsNoOp() throws {
    var item = sample()
    let incoming = OwlTemplateLibrary(entries: [item])
    item.body = "当前编辑"
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [item]), writer: writer)
    let backup = OwlTemplateBackup(rimeDir: root)
    var preview = try backup.preview(data: OwlTemplateStore.encoded(incoming))
    XCTAssertEqual(preview.rows[0].kind, .update); XCTAssertFalse(preview.rows[0].selected)
    let before = try snapshot()
    XCTAssertNil(try backup.restore(preview).backupURL)
    XCTAssertEqual(try snapshot(), before)
    preview.rows[0].selected = true
    _ = try backup.restore(preview)
    let repeated = try backup.preview(data: OwlTemplateStore.encoded(incoming))
    XCTAssertEqual(repeated.rows[0].kind, .identical)
    XCTAssertNil(try backup.restore(repeated).backupURL)
    XCTAssertEqual(try OwlTemplateStore.load(rimeDir: root).entries.count, 1)
  }

  func testConflictResolutionRetainsSourceAndExistingEntry() throws {
    let existing = sample()
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [existing]), writer: writer)
    var incoming = sample(); incoming.body = "另一条"
    let backup = OwlTemplateBackup(rimeDir: root)
    var preview = try backup.preview(data: OwlTemplateStore.encoded(OwlTemplateLibrary(entries: [incoming])))
    XCTAssertFalse(preview.conflicts.isEmpty)
    XCTAssertThrowsError(try backup.restore(preview))
    preview.makeSearchOnly(id: incoming.id)
    XCTAssertTrue(preview.conflicts.isEmpty)
    _ = try backup.restore(preview)
    let entries = try OwlTemplateStore.load(rimeDir: root).entries
    XCTAssertEqual(entries.count, 2)
    let restored = try XCTUnwrap(entries.first { $0.id == incoming.id })
    XCTAssertNil(restored.trigger); XCTAssertTrue(restored.candidateAliases.isEmpty)
    XCTAssertEqual(restored.migrationSource?.originalCode, "OldCode")
    XCTAssertEqual(entries.first { $0.id == existing.id }, existing)
  }

  func testUnicodeNormalizationOnlyIsAnUpdate() throws {
    var item = OwlTemplateEntry(title: "标题", body: "é")
    try OwlTemplateStore.save(.init(entries: [item]), writer: writer)
    item.body = "e\u{301}"
    let preview = try OwlTemplateBackup(rimeDir: root).preview(data: OwlTemplateStore.encoded(.init(entries: [item])))
    XCTAssertEqual(preview.rows[0].kind, .update)
  }

  func testRejectsNewVersionUnknownKeysCorruptAndDuplicateIDs() throws {
    let entry = sample()
    let data = try OwlTemplateStore.encoded(.init(entries: [entry]))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["formatVersion"] = 99
    XCTAssertThrowsError(try OwlTemplateBackup.decode(JSONSerialization.data(withJSONObject: object)))
    object["formatVersion"] = 1; object["future"] = true
    XCTAssertThrowsError(try OwlTemplateBackup.decode(JSONSerialization.data(withJSONObject: object)))
    object.removeValue(forKey: "future")
    var rows = try XCTUnwrap(object["entries"] as? [[String: Any]])
    rows[0]["future"] = NSNull(); object["entries"] = rows
    XCTAssertThrowsError(try OwlTemplateBackup.decode(JSONSerialization.data(withJSONObject: object)))
    XCTAssertThrowsError(try OwlTemplateBackup.decode(Data("{".utf8)))
    XCTAssertThrowsError(try OwlTemplateBackup.decode(OwlTemplateStore.encoded(.init(entries: [entry, entry]))))
  }

  func testStalePreviewDoesNotOverwriteLaterEdit() throws {
    let item = sample()
    try OwlTemplateStore.save(.init(entries: [item]), writer: writer)
    let backup = OwlTemplateBackup(rimeDir: root)
    var addition = OwlTemplateEntry(title: "新增", body: "正文")
    let preview = try backup.preview(data: OwlTemplateStore.encoded(.init(entries: [addition])))
    addition.title = "另一窗口"
    try OwlTemplateStore.save(.init(entries: [item, addition]), writer: writer)
    let before = try snapshot()
    XCTAssertThrowsError(try backup.restore(preview)); XCTAssertEqual(try snapshot(), before)
  }

  func testDeleteFailureAtEveryWriteBoundaryRestoresAllBytes() throws {
    let item = sample()
    let saved = OwlTemplateLibrary(entries: [item])
    try OwlTemplateStore.save(saved, writer: writer)
    let before = try snapshot()
    let names = [OwlTemplateStore.fileName, OwlTemplateStore.dictFileName, "rime_ice.custom.yaml", OwlTemplateStore.stateFileName]
    let checkpoints = ["backup", "journal", "completed"] + names + names.flatMap { ["replaced:" + $0, "manifest:" + $0] }
    for point in checkpoints {
      // The YAML no-op does not reach writer callbacks; before-write is still covered.
      if point == "replaced:rime_ice.custom.yaml" || point == "manifest:rime_ice.custom.yaml" { continue }
      XCTAssertThrowsError(try OwlTemplateBackup(rimeDir: root).delete(id: item.id, expected: saved, checkpoint: {
        if $0 == point { throw CocoaError(.fileWriteNoPermission) }
      }), point)
      XCTAssertEqual(try snapshot(), before, point)
      XCTAssertFalse(OwlTemplateMigration.hasPendingRecovery(rimeDir: root), point)
    }
  }

  func testAlreadyActiveInterruptedTransactionRecoversOldLibrary() throws {
    let old = OwlTemplateLibrary(entries: [sample()])
    try OwlTemplateStore.save(old, writer: writer)
    let before = try snapshot()
    let migration = OwlTemplateMigration(rimeDir: root)
    let writes = try migration.prepareLibraryTransaction(.init(), expected: old)
    // Simulate abrupt termination after the first replacement, without catch/defer recovery.
    let first = try XCTUnwrap(writes.first)
    try Data(first.contents.utf8).write(to: root.appendingPathComponent(first.fileName), options: .atomic)
    XCTAssertThrowsError(try OwlTemplateStore.load(rimeDir: root))
    try OwlTemplateMigration(rimeDir: root).recoverIfNeeded()
    XCTAssertEqual(try snapshot(), before)
  }

  func testAlreadyActiveCompletedTransactionSurvivesBookkeepingInterruption() throws {
    let old = OwlTemplateLibrary(entries: [sample()])
    try OwlTemplateStore.save(old, writer: writer)
    let next = OwlTemplateLibrary(entries: [OwlTemplateEntry(title: "新", body: "新正文")])
    let writes = try OwlTemplateMigration(rimeDir: root).prepareLibraryTransaction(next, expected: old)
    for write in writes { try Data(write.contents.utf8).write(to: root.appendingPathComponent(write.fileName), options: .atomic) }
    try OwlTemplateMigration(rimeDir: root).recoverIfNeeded()
    XCTAssertEqual(try OwlTemplateStore.encoded(OwlTemplateStore.load(rimeDir: root)), try OwlTemplateStore.encoded(next))
  }

  func testTagsSortingCopyAndSourceSearch() throws {
    let model = OwlTemplateEditorModel(writer: writer)
    model.reload(); model.draft = sample()
    model.addTag("  Research  "); model.addTag("research"); model.addTag("A, B")
    XCTAssertEqual(model.draft.tags, ["写作", "Mail, Draft", "Research", "A, B"])
    XCTAssertTrue(model.save())
    let id = model.draft.id
    model.draft.title = "改名"; XCTAssertTrue(model.save()); XCTAssertEqual(model.draft.id, id)
    XCTAssertEqual(OwlTemplateStore.filtered(model.library.entries, query: "OLDCODE", tag: "research").count, 1)
    let copy = model.draft.duplicated()
    XCTAssertNotEqual(copy.id, id); XCTAssertEqual(Data(copy.body.utf8), Data(model.draft.body.utf8))
    XCTAssertEqual(copy.tags, model.draft.tags); XCTAssertNil(copy.trigger); XCTAssertNil(copy.migrationSource)
    XCTAssertEqual(copy.invocationMode, .searchOnly)
    XCTAssertTrue(OwlTemplateStore.filtered(model.library.entries, query: "no-match", tag: nil).isEmpty)
  }
  func testClearingThenRetypingTriggerRetainsOriginalInvocationMode() throws {
    let item = sample()
    var preview = try OwlTemplateBackup(rimeDir: root).preview(data: OwlTemplateStore.encoded(.init(entries: [item])))
    preview.changeTrigger(id: item.id, to: "")
    XCTAssertEqual(preview.rows[0].entry.invocationMode, .searchOnly)
    preview.changeTrigger(id: item.id, to: "newcode")
    XCTAssertEqual(preview.rows[0].entry.invocationMode, .candidate)
    XCTAssertEqual(preview.rows[0].entry.trigger, "newcode")
    XCTAssertTrue(preview.rows[0].entry.candidateAliases.isEmpty)
  }

  func testExternalLibraryEditWhileTakingSnapshotsIsNotOverwritten() throws {
    let old = OwlTemplateLibrary(entries: [sample()])
    try OwlTemplateStore.save(old, writer: writer)
    var external = old; external.entries[0].body = "external update"
    XCTAssertThrowsError(try OwlTemplateMigration(rimeDir: root).commitLibrary(.init(), expected: old, checkpoint: { step in
      if step == "snapshot:" + OwlTemplateStore.fileName {
        try OwlTemplateStore.encoded(external).write(to: self.root.appendingPathComponent(OwlTemplateStore.fileName), options: .atomic)
      }
    }))
    XCTAssertEqual(try OwlTemplateStore.encoded(OwlTemplateStore.load(rimeDir: root)), try OwlTemplateStore.encoded(external))
    XCTAssertFalse(OwlTemplateMigration.hasPendingRecovery(rimeDir: root))
  }

  func testExternalYAMLChangeDuringSnapshotIsPreservedByPreparedWrites() throws {
    let old = OwlTemplateLibrary(entries: [sample()])
    try OwlTemplateStore.save(old, writer: writer)
    try OwlTemplateMigration(rimeDir: root).commitLibrary(.init(), expected: old, checkpoint: { step in
      if step == "snapshot:rime_ice.custom.yaml" {
        let url = self.root.appendingPathComponent("rime_ice.custom.yaml")
        let before = try String(contentsOf: url, encoding: .utf8)
        try (before + "\n  synthetic_external_setting: true\n").write(to: url, atomically: true, encoding: .utf8)
      }
    })
    XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("rime_ice.custom.yaml"), encoding: .utf8).contains("synthetic_external_setting: true"))
  }

  func testReplacingExistingExportKeepsPrivatePermissions() throws {
    try OwlTemplateStore.save(.init(entries: [sample()]), writer: writer)
    let destination = root.appendingPathComponent("existing.json")
    try Data("old".utf8).write(to: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    try OwlTemplateBackup(rimeDir: root).export(to: destination)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(try OwlTemplateBackup.decode(Data(contentsOf: destination)).entries.count, 1)
  }

  func testAnotherDescriptorHoldingWriteLockPreventsMutation() throws {
    let path = root.appendingPathComponent(".owl-template-write.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR, mode_t(0o600))
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    defer { flock(descriptor, LOCK_UN); close(descriptor) }
    XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    XCTAssertThrowsError(try OwlTemplateStore.save(.init(entries: [sample()]), writer: writer))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(OwlTemplateStore.fileName).path))
  }

  func testClipboardEditorRequiresModeAndPreservesAnonymousMetadata() throws {
    let model = OwlTemplateEditorModel(writer: writer)
    model.reload(); model.draft = OwlTemplateEntry(title: "模板", body: "{argument}")
    XCTAssertFalse(model.insertClipboardField())
    model.draft.bodyType = .template; model.draft.syntax = .legacyDoubleBraces
    XCTAssertFalse(model.insertClipboardField())
    model.draft.syntax = .standard
    model.draft.parameters = [.init(key: "a:1", name: "参数 1", isRequired: false, defaultValue: nil, options: [])]
    model.draft.tags = ["标签"]; model.draft.isPinned = true
    model.draft.migrationSource = .init(sourceFile: "synthetic.json", record: 1, originalCode: "old")
    let before = model.draft
    XCTAssertTrue(model.insertClipboardField())
    XCTAssertEqual(model.draft.id, before.id)
    XCTAssertEqual(model.draft.parameters, before.parameters)
    XCTAssertEqual(model.draft.migrationSource, before.migrationSource)
    XCTAssertEqual(model.draft.tags, before.tags); XCTAssertTrue(model.draft.isPinned)
    XCTAssertEqual(model.draft.body, "{argument}{clipboard}")
    XCTAssertTrue(model.save())
    let loaded = try XCTUnwrap(OwlTemplateStore.load(rimeDir: root).entries.first)
    XCTAssertTrue(OwlTemplateEngine.parse(loaded).contextRequirements.contains(.clipboard))
  }

  func testClipboardEditorInvalidSyntaxKeepsDraftAndUnicodeBodyEditKeepsBytes() {
    let model = OwlTemplateEditorModel(writer: writer)
    model.draft = OwlTemplateEntry(title: "模板", body: "{argument name=")
    model.draft.bodyType = .template
    let before = model.draft
    XCTAssertFalse(model.insertClipboardField()); XCTAssertEqual(model.draft, before)
    model.draft.bodyType = .plainText; model.draft.body = "é"
    model.setBody("e\u{301}")
    XCTAssertEqual(Data(model.draft.body.utf8), Data("e\u{301}".utf8))
  }

  func testPreviewCancellationAndDuplicateTitlesPreserveIdentity() throws {
    let first = OwlTemplateEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "同名", body: "first")
    let second = OwlTemplateEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "同名", body: "second")
    let library = OwlTemplateLibrary(entries: [second, first])
    try OwlTemplateStore.save(library, writer: writer)
    let before = try snapshot()
    _ = try OwlTemplateBackup(rimeDir: root).preview(data: OwlTemplateStore.encoded(.init(entries: [sample()])))
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(OwlTemplateStore.sorted(library.entries).map(\.id), [first.id, second.id])
    _ = try OwlTemplateBackup(rimeDir: root).delete(id: second.id, expected: library)
    XCTAssertEqual(try OwlTemplateStore.load(rimeDir: root).entries.map(\.id), [first.id])
  }

  func testTemporalEditorInsertsAllKindsAndPreservesMetadata() throws {
    let model = OwlTemplateEditorModel(writer: writer)
    model.reload()
    for kind in OwlTemplateEngine.TemporalKind.allCases {
      model.draft = OwlTemplateEntry(title: kind.rawValue, body: "{argument}")
      model.draft.bodyType = .template
      model.draft.parameters = [.init(key: "a:1", name: "参数 1", isRequired: false, defaultValue: "保留", options: [])]
      model.draft.tags = ["日期"]; model.draft.isPinned = true
      let before = model.draft
      XCTAssertTrue(model.insertTemporalField(kind: kind, format: "", offset: "  "))
      XCTAssertEqual(model.draft.body, "{argument}{" + kind.rawValue + "}")
      XCTAssertEqual(model.draft.id, before.id)
      XCTAssertEqual(model.draft.parameters, before.parameters)
      XCTAssertEqual(model.draft.tags, before.tags); XCTAssertTrue(model.draft.isPinned)
      XCTAssertTrue(model.save())
      let saved = try XCTUnwrap(OwlTemplateStore.load(rimeDir: root).entries.first { $0.id == before.id })
      XCTAssertTrue(OwlTemplateEngine.parse(saved).contextRequirements.contains(.temporal))
    }
  }

  func testTemporalEditorKeepsFormatWhitespaceAndRejectsInvalidAttributes() {
    let model = OwlTemplateEditorModel(writer: writer)
    model.draft = OwlTemplateEntry(title: "日期", body: "前文")
    model.draft.bodyType = .template
    XCTAssertTrue(model.insertTemporalField(kind: .datetime, format: "  yyyy-MM-dd'T'HH:mm:ssXXX  ", offset: "+1M -2d"))
    XCTAssertEqual(model.draft.body, "前文{datetime format=\"  yyyy-MM-dd'T'HH:mm:ssXXX  \" offset=\"+1M -2d\"}")
    let before = model.draft
    XCTAssertFalse(model.insertTemporalField(kind: .date, format: "jj", offset: ""))
    XCTAssertEqual(model.draft, before)
    XCTAssertFalse(model.insertTemporalField(kind: .time, format: "HH:mm:ss", offset: "1d"))
    XCTAssertEqual(model.draft, before)
    XCTAssertFalse(model.insertTemporalField(kind: .date, format: "yyyy 'unclosed", offset: ""))
    XCTAssertEqual(model.draft, before)
  }

  func testTemporalEditorRequiresExplicitTemplateAndSyntaxMode() {
    let model = OwlTemplateEditorModel(writer: writer)
    model.draft = OwlTemplateEntry(title: "普通文本", body: "body")
    let original = model.draft
    XCTAssertFalse(model.insertTemporalField(kind: .date, format: "", offset: ""))
    XCTAssertEqual(model.draft, original)
    model.draft.bodyType = .template; model.draft.syntax = .legacyDoubleBraces
    let legacy = model.draft
    XCTAssertFalse(model.insertTemporalField(kind: .time, format: "", offset: ""))
    XCTAssertEqual(model.draft, legacy)
    model.draft.syntax = .standard
    XCTAssertTrue(model.insertTemporalField(kind: .time, format: "HH:mm:ss", offset: "+30m"))
  }

  func testAutomaticEditorAcceptsDynamicTemplatesAndPreservesExplicitMode() throws {
    let model = OwlTemplateEditorModel(writer: writer)
    model.draft = OwlTemplateEntry(title: "自动", body: "{clipboard}{cursor}尾")
    model.draft.bodyType = .template
    model.draft.trigger = ";;dynamic"
    model.draft.expansionMode = .delimiterDrop
    model.draft.candidateAliases = ["vold"]
    model.setInvocationMode(.automatic)
    XCTAssertEqual(model.draft.invocationMode, .automatic)
    XCTAssertEqual(model.draft.expansionMode, .immediate, "An explicit transition initializes immediate expansion")
    XCTAssertTrue(model.draft.candidateAliases.isEmpty)
    XCTAssertTrue(model.insertClipboardField())
    XCTAssertTrue(model.insertTemporalField(kind: .date, format: "yyyy", offset: ""))
    XCTAssertEqual(model.draft.invocationMode, .automatic)
    XCTAssertTrue(model.save(), model.status)
    XCTAssertEqual(try OwlTemplateStore.load(rimeDir: root).entries.first, model.draft)

    model.draft.expansionMode = .delimiterKeep
    model.setInvocationMode(.automatic)
    XCTAssertEqual(model.draft.expansionMode, .delimiterKeep, "Loading an existing mode must not silently rewrite it")
    XCTAssertTrue(model.save(), model.status)
    let saved = model.library
    let savedBytes = try snapshot()
    model.draft.body = "前{cursor}{cursor}后"
    XCTAssertFalse(model.save(), "Invalid dynamic syntax must not replace the saved automatic entry")
    XCTAssertEqual(model.library, saved)
    XCTAssertEqual(try snapshot(), savedBytes)
    XCTAssertEqual(model.draft.body, "前{cursor}{cursor}后")

    model.draft.bodyType = .plainText
    let plain = model.draft
    XCTAssertFalse(model.insertClipboardField())
    XCTAssertFalse(model.insertTemporalField(kind: .date, format: "", offset: ""))
    XCTAssertEqual(model.draft, plain)
  }

  func testAutomaticPreferencesUseInjectedDefaultsAndReloadBoundDirectory() throws {
    let suite = "OwlTemplateBackupTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var item = OwlTemplateEntry(title: "自动", body: "body")
    item.trigger = ";;a"; item.invocationMode = .automatic; item.expansionMode = .immediate
    try OwlTemplateStore.save(.init(entries: [item]), writer: writer)
    let runtime = OwlAutomaticExpansionRuntime()
    let model = OwlTemplateEditorModel(writer: writer, defaults: defaults, automaticRuntime: runtime)
    XCTAssertFalse(model.automaticEnabled)
    model.setAutomaticEnabled(true)
    XCTAssertTrue(defaults.bool(forKey: OwlAutomaticExpansionRuntime.enabledKey))
    XCTAssertTrue(runtime.allows(bundleID: "com.apple.TextEdit"))
    XCTAssertTrue(model.addDisabledBundleID(" COM.APPLE.TEXTEDIT "))
    XCTAssertTrue(model.addDisabledBundleID("com.apple.textedit"))
    XCTAssertEqual(model.disabledBundleIDs, ["com.apple.textedit"])
    XCTAssertFalse(runtime.allows(bundleID: "com.apple.TextEdit"))
    XCTAssertFalse(model.addDisabledBundleID("not a bundle id"))
    model.removeDisabledBundleID("COM.APPLE.TEXTEDIT")
    XCTAssertTrue(runtime.allows(bundleID: "com.apple.TextEdit"))
    model.setAutomaticEnabled(false)
    XCTAssertFalse(runtime.allows(bundleID: "com.apple.TextEdit"))
  }

  func testFinalTransactionNotificationRefreshesAutomaticIndexOnlyAfterJournalSettles() throws {
    let suite = "OwlTemplateBackupTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: OwlAutomaticExpansionRuntime.enabledKey)
    var item = OwlTemplateEntry(title: "自动", body: "body")
    item.trigger = ";;a"; item.invocationMode = .automatic; item.expansionMode = .immediate
    let library = OwlTemplateLibrary(entries: [item])
    try OwlTemplateStore.save(library, writer: writer)
    let runtime = OwlAutomaticExpansionRuntime()
    try runtime.reload(rimeDir: root, defaults: defaults)
    XCTAssertTrue(runtime.allows(bundleID: "com.example.Host"))
    var publications = 0
    let observer = NotificationCenter.default.addObserver(forName: OwlTemplateStore.libraryDidCommit, object: nil, queue: nil) { notification in
      guard let directory = notification.object as? URL,
            directory.standardizedFileURL == self.root.standardizedFileURL else { return }
      publications += 1
      XCTAssertFalse(OwlTemplateMigration.hasPendingRecovery(rimeDir: directory))
      do {
        _ = try OwlTemplateStore.load(rimeDir: directory)
      } catch {
        XCTFail("Committed library must be readable when published: \(error)")
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let backup = OwlTemplateBackup(rimeDir: root)
    XCTAssertThrowsError(try backup.delete(id: item.id, expected: library, checkpoint: { step in
      XCTAssertEqual(publications, 0, "Staged writes must not publish")
      if step == "completed" { throw CocoaError(.fileWriteNoPermission) }
    }))
    XCTAssertEqual(publications, 0)
    XCTAssertTrue(runtime.allows(bundleID: "com.example.Host"))
    _ = try backup.delete(id: item.id, expected: library)
    XCTAssertEqual(publications, 1)
    XCTAssertFalse(runtime.allows(bundleID: "com.example.Host"))
    _ = try backup.restore(backup.preview(data: OwlTemplateStore.encoded(library)))
    XCTAssertEqual(publications, 2)
    XCTAssertTrue(runtime.allows(bundleID: "com.example.Host"))
  }

  func testRecoveredJournalRefreshesPreviouslyDisabledAutomaticRuntime() throws {
    let suite = "OwlTemplateBackupTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: OwlAutomaticExpansionRuntime.enabledKey)
    var item = OwlTemplateEntry(title: "自动", body: "body")
    item.trigger = ";;a"; item.invocationMode = .automatic; item.expansionMode = .immediate
    let library = OwlTemplateLibrary(entries: [item])
    try OwlTemplateStore.save(library, writer: writer)
    let runtime = OwlAutomaticExpansionRuntime()
    try runtime.reload(rimeDir: root, defaults: defaults)
    let writes = try OwlTemplateMigration(rimeDir: root).prepareLibraryTransaction(.init(), expected: library)
    let first = try XCTUnwrap(writes.first)
    try Data(first.contents.utf8).write(to: root.appendingPathComponent(first.fileName), options: .atomic)
    XCTAssertThrowsError(try runtime.reload(rimeDir: root, defaults: defaults))
    XCTAssertFalse(runtime.allows(bundleID: "com.example.Host"))
    try OwlTemplateMigration(rimeDir: root).recoverIfNeeded()
    XCTAssertTrue(runtime.allows(bundleID: "com.example.Host"))
  }

}
