//
//  OwlRustResourceContractTests.swift
//  OwltypeTests
//
//  Synthetic manifest and SQLite contract coverage for #255 B1/B2.
//

import Foundation
import SQLite3
import XCTest
@testable import Owltype

enum OwlRustResourceTestFixtures {
  struct Package {
    let root: URL
    let manifest: OwlRustResourceManifest
  }

  static func makePackage(
    at root: URL,
    name: String = "package",
    packageId: String = "im.owltype.rust.pinyin",
    inputKind: OwlRustResourceInputKind = .pinyin,
    version: Int = 1,
    candidate: String = "合成甲",
    licenseIdentifier: String = "Apache-2.0",
    requiredCapabilities: [String] = ["dictionary-contract-v1"],
    fileDigestOverride: String? = nil,
    invalidSQLite: Bool = false
  ) throws -> Package {
    let packageRoot = root.appendingPathComponent(name, isDirectory: true)
    let filesRoot = packageRoot.appendingPathComponent("files", isDirectory: true)
    let licenseRoot = filesRoot.appendingPathComponent("licenses", isDirectory: true)
    try FileManager.default.createDirectory(
      at: licenseRoot, withIntermediateDirectories: true
    )
    let databaseURL = filesRoot.appendingPathComponent("dictionary.db")
    if invalidSQLite {
      try Data("not sqlite".utf8).write(to: databaseURL)
    } else {
      try makeSQLite(at: databaseURL, candidate: candidate)
    }
    let licenseURL = licenseRoot.appendingPathComponent("NOTICE.txt")
    let licenseData = Data("\(licenseIdentifier) synthetic fixture\n".utf8)
    try licenseData.write(to: licenseURL)

    let databaseData = try Data(contentsOf: databaseURL)
    let databaseDigest: String
    if let fileDigestOverride {
      databaseDigest = fileDigestOverride
    } else {
      databaseDigest = try OwlRustResourceVerifier.digestOfFile(databaseURL)
    }
    let files = [
      OwlRustResourceFile(
        path: "files/dictionary.db",
        role: .mainDictionary,
        mediaType: "application/vnd.sqlite3",
        size: databaseData.count,
        digest: databaseDigest,
        requiredTables: []
      ),
      OwlRustResourceFile(
        path: "files/licenses/NOTICE.txt",
        role: .license,
        mediaType: "text/plain",
        size: licenseData.count,
        digest: OwlRustResourceManifest.digest(for: licenseData)
      ),
    ]
    let provisional = OwlRustResourceManifest(
      schemaVersion: 1,
      packageId: packageId,
      inputKind: inputKind,
      version: version,
      digest: OwlRustResourceManifest.zeroDigest,
      license: [
        OwlRustResourceLicense(
          identifier: licenseIdentifier,
          attribution: "Synthetic fixture",
          files: ["files/licenses/NOTICE.txt"]
        )
      ],
      engineCompatibility: OwlRustResourceEngineCompatibility(
        minimumContractVersion: 1,
        maximumContractVersion: 1,
        requiredCapabilities: requiredCapabilities
      ),
      files: files
    )
    let manifest = try replacingDigest(
      of: provisional, with: provisional.calculatedDigest()
    )
    try writeManifest(manifest, at: packageRoot)
    return Package(root: packageRoot, manifest: manifest)
  }

  static func makeSQLite(at url: URL, candidate: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    var database: OpaquePointer?
    let opened = url.path.withCString {
      sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    }
    guard opened == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) }
        ?? String(cString: sqlite3_errstr(opened))
      if let database { sqlite3_close(database) }
      throw OwlRustResourceError.sqliteOpenFailed(path: url.path, message: message)
    }
    defer { sqlite3_close(database) }
    let escaped = candidate.replacingOccurrences(of: "'", with: "''")
    let sql = """
      CREATE TABLE tbl_1_n(key TEXT, jp TEXT, value TEXT, weight INTEGER);
      INSERT INTO tbl_1_n VALUES('ni', 'n', '\(escaped)', 100);
      """
    var error: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &error)
    if result != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? "sqlite3_exec failed"
      sqlite3_free(error)
      throw OwlRustResourceError.sqliteOpenFailed(path: url.path, message: message)
    }
  }

  static func writeManifest(
    _ manifest: OwlRustResourceManifest, at packageRoot: URL
  ) throws {
    let data = try manifest.canonicalData()
    try data.write(to: packageRoot.appendingPathComponent("manifest.json"), options: .atomic)
  }

  static func replacingDigest(
    of manifest: OwlRustResourceManifest,
    with digest: String
  ) throws -> OwlRustResourceManifest {
    OwlRustResourceManifest(
      schemaVersion: manifest.schemaVersion,
      packageId: manifest.packageId,
      inputKind: manifest.inputKind,
      version: manifest.version,
      digest: digest,
      license: manifest.license,
      engineCompatibility: manifest.engineCompatibility,
      files: manifest.files
    )
  }

  static func defaultEngine(
    extraRequirements: [OwlRustResourceSQLiteRequirement] = []
  ) -> OwlRustEngineIdentity {
    OwlRustEngineIdentity(
      contractVersion: 1,
      capabilities: ["dictionary-contract-v1"],
      sqliteRequirements: [
        OwlRustResourceSQLiteRequirement(
          role: .mainDictionary,
          tables: [
            OwlRustResourceSQLiteTableRequirement(
              table: "tbl_1_n", columns: ["key", "jp", "value", "weight"]
            )
          ]
        )
      ] + extraRequirements
    )
  }
}

final class OwlRustResourceContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-rust-resource-contract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testManifestDigestCoversMetadataAndPayload() throws {
    let package = try OwlRustResourceTestFixtures.makePackage(at: root)

    try package.manifest.validateMetadata()
    try package.manifest.validateDigest()

    let changed = OwlRustResourceManifest(
      schemaVersion: package.manifest.schemaVersion,
      packageId: package.manifest.packageId,
      inputKind: package.manifest.inputKind,
      version: package.manifest.version + 1,
      digest: package.manifest.digest,
      license: package.manifest.license,
      engineCompatibility: package.manifest.engineCompatibility,
      files: package.manifest.files
    )
    XCTAssertThrowsError(try changed.validateDigest()) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .manifestDigestMismatch = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testUnsafeAndDuplicatePathsAreRejectedBeforeIO() throws {
    let package = try OwlRustResourceTestFixtures.makePackage(at: root)
    let unsafeFile = OwlRustResourceFile(
      path: "../escape.db",
      role: .wubiDictionary,
      mediaType: "application/vnd.sqlite3",
      size: 1,
      digest: OwlRustResourceManifest.digest(for: Data([1]))
    )
    let unsafe = OwlRustResourceManifest(
      schemaVersion: 1,
      packageId: package.manifest.packageId,
      inputKind: package.manifest.inputKind,
      version: 2,
      digest: OwlRustResourceManifest.zeroDigest,
      license: package.manifest.license,
      engineCompatibility: package.manifest.engineCompatibility,
      files: package.manifest.files + [unsafeFile]
    )
    XCTAssertThrowsError(try unsafe.validateMetadata()) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .unsafePath("../escape.db") = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    let duplicate = OwlRustResourceManifest(
      schemaVersion: 1,
      packageId: package.manifest.packageId,
      inputKind: package.manifest.inputKind,
      version: 2,
      digest: OwlRustResourceManifest.zeroDigest,
      license: package.manifest.license,
      engineCompatibility: package.manifest.engineCompatibility,
      files: package.manifest.files + [package.manifest.files[0]]
    )
    XCTAssertThrowsError(try duplicate.validateMetadata()) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .duplicatePath("files/dictionary.db") = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testBadPayloadDigestAndCorruptSQLiteAreRejected() throws {
    let badDigest = try OwlRustResourceTestFixtures.makePackage(
      at: root,
      name: "bad-digest",
      fileDigestOverride: OwlRustResourceManifest.digest(for: Data("wrong".utf8))
    )
    XCTAssertThrowsError(try OwlRustResourceVerifier.verifyGeneration(
      at: badDigest.root,
      manifest: badDigest.manifest,
      engine: OwlRustResourceTestFixtures.defaultEngine(),
      requireCompleteMarker: false
    )) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .fileDigestMismatch = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    let corrupt = try OwlRustResourceTestFixtures.makePackage(
      at: root, name: "corrupt", candidate: "合成乙"
    )
    let database = corrupt.root.appendingPathComponent("files/dictionary.db")
    let corruptDigest = OwlRustResourceManifest.digest(for: Data("not sqlite".utf8))
    try Data("not sqlite".utf8).write(to: database)
    var files = corrupt.manifest.files
    files[0] = OwlRustResourceFile(
      path: files[0].path,
      role: files[0].role,
      mediaType: files[0].mediaType,
      size: 10,
      digest: corruptDigest,
      requiredTables: files[0].requiredTables
    )
    let provisional = OwlRustResourceManifest(
      schemaVersion: 1,
      packageId: corrupt.manifest.packageId,
      inputKind: corrupt.manifest.inputKind,
      version: corrupt.manifest.version,
      digest: OwlRustResourceManifest.zeroDigest,
      license: corrupt.manifest.license,
      engineCompatibility: corrupt.manifest.engineCompatibility,
      files: files
    )
    let manifest = try OwlRustResourceTestFixtures.replacingDigest(
      of: provisional, with: provisional.calculatedDigest()
    )
    try OwlRustResourceTestFixtures.writeManifest(manifest, at: corrupt.root)

    XCTAssertThrowsError(try OwlRustResourceVerifier.verifyGeneration(
      at: corrupt.root,
      manifest: manifest,
      engine: OwlRustResourceTestFixtures.defaultEngine(),
      requireCompleteMarker: false
    )) { error in
      guard let resourceError = error as? OwlRustResourceError else {
        return XCTFail("unexpected error: \(error)")
      }
      switch resourceError {
      case .sqliteOpenFailed, .sqliteIntegrityFailed:
        break
      default:
        XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testTrustedEngineSchemaCannotBeWeakenedByManifest() throws {
    let package = try OwlRustResourceTestFixtures.makePackage(at: root)
    let forgedEngine = OwlRustEngineIdentity(
      contractVersion: 1,
      capabilities: ["dictionary-contract-v1"],
      sqliteRequirements: [
        OwlRustResourceSQLiteRequirement(
          role: .mainDictionary,
          tables: [
            OwlRustResourceSQLiteTableRequirement(
              table: "tbl_1_n", columns: ["missing_column"]
            )
          ]
        )
      ]
    )

    XCTAssertThrowsError(try OwlRustResourceVerifier.verifyGeneration(
      at: package.root,
      manifest: package.manifest,
      engine: forgedEngine,
      requireCompleteMarker: false
    )) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .sqliteSchemaMismatch = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testEngineContractAndCapabilitiesAreRequired() throws {
    let package = try OwlRustResourceTestFixtures.makePackage(at: root)
    let wrongVersion = OwlRustEngineIdentity(
      contractVersion: 2,
      capabilities: ["dictionary-contract-v1"],
      sqliteRequirements: []
    )
    XCTAssertThrowsError(try OwlRustResourceVerifier.verifyEngineCompatibility(
      manifest: package.manifest, engine: wrongVersion
    ))

    let missingCapability = OwlRustEngineIdentity(
      contractVersion: 1,
      capabilities: [],
      sqliteRequirements: []
    )
    XCTAssertThrowsError(try OwlRustResourceVerifier.verifyEngineCompatibility(
      manifest: package.manifest, engine: missingCapability
    ))
  }

  func testLicenseNoticeMustBePresent() throws {
    let package = try OwlRustResourceTestFixtures.makePackage(at: root)
    let missingNotice = OwlRustResourceLicense(
      identifier: "Apache-2.0",
      attribution: "Missing",
      files: ["files/licenses/ABSENT.txt"]
    )
    let invalid = OwlRustResourceManifest(
      schemaVersion: 1,
      packageId: package.manifest.packageId,
      inputKind: package.manifest.inputKind,
      version: 2,
      digest: OwlRustResourceManifest.zeroDigest,
      license: [missingNotice],
      engineCompatibility: package.manifest.engineCompatibility,
      files: package.manifest.files
    )
    XCTAssertThrowsError(try invalid.validateMetadata()) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .invalidManifest = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }
}
