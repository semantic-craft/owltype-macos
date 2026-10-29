//
//  OwlForcedFinalizeTests.swift
//  OwltypeTests — 宿主强制 finalize 落字决策 (task 07-07-pinyin-backspace-delete-all)
//
//  Locks the PURE decision `OwlForcedFinalize.commitText(preview:input:)`:
//    - a non-empty preview wins → land converted 中文 (the fix: not raw pinyin);
//    - nil / empty preview falls back to the raw input → the "空回退" never-lose-input invariant.
//
//  Also locks the finalize SEQUENCE `OwlForcedFinalize.finalize(...)` (#37 根治):
//    - live input → trace + commit + clearComposition, THEN emitCleared (ordering);
//    - nil/empty input → NO commit, NO engine clear, preview untouched — but emitCleared STILL
//      runs. That last contract is the whole point of #37: a forced finalize that skips the
//      registry clear strands the snapshot for the process lifetime (#131's wild samples).
//  The read-back class drives the REAL emitter + registry (no fake mirror), per the
//  app_options 假覆盖 lesson: assert what the registry actually holds, not what we told a fake.
//
//  No IMK, no engine, no disk: pure value logic, mirrors OwlAutoPairTests / BackspaceCorrectionTests.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlForcedFinalizeTests: XCTestCase {

  // Non-empty preview → commit the converted text (land 中文, not the raw pinyin stream).
  func testPreviewPresentCommitsPreview() {
    XCTAssertEqual(
      OwlForcedFinalize.commitText(preview: "中华人民", input: "zhonghuarenmin"),
      "中华人民"
    )
  }

  // nil preview → fall back to raw input (never lose what the user typed).
  func testNilPreviewFallsBackToInput() {
    XCTAssertEqual(
      OwlForcedFinalize.commitText(preview: nil, input: "zhonghua"),
      "zhonghua"
    )
  }

  // Empty-string preview → treated as absent → fall back to raw input.
  func testEmptyPreviewFallsBackToInput() {
    XCTAssertEqual(
      OwlForcedFinalize.commitText(preview: "", input: "fatiao"),
      "fatiao"
    )
  }

  // Both present → preview still wins (the normal converted case).
  func testPreviewWinsOverInput() {
    XCTAssertEqual(
      OwlForcedFinalize.commitText(preview: "法条", input: "fatiao"),
      "法条"
    )
  }
}

/// The #37 sequence contract, driven through recording closures (no IMK, no engine).
final class OwlForcedFinalizeSequenceTests: XCTestCase {

  /// One finalize run against recording closures. `events` captures the exact side-effect
  /// order; `previewReads` proves the lazy preview is only consulted on the live-input path.
  private struct Run {
    var events: [String] = []
    var previewReads = 0
  }

  private func run(input: String?, preview: String?) -> Run {
    var events: [String] = []
    var previewReads = 0
    OwlForcedFinalize.finalize(
      input: input,
      preview: { previewReads += 1; return preview },
      commit: { events.append("commit(\($0))") },
      clearComposition: { events.append("clearComposition") },
      emitCleared: { events.append("emitCleared") },
      trace: { events.append("trace:\($0)") }
    )
    return Run(events: events, previewReads: previewReads)
  }

  // Live composition → land preview, clear engine, THEN clear registry (exact order).
  func testLiveInputCommitsThenClearsEngineThenRegistry() {
    let r = run(input: "nihao", preview: "你好")
    XCTAssertEqual(r.events, [
      "trace:commitComposition finalize usedPreview=true len=2",
      "commit(你好)",
      "clearComposition",
      "emitCleared",
      "trace:commitComposition emitCleared",
    ])
    XCTAssertEqual(r.previewReads, 1)
  }

  // No preview → the 空回退 invariant still holds through the sequence (raw input lands).
  func testLiveInputWithoutPreviewFallsBackToRaw() {
    let r = run(input: "nihao", preview: nil)
    XCTAssertTrue(r.events.contains("commit(nihao)"))
    XCTAssertEqual(r.events.last, "trace:commitComposition emitCleared")
  }

  // THE #37 contract: no live session (nil input) → nothing committed, engine untouched,
  // preview never read — but the registry clear STILL runs.
  func testNilInputStillClearsRegistry() {
    let r = run(input: nil, preview: "残影")
    XCTAssertEqual(r.events, ["emitCleared", "trace:commitComposition emitCleared"])
    XCTAssertEqual(r.previewReads, 0)
  }

  // Same contract for an empty input string (live session, nothing pending).
  func testEmptyInputStillClearsRegistry() {
    let r = run(input: "", preview: "残影")
    XCTAssertEqual(r.events, ["emitCleared", "trace:commitComposition emitCleared"])
    XCTAssertEqual(r.previewReads, 0)
  }
}

/// The #37 read-back contract against the REAL emitter + registry: after a forced finalize,
/// `OwlSnapshotRegistry.shared.current` must be nil — asserted from the registry itself, not a
/// fake mirror (app_options 假覆盖 lesson). Mirrors HotPathLatencyTests' shared-state hygiene.
@MainActor
final class OwlForcedFinalizeRegistryReadbackTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    OwlSnapshotRegistry.shared.update(nil)
  }

  // Stranded-composition shape: a snapshot is registered (mid-composition), then the host
  // force-ends the session with nothing pending (input nil). The registry must come back empty.
  func testForcedFinalizeWithNoPendingInputClearsStrandedSnapshot() {
    let emitter = OwlSnapshotEmitter.shared
    emitter.emitComposing(
      sessionID: 7, schemaID: "pinyin_simp", rawInput: "a",
      preedit: "啊", cursor: 1, pageNo: 0,
      candidates: [EngineCandidateSnapshot(index: 0, text: "啊", comment: nil, quality: nil)]
    )
    XCTAssertNotNil(OwlSnapshotRegistry.shared.current, "precondition: snapshot registered")

    OwlForcedFinalize.finalize(
      input: nil,
      preview: { nil },
      commit: { _ in XCTFail("nothing to commit on the stranded path") },
      clearComposition: { XCTFail("no live engine to clear on the stranded path") },
      emitCleared: { emitter.emitCleared() },
      trace: { _ in }
    )

    XCTAssertNil(OwlSnapshotRegistry.shared.current, "#37: forced finalize must clear the registry")
  }

  // Live-input shape: pending composition finalized by the host → commit + engine clear ran,
  // and the registry read-back is empty as well.
  func testForcedFinalizeWithPendingInputClearsRegistry() {
    let emitter = OwlSnapshotEmitter.shared
    emitter.emitComposing(
      sessionID: 8, schemaID: "pinyin_simp", rawInput: "nihao",
      preedit: "你好", cursor: 2, pageNo: 0,
      candidates: [EngineCandidateSnapshot(index: 0, text: "你好", comment: nil, quality: nil)]
    )
    var committed: [String] = []
    OwlForcedFinalize.finalize(
      input: "nihao",
      preview: { "你好" },
      commit: { committed.append($0) },
      clearComposition: {},
      emitCleared: { emitter.emitCleared() },
      trace: { _ in }
    )
    XCTAssertEqual(committed, ["你好"])
    XCTAssertNil(OwlSnapshotRegistry.shared.current, "#37: forced finalize must clear the registry")
  }
}
