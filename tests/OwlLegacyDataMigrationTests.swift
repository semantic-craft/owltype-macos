//
//  OwlLegacyDataMigrationTests.swift
//  OwltypeTests — 改名工程 P4 首启用户数据迁移（docs/rename-owltype-plan.md §5）
//
//  在临时目录里跑完整链路：无 librime、无 AppKit、不碰真实的 `~/Library/Application Support`，
//  偏好用一次性 suite。锁住票 06 的四条验收：旧目录存在 / 不存在、半迁移中断重入、userdb 与
//  其余用户数据的改名映射、二次启动不重复迁移；外加那条红线 —— 旧目录一个字节不动。
//
//  本文件与 `sources/Engine/OwlLegacyDataMigration.swift` 一样，是全仓仅有的两处允许写出旧
//  品牌字面量的地方（`scripts/check-identity-residual.sh` 对二者豁免）：不写出旧名字就没法
//  断言迁移把它们接住了。
//

import Foundation
import XCTest
@testable import Owltype

private enum MigrationFileManagerFailure: Equatable {
  case enumerateStaging
  case restoreYAMLPermissions
  case hardenStagingRoot
}

private final class MigrationFaultFileManager: FileManager, @unchecked Sendable {
  private let failure: MigrationFileManagerFailure

  init(failure: MigrationFileManagerFailure) {
    self.failure = failure
    super.init()
  }

  override func contentsOfDirectory(
    at url: URL,
    includingPropertiesForKeys keys: [URLResourceKey]?,
    options mask: FileManager.DirectoryEnumerationOptions = []
  ) throws -> [URL] {
    if failure == .enumerateStaging,
       url.lastPathComponent == ".Owltype-migration-staging" {
      throw CocoaError(.fileReadNoPermission)
    }
    return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
  }

  override func setAttributes(
    _ attributes: [FileAttributeKey: Any] = [:],
    ofItemAtPath path: String
  ) throws {
    let name = URL(fileURLWithPath: path).lastPathComponent
    if failure == .restoreYAMLPermissions, name == "rime_ice.custom.yaml" {
      throw CocoaError(.fileWriteNoPermission)
    }
    if failure == .hardenStagingRoot, name == ".Owltype-migration-staging" {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.setAttributes(attributes, ofItemAtPath: path)
  }
}

final class OwlLegacyDataMigrationTests: XCTestCase {
  private var root: URL!
  private var legacyDir: URL!
  private var currentDir: URL!
  private var fm: FileManager { .default }

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwlLegacyDataMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    legacyDir = root.appendingPathComponent("Famo", isDirectory: true)
    currentDir = root.appendingPathComponent("Owltype", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    root = nil
    legacyDir = nil
    currentDir = nil
    try super.tearDownWithError()
  }

  // MARK: - Helpers

  private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

  private func text(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  @discardableResult
  private func write(_ contents: String, to name: String, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
  }

  /// 形似 LevelDB 的 `<name>.userdb/` 目录（几个文件足够验证「整目录」搬运）。
  @discardableResult
  private func makeUserDB(_ name: String, in dir: URL, marker: String = "learned") throws -> URL {
    let db = dir.appendingPathComponent("\(name).userdb", isDirectory: true)
    try fm.createDirectory(at: db, withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: db.appendingPathComponent("000095.ldb"))
    try Data("16".utf8).write(to: db.appendingPathComponent("CURRENT"))
    return db
  }

  /// 一个有代表性的旧数据根：不可再生的短语 / 提示词库、两个原名保留的 userdb、托管块 yaml、
  /// 若干两代同名的文件与子目录。
  private func makeLegacyTree() throws {
    try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)

    // 不可再生的用户数据（source of truth）。
    try write(#"[{"text":"猫头鹰输入法","code":"owl"}]"#, to: "famo_quick_send.json", in: legacyDir)
    try write("猫头鹰输入法\towl\t100000\n", to: "famo_quick_send.txt", in: legacyDir)
    try write(#"[{"code":"pp","title":"润色","body":"请润色"}]"#, to: "famo_prompts.json", in: legacyDir)
    try write("📝润色\tpp\t100000\n", to: "famo_prompts.txt", in: legacyDir)
    try makeUserDB("famo_quick_send", in: legacyDir, marker: "quick-send-learning")
    try makeUserDB("famo_prompts", in: legacyDir, marker: "prompts-learning")

    // 原名保留的 Rime 用户词库。
    try makeUserDB("rime_ice", in: legacyDir, marker: "rime-ice-learning")
    try makeUserDB("wubi86_jidian", in: legacyDir, marker: "wubi-learning")

    // 托管块 yaml。
    try write(legacyRimeIceCustomYAML, to: "rime_ice.custom.yaml", in: legacyDir)
    try write(legacyBaseCustomYAML, to: "famo.custom.yaml", in: legacyDir)

    // 标记 / 记录 / 备份 / 回滚 manifest。
    try write("famo seed v1\n", to: ".famo-seed-v2", in: legacyDir)
    try write("{}", to: ".famo-dictpack.json", in: legacyDir)
    try write("{}", to: "famo/rollback-manifest.json", in: legacyDir)
    try write("old", to: ".famo-backup/20260819-114100/famo.custom.yaml", in: legacyDir)

    // 两代同名，整目录复制直接带过来。
    try write("[]", to: "clipboard-history.json", in: legacyDir)
    try write(#"{"profiles":[]}"#, to: "providers.json", in: legacyDir)
    try write("{}", to: "projects/p1/project.json", in: legacyDir)
    try write("distribution_code_name: Famo\n", to: "installation.yaml", in: legacyDir)
  }

  private let legacyRimeIceCustomYAML = """
    patch:
      grammar:
        language: zh-hans-t-essay-bgw

      # >>> FAMO MANAGED QUICK_SEND RIME_ICE PATCH v1
      "engine/translators/+":
        - table_translator@famo_quick_send
      famo_quick_send:
        dictionary: ""
        user_dict: famo_quick_send
        db_class: stabledb
      # <<< FAMO MANAGED QUICK_SEND RIME_ICE PATCH v1

      # >>> FAMO MANAGED PROMPTS RIME_ICE PATCH v1
      famo_prompts:
        user_dict: famo_prompts
      # <<< FAMO MANAGED PROMPTS RIME_ICE PATCH v1

    """

  private let legacyBaseCustomYAML = """
    patch:
      # >>> FAMO MANAGED FAMO_CUSTOM APP_OPTIONS v1
      app_options/com.apple.Terminal:
        ascii_mode: true
      # <<< FAMO MANAGED FAMO_CUSTOM APP_OPTIONS v1

    """

  @discardableResult
  private func migrate(
    timestamp: String = "2026-08-21T00:00:00Z",
    fileManager: FileManager = .default,
    managedYAMLWriter: @escaping (String, URL) throws -> Void = { contents, url in
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
  ) throws -> OwlLegacyDataMigrationOutcome {
    try OwlLegacyDataMigration.migrateUserDirectoryIfNeeded(
      legacyDir: legacyDir,
      currentDir: currentDir,
      timestamp: timestamp,
      fileManager: fileManager,
      managedYAMLWriter: managedYAMLWriter
    )
  }

  private func assertMigrationRolledBack(
    to legacySnapshot: [String: Data],
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertFalse(exists(currentDir), "失败时不能发布正式目录", file: file, line: line)
    XCTAssertNil(OwlLegacyDataMigration.receipt(in: currentDir), file: file, line: line)
    XCTAssertFalse(
      exists(OwlLegacyDataMigration.stagingDirectory(for: currentDir)),
      "失败时必须清理 staging",
      file: file,
      line: line
    )
    XCTAssertEqual(try snapshot(of: legacyDir), legacySnapshot, "失败不得改动迁移源", file: file, line: line)
  }

  // MARK: - 旧目录不存在

  func testNoLegacyDirectoryIsANoOp() throws {
    XCTAssertEqual(try migrate(), .noLegacyData)
    XCTAssertFalse(exists(currentDir), "全新安装不该由迁移去建数据根 —— 那是 setupRime 的活")
    XCTAssertNil(OwlLegacyDataMigration.receipt(in: currentDir))
  }

  /// plan §5 第 4 条（fd5f75a 加的顺序红线）：**旧目录不存在时绝不写「迁移完成」标记**。
  /// P5 的旧卸载器会把迁移源一起删掉，用户要从备份恢复；跑空一次就落标记的话，恢复之后
  /// 迁移永远不会再跑。空跑必须不留任何痕迹。
  func testEmptyRunLeavesNoTraceSoARestoredBackupStillMigrates() throws {
    XCTAssertEqual(try migrate(), .noLegacyData)
    XCTAssertFalse(exists(currentDir))
    XCTAssertFalse(exists(OwlLegacyDataMigration.stagingDirectory(for: currentDir)))

    // 用户从备份恢复了旧目录 —— 下一次启动必须真的迁移。
    try makeLegacyTree()
    guard case .migrated = try migrate() else {
      return XCTFail("空跑不该锁死迁移：恢复备份后必须还能迁")
    }
    XCTAssertEqual(
      try text(at: currentDir.appendingPathComponent("owl_quick_send.json")),
      #"[{"text":"猫头鹰输入法","code":"owl"}]"#
    )
  }

  func testLegacyPathThatIsAFileIsNotTreatedAsData() throws {
    try Data("not a directory".utf8).write(to: legacyDir)
    XCTAssertEqual(try migrate(), .noLegacyData)
    XCTAssertFalse(exists(currentDir))
  }

  // MARK: - 旧目录存在：整目录复制 + 改名映射

  func testMigrationCopiesEverythingAndAppliesRenameMap() throws {
    try makeLegacyTree()

    guard case .migrated(let renamed) = try migrate() else {
      return XCTFail("旧目录存在时应当迁移")
    }

    // 不可再生的用户数据按新名到位，内容逐字节保留。
    XCTAssertEqual(
      try text(at: currentDir.appendingPathComponent("owl_quick_send.json")),
      #"[{"text":"猫头鹰输入法","code":"owl"}]"#
    )
    XCTAssertEqual(
      try text(at: currentDir.appendingPathComponent("owl_prompts.json")),
      #"[{"code":"pp","title":"润色","body":"请润色"}]"#
    )
    XCTAssertEqual(try text(at: currentDir.appendingPathComponent("owl_quick_send.txt")), "猫头鹰输入法\towl\t100000\n")
    XCTAssertEqual(try text(at: currentDir.appendingPathComponent("owl_prompts.txt")), "📝润色\tpp\t100000\n")

    // userdb 改名映射：整目录搬过来，学习数据还在。
    XCTAssertEqual(
      try text(at: currentDir.appendingPathComponent("owl_quick_send.userdb/000095.ldb")),
      "quick-send-learning"
    )
    XCTAssertEqual(
      try text(at: currentDir.appendingPathComponent("owl_prompts.userdb/000095.ldb")),
      "prompts-learning"
    )

    // rime_ice / wubi86_jidian 原名保留（票 06 点名的例外）。
    XCTAssertEqual(
      try text(at: currentDir.appendingPathComponent("rime_ice.userdb/000095.ldb")),
      "rime-ice-learning"
    )
    XCTAssertEqual(
      try text(at: currentDir.appendingPathComponent("wubi86_jidian.userdb/000095.ldb")),
      "wubi-learning"
    )
    XCTAssertFalse(exists(currentDir.appendingPathComponent("owl_ice.userdb")))

    // 其余改名项。
    XCTAssertTrue(exists(currentDir.appendingPathComponent("owltype.custom.yaml")))
    XCTAssertTrue(exists(currentDir.appendingPathComponent(".owl-seed-v2")))
    XCTAssertTrue(exists(currentDir.appendingPathComponent(".owl-dictpack.json")))
    XCTAssertTrue(exists(currentDir.appendingPathComponent(".owl-backup/20260819-114100/famo.custom.yaml")))
    XCTAssertTrue(exists(currentDir.appendingPathComponent("owltype/rollback-manifest.json")))

    // 旧名一个不剩。
    for pair in OwlLegacyDataMigration.renameMap {
      XCTAssertFalse(
        exists(currentDir.appendingPathComponent(pair.legacy)),
        "\(pair.legacy) 应已改名为 \(pair.current)"
      )
    }

    // 两代同名的照常在。
    XCTAssertTrue(exists(currentDir.appendingPathComponent("clipboard-history.json")))
    XCTAssertTrue(exists(currentDir.appendingPathComponent("providers.json")))
    XCTAssertTrue(exists(currentDir.appendingPathComponent("projects/p1/project.json")))
    XCTAssertTrue(exists(currentDir.appendingPathComponent("installation.yaml")))

    // 收据记下了改到的新名字。
    XCTAssertEqual(Set(renamed), Set([
      "owltype.custom.yaml",
      "owl_quick_send.json", "owl_quick_send.txt", "owl_quick_send.userdb",
      "owl_prompts.json", "owl_prompts.txt", "owl_prompts.userdb",
      ".owl-seed-v2", ".owl-dictpack.json", ".owl-backup", "owltype"
    ]))
    let receipt = try XCTUnwrap(OwlLegacyDataMigration.receipt(in: currentDir))
    XCTAssertEqual(receipt.source, legacyDir.path)
    XCTAssertEqual(receipt.migratedAt, "2026-08-21T00:00:00Z")
    XCTAssertEqual(Set(receipt.renamed), Set(renamed))
  }

  /// 红线：旧目录一个字节不动 —— 复制不是移动。
  func testLegacyDirectoryIsLeftByteForByteIntact() throws {
    try makeLegacyTree()
    let before = try snapshot(of: legacyDir)

    try migrate()

    XCTAssertEqual(try snapshot(of: legacyDir), before, "旧目录必须原封不动（先复制后改名）")
  }

  func testMigrationRejectsLegacyAndCurrentNameCollisionWithoutPublishing() throws {
    try makeLegacyTree()
    try write("stale current data", to: "owl_quick_send.json", in: legacyDir)
    let before = try snapshot(of: legacyDir)

    XCTAssertThrowsError(try migrate()) { error in
      guard let migrationError = error as? OwlLegacyDataMigrationError,
            case .renameFailed(let name, _) = migrationError else {
        return XCTFail("应抛出 renameFailed，实际为 \(error)")
      }
      XCTAssertEqual(name, "famo_quick_send.json")
    }

    XCTAssertFalse(exists(currentDir), "撞名时不能发布一棵混有陈旧新名数据的目录")
    XCTAssertNil(OwlLegacyDataMigration.receipt(in: currentDir))
    XCTAssertFalse(exists(OwlLegacyDataMigration.stagingDirectory(for: currentDir)))
    XCTAssertEqual(try snapshot(of: legacyDir), before, "冲突失败不得改动迁移源")
  }

  /// `<相对路径>` → 原始字节，用来断言整棵树（包括非 UTF-8 文件）未被改动。
  private func snapshot(of dir: URL) throws -> [String: Data] {
    var out: [String: Data] = [:]
    let base = dir.standardizedFileURL.path
    let walker = try XCTUnwrap(fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let url as URL in walker {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
      out[relative] = try Data(contentsOf: url)
    }
    return out
  }

  // MARK: - 托管块标识改写

  func testManagedMarkersAndIdentifiersAreRewrittenInCustomYAML() throws {
    try makeLegacyTree()
    try migrate()

    let rimeIce = try text(at: currentDir.appendingPathComponent("rime_ice.custom.yaml"))
    XCTAssertTrue(rimeIce.contains("# >>> OWL MANAGED QUICK_SEND RIME_ICE PATCH v1"))
    XCTAssertTrue(rimeIce.contains("# >>> OWL MANAGED PROMPTS RIME_ICE PATCH v1"))
    XCTAssertTrue(rimeIce.contains("- table_translator@owl_quick_send"))
    XCTAssertTrue(rimeIce.contains("user_dict: owl_quick_send"))
    XCTAssertTrue(rimeIce.contains("user_dict: owl_prompts"))
    XCTAssertFalse(rimeIce.contains("FAMO MANAGED"), "旧 marker 留着会让新 app 在同一个 patch 里另起一套块")
    XCTAssertFalse(rimeIce.contains("famo_quick_send"))
    XCTAssertFalse(rimeIce.contains("famo_prompts"))

    // 复合 marker：FAMO MANAGED + FAMO_CUSTOM 两个 token 都要换到位。
    let base = try text(at: currentDir.appendingPathComponent("owltype.custom.yaml"))
    XCTAssertTrue(base.contains("# >>> OWL MANAGED OWLTYPE_CUSTOM APP_OPTIONS v1"))
    XCTAssertTrue(base.contains("# <<< OWL MANAGED OWLTYPE_CUSTOM APP_OPTIONS v1"))

    // 与新 app 的 marker 常量逐字相同 —— 对不上就等于没改。
    XCTAssertTrue(rimeIce.contains(OwlManagedMarker.quickSendRimeIce))
    XCTAssertTrue(rimeIce.contains(OwlManagedMarker.promptsRimeIce))
    XCTAssertTrue(base.contains(OwlManagedMarker.owlAppOptions))
  }

  func testMigrationRejectsInvalidUTF8CustomYAMLWithoutPublishing() throws {
    try makeLegacyTree()
    let invalidYAML = legacyDir.appendingPathComponent("broken.custom.yaml")
    try Data([0xFF, 0xFE, 0x00]).write(to: invalidYAML)
    let before = try snapshot(of: legacyDir)

    XCTAssertThrowsError(try migrate()) { error in
      guard let migrationError = error as? OwlLegacyDataMigrationError,
            case .yamlRewriteFailed(let name, _) = migrationError else {
        return XCTFail("应抛出 yamlRewriteFailed，实际为 \(error)")
      }
      XCTAssertEqual(name, "broken.custom.yaml")
    }

    XCTAssertFalse(exists(currentDir), "配置无法改写时不能发布并永久写下完成标记")
    XCTAssertNil(OwlLegacyDataMigration.receipt(in: currentDir))
    XCTAssertFalse(exists(OwlLegacyDataMigration.stagingDirectory(for: currentDir)))
    XCTAssertEqual(try snapshot(of: legacyDir), before, "配置读取失败不得改动迁移源")
  }

  func testMigrationRollsBackWhenCustomYAMLDirectoryCannotBeEnumerated() throws {
    try makeLegacyTree()
    let before = try snapshot(of: legacyDir)
    let faultFM = MigrationFaultFileManager(failure: .enumerateStaging)

    XCTAssertThrowsError(try migrate(fileManager: faultFM)) { error in
      guard let migrationError = error as? OwlLegacyDataMigrationError,
            case .yamlRewriteFailed(let name, _) = migrationError else {
        return XCTFail("应抛出 yamlRewriteFailed，实际为 \(error)")
      }
      XCTAssertEqual(name, ".Owltype-migration-staging")
    }
    try assertMigrationRolledBack(to: before)
  }

  func testMigrationRollsBackWhenCustomYAMLPermissionsCannotBeRestored() throws {
    try makeLegacyTree()
    let before = try snapshot(of: legacyDir)
    let faultFM = MigrationFaultFileManager(failure: .restoreYAMLPermissions)

    XCTAssertThrowsError(try migrate(fileManager: faultFM)) { error in
      guard let migrationError = error as? OwlLegacyDataMigrationError,
            case .yamlRewriteFailed(let name, _) = migrationError else {
        return XCTFail("应抛出 yamlRewriteFailed，实际为 \(error)")
      }
      XCTAssertEqual(name, "rime_ice.custom.yaml")
    }
    try assertMigrationRolledBack(to: before)
  }

  func testMigrationRollsBackWhenCustomYAMLAtomicWriteFails() throws {
    try makeLegacyTree()
    let before = try snapshot(of: legacyDir)

    XCTAssertThrowsError(
      try migrate { contents, url in
        if url.lastPathComponent == "rime_ice.custom.yaml" {
          throw CocoaError(.fileWriteNoPermission)
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
      }
    ) { error in
      guard let migrationError = error as? OwlLegacyDataMigrationError,
            case .yamlRewriteFailed(let name, _) = migrationError else {
        return XCTFail("应抛出 yamlRewriteFailed，实际为 \(error)")
      }
      XCTAssertEqual(name, "rime_ice.custom.yaml")
    }
    try assertMigrationRolledBack(to: before)
  }

  func testMigrationRollsBackWhenStagingRootPermissionsCannotBeHardened() throws {
    try makeLegacyTree()
    let before = try snapshot(of: legacyDir)
    let faultFM = MigrationFaultFileManager(failure: .hardenStagingRoot)

    XCTAssertThrowsError(try migrate(fileManager: faultFM)) { error in
      guard let migrationError = error as? OwlLegacyDataMigrationError,
            case .rootPermissionsFailed(let name, _) = migrationError else {
        return XCTFail("应抛出 rootPermissionsFailed，实际为 \(error)")
      }
      XCTAssertEqual(name, ".Owltype-migration-staging")
    }
    try assertMigrationRolledBack(to: before)
  }

  func testTokenRewriteIsOrderIndependentAndLeavesOtherTextAlone() {
    let rewritten = OwlLegacyDataMigration.rewritingManagedTokens(
      "# >>> FAMO MANAGED FAMO_CUSTOM APP_OPTIONS v1\n# 法墨：雾凇全拼\nrime_ice.userdb\n"
    )
    XCTAssertEqual(
      rewritten,
      "# >>> OWL MANAGED OWLTYPE_CUSTOM APP_OPTIONS v1\n# 法墨：雾凇全拼\nrime_ice.userdb\n",
      "只换会影响行为的标识；注释里的旧品牌是历史，不在本模块职责内"
    )
  }

  // MARK: - 幂等 / 二次启动

  func testSecondLaunchDoesNotMigrateAgain() throws {
    try makeLegacyTree()
    try migrate()

    // 用户在新 app 里改过短语；第二次启动绝不能被旧库盖回去。
    let quickSend = currentDir.appendingPathComponent("owl_quick_send.json")
    try Data(#"[{"text":"改过了","code":"x"}]"#.utf8).write(to: quickSend)

    XCTAssertEqual(try migrate(), .alreadyMigrated)
    XCTAssertEqual(try text(at: quickSend), #"[{"text":"改过了","code":"x"}]"#)
  }

  func testExistingCurrentDirectoryWithoutMarkerIsNeverOverwritten() throws {
    try makeLegacyTree()
    try fm.createDirectory(at: currentDir, withIntermediateDirectories: true)
    try write("mine", to: "owl_quick_send.json", in: currentDir)

    XCTAssertEqual(try migrate(), .currentDirectoryPresent)
    XCTAssertEqual(try text(at: currentDir.appendingPathComponent("owl_quick_send.json")), "mine")
    XCTAssertFalse(exists(currentDir.appendingPathComponent("owl_prompts.json")))
  }

  // MARK: - 半迁移中断重入

  func testStaleStagingFromAnInterruptedRunIsDiscardedAndRerunSucceeds() throws {
    try makeLegacyTree()

    // 上一次跑到一半被打断：staging 里只有半棵树，正式目录还不存在。
    let staging = OwlLegacyDataMigration.stagingDirectory(for: currentDir)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    try write("half-copied garbage", to: "famo_quick_send.json", in: staging)
    try write("stale", to: "leftover-from-crash.txt", in: staging)

    guard case .migrated = try migrate() else { return XCTFail("中断后重入应当重跑完整迁移") }

    XCTAssertFalse(exists(staging), "staging 残骸必须清掉")
    XCTAssertFalse(exists(currentDir.appendingPathComponent("leftover-from-crash.txt")))
    XCTAssertEqual(
      try text(at: currentDir.appendingPathComponent("owl_quick_send.json")),
      #"[{"text":"猫头鹰输入法","code":"owl"}]"#,
      "重入拿到的必须是旧目录的真数据，不是上次的半成品"
    )
  }

  /// 中断永远发生在「挂成正式目录」之前 —— 那一步是同目录 rename(2)。所以磁盘上不存在
  /// 「半个正式目录」这种形态：要么没有，要么完整且带标记。
  func testMigrationIsAllOrNothing() throws {
    try makeLegacyTree()
    // 让最后一步必然失败：正式目录的父路径上放一个同名普通文件占位。
    let blocked = root.appendingPathComponent("blocked", isDirectory: true)
    let blockedCurrent = blocked.appendingPathComponent("Owltype", isDirectory: true)
    try Data("in the way".utf8).write(to: blocked)

    XCTAssertThrowsError(
      try OwlLegacyDataMigration.migrateUserDirectoryIfNeeded(
        legacyDir: legacyDir,
        currentDir: blockedCurrent,
        timestamp: "2026-08-21T00:00:00Z"
      )
    )
    XCTAssertFalse(exists(OwlLegacyDataMigration.stagingDirectory(for: blockedCurrent)))
    XCTAssertEqual(try text(at: legacyDir.appendingPathComponent("famo_quick_send.json")),
                   #"[{"text":"猫头鹰输入法","code":"owl"}]"#,
                   "失败后旧目录仍是唯一完好的一份")
  }

  // MARK: - 偏好整域导入

  func testLegacyDefaultsAreImportedOnceAndNeverOverwriteExistingValues() throws {
    let suite = "OwlLegacyDataMigrationTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set("mine", forKey: "sharedKey")

    let imported = OwlLegacyDataMigration.importLegacyDefaults(
      from: ["sharedKey": "legacy", "legacyOnly": 7, "flag": true],
      into: defaults
    )

    XCTAssertEqual(imported, 2)
    XCTAssertEqual(defaults.string(forKey: "sharedKey"), "mine", "新域已有的值优先，绝不被旧值盖掉")
    XCTAssertEqual(defaults.integer(forKey: "legacyOnly"), 7)
    XCTAssertTrue(defaults.bool(forKey: "flag"))
    XCTAssertTrue(defaults.bool(forKey: OwlLegacyDataMigration.defaultsImportedKey))

    // 二次启动：标记在，整域导入不再跑。
    XCTAssertEqual(
      OwlLegacyDataMigration.importLegacyDefaults(from: ["legacyOnly": 999], into: defaults),
      0
    )
    XCTAssertEqual(defaults.integer(forKey: "legacyOnly"), 7)
  }

  func testMissingLegacyDomainIsNotAFailureAndStillLandsTheMarker() throws {
    let suite = "OwlLegacyDataMigrationTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    XCTAssertEqual(OwlLegacyDataMigration.importLegacyDefaults(from: nil, into: defaults), 0)
    XCTAssertTrue(
      defaults.bool(forKey: OwlLegacyDataMigration.defaultsImportedKey),
      "旧域不存在也要落标记，否则每次启动都去翻一遍不存在的域"
    )
  }

  // MARK: - 真实旧目录（票 06 验收第 2 条：本地模拟旧目录验证）

  /// 拿一棵**真的**旧数据根跑一遍完整迁移。默认跳过；把 `OWL_MIGRATION_LEGACY_FIXTURE` 指到
  /// 一份旧目录的副本即可开跑（P5 装机前的自检也用它）。注意 `TEST_RUNNER_` 前缀不可省：
  /// xcodebuild 不转发 shell 环境变量，只有带该前缀的才会被剥掉前缀送进测试进程。
  ///
  ///     cp -a ~/Library/Application\ Support/Famo /tmp/legacy-fixture
  ///     TEST_RUNNER_OWL_MIGRATION_LEGACY_FIXTURE=/tmp/legacy-fixture xcodebuild … \\
  ///       -only-testing:OwltypeTests/OwlLegacyDataMigrationTests
  ///
  /// 指向的是副本而不是真目录本身：本测试只读源，但让一条自动化跑在唯一一份不可再生数据上
  /// 本身就是坏习惯。合成树验证的是机制，这条验证的是改名映射对真实文件名齐不齐。
  func testRealLegacyTreeFixtureMigratesCleanly() throws {
    let fixture = ProcessInfo.processInfo.environment["OWL_MIGRATION_LEGACY_FIXTURE"] ?? ""
    try XCTSkipIf(fixture.isEmpty, "set OWL_MIGRATION_LEGACY_FIXTURE to a copy of a legacy data root")
    let source = URL(fileURLWithPath: fixture, isDirectory: true)
    try fm.copyItem(at: source, to: legacyDir)

    guard case .migrated = try migrate() else { return XCTFail("fixture 应当被迁移") }

    // 迁完的树里不该再有任何旧品牌命名的**顶层**条目（`.owl-backup/` 里的历史快照除外 ——
    // 那是刻意保持旧名的旧世界快照，见 renameMap 注释）。
    let top = try fm.contentsOfDirectory(atPath: currentDir.path)
      .filter { $0.lowercased().contains("famo") }
    XCTAssertEqual(top, [], "顶层仍有旧名条目，改名映射漏了它们")

    // 托管块 marker 全部换代，且没有留下会与新块撞键的旧块。
    for name in try fm.contentsOfDirectory(atPath: currentDir.path) where name.hasSuffix(".custom.yaml") {
      let body = try text(at: currentDir.appendingPathComponent(name))
      XCTAssertFalse(body.contains("FAMO MANAGED"), "\(name) 仍带旧 marker")
      XCTAssertFalse(body.contains("famo_quick_send"), "\(name) 仍指向旧短语表")
      XCTAssertFalse(body.contains("famo_prompts"), "\(name) 仍指向旧提示词表")
    }

    // 源副本原封不动。
    XCTAssertEqual(try snapshot(of: legacyDir), try snapshot(of: source))
    XCTAssertNotNil(OwlLegacyDataMigration.receipt(in: currentDir))
  }

  // MARK: - 沙箱护栏

  func testTestUserDirOverrideDisablesTheWholeMigration() {
    // `OWL_TEST_USER_DIR` 生效时不该有迁移源 —— 开发 / 测试沙箱不搬真实旧数据。
    // 单测宿主本身就跑在覆盖态之外，所以这里只断言两者的联动契约。
    let override = ProcessInfo.processInfo.environment["OWL_TEST_USER_DIR"]
    if let override, !override.isEmpty {
      XCTAssertNil(OwlApp.legacyUserDir)
    } else {
      XCTAssertEqual(OwlApp.legacyUserDir?.lastPathComponent, OwlLegacyDataMigration.legacyDirectoryName)
      XCTAssertEqual(
        OwlApp.legacyUserDir?.deletingLastPathComponent().path,
        OwlApp.userDir.deletingLastPathComponent().path,
        "迁移源必须与数据根同父，最后一步才是同卷 rename(2)"
      )
    }
  }
}
