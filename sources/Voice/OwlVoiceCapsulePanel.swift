//
//  OwlVoiceCapsulePanel.swift
//  Owltype — Voice Input Subsystem
//

import AppKit
import SwiftUI

@MainActor
class OwlVoiceCapsulePanel: NSPanel {
  static let shared = OwlVoiceCapsulePanel()

  let viewModel = OwlVoiceCapsuleViewModel()
  private var hostingView: NSHostingView<OwlVoiceCapsuleView>?

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let view = OwlVoiceCapsuleView(viewModel: viewModel)
    let hosting = NSHostingView(rootView: view)
    self.hostingView = hosting
    self.contentView = hosting
  }

  private var lastAnchor: NSRect = .zero

  func present(state: OwlVoiceCapsuleState, anchor: NSRect) {
    if anchor != .zero {
      lastAnchor = anchor
    }
    viewModel.state = state
    updateFrame(anchor: anchor)
    if !isVisible {
      orderFrontRegardless()
    }
  }

  func updateState(_ state: OwlVoiceCapsuleState, anchor: NSRect? = nil) {
    let effective = (anchor != nil && anchor != .zero) ? anchor! : lastAnchor
    present(state: state, anchor: effective)
  }

  func dismiss() {
    orderOut(nil)
    viewModel.state = .idle
    lastAnchor = .zero
  }

  func updatePosition(anchor: NSRect) {
    if anchor != .zero {
      lastAnchor = anchor
    }
    updateFrame(anchor: anchor)
  }

  func updateFrame(anchor: NSRect, animated: Bool = true) {
    hostingView?.layoutSubtreeIfNeeded()
    let size = hostingView?.fittingSize ?? NSSize(width: 280, height: 44)
    let targetFrame: NSRect
    let effectiveAnchor = (anchor != .zero) ? anchor : lastAnchor

    if effectiveAnchor != .zero {
      let screens = NSScreen.screens.map { OwlFloatingPanelPositioner.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
      targetFrame = OwlFloatingPanelPositioner.belowCaret(
        anchor: effectiveAnchor,
        size: size,
        screens: screens,
        useVisibleFrame: true
      )
    } else {
      let mouseLoc = NSEvent.mouseLocation
      let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) } ?? NSScreen.main
      let visible = screen?.visibleFrame ?? .zero
      targetFrame = NSRect(
        x: visible.midX - size.width / 2,
        y: visible.minY + 64,
        width: size.width,
        height: size.height
      )
    }

    if animated && isVisible && !OwlDefaults.isRunningUnitTests {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animator().setFrame(targetFrame, display: true)
      }
    } else {
      setFrame(targetFrame, display: true)
    }
    invalidateShadow()
  }
}
