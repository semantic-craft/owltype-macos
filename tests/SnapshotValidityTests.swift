//
//  SnapshotValidityTests.swift
//  OwltypeTests — P0 staleness baseline (spec P0-06)
//
//  Verifies `OwlSnapshotRegistry.isCurrent(_:)` returns false after every invalidation
//  event (rawInput / preedit / pageNo / commitSerial / schemaID / sessionID change) and true
//  for an identical snapshot. No network, no engine dependency.
//

import Foundation
import XCTest
@testable import Owltype

@MainActor
final class SnapshotValidityTests: XCTestCase {

  /// Build a snapshot with overridable fields, defaulting to a representative composition.
  private func makeSnapshot(
    id: UInt64 = 1,
    sessionID: UInt64 = 100,
    schemaID: String = "pinyin_simp",
    rawInput: String = "genju",
    preedit: String = "根据",
    cursor: Int = 2,
    pageNo: Int = 0,
    commitSerial: UInt64 = 0
  ) -> OwlCompositionSnapshot {
    OwlCompositionSnapshot(
      id: id,
      sessionID: sessionID,
      schemaID: schemaID,
      rawInput: rawInput,
      preedit: preedit,
      cursor: cursor,
      pageNo: pageNo,
      candidates: [EngineCandidateSnapshot(index: 0, text: "根据")],
      commitSerial: commitSerial
    )
  }

  func testIsCurrentTrueForIdenticalState() {
    let registry = OwlSnapshotRegistry()
    let snap = makeSnapshot()
    registry.update(snap)
    // A different `id` describing the same composition state is still current.
    let sameState = makeSnapshot(id: 999)
    XCTAssertTrue(registry.isCurrent(sameState))
  }

  func testIsCurrentFalseWhenNoCurrentSnapshot() {
    let registry = OwlSnapshotRegistry()
    XCTAssertFalse(registry.isCurrent(makeSnapshot()))
  }

  func testRawInputChangeInvalidates() {
    let registry = OwlSnapshotRegistry()
    let old = makeSnapshot(id: 1, rawInput: "genju")
    registry.update(makeSnapshot(id: 2, rawInput: "genjuq"))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testPreeditChangeInvalidates() {
    let registry = OwlSnapshotRegistry()
    let old = makeSnapshot(id: 1, preedit: "根据")
    registry.update(makeSnapshot(id: 2, preedit: "跟据"))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testPageFlipInvalidates() {
    let registry = OwlSnapshotRegistry()
    let old = makeSnapshot(id: 1, pageNo: 0)
    registry.update(makeSnapshot(id: 2, pageNo: 1))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testCommitSerialBumpInvalidates() {
    let registry = OwlSnapshotRegistry()
    let old = makeSnapshot(id: 1, commitSerial: 0)
    registry.update(makeSnapshot(id: 2, commitSerial: 1))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testSchemaSwitchInvalidates() {
    let registry = OwlSnapshotRegistry()
    let old = makeSnapshot(id: 1, schemaID: "wubi86_jidian")
    registry.update(makeSnapshot(id: 2, schemaID: "pinyin_simp"))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testSessionChangeInvalidates() {
    let registry = OwlSnapshotRegistry()
    let old = makeSnapshot(id: 1, sessionID: 100)
    registry.update(makeSnapshot(id: 2, sessionID: 101))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testCompositionEndInvalidates() {
    let registry = OwlSnapshotRegistry()
    let old = makeSnapshot()
    registry.update(old)
    XCTAssertTrue(registry.isCurrent(old))
    // Composition ended (commit / escape) → current is nil → everything stale.
    registry.update(nil)
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testSnapshotIDGeneratorIsMonotonic() {
    let gen = OwlSnapshotIDGenerator()
    let first = gen.next()
    let second = gen.next()
    let third = gen.next()
    XCTAssertGreaterThan(second, first)
    XCTAssertGreaterThan(third, second)
  }
}

final class OwlClipboardStoreBoundaryTests: XCTestCase {

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-clipboard-store-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  func testClipboardStoreDefaultsOffAndLimitsLocalEntries() throws {
    let suite = "OwlClipboardTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    XCTAssertFalse(OwlClipboardStore.isEnabled(defaults: defaults))
    OwlClipboardStore.setEnabled(true, defaults: defaults)
    XCTAssertTrue(OwlClipboardStore.isEnabled(defaults: defaults))

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let longText = String(repeating: "法", count: OwlClipboardStore.maxCharacters + 10)
    let entries = (0..<(OwlClipboardStore.maxEntries + 5)).map { index in
      OwlClipboardEntry(
        id: UUID(),
        text: "\(index)-\(longText)",
        createdAt: Date(timeIntervalSince1970: Double(index))
      )
    }
    try OwlClipboardStore.save(entries, root: dir)

    let loaded = OwlClipboardStore.load(root: dir)
    XCTAssertEqual(loaded.count, OwlClipboardStore.maxEntries)
    XCTAssertLessThanOrEqual(loaded[0].text.count, OwlClipboardStore.maxCharacters)
    let rootMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(
      atPath: OwlClipboardStore.fileURL(root: dir).path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(rootMode?.intValue, 0o700)
    XCTAssertEqual(fileMode?.intValue, 0o600)

    try OwlClipboardStore.clear(root: dir)
    XCTAssertTrue(OwlClipboardStore.load(root: dir).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: OwlClipboardStore.fileURL(root: dir).path))
  }

  func testClipboardCaptureRejectsEmptyTextAndDedupes() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    XCTAssertThrowsError(try OwlClipboardStore.capture("   ", root: dir))

    _ = try OwlClipboardStore.capture("第一条", root: dir, now: Date(timeIntervalSince1970: 1))
    _ = try OwlClipboardStore.capture("第二条", root: dir, now: Date(timeIntervalSince1970: 2))
    let loaded = try OwlClipboardStore.capture("第一条", root: dir, now: Date(timeIntervalSince1970: 3))

    XCTAssertEqual(loaded.map(\.text), ["第一条", "第二条"])
    XCTAssertEqual(loaded[0].createdAt, Date(timeIntervalSince1970: 3))
  }

  func testClipboardIgnoresObsoleteNestedPath() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // A clean Owltype identity must not read migration-era nested state.
    let legacy = dir.appendingPathComponent("owltype", isDirectory: true)
      .appendingPathComponent(OwlClipboardStore.fileName)
    try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    let seeded = [OwlClipboardEntry(text: "旧记录", createdAt: Date(timeIntervalSince1970: 1))]
    try Data(JSONEncoder().encode(seeded)).write(to: legacy)

    XCTAssertTrue(OwlClipboardStore.load(root: dir).isEmpty)
    _ = try OwlClipboardStore.capture("新记录", root: dir, now: Date(timeIntervalSince1970: 2))

    XCTAssertEqual(OwlClipboardStore.load(root: dir).map(\.text), ["新记录"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: OwlClipboardStore.fileURL(root: dir).path))
  }
}

final class OwlInputSourceDisplayTests: XCTestCase {

  func testOwltypeInputSourceDisplayIsBranded() {
    XCTAssertEqual(
      OwlInstaller.currentInputSourceDisplayName(for: "im.owltype.inputmethod.Owltype.Hans"),
      "猫头鹰输入法（im.owltype.inputmethod.Owltype.Hans）"
    )
  }

  func testSquirrelInputSourceDisplayWarnsItIsNotOwltype() {
    XCTAssertEqual(
      OwlInstaller.currentInputSourceDisplayName(for: "im.rime.inputmethod.Squirrel.Hans"),
      "Squirrel（im.rime.inputmethod.Squirrel.Hans，当前不是猫头鹰）"
    )
  }

  func testUnknownInputSourceDisplayFallsBackToID() {
    XCTAssertEqual(
      OwlInstaller.currentInputSourceDisplayName(for: "com.apple.keylayout.US"),
      "com.apple.keylayout.US"
    )
    XCTAssertEqual(OwlInstaller.currentInputSourceDisplayName(for: nil), "未知")
  }
}
