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
    let host = OwlStorageHost(dataDir: userData)
    host.nativeEffect = { operation, args in
      let target = userData.appendingPathComponent(args["name"] as? String ?? "")
      switch operation {
      case "user_native_stage_source_digest": return try OwlRimeUserDBSnapshotReader.scan(syncDirectory: plan.syncDirectory, fileManager: fm).sourceDigest
      case "user_native_stage_kind": return pathKind(target).rawValue
      case "user_native_stage_mkdir":
        do { try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw OwlUserMigrationStageError.fileOperationFailed(path: target.path, reason: error.localizedDescription) }
        return true
      case "user_native_stage_chmod": try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path); return true
      case "user_native_stage_list": return try fm.contentsOfDirectory(atPath: target.path)
      case "user_native_stage_read": return Array(try Data(contentsOf: target))
      case "user_native_stage_remove":
        do { try fm.removeItem(at: target) }
        catch { throw OwlUserMigrationStageError.fileOperationFailed(path: target.path, reason: error.localizedDescription) }
        return true
      case "user_native_stage_write": try writeFile(Data(args["bytes"] as? [UInt8] ?? []), to: target, fm: fm); return true
      case "user_native_stage_sync": try syncDirectory(target); return true
      default: throw OwlAppCore.Failure(code: "unknown_migration_stage_effect")
      }
    }
    struct Reply: Decodable { let disposition: String; let directory: String }
    do {
      let reply: Reply = try host.call("user_migration_stage", ["manifest": OwlAppCore.payload(plan.manifest),
        "manifestData": Array(plan.manifestData), "recordData": Array(plan.recordData)])
      return OwlUserMigrationStageResult(disposition: reply.disposition == "reused" ? .reused : .prepared,
        directory: userData.appendingPathComponent(reply.directory, isDirectory: true), manifest: plan.manifest, recordCount: plan.records.count)
    } catch let failure as OwlAppCore.Failure {
      guard failure.code.hasPrefix("user_stage:"), let data = String(failure.code.dropFirst(11)).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { throw failure }
      let detail = object["detail"] ?? ""
      switch object["code"] {
      case "invalidPlan": throw OwlUserMigrationError.invalidPlan(detail)
      case "sourceChanged": throw OwlUserMigrationStageError.sourceChanged
      case "requestIDCollision": throw OwlUserMigrationStageError.requestIDCollision(detail)
      case "invalidStagingPath": throw OwlUserMigrationStageError.invalidStagingPath(userData.appendingPathComponent(detail).path)
      default: throw failure
      }
    }
  }

  private enum PathKind: String {
    case missing, regularFile, directory, symlink, other
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

}
