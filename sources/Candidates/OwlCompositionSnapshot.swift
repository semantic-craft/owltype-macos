//
//  OwlCompositionSnapshot.swift
//  法墨输入法 (Owltype) — P0 bypass candidate infrastructure (spec P0-01)
//
//  An IMMUTABLE, value-type snapshot of one composition state, copied off the IMK hot
//  path AFTER the engine + the candidate UI have already updated. It carries everything the
//  asynchronous enhancement layer (T1 local / T2 cloud) needs to (a) build a request and
//  (b) later prove the result is still fresh — so a late async result can be dropped
//  instead of clobbering newer input.
//
//  Boundary (parent prd / ADR-0001..0003): this type holds NO engine pointer or handle.
//  Background threads only ever touch these plain values; the engine and the hot path are
//  never reached from here.
//
//  Concurrency: `Sendable` value types, safe to hand across actor / thread boundaries.
//

import Foundation

/// Immutable snapshot of the current composition.
struct OwlCompositionSnapshot: Hashable, Sendable {
  /// Process-monotonic snapshot id (strictly increasing).
  let id: UInt64
  /// Raw input code typed so far (alphabet / wubi code stream).
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
