//
//  OwlAgentDelivery.swift
//  Owltype
//
//  `deliver_text` (#208): an agent's text reaches a field only after the user confirms it in a
//  native preview, and then once. Main thread throughout.
//
//  - Binding: the request binds to the focused field of the frontmost application. When that
//    application is the agent's own host (the terminal running it, found through the helper's
//    parent processes), the preview asks the user to switch to the target and binds to the next
//    application that comes forward with an input session.
//  - After binding, the bound application losing the front or quitting ends the request
//    (`target_changed`) and closes the preview. So does secure input.
//  - `timeoutMs` without a decision ends it as `expired`; the preview closes, so a late click
//    cannot write.
//  - `requestId` is the idempotency key: a request already decided answers its stored outcome
//    with `replayed`; one still waiting gains another waiter. A different request while one is
//    waiting is `delivery_busy`. Every waiter gone (the helper disconnected) cancels it.
//  - Writing goes through OwlTemplateHostDelivery, which re-checks the bound field and never
//    presses Return.
//

import AppKit
import Foundation

/// A field bound for one delivery.
protocol OwlAgentDeliveryTarget: AnyObject {
  var processIdentifier: pid_t { get }
  var applicationName: String { get }
  var isTerminated: Bool { get }
  func write(_ text: String, completion: @escaping (OwlTemplateDeliveryOutcome) -> Void)
}

/// The App side the coordinator needs; tests replace it.
protocol OwlAgentDeliveryHost: AnyObject {
  var frontmostProcess: pid_t? { get }
  var isSecureInputEnabled: Bool { get }
  /// The focused field of the frontmost application, or why there is none.
  func bindFrontmost() -> Result<OwlAgentDeliveryTarget, OwlAgentBridgeProtocol.TargetChangedReason>
  /// The process and its parents, to recognise the agent's own terminal.
  func ancestors(of process: pid_t) -> Set<pid_t>
  func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void)
}

/// The native preview. `decide` is called at most once, with true for 写入.
protocol OwlAgentDeliveryPreview: AnyObject {
  func show(text: String, agentName: String, decide: @escaping (Bool) -> Void)
  func showTarget(_ name: String?)
  func dismiss()
}

final class OwlAgentDeliveryCoordinator {
  typealias Wire = OwlAgentBridgeProtocol
  typealias Reply = (OwlAgentBridgeReply) -> Void

  struct Constants: Decodable {
    let outcomeLifetime: TimeInterval
    let storedOutcomeLimit: Int
    let bindPolls: Int
    let bindPollInterval: TimeInterval
    let slowBindPollInterval: TimeInterval
    let leaveSettle: TimeInterval

    enum CodingKeys: String, CodingKey {
      case outcomeLifetime = "outcome_lifetime"
      case storedOutcomeLimit = "stored_outcome_limit"
      case bindPolls = "bind_polls"
      case bindPollInterval = "bind_poll_interval"
      case slowBindPollInterval = "slow_bind_poll_interval"
      case leaveSettle = "leave_settle"
    }
  }

  static let constants: Constants = OwlAppCore.required([
    "operation": "agent_rule",
    "rule": "delivery_constants",
    "args": [:]
  ])
  static var outcomeLifetime: TimeInterval { constants.outcomeLifetime }
  static var storedOutcomeLimit: Int { constants.storedOutcomeLimit }
  static var bindPolls: Int { constants.bindPolls }
  static var bindPollInterval: TimeInterval { constants.bindPollInterval }
  static var slowBindPollInterval: TimeInterval { constants.slowBindPollInterval }
  static var leaveSettle: TimeInterval { constants.leaveSettle }

  private struct ActionWire: Decodable {
    let action: String
    let text: String?
    let agentName: String?
    let name: String?
    let timeoutSeconds: Double?
    let intervalSeconds: Double?
    let seconds: Double?
    let targetPid: Int32?
    let waiterId: UInt64?
    let waiters: [UInt64]?
    let result: Wire.DeliverResult?
    let error: Wire.ErrorObject?

    enum CodingKeys: String, CodingKey {
      case action
      case text
      case agentName = "agent_name"
      case name
      case timeoutSeconds = "timeout_seconds"
      case intervalSeconds = "interval_seconds"
      case seconds
      case targetPid = "target_pid"
      case waiterId = "waiter_id"
      case waiters
      case result
      case error
    }
  }

  private let host: OwlAgentDeliveryHost
  private let makePreview: () -> OwlAgentDeliveryPreview
  private var preview: OwlAgentDeliveryPreview?
  private let now: () -> Date
  private let core: OwlAppSession

  private var currentTarget: OwlAgentDeliveryTarget?
  private var nextWaiterID: UInt64 = 1
  private var waiters: [UInt64: (reply: Reply, cancellation: OwlAgentBridgeCancellation)] = [:]

  init(host: OwlAgentDeliveryHost, preview: @escaping () -> OwlAgentDeliveryPreview, now: @escaping () -> Date = Date.init) {
    self.host = host
    self.makePreview = preview
    self.now = now
    do {
      self.core = try OwlAppSession("agentDelivery")
    } catch {
      preconditionFailure("Failed to initialize agent delivery session: \(error)")
    }
  }

  var isWaiting: Bool {
    core.call("is_waiting")
  }

  func deliver(_ params: Wire.DeliverParams, from client: OwlAgentBridgeClient,
               cancellation: OwlAgentBridgeCancellation, reply: @escaping Reply) {
    let waiterID = nextWaiterID
    nextWaiterID += 1
    waiters[waiterID] = (reply, cancellation)

    cancellation.onCancel { [weak self] in
      DispatchQueue.main.async {
        self?.cancelWaiter(waiterID)
      }
    }

    let initialBindPayload: [String: Any]
    let front = host.frontmostProcess
    let isAncestor = front.map { host.ancestors(of: client.processID).contains($0) } ?? false
    if !isAncestor && !host.isSecureInputEnabled {
      switch host.bindFrontmost() {
      case .success(let target):
        self.currentTarget = target
        initialBindPayload = ["Ok": [
          "process_id": target.processIdentifier,
          "application_name": target.applicationName,
          "is_terminated": target.isTerminated
        ]]
      case .failure(let reason):
        initialBindPayload = ["Err": reason.rawValue]
      }
    } else {
      initialBindPayload = ["Err": "no_target"]
    }

    let event: [String: Any] = [
      "event": "submit_request",
      "request_id": params.requestId,
      "text": params.text,
      "timeout_ms": params.timeoutMs as Any? ?? NSNull(),
      "agent_name": client.agentClient?.name ?? client.helper.name,
      "client_pid": client.processID,
      "ancestors": Array(host.ancestors(of: client.processID)),
      "frontmost_pid": host.frontmostProcess as Any? ?? NSNull(),
      "is_secure_input": host.isSecureInputEnabled,
      "initial_bind": initialBindPayload,
      "waiter_id": waiterID
    ]

    dispatch(event)
  }

  func applicationDidActivate(_ process: pid_t) {
    dispatch([
      "event": "application_activated",
      "process_id": process,
      "own_pid": getpid()
    ])
  }

  func applicationDidTerminate(_ process: pid_t) {
    dispatch([
      "event": "application_terminated",
      "process_id": process
    ])
  }

  private func handleUserDecision(_ confirmed: Bool) {
    let rebindPayload: [String: Any]
    if let front = host.frontmostProcess, !host.isSecureInputEnabled {
      switch host.bindFrontmost() {
      case .success(let target):
        self.currentTarget = target
        rebindPayload = ["Ok": [
          "process_id": target.processIdentifier,
          "application_name": target.applicationName,
          "is_terminated": target.isTerminated
        ]]
      case .failure(let reason):
        rebindPayload = ["Err": reason.rawValue]
      }
    } else {
      rebindPayload = ["Err": "no_target"]
    }

    dispatch([
      "event": "user_decision",
      "confirmed": confirmed,
      "frontmost_pid": host.frontmostProcess as Any? ?? NSNull(),
      "is_secure_input": host.isSecureInputEnabled,
      "rebind_if_needed": rebindPayload
    ])
  }

  private func handleTimeout() {
    dispatch(["event": "timeout_fired"])
  }

  private func handlePoll() {
    let bindPayload: [String: Any]
    if !host.isSecureInputEnabled {
      switch host.bindFrontmost() {
      case .success(let target):
        self.currentTarget = target
        bindPayload = ["Ok": [
          "process_id": target.processIdentifier,
          "application_name": target.applicationName,
          "is_terminated": target.isTerminated
        ]]
      case .failure(let reason):
        bindPayload = ["Err": reason.rawValue]
      }
    } else {
      bindPayload = ["Err": "secure_input"]
    }

    dispatch([
      "event": "poll_fired",
      "frontmost_pid": host.frontmostProcess as Any? ?? NSNull(),
      "bind_result": bindPayload
    ])
  }

  private func handleLeaveSettle() {
    dispatch([
      "event": "leave_settle_fired",
      "target_terminated": currentTarget?.isTerminated ?? true
    ])
  }

  private func handleWriteCompleted(outcomeCode: String, targetTerminated: Bool) {
    dispatch([
      "event": "host_write_completed",
      "outcome_code": outcomeCode,
      "target_terminated": targetTerminated
    ])
  }

  private func cancelWaiter(_ waiterID: UInt64) {
    dispatch([
      "event": "cancel_waiter",
      "waiter_id": waiterID
    ])
  }

  private func dispatch(_ event: [String: Any]) {
    let nowSecs = UInt64(now().timeIntervalSince1970)
    let actions: [ActionWire] = core.call("transition", [
      "event": event,
      "now_secs": nowSecs
    ])
    dispatchActions(actions)
  }

  private func dispatchActions(_ actions: [ActionWire]) {
    for action in actions {
      switch action.action {
      case "show_preview":
        let preview = makePreview()
        self.preview = preview
        preview.show(text: action.text ?? "", agentName: action.agentName ?? "") { [weak self] confirmed in
          self?.handleUserDecision(confirmed)
        }

      case "show_target":
        preview?.showTarget(action.name)

      case "dismiss_preview":
        preview?.dismiss()
        preview = nil

      case "schedule_timeout":
        guard let seconds = action.timeoutSeconds else { break }
        host.schedule(after: seconds) { [weak self] in
          self?.handleTimeout()
        }

      case "schedule_poll":
        guard let interval = action.intervalSeconds else { break }
        host.schedule(after: interval) { [weak self] in
          self?.handlePoll()
        }

      case "schedule_leave_settle":
        guard let seconds = action.seconds else { break }
        host.schedule(after: seconds) { [weak self] in
          self?.handleLeaveSettle()
        }

      case "perform_write":
        guard let text = action.text, let target = currentTarget else {
          handleWriteCompleted(outcomeCode: "missing_host", targetTerminated: true)
          break
        }
        target.write(text) { [weak self] outcome in
          let outcomeCode: String
          switch outcome {
          case .confirmed, .confirmedWithCursor: outcomeCode = "confirmed"
          case .attemptedUnverified, .originalPreservationUnverified: outcomeCode = "unverified"
          case .notAttempted(.secureInput): outcomeCode = "secure_input"
          case .notAttempted(.unverifiableTarget): outcomeCode = "unverifiable_target"
          case .notAttempted(.missingHost): outcomeCode = "missing_host"
          case .notAttempted(.focusNotRestored), .notAttempted(.targetChanged),
               .notAttempted(.originalNotPreserved), .notAttempted(.selectionNotPrepared):
            outcomeCode = "focus_changed"
          }
          self?.handleWriteCompleted(outcomeCode: outcomeCode, targetTerminated: target.isTerminated)
        }

      case "complete_waiter":
        guard let waiterID = action.waiterId, let result = action.result else { break }
        if let waiter = waiters.removeValue(forKey: waiterID), !waiter.cancellation.isCancelled {
          waiter.reply(.success(OwlJSONValue(encoding: result)))
        }

      case "complete_waiters":
        guard let waiterIDs = action.waiters, let result = action.result else { break }
        for id in waiterIDs {
          if let waiter = waiters.removeValue(forKey: id), !waiter.cancellation.isCancelled {
            waiter.reply(.success(OwlJSONValue(encoding: result)))
          }
        }

      case "reject_waiter":
        guard let waiterID = action.waiterId, let error = action.error else { break }
        if let waiter = waiters.removeValue(forKey: waiterID) {
          waiter.reply(.failure(error))
        }

      default:
        break
      }
    }
  }

  /// The contract's four statuses from the template delivery's outcome.
  static func status(for outcome: OwlTemplateDeliveryOutcome, targetQuit: Bool) -> Wire.DeliverStatus {
    let outcomeCode: String
    switch outcome {
    case .confirmed, .confirmedWithCursor: outcomeCode = "confirmed"
    case .attemptedUnverified, .originalPreservationUnverified: outcomeCode = "unverified"
    case .notAttempted(.secureInput): outcomeCode = "secure_input"
    case .notAttempted(.unverifiableTarget): outcomeCode = "unverifiable_target"
    case .notAttempted(.missingHost): outcomeCode = "missing_host"
    case .notAttempted(.focusNotRestored), .notAttempted(.targetChanged),
         .notAttempted(.originalNotPreserved), .notAttempted(.selectionNotPrepared):
      outcomeCode = "focus_changed"
    }
    struct OutcomeResult: Decodable {
      let name: String
      let verified: Bool?
      let reason: String?
    }
    let result: OutcomeResult = OwlAppCore.required([
      "operation": "agent_rule",
      "rule": "delivery_status_from_outcome",
      "args": ["outcome": outcomeCode, "target_quit": targetQuit]
    ])
    switch result.name {
    case "delivered":
      return .delivered(verified: result.verified ?? false)
    case "target_changed":
      let reasonRaw = result.reason ?? "focus_changed"
      return .targetChanged(Wire.TargetChangedReason(rawValue: reasonRaw) ?? .focusChanged)
    case "expired":
      return .expired
    default:
      return .cancelled
    }
  }
}
