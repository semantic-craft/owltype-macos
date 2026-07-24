//
//  FamoProject.swift
//  法墨输入法 (Famo) — 项目输入空间 (blueprint_v2 P0 pillar, task 06-20-famo-project-input-space)
//
//  Pure value model for a single "项目" (project) input space: a named bundle of project
//  words + simple abbreviation expansions the user organizes their input context around.
//  Local-only, human-readable, exported as `project.json` per project (see `FamoProjectStore`).
//  Never uploaded, never fed into DeepSeek distillation.
//
//  Boundary: a plain `Codable` value type. No disk IO, no Rime handle, no hot-path call —
//  persistence + activation live in `FamoProjectStore`; candidate injection happens through
//  the existing snapshotID-gated smart-lane path in `FamoSnapshotEmitter` / `FamoCandidateStore`.
//

import Foundation

/// One project input space. `id` is a stable, filesystem-safe slug used as the on-disk
/// directory name (`projects/<id>/project.json`). `words` are the project's preferred
/// candidates (injected into the smart lane when active); `abbreviations` map a short code
/// to its expansion (e.g. "民诉" → "民事诉讼法") — reserved for a later expansion pass, stored
/// now so `project.json` is forward-compatible.
struct FamoProject: Codable, Identifiable, Equatable, Sendable {
  /// Filesystem-safe identifier (also the on-disk directory name).
  let id: String
  /// Human-facing project name.
  var name: String
  /// Project words injected into the smart lane while this project is active.
  var words: [String]
  /// 简称 → 展开 map (e.g. "民诉" → "民事诉讼法"). Stored for forward compatibility.
  var abbreviations: [String: String]
  /// 术语锁 (Terminology Lock, blueprint_v2 P0): per-project terminology rules — preferred forms,
  /// allowed variants, forbidden variants. Applied in the smart-lane enhancement step (see
  /// `FamoTerminology.apply`); never touches the Rime main lane. Defaults to empty and decodes
  /// with a default so a `project.json` written before terminology existed still round-trips.
  var termRules: [FamoTermRule]
  /// Creation timestamp (for stable list ordering / display).
  let createdAt: Date

  init(
    id: String = FamoProject.makeID(),
    name: String,
    words: [String] = [],
    abbreviations: [String: String] = [:],
    termRules: [FamoTermRule] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.words = words
    self.abbreviations = abbreviations
    self.termRules = termRules
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, words, abbreviations, termRules, createdAt
  }

  /// Decode-with-default for `termRules` so a `project.json` written before the 术语锁 feature
  /// existed still decodes (missing key → empty rules). Every other field is required as before.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(String.self, forKey: .id)
    self.name = try c.decode(String.self, forKey: .name)
    self.words = try c.decode([String].self, forKey: .words)
    self.abbreviations = try c.decode([String: String].self, forKey: .abbreviations)
    self.termRules = try c.decodeIfPresent([FamoTermRule].self, forKey: .termRules) ?? []
    self.createdAt = try c.decode(Date.self, forKey: .createdAt)
  }

  /// Fresh, collision-resistant, filesystem-safe project id (lowercase hex of a UUID).
  static func makeID() -> String {
    UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
  }

  /// `words` with surrounding whitespace trimmed, empties dropped, and duplicates removed
  /// (first occurrence wins). The single normalization point so the store and the smart-lane
  /// injection agree on exactly what a project contributes.
  var normalizedWords: [String] {
    var seen = Set<String>()
    var out: [String] = []
    for raw in words {
      let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !word.isEmpty, !seen.contains(word) else { continue }
      seen.insert(word)
      out.append(word)
    }
    return out
  }
}
