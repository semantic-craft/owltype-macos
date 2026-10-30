//
//  OwlRustResourceContract.swift
//  Owltype
//
//  Frozen resource manifest v1 for the Rust dictionary delivery path. This file
//  validates immutable input only; transaction/state management lives in
//  OwlRustResourceStore.swift.
//

import CryptoKit
import Darwin
import Foundation
import SQLite3

enum OwlRustResourceError: Error, LocalizedError, Equatable, Sendable {
  case invalidConfiguration(String)
  case stagingAndLibraryOnDifferentVolumes
  case invalidManifest(String)
  case invalidDigest(String)
  case manifestDigestMismatch(expected: String, actual: String)
  case unsafePath(String)
  case duplicatePath(String)
  case fileMissing(String)
  case fileNotRegular(String)
  case fileSizeMismatch(path: String, expected: Int, actual: Int)
  case fileDigestMismatch(path: String, expected: String, actual: String)
  case sqliteOpenFailed(path: String, message: String)
  case sqliteIntegrityFailed(path: String, message: String)
  case sqliteSchemaMismatch(path: String, message: String)
  case incompatibleEngine(String)
  case missingEngineSQLiteFile(role: OwlRustResourceFileRole)
  case sourceReadFailed(String)
  case fileOperationFailed(path: String, message: String)
  case cancellationReceived
  case faultInjected(OwlRustResourceFaultPoint)
  case activeStateMissing(OwlRustResourceInputKind)
  case activeStateInvalid(String)
  case generationMissing(String)
  case generationCorrupt(String)
  case rollbackUnavailable(OwlRustResourceInputKind)
  case versionDigestConflict(
    packageId: String, inputKind: OwlRustResourceInputKind, version: Int
  )
  case leaseNotFound(UUID)
  case processIdentityUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message):
      return "资源路径配置无效：\(message)"
    case .stagingAndLibraryOnDifferentVolumes:
      return "staging 与 library 不在同一文件系统，拒绝用 copy/delete 冒充原子 rename"
    case .invalidManifest(let message):
      return "资源 manifest 无效：\(message)"
    case .invalidDigest(let digest):
      return "资源摘要格式无效：\(digest)"
    case .manifestDigestMismatch(let expected, let actual):
      return "manifest 摘要不符：期望 \(expected)，实际 \(actual)"
    case .unsafePath(let path):
      return "资源路径不安全：\(path)"
    case .duplicatePath(let path):
      return "资源路径重复：\(path)"
    case .fileMissing(let path):
      return "资源文件缺失：\(path)"
    case .fileNotRegular(let path):
      return "资源文件不是普通文件或经过 symlink：\(path)"
    case .fileSizeMismatch(let path, let expected, let actual):
      return "资源文件大小不符 \(path)：期望 \(expected)，实际 \(actual)"
    case .fileDigestMismatch(let path, let expected, let actual):
      return "资源文件摘要不符 \(path)：期望 \(expected)，实际 \(actual)"
    case .sqliteOpenFailed(let path, let message):
      return "无法只读打开 SQLite \(path)：\(message)"
    case .sqliteIntegrityFailed(let path, let message):
      return "SQLite 完整性检查失败 \(path)：\(message)"
    case .sqliteSchemaMismatch(let path, let message):
      return "SQLite schema 不兼容 \(path)：\(message)"
    case .incompatibleEngine(let message):
      return "资源与引擎不兼容：\(message)"
    case .missingEngineSQLiteFile(let role):
      return "资源缺少引擎要求的 SQLite 文件：\(role.rawValue)"
    case .sourceReadFailed(let message):
      return "读取资源源失败：\(message)"
    case .fileOperationFailed(let path, let message):
      return "资源文件操作失败 \(path)：\(message)"
    case .cancellationReceived:
      return "资源操作已取消"
    case .faultInjected(let point):
      return "资源事务故障注入命中：\(point.rawValue)"
    case .activeStateMissing(let inputKind):
      return "尚无已激活的 \(inputKind.rawValue) 资源"
    case .activeStateInvalid(let message):
      return "资源 active 状态无效：\(message)"
    case .generationMissing(let generation):
      return "资源 generation 缺失：\(generation)"
    case .generationCorrupt(let message):
      return "资源 generation 已损坏：\(message)"
    case .rollbackUnavailable(let inputKind):
      return "\(inputKind.rawValue) 资源没有可回滚的已验证 generation"
    case .versionDigestConflict(let packageId, let inputKind, let version):
      return "\(inputKind.rawValue) \(packageId) 版本 \(version) 已存在不同摘要，拒绝覆盖"
    case .leaseNotFound(let id):
      return "资源 lease 不存在：\(id.uuidString)"
    case .processIdentityUnavailable(let message):
      return "无法取得资源进程身份：\(message)"
    }
  }
}

enum OwlRustResourceInputKind: String, Codable, CaseIterable, Sendable {
  case pinyin
  case wubi
  case pinyinWubi = "pinyin-wubi"
}

enum OwlRustResourceFileRole: String, Codable, CaseIterable, Sendable {
  case mainDictionary = "main-dictionary"
  case wubiDictionary = "wubi-dictionary"
  case englishDictionary = "english-dictionary"
  case bigram
  case trigram
  case helpcode
  case other
  case license

}

struct OwlRustResourceLicense: Codable, Equatable, Sendable {
  let identifier: String
  let attribution: String
  let files: [String]
}

struct OwlRustResourceEngineCompatibility: Codable, Equatable, Sendable {
  let minimumContractVersion: Int
  let maximumContractVersion: Int
  let requiredCapabilities: [String]
}

struct OwlRustResourceFile: Codable, Equatable, Sendable {
  let path: String
  let role: OwlRustResourceFileRole
  let mediaType: String
  let size: Int
  let digest: String
  let requiredTables: [String]?

  init(
    path: String,
    role: OwlRustResourceFileRole,
    mediaType: String,
    size: Int,
    digest: String,
    requiredTables: [String]? = nil
  ) {
    self.path = path
    self.role = role
    self.mediaType = mediaType
    self.size = size
    self.digest = digest
    self.requiredTables = requiredTables
  }
}

struct OwlRustResourceManifest: Codable, Equatable, Sendable {
  static let schemaVersionV1 = 1
  static let zeroDigest = "sha256:" + String(repeating: "0", count: 64)

  let schemaVersion: Int
  let packageId: String
  let inputKind: OwlRustResourceInputKind
  let version: Int
  let digest: String
  let license: [OwlRustResourceLicense]
  let engineCompatibility: OwlRustResourceEngineCompatibility
  let files: [OwlRustResourceFile]

  func calculatedDigest() throws -> String { try OwlResourceBusiness.call("calculated", ["manifest": OwlAppCore.payload(self)]) }
  func canonicalData() throws -> Data {
    let bytes: [UInt8] = try OwlResourceBusiness.call("canonical", ["manifest": OwlAppCore.payload(self)])
    return Data(bytes)
  }
  func validateMetadata() throws { let _: Bool = try OwlResourceBusiness.call("metadata", ["manifest": OwlAppCore.payload(self)]) }
  func validateDigest() throws { let _: Bool = try OwlResourceBusiness.call("validate", ["manifest": OwlAppCore.payload(self)]) }
  static func digest(for data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func isValidDigest(_ digest: String) -> Bool { try! OwlResourceBusiness.call("digest", ["digest": digest]) }
  static func validateRelativePath(_ path: String) throws { let _: Bool = try OwlResourceBusiness.call("relative", ["path": path]) }
  static func isValidPackageId(_ id: String) -> Bool { try! OwlResourceBusiness.call("package", ["package": id]) }
}

struct OwlRustResourceSQLiteTableRequirement: Codable, Equatable, Sendable {
  let table: String
  let columns: Set<String>

  init(table: String, columns: Set<String>) {
    self.table = table
    self.columns = columns
  }
}

struct OwlRustResourceSQLiteRequirement: Codable, Equatable, Sendable {
  let role: OwlRustResourceFileRole
  let tables: [OwlRustResourceSQLiteTableRequirement]

  init(role: OwlRustResourceFileRole, tables: [OwlRustResourceSQLiteTableRequirement]) {
    self.role = role
    self.tables = tables
  }
}

/// Supplied by the real engine integration after #250 freezes its interface.
/// Unit tests inject the same shape, so downloaded manifests never attest
/// their own engine compatibility.
struct OwlRustEngineIdentity: Codable, Equatable, Sendable {
  let contractVersion: Int
  let capabilities: Set<String>
  let sqliteRequirements: [OwlRustResourceSQLiteRequirement]
}

enum OwlRustResourceVerifier {
  static func verifyGeneration(at root: URL, manifest: OwlRustResourceManifest, engine: OwlRustEngineIdentity, requireCompleteMarker: Bool) throws {
    let _: Bool = try OwlResourceBusiness.call("generation", ["path": root.path, "manifest": OwlAppCore.payload(manifest), "engine": OwlAppCore.payload(engine), "complete": requireCompleteMarker])
  }
  static func verifyEngineCompatibility(manifest: OwlRustResourceManifest, engine: OwlRustEngineIdentity) throws {
    let _: Bool = try OwlResourceBusiness.call("compatibility", ["manifest": OwlAppCore.payload(manifest), "engine": OwlAppCore.payload(engine)])
  }
  static func verifyFile(_ url: URL, expected: OwlRustResourceFile) throws {
    let _: Bool = try OwlResourceBusiness.call("file", ["path": url.path, "file": OwlAppCore.payload(expected)])
  }
  static func safeFileURL(relativePath: String, under root: URL) throws -> URL {
    let path: String = try OwlResourceBusiness.call("safe", ["path": relativePath, "root": root.path])
    return URL(fileURLWithPath: path)
  }
  static func digestOfFile(_ url: URL) throws -> String { try OwlResourceBusiness.call("file_digest", ["path": url.path]) }
}

/// Typed error projection for the resource domain. Business errors retain their original
/// public identity across the shared storage ABI.
enum OwlResourceBusiness {
  struct Catalog: Decodable {
    let packageId: String
    let packageVersion: Int
    let configurationVersion: String
    let wubiDictionaryDigest: String
    let requiredFiles: [String]
    let models: [OwlRerankModelDescriptor]
    let nativeEngine: OwlRustEngineIdentity
    let legacyEngine: OwlRustEngineIdentity
  }
  static let catalog: Catalog = try! call("catalog", [:])
  static func call<T: Decodable>(_ operation: String, _ args: [String: Any]) throws -> T {
    do { return try OwlStorageHost(dataDir: URL(fileURLWithPath: "/")).call("resource_contract_" + operation, args) }
    catch let failure as OwlAppCore.Failure { throw map(failure) }
  }
  static func map(_ failure: OwlAppCore.Failure) -> Error {
    guard failure.code.hasPrefix("resource:"), let data = String(failure.code.dropFirst(9)).data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let args = value["args"] as? [Any] else { return failure }
    func string(_ index: Int = 0) -> String { index < args.count ? args[index] as? String ?? "" : "" }
    func integer(_ index: Int) -> Int { index < args.count ? args[index] as? Int ?? 0 : 0 }
    let text = string()
    let constructors: [String: () -> Error] = [
      "differentVolumes": { OwlRustResourceError.stagingAndLibraryOnDifferentVolumes },
      "buildSQLite": { OwlRustResourceBuildError.sqlite(text) },
      "invalidConfiguration": { OwlRustResourceError.invalidConfiguration(text) },
      "invalidManifest": { OwlRustResourceError.invalidManifest(text) },
      "invalidDigest": { OwlRustResourceError.invalidDigest(text) },
      "manifestDigestMismatch": { OwlRustResourceError.manifestDigestMismatch(expected: text, actual: string(1)) },
      "unsafePath": { OwlRustResourceError.unsafePath(text) },
      "duplicatePath": { OwlRustResourceError.duplicatePath(text) },
      "fileMissing": { OwlRustResourceError.fileMissing(text) },
      "fileNotRegular": { OwlRustResourceError.fileNotRegular(text) },
      "fileSizeMismatch": { OwlRustResourceError.fileSizeMismatch(path: text, expected: integer(1), actual: integer(2)) },
      "fileDigestMismatch": { OwlRustResourceError.fileDigestMismatch(path: text, expected: string(1), actual: string(2)) },
      "fileOperationFailed": { OwlRustResourceError.fileOperationFailed(path: text, message: string(1)) },
      "sqliteOpenFailed": { OwlRustResourceError.sqliteOpenFailed(path: text, message: string(1)) },
      "sqliteIntegrityFailed": { OwlRustResourceError.sqliteIntegrityFailed(path: text, message: string(1)) },
      "sqliteSchemaMismatch": { OwlRustResourceError.sqliteSchemaMismatch(path: text, message: string(1)) },
      "incompatibleEngine": { OwlRustResourceError.incompatibleEngine(text) },
      "missingEngineSQLiteFile": { OwlRustResourceError.missingEngineSQLiteFile(role: OwlRustResourceFileRole(rawValue: text)!) },
      "activeStateInvalid": { OwlRustResourceError.activeStateInvalid(text) },
      "activeStateMissing": { OwlRustResourceError.activeStateMissing(OwlRustResourceInputKind(rawValue: text)!) },
      "rollbackUnavailable": { OwlRustResourceError.rollbackUnavailable(OwlRustResourceInputKind(rawValue: text)!) },
      "generationCorrupt": { OwlRustResourceError.generationCorrupt(text) },
      "leaseNotFound": { OwlRustResourceError.leaseNotFound(UUID(uuidString: text)!) },
      "versionDigestConflict": { OwlRustResourceError.versionDigestConflict(packageId: text, inputKind: OwlRustResourceInputKind(rawValue: string(1))!, version: integer(2)) },
    ]
    return constructors[value["code"] as? String ?? ""]?() ?? failure
  }
}
