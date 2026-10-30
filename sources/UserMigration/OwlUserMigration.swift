import Foundation

struct OwlUserMigrationPin: Codable, Equatable, Sendable {
  let code: String
  let text: String
  let traditional: Bool

  var identity: String { "\(code)\t\(traditional ? 1 : 0)\t\(text)" }
}

struct OwlUserMigrationRecord: Codable, Equatable, Sendable {
  struct Body: Codable, Equatable, Sendable {
    let kind: String
    let code: String
    let word: String
    let weight: Int64
    let userInserted: Bool

    enum CodingKeys: String, CodingKey {
      case kind
      case code
      case word
      case weight
      case userInserted = "user_inserted"
    }
  }

  let type: String
  let deleted: Bool
  let data: Body

  init(kind: String, code: String, word: String, weight: Int64, deleted: Bool) {
    type = "overlay"
    self.deleted = deleted
    data = Body(
      kind: kind,
      code: code,
      word: word,
      weight: weight,
      userInserted: false
    )
  }
}

struct OwlUserMigrationSource: Codable, Equatable, Sendable {
  let path: String
  let installation: String
  let schema: String
  let sha256: String
  let bytes: Int
  let entries: Int
  let metadata: [OwlRimeUserDBMetadata]
}

struct OwlUserMigrationManifest: Codable, Equatable, Sendable {
  static let schemaVersionV1 = 1
  static let mapperVersionV1 = "rime-userdb-v1"

  let schemaVersion: Int
  let mapperVersion: String
  let requestID: String
  let sourceDigest: String
  let recordDigest: String
  let sources: [OwlUserMigrationSource]
  let pins: [OwlUserMigrationPin]
  let issues: [OwlUserMigrationIssue]
  let limitations: [String]
}

struct OwlUserMigrationPlan: Equatable, Sendable {
  let manifest: OwlUserMigrationManifest
  let records: [OwlUserMigrationRecord]
  let recordData: Data
  let manifestData: Data
  let captures: [OwlRimeUserDBSnapshotCapture]
  let syncDirectory: URL
}

enum OwlUserMigrationError: LocalizedError, Equatable {
  case invalidPlan(String)
  case encodingFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidPlan(let reason):
      return "用户数据迁移计划无效：\(reason)"
    case .encodingFailed(let reason):
      return "用户数据迁移计划编码失败：\(reason)"
    }
  }
}

enum OwlUserMigration {
  static let maximumWeight: Int64 = 100_000_000
  static var limitations: [String] {
    OwlAppCore.required(["operation": "user_migration_limitations"])
  }

  static func makePlan(userData: URL, pinnedWordsData: Data?, syncDirectory: URL? = nil,
                       fileManager fm: FileManager = .default) throws -> OwlUserMigrationPlan {
    let sync = syncDirectory ?? userData.appendingPathComponent("sync", isDirectory: true)
    let scan = try OwlRimeUserDBSnapshotReader.scan(syncDirectory: sync, fileManager: fm)
    let captures: [[String: Any]] = scan.captures.map { capture in
      ["installation": capture.installation, "schema": capture.schema, "relativePath": capture.relativePath,
       "bytes": capture.data.count, "sha256": capture.sha256,
       "metadata": OwlAppCore.payload(capture.metadata), "entries": OwlAppCore.payload(capture.entries)]
    }
    struct Reply: Decodable {
      let manifest: OwlUserMigrationManifest
      let records: [OwlUserMigrationRecord]
      let recordData: [UInt8]
      let manifestData: [UInt8]
    }
    var pinsError: String?
    if let pinnedWordsData, !pinnedWordsData.isEmpty {
      do { _ = try JSONDecoder().decode([OwlPinnedWord].self, from: pinnedWordsData) }
      catch { pinsError = error.localizedDescription }
    }
    let reply: Reply = try OwlStorageHost(dataDir: userData).call("user_migration_plan", [
      "scan": ["captures": captures, "issues": OwlAppCore.payload(scan.issues), "sourceDigest": scan.sourceDigest],
      "pins": Array(pinnedWordsData ?? Data()), "pinsError": pinsError as Any? ?? NSNull(),
    ])
    return OwlUserMigrationPlan(manifest: reply.manifest, records: reply.records,
      recordData: Data(reply.recordData), manifestData: Data(reply.manifestData), captures: scan.captures, syncDirectory: sync)
  }
}
