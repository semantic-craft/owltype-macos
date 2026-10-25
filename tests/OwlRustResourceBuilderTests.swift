//
//  OwlRustResourceBuilderTests.swift
//  OwltypeTests
//
//  End-to-end synthetic coverage for dict-pack YAML -> SQLite package -> store.
//

import Foundation
import SQLite3
import XCTest
@testable import Owltype

final class OwlRustResourceBuilderTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    let raw = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-rust-resource-builder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    root = try Self.canonicalDirectory(raw)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testBuildsPinyinWubiAndEnglishPayloadFromImportedDictionaries() throws {
    let input = try makeInputRoot()
    let package = try OwlRustResourcePackageBuilder(
      dictionaryRoot: input,
      packageVersion: 7
    ).build(at: root.appendingPathComponent("package", isDirectory: true))

    XCTAssertEqual(package.manifest.packageId, OwlRustResourcePackageBuilder.packageId)
    XCTAssertEqual(package.manifest.inputKind, .pinyinWubi)
    XCTAssertEqual(package.manifest.version, 7)
    XCTAssertEqual(package.stats.pinyinEntries, 4)
    XCTAssertEqual(package.stats.wubiEntries, 4)
    XCTAssertEqual(package.stats.englishEntries, 2)
    try package.manifest.validateDigest()
    try OwlRustResourceVerifier.verifyEngineCompatibility(
      manifest: package.manifest, engine: .owlRustResourceV1
    )

    let pinyin = package.root.appendingPathComponent("files/msime-pinyin.db")
    XCTAssertEqual(try rows(
      pinyin,
      "SELECT value, weight FROM tbl_2_n WHERE key='ni''hao' ORDER BY weight DESC"
    ), [["合成高", "200"], ["合成外", "75"], ["合成低", "50"]])
    XCTAssertEqual(try rows(
      pinyin,
      "SELECT value, weight FROM tbl_2_n WHERE key='ni''hao' AND value='合成外'"
    ), [["合成外", "75"]])
    XCTAssertEqual(try rows(
      pinyin,
      "SELECT value, weight FROM wubi86 WHERE key='aaaa' ORDER BY weight DESC, value"
    ), [["工", "20"], ["或", "10"]])

    let english = package.root.appendingPathComponent("files/msime-english.db")
    XCTAssertEqual(try rows(
      english,
      "SELECT word, display, weight FROM english_words ORDER BY word"
    ), [["hello", "Hello", "10"], ["world", "world", "20"]])
  }

  func testPackageInstallsIntoGenerationAndLeaseWithoutTouchingUserRoot() async throws {
    let input = try makeInputRoot()
    let package = try OwlRustResourcePackageBuilder(
      dictionaryRoot: input,
      packageVersion: 1
    ).build(at: root.appendingPathComponent("package", isDirectory: true))
    let environment = try makeStoreEnvironment()
    let before = try userBytes(environment.userRoot)
    let store = try OwlRustResourceStore(
      configuration: environment.configuration,
      engine: .owlRustResourceV1
    )

    let installed = try await store.install(
      OwlRustResourceDirectorySource(root: package.root)
    )
    XCTAssertEqual(installed.disposition, .installed)
    let lease = try await store.acquireLease(inputKind: .pinyinWubi)
    XCTAssertEqual(lease.generationId, installed.state.current.generationId)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: lease.runtimeURL.appendingPathComponent("files/msime-pinyin.db").path
    ))
    XCTAssertEqual(try userBytes(environment.userRoot), before)
    _ = try await store.recover(inputKind: .pinyinWubi)
    XCTAssertTrue(FileManager.default.fileExists(atPath: lease.runtimeURL.path))
    try await store.releaseLease(lease)
    XCTAssertFalse(FileManager.default.fileExists(atPath: lease.runtimeURL.path))
  }

  func testCurrentManifestDownloadsBuildsAndInstallsEndToEnd() async throws {
    guard ProcessInfo.processInfo.environment["OWL_RUN_LIVE_DICT_PACK"] == "1" else {
      throw XCTSkip("set TEST_RUNNER_OWL_RUN_LIVE_DICT_PACK=1 to run the pinned network download")
    }

    let dictionaryRoot = root.appendingPathComponent("dictionary", isDirectory: true)
    try FileManager.default.createDirectory(
      at: dictionaryRoot, withIntermediateDirectories: true
    )
    let packageRoot = root.appendingPathComponent("candidate-package", isDirectory: true)
    let environment = try makeStoreEnvironment()
    let before = try userBytes(environment.userRoot)
    let store = try OwlRustResourceStore(
      configuration: environment.configuration,
      engine: .owlRustResourceV1
    )
    let installer = OwlRustDictPackResourceInstaller(
      store: store,
      dictionaryRoot: dictionaryRoot,
      packageRoot: packageRoot,
      sourceChainOverride: [
        .rawPrefix("https://raw.githubusercontent.com")
      ]
    )

    let installed = try await installer.downloadAndInstall()

    XCTAssertEqual(installed.disposition, .installed)
    let record = try XCTUnwrap(OwlDictPackRecord.load(userDir: dictionaryRoot))
    XCTAssertEqual(record.version, OwlDictPackManifest.current.version)
    XCTAssertEqual(Set(record.files.keys), Set(OwlDictPackManifest.current.files.map(\.dest)))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: dictionaryRoot.appendingPathComponent(".owl-dictpack-staging").path
    ))

    let manifestData = try Data(
      contentsOf: packageRoot.appendingPathComponent("manifest.json")
    )
    let manifest = try JSONDecoder().decode(
      OwlRustResourceManifest.self, from: manifestData
    )
    let stats = try JSONDecoder().decode(
      OwlRustResourceBuildStats.self,
      from: Data(contentsOf: packageRoot.appendingPathComponent("build-stats.json"))
    )
    XCTAssertEqual(installed.state.current.digest, manifest.digest)
    XCTAssertEqual(manifest.packageId, OwlRustResourcePackageBuilder.packageId)
    XCTAssertEqual(manifest.inputKind, .pinyinWubi)
    XCTAssertEqual(stats.pinyinEntries, 891_493)
    XCTAssertEqual(stats.wubiEntries, 91_481)
    XCTAssertEqual(stats.englishEntries, 23_856)

    let repeated = try await installer.downloadAndInstall()
    XCTAssertEqual(repeated.disposition, .alreadyActive)
    XCTAssertEqual(repeated.state, installed.state)

    let lease = try await store.acquireLease(inputKind: .pinyinWubi)
    XCTAssertEqual(lease.generationId, installed.state.current.generationId)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: lease.runtimeURL.appendingPathComponent("files/msime-pinyin.db").path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: lease.runtimeURL.appendingPathComponent("files/msime-english.db").path
    ))
    _ = try await store.recover(inputKind: .pinyinWubi)
    XCTAssertTrue(FileManager.default.fileExists(atPath: lease.runtimeURL.path))
    XCTAssertEqual(try userBytes(environment.userRoot), before)

    try await store.releaseLease(lease)
    XCTAssertFalse(FileManager.default.fileExists(atPath: lease.runtimeURL.path))
    XCTAssertEqual(try userBytes(environment.userRoot), before)
  }

  func testDictPackInstallerRepeatsIdempotently() async throws {
    let fixture = try makeDictPackFixture(name: "repeat", version: 1)
    let environment = try makeStoreEnvironment()
    let store = try OwlRustResourceStore(
      configuration: environment.configuration,
      engine: .owlRustResourceV1
    )
    let installer = OwlRustDictPackResourceInstaller(
      store: store,
      dictionaryRoot: fixture.dictionaryRoot,
      packageRoot: fixture.packageRoot,
      manifest: fixture.manifest,
      sourceChainOverride: fixture.sourceChain
    )

    let first = try await installer.downloadAndInstall()
    XCTAssertEqual(first.disposition, .installed)
    let candidate = try Data(
      contentsOf: fixture.packageRoot.appendingPathComponent("manifest.json")
    )

    let second = try await installer.downloadAndInstall()

    XCTAssertEqual(second.disposition, .alreadyActive)
    XCTAssertEqual(second.state, first.state)
    XCTAssertEqual(
      try Data(contentsOf: fixture.packageRoot.appendingPathComponent("manifest.json")),
      candidate
    )
  }

  func testDictPackInstallerRejectsCorruptVerifiedInput() async throws {
    let fixture = try makeDictPackFixture(name: "corrupt", version: 1)
    let environment = try makeStoreEnvironment()
    let store = try OwlRustResourceStore(
      configuration: environment.configuration,
      engine: .owlRustResourceV1
    )
    let installer = OwlRustDictPackResourceInstaller(
      store: store,
      dictionaryRoot: fixture.dictionaryRoot,
      packageRoot: fixture.packageRoot,
      manifest: fixture.manifest,
      sourceChainOverride: fixture.sourceChain
    )
    _ = try await installer.downloadAndInstall()
    let input = fixture.dictionaryRoot.appendingPathComponent("en_dicts/en.dict.yaml")
    try Data("tampered\n".utf8).write(to: input)

    do {
      _ = try await installer.downloadAndInstall()
      XCTFail("expected unverifiedDictionaryInput")
    } catch let error as OwlRustDictPackResourceError {
      XCTAssertEqual(error, .unverifiedDictionaryInput("en_dicts/en.dict.yaml"))
    }
  }

  func testDictPackInstallerRejectsMissingRequiredInput() async throws {
    let fixture = try makeDictPackFixture(name: "missing", version: 1)
    let environment = try makeStoreEnvironment()
    let store = try OwlRustResourceStore(
      configuration: environment.configuration,
      engine: .owlRustResourceV1
    )
    let installer = OwlRustDictPackResourceInstaller(
      store: store,
      dictionaryRoot: fixture.dictionaryRoot,
      packageRoot: fixture.packageRoot,
      manifest: fixture.manifest,
      sourceChainOverride: fixture.sourceChain
    )
    _ = try await installer.downloadAndInstall()
    try FileManager.default.removeItem(
      at: fixture.dictionaryRoot.appendingPathComponent("rime-ice.LICENSE")
    )

    do {
      _ = try await installer.downloadAndInstall()
      XCTFail("expected unverifiedDictionaryInput")
    } catch let error as OwlRustDictPackResourceError {
      XCTAssertEqual(error, .unverifiedDictionaryInput("rime-ice.LICENSE"))
    }
  }

  func testDictPackInstallerRejectsUserModifiedFiles() async throws {
    let firstFixture = try makeDictPackFixture(name: "user-file-first", version: 1)
    let secondFixture = try makeDictPackFixture(name: "user-file-second", version: 2)
    let environment = try makeStoreEnvironment()
    let store = try OwlRustResourceStore(
      configuration: environment.configuration,
      engine: .owlRustResourceV1
    )
    let firstInstaller = OwlRustDictPackResourceInstaller(
      store: store,
      dictionaryRoot: firstFixture.dictionaryRoot,
      packageRoot: firstFixture.packageRoot,
      manifest: firstFixture.manifest,
      sourceChainOverride: firstFixture.sourceChain
    )
    _ = try await firstInstaller.downloadAndInstall()
    let userFile = firstFixture.dictionaryRoot
      .appendingPathComponent("cn_dicts/8105.dict.yaml")
    let userContent = "用户自备\tni hao\t1\n"
    try Data(userContent.utf8).write(to: userFile)
    let secondInstaller = OwlRustDictPackResourceInstaller(
      store: store,
      dictionaryRoot: firstFixture.dictionaryRoot,
      packageRoot: firstFixture.packageRoot,
      manifest: secondFixture.manifest,
      sourceChainOverride: secondFixture.sourceChain
    )

    do {
      _ = try await secondInstaller.downloadAndInstall()
      XCTFail("expected skippedDictionaryFiles")
    } catch let error as OwlRustDictPackResourceError {
      XCTAssertEqual(error, .skippedDictionaryFiles(["cn_dicts/8105.dict.yaml"]))
    }
    XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), userContent)
  }

  func testDictPackInstallerPreservesForeignCandidateRoot() async throws {
    let fixture = try makeDictPackFixture(name: "foreign-candidate", version: 1)
    try FileManager.default.createDirectory(
      at: fixture.packageRoot, withIntermediateDirectories: true
    )
    let sentinel = fixture.packageRoot.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)
    let environment = try makeStoreEnvironment()
    let store = try OwlRustResourceStore(
      configuration: environment.configuration,
      engine: .owlRustResourceV1
    )
    let installer = OwlRustDictPackResourceInstaller(
      store: store,
      dictionaryRoot: fixture.dictionaryRoot,
      packageRoot: fixture.packageRoot,
      manifest: fixture.manifest,
      sourceChainOverride: fixture.sourceChain
    )

    do {
      _ = try await installer.downloadAndInstall()
      XCTFail("expected candidateRootOccupied")
    } catch let error as OwlRustDictPackResourceError {
      XCTAssertEqual(error, .candidateRootOccupied(fixture.packageRoot))
    }
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
  }

  func testUnsafeImportPathIsRejectedBeforeBuildingDatabase() throws {
    let input = try makeInputRoot(importPath: "../outside")
    XCTAssertThrowsError(
      try OwlRustResourcePackageBuilder(
        dictionaryRoot: input,
        packageVersion: 1
      ).build(at: root.appendingPathComponent("package", isDirectory: true))
    ) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .unsafePath = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testOccupiedOutputDirectoryIsRejectedWithoutChangingIt() throws {
    let input = try makeInputRoot()
    let output = root.appendingPathComponent("occupied", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let sentinel = output.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)

    XCTAssertThrowsError(
      try OwlRustResourcePackageBuilder(
        dictionaryRoot: input,
        packageVersion: 1
      ).build(at: output)
    ) { error in
      guard let buildError = error as? OwlRustResourceBuildError,
            case .outputNotEmpty = buildError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
  }

  private struct StoreEnvironment {
    let userRoot: URL
    let configuration: OwlRustResourceConfiguration
  }

  private struct DictPackFixture {
    let dictionaryRoot: URL
    let packageRoot: URL
    let manifest: OwlDictPackManifest
    let sourceChain: [OwlDictPackSource]
  }

  private func makeDictPackFixture(
    name: String,
    version: Int
  ) throws -> DictPackFixture {
    let base = root.appendingPathComponent(name, isDirectory: true)
    let dictionaryRoot = base.appendingPathComponent("dictionary", isDirectory: true)
    let packageRoot = base.appendingPathComponent("candidate-package", isDirectory: true)
    let upstream = base.appendingPathComponent("upstream", isDirectory: true)
    try FileManager.default.createDirectory(
      at: dictionaryRoot, withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: upstream, withIntermediateDirectories: true
    )

    let repo = "owltype/test"
    let ref = "fixture-v\(version)"
    var files: [OwlDictPackFile] = []
    for (path, content) in Self.dictPackContents(version: version) {
      let data = Data(content.utf8)
      let upstreamFile = upstream.appendingPathComponent(
        "\(repo)/\(ref)/\(path)"
      )
      try FileManager.default.createDirectory(
        at: upstreamFile.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: upstreamFile)
      files.append(
        OwlDictPackFile(
          repo: repo,
          ref: ref,
          path: path,
          dest: path,
          sha256: OwlDictPackFetcher.sha256Hex(data),
          size: data.count,
          patch: nil
        )
      )
    }
    let prefix = upstream.absoluteString.hasSuffix("/")
      ? String(upstream.absoluteString.dropLast())
      : upstream.absoluteString
    return DictPackFixture(
      dictionaryRoot: dictionaryRoot,
      packageRoot: packageRoot,
      manifest: OwlDictPackManifest(version: version, files: files),
      sourceChain: [.rawPrefix(prefix)]
    )
  }

  private static func dictPackContents(version: Int) -> [(String, String)] {
    let tag = "v\(version)"
    return [
      (
        "rime_ice.dict.yaml",
        """
        ---
        name: rime_ice
        import_tables:
          - cn_dicts/8105
          - cn_dicts/base
          - cn_dicts/ext
          - cn_dicts/others
          - cn_dicts/tencent
        ...
        """
      ),
      (
        "cn_dicts/8105.dict.yaml",
        "---\nname: 8105\n...\n甲\(tag)\tjia\t100\n"
      ),
      (
        "cn_dicts/base.dict.yaml",
        "---\nname: base\n...\n合成甲\(tag)\tni hao\t100\n"
      ),
      (
        "cn_dicts/ext.dict.yaml",
        "---\nname: ext\n...\n合成乙\(tag)\tzhong guo\t80\n"
      ),
      (
        "cn_dicts/others.dict.yaml",
        "---\nname: others\n...\n其他\(tag)\tshi jie\t70\n"
      ),
      (
        "cn_dicts/tencent.dict.yaml",
        "---\nname: tencent\n...\n腾讯\(tag)\tgong zuo\t60\n"
      ),
      (
        "en_dicts/en.dict.yaml",
        "---\nname: en\n...\nHello\(tag)\thello\t10\n"
      ),
      (
        "en_dicts/en_ext.dict.yaml",
        "---\nname: en_ext\n...\nworld\(tag)\tworld\t20\n"
      ),
      (
        "wubi86_jidian.dict.yaml",
        """
        ---
        name: wubi86_jidian
        import_tables:
          - wubi86_jidian_extra
          - wubi86_jidian_user
          - wubi86_jidian_user_hamster
        ...
        工\(tag)\taaaa\t20
        """
      ),
      (
        "wubi86_jidian_extra.dict.yaml",
        "---\nname: wubi86_jidian_extra\n...\n或\(tag)\taaaa\t10\n"
      ),
      (
        "wubi86_jidian_user.dict.yaml",
        "---\nname: wubi86_jidian_user\n...\n"
      ),
      (
        "wubi86_jidian_user_hamster.dict.yaml",
        "---\nname: wubi86_jidian_user_hamster\n...\n"
      ),
      ("rime-ice.LICENSE", "rime-ice license\n"),
      ("wubi86-jidian.LICENSE", "wubi86-jidian license\n"),
      ("octagram-data.LICENSE", "octagram-data license\n"),
    ]
  }

  private func makeStoreEnvironment() throws -> StoreEnvironment {
    let base = root.appendingPathComponent("store", isDirectory: true)
    let user = base.appendingPathComponent("user", isDirectory: true)
    try FileManager.default.createDirectory(
      at: user.appendingPathComponent("msime-user", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("user journal".utf8).write(
      to: user.appendingPathComponent("msime-user/msime_user.db")
    )
    return StoreEnvironment(
      userRoot: user,
      configuration: OwlRustResourceConfiguration(
        libraryRoot: base.appendingPathComponent("library", isDirectory: true),
        stagingRoot: base.appendingPathComponent("staging", isDirectory: true),
        runtimeRoot: base.appendingPathComponent("runtime", isDirectory: true),
        stateRoot: base.appendingPathComponent("state", isDirectory: true),
        userRoot: user,
        cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
      )
    )
  }

  private func makeInputRoot(importPath: String = "cn_dicts/a") throws -> URL {
    let input = root.appendingPathComponent("input", isDirectory: true)
    try FileManager.default.createDirectory(
      at: input.appendingPathComponent("cn_dicts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: input.appendingPathComponent("en_dicts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try write(
      """
      ---
      name: rime_ice
      import_tables:
        - \(importPath)
        - cn_dicts/b
      ...
      """,
      to: input.appendingPathComponent("rime_ice.dict.yaml")
    )
    try write(
      """
      ---
      name: a
      ...
      合成高\tni hao\t100
      合成高\tni hao\t200
      合成低\tni hao\t50
      """,
      to: input.appendingPathComponent("cn_dicts/a.dict.yaml")
    )
    try write(
      """
      ---
      name: b
      ...
      合成外\tni hao\t75
      """,
      to: input.appendingPathComponent("cn_dicts/b.dict.yaml")
    )
    try write(
      """
      ---
      name: wubi86_jidian
      import_tables:
        - wubi86_jidian_extra
      ...
      工\taaaa\t20
      或\taaaa\t10
      """,
      to: input.appendingPathComponent("wubi86_jidian.dict.yaml")
    )
    try write(
      """
      ---
      name: wubi86_jidian_extra
      ...
      工\taaaa\t15
      你\twqiy\t20
      """,
      to: input.appendingPathComponent("wubi86_jidian_extra.dict.yaml")
    )
    for name in ["wubi86_jidian_user", "wubi86_jidian_user_hamster"] {
      try write(
        "---\nname: \(name)\n...\n",
        to: input.appendingPathComponent("\(name).dict.yaml")
      )
    }
    try write(
      "---\nname: en\n...\nHello\thello\t10\n",
      to: input.appendingPathComponent("en_dicts/en.dict.yaml")
    )
    try write(
      "---\nname: en_ext\n...\nworld\tworld\t20\n",
      to: input.appendingPathComponent("en_dicts/en_ext.dict.yaml")
    )
    for name in [
      "rime-ice.LICENSE", "wubi86-jidian.LICENSE", "octagram-data.LICENSE",
    ] {
      try Data("\(name)\n".utf8).write(to: input.appendingPathComponent(name))
    }
    return input
  }

  private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
  }

  private func rows(_ database: URL, _ sql: String) throws -> [[String]] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      database.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
    ) == SQLITE_OK, let handle else {
      throw OwlRustResourceBuildError.sqlite("open failed")
    }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw OwlRustResourceBuildError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    var result: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append((0..<sqlite3_column_count(statement)).map { column in
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
      })
    }
    return result
  }

  private func userBytes(_ root: URL) throws -> [String: Data] {
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey]
    )
    var result: [String: Data] = [:]
    while let url = enumerator?.nextObject() as? URL {
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        result[relative] = try Data(contentsOf: url)
      }
    }
    return result
  }

  private static func canonicalDirectory(_ url: URL) throws -> URL {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &resolved) != nil else {
      throw OwlRustResourceBuildError.missingInput(url.path)
    }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
  }
}
