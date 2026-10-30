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
    XCTAssertEqual(engine.deployedConfigFiles, ["owltype.yaml"])
  }

  /// A live session makes finalize refuse. The engine must stay up, untouched.
  func testRedeployBlockedByLiveSessionLeavesEngineRunning() {
    let engine = FakeInputEngine(finalizeResult: false)

    XCTAssertFalse(makeRuntime(engine).redeploy())

    XCTAssertEqual(engine.lifecycleTrace, ["finalize"])
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)
  }

  /// c00875c: an unresolved template-migration journal used to stop the engine for good once
  /// redeploy had shut it down. Recovery now only blocks recompiling; the config is reread.
  func testPendingTemplateRecoverySkipsMaintenanceButRereadsTheConfig() throws {
    let engine = FakeInputEngine()
    try writeBaseConfig(layout: "linear")
    let runtime = makeRuntime(engine)
    XCTAssertTrue(runtime.start(fullCheck: false))
    let flags = runtime.styleFlags
    try writePendingTemplateJournal()

    XCTAssertFalse(runtime.redeploy())

    XCTAssertEqual(engine.lifecycleTrace, ["startMaintenance", "finalize"],
                   "pending recovery must skip maintenance, not the engine")
    XCTAssertEqual(engine.deployedConfigFiles, ["owltype.yaml"], "only the first start deployed")
    XCTAssertEqual(runtime.config?.isOpen, true, "the reread still reaches a usable config")
    XCTAssertEqual(runtime.styleFlags, flags)
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

  private func writePendingTemplateJournal() throws {
    let directory = userDirectory.appendingPathComponent(OwlTemplateMigration.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: directory.appendingPathComponent("journal.json"))
    XCTAssertTrue(OwlTemplateMigration.hasPendingRecovery(dataDir: userDirectory))
  }

  private func writeRustJournal() throws -> URL {
    let rustRoot = userDirectory.appendingPathComponent("msime-user", isDirectory: true)
    try FileManager.default.createDirectory(at: rustRoot, withIntermediateDirectories: true)
    let journal = rustRoot.appendingPathComponent("msime_user.db")
    try Data("journal".utf8).write(to: journal)
    return journal
  }
}
