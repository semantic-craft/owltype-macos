//
//  OwlApplicationDelegate+FastApply.swift
//  Owltype
//
//  Fast settings-apply (Track 2 / PR3). Extracted from OwlApplicationDelegate.swift to keep
//  that file under the SwiftLint file_length warning. None of this runs on the IMK keystroke
//  hot path — every entry point here is invoked only from the settings-apply closures
//  (`onApplyKeyboardConfigFast` / `onApplyFuzzyConfigFast`) or the schema picker.
//

import AppKit

extension OwlApplicationDelegate {
  // MARK: - Fast settings-apply (Track 2 / PR3)

  /// Owns persistence and activation together; callers only choose the kind of edit.
  func applyKeyboardSettings(
    _ mode: OwlKeyboardSettingsApplication.Mode,
    snapshot: OwlKeyboardSnapshot = .current(),
    directory: URL = OwlApp.userDir
  ) throws -> OwlKeyboardSettingsApplication.Outcome {
    try OwlKeyboardSettingsApplication(
      engine: engine,
      directory: directory,
      activeSchema: activeSchemaIdForFastApply,
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

  /// The schema id to refresh + reselect for the fast path: prefer the active controller's
  /// live `schemaId`, else the engine's best-effort current schema. "" when unavailable.
  func activeSchemaIdForFastApply() -> String {
    if let live = activeInputController?.schemaId, !live.isEmpty {
      return live
    }
    return currentSchemaId()
  }
}
