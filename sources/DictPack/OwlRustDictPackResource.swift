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
      configuration: configuration, engine: .owlRustNativeInputV1, requireCompatibleResources: true
    )
  }

  func activeState(
    inputKind: OwlRustResourceInputKind = Self.activeInputKind
  ) throws -> OwlRustResourceActiveState? {
    struct Reply: Decodable { let state: OwlRustResourceActiveState? }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      let reply: Reply = try OwlStorageHost(dataDir: configuration.stateRoot).call("resource_contract_active",
        ["stateRoot": configuration.stateRoot.path, "inputKind": inputKind.rawValue], decoder: decoder)
      return reply.state
    } catch let error as OwlAppCore.Failure { throw OwlResourceBusiness.map(error) }
  }

  private struct Generation: Decodable {
    let resourcesPath: String
    let contentID: String
    var value: OwlRustResourceGeneration { OwlRustResourceGeneration(resourcesURL: URL(fileURLWithPath: resourcesPath, isDirectory: true), contentID: contentID) }
  }
  func activeGeneration() throws -> OwlRustResourceGeneration? {
    struct Reply: Decodable { let generation: Generation? }
    let reply: Reply = try OwlResourceBusiness.call("active_generation", ["stateRoot": configuration.stateRoot.path,
      "libraryRoot": configuration.libraryRoot.path, "inputKind": Self.activeInputKind.rawValue])
    return reply.generation?.value
  }
  func validatedGeneration(_ record: OwlRustResourceRecord) throws -> OwlRustResourceGeneration {
    let reply: Generation = try OwlResourceBusiness.call("validated", ["libraryRoot": configuration.libraryRoot.path, "record": OwlAppCore.payload(record)])
    return reply.value
  }
}

struct OwlRustDictPackPreparedResources: Codable, Equatable, Sendable {
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
  static var packageId: String { OwlResourceBusiness.catalog.packageId }
  static var packageVersion: Int { OwlResourceBusiness.catalog.packageVersion }
  static var configurationVersion: String { OwlResourceBusiness.catalog.configurationVersion }
  static var wubiDictionaryDigest: String { OwlResourceBusiness.catalog.wubiDictionaryDigest }
  static var requiredFiles: [String] { OwlResourceBusiness.catalog.requiredFiles }

  static func build(sharedSupport: URL, at root: URL, version: Int) throws -> OwlRustResourcePackageBuild {
    struct Reply: Decodable { let manifest: OwlRustResourceManifest; let stats: OwlRustResourceBuildStats }
    let reply: Reply = try OwlResourceBusiness.call("build", ["sharedSupport": sharedSupport.path, "root": root.path, "version": version])
    return OwlRustResourcePackageBuild(root: root, manifest: reply.manifest, stats: reply.stats)
  }
  static func validate(at root: URL, manifest: OwlRustResourceManifest, requireCompleteMarker: Bool) throws {
    let _: Bool = try OwlResourceBusiness.call("compatible", ["root": root.path, "manifest": OwlAppCore.payload(manifest), "complete": requireCompleteMarker])
  }
}

extension OwlRustEngineIdentity {
  static var owlRustNativeInputV1: Self { OwlResourceBusiness.catalog.nativeEngine }
  static var owlRustResourceV1: Self { OwlResourceBusiness.catalog.legacyEngine }
}
