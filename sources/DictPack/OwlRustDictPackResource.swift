//
//  OwlRustDictPackResource.swift
//  Owltype
//
//  Connects the existing pinned dict-pack downloader to the transactional Rust
//  resource store. The dictionary tree and generated package live outside the
//  Rime user directory; the store sees userRoot only as an exclusion boundary.
//

import Foundation
import SQLite3

enum OwlRustDictPackResourceError: Error, LocalizedError, Equatable {
  case dictionaryPackNotInstalled
  case userProvidedDictionaryPack(URL)
  case skippedDictionaryFiles([String])
  case unverifiedDictionaryInput(String)
  case candidateRootOccupied(URL)

  var errorDescription: String? {
    switch self {
    case .dictionaryPackNotInstalled:
      return "完整词库尚未下载，无法生成 Rust 资源"
    case .userProvidedDictionaryPack(let root):
      return "词典输入目录没有 Owltype 装机记录，拒绝把它当作已验证来源：\(root.path)"
    case .skippedDictionaryFiles(let files):
      return "隔离词典输入目录含用户文件，拒绝生成资源：\(files.joined(separator: ", "))"
    case .unverifiedDictionaryInput(let path):
      return "词典输入与固定 manifest 不符：\(path)"
    case .candidateRootOccupied(let root):
      return "资源候选目录不是本安装器生成的，拒绝覆盖：\(root.path)"
    }
  }
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

struct OwlRustDictPackResourceInstaller {
  private static let candidateMarkerName = ".owl-rust-resource-builder"
  private static let candidateMarker = Data("owltype-dictpack-v1\n".utf8)

  static let requiredInputs: Set<String> = [
    "rime_ice.dict.yaml",
    "cn_dicts/8105.dict.yaml",
    "cn_dicts/base.dict.yaml",
    "cn_dicts/ext.dict.yaml",
    "cn_dicts/others.dict.yaml",
    "cn_dicts/tencent.dict.yaml",
    "en_dicts/en.dict.yaml",
    "en_dicts/en_ext.dict.yaml",
    "wubi86_jidian.dict.yaml",
    "wubi86_jidian_extra.dict.yaml",
    "wubi86_jidian_user.dict.yaml",
    "wubi86_jidian_user_hamster.dict.yaml",
    "rime-ice.LICENSE",
    "wubi86-jidian.LICENSE",
    "octagram-data.LICENSE",
  ]

  let store: OwlRustResourceStore
  let dictionaryRoot: URL
  let packageRoot: URL
  let manifest: OwlDictPackManifest
  let baseURLOverride: String?
  let sourceChainOverride: [OwlDictPackSource]?

  init(
    store: OwlRustResourceStore,
    dictionaryRoot: URL,
    packageRoot: URL,
    manifest: OwlDictPackManifest = .current,
    baseURLOverride: String? = nil,
    sourceChainOverride: [OwlDictPackSource]? = nil
  ) {
    self.store = store
    self.dictionaryRoot = dictionaryRoot
    self.packageRoot = packageRoot
    self.manifest = manifest
    self.baseURLOverride = baseURLOverride
    self.sourceChainOverride = sourceChainOverride
  }

  func downloadAndInstall(
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> OwlRustResourceInstallResult {
    let prepared = try await prepare(progress: progress)
    return try await activate(prepared)
  }

  func prepare(
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> OwlRustDictPackPreparedResources {
    let fetcher = OwlDictPackFetcher(
      manifest: manifest,
      userDir: dictionaryRoot,
      baseURLOverride: baseURLOverride,
      sourceChainOverride: sourceChainOverride
    )
    switch fetcher.assess() {
    case .notInstalled, .installed(_):
      if fetcher.needsFetch() {
        let result = try await fetcher.run { value in
          progress?(value * 0.75)
        }
        guard result.skippedUserFiles.isEmpty else {
          throw OwlRustDictPackResourceError.skippedDictionaryFiles(
            result.skippedUserFiles
          )
        }
      }
    case .userProvided:
      throw OwlRustDictPackResourceError.userProvidedDictionaryPack(dictionaryRoot)
    case .downloading, .deploying, .prepared, .activating, .rollingBack, .failed:
      throw OwlRustDictPackResourceError.dictionaryPackNotInstalled
    }
    guard let record = OwlDictPackRecord.load(userDir: dictionaryRoot),
          record.version == manifest.version else {
      throw OwlRustDictPackResourceError.dictionaryPackNotInstalled
    }
    try validateRequiredInputs(record: record)
    progress?(0.8)

    let built = try buildPackage()
    progress?(0.95)
    let resource = try await store.prepare(
      OwlRustResourceDirectorySource(root: built.root)
    ) { value in
      progress?(0.95 + value * 0.05)
    }
    progress?(1)
    return OwlRustDictPackPreparedResources(resource: resource, stats: built.stats)
  }

  func activate(
    _ prepared: OwlRustDictPackPreparedResources
  ) async throws -> OwlRustResourceInstallResult {
    try await store.activate(prepared.resource)
  }

  private func buildPackage() throws -> OwlRustResourcePackageBuild {
    let fileManager = FileManager.default
    let parent = packageRoot.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    let attemptRoot = parent.appendingPathComponent(
      ".\(packageRoot.lastPathComponent).building-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: attemptRoot, withIntermediateDirectories: true)
    defer {
      if fileManager.fileExists(atPath: attemptRoot.path) {
        try? fileManager.removeItem(at: attemptRoot)
      }
    }

    let built = try OwlRustResourcePackageBuilder(
      dictionaryRoot: dictionaryRoot,
      packageVersion: manifest.version
    ).build(at: attemptRoot)
    try Self.candidateMarker.write(
      to: attemptRoot.appendingPathComponent(Self.candidateMarkerName),
      options: .atomic
    )
    try publish(attemptRoot)
    return OwlRustResourcePackageBuild(
      root: packageRoot,
      manifest: built.manifest,
      stats: built.stats
    )
  }

  private func publish(_ attemptRoot: URL) throws {
    let fileManager = FileManager.default
    let parent = packageRoot.deletingLastPathComponent()
    var previousRoot: URL?
    if fileManager.fileExists(atPath: packageRoot.path) {
      let values = try packageRoot.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard values.isSymbolicLink != true, values.isDirectory == true else {
        throw OwlRustDictPackResourceError.candidateRootOccupied(packageRoot)
      }
      if try fileManager.contentsOfDirectory(atPath: packageRoot.path).isEmpty {
        try fileManager.removeItem(at: packageRoot)
      } else {
        guard isOwnedCandidate(packageRoot) else {
          throw OwlRustDictPackResourceError.candidateRootOccupied(packageRoot)
        }
        let backup = parent.appendingPathComponent(
          ".\(packageRoot.lastPathComponent).previous-\(UUID().uuidString)",
          isDirectory: true
        )
        try fileManager.moveItem(at: packageRoot, to: backup)
        previousRoot = backup
      }
    }

    do {
      try fileManager.moveItem(at: attemptRoot, to: packageRoot)
    } catch {
      if let previousRoot, !fileManager.fileExists(atPath: packageRoot.path) {
        try? fileManager.moveItem(at: previousRoot, to: packageRoot)
      }
      throw error
    }
    if let previousRoot {
      try? fileManager.removeItem(at: previousRoot)
    }
  }

  private func isOwnedCandidate(_ root: URL) -> Bool {
    let marker = try? Data(
      contentsOf: root.appendingPathComponent(Self.candidateMarkerName)
    )
    guard marker == Self.candidateMarker else { return false }
    let manifestURL = root.appendingPathComponent("manifest.json")
    guard let data = try? Data(contentsOf: manifestURL),
          let candidate = try? JSONDecoder().decode(
            OwlRustResourceManifest.self, from: data
          ),
          candidate.packageId == OwlRustResourcePackageBuilder.packageId else {
      return false
    }
    return true
  }

  private func validateRequiredInputs(record: OwlDictPackRecord) throws {
    for path in Self.requiredInputs.sorted() {
      guard let entry = manifest.files.first(where: { $0.dest == path }) else {
        throw OwlRustDictPackResourceError.unverifiedDictionaryInput(path)
      }
      let url = dictionaryRoot.appendingPathComponent(path)
      guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
        throw OwlRustDictPackResourceError.unverifiedDictionaryInput(path)
      }
      let actual = OwlDictPackFetcher.sha256Hex(data)
      let expected: String
      if entry.patch == nil {
        expected = entry.sha256
      } else if let recorded = record.files[path] {
        expected = recorded
      } else {
        throw OwlRustDictPackResourceError.unverifiedDictionaryInput(path)
      }
      guard actual == expected else {
        throw OwlRustDictPackResourceError.unverifiedDictionaryInput(path)
      }
    }
  }
}

/// An update is the same immutable compatibility set shipped by this binary.
/// Never rebuild ordinary Pinyin from the legacy YAML download after activation.
enum OwlRustCompatibleResources {
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
      packageId: OwlRustResourcePackageBuilder.packageId, inputKind: .pinyinWubi, version: version,
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
