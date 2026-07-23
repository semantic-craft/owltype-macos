//
//  HotPathLatencyTests.swift
//  FamoTests — P0 added-cost latency proxy (spec P0-06)
//
//  A true IMK hot-path latency test needs a live rime session and is not unit-testable. This is
//  a PROXY: it measures only the work P0 actually appends to the hot path per `rimeUpdate()` —
//  building a `FamoCompositionSnapshot` from ~9 candidates and running `emitComposing` +
//  `emitCleared` on the main actor — and asserts the added per-iteration cost stays well under
//  1 ms (the parent prd budget). No network, no librime. The real timing/timing-order guarantee
//  is still a manual real-machine check; this only guards against the bypass becoming expensive.
//

import XCTest
@testable import Famo

@MainActor
final class HotPathLatencyTests: XCTestCase {

  /// A representative top-9 candidate page (9 = `FamoCompositionSnapshot.defaultTopN`).
  private func makeCandidates() -> [RimeCandidateSnapshot] {
    (0..<9).map { i in
      RimeCandidateSnapshot(index: i, text: "候选\(i)", comment: i == 0 ? "běn yuàn" : nil, quality: nil)
    }
  }

  override func setUp() async throws {
    try await super.setUp()
    FamoSnapshotRegistry.shared.update(nil)
    FamoCandidateStore.shared.clearForSnapshotChange()
  }

  /// Each emit cycle must register a snapshot and mirror the 9 candidates into the main lane,
  /// then a clear must drop them. Functional sanity for the benchmarked path.
  func testEmitCycleRegistersThenClears() {
    let emitter = FamoSnapshotEmitter.shared
    emitter.emitComposing(
      sessionID: 100, schemaID: "pinyin_simp", rawInput: "houxuan",
      preedit: "候选", cursor: 2, pageNo: 0, candidates: makeCandidates()
    )
    XCTAssertNotNil(FamoSnapshotRegistry.shared.current)
    XCTAssertEqual(FamoCandidateStore.shared.main.count, 9)
    XCTAssertEqual(FamoCandidateStore.shared.main.first?.source, .rime)
    XCTAssertEqual(FamoCandidateStore.shared.main.first?.lane, .main)
    XCTAssertEqual(FamoCandidateStore.shared.main.first?.baseRimeIndex, 0)

    emitter.emitCleared()
    XCTAssertNil(FamoSnapshotRegistry.shared.current)
    XCTAssertTrue(FamoCandidateStore.shared.main.isEmpty)
  }

  /// `emitCleared` while already idle must be a no-op that does NOT bump `commitSerial`.
  func testRepeatedClearDoesNotInflateCommitSerial() {
    let emitter = FamoSnapshotEmitter.shared
    emitter.emitComposing(
      sessionID: 100, schemaID: "pinyin_simp", rawInput: "a",
      preedit: "啊", cursor: 1, pageNo: 0, candidates: makeCandidates()
    )
    emitter.emitCleared()
    let serialAfterFirstClear = emitter.commitSerial
    emitter.emitCleared()
    emitter.emitCleared()
    XCTAssertEqual(emitter.commitSerial, serialAfterFirstClear,
                   "Idle clears must not inflate the commit serial")
  }

  /// The appended hot-path work (build snapshot + emitComposing + emitCleared) must cost well
  /// under the 1 ms budget per `rimeUpdate()`. Averaged over many iterations to absorb noise.
  func testEmitAddedCostUnderOneMillisecond() {
    let emitter = FamoSnapshotEmitter.shared
    let candidates = makeCandidates()
    let iterations = 1000

    // Warm up (first touch of the singletons / allocations) so we measure steady state.
    for _ in 0..<50 {
      emitter.emitComposing(
        sessionID: 1, schemaID: "pinyin_simp", rawInput: "warm",
        preedit: "暖", cursor: 1, pageNo: 0, candidates: candidates
      )
      emitter.emitCleared()
    }

    let start = DispatchTime.now().uptimeNanoseconds
    for n in 0..<iterations {
      emitter.emitComposing(
        sessionID: 100, schemaID: "pinyin_simp", rawInput: "houxuan\(n)",
        preedit: "候选", cursor: 2, pageNo: 0, candidates: candidates
      )
      emitter.emitCleared()
    }
    let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start

    let perIterationMillis = Double(elapsedNanos) / Double(iterations) / 1_000_000.0
    print("P0 emit added cost: \(perIterationMillis) ms/iter")
    XCTAssertLessThan(
      perIterationMillis, 1.0,
      "P0 emit added cost \(perIterationMillis) ms/iter exceeds the 1 ms hot-path budget"
    )
  }
}
