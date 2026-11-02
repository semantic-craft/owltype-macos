//
//  OwlVoiceCapsuleHUDTests.swift
//  OwltypeTests — Lane B: Voice Capsule HUD Tests (#393)
//

import AppKit
import XCTest
@testable import Owltype

@MainActor
final class OwlVoiceCapsuleHUDTests: XCTestCase {

  func testNonActivatingPanelInvariants() {
    let panel = OwlVoiceCapsulePanel()
    XCTAssertFalse(panel.canBecomeKey, "Voice capsule panel must never become key window")
    XCTAssertFalse(panel.canBecomeMain, "Voice capsule panel must never become main window")
    XCTAssertEqual(panel.level, .floating, "Voice capsule panel must float above normal windows")
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "Style mask must include .nonactivatingPanel")
    XCTAssertTrue(panel.styleMask.contains(.borderless), "Style mask must be borderless")
    XCTAssertFalse(panel.isOpaque)
    XCTAssertEqual(panel.backgroundColor, .clear)
  }

  func testDualModePositioningWithCaret() {
    let panel = OwlVoiceCapsulePanel()
    let mockAnchor = NSRect(x: 300, y: 500, width: 2, height: 16)
    panel.present(state: .recording(level: 0.2, duration: 1.0, isHandsFreeLocked: false), anchor: mockAnchor)

    let frame = panel.frame
    XCTAssertGreaterThan(frame.width, 100)
    XCTAssertGreaterThan(frame.height, 30)
    // When caret is available, panel should be located relative to caret anchor
    XCTAssertTrue(panel.isVisible)
    panel.dismiss()
    XCTAssertFalse(panel.isVisible)
  }

  func testDualModePositioningFallbackWhenCaretIsZero() {
    let panel = OwlVoiceCapsulePanel()
    panel.present(state: .recognizing, anchor: .zero)

    let frame = panel.frame
    let mouseLoc = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero

    // Centered horizontally: midX ≈ visible.midX
    XCTAssertEqual(frame.midX, visible.midX, accuracy: 2.0)
    // Centered above bottom dock: minY ≈ visible.minY + 64
    XCTAssertEqual(frame.minY, visible.minY + 64, accuracy: 2.0)
    panel.dismiss()
  }

  func testCapsuleStateTransitions() {
    let panel = OwlVoiceCapsulePanel()
    XCTAssertEqual(panel.viewModel.state, .idle)

    // 1. Recording
    panel.present(state: .recording(level: 0.8, duration: 3.5, isHandsFreeLocked: true), anchor: .zero)
    XCTAssertEqual(panel.viewModel.state, .recording(level: 0.8, duration: 3.5, isHandsFreeLocked: true))

    // 2. Recognizing
    panel.present(state: .recognizing, anchor: .zero)
    XCTAssertEqual(panel.viewModel.state, .recognizing)

    // 3. Polishing
    panel.present(state: .polishing(rawTranscript: "今天天气"), anchor: .zero)
    XCTAssertEqual(panel.viewModel.state, .polishing(rawTranscript: "今天天气"))

    // 4. Completed
    panel.present(state: .completed(finalText: "今天天气很好"), anchor: .zero)
    XCTAssertEqual(panel.viewModel.state, .completed(finalText: "今天天气很好"))

    // 5. Failed
    panel.present(state: .failed("网络错误"), anchor: .zero)
    XCTAssertEqual(panel.viewModel.state, .failed("网络错误"))

    // 6. Dismiss
    panel.dismiss()
    XCTAssertEqual(panel.viewModel.state, .idle)
    XCTAssertFalse(panel.isVisible)
  }
}
