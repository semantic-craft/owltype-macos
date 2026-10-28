//
//  RimeSeam.swift
//  Owltype
//
//  The input Engine/Session seam. Two small protocols put a testable boundary
//  in front of the production Rust engine:
//
//    • `RimeEngine`  — the global Rime lifecycle (setup/initialize/deploy/sync/finalize,
//                      schema list & selection, notification handler). Vends Sessions.
//    • `RimeSession` — one composition's conversation (process key, take commit, read
//                      status/composition, candidate select/page/caret, options).
//
//  `OwlRustEngine` / `OwlRustSession` are the only production adapters. Opaque native
//  handles stay inside them; only value types cross the protocol boundary. Callers never
//  cast past these protocols: every behaviour the controller needs is a requirement here,
//  with no default implementations, so a fake has to model each path production runs.
//
//  Threading invariant: these are synchronous and MUST be called on the IMK input
//  thread (the thread IMK delivers `handle(_:client:)` on). There is no actor and no
//  async — the contract is "single-threaded on the IMK callback thread", matching the
//  non-isolated controller. Fakes (PR2) are synchronous too.
//
//  Behaviour note: this is a behaviour-preserving strangler. Each method makes the SAME
//  librime call(s) in the SAME order the controller used to make inline — only the call
//  SITE moved behind the seam.
//

import Foundation

// MARK: - Protocols

enum OwlSettledRerankTiming {
  static let debounce: TimeInterval = 0.15
  static let pollInterval: TimeInterval = 1.0 / 60.0
  static let modelLoadPollInterval: TimeInterval = 0.05
}

struct OwlSettledRerankTicket: Equatable, Sendable {
  let sessionID: UInt64
  let generation: UInt64
  let rawInput: String
  let configurationEpoch: UInt64

  func isCurrent(
    sessionID: UInt64,
    generation: UInt64,
    rawInput: String,
    configurationEpoch: UInt64
  ) -> Bool {
    self.sessionID == sessionID
      && self.generation == generation
      && self.rawInput == rawInput
      && self.configurationEpoch == configurationEpoch
  }
}

struct OwlSettledRerankStartResult: Equatable, Sendable {
  let token: UInt64?
  let current: Bool
  let moved: Bool
  let error: String?

  static let noWork = OwlSettledRerankStartResult(
    token: nil,
    current: true,
    moved: false,
    error: nil
  )
}

struct OwlSettledRerankPollResult: Equatable, Sendable {
  let pending: Bool
  let current: Bool
  let moved: Bool
  let error: String?

  static let doneWithoutChange = OwlSettledRerankPollResult(
    pending: false,
    current: false,
    moved: false,
    error: nil
  )
}

/// One composition's conversation with librime. All calls are on the IMK input thread.
protocol RimeSession: AnyObject {
  /// A stable opaque identifier for this session, used only to tag composition snapshots
  /// (`OwlSnapshotEmitter`). The engine assigns it.
  var sessionID: UInt64 { get }
  /// Monotonic composition generation counter for `OwlCandidateToken` (#264).
  var generation: UInt64 { get }

  /// True if this session id is still valid (`find_session`). 0/destroyed → false.
  var isValid: Bool { get }

  /// `process_key` — returns whether librime consumed the key.
  func process(keycode: UInt32, modifiers: UInt32) -> Bool

  /// Drain a pending commit (`get_commit` + `free_commit`); nil if none.
  func takeCommit() -> String?

  /// Read status (`get_status` + `free_status`) as a value type; nil on failure.
  func status() -> RimeStatus?

  /// Read the composition/context (`get_context` + `free_context`) as a value type; nil on failure.
  func composition() -> RimeComposition?

  /// The raw input string (`get_input`); nil if unavailable.
  func input() -> String?

  /// The raw input string that originated the most recent commit, when the engine already
  /// cleared `input()` upon committing (used by prompt/template commit interception).
  func lastCommittedInput() -> String?

  /// Caret position in UTF-8 bytes (`get_caret_pos`).
  func caretPos() -> Int

  /// Move the caret (`set_caret_pos`).
  func setCaretPos(_ pos: Int)

  /// `clear_composition`.
  func clearComposition()

  /// `select_candidate_on_current_page`.
  func selectCandidate(_ index: Int) -> Bool

  /// `select_candidate`: select by **absolute** index into the whole candidate list, so a
  /// candidate that is visible but not on the current page can be committed without paging
  /// there first. Only the 多行后页行 click path uses it (mouse-only — the keyboard hot path
  /// still goes through librime's own current-page number keys). A default implementation
  /// returns `false` so existing fakes stay source-compatible.
  func selectCandidateAbsolute(_ index: Int) -> Bool
  /// Select a candidate using its `OwlCandidateToken` (#264).
  func selectCandidate(_ token: OwlCandidateToken) -> Bool

  /// Remove a currently visible candidate through the engine learning journal.
  func removeCandidate(_ token: OwlCandidateToken) -> Bool

  /// `change_page`; `up == true` pages backward.
  func changePage(up: Bool) -> Bool

  /// Read-only peek at the candidate list beyond the current page（三行候选·预览后页）.
  /// `candidate_list_from_index` + `candidate_list_next/end`: returns up to `count`
  /// candidates starting at absolute `index` into the WHOLE candidate list (not the current
  /// page). The iterator walks its own copy of the menu — the session's page/highlight
  /// state is untouched, and no IMK client round-trip is involved. Returns `[]` when the
  /// API is unavailable or the iterator can't start (e.g. index past the end). A default
  /// implementation returns `[]` so existing fakes stay source-compatible.
  func peekCandidates(from index: Int, count: Int) -> [RimeCandidate]

  /// The configured model generation. Changes whenever enabled/path/version/hash changes, so a
  /// settled result started under an older model configuration is discarded.
  var rerankConfigurationEpoch: UInt64 { get }

  /// The settled model has loaded and is attached to this runtime. The controller does not
  /// start a pause job until this is true.
  var settledRerankReady: Bool { get }

  /// The settled model is still loading on the FFI worker. A pause timer normally consumes the
  /// whole debounce interval, so the controller keeps a short retry alive while this is true.
  var settledRerankLoading: Bool { get }

  /// Re-read rerank preferences and apply them to this session on its own IMK thread.
  func syncRerankPreferences()

  /// Start the model worker for the current composition. The returned token must be polled on
  /// this same session thread, even after the composition becomes stale.
  func startSettledRerank() -> OwlSettledRerankStartResult

  /// Poll a settled job. `accept=false` drains the job without applying or moving candidates.
  func pollSettledRerank(token: UInt64, accept: Bool) -> OwlSettledRerankPollResult

  /// `select_schema` on THIS live session — re-reads the compiled `build/<schema>.schema.yaml`
  /// in place (no engine restart, no dict/octagram rebuild; clears the current composition).
  /// Used by the fast settings-apply path to make a just-deployed config effective on the
  /// active composition's session. NOT on the IMK keystroke hot path.
  func selectSchema(_ id: String) -> Bool

  /// `get_option` for a Owltype-driven option.
  func option(_ option: RimeOption) -> Bool

  /// `set_option` for a Owltype-driven option.
  func setOption(_ option: RimeOption, _ value: Bool)

  /// `set_property`.
  func setProperty(name: String, value: String)

  /// `get_state_label_abbreviated` for the open-namespace option name librime reports.
  func stateLabel(option name: String, state: Bool, abbreviated: Bool) -> String?

  /// Native finish: select the highlighted conversion and commit it through the engine
  /// (`finish`, or `finish_on_focus_loss` when the host ends the composition), so the engine
  /// learns the selection. Returns false when the engine refused the action; the caller then
  /// falls back to `OwlForcedFinalize`. Any commit is drained with `takeCommit()`.
  @discardableResult
  func finishNativeComposition(onFocusLoss: Bool) -> Bool

  /// True when the engine is in no local mode (no symbol menu, no reverse lookup…), so the
  /// host may apply smart punctuation and keep a paired closing mark.
  var acceptsHostSmartPunctuation: Bool { get }

  /// Tell the engine the host opened a 《 or 〈 pair, so its own nesting state stays balanced.
  func balanceHostPairedPunctuation()

  /// Smart punctuation routed this key to ASCII during a composition: the engine commits the
  /// composition followed by the ASCII mark. Returns whether the engine handled it.
  func processHostASCIIPunctuation(_ character: String) -> Bool

  /// `destroy_session`. After this the session is invalid.
  func destroy()
}

struct OwlEngineTraits {
  let sharedDataDir: URL
  let userDataDir: URL
  let logDir: URL
  let appName: String
}

/// Swift-owned engine notification. No C callback or context pointer crosses the seam.
typealias RimeNotificationHandler = (UInt64, String, String?) -> Void

/// The global input-engine lifecycle. Vends Sessions. All calls are on the IMK input thread.
protocol RimeEngine: AnyObject {
  func setup(_ traits: OwlEngineTraits)
  func startMaintenance(fullCheck: Bool) -> Bool
  func joinMaintenance()
  func deployConfigFile(_ fileName: String, versionKey: String) -> Bool
  func setNotificationHandler(_ handler: @escaping RimeNotificationHandler)
  func cleanupAllSessions()
  func finalize() -> Bool
  func schemaList() -> [(id: String, name: String)]
  func currentSchema() -> String
  func selectSchema(_ id: String) -> Bool
  func version() -> String?
  func createSession() -> RimeSession
  func session(for id: UInt64) -> RimeSession
}

// MARK: - Snapshot-reading port (god-object reduction)
//
// The SAME injection range RimeEngine/RimeSession established for librime, extended to the
// live composition snapshot the controller reads off the IMK hot path (e.g. to drive the
// 任意提问 window over the current composition context). A narrow (ISP) protocol over the one
// member the controller uses — NOT the registry's whole surface — so the path becomes drivable
// from a fake with no librime session. Production wires the `.shared` instance on the AppDelegate
// (composition root, alongside `engine`); injection is purely additive and changes no behaviour.
// `@MainActor` because the backing singleton (`OwlSnapshotRegistry`) is, and the controller
// touches it only from `@MainActor` Task bodies.

/// The controller's read-only view of the live composition snapshot. Exposes ONLY `current`
/// — not the registry's `update`/`isCurrent`/`@Published` write & subscribe surface — so a
/// trigger path can be handed a scripted snapshot without a live composition.
@MainActor
protocol SnapshotReading: AnyObject {
  /// The currently live composition snapshot, or nil when there is no active composition.
  var current: OwlCompositionSnapshot? { get }
}

// Conformance only — no implementation change. The member already exists with a matching
// shape; this just publishes it through the narrow port.
extension OwlSnapshotRegistry: SnapshotReading {}

// MARK: - Controller→service ports: snapshot emitter / selection polish
//
// The SAME controller→service injection range RimeEngine/SnapshotReading
// established, extended to the TWO remaining global singletons `OwlInputController` still
// reached for off the IMK hot path via bare `.shared`:
//
//   • `SnapshotEmitting`     — the composition-timeline emitter the controller pokes from
//                              `rimeUpdate()` / `commit()` (was `OwlSnapshotEmitter.shared`).
//   • `SelectionPolishing`   — the explicit 润色选中 rewrite the controller awaits (was
//                              `OwlSelectionPolishService.shared`).
//
// Each is a narrow (ISP) protocol over ONLY the members the controller calls — NOT the
// singleton's whole surface — so the AI / snapshot path becomes drivable from a fake with no
// librime session and no network. Production wires the `.shared` instances on the AppDelegate
// (composition root, alongside `engine` / `snapshots`); injection is purely
// additive and changes no behaviour. Both are `@MainActor` because the backing singletons
// are, and the controller touches them only on the main actor (the emitter calls are already
// inside the controller's `MainActor.assumeIsolated { … }` / `Task { @MainActor in … }`).

/// The controller's view of the composition-timeline snapshot emitter. Exposes ONLY the 4
/// methods the controller pokes — not the emitter's `commitSerial` — so the snapshot path can be
/// driven and asserted without a librime session.
@MainActor
protocol SnapshotEmitting: AnyObject {
  func noteCommit()
  func noteSchemaChange()
  func emitComposing(sessionID: UInt64, schemaID: String, rawInput: String, preedit: String, cursor: Int, pageNo: Int, candidates: [RimeCandidateSnapshot])
  func emitCleared()
}

/// The controller's explicit 润色选中 rewrite. Exposes ONLY the rewrite entry point — not the
/// service's keychain / fetcher / preferences internals — so a fake can return scripted
/// rewrites without DeepSeek or the keychain.
@MainActor
protocol SelectionPolishing: AnyObject {
  func polishSelection(_ selection: String) async throws -> [String]
}

/// The controller's prompt lookup at the commit chokepoint (task 06-30-owl-prompt-management-panel).
/// Exposes ONLY the (originating code, committed title) → entry lookup — not the store's
/// load/save/validation surface — so a fake can return a scripted prompt without touching disk.
/// `nil` = the committed candidate is not a Owltype prompt (→ normal Rime commit).
@MainActor
protocol PromptResolving: AnyObject {
  func entry(forCode code: String, title: String) -> OwlPromptEntry?
}

// Conformances only — the members already exist with matching signatures.
extension OwlSnapshotEmitter: SnapshotEmitting {}
extension OwlSelectionPolishService: SelectionPolishing {}
extension OwlPromptResolver: PromptResolving {}
