//
//  OwlSnapshotEmitter.swift
//  猫头鹰输入法 (Owltype) — P0 bypass candidate infrastructure (spec P0-02, emitter part)
//
//  The ONE place that touches the IMK hot-path region. It runs strictly AFTER librime and the
//  main candidate lane have already updated (post-update / post-commit), copies the public
//  composition state into an immutable `OwlCompositionSnapshot` and registers it. Readers (the
//  update logout prompt, the dictionary prompt) use the registry to tell whether the user is
//  mid-composition. It NEVER calls process_key / setMarkedText / insertText / commit, never holds
//  a librime pointer, never throws, and never affects the caller — capture failure must not
//  influence input (parent prd hard constraint).
//
//  Ownership: this emitter owns `commitSerial`, the monotonic counter bumped on every
//  commit / clear / escape / schema switch. A snapshot taken before such an event is therefore
//  detectably stale via `OwlSnapshotRegistry.isCurrent(_:)`.
//
//  Concurrency: `@MainActor`-isolated. All call sites are IMK main-thread callbacks; the
//  controller bridges in via `MainActor.assumeIsolated { ... }` (it is itself non-isolated, to
//  match the non-isolated `IMKInputController`, so we cannot annotate the controller).
//

import Foundation

/// Hot-path-adjacent, side-effect-free snapshot emitter (P0-02). Single shared instance because
/// `commitSerial` is one process-wide composition timeline and `OwlSnapshotRegistry` is likewise a
/// singleton.
@MainActor
final class OwlSnapshotEmitter {
  /// Shared emitter. The controller's three appended call sites use `OwlSnapshotEmitter.shared`.
  static let shared = OwlSnapshotEmitter()

  /// Commit serial at the head of the composition timeline. Bumped on commit / clear / escape /
  /// schema switch so any snapshot captured earlier is detectably stale.
  private(set) var commitSerial: UInt64 = 0

  /// Whether we believe a composition is currently active. Guards `emitCleared()` against
  /// over-incrementing `commitSerial` on repeated idle (no-composition) updates.
  private var wasComposing: Bool = false

  init() {}

  /// A commit just happened. Bump the serial so pre-commit snapshots are stale. The composition
  /// will be re-emitted (or cleared) by the subsequent `rimeUpdate()`; we do not clear here.
  func noteCommit() {
    commitSerial &+= 1
  }

  /// The active schema changed. Bump the serial so snapshots from the previous schema are stale.
  func noteSchemaChange() {
    commitSerial &+= 1
  }

  /// Emit a fresh snapshot for an active composition. Called from `rimeUpdate()` AFTER the engine
  /// state and the main candidate lane have already been shown, and registers the snapshot.
  ///
  /// - Important: pure observation. Builds plain values only; touches no librime handle.
  func emitComposing(
    sessionID: UInt64,
    schemaID: String,
    rawInput: String,
    preedit: String,
    cursor: Int,
    pageNo: Int,
    candidates: [RimeCandidateSnapshot]
  ) {
    let snapshot = OwlCompositionSnapshot(
      id: OwlSnapshotIDGenerator.shared.next(),
      sessionID: sessionID,
      schemaID: schemaID,
      rawInput: rawInput,
      preedit: preedit,
      cursor: cursor,
      pageNo: pageNo,
      candidates: candidates,
      commitSerial: commitSerial,
      createdAtNanos: DispatchTime.now().uptimeNanoseconds
    )

    OwlSnapshotRegistry.shared.update(snapshot)

    wasComposing = true
  }

  /// Composition ended (no context / hidePalettes). Bumps the serial ONCE per active-composition
  /// teardown and clears the registry. A no-op when we were already idle, so repeated idle updates
  /// never inflate `commitSerial`.
  func emitCleared() {
    guard wasComposing else { return }
    commitSerial &+= 1
    OwlSnapshotRegistry.shared.update(nil)
    wasComposing = false
  }
}
