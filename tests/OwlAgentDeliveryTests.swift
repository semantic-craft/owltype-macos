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
  var deferCompletion = false
  var completions: [(OwlTemplateDeliveryOutcome) -> Void] = []

  init(_ process: pid_t) { processIdentifier = process }

  func write(_ text: String, completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
    writes.append(text)
    if deferCompletion {
      completions.append(completion)
    } else {
      completion(outcome)
    }
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
  var onShow: (() -> Void)?

  func show(text: String, agentName: String, decide: @escaping (Bool) -> Void) {
    shown.append("\(agentName): \(text)")
    self.decide = decide
    onShow?()
  }
  func showTarget(_ name: String?) { targets.append(name) }
  func dismiss() { dismissed += 1 }
}

final class OwlAgentDeliveryTests: XCTestCase {
  private enum Timing {
    static let outcomeLifetime: TimeInterval = 600
    static let bindPolls = 10
    static let bindPollInterval: TimeInterval = 0.2
    static let slowBindPollInterval: TimeInterval = 0.5
    static let leaveSettle: TimeInterval = 0.5
  }

  private enum TestDeliveryError: Error {
    case unexpectedReply
  }

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
    guard case .success(let value) = try XCTUnwrap(reply) else { throw TestDeliveryError.unexpectedReply }
    return try Wire.decodeStrict(Wire.DeliverResult.self, from: value)
  }

  private func assertResult(
    _ reply: OwlAgentBridgeReply?,
    requestId: String,
    status: Wire.DeliverStatus,
    replayed: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let actual = try result(reply)
    XCTAssertEqual(actual.requestId, requestId, file: file, line: line)
    XCTAssertEqual(actual.status, status, file: file, line: line)
    XCTAssertEqual(actual.replayed, replayed, file: file, line: line)
  }

  private func assertBusy(file: StaticString = #filePath, line: UInt = #line) throws {
    let probe = start(params("busy-probe-\(UUID().uuidString)", text: "probe"))
    guard case .failure(let error) = try XCTUnwrap(probe(), file: file, line: line) else {
      return XCTFail("expected delivery_busy", file: file, line: line)
    }
    XCTAssertEqual(error.code, .deliveryBusy, file: file, line: line)
  }

  func testConfirmWritesOnceAndAReplayDoesNotWriteAgain() throws {
    let reply = start(params())
    XCTAssertEqual(preview.shown, ["grok-build: 你好"])
    XCTAssertEqual(preview.targets, ["TextEdit"])
    XCTAssertNil(reply(), "nothing is answered before the user decides")
    preview.decide?(true)
    try assertResult(reply(), requestId: "r1", status: .delivered(verified: true), replayed: false)
    XCTAssertEqual(host.target.writes, ["你好"])

    let again = start(params())
    try assertResult(again(), requestId: "r1", status: .delivered(verified: true), replayed: true)
    XCTAssertEqual(host.target.writes.count, 1)
    XCTAssertEqual(preview.shown.count, 1)
  }

  func testCancelWritesNothing() throws {
    let reply = start(params())
    preview.decide?(false)
    XCTAssertEqual(try result(reply()).status, .cancelled)
    XCTAssertTrue(host.target.writes.isEmpty)
  }

  func testConfirmationKeepsTheOriginallyBoundFieldInTheSameApp() throws {
    let reply = start(params())
    let otherField = FakeTarget(host.target.processIdentifier)
    host.bindResult = .success(otherField)

    preview.decide?(true)

    try assertResult(reply(), requestId: "r1", status: .delivered(verified: true), replayed: false)
    XCTAssertEqual(host.target.writes, ["你好"])
    XCTAssertTrue(otherField.writes.isEmpty)
  }

  func testBusyRequestCannotReplaceTheActiveRequestsBoundField() throws {
    let active = start(params("active"))
    let otherField = FakeTarget(host.target.processIdentifier)
    host.bindResult = .success(otherField)
    let busy = start(params("busy", text: "other"))
    guard case .failure(let error) = try XCTUnwrap(busy()) else { return XCTFail("expected delivery_busy") }
    XCTAssertEqual(error.code, .deliveryBusy)
    host.bindResult = .failure(.noTarget)

    preview.decide?(true)

    try assertResult(active(), requestId: "active", status: .delivered(verified: true), replayed: false)
    XCTAssertEqual(host.target.writes, ["你好"])
    XCTAssertTrue(otherField.writes.isEmpty)
  }

  func testReplayedRequestCannotReplaceTheActiveRequestsBoundField() throws {
    let completed = start(params("completed"))
    preview.decide?(false)
    XCTAssertEqual(try result(completed()).status, .cancelled)
    let active = start(params("active"))
    let otherField = FakeTarget(host.target.processIdentifier)
    host.bindResult = .success(otherField)
    let replay = start(params("completed"))
    try assertResult(replay(), requestId: "completed", status: .cancelled, replayed: true)
    host.bindResult = .failure(.noTarget)

    preview.decide?(true)

    try assertResult(active(), requestId: "active", status: .delivered(verified: true), replayed: false)
    XCTAssertEqual(host.target.writes, ["你好"])
    XCTAssertTrue(otherField.writes.isEmpty)
  }

  func testCompletedRequestsTimeoutCannotExpireTheNextRequest() throws {
    let first = start(params("first", timeout: 5_000))
    preview.decide?(false)
    XCTAssertEqual(try result(first()).status, .cancelled)
    let next = start(params("next", text: "next", timeout: 120_000))

    host.fire(5)

    XCTAssertNil(next())
    try assertBusy()
    XCTAssertTrue(host.target.writes.isEmpty)
    preview.decide?(true)
    try assertResult(next(), requestId: "next", status: .delivered(verified: true), replayed: false)
    XCTAssertEqual(host.target.writes, ["next"])
  }

  func testExpiredRequestsPreviewCannotConfirmTheNextRequest() throws {
    let first = start(params("first", timeout: 5_000))
    let oldDecision = try XCTUnwrap(preview.decide)
    host.fire(5)
    XCTAssertEqual(try result(first()).status, .expired)
    let next = start(params("next", text: "next"))

    oldDecision(true)

    XCTAssertNil(next())
    try assertBusy()
    XCTAssertTrue(host.target.writes.isEmpty)
    preview.decide?(true)
    try assertResult(next(), requestId: "next", status: .delivered(verified: true), replayed: false)
    XCTAssertEqual(host.target.writes, ["next"])
  }

  func testCompletedRequestsHostReceiptCannotCompleteTheNextWrite() throws {
    host.target.deferCompletion = true
    let first = start(params("first", text: "first"))
    preview.decide?(true)
    let oldCompletion = try XCTUnwrap(host.target.completions.first)
    host.target.isTerminated = true
    coordinator.applicationDidTerminate(host.target.processIdentifier)
    XCTAssertEqual(try result(first()).status, .targetChanged(.targetQuit))

    let nextTarget = FakeTarget(300)
    nextTarget.deferCompletion = true
    host.frontmostProcess = nextTarget.processIdentifier
    host.bindResult = .success(nextTarget)
    let next = start(params("next", text: "next"))
    preview.decide?(true)
    let nextCompletion = try XCTUnwrap(nextTarget.completions.first)

    oldCompletion(.confirmed)

    XCTAssertNil(next())
    try assertBusy()
    XCTAssertEqual(host.target.writes, ["first"])
    XCTAssertEqual(nextTarget.writes, ["next"])
    nextCompletion(.attemptedUnverified)
    try assertResult(next(), requestId: "next", status: .delivered(verified: false), replayed: false)
    XCTAssertEqual(nextTarget.writes, ["next"])
    XCTAssertNil(start(params("after-idle", text: "ok"))(), "coordinator should accept a new request once idle")
  }

  func testChainedDeliveryInsideWaiterReplyKeepsHostBinding() throws {
    var firstReply: OwlAgentBridgeReply?
    var secondReply: (() -> OwlAgentBridgeReply?)?
    coordinator.deliver(params("first", text: "first"), from: client, cancellation: .init()) { [unowned self] reply in
      firstReply = reply
      secondReply = self.start(self.params("second", text: "second"))
    }
    preview.decide?(true)

    try assertResult(firstReply, requestId: "first", status: .delivered(verified: true), replayed: false)
    let secondBox = try XCTUnwrap(secondReply)
    XCTAssertNil(secondBox())
    try assertBusy()
    XCTAssertEqual(preview.shown, ["grok-build: first", "grok-build: second"])
    XCTAssertEqual(host.target.writes, ["first"])

    preview.decide?(true)
    try assertResult(secondBox(), requestId: "second", status: .delivered(verified: true), replayed: false)
    XCTAssertEqual(host.target.writes, ["first", "second"])
    XCTAssertNil(start(params("after-idle", text: "ok"))(), "coordinator should accept a new request once idle")
  }

  func testCancelledWaiterReleasesReplyClosureAndPreCancelledDeliverIsIgnored() throws {
    final class ReplyToken {}
    weak var weakCancellation: OwlAgentBridgeCancellation?
    weak var weakToken: ReplyToken?
    var secondReply: OwlAgentBridgeReply?
    let keepAliveCancellation = OwlAgentBridgeCancellation()

    do {
      let cancellation1 = OwlAgentBridgeCancellation()
      let token = ReplyToken()
      weakCancellation = cancellation1
      weakToken = token
      coordinator.deliver(params("r1"), from: client, cancellation: cancellation1) { _ in
        _ = token
      }
      coordinator.deliver(params("r1"), from: client, cancellation: keepAliveCancellation) { secondReply = $0 }
      cancellation1.cancel()
    }

    let drained = expectation(description: "main")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)

    XCTAssertNil(weakCancellation)
    XCTAssertNil(weakToken)
    try assertBusy()
    preview.decide?(true)
    try assertResult(secondReply, requestId: "r1", status: .delivered(verified: true), replayed: true)
    XCTAssertEqual(host.target.writes, ["你好"])

    let preCancelled = OwlAgentBridgeCancellation()
    preCancelled.cancel()
    var preCancelledCalled = false
    coordinator.deliver(params("precancel"), from: client, cancellation: preCancelled) { _ in
      preCancelledCalled = true
    }
    let drainedPre = expectation(description: "main-precancel")
    DispatchQueue.main.async { drainedPre.fulfill() }
    wait(for: [drainedPre], timeout: 2)

    XCTAssertFalse(preCancelledCalled)
    XCTAssertEqual(preview.shown.count, 1)

    let fresh = start(params("precancel", text: "fresh"))
    XCTAssertNil(fresh())
    try assertBusy()
    preview.decide?(true)
    try assertResult(fresh(), requestId: "precancel", status: .delivered(verified: true), replayed: false)
    XCTAssertEqual(host.target.writes, ["你好", "fresh"])
  }

  func testReentrantDispatchDuringPreviewShowPreservesInitialBindTarget() throws {
    preview.onShow = { [unowned self] in
      self.coordinator.applicationDidActivate(getpid())
    }
    let reply = start(params("reentrant", text: "hello"))
    preview.decide?(true)

    try assertResult(reply(), requestId: "reentrant", status: .delivered(verified: true), replayed: false)
    XCTAssertEqual(host.target.writes, ["hello"])
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
    try assertResult(retry(), requestId: "r1", status: .delivered(verified: true), replayed: true)
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
    host.fire(Timing.leaveSettle)
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
    host.fire(Timing.leaveSettle)
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
    host.fire(Timing.bindPollInterval)
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
    for _ in 0...Timing.bindPolls { host.fire(Timing.bindPollInterval) }
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
    for _ in 0...Timing.bindPolls { host.fire(Timing.bindPollInterval) }
    for _ in 0..<20 { host.fire(Timing.slowBindPollInterval) }
    XCTAssertEqual(preview.targets.last, .some(nil), "no field yet: 写入 stays disabled")
    host.bindResult = .success(host.target)
    host.fire(Timing.slowBindPollInterval)
    XCTAssertEqual(preview.targets.last, "TextEdit", "the panel learns its target without another app switch")
    preview.decide?(true)
    XCTAssertEqual(try result(reply()).status, .delivered(verified: true))
    host.fire(Timing.slowBindPollInterval)
    XCTAssertTrue(host.scheduled.filter { $0.0 == Timing.slowBindPollInterval }.isEmpty, "polling stops once bound")
  }

  func testDisconnectCancelsAndTheOutcomeIsKeptForARetry() throws {
    let cancellation = OwlAgentBridgeCancellation()
    _ = start(params(), cancellation: cancellation)
    cancellation.cancel()
    let drained = expectation(description: "main")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
    XCTAssertGreaterThan(preview.dismissed, 0)
    try assertResult(start(params())(), requestId: "r1", status: .cancelled, replayed: true)
    XCTAssertNil(start(params("after-disconnect", text: "ok"))(), "cancelled request must leave coordinator idle")
  }

  func testStoredOutcomesExpire() throws {
    let reply = start(params())
    preview.decide?(true)
    _ = try result(reply())
    clock = clock.addingTimeInterval(Timing.outcomeLifetime + 1)
    _ = start(params())
    XCTAssertEqual(preview.shown.count, 2, "an id past its lifetime is a new request")
  }

  func testEveryHostOutcomeMapsToAContractStatus() throws {
    let cases: [(OwlTemplateDeliveryOutcome, Bool, Wire.DeliverStatus)] = [
      (.confirmedWithCursor(.leftAtEnd), false, .delivered(verified: true)),
      (.originalPreservationUnverified, false, .delivered(verified: false)),
      (.notAttempted(.secureInput), false, .targetChanged(.secureInput)),
      (.notAttempted(.unverifiableTarget), false, .targetChanged(.unverifiableTarget)),
      (.notAttempted(.missingHost), true, .targetChanged(.targetQuit)),
      (.notAttempted(.missingHost), false, .targetChanged(.noTarget)),
      (.notAttempted(.focusNotRestored), false, .targetChanged(.focusChanged)),
      (.notAttempted(.targetChanged), false, .targetChanged(.focusChanged)),
    ]
    for (index, item) in cases.enumerated() {
      host.target.outcome = item.0
      host.target.isTerminated = item.1
      let reply = start(params("outcome-\(index)"))
      preview.decide?(true)
      XCTAssertEqual(try result(reply()).status, item.2)
    }
  }
}
