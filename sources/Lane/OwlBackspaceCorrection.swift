//
//  OwlBackspaceCorrection.swift
//  猫头鹰输入法 (Owltype) — 退格 LM 纠错钩子 (task 06-22-backspace-typo-correction)
//
//  PURE, deterministic, model-free trigger + candidate-shaping for the backspace-after-conversion
//  Chinese spelling-correction (CSC) hook. Inspired by azooKey's
//  `SegmentsManager.deleteBackwardFromCursorPosition` + `makeBackspaceTypoCorrectionPredictionCandidate`
//  (its `PredictionCandidate{displayText, appendText, deleteCount}` semantics): a correction
//  candidate carries "first delete N trailing units, then append the corrected text".
//
//  Boundary (ADR-0001 / 0002 / 0003): nothing here touches the IMK hot path, librime, CoreML,
//  network, or disk. The trigger is a pure comparison of two composition snapshots; the scoring is
//  delegated to `OwlMacbertCscScorer` (which itself ships green with NO model — see that file).
//  The shaped candidate reaches the panel ONLY through the snapshotID-gated smart-lane upsert in
//  `OwlSnapshotEmitter`; async/scoring code NEVER calls setMarkedText/insertText
//  (the `OwlExternalCommitBroker` discipline).
//
//  Why CHARACTERS, not pinyin (settled design): macbert4csc is a CHARACTER-level CSC model — it
//  corrects 别字 / homophone errors in converted Chinese TEXT. It does NOT correct pinyin readings
//  (that is librime's fuzzy/容错 job, out of scope). So the trigger operates on the converted
//  Chinese characters carried in the composition's preedit, never on the raw pinyin code.
//

import Foundation

/// A minimal value snapshot of "what the user sees committed/converted in the composition" at one
/// instant, plus whether any composition is active. Pure value type so the trigger is unit-testable
/// without IMK/librime. `convertedText` is the already-converted Chinese run in the preedit (the
/// part the CSC model can correct); `rawInput` is the live pinyin/code stream (NEVER fed to CSC).
struct OwlCompositionDelta: Equatable {
  /// The converted Chinese characters currently shown (preedit's committed-conversion run).
  let convertedText: String
  /// The raw input code stream (pinyin / wubi). Carried for completeness; CSC never reads it.
  let rawInput: String
  /// Whether a composition is active at all (false once everything is committed / cleared).
  let isComposing: Bool

  init(convertedText: String, rawInput: String, isComposing: Bool) {
    self.convertedText = convertedText
    self.rawInput = rawInput
    self.isComposing = isComposing
  }
}

/// The shape of a correction candidate, mirroring azooKey's
/// `PredictionCandidate{displayText, appendText, deleteCount}`. The Chinese reading:
///   - `deleteCount`: how many trailing CHARACTERS of the just-typed converted run to delete first,
///   - `appendText`: the corrected characters to append after the delete,
///   - `displayText`: what the candidate shows in the panel (the full corrected run).
///
/// Commit semantics in Owltype: the smart lane commits external text via `OwlExternalCommitBroker`;
/// the broker performs the delete-then-insert. This value type carries the intent purely so it can
/// be tested independent of any client. `Equatable` for table tests.
struct OwlCorrectionCandidate: Equatable {
  let displayText: String
  let appendText: String
  let deleteCount: Int

  init(displayText: String, appendText: String, deleteCount: Int) {
    self.displayText = displayText
    self.appendText = appendText
    self.deleteCount = deleteCount
  }
}

/// The PURE trigger + shaping logic. No model, no IO, no IMK. The CSC inference is injected as a
/// closure (`correct:`) so this stays testable with a stub; production passes
/// `OwlMacbertCscScorer.correct`.
enum OwlBackspaceCorrection {

  /// Extract the converted Chinese run from a `preedit` — its leading run of CJK characters, which
  /// is the already-committed-conversion prefix the CSC model can correct (the trailing pinyin/code
  /// is excluded). PURE; CSC never sees the pinyin. Stops at the first non-CJK scalar so a mixed
  /// `已选某些字xiang` preedit yields `已选某些字`.
  static func convertedRun(in preedit: String) -> String {
    var run = ""
    for scalar in preedit.unicodeScalars {
      if OwlBertTokenizer.isCJK(scalar) {
        run.unicodeScalars.append(scalar)
      } else {
        break
      }
    }
    return run
  }

  /// Decide whether the transition `previous → current` is a "backspace into/over just-converted
  /// Chinese text" — the trigger condition for requesting a CSC pass. PURE.
  ///
  /// True iff ALL hold:
  ///   - a composition is still active in `current` (we never correct a fully-committed empty state),
  ///   - the converted run SHRANK (`current.convertedText.count < previous.convertedText.count`) —
  ///     i.e. the user deleted converted characters (a backspace over conversion), as opposed to
  ///     typing more code (run grows) or paging (run unchanged),
  ///   - the remaining converted run is non-empty (there is still text to correct), and
  ///   - the remaining run is a PREFIX of the previous run (a pure trailing-delete, the backspace
  ///     case — not a re-conversion that changed earlier characters).
  ///
  /// Deliberately conservative: re-conversions, code typing, and paging do NOT trigger.
  static func isBackspaceAfterConversion(
    previous: OwlCompositionDelta,
    current: OwlCompositionDelta
  ) -> Bool {
    guard current.isComposing else { return false }
    let prev = Array(previous.convertedText)
    let curr = Array(current.convertedText)
    guard !curr.isEmpty, curr.count < prev.count else { return false }
    // The remaining run must be a leading prefix of the previous run (trailing-only delete).
    return Array(prev.prefix(curr.count)) == curr
  }

  /// Shape a `OwlCorrectionCandidate` from the (possibly-)corrected `corrected` string for the
  /// current converted run `original`. Returns `nil` (no candidate) when:
  ///   - `corrected` is empty, equals `original`, or differs in length (CSC is per-position: a
  ///     correct result has the SAME length — a length change means the model produced junk; drop),
  ///   - 防抖 (the azooKey `shouldPresentTypoCorrectionPredictionCandidate` analogue): the correction
  ///     equals what is already shown (`original`) → no candidate, so we never offer a no-op.
  ///
  /// When a correction differs, `deleteCount` is the full current run length (we re-commit the whole
  /// corrected run as one unit) and `appendText`/`displayText` are the corrected string. PURE.
  static func shapeCandidate(original: String, corrected: String) -> OwlCorrectionCandidate? {
    guard !corrected.isEmpty, corrected != original else { return nil }
    // CSC is strictly per-position: a valid correction keeps the character count. A different
    // length is a malformed model output → no candidate (never surface junk).
    guard corrected.count == original.count else { return nil }
    return OwlCorrectionCandidate(
      displayText: corrected,
      appendText: corrected,
      deleteCount: original.count
    )
  }

  /// End-to-end PURE pipeline: given the snapshot transition and an injected CSC `correct` closure,
  /// produce a correction candidate or `nil`. The closure is the only impure dependency at the call
  /// site (production wires `OwlMacbertCscScorer.correct`, which returns the input unchanged when no
  /// model is present → `nil` here). No-op when the transition is not a backspace-after-conversion.
  ///
  /// - Parameters:
  ///   - previous: the converted/raw state BEFORE the backspace.
  ///   - current: the converted/raw state AFTER the backspace.
  ///   - correct: pure-ish CSC pass `convertedText -> correctedText` (identity when no model).
  /// - Returns: a shaped correction candidate, or `nil` when nothing should be offered.
  static func proposeCorrection(
    previous: OwlCompositionDelta,
    current: OwlCompositionDelta,
    correct: (String) -> String
  ) -> OwlCorrectionCandidate? {
    guard isBackspaceAfterConversion(previous: previous, current: current) else { return nil }
    let original = current.convertedText
    let corrected = correct(original)
    return shapeCandidate(original: original, corrected: corrected)
  }
}
