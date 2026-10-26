//
//  RimeSeamTests.swift
//  OwltypeTests — PR2 of the Rime Engine/Session seam (task 06-20-owl-rime-engine-session-seam)
//
//  Cashes in the testability goal PR1b created. PR1b put `protocol RimeSession` /
//  `protocol RimeEngine` (sources/RimeSeam.swift) in front of the librime C API, with
//  the value types in sources/RimeValueTypes.swift crossing the boundary and the closed
//  `RimeOption` enum (sources/RimeOption.swift) replacing string literals. This file adds
//  the test-only `FakeRimeSession` / `FakeRimeEngine` (scripted, in-memory, NO librime)
//  plus three axes of assertions:
//
//    1. `RimeOption`  — 15-case rawValue round-trip + the exact librime key strings the
//       enum replaced, locking the closed set against typos and accidental additions.
//    2. Value-type mapping — a `FakeRimeSession` scripted with a multi-candidate
//       composition / status / commit reads back EXACTLY through the protocol, proving
//       the seam carries every field the controller needs.
//    3. Recording — the fake records processed keycodes and set options, the proof a test
//       can assert what the controller drove WITHOUT a live librime session.
//
//  Scope (PRD Out-of-Scope): this stops at the Session / value-type boundary. Driving the
//  controller's `rimeUpdate` / `showPanel` end-to-end through a fake needs the as-yet
//  unbuilt IMK `client` seam (and a live app-delegate `engine`), so that is DEFERRED, not
//  faked here. The controller's option helpers (`rimeOption` / `setRimeOption`) delegate
//  1:1 to `RimeSession.option` / `.setOption`, so the contract those helpers rely on is
//  proven directly against the fake.
//
//  No network, no librime, no disk: the fake is pure in-memory scripted state.
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
///   • drives are recorded (`processedKeys` / `setOptions` / `setAppOptions` / `properties` /
///     `selectedIndices` / `pageChanges` / caret moves / `clearCompositionCount` / `destroyed`).
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

  // --- Recorded drives ----------------------------------------------------------

  private(set) var processedKeys: [(keycode: UInt32, modifiers: UInt32)] = []
  private(set) var setOptions: [(option: RimeOption, value: Bool)] = []
  private(set) var setAppOptions: [(key: String, value: Bool)] = []
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
    stateLabels: [String: String] = [:]
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

  func setAppOption(_ key: String, _ value: Bool) {
    setAppOptions.append((key, value))
  }

  func setProperty(name: String, value: String) {
    properties.append((name, value))
  }

  func stateLabel(option name: String, state: Bool, abbreviated: Bool) -> String? {
    stateLabels[name]
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

  // MARK: 2. Value-type mapping through the seam

  /// A realistic multi-candidate composition snapshot.
  private func multiCandidateComposition() -> RimeComposition {
    RimeComposition(
      preedit: "nihao",
      selStart: 0,
      selEnd: 2,
      cursorPos: 5,
      commitTextPreview: "你好",
      candidates: [
        RimeCandidate(text: "你好", comment: "nǐ hǎo"),
        RimeCandidate(text: "你号", comment: nil),
        RimeCandidate(text: "尼", comment: "ní"),
      ],
      labels: ["1", "2", "3"],
      pageNo: 0,
      pageSize: 5,
      isLastPage: false,
      highlightedIndex: 0,
      numCandidates: 3
    )
  }

  func testFakeSessionReadsBackCompositionExactly() {
    let comp = multiCandidateComposition()
    let session = FakeRimeSession(composition: comp)

    let read = session.composition()
    XCTAssertNotNil(read)
    XCTAssertEqual(read?.preedit, "nihao")
    XCTAssertEqual(read?.selStart, 0)
    XCTAssertEqual(read?.selEnd, 2)
    XCTAssertEqual(read?.cursorPos, 5)
    XCTAssertEqual(read?.commitTextPreview, "你好")
    XCTAssertEqual(read?.numCandidates, 3)
    XCTAssertEqual(read?.candidates.count, 3)
    XCTAssertEqual(read?.candidates[0].text, "你好")
    XCTAssertEqual(read?.candidates[0].comment, "nǐ hǎo")
    XCTAssertEqual(read?.candidates[1].text, "你号")
    XCTAssertNil(read?.candidates[1].comment)
    XCTAssertEqual(read?.candidates[2].comment, "ní")
    XCTAssertEqual(read?.labels, ["1", "2", "3"])
    XCTAssertEqual(read?.pageNo, 0)
    XCTAssertEqual(read?.pageSize, 5)
    XCTAssertEqual(read?.isLastPage, false)
    XCTAssertEqual(read?.highlightedIndex, 0)
  }

  func testFakeSessionReadsBackStatusExactly() {
    let status = RimeStatus(
      schemaId: "rime_ice",
      isASCIIMode: true,
      isASCIIPunct: false,
      isFullShape: true
    )
    let session = FakeRimeSession(status: status)

    let read = session.status()
    XCTAssertEqual(read?.schemaId, "rime_ice")
    XCTAssertEqual(read?.isASCIIMode, true)
    XCTAssertEqual(read?.isASCIIPunct, false)
    XCTAssertEqual(read?.isFullShape, true)
  }

  func testTakeCommitReturnsThenClears() {
    let session = FakeRimeSession(pendingCommit: "你好")
    XCTAssertEqual(session.takeCommit(), "你好")  // first drain returns
    XCTAssertNil(session.takeCommit())            // then it's gone, like free_commit
    XCTAssertEqual(session.takeCommitCount, 2)
  }

  func testTakeCommitNilWhenNoCommit() {
    let session = FakeRimeSession()
    XCTAssertNil(session.takeCommit())
  }

  func testNilCompositionAndStatusWhenUnscripted() {
    let session = FakeRimeSession()
    XCTAssertNil(session.composition())
    XCTAssertNil(session.status())
  }

  func testInputAndCaretReadBack() {
    let session = FakeRimeSession(input: "nihao", caretPos: 3)
    XCTAssertEqual(session.input(), "nihao")
    XCTAssertEqual(session.caretPos(), 3)
    session.setCaretPos(5)
    XCTAssertEqual(session.caretPos(), 5)
    XCTAssertEqual(session.caretMoves, [5])
  }

  // MARK: 3. Recording drives + per-option get/set

  func testOptionGetReturnsScriptedState() {
    let session = FakeRimeSession(optionState: [.asciiMode: true, .fullShape: false])
    XCTAssertTrue(session.option(.asciiMode))
    XCTAssertFalse(session.option(.fullShape))
    XCTAssertFalse(session.option(.vimMode))   // unset → false
  }

  func testSetOptionMutatesAndRecords() {
    let session = FakeRimeSession()
    session.setOption(.asciiMode, true)
    session.setOption(.fullShape, true)
    session.setOption(.asciiMode, false)

    // Read-back reflects the latest set, mirroring set_option/get_option.
    XCTAssertFalse(session.option(.asciiMode))
    XCTAssertTrue(session.option(.fullShape))

    // The full drive history is recorded for assertion.
    XCTAssertEqual(session.setOptions.count, 3)
    XCTAssertEqual(session.setOptions[0].option, .asciiMode)
    XCTAssertEqual(session.setOptions[0].value, true)
    XCTAssertEqual(session.setOptions[2].option, .asciiMode)
    XCTAssertEqual(session.setOptions[2].value, false)
  }

  func testProcessKeyRecordsAndReturnsScriptedResult() {
    let session = FakeRimeSession(processResult: true)
    XCTAssertTrue(session.process(keycode: 0x6e, modifiers: 0))   // 'n'
    XCTAssertTrue(session.process(keycode: 0x69, modifiers: 0))   // 'i'
    XCTAssertEqual(session.processedKeys.count, 2)
    XCTAssertEqual(session.processedKeys[0].keycode, 0x6e)
    XCTAssertEqual(session.processedKeys[1].keycode, 0x69)
  }

  func testSelectCandidateAndPagingRecorded() {
    let session = FakeRimeSession(selectCandidateResult: true, changePageResult: true)
    XCTAssertTrue(session.selectCandidate(2))
    XCTAssertTrue(session.changePage(up: false))
    XCTAssertEqual(session.selectedIndices, [2])
    XCTAssertEqual(session.pageChanges, [false])
  }

  func testSelectSchemaOnLiveSessionRecordsAndReturnsScriptedResult() {
    let session = FakeRimeSession(selectSchemaResult: true)
    XCTAssertTrue(session.selectSchema("rime_ice"))
    let denied = FakeRimeSession(selectSchemaResult: false)
    XCTAssertFalse(denied.selectSchema("wubi86_jidian"))
    XCTAssertEqual(session.selectedLiveSchemas, ["rime_ice"])
    XCTAssertEqual(denied.selectedLiveSchemas, ["wubi86_jidian"])
  }

  // MARK: 3b. Fast settings-apply live-session RELOAD sequence (task 06-22 fix, 2026-06-22)

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
    let previous = delegate.engine
    delegate.engine = FakeRimeEngine()
    defer { delegate.engine = previous; delegate.owlPanel?.hidePanel() }
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = old
    controller.schemaId = capturedSchema
    delegate.engine = engine
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

  func testAppOptionAndPropertyRecorded() {
    let session = FakeRimeSession()
    session.setAppOption("ascii_mode", true)        // open-namespace app option
    session.setProperty(name: "client_app", value: "com.apple.TextEdit")
    XCTAssertEqual(session.setAppOptions.count, 1)
    XCTAssertEqual(session.setAppOptions[0].key, "ascii_mode")
    XCTAssertEqual(session.properties[0].name, "client_app")
    XCTAssertEqual(session.properties[0].value, "com.apple.TextEdit")
  }

  func testClearCompositionAndDestroyRecorded() {
    let session = FakeRimeSession()
    session.clearComposition()
    XCTAssertEqual(session.clearCompositionCount, 1)

    XCTAssertTrue(session.isValid)
    session.destroy()
    XCTAssertTrue(session.destroyed)
    XCTAssertFalse(session.isValid)
    XCTAssertEqual(session.sessionID, 0)
  }

  func testStateLabelLookup() {
    let session = FakeRimeSession(stateLabels: ["ascii_mode": "英"])
    XCTAssertEqual(session.stateLabel(option: "ascii_mode", state: true, abbreviated: true), "英")
    XCTAssertNil(session.stateLabel(option: "full_shape", state: true, abbreviated: true))
  }

  // MARK: 3c. Settled rerank timers and stale-result ownership

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
    let previousEngine = delegate.engine
    delegate.engine = FakeRimeEngine(vendedSession: session)
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
      fixture.delegate.engine = fixture.previousEngine
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
      fixture.delegate.engine = fixture.previousEngine
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
      fixture.delegate.engine = fixture.previousEngine
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
      fixture.delegate.engine = fixture.previousEngine
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
      fixture.delegate.engine = fixture.previousEngine
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
      fixture.delegate.engine = fixture.previousEngine
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
      fixture.delegate.engine = fixture.previousEngine
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
      fixture.delegate.engine = fixture.previousEngine
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
      fixture.delegate.engine = fixture.previousEngine
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
      fixture.delegate.engine = fixture.previousEngine
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

  // MARK: 4. FakeRimeEngine — vending + lifecycle recording

  func testEngineVendsScriptedSession() {
    let scripted = FakeRimeSession(sessionID: 42)
    let engine = FakeRimeEngine(vendedSession: scripted)

    let vended = engine.createSession()
    XCTAssertTrue(vended === scripted)        // same object handed back
    XCTAssertEqual(vended.sessionID, 42)
    XCTAssertEqual(engine.createdSessionCount, 1)
  }

  func testEngineSessionForIDRecordsAndVends() {
    let scripted = FakeRimeSession(sessionID: 7)
    let engine = FakeRimeEngine(vendedSession: scripted)
    let wrapped = engine.session(for: UInt64(7))
    XCTAssertTrue(wrapped === scripted)
    XCTAssertEqual(engine.sessionForIDs, [UInt64(7)])
  }

  func testEngineLifecycleAndSchemaScripting() {
    let engine = FakeRimeEngine(
      schemaList: [(id: "rime_ice", name: "雾凇拼音"), (id: "wubi86_jidian", name: "五笔")],
      currentSchema: "rime_ice",
      version: "1.0.0"
    )
    XCTAssertTrue(engine.startMaintenance(fullCheck: true))
    XCTAssertEqual(engine.currentSchema(), "rime_ice")
    XCTAssertEqual(engine.version(), "1.0.0")

    let list = engine.schemaList()
    XCTAssertEqual(list.count, 2)
    XCTAssertEqual(list[0].id, "rime_ice")
    XCTAssertEqual(list[1].name, "五笔")

    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    XCTAssertEqual(engine.selectedSchemas, ["wubi86_jidian"])

    engine.cleanupAllSessions()
    XCTAssertTrue(engine.finalize())
    XCTAssertEqual(engine.cleanupAllSessionsCount, 1)
    XCTAssertEqual(engine.finalizeCount, 1)
  }

  // MARK: 5. Seam-injection boundary — controller helpers delegate 1:1 (deferred end-to-end)

  // NOTE (PRD Out-of-Scope): constructing a `OwlInputController` in a unit test calls
  // `IMKInputController`'s server initializer and `NSApp.owlAppDelegate.engine` inside
  // `createSession()`, and its option helpers funnel through `rimeUpdate()`/the IMK
  // `client` on success — neither is available headless. So driving the controller
  // through the fake is DEFERRED until the IMK `client` seam (a named follow-up in the
  // PRD) lands. What the controller relies on IS proven here: `rimeOption`/`setRimeOption`
  // forward verbatim to `RimeSession.option`/`.setOption`, which the tests above lock to
  // the fake's scripted get and recorded set. The seam's `var rime: RimeSession?` already
  // accepts a `FakeRimeSession` by type (it conforms to the protocol) — the gap is purely
  // the headless controller construction, not the injection point.
}
