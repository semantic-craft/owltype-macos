//
//  RimeSeam.swift
//  Owltype
//
//  The Rime Engine/Session seam (PR1b of the Rime engine seam refactor). Two small
//  protocols put a testable boundary in front of the librime C API:
//
//    • `RimeEngine`  — the global Rime lifecycle (setup/initialize/deploy/sync/finalize,
//                      schema list & selection, notification handler). Vends Sessions.
//    • `RimeSession` — one composition's conversation (process key, take commit, read
//                      status/composition, candidate select/page/caret, options).
//
//  `LiveRimeEngine` / `LiveRimeSession` are the production adapters. They are the ONLY
//  owners of the `rimeAPI` singleton (`RimeApi_stdbool`) and the raw `RimeSessionId`.
//  Every C-struct alloc → read → free happens INSIDE the adapter; only the value types
//  in RimeValueTypes.swift cross the protocol boundary.
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

/// One composition's conversation with librime. All calls are on the IMK input thread.
protocol RimeSession: AnyObject {
  /// A stable opaque identifier for this session, used only to tag composition snapshots
  /// (`OwlSnapshotEmitter`). For the live adapter this is the raw `RimeSessionId`.
  var sessionID: UInt64 { get }

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

  /// `select_schema` on THIS live session — re-reads the compiled `build/<schema>.schema.yaml`
  /// in place (no engine restart, no dict/octagram rebuild; clears the current composition).
  /// Used by the fast settings-apply path to make a just-deployed config effective on the
  /// active composition's session. NOT on the IMK keystroke hot path.
  func selectSchema(_ id: String) -> Bool

  /// `get_option` for a Owltype-driven option.
  func option(_ option: RimeOption) -> Bool

  /// `set_option` for a Owltype-driven option.
  func setOption(_ option: RimeOption, _ value: Bool)

  /// `set_option` for an open-namespace app option (arbitrary key from config). Kept
  /// separate from the closed `RimeOption` set on purpose — see `updateAppOptions`.
  func setAppOption(_ key: String, _ value: Bool)

  /// `set_property`.
  func setProperty(name: String, value: String)

  /// `get_state_label_abbreviated` for the open-namespace option name librime reports.
  func stateLabel(option name: String, state: Bool, abbreviated: Bool) -> String?

  /// `destroy_session`. After this the session is invalid.
  func destroy()
}

extension RimeSession {
  /// Default no-preview implementation — keeps fakes/spies source-compatible; the live
  /// adapter overrides with the real iterator walk.
  func peekCandidates(from _: Int, count _: Int) -> [RimeCandidate] { [] }

  /// Default no-op — keeps fakes/spies source-compatible; the live adapter overrides with
  /// `select_candidate`.
  func selectCandidateAbsolute(_: Int) -> Bool { false }
}

/// The global Rime lifecycle. Vends Sessions. All calls are on the IMK input thread.
protocol RimeEngine: AnyObject {
  /// `setup`.
  func setup(_ traits: inout RimeTraits)

  /// `initialize`.
  func initialize(_ traits: UnsafeMutablePointer<RimeTraits>?)

  /// `start_maintenance`.
  func startMaintenance(fullCheck: Bool) -> Bool

  /// `join_maintenance_thread` — block until the async `start_maintenance` work thread
  /// (`workspace_update`, prism/dict rebuild) has finished. MUST be called before re-reading
  /// the freshly-built `build/` (e.g. the fast fuzzy-apply reselect), since `start_maintenance`
  /// schedules its work on a background thread and returns immediately. Off the hot path.
  func joinMaintenance()

  /// `deploy_config_file`.
  func deployConfigFile(_ fileName: String, versionKey: String) -> Bool

  /// `set_notification_handler`.
  func setNotificationHandler(_ handler: @escaping RimeNotificationHandler, context: UnsafeMutableRawPointer?)

  /// `sync_user_data`.
  func syncUserData() -> Bool

  /// `cleanup_all_sessions`.
  func cleanupAllSessions()

  /// `finalize`.
  func finalize()

  /// `get_schema_list` + `free_schema_list`, decoded to value tuples.
  func schemaList() -> [(id: String, name: String)]

  /// Current schema id via a transient session (`get_current_schema`); "" when unavailable.
  func currentSchema() -> String

  /// Select a schema via a transient session (`select_schema`). Returns false when the target
  /// is not compiled, including the clean-install dict-pack case with no active IMK session.
  func selectSchema(_ id: String) -> Bool

  /// `get_version`; nil when unavailable.
  func version() -> String?

  /// `create_session`. Returns a live Session wrapping the new id (0 → invalid session).
  func createSession() -> RimeSession

  /// Wrap a session id librime handed back (e.g. in the notification handler) without
  /// creating a new one, so its read-only helpers (`stateLabel`) are reachable through
  /// the seam. Does NOT own the id's lifetime — the engine/owner created/destroys it.
  func session(for id: RimeSessionId) -> RimeSession
}

// MARK: - Live adapters

/// Production `RimeSession`: wraps the `rimeAPI` singleton + one `RimeSessionId`. Owns
/// all C-struct lifetime for this session. The controller holds one of these via its
/// swappable `rime` property (live default vended by `LiveRimeEngine.createSession()`).
final class LiveRimeSession: RimeSession {
  private let rimeAPI: RimeApi_stdbool
  private(set) var sessionId: RimeSessionId

  init(rimeAPI: RimeApi_stdbool, sessionId: RimeSessionId) {
    self.rimeAPI = rimeAPI
    self.sessionId = sessionId
  }

  var sessionID: UInt64 { UInt64(sessionId) }

  var isValid: Bool {
    sessionId != 0 && rimeAPI.find_session(sessionId)
  }

  func process(keycode: UInt32, modifiers: UInt32) -> Bool {
    rimeAPI.process_key(sessionId, Int32(keycode), Int32(modifiers))
  }

  func takeCommit() -> String? {
    var commit = RimeCommit.rimeStructInit()
    defer { _ = rimeAPI.free_commit(&commit) }
    guard rimeAPI.get_commit(sessionId, &commit) else { return nil }
    return commit.text.map { String(cString: $0) }
  }

  func status() -> RimeStatus? {
    var status = RimeStatus_stdbool.rimeStructInit()
    guard rimeAPI.get_status(sessionId, &status) else { return nil }
    defer { _ = rimeAPI.free_status(&status) }
    let schemaId = status.schema_id.map { String(cString: $0) } ?? ""
    return RimeStatus(
      schemaId: schemaId,
      isASCIIMode: status.is_ascii_mode,
      isASCIIPunct: status.is_ascii_punct,
      isFullShape: status.is_full_shape
    )
  }

  // swiftlint:disable:next identifier_name
  func composition() -> RimeComposition? {
    var ctx = RimeContext_stdbool.rimeStructInit()
    guard rimeAPI.get_context(sessionId, &ctx) else { return nil }
    defer { _ = rimeAPI.free_context(&ctx) }

    let preedit = ctx.composition.preedit.map { String(cString: $0) } ?? ""
    let commitTextPreview = ctx.commit_text_preview.map { String(cString: $0) }

    let numCandidates = Int(ctx.menu.num_candidates)
    var candidates = [RimeCandidate]()
    candidates.reserveCapacity(numCandidates)
    for i in 0..<numCandidates {
      let candidate = ctx.menu.candidates[i]
      candidates.append(RimeCandidate(
        text: candidate.text.map { String(cString: $0) } ?? "",
        comment: candidate.comment.map { String(cString: $0) }
      ))
    }

    // Label precedence preserved exactly from the old `rimeUpdate`: select_keys (one
    // label per character) wins; otherwise select_labels[0..<page_size].
    var labels = [String]()
    if let select_keys = ctx.menu.select_keys {
      labels = String(cString: select_keys).map { String($0) }
    } else if let select_labels = ctx.select_labels {
      let pageSize = Int(ctx.menu.page_size)
      for i in 0..<pageSize {
        labels.append(select_labels[i].map { String(cString: $0) } ?? "")
      }
    }

    return RimeComposition(
      preedit: preedit,
      selStart: Int(ctx.composition.sel_start),
      selEnd: Int(ctx.composition.sel_end),
      cursorPos: Int(ctx.composition.cursor_pos),
      commitTextPreview: commitTextPreview,
      candidates: candidates,
      labels: labels,
      pageNo: Int(ctx.menu.page_no),
      pageSize: Int(ctx.menu.page_size),
      isLastPage: ctx.menu.is_last_page,
      highlightedIndex: Int(ctx.menu.highlighted_candidate_index),
      numCandidates: numCandidates
    )
  }

  func input() -> String? {
    rimeAPI.get_input(sessionId).map { String(cString: $0) }
  }

  func caretPos() -> Int {
    Int(rimeAPI.get_caret_pos(sessionId))
  }

  func setCaretPos(_ pos: Int) {
    rimeAPI.set_caret_pos(sessionId, pos)
  }

  func clearComposition() {
    rimeAPI.clear_composition(sessionId)
  }

  func selectCandidate(_ index: Int) -> Bool {
    rimeAPI.select_candidate_on_current_page(sessionId, index)
  }

  func selectCandidateAbsolute(_ index: Int) -> Bool {
    rimeAPI.select_candidate(sessionId, index)
  }

  func changePage(up: Bool) -> Bool {
    rimeAPI.change_page(sessionId, up)
  }

  func peekCandidates(from index: Int, count: Int) -> [RimeCandidate] {
    // Guarded like `get_version`: the function pointers ride librime's data_size
    // versioning, so an older dylib may not carry them — degrade to "no preview".
    guard count > 0,
          let fromIndex = rimeAPI.candidate_list_from_index,
          let next = rimeAPI.candidate_list_next,
          let end = rimeAPI.candidate_list_end else { return [] }
    var iterator = RimeCandidateListIterator()
    guard fromIndex(sessionId, &iterator, Int32(index)) else { return [] }
    defer { end(&iterator) }
    var peeked: [RimeCandidate] = []
    peeked.reserveCapacity(count)
    while peeked.count < count, next(&iterator) {
      peeked.append(RimeCandidate(
        text: iterator.candidate.text.map { String(cString: $0) } ?? "",
        comment: iterator.candidate.comment.map { String(cString: $0) }
      ))
    }
    return peeked
  }

  func selectSchema(_ id: String) -> Bool {
    id.withCString { rimeAPI.select_schema(sessionId, $0) }
  }

  func option(_ option: RimeOption) -> Bool {
    option.rawValue.withCString { rimeAPI.get_option(sessionId, $0) }
  }

  func setOption(_ option: RimeOption, _ value: Bool) {
    option.rawValue.withCString { rimeAPI.set_option(sessionId, $0, value) }
  }

  func setAppOption(_ key: String, _ value: Bool) {
    rimeAPI.set_option(sessionId, key, value)
  }

  func setProperty(name: String, value: String) {
    value.withCString { rimeAPI.set_property(sessionId, name, $0) }
  }

  func stateLabel(option name: String, state: Bool, abbreviated: Bool) -> String? {
    name.withCString { rimeAPI.get_state_label_abbreviated(sessionId, $0, state, abbreviated).asString }
  }

  func destroy() {
    if sessionId != 0 {
      _ = rimeAPI.destroy_session(sessionId)
      sessionId = 0
    }
  }
}

/// Production `RimeEngine`: the single owner of the global `rimeAPI` lifecycle. The
/// AppDelegate holds one and the controller obtains its Session from it (via
/// `NSApp.owlAppDelegate.engine`, the same indirection as `ensureOwltypePanel`).
final class LiveRimeEngine: RimeEngine {
  private let rimeAPI: RimeApi_stdbool

  init(rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee) {
    self.rimeAPI = rimeAPI
  }

  func setup(_ traits: inout RimeTraits) {
    rimeAPI.setup(&traits)
  }

  func initialize(_ traits: UnsafeMutablePointer<RimeTraits>?) {
    rimeAPI.initialize(traits)
  }

  func startMaintenance(fullCheck: Bool) -> Bool {
    rimeAPI.start_maintenance(fullCheck)
  }

  func joinMaintenance() {
    rimeAPI.join_maintenance_thread()
  }

  func deployConfigFile(_ fileName: String, versionKey: String) -> Bool {
    rimeAPI.deploy_config_file(fileName, versionKey)
  }

  func setNotificationHandler(_ handler: @escaping RimeNotificationHandler, context: UnsafeMutableRawPointer?) {
    rimeAPI.set_notification_handler(handler, context)
  }

  func syncUserData() -> Bool {
    rimeAPI.sync_user_data()
  }

  func cleanupAllSessions() {
    rimeAPI.cleanup_all_sessions()
  }

  func finalize() {
    rimeAPI.finalize()
  }

  func schemaList() -> [(id: String, name: String)] {
    var list = RimeSchemaList()
    guard rimeAPI.get_schema_list(&list) else { return [] }
    defer { rimeAPI.free_schema_list(&list) }

    var items: [(id: String, name: String)] = []
    let count = Int(list.size)
    if let base = list.list {
      for index in 0..<count {
        let entry = base[index]
        guard let idC = entry.schema_id else { continue }
        let id = String(cString: idC)
        let name = entry.name.map { String(cString: $0) } ?? id
        items.append((id: id, name: name))
      }
    }
    return items
  }

  func currentSchema() -> String {
    let session = rimeAPI.create_session()
    guard session != 0 else { return "" }
    defer { _ = rimeAPI.destroy_session(session) }

    let bufferSize = 256
    var buffer = [CChar](repeating: 0, count: bufferSize)
    guard rimeAPI.get_current_schema(session, &buffer, bufferSize) else { return "" }
    return String(cString: buffer)
  }

  func selectSchema(_ id: String) -> Bool {
    guard !id.isEmpty else { return false }
    let session = rimeAPI.create_session()
    guard session != 0 else { return false }
    defer { _ = rimeAPI.destroy_session(session) }
    return id.withCString { rimeAPI.select_schema(session, $0) }
  }

  func version() -> String? {
    guard let getVersion = rimeAPI.get_version else { return nil }
    guard let cString = getVersion() else { return nil }
    let version = String(cString: cString)
    return version.isEmpty ? nil : version
  }

  func createSession() -> RimeSession {
    LiveRimeSession(rimeAPI: rimeAPI, sessionId: rimeAPI.create_session())
  }

  func session(for id: RimeSessionId) -> RimeSession {
    LiveRimeSession(rimeAPI: rimeAPI, sessionId: id)
  }
}

/// The C notification-handler function-pointer type librime expects.
typealias RimeNotificationHandler =
  @convention(c) (UnsafeMutableRawPointer?, RimeSessionId, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

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

// MARK: - Candidate-store write-sink port (god-object reduction)
//
// The SAME injection range, extended to the heaviest remaining singleton coupling: the
// background/async WRITER services (`OwlSnapshotEmitter`, `OwlExternalCommitBroker`)
// all write candidates/errors into the global
// `OwlCandidateStore.shared` sink. Unlike the controller→service ports above, these are
// service→sink couplings with no delegate hop, so the injection point is the WRITER service
// instance itself (`var store = OwlCandidateStore.shared`, mirroring `var engine`).
// A narrow (ISP) port over the methods the writers actually call lets each writer's
// write-behaviour be asserted against a `Fake` with no librime and no network.
// is deliberately excluded — it is defined on the store but never called externally via
// `.shared`. `@MainActor` because the store is, and every writer touches it on the main actor.

/// The writers' outbound view of the candidate sink. Exposes ONLY the write/clear/error
/// methods the background/async services actually call — not the store's `@Published`
/// read surface — so a fake can record what a writer wrote without a store.
@MainActor
protocol CandidateStoring: AnyObject {
  func setMainCandidates(_ candidates: [EnhancedCandidate])
  func upsertSmartCandidates(_ candidates: [EnhancedCandidate], snapshotID: UInt64)
  func clearForSnapshotChange()
  func showError(_ message: String, lane: EnhancedCandidate.Lane, snapshotID: UInt64)
}

// Conformance only — the members already exist with matching signatures.
extension OwlCandidateStore: CandidateStoring {}

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
/// methods the controller pokes — not the emitter's `commitSerial` / `projectStore` / `store`
/// internals — so the snapshot path can be driven and asserted without a librime session.
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
