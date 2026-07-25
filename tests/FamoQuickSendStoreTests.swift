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

    // Derived table carries the code behind the ` prefix; the old bare + `v` variants are gone
    // (2026-07-25: bare codes let a single `y` complete into `yocc` and hijack the candidates).
    let dict = try read(FamoQuickSendStore.dictFileName)
    XCTAssertTrue(dict.contains("claude --dangerously-skip-permissions\t`yocc\t100000"))
    XCTAssertFalse(dict.contains("\tyocc\t"))
    XCTAssertFalse(dict.contains("\tvyocc\t"))
    // …and the JSON stores the bare code (the prefix lives only in the derived table, so
    // upgrading users get it for free with no JSON migration).
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
