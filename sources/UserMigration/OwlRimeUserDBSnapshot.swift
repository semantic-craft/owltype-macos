import Darwin
import Foundation

enum OwlUserMigrationIssueCode: String, Codable, Equatable, Sendable {
  case sourceSymlink
  case sourceNotRegularFile
  case sourceTooLarge
  case sourceUnreadable
  case sourceNotUTF8
  case invalidMetadata
  case invalidEntry
  case invalidValue
  case recordLimit
  case unsupportedSchema
  case coalescedEntry
  case invalidPinnedWords
  case invalidPinnedWord
  case coalescedPin
}

struct OwlUserMigrationIssue: Codable, Equatable, Sendable {
  let code: OwlUserMigrationIssueCode
  let source: String?
  let line: Int?
  let count: Int?
  let message: String
}

struct OwlRimeUserDBMetadata: Codable, Equatable, Sendable {
  let key: String
  let value: String
}

struct OwlRimeUserDBEntry: Codable, Equatable, Sendable {
  let code: String
  let phrase: String
  let commits: Int64
  let decay: Double
  let tick: UInt64
  let line: Int
}

struct OwlRimeUserDBSnapshotCapture: Codable, Equatable, Sendable {
  let installation: String
  let schema: String
  let relativePath: String
  let data: Data
  let sha256: String
  let metadata: [OwlRimeUserDBMetadata]
  let entries: [OwlRimeUserDBEntry]
}

struct OwlRimeUserDBSnapshotScan: Codable, Equatable, Sendable {
  let captures: [OwlRimeUserDBSnapshotCapture]
  let issues: [OwlUserMigrationIssue]
  let sourceDigest: String
}

enum OwlRimeUserDBSnapshotError: LocalizedError, Equatable {
  case directoryUnreadable(path: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .directoryUnreadable(let path, let reason):
      return "无法读取 \(path)：\(reason)"
    }
  }
}

/// Reads only librime's stable `sync/<installation>/*.userdb.txt` snapshots.
///
/// The LevelDB directories are deliberately outside this reader: they can be locked by the
/// running input method, and copying them is not a stable export. Both the source bytes and
/// the mapping result are retained so staging can prove that the files did not change.
enum OwlRimeUserDBSnapshotReader {
  static let suffix = ".userdb.txt"
  static let maximumFileBytes = 64 * 1024 * 1024
  static let maximumLineBytes = 64 * 1024
  static let maximumRecordsPerSnapshot = 500_000
  private static let digestDomain = Data("owlrime-userdb-source-v1".utf8)

  static func scan(
    root: URL,
    fileManager fm: FileManager = .default
  ) throws -> OwlRimeUserDBSnapshotScan {
    try scan(
      syncDirectory: root.appendingPathComponent("sync", isDirectory: true),
      fileManager: fm
    )
  }

  /// Scans a resolved sync root. Manifest paths stay relative to the stable logical
  /// `sync/<installation>/` layout even when `installation.yaml` points elsewhere.
  static func scan(
    syncDirectory: URL,
    fileManager fm: FileManager = .default
  ) throws -> OwlRimeUserDBSnapshotScan {
    let host = OwlStorageHost(dataDir: syncDirectory)
    host.nativeEffect = { operation, args in
      let name = args["name"] as? String ?? ""
      let url = name.isEmpty ? syncDirectory : syncDirectory.appendingPathComponent(name)
      switch operation {
      case "user_native_scan_kind":
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? "missing" : "other" }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return "regularFile"
        case S_IFDIR: return "directory"
        case S_IFLNK: return "symlink"
        default: return "other"
        }
      case "user_native_scan_list":
        do { return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]).map(\.lastPathComponent).sorted() }
        catch { throw OwlRimeUserDBSnapshotError.directoryUnreadable(path: url.path, reason: error.localizedDescription) }
      case "user_native_scan_size":
        do { return ["value": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0] }
        catch { return ["error": error.localizedDescription] }
      case "user_native_scan_read":
        do { return ["value": try Data(contentsOf: url, options: [.mappedIfSafe]).base64EncodedString()] }
        catch { return ["error": error.localizedDescription] }
      default: throw OwlAppCore.Failure(code: "unknown_snapshot_effect")
      }
    }
    return try host.call("user_migration_scan")
  }
}
