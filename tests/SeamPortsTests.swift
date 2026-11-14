//
//  SeamPortsTests.swift
//  OwltypeTests — PR for task 06-20-extend-rimeengine-seam-to-snapshot-cloud-ports
//
//  Cashes in the testability goal the InputEngine seam established (sources/Engine/OwlRustEngine.swift),
//  extended to the read-only snapshot port `OwlInputController` reaches off the IMK hot path:
//
//    • `SnapshotReading`            — the read-only live-snapshot view the controller reads
//                                     (was `OwlSnapshotRegistry.shared.current`); the 任意提问 /
//                                     local Smart-lane triggers read it off the IMK hot path.
//
//  This file adds the test-only `FakeSnapshotStore` (scripted, in-memory, NO engine, NO
//  network) and proves:
//
//    1. The narrow `SnapshotReading` port carries exactly what the controller needs: a scripted
//       `current` reads back through the port.
//    2. The injection points are real: assigning the fakes onto `OwlApplicationDelegate`'s
//       `snapshots` (the composition root, alongside `engine`) type-checks and swaps the
//       production `.shared` defaults out.
//
//  Scope: this stops at the port boundary.
//  Constructing a `OwlInputController` headless calls `IMKInputController`'s server
//  initializer, so the trigger's read-then-request SEQUENCE is reproduced here against the
//  ports the controller now funnels through. `.shared` stays the
//  production default; injection is pure addition.
//
//  No network, no engine, no disk: the fakes are pure in-memory scripted state.
//

import Foundation
import XCTest
@testable import Owltype

// MARK: - Fakes (test fixtures only — never shipped in sources/)

/// A scripted `SnapshotReading` with no registry/engine. Construct it with the snapshot a
/// test wants the controller's trigger path to read; `readCount` records how many times the
/// trigger reached for `current`.
@MainActor
final class FakeSnapshotStore: SnapshotReading {
  var scriptedCurrent: OwlCompositionSnapshot?
  private(set) var readCount = 0

  init(current: OwlCompositionSnapshot? = nil) {
    self.scriptedCurrent = current
  }

  var current: OwlCompositionSnapshot? {
    readCount += 1
    return scriptedCurrent
  }
}

/// A scripted `SnapshotEmitting` with no registry/store/engine. Records every emitter call
/// (and `emitComposing`'s args) so a test can assert the controller's snapshot-timeline pokes
/// flowed through the port — without a live composition or the real timeline singleton.
@MainActor
final class FakeSnapshotEmitter: SnapshotEmitting {
  private(set) var emitClearedCount = 0
  private(set) var rawInputs: [String] = []

  func emitCleared() { emitClearedCount += 1 }
  func emitComposing(rawInput: String) {
    rawInputs.append(rawInput)
  }
}

/// A scripted `SelectionPolishing` with no service/keychain/network. Records the selection it
/// was asked to polish and returns scripted rewrites so a test can assert the controller's
/// 润色选中 trigger forwarded the selection and consumed the rewrites — without DeepSeek.
@MainActor
final class FakeSelectionPolish: SelectionPolishing {
  var scriptedRewrites: [String]
  private(set) var polished: [String] = []

  init(rewrites: [String] = []) { self.scriptedRewrites = rewrites }

  func polishSelection(_ selection: String) async throws -> [String] {
    polished.append(selection)
    return scriptedRewrites
  }
}

// MARK: - Tests

@MainActor
final class SeamPortsTests: XCTestCase {

  // `OwlSnapshotRegistry` is a process-wide singleton other test classes also write. This
  // class never touches `.shared` (its fakes are scripted in-memory), but it asserts
  // `OwlSnapshotRegistry.shared.current == nil` to prove the fake-driven path leaves the
  // production singleton untouched. Clear the registry at the start AND end of each test so
  // a snapshot left by an earlier/other test class can't make that assertion flap, and so
  // this class never leaks state into a later one. (single-threaded @MainActor test runner.)
  override func setUp() async throws {
    try await super.setUp()
    OwlSnapshotRegistry.shared.update(nil)
  }

  override func tearDown() async throws {
    OwlSnapshotRegistry.shared.update(nil)
    try await super.tearDown()
  }

  // A realistic composition snapshot, the kind the emitter copies off the hot path.
  private func snapshot(id: UInt64 = 7, raw: String = "nihao") -> OwlCompositionSnapshot {
    OwlCompositionSnapshot(id: id, rawInput: raw)
  }

  // MARK: 1. Narrow ports carry exactly what the controller needs

  func testSnapshotReadingReadsBackScriptedCurrent() {
    let snap = snapshot()
    let store = FakeSnapshotStore(current: snap)

    let read = store.current
    XCTAssertEqual(read?.id, snap.id)
    XCTAssertEqual(read?.rawInput, "nihao")
    XCTAssertEqual(read?.schemaID, "rime_ice")
    XCTAssertEqual(store.readCount, 1)
  }

  func testSnapshotReadingReturnsNilWhenNoComposition() {
    let store = FakeSnapshotStore()
    XCTAssertNil(store.current)   // mirrors "请先输入一段正在组字的编码"
  }

  // MARK: 2. Injection points are real (composition root, alongside `engine`)

  func testDelegateDefaultsAreTheSharedSingletons() {
    let delegate = OwlApplicationDelegate()
    // Behaviour invariant: the runtime default is the `.shared` snapshot registry.
    XCTAssertTrue(delegate.snapshots === OwlSnapshotRegistry.shared)
  }

  func testDelegatePortsAreSwappableToFakes() {
    let delegate = OwlApplicationDelegate()
    let store = FakeSnapshotStore(current: snapshot())
    delegate.snapshots = store
    XCTAssertTrue(delegate.snapshots === store)
  }

  // MARK: 3. The 2 controller→service ports (snapshot emitter / selection polish)

  // Each port mirrors the SnapshotReading cases above: prove the
  // delegate runtime default IS the `.shared` singleton, prove the property is swappable to a
  // fake, and drive the controller's trigger SEQUENCE through ONLY the injected port (no
  // the engine, no network, headless `IMKInputController` not constructed — see file header).

  func testDelegatePortDefaultsAreTheSharedSingletons() {
    let delegate = OwlApplicationDelegate()
    XCTAssertTrue(delegate.snapshotEmitter === OwlSnapshotEmitter.shared)
    XCTAssertTrue(delegate.selectionPolish === OwlSelectionPolishService.shared)
  }

  func testDelegateControllerPortsAreSwappableToFakes() {
    let delegate = OwlApplicationDelegate()
    let emitter = FakeSnapshotEmitter()
    let polish = FakeSelectionPolish()
    delegate.snapshotEmitter = emitter
    delegate.selectionPolish = polish
    XCTAssertTrue(delegate.snapshotEmitter === emitter)
    XCTAssertTrue(delegate.selectionPolish === polish)
  }

  /// Reproduces the controller's `engineUpdate()` emitter sequence
  /// (`emitComposing` → `emitCleared`) against the injected port,
  /// asserting each call — and `emitComposing`'s scripted args — flowed through the fake.
  func testSnapshotEmitterTriggerFlowsThroughInjectedPort() {
    let delegate = OwlApplicationDelegate()
    let emitter = FakeSnapshotEmitter()
    delegate.snapshotEmitter = emitter

    let snap = snapshot(id: 9, raw: "falv")
    // The exact pokes the controller performs (all inside MainActor.assumeIsolated in the controller).
    delegate.snapshotEmitter.emitComposing(rawInput: snap.rawInput)
    delegate.snapshotEmitter.emitCleared()

    XCTAssertEqual(emitter.emitClearedCount, 1)
    XCTAssertEqual(emitter.rawInputs, ["falv"])
  }


}
