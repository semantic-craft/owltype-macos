//
//  CandidateStorePortTests.swift
//  FamoTests — PR for task 06-20-port-famocandidatestore-to-injected-candidatestoring-port
//
//  Cashes in the testability goal the RimeEngine seam established (sources/RimeSeam.swift,
//  tests/RimeSeamTests.swift, tests/SeamPortsTests.swift), extended to the heaviest remaining
//  singleton coupling: the background/async WRITER services that write into the global
//  `FamoCandidateStore.shared` sink. The new `CandidateStoring` port (RimeSeam.swift) lets each
//  writer's write-behaviour be asserted against a `FakeCandidateStore` with NO librime and NO
//  network. Unlike the controller→service ports, these are service→sink couplings with no
//  delegate hop, so the injection point is each WRITER instance's `var store` (mirroring
//  `RimeSeam`'s `var engine` and the delegate's `var snapshots`).
//
//  This file adds the test-only `FakeCandidateStore: CandidateStoring` (scripted, in-memory,
//  records every call) and proves two things per writer:
//
//    1. The runtime default IS the `.shared` singleton — production behaviour is unchanged,
//       injection is pure addition.
//    2. A reachable write/clear/error path runs end-to-end through ONLY the injected port, with
//       no librime session and no network, and the fake store records the scripted value.
//
//  `.shared.store` is reset in `tearDown` to avoid cross-test bleed (the `Fake` is `@MainActor`,
//  single-threaded test runner, so reset-in-tearDown is sufficient).
//
//  No network, no librime, no disk: the fake is pure in-memory scripted state.
//

import Foundation
import XCTest
@testable import Famo

// MARK: - Fake (test fixture only — never shipped in sources/)

/// A scripted `CandidateStoring` with no real store / registry. Records every call the writer
/// made so a test can assert the scripted candidates / error flowed through the port — without
/// the staleness gate, the `@Published` lanes, or `FamoSnapshotRegistry`.
@MainActor
final class FakeCandidateStore: CandidateStoring {
  private(set) var mainSet: [[EnhancedCandidate]] = []
  private(set) var smartUpserts: [(candidates: [EnhancedCandidate], snapshotID: UInt64)] = []
  private(set) var clearCount = 0
  private(set) var errors: [(message: String, lane: EnhancedCandidate.Lane, snapshotID: UInt64)] = []

  func setMainCandidates(_ candidates: [EnhancedCandidate]) {
    mainSet.append(candidates)
  }

  func upsertSmartCandidates(_ candidates: [EnhancedCandidate], snapshotID: UInt64) {
    smartUpserts.append((candidates, snapshotID))
  }

  func clearForSnapshotChange() {
    clearCount += 1
  }

  func showError(_ message: String, lane: EnhancedCandidate.Lane, snapshotID: UInt64) {
    errors.append((message, lane, snapshotID))
  }
}

// MARK: - Tests

@MainActor
final class CandidateStorePortTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    FamoCloudPreferences.resetForTesting()
    FamoSnapshotRegistry.shared.update(nil)
  }

  override func tearDown() async throws {
    // Reset every singleton's injected port back to the production default to avoid cross-test
    // bleed (these are process-wide singletons; a `Fake` left in place would poison later tests).
    FamoSnapshotEmitter.shared.store = FamoCandidateStore.shared
    FamoExternalCommitBroker.shared.store = FamoCandidateStore.shared
    FamoCloudPreferences.resetForTesting()
    FamoSnapshotRegistry.shared.update(nil)
    try await super.tearDown()
  }

  private func snapshot(id: UInt64 = 7, raw: String = "byrw", schema: String = "wubi86_jidian")
    -> FamoCompositionSnapshot {
    FamoCompositionSnapshot(
      id: id,
      sessionID: 1,
      schemaID: schema,
      rawInput: raw,
      preedit: "本院",
      cursor: 2,
      pageNo: 0,
      candidates: [RimeCandidateSnapshot(index: 0, text: "本院", comment: nil, quality: 100)],
      commitSerial: 0
    )
  }

  // MARK: 1. Runtime defaults ARE the shared singleton (behaviour invariant)

  func testWriterDefaultsAreTheSharedStore() {
    XCTAssertTrue(FamoSnapshotEmitter.shared.store === FamoCandidateStore.shared)
    XCTAssertTrue(FamoExternalCommitBroker.shared.store === FamoCandidateStore.shared)
  }

  // MARK: 2. A reachable write/clear/error path per writer flows through the injected port

  /// `FamoSnapshotEmitter.emitComposing` mirrors the Rime menu into the main lane via
  /// `store.setMainCandidates`. No project active (default) → no smart-lane injection. No network.
  func testEmitterMainLaneWriteFlowsThroughInjectedStore() {
    let emitter = FamoSnapshotEmitter()
    let fake = FakeCandidateStore()
    emitter.store = fake

    emitter.emitComposing(
      sessionID: 1,
      schemaID: "wubi86_jidian",
      rawInput: "byrw",
      preedit: "本院",
      cursor: 2,
      pageNo: 0,
      candidates: [RimeCandidateSnapshot(index: 0, text: "本院", comment: nil, quality: 100)]
    )

    XCTAssertEqual(fake.mainSet.count, 1)
    XCTAssertEqual(fake.mainSet.first?.map(\.text), ["本院"])
    XCTAssertEqual(fake.mainSet.first?.first?.lane, .main)
    XCTAssertEqual(fake.mainSet.first?.first?.source, .rime)
  }

  /// `FamoExternalCommitBroker.commit` clears the non-main lanes after a successful insert via
  /// `store.clearForSnapshotChange`. The candidate must match the live snapshot. No network.
  func testCommitBrokerClearFlowsThroughInjectedStore() {
    let broker = FamoExternalCommitBroker()
    let fake = FakeCandidateStore()
    broker.store = fake

    let live = snapshot(id: 60)
    FamoSnapshotRegistry.shared.update(live)
    let candidate = EnhancedCandidate(
      snapshotID: 60,
      source: .localStat,
      lane: .smart,
      text: "本院认为",
      commitMode: .externalText
    )

    var inserted: [String] = []
    broker.commit(candidate) { inserted.append($0) }

    XCTAssertEqual(inserted, ["本院认为"])
    XCTAssertEqual(fake.clearCount, 1)
  }

}
