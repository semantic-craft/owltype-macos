//
//  SnapshotValidityTests.swift
//  OwltypeTests — P0 staleness baseline (spec P0-06)
//

import Foundation
import XCTest
@testable import Owltype

@MainActor
final class SnapshotValidityTests: XCTestCase {

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
      "法墨输入法（im.owltype.inputmethod.Owltype.Hans）"
    )
  }

  func testSquirrelInputSourceDisplayWarnsItIsNotOwltype() {
    XCTAssertEqual(
      OwlInstaller.currentInputSourceDisplayName(for: "im.rime.inputmethod.Squirrel.Hans"),
      "Squirrel（im.rime.inputmethod.Squirrel.Hans，当前不是法墨）"
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
