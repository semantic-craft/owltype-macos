//
//  OwlTerminology.swift
//  猫头鹰输入法 (Owltype) — 术语锁 (Terminology Lock, blueprint_v2 P0 pillar, task 06-20-owl-terminology-lock)
//
//  Project-level terminology rules: a preferred term, its allowed variants, and forbidden
//  variants. Built ON the just-landed 项目输入空间 (`OwlProject` / `OwlProjectStore`) — terminology
//  rules ride along on a `OwlProject` (one rule set per project) and are persisted in the same
//  human-readable `project.json`.
//
//  Boundary: a plain `Codable` value model (`OwlTermRule`) plus a PURE, side-effect-free
//  reordering function (`OwlTerminology.apply`). NO disk IO, no Rime handle, no hot-path call.
//  Enforcement happens only in the ENHANCEMENT layer (the smart lane, via `OwlSnapshotEmitter`),
//  exactly like project-word injection — it NEVER touches the IMK hot path, the Rime main lane,
//  the owl_law_* legal layer, or rime config/deploy. No Lua filter in this MVP.
//
//  Not in MVP (left as comments for a later pass):
//    - firstForm vs shortForm context tracking (needs document-level state).
//    - cross-project shared terminology libraries.
//

import Foundation

/// One terminology rule inside a project: a `preferred` canonical form, the `allowedVariants`
/// that are tolerated (kept in candidates, never promoted over `preferred`), and the
/// `forbiddenVariants` that should be removed from the enhancement lane.
///
/// `firstForm` / `shortForm` are reserved for the later 首次出现 vs 后续简称 context pass; they are
/// stored now so `project.json` is forward-compatible, but the MVP `apply` does not consult them.
///
/// A plain `Codable` value type — no IO, no hot-path call. Persisted as part of `OwlProject`.
struct OwlTermRule: Codable, Equatable, Sendable, Identifiable {
  /// Stable id for SwiftUI list editing (not persisted as the primary key; `preferred` is the
  /// human-facing key). Defaulted on decode so older `project.json` (no id) still round-trips.
  var id: String
  /// The canonical preferred form (e.g. "正当防卫"). Promoted to the top of the smart lane when
  /// the rule fires.
  var preferred: String
  /// Variants that are acceptable: kept in candidates as-is, never removed, never promoted over
  /// `preferred`.
  var allowedVariants: [String]
  /// Variants that must NOT appear: removed from the smart/cloud enhancement lane (the Rime main
  /// lane is never touched — this is enforcement in the enhancement layer only).
  var forbiddenVariants: [String]
  /// Reserved (MVP no-op): the full first-occurrence form for 首次出现 vs 后续简称 tracking.
  var firstForm: String?
  /// Reserved (MVP no-op): the later short form for 首次出现 vs 后续简称 tracking.
  var shortForm: String?

  init(
    id: String = UUID().uuidString,
    preferred: String,
    allowedVariants: [String] = [],
    forbiddenVariants: [String] = [],
    firstForm: String? = nil,
    shortForm: String? = nil
  ) {
    self.id = id
    self.preferred = preferred
    self.allowedVariants = allowedVariants
    self.forbiddenVariants = forbiddenVariants
    self.firstForm = firstForm
    self.shortForm = shortForm
  }

  private enum CodingKeys: String, CodingKey {
    case id, preferred, allowedVariants, forbiddenVariants, firstForm, shortForm
  }

  /// Decode-with-defaults so a `project.json` written before terminology existed (or by a future
  /// version that drops optional keys) still decodes: missing `id` is regenerated, missing
  /// variant lists default to empty.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    self.preferred = try c.decode(String.self, forKey: .preferred)
    self.allowedVariants = try c.decodeIfPresent([String].self, forKey: .allowedVariants) ?? []
    self.forbiddenVariants = try c.decodeIfPresent([String].self, forKey: .forbiddenVariants) ?? []
    self.firstForm = try c.decodeIfPresent(String.self, forKey: .firstForm)
    self.shortForm = try c.decodeIfPresent(String.self, forKey: .shortForm)
  }

  /// `preferred` trimmed; `nil` when blank (a rule with no preferred term is inert).
  var normalizedPreferred: String? {
    let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// `forbiddenVariants` trimmed + de-duped, empties dropped.
  var normalizedForbidden: [String] {
    OwlTermRule.normalize(forbiddenVariants)
  }

  /// `allowedVariants` trimmed + de-duped, empties dropped.
  var normalizedAllowed: [String] {
    OwlTermRule.normalize(allowedVariants)
  }

  private static func normalize(_ list: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for raw in list {
      let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !item.isEmpty, !seen.contains(item) else { continue }
      seen.insert(item)
      out.append(item)
    }
    return out
  }
}

/// Pure terminology enforcement over an enhancement-lane candidate list.
///
/// `apply(candidates:rules:)` is the single, unit-testable contract:
///   - removes any candidate whose text exactly matches a rule's forbidden variant,
///   - promotes each rule's preferred form to the FRONT (deduped, with `.localNeural` source so
///     the existing provenance derivation labels it 「项目」), and
///   - leaves every other candidate untouched, in its original relative order.
///
/// Empty `rules` (or rules with no actionable preferred/forbidden term) → `candidates` returned
/// unchanged. The function never mutates input, never touches disk, the Rime main lane, or the
/// hot path — callers run it strictly inside the smart-lane enhancement step.
enum OwlTerminology {
  /// Apply `rules` to enhancement-lane `candidates`. See type doc for the exact contract.
  ///
  /// - Parameters:
  ///   - candidates: smart/cloud lane candidates for ONE snapshot (all share a snapshotID/lane).
  ///   - rules: the active project's terminology rules.
  /// - Returns: the reordered/filtered candidates. Identity (unchanged array) when `rules` is empty.
  static func apply(candidates: [EnhancedCandidate], rules: [OwlTermRule]) -> [EnhancedCandidate] {
    guard !rules.isEmpty, !candidates.isEmpty else { return candidates }

    // Gather the actionable preferred terms (in rule order, deduped) and the forbidden set.
    var preferredOrder: [String] = []
    var preferredSeen = Set<String>()
    var forbidden = Set<String>()
    for rule in rules {
      if let preferred = rule.normalizedPreferred, !preferredSeen.contains(preferred) {
        preferredSeen.insert(preferred)
        preferredOrder.append(preferred)
      }
      forbidden.formUnion(rule.normalizedForbidden)
    }
    // A preferred term is never also treated as forbidden (preferred wins).
    forbidden.subtract(preferredSeen)

    // Nothing to do: no promotions, no removals → return input unchanged (identity).
    guard !preferredOrder.isEmpty || !forbidden.isEmpty else { return candidates }

    // 1. Drop forbidden-variant candidates from the enhancement lane.
    let surviving = candidates.filter { !forbidden.contains($0.text) }

    // No promotions requested → just the filtered list.
    guard !preferredOrder.isEmpty else { return surviving }

    // 2. Build the promoted block: each preferred form, in rule order, at the front.
    //    Reuse an existing candidate's metadata when the preferred form is already present (so a
    //    `.rimeIndex` main echo keeps its commit semantics); otherwise synthesize a smart-lane
    //    `.localNeural`/`.project` candidate carrying the rule. Either way the preferred form is
    //    surfaced exactly once, at the top.
    let template = surviving.first
    var promoted: [EnhancedCandidate] = []
    var promotedText = Set<String>()
    for preferred in preferredOrder {
      guard !promotedText.contains(preferred) else { continue }
      promotedText.insert(preferred)
      if let existing = surviving.first(where: { $0.text == preferred }) {
        promoted.append(existing)
      } else if let template {
        promoted.append(
          EnhancedCandidate(
            snapshotID: template.snapshotID,
            source: .localNeural,
            lane: template.lane,
            text: preferred,
            comment: template.comment,
            baseRimeIndex: nil,
            score: template.score,
            commitMode: .externalText
          )
        )
      }
      // No template (empty surviving list) → nothing to anchor a synthesized candidate to; skip.
    }

    // 3. The rest: everything that survived and was not promoted, in original order.
    let rest = surviving.filter { !promotedText.contains($0.text) }
    return promoted + rest
  }
}
