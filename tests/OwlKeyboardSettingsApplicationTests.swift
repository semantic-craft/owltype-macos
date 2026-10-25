import XCTest
@testable import Owltype

final class OwlKeyboardSettingsApplicationTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testConfigWritesBeforeRefreshAndDeploysFrontendAndActiveSchema() throws {
    let engine = FakeRimeEngine()
    var refreshed = false
    let application = OwlKeyboardSettingsApplication(
      engine: engine, directory: directory, activeSchema: { "rime_ice" }, refresh: {
        refreshed = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("default.custom.yaml").path))
        XCTAssertEqual(engine.deployedConfigFiles, ["default.yaml", "owltype.yaml", "rime_ice.schema.yaml"])
      })
    let outcome = try application.apply(.current(), mode: .config)
    XCTAssertTrue(outcome.succeeded)
    XCTAssertTrue(outcome.written.contains("default.custom.yaml"))
    XCTAssertTrue(refreshed)
    XCTAssertEqual(engine.finalizeCount, 0)
    XCTAssertTrue(engine.lifecycleTrace.isEmpty)
  }

  func testFuzzyWaitsForPrismBeforeRefreshing() throws {
    let engine = FakeRimeEngine()
    var refreshed = false
    let application = OwlKeyboardSettingsApplication(
      engine: engine, directory: directory, activeSchema: { "rime_ice" }, refresh: {
        refreshed = true
        XCTAssertEqual(engine.lifecycleTrace, ["startMaintenance", "joinMaintenance"])
      })
    XCTAssertTrue(try application.apply(.current(), mode: .fuzzy).succeeded)
    XCTAssertTrue(refreshed)
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)
  }

  func testWriteFailureNeverDeploysOrRefreshes() throws {
    // A regular file cannot serve as a configuration directory.
    let blocked = directory.appendingPathComponent("not-a-directory")
    try Data("blocked".utf8).write(to: blocked)
    let engine = FakeRimeEngine()
    let application = OwlKeyboardSettingsApplication(
      engine: engine, directory: blocked, activeSchema: { "rime_ice" },
      refresh: { XCTFail("Failed write must not refresh") })
    XCTAssertThrowsError(try application.apply(.current(), mode: .config))
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)
    XCTAssertTrue(engine.lifecycleTrace.isEmpty)
  }

  func testFailedDeploymentReportsSavedButNotEffective() throws {
    let engine = FakeRimeEngine(deployConfigFileResult: false)
    let application = OwlKeyboardSettingsApplication(
      engine: engine, directory: directory, activeSchema: { "rime_ice" }, refresh: {})
    let outcome = try application.apply(.current(), mode: .config)
    XCTAssertFalse(outcome.succeeded)
    XCTAssertFalse(outcome.written.isEmpty)
  }

  func testNativeApplyUsesTheEngineSeamWithoutWritingRimeFiles() throws {
    let engine = FakeRimeEngine()
    let application = OwlKeyboardSettingsApplication(
      engine: engine,
      directory: directory,
      activeSchema: { "rime_ice" },
      refresh: {},
      nativeApply: true
    )

    let outcome = try application.apply(.current(), mode: .config)

    XCTAssertTrue(outcome.succeeded)
    XCTAssertEqual(outcome.written, [])
    XCTAssertEqual(engine.deployedConfigFiles, ["default.yaml"])
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("default.custom.yaml").path
    ))
  }

  func testNativeApplyFailureIsNotReportedAsEffective() throws {
    let engine = FakeRimeEngine(deployConfigFileResult: false)
    let application = OwlKeyboardSettingsApplication(
      engine: engine,
      directory: directory,
      activeSchema: { "rime_ice" },
      refresh: {},
      nativeApply: true
    )

    let outcome = try application.apply(.current(), mode: .config)

    XCTAssertFalse(outcome.succeeded)
    XCTAssertEqual(outcome.written, [])
  }

  func testNativeApplyStillRefusesPendingMigrationRecovery() throws {
    let journal = directory
      .appendingPathComponent(".owl-template-migration", isDirectory: true)
      .appendingPathComponent("journal.json")
    try FileManager.default.createDirectory(
      at: journal.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{broken".utf8).write(to: journal)
    let engine = FakeRimeEngine()
    let application = OwlKeyboardSettingsApplication(
      engine: engine,
      directory: directory,
      activeSchema: { "rime_ice" },
      refresh: { XCTFail("Recovery-pending apply must not refresh") },
      nativeApply: true
    )

    XCTAssertThrowsError(try application.apply(.current(), mode: .config)) { error in
      XCTAssertEqual((error as? OwlKeyboardSettingsApplication.Failure)?.errorDescription,
                     OwlKeyboardSettingsApplication.Failure.recoveryPending.errorDescription)
    }
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)
    XCTAssertTrue(engine.lifecycleTrace.isEmpty)
  }
}
