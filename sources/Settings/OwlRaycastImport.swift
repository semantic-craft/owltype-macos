import Foundation
import CryptoKit

/// Original source is immutable through ordinary editing; identity is independent of local edits.
struct OwlTemplateImportSource: Codable, Equatable, Sendable {
  enum CodingKeys: String, CodingKey, CaseIterable { case version, originalName, originalBody, originalKeyword }
  var version = 1
  let originalName: String
  let originalBody: String
  let originalKeyword: String?

  var fingerprint: String {
    var hash = SHA256()
    // Length framing avoids collisions between fields. Missing/empty keywords both mean no trigger.
    for value in [String(version), originalName, originalBody, originalKeyword ?? ""] {
      let bytes = Data(value.utf8)
      hash.update(data: Data("\(bytes.count):".utf8)); hash.update(data: bytes)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// Local schema conversion and user choices. Rendering stays in OwlTemplateEngine, writing in Backup.
struct OwlRaycastImport {
  enum DuplicateKind: Equatable { case identical, alreadyImported }
  struct Row: Identifiable {
    let id = UUID()
    let number: Int
    let originalTitle: String
    let originalBody: String?
    let fieldErrors: [String]
    let unsupportedKeys: [String]
    var entry: OwlTemplateEntry?
    var selected = false
    var syntaxIssues: [OwlTemplateEngine.Diagnostic] {
      entry.map { OwlRaycastImport.compatibilityIssues($0) } ?? []
    }
  }
  struct Preview: Identifiable {
    let id = UUID()
    let baseline: OwlTemplateLibrary
    var rows: [Row]

    struct Assessment {
      var duplicates: [Int: DuplicateKind] = [:]
      var conflicts: [Int: [String]] = [:]
      var selectedIndices: [Int] = []
      var pendingCount = 0
    }

    /// One pass of semantic/source identity, then a trigger-count index. The view shares this
    /// snapshot across all rows rather than repeatedly parsing every other row on the main thread.
    var assessment: Assessment {
      var result = Assessment()
      var meanings = Set(baseline.entries.compactMap { OwlRaycastImport.semanticKey($0) })
      var sources = Set(baseline.entries.compactMap { $0.importSource?.fingerprint })
      for index in rows.indices {
        guard let entry = rows[index].entry else { continue }
        let meaning = OwlRaycastImport.semanticKey(entry)
        let source = entry.importSource?.fingerprint
        if let meaning, meanings.contains(meaning) { result.duplicates[index] = .identical }
        else if let source, sources.contains(source) { result.duplicates[index] = .alreadyImported }
        else if rows[index].selected {
          result.selectedIndices.append(index)
          if entry.isPendingReview { result.pendingCount += 1 }
          if let meaning { meanings.insert(meaning) }
          if let source { sources.insert(source) }
        }
      }
      var codes: [String: Int] = [:]
      let active = baseline.entries + result.selectedIndices.compactMap { rows[$0].entry }
      for entry in active {
        for code in Set([entry.trigger].compactMap { $0 } + entry.candidateAliases) { codes[code, default: 0] += 1 }
      }
      let selected = Set(result.selectedIndices)
      for index in rows.indices where result.duplicates[index] == nil {
        guard let trigger = rows[index].entry?.trigger, !trigger.isEmpty else { continue }
        if codes[trigger, default: 0] > (selected.contains(index) ? 1 : 0) { result.conflicts[index] = [trigger] }
      }
      return result
    }

    func duplicateKind(at index: Int) -> DuplicateKind? { assessment.duplicates[index] }
    func conflicts(at index: Int) -> [String] { assessment.conflicts[index] ?? [] }
    var selectedIndices: [Int] { assessment.selectedIndices }
    var selectedCount: Int { assessment.selectedIndices.count }
    var pendingCount: Int { assessment.pendingCount }
    var validationMessage: String? { validationMessage(for: assessment) }
    func validationMessage(for review: Assessment) -> String? {
      for index in rows.indices where rows[index].selected {
        if !rows[index].fieldErrors.isEmpty { return "第 \(rows[index].number) 项字段错误，请取消选择。" }
      }
      for index in review.selectedIndices {
        if review.conflicts[index] != nil { return "第 \(rows[index].number) 项触发词冲突，请改词、仅搜索或跳过。" }
        if let entry = rows[index].entry, !entry.isPendingReview, !OwlRaycastImport.compatibilityIssues(entry).isEmpty {
          return "第 \(rows[index].number) 项语法需要处理。"
        }
      }
      do { try OwlTemplateStore.validate(library(for: review)) } catch { return error.localizedDescription }
      return nil
    }
    var library: OwlTemplateLibrary { library(for: assessment) }
    private func library(for review: Assessment) -> OwlTemplateLibrary {
      var next = baseline
      next.entries += review.selectedIndices.compactMap { rows[$0].entry }
      return next
    }
    mutating func makeSearchOnly(at index: Int) {
      rows[index].entry?.trigger = nil
      rows[index].entry?.candidateAliases = []
      rows[index].entry?.invocationMode = .searchOnly
    }
    mutating func changeTrigger(at index: Int, to trigger: String) {
      rows[index].entry?.trigger = trigger.isEmpty ? nil : trigger
      rows[index].entry?.candidateAliases = []
      if trigger.isEmpty { rows[index].entry?.invocationMode = .searchOnly }
    }
    mutating func convertToPlainText(at index: Int) {
      guard var entry = rows[index].entry else { return }
      OwlRaycastImport.convertToPlainText(&entry)
      rows[index].entry = entry
      rows[index].selected = true
    }
  }

  let rimeDir: URL

  func preview(data: Data) throws -> Preview {
    let objects: [Any]
    do {
      guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
        throw OwlTemplateError.invalid("Raycast 基础 JSON 须为条目数组。")
      }
      objects = array
    } catch let error as OwlTemplateError { throw error }
    catch { throw OwlTemplateError.invalid("JSON 无法读取，请保留原文件并检查格式。") }
    let baseline = try OwlTemplateBackup(rimeDir: rimeDir).currentLibrary()
    var preview = Preview(baseline: baseline, rows: objects.enumerated().map { Self.row($0.element, number: $0.offset + 1) })
    for index in preview.rows.indices {
      preview.rows[index].selected = preview.rows[index].entry.map { !$0.isPendingReview } ?? false
    }
    let review = preview.assessment
    for index in review.duplicates.keys { preview.rows[index].selected = false }
    return preview
  }

  func commit(_ preview: Preview, checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> OwlTemplateBackup.Outcome {
    if let message = preview.validationMessage { throw OwlTemplateError.invalid(message) }
    return try OwlTemplateBackup(rimeDir: rimeDir).commit(preview.library, expected: preview.baseline, checkpoint: checkpoint)
  }

  private static func row(_ value: Any, number: Int) -> Row {
    guard let object = value as? [String: Any] else {
      return Row(number: number, originalTitle: "第 \(number) 项", originalBody: nil,
                 fieldErrors: ["记录必须是对象。"], unsupportedKeys: [], entry: nil)
    }
    let title = object["name"] as? String
    let body = object["text"] as? String
    let keyword = object["keyword"] as? String
    var errors: [String] = []
    if title == nil { errors.append("name 必须是字符串。") }
    if body == nil { errors.append("text 必须是字符串。") }
    if object["keyword"] != nil && keyword == nil { errors.append("keyword 必须是字符串或省略。") }
    let extra = Set(object.keys).subtracting(["name", "text", "keyword"]).sorted()
    var entry: OwlTemplateEntry?
    if let title, let body, errors.isEmpty {
      var candidate = OwlTemplateEntry(title: title, body: body)
      candidate.trigger = keyword?.isEmpty == false ? keyword : nil
      candidate.importSource = .init(originalName: title, originalBody: body, originalKeyword: keyword)
      candidate.bodyType = .template
      let parsed = OwlTemplateEngine.parse(candidate)
      // Raycast defaults are optional, including an explicit empty default. Merge named occurrences first.
      candidate.parameters = parsed.parameters.map {
        .init(key: $0.key, name: $0.name, isRequired: $0.defaultValue == nil, defaultValue: $0.defaultValue, options: $0.options)
      }
      let issues = compatibilityIssues(candidate)
      let hasDynamic = parsed.tokens.contains { $0.kind != .literal }
      if !issues.isEmpty { candidate.reviewState = .pending }
      else if !hasDynamic { candidate.bodyType = .plainText; candidate.parameters = [] }
      do { try OwlTemplateStore.validate(.init(entries: [candidate])); entry = candidate }
      catch { errors.append(error.localizedDescription) }
    }
    return Row(number: number, originalTitle: title ?? "第 \(number) 项", originalBody: body,
               fieldErrors: errors, unsupportedKeys: extra, entry: entry)
  }

  /// Strict import compatibility is separate from permissive hand-authored unknown literal fields.
  /// Uses the real parser, ignores the review gate solely for explicit review/editing.
  static func compatibilityIssues(_ entry: OwlTemplateEntry) -> [OwlTemplateEngine.Diagnostic] {
    guard entry.bodyType == .template else { return [] }
    let parsed = OwlTemplateEngine.parse(body: entry.body, bodyType: entry.bodyType, syntax: entry.syntax, definitions: entry.parameters)
    var issues = parsed.diagnostics.map { diagnostic in
      diagnostic.message == "未支持的字段将原样插入。"
        ? OwlTemplateEngine.Diagnostic(severity: diagnostic.severity, range: diagnostic.range,
            message: "含尚未支持的字段，保留待处理，不能执行。")
        : diagnostic
    }
    for parameter in parsed.parameters where parameter.legacy {
      issues.append(.init(severity: .error, range: parameter.ranges[0],
                          message: "双花括号与 Owltype 旧参数语法有歧义；请修正，或明确转为普通文本。"))
    }
    return issues
  }

  @discardableResult
  static func enableAfterReview(_ entry: inout OwlTemplateEntry) -> Bool {
    guard entry.bodyType == .template else { return false }
    var candidate = entry
    let inline = OwlTemplateEngine.parse(body: candidate.body, bodyType: candidate.bodyType, syntax: candidate.syntax)
    let keys = Set(inline.parameters.map(\.key))
    // Explicit review is the boundary for removing definitions whose body positions were deleted.
    candidate.parameters.removeAll { !keys.contains($0.key) }
    for parameter in inline.parameters where !candidate.parameters.contains(where: { $0.key == parameter.key }) {
      candidate.parameters.append(.init(key: parameter.key, name: parameter.name,
        isRequired: parameter.defaultValue == nil, defaultValue: parameter.defaultValue, options: parameter.options))
    }
    guard compatibilityIssues(candidate).isEmpty else { return false }
    candidate.reviewState = nil
    entry = candidate
    return true
  }

  static func convertToPlainText(_ entry: inout OwlTemplateEntry) {
    entry.bodyType = .plainText
    entry.parameters = []
    entry.reviewState = nil
  }

  private struct Meaning: Encodable {
    let title: String
    let body: String
    let trigger: String?
    let bodyType: OwlTemplateEntry.BodyType
    let syntax: OwlTemplateEntry.Syntax
    let parameters: [OwlTemplateParameter]
  }
  private static func semanticKey(_ entry: OwlTemplateEntry) -> Data? {
    let parsed = OwlTemplateEngine.parse(body: entry.body, bodyType: entry.bodyType, syntax: entry.syntax, definitions: entry.parameters)
    let parameters = parsed.parameters.map {
      OwlTemplateParameter(key: $0.key, name: $0.name, isRequired: $0.isRequired, defaultValue: $0.defaultValue, options: $0.options)
    }
    let value = Meaning(title: entry.title, body: entry.body, trigger: entry.trigger?.isEmpty == false ? entry.trigger : nil,
                        bodyType: entry.bodyType, syntax: entry.bodyType == .plainText ? .standard : entry.syntax, parameters: parameters)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try? encoder.encode(value)
  }
}
