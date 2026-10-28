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
  private struct Journal: Codable {
    var version = 1
    let migrationID: UUID
    var phase: String
    let snapshots: [Snapshot]
    let expectedWrites: [String: Data]
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
  private static let journalName = directoryName + "/journal.json"
  private static let planName = directoryName + "/plan.json"
  private static let sourceNames = ["owl_quick_send.json", "owl_quick_send.txt", "owl_prompts.json", "owl_prompts.txt",
                                    OwlTemplateStore.fileName, OwlTemplateStore.stateFileName]
  private static let targetNames = [OwlTemplateStore.fileName, OwlTemplateStore.dictFileName, "rime_ice.custom.yaml",
                                    OwlTemplateStore.stateFileName, "owltype/rollback-manifest.json"]
  let dataDir: URL
  private var writer: OwlConfigWriter { OwlConfigWriter(dataDir: dataDir) }
  init(dataDir: URL) { self.dataDir = dataDir }
  private func url(_ name: String) -> URL { dataDir.appendingPathComponent(name) }
  private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
  private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

  static func hasPendingRecovery(dataDir: URL) -> Bool {
    let path = dataDir.appendingPathComponent(journalName)
    guard FileManager.default.fileExists(atPath: path.path) else { return false }
    guard let journal = try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: path)), journal.version == 1 else { return true }
    return journal.phase != "committed" && journal.phase != "rolledBack"
  }

  private func snapshot(_ name: String) throws -> Snapshot {
    guard exists(name) else { return Snapshot(name: name, bytes: nil, digest: nil, permissions: nil) }
    let bytes = try Data(contentsOf: url(name))
    let attributes = try FileManager.default.attributesOfItem(atPath: url(name).path)
    return Snapshot(name: name, bytes: bytes, digest: Self.hash(bytes), permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
  }
  private func matches(_ snapshot: Snapshot) throws -> Bool {
    if !exists(snapshot.name) { return snapshot.bytes == nil }
    return try Data(contentsOf: url(snapshot.name)) == snapshot.bytes
  }
  private func persist<T: Encodable>(_ value: T, name: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(value)
    try OwlPrivateStorage.prepareDirectory(url(name).deletingLastPathComponent())
    try bytes.write(to: url(name), options: .atomic)
    try OwlPrivateStorage.hardenFile(url(name))
    guard try Data(contentsOf: url(name)) == bytes else { throw Failure.recovery }
  }

  /// prepare preserves a plan (and its UUIDs) while the source bytes remain identical.
  func prepare() throws -> Plan {
    try OwlTemplateStore.withWriteLock(dataDir: dataDir) {
      try recoverIfNeeded()
      if OwlTemplateStore.mode(dataDir: dataDir) == .unified { throw Failure.alreadyUnified }
      if exists(Self.planName) {
        let previous = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url(Self.planName)))
        if previous.version == 1, previous.sources.count == Self.sourceNames.count, try previous.sources.allSatisfy({ try matches($0) }) { return previous }
      }
      var sources: [Snapshot] = []
      var issues: [Issue] = []
      for name in Self.sourceNames {
        do { sources.append(try snapshot(name)) }
        catch { issues.append(Issue(file: name, record: nil, message: "文件无法读取，请检查权限。")) }
      }
      var existing = [OwlTemplateEntry]()
      if exists(OwlTemplateStore.stateFileName) {
        issues.append(Issue(file: OwlTemplateStore.stateFileName, record: nil, message: "启用标记无效，不能用迁移覆盖已启用的库。"))
      }
      if exists(OwlTemplateStore.fileName) {
        do { existing = try OwlTemplateStore.load(dataDir: dataDir).entries }
        catch { issues.append(Issue(file: OwlTemplateStore.fileName, record: nil, message: "已有新库无法严格读取，不能覆盖。")) }
      }
      var plan = Plan(id: UUID(), sources: sources, entries: [], existingEntries: existing, issues: issues, collapsedRows: 0)
      if exists("owl_quick_send.json") { auditJSON("owl_quick_send.json", prompt: false, plan: &plan) }
      else if exists("owl_quick_send.txt") { auditTable(plan: &plan) }
      if exists("owl_prompts.json") { auditJSON("owl_prompts.json", prompt: true, plan: &plan) }
      else if exists("owl_prompts.txt") {
        do {
          let lines = try String(contentsOf: url("owl_prompts.txt"), encoding: .utf8).components(separatedBy: .newlines)
          if lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
            plan.issues.append(Issue(file: "owl_prompts.txt", record: nil, message: "仅有提示词候选表，缺少正文原件 owl_prompts.json。"))
          }
        } catch { plan.issues.append(Issue(file: "owl_prompts.txt", record: nil, message: "候选表无法读取。")) }
      }
      try persist(plan, name: Self.planName)
      return plan
    }
  }

  private func auditJSON(_ file: String, prompt: Bool, plan: inout Plan) {
    let records: [Any]
    do {
      let bytes = try Data(contentsOf: url(file))
      guard String(data: bytes, encoding: .utf8) != nil,
            let decoded = try JSONSerialization.jsonObject(with: bytes) as? [Any] else {
        plan.issues.append(Issue(file: file, record: nil, message: "文件必须是 UTF-8 JSON 数组。")); return
      }
      records = decoded
    } catch { plan.issues.append(Issue(file: file, record: nil, message: "JSON 无法解析或读取；未使用派生表代替原件。")); return }
    for (index, record) in records.enumerated() {
      let position = index + 1
      guard let object = record as? [String: Any] else {
        plan.issues.append(Issue(file: file, record: position, message: "记录必须是对象。")); continue
      }
      let fields = prompt ? ["code", "title", "body", "category"] : ["code", "text"]
      let wrong = fields.filter { object[$0] as? String == nil }
      for field in wrong { plan.issues.append(Issue(file: file, record: position, message: "字段 \(field) 缺失或不是文本。")) }
      if !Set(object.keys).subtracting(fields).isEmpty {
        plan.issues.append(Issue(file: file, record: position, message: "记录包含未支持字段，请先核对原件。"))
      }
      guard wrong.isEmpty, let code = object["code"] as? String, let body = object[prompt ? "body" : "text"] as? String else { continue }
      let title = prompt ? object["title"] as? String ?? "" : displayTitle(body)
      var entry = makeEntry(code: code, title: title, body: body, prompt: prompt, file: file, position: position)
      if prompt, let category = object["category"] as? String, !category.isEmpty { entry.tags = [category] }
      appendAudited(entry, plan: &plan)
    }
  }
  private func displayTitle(_ body: String) -> String {
    body.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
      .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
  }
  private func makeEntry(code: String, title: String, body: String, prompt: Bool, file: String, position: Int) -> OwlTemplateEntry {
    var entry = OwlTemplateEntry(title: title, body: body)
    entry.trigger = code
    entry.invocationMode = .candidate
    entry.migrationSource = OwlTemplateMigrationSource(sourceFile: file, record: position, originalCode: code)
    if prompt {
      entry.bodyType = .template; entry.syntax = .legacyDoubleBraces; entry.category = .prompt
      entry.candidateAliases = ["v" + code]
      entry.parameters = OwlPromptVariables.extract(from: body).map {
        OwlTemplateParameter(key: "n:" + $0, name: $0, isRequired: false, defaultValue: "", options: [])
      }
    }
    return entry
  }
  private func appendAudited(_ entry: OwlTemplateEntry, plan: inout Plan) {
    if let source = entry.migrationSource {
      // Invalid codes remain visible and can be resolved to a new code or search-only.
      if entry.trigger?.range(of: "^[a-z][a-z0-9]{0,31}$", options: .regularExpression) == nil {
        plan.issues.append(Issue(file: source.sourceFile, record: source.record, message: "原编码无效，请改码或选择仅搜索。"))
      }
      var textCheck = entry
      textCheck.trigger = nil; textCheck.candidateAliases = []; textCheck.invocationMode = .searchOnly
      do { try OwlTemplateStore.validate(OwlTemplateLibrary(entries: [textCheck])) }
      catch { plan.issues.append(Issue(file: source.sourceFile, record: source.record, message: "标题或正文无效，请修复原记录后重新检查。")) }
    }
    plan.entries.append(entry)
  }
  private func auditTable(plan: inout Plan) {
    let file = "owl_quick_send.txt"
    guard let text = try? String(contentsOf: url(file), encoding: .utf8) else {
      plan.issues.append(Issue(file: file, record: nil, message: "历史短语表无法读取。")); return
    }
    var rows: [OwlTemplateEntry] = []
    for (index, line) in text.components(separatedBy: .newlines).enumerated() {
      if line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
      let parts = line.components(separatedBy: "\t")
      guard (2...3).contains(parts.count), parts.count != 3 || Int(parts[2]) != nil else {
        plan.issues.append(Issue(file: file, record: index + 1, message: "历史记录必须是正文、编码及可选数字权重。")); continue
      }
      rows.append(makeEntry(code: parts[1], title: displayTitle(parts[0]), body: parts[0], prompt: false, file: file, position: index + 1))
    }
    let groups = Dictionary(grouping: rows, by: { $0.trigger ?? "" })
    for row in rows {
      let code = row.trigger ?? ""
      let bases = groups[String(code.dropFirst())] ?? []
      if code.hasPrefix("v"), groups[code]?.count == 1, bases.count == 1,
         Data(bases[0].body.utf8) == Data(row.body.utf8) { plan.collapsedRows += 1 }
      else { appendAudited(row, plan: &plan) }
    }
  }

  func conflicts(in plan: Plan) -> [String] {
    var codes = [String: Int]()
    for entry in plan.library.entries where entry.invocationMode != .searchOnly {
      for code in ([entry.trigger].compactMap { $0 } + entry.candidateAliases) { codes[code, default: 0] += 1 }
    }
    return codes.filter { $0.value > 1 }.map(\.key).sorted()
  }

  func resolve(_ plan: Plan, id: UUID, code: String?) throws -> Plan {
    try OwlTemplateStore.withWriteLock(dataDir: dataDir) {
      try verifyPlan(plan)
      var updated = plan
      guard let index = updated.entries.firstIndex(where: { $0.id == id }) else { throw Failure.changed }
      let entry = updated.entries[index]
      updated.entries[index].trigger = code
      updated.entries[index].invocationMode = code == nil ? .searchOnly : .candidate
      updated.entries[index].candidateAliases = code.map { entry.category == .prompt ? ["v" + $0] : [] } ?? []
      try OwlTemplateStore.validate(OwlTemplateLibrary(entries: [updated.entries[index]]))
      if let source = entry.migrationSource {
        updated.issues.removeAll { $0.file == source.sourceFile && $0.record == source.record && $0.message == "原编码无效，请改码或选择仅搜索。" }
      }
      try persist(updated, name: Self.planName)
      return updated
    }
  }

  private func verifyPlan(_ plan: Plan) throws {
    guard plan.version == 1, try plan.sources.allSatisfy({ try matches($0) }),
          exists(Self.planName) else { throw Failure.changed }
    let saved = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url(Self.planName)))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    guard try encoder.encode(saved) == encoder.encode(plan) else { throw Failure.changed }
  }

  private func writes(for plan: Plan) throws -> [OwlTemplateStore.PreparedWrite] {
    var writes = try OwlTemplateStore.prepareWrites(plan.library, writer: writer)
    if let index = writes.firstIndex(where: { $0.fileName == "rime_ice.custom.yaml" }) {
      var yaml = writes[index].contents
      for marker in [OwlManagedMarker.quickSendRimeIce, OwlManagedMarker.promptsRimeIce] {
        let begin = "  # >>> " + marker
        let end = "  # <<< " + marker
        if let first = yaml.range(of: begin), let last = yaml.range(of: end), first.lowerBound < last.upperBound {
          yaml.removeSubrange(first.lowerBound..<last.upperBound)
        } else if yaml.contains(begin) || yaml.contains(end) { throw Failure.issues }
      }
      // Unknown registrations cannot be silently removed or left active alongside the new table.
      if yaml.contains("table_translator@owl_quick_send") || yaml.contains("table_translator@owl_prompts") { throw Failure.issues }
      writes[index] = OwlTemplateStore.PreparedWrite(fileName: "rime_ice.custom.yaml", contents: yaml, marker: OwlTemplateStore.patch.marker)
    }
    if let last = writes.indices.last {
      writes[last] = OwlTemplateStore.PreparedWrite(fileName: OwlTemplateStore.stateFileName,
        contents: try OwlTemplateStore.activationContents(transactionID: plan.id), marker: writes[last].marker)
    }
    return writes
  }

  private func stage(_ plan: Plan, checkpoint: (String) throws -> Void = { _ in }) throws -> (Journal, [OwlTemplateStore.PreparedWrite]) {
    try verifyPlan(plan)
    guard plan.issues.isEmpty else { throw Failure.issues }
    guard conflicts(in: plan).isEmpty else { throw Failure.conflict }
    let writes = try writes(for: plan)
    let names = Array(Set(Self.targetNames + Self.sourceNames)).sorted()
    let snapshots = try names.map { name in
      try checkpoint("snapshot:" + name)
      return try snapshot(name)
    }
    let journal = Journal(migrationID: plan.id, phase: "prepared", snapshots: snapshots,
                          expectedWrites: Dictionary(uniqueKeysWithValues: writes.map { ($0.fileName, Data($0.contents.utf8)) }))
    try persist(journal, name: Self.journalName)
    return (journal, writes)
  }

  /// Persist before-images before handing the fixed write set to a batch executor. A fresh
  /// instance can recover if execution terminates without reaching commit/finalization.
  @discardableResult func prepareTransaction(_ plan: Plan) throws -> [OwlTemplateStore.PreparedWrite] {
    try OwlTemplateStore.withWriteLock(dataDir: dataDir) {
      try recoverIfNeeded()
      let (_, writes) = try stage(plan)
      return writes
    }
  }

  func commit(_ plan: Plan, checkpoint: @escaping (String) throws -> Void = { _ in }) throws {
    try OwlTemplateStore.withWriteLock(dataDir: dataDir) {
      try recoverIfNeeded()
      let staged = try stage(plan, checkpoint: checkpoint)
      try execute(staged, library: plan.library, checkpoint: checkpoint) {
        for source in plan.sources where !Self.targetNames.contains(source.name) {
          guard try self.matches(source) else { throw Failure.changed }
        }
      }
    }
    OwlTemplateStore.notifyCommittedLibrary(dataDir: dataDir)
  }

  /// Reuse the migration journal for the same fixed template outputs, with a new transaction ID.
  /// Caller owns user-facing backup/preview. No legacy input or migration plan is consulted.
  private func stageLibrary(_ library: OwlTemplateLibrary, expected: OwlTemplateLibrary,
                            checkpoint: (String) throws -> Void) throws -> (Journal, [OwlTemplateStore.PreparedWrite]) {
    let current: OwlTemplateLibrary
    switch OwlTemplateStore.mode(dataDir: dataDir) {
    case .empty: current = OwlTemplateLibrary()
    case .unified: current = try OwlTemplateStore.load(dataDir: dataDir)
    case .legacy: throw OwlTemplateError.legacyRequiresMigration
    case .unavailable(let message): throw OwlTemplateError.invalid(message)
    }
    guard try OwlTemplateStore.encoded(current) == OwlTemplateStore.encoded(expected) else { throw OwlTemplateError.changedOnDisk }
    let id = UUID()
    let snapshots = try Self.targetNames.map { name in
      try checkpoint("snapshot:" + name)
      return try snapshot(name)
    }
    var writes = try OwlTemplateStore.prepareWrites(library, writer: writer)
    let last = writes.count - 1
    writes[last] = .init(fileName: OwlTemplateStore.stateFileName,
      contents: try OwlTemplateStore.activationContents(transactionID: id), marker: writes[last].marker)
    // Snapshot hooks/other writers must not move the baseline between preview validation
    // and journal publication. Recheck both semantic baseline and exact fixed target bytes.
    let reread = current.entries.isEmpty && !exists(OwlTemplateStore.fileName) ? OwlTemplateLibrary() : try OwlTemplateStore.load(dataDir: dataDir)
    guard try OwlTemplateStore.encoded(reread) == OwlTemplateStore.encoded(expected),
          try snapshots.allSatisfy({ try matches($0) }) else { throw OwlTemplateError.changedOnDisk }
    let journal = Journal(migrationID: id, phase: "prepared", snapshots: snapshots,
      expectedWrites: Dictionary(uniqueKeysWithValues: writes.map { ($0.fileName, Data($0.contents.utf8)) }))
    try persist(journal, name: Self.journalName)
    return (journal, writes)
  }

  /// Failure-injection tests can stop after staging and restart a fresh recovery instance.
  func prepareLibraryTransaction(_ library: OwlTemplateLibrary, expected: OwlTemplateLibrary) throws -> [OwlTemplateStore.PreparedWrite] {
    try OwlTemplateStore.withWriteLock(dataDir: dataDir) {
      try recoverIfNeeded()
      return try stageLibrary(library, expected: expected, checkpoint: { _ in }).1
    }
  }

  func commitLibrary(_ library: OwlTemplateLibrary, expected: OwlTemplateLibrary,
                     checkpoint: @escaping (String) throws -> Void = { _ in }) throws {
    try OwlTemplateStore.withWriteLock(dataDir: dataDir) {
      try recoverIfNeeded()
      let staged = try stageLibrary(library, expected: expected, checkpoint: checkpoint)
      try execute(staged, library: library, checkpoint: checkpoint)
    }
    OwlTemplateStore.notifyCommittedLibrary(dataDir: dataDir)
  }

  private func execute(_ staged: (Journal, [OwlTemplateStore.PreparedWrite]), library: OwlTemplateLibrary,
                       checkpoint: @escaping (String) throws -> Void, verifySources: () throws -> Void = {}) throws {
    var journal = staged.0
    do {
      try checkpoint("journal")
      let committingWriter = OwlConfigWriter(dataDir: dataDir, writeCheckpoint: checkpoint)
      try OwlTemplateStore.commitPreparedWrites(staged.1, library: library, writer: committingWriter, beforeWrite: { name in
        try verifySources()
        if let original = journal.snapshots.first(where: { $0.name == name }) {
          guard try self.matches(original) else { throw Failure.changed }
        }
        try checkpoint(name)
      }, batchTimestamp: "migration-" + journal.migrationID.uuidString, restoreOnFailure: false)
    } catch {
      try restore(&journal, beforeRestore: { try checkpoint("restore:" + $0) })
      throw error
    }
    // All outputs plus transaction identity are committed. Recover can finish bookkeeping.
    journal.phase = "committed"
    try persist(journal, name: Self.journalName)
  }

  func recoverIfNeeded(beforeRestore: (String) throws -> Void = { _ in }) throws {
    var settled = false
    defer { if settled { OwlTemplateStore.notifyCommittedLibrary(dataDir: dataDir) } }
    try OwlTemplateStore.withWriteLock(dataDir: dataDir) {
      guard exists(Self.journalName) else { return }
      var journal: Journal
      do { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url(Self.journalName))) }
      catch { throw Failure.invalidJournal }
      let allowed = Set(Self.targetNames + Self.sourceNames)
      guard journal.version == 1, ["prepared", "rollingBack", "committed", "rolledBack"].contains(journal.phase),
            [allowed, Set(Self.targetNames)].contains(Set(journal.snapshots.map(\.name))),
            journal.snapshots.count == Set(journal.snapshots.map(\.name)).count,
            Set(journal.expectedWrites.keys) == Set(Self.targetNames.filter { $0 != "owltype/rollback-manifest.json" }),
            journal.snapshots.allSatisfy({ $0.digest == $0.bytes.map(Self.hash) }) else { throw Failure.invalidJournal }
      if journal.phase == "committed" || journal.phase == "rolledBack" { return }
      if journal.phase == "rollingBack" {
        try restore(&journal, beforeRestore: beforeRestore)
        settled = true
        return
      }
      // Identity distinguishes this batch from an already-active library (including future
      // native restore/delete batches). Never infer completion from committed=true alone.
      let currentState = try? JSONDecoder().decode(OwlTemplateStore.Activation.self,
        from: Data(contentsOf: url(OwlTemplateStore.stateFileName)))
      if let state = currentState, state.transactionID == journal.migrationID, state.committed, state.formatVersion == 1 {
        guard try journal.expectedWrites.allSatisfy({ name, bytes in
          guard exists(name) else { return false }
          return try Data(contentsOf: url(name)) == bytes
        }) else { throw Failure.changed }
        _ = try OwlTemplateStore.loadCommittedBytes(dataDir: dataDir)
        journal.phase = "committed"
        try persist(journal, name: Self.journalName)
        settled = true
        return
      }
      try restore(&journal, beforeRestore: beforeRestore)
      settled = true
    }
  }
  private func restore(_ journal: inout Journal, beforeRestore: (String) throws -> Void = { _ in }) throws {
    // Refuse to overwrite a target that is neither a before-image nor our staged output.
    // The manifest may have our own appended rows, identified by this transaction timestamp.
    for original in journal.snapshots where Self.targetNames.contains(original.name) {
      if try matches(original) { continue }
      if original.name == "owltype/rollback-manifest.json" {
        guard try ownsManifestChanges(journal, original: original) else { throw Failure.changed }
      } else {
        guard exists(original.name), let expected = journal.expectedWrites[original.name],
              try Data(contentsOf: url(original.name)) == expected else { throw Failure.changed }
      }
    }
    // Record rollback intent before touching a target. If recovery itself stops after restoring
    // the library but before removing activation, the next process continues this same rollback.
    journal.phase = "rollingBack"
    try persist(journal, name: Self.journalName)
    var failed = false
    // Restore only transaction targets. Legacy files are immutable, never overwrite external edits.
    for snapshot in journal.snapshots where Self.targetNames.contains(snapshot.name) {
      do {
        try beforeRestore(snapshot.name)
        if let bytes = snapshot.bytes {
          try OwlPrivateStorage.prepareDirectory(url(snapshot.name).deletingLastPathComponent())
          try bytes.write(to: url(snapshot.name), options: .atomic)
          try FileManager.default.setAttributes([.posixPermissions: snapshot.permissions ?? 0o600], ofItemAtPath: url(snapshot.name).path)
        } else if exists(snapshot.name) { try FileManager.default.removeItem(at: url(snapshot.name)) }
        guard try matches(snapshot) else { throw Failure.recovery }
      } catch { failed = true }
    }
    guard !failed else { throw Failure.recovery }
    journal.phase = "rolledBack"
    try persist(journal, name: Self.journalName)
  }

  private func ownsManifestChanges(_ journal: Journal, original: Snapshot) throws -> Bool {
    guard exists(original.name) else { return original.bytes == nil }
    let current = try JSONDecoder().decode(OwlRollbackManifest.self, from: Data(contentsOf: url(original.name)))
    let before = try original.bytes.map { try JSONDecoder().decode(OwlRollbackManifest.self, from: $0) }
    let count = before?.files.count ?? 0
    guard current.files.count >= count else { return false }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    if let before {
      guard try encoder.encode(Array(current.files.prefix(count))) == encoder.encode(before.files) else { return false }
    }
    return current.files.dropFirst(count).allSatisfy {
      $0.ts == "migration-" + journal.migrationID.uuidString && Self.targetNames.contains(URL(fileURLWithPath: $0.path).lastPathComponent)
    }
  }

  @discardableResult func runAutomatically() throws -> Bool {
    try recoverIfNeeded()
    let mode = OwlTemplateStore.mode(dataDir: dataDir)
    guard mode == .legacy else { return false }
    let plan = try prepare()
    guard plan.issues.isEmpty, conflicts(in: plan).isEmpty else { return false }
    try commit(plan)
    return true
  }
}
