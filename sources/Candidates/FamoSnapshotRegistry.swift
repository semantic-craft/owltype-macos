//
//  FamoSnapshotRegistry.swift
//  法墨输入法 (Famo) — P0 bypass candidate infrastructure (spec P0-02, registry part)
//
//  The MainActor source of truth for "which composition snapshot is currently live". An
//  async local-enhancement result must call `isCurrent(_:)` on the main
//  thread before it touches the UI; if the user has typed / paged / committed / switched
//  schema since the snapshot was taken, the result is stale and must be dropped.
//
//  Scope (Increment 1): this file is the registry + staleness check ONLY. The hot-path
//  EMITTER that produces snapshots (P0-02 emitter part) is Increment 2 and lives elsewhere;
//  nothing here touches `FamoInputController` or librime.
//

import Foundation
import SwiftUI

/// MainActor-isolated holder of the live composition snapshot.
///
/// Staleness rule (`isCurrent`): a snapshot is current iff its `sessionID`, `schemaID`,
/// `rawInput`, `preedit`, `pageNo`, and `commitSerial` all match the registered current
/// snapshot. `id` and `createdAtNanos` are deliberately NOT compared — two snapshots that
/// describe the same composition state are interchangeable for freshness purposes.
@MainActor
final class FamoSnapshotRegistry: ObservableObject {
  /// Shared registry. The async services reference `FamoSnapshotRegistry.shared` per spec.
  static let shared = FamoSnapshotRegistry()

  /// The currently live composition snapshot, or nil when there is no active composition.
  @Published private(set) var current: FamoCompositionSnapshot?

  init() {}

  /// Replace the live snapshot. Called by the hot-path emitter (Increment 2) after the
  /// engine + main candidate lane have already updated, and with nil when composition ends.
  func update(_ snapshot: FamoCompositionSnapshot?) {
    current = snapshot
  }

  /// Whether `snapshot` still describes the live composition (i.e. is safe to act on).
  ///
  /// Returns false when there is no current snapshot, so a result that arrives after the
  /// composition has ended is always dropped.
  func isCurrent(_ snapshot: FamoCompositionSnapshot) -> Bool {
    guard let current else { return false }
    return current.sessionID == snapshot.sessionID
      && current.schemaID == snapshot.schemaID
      && current.rawInput == snapshot.rawInput
      && current.preedit == snapshot.preedit
      && current.pageNo == snapshot.pageNo
      && current.commitSerial == snapshot.commitSerial
  }
}
