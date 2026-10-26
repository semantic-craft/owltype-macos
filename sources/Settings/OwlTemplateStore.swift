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

struct OwlTemplateMigrationSource: Codable, Equatable, Sendable {
  enum CodingKeys: String, CodingKey, CaseIterable { case sourceFile, record, originalCode }
  var sourceFile: String
  var record: Int
  var originalCode: String
}

struct OwlTemplateEntry: Identifiable, Codable, Equatable, Sendable {
  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, title, body, bodyType, syntax, candidateAliases, trigger, tags, isPinned, category
    case parameters, invocationMode, expansionMode, migrationSource, importSource, reviewState
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
  var migrationSource: OwlTemplateMigrationSource?
  var importSource: OwlTemplateImportSource?
  var reviewState: ReviewState?
  var isPendingReview: Bool { reviewState == .pending }

  init(id: UUID = UUID(), title: String = "", body: String = "") {
    self.id = id
    self.title = title
    self.body = body
  }

  func duplicated() -> Self {
    var copy = Self(title: title + " 副本", body: body)
    copy.bodyType = bodyType
    copy.syntax = syntax
    copy.tags = tags
    copy.isPinned = isPinned
    copy.category = category
    copy.parameters = parameters
    copy.reviewState = reviewState
    return copy
  }

  var executionIssue: String? {
    OwlTemplateEngine.parse(self).diagnostics.first(where: { $0.severity == .error })?.message
  }

  var legacyVariables: [String] {
    bodyType == .template && syntax == .legacyDoubleBraces ? OwlPromptVariables.extract(from: body) : []
  }
}

struct OwlTemplateLibrary: Codable, Equatable, Sendable {
  enum CodingKeys: String, CodingKey, CaseIterable { case formatVersion, entries }
  var formatVersion = 1
  var entries: [OwlTemplateEntry] = []
}

enum OwlTemplateError: LocalizedError {
  case invalid(String)
  case legacyRequiresMigration
  case changedOnDisk
  case recoveryFailed

  var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    case .legacyRequiresMigration: return "现有短语和提示词尚未迁移，请继续使用原入口。"
    case .changedOnDisk: return "模板库已被其他窗口修改，请重新打开后再保存。"
    case .recoveryFailed: return "保存失败且未能完整恢复，请保留备份并检查文件权限。"
    }
  }
}

/// Single fact source. Legacy loading is selected outside this store, never used as fallback.
/// Save is serialized and restores all touched bytes on a thrown failure. Crash recovery for
/// legacy migration is owned by #163; this is not a claim of a multi-file filesystem transaction.
enum OwlTemplateStore {
  static let fileName = "owl_templates.json"
  static let dictFileName = "owl_templates.txt"
  static let stateFileName = "owl_templates_state.json"
  static let candidatePrefix = "🦉["
  private static let lock = NSRecursiveLock()
  private static var lockedDirectories = Set<String>()
  private static let activation = "{\"formatVersion\":1,\"committed\":true}\n"
  struct Activation: Codable {
    var formatVersion = 1
    var committed = true
    var transactionID: UUID?
  }

  static func activationContents(transactionID: UUID) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(Activation(transactionID: transactionID)), as: UTF8.self) + "\n"
  }

  enum Mode: Equatable { case empty, legacy, unified, unavailable(String) }

  static func exclusively<T>(_ action: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try action()
  }

  /// One advisory lock for this fixed library write set, shared by app instances. Recursive
  /// calls from journal recovery reuse the descriptor while the process lock is held.
  static func withWriteLock<T>(rimeDir: URL, _ action: () throws -> T) throws -> T {
    try exclusively {
      let directory = rimeDir.standardizedFileURL.resolvingSymlinksInPath()
      let key = directory.path
      if lockedDirectories.contains(key) { return try action() }
      try OwlPrivateStorage.prepareDirectory(directory)
      let path = directory.appendingPathComponent(".owl-template-write.lock").path
      let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
      guard descriptor >= 0 else { throw OwlTemplateError.invalid("无法锁定模板库，请检查目录权限。") }
      defer { close(descriptor) }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw OwlTemplateError.invalid("另一个实例正在修改模板库，请稍后重试。") }
      lockedDirectories.insert(key)
      defer { lockedDirectories.remove(key); flock(descriptor, LOCK_UN) }
      return try action()
    }
  }

  static func mode(rimeDir: URL = OwlApp.userDir) -> Mode {
    if OwlTemplateMigration.hasPendingRecovery(rimeDir: rimeDir) {
      return .unavailable("模板库操作需要恢复，请到快捷片段设置中重试。")
    }
    let fm = FileManager.default
    let state = rimeDir.appendingPathComponent(stateFileName)
    if fm.fileExists(atPath: state.path) {
      do {
        let data = try Data(contentsOf: state)
        struct State: Decodable { let formatVersion: Int; let committed: Bool }
        let value = try JSONDecoder().decode(State.self, from: data)
        guard value.formatVersion == 1, value.committed else {
          return .unavailable("模板库启用状态无效，请恢复备份。")
        }
        _ = try load(rimeDir: rimeDir)
        return .unified
      } catch { return .unavailable("模板库无法读取，请保留原件并恢复备份。") }
    }
    if fm.fileExists(atPath: rimeDir.appendingPathComponent(fileName).path) {
      return .unavailable("发现未完成写入的模板库，请恢复备份后继续。")
    }
    let legacy = [OwlQuickSendStore.fileName, OwlQuickSendStore.dictFileName, OwlPromptStore.fileName, OwlPromptStore.dictFileName]
    return legacy.contains { fm.fileExists(atPath: rimeDir.appendingPathComponent($0).path) } ? .legacy : .empty
  }

  static func load(rimeDir: URL = OwlApp.userDir) throws -> OwlTemplateLibrary {
    try exclusively {
      guard !OwlTemplateMigration.hasPendingRecovery(rimeDir: rimeDir) else {
        throw OwlTemplateError.invalid("模板库操作尚未完成，请先恢复。")
      }
      return try loadCommittedBytes(rimeDir: rimeDir)
    }
  }

  /// Only transaction verification/recovery may inspect staged bytes before publication.
  static func loadCommittedBytes(rimeDir: URL) throws -> OwlTemplateLibrary {
    let library = try JSONDecoder().decode(OwlTemplateLibrary.self, from: Data(contentsOf: rimeDir.appendingPathComponent(fileName)))
    try validate(library)
    return library
  }

  static func validate(_ library: OwlTemplateLibrary) throws {
    guard library.formatVersion == 1 else { throw OwlTemplateError.invalid("不支持的模板库版本。") }
    var ids = Set<UUID>()
    var triggers = Set<String>()
    for entry in library.entries {
      guard ids.insert(entry.id).inserted else { throw OwlTemplateError.invalid("条目 ID 重复。") }
      guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            entry.title.rangeOfCharacter(from: .newlines.union(.init(charactersIn: "\t"))) == nil else {
        throw OwlTemplateError.invalid("标题不能为空，且不能包含换行或 Tab。")
      }
      guard !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OwlTemplateError.invalid("正文不能全部为空白。")
      }
      if !entry.isPendingReview, let issue = entry.executionIssue { throw OwlTemplateError.invalid(issue) }
      if let trigger = entry.trigger, trigger.isEmpty || trigger.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
        throw OwlTemplateError.invalid("触发词不能包含空白。")
      }
      if entry.invocationMode == .candidate {
        guard let trigger = entry.trigger,
              trigger.range(of: "^[a-z][a-z0-9]{0,31}$", options: .regularExpression) != nil else {
          throw OwlTemplateError.invalid("候选编码须为小写字母开头的字母或数字，最多 32 位。")
        }
      }
      for alias in entry.candidateAliases {
        guard entry.invocationMode == .candidate, alias.range(of: "^v[a-z][a-z0-9]{0,31}$", options: .regularExpression) != nil,
              triggers.insert(alias).inserted else { throw OwlTemplateError.invalid("候选别名无效或冲突。") }
      }
      if entry.invocationMode != .searchOnly {
        guard let trigger = entry.trigger, triggers.insert(trigger).inserted else {
          throw OwlTemplateError.invalid("生效触发词缺失或重复。")
        }
      }
      if let source = entry.importSource, source.version != 1 {
        throw OwlTemplateError.invalid("不支持的导入来源版本。")
      }
      guard Set(entry.parameters.map(\.key)).count == entry.parameters.count,
            entry.parameters.allSatisfy({ !$0.key.isEmpty && !$0.name.isEmpty }) else {
        throw OwlTemplateError.invalid("参数名称或标识无效。")
      }
    }
    _ = try OwlAutomaticExpansionIndex(entries: library.entries)
  }

  static func sorted(_ entries: [OwlTemplateEntry]) -> [OwlTemplateEntry] {
    entries.sorted {
      if $0.isPinned != $1.isPinned { return $0.isPinned }
      let order = $0.title.localizedStandardCompare($1.title)
      return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
    }
  }

  static func filtered(_ entries: [OwlTemplateEntry], query: String = "", tag: String? = nil,
                       promptOnly: Bool = false) -> [OwlTemplateEntry] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return sorted(entries).filter { entry in
      (!promptOnly || entry.category == .prompt) &&
      (tag == nil || entry.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame }) &&
      (query.isEmpty || searchText(entry).localizedCaseInsensitiveContains(query))
    }
  }

  static func searchText(_ entry: OwlTemplateEntry) -> String {
    ([entry.title, entry.body, entry.trigger ?? "", entry.migrationSource?.originalCode ?? "", entry.importSource?.originalKeyword ?? ""] +
      entry.tags + entry.candidateAliases).joined(separator: "\n")
  }

  static func tags(in entries: [OwlTemplateEntry]) -> [String] {
    var tags: [String] = []
    for tag in entries.flatMap(\.tags) where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
      tags.append(tag)
    }
    return tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  static func candidateText(_ entry: OwlTemplateEntry) -> String {
    candidatePrefix + entry.id.uuidString + "]" + entry.title
  }

  static func candidateID(_ text: String) -> UUID? {
    guard text.hasPrefix(candidatePrefix) else { return nil }
    let tail = text.dropFirst(candidatePrefix.count)
    guard let end = tail.firstIndex(of: "]") else { return nil }
    return UUID(uuidString: String(tail[..<end]))
  }

  static func candidateDisplay(_ text: String) -> String {
    guard candidateID(text) != nil, let end = text.firstIndex(of: "]") else { return text }
    return "📝" + text[text.index(after: end)...]
  }

  static func renderCandidateProjection(_ library: OwlTemplateLibrary) -> String {
    let header = "# Rime table\n# coding: utf-8\n#@/db_name\towl_templates\n#@/db_type\ttabledb\n"
    return header + sorted(library.entries).filter { $0.invocationMode == .candidate && !$0.isPendingReview }.map {
      entry in
      ([entry.trigger ?? ""] + entry.candidateAliases).map { "\(candidateText(entry))\t\($0)\t100000\n" }.joined()
    }.joined()
  }

  /// A stale title/code/ID must not resolve to a different or edited record.
  static func resolveCandidate(code: String?, text: String, loadLibrary: () throws -> OwlTemplateLibrary) -> OwlTemplateEntry? {
    guard let id = candidateID(text), let rawCode = code else { return nil }
    // Native K mode adds a mode prefix; stored trigger codes and user content stay unchanged.
    let code = rawCode.hasPrefix("K") ? String(rawCode.dropFirst()) : rawCode
    guard let library = try? loadLibrary() else { return nil }
    return library.entries.first {
      $0.id == id && !$0.isPendingReview && $0.invocationMode == .candidate && ($0.trigger == code || $0.candidateAliases.contains(code)) && candidateText($0) == text
    }
  }

  static var patch: ManagedPatchBlock {
    ManagedPatchBlock(marker: "OWL MANAGED TEMPLATES RIME_ICE PATCH v1", yamlLinesIndentedUnderPatch: [
      "  \"engine/translators/+\":", "    - table_translator@owl_templates", "  owl_templates:",
      "    dictionary: \"\"", "    user_dict: owl_templates", "    db_class: stabledb",
      "    enable_completion: false", "    enable_sentence: false", "    initial_quality: 99",
    ])
  }

  /// expectedLibrary is the editor's last successful read, for lost-update protection.
  /// beforeWrite is a failure-injection seam; it receives only file names, never user content.
  static func save(_ library: OwlTemplateLibrary, writer: OwlConfigWriter = OwlConfigWriter(),
                   expectedLibrary: OwlTemplateLibrary? = nil, beforeWrite: (String) throws -> Void = { _ in }) throws {
    try withWriteLock(rimeDir: writer.rimeDir) {
      try validate(library)
      switch mode(rimeDir: writer.rimeDir) {
      case .legacy: throw OwlTemplateError.legacyRequiresMigration
      case .unavailable(let message): throw OwlTemplateError.invalid(message)
      case .empty:
        if let expectedLibrary, !expectedLibrary.entries.isEmpty { throw OwlTemplateError.changedOnDisk }
      case .unified:
        if let expectedLibrary, try encoded(load(rimeDir: writer.rimeDir)) != encoded(expectedLibrary) { throw OwlTemplateError.changedOnDisk }
      }
      try performBatch(prepareWrites(library, writer: writer), library: library, writer: writer, beforeWrite: beforeWrite)
    }
    notifyCommittedLibrary(rimeDir: writer.rimeDir)
  }

  static let libraryDidCommit = Notification.Name("OwlTemplateLibraryDidCommit")

  /// Call only after the complete transaction/journal has settled. Runtime listeners re-read
  /// through the public gate; staged bytes and partially committed writes are never published.
  static func notifyCommittedLibrary(rimeDir: URL) {
    NotificationCenter.default.post(name: libraryDidCommit, object: rimeDir.standardizedFileURL)
  }

  static func encoded(_ library: OwlTemplateLibrary) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(library)
  }

  struct PreparedWrite {
    let fileName: String
    let contents: String
    let marker: String
  }

  /// Pure preparation after strict reads: #163 may add legacy projection cleanup BEFORE the
  /// final state write, and journal the complete write set before committing this batch.
  static func prepareWrites(_ library: OwlTemplateLibrary, writer: OwlConfigWriter) throws -> [PreparedWrite] {
    try validate(library)
    let json = String(decoding: try encoded(library), as: UTF8.self) + "\n"
    let yamlURL = writer.rimeDir.appendingPathComponent("rime_ice.custom.yaml")
    let yaml = FileManager.default.fileExists(atPath: yamlURL.path) ? try String(contentsOf: yamlURL, encoding: .utf8) : "patch:\n"
    return [
      PreparedWrite(fileName: fileName, contents: json, marker: "OWL MANAGED TEMPLATES JSON v1"),
      PreparedWrite(fileName: dictFileName, contents: renderCandidateProjection(library), marker: "OWL MANAGED TEMPLATES DICT v1"),
      PreparedWrite(fileName: "rime_ice.custom.yaml", contents: try writer.renderManagedBlock(yaml, block: patch), marker: patch.marker),
      PreparedWrite(fileName: stateFileName, contents: activation, marker: "OWL MANAGED TEMPLATES STATE v1"),
    ]
  }

  /// Migration-only low-level commit: the caller owns raw-source preflight, conflicts, durable
  /// journal and recovery across process termination. Normal editors MUST use save instead.
  static func commitPreparedWrites(_ writes: [PreparedWrite], library: OwlTemplateLibrary, writer: OwlConfigWriter,
                                   beforeWrite: (String) throws -> Void = { _ in }, batchTimestamp: String? = nil, restoreOnFailure: Bool = true) throws {
    try withWriteLock(rimeDir: writer.rimeDir) {
      try validate(library)
      try performBatch(writes, library: library, writer: writer, beforeWrite: beforeWrite, batchTimestamp: batchTimestamp, restoreOnFailure: restoreOnFailure)
    }
  }

  private static func performBatch(_ writes: [PreparedWrite], library: OwlTemplateLibrary, writer: OwlConfigWriter,
                                   beforeWrite: (String) throws -> Void, batchTimestamp: String? = nil, restoreOnFailure: Bool = true) throws {
    guard let last = writes.last, last.fileName == stateFileName,
          let state = try? JSONDecoder().decode(Activation.self, from: Data(last.contents.utf8)), state.formatVersion == 1, state.committed,
          Set(writes.map(\.fileName)).count == writes.count,
          writes.allSatisfy({ OwlConfigWriter.owlManagedFiles.contains($0.fileName) }) else {
      throw OwlTemplateError.invalid("模板库写入计划无效。")
    }
    let timestamp = batchTimestamp ?? "templates-" + UUID().uuidString
    let names = writes.map(\.fileName) + ["owltype/rollback-manifest.json"]
    let snapshots = try names.map { name -> (URL, Data?) in
      let url = writer.rimeDir.appendingPathComponent(name)
      return (url, FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil)
    }
    do {
      for write in writes {
        if write.fileName == stateFileName {
          guard try encoded(loadCommittedBytes(rimeDir: writer.rimeDir)) == encoded(library) else { throw OwlTemplateError.invalid("写入核对失败。") }
        }
        try beforeWrite(write.fileName)
        try writer.applyTextFile(fileName: write.fileName, contents: write.contents, marker: write.marker, timestamp: timestamp)
        guard try Data(contentsOf: writer.rimeDir.appendingPathComponent(write.fileName)) == Data(write.contents.utf8) else {
          throw OwlTemplateError.invalid("写入核对失败。")
        }
      }
      try beforeWrite("completed")
    } catch {
      // Durable callers restore against their journal and reject unknown external changes.
      guard restoreOnFailure else { throw error }
      var recoveryFailed = false
      for (url, bytes) in snapshots {
        do {
          if let bytes {
            try bytes.write(to: url, options: .atomic)
            try OwlPrivateStorage.hardenFile(url)
          } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
          }
        } catch { recoveryFailed = true }
      }
      if recoveryFailed { throw OwlTemplateError.recoveryFailed }
      throw error
    }
  }
}
