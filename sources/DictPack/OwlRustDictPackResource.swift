//
//  OwlRustDictPackResource.swift
//  Owltype
//
//  Connects the existing pinned dict-pack downloader to the transactional Rust
//  resource store. The dictionary tree and generated package live outside the
//  Rime user directory; the store sees userRoot only as an exclusion boundary.
//

import Foundation

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
    case .downloading, .deploying, .failed:
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
    let installed = try await store.install(
      OwlRustResourceDirectorySource(root: built.root)
    ) { value in
      progress?(0.95 + value * 0.05)
    }
    progress?(1)
    return installed
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
