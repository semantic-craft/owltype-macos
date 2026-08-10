//
//  SnapshotValidityTests.swift
//  FamoTests — P0 staleness baseline (spec P0-06)
//
//  Verifies `FamoSnapshotRegistry.isCurrent(_:)` returns false after every invalidation
//  event (rawInput / preedit / pageNo / commitSerial / schemaID / sessionID change) and true
//  for an identical snapshot. No network, no librime dependency.
//

import Foundation
import XCTest
@testable import Famo

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
  ) -> FamoCompositionSnapshot {
    FamoCompositionSnapshot(
      id: id,
      sessionID: sessionID,
      schemaID: schemaID,
      rawInput: rawInput,
      preedit: preedit,
      cursor: cursor,
      pageNo: pageNo,
      candidates: [RimeCandidateSnapshot(index: 0, text: "根据")],
      commitSerial: commitSerial
    )
  }

  func testIsCurrentTrueForIdenticalState() {
    let registry = FamoSnapshotRegistry()
    let snap = makeSnapshot()
    registry.update(snap)
    // A different `id` describing the same composition state is still current.
    let sameState = makeSnapshot(id: 999)
    XCTAssertTrue(registry.isCurrent(sameState))
  }

  func testIsCurrentFalseWhenNoCurrentSnapshot() {
    let registry = FamoSnapshotRegistry()
    XCTAssertFalse(registry.isCurrent(makeSnapshot()))
  }

  func testRawInputChangeInvalidates() {
    let registry = FamoSnapshotRegistry()
    let old = makeSnapshot(id: 1, rawInput: "genju")
    registry.update(makeSnapshot(id: 2, rawInput: "genjuq"))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testPreeditChangeInvalidates() {
    let registry = FamoSnapshotRegistry()
    let old = makeSnapshot(id: 1, preedit: "根据")
    registry.update(makeSnapshot(id: 2, preedit: "跟据"))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testPageFlipInvalidates() {
    let registry = FamoSnapshotRegistry()
    let old = makeSnapshot(id: 1, pageNo: 0)
    registry.update(makeSnapshot(id: 2, pageNo: 1))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testCommitSerialBumpInvalidates() {
    let registry = FamoSnapshotRegistry()
    let old = makeSnapshot(id: 1, commitSerial: 0)
    registry.update(makeSnapshot(id: 2, commitSerial: 1))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testSchemaSwitchInvalidates() {
    let registry = FamoSnapshotRegistry()
    let old = makeSnapshot(id: 1, schemaID: "wubi86_jidian")
    registry.update(makeSnapshot(id: 2, schemaID: "pinyin_simp"))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testSessionChangeInvalidates() {
    let registry = FamoSnapshotRegistry()
    let old = makeSnapshot(id: 1, sessionID: 100)
    registry.update(makeSnapshot(id: 2, sessionID: 101))
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testCompositionEndInvalidates() {
    let registry = FamoSnapshotRegistry()
    let old = makeSnapshot()
    registry.update(old)
    XCTAssertTrue(registry.isCurrent(old))
    // Composition ended (commit / escape) → current is nil → everything stale.
    registry.update(nil)
    XCTAssertFalse(registry.isCurrent(old))
  }

  func testSnapshotIDGeneratorIsMonotonic() {
    let gen = FamoSnapshotIDGenerator()
    let first = gen.next()
    let second = gen.next()
    let third = gen.next()
    XCTAssertGreaterThan(second, first)
    XCTAssertGreaterThan(third, second)
  }
}

final class FamoConfigWriterBoundaryTests: XCTestCase {

  private let fuzzyOff = FamoFuzzySnapshot(
    zhz: false, chc: false, shs: false, nl: false, rl: false,
    fh: false, anang: false, eneng: false, ining: false
  )

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("famo-config-writer-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func keyboardSnapshot(
    fuzzy: FamoFuzzySnapshot? = nil,
    slashSymbolMenu: Bool = false
  ) -> FamoKeyboardSnapshot {
    FamoKeyboardSnapshot(
      inputMethod: .pinyin,
      doublePinyin: .flypy,
      shiftSwitchCJK: true,
      cjkPunctToggle: false,
      pageSize: 8,
      pageMinusEquals: true,
      pageBrackets: true,
      pageCommaPeriod: false,
      select23Semicolon: true,
      fuzzy: fuzzy ?? fuzzyOff,
      wubiCodeHint: false,
      wubiAutoClear: false,
      wubiCandidateMode: .normal,
      appEnglishBundleIDs: [],
      slashSymbolMenu: slashSymbolMenu
    )
  }

  func testDefaultDirectoryIsFamoUserDataDir() {
    let writer = FamoConfigWriter()
    XCTAssertEqual(
      writer.rimeDir.standardizedFileURL.path,
      FamoApp.userDir.standardizedFileURL.path
    )
    XCTAssertFalse(
      writer.rimeDir.path.hasSuffix("/Library/Rime"),
      "Famo must not default to the user's shared Rime directory"
    )
  }

  func testRimeSyncSettingsDefaultToFamoSyncDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let settings = FamoRimeSyncSettings(rimeDir: dir)
    XCTAssertEqual(
      settings.currentSyncDirectory().standardizedFileURL.path,
      dir.appendingPathComponent("sync", isDirectory: true).standardizedFileURL.path
    )
  }

  func testRimeSyncSettingsReadCustomSyncDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    try """
    installation_id: abc
    sync_dir: "/tmp/Famo Sync"
    distribution_code_name: famo

    """.write(to: dir.appendingPathComponent("installation.yaml"), atomically: true, encoding: .utf8)

    XCTAssertEqual(
      FamoRimeSyncSettings(rimeDir: dir).currentSyncDirectory().path,
      "/tmp/Famo Sync"
    )
  }

  func testRimeSyncSettingsWriteSyncDirectoryPreservesInstallationFields() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let installation = dir.appendingPathComponent("installation.yaml")
    try """
    installation_id: abc
    distribution_code_name: famo

    """.write(to: installation, atomically: true, encoding: .utf8)

    let target = dir.appendingPathComponent("Cloud Sync/Famo", isDirectory: true)
    let settings = FamoRimeSyncSettings(rimeDir: dir)
    try settings.setSyncDirectory(target)

    let text = try String(contentsOf: installation, encoding: .utf8)
    XCTAssertTrue(text.contains("installation_id: abc"))
    XCTAssertTrue(text.contains("distribution_code_name: famo"))
    XCTAssertTrue(text.contains("sync_dir: \"\(target.path)\""))
    XCTAssertEqual(settings.currentSyncDirectory().path, target.path)
  }

  func testKeyboardPatchPlanDefaultsSlashSymbolMenuOff() {
    let files = FamoManagedKeyboardPatchPlan.files(from: keyboardSnapshot())
    XCTAssertEqual(files.map(\.fileName), [
      "default.custom.yaml",
      "famo.custom.yaml",
      "rime_ice.custom.yaml",
      "wubi86_jidian.custom.yaml",
      "wubi86_jidian_pinyin.custom.yaml",
      "wubi86_jidian_trad.custom.yaml",
      "wubi86_jidian_trad_pinyin.custom.yaml",
    ])

    let block = files[0].block
    let text = block.yamlLinesIndentedUnderPatch.joined(separator: "\n")
    XCTAssertEqual(block.marker, FamoManagedMarker.defaultPatch)
    XCTAssertFalse(text.contains("\"punctuator/half_shape/+\":"))
    XCTAssertFalse(text.contains("\"/\": ["))

    // index 1 = famo.custom.yaml (per-app app_options, famo 域, task 07-08); indices below shift by 1.
    XCTAssertEqual(files[1].block.marker, FamoManagedMarker.famoAppOptions)
    XCTAssertEqual(files[2].block.marker, FamoManagedMarker.rimeIce)
    XCTAssertTrue(files[2].block.yamlLinesIndentedUnderPatch.isEmpty)
    XCTAssertEqual(files[3].block.marker, FamoManagedMarker.wubiJidian)
    XCTAssertTrue(files[3].block.yamlLinesIndentedUnderPatch.contains { $0.contains("translator/comment_format") })
  }

  func testKeyboardPatchPlanIncludesSlashSymbolMenuWhenEnabled() {
    let files = FamoManagedKeyboardPatchPlan.files(from: keyboardSnapshot(slashSymbolMenu: true))
    let text = files[0].block.yamlLinesIndentedUnderPatch.joined(separator: "\n")
    XCTAssertTrue(text.contains("\"punctuator/half_shape/+\":"))
    XCTAssertTrue(text.contains("\"punctuator/full_shape/+\":"))
    XCTAssertTrue(text.contains("\"/\": [\"、\", \"/\", \"／\", \"÷\"]"))
  }

  func testKeyboardPatchPlanApplyPreservesExistingUserPatch() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let original = """
    patch:
      schema_list:
        - schema: double_pinyin_flypy
      "menu/page_size": 5
      "punctuator/full_shape/+":
        "!": "！"
      "app_options/com.example.Legacy/ascii_mode": true
      "switcher/caption": test

    """
    let target = dir.appendingPathComponent("default.custom.yaml")
    try original.write(to: target, atomically: true, encoding: .utf8)

    let written = try FamoManagedKeyboardPatchPlan.apply(
      snapshot: keyboardSnapshot(),
      writer: FamoConfigWriter(rimeDir: dir),
      timestamp: "20260619-smoke"
    )

    XCTAssertEqual(written, [
      "default.custom.yaml",
      "famo.custom.yaml",
      "rime_ice.custom.yaml",
      "wubi86_jidian.custom.yaml",
      "wubi86_jidian_pinyin.custom.yaml",
      "wubi86_jidian_trad.custom.yaml",
      "wubi86_jidian_trad_pinyin.custom.yaml",
    ])
    let updated = try String(contentsOf: target, encoding: .utf8)
    XCTAssertFalse(updated.contains("double_pinyin_flypy"))
    XCTAssertFalse(updated.contains("\"menu/page_size\": 5"))
    XCTAssertFalse(updated.contains("\"!\": \"！\""))
    XCTAssertFalse(updated.contains("com.example.Legacy"))
    XCTAssertTrue(updated.contains("\"menu/page_size\": 8"))
    XCTAssertTrue(updated.contains("\"switcher/caption\": test"))
    XCTAssertTrue(updated.contains("# >>> \(FamoManagedMarker.defaultPatch)"))
    // 新开关默认关闭：重生成的托管块不得擅自改变 `/` 行为。
    XCTAssertFalse(updated.contains("\"/\": ["))
    let rimeIce = try String(contentsOf: dir.appendingPathComponent("rime_ice.custom.yaml"), encoding: .utf8)
    XCTAssertTrue(rimeIce.contains("# >>> \(FamoManagedMarker.rimeIce)"))
    XCTAssertFalse(rimeIce.contains("speller/algebra"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir
          .appendingPathComponent(".famo-backup/20260619-smoke/default.custom.yaml")
          .path
      )
    )
  }

  func testQuickSendStoreWritesFamoOwnedPhraseFileAndPatch() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let entry = try FamoQuickSendStore.entry(text: "法墨测试短语", code: "fmcs")
    try FamoQuickSendStore.save(
      [entry],
      writer: FamoConfigWriter(rimeDir: dir),
      timestamp: "20260619-quick"
    )

    let phraseFile = try String(
      contentsOf: dir.appendingPathComponent("famo_quick_send.txt"),
      encoding: .utf8
    )
    XCTAssertTrue(phraseFile.contains("#@/db_name\tfamo_quick_send"))
    XCTAssertTrue(phraseFile.contains("法墨测试短语\tfmcs\t100000"))
    XCTAssertFalse(phraseFile.contains("`fmcs"))
    XCTAssertFalse(phraseFile.contains("\tvfmcs\t"))

    let rimeIce = try String(
      contentsOf: dir.appendingPathComponent("rime_ice.custom.yaml"),
      encoding: .utf8
    )
    XCTAssertTrue(rimeIce.contains("# >>> \(FamoManagedMarker.quickSendRimeIce)"))
    XCTAssertTrue(rimeIce.contains("table_translator@famo_quick_send"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("custom_phrase.txt").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir
          .appendingPathComponent(".famo-backup/20260619-quick/famo_quick_send.txt")
          .path
      )
    )
  }

  func testQuickSendStoreRejectsUnsafeEntries() {
    XCTAssertThrowsError(try FamoQuickSendStore.entry(text: "bad\ttext", code: "fm"))
    XCTAssertThrowsError(try FamoQuickSendStore.entry(text: "法墨", code: "bad:key"))
  }

  func testConfigWriterAllowsManagedLawFormsLuaFile() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let writer = FamoConfigWriter(rimeDir: dir)
    try writer.applyTextFile(
      fileName: "lua/law_forms.lua",
      contents: "return {}\n",
      marker: "FAMO MANAGED LAW FORMS TEST",
      timestamp: "20260621-lawforms"
    )

    XCTAssertEqual(
      try String(contentsOf: dir.appendingPathComponent("lua/law_forms.lua"), encoding: .utf8),
      "return {}\n"
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir
          .appendingPathComponent(".famo-backup/20260621-lawforms/lua/law_forms.lua")
          .path
      )
    )
  }

  func testClipboardStoreDefaultsOffAndLimitsLocalEntries() throws {
    let suite = "FamoClipboardTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    XCTAssertFalse(FamoClipboardStore.isEnabled(defaults: defaults))
    FamoClipboardStore.setEnabled(true, defaults: defaults)
    XCTAssertTrue(FamoClipboardStore.isEnabled(defaults: defaults))

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let longText = String(repeating: "法", count: FamoClipboardStore.maxCharacters + 10)
    let entries = (0..<(FamoClipboardStore.maxEntries + 5)).map { index in
      FamoClipboardEntry(
        id: UUID(),
        text: "\(index)-\(longText)",
        createdAt: Date(timeIntervalSince1970: Double(index))
      )
    }
    try FamoClipboardStore.save(entries, root: dir)

    let loaded = FamoClipboardStore.load(root: dir)
    XCTAssertEqual(loaded.count, FamoClipboardStore.maxEntries)
    XCTAssertLessThanOrEqual(loaded[0].text.count, FamoClipboardStore.maxCharacters)
    let rootMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(
      atPath: FamoClipboardStore.fileURL(root: dir).path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(rootMode?.intValue, 0o700)
    XCTAssertEqual(fileMode?.intValue, 0o600)

    try FamoClipboardStore.clear(root: dir)
    XCTAssertTrue(FamoClipboardStore.load(root: dir).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: FamoClipboardStore.fileURL(root: dir).path))
  }

  func testClipboardCaptureRejectsEmptyTextAndDedupes() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    XCTAssertThrowsError(try FamoClipboardStore.capture("   ", root: dir))

    _ = try FamoClipboardStore.capture("第一条", root: dir, now: Date(timeIntervalSince1970: 1))
    _ = try FamoClipboardStore.capture("第二条", root: dir, now: Date(timeIntervalSince1970: 2))
    let loaded = try FamoClipboardStore.capture("第一条", root: dir, now: Date(timeIntervalSince1970: 3))

    XCTAssertEqual(loaded.map(\.text), ["第一条", "第二条"])
    XCTAssertEqual(loaded[0].createdAt, Date(timeIntervalSince1970: 3))
  }

  func testClipboardMigratesFromLegacyNestedPath() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Seed history only at the pre-fix nested `.../famo/clipboard-history.json` location.
    let legacy = FamoClipboardStore.legacyFileURL(root: dir)
    try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    let seeded = [FamoClipboardEntry(text: "旧记录", createdAt: Date(timeIntervalSince1970: 1))]
    try Data(JSONEncoder().encode(seeded)).write(to: legacy)

    // load() falls back to the legacy file, and the next save migrates it forward + drops legacy.
    XCTAssertEqual(FamoClipboardStore.load(root: dir).map(\.text), ["旧记录"])
    _ = try FamoClipboardStore.capture("新记录", root: dir, now: Date(timeIntervalSince1970: 2))

    XCTAssertEqual(FamoClipboardStore.load(root: dir).map(\.text), ["新记录", "旧记录"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: FamoClipboardStore.fileURL(root: dir).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
  }

  func testApplyWritesManifestAndRollbackInsideInjectedDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let original = "patch:\n  \"menu/page_size\": 5\n"
    let target = dir.appendingPathComponent("default.custom.yaml")
    try original.write(to: target, atomically: true, encoding: .utf8)

    let writer = FamoConfigWriter(rimeDir: dir)
    let block = ManagedPatchBlock(
      marker: "FAMO MANAGED TEST PATCH",
      yamlLinesIndentedUnderPatch: [
        "  \"key_binder/bindings/+\":",
        "    - { when: has_menu, accept: bracketleft, send: Page_Up }",
      ]
    )

    try writer.apply(fileName: "default.custom.yaml", block: block, timestamp: "20260618-test")

    let updated = try String(contentsOf: target, encoding: .utf8)
    XCTAssertTrue(updated.contains("# >>> FAMO MANAGED TEST PATCH"))
    XCTAssertTrue(updated.contains("accept: bracketleft"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir
          .appendingPathComponent("famo/rollback-manifest.json")
          .path
      )
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir
          .appendingPathComponent(".famo-backup/20260618-test/default.custom.yaml")
          .path
      )
    )

    try writer.rollback()
    let restored = try String(contentsOf: target, encoding: .utf8)
    XCTAssertEqual(restored, original)
  }

  func testRollbackRestoresAllFilesFromLatestApplyBatch() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let defaultOriginal = "patch:\n  \"menu/page_size\": 5\n"
    let rimeIceOriginal = "patch:\n  \"speller/algebra/+\": []\n"
    let defaultURL = dir.appendingPathComponent("default.custom.yaml")
    let rimeIceURL = dir.appendingPathComponent("rime_ice.custom.yaml")
    try defaultOriginal.write(to: defaultURL, atomically: true, encoding: .utf8)
    try rimeIceOriginal.write(to: rimeIceURL, atomically: true, encoding: .utf8)

    let writer = FamoConfigWriter(rimeDir: dir)
    let defaultBlock = ManagedPatchBlock(
      marker: "FAMO MANAGED DEFAULT TEST",
      yamlLinesIndentedUnderPatch: ["  \"menu/page_size\": 8"]
    )
    let rimeIceBlock = ManagedPatchBlock(
      marker: "FAMO MANAGED RIME_ICE TEST",
      yamlLinesIndentedUnderPatch: ["  \"speller/algebra/+\":", "    - derive/^z/zh/"]
    )

    try writer.apply(fileName: "default.custom.yaml", block: defaultBlock, timestamp: "20260619-batch")
    try writer.apply(fileName: "rime_ice.custom.yaml", block: rimeIceBlock, timestamp: "20260619-batch")
    try writer.rollback()

    XCTAssertEqual(try String(contentsOf: defaultURL, encoding: .utf8), defaultOriginal)
    XCTAssertEqual(try String(contentsOf: rimeIceURL, encoding: .utf8), rimeIceOriginal)
  }

  func testApplyRefusesRuntimeUserDataFiles() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let writer = FamoConfigWriter(rimeDir: dir)
    let block = ManagedPatchBlock(
      marker: "FAMO MANAGED TEST PATCH",
      yamlLinesIndentedUnderPatch: ["  \"menu/page_size\": 8"]
    )

    XCTAssertThrowsError(
      try writer.apply(fileName: "user.yaml", block: block, timestamp: "20260618-test")
    ) { error in
      guard case FamoConfigWriteError.refusedNeverTouch("user.yaml") = error else {
        XCTFail("Expected refusedNeverTouch(user.yaml), got \(error)")
        return
      }
    }
  }

  func testApplyRefusesFilesOutsideFamoManagedList() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let writer = FamoConfigWriter(rimeDir: dir)
    let block = ManagedPatchBlock(
      marker: "FAMO MANAGED TEST PATCH",
      yamlLinesIndentedUnderPatch: ["  \"menu/page_size\": 8"]
    )

    XCTAssertThrowsError(
      try writer.apply(fileName: "../Squirrel/default.custom.yaml", block: block, timestamp: "20260619-test")
    ) { error in
      guard case FamoConfigWriteError.refusedUnmanagedFile("../Squirrel/default.custom.yaml") = error else {
        XCTFail("Expected refusedUnmanagedFile, got \(error)")
        return
      }
    }
  }
}

final class FamoInputSourceDisplayTests: XCTestCase {

  func testFamoInputSourceDisplayIsBranded() {
    XCTAssertEqual(
      FamoInstaller.currentInputSourceDisplayName(for: "im.famo.inputmethod.Famo.Hans"),
      "法墨输入法（im.famo.inputmethod.Famo.Hans）"
    )
  }

  func testSquirrelInputSourceDisplayWarnsItIsNotFamo() {
    XCTAssertEqual(
      FamoInstaller.currentInputSourceDisplayName(for: "im.rime.inputmethod.Squirrel.Hans"),
      "Squirrel（im.rime.inputmethod.Squirrel.Hans，当前不是法墨）"
    )
  }

  func testUnknownInputSourceDisplayFallsBackToID() {
    XCTAssertEqual(
      FamoInstaller.currentInputSourceDisplayName(for: "com.apple.keylayout.US"),
      "com.apple.keylayout.US"
    )
    XCTAssertEqual(FamoInstaller.currentInputSourceDisplayName(for: nil), "未知")
  }
}
