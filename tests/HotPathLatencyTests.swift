//
//  HotPathLatencyTests.swift
//  OwltypeTests — P0 added-cost latency proxy (spec P0-06)
//
//  A true IMK hot-path latency test needs a live rime session and is not unit-testable. This is
//  a PROXY: it measures only the work P0 actually appends to the hot path per `engineUpdate()` —
//  building a `OwlCompositionSnapshot` from ~9 candidates and running `emitComposing` +
//  `emitCleared` on the main actor — and asserts the added per-iteration cost stays well under
//  1 ms (the parent prd budget). No network, no engine. The real timing/timing-order guarantee
//  is still a manual real-machine check; this only guards against the bypass becoming expensive.
//

import XCTest
@testable import Owltype

@MainActor
final class HotPathLatencyTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    OwlSnapshotRegistry.shared.update(nil)
  }

  /// Each emit cycle must register a snapshot, then a clear must drop it. Functional sanity for
  /// the benchmarked path.
  func testEmitCycleRegistersThenClears() {
    let emitter = OwlSnapshotEmitter.shared
    emitter.emitComposing(rawInput: "houxuan")
    XCTAssertEqual(OwlSnapshotRegistry.shared.current?.rawInput, "houxuan")

    emitter.emitCleared()
    XCTAssertNil(OwlSnapshotRegistry.shared.current)
  }

  /// The appended hot-path work (build snapshot + emitComposing + emitCleared) must cost well
  /// under the 1 ms budget per `engineUpdate()`. Averaged over many iterations to absorb noise.
  func testEmitAddedCostUnderOneMillisecond() {
    let emitter = OwlSnapshotEmitter.shared
    let iterations = 1000

    // Warm up (first touch of the singletons / allocations) so we measure steady state.
    for _ in 0..<50 {
      emitter.emitComposing(rawInput: "warm")
      emitter.emitCleared()
    }

    let start = DispatchTime.now().uptimeNanoseconds
    for n in 0..<iterations {
      emitter.emitComposing(rawInput: "houxuan\(n)")
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
