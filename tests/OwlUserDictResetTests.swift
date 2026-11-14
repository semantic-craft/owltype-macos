//
//  OwlUserDictResetTests.swift
//  OwltypeTests — 「重置用户词典…」
//
//  Synthetic coverage for the Rust data reset: complete backup, deletion, failure
//  restoration, and preserving the legacy Rime data retained for migration/rollback.
//

import AppKit
import Foundation
import XCTest
@testable import Owltype

final class OwlUserDictResetTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwlUserDictResetTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    root = nil
    try super.tearDownWithError()
  }

  // MARK: - Helpers

  private var rustRoot: URL {
    root.appendingPathComponent("msime-user", isDirectory: true)
  }

  private func makeRustData() throws {
    try FileManager.default.createDirectory(
      at: rustRoot,
      withIntermediateDirectories: true
    )
    try Data("journal".utf8).write(
      to: rustRoot.appendingPathComponent("msime_user.db")
    )
    try Data("wal".utf8).write(
      to: rustRoot.appendingPathComponent("msime_user.db-wal")
    )
    try Data("corrupt".utf8).write(
      to: rustRoot.appendingPathComponent("msime_user.db.corrupt-100")
    )
    let generation = rustRoot
      .appendingPathComponent("dictionaries/seed-abc", isDirectory: true)
    try FileManager.default.createDirectory(
      at: generation,
      withIntermediateDirectories: true
    )
    try Data("working dictionary".utf8).write(
      to: generation.appendingPathComponent("msime-pinyin.db")
    )
  }

  private func makeLegacyData() throws {
    let userDB = root.appendingPathComponent("rime_ice.userdb", isDirectory: true)
    try FileManager.default.createDirectory(at: userDB, withIntermediateDirectories: true)
    try Data("legacy learned".utf8).write(to: userDB.appendingPathComponent("000095.ldb"))

    let snapshot = root.appendingPathComponent("sync/install-a", isDirectory: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data("legacy snapshot".utf8).write(
      to: snapshot.appendingPathComponent("rime_ice.userdb.txt")
    )
    try Data("installation_id: abc\n".utf8).write(
      to: root.appendingPathComponent("installation.yaml")
    )
    try Data("pins".utf8).write(
      to: root.appendingPathComponent("owl_input_habits.json")
    )
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  private func assertLegacyDataUnchanged() throws {
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("rime_ice.userdb/000095.ldb")),
      Data("legacy learned".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(
        "sync/install-a/rime_ice.userdb.txt"
      )),
      Data("legacy snapshot".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("installation.yaml")),
      Data("installation_id: abc\n".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("owl_input_habits.json")),
      Data("pins".utf8)
    )
  }

  // MARK: - Normal path

  func testBacksUpAndRemovesOnlyRustJournalAndGeneration() throws {
    try makeRustData()
    try makeLegacyData()

    let outcome = try OwlUserDictReset.run(
      root: root,
      timestamp: "20261026-120000"
    )

    XCTAssertEqual(
      Set(outcome.removedItems),
      Set([
        "dictionaries",
        "msime_user.db",
        "msime_user.db-wal",
        "msime_user.db.corrupt-100",
      ])
    )
    XCTAssertFalse(exists(rustRoot.appendingPathComponent("msime_user.db")))
    XCTAssertFalse(exists(rustRoot.appendingPathComponent("msime_user.db-wal")))
    XCTAssertFalse(exists(rustRoot.appendingPathComponent("msime_user.db.corrupt-100")))
    XCTAssertFalse(exists(rustRoot.appendingPathComponent("dictionaries")))
    try assertLegacyDataUnchanged()

    let backupDir = try XCTUnwrap(outcome.backupDir)
    XCTAssertEqual(backupDir.lastPathComponent, "rust-userdict-reset-20261026-120000")
    XCTAssertEqual(
      backupDir.deletingLastPathComponent().lastPathComponent,
      ".owl-backup"
    )
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: backupDir.path)),
      Set(outcome.removedItems)
    )
  }

  func testBackupIsCompleteAndCanBeRestoredByHand() throws {
    try makeRustData()

    let outcome = try OwlUserDictReset.run(
      root: root,
      timestamp: "20261026-120000"
    )
    let backup = try XCTUnwrap(outcome.backupDir)

    XCTAssertEqual(
      try Data(contentsOf: backup.appendingPathComponent("msime_user.db")),
      Data("journal".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: backup.appendingPathComponent(
        "dictionaries/seed-abc/msime-pinyin.db"
      )),
      Data("working dictionary".utf8)
    )

    try FileManager.default.moveItem(
      at: backup.appendingPathComponent("msime_user.db"),
      to: rustRoot.appendingPathComponent("msime_user.db")
    )
    try FileManager.default.moveItem(
      at: backup.appendingPathComponent("dictionaries"),
      to: rustRoot.appendingPathComponent("dictionaries")
    )
    XCTAssertEqual(
      try Data(contentsOf: rustRoot.appendingPathComponent("msime_user.db")),
      Data("journal".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: rustRoot.appendingPathComponent(
        "dictionaries/seed-abc/msime-pinyin.db"
      )),
      Data("working dictionary".utf8)
    )
  }

  // MARK: - No-op

  func testLegacyOnlyDataIsNotMistakenForTheRustDictionary() throws {
    try makeLegacyData()

    let outcome = try OwlUserDictReset.run(
      root: root,
      timestamp: "20261026-120000"
    )

    XCTAssertEqual(outcome.removedItems, [])
    XCTAssertNil(outcome.backupDir)
    XCTAssertFalse(exists(root.appendingPathComponent(".owl-backup")))
    try assertLegacyDataUnchanged()
    XCTAssertEqual(
      OwlUserDictReset.statusMessage(outcome: outcome, redeployed: true),
      "本机还没有 Rust 用户词典数据，无需重置。"
    )
  }

  func testMissingRootDirectoryIsANoOpRatherThanAThrow() throws {
    let missing = root.appendingPathComponent("nope", isDirectory: true)
    let outcome = try OwlUserDictReset.run(
      root: missing,
      timestamp: "20261026-120000"
    )
    XCTAssertEqual(
      outcome,
      OwlUserDictResetOutcome(removedItems: [], backupDir: nil)
    )
  }

  // MARK: - Failure leaves no intermediate state

  func testBackupFailureLeavesEveryRustItemInPlace() throws {
    try makeRustData()
    try Data("blocks backup root".utf8).write(
      to: root.appendingPathComponent(".owl-backup")
    )

    XCTAssertThrowsError(try OwlUserDictReset.run(
      root: root,
      timestamp: "20261026-120000"
    )) { error in
      guard case OwlUserDictResetError.backupFailed(let item, _) = error else {
        return XCTFail("expected backupFailed, got \(error)")
      }
      XCTAssertEqual(item, "msime_user.db")
    }

    XCTAssertEqual(
      try Data(contentsOf: rustRoot.appendingPathComponent("msime_user.db")),
      Data("journal".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: rustRoot.appendingPathComponent(
        "dictionaries/seed-abc/msime-pinyin.db"
      )),
      Data("working dictionary".utf8)
    )
  }

  func testDeletionFailureRestoresTheWholeRustDataSet() throws {
    try makeRustData()

    XCTAssertThrowsError(try OwlUserDictReset.run(
      root: root,
      timestamp: "20261026-120000"
    ) { item in
      if item == "dictionaries" {
        throw CocoaError(.fileWriteUnknown)
      }
    }) { error in
      guard case OwlUserDictResetError.removeFailed(
        let item,
        _,
        let restored,
        let restoreReason
      ) = error else {
        return XCTFail("expected removeFailed, got \(error)")
      }
      XCTAssertEqual(item, "dictionaries")
      XCTAssertTrue(restored)
      XCTAssertNil(restoreReason)
    }

    XCTAssertEqual(
      try Data(contentsOf: rustRoot.appendingPathComponent("msime_user.db")),
      Data("journal".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: rustRoot.appendingPathComponent("msime_user.db-wal")),
      Data("wal".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: rustRoot.appendingPathComponent(
        "msime_user.db.corrupt-100"
      )),
      Data("corrupt".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: rustRoot.appendingPathComponent(
        "dictionaries/seed-abc/msime-pinyin.db"
      )),
      Data("working dictionary".utf8)
    )
  }

  // MARK: - Status copy

  func testStatusMessageReportsTheBackupAndRustItems() {
    let backupDir = root.appendingPathComponent(
      ".owl-backup/rust-userdict-reset-20261026-120000"
    )
    let outcome = OwlUserDictResetOutcome(
      removedItems: ["msime_user.db", "dictionaries"],
      backupDir: backupDir
    )

    let message = OwlUserDictReset.statusMessage(
      outcome: outcome,
      redeployed: true
    )

    XCTAssertTrue(message.contains("Rust 用户词典数据"), message)
    XCTAssertTrue(message.contains("msime_user.db、dictionaries"), message)
    XCTAssertTrue(message.contains(backupDir.path), message)
    XCTAssertFalse(message.contains("失败"), message)
  }

  func testStatusMessageSurfacesARestartFailure() {
    let outcome = OwlUserDictResetOutcome(
      removedItems: ["msime_user.db"],
      backupDir: root.appendingPathComponent(
        ".owl-backup/rust-userdict-reset-20261026-120000"
      )
    )
    let message = OwlUserDictReset.statusMessage(
      outcome: outcome,
      redeployed: false
    )
    XCTAssertTrue(message.contains("重新启动 Rust 引擎失败"), message)
  }

  func testFailureMessageReportsRestoration() {
    let error = OwlUserDictResetError.removeFailed(
      item: "dictionaries",
      reason: "Permission denied",
      restored: true,
      restoreReason: nil
    )
    let message = OwlUserDictReset.failureMessage(
      error: error,
      redeployed: true
    )
    XCTAssertTrue(message.contains("已从备份恢复"), message)
    XCTAssertTrue(message.contains("dictionaries"), message)
    XCTAssertTrue(message.contains("Permission denied"), message)
  }

  // MARK: - Confirmation

  @MainActor
  func testConfirmationAlertDefaultsToCancel() {
    let alert = OwlUserDictResetPrompt.makeAlert()

    XCTAssertEqual(alert.buttons.first?.title, "取消")
    XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r", "回车必须落在取消上")
    XCTAssertEqual(alert.buttons.count, 2)
    XCTAssertEqual(alert.buttons.last?.title, "重置")
    XCTAssertTrue(alert.buttons.last?.hasDestructiveAction ?? false)
    XCTAssertEqual(
      alert.buttons.last?.tag,
      NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
    )
  }

  @MainActor
  func testConfirmationExplainsRustScopeAndPreservedLegacyData() {
    let alert = OwlUserDictResetPrompt.makeAlert()
    XCTAssertTrue(alert.informativeText.contains("Rust"), alert.informativeText)
    XCTAssertTrue(alert.informativeText.contains("输入习惯"), alert.informativeText)
    XCTAssertTrue(alert.informativeText.contains("自造词"), alert.informativeText)
    XCTAssertTrue(alert.informativeText.contains(".userdb"), alert.informativeText)
    XCTAssertTrue(alert.informativeText.contains("置顶词列表"), alert.informativeText)
    XCTAssertTrue(
      alert.informativeText.contains(".owl-backup/rust-userdict-reset-"),
      alert.informativeText
    )
  }
}
