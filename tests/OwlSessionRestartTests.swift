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

  func testServerQueryListsTheProcessThatRunsIt() throws {
    // The hosted test process stands in for the App re-checking itself: pgrep runs as its child.
    let query = OwlSessionRestart.serverQuery(uid: getuid(), name: ProcessInfo.processInfo.processName)
    let pids = try output(of: "/usr/bin/pgrep", query)
    XCTAssertTrue(pids.split(separator: "\n").contains("\(getpid())"), pids)
  }

  func testServerFactsComeFromTheKernelAndTheBundle() throws {
    // The hosted test process maps its host App's executable, as the server maps the installed one.
    let pid = getpid()
    let mapping = try output(of: "/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "txt", "-F", "fin"])
    let server = OwlSessionRestart.server(pid: pid, mapping: mapping, installedInode: 0)
    let executable = try XCTUnwrap(Bundle.main.executablePath.flatMap { realpath($0, nil) })
    defer { free(executable) }
    XCTAssertEqual(server.executable, String(cString: executable))
    XCTAssertEqual(server.version, Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    // Another file now at that path is not the binary the process runs.
    XCTAssertEqual(OwlSessionRestart.bundleVersion(of: server.executable, mapping: "p\(pid)\nftxt\ni1\nn\(server.executable)\n"), "")
  }

  // MARK: #207 —— 失败归因：阶段、原因、未满足条件（安装日志、恢复弹窗、诊断包共用）

  func testStagesAreEnteredInOrderBeforeEachStepsFirstEffect() throws {
    let effects = Session()
    effects.observations = [ready(source: other), ready(source: own), ready(source: own)]
    _ = try OwlSessionRestart.run(request(first: true), effects: effects)
    XCTAssertEqual(effects.stages, [.stopOldProcesses, .enable, .select, .launch, .verify])
  }

  func testUnmetConditionsNameEveryMissingPieceOfEvidence() {
    XCTAssertEqual(OwlSessionRestart.unmetConditions(ready(source: own), request: request()), [])
    let disabled = OwlSessionRestart.Observation(parentEnabled: true, modeEnabled: false, selectedSource: other, servers: [])
    XCTAssertEqual(OwlSessionRestart.unmetConditions(disabled, request: request()),
                   [.sourceNotEnabled, .selectedSourceDiffers, .noServer])
    let stale = OwlSessionRestart.Observation(parentEnabled: true, modeEnabled: true, selectedSource: own,
                                              servers: [server(version: "2.0.12", path: "/tmp/Owltype", mapped: false)])
    XCTAssertEqual(OwlSessionRestart.unmetConditions(stale, request: request()),
                   [.serverOutsideInstalledApp, .serverVersionDiffers, .serverMapsOtherExecutable])
    let two = OwlSessionRestart.Observation(parentEnabled: true, modeEnabled: true, selectedSource: own,
                                            servers: [server(), server()])
    XCTAssertEqual(OwlSessionRestart.unmetConditions(two, request: request()), [.multipleServers])
    let dead = OwlSessionRestart.Observation(parentEnabled: true, modeEnabled: true, selectedSource: own,
                                             servers: [.init(pid: 0, executable: OwlSessionRestart.installedExecutable,
                                                             version: "2.0.13", mapsInstalledExecutable: true)])
    XCTAssertEqual(OwlSessionRestart.unmetConditions(dead, request: request()), [.noServer])
  }

  func testServerConditionsIgnoreSelectionSoTheAppCanRecheckAfterTheUserSwitched() {
    let switched = ready(source: other)
    XCTAssertEqual(OwlSessionRestart.unmetServerConditions(switched, expectedVersion: "2.0.13"), [])
    XCTAssertEqual(OwlSessionRestart.unmetConditions(switched, request: request()), [.selectedSourceDiffers])
  }

  func testTimeoutDiagnosisNamesTheStageAndWhatTheLastProbeSaw() {
    let effects = Session()
    effects.observations = [.init(parentEnabled: true, modeEnabled: true, selectedSource: own, servers: [server(version: "2.0.12")])]
    let diagnosis = diagnoseFailure(request(), effects: effects, timeout: 2)
    XCTAssertEqual(diagnosis?.stage, .verify)
    XCTAssertEqual(diagnosis?.reason, "selfCheckTimedOut")
    XCTAssertEqual(diagnosis?.unmet, [.serverVersionDiffers])
    XCTAssertEqual(diagnosis?.lastObservation, effects.observations[0])
    XCTAssertEqual(diagnosis?.summary,
                   "阶段「核验会话」失败：自检超时（selfCheckTimedOut）；未满足：运行中的版本为 2.0.12，预期 2.0.13")
  }

  func testSelectionThatNeverTakesEffectIsAttributedToTheSelectStage() {
    let effects = Session()
    effects.observations = [ready(source: "com.apple.keylayout.US")]
    let diagnosis = diagnoseFailure(request(), effects: effects, timeout: 2)
    XCTAssertEqual(diagnosis?.stage, .select)
    XCTAssertEqual(diagnosis?.unmet, [.selectedSourceDiffers])
    XCTAssertEqual(diagnosis?.summary, "阶段「恢复选中的输入法」失败：自检超时（selfCheckTimedOut）；未满足："
                   + "选中的输入法与安装前不同（预期 \(own)，实际 com.apple.keylayout.US）")
  }

  func testConsentTimeoutDiagnosisReportsOnlyTheEnableCondition() {
    let effects = Session()
    effects.observations = [.init(parentEnabled: true, modeEnabled: false, selectedSource: other, servers: [])]
    let diagnosis = diagnoseFailure(request(first: true), effects: effects, consentTimeout: 3)
    XCTAssertEqual(diagnosis?.stage, .enable)
    XCTAssertEqual(diagnosis?.reason, "inputSourceNotEnabled")
    XCTAssertEqual(diagnosis?.unmet, [.sourceNotEnabled], "启用前不期待服务器，也不报选中态")
    XCTAssertEqual(diagnosis?.summary,
                   "阶段「等待启用输入源」失败：等待启用超时（inputSourceNotEnabled）；未满足：输入源未启用（父源已启用，模式未启用）")
  }

  func testStopStageDiagnosisCarriesNoProbeConditions() {
    let effects = Session()
    effects.oldProcessAlive = true
    effects.forceWorks = false
    let diagnosis = diagnoseFailure(request(first: true), effects: effects)
    XCTAssertEqual(diagnosis?.stage, .stopOldProcesses)
    XCTAssertEqual(diagnosis?.unmet, [])
    XCTAssertNil(diagnosis?.lastObservation)
    XCTAssertEqual(diagnosis?.summary, "阶段「结束旧进程」失败：旧进程没有退出（oldProcessDidNotExit）")
  }

  func testHelperCommandErrorKeepsItsOwnDescriptionAsTheReason() {
    struct ProbeTimedOut: Error, CustomStringConvertible {
      var description: String { "Owltype --install-session-probe 超过 8 秒未结束" }
    }
    let diagnosis = OwlSessionRestart.diagnose(ProbeTimedOut(), request: request(), stage: .launch, lastObservation: nil)
    XCTAssertEqual(diagnosis.reason, "Owltype --install-session-probe 超过 8 秒未结束")
    XCTAssertEqual(diagnosis.summary, "阶段「启动已安装的法墨」失败：Owltype --install-session-probe 超过 8 秒未结束")
  }

  func testDescribeSpellsOutEachConditionAndAnEmptyListMeansHealthy() {
    let observation = OwlSessionRestart.Observation(parentEnabled: false, modeEnabled: false, selectedSource: other,
                                                    servers: [server(), server(version: "2.0.12")])
    let text = OwlSessionRestart.describe(unmet: [.sourceNotEnabled, .multipleServers], observation: observation,
                                          expectedSource: own, expectedVersion: "2.0.13")
    XCTAssertEqual(text, "输入源未启用（父源未启用，模式未启用）；法墨进程不止一个（pid 400、400）")
    XCTAssertEqual(OwlSessionRestart.describe(unmet: [], observation: nil, expectedSource: own, expectedVersion: "2.0.13"),
                   "全部条件已满足")
  }

  func testDiagnosisRoundTripsThroughJSON() throws {
    let diagnosis = OwlSessionRestart.diagnose(OwlSessionRestart.Failure.selfCheckTimedOut, request: request(),
                                               stage: .verify, lastObservation: ready(source: own))
    let data = try JSONEncoder().encode(diagnosis)
    XCTAssertEqual(try JSONDecoder().decode(OwlSessionRestart.Diagnosis.self, from: data), diagnosis)
  }

  private func diagnoseFailure(_ request: OwlSessionRestart.Request, effects: Session, timeout: TimeInterval = 45,
                               consentTimeout: TimeInterval = 120) -> OwlSessionRestart.Diagnosis? {
    do {
      try OwlSessionRestart.run(request, effects: effects, timeout: timeout, consentTimeout: consentTimeout)
      XCTFail("expected the sequence to fail")
      return nil
    } catch {
      return OwlSessionRestart.diagnose(error, request: request, stage: effects.stages.last ?? .stopOldProcesses,
                                        lastObservation: effects.lastObservation)
    }
  }

  private func output(of path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
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
    /// Stage transitions, consecutive repeats collapsed; kept apart from `events` so the exact
    /// effect sequences above stay what they lock.
    var stages: [OwlSessionRestart.Stage] = []
    var lastObservation: OwlSessionRestart.Observation?
    func pause() { uptime += 0.5 }
    func stopOldProcesses(force: Bool) {
      events.append(force ? "kill" : "terminate")
      if force && forceWorks { oldProcessAlive = false }
    }
    func oldProcessesRemain() -> Bool { oldProcessAlive }
    func registerAndEnableParentAndMode() { events.append("register-enable") }
    func observe() -> OwlSessionRestart.Observation {
      events.append("observe")
      let observation = observations.count > 1 ? observations.removeFirst() : observations[0]
      lastObservation = observation
      return observation
    }
    func selectSource(_ source: String) { events.append("select:\(source)") }
    func refreshTextInputServices() { events.append("refresh") }
    func launchInstalledApp() { events.append("launch") }
    func didEnter(_ stage: OwlSessionRestart.Stage) {
      if stages.last != stage { stages.append(stage) }
    }
  }
}
