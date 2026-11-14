//
//  EngineRuntimeTests.swift
//  OwltypeTests
//
//  Drives the engine runtime's start, redeploy, recovery, reset and config-cache sequences
//  through `FakeInputEngine`, with a temporary user directory and shared-support directory.
//

import AppKit
import XCTest
@testable import Owltype

final class EngineRuntimeTests: XCTestCase {
  private var userDirectory: URL!
  private var sharedSupport: URL!

  override func setUpWithError() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-engine-runtime-\(UUID().uuidString)", isDirectory: true)
    userDirectory = base.appendingPathComponent("user", isDirectory: true)
    sharedSupport = base.appendingPathComponent("shared", isDirectory: true)
    try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sharedSupport, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: userDirectory.deletingLastPathComponent())
  }

  // MARK: - Start and redeploy

  func testRedeployStopsThenStartsMaintenanceThenDeploysFrontendConfig() throws {
    let engine = FakeInputEngine()
    try writeBaseConfig(layout: "linear")

    XCTAssertTrue(makeRuntime(engine).redeploy())

    XCTAssertEqual(engine.lifecycleTrace, ["finalize", "startMaintenance"])
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)
  }

  /// A live session makes finalize refuse. The engine must stay up, untouched.
  func testRedeployBlockedByLiveSessionLeavesEngineRunning() {
    let engine = FakeInputEngine(finalizeResult: false)

    XCTAssertFalse(makeRuntime(engine).redeploy())

    XCTAssertEqual(engine.lifecycleTrace, ["finalize"])
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)
  }

  // MARK: - Running work with the engine stopped

  func testWhileStoppedRunsBodyBetweenStopAndRestart() throws {
    let engine = FakeInputEngine()
    try writeBaseConfig(layout: "linear")
    let runtime = makeRuntime(engine)

    let run = runtime.whileStopped { engine.lifecycleTrace }

    guard case .finished(.success(let traceDuringBody), let restarted) = run else {
      return XCTFail("expected the body to run, got \(run)")
    }
    XCTAssertEqual(traceDuringBody, ["finalize"], "the body runs only after the engine stopped")
    XCTAssertTrue(restarted)
    XCTAssertEqual(engine.lifecycleTrace, ["finalize", "startMaintenance"])
    XCTAssertNotNil(runtime.config, "the config cache is reloaded after the restart")
  }

  /// A failing body must still bring the engine back: a finalized engine means no typing.
  func testWhileStoppedRestartsEvenWhenBodyThrows() {
    struct Failure: Error {}
    let engine = FakeInputEngine()

    let run = makeRuntime(engine).whileStopped { throw Failure() }

    guard case .finished(.failure(let error), let restarted) = run else {
      return XCTFail("expected a failed body, got \(run)")
    }
    XCTAssertTrue(error is Failure)
    XCTAssertTrue(restarted)
    XCTAssertEqual(engine.lifecycleTrace, ["finalize", "startMaintenance"])
  }

  func testWhileStoppedBlockedNeverRunsBody() {
    let engine = FakeInputEngine(finalizeResult: false)

    let run = makeRuntime(engine).whileStopped { XCTFail("the body must not run while a session is live") }

    guard case .blocked = run else { return XCTFail("expected blocked, got \(run)") }
    XCTAssertEqual(engine.lifecycleTrace, ["finalize"])
  }

  // MARK: - Reset

  func testResetUserDictBlockedLeavesUserDataUntouched() throws {
    let engine = FakeInputEngine(finalizeResult: false)
    let journal = try writeRustJournal()

    let message = makeRuntime(engine).resetUserDict(timestamp: "20261028-000000")

    XCTAssertTrue(message.hasPrefix("重置失败"), message)
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    XCTAssertEqual(engine.lifecycleTrace, ["finalize"])
  }

  func testResetUserDictRemovesDataWhileStoppedThenRestarts() throws {
    let engine = FakeInputEngine()
    let journal = try writeRustJournal()

    let message = makeRuntime(engine).resetUserDict(timestamp: "20261028-000000")

    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    XCTAssertEqual(engine.lifecycleTrace, ["finalize", "startMaintenance"])
    XCTAssertFalse(message.hasPrefix("重置失败"), message)
  }

  // MARK: - Config cache (B1/B2)

  func testLoadSettingsReadsStyleFlagsFromAUsableConfig() throws {
    try writeBaseConfig(layout: "stacked")
    let runtime = makeRuntime(FakeInputEngine())

    runtime.loadSettings()

    XCTAssertNotNil(runtime.config)
    XCTAssertFalse(runtime.styleFlags.linear)
  }

  /// B1: a reread that opens an empty shell must not replace the good config or its flags.
  func testUnusableRereadKeepsThePreviousConfigAndFlags() throws {
    try writeBaseConfig(layout: "stacked")
    let runtime = makeRuntime(FakeInputEngine())
    runtime.loadSettings()
    let good = try XCTUnwrap(runtime.config)
    let flags = runtime.styleFlags

    try Data("config_version: \"2\"\n".utf8).write(to: baseConfigURL)
    runtime.loadSettings()

    XCTAssertTrue(runtime.config === good)
    XCTAssertEqual(runtime.styleFlags, flags)
  }

  /// Without any usable config the IMK path still gets inline, linear defaults.
  func testNoUsableConfigFallsBackToInlineLinearFlags() {
    let runtime = makeRuntime(FakeInputEngine())

    runtime.loadSettings()

    XCTAssertNil(runtime.config)
    XCTAssertTrue(runtime.styleFlags.linear)
    XCTAssertTrue(runtime.styleFlags.inlinePreedit)
  }

  /// B2: a per-schema reload heals a missing config once the base config becomes readable.
  func testSchemaReloadHealsAMissingConfig() throws {
    let runtime = makeRuntime(FakeInputEngine())
    runtime.loadSettings()
    XCTAssertNil(runtime.config)

    try writeBaseConfig(layout: "stacked")
    runtime.loadSettings(for: "rime_ice")

    XCTAssertNotNil(runtime.config)
    XCTAssertFalse(runtime.styleFlags.linear)
  }

  // MARK: - Refresh when idle

  @MainActor
  func testRefreshRunsAtOnceWithoutLiveSessions() {
    let runtime = makeRuntime(FakeInputEngine())
    var ran = false

    XCTAssertFalse(runtime.requestLiveSessionRefreshWhenIdle { ran = true })

    XCTAssertTrue(ran)
    XCTAssertFalse(runtime.applyPendingLiveSessionRefreshIfIdle(), "nothing stays queued")
  }

  @MainActor
  func testRefreshWaitsForAnInFlightComposition() throws {
    let delegate = NSApp.owlAppDelegate
    let previousEngine = delegate.runtime.engine
    delegate.runtime.engine = FakeInputEngine()
    defer { delegate.runtime.engine = previousEngine }
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    let session = FakeEngineSession(sessionID: 30, input: "ni")
    controller.engineSession = session
    let runtime = makeRuntime(FakeInputEngine())
    runtime.registerLiveController(controller)
    var ran = false

    XCTAssertTrue(runtime.requestLiveSessionRefreshWhenIdle { ran = true })
    XCTAssertFalse(ran, "a composing session must not be refreshed")
    XCTAssertFalse(session.destroyed)

    session.scriptedInput = nil  // the composition ended
    XCTAssertFalse(runtime.applyPendingLiveSessionRefreshIfIdle())
    XCTAssertTrue(ran)
  }

  @MainActor
  func testKeyboardApplyPreservesCompositionUntilIdle() throws {
    let delegate = NSApp.owlAppDelegate
    let previousEngine = delegate.runtime.engine
    delegate.runtime.engine = FakeInputEngine()
    defer { delegate.runtime.engine = previousEngine }
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    let session = FakeEngineSession(sessionID: 31, input: "ni")
    controller.engineSession = session
    let runtime = makeRuntime(FakeInputEngine())
    runtime.registerLiveController(controller)

    _ = try runtime.applyKeyboardSettings(.config)

    XCTAssertFalse(session.destroyed, "applying settings must not tear down a composing session")
    XCTAssertEqual(controller.engineSession?.input(), "ni")
    session.scriptedInput = nil
    XCTAssertFalse(runtime.applyPendingLiveSessionRefreshIfIdle())
    XCTAssertTrue(session.destroyed, "the queued configuration refresh runs at the idle boundary")
  }

  // MARK: - Helpers

  private func makeRuntime(_ engine: FakeInputEngine) -> EngineRuntime {
    EngineRuntime(engine: engine, userDirectory: userDirectory, sharedSupportURL: sharedSupport)
  }

  private var baseConfigURL: URL {
    sharedSupport.appendingPathComponent("owltype.yaml")
  }

  private func writeBaseConfig(layout: String) throws {
    try Data("""
      config_version: "1"
      style:
        candidate_list_layout: \(layout)
        inline_preedit: true
      """.utf8).write(to: baseConfigURL)
  }

  private func writeRustJournal() throws -> URL {
    let rustRoot = userDirectory.appendingPathComponent("msime-user", isDirectory: true)
    try FileManager.default.createDirectory(at: rustRoot, withIntermediateDirectories: true)
    let journal = rustRoot.appendingPathComponent("msime_user.db")
    try Data("journal".utf8).write(to: journal)
    return journal
  }
}

// MARK: - Fakes (test fixtures only — never shipped in sources/)

final class FakeEngineSession: OwlRustSession {
  private var _generation: UInt64
  private var _isValid: Bool
  var processResult: Bool
  var pendingCommit: String?
  var scriptedStatus: EngineStatus?
  var scriptedComposition: EngineComposition?
  var scriptedInput: String?
  var scriptedCaretPos: Int
  var optionState: [EngineOption: Bool]
  var selectCandidateResult: Bool
  var changePageResult: Bool
  var selectSchemaResult: Bool
  private var _settledRerankReady: Bool
  private var _settledRerankLoading: Bool
  private var _rerankConfigurationEpoch: UInt64
  var stateLabels: [String: String]
  var syncRerankPreferencesTransition: (() -> Void)?
  var settledRerankStartTransition: (() -> Void)?
  var settledRerankStartResult: OwlSettledRerankStartResult
  var settledRerankPollResults: [OwlSettledRerankPollResult]
  var finishNativeResult: Bool
  var finishNativeCommit: String?
  private var _acceptsHostSmartPunctuation: Bool
  var lastCommittedRawInput: String?
  var peekableCandidates: [EngineCandidate]
  var selectCandidateAbsoluteResult: Bool
  var removeCandidateResult: Bool

  private(set) var processedKeys: [(keycode: UInt32, modifiers: UInt32)] = []
  private(set) var setOptions: [(option: EngineOption, value: Bool)] = []
  private(set) var properties: [(name: String, value: String)] = []
  private(set) var selectedIndices: [Int] = []
  private(set) var pageChanges: [Bool] = []
  private(set) var selectedLiveSchemas: [String] = []
  private(set) var clearCompositionCount = 0
  private(set) var destroyed = false
  private(set) var takeCommitCount = 0
  private(set) var rerankPreferenceSyncCount = 0
  private(set) var settledRerankStartCount = 0
  private(set) var settledRerankPolls: [(token: UInt64, accept: Bool)] = []
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
    status: EngineStatus? = nil,
    composition: EngineComposition? = nil,
    input: String? = nil,
    caretPos: Int = 0,
    optionState: [EngineOption: Bool] = [:],
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
    self._generation = generation
    self._isValid = isValid
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
    self._settledRerankReady = settledRerankReady
    self._settledRerankLoading = settledRerankLoading
    self._rerankConfigurationEpoch = rerankConfigurationEpoch
    self.stateLabels = stateLabels
    self.settledRerankStartResult = .noWork
    self.settledRerankPollResults = [.doneWithoutChange]
    self.finishNativeResult = finishNativeResult
    self.finishNativeCommit = finishNativeCommit
    self._acceptsHostSmartPunctuation = acceptsHostSmartPunctuation
    self.peekableCandidates = []
    self.selectCandidateAbsoluteResult = false
    self.removeCandidateResult = false
    super.init(sessionID: sessionID)
  }

  override var generation: UInt64 {
    get { _generation }
    set { _generation = newValue }
  }

  override var isValid: Bool {
    get { _isValid }
    set { _isValid = newValue }
  }

  override var settledRerankReady: Bool {
    get { _settledRerankReady }
    set { _settledRerankReady = newValue }
  }

  override var settledRerankLoading: Bool {
    get { _settledRerankLoading }
    set { _settledRerankLoading = newValue }
  }

  override var rerankConfigurationEpoch: UInt64 {
    get { _rerankConfigurationEpoch }
    set { _rerankConfigurationEpoch = newValue }
  }

  override var acceptsHostSmartPunctuation: Bool {
    get { _acceptsHostSmartPunctuation }
    set { _acceptsHostSmartPunctuation = newValue }
  }

  override func process(keycode: UInt32, modifiers: UInt32) -> Bool {
    processedKeys.append((keycode, modifiers))
    return processResult
  }

  override func takeCommit() -> String? {
    takeCommitCount += 1
    defer { pendingCommit = nil }
    return pendingCommit
  }

  override func lastCommittedInput() -> String? { lastCommittedRawInput }

  override func status() -> EngineStatus? { scriptedStatus }

  override func composition() -> EngineComposition? { scriptedComposition }

  override func input() -> String? { scriptedInput }

  override func caretPos() -> Int { scriptedCaretPos }

  override func clearComposition() { clearCompositionCount += 1 }

  override func selectCandidate(_ index: Int) -> Bool {
    selectedIndices.append(index)
    return selectCandidateResult
  }

  override func selectCandidateAbsolute(_ index: Int) -> Bool {
    selectedAbsoluteIndices.append(index)
    return selectCandidateAbsoluteResult
  }

  override func selectCandidate(_ token: OwlCandidateToken) -> Bool {
    if token.sessionID != 0 && token.sessionID != sessionID {
      return false
    }
    if token.isAbsolute {
      return selectCandidateAbsolute(token.candidateID)
    }
    return selectCandidate(token.candidateID)
  }

  override func removeCandidate(_ token: OwlCandidateToken) -> Bool {
    removedCandidates.append(token)
    return removeCandidateResult
  }

  override func peekCandidates(from index: Int, count: Int) -> [EngineCandidate] {
    guard index >= 0, index < peekableCandidates.count, count > 0 else { return [] }
    return Array(peekableCandidates[index..<min(index + count, peekableCandidates.count)])
  }

  override func changePage(up: Bool) -> Bool {
    pageChanges.append(up)
    return changePageResult
  }

  override func selectSchema(_ id: String) -> Bool {
    selectedLiveSchemas.append(id)
    return selectSchemaResult
  }

  override func syncRerankPreferences() {
    rerankPreferenceSyncCount += 1
    syncRerankPreferencesTransition?()
  }

  override func startSettledRerank() -> OwlSettledRerankStartResult {
    settledRerankStartCount += 1
    settledRerankStartTransition?()
    return settledRerankStartResult
  }

  override func pollSettledRerank(token: UInt64, accept: Bool) -> OwlSettledRerankPollResult {
    settledRerankPolls.append((token, accept))
    guard !settledRerankPollResults.isEmpty else { return .doneWithoutChange }
    return settledRerankPollResults.removeFirst()
  }

  override func option(_ option: EngineOption) -> Bool { optionState[option] ?? false }

  override func setOption(_ option: EngineOption, _ value: Bool) {
    setOptions.append((option, value))
    optionState[option] = value
  }

  override func setProperty(name: String, value: String) {
    properties.append((name, value))
  }

  override func stateLabel(option name: String, state: Bool, abbreviated: Bool) -> String? {
    stateLabels[name]
  }

  override func finishNativeComposition(onFocusLoss: Bool) -> Bool {
    nativeFinishes.append(onFocusLoss)
    guard finishNativeResult else { return false }
    pendingCommit = finishNativeCommit
    scriptedInput = ""
    scriptedComposition = nil
    return true
  }

  override func balanceHostPairedPunctuation() { pairBalanceCount += 1 }

  override func processHostASCIIPunctuation(_ character: String) -> Bool {
    hostASCIIPunctuation.append(character)
    return processResult
  }

  override func destroy() {
    destroyed = true
    _isValid = false
    sessionID = 0
  }
}

final class FakeInputEngine: OwlRustEngine {
  var vendedSession: FakeEngineSession
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
  private(set) var lifecycleTrace: [String] = []
  private(set) var deployedConfigFiles: [String] = []
  private(set) var createdSessionCount = 0
  private(set) var selectedSchemas: [String] = []
  private(set) var sessionForIDs: [UInt64] = []
  private(set) var notificationHandlerSet = false

  init(
    vendedSession: FakeEngineSession = FakeEngineSession(),
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
    super.init()
  }

  override func setup(_ traits: OwlEngineTraits) { setupCount += 1 }
  override func startMaintenance(fullCheck: Bool) -> Bool {
    lifecycleTrace.append("startMaintenance")
    return startMaintenanceResult
  }
  override func joinMaintenance() {
    joinMaintenanceCount += 1
    lifecycleTrace.append("joinMaintenance")
  }
  override func deployConfigFile(_ fileName: String, versionKey: String) -> Bool {
    deployedConfigFiles.append(fileName)
    return deployConfigFileResult
  }
  override func setNotificationHandler(_ handler: @escaping EngineNotificationHandler) {
    notificationHandlerSet = true
  }
  override func cleanupAllSessions() { cleanupAllSessionsCount += 1 }
  override func finalize() -> Bool {
    finalizeCount += 1
    lifecycleTrace.append("finalize")
    return finalizeResult
  }
  override func schemaList() -> [(id: String, name: String)] { scriptedSchemaList }
  override func currentSchema() -> String { scriptedCurrentSchema }
  override func selectSchema(_ id: String) -> Bool {
    selectedSchemas.append(id)
    return selectSchemaResult
  }
  override func version() -> String? { scriptedVersion }

  override func createSession() -> OwlRustSession {
    createdSessionCount += 1
    return vendedSession
  }

  override func session(for id: UInt64) -> OwlRustSession {
    sessionForIDs.append(id)
    return vendedSession
  }
}
