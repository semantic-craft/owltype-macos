//
//  OwlLaneTasksTests.swift
//  OwltypeTests — per-lane AI task supervisor (B8)
//
//  Proves, with NO librime, NO network, NO real Keychain, that `OwlLaneTasks` supervises one
//  in-flight task per lane: a second `run` on the SAME lane cancels the first (the first op
//  observes `Task.isCancelled` / throws `CancellationError`); a `run` on a DIFFERENT lane does
//  NOT cancel; `cancel(lane)` cancels one lane; `cancelAll()` cancels all.
//

import Foundation
import XCTest
@testable import Owltype

// MARK: - Tests

@MainActor
final class OwlLaneTasksTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    OwlCloudPreferences.resetForTesting()
    OwlSnapshotRegistry.shared.update(nil)
  }

  override func tearDown() async throws {
    OwlCloudPreferences.resetForTesting()
    OwlSnapshotRegistry.shared.update(nil)
    try await super.tearDown()
  }

  // MARK: 1. Supervisor — per-lane cancellation

  /// A second `run` on the SAME lane cancels the first; the first op observes the cancellation.
  func testSecondRunSameLaneCancelsFirst() async {
    let tasks = OwlLaneTasks()
    let firstObservedCancel = expectation(description: "first cloud op observes cancellation")
    let firstStarted = expectation(description: "first cloud op started")

    tasks.run(.cloud) {
      firstStarted.fulfill()
      do {
        // A long suspension that throws CancellationError when the task is cancelled.
        try await Task.sleep(nanoseconds: 5_000_000_000)
        XCTFail("the first cloud op should have been cancelled before completing")
      } catch {
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(Task.isCancelled)
        firstObservedCancel.fulfill()
      }
    }
    await fulfillment(of: [firstStarted], timeout: 2.0)

    // Supersede on the SAME lane → cancels the first.
    tasks.run(.cloud) { }
    await fulfillment(of: [firstObservedCancel], timeout: 2.0)
  }

  /// A `run` on a DIFFERENT lane does NOT cancel the first.
  func testRunDifferentLaneDoesNotCancel() async {
    let tasks = OwlLaneTasks()
    let cloudStarted = expectation(description: "cloud op started")
    let cloudFinished = expectation(description: "cloud op finished without cancellation")

    tasks.run(.cloud) {
      cloudStarted.fulfill()
      do {
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(Task.isCancelled, "a different-lane run must not cancel the cloud op")
        cloudFinished.fulfill()
      } catch {
        XCTFail("the cloud op must not be cancelled by a different-lane run: \(error)")
      }
    }
    await fulfillment(of: [cloudStarted], timeout: 2.0)

    // Run on a DIFFERENT lane while cloud is in flight — must leave cloud alone.
    tasks.run(.polish) { }
    await fulfillment(of: [cloudFinished], timeout: 2.0)
  }

  /// `cancel(lane)` cancels exactly that one lane.
  func testCancelOneLane() async {
    let tasks = OwlLaneTasks()
    let started = expectation(description: "polish op started")
    let cancelled = expectation(description: "polish op observed cancellation")

    tasks.run(.polish) {
      started.fulfill()
      do {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        XCTFail("the polish op should have been cancelled")
      } catch {
        XCTAssertTrue(Task.isCancelled)
        cancelled.fulfill()
      }
    }
    await fulfillment(of: [started], timeout: 2.0)

    tasks.cancel(.polish)
    await fulfillment(of: [cancelled], timeout: 2.0)
  }

  /// `cancelAll()` cancels every in-flight lane.
  func testCancelAllCancelsAllLanes() async {
    let tasks = OwlLaneTasks()
    let cloudStarted = expectation(description: "cloud started")
    let polishStarted = expectation(description: "polish started")
    let cloudCancelled = expectation(description: "cloud cancelled")
    let polishCancelled = expectation(description: "polish cancelled")

    tasks.run(.cloud) {
      cloudStarted.fulfill()
      do { try await Task.sleep(nanoseconds: 5_000_000_000); XCTFail("cloud not cancelled") }
      catch { XCTAssertTrue(Task.isCancelled); cloudCancelled.fulfill() }
    }
    tasks.run(.polish) {
      polishStarted.fulfill()
      do { try await Task.sleep(nanoseconds: 5_000_000_000); XCTFail("polish not cancelled") }
      catch { XCTAssertTrue(Task.isCancelled); polishCancelled.fulfill() }
    }
    await fulfillment(of: [cloudStarted, polishStarted], timeout: 2.0)

    tasks.cancelAll()
    await fulfillment(of: [cloudCancelled, polishCancelled], timeout: 2.0)
  }

}
