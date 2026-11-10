//
//  OwlRustDictPackResource.swift
//  Owltype
//
//  Direct bundled SQLite resource catalog and environment for the Rust msime engine.
//  Loads immutable bundled dictionary and model assets directly from
//  `Bundle.main.sharedSupportURL/msime` without multi-generation staging or leases.
//

import Foundation

enum OwlRustResourceError: Error, LocalizedError, Equatable, Sendable {
  case sharedSupportUnavailable
  case directoryMissing(String)
  case fileMissing(String)
  case fileNotRegular(String)
  case fileOperationFailed(path: String, message: String)

  var errorDescription: String? {
    switch self {
    case .sharedSupportUnavailable:
      return "无法定位随包 SharedSupport 目录"
    case .directoryMissing(let path):
      return "随包词库目录缺失：\(path)"
    case .fileMissing(let path):
      return "随包词库资源文件缺失：\(path)"
    case .fileNotRegular(let path):
      return "随包词库资源不是普通文件或经过符号链接：\(path)"
    case .fileOperationFailed(let path, let message):
      return "资源目录操作失败 \(path)：\(message)"
    }
  }
}

struct OwlRustResourceGeneration: Equatable, Sendable {
  let resourcesURL: URL
  let contentID: String
}

enum OwlRustCompatibleResources {
  struct Catalog: Decodable, Sendable {
    let packageId: String
    let packageVersion: Int
    let configurationVersion: String
    let wubiDictionaryDigest: String
    let requiredFiles: [String]
    let notices: [String]
    let models: [OwlRerankModelDescriptor]
  }

  static let catalog: Catalog = OwlAppCore.required(["operation": "resource_catalog"])

  static var packageId: String { catalog.packageId }
  static var packageVersion: Int { catalog.packageVersion }
  static var configurationVersion: String { catalog.configurationVersion }
  static var wubiDictionaryDigest: String { catalog.wubiDictionaryDigest }
  static var requiredFiles: [String] { catalog.requiredFiles }
  static var notices: [String] { catalog.notices }
  static var models: [OwlRerankModelDescriptor] { catalog.models }
  static var contentID: String {
    let digestHex = wubiDictionaryDigest.replacingOccurrences(of: "sha256:", with: "")
    return "bundled-v\(packageVersion)-\(digestHex)"
  }

  static func bundledResourcesURL(sharedSupport: URL? = Bundle.main.sharedSupportURL) throws -> URL {
    guard let sharedSupport else {
      throw OwlRustResourceError.sharedSupportUnavailable
    }
    return sharedSupport.appendingPathComponent("msime", isDirectory: true)
  }

  static func validateBundledResources(
    sharedSupport: URL? = Bundle.main.sharedSupportURL
  ) throws -> OwlRustResourceGeneration {
    let msimeURL = try bundledResourcesURL(sharedSupport: sharedSupport)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: msimeURL.path, isDirectory: &isDir),
          isDir.boolValue else {
      throw OwlRustResourceError.directoryMissing(msimeURL.path)
    }
    for relativePath in requiredFiles {
      let fileURL = msimeURL.appendingPathComponent(relativePath, isDirectory: false)
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw OwlRustResourceError.fileMissing(relativePath)
      }
      let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
        throw OwlRustResourceError.fileNotRegular(relativePath)
      }
    }
    return OwlRustResourceGeneration(
      resourcesURL: msimeURL,
      contentID: contentID
    )
  }
}

struct OwlRustResourceEnvironment: Sendable {
  let userRoot: URL
  let sharedSupportURL: URL?
  let store: OwlRustResourceStore

  static func production(
    userRoot: URL = OwlApp.userDir,
    sharedSupportURL: URL? = Bundle.main.sharedSupportURL
  ) -> Self {
    let store = OwlRustResourceStore(userRoot: userRoot, sharedSupportURL: sharedSupportURL)
    return Self(userRoot: userRoot, sharedSupportURL: sharedSupportURL, store: store)
  }

  func activeGeneration() throws -> OwlRustResourceGeneration {
    try store.resolveBundledGeneration()
  }
}
