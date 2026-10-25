import Darwin
import Foundation

enum OwlUserMigrationStageDisposition: String, Equatable, Sendable {
  case prepared
  case reused
}

struct OwlUserMigrationStageResult: Equatable, Sendable {
  let disposition: OwlUserMigrationStageDisposition
  let directory: URL
  let manifest: OwlUserMigrationManifest
  let recordCount: Int
}

enum OwlUserMigrationStageError: LocalizedError, Equatable {
  case sourceChanged
  case requestIDCollision(String)
  case invalidStagingPath(String)
  case fileOperationFailed(path: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .sourceChanged:
      return "迁移期间源词库快照发生变化，本次未留下迁移暂存"
    case .requestIDCollision(let requestID):
      return "迁移暂存 \(requestID) 已存在但内容不同，拒绝覆盖"
    case .invalidStagingPath(let path):
      return "迁移暂存路径不安全：\(path)"
    case .fileOperationFailed(let path, let reason):
      return "迁移暂存写入 \(path) 失败：\(reason)"
    }
  }
}

/// Stages a deterministic, complete migration before any Rust dictionary call is made.
///
/// Nothing here opens the user journal. A retry with the same source bytes and pins reuses
/// the same bytes; a complete directory with a colliding request ID is never overwritten.
enum OwlUserMigrationStage {
  static let rootName = ".owl-user-migration"
  static let manifestName = "manifest.json"
  static let recordsName = "dictionary-state.ndjson"
  static let preparedName = ".prepared"
  static let marker = Data("owlrime-user-migration-v1\n".utf8)

  static func prepare(
    _ plan: OwlUserMigrationPlan,
    in userData: URL,
    fileManager fm: FileManager = .default
  ) throws -> OwlUserMigrationStageResult {
    guard plan.manifest.schemaVersion == OwlUserMigrationManifest.schemaVersionV1,
          plan.manifest.mapperVersion == OwlUserMigrationManifest.mapperVersionV1,
          plan.manifest.requestID.range(of: #"^owlrime-migrate-[0-9a-f]{64}$"#,
                                        options: .regularExpression) != nil,
          plan.manifest.recordDigest == OwlUserMigrationDigest.sha256(plan.recordData) else {
      throw OwlUserMigrationError.invalidPlan("manifest 版本、requestID 或 recordDigest 不匹配")
    }

    let before = try OwlRimeUserDBSnapshotReader.scan(root: userData, fileManager: fm)
    guard before.sourceDigest == plan.manifest.sourceDigest else {
      throw OwlUserMigrationStageError.sourceChanged
    }

    let migrationRoot = userData.appendingPathComponent(rootName, isDirectory: true)
    try preparePrivateRoot(migrationRoot, fileManager: fm)
    let destination = migrationRoot.appendingPathComponent(
      plan.manifest.requestID,
      isDirectory: true
    )

    if pathKind(destination) != .missing {
      switch inspectExisting(destination, plan: plan, fileManager: fm) {
      case .reused:
        guard try sourceDigestUnchanged(userData, expected: plan.manifest.sourceDigest, fm: fm) else {
          throw OwlUserMigrationStageError.sourceChanged
        }
        return result(.reused, destination, plan)
      case .collision:
        throw OwlUserMigrationStageError.requestIDCollision(plan.manifest.requestID)
      case .incomplete:
        try removeIncomplete(destination, fileManager: fm)
      }
    }

    var ownsDestination = false
    do {
      try createDirectoryExclusive(destination, fileManager: fm)
      ownsDestination = true
      try writeFile(plan.manifestData, to: destination.appendingPathComponent(manifestName), fm: fm)
      try writeFile(plan.recordData, to: destination.appendingPathComponent(recordsName), fm: fm)
      try writeFile(marker, to: destination.appendingPathComponent(preparedName), fm: fm)
      try syncDirectory(destination)
      try syncDirectory(migrationRoot)

      guard try sourceDigestUnchanged(
        userData,
        expected: plan.manifest.sourceDigest,
        fm: fm
      ) else {
        throw OwlUserMigrationStageError.sourceChanged
      }
      return result(.prepared, destination, plan)
    } catch {
      if ownsDestination {
        try? fm.removeItem(at: destination)
      }
      throw error
    }
  }

  private enum Existing {
    case reused
    case collision
    case incomplete
  }

  private enum PathKind {
    case missing
    case regularFile
    case directory
    case symlink
    case other
  }

  private static func inspectExisting(
    _ directory: URL,
    plan: OwlUserMigrationPlan,
    fileManager fm: FileManager
  ) -> Existing {
    guard pathKind(directory) == .directory else { return .collision }
    guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
      return .collision
    }
    let expectedNames = [manifestName, recordsName, preparedName]
    let requiredPresent = expectedNames.allSatisfy(names.contains)
    guard requiredPresent else { return .incomplete }
    guard Set(names) == Set(expectedNames) else { return .collision }

    let manifest = directory.appendingPathComponent(manifestName)
    let records = directory.appendingPathComponent(recordsName)
    let markerURL = directory.appendingPathComponent(preparedName)
    guard pathKind(manifest) == .regularFile,
          pathKind(records) == .regularFile,
          pathKind(markerURL) == .regularFile,
          (try? Data(contentsOf: manifest)) == plan.manifestData,
          (try? Data(contentsOf: records)) == plan.recordData,
          (try? Data(contentsOf: markerURL)) == marker else {
      return .collision
    }
    return .reused
  }

  private static func preparePrivateRoot(_ directory: URL, fileManager fm: FileManager) throws {
    switch pathKind(directory) {
    case .missing:
      do {
        try fm.createDirectory(
          at: directory,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw OwlUserMigrationStageError.fileOperationFailed(
          path: directory.path,
          reason: error.localizedDescription
        )
      }
    case .directory:
      do {
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      } catch {
        throw OwlUserMigrationStageError.fileOperationFailed(
          path: directory.path,
          reason: error.localizedDescription
        )
      }
    case .symlink, .regularFile, .other:
      throw OwlUserMigrationStageError.invalidStagingPath(directory.path)
    }
  }

  private static func removeIncomplete(_ directory: URL, fileManager fm: FileManager) throws {
    guard pathKind(directory) == .directory else {
      throw OwlUserMigrationStageError.invalidStagingPath(directory.path)
    }
    do {
      try fm.removeItem(at: directory)
    } catch {
      throw OwlUserMigrationStageError.fileOperationFailed(
        path: directory.path,
        reason: error.localizedDescription
      )
    }
  }

  private static func createDirectoryExclusive(
    _ directory: URL,
    fileManager fm: FileManager
  ) throws {
    do {
      try fm.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      if pathKind(directory) != .missing {
        throw OwlUserMigrationStageError.requestIDCollision(directory.lastPathComponent)
      }
      throw OwlUserMigrationStageError.fileOperationFailed(
        path: directory.path,
        reason: error.localizedDescription
      )
    }
  }

  private static func writeFile(_ data: Data, to url: URL, fm: FileManager) throws {
    do {
      try data.write(to: url, options: [.atomic])
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.synchronize()
    } catch {
      throw OwlUserMigrationStageError.fileOperationFailed(
        path: url.path,
        reason: error.localizedDescription
      )
    }
  }

  private static func sourceDigestUnchanged(
    _ userData: URL,
    expected: String,
    fm: FileManager
  ) throws -> Bool {
    try OwlRimeUserDBSnapshotReader.scan(root: userData, fileManager: fm).sourceDigest == expected
  }

  private static func syncDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw OwlUserMigrationStageError.fileOperationFailed(
        path: directory.path,
        reason: String(cString: strerror(errno))
      )
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw OwlUserMigrationStageError.fileOperationFailed(
        path: directory.path,
        reason: String(cString: strerror(errno))
      )
    }
  }

  private static func pathKind(_ url: URL) -> PathKind {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      return errno == ENOENT ? .missing : .other
    }
    switch info.st_mode & S_IFMT {
    case S_IFREG: return .regularFile
    case S_IFDIR: return .directory
    case S_IFLNK: return .symlink
    default: return .other
    }
  }

  private static func result(
    _ disposition: OwlUserMigrationStageDisposition,
    _ directory: URL,
    _ plan: OwlUserMigrationPlan
  ) -> OwlUserMigrationStageResult {
    OwlUserMigrationStageResult(
      disposition: disposition,
      directory: directory,
      manifest: plan.manifest,
      recordCount: plan.records.count
    )
  }
}
