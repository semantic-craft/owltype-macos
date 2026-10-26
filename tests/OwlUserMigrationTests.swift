//
//  OwlUserMigrationTests.swift
//  OwltypeTests
//
//  Synthetic coverage for #260: stable Rime snapshots, mapping, pins, and retryable staging.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlUserMigrationTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwlUserMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    root = nil
    try super.tearDownWithError()
  }

  func testDiscoversOnlyTheStableTwoLevelSnapshotLayout() throws {
    let valid = try writeSnapshot(
      installation: "a94a2c5e",
      schema: "rime_ice",
      lines: ["# Rime user dictionary", "ni hao \t你好\tc=5 d=0.25 t=9"]
    )
    try Data("not discovered".utf8).write(to: root.appendingPathComponent("root.userdb.txt"))
    try writeSnapshot(
      installation: "a94a2c5e",
      schema: "ignored",
      relativeDirectory: "nested",
      lines: ["x\t不该读取\tc=1 d=0 t=1"]
    )
    let link = root.appendingPathComponent("sync/a94a2c5e/linked.userdb.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)

    let scan = try OwlRimeUserDBSnapshotReader.scan(root: root)

    XCTAssertEqual(scan.captures.map(\.relativePath), ["sync/a94a2c5e/rime_ice.userdb.txt"])
    XCTAssertEqual(scan.captures[0].entries.count, 1)
    XCTAssertTrue(scan.issues.contains {
      $0.code == .sourceSymlink && $0.source == "sync/a94a2c5e/linked.userdb.txt"
    })
  }

  func testRejectsNonUTF8SnapshotAndRecordsItExplicitly() throws {
    let directory = root.appendingPathComponent("sync/install-a", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0x00]).write(
      to: directory.appendingPathComponent("rime_ice.userdb.txt")
    )

    let scan = try OwlRimeUserDBSnapshotReader.scan(root: root)

    XCTAssertTrue(scan.captures.isEmpty)
    XCTAssertEqual(scan.issues.map(\.code), [.sourceNotUTF8])
  }

  func testMapsPinyinWubiAndNegativeCommits() throws {
    try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: [
        "#@db_name\trime_ice.userdb",
        "ni hao \t你好\tc=5 d=0.5 t=7",
        "ni'hao\t拟好\tc=5 d=0.2 t=7",
        "shan shui\t山水\tc=-3 d=0 t=7",
      ]
    )
    try writeSnapshot(
      installation: "install-b",
      schema: "luna_pinyin_fluency",
      lines: ["ni hao \t你好\tc=9 d=0.1 t=8"]
    )
    try writeSnapshot(
      installation: "install-a",
      schema: "wubi86_jidian",
      lines: ["abcd\t测试\tc=3 d=0 t=1"]
    )
    try writeSnapshot(
      installation: "install-a",
      schema: "wubi98_jidian",
      lines: ["kkll\t词条\tc=-1 d=0 t=1"]
    )

    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: nil)

    XCTAssertEqual(plan.manifest.schemaVersion, 1)
    XCTAssertEqual(plan.manifest.mapperVersion, "rime-userdb-v1")
    XCTAssertNotNil(plan.manifest.requestID.range(
      of: #"^owlrime-migrate-[0-9a-f]{64}$"#,
      options: .regularExpression
    ))
    XCTAssertNotEqual(plan.manifest.requestID, "owlrime-migrate-\(plan.manifest.sourceDigest)")
    XCTAssertEqual(plan.manifest.sources.count, 4)
    XCTAssertEqual(plan.records.count, 5)
    XCTAssertEqual(record("pinyin", "ni'hao", "你好", in: plan)?.data.weight, 9)
    XCTAssertEqual(record("pinyin", "ni'hao", "拟好", in: plan)?.data.weight, 5)
    XCTAssertEqual(record("pinyin", "shan'shui", "山水", in: plan)?.deleted, true)
    XCTAssertEqual(record("pinyin", "shan'shui", "山水", in: plan)?.data.weight, 0)
    XCTAssertEqual(record("wubi", "abcd", "测试", in: plan)?.data.weight, 3)
    XCTAssertEqual(record("wubi98", "kkll", "词条", in: plan)?.deleted, true)
    XCTAssertTrue(plan.manifest.issues.contains {
      $0.code == .coalescedEntry && $0.message.contains("5 与 9")
    })
    XCTAssertTrue(plan.manifest.limitations.contains { $0.contains("user_inserted=false") })
  }

  func testReportsUnsupportedSchemaAndMalformedRecordsWithoutSilentLoss() throws {
    try writeSnapshot(
      installation: "install-a",
      schema: "unknown_schema",
      lines: ["code\t词\tc=4 d=0 t=1"]
    )
    try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: [
        "#@broken-metadata",
        "missing-tabs",
        "bad-value\t错误\tc=1 d=0",
        "zero\t零\tc=0 d=0 t=1",
        "# no comment",
        "#tag\t标签\tc=2 d=0 t=1",
      ]
    )

    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: nil)

    XCTAssertEqual(plan.records.count, 2)
    XCTAssertEqual(record("pinyin", "zero", "零", in: plan)?.data.weight, 1)
    XCTAssertNotNil(record("pinyin", "#tag", "标签", in: plan))
    XCTAssertTrue(plan.manifest.issues.contains { $0.code == .unsupportedSchema && $0.count == 1 })
    XCTAssertTrue(plan.manifest.issues.contains { $0.code == .invalidMetadata })
    XCTAssertTrue(plan.manifest.issues.contains {
      $0.code == .invalidEntry && $0.line == 2
    })
    XCTAssertTrue(plan.manifest.issues.contains {
      $0.code == .invalidEntry && $0.line == 3
    })
  }

  func testPinnedWordsKeepOrderAndDuplicatesAreReported() throws {
    let first = OwlPinnedWord(code: "shi xing", text: "施行", traditional: false)
    let second = OwlPinnedWord(code: "shi xing", text: "试行", traditional: false)
    let traditional = OwlPinnedWord(code: "shi xing", text: "試行", traditional: true)
    let pinsData = try JSONEncoder().encode([first, second, first, traditional])

    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: pinsData)

    XCTAssertEqual(plan.manifest.pins.map(\.text), ["施行", "试行", "試行"])
    XCTAssertEqual(plan.manifest.pins.map(\.traditional), [false, false, true])
    XCTAssertTrue(plan.manifest.issues.contains { $0.code == .coalescedPin })
    XCTAssertTrue(plan.manifest.limitations.contains { $0.contains("owl_pinned_words") })
    XCTAssertTrue(plan.manifest.limitations.contains { $0.contains("pinned_candidates") })
  }

  func testInvalidPinnedWordsAreReportedAndRimeEntriesStillMigrate() throws {
    try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: ["ni hao \t你好\tc=2 d=0 t=1"]
    )

    let plan = try OwlUserMigration.makePlan(
      userData: root,
      pinnedWordsData: Data("{not-json".utf8)
    )

    XCTAssertEqual(plan.records.count, 1)
    XCTAssertTrue(plan.manifest.pins.isEmpty)
    XCTAssertTrue(plan.manifest.issues.contains { $0.code == .invalidPinnedWords })
  }

  func testStagingIsDeterministicAndRepeatedPreparationReusesIt() throws {
    let snapshot = try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: ["ni hao \t你好\tc=4 d=0 t=1"]
    )
    let sourceBefore = try Data(contentsOf: snapshot)
    let pins = try JSONEncoder().encode([
      OwlPinnedWord(code: "ni hao", text: "你好", traditional: false),
    ])
    let firstPlan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: pins)

    let first = try OwlUserMigrationStage.prepare(firstPlan, in: root)
    let manifestBefore = try Data(contentsOf: first.directory.appendingPathComponent("manifest.json"))
    let recordsBefore = try Data(
      contentsOf: first.directory.appendingPathComponent("dictionary-state.ndjson")
    )
    let secondPlan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: pins)
    let second = try OwlUserMigrationStage.prepare(secondPlan, in: root)

    XCTAssertEqual(first.disposition, .prepared)
    XCTAssertEqual(second.disposition, .reused)
    XCTAssertEqual(firstPlan.manifest.requestID, secondPlan.manifest.requestID)
    XCTAssertEqual(first.directory, second.directory)
    XCTAssertEqual(
      try Data(contentsOf: first.directory.appendingPathComponent("manifest.json")),
      manifestBefore
    )
    XCTAssertEqual(
      try Data(contentsOf: first.directory.appendingPathComponent("dictionary-state.ndjson")),
      recordsBefore
    )
    XCTAssertEqual(try Data(contentsOf: snapshot), sourceBefore)

    let line = try XCTUnwrap(
      String(data: recordsBefore, encoding: .utf8)?.split(separator: "\n").first
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    XCTAssertEqual(object["type"] as? String, "overlay")
    XCTAssertEqual(object["deleted"] as? Bool, false)
    let body = try XCTUnwrap(object["data"] as? [String: Any])
    XCTAssertEqual(body["kind"] as? String, "pinyin")
    XCTAssertEqual(body["code"] as? String, "ni'hao")
    XCTAssertEqual(body["word"] as? String, "你好")
    XCTAssertEqual(body["weight"] as? Int, 4)
    XCTAssertEqual(body["user_inserted"] as? Bool, false)
  }

  func testStagingCanLiveOutsideTheLegacyRimeRoot() throws {
    let snapshot = try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: ["ni hao \t你好\tc=4 d=0 t=1"]
    )
    let sourceBefore = try Data(contentsOf: snapshot)
    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: nil)
    let rustUserRoot = root.appendingPathComponent("msime-user", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rustUserRoot,
      withIntermediateDirectories: false
    )

    let staged = try OwlUserMigrationStage.prepare(
      plan,
      in: rustUserRoot
    )

    XCTAssertEqual(staged.disposition, .prepared)
    XCTAssertEqual(
      staged.directory.deletingLastPathComponent(),
      rustUserRoot.appendingPathComponent(".owl-user-migration", isDirectory: true)
    )
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: root.appendingPathComponent(".owl-user-migration").path
    ))
    XCTAssertEqual(try Data(contentsOf: snapshot), sourceBefore)
  }

  func testPinnedChangeProducesADistinctRequestAndStage() throws {
    try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: ["ni hao \t你好\tc=4 d=0 t=1"]
    )
    let firstPlan = try OwlUserMigration.makePlan(
      userData: root,
      pinnedWordsData: try JSONEncoder().encode([
        OwlPinnedWord(code: "ni hao", text: "你好", traditional: false),
      ])
    )
    let secondPlan = try OwlUserMigration.makePlan(
      userData: root,
      pinnedWordsData: try JSONEncoder().encode([
        OwlPinnedWord(code: "ni hao", text: "拟好", traditional: false),
      ])
    )

    XCTAssertNotEqual(firstPlan.manifest.requestID, secondPlan.manifest.requestID)
    XCTAssertEqual(
      try OwlUserMigrationStage.prepare(firstPlan, in: root).disposition,
      .prepared
    )
    XCTAssertEqual(
      try OwlUserMigrationStage.prepare(secondPlan, in: root).disposition,
      .prepared
    )
  }

  func testIncompleteStagingIsDiscardedAndRecreated() throws {
    try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: ["ni hao \t你好\tc=4 d=0 t=1"]
    )
    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: nil)
    let destination = root
      .appendingPathComponent(".owl-user-migration", isDirectory: true)
      .appendingPathComponent(plan.manifest.requestID, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: destination.appendingPathComponent("manifest.json"))

    let result = try OwlUserMigrationStage.prepare(plan, in: root)

    XCTAssertEqual(result.disposition, .prepared)
    XCTAssertEqual(
      try Data(contentsOf: destination.appendingPathComponent("manifest.json")),
      plan.manifestData
    )
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: destination.appendingPathComponent(".prepared").path
    ))
  }

  func testSourceChangeAbortsAndLeavesNoStaging() throws {
    let snapshot = try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: ["ni hao \t你好\tc=4 d=0 t=1"]
    )
    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: nil)
    try Data("changed while planning\n".utf8).write(to: snapshot)

    XCTAssertThrowsError(try OwlUserMigrationStage.prepare(plan, in: root)) { error in
      XCTAssertEqual(error as? OwlUserMigrationStageError, .sourceChanged)
    }
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: root
        .appendingPathComponent(".owl-user-migration")
        .appendingPathComponent(plan.manifest.requestID)
        .path
    ))
  }

  func testCompleteStagingCollisionIsNeverOverwritten() throws {
    try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: ["ni hao \t你好\tc=4 d=0 t=1"]
    )
    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: nil)
    let staged = try OwlUserMigrationStage.prepare(plan, in: root)
    let manifest = staged.directory.appendingPathComponent("manifest.json")
    let tampered = Data("{\"tampered\":true}\n".utf8)
    try tampered.write(to: manifest)

    XCTAssertThrowsError(try OwlUserMigrationStage.prepare(plan, in: root)) { error in
      XCTAssertEqual(
        error as? OwlUserMigrationStageError,
        .requestIDCollision(plan.manifest.requestID)
      )
    }
    XCTAssertEqual(try Data(contentsOf: manifest), tampered)
  }

  func testExtraFileInACompleteStagingDirectoryIsACollision() throws {
    try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: ["ni hao \t你好\tc=4 d=0 t=1"]
    )
    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: nil)
    let staged = try OwlUserMigrationStage.prepare(plan, in: root)
    let extra = staged.directory.appendingPathComponent("extra")
    try Data("keep".utf8).write(to: extra)

    XCTAssertThrowsError(try OwlUserMigrationStage.prepare(plan, in: root)) { error in
      guard let stageError = error as? OwlUserMigrationStageError,
            case .requestIDCollision = stageError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: extra), Data("keep".utf8))
  }

  func testNoSnapshotStillStagesPins() throws {
    let pins = try JSONEncoder().encode([
      OwlPinnedWord(code: "ni hao", text: "你好", traditional: false),
    ])
    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: pins)

    let staged = try OwlUserMigrationStage.prepare(plan, in: root)

    XCTAssertEqual(staged.recordCount, 0)
    XCTAssertEqual(staged.manifest.pins.count, 1)
    XCTAssertEqual(try Data(contentsOf: staged.directory.appendingPathComponent(
      "dictionary-state.ndjson"
    )), Data())
  }

  func testPlanAndStageUseCustomSyncDirectoryWithoutLeakingItsPath() throws {
    let customSync = root.appendingPathComponent(
      "Cloud Sync/Owltype",
      isDirectory: true
    )
    let snapshot = try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      baseDirectory: customSync,
      lines: ["ni hao \t你好\tc=4 d=0 t=1"]
    )
    try Data("sync_dir: \"\(customSync.path)\"\n".utf8).write(
      to: root.appendingPathComponent("installation.yaml")
    )
    let resolved = OwlRimeSyncSettings(rimeDir: root).currentSyncDirectory()
    let plan = try OwlUserMigration.makePlan(
      userData: root,
      pinnedWordsData: nil,
      syncDirectory: resolved
    )

    XCTAssertEqual(plan.syncDirectory, customSync)
    XCTAssertEqual(
      plan.manifest.sources.map(\.path),
      ["sync/install-a/rime_ice.userdb.txt"]
    )
    XCTAssertNil(plan.manifestData.range(of: Data(customSync.path.utf8)))

    let staged = try OwlUserMigrationStage.prepare(plan, in: root)
    XCTAssertEqual(staged.disposition, .prepared)
    XCTAssertEqual(staged.recordCount, 1)

    try Data("changed\n".utf8).write(to: snapshot)
    XCTAssertThrowsError(try OwlUserMigrationStage.prepare(plan, in: root)) { error in
      XCTAssertEqual(error as? OwlUserMigrationStageError, .sourceChanged)
    }
  }

  func testSuccessMessageDisclosesPinsNotRepresentableInRust() {
    let report = OwlUserMigrationImportReport(
      ok: true,
      error: nil,
      requestID: "owlrime-migrate-\(String(repeating: "0", count: 64))",
      sourceCount: 0,
      issueCount: 0,
      recordCount: 0,
      entriesWritten: 0,
      positionsWritten: 0,
      selectionsWritten: 0,
      recordsKept: 0,
      recordsSkipped: 0,
      userWordsPreserved: 0,
      pinsTotal: 3,
      pinsWritten: 1,
      pinsKept: 0,
      pinsExternalOnly: 2,
      habitsTrimmed: 0,
      warnings: []
    )
    let outcome = OwlUserMigrationImportOutcome(
      report: report,
      generation: OwlRustResourceGeneration(
        resourcesURL: root,
        contentID: "test"
      ),
      warnings: []
    )

    let message = OwlUserMigrationImport.successMessage(
      outcome,
      engineRestarted: true
    )

    XCTAssertTrue(message.contains("2 条置顶仍保留在 owl_pinned_words"), message)
    XCTAssertTrue(message.contains("每个拼音上下文只能保存一条"), message)
  }

  func testRustImportUsesBundledGenerationAndImportedEntryCanBeTyped() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sharedSupport = repository.appendingPathComponent("data/owl-rime", isDirectory: true)
    let resources = sharedSupport.appendingPathComponent("msime", isDirectory: true)
    for name in ["msime-pinyin.db", "msime-english.db"] {
      guard FileManager.default.fileExists(
        atPath: resources.appendingPathComponent(name).path
      ) else {
        throw XCTSkip("Rust seed dictionaries are not generated at \(resources.path)")
      }
    }
    let resourceDigest = try OwlRustEngine.contentDigest(of: resources)
    let snapshot = try writeSnapshot(
      installation: "install-a",
      schema: "rime_ice",
      lines: ["zhuang qiang \t迁移混输\tc=10 d=0 t=1"]
    )
    let snapshotBefore = try Data(contentsOf: snapshot)
    let plan = try OwlUserMigration.makePlan(userData: root, pinnedWordsData: nil)
    let rustUserRoot = root.appendingPathComponent("msime-user", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rustUserRoot,
      withIntermediateDirectories: false
    )
    let staged = try OwlUserMigrationStage.prepare(
      plan,
      in: rustUserRoot
    )

    let first = try OwlUserMigrationImport.run(
      staged,
      userRoot: root,
      sharedSupportURL: sharedSupport
    )

    XCTAssertEqual(first.report.requestID, plan.manifest.requestID)
    XCTAssertEqual(first.report.sourceCount, 1)
    XCTAssertEqual(first.report.recordCount, 1)
    XCTAssertEqual(first.report.entriesWritten, 1)
    XCTAssertTrue(first.generation.contentID.hasPrefix("seed-"))
    XCTAssertEqual(try OwlRustEngine.contentDigest(of: resources), resourceDigest)
    XCTAssertEqual(try Data(contentsOf: snapshot), snapshotBefore)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: rustUserRoot.appendingPathComponent("msime_user.db").path
    ))

    let second = try OwlUserMigrationImport.run(
      staged,
      userRoot: root,
      sharedSupportURL: sharedSupport
    )
    XCTAssertEqual(second.report.requestID, first.report.requestID)
    XCTAssertEqual(second.report.entriesWritten, 0)
    XCTAssertEqual(second.report.recordsKept, 1)

    let engine = OwlRustEngine(sharedSupportURL: sharedSupport, userDataURL: root)
    let session = engine.createSession()
    defer { session.destroy() }
    XCTAssertTrue(session.isValid)
    typeText("zhuangqiang", into: session)
    let index = try XCTUnwrap(
      visibleAndPeekedCandidates(in: session).firstIndex { $0.text == "迁移混输" }
    )
    XCTAssertTrue(session.selectCandidateAbsolute(index))
    XCTAssertEqual(session.takeCommit(), "迁移混输")
  }

  private func typeText(_ text: String, into session: RimeSession) {
    for scalar in text.unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
  }

  private func visibleAndPeekedCandidates(
    in session: RimeSession,
    count: Int = 100
  ) -> [RimeCandidate] {
    guard let composition = session.composition() else { return [] }
    let start = composition.pageSize
    return composition.candidates + session.peekCandidates(from: start, count: count)
  }

  @discardableResult
  private func writeSnapshot(
    installation: String,
    schema: String,
    relativeDirectory: String? = nil,
    baseDirectory: URL? = nil,
    lines: [String]
  ) throws -> URL {
    var directory = (baseDirectory
      ?? root.appendingPathComponent("sync", isDirectory: true))
      .appendingPathComponent(installation, isDirectory: true)
    if let relativeDirectory {
      directory.appendPathComponent(relativeDirectory, isDirectory: true)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(schema).userdb.txt")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    return url
  }

  private func record(
    _ kind: String,
    _ code: String,
    _ word: String,
    in plan: OwlUserMigrationPlan
  ) -> OwlUserMigrationRecord? {
    plan.records.first {
      $0.data.kind == kind && $0.data.code == code && $0.data.word == word
    }
  }
}
