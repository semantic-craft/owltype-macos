import Foundation

struct OwlTemplateImportSource: Codable, Equatable, Sendable {
  enum CodingKeys: String, CodingKey, CaseIterable { case version, originalName, originalBody, originalKeyword }
  var version = 1
  let originalName: String
  let originalBody: String
  let originalKeyword: String?
  var fingerprint: String { OwlTemplateStore.core("import_fingerprint", ["source": OwlAppCore.payload(self)]) }
}

/// Review DTOs and UI bindings. Conversion, identity and conflict decisions live in Rust.
struct OwlRaycastImport {
  enum DuplicateKind: String, Codable { case identical, alreadyImported }
  struct Row: Identifiable, Codable {
    let id: UUID
    let number: Int
    let originalTitle: String
    let originalBody: String?
    let fieldErrors: [String]
    let unsupportedKeys: [String]
    var entry: OwlTemplateEntry?
    var selected: Bool
    var syntaxIssues: [OwlTemplateEngine.Diagnostic] { entry.map(OwlRaycastImport.compatibilityIssues) ?? [] }
  }
  struct Preview: Identifiable, Codable {
    let id = UUID()
    let baseline: OwlTemplateLibrary
    var rows: [Row]
    enum CodingKeys: String, CodingKey { case baseline, rows }
    struct Assessment: Codable {
      var duplicates: [Int: DuplicateKind] = [:]
      var conflicts: [Int: [String]] = [:]
      var selectedIndices: [Int] = []
      var pendingCount = 0
    }
    var assessment: Assessment { OwlTemplateStore.core("import_assessment", ["preview": OwlAppCore.payload(self)]) }
    func duplicateKind(at index: Int) -> DuplicateKind? { assessment.duplicates[index] }
    func conflicts(at index: Int) -> [String] { assessment.conflicts[index] ?? [] }
    var selectedIndices: [Int] { assessment.selectedIndices }
    var selectedCount: Int { assessment.selectedIndices.count }
    var pendingCount: Int { assessment.pendingCount }
    var validationMessage: String? { validationMessage(for: assessment) }
    func validationMessage(for review: Assessment) -> String? {
      struct Message: Decodable { let message: String? }
      let result: Message = OwlTemplateStore.core("import_message", ["preview": OwlAppCore.payload(self)])
      return result.message
    }
    var library: OwlTemplateLibrary { OwlTemplateStore.core("import_library", ["preview": OwlAppCore.payload(self)]) }
    private mutating func change(at index: Int, action: String, trigger: String = "") {
      let result: Preview = OwlTemplateStore.core("import_change", ["preview": OwlAppCore.payload(self), "index": index, "action": action, "trigger": trigger])
      rows = result.rows
    }
    mutating func makeSearchOnly(at index: Int) { change(at: index, action: "search") }
    mutating func changeTrigger(at index: Int, to trigger: String) { change(at: index, action: "trigger", trigger: trigger) }
    mutating func convertToPlainText(at index: Int) { change(at: index, action: "plain") }
  }
  let dataDir: URL
  func preview(data: Data) throws -> Preview { try OwlStorageHost(dataDir: dataDir).call("import_preview", ["bytes": Array(data)]) }
  func commit(_ preview: Preview, checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> OwlTemplateLibrary {
    let result: OwlTemplateLibrary = try OwlStorageHost(dataDir: dataDir, checkpoint: checkpoint).call("import_commit", ["preview": OwlAppCore.payload(preview)])
    return result
  }
  static func compatibilityIssues(_ entry: OwlTemplateEntry) -> [OwlTemplateEngine.Diagnostic] {
    OwlTemplateStore.core("import_compatibility", ["entry": OwlAppCore.payload(entry)])
  }
  @discardableResult static func enableAfterReview(_ entry: inout OwlTemplateEntry) -> Bool {
    struct Result: Decodable { let enabled: Bool; let entry: OwlTemplateEntry }
    let result: Result = OwlTemplateStore.core("import_enable", ["entry": OwlAppCore.payload(entry)])
    if result.enabled { entry = result.entry }
    return result.enabled
  }
  static func convertToPlainText(_ entry: inout OwlTemplateEntry) {
    entry = OwlTemplateStore.core("import_plain", ["entry": OwlAppCore.payload(entry)])
  }
}
