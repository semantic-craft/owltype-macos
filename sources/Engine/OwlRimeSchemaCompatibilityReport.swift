import Foundation

/// Read-only audit for explicitly supplied custom Rime schema files.
///
/// This type never searches a user directory and never writes the inspected files. Rime's
/// built-in capabilities are implemented natively by the Rust engine; external schema patches
/// and Lua references are reported as unavailable rather than silently presented as executed.
enum OwlRimeSchemaCompatibilityReport {
  struct FileEntry: Codable, Equatable {
    enum Kind: String, Codable {
      case schema
      case custom
    }

    let fileName: String
    let kind: Kind
    let schemaID: String?
    let luaReferences: [String]
  }

  struct Report: Codable, Equatable {
    let files: [FileEntry]
    let nativeEquivalentCapabilities: [String]
    let externalExecution: String
    let originalPreserved: Bool
    let notice: String
  }

  enum Failure: LocalizedError, Equatable {
    case unsupportedFile(String)
    case unreadable(String)
    case notUTF8(String)

    var errorDescription: String? {
      switch self {
      case .unsupportedFile(let name):
        return "仅支持 .schema.yaml 与 .custom.yaml：\(name)"
      case .unreadable(let name):
        return "无法读取方案文件：\(name)"
      case .notUTF8(let name):
        return "方案文件不是 UTF-8：\(name)"
      }
    }
  }

  static let nativeEquivalentCapabilities = ["日期", "农历", "Unicode", "表达式"]

  private static let luaPattern = try! NSRegularExpression(
    pattern: #"lua_(?:translator|processor|filter)@[A-Za-z0-9_@*./-]+|[A-Za-z0-9_@*./-]+\.lua"#
  )

  static func supports(fileURL: URL) -> Bool {
    let name = fileURL.lastPathComponent
    return name.hasSuffix(".schema.yaml") || name.hasSuffix(".custom.yaml")
  }

  static func inspect(fileURLs: [URL]) throws -> Report {
    let entries = try fileURLs.map(inspect(fileURL:))
    return Report(
      files: entries,
      nativeEquivalentCapabilities: nativeEquivalentCapabilities,
      externalExecution: "Rust 不执行 Lua 或自定义 Rime schema。",
      originalPreserved: true,
      notice: "外部原文只读保留；内置 rime-ice 的日期、农历、Unicode、表达式等能力由 Rust 原生等价实现。"
    )
  }

  private static func inspect(fileURL: URL) throws -> FileEntry {
    let name = fileURL.lastPathComponent
    guard supports(fileURL: fileURL) else {
      throw Failure.unsupportedFile(name)
    }
    let kind: FileEntry.Kind = name.hasSuffix(".schema.yaml") ? .schema : .custom
    guard let data = try? Data(contentsOf: fileURL) else {
      throw Failure.unreadable(name)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw Failure.notUTF8(name)
    }
    return FileEntry(
      fileName: name,
      kind: kind,
      schemaID: schemaID(in: text),
      luaReferences: luaReferences(in: text)
    )
  }

  private static func schemaID(in text: String) -> String? {
    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: ":") else { continue }
      let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
      guard key == "schema_id" else { continue }
      let value = trimmed[trimmed.index(after: separator)...]
        .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      if !value.isEmpty { return value }
    }
    return nil
  }

  private static func luaReferences(in text: String) -> [String] {
    var seen = Set<String>()
    var references: [String] = []
    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#") else { continue }
      let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
      for match in luaPattern.matches(in: trimmed, range: range) {
        guard let matchRange = Range(match.range, in: trimmed) else { continue }
        let reference = String(trimmed[matchRange])
        if seen.insert(reference).inserted {
          references.append(reference)
        }
      }
    }
    return references
  }
}
