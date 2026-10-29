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

final class OwlConfigWriterBoundaryTests: XCTestCase {

  private let fuzzyOff = OwlFuzzySnapshot(
    zhz: false, chc: false, shs: false, nl: false, rl: false,
    fh: false, anang: false, eneng: false, ining: false
  )

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-config-writer-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func keyboardSnapshot(
    fuzzy: OwlFuzzySnapshot? = nil,
    slashSymbolMenu: Bool = false
  ) -> OwlKeyboardSnapshot {
    OwlKeyboardSnapshot(
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

  func testDefaultDirectoryIsOwltypeUserDataDir() {
    let writer = OwlConfigWriter()
    XCTAssertEqual(
      writer.dataDir.standardizedFileURL.path,
      OwlApp.userDir.standardizedFileURL.path
    )
    XCTAssertFalse(
      writer.dataDir.path.hasSuffix("/Library/Rime"),
      "Owltype must not default to the user's shared Rime directory"
    )
  }

  func testRimeSyncSettingsDefaultToOwltypeSyncDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let settings = OwlSyncSettings(dataDir: dir)
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
    sync_dir: "/tmp/Owltype Sync"
    distribution_code_name: owltype

    """.write(to: dir.appendingPathComponent("installation.yaml"), atomically: true, encoding: .utf8)

    XCTAssertEqual(
      OwlSyncSettings(dataDir: dir).currentSyncDirectory().path,
      "/tmp/Owltype Sync"
    )
  }

  func testRimeSyncSettingsExpandsTildeWithoutRewritingInstallationFile() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let installation = dir.appendingPathComponent("installation.yaml")
    try """
    installation_id: abc
    sync_dir: "~/Library/CloudStorage/Owltype Sync"
    distribution_code_name: owltype

    """.write(to: installation, atomically: true, encoding: .utf8)
    let before = try Data(contentsOf: installation)

    let settings = OwlSyncSettings(dataDir: dir)
    XCTAssertEqual(
      settings.currentSyncDirectory().path,
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage/Owltype Sync").path
    )
    XCTAssertEqual(try Data(contentsOf: installation), before)
  }

  func testKeyboardPatchPlanDefaultsSlashSymbolMenuOff() {
    let files = OwlManagedKeyboardPatchPlan.files(from: keyboardSnapshot())
    XCTAssertEqual(files.map(\.fileName), [
      "default.custom.yaml",
      "owltype.custom.yaml",
      "rime_ice.custom.yaml",
      "wubi86_jidian.custom.yaml",
      "wubi86_jidian_pinyin.custom.yaml",
      "wubi86_jidian_trad.custom.yaml",
      "wubi86_jidian_trad_pinyin.custom.yaml",
    ])

    let block = files[0].block
    let text = block.yamlLinesIndentedUnderPatch.joined(separator: "\n")
    XCTAssertEqual(block.marker, OwlManagedMarker.defaultPatch)
    XCTAssertFalse(text.contains("\"punctuator/half_shape/+\":"))
    XCTAssertFalse(text.contains("\"/\": ["))

    // index 1 = owltype.custom.yaml (per-app app_options, owltype 域, task 07-08); indices below shift by 1.
    XCTAssertEqual(files[1].block.marker, OwlManagedMarker.owlAppOptions)
    XCTAssertEqual(files[2].block.marker, OwlManagedMarker.rimeIce)
    XCTAssertTrue(files[2].block.yamlLinesIndentedUnderPatch.isEmpty)
    XCTAssertEqual(files[3].block.marker, OwlManagedMarker.wubiJidian)
    XCTAssertTrue(files[3].block.yamlLinesIndentedUnderPatch.contains { $0.contains("translator/comment_format") })
  }

  func testKeyboardPatchPlanIncludesSlashSymbolMenuWhenEnabled() {
    let files = OwlManagedKeyboardPatchPlan.files(from: keyboardSnapshot(slashSymbolMenu: true))
    let text = files[0].block.yamlLinesIndentedUnderPatch.joined(separator: "\n")
    XCTAssertTrue(text.contains("\"punctuator/half_shape/+\":"))
    XCTAssertTrue(text.contains("\"punctuator/full_shape/+\":"))
    XCTAssertTrue(text.contains("\"/\": [\"、\", \"/\", \"／\", \"÷\"]"))

    for file in files.dropFirst(3) {
      let wubiText = file.block.yamlLinesIndentedUnderPatch.joined(separator: "\n")
      XCTAssertTrue(wubiText.contains("\"punctuator/half_shape/+\":"), file.fileName)
      XCTAssertTrue(wubiText.contains("\"punctuator/full_shape/+\":"), file.fileName)
      XCTAssertTrue(
        wubiText.contains("\"/\": [\"、\", \"/\", \"／\", \"÷\"]"),
        file.fileName
      )
    }
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

    let written = try OwlManagedKeyboardPatchPlan.apply(
      snapshot: keyboardSnapshot(),
      writer: OwlConfigWriter(dataDir: dir),
      timestamp: "20260619-smoke"
    )

    XCTAssertEqual(written, [
      "default.custom.yaml",
      "owltype.custom.yaml",
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
    XCTAssertTrue(updated.contains("# >>> \(OwlManagedMarker.defaultPatch)"))
    // 新开关默认关闭：重生成的托管块不得擅自改变 `/` 行为。
    XCTAssertFalse(updated.contains("\"/\": ["))
    let rimeIce = try String(contentsOf: dir.appendingPathComponent("rime_ice.custom.yaml"), encoding: .utf8)
    XCTAssertTrue(rimeIce.contains("# >>> \(OwlManagedMarker.rimeIce)"))
    XCTAssertFalse(rimeIce.contains("speller/algebra"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir
          .appendingPathComponent(".owl-backup/20260619-smoke/default.custom.yaml")
          .path
      )
    )
  }

  func testQuickSendStoreWritesOwltypeOwnedPhraseFileAndPatch() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let entry = try OwlQuickSendStore.entry(text: "猫头鹰测试短语", code: "mtycs")
    try OwlQuickSendStore.save(
      [entry],
      writer: OwlConfigWriter(dataDir: dir),
      timestamp: "20260619-quick"
    )

    let phraseFile = try String(
      contentsOf: dir.appendingPathComponent("owl_quick_send.txt"),
      encoding: .utf8
    )
    XCTAssertTrue(phraseFile.contains("#@/db_name\towl_quick_send"))
    XCTAssertTrue(phraseFile.contains("猫头鹰测试短语\tmtycs\t100000"))
    XCTAssertFalse(phraseFile.contains("`mtycs"))
    XCTAssertFalse(phraseFile.contains("\tvmtycs\t"))

    let rimeIce = try String(
      contentsOf: dir.appendingPathComponent("rime_ice.custom.yaml"),
      encoding: .utf8
    )
    XCTAssertTrue(rimeIce.contains("# >>> \(OwlManagedMarker.quickSendRimeIce)"))
    XCTAssertTrue(rimeIce.contains("table_translator@owl_quick_send"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("custom_phrase.txt").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir
          .appendingPathComponent(".owl-backup/20260619-quick/owl_quick_send.txt")
          .path
      )
    )
  }

  func testQuickSendStoreRejectsUnsafeEntries() {
    XCTAssertThrowsError(try OwlQuickSendStore.entry(text: "bad\ttext", code: "fm"))
    XCTAssertThrowsError(try OwlQuickSendStore.entry(text: "猫头鹰", code: "bad:key"))
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

  func testApplyWritesManifestAndRollbackInsideInjectedDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let original = "patch:\n  \"menu/page_size\": 5\n"
    let target = dir.appendingPathComponent("default.custom.yaml")
    try original.write(to: target, atomically: true, encoding: .utf8)

    let writer = OwlConfigWriter(dataDir: dir)
    let block = ManagedPatchBlock(
      marker: "OWL MANAGED TEST PATCH",
      yamlLinesIndentedUnderPatch: [
        "  \"key_binder/bindings/+\":",
        "    - { when: has_menu, accept: bracketleft, send: Page_Up }",
      ]
    )

    try writer.apply(fileName: "default.custom.yaml", block: block, timestamp: "20260618-test")

    let updated = try String(contentsOf: target, encoding: .utf8)
    XCTAssertTrue(updated.contains("# >>> OWL MANAGED TEST PATCH"))
    XCTAssertTrue(updated.contains("accept: bracketleft"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir
          .appendingPathComponent("owltype/rollback-manifest.json")
          .path
      )
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir
          .appendingPathComponent(".owl-backup/20260618-test/default.custom.yaml")
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

    let writer = OwlConfigWriter(dataDir: dir)
    let defaultBlock = ManagedPatchBlock(
      marker: "OWL MANAGED DEFAULT TEST",
      yamlLinesIndentedUnderPatch: ["  \"menu/page_size\": 8"]
    )
    let rimeIceBlock = ManagedPatchBlock(
      marker: "OWL MANAGED RIME_ICE TEST",
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

    let writer = OwlConfigWriter(dataDir: dir)
    let block = ManagedPatchBlock(
      marker: "OWL MANAGED TEST PATCH",
      yamlLinesIndentedUnderPatch: ["  \"menu/page_size\": 8"]
    )

    XCTAssertThrowsError(
      try writer.apply(fileName: "user.yaml", block: block, timestamp: "20260618-test")
    ) { error in
      guard case OwlConfigWriteError.refusedNeverTouch("user.yaml") = error else {
        XCTFail("Expected refusedNeverTouch(user.yaml), got \(error)")
        return
      }
    }
  }

  func testApplyRefusesFilesOutsideOwltypeManagedList() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let writer = OwlConfigWriter(dataDir: dir)
    let block = ManagedPatchBlock(
      marker: "OWL MANAGED TEST PATCH",
      yamlLinesIndentedUnderPatch: ["  \"menu/page_size\": 8"]
    )

    XCTAssertThrowsError(
      try writer.apply(fileName: "../Squirrel/default.custom.yaml", block: block, timestamp: "20260619-test")
    ) { error in
      guard case OwlConfigWriteError.refusedUnmanagedFile("../Squirrel/default.custom.yaml") = error else {
        XCTFail("Expected refusedUnmanagedFile, got \(error)")
        return
      }
    }
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
