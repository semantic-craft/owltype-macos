//
//  OwlSnapshotEmitter.swift
//  法墨输入法 (Owltype) — P0 bypass candidate infrastructure (spec P0-02, emitter part)
//
//  The ONE place that touches the IMK hot-path region. It runs strictly AFTER the engine and the
//  main candidate lane have already updated (post-update / post-commit), copies the public
//  composition state into an immutable `OwlCompositionSnapshot` and registers it. Readers (the
//  update logout prompt, the dictionary prompt) use the registry to tell whether the user is
//  mid-composition. It NEVER calls process_key / setMarkedText / insertText / commit, never holds
//  an engine pointer, never throws, and never affects the caller — capture failure must not
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
/// `OwlSnapshotRegistry` is likewise a singleton.
@MainActor
final class OwlSnapshotEmitter {
  /// Shared emitter.
  static let shared = OwlSnapshotEmitter()

  private var wasComposing: Bool = false

  init() {}

  /// Emit a fresh snapshot for an active composition. Called from `engineUpdate()` AFTER the engine
  /// state and the main candidate lane have already been shown, and registers the snapshot.
  ///
  /// - Important: pure observation. Builds plain values only; touches no engine handle.
  func emitComposing(rawInput: String) {
    let snapshot = OwlCompositionSnapshot(
      id: OwlSnapshotIDGenerator.shared.next(),
      rawInput: rawInput
    )

    OwlSnapshotRegistry.shared.update(snapshot)

    wasComposing = true
  }

  /// Composition ended (no context / hidePalettes). Clears the registry once per active-composition
  /// teardown. A no-op when we were already idle.
  func emitCleared() {
    guard wasComposing else { return }
    OwlSnapshotRegistry.shared.update(nil)
    wasComposing = false
  }
}
