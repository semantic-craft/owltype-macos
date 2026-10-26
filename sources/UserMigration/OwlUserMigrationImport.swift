import AppKit
import Foundation

struct OwlUserMigrationImportReport: Decodable, Equatable, Sendable {
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
    let resolution = try resolveGeneration(
      userRoot: userRoot,
      sharedSupportURL: sharedSupportURL
    )
    let generation = resolution.generation

    let rustUserRoot = userRoot.appendingPathComponent("msime-user", isDirectory: true)
    let cacheRoot = userRoot.appendingPathComponent("msime-cache", isDirectory: true)
    let dictionariesParent = rustUserRoot
      .appendingPathComponent("dictionaries", isDirectory: true)
    let dictionariesRoot = dictionariesParent
      .appendingPathComponent(generation.contentID, isDirectory: true)
    for directory in [rustUserRoot, cacheRoot, dictionariesParent] {
      do {
        try fm.createDirectory(
          at: directory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw OwlUserMigrationImportError.runtimeDirectoryFailed(
          path: directory.path,
          reason: error.localizedDescription
        )
      }
    }

    try prepareGeneration(
      resourcesRoot: generation.resourcesURL,
      rustUserRoot: rustUserRoot,
      cacheRoot: cacheRoot,
      contentID: generation.contentID
    )
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: dictionariesRoot.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      throw OwlUserMigrationImportError.runtimeDirectoryFailed(
        path: dictionariesRoot.path,
        reason: "Rust did not create the prepared generation"
      )
    }

    let rawReport = generation.resourcesURL.path.withCString { resources in
      rustUserRoot.path.withCString { user in
        cacheRoot.path.withCString { cache in
          dictionariesRoot.path.withCString { dictionaries in
            staged.manifest.requestID.withCString { requestID in
              owl_msime_user_migration_import(
                resources,
                user,
                cache,
                dictionaries,
                requestID
              )
            }
          }
        }
      }
    }
    guard let rawReport else {
      throw OwlUserMigrationImportError.missingReport
    }
    let json = String(cString: rawReport)
    owl_msime_string_free(rawReport)

    let report: OwlUserMigrationImportReport
    do {
      report = try JSONDecoder().decode(
        OwlUserMigrationImportReport.self,
        from: Data(json.utf8)
      )
    } catch {
      throw OwlUserMigrationImportError.invalidReport(error.localizedDescription)
    }
    guard report.ok else {
      throw OwlUserMigrationImportError.rejected(
        report.error ?? "Rust importer returned ok=false without an error"
      )
    }
    guard report.requestID == staged.manifest.requestID else {
      throw OwlUserMigrationImportError.invalidReport(
        "request_id does not match the staged request"
      )
    }
    guard report.sourceCount == staged.manifest.sources.count,
          report.issueCount == staged.manifest.issues.count,
          report.recordCount == staged.recordCount,
          report.pinsTotal == staged.manifest.pins.count else {
      throw OwlUserMigrationImportError.invalidReport(
        "source, issue, record or pin count differs from the staged manifest"
      )
    }

    var warnings = resolution.warnings
    warnings.append(contentsOf: report.warnings)
    return OwlUserMigrationImportOutcome(
      report: report,
      generation: generation,
      warnings: warnings
    )
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

  private static func resolveGeneration(
    userRoot: URL,
    sharedSupportURL: URL?
  ) throws -> (generation: OwlRustResourceGeneration, warnings: [String]) {
    let environment = OwlRustResourceEnvironment.production(userRoot: userRoot)
    var warnings: [String] = []
    do {
      if let generation = try environment.activeGeneration() {
        return (generation, warnings)
      }
    } catch {
      warnings.append(
        "当前完整词库不可用，迁移与重新启动都回退到随包精简词库：\(error.localizedDescription)"
      )
    }

    guard let sharedSupportURL else {
      throw OwlUserMigrationImportError.bundledResourcesUnavailable
    }
    let resourcesURL = sharedSupportURL.appendingPathComponent("msime", isDirectory: true)
    do {
      let digest = try OwlRustEngine.contentDigest(of: resourcesURL)
      return (
        OwlRustResourceGeneration(
          resourcesURL: resourcesURL,
          contentID: "seed-\(digest)"
        ),
        warnings
      )
    } catch {
      throw OwlUserMigrationImportError.bundledResourcesUnavailable
    }
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
