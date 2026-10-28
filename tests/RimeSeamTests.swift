//
//  RimeSeamTests.swift
//  OwltypeTests — the input Engine/Session seam (sources/Engine/RimeSeam.swift)
//
//  `FakeRimeSession` / `FakeRimeEngine` are scripted, in-memory stand-ins for the Rust engine.
//  `RimeSession` has no default implementations and production never casts past it, so the
//  fake models every path the controller runs, and these tests drive the production controller
//  through it:
//
//    1. `RimeOption` — the closed set of option keys and their exact engine strings.
//    2. Fast settings-apply — live-session reload, schema restore and raw-input replay.
//    3. Settled rerank — timers, tickets and stale-result ownership.
//    4. Native finish and paired punctuation — composition end, application chords and the
//       host-held closing mark, which used to need the concrete Rust session.
//
//  No network, no engine, no disk.
//

import AppKit
import Foundation
import XCTest
@testable import Owltype

// MARK: - Fakes (test fixtures only — never shipped in sources/)

/// A scripted `RimeSession` with no librime. Construct it with the canned state a test
/// wants the controller to read (composition / status / commit / per-option booleans /
/// validity), then assert:
///   • reads come back exactly (`composition()` / `status()` / `takeCommit()` / `option`),
///   • drives are recorded (`processedKeys` / `setOptions` / `properties` / `selectedIndices` /
///     `pageChanges` / caret moves / `clearCompositionCount` / `nativeFinishes` /
///     `pairBalanceCount` / `destroyed`).
/// It implements every `RimeSession` requirement; the protocol has no default implementations.
final class FakeRimeSession: RimeSession {

  // --- Scripted read-back state -------------------------------------------------

  var sessionID: UInt64
  var generation: UInt64
  var isValid: Bool
  /// `process(keycode:modifiers:)` returns this (whether librime "consumed" the key).
  var processResult: Bool
  /// Drained by `takeCommit()` (returns then clears, like the live `get_commit`).
  var pendingCommit: String?
  var scriptedStatus: RimeStatus?
  var scriptedComposition: RimeComposition?
  var scriptedInput: String?
  var scriptedCaretPos: Int
  /// Per-option booleans `option(_:)` reads and `setOption(_:_:)` mutates.
  var optionState: [RimeOption: Bool]
  var selectCandidateResult: Bool
  var changePageResult: Bool
  /// Returned by `selectSchema(_:)` on this live session (the fast-apply reselect).
  var selectSchemaResult: Bool
  /// The settled rerank model load state exposed through `RimeSession`.
  var settledRerankReady: Bool
  var settledRerankLoading: Bool
  var rerankConfigurationEpoch: UInt64
  /// Returned by `stateLabel(option:state:abbreviated:)`; keyed by the option name.
  var stateLabels: [String: String]
  /// Optional transition after a forced status refresh. The debounce retry path calls
  /// `syncRerankPreferences()` when the first pause finds the model still loading.
  var syncRerankPreferencesTransition: (() -> Void)?
  /// Optional transition before a scripted synchronous settled result is returned.
  var settledRerankStartTransition: (() -> Void)?
  /// Scripted results for the next `startSettledRerank()` call.
  var settledRerankStartResult: OwlSettledRerankStartResult
  /// Scripted results consumed by successive `pollSettledRerank` calls. The last result repeats.
  var settledRerankPollResults: [OwlSettledRerankPollResult]
  /// Returned by `finishNativeComposition(onFocusLoss:)`; false models an engine that refused
  /// the action, so the controller takes the `OwlForcedFinalize` fallback.
  var finishNativeResult: Bool
  /// Committed into `pendingCommit` when a native finish succeeds, like the engine's commit.
  var finishNativeCommit: String?
  var acceptsHostSmartPunctuation: Bool
  var lastCommittedRawInput: String?
  /// The whole candidate list `peekCandidates(from:count:)` slices.
  var peekableCandidates: [RimeCandidate]
  var selectCandidateAbsoluteResult: Bool
  var removeCandidateResult: Bool

  // --- Recorded drives ----------------------------------------------------------

  private(set) var processedKeys: [(keycode: UInt32, modifiers: UInt32)] = []
  private(set) var setOptions: [(option: RimeOption, value: Bool)] = []
  private(set) var properties: [(name: String, value: String)] = []
  private(set) var selectedIndices: [Int] = []
  private(set) var pageChanges: [Bool] = []   // true == up
  private(set) var selectedLiveSchemas: [String] = []   // selectSchema(_:) on this session
  private(set) var caretMoves: [Int] = []
  private(set) var clearCompositionCount = 0
  private(set) var destroyed = false
  private(set) var takeCommitCount = 0
  private(set) var rerankPreferenceSyncCount = 0
  private(set) var settledRerankStartCount = 0
  private(set) var settledRerankPolls: [(token: UInt64, accept: Bool)] = []
  /// One entry per native finish: the `onFocusLoss` flag it was called with.
  private(set) var nativeFinishes: [Bool] = []
  private(set) var pairBalanceCount = 0
  private(set) var hostASCIIPunctuation: [String] = []
  private(set) var selectedAbsoluteIndices: [Int] = []
  private(set) var removedCandidates: [OwlCandidateToken] = []

  init(
    sessionID: UInt64 = 1,
    generation: UInt64 = 0,
    isValid: Bool = true,
    processResult: Bool = true,
    pendingCommit: String? = nil,
    status: RimeStatus? = nil,
    composition: RimeComposition? = nil,
    input: String? = nil,
    caretPos: Int = 0,
    optionState: [RimeOption: Bool] = [:],
    selectCandidateResult: Bool = false,
    changePageResult: Bool = false,
    selectSchemaResult: Bool = true,
    settledRerankReady: Bool = false,
    settledRerankLoading: Bool = false,
    rerankConfigurationEpoch: UInt64 = 0,
    stateLabels: [String: String] = [:],
    finishNativeResult: Bool = false,
    finishNativeCommit: String? = nil,
    acceptsHostSmartPunctuation: Bool = false
  ) {
    self.sessionID = sessionID
    self.generation = generation
    self.isValid = isValid
    self.processResult = processResult
    self.pendingCommit = pendingCommit
    self.scriptedStatus = status
    self.scriptedComposition = composition
    self.scriptedInput = input
    self.scriptedCaretPos = caretPos
    self.optionState = optionState
    self.selectCandidateResult = selectCandidateResult
    self.changePageResult = changePageResult
    self.selectSchemaResult = selectSchemaResult
    self.settledRerankReady = settledRerankReady
    self.settledRerankLoading = settledRerankLoading
    self.rerankConfigurationEpoch = rerankConfigurationEpoch
    self.stateLabels = stateLabels
    self.settledRerankStartResult = .noWork
    self.settledRerankPollResults = [.doneWithoutChange]
    self.finishNativeResult = finishNativeResult
    self.finishNativeCommit = finishNativeCommit
    self.acceptsHostSmartPunctuation = acceptsHostSmartPunctuation
    self.peekableCandidates = []
    self.selectCandidateAbsoluteResult = false
    self.removeCandidateResult = false
  }

  func process(keycode: UInt32, modifiers: UInt32) -> Bool {
    processedKeys.append((keycode, modifiers))
    return processResult
  }

  func takeCommit() -> String? {
    takeCommitCount += 1
    defer { pendingCommit = nil }   // drains, mirroring get_commit/free_commit
    return pendingCommit
  }

  func lastCommittedInput() -> String? { lastCommittedRawInput }

  func status() -> RimeStatus? { scriptedStatus }

  func composition() -> RimeComposition? { scriptedComposition }

  func input() -> String? { scriptedInput }

  func caretPos() -> Int { scriptedCaretPos }

  func setCaretPos(_ pos: Int) {
    caretMoves.append(pos)
    scriptedCaretPos = pos
  }

  func clearComposition() { clearCompositionCount += 1 }

  func selectCandidate(_ index: Int) -> Bool {
    selectedIndices.append(index)
    return selectCandidateResult
  }

  func selectCandidateAbsolute(_ index: Int) -> Bool {
    selectedAbsoluteIndices.append(index)
    return selectCandidateAbsoluteResult
  }

  func selectCandidate(_ token: OwlCandidateToken) -> Bool {
    if token.sessionID != 0 && token.sessionID != sessionID {
      return false
    }
    if token.isAbsolute {
      return selectCandidateAbsolute(token.candidateID)
    }
    return selectCandidate(token.candidateID)
  }

  func removeCandidate(_ token: OwlCandidateToken) -> Bool {
    removedCandidates.append(token)
    return removeCandidateResult
  }

  func peekCandidates(from index: Int, count: Int) -> [RimeCandidate] {
    guard index >= 0, index < peekableCandidates.count, count > 0 else { return [] }
    return Array(peekableCandidates[index..<min(index + count, peekableCandidates.count)])
  }

  func changePage(up: Bool) -> Bool {
    pageChanges.append(up)
    return changePageResult
  }

  func selectSchema(_ id: String) -> Bool {
    selectedLiveSchemas.append(id)
    return selectSchemaResult
  }

  func syncRerankPreferences() {
    rerankPreferenceSyncCount += 1
    syncRerankPreferencesTransition?()
  }

  func startSettledRerank() -> OwlSettledRerankStartResult {
    settledRerankStartCount += 1
    settledRerankStartTransition?()
    return settledRerankStartResult
  }

  func pollSettledRerank(token: UInt64, accept: Bool) -> OwlSettledRerankPollResult {
    settledRerankPolls.append((token, accept))
    guard !settledRerankPollResults.isEmpty else { return .doneWithoutChange }
    return settledRerankPollResults.removeFirst()
  }

  func option(_ option: RimeOption) -> Bool { optionState[option] ?? false }

  func setOption(_ option: RimeOption, _ value: Bool) {
    setOptions.append((option, value))
    optionState[option] = value
  }

  func setProperty(name: String, value: String) {
    properties.append((name, value))
  }

  func stateLabel(option name: String, state: Bool, abbreviated: Bool) -> String? {
    stateLabels[name]
  }

  func finishNativeComposition(onFocusLoss: Bool) -> Bool {
    nativeFinishes.append(onFocusLoss)
    guard finishNativeResult else { return false }
    pendingCommit = finishNativeCommit
    scriptedInput = ""
    scriptedComposition = nil
    return true
  }

  func balanceHostPairedPunctuation() { pairBalanceCount += 1 }

  func processHostASCIIPunctuation(_ character: String) -> Bool {
    hostASCIIPunctuation.append(character)
    return processResult
  }

  func destroy() {
    destroyed = true
    isValid = false
    sessionID = 0
  }
}

/// A scripted `RimeEngine` with no librime. `createSession()` / `session(for:)` vend a
/// `FakeRimeSession` (the configured `vendedSession`, or a default valid one), and the
/// global-lifecycle calls are no-ops that record they happened.
final class FakeRimeEngine: RimeEngine {

  /// The session handed back by `createSession()` and `session(for:)`. Default: a fresh
  /// valid fake, so a test can `engine.createSession()` and immediately script it.
  var vendedSession: FakeRimeSession
  var scriptedSchemaList: [(id: String, name: String)]
  var scriptedCurrentSchema: String
  var scriptedVersion: String?
  var startMaintenanceResult: Bool
  var deployConfigFileResult: Bool
  var finalizeResult: Bool
  var selectSchemaResult: Bool

  private(set) var setupCount = 0
  private(set) var finalizeCount = 0
  private(set) var cleanupAllSessionsCount = 0
  private(set) var joinMaintenanceCount = 0
  /// Ordered trace of lifecycle calls, so a test can assert `join` happens AFTER
  /// `start_maintenance` and BEFORE a reselect on the fast fuzzy-apply path.
  private(set) var lifecycleTrace: [String] = []
  /// Every `deploy_config_file` file name, in call order — so a test can assert WHICH configs
  /// a deploy path recompiles (owltype.yaml's absence from fast-apply/startRime was the #121 gap).
  private(set) var deployedConfigFiles: [String] = []
  private(set) var createdSessionCount = 0
  private(set) var selectedSchemas: [String] = []
  private(set) var sessionForIDs: [UInt64] = []
  private(set) var notificationHandlerSet = false

  init(
    vendedSession: FakeRimeSession = FakeRimeSession(),
    schemaList: [(id: String, name: String)] = [],
    currentSchema: String = "",
    version: String? = nil,
    startMaintenanceResult: Bool = true,
    deployConfigFileResult: Bool = true,
    finalizeResult: Bool = true,
    selectSchemaResult: Bool = true
  ) {
    self.vendedSession = vendedSession
    self.scriptedSchemaList = schemaList
    self.scriptedCurrentSchema = currentSchema
    self.scriptedVersion = version
    self.startMaintenanceResult = startMaintenanceResult
    self.deployConfigFileResult = deployConfigFileResult
    self.finalizeResult = finalizeResult
    self.selectSchemaResult = selectSchemaResult
  }

  func setup(_ traits: OwlEngineTraits) { setupCount += 1 }
  func startMaintenance(fullCheck: Bool) -> Bool {
    lifecycleTrace.append("startMaintenance")
    return startMaintenanceResult
  }
  func joinMaintenance() {
    joinMaintenanceCount += 1
    lifecycleTrace.append("joinMaintenance")
  }
  func deployConfigFile(_ fileName: String, versionKey: String) -> Bool {
    deployedConfigFiles.append(fileName)
    return deployConfigFileResult
  }
  func setNotificationHandler(_ handler: @escaping RimeNotificationHandler) {
    notificationHandlerSet = true
  }
  func cleanupAllSessions() { cleanupAllSessionsCount += 1 }
  func finalize() -> Bool {
    finalizeCount += 1
    lifecycleTrace.append("finalize")
    return finalizeResult
  }
  func schemaList() -> [(id: String, name: String)] { scriptedSchemaList }
  func currentSchema() -> String { scriptedCurrentSchema }
  func selectSchema(_ id: String) -> Bool {
    selectedSchemas.append(id)
    return selectSchemaResult
  }
  func version() -> String? { scriptedVersion }

  func createSession() -> RimeSession {
    createdSessionCount += 1
    return vendedSession
  }

  func session(for id: UInt64) -> RimeSession {
    sessionForIDs.append(id)
    return vendedSession
  }
}

// MARK: - Tests

final class RimeSeamTests: XCTestCase {

  // MARK: 1. RimeOption — closed-set contract

  /// The librime option keys the enum replaced. If the enum ever drops/renames a case or
  /// a rawValue drifts, this dictionary makes the test fail at the exact key.
  private static let expectedRawValues: [RimeOption: String] = [
    .asciiMode: "ascii_mode",
    .asciiPunct: "ascii_punct",
    .fullShape: "full_shape",
    .traditional: "traditional",
    .traditionalization: "traditionalization",
    .zhTrad: "zh_trad",
    .simplification: "simplification",
    .transcription: "transcription",
    .vimMode: "vim_mode",
    .linear: "_linear",
    .vertical: "_vertical",
    .chordTyping: "_chord_typing",
    .noInline: "no_inline",
    .inline: "inline",
    .softCursor: "soft_cursor",
    .emojiSuggestion: "emoji",
  ]

  func testRimeOptionHasExactly16Cases() {
    XCTAssertEqual(RimeOption.allCases.count, 16)
    // The expectation map must cover every case (no case left untested).
    XCTAssertEqual(Set(RimeOption.allCases), Set(Self.expectedRawValues.keys))
  }

  func testRimeOptionRawValuesMatchLibrimeKeys() {
    for option in RimeOption.allCases {
      XCTAssertEqual(
        option.rawValue,
        Self.expectedRawValues[option],
        "RimeOption.\(option) must map to its original librime key"
      )
    }
  }

  func testRimeOptionRawValueRoundTrips() {
    for option in RimeOption.allCases {
      XCTAssertEqual(RimeOption(rawValue: option.rawValue), option,
                     "RimeOption(rawValue:) must round-trip \(option.rawValue)")
    }
  }

  func testRimeOptionRawValuesAreUnique() {
    let raws = RimeOption.allCases.map(\.rawValue)
    XCTAssertEqual(Set(raws).count, raws.count, "Two RimeOption cases share a librime key")
  }

  func testFrontEndOptionsAreUnderscorePrefixed() {
    // Client-set presentation options keep Rime's `_` convention.
    for option in [RimeOption.linear, .vertical, .chordTyping] {
      XCTAssertTrue(option.rawValue.hasPrefix("_"), "\(option) should be `_`-prefixed")
    }
  }

  // MARK: 2. Fast settings-apply live-session RELOAD sequence (task 06-22 fix, 2026-06-22)

  /// The harness supplies engine state; all lifecycle and replay logic is production code.
  @MainActor
  @discardableResult
  private func driveReload(
    old: FakeRimeSession,
    engine: FakeRimeEngine,
    capturedSchema: String,
    replayComposition: Bool
  ) throws -> FakeRimeSession {
    let delegate = NSApp.owlAppDelegate
    let previous = delegate.runtime.engine
    delegate.runtime.engine = FakeRimeEngine()
    defer { delegate.runtime.engine = previous; delegate.owlPanel?.hidePanel() }
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = old
    controller.schemaId = capturedSchema
    delegate.runtime.engine = engine
    controller.reapplyConfigToLiveSession(replayComposition: replayComposition)
    // Detach the fake so controller teardown cannot change the observed result.
    let result = controller.rime as? FakeRimeSession ?? old
    controller.rime = nil
    return result
  }

  @MainActor
  func testFastApplyReloadsActiveSessionRestoresSchemaAndReplays() throws {
    let old = FakeRimeSession(sessionID: 1, input: "qiu")
    let fresh = FakeRimeSession(sessionID: 2)         // a DIFFERENT session id — proves it's recreated
    let engine = FakeRimeEngine(vendedSession: fresh)

    let result = try driveReload(old: old, engine: engine, capturedSchema: "wubi86_jidian", replayComposition: true)

    // 1. the OLD session was DESTROYED (the whole point — same-id reselect didn't reload).
    XCTAssertTrue(old.destroyed)
    // 2. a FRESH session was created from the engine (reads the new build/ = new page_size).
    XCTAssertEqual(engine.createdSessionCount, 1)
    XCTAssertTrue(result === fresh)
    XCTAssertEqual(result.sessionID, 2)
    // 3. the captured schema was RESTORED on the fresh session (don't kick 五笔 → 拼音).
    XCTAssertEqual(fresh.selectedLiveSchemas.last, "wubi86_jidian")
    // 4. the in-flight rawInput was replayed on the FRESH session so the panel re-renders.
    XCTAssertEqual(fresh.processedKeys.map(\.keycode), Array("qiu".unicodeScalars.map(\.value)))
    XCTAssertTrue(fresh.processedKeys.allSatisfy { $0.modifiers == 0 })
    // …and NOT on the old, destroyed session.
    XCTAssertTrue(old.processedKeys.isEmpty)
  }

  @MainActor
  func testFastApplyDestroysBackgroundSessionWithoutRecreating() throws {
    // A non-active (background) controller: DESTROY ONLY. We must NOT eagerly recreate — the
    // backgrounded controller's `client` is nil (deactivateServer cleared it), so recreating
    // here would derive `UnknownApp<n>` and drop the app's per-app options. Its `handle()` hot
    // path lazily recreates with a live client (reading the new build/) on the next keystroke.
    let old = FakeRimeSession(sessionID: 10, input: "shouldNotReplay")
    let fresh = FakeRimeSession(sessionID: 11)
    let engine = FakeRimeEngine(vendedSession: fresh)

    let result = try driveReload(old: old, engine: engine, capturedSchema: "rime_ice", replayComposition: false)

    XCTAssertTrue(old.destroyed)
    XCTAssertEqual(engine.createdSessionCount, 0)               // NO eager recreate
    XCTAssertTrue(result === old)                               // returns the destroyed old session
    XCTAssertTrue(fresh.selectedLiveSchemas.isEmpty)            // fresh session never touched
    XCTAssertTrue(fresh.processedKeys.isEmpty)                  // nothing replayed
  }

  @MainActor
  func testFastApplyReloadWithEmptySchemaLeavesFreshSessionDefault() throws {
    // Empty captured schema (no schema yet) → leave the fresh session on its default; the
    // PRD says this is fine (no reselect, no replay needed).
    let old = FakeRimeSession(sessionID: 20, input: "")
    let fresh = FakeRimeSession(sessionID: 21)
    let engine = FakeRimeEngine(vendedSession: fresh)

    try driveReload(old: old, engine: engine, capturedSchema: "", replayComposition: true)

    XCTAssertTrue(old.destroyed)
    XCTAssertEqual(engine.createdSessionCount, 1)
    XCTAssertEqual(fresh.selectedLiveSchemas, [OwlKeyboardPreferences.preferredSchemaID])
    XCTAssertTrue(fresh.processedKeys.isEmpty)                  // nothing to replay
  }

  @MainActor
  func testReplayRawInputSkipsNonASCIIAndPreservesOrder() throws {
    // Owltype raw input codes are ASCII; a stray non-ASCII scalar must be skipped, not crash.
    let old = FakeRimeSession(sessionID: 30, input: "ow鹰ltype")
    let fresh = FakeRimeSession(sessionID: 31)
    let engine = FakeRimeEngine(vendedSession: fresh)

    try driveReload(old: old, engine: engine, capturedSchema: "rime_ice", replayComposition: true)

    // Only the ASCII bytes o w l t y p e are re-fed on the fresh session; the CJK 鹰 is skipped.
    XCTAssertEqual(fresh.processedKeys.map(\.keycode), Array("owltype".unicodeScalars.map(\.value)))
  }

  // MARK: 3. Settled rerank timers and stale-result ownership

  @MainActor
  private func makeSettledRerankController(
    session: FakeRimeSession
  ) throws -> (
    controller: OwlInputController,
    delegate: OwlApplicationDelegate,
    previousEngine: RimeEngine
  ) {
    OwlExperimentalPreferences.resetForTesting()
    OwlExperimentalPreferences.settledRerankEnabled = true
    let delegate = NSApp.owlAppDelegate
    let previousEngine = delegate.runtime.engine
    delegate.runtime.engine = FakeRimeEngine(vendedSession: session)
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    return (controller, delegate, previousEngine)
  }

  @MainActor
  @discardableResult
  private func waitForMainRunLoop(
    timeout: TimeInterval = 0.8,
    until condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if condition() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } while Date() < deadline
    return condition()
  }

  @MainActor
  private func spinMainRunLoop(_ interval: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(interval))
  }

  @MainActor
  func testSettledActionInvalidationRejectsAResultEvenWithoutEngineMutation() throws {
    let session = FakeRimeSession(sessionID: 71, generation: 9, input: "ni", settledRerankReady: true)
    session.settledRerankStartResult = OwlSettledRerankStartResult(
      token: 104, current: false, moved: false, error: nil
    )
    session.settledRerankPollResults = [
      OwlSettledRerankPollResult(pending: false, current: true, moved: true, error: nil)
    ]
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }
    controller.armSettledRerankAfterInput()
    // Fire the actual timer only after the pause is due; no wall-clock sleep races the worker.
    controller.settledRerankLastInputAt = 0
    try XCTUnwrap(controller.settledRerankDebounceTimer).fire()
    XCTAssertEqual(session.settledRerankStartCount, 1)
    let updatesBefore = session.takeCommitCount
    // A boundary-page action can be unconsumed and leave generation/raw input unchanged.
    // It nevertheless ends the pause during which this worker was started.
    session.changePageResult = false
    XCTAssertFalse(controller.page(up: true))
    try XCTUnwrap(controller.settledRerankPollTimer).fire()
    XCTAssertEqual(session.settledRerankPolls.map(\.accept), [false])
    XCTAssertEqual(session.takeCommitCount, updatesBefore)
    XCTAssertNil(controller.settledRerankJob)
  }

  @MainActor
  func testSettledPauseUsesLastInputAndDrainsOldScoringBeforeRestarting() throws {
    let session = FakeRimeSession(sessionID: 72, generation: 10, input: "ni", settledRerankReady: true)
    session.settledRerankStartResult = OwlSettledRerankStartResult(
      token: 105, current: false, moved: false, error: nil
    )
    session.settledRerankPollResults = [
      OwlSettledRerankPollResult(pending: false, current: false, moved: false, error: nil)
    ]
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }
    var now: UInt64 = 1_000_000_000
    controller.settledRerankNow = { now }
    controller.armSettledRerankAfterInput()
    now += 149_999_999
    try XCTUnwrap(controller.settledRerankDebounceTimer).fire()
    XCTAssertEqual(session.settledRerankStartCount, 0, "149.999999 ms is still typing")
    controller.invalidateSettledRerankForAction()
    session.scriptedInput = "nia"
    session.generation += 1
    controller.armSettledRerankAfterInput()
    now += 149_999_999
    try XCTUnwrap(controller.settledRerankDebounceTimer).fire()
    XCTAssertEqual(session.settledRerankStartCount, 0, "new input resets the entire pause")
    now += 1
    try XCTUnwrap(controller.settledRerankDebounceTimer).fire()
    XCTAssertEqual(session.settledRerankStartCount, 1)

    // A second composition reaches its pause while the first score still owns the model.
    controller.invalidateSettledRerankForAction()
    session.scriptedInput = "ni"
    session.generation += 1
    controller.armSettledRerankAfterInput()
    now += 150_000_000
    try XCTUnwrap(controller.settledRerankDebounceTimer).fire()
    XCTAssertEqual(session.settledRerankStartCount, 1, "only one score owns the model")
    try XCTUnwrap(controller.settledRerankPollTimer).fire()
    XCTAssertEqual(session.settledRerankPolls.map(\.accept), [false])
    XCTAssertEqual(session.settledRerankStartCount, 2, "draining returns the model to the due composition")
  }

  @MainActor
  func testFocusLossRejectsSettledResultWithoutRelyingOnEngineClear() throws {
    let session = FakeRimeSession(sessionID: 73, generation: 11, input: "ni", settledRerankReady: true)
    session.settledRerankStartResult = OwlSettledRerankStartResult(
      token: 106, current: false, moved: false, error: nil
    )
    session.settledRerankPollResults = [
      OwlSettledRerankPollResult(pending: false, current: true, moved: true, error: nil)
    ]
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }
    var now: UInt64 = 1_000_000_000
    controller.settledRerankNow = { now }
    controller.armSettledRerankAfterInput()
    now += 150_000_000
    try XCTUnwrap(controller.settledRerankDebounceTimer).fire()
    controller.deactivateServer(nil)
    let updatesAfterBlur = session.takeCommitCount
    // The fake deliberately keeps generation/input on clear: focus owns invalidation itself.
    try XCTUnwrap(controller.settledRerankPollTimer).fire()
    XCTAssertEqual(session.settledRerankPolls.map(\.accept), [false])
    XCTAssertEqual(session.takeCommitCount, updatesAfterBlur)
    XCTAssertNil(controller.settledRerankJob)
    XCTAssertNil(controller.settledRerankDebounceTimer)
  }

  @MainActor
  func testSettledRerankRetriesWhileModelIsStillLoading() throws {
    let session = FakeRimeSession(input: "ni", settledRerankLoading: true)
    session.syncRerankPreferencesTransition = {
      guard session.rerankPreferenceSyncCount >= 2 else { return }
      session.settledRerankLoading = false
      session.settledRerankReady = true
    }
    session.settledRerankStartResult = OwlSettledRerankStartResult(
      token: 99,
      current: false,
      moved: false,
      error: nil
    )
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }

    controller.armSettledRerankAfterInput()
    XCTAssertTrue(waitForMainRunLoop {
      session.settledRerankStartCount == 1
    }, "a model still loading after the first pause must be polled again")
    XCTAssertGreaterThanOrEqual(session.rerankPreferenceSyncCount, 2)
  }

  @MainActor
  func testSynchronousMovedSettledResultRefreshesAfterGenerationAdvance() throws {
    let session = FakeRimeSession(
      sessionID: 52,
      generation: 17,
      input: "ni",
      settledRerankReady: true
    )
    session.settledRerankStartResult = OwlSettledRerankStartResult(
      token: nil,
      current: true,
      moved: true,
      error: nil
    )
    session.settledRerankStartTransition = {
      session.generation += 1
    }
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }

    let updatesBefore = session.takeCommitCount
    controller.armSettledRerankAfterInput()
    XCTAssertTrue(waitForMainRunLoop { session.settledRerankStartCount == 1 })
    XCTAssertEqual(
      session.takeCommitCount,
      updatesBefore + 1,
      "an accepted synchronous move must refresh after its snapshot advances generation"
    )
    XCTAssertNil(controller.settledRerankJob)
    XCTAssertTrue(session.settledRerankPolls.isEmpty)
  }

  @MainActor
  func testNewInputCancelsThePreviousSettledRerankPause() throws {
    let session = FakeRimeSession(input: "ni", settledRerankReady: true)
    session.settledRerankStartResult = OwlSettledRerankStartResult(
      token: 7,
      current: false,
      moved: false,
      error: nil
    )
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.invalidateSettledRerankForAction()
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }

    controller.armSettledRerankAfterInput()
    spinMainRunLoop(0.05)
    let event = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "a",
      charactersIgnoringModifiers: "a",
      isARepeat: false,
      keyCode: 0
    ))
    XCTAssertTrue(controller.handle(event, client: nil))
    // The first pause was due at 150 ms; the replacement is due at about 200 ms.
    spinMainRunLoop(0.12)
    XCTAssertEqual(session.settledRerankStartCount, 0)
  }

  @MainActor
  func testStaleSettledResultIsDrainedWithoutRefreshingThePanel() throws {
    let session = FakeRimeSession(
      sessionID: 41,
      generation: 8,
      input: "ni",
      settledRerankReady: true
    )
    session.settledRerankStartResult = OwlSettledRerankStartResult(
      token: 101,
      current: false,
      moved: false,
      error: nil
    )
    session.settledRerankPollResults = [
      OwlSettledRerankPollResult(pending: true, current: false, moved: false, error: nil),
      OwlSettledRerankPollResult(pending: false, current: false, moved: true, error: nil),
    ]
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }

    let updatesBefore = session.takeCommitCount
    controller.armSettledRerankAfterInput()
    XCTAssertTrue(waitForMainRunLoop { session.settledRerankStartCount == 1 })
    session.scriptedInput = "nia"
    session.generation += 1
    XCTAssertTrue(waitForMainRunLoop {
      controller.settledRerankJob == nil
        && session.settledRerankPolls.contains { !$0.accept }
    })
    XCTAssertNil(controller.settledRerankJob)
    XCTAssertEqual(session.takeCommitCount, updatesBefore, "stale results must not refresh the panel")
  }

  @MainActor
  func testSymbolMenuGenerationDrainsRunningSettledResultWithoutRefreshingThePanel() throws {
    let session = FakeRimeSession(
      sessionID: 45,
      generation: 0x1234,
      input: "ni",
      settledRerankReady: true
    )
    session.settledRerankStartResult = OwlSettledRerankStartResult(
      token: 103,
      current: false,
      moved: false,
      error: nil
    )
    session.settledRerankPollResults = [
      OwlSettledRerankPollResult(pending: true, current: false, moved: false, error: nil),
      OwlSettledRerankPollResult(pending: false, current: true, moved: true, error: nil),
    ]
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }

    let updatesBefore = session.takeCommitCount
    controller.armSettledRerankAfterInput()
    XCTAssertTrue(waitForMainRunLoop { session.settledRerankStartCount == 1 })

    // A punctuation menu is a different presentation namespace, so a running runtime result
    // must be drained even if its stale response claims it is current and moved.
    session.scriptedInput = "<"
    session.generation = (UInt64(1) << 63) | 0x51
    XCTAssertTrue(waitForMainRunLoop {
      controller.settledRerankJob == nil
        && session.settledRerankPolls.contains { !$0.accept }
    })
    XCTAssertEqual(session.takeCommitCount, updatesBefore)
  }

  @MainActor
  func testCurrentMovedSettledResultRefreshesOnlyOnce() throws {
    let session = FakeRimeSession(sessionID: 51, input: "ni", settledRerankReady: true)
    session.settledRerankStartResult = OwlSettledRerankStartResult(
      token: 102,
      current: false,
      moved: false,
      error: nil
    )
    session.settledRerankPollResults = [
      OwlSettledRerankPollResult(pending: true, current: false, moved: false, error: nil),
      OwlSettledRerankPollResult(pending: false, current: true, moved: true, error: nil),
    ]
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }

    controller.armSettledRerankAfterInput()
    XCTAssertTrue(waitForMainRunLoop { session.settledRerankStartCount == 1 })
    let updatesBefore = session.takeCommitCount
    XCTAssertTrue(waitForMainRunLoop {
      session.settledRerankPolls.count >= 2 && controller.settledRerankJob == nil
    })
    XCTAssertEqual(session.takeCommitCount, updatesBefore + 1)
    XCTAssertEqual(session.settledRerankPolls.map(\.accept), [true, true])
    spinMainRunLoop(0.08)
    XCTAssertEqual(session.takeCommitCount, updatesBefore + 1, "one result must cause one refresh")
    XCTAssertEqual(session.settledRerankPolls.count, 2)
  }

  @MainActor
  func testSettledRerankDebounceIsClearedBySessionLifecycle() throws {
    let session = FakeRimeSession(sessionID: 61, input: "ni", settledRerankReady: true)
    let fixture = try makeSettledRerankController(session: session)
    let controller = fixture.controller
    defer {
      controller.destroySession()
      fixture.delegate.runtime.engine = fixture.previousEngine
      OwlExperimentalPreferences.resetForTesting()
      fixture.delegate.owlPanel?.hidePanel()
    }

    controller.armSettledRerankAfterInput()
    XCTAssertNotNil(controller.settledRerankDebounceTimer)
    controller.resetSettledRerankRuntime()
    XCTAssertNil(controller.settledRerankDebounceTimer)

    controller.armSettledRerankAfterInput()
    controller.createSession()
    XCTAssertNil(controller.settledRerankDebounceTimer)

    controller.armSettledRerankAfterInput()
    controller.destroySession()
    XCTAssertNil(controller.settledRerankDebounceTimer)

    session.isValid = true
    session.sessionID = 62
    controller.createSession()
    controller.armSettledRerankAfterInput()
    XCTAssertNotNil(controller.settledRerankDebounceTimer)
    controller.deactivateServer(nil)
    XCTAssertNil(controller.settledRerankDebounceTimer)
  }

  // MARK: 4. Native finish and paired punctuation, driven through the fake

  @MainActor
  private func makeNativeController(
    session: FakeRimeSession
  ) throws -> (controller: OwlInputController, client: HabitsTextClient, restore: () -> Void) {
    let delegate = NSApp.owlAppDelegate
    let previousEngine = delegate.runtime.engine
    delegate.runtime.engine = FakeRimeEngine(vendedSession: session)
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.rime = session
    let client = HabitsTextClient()
    client.appID = "com.apple.TextEdit"
    controller.client = client
    let pairKey = "OwlKeyboardAutoPairBrackets"
    let savedPair = OwlDefaults.standard.object(forKey: pairKey)
    OwlKeyboardPreferences.autoPairBrackets = true
    return (controller, client, {
      controller.rime = nil
      delegate.runtime.engine = previousEngine
      delegate.owlPanel?.hidePanel()
      if let savedPair { OwlDefaults.standard.set(savedPair, forKey: pairKey) } else {
        OwlDefaults.standard.removeObject(forKey: pairKey)
      }
    })
  }

  private func composing(_ input: String, candidates: [String], highlighted: Int) -> RimeComposition {
    RimeComposition(
      preedit: input, selStart: 0, selEnd: input.utf8.count, cursorPos: input.utf8.count,
      commitTextPreview: candidates[highlighted],
      candidates: candidates.map { RimeCandidate(text: $0, comment: nil) },
      labels: candidates.indices.map { String($0 + 1) }, pageNo: 0, pageSize: 5,
      isLastPage: true, highlightedIndex: highlighted, numCandidates: candidates.count
    )
  }

  private func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
      isARepeat: false, keyCode: code))
  }

  /// LESSONS.md "Host composition end must execute the engine selection": the host inserts
  /// what the engine committed, and never clears the engine instead of finishing it.
  @MainActor
  func testHostCompositionEndCommitsThroughNativeFinish() throws {
    let session = FakeRimeSession(
      composition: composing("gggg", candidates: ["王", "五一"], highlighted: 1), input: "gggg",
      finishNativeResult: true, finishNativeCommit: "五一")
    let fixture = try makeNativeController(session: session)
    defer { fixture.restore() }

    fixture.controller.commitComposition(fixture.client)

    XCTAssertEqual(session.nativeFinishes, [true], "composition end is a focus-loss finish")
    XCTAssertEqual(fixture.client.text.string, "五一")
    XCTAssertEqual(session.clearCompositionCount, 0, "the engine selects; the host never cancels it")
  }

  @MainActor
  func testRefusedNativeFinishFallsBackToTheConvertedPreview() throws {
    let session = FakeRimeSession(
      composition: composing("gggg", candidates: ["王", "五一"], highlighted: 0), input: "gggg",
      finishNativeResult: false)
    let fixture = try makeNativeController(session: session)
    defer { fixture.restore() }

    fixture.controller.commitComposition(fixture.client)

    XCTAssertEqual(session.nativeFinishes, [true])
    XCTAssertEqual(fixture.client.text.string, "王")
    XCTAssertEqual(session.clearCompositionCount, 1)
  }

  @MainActor
  func testApplicationChordFinishesNativelyBeforePassthrough() throws {
    let session = FakeRimeSession(
      composition: composing("ni", candidates: ["你"], highlighted: 0), input: "ni",
      finishNativeResult: true, finishNativeCommit: "你")
    let fixture = try makeNativeController(session: session)
    defer { fixture.restore() }

    XCTAssertFalse(fixture.controller.handle(try key("c", code: 8, flags: .command), client: fixture.client))

    XCTAssertEqual(session.nativeFinishes, [false], "a chord is an ordinary finish, not focus loss")
    XCTAssertEqual(fixture.client.text.string, "你", "the application receives its chord after the commit")
  }

  @MainActor
  func testPairedPunctuationHoldsTheClosingUntilCompositionEnds() throws {
    let session = FakeRimeSession(pendingCommit: "（", acceptsHostSmartPunctuation: true)
    let fixture = try makeNativeController(session: session)
    defer { fixture.restore() }

    XCTAssertTrue(fixture.controller.handle(try key("(", code: 25, flags: .shift), client: fixture.client))

    XCTAssertEqual(fixture.client.text.string, "（")
    XCTAssertEqual(fixture.controller.pendingPairedClosing, "）")
    XCTAssertEqual(session.pairBalanceCount, 0, "only 《 and 〈 change the engine's nesting state")
    fixture.controller.commitComposition(fixture.client)
    XCTAssertEqual(fixture.client.text.string, "（）")
    XCTAssertNil(fixture.controller.pendingPairedClosing)
  }

  @MainActor
  func testOpeningBookTitleMarkBalancesTheEnginePair() throws {
    let session = FakeRimeSession(pendingCommit: "《", acceptsHostSmartPunctuation: true)
    let fixture = try makeNativeController(session: session)
    defer { fixture.restore() }

    XCTAssertTrue(fixture.controller.handle(try key("<", code: 43, flags: .shift), client: fixture.client))

    XCTAssertEqual(fixture.client.text.string, "《")
    XCTAssertEqual(fixture.controller.pendingPairedClosing, "》")
    XCTAssertEqual(session.pairBalanceCount, 1)
  }

  @MainActor
  func testEngineLocalModeKeepsTheHostOutOfPairing() throws {
    let session = FakeRimeSession(pendingCommit: "（", acceptsHostSmartPunctuation: false)
    let fixture = try makeNativeController(session: session)
    defer { fixture.restore() }

    XCTAssertTrue(fixture.controller.handle(try key("(", code: 25, flags: .shift), client: fixture.client))

    XCTAssertEqual(fixture.client.text.string, "（")
    XCTAssertNil(fixture.controller.pendingPairedClosing)
  }

  @MainActor
  func testSwitchingClientsFinishesTheCompositionBeforeClosingThePair() throws {
    let session = FakeRimeSession(pendingCommit: "（", acceptsHostSmartPunctuation: true)
    let fixture = try makeNativeController(session: session)
    defer { fixture.restore() }
    XCTAssertTrue(fixture.controller.handle(try key("(", code: 25, flags: .shift), client: fixture.client))
    session.finishNativeResult = true
    session.finishNativeCommit = "你"

    fixture.controller.finishPairBeforeChangingClient(to: HabitsTextClient())

    XCTAssertEqual(session.nativeFinishes, [false])
    XCTAssertEqual(fixture.client.text.string, "（你）", "the old client gets the commit, then its closing")
    XCTAssertNil(fixture.controller.pendingPairedClosing)
  }
}
