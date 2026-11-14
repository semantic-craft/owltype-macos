import Foundation
import Darwin

struct OwlTemplateParameter: Codable, Equatable, Sendable {
  enum CodingKeys: String, CodingKey, CaseIterable { case key, name, isRequired, defaultValue, options }
  var key: String
  var name: String
  var isRequired = true
  var defaultValue: String?
  var options: [String] = []
}

struct OwlTemplateEntry: Identifiable, Codable, Equatable, Sendable {
  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, title, body, bodyType, syntax, candidateAliases, trigger, tags, isPinned, category
    case parameters, invocationMode, expansionMode, importSource, reviewState, exposedToAgents
  }
  enum ReviewState: String, Codable, Sendable { case pending }
  enum BodyType: String, Codable, Sendable { case plainText, template }
  enum Syntax: String, Codable, Sendable { case standard, legacyDoubleBraces }
  enum Category: String, Codable, Sendable { case general, prompt }
  enum InvocationMode: String, Codable, Sendable { case searchOnly, candidate, automatic }
  enum ExpansionMode: String, Codable, Sendable { case immediate, delimiterKeep, delimiterDrop }

  let id: UUID
  var title: String
  var body: String
  var bodyType: BodyType = .plainText
  var syntax: Syntax = .standard
  var candidateAliases: [String] = []
  var trigger: String?
  var tags: [String] = []
  var isPinned = false
  var category: Category = .general
  var parameters: [OwlTemplateParameter] = []
  var invocationMode: InvocationMode = .searchOnly
  var expansionMode: ExpansionMode = .delimiterDrop
  var importSource: OwlTemplateImportSource?
  var reviewState: ReviewState?
  /// Offered to local agents through Agent access (#208). Absent means not exposed; a copy is
  /// never exposed until the user exposes it.
  var exposedToAgents: Bool?
  var isPendingReview: Bool { reviewState == .pending }
  var isExposedToAgents: Bool {
    get { exposedToAgents == true }
    set { exposedToAgents = newValue ? true : nil }
  }

  init(id: UUID = UUID(), title: String = "", body: String = "") {
    self.id = id
    self.title = title
    self.body = body
  }

  func duplicated() -> Self {
    OwlAppCore.required(["operation": "template_duplicate", "entry": OwlAppCore.payload(self), "new_id": UUID().uuidString])
  }

  var executionIssue: String? {
    OwlTemplateEngine.parse(self).diagnostics.first(where: { $0.severity == .error })?.message
  }
}

struct OwlTemplateLibrary: Codable, Equatable, Sendable {
  enum CodingKeys: String, CodingKey, CaseIterable { case formatVersion, entries }
  var formatVersion = 1
  var entries: [OwlTemplateEntry] = []
}

enum OwlTemplateError: LocalizedError, Equatable {
  case invalid(String)
  case changedOnDisk

  var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    case .changedOnDisk: return "模板库已被其他窗口修改，请重新打开后再保存。"
    }
  }
}

/// DTO facade for the single Rust library owner. Native APIs retain their established seams.
enum OwlTemplateStore {
  static let fileName = "owl_templates.json"
  static let candidatePrefix = "🦉["
  enum Mode: Equatable { case empty, unified, unavailable(String) }
  static func core<T: Decodable>(_ operation: String, _ args: [String: Any] = [:]) -> T {
    OwlAppCore.required(["operation": "template_rule", "rule": operation, "args": args])
  }
  static func exclusively<T>(_ action: () throws -> T) rethrows -> T { try OwlStorageHost.exclusively(action) }
  static func mode(dataDir: URL = OwlApp.userDir) -> Mode {
    struct State: Decodable { let kind: String; let message: String? }
    guard let value: State = try? OwlStorageHost(dataDir: dataDir).call("library_mode") else { return .unavailable("模板库无法读取。") }
    switch value.kind { case "empty": return .empty; case "unified": return .unified; default: return .unavailable(value.message ?? "模板库无法读取。") }
  }
  static func load(dataDir: URL = OwlApp.userDir) throws -> OwlTemplateLibrary {
    try exclusively { try OwlStorageHost(dataDir: dataDir).call("library_load") }
  }
  static func sorted(_ entries: [OwlTemplateEntry]) -> [OwlTemplateEntry] { core("library_sorted", ["entries": OwlAppCore.payload(entries)]) }
  static func filtered(_ entries: [OwlTemplateEntry], query: String = "", tag: String? = nil, promptOnly: Bool = false) -> [OwlTemplateEntry] {
    core("library_filtered", ["entries": OwlAppCore.payload(entries), "query": query, "tag": tag as Any? ?? NSNull(), "promptOnly": promptOnly])
  }
  static func searchText(_ entry: OwlTemplateEntry) -> String { core("library_search_text", ["entry": OwlAppCore.payload(entry)]) }
  static func tags(in entries: [OwlTemplateEntry]) -> [String] { core("library_tags", ["entries": OwlAppCore.payload(entries)]) }
  static func candidateID(_ text: String) -> UUID? {
    struct Identifier: Decodable { let id: UUID? }
    let value: Identifier = core("library_candidate_id", ["text": text]); return value.id
  }
  static func candidateDisplay(_ text: String) -> String {
    guard candidateID(text) != nil, let end = text.firstIndex(of: "]") else { return text }
    return "📝" + text[text.index(after: end)...]
  }
  static func renderCandidateProjection(_ library: OwlTemplateLibrary) -> String { core("library_projection", ["library": OwlAppCore.payload(library)]) }
  static func resolveCandidate(code: String?, text: String, loadLibrary: () throws -> OwlTemplateLibrary) -> OwlTemplateEntry? {
    guard candidateID(text) != nil, let code, let library = try? loadLibrary() else { return nil }
    struct Resolution: Decodable { let entry: OwlTemplateEntry? }
    let result: Resolution = core("library_resolve", ["code": code, "text": text, "library": OwlAppCore.payload(library)])
    return result.entry
  }
  static func save(_ library: OwlTemplateLibrary, dataDir: URL = OwlApp.userDir, expectedLibrary: OwlTemplateLibrary? = nil, beforeWrite: (String) throws -> Void = { _ in }) throws {
    try withoutActuallyEscaping(beforeWrite) { checkpoint in
      let _: Bool = try OwlStorageHost(dataDir: dataDir, checkpoint: checkpoint).call("library_save",
        ["library": OwlAppCore.payload(library), "expected": expectedLibrary.map(OwlAppCore.payload) ?? NSNull()])
    }
  }
  static func delete(id: UUID, expected: OwlTemplateLibrary, dataDir: URL = OwlApp.userDir, beforeWrite: (String) throws -> Void = { _ in }) throws -> OwlTemplateLibrary {
    let result: OwlTemplateLibrary = try withoutActuallyEscaping(beforeWrite) { checkpoint in
      try OwlStorageHost(dataDir: dataDir, checkpoint: checkpoint).call("library_delete",
        ["id": id.uuidString, "expected": OwlAppCore.payload(expected)])
    }
    return result
  }
  static let libraryDidCommit = Notification.Name("OwlTemplateLibraryDidCommit")
  static func notifyCommittedLibrary(dataDir: URL) { NotificationCenter.default.post(name: libraryDidCommit, object: dataDir.standardizedFileURL) }
  static func encoded(_ library: OwlTemplateLibrary) throws -> Data {
    let bytes: [UInt8] = try OwlAppCore.call(["operation": "template_encode", "library": OwlAppCore.payload(library)])
    return Data(bytes)
  }
}
