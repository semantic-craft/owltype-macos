import Foundation
import CryptoKit

/// Raw audit and restart recovery. All locations are injected; no legacy tolerant loader is used.
final class OwlTemplateMigration {
  struct Issue: Codable, Equatable, Identifiable {
    let file: String
    let record: Int?
    let message: String
    var id: String { "\(file):\(record ?? -1):\(message)" }
  }
  struct Snapshot: Codable {
    let name: String
    let bytes: Data?
    let digest: String?
    let permissions: Int?
  }
  struct Plan: Codable {
    var version = 1
    let id: UUID
    let sources: [Snapshot]
    var entries: [OwlTemplateEntry]
    let existingEntries: [OwlTemplateEntry]
    var issues: [Issue]
    var collapsedRows: Int
    var library: OwlTemplateLibrary { OwlTemplateLibrary(entries: existingEntries + entries) }
  }
  enum Failure: LocalizedError {
    case issues, conflict, changed, invalidJournal, recovery, alreadyUnified
    var errorDescription: String? {
      switch self {
      case .issues: return "原始数据有待处理问题。请按文件和记录位置修复副本后重试；原件未改动。"
      case .conflict: return "候选编码或别名有冲突，请改码或改为仅搜索后迁移。"
      case .changed: return "原始数据或迁移计划已改变，请重新检查后再迁移。"
      case .invalidJournal: return "迁移恢复记录无法校验。请保留迁移备份，恢复文件后再重试。"
      case .recovery: return "未能完整恢复旧状态。请检查文件权限后重试，暂不修改模板库。"
      case .alreadyUnified: return "模板库已经启用，无需再次迁移。"
      }
    }
  }
  static let directoryName = ".owl-template-migration"
  let dataDir: URL
  init(dataDir: URL) { self.dataDir = dataDir }
  static func hasPendingRecovery(dataDir: URL) -> Bool {
    (try? OwlStorageHost(dataDir: dataDir).call("transaction_pending")) ?? true
  }
  func prepare() throws -> Plan { try OwlStorageHost(dataDir: dataDir).call("migration_prepare") }
  func conflicts(in plan: Plan) -> [String] {
    OwlTemplateStore.core("library_conflicts", ["entries": OwlAppCore.payload(plan.library.entries)])
  }
  func resolve(_ plan: Plan, id: UUID, code: String?) throws -> Plan {
    try OwlStorageHost(dataDir: dataDir).call("migration_resolve", ["plan": OwlAppCore.payload(plan), "id": id.uuidString, "code": code as Any? ?? NSNull()])
  }
  @discardableResult func prepareTransaction(_ plan: Plan) throws -> [OwlTemplateStore.PreparedWrite] {
    try OwlStorageHost(dataDir: dataDir).call("migration_commit", ["plan": OwlAppCore.payload(plan), "prepareOnly": true])
  }
  func commit(_ plan: Plan, checkpoint: @escaping (String) throws -> Void = { _ in }) throws {
    let _: [OwlTemplateStore.PreparedWrite] = try OwlStorageHost(dataDir: dataDir, checkpoint: checkpoint, writerCheckpoint: checkpoint).call("migration_commit", ["plan": OwlAppCore.payload(plan), "prepareOnly": false])
    OwlTemplateStore.notifyCommittedLibrary(dataDir: dataDir)
  }
  func prepareLibraryTransaction(_ library: OwlTemplateLibrary, expected: OwlTemplateLibrary) throws -> [OwlTemplateStore.PreparedWrite] {
    try OwlStorageHost(dataDir: dataDir).call("transaction_commit_library", ["library": OwlAppCore.payload(library), "expected": OwlAppCore.payload(expected), "prepareOnly": true])
  }
  func commitLibrary(_ library: OwlTemplateLibrary, expected: OwlTemplateLibrary, checkpoint: @escaping (String) throws -> Void = { _ in }) throws {
    let _: [OwlTemplateStore.PreparedWrite] = try OwlStorageHost(dataDir: dataDir, checkpoint: checkpoint, writerCheckpoint: checkpoint).call("transaction_commit_library", ["library": OwlAppCore.payload(library), "expected": OwlAppCore.payload(expected), "prepareOnly": false])
    OwlTemplateStore.notifyCommittedLibrary(dataDir: dataDir)
  }
  func recoverIfNeeded(beforeRestore: (String) throws -> Void = { _ in }) throws {
    let _: Bool = try withoutActuallyEscaping(beforeRestore) { beforeRestore in
      try OwlStorageHost(dataDir: dataDir, checkpoint: { name in
        if name.hasPrefix("restore:") { try beforeRestore(String(name.dropFirst(8))) }
      }).call("transaction_recover")
    }
  }
  @discardableResult func runAutomatically() throws -> Bool {
    let result: Bool = try OwlStorageHost(dataDir: dataDir).call("migration_automatic")
    if result { OwlTemplateStore.notifyCommittedLibrary(dataDir: dataDir) }
    return result
  }
}
