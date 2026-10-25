//
//  OwlDictPackTests.swift
//  OwltypeTests — dict-pack（方案B 首启拉取）全链路：下载/sha256 校验/patch/落盘/所有权保护。
//
//  No network, no librime：baseURLOverride 注入 file:// fixture 根，URLSession 走本地文件。
//  fixture 布局与线上 raw 路径同构：<root>/<repo>/<ref>/<path>。
//

import Foundation
import XCTest
@testable import Owltype

final class OwlDictPackTests: XCTestCase {

  private var fixtureRoot: URL!
  private var userDir: URL!

  override func setUpWithError() throws {
    let base = FileManager.default.temporaryDirectory
      .appending(component: "owl-dictpack-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
    content: String, patch: OwlDictPackPatch? = nil
  ) throws -> OwlDictPackFile {
    let data = Data(content.utf8)
    let url = fixtureRoot.appending(path: "\(repo)/\(ref)/\(path)", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return OwlDictPackFile(
      repo: repo, ref: ref, path: path, dest: dest,
      sha256: OwlDictPackFetcher.sha256Hex(data), size: data.count, patch: patch)
  }

  private func fetcher(_ files: [OwlDictPackFile], version: Int = 1) -> OwlDictPackFetcher {
    OwlDictPackFetcher(
      manifest: OwlDictPackManifest(version: version, files: files),
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

    let record = try XCTUnwrap(OwlDictPackRecord.load(userDir: userDir))
    XCTAssertEqual(record.version, 1)
    XCTAssertEqual(record.files["cn_dicts/base.dict.yaml"], dict.sha256)
    // staging 清理干净
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: userDir.appending(component: ".owl-dictpack-staging", directoryHint: .isDirectory).path))
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
    let record = try XCTUnwrap(OwlDictPackRecord.load(userDir: userDir))
    XCTAssertNotEqual(record.files["wubi86_jidian_trad.schema.yaml"], entry.sha256)
    XCTAssertEqual(record.files["wubi86_jidian_trad.schema.yaml"], OwlDictPackFetcher.sha256Hex(Data(installed.utf8)))
  }

  func testHashMismatchAbortsWithoutInstalling() async throws {
    var entry = try stub(path: "rime_ice.dict.yaml", dest: "rime_ice.dict.yaml", content: "tampered upstream\n")
    entry = OwlDictPackFile(
      repo: entry.repo, ref: entry.ref, path: entry.path, dest: entry.dest,
      sha256: String(repeating: "0", count: 64), size: entry.size, patch: nil)

    do {
      _ = try await fetcher([entry]).run { _ in }
      XCTFail("expected hashMismatch")
    } catch let error as OwlDictPackError {
      guard case .hashMismatch(let dest, _, _) = error else { return XCTFail("wrong error: \(error)") }
      XCTAssertEqual(dest, "rime_ice.dict.yaml")
    }
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: userDir.appending(component: "rime_ice.dict.yaml", directoryHint: .notDirectory).path))
    XCTAssertNil(OwlDictPackRecord.load(userDir: userDir))
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
    let record = try XCTUnwrap(OwlDictPackRecord.load(userDir: userDir))
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
    XCTAssertEqual(OwlDictPackRecord.load(userDir: userDir)?.version, 2)
  }

  func testAssessAndNeedsFetch() throws {
    let entry = OwlDictPackFile(
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
    try OwlDictPackRecord(version: 2, files: [:]).save(userDir: userDir)
    XCTAssertEqual(f.assess(), .installed(version: 2))
    XCTAssertTrue(f.needsFetch())
    try OwlDictPackRecord(version: 3, files: [:]).save(userDir: userDir)
    XCTAssertFalse(f.needsFetch())
  }

  func testPatchDidNothingThrows() async throws {
    let entry = try stub(
      repo: "KyleBing/rime-wubi86-jidian", path: "wubi86_jidian_trad.schema.yaml",
      dest: "wubi86_jidian_trad.schema.yaml", content: "no matching line\n", patch: .wubiDateTranslator)
    do {
      _ = try await fetcher([entry]).run { _ in }
      XCTFail("expected patchDidNothing")
    } catch let error as OwlDictPackError {
      guard case .patchDidNothing = error else { return XCTFail("wrong error: \(error)") }
    }
  }

  // MARK: 断点续传（staging 复用）

  func testResumeReusesValidStagedFile() async throws {
    // staging 里已有 sha256 相符的文件（上次被打断的遗产）→ 不重下。fixture 里
    // 故意不放这个文件：若走网络必失败，成功即证明用的是 staged 副本。
    let content = "big-dict-from-last-time\n"
    let entry = OwlDictPackFile(
      repo: "iDvel/rime-ice", ref: "deadbeef", path: "cn_dicts/base.dict.yaml",
      dest: "cn_dicts/base.dict.yaml",
      sha256: OwlDictPackFetcher.sha256Hex(Data(content.utf8)), size: content.utf8.count, patch: nil)
    let staged = userDir.appending(
      path: ".owl-dictpack-staging/cn_dicts/base.dict.yaml", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: staged)

    let result = try await fetcher([entry]).run { _ in }

    XCTAssertEqual(result.installed, ["cn_dicts/base.dict.yaml"])
    XCTAssertEqual(try read("cn_dicts/base.dict.yaml"), content)
  }

  func testResumeRedownloadsCorruptStagedFile() async throws {
    // staging 里的半截文件（哈希不符）→ 重下，最终装的是上游内容。
    let entry = try stub(path: "cn_dicts/ext.dict.yaml", dest: "cn_dicts/ext.dict.yaml", content: "upstream-good\n")
    let staged = userDir.appending(
      path: ".owl-dictpack-staging/cn_dicts/ext.dict.yaml", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("trunca".utf8).write(to: staged)

    let result = try await fetcher([entry]).run { _ in }

    XCTAssertEqual(result.installed, ["cn_dicts/ext.dict.yaml"])
    XCTAssertEqual(try read("cn_dicts/ext.dict.yaml"), "upstream-good\n")
  }

  func testFailedRunKeepsStagingForResume() async throws {
    // 两个文件：第一个能下、第二个 fixture 缺失 → run 失败，但第一个的 staged 副本保留。
    let good = try stub(path: "cn_dicts/a.dict.yaml", dest: "cn_dicts/a.dict.yaml", content: "A\n")
    let missing = OwlDictPackFile(
      repo: "iDvel/rime-ice", ref: "deadbeef", path: "cn_dicts/nowhere.yaml", dest: "cn_dicts/nowhere.yaml",
      sha256: String(repeating: "1", count: 64), size: 9, patch: nil)

    do {
      _ = try await fetcher([good, missing]).run { _ in }
      XCTFail("expected downloadFailed")
    } catch let error as OwlDictPackError {
      guard case .downloadFailed = error else { return XCTFail("wrong error: \(error)") }
    }
    let staged = userDir.appending(
      path: ".owl-dictpack-staging/cn_dicts/a.dict.yaml", directoryHint: .notDirectory)
    XCTAssertTrue(OwlDictPackFetcher.stagedFileValid(at: staged, sha256: good.sha256))
    // 未落盘、无记录
    XCTAssertNil(OwlDictPackRecord.load(userDir: userDir))
  }

  // MARK: 下载源链（换源接力）

  func testSourceFailoverOnUnreachablePrimary() async throws {
    // 主源指向不存在的目录 → 自动切到第二源成功。
    let entry = try stub(path: "rime_ice.dict.yaml", dest: "rime_ice.dict.yaml", content: "from-mirror\n")
    let deadRoot = fixtureRoot.deletingLastPathComponent()
      .appending(component: "no-such-root", directoryHint: .isDirectory).absoluteString
    let f = OwlDictPackFetcher(
      manifest: OwlDictPackManifest(version: 1, files: [entry]),
      userDir: userDir,
      sourceChainOverride: [
        .rawPrefix(String(deadRoot.dropLast())),
        .rawPrefix(String(fixtureRoot.absoluteString.dropLast())),
      ])

    let result = try await f.run { _ in }

    XCTAssertEqual(result.installed, ["rime_ice.dict.yaml"])
    XCTAssertEqual(try read("rime_ice.dict.yaml"), "from-mirror\n")
  }

  func testSourceFailoverOnHashMismatch() async throws {
    // 主源内容被篡改（哈希不符）→ 不装、换下一源拿到正确内容。
    let entry = try stub(path: "cn_dicts/base.dict.yaml", dest: "cn_dicts/base.dict.yaml", content: "genuine\n")
    // 第二棵 fixture 树：同路径放篡改内容，当主源。
    let tamperedRoot = fixtureRoot.deletingLastPathComponent()
      .appending(component: "tampered", directoryHint: .isDirectory)
    let tamperedFile = tamperedRoot.appending(
      path: "\(entry.repo)/\(entry.ref)/\(entry.path)", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: tamperedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("evil-mirror\n".utf8).write(to: tamperedFile)
    let f = OwlDictPackFetcher(
      manifest: OwlDictPackManifest(version: 1, files: [entry]),
      userDir: userDir,
      sourceChainOverride: [
        .rawPrefix(String(tamperedRoot.absoluteString.dropLast())),
        .rawPrefix(String(fixtureRoot.absoluteString.dropLast())),
      ])

    let result = try await f.run { _ in }

    XCTAssertEqual(result.installed, ["cn_dicts/base.dict.yaml"])
    XCTAssertEqual(try read("cn_dicts/base.dict.yaml"), "genuine\n")
  }

  func testSourceChainShape() {
    // override → 独占；默认链固定以 raw 直连开头/兜底收尾（用户镜像若设会插在链首，
    // 这里只断言与用户 defaults 无关的后缀形状）。
    let entry = OwlDictPackFile(
      repo: "iDvel/rime-ice", ref: "abc123", path: "d/f.yaml", dest: "d/f.yaml",
      sha256: String(repeating: "0", count: 64), size: 1, patch: nil)
    XCTAssertEqual(fetcher([entry]).sources().count, 1)

    let plain = OwlDictPackFetcher(
      manifest: OwlDictPackManifest(version: 1, files: [entry]), userDir: userDir)
    let chain = plain.sources()
    XCTAssertEqual(Array(chain.suffix(3)), [
      .rawPrefix("https://raw.githubusercontent.com"),
      .rawPrefix("https://gh-proxy.com/https://raw.githubusercontent.com"),
      .jsDelivr,
    ])
    // jsDelivr 的 gh CDN URL 形状：/gh/<repo>@<ref>/<path>
    XCTAssertEqual(
      OwlDictPackSource.jsDelivr.url(for: entry)?.absoluteString,
      "https://cdn.jsdelivr.net/gh/iDvel/rime-ice@abc123/d/f.yaml")
  }

  // MARK: 流式进度

  func testStreamingProgressIsByteLevel() async throws {
    // 单文件 600 KB（> 256 KB chunk）→ 下载中就有中间进度回调，而不是文件完成才跳一格。
    let big = String(repeating: "x", count: 600 * 1024)
    let entry = try stub(path: "cn_dicts/big.dict.yaml", dest: "cn_dicts/big.dict.yaml", content: big)
    let collector = ProgressCollector()

    _ = try await fetcher([entry]).run { collector.add($0) }

    let values = collector.values
    XCTAssertEqual(values.last, 1.0)
    XCTAssertTrue(values.contains { $0 > 0 && $0 < 1 }, "no intermediate byte-level progress: \(values)")
  }

  func testBundledManifestIsWellFormed() {
    // 生成物基本卫生：非空、版本≥1、dest 唯一、sha256 是 64 位十六进制、无越界路径。
    let manifest = OwlDictPackManifest.current
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
  private func promptManifest() -> OwlDictPackManifest {
    OwlDictPackManifest(version: 1, files: [
      .init(repo: "KyleBing/rime-wubi86-jidian", ref: "deadbeef", path: "wubi86_jidian.schema.yaml",
            dest: "wubi86_jidian.schema.yaml", sha256: String(repeating: "a", count: 64), size: 1, patch: nil)
    ])
  }

  func testDictPackManagedSchemaOnlyMatchesManifestSchemas() {
    let manifest = promptManifest()
    XCTAssertTrue(OwlDictPackPrompt.isDictPackManagedSchema("wubi86_jidian", manifest: manifest))
    // 随包分发的方案不归 dict-pack 管——切它失败是真·未编译，不该弹版权说明。
    XCTAssertFalse(OwlDictPackPrompt.isDictPackManagedSchema("rime_ice", manifest: manifest))
    XCTAssertFalse(OwlDictPackPrompt.isDictPackManagedSchema("", manifest: manifest))
    // 只认 <id>.schema.yaml，不能被同前缀的 dict 条目误判。
    XCTAssertFalse(OwlDictPackPrompt.isDictPackManagedSchema("wubi86_jidian.schema", manifest: manifest))
  }

  /// 已装/自备/进行中都不该再弹；未装与失败态才弹（失败后仍要给用户再来一次的入口）。
  func testAbsentDictPackSchemaGatesOnStatus() {
    let manifest = promptManifest()
    let absent: [OwlDictPackStatus] = [.notInstalled, .failed("network")]
    for status in absent {
      XCTAssertTrue(
        OwlDictPackPrompt.isAbsentDictPackSchema(schemaID: "wubi86_jidian", manifest: manifest, status: status),
        "\(status) 应判为缺失")
    }
    let present: [OwlDictPackStatus] = [
      .installed(version: 1), .userProvided, .downloading(progress: 0.5), .deploying,
      .prepared(version: 2), .activating, .rollingBack,
    ]
    for status in present {
      XCTAssertFalse(
        OwlDictPackPrompt.isAbsentDictPackSchema(schemaID: "wubi86_jidian", manifest: manifest, status: status),
        "\(status) 不应再弹")
    }
    // 未装，但方案本就随包分发 → 仍不弹。
    XCTAssertFalse(
      OwlDictPackPrompt.isAbsentDictPackSchema(schemaID: "rime_ice", manifest: manifest, status: .notInstalled))
  }

  /// 线上清单必须真的覆盖会触发提示的那批方案——漏一个，用户切过去只会看到「尚未编译」的
  /// 误导提示，且永远没有下载入口。
  func testCurrentManifestCoversPromptableSchemas() {
    for id in ["wubi86_jidian", "wubi86_jidian_pinyin", "wubi86_jidian_trad",
               "wubi86_jidian_trad_pinyin", "pinyin_simp", "double_pinyin_flypy"] {
      XCTAssertTrue(OwlDictPackPrompt.isDictPackManagedSchema(id), "清单未覆盖 \(id)")
      XCTAssertNotEqual(OwlDictPackPrompt.displayName(for: id), id, "\(id) 缺中文名，弹窗会显示裸 id")
    }
  }

  func testLaunchActionDefersToOnboardingBeforeFirstRunCompletes() {
    // 引导未走完 ⟺ 本次启动引导会弹，它的词库步骤讲同一件事、写同一个 promptShown ——
    // 此时武装调度器就会在引导窗上再弹一次模态问同一个问题。
    XCTAssertEqual(
      OwlDictPackPrompt.launchAction(
        needsFetch: true, autoFetch: false, promptShown: false, onboardingDone: false),
      .deferToOnboarding)
    // 引导走完过（含老用户升级上来）→ 常规首启告知。
    XCTAssertEqual(
      OwlDictPackPrompt.launchAction(
        needsFetch: true, autoFetch: false, promptShown: false, onboardingDone: true),
      .armPrompt)
  }

  func testLaunchActionHonoursInstalledAndConsentFlags() {
    // 已装 / 用户自备（needsFetch=false）：任何组合都不动。
    for done in [true, false] {
      for shown in [true, false] {
        XCTAssertEqual(
          OwlDictPackPrompt.launchAction(
            needsFetch: false, autoFetch: false, promptShown: shown, onboardingDone: done),
          .doNothing)
      }
    }
    // 问过了就不再问 —— 引导是否走完都一样（引导里作出选择同样置真 promptShown）。
    XCTAssertEqual(
      OwlDictPackPrompt.launchAction(
        needsFetch: true, autoFetch: false, promptShown: true, onboardingDone: false),
      .doNothing)
    // autoFetch 是用户显式授权，优先于一切提示（含引导让路）。
    XCTAssertEqual(
      OwlDictPackPrompt.launchAction(
        needsFetch: true, autoFetch: true, promptShown: false, onboardingDone: false),
      .fetchSilently)
  }

  func testDisplayNameFallsBackToRawID() {
    XCTAssertEqual(OwlDictPackPrompt.displayName(for: "wubi86_jidian"), "极点五笔86")
    XCTAssertEqual(OwlDictPackPrompt.displayName(for: "double_pinyin_mspy"), "双拼")
    XCTAssertEqual(OwlDictPackPrompt.displayName(for: "some_unknown_schema"), "some_unknown_schema")
  }
}

/// run 的 progress 回调是 @Sendable —— 用引用类型收集，避免并发捕获 var。
private final class ProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Double] = []
  var values: [Double] { lock.withLock { storage } }
  func add(_ value: Double) { lock.withLock { storage.append(value) } }
}

@MainActor
final class OwlDictPackCenterTests: XCTestCase {
  func testRustPrepareActivateAndRollbackNeverDeploy() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(component: "owl-dictpack-center-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let previous = fixtureRecord(version: 6, seed: "b")
    let current = fixtureRecord(version: 7, seed: "a")
    let activeState = OwlRustResourceActiveState(
      schemaVersion: 1,
      inputKind: .pinyinWubi,
      current: current,
      previous: previous,
      activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let rolledBackState = OwlRustResourceActiveState(
      schemaVersion: 1,
      inputKind: .pinyinWubi,
      current: previous,
      previous: nil,
      activatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let prepared = OwlRustDictPackPreparedResources(
      resource: OwlRustResourcePrepared(record: current, previousGenerationId: previous.generationId),
      stats: OwlRustResourceBuildStats(
        pinyinEntries: 21,
        wubiEntries: 22,
        englishEntries: 23,
        rejectedPinyinEntries: 1,
        rejectedWubiEntries: 2,
        rejectedEnglishEntries: 3
      )
    )

    let calls = OwlDictPackCenterBackendCalls(
      prepared: prepared,
      activeState: activeState,
      rolledBackState: rolledBackState
    )
    let deployRecorder = OwlDictPackDeployRecorder()
    let refreshRecorder = OwlDictPackLiveSessionRefreshRecorder(deferred: true)
    let backend = OwlDictPackCenterRustBackend(
      environment: OwlRustResourceEnvironment.production(userRoot: root),
      prepare: { _, progress in
        progress?(0.5)
        return await calls.prepare()
      },
      activate: { _, _ in
        await calls.activate()
      },
      rollback: { _, _ in
        await calls.rollback()
      }
    )
    let center = OwlDictPackCenter(
      usesRustResources: true,
      rustBackend: backend,
      deploy: { deployRecorder.deploy() },
      liveSessionRefresh: refreshRecorder.schedule
    )

    center.start()
    try await waitUntil { center.status == .prepared(version: 7) }

    XCTAssertEqual(center.status, .prepared(version: 7))
    XCTAssertEqual(center.preparedCandidate, OwlDictPackCandidate(prepared: prepared))
    XCTAssertEqual(center.preparedCandidate?.licenseIdentifiers, ["MIT", "Zlib"])
    XCTAssertEqual(center.preparedCandidate?.rejectedEntries, 6)
    let prepareCalls = await calls.prepareCalls
    let activateCallsBeforeConfirmation = await calls.activateCalls
    XCTAssertEqual(prepareCalls, 1)
    XCTAssertEqual(activateCallsBeforeConfirmation, 0, "preparing a candidate must not activate it")
    XCTAssertEqual(deployRecorder.calls, 0)

    center.activatePrepared()
    try await waitUntil { center.status == .installed(version: 7) }

    let activateCalls = await calls.activateCalls
    XCTAssertEqual(activateCalls, 1)
    XCTAssertEqual(center.rollbackTargetVersion, 6)
    XCTAssertTrue(center.isAwaitingLiveSessionRefresh)
    XCTAssertEqual(refreshRecorder.calls, 1)
    XCTAssertEqual(deployRecorder.calls, 0, "Rust activation must not invoke Rime deploy")

    center.rollback()
    try await waitUntil { center.status == .installed(version: 6) }

    let rollbackCalls = await calls.rollbackCalls
    XCTAssertEqual(rollbackCalls, 1)
    XCTAssertNil(center.rollbackTargetVersion)
    XCTAssertTrue(center.isAwaitingLiveSessionRefresh)
    XCTAssertEqual(refreshRecorder.calls, 2)
    XCTAssertEqual(deployRecorder.calls, 0, "Rust rollback must not invoke Rime deploy")

    refreshRecorder.finish()
    XCTAssertFalse(center.isAwaitingLiveSessionRefresh)
  }

  func testRustActivationWaitsForPartialSelectionToFinishBeforeSwitchingSessions() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(component: "owl-dictpack-idle-refresh-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let previous = fixtureRecord(version: 6, seed: "b")
    let current = fixtureRecord(version: 7, seed: "a")
    let activeState = OwlRustResourceActiveState(
      schemaVersion: 1,
      inputKind: .pinyinWubi,
      current: current,
      previous: previous,
      activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let prepared = OwlRustDictPackPreparedResources(
      resource: OwlRustResourcePrepared(record: current, previousGenerationId: previous.generationId),
      stats: OwlRustResourceBuildStats(
        pinyinEntries: 21,
        wubiEntries: 22,
        englishEntries: 23,
        rejectedPinyinEntries: 1,
        rejectedWubiEntries: 2,
        rejectedEnglishEntries: 3
      )
    )
    let backend = OwlDictPackCenterRustBackend(
      environment: OwlRustResourceEnvironment.production(userRoot: root),
      prepare: { _, _ in prepared },
      activate: { _, _ in
        OwlRustResourceInstallResult(disposition: .installed, state: activeState)
      },
      rollback: { _, _ in
        XCTFail("rollback is not part of this activation path")
        return activeState
      }
    )
    let deployRecorder = OwlDictPackDeployRecorder()

    let delegate = NSApp.owlAppDelegate
    let previousEngine = delegate.engine
    let previousActive = delegate.activeInputController
    delegate.engine = FakeRimeEngine()
    let active = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    let background = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    active.destroySession()
    background.destroySession()
    defer {
      delegate.liveControllers.remove(active)
      delegate.liveControllers.remove(background)
      delegate.activeInputController = previousActive
      delegate.engine = previousEngine
      _ = delegate.applyPendingLiveSessionRefreshIfIdle()
    }

    let partialSelection = RimeComposition(
      preedit: "西te'le",
      selStart: 3,
      selEnd: 9,
      cursorPos: 9,
      commitTextPreview: "西特乐",
      candidates: [RimeCandidate(text: "西特乐", comment: "xi'te'le")],
      labels: ["1"],
      pageNo: 0,
      pageSize: 1,
      isLastPage: true,
      highlightedIndex: 0,
      numCandidates: 1
    )
    let activeOld = FakeRimeSession(
      sessionID: 10,
      composition: partialSelection,
      input: "te'le"
    )
    let backgroundOld = FakeRimeSession(
      sessionID: 20,
      composition: partialSelection,
      input: "te'le"
    )
    let activeFresh = FakeRimeSession(sessionID: 11)
    let engine = FakeRimeEngine(vendedSession: activeFresh)
    delegate.engine = engine

    active.rime = activeOld
    active.schemaId = "rime_ice"
    active.preedit = "西te'le"
    background.rime = backgroundOld
    background.schemaId = "rime_ice"
    delegate.registerLiveController(active)
    delegate.registerLiveController(background)
    delegate.activeInputController = active

    let center = OwlDictPackCenter(
      usesRustResources: true,
      rustBackend: backend,
      deploy: { deployRecorder.deploy() }
    )
    center.start()
    try await waitUntil { center.status == .prepared(version: 7) }
    center.activatePrepared()
    try await waitUntil { center.status == .installed(version: 7) }

    XCTAssertTrue(center.isAwaitingLiveSessionRefresh)
    XCTAssertFalse(activeOld.destroyed, "an in-flight partial selection must not be torn down")
    XCTAssertFalse(backgroundOld.destroyed, "all live sessions wait for the active composition")
    XCTAssertEqual(engine.createdSessionCount, 0)
    XCTAssertEqual(deployRecorder.calls, 0)

    activeOld.scriptedInput = ""
    activeOld.scriptedComposition = nil
    active.preedit = ""
    active.rimeUpdate()

    XCTAssertFalse(activeOld.destroyed, "an unfinished background session must also block the handoff")
    XCTAssertFalse(backgroundOld.destroyed)
    XCTAssertEqual(engine.createdSessionCount, 0)
    XCTAssertTrue(center.isAwaitingLiveSessionRefresh)

    backgroundOld.scriptedInput = ""
    backgroundOld.scriptedComposition = nil
    // A stale UI preedit is not source of truth: the underlying session is idle.
    background.preedit = "stale"
    active.rimeUpdate()

    XCTAssertTrue(activeOld.destroyed)
    XCTAssertTrue(backgroundOld.destroyed)
    XCTAssertEqual(engine.createdSessionCount, 1, "only the active controller is eagerly recreated")
    XCTAssertTrue(activeFresh.processedKeys.isEmpty, "the idle handoff must not replay stale raw input")
    XCTAssertFalse(center.isAwaitingLiveSessionRefresh)
    XCTAssertEqual(deployRecorder.calls, 0)
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out waiting for dict-pack center state")
  }

  private func fixtureRecord(version: Int, seed: Character) -> OwlRustResourceRecord {
    let digest = "sha256:" + String(repeating: String(seed), count: 64)
    let licenseFiles = ["files/msime-pinyin.db"]
    let manifest = OwlRustResourceManifest(
      schemaVersion: 1,
      packageId: "owltype-dictpack",
      inputKind: .pinyinWubi,
      version: version,
      digest: digest,
      license: [
        OwlRustResourceLicense(identifier: "Zlib", attribution: "Fixture Z", files: licenseFiles),
        OwlRustResourceLicense(identifier: "MIT", attribution: "Fixture M", files: licenseFiles),
      ],
      engineCompatibility: OwlRustResourceEngineCompatibility(
        minimumContractVersion: 1,
        maximumContractVersion: 1,
        requiredCapabilities: []
      ),
      files: []
    )
    return OwlRustResourceRecord(
      generationId: "sha256-" + String(repeating: String(seed), count: 64),
      digest: digest,
      manifest: manifest
    )
  }
}

private actor OwlDictPackCenterBackendCalls {
  private let prepared: OwlRustDictPackPreparedResources
  private let activeState: OwlRustResourceActiveState
  private let rolledBackState: OwlRustResourceActiveState
  private(set) var prepareCalls = 0
  private(set) var activateCalls = 0
  private(set) var rollbackCalls = 0

  init(
    prepared: OwlRustDictPackPreparedResources,
    activeState: OwlRustResourceActiveState,
    rolledBackState: OwlRustResourceActiveState
  ) {
    self.prepared = prepared
    self.activeState = activeState
    self.rolledBackState = rolledBackState
  }

  func prepare() -> OwlRustDictPackPreparedResources {
    prepareCalls += 1
    return prepared
  }

  func activate() -> OwlRustResourceInstallResult {
    activateCalls += 1
    return OwlRustResourceInstallResult(disposition: .installed, state: activeState)
  }

  func rollback() -> OwlRustResourceActiveState {
    rollbackCalls += 1
    return rolledBackState
  }
}

@MainActor
private final class OwlDictPackDeployRecorder {
  private(set) var calls = 0

  func deploy() -> Bool {
    calls += 1
    return true
  }
}

@MainActor
private final class OwlDictPackLiveSessionRefreshRecorder {
  private(set) var calls = 0
  private let deferred: Bool
  private var completions: [@MainActor () -> Void] = []

  init(deferred: Bool) {
    self.deferred = deferred
  }

  func schedule(completion: @escaping @MainActor () -> Void) -> Bool {
    calls += 1
    guard deferred else {
      completion()
      return false
    }
    completions.append(completion)
    return true
  }

  func finish() {
    let pending = completions
    completions.removeAll()
    for completion in pending {
      completion()
    }
  }
}

final class OwlPinyinMixedInputTests: XCTestCase {
  private var root: URL!
  private var user: URL { root.appendingPathComponent("user") }
  private var shared: URL { root.appendingPathComponent("shared") }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-mixed-\(UUID().uuidString)")
    try write("rime_ice.schema.yaml", at: shared, text: "schema:\n  schema_id: rime_ice\nengine:\n  translators:\n    - script_translator\n")
    try write("rime_ice.custom.yaml", at: user, text: "# User comment\npatch: {}\n")
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func write(_ path: String, at directory: URL, text: String = "fixture\n") throws {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func populate() throws {
    for file in OwlPinyinMixedInput.englishFiles + ["en_dicts/cn_en.txt"] { try write(file, at: user) }
  }

  private func config() throws -> String {
    try String(contentsOf: user.appendingPathComponent("rime_ice.custom.yaml"), encoding: .utf8)
  }

  func testDownloadThenUpgradeRestoresChannelsWithoutDuplicateOrLostUserPatch() throws {
    try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
    XCTAssertEqual(try config(), "# User comment\npatch: {}\n")
    try populate()
    // Templates already own the /+ key. Mixed input must not add a second such key.
    try write("rime_ice.custom.yaml", at: user, text: "patch:\n  \"engine/translators/+\":\n    - table_translator@owl_templates\n  \"menu/page_size\": 7\n")
    try write("build/rime_ice.schema.yaml", at: user, text: "old compiled schema")
    try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
    let compiled = user.appendingPathComponent("build/rime_ice.schema.yaml")
    XCTAssertFalse(FileManager.default.fileExists(atPath: compiled.path), "Rapid dictionary installation must invalidate the old translator list")
    let first = try config()
    try write("build/rime_ice.schema.yaml", at: user, text: "updated compiled schema")
    XCTAssertTrue(first.contains("table_translator@melt_eng"))
    XCTAssertTrue(first.contains("table_translator@cn_en"))
    XCTAssertTrue(first.contains("table_translator@owl_templates"))
    XCTAssertTrue(first.contains("\"menu/page_size\": 7"))
    XCTAssertEqual(first.components(separatedBy: "engine/translators/+").count, 2)
    try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
    XCTAssertEqual(try config(), first, "An upgrader's existing data must remain idempotent")
    XCTAssertTrue(FileManager.default.fileExists(atPath: compiled.path))
  }

  func testEmptySeedMapIsExpandedAndMissingResourcesRemoveOnlyOwnedChannels() throws {
    try populate()
    try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
    XCTAssertFalse(try config().contains("patch: {}"))
    XCTAssertTrue(try config().contains("# User comment"))
    try FileManager.default.removeItem(at: user.appendingPathComponent("en_dicts/en.dict.yaml"))
    try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
    XCTAssertFalse(try config().contains("table_translator@melt_eng"))
    XCTAssertTrue(try config().contains("table_translator@cn_en"))
    try FileManager.default.removeItem(at: user.appendingPathComponent("en_dicts/cn_en.txt"))
    try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
    XCTAssertFalse(try config().contains("table_translator@cn_en"))
    XCTAssertTrue(try config().contains("# User comment"))
  }

  func testUserOwnedSchemaOrTranslatorListIsPreserved() throws {
    try populate()
    for key in ["engine/translators", "engine/translators/=", "engine/translators/@before 0"] {
      let custom = "patch:\n  \"\(key)\": [script_translator]\n"
      try write("rime_ice.custom.yaml", at: user, text: custom)
      try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
      XCTAssertEqual(try config(), custom)
    }
    try write("rime_ice.custom.yaml", at: user, text: "patch: {}\n")
    try write("rime_ice.schema.yaml", at: user)
    try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
    XCTAssertEqual(try config(), "patch: {}\n")
  }

  func testFullSchemaOrUserAppendDoesNotDuplicateExistingTranslators() throws {
    try populate()
    let custom = "patch:\n  \"engine/translators/+\": [table_translator@melt_eng, table_translator@cn_en]\n"
    try write("rime_ice.custom.yaml", at: user, text: custom)
    try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
    XCTAssertEqual(try config(), custom)
    try write("rime_ice.custom.yaml", at: user, text: "patch: {}\n")
    try write("rime_ice.schema.yaml", at: shared,
              text: "engine:\n  translators:\n    - table_translator@melt_eng\n    - table_translator@cn_en\n")
    try OwlPinyinMixedInput.apply(userDir: user, sharedDir: shared)
    XCTAssertEqual(try config(), "patch: {}\n")
  }
}
