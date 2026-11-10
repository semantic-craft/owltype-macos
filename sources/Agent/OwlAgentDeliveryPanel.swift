//
//  OwlAgentDeliveryPanel.swift
//  Owltype
//
//  The production side of `deliver_text`: the preview panel and the host it binds to.
//
//  The panel never becomes key and never activates Owltype, so the host keeps its focused field
//  and input session while the user reads the text; 写入 and 取消 take a first click. 写入 is
//  enabled only once a target is bound and the panel has been visible for a moment, so a click
//  meant for something else cannot confirm it.
//

import AppKit
import Darwin

final class OwlAgentDeliveryPanel: OwlFloatingPanel, OwlAgentDeliveryPreview {
  private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  }

  static let confirmDelay: TimeInterval = 0.6

  private let heading = NSTextField(labelWithString: "")
  private let target = NSTextField(labelWithString: "")
  private let textView = NSTextView()
  private let confirm = FirstClickButton(title: "写入", target: nil, action: nil)
  private let cancel = FirstClickButton(title: "取消", target: nil, action: nil)
  private var decide: ((Bool) -> Void)?
  private var hasTarget = false
  private var delayPassed = false

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
      styleMask: [.titled, .fullSizeContentView],
      transparentChrome: false
    )
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    heading.font = .boldSystemFont(ofSize: 13)
    heading.lineBreakMode = .byTruncatingTail
    target.font = .systemFont(ofSize: 12)
    target.textColor = .secondaryLabelColor
    textView.isEditable = false
    textView.isSelectable = false
    textView.drawsBackground = false
    textView.font = .systemFont(ofSize: 13)
    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    let note = NSTextField(wrappingLabelWithString: "确认后只写入一次，不会按回车。切换到其他应用会取消这次写入。")
    note.font = .systemFont(ofSize: 11)
    note.textColor = .secondaryLabelColor

    confirm.keyEquivalent = ""
    confirm.bezelStyle = .rounded
    cancel.bezelStyle = .rounded
    confirm.target = self
    confirm.action = #selector(confirmed)
    cancel.target = self
    cancel.action = #selector(cancelled)
    confirm.setAccessibilityIdentifier("agent-delivery-confirm")
    cancel.setAccessibilityIdentifier("agent-delivery-cancel")
    let buttons = NSStackView(views: [NSView(), cancel, confirm])
    buttons.orientation = .horizontal

    let stack = NSStackView(views: [heading, target, scroll, note, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 28, left: 16, bottom: 14, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false
    for view in [scroll, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
    let content = NSView()
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
    ])
    contentView = content
  }

  func show(text: String, agentName: String, decide: @escaping (Bool) -> Void) {
    self.decide = decide
    heading.stringValue = "\(agentName) 请求写入以下文字"
    textView.string = text
    hasTarget = false
    delayPassed = false
    updateConfirm()
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    if let visible = screen?.visibleFrame {
      setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 80))
    }
    orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmDelay) { [weak self] in
      self?.delayPassed = true
      self?.updateConfirm()
    }
  }

  func showTarget(_ name: String?) {
    hasTarget = name != nil
    target.stringValue = name.map { "将写入：\($0) 当前的输入框" } ?? "请切换到要写入的输入框，再点「写入」。"
    updateConfirm()
  }

  func dismiss() {
    decide = nil
    orderOut(nil)
  }

  private func updateConfirm() { confirm.isEnabled = hasTarget && delayPassed }

  @objc private func confirmed() {
    guard confirm.isEnabled, let decide else { return }
    self.decide = nil
    decide(true)
  }

  @objc private func cancelled() {
    guard let decide else { return }
    self.decide = nil
    decide(false)
  }
}

/// The frontmost application's focused field, written through OwlTemplateHostDelivery.
final class OwlAgentLiveDeliveryHost: OwlAgentDeliveryHost {
  private final class Target: OwlAgentDeliveryTarget {
    let application: NSRunningApplication
    let delivery: OwlTemplateHostDelivery

    init(application: NSRunningApplication, delivery: OwlTemplateHostDelivery) {
      self.application = application
      self.delivery = delivery
    }

    var processIdentifier: pid_t { application.processIdentifier }
    var applicationName: String { application.localizedName ?? application.bundleIdentifier ?? "当前应用" }
    var isTerminated: Bool { application.isTerminated }

    func write(_ text: String, completion: @escaping (OwlTemplateDeliveryOutcome) -> Void) {
      delivery.deliver(OwlAgentLiveDeliveryHost.deliveryResult(text), completion: completion)
    }
  }

  /// The caret ends after the text either way. Naming that offset makes the delivery capture the
  /// insertion origin and read back what it inserted, so a readable field reports verified.
  static func deliveryResult(_ text: String) -> OwlTemplateInvocation.Result {
    OwlTemplateInvocation.Result(text: text, cursorOffset: text.utf16.count)
  }

  private var observers: [NSObjectProtocol] = []

  /// Forwards activation and termination to `coordinator` for as long as this host lives.
  func observe(for coordinator: OwlAgentDeliveryCoordinator) {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak coordinator] notification in
      guard let coordinator, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      coordinator.applicationDidActivate(app.processIdentifier)
    })
    observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak coordinator] notification in
      guard let coordinator, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      coordinator.applicationDidTerminate(app.processIdentifier)
    })
  }

  deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

  var frontmostProcess: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

  var isSecureInputEnabled: Bool { OwlClientPrivacyState.current().isSecureInputEnabled }

  func bindFrontmost() -> Result<OwlAgentDeliveryTarget, OwlAgentBridgeProtocol.TargetChangedReason> {
    guard let application = NSWorkspace.shared.frontmostApplication,
          application.processIdentifier != getpid() else { return .failure(.noTarget) }
    guard let controller = NSApp.owlAppDelegate.runtime.activatedInputController, let client = controller.client,
          let bundle = client.bundleIdentifier(), bundle == application.bundleIdentifier else { return .failure(.noTarget) }
    let delivery = OwlTemplateHostDelivery(controller: controller, client: client)
    delivery.endImmediateDelivery()
    return .success(Target(application: application, delivery: delivery))
  }

  func ancestors(of process: pid_t) -> Set<pid_t> {
    var result: Set<pid_t> = []
    var current = process
    while current > 1, result.insert(current).inserted {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.size
      var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
      guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
      current = info.kp_eproc.e_ppid
    }
    return result
  }

  func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
  }
}
