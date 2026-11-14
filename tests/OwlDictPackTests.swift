//
//  OwlDictPackTests.swift
//  OwltypeTests — 随包预置 SQLite 资源加载测试（OwlRustDictPackResource + OwlRustResourceStore）
//

import XCTest
@testable import Owltype

final class OwlDictPackTests: XCTestCase {

  func testCompatibleResourcesCatalogExposesBundledMetadataAndModels() {
    XCTAssertEqual(OwlRustCompatibleResources.packageVersion, 5)
    XCTAssertFalse(OwlRustCompatibleResources.configurationVersion.isEmpty)
    XCTAssertTrue(OwlRustCompatibleResources.requiredFiles.contains("msime-pinyin.db"))
    XCTAssertTrue(OwlRustCompatibleResources.requiredFiles.contains("msime-wubi.db"))
    XCTAssertTrue(OwlRustCompatibleResources.requiredFiles.contains("msime-english.db"))
    XCTAssertEqual(OwlRustCompatibleResources.models.map(\.kind), [.keyboard, .settled])
    XCTAssertEqual(OwlRerankModelDescriptor.descriptor(for: .keyboard).fileName, "keyboard-model.bin")
    XCTAssertEqual(OwlRerankModelDescriptor.descriptor(for: .settled).fileName, "settled-model.bin")
  }

  func testSchemaDisplayNameResolvesKnownSchemasAndFallsBackToRawID() {
    XCTAssertEqual(OwlRustSchemaMap.displayName(for: "wubi86_jidian"), "极点五笔86")
    XCTAssertEqual(OwlRustSchemaMap.displayName(for: "rime_ice"), "雾凇拼音")
    XCTAssertEqual(OwlRustSchemaMap.displayName(for: "some_unknown_schema"), "some_unknown_schema")
  }

  func testResourceStoreResolvesBundledSQLiteResourcesDirectlyWithoutStagingCopy() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let seedDir = repoRoot.appendingPathComponent("data/owl-rime", isDirectory: true)
    let userRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-bundled-resource-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: userRoot) }

    let environment = OwlRustResourceEnvironment.production(
      userRoot: userRoot,
      sharedSupportURL: seedDir
    )
    let generation = try environment.activeGeneration()
    XCTAssertEqual(
      generation.resourcesURL.standardizedFileURL,
      seedDir.appendingPathComponent("msime", isDirectory: true).standardizedFileURL
    )
    XCTAssertEqual(generation.contentID, OwlRustCompatibleResources.contentID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: environment.store.mutableUserDir.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: environment.store.mutableCacheDir.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: userRoot.appendingPathComponent("rust-resources").path
      ),
      "direct bundled SQLite loading must not create a multi-generation rust-resources staging/library tree"
    )
  }

  func testValidateBundledResourcesRejectsMissingRequiredSQLiteFile() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-bundled-missing-file-\(UUID().uuidString)", isDirectory: true)
    let msimeDir = tempRoot.appendingPathComponent("msime", isDirectory: true)
    try FileManager.default.createDirectory(at: msimeDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    // Write only the first required file; validation must fail on the first missing file.
    let firstFile = msimeDir.appendingPathComponent("msime-pinyin.db")
    try Data("sqlite".utf8).write(to: firstFile)

    XCTAssertThrowsError(
      try OwlRustCompatibleResources.validateBundledResources(sharedSupport: tempRoot)
    ) { error in
      guard case OwlRustResourceError.fileMissing(let missing) = error else {
        return XCTFail("Expected .fileMissing, got \(error)")
      }
      XCTAssertEqual(missing, "msime-wubi.db")
    }
  }
}
