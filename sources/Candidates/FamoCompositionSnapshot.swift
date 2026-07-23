//
//  FamoCompositionSnapshot.swift
//  法墨输入法 (Famo) — P0 bypass candidate infrastructure (spec P0-01)
//
//  An IMMUTABLE, value-type snapshot of one composition state, copied off the IMK hot
//  path AFTER librime + the candidate UI have already updated. It carries everything the
//  asynchronous local-enhancement layer needs to (a) build a request and
//  (b) later prove the result is still fresh — so a late async result can be dropped
//  instead of clobbering newer input.
//
//  Boundary (parent prd / ADR-0001..0003): this type holds NO librime pointer or handle.
//  Background threads only ever touch these plain values; the engine and the hot path are
//  never reached from here.
//
//  Concurrency: `Sendable` value types, safe to hand across actor / thread boundaries.
//

import Foundation

/// One candidate, copied out of librime into a plain value. Deliberately holds no engine
/// handle / index into live Rime state — only what the local enhancement layer may read.
struct RimeCandidateSnapshot: Hashable, Sendable {
  /// 0-based position in the Rime menu page at capture time.
  let index: Int
  /// Candidate text (the would-be commit string).
  let text: String
  /// Optional Rime comment (reading / 释义 / source line).
  let comment: String?
  /// Optional Rime quality / weight, if exposed; nil when unknown.
  let quality: Double?

  init(index: Int, text: String, comment: String? = nil, quality: Double? = nil) {
    self.index = index
    self.text = text
    self.comment = comment
    self.quality = quality
  }
}

/// Immutable snapshot of the current composition + candidate page.
///
/// Identity & staleness: `id` is a process-monotonic value (see `FamoSnapshotIDGenerator`);
/// `commitSerial` is bumped by the controller on every commit / clear / escape / schema
/// switch so a snapshot taken before such an event is detectably stale. `FamoSnapshotRegistry`
/// compares `sessionID / schemaID / rawInput / preedit / pageNo / commitSerial` to decide if a
/// given snapshot still describes the live composition.
struct FamoCompositionSnapshot: Hashable, Sendable {
  /// Process-monotonic snapshot id (strictly increasing).
  let id: UInt64
  /// IMK session identity; changes when the composition session is replaced.
  let sessionID: UInt64
  /// Active Rime schema id (e.g. `pinyin_simp`, `wubi86_jidian`). Distinguishes 拼音/五笔.
  let schemaID: String
  /// Raw input code typed so far (alphabet / wubi code stream).
  let rawInput: String
  /// Current preedit / marked-text string shown to the user.
  let preedit: String
  /// Caret position within the preedit (UTF-16-agnostic logical index from the engine).
  let cursor: Int
  /// 0-based candidate page number at capture time.
  let pageNo: Int
  /// Top-N candidates copied out of the live menu page (default N = ``defaultTopN``).
  let candidates: [RimeCandidateSnapshot]
  /// Commit serial at capture time; bumped on commit/clear/escape/schema switch.
  let commitSerial: UInt64
  /// `DispatchTime.now().uptimeNanos` at capture, for local debug telemetry only (never uploaded).
  let createdAtNanos: UInt64

  /// Default number of top candidates copied into a snapshot. Configurable per capture.
  static let defaultTopN: Int = 9

  init(
    id: UInt64,
    sessionID: UInt64,
    schemaID: String,
    rawInput: String,
    preedit: String,
    cursor: Int,
    pageNo: Int,
    candidates: [RimeCandidateSnapshot],
    commitSerial: UInt64,
    createdAtNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    self.id = id
    self.sessionID = sessionID
    self.schemaID = schemaID
    self.rawInput = rawInput
    self.preedit = preedit
    self.cursor = cursor
    self.pageNo = pageNo
    self.candidates = candidates
    self.commitSerial = commitSerial
    self.createdAtNanos = createdAtNanos
  }
}

/// Thread-safe source of strictly-increasing snapshot ids. A snapshot may be built off the
/// hot path, so the counter must be safe to call from any thread; an `os_unfair_lock`-guarded
/// `UInt64` keeps `next()` allocation-free and cheap (the hot path must stay < 1 ms).
final class FamoSnapshotIDGenerator: @unchecked Sendable {
  /// Shared generator. One process-wide monotonic id space is sufficient and simplest.
  static let shared = FamoSnapshotIDGenerator()

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
