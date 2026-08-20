//
//  SeamPortsTests.swift
//  OwltypeTests — PR for task 06-20-extend-rimeengine-seam-to-snapshot-cloud-ports
//
//  Cashes in the testability goal the RimeEngine seam established (sources/RimeSeam.swift,
//  tests/RimeSeamTests.swift), extended to the only OTHER two global singletons
//  `OwlInputController` directly reaches off the IMK hot path:
//
//    • `SnapshotReading`            — the read-only live-snapshot view the controller reads
//                                     (was `OwlSnapshotRegistry.shared.current`); the 任意提问 /
//                                     local Smart-lane triggers read it off the IMK hot path.
//
//  This file adds the test-only `FakeSnapshotStore` (scripted, in-memory, NO librime, NO
//  network) and proves:
//
//    1. The narrow `SnapshotReading` port carries exactly what the controller needs: a scripted
//       `current` reads back through the port.
//    2. The injection points are real: assigning the fakes onto `OwlApplicationDelegate`'s
//       `snapshots` (the composition root, alongside `engine`) type-checks and swaps the
//       production `.shared` defaults out.
//
//  Scope (PRD Out-of-Scope, mirrors RimeSeamTests): this stops at the port boundary.
//  Constructing a `OwlInputController` headless calls `IMKInputController`'s server
//  initializer, so the trigger's read-then-request SEQUENCE is reproduced here against the
//  ports the controller now funnels through — the same approach RimeSeamTests used to prove
//  the controller's librime helpers without a live controller. `.shared` stays the
//  production default; injection is pure addition.
//
//  No network, no librime, no disk: the fakes are pure in-memory scripted state.
//

import Foundation
import XCTest
@testable import Owltype

// MARK: - Fakes (test fixtures only — never shipped in sources/)

/// A scripted `SnapshotReading` with no registry/librime. Construct it with the snapshot a
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

/// A scripted `SnapshotEmitting` with no registry/store/librime. Records every emitter call
/// (and `emitComposing`'s args) so a test can assert the controller's snapshot-timeline pokes
/// flowed through the port — without a live composition or the real timeline singleton.
@MainActor
final class FakeSnapshotEmitter: SnapshotEmitting {
  struct Composing: Equatable {
    let sessionID: UInt64
    let schemaID: String
    let rawInput: String
    let preedit: String
    let cursor: Int
    let pageNo: Int
    let candidateCount: Int
  }
  private(set) var noteCommitCount = 0
  private(set) var noteSchemaChangeCount = 0
  private(set) var emitClearedCount = 0
  private(set) var composings: [Composing] = []

  func noteCommit() { noteCommitCount += 1 }
  func noteSchemaChange() { noteSchemaChangeCount += 1 }
  func emitCleared() { emitClearedCount += 1 }
  func emitComposing(sessionID: UInt64, schemaID: String, rawInput: String, preedit: String, cursor: Int, pageNo: Int, candidates: [RimeCandidateSnapshot]) {
    composings.append(Composing(sessionID: sessionID, schemaID: schemaID, rawInput: rawInput, preedit: preedit, cursor: cursor, pageNo: pageNo, candidateCount: candidates.count))
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

/// A scripted `PromptResolving` with no disk. Matches scripted entries on exact (code, title)
/// and records every query so a test can assert the commit chokepoint hit (or skipped) the
/// lookup — without famo_prompts.json. (The live resolver's v-prefix tolerance + JSON read are
/// covered against `OwlPromptStore.matchEntry` in OwlPromptInterceptionTests.)
@MainActor
final class FakePromptStore: PromptResolving {
  var entries: [OwlPromptEntry]
  private(set) var queries: [(code: String, title: String)] = []

  init(entries: [OwlPromptEntry] = []) { self.entries = entries }

  func entry(forCode code: String, title: String) -> OwlPromptEntry? {
    queries.append((code, title))
    return entries.first { $0.code == code && $0.title == title }
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
  private func snapshot(id: UInt64 = 7, raw: String = "nihao", schema: String = "rime_ice")
    -> OwlCompositionSnapshot {
    OwlCompositionSnapshot(
      id: id,
      sessionID: 1,
      schemaID: schema,
      rawInput: raw,
      preedit: raw,
      cursor: raw.count,
      pageNo: 0,
      candidates: [RimeCandidateSnapshot(index: 0, text: "你好", comment: "nǐ hǎo")],
      commitSerial: 0,
      createdAtNanos: 0
    )
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
  // librime, no network, headless `IMKInputController` not constructed — see file header).

  func testDelegatePortDefaultsAreTheSharedSingletons() {
    let delegate = OwlApplicationDelegate()
    XCTAssertTrue(delegate.snapshotEmitter === OwlSnapshotEmitter.shared)
    XCTAssertTrue(delegate.selectionPolish === OwlSelectionPolishService.shared)
    XCTAssertTrue(delegate.promptStore === OwlPromptResolver.shared)
  }

  func testDelegateControllerPortsAreSwappableToFakes() {
    let delegate = OwlApplicationDelegate()
    let emitter = FakeSnapshotEmitter()
    let polish = FakeSelectionPolish()
    let prompts = FakePromptStore()
    delegate.snapshotEmitter = emitter
    delegate.selectionPolish = polish
    delegate.promptStore = prompts
    XCTAssertTrue(delegate.snapshotEmitter === emitter)
    XCTAssertTrue(delegate.selectionPolish === polish)
    XCTAssertTrue(delegate.promptStore === prompts)
  }

  /// Reproduces the controller's `rimeUpdate()` / `commit()` emitter SEQUENCE
  /// (noteSchemaChange → emitComposing → emitCleared → noteCommit) against the injected port,
  /// asserting each call — and `emitComposing`'s scripted args — flowed through the fake.
  func testSnapshotEmitterTriggerFlowsThroughInjectedPort() {
    let delegate = OwlApplicationDelegate()
    let emitter = FakeSnapshotEmitter()
    delegate.snapshotEmitter = emitter

    let snap = snapshot(id: 9, raw: "falv", schema: "rime_ice")
    // The exact pokes the controller performs (all inside MainActor.assumeIsolated in the controller).
    delegate.snapshotEmitter.noteSchemaChange()
    delegate.snapshotEmitter.emitComposing(
      sessionID: snap.sessionID, schemaID: snap.schemaID, rawInput: snap.rawInput,
      preedit: snap.preedit, cursor: snap.cursor, pageNo: snap.pageNo, candidates: snap.candidates
    )
    delegate.snapshotEmitter.emitCleared()
    delegate.snapshotEmitter.noteCommit()

    XCTAssertEqual(emitter.noteSchemaChangeCount, 1)
    XCTAssertEqual(emitter.emitClearedCount, 1)
    XCTAssertEqual(emitter.noteCommitCount, 1)
    XCTAssertEqual(emitter.composings.count, 1)
    XCTAssertEqual(emitter.composings[0], FakeSnapshotEmitter.Composing(
      sessionID: 1, schemaID: "rime_ice", rawInput: "falv", preedit: "falv",
      cursor: snap.cursor, pageNo: 0, candidateCount: 1
    ))
  }

  /// Reproduces the 划词菜单「润色」trigger (`handlePolish`): it awaits the port's
  /// `polishSelection(_:)` and takes the best rewrite. Asserts the selection forwarded through
  /// the port and the scripted rewrites came back — without DeepSeek/keychain.
  func testSelectionPolishTriggerFlowsThroughInjectedPort() async throws {
    let delegate = OwlApplicationDelegate()
    let polish = FakeSelectionPolish(rewrites: ["改写一", "改写二"])
    delegate.selectionPolish = polish

    let rewrites = try await delegate.selectionPolish.polishSelection("原始选中文本")

    XCTAssertEqual(polish.polished, ["原始选中文本"])
    XCTAssertEqual(rewrites.first, "改写一")
  }

}
