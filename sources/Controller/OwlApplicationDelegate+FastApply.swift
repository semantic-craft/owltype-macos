//
//  OwlApplicationDelegate+FastApply.swift
//  Owltype
//
//  Fast settings-apply (Track 2 / PR3). Extracted from OwlApplicationDelegate.swift to keep
//  that file under the SwiftLint file_length warning. Persistence and deploy entry points run
//  from the settings-apply closures (`onApplyKeyboardConfigFast` / `onApplyFuzzyConfigFast`) or
//  the schema picker. The queued Rust generation handoff only drains at the outermost idle
//  `rimeUpdate` / next-key boundary, never in the middle of a composition transaction.
//

import AppKit

extension OwlApplicationDelegate {
  // MARK: - Fast settings-apply (Track 2 / PR3)

  /// Apply a resource-generation switch only when the active composition is idle.
  ///
  /// Replaying `rawInput` cannot reconstruct the Rust session's selected phrase progress
  /// (`phrase_progress`). Therefore a resource switch never tears down a session with live
  /// content: it queues one refresh, and the controller calls this again when a composition
  /// ends. The active generation pointer is already updated, so this is only the live-session
  /// handoff, not another storage transaction.
  @discardableResult
  @MainActor
  func requestLiveSessionRefreshWhenIdle(
    completion: @escaping @MainActor () -> Void
  ) -> Bool {
    liveSessionRefreshCompletions.append(completion)
    return applyPendingLiveSessionRefreshIfIdle()
  }

  /// Drain queued resource refreshes at a safe boundary. Returns true when any live session
  /// still has content and the refresh remains queued. Background sessions normally committed
  /// on `deactivateServer`; checking all live sessions protects a stale lifecycle from
  /// turning the destroy-only background branch into silent content loss.
  @discardableResult
  @MainActor
  func applyPendingLiveSessionRefreshIfIdle() -> Bool {
    guard !liveSessionRefreshCompletions.isEmpty else { return false }
    guard !liveControllers.allObjects.contains(where: \.hasInFlightComposition) else {
      return true
    }

    let completions = liveSessionRefreshCompletions
    liveSessionRefreshCompletions.removeAll()
    reapplyToLiveSession()
    for completion in completions {
      completion()
    }
    return false
  }

  /// Owns persistence and activation together; callers only choose the kind of edit.
  func applyKeyboardSettings(
    _ mode: OwlKeyboardSettingsApplication.Mode,
    snapshot: OwlKeyboardSnapshot = .current(),
    directory: URL = OwlApp.userDir
  ) throws -> OwlKeyboardSettingsApplication.Outcome {
    try OwlKeyboardSettingsApplication(
      engine: engine,
      directory: directory,
      refresh: { self.loadSettings(); self.reapplyToLiveSession() }
    ).apply(snapshot, mode: mode)
  }

  /// Re-apply the just-deployed config to EVERY live controller's session so the freshly-built
  /// `build/` actually takes effect (live-session-reload rewrite, 2026-06-22).
  ///
  /// The old implementation only touched `activeInputController` and used `select_schema(sameId)`,
  /// which does NOT force librime to rebuild the cached `Schema` — so a changed `menu/page_size`
  /// never reached the running session (the 8→5-not-applying bug). The fix forces a real reload
  /// by destroying sessions (the engine stays up — no octagram reload → still sub-second):
  ///
  /// - Background controllers are DESTROYED ONLY. Their `client` is nil after `deactivateServer`,
  ///   so eagerly recreating now would mislabel the app (`UnknownApp<n>`) and drop its per-app
  ///   options. Instead their `handle()` hot path lazily recreates on the next keystroke (with a
  ///   live `client`), reading the new `build/` then.
  /// - The ACTIVE controller is refreshed LAST: destroy + recreate + restore its captured schema
  ///   + replay its in-flight composition, so the panel re-renders immediately under the new
  ///   config (no retype).
  ///
  /// No-op when no controller is live — the next `createSession` reads fresh `build/` anyway. Off
  /// the IMK keystroke hot path.
  func reapplyToLiveSession() {
    OwlLatencyTrace.event("deploy.sessionReapplyStart")
    let active = activeInputController
    // Snapshot first (mutating sessions during iteration; the table is weak so dead ones are
    // already gone). Background controllers (destroy-only) first, then the active one LAST so its
    // recreate + panel render wins.
    let live = liveControllers.allObjects
    for controller in live where controller !== active {
      OwlLatencyTrace.event("deploy.sessionRelease")
      controller.reapplyConfigToLiveSession(replayComposition: false)
    }
    if active != nil {
      OwlLatencyTrace.event("deploy.sessionRecreate")
    }
    active?.reapplyConfigToLiveSession(replayComposition: true)
  }
}
