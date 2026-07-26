//
//  FamoQuickSendStoreTests.swift
//  FamoTests — 快捷短语存储：JSON source of truth + 派生表 + 旧格式 v 链迁移
//
//  Locks the storage boundary that fixes the 2026-07 snowball bug: the old store both WROTE the
//  derived Rime table (`text\tcode\t100000` + the `v{code}` collision variant line) AND READ it
//  back as entries, so every save materialized the `v` variants as real entries and re-derived
//  another `v` layer — entries multiplied until codes hit the 32-char trigger limit.
//
//    1. `save` writes THREE files atomically through `FamoConfigWriter`: `famo_quick_send.json`
//       (source of truth) PLUS the derived `famo_quick_send.txt` PLUS the `rime_ice.custom.yaml`
//       patch. `load` reads JSON only — repeated save→load round-trips are a FIXPOINT (the
//       regression guard: no growth, no `v` accretion).
//    2. Legacy migration: a dict-only dir (pre-JSON install) is parsed once with the snowballed
//       `v` chains collapsed — base codes kept, orphaned chains keep their shortest code, and a
//       genuine user code that merely starts with "v" survives.
//
//  No network, no librime. The store is pointed at a unique temp root so it never touches the
//  real ~/Library/Application Support/Famo.
//

import Foundation
import XCTest
@testable import Famo

final class FamoQuickSendStoreTests: XCTestCase {

  private var tempRoot: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("FamoQuickSendStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
      try FileManager.default.removeItem(at: tempRoot)
    }
    try super.tearDownWithError()
  }

  private func read(_ fileName: String) throws -> String {
    try String(contentsOf: tempRoot.appendingPathComponent(fileName), encoding: .utf8)
  }

  // MARK: - JSON source of truth + derived table

  func testSaveWritesJSONSourceOfTruthPlusDerivedTable() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    let entries = [
      try FamoQuickSendStore.entry(text: "claude --dangerously-skip-permissions", code: "yocc"),
      try FamoQuickSendStore.entry(text: "最高人民法院", code: "zgfy"),
    ]
    try FamoQuickSendStore.save(entries, writer: writer, timestamp: "20260724-000000")

    let loaded = FamoQuickSendStore.load(rimeDir: tempRoot)
    XCTAssertEqual(loaded.map(\.code), ["yocc", "zgfy"])

    // Derived table carries the BARE code — no ` prefix (` is rime-ice's radical-search lead;
    // a prefixed code never reaches the translator), no `v` variant rows (the 2026-07 snowball).
    // Single-key hijack is prevented by enable_completion: false in the patch, not by prefixes.
    let dict = try read(FamoQuickSendStore.dictFileName)
    XCTAssertTrue(dict.contains("claude --dangerously-skip-permissions\tyocc\t100000"))
    XCTAssertFalse(dict.contains("`yocc"))
    XCTAssertFalse(dict.contains("\tvyocc\t"))
    let json = try read(FamoQuickSendStore.fileName)
    XCTAssertTrue(json.contains("\"yocc\""))
    XCTAssertFalse(json.contains("\"vyocc\""))
  }

  /// THE regression guard for the snowball bug: repeated save→load cycles are a fixpoint.
  /// (The old dict-backed store grew one `v` generation per cycle.)
  func testRepeatedSaveLoadRoundTripsAreAFixpoint() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    var entries = [try FamoQuickSendStore.entry(text: "opencode --auto", code: "yooc")]
    for cycle in 1...5 {
      try FamoQuickSendStore.save(entries, writer: writer, timestamp: "20260724-00000\(cycle)")
      entries = FamoQuickSendStore.load(rimeDir: tempRoot)
      XCTAssertEqual(entries.map(\.code), ["yooc"], "cycle \(cycle) must not grow the store")
    }
  }

  // MARK: - Legacy dict migration (v-chain collapse)

  func testLoadMigratesLegacyDictCollapsingVariantChains() throws {
    // Pre-JSON install: the dict WAS the store, already snowballed two generations deep.
    let legacy = """
      # Rime table
      #@/db_name famo_quick_send
      opencode --auto\tyooc\t100000
      opencode --auto\tvyooc\t100000
      opencode --auto\tvvyooc\t100000
      opencode --auto\tvvvyooc\t100000
      """
    try legacy.write(
      to: tempRoot.appendingPathComponent(FamoQuickSendStore.dictFileName),
      atomically: true, encoding: .utf8)

    let migrated = FamoQuickSendStore.load(rimeDir: tempRoot)
    XCTAssertEqual(migrated, [FamoQuickSendEntry(text: "opencode --auto", code: "yooc")])
  }

  func testLegacyMigrationKeepsShortestCodeOfOrphanedChainAndGenuineVCodes() throws {
    // Orphaned chain: base `yocc` was deleted, only its v-descendants remain → keep the shortest.
    // Genuine v-code: `vip` shares no text with `ip`, so it is a real user entry — kept.
    let legacy = """
      claude --dangerously-skip-permissions\tvyocc\t100000
      claude --dangerously-skip-permissions\tvvyocc\t100000
      知识产权\tip\t100000
      贵宾通道\tvip\t100000
      """
    try legacy.write(
      to: tempRoot.appendingPathComponent(FamoQuickSendStore.dictFileName),
      atomically: true, encoding: .utf8)

    let migrated = FamoQuickSendStore.load(rimeDir: tempRoot)
    XCTAssertEqual(migrated.map(\.code), ["ip", "vip", "vyocc"])
  }

  // MARK: - Launch-time derived-artifact migration (1.5.2 ` prefix never reached upgraders)

  /// The exact 2026-07-26 real-machine state: a 1.5.1-era install upgraded to 1.5.3 without ever
  /// re-saving in settings — bare-code dict (no JSON) + the old patch (completion on, quality 100)
  /// still live, so a single `y` completes into `yocc`. Migration must regenerate all three files.
  func testMigrateRegeneratesStaleLegacyArtifacts() throws {
    let legacyDict = """
      # Rime table
      #@/db_name famo_quick_send
      claude --dangerously-skip-permissions\tyocc\t100000
      claude --dangerously-skip-permissions\tvyocc\t100000
      """
    try legacyDict.write(
      to: tempRoot.appendingPathComponent(FamoQuickSendStore.dictFileName),
      atomically: true, encoding: .utf8)
    let legacyYAML = """
      patch:
        # >>> FAMO MANAGED QUICK_SEND RIME_ICE PATCH v1
        "engine/translators/+":
          - table_translator@famo_quick_send
        famo_quick_send:
          dictionary: ""
          user_dict: famo_quick_send
          db_class: stabledb
          enable_completion: true
          enable_sentence: false
          initial_quality: 100
        # <<< FAMO MANAGED QUICK_SEND RIME_ICE PATCH v1
      """
    try legacyYAML.write(
      to: tempRoot.appendingPathComponent("rime_ice.custom.yaml"),
      atomically: true, encoding: .utf8)

    FamoQuickSendStore.migrateDerivedArtifactsIfNeeded(rimeDir: tempRoot)

    // JSON source of truth materialized with the v-chain collapsed to the bare code.
    let json = try read(FamoQuickSendStore.fileName)
    XCTAssertTrue(json.contains("\"yocc\""))
    XCTAssertFalse(json.contains("\"vyocc\""))
    // Derived table re-rendered: one bare-code line per entry, v-chain gone.
    let dict = try read(FamoQuickSendStore.dictFileName)
    XCTAssertTrue(dict.contains("claude --dangerously-skip-permissions\tyocc\t100000"))
    XCTAssertFalse(dict.contains("vyocc"))
    // Patch block replaced in place: completion off (the actual y-hijack fix), quality 99.
    let yaml = try read("rime_ice.custom.yaml")
    XCTAssertTrue(yaml.contains("enable_completion: false"))
    XCTAssertFalse(yaml.contains("initial_quality: 100"))
    XCTAssertTrue(yaml.contains("initial_quality: 99"))
  }

  /// The 1.5.2–1.5.3 on-disk shape (` -prefixed table, quality-1 patch) is ALSO stale: the `
  /// prefix collides with rime-ice's radical-search lead key, so those phrases can never fire.
  /// Migration must re-render bare codes from the JSON.
  func testMigrateRewritesPrefixedTableFromJSONSourceOfTruth() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    try FamoQuickSendStore.save(
      [try FamoQuickSendStore.entry(text: "claude --dangerously-skip-permissions", code: "yocc")],
      writer: writer, timestamp: "20260726-000001")
    // Regress the derived table to the 1.5.2 ` -prefixed rendering.
    try "claude --dangerously-skip-permissions\t`yocc\t100000\n".write(
      to: tempRoot.appendingPathComponent(FamoQuickSendStore.dictFileName),
      atomically: true, encoding: .utf8)

    FamoQuickSendStore.migrateDerivedArtifactsIfNeeded(rimeDir: tempRoot)

    let dict = try read(FamoQuickSendStore.dictFileName)
    XCTAssertTrue(dict.contains("claude --dangerously-skip-permissions\tyocc\t100000"))
    XCTAssertFalse(dict.contains("`yocc"))
  }

  /// Once artifacts are in sync the launch-time replay must be pure comparison — zero disk writes,
  /// zero new rollback-manifest entries (it runs on EVERY launch).
  func testMigrateIsNoOpOnceArtifactsAreInSync() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    try FamoQuickSendStore.save(
      [try FamoQuickSendStore.entry(text: "opencode --auto", code: "yooc")],
      writer: writer, timestamp: "20260726-000000")
    let manifestURL = tempRoot.appendingPathComponent("famo/rollback-manifest.json")
    let manifestBefore = try Data(contentsOf: manifestURL)
    let dictBefore = try read(FamoQuickSendStore.dictFileName)
    let yamlBefore = try read("rime_ice.custom.yaml")

    FamoQuickSendStore.migrateDerivedArtifactsIfNeeded(rimeDir: tempRoot)

    XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore, "in-sync replay must not append manifest entries")
    XCTAssertEqual(try read(FamoQuickSendStore.dictFileName), dictBefore)
    XCTAssertEqual(try read("rime_ice.custom.yaml"), yamlBefore)
  }

  /// A user who never used quick send has neither the JSON nor the dict — migration must not
  /// conjure files (that would register the translator for everyone).
  func testMigrateDoesNothingWhenFeatureNeverUsed() throws {
    FamoQuickSendStore.migrateDerivedArtifactsIfNeeded(rimeDir: tempRoot)
    let fm = FileManager.default
    XCTAssertFalse(fm.fileExists(atPath: tempRoot.appendingPathComponent(FamoQuickSendStore.fileName).path))
    XCTAssertFalse(fm.fileExists(atPath: tempRoot.appendingPathComponent(FamoQuickSendStore.dictFileName).path))
    XCTAssertFalse(fm.fileExists(atPath: tempRoot.appendingPathComponent("rime_ice.custom.yaml").path))
  }

  func testJSONWinsOverLegacyDictWhenBothExist() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    try FamoQuickSendStore.save(
      [try FamoQuickSendStore.entry(text: "最高人民法院", code: "zgfy")],
      writer: writer, timestamp: "20260724-000010")
    // A stale/polluted dict must be ignored once the JSON exists.
    try "野表条目\twild\t100000\n".write(
      to: tempRoot.appendingPathComponent(FamoQuickSendStore.dictFileName),
      atomically: true, encoding: .utf8)

    XCTAssertEqual(FamoQuickSendStore.load(rimeDir: tempRoot).map(\.code), ["zgfy"])
  }
}
