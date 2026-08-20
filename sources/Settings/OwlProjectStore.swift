//
//  OwlProjectStore.swift
//  法墨输入法 (Owltype) — 项目输入空间 (blueprint_v2 P0 pillar, task 06-20-owl-project-input-space)
//
//  CRUD + activation for `OwlProject` input spaces. Each project is persisted as a single
//  human-readable `project.json` under:
//
//      ~/Library/Application Support/Owltype/projects/<project-id>/project.json
//
//  Pure local storage — `FileManager` + pretty-printed `JSONEncoder`, atomic writes. Nothing
//  here is uploaded, synced, or fed into DeepSeek distillation. The active project id is the
//  only piece of state in `UserDefaults`; the projects themselves live as files so they stay
//  exportable and inspectable.
//
//  Candidate injection is NOT performed here. The active project's words are read by
//  `OwlSnapshotEmitter` and handed to `OwlCandidateStore.upsertSmartCandidates(_:snapshotID:)`,
//  which is snapshotID-gated, so a stale composition can never receive project words. This file
//  only owns persistence + the "which project is active" pointer; it never touches the IMK hot
//  path, the Rime main lane, or rime config/deploy.
//
//  Concurrency: not `@MainActor`-isolated (matches the rest of the settings / store layer).
//  All access is on the main thread via the settings UI / delegate.
//

import Foundation

/// Errors surfaced by project CRUD (shown verbatim in the 项目 settings page).
enum OwlProjectError: LocalizedError, Equatable {
  case emptyName
  case notFound(String)

  var errorDescription: String? {
    switch self {
    case .emptyName: return "场景名称不能为空。"
    case let .notFound(id): return "未找到场景词库（\(id)）。"
    }
  }
}

/// File-backed CRUD store for `OwlProject` input spaces + the active-project pointer.
///
/// `root` is injectable so tests can point at a temporary directory instead of the real
/// `~/Library/Application Support/Owltype`. `defaults` is injectable for the same reason.
final class OwlProjectStore {
  /// Shared store used by the emitter (smart-lane injection) and the settings page.
  static let shared = OwlProjectStore()

  /// UserDefaults key holding the active project id (the only piece of state not on disk).
  static let activeProjectIDKey = "OwlActiveProjectID"

  /// Subdirectory under the Owltype user dir that holds one folder per project.
  static let projectsDirName = "projects"

  /// On-disk filename inside each `<id>/` folder.
  static let projectFileName = "project.json"

  private let root: URL
  private let defaults: UserDefaults

  init(root: URL = OwlApp.userDir, defaults: UserDefaults = OwlDefaults.standard) {
    self.root = root
    self.defaults = defaults
  }

  // MARK: - Paths

  /// `<root>/projects` — created lazily on the first write.
  var projectsDir: URL {
    root.appendingPathComponent(Self.projectsDirName, isDirectory: true)
  }

  /// `<root>/projects/<id>/project.json`.
  func fileURL(for id: String) -> URL {
    projectsDir
      .appendingPathComponent(id, isDirectory: true)
      .appendingPathComponent(Self.projectFileName, isDirectory: false)
  }

  // MARK: - Coders

  /// Encoder/decoder share an `.iso8601` date strategy so `createdAt` round-trips as a
  /// human-readable timestamp string (and `.prettyPrinted` + `.sortedKeys` keep the file
  /// diff-friendly and inspectable).
  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  // MARK: - Read

  /// Every persisted project, sorted by creation time (oldest first) for a stable list order.
  /// Malformed / partial folders are skipped silently rather than crashing the settings page.
  func loadAll() -> [OwlProject] {
    let fm = FileManager.default
    let decoder = Self.makeDecoder()
    guard let entries = try? fm.contentsOfDirectory(
      at: projectsDir,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    var out: [OwlProject] = []
    for dir in entries {
      let url = dir.appendingPathComponent(Self.projectFileName, isDirectory: false)
      guard let data = try? Data(contentsOf: url),
            let project = try? decoder.decode(OwlProject.self, from: data) else {
        continue
      }
      out.append(project)
    }
    // Sort by creation time, falling back to id so the order is stable even when two projects
    // share a whole-second `createdAt` (ISO8601 persists seconds only).
    return out.sorted {
      $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
    }
  }

  /// One project by id, or `nil` when it doesn't exist / fails to decode.
  func load(id: String) -> OwlProject? {
    guard let data = try? Data(contentsOf: fileURL(for: id)),
          let project = try? Self.makeDecoder().decode(OwlProject.self, from: data) else {
      return nil
    }
    return project
  }

  // MARK: - Write

  /// Create + persist a new project with `name`. Trims the name and rejects empty.
  @discardableResult
  func create(name: String) throws -> OwlProject {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw OwlProjectError.emptyName }
    let project = OwlProject(name: trimmed)
    try save(project)
    return project
  }

  /// Persist `project` (upsert by id), pretty-printed + atomic. Creates the `<id>/` folder.
  func save(_ project: OwlProject) throws {
    let url = fileURL(for: project.id)
    try OwlPrivateStorage.prepareDirectory(root)
    try OwlPrivateStorage.prepareDirectory(projectsDir)
    try OwlPrivateStorage.prepareDirectory(url.deletingLastPathComponent())
    let data = try Self.makeEncoder().encode(project)
    try data.write(to: url, options: .atomic)
    try OwlPrivateStorage.hardenFile(url)
  }

  /// Rename a project. Throws `.notFound` when the id is unknown, `.emptyName` when blank.
  @discardableResult
  func rename(id: String, to newName: String) throws -> OwlProject {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw OwlProjectError.emptyName }
    guard var project = load(id: id) else { throw OwlProjectError.notFound(id) }
    project.name = trimmed
    try save(project)
    return project
  }

  /// Replace a project's word list. Throws `.notFound` when the id is unknown.
  @discardableResult
  func setWords(id: String, words: [String]) throws -> OwlProject {
    guard var project = load(id: id) else { throw OwlProjectError.notFound(id) }
    project.words = words
    try save(project)
    return project
  }

  /// Replace a project's 术语锁 rule set. Throws `.notFound` when the id is unknown.
  @discardableResult
  func setTermRules(id: String, termRules: [OwlTermRule]) throws -> OwlProject {
    guard var project = load(id: id) else { throw OwlProjectError.notFound(id) }
    project.termRules = termRules
    try save(project)
    return project
  }

  /// Delete a project's folder. Clears the active pointer if it pointed at this project.
  func delete(id: String) throws {
    let dir = projectsDir.appendingPathComponent(id, isDirectory: true)
    if FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.removeItem(at: dir)
    }
    if activeProjectID == id {
      activeProjectID = nil
    }
  }

  // MARK: - Active project

  /// Id of the active project (persisted in `UserDefaults`). Setting `nil` clears it.
  var activeProjectID: String? {
    get { defaults.string(forKey: Self.activeProjectIDKey) }
    set {
      if let newValue {
        defaults.set(newValue, forKey: Self.activeProjectIDKey)
      } else {
        defaults.removeObject(forKey: Self.activeProjectIDKey)
      }
    }
  }

  /// The active project, or `nil` when none is active / its file is gone. A dangling
  /// active id (folder deleted out from under us) reads as no active project — the smart
  /// lane simply gets no project words rather than crashing.
  var activeProject: OwlProject? {
    guard let id = activeProjectID else { return nil }
    return load(id: id)
  }

  /// Activate (switch to) a project. Throws `.notFound` when the id doesn't exist.
  func activate(id: String) throws {
    guard load(id: id) != nil else { throw OwlProjectError.notFound(id) }
    activeProjectID = id
  }

}
