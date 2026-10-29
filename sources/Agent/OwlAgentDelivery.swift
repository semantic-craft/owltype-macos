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

  static let outcomeLifetime: TimeInterval = 600
  static let storedOutcomeLimit = 256
  /// Polls for the newly activated application's input session while waiting for a target.
  static let bindPolls = 10
  static let bindPollInterval: TimeInterval = 0.2

  private final class Pending {
    let requestID: String
    let text: String
    var waiters: [(reply: Reply, cancellation: OwlAgentBridgeCancellation, replayed: Bool)] = []
    var target: OwlAgentDeliveryTarget?
    let ancestors: Set<pid_t>
    var decided = false
    var writing = false

    init(requestID: String, text: String, ancestors: Set<pid_t>) {
      self.requestID = requestID
      self.text = text
      self.ancestors = ancestors
    }
  }

  private let host: OwlAgentDeliveryHost
  private let makePreview: () -> OwlAgentDeliveryPreview
  private var preview: OwlAgentDeliveryPreview?
  private var pending: Pending?
  private var outcomes: [String: (status: Wire.DeliverStatus, at: Date)] = [:]
  private let now: () -> Date

  init(host: OwlAgentDeliveryHost, preview: @escaping () -> OwlAgentDeliveryPreview, now: @escaping () -> Date = Date.init) {
    self.host = host
    makePreview = preview
    self.now = now
  }

  var isWaiting: Bool { pending != nil }

  func deliver(_ params: Wire.DeliverParams, from client: OwlAgentBridgeClient,
               cancellation: OwlAgentBridgeCancellation, reply: @escaping Reply) {
    dropExpiredOutcomes()
    if let stored = outcomes[params.requestId] {
      return reply(.success(Self.encode(params.requestId, stored.status, replayed: true)))
    }
    if let pending {
      guard pending.requestID == params.requestId else {
        return reply(.failure(.init(code: .deliveryBusy, message: "Another deliver_text request is waiting for confirmation")))
      }
      return attach(pending, reply: reply, cancellation: cancellation, replayed: true)
    }

    let request = Pending(requestID: params.requestId, text: params.text, ancestors: host.ancestors(of: client.processID))
    pending = request
    attach(request, reply: reply, cancellation: cancellation, replayed: false)
    guard pending === request else { return }

    let preview = makePreview()
    self.preview = preview
    preview.show(text: params.text, agentName: client.agentClient?.name ?? client.helper.name) { [weak self, weak request] confirmed in
      guard let self, let request, self.pending === request else { return }
      if confirmed { self.write(request) } else { self.finish(request, .cancelled) }
    }
    host.schedule(after: Double(params.effectiveTimeoutMs) / 1000) { [weak self, weak request] in
      guard let self, let request, self.pending === request, !request.writing else { return }
      self.finish(request, .expired)
    }

    if let front = host.frontmostProcess, request.ancestors.contains(front) {
      preview.showTarget(nil)  // the agent's own terminal is in front: wait for the user to switch
    } else {
      bind(request)
    }
  }

  private func attach(_ request: Pending, reply: @escaping Reply, cancellation: OwlAgentBridgeCancellation, replayed: Bool) {
    request.waiters.append((reply, cancellation, replayed))
    cancellation.onCancel { [weak self, weak request] in
      DispatchQueue.main.async {
        guard let self, let request, self.pending === request, !request.writing else { return }
        if request.waiters.allSatisfy({ $0.cancellation.isCancelled }) { self.finish(request, .cancelled) }
      }
    }
  }

  private func bind(_ request: Pending) {
    if host.isSecureInputEnabled { return finish(request, .targetChanged(.secureInput)) }
    switch host.bindFrontmost() {
    case .success(let target):
      request.target = target
      preview?.showTarget(target.applicationName)
    case .failure(let reason):
      finish(request, .targetChanged(reason))
    }
  }

  /// NSWorkspace activation, forwarded by the production host.
  func applicationDidActivate(_ process: pid_t) {
    guard let request = pending, !request.decided else { return }
    if let target = request.target {
      if process != target.processIdentifier, process != getpid() { finish(request, .targetChanged(.focusChanged)) }
      return
    }
    guard !request.ancestors.contains(process), process != getpid() else { return }
    awaitInputSession(request, process: process, polls: Self.bindPolls)
  }

  /// The newly active application's input session appears after its activation; bind once it does.
  private func awaitInputSession(_ request: Pending, process: pid_t, polls: Int) {
    host.schedule(after: Self.bindPollInterval) { [weak self, weak request] in
      guard let self, let request, self.pending === request, request.target == nil,
            self.host.frontmostProcess == process else { return }
      if case .success = self.host.bindFrontmost() { return self.bind(request) }
      if polls > 0 { self.awaitInputSession(request, process: process, polls: polls - 1) }
    }
  }

  func applicationDidTerminate(_ process: pid_t) {
    guard let request = pending, let target = request.target, target.processIdentifier == process else { return }
    finish(request, .targetChanged(.targetQuit))
  }

  private func write(_ request: Pending) {
    guard !request.decided, !request.writing else { return }
    if request.target == nil {
      // The user may have focused the field after the binding polls ran out: try again now,
      // unless the agent's own terminal is still in front.
      if let front = host.frontmostProcess, !request.ancestors.contains(front) { bind(request) }
      guard request.target != nil else {
        if !request.decided { preview?.showTarget(nil) }
        return
      }
    }
    guard let target = request.target else { return }
    if target.isTerminated { return finish(request, .targetChanged(.targetQuit)) }
    if host.isSecureInputEnabled { return finish(request, .targetChanged(.secureInput)) }
    request.writing = true
    preview?.dismiss()
    preview = nil
    target.write(request.text) { [weak self, weak request, weak target] outcome in
      guard let self, let request else { return }
      self.finish(request, Self.status(for: outcome, targetQuit: target?.isTerminated ?? true))
    }
  }

  private func finish(_ request: Pending, _ status: Wire.DeliverStatus) {
    guard pending === request, !request.decided else { return }
    request.decided = true
    pending = nil
    preview?.dismiss()
    preview = nil
    outcomes[request.requestID] = (status, now())
    trimOutcomes()
    for waiter in request.waiters where !waiter.cancellation.isCancelled {
      waiter.reply(.success(Self.encode(request.requestID, status, replayed: waiter.replayed)))
    }
  }

  private func dropExpiredOutcomes() {
    let oldest = now().addingTimeInterval(-Self.outcomeLifetime)
    outcomes = outcomes.filter { $0.value.at >= oldest }
  }

  private func trimOutcomes() {
    guard outcomes.count > Self.storedOutcomeLimit else { return }
    for (key, _) in outcomes.sorted(by: { $0.value.at < $1.value.at }).prefix(outcomes.count - Self.storedOutcomeLimit) {
      outcomes[key] = nil
    }
  }

  static func encode(_ requestID: String, _ status: Wire.DeliverStatus, replayed: Bool) -> OwlJSONValue {
    OwlJSONValue(encoding: Wire.DeliverResult(requestId: requestID, status: status, replayed: replayed))
  }

  /// The contract's four statuses from the template delivery's outcome.
  static func status(for outcome: OwlTemplateDeliveryOutcome, targetQuit: Bool) -> Wire.DeliverStatus {
    switch outcome {
    case .confirmed, .confirmedWithCursor: return .delivered(verified: true)
    case .attemptedUnverified, .originalPreservationUnverified: return .delivered(verified: false)
    case .notAttempted(.secureInput): return .targetChanged(.secureInput)
    case .notAttempted(.unverifiableTarget): return .targetChanged(.unverifiableTarget)
    case .notAttempted(.missingHost): return .targetChanged(targetQuit ? .targetQuit : .noTarget)
    case .notAttempted(.focusNotRestored), .notAttempted(.targetChanged), .notAttempted(.originalNotPreserved):
      return .targetChanged(.focusChanged)
    }
  }
}
