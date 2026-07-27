//
//  FamoDictPackTests.swift
//  FamoTests — dict-pack（方案B 首启拉取）全链路：下载/sha256 校验/patch/落盘/所有权保护。
//
//  No network, no librime：baseURLOverride 注入 file:// fixture 根，URLSession 走本地文件。
//  fixture 布局与线上 raw 路径同构：<root>/<repo>/<ref>/<path>。
//

import Foundation
import XCTest
@testable import Famo

final class FamoDictPackTests: XCTestCase {

  private var fixtureRoot: URL!
  private var userDir: URL!

  override func setUpWithError() throws {
    let base = FileManager.default.temporaryDirectory
      .appending(component: "famo-dictpack-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    fixtureRoot = base.appending(component: "fixture", directoryHint: .isDirectory)
    userDir = base.appending(component: "user", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: fixtureRoot.deletingLastPathComponent())
  }

  // MARK: - helpers

  /// 把 content 写进 fixture 的 <repo>/<ref>/<path>，返回对应 manifest 条目。
  private func stub(
    repo: String = "iDvel/rime-ice", ref: String = "deadbeef", path: String, dest: String,
    content: String, patch: FamoDictPackPatch? = nil
  ) throws -> FamoDictPackFile {
    let data = Data(content.utf8)
    let url = fixtureRoot.appending(path: "\(repo)/\(ref)/\(path)", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return FamoDictPackFile(
      repo: repo, ref: ref, path: path, dest: dest,
      sha256: FamoDictPackFetcher.sha256Hex(data), size: data.count, patch: patch)
  }

  private func fetcher(_ files: [FamoDictPackFile], version: Int = 1) -> FamoDictPackFetcher {
    FamoDictPackFetcher(
      manifest: FamoDictPackManifest(version: version, files: files),
      userDir: userDir,
      baseURLOverride: fixtureRoot.absoluteString.hasSuffix("/")
        ? String(fixtureRoot.absoluteString.dropLast())
        : fixtureRoot.absoluteString)
  }

  private func read(_ dest: String) throws -> String {
    try String(contentsOf: userDir.appending(path: dest, directoryHint: .notDirectory), encoding: .utf8)
  }

  // MARK: - tests

  func testFullInstallWritesFilesAndRecord() async throws {
    let dict = try stub(path: "cn_dicts/base.dict.yaml", dest: "cn_dicts/base.dict.yaml", content: "base-dict\n")
    let gram = try stub(repo: "lotem/rime-octagram-data", path: "zh-hans-t-essay-bgw.gram", dest: "zh-hans-t-essay-bgw.gram", content: "GRAM")
    var progressValues: [Double] = []
    let collector = ProgressCollector()

    let result = try await fetcher([dict, gram]).run { collector.add($0) }
    progressValues = collector.values

    XCTAssertEqual(Set(result.installed), ["cn_dicts/base.dict.yaml", "zh-hans-t-essay-bgw.gram"])
    XCTAssertTrue(result.skippedUserFiles.isEmpty)
    XCTAssertEqual(try read("cn_dicts/base.dict.yaml"), "base-dict\n")
    XCTAssertEqual(progressValues.last, 1.0)

    let record = try XCTUnwrap(FamoDictPackRecord.load(userDir: userDir))
    XCTAssertEqual(record.version, 1)
    XCTAssertEqual(record.files["cn_dicts/base.dict.yaml"], dict.sha256)
    // staging 清理干净
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: userDir.appending(component: ".famo-dictpack-staging", directoryHint: .isDirectory).path))
  }

  func testWubiDateTranslatorPatchApplied() async throws {
    // active 行的形状来自上游真实文件（KyleBing a194fb8 第49行）：带尾随注释，不能假设行尾干净。
    let schema = """
      engine:
        translators:
          - lua_translator@date_translator # 自定义系统变量输出
          # - lua_translator@*wubi86_jidian_date_translator
      """
    let entry = try stub(
      repo: "KyleBing/rime-wubi86-jidian", path: "wubi86_jidian_trad.schema.yaml",
      dest: "wubi86_jidian_trad.schema.yaml", content: schema, patch: .wubiDateTranslator)

    let result = try await fetcher([entry]).run { _ in }

    XCTAssertEqual(result.installed, ["wubi86_jidian_trad.schema.yaml"])
    let installed = try read("wubi86_jidian_trad.schema.yaml")
    // 改名生效且行尾注释原样保留（正则只替换匹配段）
    XCTAssertTrue(installed.contains("- lua_translator@*wubi86_jidian_date_translator # 自定义系统变量输出"))
    XCTAssertFalse(installed.contains("- lua_translator@date_translator"))
    // 注释行原样保留（patch 只动 active 行）
    XCTAssertTrue(installed.contains("# - lua_translator@*wubi86_jidian_date_translator"))
    // 记录的是 patch 后哈希，不是上游哈希
    let record = try XCTUnwrap(FamoDictPackRecord.load(userDir: userDir))
    XCTAssertNotEqual(record.files["wubi86_jidian_trad.schema.yaml"], entry.sha256)
    XCTAssertEqual(record.files["wubi86_jidian_trad.schema.yaml"], FamoDictPackFetcher.sha256Hex(Data(installed.utf8)))
  }

  func testHashMismatchAbortsWithoutInstalling() async throws {
    var entry = try stub(path: "rime_ice.dict.yaml", dest: "rime_ice.dict.yaml", content: "tampered upstream\n")
    entry = FamoDictPackFile(
      repo: entry.repo, ref: entry.ref, path: entry.path, dest: entry.dest,
      sha256: String(repeating: "0", count: 64), size: entry.size, patch: nil)

    do {
      _ = try await fetcher([entry]).run { _ in }
      XCTFail("expected hashMismatch")
    } catch let error as FamoDictPackError {
      guard case .hashMismatch(let dest, _, _) = error else { return XCTFail("wrong error: \(error)") }
      XCTAssertEqual(dest, "rime_ice.dict.yaml")
    }
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: userDir.appending(component: "rime_ice.dict.yaml", directoryHint: .notDirectory).path))
    XCTAssertNil(FamoDictPackRecord.load(userDir: userDir))
  }

  func testUserProvidedFileNeverOverwritten() async throws {
    // 2026-07-24 手工恢复的场景：文件已在、无 dict-pack 记录 → 视为用户自备。
    let userContent = "user's own full dict\n"
    let dst = userDir.appending(path: "cn_dicts/base.dict.yaml", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(userContent.utf8).write(to: dst)

    let entry = try stub(path: "cn_dicts/base.dict.yaml", dest: "cn_dicts/base.dict.yaml", content: "upstream dict\n")
    let result = try await fetcher([entry]).run { _ in }

    XCTAssertEqual(result.skippedUserFiles, ["cn_dicts/base.dict.yaml"])
    XCTAssertTrue(result.installed.isEmpty)
    XCTAssertEqual(try read("cn_dicts/base.dict.yaml"), userContent)
    // 记录不认领用户文件
    let record = try XCTUnwrap(FamoDictPackRecord.load(userDir: userDir))
    XCTAssertNil(record.files["cn_dicts/base.dict.yaml"])
  }

  func testOwnedUnmodifiedFileIsUpgraded() async throws {
    // 第一次装 v1，上游内容 A；bump 到 v2 内容 B → 覆盖（记录在案且未被用户改过）。
    let v1 = try stub(path: "cn_dicts/ext.dict.yaml", dest: "cn_dicts/ext.dict.yaml", content: "A\n")
    _ = try await fetcher([v1], version: 1).run { _ in }

    let v2 = try stub(ref: "cafebabe", path: "cn_dicts/ext.dict.yaml", dest: "cn_dicts/ext.dict.yaml", content: "B\n")
    let result = try await fetcher([v2], version: 2).run { _ in }

    XCTAssertEqual(result.installed, ["cn_dicts/ext.dict.yaml"])
    XCTAssertEqual(try read("cn_dicts/ext.dict.yaml"), "B\n")
    XCTAssertEqual(FamoDictPackRecord.load(userDir: userDir)?.version, 2)
  }

  func testAssessAndNeedsFetch() throws {
    let entry = FamoDictPackFile(
      repo: "iDvel/rime-ice", ref: "deadbeef", path: "x", dest: "x",
      sha256: String(repeating: "0", count: 64), size: 1, patch: nil)
    let f = fetcher([entry], version: 3)

    XCTAssertEqual(f.assess(), .notInstalled)
    XCTAssertTrue(f.needsFetch())

    // 关键文件在但无记录 → userProvided，不自动拉取
    let probe = userDir.appending(component: "rime_ice.dict.yaml", directoryHint: .notDirectory)
    try Data("full\n".utf8).write(to: probe)
    XCTAssertEqual(f.assess(), .userProvided)
    XCTAssertFalse(f.needsFetch())
    try FileManager.default.removeItem(at: probe)

    // 旧版本记录 → 需要升级；同版本 → 不需要
    try FamoDictPackRecord(version: 2, files: [:]).save(userDir: userDir)
    XCTAssertEqual(f.assess(), .installed(version: 2))
    XCTAssertTrue(f.needsFetch())
    try FamoDictPackRecord(version: 3, files: [:]).save(userDir: userDir)
    XCTAssertFalse(f.needsFetch())
  }

  func testPatchDidNothingThrows() async throws {
    let entry = try stub(
      repo: "KyleBing/rime-wubi86-jidian", path: "wubi86_jidian_trad.schema.yaml",
      dest: "wubi86_jidian_trad.schema.yaml", content: "no matching line\n", patch: .wubiDateTranslator)
    do {
      _ = try await fetcher([entry]).run { _ in }
      XCTFail("expected patchDidNothing")
    } catch let error as FamoDictPackError {
      guard case .patchDidNothing = error else { return XCTFail("wrong error: \(error)") }
    }
  }

  func testBundledManifestIsWellFormed() {
    // 生成物基本卫生：非空、版本≥1、dest 唯一、sha256 是 64 位十六进制、无越界路径。
    let manifest = FamoDictPackManifest.current
    XCTAssertGreaterThanOrEqual(manifest.version, 1)
    XCTAssertFalse(manifest.files.isEmpty)
    XCTAssertEqual(Set(manifest.files.map(\.dest)).count, manifest.files.count)
    for file in manifest.files {
      XCTAssertEqual(file.sha256.count, 64, file.dest)
      XCTAssertNil(file.sha256.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdef").inverted), file.dest)
      XCTAssertFalse(file.dest.hasPrefix("/"), file.dest)
      XCTAssertFalse(file.dest.contains(".."), file.dest)
      XCTAssertGreaterThan(file.size, 0, file.dest)
    }
    // 关键载荷点名在场：全量拼音词库 + 语法模型 + 五笔
    let dests = Set(manifest.files.map(\.dest))
    XCTAssertTrue(dests.contains("cn_dicts/base.dict.yaml"))
    XCTAssertTrue(dests.contains("rime_ice.dict.yaml"))
    XCTAssertTrue(dests.contains("zh-hans-t-essay-bgw.gram"))
    XCTAssertTrue(dests.contains("wubi86_jidian.schema.yaml"))
  }

  // MARK: - 知情同意提示的纯判定（2026-07-27 改版）

  /// 注入用小清单：只认 wubi86_jidian 一个方案，逻辑与线上清单内容解耦。
  private func promptManifest() -> FamoDictPackManifest {
    FamoDictPackManifest(version: 1, files: [
      .init(repo: "KyleBing/rime-wubi86-jidian", ref: "deadbeef", path: "wubi86_jidian.schema.yaml",
            dest: "wubi86_jidian.schema.yaml", sha256: String(repeating: "a", count: 64), size: 1, patch: nil)
    ])
  }

  func testDictPackManagedSchemaOnlyMatchesManifestSchemas() {
    let manifest = promptManifest()
    XCTAssertTrue(FamoDictPackPrompt.isDictPackManagedSchema("wubi86_jidian", manifest: manifest))
    // 随包分发的方案不归 dict-pack 管——切它失败是真·未编译，不该弹版权说明。
    XCTAssertFalse(FamoDictPackPrompt.isDictPackManagedSchema("rime_ice", manifest: manifest))
    XCTAssertFalse(FamoDictPackPrompt.isDictPackManagedSchema("", manifest: manifest))
    // 只认 <id>.schema.yaml，不能被同前缀的 dict 条目误判。
    XCTAssertFalse(FamoDictPackPrompt.isDictPackManagedSchema("wubi86_jidian.schema", manifest: manifest))
  }

  /// 已装/自备/进行中都不该再弹；未装与失败态才弹（失败后仍要给用户再来一次的入口）。
  func testAbsentDictPackSchemaGatesOnStatus() {
    let manifest = promptManifest()
    let absent: [FamoDictPackStatus] = [.notInstalled, .failed("network")]
    for status in absent {
      XCTAssertTrue(
        FamoDictPackPrompt.isAbsentDictPackSchema(schemaID: "wubi86_jidian", manifest: manifest, status: status),
        "\(status) 应判为缺失")
    }
    let present: [FamoDictPackStatus] = [
      .installed(version: 1), .userProvided, .downloading(progress: 0.5), .deploying
    ]
    for status in present {
      XCTAssertFalse(
        FamoDictPackPrompt.isAbsentDictPackSchema(schemaID: "wubi86_jidian", manifest: manifest, status: status),
        "\(status) 不应再弹")
    }
    // 未装，但方案本就随包分发 → 仍不弹。
    XCTAssertFalse(
      FamoDictPackPrompt.isAbsentDictPackSchema(schemaID: "rime_ice", manifest: manifest, status: .notInstalled))
  }

  /// 线上清单必须真的覆盖会触发提示的那批方案——漏一个，用户切过去只会看到「尚未编译」的
  /// 误导提示，且永远没有下载入口。
  func testCurrentManifestCoversPromptableSchemas() {
    for id in ["wubi86_jidian", "wubi86_jidian_pinyin", "wubi86_jidian_trad",
               "wubi86_jidian_trad_pinyin", "pinyin_simp", "double_pinyin_flypy"] {
      XCTAssertTrue(FamoDictPackPrompt.isDictPackManagedSchema(id), "清单未覆盖 \(id)")
      XCTAssertNotEqual(FamoDictPackPrompt.displayName(for: id), id, "\(id) 缺中文名，弹窗会显示裸 id")
    }
  }

  func testDisplayNameFallsBackToRawID() {
    XCTAssertEqual(FamoDictPackPrompt.displayName(for: "wubi86_jidian"), "极点五笔86")
    XCTAssertEqual(FamoDictPackPrompt.displayName(for: "double_pinyin_mspy"), "双拼")
    XCTAssertEqual(FamoDictPackPrompt.displayName(for: "some_unknown_schema"), "some_unknown_schema")
  }
}

/// run 的 progress 回调是 @Sendable —— 用引用类型收集，避免并发捕获 var。
private final class ProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Double] = []
  var values: [Double] { lock.withLock { storage } }
  func add(_ value: Double) { lock.withLock { storage.append(value) } }
}
