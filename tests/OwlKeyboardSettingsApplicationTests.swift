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

  func testFuzzyWaitsForPrismBeforeRefreshing() throws {
    let engine = FakeInputEngine()
    var refreshed = false
    let application = OwlKeyboardSettingsApplication(
      engine: engine, directory: directory, refresh: {
        refreshed = true
        XCTAssertEqual(engine.lifecycleTrace, ["startMaintenance", "joinMaintenance"])
      })
    XCTAssertTrue(try application.apply(mode: .fuzzy).succeeded)
    XCTAssertTrue(refreshed)
    XCTAssertTrue(engine.deployedConfigFiles.isEmpty)
  }

  func testConfigApplyDeploysThroughTheEngineWithoutWritingRimeFiles() throws {
    let engine = FakeInputEngine()
    let application = OwlKeyboardSettingsApplication(
      engine: engine,
      directory: directory,
      refresh: {}
    )

    let outcome = try application.apply(mode: .config)

    XCTAssertTrue(outcome.succeeded)
    XCTAssertEqual(outcome.written, [])
    XCTAssertEqual(engine.deployedConfigFiles, ["default.yaml"])
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("default.custom.yaml").path
    ))
  }

  func testFailedConfigApplyIsNotReportedAsEffective() throws {
    let engine = FakeInputEngine(deployConfigFileResult: false)
    let application = OwlKeyboardSettingsApplication(
      engine: engine,
      directory: directory,
      refresh: {}
    )

    let outcome = try application.apply(mode: .config)

    XCTAssertFalse(outcome.succeeded)
    XCTAssertEqual(outcome.written, [])
  }
}
