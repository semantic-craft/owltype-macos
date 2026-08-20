//
//  BackspaceCorrectionTests.swift
//  OwltypeTests — 退格 LM 纠错钩子 (task 06-22-backspace-typo-correction)
//
//  Locks the PURE layer of the backspace CSC hook, all green with NO model present (the shipped /
//  CI state):
//    1. `OwlBackspaceCorrection.isBackspaceAfterConversion`: a pure-function TABLE test —
//       backspace-over-conversion → true; typing more / paging / re-conversion / no-composition →
//       false.
//    2. `OwlBackspaceCorrection.shapeCandidate`: the azooKey `{displayText, appendText, deleteCount}`
//       contract in Chinese (`句子` typo → corrected), plus 防抖 (correction == shown → nil) and the
//       length-mismatch guard.
//    3. `OwlCscDecode.corrected`: per-position decode independent of CoreML, with a fixture vocab.
//    4. `OwlMacbertCscScorer` fallback: no model/vocab → `correct(_:)` returns the input UNCHANGED
//       (no crash, no correction) — the proof the build ships green without the artifacts.
//    5. The emitter wiring: toggle OFF and no-model are COMPLETE no-ops on the smart lane.
//
//  No network, no librime, no disk, no CoreML: every path here is pure or the no-model fallback.
//

import Foundation
import XCTest
@testable import Owltype

final class BackspaceCorrectionTests: XCTestCase {

  // MARK: - Helpers

  private func delta(_ converted: String, raw: String = "", composing: Bool = true) -> OwlCompositionDelta {
    OwlCompositionDelta(convertedText: converted, rawInput: raw, isComposing: composing)
  }

  // MARK: - 1. Trigger predicate (pure table test)

  func testTriggerTableBackspaceOverConversion() {
    let cases: [(name: String, prev: OwlCompositionDelta, curr: OwlCompositionDelta, expected: Bool)] = [
      // Backspace over converted text: run shrank, remainder is a prefix → TRIGGER.
      ("delete last char", delta("正当防卫"), delta("正当防"), true),
      ("delete two chars", delta("管辖权异议"), delta("管辖权"), true),
      // Typing more code grows the run → NO trigger.
      ("run grew", delta("正当防"), delta("正当防卫"), false),
      // Paging / no change → NO trigger.
      ("unchanged", delta("正当防卫"), delta("正当防卫"), false),
      // Re-conversion changed an earlier char (not a trailing-only delete) → NO trigger.
      ("not a prefix", delta("正当防卫"), delta("正大防"), false),
      // Composition ended → NO trigger even though the run shrank to empty.
      ("not composing", delta("正当防卫"), delta("", composing: false), false),
      // Shrank to empty while composing → nothing left to correct → NO trigger.
      ("shrank to empty", delta("正"), delta("", composing: true), false),
      // First update (empty → text) is a grow → NO trigger.
      ("empty to text", delta(""), delta("正当"), false),
    ]
    for c in cases {
      XCTAssertEqual(
        OwlBackspaceCorrection.isBackspaceAfterConversion(previous: c.prev, current: c.curr),
        c.expected,
        "trigger case failed: \(c.name)"
      )
    }
  }

  // MARK: - 2. Candidate shaping (azooKey {displayText, appendText, deleteCount} in Chinese)

  /// The Chinese analogue of azooKey's `くだし`→`下さい` case: the converted run carries a 别字 and
  /// CSC proposes a same-length corrected string. deleteCount = full run length, appendText =
  /// corrected run (per-position re-commit of the whole run).
  func testShapeCandidateProducesCorrection() {
    // 别字: 「报道」误为「报到」类 — here a same-length homophone correction.
    let candidate = OwlBackspaceCorrection.shapeCandidate(original: "报到", corrected: "报道")
    XCTAssertEqual(candidate, OwlCorrectionCandidate(displayText: "报道", appendText: "报道", deleteCount: 2))
  }

  func testShapeCandidateDebounceIdenticalReturnsNil() {
    // 防抖: the correction equals what is already shown → no candidate.
    XCTAssertNil(OwlBackspaceCorrection.shapeCandidate(original: "正当防", corrected: "正当防"))
  }

  func testShapeCandidateEmptyCorrectionReturnsNil() {
    XCTAssertNil(OwlBackspaceCorrection.shapeCandidate(original: "正当防", corrected: ""))
  }

  func testShapeCandidateLengthMismatchReturnsNil() {
    // CSC is per-position: a length change is junk → no candidate.
    XCTAssertNil(OwlBackspaceCorrection.shapeCandidate(original: "报到", corrected: "报道了"))
    XCTAssertNil(OwlBackspaceCorrection.shapeCandidate(original: "报到", corrected: "报"))
  }

  // MARK: - 3. End-to-end pure pipeline with an injected correct closure

  func testProposeCorrectionFiresOnBackspaceWithCorrectingClosure() {
    // Backspace 报道了 → 报到 (the trailing 了 deleted), and the stub corrects 报到 → 报道.
    let result = OwlBackspaceCorrection.proposeCorrection(
      previous: delta("报到了"),
      current: delta("报到"),
      correct: { $0 == "报到" ? "报道" : $0 }
    )
    XCTAssertEqual(result, OwlCorrectionCandidate(displayText: "报道", appendText: "报道", deleteCount: 2))
  }

  func testProposeCorrectionNoOpWhenNotBackspace() {
    // A grow transition never proposes, even with an over-eager correcting closure.
    let result = OwlBackspaceCorrection.proposeCorrection(
      previous: delta("报"),
      current: delta("报到"),
      correct: { _ in "报道" }
    )
    XCTAssertNil(result)
  }

  func testProposeCorrectionNoOpWhenModelReturnsIdentity() {
    // The no-model fallback returns the input unchanged → identity closure → no candidate.
    let result = OwlBackspaceCorrection.proposeCorrection(
      previous: delta("报到了"),
      current: delta("报到"),
      correct: { $0 }  // identity == the no-model scorer
    )
    XCTAssertNil(result)
  }

  // MARK: - 4. Pure CSC decode (fixture vocab, no CoreML)

  /// A tiny BERT-style vocab: special tokens at their canonical ids + a handful of CJK chars.
  private func fixtureTokenizer() -> OwlBertTokenizer {
    var vocab: [String: Int] = [
      "[PAD]": 0, "[UNK]": 100, "[CLS]": 101, "[SEP]": 102,
    ]
    let chars = ["报", "到", "道", "正", "当", "防", "卫"]
    for (i, ch) in chars.enumerated() { vocab[ch] = 200 + i }
    return OwlBertTokenizer(vocab: vocab)
  }

  func testCscDecodeReconstructsCorrectedRun() {
    let tok = fixtureTokenizer()
    // argmax ids: [CLS], 报, 道, [SEP]  → decode positions 1...2 → "报道" (corrects 到→道).
    let ids = [tok.id(for: "[CLS]")!, tok.id(for: "报")!, tok.id(for: "道")!, tok.id(for: "[SEP]")!]
    XCTAssertEqual(OwlCscDecode.corrected(original: "报到", argmaxIDs: ids, tokenizer: tok), "报道")
  }

  func testCscDecodeKeepsOriginalForNonCJKPosition() {
    let tok = fixtureTokenizer()
    // Position 2 argmaxes to [UNK] (not a CJK char) → keep the original 到.
    let ids = [tok.id(for: "[CLS]")!, tok.id(for: "报")!, tok.id(for: "[UNK]")!, tok.id(for: "[SEP]")!]
    XCTAssertEqual(OwlCscDecode.corrected(original: "报到", argmaxIDs: ids, tokenizer: tok), "报到")
  }

  func testCscDecodeTooFewPositionsReturnsNil() {
    let tok = fixtureTokenizer()
    // Only [CLS] present, no content positions for a 2-char original → nil.
    XCTAssertNil(OwlCscDecode.corrected(original: "报到", argmaxIDs: [tok.id(for: "[CLS]")!], tokenizer: tok))
  }

  func testCscDecodeEmptyOriginalReturnsEmpty() {
    let tok = fixtureTokenizer()
    XCTAssertEqual(OwlCscDecode.corrected(original: "", argmaxIDs: [], tokenizer: tok), "")
  }

  // MARK: - 5. Scorer fallback (no model / no vocab)

  func testScorerWithoutBundleReportsModelUnavailable() {
    XCTAssertFalse(OwlMacbertCscScorer().isModelAvailable)
  }

  func testScorerWithModellessBundleReportsUnavailable() {
    let scorer = OwlMacbertCscScorer(bundle: Bundle(for: type(of: self)))
    XCTAssertFalse(scorer.isModelAvailable)
  }

  func testScorerCorrectReturnsInputUnchangedWithoutModel() {
    let scorer = OwlMacbertCscScorer()
    for text in ["报到", "正当防卫", "", "管辖权异议"] {
      XCTAssertEqual(scorer.correct(text), text, "no-model scorer must return input unchanged")
    }
  }

  // MARK: - 6. Tokenizer inverse map (additive)

  func testTokenizerInverseMap() {
    let tok = fixtureTokenizer()
    XCTAssertEqual(tok.token(for: tok.id(for: "报")!), "报")
    XCTAssertEqual(tok.token(for: 101), "[CLS]")
    XCTAssertNil(tok.token(for: 999_999))
  }

  // MARK: - 7. convertedRun extraction (pure)

  func testConvertedRunExtractsLeadingCJK() {
    XCTAssertEqual(OwlBackspaceCorrection.convertedRun(in: "已选某些字xiang"), "已选某些字")
    XCTAssertEqual(OwlBackspaceCorrection.convertedRun(in: "正当防卫"), "正当防卫")
    XCTAssertEqual(OwlBackspaceCorrection.convertedRun(in: "nihao"), "")
    XCTAssertEqual(OwlBackspaceCorrection.convertedRun(in: ""), "")
  }

  // MARK: - 8. Emitter wiring: toggle OFF / no-model are no-ops; ON + correcting model fires

  /// A scripted CSC corrector (no model, no CoreML) — maps a fixed input to a corrected output so
  /// the positive emitter path can be exercised. The `OwlCscCorrecting` port keeps this swappable.
  private struct ScriptedCsc: OwlCscCorrecting {
    let table: [String: String]
    func correct(_ text: String) -> String { table[text] ?? text }
  }

  /// Build an emitter wired to a fake store + clean (no-active-project) project store, with the
  /// shared registry reset so the snapshotID gate behaves deterministically.
  @MainActor
  private func makeEmitter(store: FakeCandidateStore, csc: OwlCscCorrecting) -> OwlSnapshotEmitter {
    OwlSnapshotRegistry.shared.update(nil)
    let emitter = OwlSnapshotEmitter()
    emitter.store = store
    emitter.projectStore = OwlProjectStore(root: Self.tempRoot(), defaults: Self.cleanDefaults())
    emitter.csc = csc
    return emitter
  }

  /// Drive a 报到了 → (backspace) 报到 transition through two composing updates.
  @MainActor
  private func driveBackspaceTransition(_ emitter: OwlSnapshotEmitter) {
    emitter.emitComposing(sessionID: 1, schemaID: "pinyin_simp", rawInput: "baodaole",
                          preedit: "报到了", cursor: 3, pageNo: 0, candidates: [])
    emitter.emitComposing(sessionID: 1, schemaID: "pinyin_simp", rawInput: "baodao",
                          preedit: "报到", cursor: 2, pageNo: 0, candidates: [])
  }

  @MainActor
  func testToggleOffIsCompleteNoOpOnSmartLane() {
    OwlExperimentalPreferences.resetForTesting()  // default OFF
    defer { OwlExperimentalPreferences.resetForTesting() }

    let store = FakeCandidateStore()
    // Even a correcting model present must not fire while the toggle is OFF.
    let emitter = makeEmitter(store: store, csc: ScriptedCsc(table: ["报到": "报道"]))
    driveBackspaceTransition(emitter)

    XCTAssertTrue(store.smartUpserts.isEmpty, "toggle off must never upsert a smart candidate")
  }

  @MainActor
  func testToggleOnButNoModelIsNoOpOnSmartLane() {
    OwlExperimentalPreferences.resetForTesting()
    OwlExperimentalPreferences.backspaceCorrectionEnabled = true
    defer { OwlExperimentalPreferences.resetForTesting() }

    let store = FakeCandidateStore()
    // No bundle → no model → identity correct → shaping yields nil → no upsert.
    let emitter = makeEmitter(store: store, csc: OwlMacbertCscScorer())
    driveBackspaceTransition(emitter)

    XCTAssertTrue(store.smartUpserts.isEmpty, "no-model path must be a no-op on the smart lane")
  }

  @MainActor
  func testToggleOnWithCorrectingModelFiresCorrectionCandidate() {
    OwlExperimentalPreferences.resetForTesting()
    OwlExperimentalPreferences.backspaceCorrectionEnabled = true
    defer { OwlExperimentalPreferences.resetForTesting() }

    let store = FakeCandidateStore()
    let emitter = makeEmitter(store: store, csc: ScriptedCsc(table: ["报到": "报道"]))
    driveBackspaceTransition(emitter)

    // The second update is the backspace transition; the correcting model proposes 报道.
    let upsert = store.smartUpserts.last
    XCTAssertNotNil(upsert, "a correction candidate must reach the smart lane via upsert")
    XCTAssertEqual(upsert?.candidates.map(\.text), ["报道"])
    XCTAssertEqual(upsert?.candidates.first?.lane, .smart)
    XCTAssertEqual(upsert?.candidates.first?.commitMode, .externalText)
    XCTAssertEqual(upsert?.candidates.first?.comment, "纠错")
  }

  // MARK: - Test fixtures

  private static func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwlBackspaceTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func cleanDefaults() -> UserDefaults {
    let suite = "OwlBackspaceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}
