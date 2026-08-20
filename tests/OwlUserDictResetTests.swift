//
//  OwlUserDictResetTests.swift
//  OwltypeTests — 「重置用户词典…」(#37)
//
//  在临时目录里跑完整的备份 → 删除链路：无 librime、无 AppKit、不碰真实用户目录。
//  锁住 #37 验收里属于纯逻辑的那几条：备份存在且可手工还原、只碰 `*.userdb`、
//  全新机器（无 userdb）点它不报错、失败不留中间态、确认弹窗默认按钮是取消。
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

  /// 造一个形似 LevelDB 的 `<schema>.userdb/` 目录（几个文件足够验证「整目录」搬运）。
  @discardableResult
  private func makeUserDB(_ schemaID: String, marker: String = "learned") throws -> URL {
    let db = root.appendingPathComponent("\(schemaID).userdb", isDirectory: true)
    try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: db.appendingPathComponent("000095.ldb"))
    try Data("16".utf8).write(to: db.appendingPathComponent("CURRENT"))
    return db
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  private func names(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
  }

  // MARK: - 正常路径

  func testBacksUpEveryUserDBThenDeletesIt() throws {
    try makeUserDB("rime_ice", marker: "繁體字")
    try makeUserDB("wubi86_jidian")

    let outcome = try OwlUserDictReset.run(root: root, timestamp: "20260726-120000")

    XCTAssertEqual(outcome.schemaIDs, ["rime_ice", "wubi86_jidian"])
    XCTAssertFalse(exists(root.appendingPathComponent("rime_ice.userdb")), "userdb 应已删除")
    XCTAssertFalse(exists(root.appendingPathComponent("wubi86_jidian.userdb")), "userdb 应已删除")

    let backupDir = try XCTUnwrap(outcome.backupDir)
    XCTAssertEqual(backupDir.lastPathComponent, "userdb-reset-20260726-120000")
    XCTAssertEqual(
      backupDir.deletingLastPathComponent().lastPathComponent,
      ".famo-backup",
      "备份要落在配置目录既有的 .famo-backup 根下"
    )
    XCTAssertEqual(names(in: backupDir), ["rime_ice.userdb", "wubi86_jidian.userdb"])
  }

  /// 验收「备份目录存在且可手工还原」：备份里是整目录的逐字节副本，`mv` 回去即还原。
  func testBackupIsAByteForByteCopySoItCanBeRestoredByHand() throws {
    try makeUserDB("rime_ice", marker: "繁體字")

    let outcome = try OwlUserDictReset.run(root: root, timestamp: "20260726-120000")
    let backup = try XCTUnwrap(outcome.backupDir).appendingPathComponent("rime_ice.userdb")

    XCTAssertEqual(names(in: backup), ["000095.ldb", "CURRENT"])
    XCTAssertEqual(
      try Data(contentsOf: backup.appendingPathComponent("000095.ldb")),
      Data("繁體字".utf8)
    )

    // 手工还原就是把目录搬回去。
    let original = root.appendingPathComponent("rime_ice.userdb", isDirectory: true)
    try FileManager.default.moveItem(at: backup, to: original)
    XCTAssertEqual(
      try Data(contentsOf: original.appendingPathComponent("000095.ldb")),
      Data("繁體字".utf8)
    )
  }

  /// 验收「方案选择、皮肤、快捷短语等设置不受影响」的文件系统那一半：同目录其余文件一个不动。
  func testLeavesEverythingThatIsNotAUserDBAlone() throws {
    try makeUserDB("rime_ice")
    let untouched = [
      "default.custom.yaml", "famo.custom.yaml", "famo_quick_send.txt",
      "installation.yaml", "rime_ice.dict.yaml", "clipboard-history.json",
    ]
    for name in untouched {
      try Data(name.utf8).write(to: root.appendingPathComponent(name))
    }
    let buildDir = root.appendingPathComponent("build", isDirectory: true)
    try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

    _ = try OwlUserDictReset.run(root: root, timestamp: "20260726-120000")

    for name in untouched {
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent(name)),
        Data(name.utf8),
        "\(name) 不该被重置动作碰到"
      )
    }
    XCTAssertTrue(exists(buildDir))
  }

  /// `sync/` 里的 `<schema>.userdb.txt` 快照是别的机器也在读的数据，本动作不递归、不碰。
  func testDoesNotRecurseIntoTheSyncDirectory() throws {
    try makeUserDB("rime_ice")
    let syncDir = root.appendingPathComponent("sync/a94a2c5e", isDirectory: true)
    try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
    let snapshot = syncDir.appendingPathComponent("rime_ice.userdb.txt")
    try Data("snapshot".utf8).write(to: snapshot)

    let outcome = try OwlUserDictReset.run(root: root, timestamp: "20260726-120000")

    XCTAssertEqual(outcome.schemaIDs, ["rime_ice"])
    XCTAssertTrue(exists(snapshot), "同步快照不在本动作范围内")
  }

  // MARK: - 全新机器

  /// 验收「无 userdb 的全新机器上点它不报错」。
  func testFreshMachineWithNoUserDBIsANoOp() throws {
    try Data("seed".utf8).write(to: root.appendingPathComponent("default.custom.yaml"))

    let outcome = try OwlUserDictReset.run(root: root, timestamp: "20260726-120000")

    XCTAssertEqual(outcome.schemaIDs, [])
    XCTAssertNil(outcome.backupDir)
    XCTAssertFalse(
      exists(root.appendingPathComponent(".famo-backup")),
      "什么都没清就不该留下空备份目录"
    )
    XCTAssertEqual(
      OwlUserDictReset.statusMessage(outcome: outcome, redeployed: true),
      "本机还没有用户词典，无需重置。"
    )
  }

  func testMissingRootDirectoryIsANoOpRatherThanAThrow() throws {
    let missing = root.appendingPathComponent("nope", isDirectory: true)
    let outcome = try OwlUserDictReset.run(root: missing, timestamp: "20260726-120000")
    XCTAssertEqual(outcome, OwlUserDictResetOutcome(schemaIDs: [], backupDir: nil))
  }

  // MARK: - 失败不留中间态

  /// 备份阶段失败（备份目标已被同名文件占住 → copyItem 抛）时，磁盘必须原封不动：
  /// 一个 userdb 都没删。
  func testBackupFailureLeavesEveryUserDBInPlace() throws {
    try makeUserDB("rime_ice", marker: "繁體字")
    try makeUserDB("wubi86_jidian")

    // 预先占位：`.famo-backup/userdb-reset-<ts>/rime_ice.userdb` 是个普通文件，copyItem 必失败。
    let backupDir = root
      .appendingPathComponent(".famo-backup", isDirectory: true)
      .appendingPathComponent("userdb-reset-20260726-120000", isDirectory: true)
    try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
    try Data("blocker".utf8).write(to: backupDir.appendingPathComponent("rime_ice.userdb"))

    XCTAssertThrowsError(try OwlUserDictReset.run(root: root, timestamp: "20260726-120000")) { error in
      guard case OwlUserDictResetError.backupFailed(let schemaID, _) = error else {
        return XCTFail("expected backupFailed, got \(error)")
      }
      XCTAssertEqual(schemaID, "rime_ice")
    }

    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("rime_ice.userdb/000095.ldb")),
      Data("繁體字".utf8),
      "备份失败时用户词典必须原封不动"
    )
    XCTAssertTrue(exists(root.appendingPathComponent("wubi86_jidian.userdb")))
  }

  // MARK: - 状态行文案

  func testStatusMessageReportsSchemaCountAndBackupLocation() throws {
    let backupDir = root.appendingPathComponent(".famo-backup/userdb-reset-20260726-120000")
    let outcome = OwlUserDictResetOutcome(schemaIDs: ["rime_ice", "wubi86_jidian"], backupDir: backupDir)

    let message = OwlUserDictReset.statusMessage(outcome: outcome, redeployed: true)

    XCTAssertTrue(message.contains("2 个方案"), message)
    XCTAssertTrue(message.contains("rime_ice、wubi86_jidian"), message)
    XCTAssertTrue(message.contains(backupDir.path), message)
    XCTAssertFalse(message.contains("失败"), message)
  }

  func testStatusMessageSurfacesARedeployFailure() {
    let outcome = OwlUserDictResetOutcome(
      schemaIDs: ["rime_ice"],
      backupDir: root.appendingPathComponent(".famo-backup/userdb-reset-20260726-120000")
    )
    let message = OwlUserDictReset.statusMessage(outcome: outcome, redeployed: false)
    XCTAssertTrue(message.contains("重新部署失败"), message)
  }

  func testFailureMessageSaysTheDictionaryWasRestored() {
    let error = OwlUserDictResetError.removeFailed(schemaID: "rime_ice", reason: "Permission denied")
    let message = OwlUserDictReset.failureMessage(error: error, redeployed: true)
    XCTAssertTrue(message.contains("已还原"), message)
    XCTAssertTrue(message.contains("rime_ice"), message)
    XCTAssertTrue(message.contains("Permission denied"), message)
  }

  // MARK: - 确认弹窗

  /// 验收「确认弹窗默认按钮是取消」。NSAlert 把回车（keyEquivalent "\r"）给第一个
  /// addButton，所以「取消」必须排在第一位。
  @MainActor
  func testConfirmationAlertDefaultsToCancel() {
    let alert = OwlUserDictResetPrompt.makeAlert()

    XCTAssertEqual(alert.buttons.first?.title, "取消")
    XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r", "回车必须落在取消上")
    XCTAssertEqual(alert.buttons.count, 2)
    XCTAssertEqual(alert.buttons.last?.title, "重置")
    XCTAssertTrue(alert.buttons.last?.hasDestructiveAction ?? false)
    // 「重置」是第二个按钮 → confirm() 判 .alertSecondButtonReturn。
    XCTAssertEqual(alert.buttons.last?.tag, NSApplication.ModalResponse.alertSecondButtonReturn.rawValue)
  }

  /// 弹窗必须讲清代价，并说明什么**不**受影响（#37 设计第 1 条）。
  @MainActor
  func testConfirmationAlertExplainsTheCost() {
    let alert = OwlUserDictResetPrompt.makeAlert()
    XCTAssertTrue(alert.informativeText.contains("输入习惯"), alert.informativeText)
    XCTAssertTrue(alert.informativeText.contains("自造词"), alert.informativeText)
    XCTAssertTrue(alert.informativeText.contains("设置不受影响"), alert.informativeText)
    XCTAssertTrue(alert.informativeText.contains(".famo-backup"), alert.informativeText)
  }
}
