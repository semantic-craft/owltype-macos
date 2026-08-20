//
//  OwlSchemaSelectionGate.swift
//  猫头鹰输入法 (Owltype) — 方案 select 尝试/退避的纯决策 (task 07-07-schema-consistency-guard)
//
//  librime `select_schema` can fail (the target `build/<id>.schema.yaml` isn't compiled — e.g. a
//  stale seed, or a schema the user picked before its config was deployed). Two controller paths
//  call it and used to mishandle that failure:
//    • the idle-key guard (`ensurePreferredSchemaForIdleSession`) re-ran a doomed select on EVERY
//      idle keystroke — one wasted librime call + one trace line per key, forever;
//    • the live picker switch (`switchLiveSessionSchema`) wrote the cached `schemaId` even when the
//      select failed, poisoning the cache into a not-actually-active schema (设置显示拼音, 打字出五笔).
//
//  This pure decision splits "what should the idle guard do this key" and "what's the new
//  known-failed marker after an attempt" out of the controller side effects, mirroring how
//  `OwlForcedFinalize` / `OwlAutoPair` keep a testable seam in front of the IMK/librime shell.
//
//  This file is PURE value logic only — no IMK, no librime handle, no UserDefaults, no IO. The
//  impure shell (reading `rime.status()`, calling `rime.selectSchema`, writing `schemaId`, emitting
//  the user-facing notification, resetting the marker on config change) stays in
//  `OwlInputController+Session.swift` / `OwlApplicationDelegate.swift`.
//

import Foundation

/// The pure "attempt vs back off, and remember failures" decision for schema selection.
enum OwlSchemaSelectionGate {

  /// What the idle-key guard should do this keystroke.
  enum IdleAction: Equatable {
    /// The session already runs the preferred schema → adopt it as `schemaId`, make no librime call.
    case alreadyActive
    /// The preferred schema differs and is not a known-failed id → attempt `select_schema`.
    case attempt
    /// The preferred schema equals the last id whose select failed (and config hasn't changed
    /// since) → back off: no librime call, no per-key trace. Cleared when config changes / a select
    /// later succeeds (the caller resets the marker).
    case skipKnownFailed
  }

  /// Decide the idle-key guard's action.
  ///
  /// - Parameters:
  ///   - current: the session's observed schema id (`rime.status()?.schemaId`), possibly empty.
  ///   - preferred: the settings source-of-truth schema id (`preferredSchemaID`); the caller
  ///     guarantees this is non-empty before calling.
  ///   - knownFailed: the last preferred id whose `select_schema` returned false and has not been
  ///     cleared by a success or a config change; `nil` when none is known-failed.
  static func idleAction(current: String, preferred: String, knownFailed: String?) -> IdleAction {
    if current == preferred { return .alreadyActive }
    if let knownFailed, knownFailed == preferred { return .skipKnownFailed }
    return .attempt
  }

  /// The new known-failed marker after a `select_schema` attempt.
  ///
  /// - Returns: `nil` when the select succeeded (clears any prior mark — the config is now
  ///   consistent); the attempted `preferred` id when it failed (remember it so the idle guard
  ///   backs off instead of retrying every key).
  static func markerAfterAttempt(preferred: String, selected: Bool) -> String? {
    selected ? nil : preferred
  }
}

/// The typed outcome of a live picker schema switch (`switchLiveSessionSchema`), so the caller can
/// give the user perceptible feedback on failure instead of silently poisoning `schemaId`.
enum SchemaSwitchResult: Equatable {
  /// `select_schema` succeeded; the live session now runs the new schema and `schemaId` was updated.
  case ok
  /// No live session to switch (the next `createSession` will pick up the switched schema, which
  /// librime remembers via the transient-session select the delegate also performs).
  case noLiveSession
  /// `select_schema` failed; `schemaId` was NOT written (no cache poisoning). Carries the id that
  /// failed so the caller can name it in user-facing feedback.
  case selectFailed(schemaID: String)
}
