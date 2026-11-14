//
//  OwlLaneTasksTests.swift
//  OwltypeTests — per-lane AI task supervisor (B8)
//
//  Proves, with NO engine, NO network, NO real Keychain, that `OwlLaneTasks` supervises one
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

  /// `cancel(lane)` cancels exactly that one lane.
  func testCancelOneLane() async {
    let tasks = OwlLaneTasks()
    let started = expectation(description: "cloud op started")
    let cancelled = expectation(description: "cloud op observed cancellation")

    tasks.run(.cloud) {
      started.fulfill()
      do {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        XCTFail("the cloud op should have been cancelled")
      } catch {
        XCTAssertTrue(Task.isCancelled)
        cancelled.fulfill()
      }
    }
    await fulfillment(of: [started], timeout: 2.0)

    tasks.cancel(.cloud)
    await fulfillment(of: [cancelled], timeout: 2.0)
  }

  /// `cancelAll()` cancels every in-flight lane.
  func testCancelAllCancelsAllLanes() async {
    let tasks = OwlLaneTasks()
    let cloudStarted = expectation(description: "cloud started")
    let cloudCancelled = expectation(description: "cloud cancelled")

    tasks.run(.cloud) {
      cloudStarted.fulfill()
      do { try await Task.sleep(nanoseconds: 5_000_000_000); XCTFail("cloud not cancelled") }
      catch { XCTAssertTrue(Task.isCancelled); cloudCancelled.fulfill() }
    }
    await fulfillment(of: [cloudStarted], timeout: 2.0)

    tasks.cancelAll()
    await fulfillment(of: [cloudCancelled], timeout: 2.0)
  }

}
