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

  private struct ActionWire: Decodable {
    let action: String
    let invocationId: UInt64?
    let targetId: UInt64?
    let text: String?
    let agentName: String?
    let name: String?
    let timeoutSeconds: Double?
    let intervalSeconds: Double?
    let seconds: Double?
    let waiterId: UInt64?
    let result: Wire.DeliverResult?
    let error: Wire.ErrorObject?

    enum CodingKeys: String, CodingKey {
      case action
      case invocationId = "invocation_id"
      case targetId = "target_id"
      case text
      case agentName = "agent_name"
      case name
      case timeoutSeconds = "timeout_seconds"
      case intervalSeconds = "interval_seconds"
      case seconds
      case waiterId = "waiter_id"
      case result
      case error
    }
  }

  private struct BoundTarget {
    let invocationID: UInt64
    let targetID: UInt64
    let target: OwlAgentDeliveryTarget
  }

  private let host: OwlAgentDeliveryHost
  private let makePreview: () -> OwlAgentDeliveryPreview
  private let now: () -> Date
  private let core: OwlAppSession

  private var activeInvocationID: UInt64?
  private var activePreview: (invocationID: UInt64, preview: OwlAgentDeliveryPreview)?
  private var boundTarget: BoundTarget?
  private var nextTargetID: UInt64 = 1
  private var candidateTargets: [UInt64: OwlAgentDeliveryTarget] = [:]
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

  private func probeCandidateTarget() -> (payload: [String: Any], candidateID: UInt64?) {
    switch host.bindFrontmost() {
    case .success(let target):
      let targetID = nextTargetID
      nextTargetID += 1
      candidateTargets[targetID] = target
      return ([
        "Ok": [
          "target_id": targetID,
          "process_id": target.processIdentifier,
          "application_name": target.applicationName,
          "is_terminated": target.isTerminated
        ]
      ], targetID)
    case .failure(let reason):
      return (["Err": reason.rawValue], nil)
    }
  }

  func deliver(_ params: Wire.DeliverParams, from client: OwlAgentBridgeClient,
               cancellation: OwlAgentBridgeCancellation, reply: @escaping Reply) {
    guard !cancellation.isCancelled else { return }

    let waiterID = nextWaiterID
    nextWaiterID += 1
    waiters[waiterID] = (reply, cancellation)

    cancellation.onCancel { [weak self] in
      DispatchQueue.main.async {
        self?.cancelWaiter(waiterID)
      }
    }

    let initialBindProbe: (payload: [String: Any], candidateID: UInt64?)?
    let front = host.frontmostProcess
    let isAncestor = front.map { host.ancestors(of: client.processID).contains($0) } ?? false
    if activeInvocationID == nil && !isAncestor && !host.isSecureInputEnabled {
      initialBindProbe = probeCandidateTarget()
    } else {
      initialBindProbe = nil
    }
    defer {
      if let id = initialBindProbe?.candidateID {
        candidateTargets.removeValue(forKey: id)
      }
    }
    let initialBindPayload = initialBindProbe?.payload ?? ["Err": "no_target"]

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

  private func handleUserDecision(_ confirmed: Bool, invocationID: UInt64) {
    guard activeInvocationID == invocationID else { return }
    let rebindProbe: (payload: [String: Any], candidateID: UInt64?)?
    if confirmed && boundTarget == nil && host.frontmostProcess != nil && !host.isSecureInputEnabled {
      rebindProbe = probeCandidateTarget()
    } else {
      rebindProbe = nil
    }
    defer {
      if let id = rebindProbe?.candidateID {
        candidateTargets.removeValue(forKey: id)
      }
    }
    let rebindPayload = rebindProbe?.payload ?? ["Err": "no_target"]

    dispatch([
      "event": "user_decision",
      "invocation_id": invocationID,
      "confirmed": confirmed,
      "frontmost_pid": host.frontmostProcess as Any? ?? NSNull(),
      "is_secure_input": host.isSecureInputEnabled,
      "rebind_if_needed": rebindPayload
    ])
  }

  private func handleTimeout(_ invocationID: UInt64) {
    guard activeInvocationID == invocationID else { return }
    dispatch([
      "event": "timeout_fired",
      "invocation_id": invocationID
    ])
  }

  private func handlePoll(_ invocationID: UInt64) {
    guard activeInvocationID == invocationID, boundTarget == nil else { return }
    let bindProbe: (payload: [String: Any], candidateID: UInt64?)?
    if !host.isSecureInputEnabled {
      bindProbe = probeCandidateTarget()
    } else {
      bindProbe = nil
    }
    defer {
      if let id = bindProbe?.candidateID {
        candidateTargets.removeValue(forKey: id)
      }
    }
    let bindPayload = bindProbe?.payload ?? ["Err": "secure_input"]

    dispatch([
      "event": "poll_fired",
      "invocation_id": invocationID,
      "frontmost_pid": host.frontmostProcess as Any? ?? NSNull(),
      "bind_result": bindPayload
    ])
  }

  private func handleLeaveSettle(_ invocationID: UInt64) {
    guard let bound = boundTarget, bound.invocationID == invocationID else { return }
    dispatch([
      "event": "leave_settle_fired",
      "invocation_id": invocationID,
      "target_terminated": bound.target.isTerminated
    ])
  }

  private func handleWriteCompleted(invocationID: UInt64, outcomeCode: String, targetTerminated: Bool) {
    dispatch([
      "event": "host_write_completed",
      "invocation_id": invocationID,
      "outcome_code": outcomeCode,
      "target_terminated": targetTerminated
    ])
  }

  private func cancelWaiter(_ waiterID: UInt64) {
    waiters.removeValue(forKey: waiterID)
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
      dispatchSingleAction(action)
    }
  }

  private func dispatchSingleAction(_ action: ActionWire) {
    switch action.action {
    case "show_preview", "show_target", "dismiss_preview":
      dispatchPreviewAction(action)
    case "bind_target":
      dispatchBindTarget(action)
    case "schedule_timeout", "schedule_poll", "schedule_leave_settle":
      dispatchScheduleAction(action)
    case "perform_write":
      dispatchPerformWrite(action)
    case "finish_invocation":
      dispatchFinishInvocation(action)
    case "complete_waiter", "reject_waiter":
      dispatchWaiterAction(action)
    default:
      break
    }
  }

  private func dispatchBindTarget(_ action: ActionWire) {
    guard let invID = action.invocationId,
          let targetID = action.targetId,
          activeInvocationID == nil || activeInvocationID == invID,
          let target = candidateTargets[targetID] else { return }
    activeInvocationID = invID
    boundTarget = BoundTarget(invocationID: invID, targetID: targetID, target: target)
  }

  private func dispatchPreviewAction(_ action: ActionWire) {
    switch action.action {
    case "show_preview":
      guard let invID = action.invocationId else { return }
      activeInvocationID = invID
      let preview = makePreview()
      activePreview = (invID, preview)
      preview.show(text: action.text ?? "", agentName: action.agentName ?? "") { [weak self] confirmed in
        self?.handleUserDecision(confirmed, invocationID: invID)
      }
    case "show_target":
      guard let invID = action.invocationId,
            let active = activePreview,
            active.invocationID == invID else { return }
      active.preview.showTarget(action.name)
    case "dismiss_preview":
      guard let invID = action.invocationId,
            let active = activePreview,
            active.invocationID == invID else { return }
      let preview = active.preview
      activePreview = nil
      preview.dismiss()
    default:
      break
    }
  }

  private func dispatchScheduleAction(_ action: ActionWire) {
    switch action.action {
    case "schedule_timeout":
      guard let invID = action.invocationId, let seconds = action.timeoutSeconds else { return }
      host.schedule(after: seconds) { [weak self] in self?.handleTimeout(invID) }
    case "schedule_poll":
      guard let invID = action.invocationId, let interval = action.intervalSeconds else { return }
      host.schedule(after: interval) { [weak self] in self?.handlePoll(invID) }
    case "schedule_leave_settle":
      guard let invID = action.invocationId, let seconds = action.seconds else { return }
      host.schedule(after: seconds) { [weak self] in self?.handleLeaveSettle(invID) }
    default:
      break
    }
  }

  private func dispatchPerformWrite(_ action: ActionWire) {
    guard let invID = action.invocationId else { return }
    guard let targetID = action.targetId,
          let text = action.text,
          let bound = boundTarget,
          bound.invocationID == invID,
          bound.targetID == targetID else {
      handleWriteCompleted(
        invocationID: invID,
        outcomeCode: "missing_host",
        targetTerminated: boundTarget?.target.isTerminated ?? false
      )
      return
    }
    let target = bound.target
    target.write(text) { [weak self] outcome in
      let code = Self.outcomeCode(for: outcome)
      self?.handleWriteCompleted(invocationID: invID, outcomeCode: code, targetTerminated: target.isTerminated)
    }
  }

  private func dispatchFinishInvocation(_ action: ActionWire) {
    guard let invID = action.invocationId else { return }
    if let active = activePreview, active.invocationID == invID {
      let preview = active.preview
      activePreview = nil
      preview.dismiss()
    }
    if boundTarget?.invocationID == invID {
      boundTarget = nil
    }
    if activeInvocationID == invID {
      activeInvocationID = nil
    }
  }

  private func dispatchWaiterAction(_ action: ActionWire) {
    switch action.action {
    case "complete_waiter":
      guard let waiterID = action.waiterId, let result = action.result else { return }
      if let waiter = waiters.removeValue(forKey: waiterID), !waiter.cancellation.isCancelled {
        waiter.reply(.success(OwlJSONValue(encoding: result)))
      }
    case "reject_waiter":
      guard let waiterID = action.waiterId, let error = action.error else { return }
      if let waiter = waiters.removeValue(forKey: waiterID) {
        waiter.reply(.failure(error))
      }
    default:
      break
    }
  }

  static func outcomeCode(for outcome: OwlTemplateDeliveryOutcome) -> String {
    switch outcome {
    case .confirmed, .confirmedWithCursor:
      return "confirmed"
    case .attemptedUnverified, .originalPreservationUnverified:
      return "unverified"
    case .notAttempted(.secureInput):
      return "secure_input"
    case .notAttempted(.unverifiableTarget):
      return "unverifiable_target"
    case .notAttempted(.missingHost):
      return "missing_host"
    case .notAttempted(.focusNotRestored), .notAttempted(.targetChanged),
         .notAttempted(.originalNotPreserved), .notAttempted(.selectionNotPrepared):
      return "focus_changed"
    }
  }
}
