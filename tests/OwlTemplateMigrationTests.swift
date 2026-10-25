import XCTest
@testable import Owltype

@MainActor
final class OwlTemplateMigrationTests: XCTestCase {
  private var root: URL!
  private var migration: OwlTemplateMigration { OwlTemplateMigration(rimeDir: root) }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("OwlMigration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  private func write(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(name))
  }
  private func seed() throws {
    try write("owl_quick_send.json", #"[{"text":"  原文 {{clipboard}}  ","code":"hello"}]"#)
    try write("owl_prompts.json", #"[{"code":"prompt","title":"题名","body":"\n{clipboard} {{clipboard}} {{x}}\t ","category":"写作"}]"#)
  }
  func testMigrationPreservesBytesIDsAliasesAndLegacySemantics() throws {
    try seed()
    let before = try Data(contentsOf: root.appendingPathComponent("owl_quick_send.json"))
    let plan = try migration.prepare()
    XCTAssertTrue(plan.issues.isEmpty)
    XCTAssertEqual(plan.entries.count, 2)
    XCTAssertEqual(try migration.prepare().entries.map(\.id), plan.entries.map(\.id))
    try migration.commit(plan)
    let library = try OwlTemplateStore.load(rimeDir: root)
    XCTAssertEqual(library.entries.map(\.id), plan.entries.map(\.id))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("owl_quick_send.json")), before)
    XCTAssertEqual(OwlTemplateStore.mode(rimeDir: root), .unified)
    let prompt = try XCTUnwrap(library.entries.first { $0.category == .prompt })
    XCTAssertEqual(prompt.syntax, .legacyDoubleBraces)
    XCTAssertEqual(prompt.tags, ["写作"])
    XCTAssertEqual(prompt.body, "\n{clipboard} {{clipboard}} {{x}}\t ")
    XCTAssertEqual(prompt.candidateAliases, ["vprompt"])
    XCTAssertTrue(prompt.parameters.allSatisfy { !$0.isRequired && $0.defaultValue == "" })
    for code in ["prompt", "vprompt"] {
      XCTAssertEqual(OwlTemplateStore.resolveCandidate(code: code, text: OwlTemplateStore.candidateText(prompt), loadLibrary: { library })?.id, prompt.id)
    }
    var delivered: [String] = []
    let invocation = OwlTemplateInvocation(content: .template(prompt), broker: OwlPanelInsertionBroker(), deliver: { delivered.append($0.text); return .confirmed })
    invocation.confirm(values: ["clipboard": "", "x": "值"])
    invocation.confirm(values: [:])
    XCTAssertEqual(delivered, ["\n{clipboard}  值\t "])
    XCTAssertFalse(try migration.runAutomatically())
    XCTAssertEqual(try OwlTemplateStore.load(rimeDir: root).entries.map(\.id), library.entries.map(\.id))
  }
  func testRawAuditReportsAllBadRecordsWithoutFallbackOrPartialCommit() throws {
    try write("owl_quick_send.json", #"[null,{"text":5,"code":"x"},{"text":"ok","code":"UP"},{"text":" ","code":"blank"}]"#)
    try write("owl_quick_send.txt", "fallback\tf\t1\n")
    try write("owl_prompts.json", "{broken")
    let plan = try migration.prepare()
    XCTAssertGreaterThanOrEqual(plan.issues.count, 5)
    XCTAssertFalse(plan.entries.contains { $0.body == "fallback" })
    XCTAssertThrowsError(try migration.commit(plan))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(OwlTemplateStore.fileName).path))
  }
  func testConflictsKeepBothRecordsAndOnlySearchPreservesOriginalCode() throws {
    try seed()
    try write("owl_quick_send.json", #"[{"text":"甲","code":"prompt"},{"text":"乙","code":"vprompt"}]"#)
    var plan = try migration.prepare()
    XCTAssertFalse(migration.conflicts(in: plan).isEmpty)
    XCTAssertThrowsError(try migration.commit(plan))
    for entry in plan.entries where entry.category == .general {
      plan = try migration.resolve(plan, id: entry.id, code: nil)
    }
    XCTAssertTrue(migration.conflicts(in: plan).isEmpty)
    try migration.commit(plan)
    let entries = try OwlTemplateStore.load(rimeDir: root).entries
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(entries.filter { $0.invocationMode == .searchOnly }.compactMap { $0.migrationSource?.originalCode }.sorted(), ["prompt", "vprompt"])
  }
  func testExistingUnactivatedNewEntriesAreKept() throws {
    try seed()
    let existing = OwlTemplateEntry(title: "新库已有", body: "保留")
    try JSONEncoder().encode(OwlTemplateLibrary(entries: [existing])).write(to: root.appendingPathComponent(OwlTemplateStore.fileName))
    let plan = try migration.prepare()
    XCTAssertEqual(plan.existingEntries, [existing])
    try migration.commit(plan)
    XCTAssertEqual(try OwlTemplateStore.load(rimeDir: root).entries.first, existing)
  }
  func testTXTOnlyCollapseHasSourceAccountingAndBadRowsBlock() throws {
    try write("owl_quick_send.txt", "# Rime table\n正文\tabc\t1\n正文\tvabc\t1\n正文\tvvabc\t1\n不同\tvip\t1\n")
    let plan = try migration.prepare()
    XCTAssertEqual(plan.entries.compactMap(\.trigger), ["abc", "vip"])
    XCTAssertEqual(plan.collapsedRows, 2)
    try write("owl_quick_send.txt", "正文\tabc\t1\nbad row\n")
    XCTAssertFalse(try migration.prepare().issues.isEmpty)
  }
  func testSourceChangedAfterPlanCannotBeOverwritten() throws {
    try seed()
    let plan = try migration.prepare()
    try write("owl_prompts.json", "[]")
    XCTAssertThrowsError(try migration.commit(plan))
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("owl_prompts.json"), encoding: .utf8), "[]")
  }
  func testEachWriteFailureRestoresBytesExistenceAndStableIDs() throws {
    try seed()
    try write("rime_ice.custom.yaml", "patch:\n  user_key: retained\n")
    let plan = try migration.prepare()
    let names = [OwlTemplateStore.fileName, OwlTemplateStore.dictFileName, "rime_ice.custom.yaml", OwlTemplateStore.stateFileName, "owltype/rollback-manifest.json"]
    let before = names.map { try? Data(contentsOf: root.appendingPathComponent($0)) }
    let writes = [OwlTemplateStore.fileName, OwlTemplateStore.dictFileName, "rime_ice.custom.yaml", OwlTemplateStore.stateFileName]
    let stages = ["journal"] + names.map { "snapshot:" + $0 } + writes + writes.flatMap { name in
      ["backup:" + name, "replaced:" + name, "manifest:" + name]
    }
    for stage in stages {
      XCTAssertThrowsError(try migration.commit(plan, checkpoint: { if $0 == stage { throw CocoaError(.fileWriteNoPermission) } }))
      XCTAssertEqual(names.map { try? Data(contentsOf: root.appendingPathComponent($0)) }, before)
      XCTAssertEqual(try migration.prepare().entries.map(\.id), plan.entries.map(\.id))
    }
    try migration.commit(plan)
  }
  func testInterruptedWritesRecoverFromJournalInNewInstance() throws {
    try seed()
    let plan = try migration.prepare()
    let writes = try migration.prepareTransaction(plan)
    try write(OwlTemplateStore.fileName, try XCTUnwrap(writes.first?.contents))
    XCTAssertNotEqual(OwlTemplateStore.mode(rimeDir: root), .legacy)
    try OwlTemplateMigration(rimeDir: root).recoverIfNeeded()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(OwlTemplateStore.fileName).path))
    XCTAssertEqual(OwlTemplateStore.mode(rimeDir: root), .legacy)
    XCTAssertEqual(try migration.prepare().entries.map(\.id), plan.entries.map(\.id))
  }
  func testOldPatchBlocksDisabledWithoutChangingUserFragmentOrOldFiles() throws {
    try seed()
    let writer = OwlConfigWriter(rimeDir: root)
    try writer.apply(fileName: "rime_ice.custom.yaml", block: OwlPromptStore.rimeIcePatchBlock)
    try OwlQuickSendStore.save([OwlQuickSendEntry(text: "短句", code: "short")], writer: writer)
    let path = root.appendingPathComponent("rime_ice.custom.yaml")
    let prior = try String(contentsOf: path, encoding: .utf8)
    try (prior + "\n  user_setting: true\n").write(to: path, atomically: true, encoding: .utf8)
    let legacy = try Data(contentsOf: root.appendingPathComponent("owl_quick_send.txt"))
    try migration.commit(migration.prepare())
    let after = try String(contentsOf: path, encoding: .utf8)
    XCTAssertFalse(after.contains("table_translator@owl_prompts"))
    XCTAssertFalse(after.contains("table_translator@owl_quick_send"))
    XCTAssertTrue(after.contains("table_translator@owl_templates"))
    XCTAssertTrue(after.contains("user_setting: true"))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("owl_quick_send.txt")), legacy)
  }
  func testEveryInterruptedStagingBoundaryRestoresBeforeActivationAndFinishesAfterIt() throws {
    try seed()
    let plan = try migration.prepare()
    for count in 0...4 {
      let writes = try migration.prepareTransaction(plan)
      let writer = OwlConfigWriter(rimeDir: root)
      for write in writes.prefix(count) {
        try writer.applyTextFile(fileName: write.fileName, contents: write.contents, marker: write.marker, timestamp: "migration-" + plan.id.uuidString)
      }
      try OwlTemplateMigration(rimeDir: root).recoverIfNeeded()
      if count == writes.count {
        XCTAssertEqual(OwlTemplateStore.mode(rimeDir: root), .unified)
        XCTAssertEqual(try OwlTemplateStore.load(rimeDir: root).entries.map(\.id), plan.entries.map(\.id))
      } else {
        XCTAssertEqual(OwlTemplateStore.mode(rimeDir: root), .legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(OwlTemplateStore.fileName).path))
      }
    }
  }

  func testRecoveryFailureKeepsJournalAndCanBeRetried() throws {
    try seed()
    try write("rime_ice.custom.yaml", "patch:\n  preserved: true\n")
    let plan = try migration.prepare()
    let writes = try migration.prepareTransaction(plan)
    let patch = root.appendingPathComponent("rime_ice.custom.yaml")
    for write in writes.dropLast() {
      try OwlConfigWriter(rimeDir: root).applyTextFile(fileName: write.fileName, contents: write.contents,
        marker: write.marker, timestamp: "migration-" + plan.id.uuidString)
    }
    XCTAssertThrowsError(try migration.recoverIfNeeded(beforeRestore: { name in
      if name == "rime_ice.custom.yaml" { throw CocoaError(.fileWriteNoPermission) }
    }))
    XCTAssertTrue(OwlTemplateMigration.hasPendingRecovery(rimeDir: root))
    XCTAssertThrowsError(try OwlTemplateStore.save(OwlTemplateLibrary(), writer: OwlConfigWriter(rimeDir: root)))
    try migration.recoverIfNeeded()
    XCTAssertEqual(try String(contentsOf: patch, encoding: .utf8), "patch:\n  preserved: true\n")
    XCTAssertFalse(OwlTemplateMigration.hasPendingRecovery(rimeDir: root))
  }

  func testCorruptJournalBlocksRecoveryWithoutReplacingAnySource() throws {
    try seed()
    let plan = try migration.prepare()
    try migration.prepareTransaction(plan)
    let source = try Data(contentsOf: root.appendingPathComponent("owl_prompts.json"))
    try write(".owl-template-migration/journal.json", "{broken")
    XCTAssertThrowsError(try migration.recoverIfNeeded())
    XCTAssertTrue(OwlTemplateMigration.hasPendingRecovery(rimeDir: root))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("owl_prompts.json")), source)
  }

  func testCommittedLibraryEditsSurviveSubsequentStartup() throws {
    try seed()
    try migration.commit(migration.prepare())
    var library = try OwlTemplateStore.load(rimeDir: root)
    library.entries[0].body = "new edit"
    try OwlTemplateStore.save(library, writer: OwlConfigWriter(rimeDir: root))
    XCTAssertFalse(try migration.runAutomatically())
    XCTAssertEqual(try OwlTemplateStore.load(rimeDir: root).entries[0].body, "new edit")
  }

  func testInvalidCodeCanBeExplicitlyResolvedAndModelRetainsFailureState() throws {
    try write("owl_quick_send.json", #"[{"text":"原文","code":"UP"}]"#)
    let model = OwlTemplateMigrationModel(rimeDir: root)
    model.reload()
    XCTAssertFalse(model.canCommit)
    let id = try XCTUnwrap(model.plan?.entries.first?.id)
    model.resolve(id: id, code: "fixed")
    XCTAssertTrue(model.canCommit)
    XCTAssertEqual(model.plan?.entries.first?.migrationSource?.originalCode, "UP")
    try write("owl_quick_send.json", "[]")
    XCTAssertFalse(model.commit())
    XCTAssertFalse(model.completed)
    XCTAssertEqual(model.plan?.entries.first?.id, id)
    XCTAssertFalse(model.status.isEmpty)
  }

  func testMetadataAndBackupsUsePrivatePermissions() throws {
    try seed()
    try migration.commit(migration.prepare())
    for name in [".owl-template-migration/plan.json", ".owl-template-migration/journal.json", OwlTemplateStore.fileName] {
      let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
      XCTAssertEqual(permissions?.intValue, 0o600)
    }
    let library = try OwlTemplateStore.load(rimeDir: root)
    XCTAssertEqual(library.entries.first?.migrationSource?.sourceFile, "owl_quick_send.json")
  }

  func testActivatedInterruptedTransactionNeverOverwritesChangedNewLibrary() throws {
    try seed()
    let plan = try migration.prepare()
    let writes = try migration.prepareTransaction(plan)
    for write in writes {
      try OwlConfigWriter(rimeDir: root).applyTextFile(fileName: write.fileName, contents: write.contents,
        marker: write.marker, timestamp: "migration-" + plan.id.uuidString)
    }
    var edited = plan.library
    edited.entries[0].body = "external edit after activation"
    let editedBytes = try JSONEncoder().encode(edited)
    try editedBytes.write(to: root.appendingPathComponent(OwlTemplateStore.fileName))
    XCTAssertThrowsError(try migration.recoverIfNeeded())
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(OwlTemplateStore.fileName)), editedBytes)
    XCTAssertTrue(OwlTemplateMigration.hasPendingRecovery(rimeDir: root))
  }

  func testManualRecoveryOfCompletedActivationPublishesCompletedState() throws {
    try seed()
    let plan = try migration.prepare()
    let writes = try migration.prepareTransaction(plan)
    for write in writes {
      try OwlConfigWriter(rimeDir: root).applyTextFile(fileName: write.fileName, contents: write.contents,
        marker: write.marker, timestamp: "migration-" + plan.id.uuidString)
    }
    let model = OwlTemplateMigrationModel(rimeDir: root)
    model.reload()
    XCTAssertTrue(model.completed)
    XCTAssertFalse(model.canCommit)
    XCTAssertEqual(OwlTemplateStore.mode(rimeDir: root), .unified)
  }

  func testUncommittedRecoveryRefusesUnknownExternalTargetChanges() throws {
    try seed()
    let plan = try migration.prepare()
    try migration.prepareTransaction(plan)
    try write(OwlTemplateStore.fileName, "external new file")
    XCTAssertThrowsError(try migration.recoverIfNeeded())
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(OwlTemplateStore.fileName), encoding: .utf8), "external new file")
  }

  func testRollbackInterruptedAfterActivationCanContinueInNewInstance() throws {
    try seed()
    let plan = try migration.prepare()
    XCTAssertThrowsError(try migration.commit(plan, checkpoint: { step in
      if step == "manifest:" + OwlTemplateStore.stateFileName || step == "restore:" + OwlTemplateStore.stateFileName {
        throw CocoaError(.fileWriteNoPermission)
      }
    }))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(OwlTemplateStore.stateFileName).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(OwlTemplateStore.fileName).path))
    XCTAssertTrue(OwlTemplateMigration.hasPendingRecovery(rimeDir: root))
    try OwlTemplateMigration(rimeDir: root).recoverIfNeeded()
    XCTAssertEqual(OwlTemplateStore.mode(rimeDir: root), .legacy)
    XCTAssertEqual(try migration.prepare().entries.map(\.id), plan.entries.map(\.id))
  }

  /// Pending recovery must block configuration deployment, never input itself.
  func testPendingRecoveryKeepsRimeRunningButSkipsDeployment() throws {
    try seed()
    try migration.prepareTransaction(migration.prepare())
    let delegate = OwlApplicationDelegate()
    let engine = FakeRimeEngine()
    delegate.engine = engine
    XCTAssertFalse(delegate.startRime(fullCheck: true, migrationDirectory: root))
    XCTAssertTrue(engine.lifecycleTrace.isEmpty)
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)
    // The complete settings path must reject edits before touching recovery inputs.
    let before = try? Data(contentsOf: root.appendingPathComponent("rime_ice.custom.yaml"))
    let application = OwlKeyboardSettingsApplication(
      engine: engine, directory: root, activeSchema: { "rime_ice" },
      refresh: { XCTFail("Recovery must block settings activation") })
    XCTAssertThrowsError(try application.apply(.current(), mode: .config))
    XCTAssertEqual(try? Data(contentsOf: root.appendingPathComponent("rime_ice.custom.yaml")), before)
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)

    try OwlTemplateMigration(rimeDir: root).recoverIfNeeded()
    XCTAssertTrue(delegate.startRime(fullCheck: true, migrationDirectory: root))
    XCTAssertEqual(engine.lifecycleTrace, ["startMaintenance"])
  }

}
