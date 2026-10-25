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
  static let limitations = [
    "Rime commits 与 Rust weight 不是同一计量；本次按 commits 取舍并映射，weight 限制在 1...100000000。",
    "Rime decay 与 tick 未导入 Rust dictionary-state，不能声称保留了全部统计内部状态。",
    "Rime 负 commits 转成 Rust 删除记录，保留删除结果但不保留原负值。",
    "Rime 快照不区分用户自造词与学习调权；本次全部按 user_inserted=false 的学习 overlay 迁移，自造词的个人词库队列语义未保留。",
    "旧置顶继续由 owl_pinned_words 保存；pinned_candidates 每个上下文只能保存一个值，不能无损替代简繁标记和顺序。",
    "只读取 sync/<installation>/*.userdb.txt；不读取运行中的 LevelDB。",
  ]

  static func makePlan(
    userData: URL,
    pinnedWordsData: Data?,
    fileManager fm: FileManager = .default
  ) throws -> OwlUserMigrationPlan {
    let scan = try OwlRimeUserDBSnapshotReader.scan(root: userData, fileManager: fm)
    var issues = scan.issues
    let pins = decodePins(pinnedWordsData, issues: &issues)
    var mapped: [RecordKey: (record: OwlUserMigrationRecord, commits: Int64)] = [:]

    for capture in scan.captures {
      guard let kind = dictionaryKind(schema: capture.schema) else {
        issues.append(OwlUserMigrationIssue(
          code: .unsupportedSchema,
          source: capture.relativePath,
          line: nil,
          count: capture.entries.count,
          message: "方案 \(capture.schema) 没有已确认的 Rust 词库映射，跳过全部记录"
        ))
        continue
      }

      for entry in capture.entries {
        guard let code = normalizedCode(entry.code, kind: kind) else {
          issues.append(issue(
            .invalidEntry,
            capture.relativePath,
            entry.line,
            "编码去掉 Rime 分隔空格后为空或超过 512 字节"
          ))
          continue
        }
        let key = RecordKey(kind: kind, code: code, word: entry.phrase)
        let record = OwlUserMigrationRecord(
          kind: kind,
          code: code,
          word: entry.phrase,
          weight: mappedWeight(commits: entry.commits),
          deleted: entry.commits < 0
        )
        if let previous = mapped[key] {
          issues.append(OwlUserMigrationIssue(
            code: .coalescedEntry,
            source: capture.relativePath,
            line: entry.line,
            count: 2,
            message: "同一目标词条重复，按 commits 取大：\(previous.commits) 与 \(entry.commits)"
          ))
          if entry.commits > previous.commits {
            mapped[key] = (record, entry.commits)
          }
        } else {
          mapped[key] = (record, entry.commits)
        }
      }
    }

    let records = mapped.values
      .map(\.record)
      .sorted(by: recordOrder)
    let recordData = try encodeRecords(records)
    let recordDigest = OwlUserMigrationDigest.sha256(recordData)
    let sources = scan.captures.map {
      OwlUserMigrationSource(
        path: $0.relativePath,
        installation: $0.installation,
        schema: $0.schema,
        sha256: $0.sha256,
        bytes: $0.data.count,
        entries: $0.entries.count,
        metadata: $0.metadata
      )
    }
    let requestID = try makeRequestID(
      sourceDigest: scan.sourceDigest,
      recordDigest: recordDigest,
      pins: pins,
      issues: issues
    )
    let manifest = OwlUserMigrationManifest(
      schemaVersion: OwlUserMigrationManifest.schemaVersionV1,
      mapperVersion: OwlUserMigrationManifest.mapperVersionV1,
      requestID: requestID,
      sourceDigest: scan.sourceDigest,
      recordDigest: recordDigest,
      sources: sources,
      pins: pins,
      issues: issues,
      limitations: limitations
    )
    let manifestData = try encodeManifest(manifest)
    return OwlUserMigrationPlan(
      manifest: manifest,
      records: records,
      recordData: recordData,
      manifestData: manifestData,
      captures: scan.captures
    )
  }

  private struct RecordKey: Hashable {
    let kind: String
    let code: String
    let word: String
  }

  private struct RequestKey: Codable {
    let schemaVersion: Int
    let mapperVersion: String
    let sourceDigest: String
    let recordDigest: String
    let pins: [OwlUserMigrationPin]
    let issues: [OwlUserMigrationIssue]
  }

  private static func makeRequestID(
    sourceDigest: String,
    recordDigest: String,
    pins: [OwlUserMigrationPin],
    issues: [OwlUserMigrationIssue]
  ) throws -> String {
    let key = RequestKey(
      schemaVersion: OwlUserMigrationManifest.schemaVersionV1,
      mapperVersion: OwlUserMigrationManifest.mapperVersionV1,
      sourceDigest: sourceDigest,
      recordDigest: recordDigest,
      pins: pins,
      issues: issues
    )
    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      data = try encoder.encode(key)
    } catch {
      throw OwlUserMigrationError.encodingFailed(error.localizedDescription)
    }
    return "owlrime-migrate-\(OwlUserMigrationDigest.sha256(data))"
  }

  private static func dictionaryKind(schema: String) -> String? {
    if schema == "rime_ice" || schema == "terra_pinyin" || schema.hasPrefix("luna_pinyin") {
      return "pinyin"
    }
    if schema.hasPrefix("wubi98") { return "wubi98" }
    if schema.hasPrefix("wubi86") { return "wubi" }
    return nil
  }

  /// librime stores a structural trailing space after the code. Its pinyin syllable
  /// separators are spaces in the TSV; Rust's dictionary key uses apostrophes.
  private static func normalizedCode(_ raw: String, kind: String) -> String? {
    let trailingTrimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trailingTrimmed.isEmpty else { return nil }
    let value: String
    if kind == "pinyin" {
      value = trailingTrimmed
        .split(whereSeparator: { $0 == " " || $0 == "'" })
        .map(String.init)
        .joined(separator: "'")
    } else {
      value = trailingTrimmed
    }
    guard !value.isEmpty, value.utf8.count <= 512 else { return nil }
    return value
  }

  private static func mappedWeight(commits: Int64) -> Int64 {
    guard commits >= 0 else { return 0 }
    return min(max(commits, 1), maximumWeight)
  }

  private static func decodePins(
    _ data: Data?,
    issues: inout [OwlUserMigrationIssue]
  ) -> [OwlUserMigrationPin] {
    guard let data, !data.isEmpty else { return [] }
    let legacy: [OwlPinnedWord]
    do {
      legacy = try JSONDecoder().decode([OwlPinnedWord].self, from: data)
    } catch {
      issues.append(OwlUserMigrationIssue(
        code: .invalidPinnedWords,
        source: "owl_pinned_words",
        line: nil,
        count: nil,
        message: "旧置顶 JSON 无法解码：\(error.localizedDescription)"
      ))
      return []
    }

    var seen = Set<String>()
    var pins: [OwlUserMigrationPin] = []
    for word in legacy {
      guard !word.code.isEmpty, !word.text.isEmpty,
            !word.code.contains("\t"), !word.code.contains("\n"), !word.code.contains("\r"),
            !word.text.contains("\t"), !word.text.contains("\n"), !word.text.contains("\r") else {
        issues.append(OwlUserMigrationIssue(
          code: .invalidPinnedWord,
          source: "owl_pinned_words",
          line: nil,
          count: nil,
          message: "有一条置顶含空字段或会破坏引擎属性格式的控制字符，未迁移"
        ))
        continue
      }
      let pin = OwlUserMigrationPin(
        code: word.code,
        text: word.text,
        traditional: word.traditional
      )
      guard seen.insert(pin.identity).inserted else {
        issues.append(OwlUserMigrationIssue(
          code: .coalescedPin,
          source: "owl_pinned_words",
          line: nil,
          count: 2,
          message: "重复置顶已按原有先后顺序合并"
        ))
        continue
      }
      pins.append(pin)
    }
    return pins
  }

  private static func encodeRecords(_ records: [OwlUserMigrationRecord]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      var data = Data()
      for record in records {
        data.append(try encoder.encode(record))
        data.append(0x0A)
      }
      return data
    } catch {
      throw OwlUserMigrationError.encodingFailed(error.localizedDescription)
    }
  }

  private static func encodeManifest(_ manifest: OwlUserMigrationManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      var data = try encoder.encode(manifest)
      data.append(0x0A)
      return data
    } catch {
      throw OwlUserMigrationError.encodingFailed(error.localizedDescription)
    }
  }

  private static func recordOrder(
    _ left: OwlUserMigrationRecord,
    _ right: OwlUserMigrationRecord
  ) -> Bool {
    let leftKind = kindOrder(left.data.kind)
    let rightKind = kindOrder(right.data.kind)
    if leftKind != rightKind { return leftKind < rightKind }
    if left.data.code != right.data.code { return left.data.code < right.data.code }
    return left.data.word < right.data.word
  }

  private static func kindOrder(_ kind: String) -> Int {
    switch kind {
    case "pinyin": return 0
    case "wubi": return 1
    case "wubi98": return 2
    default: return 3
    }
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
}
