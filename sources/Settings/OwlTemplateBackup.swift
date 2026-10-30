import Foundation

/// Native presentation DTOs; strict decode, preview merge and durable restore live in Rust.
struct OwlTemplateBackup {
  enum Kind: String, Codable { case new, identical, update }
  struct Row: Identifiable, Codable {
    var entry: OwlTemplateEntry
    let current: OwlTemplateEntry?
    let kind: Kind
    let originalInvocationMode: OwlTemplateEntry.InvocationMode
    var selected: Bool
    var id: UUID { entry.id }
  }
  struct Preview: Identifiable, Codable {
    let id = UUID()
    let baseline: OwlTemplateLibrary
    var rows: [Row]
    enum CodingKeys: String, CodingKey { case baseline, rows }
    var library: OwlTemplateLibrary { OwlTemplateStore.core("backup_library", ["preview": OwlAppCore.payload(self)]) }
    var conflicts: [String] { OwlTemplateStore.core("library_conflicts", ["entries": OwlAppCore.payload(library.entries)]) }
    var selectedCount: Int { rows.filter { $0.selected && $0.kind != .identical }.count }
    mutating func makeSearchOnly(id: UUID) { changeTrigger(id: id, to: "") }
    mutating func changeTrigger(id: UUID, to code: String) {
      let next: Preview = OwlTemplateStore.core("backup_change", ["preview": OwlAppCore.payload(self), "id": id.uuidString, "code": code])
      rows = next.rows
    }
  }
  struct Outcome: Decodable { let library: OwlTemplateLibrary; let backupURL: URL? }
  let dataDir: URL
  static func decode(_ data: Data) throws -> OwlTemplateLibrary {
    try OwlStorageHost(dataDir: URL(fileURLWithPath: "/")).call("backup_decode", ["bytes": Array(data)])
  }
  func currentLibrary() throws -> OwlTemplateLibrary { try OwlStorageHost(dataDir: dataDir).call("library_current") }
  func preview(data: Data) throws -> Preview {
    try OwlTemplateStore.exclusively { try OwlStorageHost(dataDir: dataDir).call("backup_preview", ["bytes": Array(data)]) }
  }
  func export(to destination: URL) throws {
    let _: Bool = try OwlTemplateStore.exclusively { try OwlStorageHost(dataDir: dataDir).call("backup_export", ["destination": destination.path]) }
  }
  func restore(_ preview: Preview, checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> Outcome {
    try perform("backup_restore", ["preview": OwlAppCore.payload(preview)], checkpoint: checkpoint)
  }
  func delete(id: UUID, expected: OwlTemplateLibrary, checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> Outcome {
    try perform("backup_delete", ["id": id.uuidString, "expected": OwlAppCore.payload(expected)], checkpoint: checkpoint)
  }
  func commit(_ next: OwlTemplateLibrary, expected: OwlTemplateLibrary, checkpoint: @escaping (String) throws -> Void) throws -> Outcome {
    try perform("backup_commit", ["library": OwlAppCore.payload(next), "expected": OwlAppCore.payload(expected)], checkpoint: checkpoint)
  }
  private func perform(_ operation: String, _ args: [String: Any], checkpoint: @escaping (String) throws -> Void) throws -> Outcome {
    let outcome: Outcome = try OwlStorageHost(dataDir: dataDir, checkpoint: checkpoint, writerCheckpoint: checkpoint).call(operation, args)
    OwlTemplateStore.notifyCommittedLibrary(dataDir: dataDir)
    return outcome
  }
}
