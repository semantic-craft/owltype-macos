//
//  OwlSnapshotRegistry.swift
//  法墨输入法 (Owltype) — P0 bypass candidate infrastructure (spec P0-02, registry part)
//
//  The MainActor source of truth for "which composition snapshot is currently live". An
//  async enhancement result (T1 local / T2 cloud) must call `isCurrent(_:)` on the main
//  thread before it touches the UI; if the user has typed / paged / committed / switched
//  schema since the snapshot was taken, the result is stale and must be dropped.
//
//  Scope (Increment 1): this file is the registry + staleness check ONLY. The hot-path
//  EMITTER that produces snapshots (P0-02 emitter part) is Increment 2 and lives elsewhere;
//  nothing here touches `OwlInputController` or the engine.
//

import Foundation

/// MainActor-isolated holder of the live composition snapshot.
@MainActor
final class OwlSnapshotRegistry {
  /// Shared registry. The async services reference `OwlSnapshotRegistry.shared` per spec.
  static let shared = OwlSnapshotRegistry()

  /// The currently live composition snapshot, or nil when there is no active composition.
  private(set) var current: OwlCompositionSnapshot?

  init() {}

  /// Replace the live snapshot. Called by the hot-path emitter after the
  /// engine + main candidate lane have already updated, and with nil when composition ends.
  func update(_ snapshot: OwlCompositionSnapshot?) {
    current = snapshot
  }
}
