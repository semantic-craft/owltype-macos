//
//  OwlCandidateStore.swift
//  猫头鹰输入法 (Owltype) — P0 bypass candidate infrastructure (spec P0-03)
//
//  The MainActor container behind the two-lane candidate UI:
//    - main  : Rime's authoritative candidates (set elsewhere; untouched here in P0).
//    - smart : T1 local recommendations / 五笔 typo correction / 法学 collocations.
//  (A former `cloud` lane for inline DeepSeek candidates was removed — see task 06-25-ai /
//  memory owl-ai-candidate-lane-removed; the DeepSeek base types live on for 划词/任意提问.)
//
//  Staleness gate (the whole point of P0): every async upsert carries the `snapshotID` it
//  was computed for. If that id does not match the live snapshot in `OwlSnapshotRegistry`,
//  the upsert is DROPPED — a late cloud result can never overwrite newer input. P0 stage:
//  smart/cloud start empty and are only populated by P1+ services.
//
//  Boundary: holds plain value-type candidates only; no librime handle, no hot-path call.
//

import Foundation
import SwiftUI

/// A candidate destined for the smart/cloud lanes (or echoing a main-lane Rime candidate).
/// `Sendable` so an enhancement service can build it off the main thread and hand it in.
struct EnhancedCandidate: Identifiable, Hashable, Sendable {
  /// Where the candidate came from.
  enum Source: String, Sendable {
    case rime
    case localStat
    case localNeural
  }

  /// Which UI lane the candidate belongs to.
  enum Lane: String, Sendable {
    case main
    case smart
  }

  /// How selecting the candidate should commit it.
  enum CommitMode: String, Sendable {
    /// Select by the underlying Rime candidate index (authoritative path).
    case rimeIndex
    /// Commit external text via the broker side-channel (smart/cloud results).
    case externalText
  }

  let id: UUID
  /// Snapshot this candidate was computed for; checked against the live snapshot on upsert.
  let snapshotID: UInt64
  let source: Source
  let lane: Lane
  let text: String
  let comment: String?
  /// Underlying Rime candidate index when `commitMode == .rimeIndex`; nil otherwise.
  let baseRimeIndex: Int?
  let score: Double
  let commitMode: CommitMode

  init(
    id: UUID = UUID(),
    snapshotID: UInt64,
    source: Source,
    lane: Lane,
    text: String,
    comment: String? = nil,
    baseRimeIndex: Int? = nil,
    score: Double = 0,
    commitMode: CommitMode
  ) {
    self.id = id
    self.snapshotID = snapshotID
    self.source = source
    self.lane = lane
    self.text = text
    self.comment = comment
    self.baseRimeIndex = baseRimeIndex
    self.score = score
    self.commitMode = commitMode
  }
}

extension EnhancedCandidate {
  /// G3: derive the user-visible provenance from a candidate's lane/source.
  ///
  /// Pure, deterministic, side-effect free — safe to call off the hot path (in the
  /// `showPanel` data-prep step / view-model construction, never inside key handling).
  /// Returns `nil` for ordinary main-lane Rime pinyin candidates → no label, no noise.
  static func provenance(source: Source, lane: Lane) -> OwlProvenance? {
    switch lane {
    case .smart:
      return source == .localNeural ? .project : .personal  // neural=项目排序, stat=个人词频
    case .main:
      return nil                                       // 普通拼音主词典 → 不加标签
    }
  }

  /// Instance form: this candidate's provenance (consumes its own lane/source).
  func provenance() -> OwlProvenance? {
    Self.provenance(source: source, lane: lane)
  }
}

/// Transient error surfaced in a non-main lane (e.g. cloud decode / network failure).
/// Carries the `snapshotID` so a stale error is dropped exactly like a stale candidate.
struct EnhancedLaneError: Hashable, Sendable {
  let snapshotID: UInt64
  let lane: EnhancedCandidate.Lane
  let message: String
}

/// MainActor observable store of the three candidate lanes.
///
/// `main` is owned by the existing Rime path and is NOT written by this increment. `smart`
/// and `cloud` are written only through the guarded `upsert*` methods, which drop anything
/// whose `snapshotID` no longer matches the live snapshot.
@MainActor
final class OwlCandidateStore: ObservableObject {
  /// Shared store. The async services reference `OwlCandidateStore.shared` per spec.
  static let shared = OwlCandidateStore()

  /// Rime's authoritative candidates. Set by the existing main-lane path (not here in P0).
  @Published private(set) var main: [EnhancedCandidate] = []
  /// T1 local recommendations. Empty until P2 services populate it.
  @Published private(set) var smart: [EnhancedCandidate] = []
  /// Latest non-main lane error, if any (e.g. cloud decode error). Cleared on snapshot change.
  @Published private(set) var laneError: EnhancedLaneError?

  /// P0-04: minimal notify so the candidate panel can re-render when the async smart/cloud
  /// lanes change AFTER the initial Rime `showPanel` already drew the page. The controller sets
  /// this once (createSession) to a method that rebuilds the panel from the cached Rime state +
  /// the now-updated store lanes. Invoked on the main actor (the store is `@MainActor`) at the
  /// end of every smart/cloud mutation; nil when no controller is live. Off the IMK key hot path
  /// (an async upsert / clear, never `processKey`).
  var onLanesChanged: (() -> Void)?

  init() {}

  /// Whether `snapshotID` matches the live snapshot. An upsert for a stale snapshot is dropped.
  private func isCurrent(_ snapshotID: UInt64) -> Bool {
    OwlSnapshotRegistry.shared.current?.id == snapshotID
  }

  /// Whether every candidate belongs to lane `lane` and carries `snapshotID`. Guards against
  /// a service accidentally mixing lanes / snapshots into one upsert.
  private func allConsistent(
    _ candidates: [EnhancedCandidate],
    lane: EnhancedCandidate.Lane,
    snapshotID: UInt64
  ) -> Bool {
    candidates.allSatisfy { $0.lane == lane && $0.snapshotID == snapshotID }
  }

  /// Replace the smart lane with `candidates`, IFF `snapshotID` is still live. Drops otherwise.
  func upsertSmartCandidates(_ candidates: [EnhancedCandidate], snapshotID: UInt64) {
    guard isCurrent(snapshotID),
          allConsistent(candidates, lane: .smart, snapshotID: snapshotID) else { return }
    smart = candidates
    onLanesChanged?()
  }

  /// Clear every non-main lane (smart, error). Called when the composition changes so
  /// no candidate from the previous composition lingers on screen.
  func clearForSnapshotChange() {
    smart = []
    laneError = nil
    onLanesChanged?()
  }

  /// Surface an error for a non-main lane, IFF `snapshotID` is still live. Drops otherwise.
  func showError(_ message: String, lane: EnhancedCandidate.Lane, snapshotID: UInt64) {
    guard isCurrent(snapshotID) else { return }
    laneError = EnhancedLaneError(snapshotID: snapshotID, lane: lane, message: message)
  }

  /// Set the Rime main lane. Provided for completeness / Increment 2 wiring; in P0 the main
  /// lane is still driven by the existing native path and this is unused by the hot path.
  func setMainCandidates(_ candidates: [EnhancedCandidate]) {
    main = candidates
  }
}
