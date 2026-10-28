//
//  OwlRustDictPackResource.swift
//  Owltype
//
//  The Rust resource environment and the one package it installs: the bundled
//  msime resources, copied into a generation for the transactional store. The
//  store sees userRoot only as an exclusion boundary.
//

import Foundation
import SQLite3

enum OwlRustResourceBuildError: Error, LocalizedError, Equatable {
  case sqlite(String)

  var errorDescription: String? {
    switch self {
    case .sqlite(let message):
      return "读取资源 SQLite 失败：\(message)"
    }
  }
}

struct OwlRustResourceBuildStats: Codable, Equatable, Sendable {
  let pinyinEntries: Int
  let wubiEntries: Int
  let englishEntries: Int
  let rejectedPinyinEntries: Int
  let rejectedWubiEntries: Int
  let rejectedEnglishEntries: Int
}

struct OwlRustResourcePackageBuild: Equatable, Sendable {
  let root: URL
  let manifest: OwlRustResourceManifest
  let stats: OwlRustResourceBuildStats
}

struct OwlRustResourceGeneration: Equatable, Sendable {
  let resourcesURL: URL
  let contentID: String
}

struct OwlRustResourceEnvironment: Sendable {
  static let activeInputKind = OwlRustResourceInputKind.pinyinWubi

  let dictionaryRoot: URL
  let packageRoot: URL
  let configuration: OwlRustResourceConfiguration

  static func production(userRoot: URL = OwlApp.userDir) -> Self {
    let resourcesRoot = userRoot.appendingPathComponent(
      "rust-resources", isDirectory: true
    )
    return Self(
      dictionaryRoot: userRoot,
      packageRoot: resourcesRoot.appendingPathComponent("candidate", isDirectory: true),
      configuration: OwlRustResourceConfiguration(
        libraryRoot: resourcesRoot.appendingPathComponent("library", isDirectory: true),
        stagingRoot: resourcesRoot.appendingPathComponent("staging", isDirectory: true),
        runtimeRoot: resourcesRoot.appendingPathComponent("runtime", isDirectory: true),
        stateRoot: resourcesRoot.appendingPathComponent("state", isDirectory: true),
        userRoot: userRoot.appendingPathComponent("msime-user", isDirectory: true),
        cacheRoot: userRoot.appendingPathComponent("msime-cache", isDirectory: true)
      )
    )
  }

  func makeStore() throws -> OwlRustResourceStore {
    try FileManager.default.createDirectory(
      at: configuration.userRoot, withIntermediateDirectories: true
    )
    return try OwlRustResourceStore(
      configuration: configuration, engine: .owlRustNativeInputV1
    )
  }

  func activeState(
    inputKind: OwlRustResourceInputKind = Self.activeInputKind
  ) throws -> OwlRustResourceActiveState? {
    let url = configuration.stateRoot
      .appendingPathComponent("active", isDirectory: true)
      .appendingPathComponent(inputKind.rawValue + ".json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let state: OwlRustResourceActiveState
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      state = try decoder.decode(
        OwlRustResourceActiveState.self, from: Data(contentsOf: url)
      )
    } catch {
      throw OwlRustResourceError.activeStateInvalid(
        "active pointer is unreadable: \(error.localizedDescription)"
      )
    }
    guard state.schemaVersion == 1, state.inputKind == inputKind else {
      throw OwlRustResourceError.activeStateInvalid("schema or inputKind mismatch")
    }
    return state
  }

  func activeGeneration() throws -> OwlRustResourceGeneration? {
    guard let state = try activeState() else { return nil }
    do { return try validatedGeneration(state.current) } catch {
      if let previous = state.previous { return try validatedGeneration(previous) }
      throw error
    }
  }

  func validatedGeneration(_ record: OwlRustResourceRecord) throws -> OwlRustResourceGeneration {
    let expectedGenerationId = "sha256-" + record.digest.dropFirst("sha256:".count)
    guard record.digest == record.manifest.digest,
          record.generationId == expectedGenerationId else {
      throw OwlRustResourceError.activeStateInvalid(
        "active generation identity is inconsistent"
      )
    }

    let generation = configuration.libraryRoot
      .appendingPathComponent(record.manifest.packageId, isDirectory: true)
      .appendingPathComponent("generations", isDirectory: true)
      .appendingPathComponent(record.generationId, isDirectory: true)
    try OwlRustCompatibleResources.validate(at: generation, manifest: record.manifest, requireCompleteMarker: true)
    let resources = generation.appendingPathComponent("files", isDirectory: true)
    return OwlRustResourceGeneration(
      resourcesURL: resources,
      contentID: record.generationId
    )
  }
}

struct OwlRustDictPackPreparedResources: Equatable, Sendable {
  let resource: OwlRustResourcePrepared
  let stats: OwlRustResourceBuildStats

  var version: Int { resource.record.manifest.version }
  var licenseIdentifiers: [String] {
    resource.record.manifest.license.map(\.identifier).sorted()
  }
}

struct OwlDictPackCandidate: Equatable, Sendable {
  let version: Int
  let digest: String
  let licenseIdentifiers: [String]
  let pinyinEntries: Int
  let wubiEntries: Int
  let englishEntries: Int
  let rejectedEntries: Int

  init(prepared: OwlRustDictPackPreparedResources) {
    version = prepared.version
    digest = prepared.resource.record.digest
    licenseIdentifiers = prepared.licenseIdentifiers
    pinyinEntries = prepared.stats.pinyinEntries
    wubiEntries = prepared.stats.wubiEntries
    englishEntries = prepared.stats.englishEntries
    rejectedEntries = prepared.stats.rejectedPinyinEntries
      + prepared.stats.rejectedWubiEntries
      + prepared.stats.rejectedEnglishEntries
  }
}

/// An update is the same immutable compatibility set shipped by this binary.
/// Never rebuild ordinary Pinyin from the legacy YAML download after activation.
enum OwlRustCompatibleResources {
  /// Existing generations live under this id in the store library; never change it.
  static let packageId = "owltype-dictpack"
  static let packageVersion = 3
  static let configurationVersion = "msime-macos-v0.55.0-native-input-v1"
  // data/msime-dictionary-manifest.json, dict-v2.0.24: both official 86/98 tables.
  // Like the model hashes, this identity belongs to the fixed binary configuration.
  static let wubiDictionaryDigest = "sha256:851ed68211311a76847fe6a26096702747abbaab8dffb141698e0365143b31c1"
  static let requiredFiles = [
    "msime-pinyin.db", "msime-wubi.db", "msime-english.db", "msime-others.db",
    "msime-bigram.bin", "msime-trigram.bin", "msime-dictionary-manifest.json",
    "OWLTYPE-UPSTREAM-RESOURCES.json",
    "msime-scowl_Copyright.txt", "models/keyboard-model.bin", "models/settled-model.bin",
    "models/LICENSE-Apache-2.0.txt", "models/NOTICE.txt"
  ]

  static func build(sharedSupport: URL, at root: URL, version: Int) throws -> OwlRustResourcePackageBuild {
    let manager = FileManager.default
    let resources = sharedSupport.appendingPathComponent("msime")
    let files = root.appendingPathComponent("files")
    try manager.createDirectory(at: files, withIntermediateDirectories: true)
    var entries: [OwlRustResourceFile] = []
    let notices = ["rime-ice.LICENSE", "wubi86-jidian.LICENSE", "rime-kaomoji.LICENSE",
      "OpenCC.LICENSE", "jieba.LICENSE", "phrase-pinyin-data.LICENSE", "python-pinyin.LICENSE",
      "rime-ice-Credits.md", "msime-others-NOTICE.txt", "msime-resources-NOTICE.md",
      "msime-upstream-licensing-NOTICE.md", "licenses/LGPL-3.0-only.txt",
      "licenses/rime-wanxiang-CC-BY-4.0.txt", "licenses/msime-latex-symbols-MIT.txt",
      "licenses/CC-BY-3.0.txt", "licenses/chinese-ime-lm.LICENSE", "licenses/Unicode-3.0.txt",
      "licenses/MIT.txt", "licenses/GPL-3.0-only.txt", "licenses/CC-BY-SA-4.0.txt",
      "licenses/BSD-3-Clause.txt", "licenses/Apache-2.0.txt",
      "licenses/Unlicense.txt", "licenses/Administrative-divisions-of-China-WTFPL.txt"]
    for name in requiredFiles + notices {
      let source = try OwlRustResourceVerifier.safeFileURL(
        relativePath: name, under: notices.contains(name) ? sharedSupport : resources)
      let destination = files.appendingPathComponent(name)
      try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try manager.copyItem(at: source, to: destination)
      let role: OwlRustResourceFileRole
      switch name {
      case "msime-pinyin.db": role = .mainDictionary
      case "msime-wubi.db": role = .wubiDictionary
      case "msime-english.db": role = .englishDictionary
      case "msime-bigram.bin": role = .bigram
      case "msime-trigram.bin": role = .trigram
      default: role = notices.contains(name) ? .license : .other
      }
      entries.append(try entry(destination, name: name, role: role))
    }
    let marker = files.appendingPathComponent("compatibility.txt")
    try Data((configurationVersion + "\n").utf8).write(to: marker)
    entries.append(try entry(marker, name: "compatibility.txt", role: .other))
    let unsigned = OwlRustResourceManifest(schemaVersion: 1,
      packageId: packageId, inputKind: .pinyinWubi, version: version,
      digest: OwlRustResourceManifest.zeroDigest,
      license: [
        OwlRustResourceLicense(identifier: "GPL-3.0-only", attribution: "Pinned MSIME dictionary sources and resource notices",
          files: notices.map { "files/" + $0 }),
        OwlRustResourceLicense(identifier: "Apache-2.0", attribution: "Pinned chinese-ime-lm models and official Jidian Wubi base",
          files: ["files/licenses/chinese-ime-lm.LICENSE", "files/wubi86-jidian.LICENSE"]),
        OwlRustResourceLicense(identifier: "Unlicense", attribution: "Pinned 98wubi-tables original data",
          files: ["files/licenses/Unlicense.txt"]),
        OwlRustResourceLicense(identifier: "WTFPL", attribution: "Pinned administrative-division names in phrase supplements",
          files: ["files/licenses/Administrative-divisions-of-China-WTFPL.txt"]),
        OwlRustResourceLicense(identifier: "MIT", attribution: "Pinned static symbol tables and kaomoji sources",
          files: ["files/licenses/msime-latex-symbols-MIT.txt", "files/rime-kaomoji.LICENSE"])
      ],
      engineCompatibility: OwlRustResourceEngineCompatibility(minimumContractVersion: 1,
        maximumContractVersion: 1, requiredCapabilities: ["pinyin-wubi-v1", "persistent-user-journal-v1"]),
      files: entries.sorted { $0.path < $1.path })
    let manifest = OwlRustResourceManifest(schemaVersion: unsigned.schemaVersion,
      packageId: unsigned.packageId, inputKind: unsigned.inputKind, version: unsigned.version,
      digest: try unsigned.calculatedDigest(), license: unsigned.license,
      engineCompatibility: unsigned.engineCompatibility, files: unsigned.files)
    try manifest.canonicalData().write(to: root.appendingPathComponent("manifest.json"))
    try validate(at: root, manifest: manifest, requireCompleteMarker: false)
    // Counts describe this copied payload, rather than the retired YAML builder.
    let stats = OwlRustResourceBuildStats(pinyinEntries: try rowCount(files.appendingPathComponent("msime-pinyin.db"), prefix: "tbl_"),
      wubiEntries: try rowCount(files.appendingPathComponent("msime-wubi.db"), prefix: "wubi86"),
      englishEntries: try rowCount(files.appendingPathComponent("msime-english.db"), prefix: "english_words"),
      rejectedPinyinEntries: 0, rejectedWubiEntries: 0, rejectedEnglishEntries: 0)
    return OwlRustResourcePackageBuild(root: root, manifest: manifest, stats: stats)
  }

  static func validate(at root: URL, manifest: OwlRustResourceManifest, requireCompleteMarker: Bool) throws {
    let names = Set(manifest.files.map(\.path))
    for name in requiredFiles + ["compatibility.txt"] where !names.contains("files/" + name) {
      throw OwlRustResourceError.fileMissing("files/" + name)
    }
    try OwlRustResourceVerifier.verifyGeneration(at: root, manifest: manifest,
      engine: .owlRustNativeInputV1, requireCompleteMarker: requireCompleteMarker)
    let resources = root.appendingPathComponent("files")
    guard try String(contentsOf: resources.appendingPathComponent("compatibility.txt"), encoding: .utf8)
      == configurationVersion + "\n" else {
      throw OwlRustResourceError.incompatibleEngine("resource configuration version differs from this binary")
    }
    guard try OwlRustResourceVerifier.digestOfFile(resources.appendingPathComponent("msime-wubi.db"))
      == wubiDictionaryDigest else {
      throw OwlRustResourceError.incompatibleEngine("official Wubi tables differ from this binary")
    }
    for kind in OwlRerankModelKind.allCases {
      let descriptor = OwlRerankModelDescriptor.descriptor(for: kind)
      let model = resources.appendingPathComponent("models/" + descriptor.fileName)
      guard try OwlRustResourceVerifier.digestOfFile(model) == "sha256:" + descriptor.expectedSHA256 else {
        throw OwlRustResourceError.incompatibleEngine("resource model differs from this binary: " + kind.rawValue)
      }
    }
  }

  private static func rowCount(_ file: URL, prefix: String) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else { throw OwlRustResourceBuildError.sqlite("cannot open resource") }
    defer { sqlite3_close(database) }
    var tables: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type='table'", -1, &tables, nil) == SQLITE_OK else {
      throw OwlRustResourceBuildError.sqlite("cannot list resource tables")
    }
    defer { sqlite3_finalize(tables) }
    var total = 0
    while sqlite3_step(tables) == SQLITE_ROW {
      let name = String(cString: sqlite3_column_text(tables, 0))
      guard name.hasPrefix(prefix) else { continue }
      var count: OpaquePointer?
      let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
      guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \"\(escaped)\"", -1, &count, nil) == SQLITE_OK else {
        throw OwlRustResourceBuildError.sqlite("cannot count resource rows")
      }
      if sqlite3_step(count) == SQLITE_ROW { total += Int(sqlite3_column_int64(count, 0)) }
      sqlite3_finalize(count)
    }
    return total
  }

  private static func entry(_ file: URL, name: String, role: OwlRustResourceFileRole) throws -> OwlRustResourceFile {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    return OwlRustResourceFile(path: "files/" + name, role: role,
      mediaType: "application/octet-stream", size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
      digest: try OwlRustResourceVerifier.digestOfFile(file))
  }
}

extension OwlRustEngineIdentity {
  /// Native desktop resources split the two official Wubi tables out of the main database.
  /// owlRustResourceV1 is the base contract it derives from (merged Wubi layout).
  static let owlRustNativeInputV1 = OwlRustEngineIdentity(
    contractVersion: owlRustResourceV1.contractVersion,
    capabilities: owlRustResourceV1.capabilities,
    sqliteRequirements: owlRustResourceV1.sqliteRequirements.map { requirement in
      guard requirement.role == .mainDictionary else { return requirement }
      return OwlRustResourceSQLiteRequirement(role: .mainDictionary,
        tables: requirement.tables.filter { $0.table != "wubi86" })
    } + [OwlRustResourceSQLiteRequirement(role: .wubiDictionary, tables: [
      OwlRustResourceSQLiteTableRequirement(table: "wubi86", columns: ["key", "value", "weight"]),
      OwlRustResourceSQLiteTableRequirement(table: "wubi98", columns: ["key", "value", "weight"])
    ])]
  )

  static let owlRustResourceV1 = OwlRustEngineIdentity(
    contractVersion: 1,
    capabilities: ["dictionary-contract-v1", "pinyin-wubi-v1", "persistent-user-journal-v1"],
    sqliteRequirements: [
      OwlRustResourceSQLiteRequirement(
        role: .mainDictionary,
        tables: [
          OwlRustResourceSQLiteTableRequirement(
            table: "tbl_1_n", columns: ["key", "jp", "value", "weight"]
          ),
          OwlRustResourceSQLiteTableRequirement(
            table: "wubi86", columns: ["key", "value", "weight"]
          ),
          OwlRustResourceSQLiteTableRequirement(
            table: "quick_parases", columns: ["key", "value", "weight"]
          ),
        ]
      ),
      OwlRustResourceSQLiteRequirement(
        role: .englishDictionary,
        tables: [
          OwlRustResourceSQLiteTableRequirement(
            table: "english_words", columns: ["word", "display", "weight"]
          ),
        ]
      ),
    ]
  )
}
