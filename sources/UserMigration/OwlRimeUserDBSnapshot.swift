import CryptoKit
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

struct OwlRimeUserDBEntry: Equatable, Sendable {
  let code: String
  let phrase: String
  let commits: Int64
  let decay: Double
  let tick: UInt64
  let line: Int
}

struct OwlRimeUserDBSnapshotCapture: Equatable, Sendable {
  let installation: String
  let schema: String
  let relativePath: String
  let data: Data
  let sha256: String
  let metadata: [OwlRimeUserDBMetadata]
  let entries: [OwlRimeUserDBEntry]
}

struct OwlRimeUserDBSnapshotScan: Equatable, Sendable {
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
    let sync = root.appendingPathComponent("sync", isDirectory: true)
    guard pathKind(sync) != .missing else {
      return OwlRimeUserDBSnapshotScan(
        captures: [],
        issues: [],
        sourceDigest: OwlUserMigrationDigest.hash(domain: digestDomain, pieces: [])
      )
    }
    guard pathKind(sync) == .directory else {
      let issue = OwlUserMigrationIssue(
        code: pathKind(sync) == .symlink ? .sourceSymlink : .sourceNotRegularFile,
        source: "sync",
        line: nil,
        count: nil,
        message: "sync 必须是普通目录，未跟随该路径"
      )
      return OwlRimeUserDBSnapshotScan(
        captures: [],
        issues: [issue],
        sourceDigest: digest(for: [("sync", "rejected:\(issue.code.rawValue)")])
      )
    }

    let installations = try directoryEntries(at: sync, fileManager: fm)
    var captures: [OwlRimeUserDBSnapshotCapture] = []
    var issues: [OwlUserMigrationIssue] = []
    var identities: [(path: String, identity: String)] = []

    for installationURL in installations {
      let installation = installationURL.lastPathComponent
      let relativeInstallation = "sync/\(installation)"
      guard pathKind(installationURL) == .directory else {
        let kind = pathKind(installationURL)
        let issue = OwlUserMigrationIssue(
          code: kind == .symlink ? .sourceSymlink : .sourceNotRegularFile,
          source: relativeInstallation,
          line: nil,
          count: nil,
          message: "安装目录不是普通目录，未读取"
        )
        issues.append(issue)
        identities.append((relativeInstallation, "rejected:\(issue.code.rawValue)"))
        continue
      }

      let snapshots = try directoryEntries(at: installationURL, fileManager: fm)
        .filter { $0.lastPathComponent.hasSuffix(suffix) }
      for snapshotURL in snapshots {
        let filename = snapshotURL.lastPathComponent
        let relativePath = "\(relativeInstallation)/\(filename)"
        let kind = pathKind(snapshotURL)
        if kind == .symlink || kind != .regularFile {
          let issue = OwlUserMigrationIssue(
            code: kind == .symlink ? .sourceSymlink : .sourceNotRegularFile,
            source: relativePath,
            line: nil,
            count: nil,
            message: "同步快照不是普通文件，未读取"
          )
          issues.append(issue)
          identities.append((relativePath, "rejected:\(issue.code.rawValue)"))
          continue
        }

        let size: Int
        do {
          size = try snapshotURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
          let issue = OwlUserMigrationIssue(
            code: .sourceUnreadable,
            source: relativePath,
            line: nil,
            count: nil,
            message: error.localizedDescription
          )
          issues.append(issue)
          identities.append((relativePath, "rejected:unreadable"))
          continue
        }
        guard size <= maximumFileBytes else {
          let issue = OwlUserMigrationIssue(
            code: .sourceTooLarge,
            source: relativePath,
            line: nil,
            count: nil,
            message: "快照 \(size) 字节，超过 \(maximumFileBytes) 字节上限"
          )
          issues.append(issue)
          identities.append((relativePath, "rejected:size:\(size)"))
          continue
        }

        let data: Data
        do {
          data = try Data(contentsOf: snapshotURL, options: [.mappedIfSafe])
        } catch {
          let issue = OwlUserMigrationIssue(
            code: .sourceUnreadable,
            source: relativePath,
            line: nil,
            count: nil,
            message: error.localizedDescription
          )
          issues.append(issue)
          identities.append((relativePath, "rejected:unreadable"))
          continue
        }
        let sha256 = OwlUserMigrationDigest.sha256(data)
        identities.append((relativePath, "sha256:\(sha256)"))
        guard var text = String(data: data, encoding: .utf8) else {
          issues.append(OwlUserMigrationIssue(
            code: .sourceNotUTF8,
            source: relativePath,
            line: nil,
            count: nil,
            message: "同步快照不是 UTF-8，未解析"
          ))
          continue
        }
        if text.unicodeScalars.first?.value == 0xFEFF {
          text = String(text.dropFirst())
        }

        let parsed = parse(
          text,
          installation: installation,
          schema: String(filename.dropLast(suffix.count)),
          relativePath: relativePath
        )
        issues.append(contentsOf: parsed.issues)
        captures.append(OwlRimeUserDBSnapshotCapture(
          installation: installation,
          schema: String(filename.dropLast(suffix.count)),
          relativePath: relativePath,
          data: data,
          sha256: sha256,
          metadata: parsed.metadata,
          entries: parsed.entries
        ))
      }
    }

    captures.sort { $0.relativePath < $1.relativePath }
    issues.sort(by: issueOrder)
    return OwlRimeUserDBSnapshotScan(
      captures: captures,
      issues: issues,
      sourceDigest: digest(for: identities)
    )
  }

  private enum PathKind {
    case missing
    case regularFile
    case directory
    case symlink
    case other
  }

  private static func parse(
    _ text: String,
    installation: String,
    schema: String,
    relativePath: String
  ) -> (
    metadata: [OwlRimeUserDBMetadata],
    entries: [OwlRimeUserDBEntry],
    issues: [OwlUserMigrationIssue]
  ) {
    var metadata: [OwlRimeUserDBMetadata] = []
    var entries: [OwlRimeUserDBEntry] = []
    var issues: [OwlUserMigrationIssue] = []
    var commentsEnabled = true

    for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
      let lineNumber = offset + 1
      if rawLine.utf8.count > maximumLineBytes {
        issues.append(issue(
          .invalidEntry,
          relativePath,
          lineNumber,
          "单行超过 \(maximumLineBytes) 字节"
        ))
        continue
      }
      let line = trimTrailingWhitespace(rawLine)
      if line.isEmpty { continue }
      if commentsEnabled && line.hasPrefix("#") {
        if line.hasPrefix("#@") {
          let fields = String(line.dropFirst(2)).components(separatedBy: "\t")
          if fields.count == 2 {
            metadata.append(OwlRimeUserDBMetadata(key: fields[0], value: fields[1]))
          } else {
            issues.append(issue(
              .invalidMetadata,
              relativePath,
              lineNumber,
              "元数据必须恰有一个制表符"
            ))
          }
        } else if line == "# no comment" {
          commentsEnabled = false
        }
        continue
      }

      guard entries.count < maximumRecordsPerSnapshot else {
        if !issues.contains(where: {
          $0.code == .recordLimit && $0.source == relativePath
        }) {
          issues.append(issue(
            .recordLimit,
            relativePath,
            lineNumber,
            "每个快照最多读取 \(maximumRecordsPerSnapshot) 条记录，其余记录未迁移"
          ))
        }
        continue
      }
      guard let entry = parseEntry(line, lineNumber: lineNumber) else {
        issues.append(issue(
          .invalidEntry,
          relativePath,
          lineNumber,
          "记录必须是 code、phrase、c/d/t 三列"
        ))
        continue
      }
      entries.append(entry)
    }

    _ = installation
    _ = schema
    return (metadata, entries, issues)
  }

  private static func parseEntry(_ line: String, lineNumber: Int) -> OwlRimeUserDBEntry? {
    let fields = line.components(separatedBy: "\t")
    guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
    guard fields[0].utf8.count <= 512, fields[1].utf8.count <= 4096 else { return nil }

    var commits: Int64?
    var decay: Double?
    var tick: UInt64?
    for token in fields[2].split(separator: " ", omittingEmptySubsequences: true) {
      guard let equals = token.firstIndex(of: "=") else { return nil }
      let key = token[..<equals]
      let value = token[token.index(after: equals)...]
      switch key {
      case "c":
        guard commits == nil, let parsed = Int64(value) else { return nil }
        commits = parsed
      case "d":
        guard decay == nil, let parsed = Double(value), parsed.isFinite else { return nil }
        decay = parsed
      case "t":
        guard tick == nil, let parsed = UInt64(value) else { return nil }
        tick = parsed
      default:
        return nil
      }
    }
    guard let commits, let decay, let tick else { return nil }
    return OwlRimeUserDBEntry(
      code: fields[0],
      phrase: fields[1],
      commits: commits,
      decay: decay,
      tick: tick,
      line: lineNumber
    )
  }

  private static func directoryEntries(at directory: URL, fileManager fm: FileManager) throws -> [URL] {
    do {
      return try fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
      ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      throw OwlRimeUserDBSnapshotError.directoryUnreadable(
        path: directory.path,
        reason: error.localizedDescription
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

  private static func trimTrailingWhitespace(_ value: String) -> String {
    var end = value.endIndex
    while end > value.startIndex {
      let previous = value.index(before: end)
      guard value[previous].isWhitespace else { break }
      end = previous
    }
    return String(value[..<end])
  }

  private static func digest(for identities: [(path: String, identity: String)]) -> String {
    let pieces = identities
      .sorted { $0.path < $1.path }
      .flatMap { [Data($0.path.utf8), Data($0.identity.utf8)] }
    return OwlUserMigrationDigest.hash(domain: digestDomain, pieces: pieces)
  }

  private static func issue(
    _ code: OwlUserMigrationIssueCode,
    _ source: String,
    _ line: Int?,
    _ message: String
  ) -> OwlUserMigrationIssue {
    OwlUserMigrationIssue(
      code: code,
      source: source,
      line: line,
      count: nil,
      message: message
    )
  }

  private static func issueOrder(
    _ left: OwlUserMigrationIssue,
    _ right: OwlUserMigrationIssue
  ) -> Bool {
    if left.source != right.source {
      return (left.source ?? "") < (right.source ?? "")
    }
    return (left.line ?? 0) < (right.line ?? 0)
  }
}

enum OwlUserMigrationDigest {
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Length-prefixes every piece so adjacent paths and values cannot form the same stream.
  static func hash(domain: Data, pieces: [Data]) -> String {
    var hasher = SHA256()
    hasher.update(data: domain)
    for piece in pieces {
      var length = UInt64(piece.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
      hasher.update(data: piece)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
