//
//  OwlCompositionSnapshot.swift
//

import Foundation

struct OwlCompositionSnapshot: Hashable, Sendable {
  let id: UInt64
  let rawInput: String
}

/// Thread-safe source of strictly-increasing snapshot ids. A snapshot may be built off the
/// hot path, so the counter must be safe to call from any thread; an `os_unfair_lock`-guarded
/// `UInt64` keeps `next()` allocation-free and cheap (the hot path must stay < 1 ms).
final class OwlSnapshotIDGenerator: @unchecked Sendable {
  /// Shared generator. One process-wide monotonic id space is sufficient and simplest.
  static let shared = OwlSnapshotIDGenerator()

  private var lock = os_unfair_lock_s()
  private var value: UInt64 = 0

  /// Return the next id (starts at 1; 0 is reserved as "no snapshot").
  func next() -> UInt64 {
    os_unfair_lock_lock(&lock)
    value &+= 1
    let result = value
    os_unfair_lock_unlock(&lock)
    return result
  }
}

/// MainActor-isolated holder of the live composition snapshot.
@MainActor
final class OwlSnapshotRegistry {
  static let shared = OwlSnapshotRegistry()

  private(set) var current: OwlCompositionSnapshot?

  init() {}

  func update(_ snapshot: OwlCompositionSnapshot?) {
    current = snapshot
  }
}

@MainActor
final class OwlSnapshotEmitter {
  static let shared = OwlSnapshotEmitter()

  private var wasComposing: Bool = false

  init() {}

  func emitComposing(rawInput: String) {
    let snapshot = OwlCompositionSnapshot(
      id: OwlSnapshotIDGenerator.shared.next(),
      rawInput: rawInput
    )

    OwlSnapshotRegistry.shared.update(snapshot)

    wasComposing = true
  }

  func emitCleared() {
    guard wasComposing else { return }
    OwlSnapshotRegistry.shared.update(nil)
    wasComposing = false
  }
}
