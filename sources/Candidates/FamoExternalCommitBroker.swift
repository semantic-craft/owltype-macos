//
//  FamoExternalCommitBroker.swift
//  法墨输入法 (Famo) — P0 bypass candidate infrastructure (spec P0-05)
//
//  The ONLY sanctioned path for an asynchronous smart-lane candidate to reach the document.
//  Async enhancement services (T1 local) must NEVER call setMarkedText / insertText
//  directly: a result computed for one composition can arrive after the user has typed more,
//  paged, committed, or switched schema. The broker re-validates the candidate's snapshot
//  against the live snapshot at the instant of commit and DROPS anything stale.
//
//  Insertion is delegated through an `insert:` closure supplied by the controller (the side
//  channel), so this type holds no IMK client and never touches the hot path itself. After a
//  successful insert it clears the non-main lanes so no stale enhancement candidate lingers.
//
//  Scope note: the existing emoji-insert path is intentionally NOT routed through this broker.
//  An emoji pick is a SYNCHRONOUS user action with no composition snapshot, so snapshot
//  re-validation would wrongly drop it. Folding emoji into the broker is out of scope for P0.
//

import Foundation

/// Re-validating side-channel commit for async smart-lane candidates (P0-05).
@MainActor
final class FamoExternalCommitBroker {
  /// Shared broker. The async smart-lane services commit through `FamoExternalCommitBroker.shared`.
  static let shared = FamoExternalCommitBroker()

  /// Candidate write-sink port. Defaults to the shared store (production composition root);
  /// injectable so a test can assert the post-commit clear without a real store. See
  /// `CandidateStoring` in RimeSeam.swift / `famo-dependency-seams.md`.
  var store: CandidateStoring = FamoCandidateStore.shared

  init() {}

  /// Commit `candidate` IFF it still describes the live composition; otherwise drop silently.
  ///
  /// Validation: the candidate's `snapshotID` must equal the live snapshot's `id`. (We compare
  /// `id` directly here because the broker commits a candidate that was minted for one specific
  /// snapshot; any newer composition has a strictly greater snapshot id.)
  ///
  /// - Parameters:
  ///   - candidate: the smart-lane candidate the user selected.
  ///   - insert: controller-supplied side channel that performs the actual document insert.
  func commit(_ candidate: EnhancedCandidate, insert: (String) -> Void) {
    let live = FamoSnapshotRegistry.shared.current
    guard live?.id == candidate.snapshotID else {
      // Stale: the user has moved on since this candidate was computed. Drop it.
      return
    }
    insert(candidate.text)
    store.clearForSnapshotChange()
  }
}
