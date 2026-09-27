import Foundation

/// Native content backup and explicit ID-based merge. All disk locations are injected.
struct OwlTemplateBackup {
  enum Kind: String { case new, identical, update }
  struct Row: Identifiable {
    var entry: OwlTemplateEntry
    let current: OwlTemplateEntry?
    let kind: Kind
    let originalInvocationMode: OwlTemplateEntry.InvocationMode
    var selected: Bool
    var id: UUID { entry.id }
  }
  struct Preview: Identifiable {
    let id = UUID()
    let baseline: OwlTemplateLibrary
    var rows: [Row]
    var library: OwlTemplateLibrary {
      var result = baseline
      for row in rows where row.selected && row.kind != .identical {
        if let index = result.entries.firstIndex(where: { $0.id == row.id }) { result.entries[index] = row.entry }
        else { result.entries.append(row.entry) }
      }
      return result
    }
    var conflicts: [String] {
      var codes: [String: Int] = [:]
      for entry in library.entries where entry.invocationMode != .searchOnly {
        for code in [entry.trigger].compactMap({ $0 }) + entry.candidateAliases { codes[code, default: 0] += 1 }
      }
      return codes.filter { $0.value > 1 }.map(\.key).sorted()
    }
    var selectedCount: Int { rows.filter { $0.selected && $0.kind != .identical }.count }
    mutating func makeSearchOnly(id: UUID) {
      guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
      preserveSource(at: index)
      rows[index].entry.trigger = nil
      rows[index].entry.candidateAliases = []
      rows[index].entry.invocationMode = .searchOnly
    }
    mutating func changeTrigger(id: UUID, to code: String) {
      guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
      if code.isEmpty { makeSearchOnly(id: id); return }
      preserveSource(at: index)
      rows[index].entry.trigger = code
      rows[index].entry.invocationMode = rows[index].originalInvocationMode
      rows[index].entry.candidateAliases = []
    }
    private mutating func preserveSource(at index: Int) {
      if rows[index].entry.migrationSource == nil, let code = rows[index].entry.trigger {
        rows[index].entry.migrationSource = .init(sourceFile: "native-backup", record: index + 1, originalCode: code)
      }
    }
  }
  struct Outcome {
    let library: OwlTemplateLibrary
    let backupURL: URL?
  }
  let rimeDir: URL

  static func decode(_ data: Data) throws -> OwlTemplateLibrary {
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["formatVersion"] as? Int, version == 1 else {
        throw OwlTemplateError.invalid("不支持的原生备份版本或格式。")
      }
      try checkKeys(object, allowed: OwlTemplateLibrary.CodingKeys.allCases.map(\.rawValue))
      guard let entries = object["entries"] as? [[String: Any]] else { throw OwlTemplateError.invalid("备份条目必须是数组。") }
      for entry in entries {
        try checkKeys(entry, allowed: OwlTemplateEntry.CodingKeys.allCases.map(\.rawValue))
        if let parameters = entry["parameters"] as? [[String: Any]] {
          for parameter in parameters { try checkKeys(parameter, allowed: OwlTemplateParameter.CodingKeys.allCases.map(\.rawValue)) }
        }
        if let source = entry["migrationSource"] as? [String: Any] {
          try checkKeys(source, allowed: OwlTemplateMigrationSource.CodingKeys.allCases.map(\.rawValue))
        }
        if let source = entry["importSource"] as? [String: Any] {
          try checkKeys(source, allowed: OwlTemplateImportSource.CodingKeys.allCases.map(\.rawValue))
        }
      }
      let library = try JSONDecoder().decode(OwlTemplateLibrary.self, from: data)
      guard Set(library.entries.map(\.id)).count == library.entries.count else { throw OwlTemplateError.invalid("备份中有重复 ID。") }
      // Cross-entry trigger collisions are shown in the merge preview, never silently discarded.
      for entry in library.entries { try OwlTemplateStore.validate(.init(entries: [entry])) }
      return library
    } catch let error as OwlTemplateError { throw error }
    catch { throw OwlTemplateError.invalid("原生备份无法完整读取；请保留原文件并核对格式。") }
  }

  private static func checkKeys(_ object: [String: Any], allowed: [String]) throws {
    guard Set(object.keys).isSubset(of: Set(allowed)) else {
      throw OwlTemplateError.invalid("备份包含当前版本无法保留的字段，请使用支持该格式的版本。")
    }
  }

  func currentLibrary() throws -> OwlTemplateLibrary {
    switch OwlTemplateStore.mode(rimeDir: rimeDir) {
    case .empty: return OwlTemplateLibrary()
    case .unified: return try OwlTemplateStore.load(rimeDir: rimeDir)
    case .legacy: throw OwlTemplateError.legacyRequiresMigration
    case .unavailable(let message): throw OwlTemplateError.invalid(message)
    }
  }

  func preview(data: Data) throws -> Preview {
    let incoming = try Self.decode(data)
    return try OwlTemplateStore.exclusively {
      let baseline = try currentLibrary()
      let rows = try incoming.entries.map { entry -> Row in
        let current = baseline.entries.first { $0.id == entry.id }
        let kind: Kind
    let originalInvocationMode: OwlTemplateEntry.InvocationMode
        if let current {
          kind = try OwlTemplateStore.encoded(.init(entries: [current])) == OwlTemplateStore.encoded(.init(entries: [entry])) ? .identical : .update
        } else { kind = .new }
        return Row(entry: entry, current: current, kind: kind, originalInvocationMode: entry.invocationMode, selected: kind == .new)
      }
      return Preview(baseline: baseline, rows: rows)
    }
  }

  func export(to destination: URL) throws {
    try OwlTemplateStore.exclusively {
      try Self.writeBackup(OwlTemplateStore.encoded(currentLibrary()), to: destination)
    }
  }

  private static func writeBackup(_ data: Data, to destination: URL) throws {
    _ = try decode(data)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".owl-native-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: .atomic)
    try OwlPrivateStorage.hardenFile(temporary)
    guard try Data(contentsOf: temporary) == data else { throw OwlTemplateError.invalid("备份写入核对失败。") }
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
    } else { try FileManager.default.moveItem(at: temporary, to: destination) }
  }

  func restore(_ preview: Preview, checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> Outcome {
    guard preview.conflicts.isEmpty else { throw OwlTemplateError.invalid("生效触发词或候选别名冲突，请先处理后恢复。") }
    return try commit(preview.library, expected: preview.baseline, checkpoint: checkpoint)
  }

  func delete(id: UUID, expected: OwlTemplateLibrary, checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> Outcome {
    guard expected.entries.contains(where: { $0.id == id }) else { throw OwlTemplateError.changedOnDisk }
    var next = expected
    next.entries.removeAll { $0.id == id }
    return try commit(next, expected: expected, checkpoint: checkpoint)
  }

  // Shared batch entry for native restore/delete and an explicitly confirmed Raycast import.
  func commit(_ next: OwlTemplateLibrary, expected: OwlTemplateLibrary,
                      checkpoint: @escaping (String) throws -> Void) throws -> Outcome {
    try OwlTemplateStore.exclusively {
      let transaction = OwlTemplateMigration(rimeDir: rimeDir)
      try transaction.recoverIfNeeded()
      let current = try currentLibrary()
      guard try OwlTemplateStore.encoded(current) == OwlTemplateStore.encoded(expected) else { throw OwlTemplateError.changedOnDisk }
      try OwlTemplateStore.validate(next)
      guard try OwlTemplateStore.encoded(next) != OwlTemplateStore.encoded(current) else {
        return Outcome(library: current, backupURL: nil)
      }
      let backupDirectory = rimeDir.appendingPathComponent(".owl-backup/templates-" + UUID().uuidString)
      try checkpoint("backup")
      try OwlPrivateStorage.prepareDirectory(backupDirectory)
      let backupURL = backupDirectory.appendingPathComponent(OwlTemplateStore.fileName)
      let source = rimeDir.appendingPathComponent(OwlTemplateStore.fileName)
      let bytes = FileManager.default.fileExists(atPath: source.path) ? try Data(contentsOf: source) : try OwlTemplateStore.encoded(current)
      guard try OwlTemplateStore.encoded(Self.decode(bytes)) == OwlTemplateStore.encoded(current) else { throw OwlTemplateError.changedOnDisk }
      try Self.writeBackup(bytes, to: backupURL)
      try checkpoint("backupVerified")
      do { try transaction.commitLibrary(next, expected: expected, checkpoint: checkpoint) }
      catch {
        let commitError = error
        // A final journal bookkeeping error can follow a completely committed batch.
        // Finish recovery before reporting its actual outcome; never reapply the merge.
        try transaction.recoverIfNeeded()
        guard try OwlTemplateStore.encoded(currentLibrary()) == OwlTemplateStore.encoded(next) else { throw commitError }
      }
      return Outcome(library: next, backupURL: backupURL)
    }
  }
}
