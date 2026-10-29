//
//  OwlAgentDeliveryTests.swift
//  OwltypeTests
//
//  deliver_text decisions with a fake host, target and preview: one write per confirmed request,
//  the four statuses, replay and busy, binding to the agent's terminal's successor, focus change,
//  quit, secure input, expiry and disconnect.
//

import XCTest
@testable import Owltype

private final class FakeTarget: OwlAgentDeliveryTarget {
  let processIdentifier: pid_t
  let applicationName = "TextEdit"
  var isTerminated = false
  var outcome = OwlTemplateDeliveryOutcome.confirmed
  var writes: [String] = []

  init(_ process: pid_t) { processIdentifier = process }

  func write(_ text: String, completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
    writes.append(text)
    completion(outcome)
  }
}

private final class FakeHost: OwlAgentDeliveryHost {
  var frontmostProcess: pid_t? = 200
  var isSecureInputEnabled = false
  var bindResult: Result<OwlAgentDeliveryTarget, OwlAgentBridgeProtocol.TargetChangedReason>
  var agentAncestors: Set<pid_t> = [100, 50]
  var scheduled: [(TimeInterval, () -> Void)] = []
  let target = FakeTarget(200)

  init() { bindResult = .success(target) }

  func bindFrontmost() -> Result<OwlAgentDeliveryTarget, OwlAgentBridgeProtocol.TargetChangedReason> { bindResult }
  func ancestors(of process: pid_t) -> Set<pid_t> { agentAncestors }
  func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) { scheduled.append((seconds, action)) }

  /// Runs the actions scheduled at exactly `seconds`.
  func fire(_ seconds: TimeInterval) {
    let due = scheduled.filter { $0.0 == seconds }
    scheduled.removeAll { $0.0 == seconds }
    due.forEach { $0.1() }
  }
}

private final class FakePreview: OwlAgentDeliveryPreview {
  var shown: [String] = []
  var targets: [String?] = []
  var dismissed = 0
  var decide: ((Bool) -> Void)?

  func show(text: String, agentName: String, decide: @escaping (Bool) -> Void) {
    shown.append("\(agentName): \(text)")
    self.decide = decide
  }
  func showTarget(_ name: String?) { targets.append(name) }
  func dismiss() { dismissed += 1 }
}

final class OwlAgentDeliveryTests: XCTestCase {
  private typealias Wire = OwlAgentBridgeProtocol
  private var host: FakeHost!
  private var preview: FakePreview!
  private var clock = Date(timeIntervalSince1970: 1_000_000)
  private var coordinator: OwlAgentDeliveryCoordinator!
  private let client = OwlAgentBridgeClient(helper: .init(name: "owltype-mcp", version: "0.1.0"),
                                            agentClient: .init(name: "grok-build", version: "0.9.3"), processID: 100)

  override func setUp() {
    host = FakeHost()
    preview = FakePreview()
    coordinator = OwlAgentDeliveryCoordinator(host: host, preview: { [unowned self] in self.preview }, now: { [unowned self] in self.clock })
  }

  private func params(_ id: String = "r1", text: String = "你好", timeout: Int? = nil) -> Wire.DeliverParams {
    .init(requestId: id, text: text, timeoutMs: timeout)
  }

  /// Starts a delivery and returns a box that fills with its reply.
  private func start(_ params: Wire.DeliverParams, cancellation: OwlAgentBridgeCancellation = .init()) -> () -> OwlAgentBridgeReply? {
    var reply: OwlAgentBridgeReply?
    coordinator.deliver(params, from: client, cancellation: cancellation) { reply = $0 }
    return { reply }
  }

  private func result(_ reply: OwlAgentBridgeReply?) throws -> Wire.DeliverResult {
    guard case .success(let value) = try XCTUnwrap(reply) else { throw Wire.ContractError.notJSON }
    return try Wire.decodeStrict(Wire.DeliverResult.self, from: value)
  }

  func testConfirmWritesOnceAndAReplayDoesNotWriteAgain() throws {
    let reply = start(params())
    XCTAssertEqual(preview.shown, ["grok-build: 你好"])
    XCTAssertEqual(preview.targets, ["TextEdit"])
    XCTAssertNil(reply(), "nothing is answered before the user decides")
    preview.decide?(true)
    XCTAssertEqual(try result(reply()), .init(requestId: "r1", status: .delivered(verified: true), replayed: false))
    XCTAssertEqual(host.target.writes, ["你好"])

    let again = start(params())
    XCTAssertEqual(try result(again()), .init(requestId: "r1", status: .delivered(verified: true), replayed: true))
    XCTAssertEqual(host.target.writes.count, 1)
    XCTAssertEqual(preview.shown.count, 1)
  }

  func testCancelWritesNothing() throws {
    let reply = start(params())
    preview.decide?(false)
    XCTAssertEqual(try result(reply()).status, .cancelled)
    XCTAssertTrue(host.target.writes.isEmpty)
  }

  func testNoDecisionExpiresAndALateClickCannotWrite() throws {
    let reply = start(params(timeout: 5_000))
    let decide = preview.decide
    host.fire(5)
    XCTAssertEqual(try result(reply()).status, .expired)
    XCTAssertGreaterThan(preview.dismissed, 0)
    decide?(true)
    XCTAssertTrue(host.target.writes.isEmpty)
  }

  func testTheDefaultWindowIsTwoMinutes() {
    _ = start(params())
    XCTAssertEqual(host.scheduled.map(\.0), [120])
  }

  func testAnotherRequestIsBusyAndTheSameOneWaitsForTheSameOutcome() throws {
    let first = start(params("r1"))
    let busy = start(params("r2"))
    guard case .failure(let error) = try XCTUnwrap(busy()) else { return XCTFail("expected delivery_busy") }
    XCTAssertEqual(error.code, .deliveryBusy)
    let retry = start(params("r1"))
    XCTAssertEqual(preview.shown.count, 1)
    preview.decide?(true)
    XCTAssertEqual(try result(first()).replayed, false)
    XCTAssertEqual(try result(retry()), .init(requestId: "r1", status: .delivered(verified: true), replayed: true))
    XCTAssertEqual(host.target.writes.count, 1)
  }

  func testUnreadableHostIsDeliveredUnverified() throws {
    host.target.outcome = .attemptedUnverified
    let reply = start(params())
    preview.decide?(true)
    XCTAssertEqual(try result(reply()).status, .delivered(verified: false))
  }

  func testNoInputSessionIsNoTarget() throws {
    host.bindResult = .failure(.noTarget)
    let reply = start(params())
    XCTAssertEqual(try result(reply()).status, .targetChanged(.noTarget))
    XCTAssertGreaterThan(preview.dismissed, 0)
  }

  func testSecureInputRefusesBeforeAndAtConfirmation() throws {
    host.isSecureInputEnabled = true
    XCTAssertEqual(try result(start(params("a"))()).status, .targetChanged(.secureInput))
    host.isSecureInputEnabled = false
    let later = start(params("b"))
    host.isSecureInputEnabled = true
    preview.decide?(true)
    XCTAssertEqual(try result(later()).status, .targetChanged(.secureInput))
    XCTAssertTrue(host.target.writes.isEmpty)
  }

  func testFocusMovingAwayFromTheBoundAppEndsTheRequest() throws {
    let reply = start(params())
    coordinator.applicationDidActivate(getpid())  // Owltype itself coming forward is not a change
    XCTAssertNil(reply())
    let decide = preview.decide
    coordinator.applicationDidActivate(300)
    XCTAssertGreaterThan(preview.dismissed, 0, "the preview closes at once")
    decide?(true)
    XCTAssertNil(reply(), "decided only once it is clear the app did not quit")
    host.fire(OwlAgentDeliveryCoordinator.leaveSettle)
    XCTAssertEqual(try result(reply()).status, .targetChanged(.focusChanged))
    XCTAssertTrue(host.target.writes.isEmpty)
  }

  /// 2026-10-29 live (agy, Stickies): quitting the bound app activated another app before the
  /// termination notice, so it was reported as a focus change.
  func testTheBoundAppQuittingAfterAnotherTookTheFront() throws {
    let reply = start(params())
    coordinator.applicationDidActivate(300)
    host.target.isTerminated = true
    coordinator.applicationDidTerminate(200)
    host.fire(OwlAgentDeliveryCoordinator.leaveSettle)
    XCTAssertEqual(try result(reply()).status, .targetChanged(.targetQuit))
  }

  func testTheBoundAppQuitting() throws {
    let reply = start(params())
    coordinator.applicationDidTerminate(200)
    XCTAssertEqual(try result(reply()).status, .targetChanged(.targetQuit))
  }

  func testInTheAgentsTerminalItWaitsForTheUserToSwitch() throws {
    host.frontmostProcess = 50  // the terminal running the agent
    let reply = start(params())
    XCTAssertEqual(preview.targets, [nil])
    preview.decide?(true)
    XCTAssertNil(reply(), "写入 does nothing before a target is bound")
    XCTAssertTrue(host.target.writes.isEmpty)

    host.frontmostProcess = 200
    coordinator.applicationDidActivate(200)
    host.fire(OwlAgentDeliveryCoordinator.bindPollInterval)
    XCTAssertEqual(preview.targets, [nil, nil, "TextEdit"], "the early click repeats the hint")
    preview.decide?(true)
    XCTAssertEqual(try result(reply()).status, .delivered(verified: true))
  }

  func testConfirmBindsWhenTheFieldWasFocusedAfterThePollsRanOut() throws {
    host.frontmostProcess = 50
    let reply = start(params())
    host.frontmostProcess = 200
    host.bindResult = .failure(.noTarget)
    coordinator.applicationDidActivate(200)
    for _ in 0...OwlAgentDeliveryCoordinator.bindPolls { host.fire(OwlAgentDeliveryCoordinator.bindPollInterval) }
    XCTAssertNil(reply(), "no input session yet: still waiting")
    host.bindResult = .success(host.target)
    preview.decide?(true)
    XCTAssertEqual(try result(reply()).status, .delivered(verified: true))
    XCTAssertEqual(host.target.writes, ["你好"])
  }

  func testAFieldFocusedLongAfterTheSwitchStillBinds() throws {
    host.frontmostProcess = 50
    let reply = start(params())
    host.frontmostProcess = 200
    host.bindResult = .failure(.noTarget)
    coordinator.applicationDidActivate(200)
    for _ in 0...OwlAgentDeliveryCoordinator.bindPolls { host.fire(OwlAgentDeliveryCoordinator.bindPollInterval) }
    for _ in 0..<20 { host.fire(OwlAgentDeliveryCoordinator.slowBindPollInterval) }
    XCTAssertEqual(preview.targets.last, .some(nil), "no field yet: 写入 stays disabled")
    host.bindResult = .success(host.target)
    host.fire(OwlAgentDeliveryCoordinator.slowBindPollInterval)
    XCTAssertEqual(preview.targets.last, "TextEdit", "the panel learns its target without another app switch")
    preview.decide?(true)
    XCTAssertEqual(try result(reply()).status, .delivered(verified: true))
    host.fire(OwlAgentDeliveryCoordinator.slowBindPollInterval)
    XCTAssertTrue(host.scheduled.filter { $0.0 == OwlAgentDeliveryCoordinator.slowBindPollInterval }.isEmpty, "polling stops once bound")
  }

  func testDisconnectCancelsAndTheOutcomeIsKeptForARetry() throws {
    let cancellation = OwlAgentBridgeCancellation()
    _ = start(params(), cancellation: cancellation)
    cancellation.cancel()
    let drained = expectation(description: "main")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
    XCTAssertFalse(coordinator.isWaiting)
    XCTAssertGreaterThan(preview.dismissed, 0)
    XCTAssertEqual(try result(start(params())()), .init(requestId: "r1", status: .cancelled, replayed: true))
  }

  func testStoredOutcomesExpire() throws {
    let reply = start(params())
    preview.decide?(true)
    _ = try result(reply())
    clock = clock.addingTimeInterval(OwlAgentDeliveryCoordinator.outcomeLifetime + 1)
    _ = start(params())
    XCTAssertEqual(preview.shown.count, 2, "an id past its lifetime is a new request")
  }

  func testEveryHostOutcomeMapsToAContractStatus() {
    typealias Coordinator = OwlAgentDeliveryCoordinator
    XCTAssertEqual(Coordinator.status(for: .confirmedWithCursor(.leftAtEnd), targetQuit: false), .delivered(verified: true))
    XCTAssertEqual(Coordinator.status(for: .originalPreservationUnverified, targetQuit: false), .delivered(verified: false))
    XCTAssertEqual(Coordinator.status(for: .notAttempted(.secureInput), targetQuit: false), .targetChanged(.secureInput))
    XCTAssertEqual(Coordinator.status(for: .notAttempted(.unverifiableTarget), targetQuit: false), .targetChanged(.unverifiableTarget))
    XCTAssertEqual(Coordinator.status(for: .notAttempted(.missingHost), targetQuit: true), .targetChanged(.targetQuit))
    XCTAssertEqual(Coordinator.status(for: .notAttempted(.missingHost), targetQuit: false), .targetChanged(.noTarget))
    XCTAssertEqual(Coordinator.status(for: .notAttempted(.focusNotRestored), targetQuit: false), .targetChanged(.focusChanged))
    XCTAssertEqual(Coordinator.status(for: .notAttempted(.targetChanged), targetQuit: false), .targetChanged(.focusChanged))
  }
}
