//
//  OwlFloatingPanelPositionerTests.swift
//  OwltypeTests — floating-panel placement geometry (C4)
//
//  Locks the pure screen math extracted from the candidate / quick-send / HUD / emoji panels:
//  below-caret placement with the Squirrel-faithful flip + clamp cascade (both `frame` and
//  `visibleFrame` modes) and centre-under-mouse. Fabricated screens, no live NSScreen.
//

import CoreGraphics
import XCTest
@testable import Owltype

final class OwlFloatingPanelPositionerTests: XCTestCase {
  private typealias Positioner = OwlFloatingPanelPositioner

  // A full-HD screen whose visible area trims 40pt (e.g. a menu bar) off the top edge.
  private let screen = Positioner.Screen(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1040))

  // MARK: belowCaret

  func testBelowCaretSitsUnderAnchor() {
    let r = Positioner.belowCaret(
      anchor: CGRect(x: 100, y: 500, width: 1, height: 18),
      size: CGSize(width: 200, height: 100),
      screens: [screen], useVisibleFrame: false)
    // y = anchorMinY - height - 6 = 500 - 106 = 394; x = anchorMinX
    XCTAssertEqual(r, CGRect(x: 100, y: 394, width: 200, height: 100))
  }

  func testBelowCaretClampsRightEdge() {
    let r = Positioner.belowCaret(
      anchor: CGRect(x: 1850, y: 500, width: 1, height: 18),
      size: CGSize(width: 200, height: 100),
      screens: [screen], useVisibleFrame: false)
    // x + width = 2050 > 1920 → x = 1920 - 200 - 6 = 1714
    XCTAssertEqual(r.minX, 1714)
    XCTAssertEqual(r.minY, 394)
  }

  func testBelowCaretFlipsAboveWhenOffTop() {
    let r = Positioner.belowCaret(
      anchor: CGRect(x: 100, y: 50, width: 1, height: 18),
      size: CGSize(width: 200, height: 100),
      screens: [screen], useVisibleFrame: false)
    // below y = 50 - 106 = -56 < 0 → flip: y = anchorMaxY + 6 = 68 + 6 = 74
    XCTAssertEqual(r.minY, 74)
  }

  func testBelowCaretFinalReclampKeepsTallPanelOnScreen() {
    // A panel taller than the screen (minus margins) would, after flip + bottom-clamp, land above
    // the top edge; the final re-clamp pulls it back on. This is the branch the HUD toast omits —
    // harmless there because a short toast never reaches it.
    let small = Positioner.Screen(
      frame: CGRect(x: 0, y: 0, width: 800, height: 200),
      visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 200))
    let r = Positioner.belowCaret(
      anchor: CGRect(x: 100, y: 150, width: 1, height: 18),
      size: CGSize(width: 200, height: 300),
      screens: [small], useVisibleFrame: false)
    XCTAssertEqual(r.minY, 6, "final re-clamp lands the over-tall panel 6pt from the top")
  }

  func testUseVisibleFrameClampsToVisibleArea() {
    // Anchor in the menu-bar band (y between visibleFrame top 1040 and frame top 1080): with the
    // full frame the panel fits, with the visibleFrame it must be pulled up. Proves the flag
    // selects the clamp bounds.
    let anchor = CGRect(x: 500, y: 1060, width: 1, height: 10)
    let size = CGSize(width: 100, height: 100)
    let full = Positioner.belowCaret(anchor: anchor, size: size, screens: [screen], useVisibleFrame: false)
    let vis  = Positioner.belowCaret(anchor: anchor, size: size, screens: [screen], useVisibleFrame: true)
    XCTAssertNotEqual(full.minY, vis.minY)
    XCTAssertLessThan(vis.minY, full.minY, "visibleFrame's lower maxY pulls the panel higher")
  }

  func testBelowCaretPicksScreenUnderAnchor() {
    let left  = Positioner.Screen(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let right = Positioner.Screen(frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000),
                                  visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 1000))
    let r = Positioner.belowCaret(anchor: CGRect(x: 1200, y: 500, width: 1, height: 18),
                                  size: CGSize(width: 100, height: 100),
                                  screens: [left, right], useVisibleFrame: false)
    // anchor on the right screen → x stays 1200 (fits); had it picked the left screen (maxX 1000)
    // x would clamp to 894.
    XCTAssertEqual(r.minX, 1200)
    XCTAssertEqual(r.minY, 394)
  }

  func testBelowCaretHandlesNegativeOriginExternalDisplay() {
    let primary = Positioner.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860))
    let left = Positioner.Screen(frame: CGRect(x: -1280, y: 0, width: 1280, height: 800),
                                 visibleFrame: CGRect(x: -1280, y: 0, width: 1280, height: 760))
    let r = Positioner.belowCaret(anchor: CGRect(x: -1200, y: 500, width: 1, height: 18),
                                  size: CGSize(width: 260, height: 120),
                                  screens: [primary, left], useVisibleFrame: false)
    XCTAssertEqual(r.minX, -1200)
    XCTAssertEqual(r.minY, 374)
    XCTAssertGreaterThanOrEqual(r.minX, left.frame.minX)
    XCTAssertLessThanOrEqual(r.maxX, left.frame.maxX)
  }

  func testBelowCaretClampsLeftEdge() {
    let r = Positioner.belowCaret(
      anchor: CGRect(x: -20, y: 500, width: 1, height: 18),
      size: CGSize(width: 200, height: 100),
      screens: [screen], useVisibleFrame: false)
    XCTAssertEqual(r.minX, 6)
  }

  func testBelowCaretKeepsOversizedPanelWithinBestEffortMargins() {
    let small = Positioner.Screen(
      frame: CGRect(x: 0, y: 0, width: 300, height: 220),
      visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 220))
    let r = Positioner.belowCaret(
      anchor: CGRect(x: 150, y: 110, width: 1, height: 18),
      size: CGSize(width: 500, height: 400),
      screens: [small], useVisibleFrame: false)
    XCTAssertEqual(r.minX, 6)
    XCTAssertEqual(r.minY, 6)
    XCTAssertEqual(r.width, 500)
    XCTAssertEqual(r.height, 400)
  }

  func testBelowCaretSupportsHorizontalAndVerticalCandidateShapes() {
    let anchor = CGRect(x: 700, y: 700, width: 1, height: 18)
    let horizontal = Positioner.belowCaret(
      anchor: anchor,
      size: CGSize(width: 520, height: 72),
      screens: [screen],
      useVisibleFrame: false)
    let vertical = Positioner.belowCaret(
      anchor: anchor,
      size: CGSize(width: 220, height: 360),
      screens: [screen],
      useVisibleFrame: false)
    XCTAssertEqual(horizontal.minX, 700)
    XCTAssertEqual(vertical.minX, 700)
    XCTAssertEqual(horizontal.minY, 622)
    XCTAssertEqual(vertical.minY, 334)
  }

  func testBelowCaretFallsBackToFirstScreenForOffscreenAnchor() {
    let r = Positioner.belowCaret(
      anchor: CGRect(x: 5000, y: 5000, width: 1, height: 18),
      size: CGSize(width: 220, height: 120),
      screens: [screen],
      useVisibleFrame: false)
    XCTAssertLessThanOrEqual(r.maxX, screen.frame.maxX)
    XCTAssertLessThanOrEqual(r.maxY, screen.frame.maxY)
  }

  // MARK: centeredUnder

  func testCenteredUnderCentresOnVisibleFrame() {
    let r = Positioner.centeredUnder(
      point: CGPoint(x: 500, y: 500),
      size: CGSize(width: 200, height: 100),
      screens: [screen])
    // centre of visibleFrame (0,0,1920,1040): x = 960 - 100 = 860, y = 520 - 50 = 470
    XCTAssertEqual(r, CGRect(x: 860, y: 470, width: 200, height: 100))
  }

  func testCenteredUnderReturnsNilWithoutScreens() {
    XCTAssertNil(Positioner.centeredUnder(point: .zero, size: CGSize(width: 10, height: 10), screens: []))
  }

  func testCenteredUnderPicksScreenUnderPoint() {
    let left  = Positioner.Screen(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let right = Positioner.Screen(frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000),
                                  visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 1000))
    let r = Positioner.centeredUnder(point: CGPoint(x: 1500, y: 500),
                                     size: CGSize(width: 100, height: 100), screens: [left, right])
    // centred on the right screen (visibleFrame midX 1500) → x = 1500 - 50 = 1450
    XCTAssertEqual(r?.minX, 1450)
  }
}
