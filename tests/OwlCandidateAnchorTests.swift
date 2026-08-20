//
//  OwlCandidateAnchorTests.swift
//  OwltypeTests — candidate-anchor validation cascade (B3)
//
//  Locks the pure anchor validator that keeps the candidate panel / status HUD from flying to
//  the screen origin / wrong display when the IMK client hands back a junk caret rect. Covers:
//    1. Every `Reason` (.nullRect / .infiniteRect / .nonFiniteCoordinate / .zeroHeight /
//       .offscreen) and the accept case.
//    2. `resolve(fresh:previous:screens:)` three branches: usable fresh → usable previous → nil.
//
//  Pure CoreGraphics: fabricated rects + fake screen frames, no IMK client, no live NSScreen.
//

import CoreGraphics
import XCTest
@testable import Owltype

final class OwlCandidateAnchorTests: XCTestCase {

  // A single representative screen frame (origin at zero, 1920x1080).
  private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
  // A normal caret rect well inside that screen.
  private let goodRect = CGRect(x: 100, y: 200, width: 1, height: 18)

  private var screens: [CGRect] { [screen] }

  // MARK: rejectionReason — reject cases

  func testZeroRectIsRejected() {
    // CGRect.zero has zero height → caught by .zeroHeight before .nullRect/.offscreen matters.
    let reason = OwlCandidateAnchor.rejectionReason(.zero, screens: screens)
    XCTAssertNotNil(reason, "a .zero rect must be rejected")
  }

  func testNullRectIsRejected() {
    XCTAssertEqual(OwlCandidateAnchor.rejectionReason(.null, screens: screens), .nullRect)
  }

  func testInfiniteRectIsRejected() {
    XCTAssertEqual(OwlCandidateAnchor.rejectionReason(.infinite, screens: screens), .infiniteRect)
  }

  func testNonFiniteCoordinateIsRejected() {
    // A NaN coordinate survives CGRect.init as a real rect with a non-finite field.
    let nan = CGRect(x: CGFloat.nan, y: 200, width: 1, height: 18)
    XCTAssertEqual(OwlCandidateAnchor.rejectionReason(nan, screens: screens), .nonFiniteCoordinate)

    let nanH = CGRect(x: 100, y: 200, width: 1, height: CGFloat.nan)
    XCTAssertEqual(OwlCandidateAnchor.rejectionReason(nanH, screens: screens), .nonFiniteCoordinate)
  }

  func testInfiniteCoordinateCollapsesToNullRect() {
    // CoreGraphics behavior: CGRect.init with an ±infinity coordinate collapses the rect to the
    // null sentinel (isNull == true), so it is (correctly) rejected as .nullRect, never reaching
    // the .nonFiniteCoordinate branch. Either way it is rejected — the panel never uses it.
    let inf = CGRect(x: 100, y: CGFloat.infinity, width: 1, height: 18)
    XCTAssertTrue(inf.isNull, "sanity: CGRect collapses an infinite coordinate to .null")
    XCTAssertEqual(OwlCandidateAnchor.rejectionReason(inf, screens: screens), .nullRect)
  }

  func testNegativeOriginDisplayAcceptsAnchorOnThatDisplay() {
    let negativeScreen = CGRect(x: -1280, y: 0, width: 1280, height: 800)
    let rect = CGRect(x: -900, y: 400, width: 1, height: 18)
    XCTAssertNil(OwlCandidateAnchor.rejectionReason(rect, screens: [screen, negativeScreen]))
  }

  func testZeroHeightIsRejected() {
    let flat = CGRect(x: 100, y: 200, width: 1, height: 0)
    XCTAssertEqual(OwlCandidateAnchor.rejectionReason(flat, screens: screens), .zeroHeight)
  }

  func testHeightBelowMinimumIsRejected() {
    // Default minimumHeight is 1: a 0.5pt-high rect must be rejected as .zeroHeight.
    let sliver = CGRect(x: 100, y: 200, width: 1, height: 0.5)
    XCTAssertEqual(OwlCandidateAnchor.rejectionReason(sliver, screens: screens), .zeroHeight)
  }

  func testOffscreenOriginIsRejected() {
    // A finite, tall-enough rect whose origin sits on no screen.
    let off = CGRect(x: 5000, y: 5000, width: 1, height: 18)
    XCTAssertEqual(OwlCandidateAnchor.rejectionReason(off, screens: screens), .offscreen)
  }

  // MARK: rejectionReason — accept case

  func testGoodRectIsAccepted() {
    XCTAssertNil(OwlCandidateAnchor.rejectionReason(goodRect, screens: screens))
    XCTAssertTrue(OwlCandidateAnchor.isUsable(goodRect, screens: screens))
  }

  func testEmptyScreensRejectsEvenGoodRect() {
    // No screens supplied → the origin is contained by nothing → .offscreen.
    XCTAssertEqual(OwlCandidateAnchor.rejectionReason(goodRect, screens: []), .offscreen)
  }

  // MARK: resolve — three branches

  func testResolveReturnsFreshWhenUsable() {
    let previous = CGRect(x: 999, y: 999, width: 1, height: 18)
    let resolved = OwlCandidateAnchor.resolve(fresh: goodRect, previous: previous, screens: screens)
    XCTAssertEqual(resolved, goodRect, "a usable fresh anchor must be used unchanged")
  }

  func testResolveFallsBackToPreviousWhenFreshIsJunk() {
    let junk = CGRect.zero
    let previous = CGRect(x: 300, y: 400, width: 1, height: 18)
    let resolved = OwlCandidateAnchor.resolve(fresh: junk, previous: previous, screens: screens)
    XCTAssertEqual(resolved, previous, "a junk fresh anchor must fall back to a usable previous")
  }

  func testResolveReturnsNilWhenNeitherUsable() {
    let junk = CGRect.zero
    let badPrevious = CGRect(x: 5000, y: 5000, width: 1, height: 18) // offscreen
    let resolved = OwlCandidateAnchor.resolve(fresh: junk, previous: badPrevious, screens: screens)
    XCTAssertNil(resolved, "no usable fresh and no usable previous → nil (caller supplies safe default)")
  }

  func testResolveReturnsNilWhenNoPreviousAndJunkFresh() {
    let resolved = OwlCandidateAnchor.resolve(fresh: .zero, previous: nil, screens: screens)
    XCTAssertNil(resolved)
  }

  // MARK: resolve(candidates:) — ordered multi-candidate cascade (B4)

  func testResolveCandidatesReturnsFirstUsable() {
    // caret-end rect usable → it wins, the head rect is never considered.
    let caret = CGRect(x: 100, y: 200, width: 1, height: 18)
    let head = CGRect(x: 50, y: 800, width: 1, height: 18)
    let previous = CGRect(x: 999, y: 999, width: 1, height: 18)
    let resolved = OwlCandidateAnchor.resolve(candidates: [caret, head], previous: previous, screens: screens)
    XCTAssertEqual(resolved, caret, "the first usable candidate (caret-end) must win")
  }

  func testResolveCandidatesSkipsLeadingJunkToNextUsable() {
    // caret-end rect is junk (.zero) → skip to the usable head rect, NOT the stale previous.
    let head = CGRect(x: 50, y: 800, width: 1, height: 18)
    let previous = CGRect(x: 300, y: 400, width: 1, height: 18)
    let resolved = OwlCandidateAnchor.resolve(candidates: [.zero, head], previous: previous, screens: screens)
    XCTAssertEqual(resolved, head, "a leading junk candidate must be skipped to the next usable candidate")
  }

  func testResolveCandidatesFallsBackToPreviousWhenAllJunk() {
    // both candidates junk → fall back to a usable previous.
    let previous = CGRect(x: 300, y: 400, width: 1, height: 18)
    let offscreen = CGRect(x: 5000, y: 5000, width: 1, height: 18)
    let resolved = OwlCandidateAnchor.resolve(candidates: [.zero, offscreen], previous: previous, screens: screens)
    XCTAssertEqual(resolved, previous, "all-junk candidates must fall back to a usable previous")
  }

  func testResolveCandidatesReturnsNilWhenAllJunkAndNoUsablePrevious() {
    let offscreen = CGRect(x: 5000, y: 5000, width: 1, height: 18)
    XCTAssertNil(
      OwlCandidateAnchor.resolve(candidates: [.zero, offscreen], previous: nil, screens: screens),
      "all-junk candidates + no previous → nil (caller supplies safe default)"
    )
    XCTAssertNil(
      OwlCandidateAnchor.resolve(candidates: [.zero], previous: offscreen, screens: screens),
      "all-junk candidates + junk previous → nil"
    )
  }

  func testResolveCandidatesEmptyArrayUsesPrevious() {
    // No candidates supplied → behaves like "no usable fresh": fall back to previous.
    let previous = CGRect(x: 300, y: 400, width: 1, height: 18)
    XCTAssertEqual(OwlCandidateAnchor.resolve(candidates: [], previous: previous, screens: screens), previous)
    XCTAssertNil(OwlCandidateAnchor.resolve(candidates: [], previous: nil, screens: screens))
  }

  // MARK: shouldQueryCaret — Chromium/Electron deadlock guard (azooKey parity)

  func testZeroCandidatesSkipCaretQuery() {
    // 0 candidates → showPanel must NOT issue the synchronous client.attributes(forCharacterIndex:)
    // query (the azooKey deadlock vector); it bails before any client round-trip.
    XCTAssertFalse(OwlCandidateAnchor.shouldQueryCaret(candidateCount: 0))
  }

  func testNonEmptyCandidatesQueryCaret() {
    // At least one candidate → there is something to anchor, so the caret query proceeds as before.
    XCTAssertTrue(OwlCandidateAnchor.shouldQueryCaret(candidateCount: 1))
    XCTAssertTrue(OwlCandidateAnchor.shouldQueryCaret(candidateCount: 9))
  }

  // MARK: safeFallbackAnchor

  func testSafeFallbackAnchorUsesFirstScreenTopCenter() {
    let fallback = OwlCandidateAnchor.safeFallbackAnchor(screens: [screen])
    XCTAssertEqual(fallback, CGRect(x: 960, y: 810, width: 1, height: 18))
  }

  func testSafeFallbackAnchorHasDefaultWhenScreensAreMissing() {
    let fallback = OwlCandidateAnchor.safeFallbackAnchor(screens: [])
    XCTAssertEqual(fallback, CGRect(x: 640, y: 600, width: 1, height: 18))
  }
}
