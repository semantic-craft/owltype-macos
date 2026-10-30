import AppKit
import Foundation

struct OwlUserMigrationImportReport: Codable, Equatable, Sendable {
  let ok: Bool
  let error: String?
  let requestID: String?
  let sourceCount: Int
  let issueCount: Int
  let recordCount: Int
  let entriesWritten: Int
  let positionsWritten: Int
  let selectionsWritten: Int
  let recordsKept: Int
  let recordsSkipped: Int
  let userWordsPreserved: Int
  let pinsTotal: Int
  let pinsWritten: Int
  let pinsKept: Int
  let pinsExternalOnly: Int
  let habitsTrimmed: Int
  let warnings: [String]

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case requestID = "request_id"
    case sourceCount = "source_count"
    case issueCount = "issue_count"
    case recordCount = "record_count"
    case entriesWritten = "entries_written"
    case positionsWritten = "positions_written"
    case selectionsWritten = "selections_written"
    case recordsKept = "records_kept"
    case recordsSkipped = "records_skipped"
    case userWordsPreserved = "user_words_preserved"
    case pinsTotal = "pins_total"
    case pinsWritten = "pins_written"
    case pinsKept = "pins_kept"
    case pinsExternalOnly = "pins_external_only"
    case habitsTrimmed = "habits_trimmed"
    case warnings
  }
}

struct OwlUserMigrationImportOutcome: Equatable, Sendable {
  let report: OwlUserMigrationImportReport
  let generation: OwlRustResourceGeneration
  let warnings: [String]
}

enum OwlUserMigrationImportError: LocalizedError, Equatable {
  case bundledResourcesUnavailable
  case runtimeDirectoryFailed(path: String, reason: String)
  case missingReport
  case invalidReport(String)
  case rejected(String)

  var errorDescription: String? {
    switch self {
    case .bundledResourcesUnavailable:
      return "找不到随包 Rust 词库资源"
    case .runtimeDirectoryFailed(let path, let reason):
      return "准备迁移运行目录失败（\(path)）：\(reason)"
    case .missingReport:
      return "Rust 迁移没有返回报告"
    case .invalidReport(let reason):
      return "Rust 迁移报告无效：\(reason)"
    case .rejected(let reason):
      return "Rust 迁移失败：\(reason)"
    }
  }
}

/// Calls the Rust importer over the exact generation the live engine resolves.
///
/// The caller must shut down every session using `userRoot` first. This type validates
/// the FFI boundary and paths; transactional database rollback remains in Rust.
enum OwlUserMigrationImport {
  static func run(
    _ staged: OwlUserMigrationStageResult,
    userRoot: URL = OwlApp.userDir,
    sharedSupportURL: URL? = Bundle.main.sharedSupportURL,
    fileManager fm: FileManager = .default
  ) throws -> OwlUserMigrationImportOutcome {
    let host = OwlStorageHost(dataDir: userRoot)
    host.nativeEffect = { operation, args in
      let path = args["path"] as? String ?? ""
      switch operation {
      case "user_native_import_active":
        do {
          let generation = try OwlRustResourceEnvironment.production(userRoot: userRoot).activeGeneration()
          return ["generation": generation.map { ["resourcesPath": $0.resourcesURL.path, "contentID": $0.contentID] } as Any? ?? NSNull()]
        } catch { return ["error": error.localizedDescription] }
      case "user_native_import_digest": return try OwlRustEngine.contentDigest(of: URL(fileURLWithPath: path))
      case "user_native_import_mkdir":
        do { try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw OwlUserMigrationImportError.runtimeDirectoryFailed(path: path, reason: error.localizedDescription) }
        return true
      case "user_native_import_is_directory":
        var directory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
      case "user_native_import_prepare":
        try prepareGeneration(resourcesRoot: URL(fileURLWithPath: args["resources"] as? String ?? ""),
          rustUserRoot: URL(fileURLWithPath: args["user"] as? String ?? ""), cacheRoot: URL(fileURLWithPath: args["cache"] as? String ?? ""),
          contentID: args["contentID"] as? String ?? "")
        return true
      case "user_native_import_report":
        let raw = (args["resources"] as? String ?? "").withCString { resources in
          (args["user"] as? String ?? "").withCString { user in
            (args["cache"] as? String ?? "").withCString { cache in
              (args["dictionaries"] as? String ?? "").withCString { dictionaries in
                (args["requestID"] as? String ?? "").withCString { request in
                  owl_msime_user_migration_import(resources, user, cache, dictionaries, request)
                }
              }
            }
          }
        }
        guard let raw else { throw OwlUserMigrationImportError.missingReport }
        defer { owl_msime_string_free(raw) }
        do {
          let report = try JSONDecoder().decode(OwlUserMigrationImportReport.self, from: Data(String(cString: raw).utf8))
          return OwlAppCore.payload(report)
        } catch { throw OwlUserMigrationImportError.invalidReport(error.localizedDescription) }
      default: throw OwlAppCore.Failure(code: "unknown_import_effect")
      }
    }
    struct Reply: Decodable {
      struct Generation: Decodable { let resourcesPath: String; let contentID: String }
      let report: OwlUserMigrationImportReport
      let generation: Generation
      let warnings: [String]
    }
    do {
      let reply: Reply = try host.call("user_migration_import", ["manifest": OwlAppCore.payload(staged.manifest),
        "recordCount": staged.recordCount, "userRoot": userRoot.path, "sharedSupport": sharedSupportURL?.path as Any? ?? NSNull()])
      return OwlUserMigrationImportOutcome(report: reply.report,
        generation: OwlRustResourceGeneration(resourcesURL: URL(fileURLWithPath: reply.generation.resourcesPath, isDirectory: true), contentID: reply.generation.contentID), warnings: reply.warnings)
    } catch let failure as OwlAppCore.Failure {
      guard failure.code.hasPrefix("user_import:"), let data = String(failure.code.dropFirst(12)).data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { throw failure }
      let detail = value["detail"] ?? ""
      switch value["code"] {
      case "bundledResourcesUnavailable": throw OwlUserMigrationImportError.bundledResourcesUnavailable
      case "runtimeDirectoryFailed": throw OwlUserMigrationImportError.runtimeDirectoryFailed(path: detail, reason: "Rust did not create the prepared generation")
      case "invalidReport": throw OwlUserMigrationImportError.invalidReport(detail)
      case "rejected": throw OwlUserMigrationImportError.rejected(detail)
      default: throw failure
      }
    }
  }

  /// Materializes the same generation the live engine will use. The importer merges into
  /// prepared working dictionaries, so an empty `dictionaries/<id>` is not enough.
  private static func prepareGeneration(
    resourcesRoot: URL,
    rustUserRoot: URL,
    cacheRoot: URL,
    contentID: String
  ) throws {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let session = resourcesRoot.path.withCString { resources in
      rustUserRoot.path.withCString { user in
        cacheRoot.path.withCString { cache in
          contentID.withCString { id in
            owl_msime_session_create_with_generation(
              resources,
              user,
              cache,
              id,
              5,
              &errorPointer
            )
          }
        }
      }
    }
    if let session {
      owl_msime_session_destroy(session)
      if let errorPointer {
        owl_msime_string_free(errorPointer)
      }
      return
    }
    guard let errorPointer else {
      throw OwlUserMigrationImportError.runtimeDirectoryFailed(
        path: resourcesRoot.path,
        reason: "cannot prepare the Rust dictionary generation"
      )
    }
    let reason = String(cString: errorPointer)
    owl_msime_string_free(errorPointer)
    throw OwlUserMigrationImportError.runtimeDirectoryFailed(
      path: resourcesRoot.path,
      reason: reason
    )
  }

  static func successMessage(
    _ outcome: OwlUserMigrationImportOutcome,
    engineRestarted: Bool
  ) -> String {
    let report = outcome.report
    let changes: String
    if report.entriesWritten == 0 && report.pinsWritten == 0 {
      changes = "已核对旧快照，没有重复写入"
    } else {
      changes = "写入 \(report.entriesWritten) 条词频、\(report.pinsWritten) 条置顶"
    }
    var message = "已读取 \(report.sourceCount) 个旧快照；\(changes)。原快照未改动，可安全重试。"
    if report.recordsSkipped > 0 {
      message += "另跳过 \(report.recordsSkipped) 条无效或越界记录。"
    }
    if report.pinsExternalOnly > 0 {
      message += """
      另有 \(report.pinsExternalOnly) 条置顶仍保留在 owl_pinned_words 中；\
      Rust pinned_candidates 每个拼音上下文只能保存一条，因此这些置顶没有写入 Rust。
      """
    }
    if report.issueCount > 0 {
      message += "迁移清单记录了 \(report.issueCount) 条提示。"
    }
    if !engineRestarted {
      message += "但 Rust 引擎重新启动失败；请查看诊断日志后再试。"
    }
    return message
  }

  static func failureMessage(_ error: Error, engineRestarted: Bool) -> String {
    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    let head = "迁移旧版输入记录失败；数据库改动已回滚，原快照未改动。\(reason)"
    return engineRestarted
      ? head
      : "\(head) Rust 引擎重新启动也失败了；请查看诊断日志。"
  }
}

enum OwlUserMigrationPrompt {
  static let cancelTitle = "取消"
  static let confirmTitle = "开始迁移"

  static func makeAlert() -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "迁移旧版输入记录？"
    alert.informativeText = """
      只会读取同步目录里的稳定快照 sync/<安装>/<方案>.userdb.txt，不读取旧版正在使用的学习库，也不删除或改写这些快照。

      迁移会合并词频、输入排序和置顶到 Rust 学习库；重复执行不会重复累加。完成后会重启输入引擎。
      """
    alert.addButton(withTitle: cancelTitle)
    alert.addButton(withTitle: confirmTitle)
    return alert
  }

  static func confirm() -> Bool {
    makeAlert().runModal() == .alertSecondButtonReturn
  }
}
