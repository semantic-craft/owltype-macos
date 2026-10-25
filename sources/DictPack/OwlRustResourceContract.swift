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

  var isSingleton: Bool {
    switch self {
    case .mainDictionary, .wubiDictionary, .englishDictionary, .bigram, .trigram:
      return true
    case .helpcode, .other, .license:
      return false
    }
  }
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

  func calculatedDigest() throws -> String {
    var unsigned = self
    unsigned = OwlRustResourceManifest(
      schemaVersion: schemaVersion,
      packageId: packageId,
      inputKind: inputKind,
      version: version,
      digest: Self.zeroDigest,
      license: license,
      engineCompatibility: engineCompatibility,
      files: files
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Self.digest(for: try encoder.encode(unsigned))
  }

  func canonicalData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  func validateMetadata() throws {
    guard schemaVersion == Self.schemaVersionV1 else {
      throw OwlRustResourceError.invalidManifest("不支持 schemaVersion \(schemaVersion)")
    }
    guard Self.isValidPackageId(packageId) else {
      throw OwlRustResourceError.invalidManifest("packageId 无效：\(packageId)")
    }
    guard version > 0 else {
      throw OwlRustResourceError.invalidManifest("version 必须为正整数")
    }
    guard Self.isValidDigest(digest) else {
      throw OwlRustResourceError.invalidDigest(digest)
    }
    guard !license.isEmpty else {
      throw OwlRustResourceError.invalidManifest("license 不得为空")
    }
    guard !files.isEmpty else {
      throw OwlRustResourceError.invalidManifest("files 不得为空")
    }

    try Self.validateFileEntries(files)
    try Self.validateLicenseEntries(license, files: files)
    try Self.validateEngineCompatibility(engineCompatibility)
  }

  private static func validateFileEntries(_ files: [OwlRustResourceFile]) throws {
    var paths = Set<String>()
    var singletonRoles = Set<OwlRustResourceFileRole>()
    for file in files {
      try Self.validateRelativePath(file.path)
      guard file.path.hasPrefix("files/") else {
        throw OwlRustResourceError.unsafePath(file.path)
      }
      guard paths.insert(file.path).inserted else {
        throw OwlRustResourceError.duplicatePath(file.path)
      }
      guard file.size > 0 else {
        throw OwlRustResourceError.invalidManifest("文件大小必须为正：\(file.path)")
      }
      guard Self.isValidDigest(file.digest) else {
        throw OwlRustResourceError.invalidDigest(file.digest)
      }
      guard !file.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OwlRustResourceError.invalidManifest("mediaType 为空：\(file.path)")
      }
      if file.role.isSingleton, !singletonRoles.insert(file.role).inserted {
        throw OwlRustResourceError.invalidManifest("role 重复：\(file.role.rawValue)")
      }
      for table in file.requiredTables ?? [] {
        guard !table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw OwlRustResourceError.invalidManifest("requiredTables 含空表名：\(file.path)")
        }
      }
    }
  }

  private static func validateLicenseEntries(
    _ license: [OwlRustResourceLicense],
    files: [OwlRustResourceFile]
  ) throws {
    let licenseFiles = Set(files.filter { $0.role == .license }.map(\.path))
    for notice in license {
      guard !notice.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !notice.attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !notice.files.isEmpty else {
        throw OwlRustResourceError.invalidManifest("license 条目缺少 identifier/attribution/files")
      }
      for path in notice.files {
        try Self.validateRelativePath(path)
        guard licenseFiles.contains(path) else {
          throw OwlRustResourceError.invalidManifest("license notice 未以 role=license 列入 files：\(path)")
        }
      }
    }
  }

  private static func validateEngineCompatibility(
    _ engineCompatibility: OwlRustResourceEngineCompatibility
  ) throws {
    guard engineCompatibility.minimumContractVersion > 0,
          engineCompatibility.maximumContractVersion >= engineCompatibility.minimumContractVersion else {
      throw OwlRustResourceError.invalidManifest("engineCompatibility 版本区间无效")
    }
    let capabilities = engineCompatibility.requiredCapabilities
    guard capabilities.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
          Set(capabilities).count == capabilities.count else {
      throw OwlRustResourceError.invalidManifest("requiredCapabilities 含空值或重复值")
    }
  }

  func validateDigest() throws {
    try validateMetadata()
    let actual = try calculatedDigest()
    guard actual == digest else {
      throw OwlRustResourceError.manifestDigestMismatch(expected: digest, actual: actual)
    }
  }

  static func digest(for data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func isValidDigest(_ digest: String) -> Bool {
    guard digest.hasPrefix("sha256:"), digest.count == 71 else { return false }
    let hex = digest.dropFirst(7)
    return hex.unicodeScalars.allSatisfy {
      (UInt32(UInt8(ascii: "0"))...UInt32(UInt8(ascii: "9"))).contains($0.value)
        || (UInt32(UInt8(ascii: "a"))...UInt32(UInt8(ascii: "f"))).contains($0.value)
    }
  }

  static func validateRelativePath(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
          !path.contains("\0"), !path.contains("\\") else {
      throw OwlRustResourceError.unsafePath(path)
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw OwlRustResourceError.unsafePath(path)
    }
  }

  static func isValidPackageId(_ id: String) -> Bool {
    guard (1...128).contains(id.utf8.count),
          id.first.map({ $0.isASCII && ($0.isLetter || $0.isNumber) }) == true else {
      return false
    }
    return id.unicodeScalars.allSatisfy {
      ($0.value >= 97 && $0.value <= 122)
        || ($0.value >= 48 && $0.value <= 57)
        || $0 == "."
        || $0 == "_"
        || $0 == "-"
    }
  }
}

struct OwlRustResourceSQLiteTableRequirement: Equatable, Sendable {
  let table: String
  let columns: Set<String>

  init(table: String, columns: Set<String>) {
    self.table = table
    self.columns = columns
  }
}

struct OwlRustResourceSQLiteRequirement: Equatable, Sendable {
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
struct OwlRustEngineIdentity: Equatable, Sendable {
  let contractVersion: Int
  let capabilities: Set<String>
  let sqliteRequirements: [OwlRustResourceSQLiteRequirement]
}

enum OwlRustResourceVerifier {
  static func verifyGeneration(
    at generationRoot: URL,
    manifest: OwlRustResourceManifest,
    engine: OwlRustEngineIdentity,
    requireCompleteMarker: Bool
  ) throws {
    try manifest.validateDigest()
    try verifyEngineCompatibility(manifest: manifest, engine: engine)

    let manifestURL = generationRoot.appendingPathComponent("manifest.json", isDirectory: false)
    guard let manifestData = try? Data(contentsOf: manifestURL),
          let storedManifest = try? JSONDecoder().decode(OwlRustResourceManifest.self, from: manifestData),
          storedManifest == manifest else {
      throw OwlRustResourceError.generationCorrupt("manifest.json 与期望 manifest 不一致")
    }

    if requireCompleteMarker {
      let markerURL = generationRoot.appendingPathComponent(".complete", isDirectory: false)
      guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
            marker.trimmingCharacters(in: .whitespacesAndNewlines) == manifest.digest else {
        throw OwlRustResourceError.generationCorrupt("完整标记缺失或摘要不符")
      }
    }

    for file in manifest.files {
      let url = try safeFileURL(relativePath: file.path, under: generationRoot)
      try verifyFile(url, expected: file)
    }

    var requirementsByRole: [OwlRustResourceFileRole: [OwlRustResourceSQLiteTableRequirement]] = [:]
    for requirement in engine.sqliteRequirements {
      requirementsByRole[requirement.role, default: []].append(contentsOf: requirement.tables)
    }
    for (role, trustedTables) in requirementsByRole {
      guard let file = manifest.files.first(where: { $0.role == role }) else {
        throw OwlRustResourceError.missingEngineSQLiteFile(role: role)
      }
      let path = try safeFileURL(relativePath: file.path, under: generationRoot).path
      let manifestTables = Set(file.requiredTables ?? [])
      let allManifestTables = manifestTables.union(trustedTables.map(\.table))
      try verifySQLite(
        path: path,
        requiredTables: allManifestTables,
        trustedTableRequirements: trustedTables
      )
    }
    for file in manifest.files where !(file.requiredTables ?? []).isEmpty {
      guard !requirementsByRole.keys.contains(file.role) else { continue }
      let path = try safeFileURL(relativePath: file.path, under: generationRoot).path
      try verifySQLite(
        path: path,
        requiredTables: Set(file.requiredTables ?? []),
        trustedTableRequirements: []
      )
    }
  }

  static func verifyEngineCompatibility(
    manifest: OwlRustResourceManifest,
    engine: OwlRustEngineIdentity
  ) throws {
    let compatibility = manifest.engineCompatibility
    guard (compatibility.minimumContractVersion...compatibility.maximumContractVersion)
      .contains(engine.contractVersion) else {
      throw OwlRustResourceError.incompatibleEngine(
        "engine contract \(engine.contractVersion) 不在 "
          + "\(compatibility.minimumContractVersion)...\(compatibility.maximumContractVersion)"
      )
    }
    let missing = Set(compatibility.requiredCapabilities).subtracting(engine.capabilities).sorted()
    guard missing.isEmpty else {
      throw OwlRustResourceError.incompatibleEngine(
        "缺少 capabilities：\(missing.joined(separator: ", "))"
      )
    }
  }

  static func verifyFile(_ url: URL, expected: OwlRustResourceFile) throws {
    try rejectRedirectedFile(url)
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
      if !FileManager.default.fileExists(atPath: url.path) {
        throw OwlRustResourceError.fileMissing(expected.path)
      }
      throw OwlRustResourceError.fileOperationFailed(
        path: expected.path, message: error.localizedDescription
      )
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw OwlRustResourceError.fileNotRegular(expected.path)
    }
    let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? -1
    guard actualSize == expected.size else {
      throw OwlRustResourceError.fileSizeMismatch(
        path: expected.path, expected: expected.size, actual: actualSize
      )
    }
    let actualDigest = try digestOfFile(url)
    guard actualDigest == expected.digest else {
      throw OwlRustResourceError.fileDigestMismatch(
        path: expected.path, expected: expected.digest, actual: actualDigest
      )
    }
  }

  static func safeFileURL(relativePath: String, under root: URL) throws -> URL {
    try OwlRustResourceManifest.validateRelativePath(relativePath)
    var current = root
    let components = relativePath.split(separator: "/").map(String.init)
    for component in components {
      current.appendPathComponent(component)
      var info = stat()
      guard lstat(current.path, &info) == 0 else {
        throw OwlRustResourceError.fileMissing(relativePath)
      }
      if (info.st_mode & S_IFMT) == S_IFLNK {
        throw OwlRustResourceError.fileNotRegular(relativePath)
      }
    }
    return current
  }

  static func digestOfFile(_ url: URL) throws -> String {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: error.localizedDescription
      )
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 256 * 1024) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func rejectRedirectedFile(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw OwlRustResourceError.fileMissing(url.lastPathComponent)
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw OwlRustResourceError.fileNotRegular(url.lastPathComponent)
    }
  }

  private static func verifySQLite(
    path: String,
    requiredTables: Set<String>,
    trustedTableRequirements: [OwlRustResourceSQLiteTableRequirement]
  ) throws {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
    guard result == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) }
        ?? String(cString: sqlite3_errstr(result))
      if let database { sqlite3_close(database) }
      throw OwlRustResourceError.sqliteOpenFailed(path: path, message: message)
    }
    defer { sqlite3_close(database) }

    guard try sqliteScalar(database, sql: "PRAGMA quick_check") == "ok" else {
      throw OwlRustResourceError.sqliteIntegrityFailed(
        path: path, message: "PRAGMA quick_check 未返回 ok"
      )
    }
    if try sqliteRows(database, sql: "PRAGMA foreign_key_check").next() != nil {
      throw OwlRustResourceError.sqliteIntegrityFailed(
        path: path, message: "PRAGMA foreign_key_check 返回了冲突行"
      )
    }

    var existingTables = Set<String>()
    let tableRows = try sqliteRows(
      database, sql: "SELECT name FROM sqlite_master WHERE type='table'"
    )
    while let row = try tableRows.next() {
      if let name = row.first ?? nil {
        existingTables.insert(name)
      }
    }
    for table in requiredTables.sorted() where !existingTables.contains(table) {
      throw OwlRustResourceError.sqliteSchemaMismatch(
        path: path, message: "缺少表 \(table)"
      )
    }
    for requirement in trustedTableRequirements {
      guard existingTables.contains(requirement.table) else {
        throw OwlRustResourceError.sqliteSchemaMismatch(
          path: path, message: "缺少可信引擎要求的表 \(requirement.table)"
        )
      }
      let escaped = requirement.table.replacingOccurrences(of: "\"", with: "\"\"")
      var columns = Set<String>()
      let columnRows = try sqliteRows(
        database, sql: "PRAGMA table_info(\"\(escaped)\")"
      )
      while let row = try columnRows.next() {
        if row.count > 1, let name = row[1] {
          columns.insert(name)
        }
      }
      let missing = requirement.columns.subtracting(columns).sorted()
      guard missing.isEmpty else {
        throw OwlRustResourceError.sqliteSchemaMismatch(
          path: path,
          message: "表 \(requirement.table) 缺少列 \(missing.joined(separator: ", "))"
        )
      }
    }
  }

  private static func sqliteScalar(_ database: OpaquePointer, sql: String) throws -> String? {
    let rows = try sqliteRows(database, sql: sql)
    return try rows.next()?.first ?? nil
  }

  private static func sqliteRows(
    _ database: OpaquePointer, sql: String
  ) throws -> OwlRustSQLiteRowIterator {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw OwlRustResourceError.sqliteIntegrityFailed(
        path: String(cString: sqlite3_db_filename(database, "main")),
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    return OwlRustSQLiteRowIterator(database: database, statement: statement)
  }
}

private final class OwlRustSQLiteRowIterator {
  private let database: OpaquePointer
  private let statement: OpaquePointer
  private var finished = false

  init(database: OpaquePointer, statement: OpaquePointer) {
    self.database = database
    self.statement = statement
  }

  deinit {
    sqlite3_finalize(statement)
  }

  func next() throws -> [String?]? {
    guard !finished else { return nil }
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE {
      finished = true
      return nil
    }
    guard result == SQLITE_ROW else {
      throw OwlRustResourceError.sqliteIntegrityFailed(
        path: String(cString: sqlite3_db_filename(database, "main")),
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    return (0..<sqlite3_column_count(statement)).map { index in
      guard let text = sqlite3_column_text(statement, index) else { return nil }
      return String(cString: text)
    }
  }
}
