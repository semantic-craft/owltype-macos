import XCTest

final class OwlSessionRestartTests: XCTestCase {
  private let own = OwlSessionRestart.primarySource
  private let other = "com.tencent.inputmethod.wetype.pinyin"

  func testFirstInstallRegistersOnceAndVerifiesSelectionBeforeRefreshAndLaunch() throws {
    let effects = Session()
    effects.observations = [ready(source: other), ready(source: own), ready(source: own)]
    let server = try OwlSessionRestart.run(request(first: true), effects: effects)
    XCTAssertEqual(server.pid, 400)
    XCTAssertEqual(effects.events, ["terminate", "register-enable", "observe", "select:\(own)",
                                   "observe", "refresh", "launch", "observe"])
  }

  func testUpdateRestoresExactHantModeWithoutRegisteringOrEnabling() throws {
    let hant = "im.owltype.inputmethod.Owltype.Hant"
    let effects = Session()
    effects.observations = [ready(source: "com.apple.keylayout.US"), ready(source: hant)]
    _ = try OwlSessionRestart.run(request(source: hant), effects: effects)
    XCTAssertTrue(effects.events.contains("select:\(hant)"))
    XCTAssertFalse(effects.events.contains("register-enable"))
    XCTAssertEqual(effects.events.filter { $0 == "refresh" }.count, 1)
  }

  func testUpdateDoesNotSelectOverOtherInputMethod() throws {
    let effects = Session()
    effects.observations = [ready(source: other)]
    _ = try OwlSessionRestart.run(request(source: other), effects: effects)
    XCTAssertEqual(effects.events, ["terminate", "observe", "refresh", "launch", "observe"])
  }

  func testUnexpectedSourceChangeFailsWithoutForcingPreviousOtherSource() {
    let effects = Session()
    effects.observations = [ready(source: "com.apple.keylayout.US")]
    expectFailure(.selfCheckTimedOut) {
      try OwlSessionRestart.run(request(source: other), effects: effects, timeout: 2)
    }
    XCTAssertFalse(effects.events.contains { $0.hasPrefix("select:") })
  }

  func testSelectionReturnDoesNotCountAsReadbackOrTriggerRefresh() {
    let effects = Session()
    effects.observations = [ready(source: "com.apple.keylayout.US")]
    expectFailure(.selfCheckTimedOut) {
      try OwlSessionRestart.run(request(), effects: effects, timeout: 2)
    }
    XCTAssertFalse(effects.events.contains("refresh"))
    XCTAssertFalse(effects.events.contains("launch"))
  }

  func testWaitsForEnableConsentWithoutRepeatingEnable() throws {
    let effects = Session()
    effects.observations = [
      .init(parentEnabled: false, modeEnabled: false, selectedSource: other, servers: []),
      ready(source: own),
    ]
    _ = try OwlSessionRestart.run(request(first: true), effects: effects)
    XCTAssertEqual(effects.events.filter { $0 == "register-enable" }.count, 1)
    XCTAssertEqual(effects.events.prefix(5), ["terminate", "register-enable", "observe", "observe", "refresh"])
  }

  func testConsentWaitDoesNotSpendTheSelfCheckBudget() throws {
    let effects = Session()
    let disabled = OwlSessionRestart.Observation(parentEnabled: false, modeEnabled: false, selectedSource: other, servers: [])
    effects.observations = Array(repeating: disabled, count: 120) + [ready(source: own)]
    _ = try OwlSessionRestart.run(request(first: true), effects: effects)
    XCTAssertGreaterThan(effects.uptime, 45)
    XCTAssertEqual(effects.events.filter { $0 == "register-enable" }.count, 1)
  }

  func testMissingConsentFailsWithItsOwnReason() {
    let effects = Session()
    effects.observations = [.init(parentEnabled: true, modeEnabled: false, selectedSource: other, servers: [])]
    expectFailure(.inputSourceNotEnabled) {
      try OwlSessionRestart.run(request(first: true), effects: effects, consentTimeout: 3)
    }
    XCTAssertFalse(effects.events.contains("refresh"))
  }

  func testUpdateOfDisabledSourceRequestsEnableOnceSoRetryRecovers() throws {
    let effects = Session()
    effects.observations = [
      .init(parentEnabled: false, modeEnabled: false, selectedSource: other, servers: []),
      .init(parentEnabled: false, modeEnabled: false, selectedSource: other, servers: []),
      ready(source: other),
    ]
    _ = try OwlSessionRestart.run(request(source: other), effects: effects)
    XCTAssertEqual(effects.events, ["terminate", "observe", "register-enable", "observe", "observe",
                                   "refresh", "launch", "observe"])
  }

  func testOldProcessGetsOneForcedTerminationBeforeSessionActions() throws {
    let effects = Session()
    effects.oldProcessAlive = true
    effects.observations = [ready(source: own)]
    _ = try OwlSessionRestart.run(request(), effects: effects)
    XCTAssertEqual(effects.events.prefix(3), ["terminate", "kill", "observe"])
    XCTAssertEqual(effects.events.filter { $0 == "kill" }.count, 1)
  }

  func testOldProcessThatCannotExitStopsBeforeRegistrationOrRefresh() {
    let effects = Session()
    effects.oldProcessAlive = true
    effects.forceWorks = false
    expectFailure(.oldProcessDidNotExit) {
      try OwlSessionRestart.run(request(first: true), effects: effects)
    }
    XCTAssertEqual(effects.events, ["terminate", "kill"])
  }

  func testRejectsWrongVersionPathStaleInodeAndMultipleServers() {
    let valid = server()
    let invalid: [[OwlSessionRestart.Server]] = [
      [],
      [server(version: "2.0.12")],
      [server(path: "/tmp/Owltype.app/Contents/MacOS/Owltype")],
      [server(mapped: false)],
      [valid, valid],
    ]
    for servers in invalid {
      let effects = Session()
      effects.observations = [.init(parentEnabled: true, modeEnabled: true, selectedSource: own, servers: servers)]
      expectFailure(.selfCheckTimedOut) {
        try OwlSessionRestart.run(request(), effects: effects, timeout: 2)
      }
    }
  }

  func testRejectsRootAndMissingUpdateContextBeforeSideEffects() {
    let effects = Session()
    effects.isUserSession = false
    expectFailure(.notUserSession) { try OwlSessionRestart.run(request(), effects: effects) }
    effects.isUserSession = true
    expectFailure(.missingContext) { try OwlSessionRestart.run(request(source: ""), effects: effects) }
    XCTAssertTrue(effects.events.isEmpty)
  }

  func testMappingRequiresPathAndInodeInTheSameTextRecord() {
    let path = OwlSessionRestart.installedExecutable
    XCTAssertTrue(OwlSessionRestart.mapsInstalledExecutable("p400\nftxt\ni100\nn\(path)\n", inode: 100))
    XCTAssertFalse(OwlSessionRestart.mapsInstalledExecutable("p400\nftxt\ni99\nn\(path)\n", inode: 100))
    XCTAssertFalse(OwlSessionRestart.mapsInstalledExecutable("p400\nftxt\ni100\nn/retired/Owltype\nftxt\ni99\nn\(path)\n", inode: 100))
  }

  private func request(first: Bool = false, source: String = OwlSessionRestart.primarySource) -> OwlSessionRestart.Request {
    .init(firstInstall: first, sourceBefore: source, expectedVersion: "2.0.13")
  }

  private func ready(source: String) -> OwlSessionRestart.Observation {
    .init(parentEnabled: true, modeEnabled: true, selectedSource: source, servers: [server()])
  }

  private func server(version: String = "2.0.13", path: String = OwlSessionRestart.installedExecutable,
                      mapped: Bool = true) -> OwlSessionRestart.Server {
    .init(pid: 400, executable: path, version: version, mapsInstalledExecutable: mapped)
  }

  private func expectFailure<T>(_ expected: OwlSessionRestart.Failure, file: StaticString = #filePath,
                                line: UInt = #line, _ operation: () throws -> T) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      XCTAssertEqual(error as? OwlSessionRestart.Failure, expected, file: file, line: line)
    }
  }

  private final class Session: OwlSessionRestart.Effects {
    var isUserSession = true
    var uptime: TimeInterval = 0
    var oldProcessAlive = false
    var forceWorks = true
    var events: [String] = []
    var observations: [OwlSessionRestart.Observation] = []
    func pause() { uptime += 0.5 }
    func stopOldProcesses(force: Bool) {
      events.append(force ? "kill" : "terminate")
      if force && forceWorks { oldProcessAlive = false }
    }
    func oldProcessesRemain() -> Bool { oldProcessAlive }
    func registerAndEnableParentAndMode() { events.append("register-enable") }
    func observe() -> OwlSessionRestart.Observation {
      events.append("observe")
      return observations.count > 1 ? observations.removeFirst() : observations[0]
    }
    func selectSource(_ source: String) { events.append("select:\(source)") }
    func refreshTextInputServices() { events.append("refresh") }
    func launchInstalledApp() { events.append("launch") }
  }
}
