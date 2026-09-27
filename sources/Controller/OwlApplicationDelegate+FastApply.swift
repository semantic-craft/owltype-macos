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

  /// Fast path for Track-2 *config-only* settings (候选个数 `menu/page_size` / 翻页·选词键
  /// `key_binder` / Shift `ascii_composer` / slash `punctuator` /
  /// schema_list). The patch text is already written by the caller
  /// (`OwlManagedKeyboardPatchPlan.apply`); this only makes it EFFECTIVE without the heavy
  /// `deploy()` (`shutdownRime` + `startRime(fullCheck:true)`):
  ///   1. `deploy_config_file("default.yaml")` (+ the active `<schema>.schema.yaml`) — the
  ///      `config_file_update` task: recompiles ONE config, merges its `.custom.yaml`,
  ///      mtime-gated, NO dict/octagram rebuild. `config_file_update` is a synchronous
  ///      `RunTask`, so the rebuilt `build/` is ready before the reselect below.
  ///   2. force EVERY live session to reload the new `build/` (`reapplyToLiveSession`:
  ///      destroy+recreate each session + restore its schema; the active one also replays its
  ///      composition so the panel re-renders under the new config — no retype). A same-id
  ///      reselect was NOT enough (it doesn't rebuild the cached Schema → page_size stayed stale).
  /// Wrapped in a `OwlPerf` mark (PR1's deferred empirical deliverable). Reloads `loadSettings`
  /// so style flags pick up any layout change. NOT on the IMK keystroke hot path. Returns
  /// whether the config_file deploy(s) succeeded.
  @discardableResult
  func applyKeyboardConfigFast() -> Bool {
    let trace = OwlLatencyTrace.begin("deploy.fast.config")
    defer { OwlLatencyTrace.end("deploy.fast.config", trace) }
    guard !templateRecoveryBlocksDeployment() else { return false }
    let perf = OwlPerf.mark()
    var ok = engine.deployConfigFile("default.yaml", versionKey: "config_version")
    // owltype.yaml (frontend config: style + per-app app_options) is NOT in rime's tracked
    // default/schema set — without this explicit deploy, App 默认英文 writes landing in
    // owltype.custom.yaml's managed block never reach build/owltype.yaml, so getAppOptions keeps
    // serving factory entries only (#121 真机验收逮住). config_file_update is
    // fingerprint-gated → free when owltype.custom.yaml is unchanged.
    ok = engine.deployConfigFile(OwlRimeIdentity.configFile, versionKey: "config_version") && ok
    let schema = activeSchemaIdForFastApply()
    if !schema.isEmpty, schema.first != "." {
      // The active schema's own config carries schema-level keys (wubi 编码提示 / 单字 / 清码,
      // schema-bundled punctuator). config_file_update is config-only (no prism/dict rebuild).
      ok = engine.deployConfigFile("\(schema).schema.yaml", versionKey: "schema/version") && ok
    }
    loadSettings()
    reapplyToLiveSession()
    OwlPerf.since(perf, "fastapply.config")
    return ok
  }

  /// Fast-ish path for the ONE Track-2 exception — 模糊拼音 `speller/algebra`. Changing
  /// algebra rebuilds the schema PRISM (`dict_compiler`), which the config-only
  /// `deploy_config_file` path does NOT do, so it falls back to the mtime-gated
  /// `start_maintenance(fullCheck:false)` (rebuilds only the affected schema — NOT octagram —
  /// per `detect_modifications`). Faster than the full `deploy()` (`fullCheck:true` skips the
  /// mtime gate), but honestly NOT instant. `start_maintenance` schedules its work on a
  /// background thread and returns immediately, so we `joinMaintenance()` to wait for the prism
  /// rebuild to land in `build/` BEFORE the reselect re-reads it (otherwise the reselect would
  /// race the rebuild and the new fuzzy rules would silently not take effect). Then reselect +
  /// replay on the live session. NOT on the IMK keystroke hot path. Returns whether maintenance
  /// started.
  @discardableResult
  func applyFuzzyConfigFast() -> Bool {
    let trace = OwlLatencyTrace.begin("deploy.fast.fuzzy")
    defer { OwlLatencyTrace.end("deploy.fast.fuzzy", trace) }
    guard !templateRecoveryBlocksDeployment() else { return false }
    let perf = OwlPerf.mark()
    // mtime-gated maintenance: rebuilds only the schema whose `speller/algebra` changed
    // (prism), never octagram. No shutdownRime — the live session stays up.
    let ok = engine.startMaintenance(fullCheck: false)
    if ok {
      // Block until the async workspace_update (prism rebuild) finishes, so the reselect
      // below re-reads the rebuilt build/<schema>.schema.yaml rather than the stale one.
      engine.joinMaintenance()
    }
    loadSettings()
    reapplyToLiveSession()
    OwlPerf.since(perf, "fastapply.fuzzy")
    return ok
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
