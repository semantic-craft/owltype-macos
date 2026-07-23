//
//  FamoMacbertCscScorer.swift
//  法墨输入法 (Famo) — 退格 LM 纠错钩子 · 端上 CSC scorer (task 06-22-backspace-typo-correction)
//
//  The on-device Chinese Spelling Correction (CSC) backend for the backspace correction hook. It
//  tokenizes the converted Chinese run with `FamoBertTokenizer`, runs `macbert4csc.mlpackage`
//  (a BERT masked-LM-style model: per-position logits over the vocab), argmaxes each non-special
//  position, and decodes the corrected character string. A lazy locked bundle probe → `nil` when
//  the model/vocab are absent → clean per-call fallback (return the input UNCHANGED = no correction).
//
//  GRACEFUL FALLBACK (the whole point of shipping this green with NO model present): the
//  `macbert4csc.mlpackage` and the matching `vocab.txt` are LARGE offline build artifacts
//  (gitignored, ABSENT in the repo/CI). When EITHER is missing, every
//  `correct(_:)` returns its argument unchanged — no crash, no network, no IO beyond the one lazy
//  bundle probe. Dropping the artifacts in later upgrades this seam to real CSC with no code change.
//
//  SCHEDULING (do NOT regress the hot path): this runs ONLY inside the smart-lane enhancement step
//  (`FamoSnapshotEmitter`, the backspace-after-conversion branch), under the default-OFF experiment
//  toggle — NEVER per-keystroke on the IMK hot path, NEVER on the Rime main lane. The correction
//  candidate reaches the panel only through the snapshotID-gated smart-lane upsert; this file never
//  calls setMarkedText / insertText / commit / deploy.
//

import CoreML
import Foundation

/// The narrow CSC port: correct a converted Chinese run, returning the input UNCHANGED when no
/// correction applies (the no-model contract). Injected on `FamoSnapshotEmitter` so a test can swap
/// a scripted corrector for the concrete `FamoMacbertCscScorer` (see `famo-dependency-seams.md`).
protocol FamoCscCorrecting {
  /// Correct `text`; returns `text` unchanged when there is nothing to correct (or no model).
  func correct(_ text: String) -> String
}

/// On-device CSC scorer. Lazily loads `macbert4csc.mlpackage` + `vocab.txt` from the app bundle;
/// when either is absent, `correct(_:)` returns its input UNCHANGED (no correction = the CI state).
final class FamoMacbertCscScorer: FamoCscCorrecting, @unchecked Sendable {
  /// Resource names of the offline build artifacts (gitignored; injected at build time).
  private static let modelResourceName = "macbert4csc"
  private static let modelResourceExtension = "mlpackage"
  private static let vocabResourceName = "vocab"
  private static let vocabResourceExtension = "txt"
  /// Fixed sequence length the conversion script bakes in. macbert4csc corrects short runs; 128 is
  /// ample for a single composition's converted text.
  private static let sequenceLength = 128

  /// The bundle to probe for the model + vocab. Injectable so a test can point at a fixture bundle
  /// (or omit it entirely — the default — to force the no-model fallback path, which CI runs in).
  private let bundle: Bundle?

  /// Lazily-resolved engine. `nil` means "model and/or vocab missing → no correction". Computed
  /// once on first `correct(...)` and memoized; serialized by `engineLock` for thread safety.
  private var engine: Engine??
  private let engineLock = NSLock()

  /// Construct with the bundle to probe. `bundle == nil` (the default) forces the no-correction
  /// fallback — exactly the no-model state CI runs in.
  init(bundle: Bundle? = nil) {
    self.bundle = bundle
  }

  /// Whether the real model + vocab loaded. Triggers the lazy probe. Used by the wiring layer to
  /// skip needless work when no model is present, and by tests to assert the fallback state.
  var isModelAvailable: Bool { resolveEngine() != nil }

  /// Correct `text` (a converted Chinese run). Returns the corrected string, or — when no model /
  /// vocab is present, or inference fails — `text` UNCHANGED (no correction). NEVER throws, never
  /// blocks on network/disk beyond the one lazy probe. A returned value equal to `text` means "no
  /// correction", which the pure shaping layer (`FamoBackspaceCorrection.shapeCandidate`) maps to
  /// `nil` (no candidate).
  func correct(_ text: String) -> String {
    guard !text.isEmpty, let engine = resolveEngine() else { return text }
    return engine.correct(text) ?? text
  }

  // MARK: - Lazy engine resolution

  /// Resolve (once) the CoreML engine, or `nil` if the model/vocab are missing or fail to load.
  private func resolveEngine() -> Engine? {
    engineLock.lock()
    defer { engineLock.unlock() }
    if let resolved = engine { return resolved }
    let built = Self.buildEngine(bundle: bundle)
    engine = .some(built)
    return built
  }

  /// Probe the bundle for both artifacts and build an `Engine`. Returns `nil` (→ no correction) when
  /// the bundle is nil, either artifact is missing, the vocab is unusable, or CoreML load fails.
  private static func buildEngine(bundle: Bundle?) -> Engine? {
    guard let bundle else { return nil }
    guard
      let modelURL = bundle.url(forResource: modelResourceName, withExtension: modelResourceExtension),
      let vocabURL = bundle.url(forResource: vocabResourceName, withExtension: vocabResourceExtension),
      let vocabText = try? String(contentsOf: vocabURL, encoding: .utf8)
    else {
      return nil
    }
    let tokenizer = FamoBertTokenizer(vocabText: vocabText)
    guard tokenizer.isAvailable else { return nil }
    guard let model = try? loadModel(at: modelURL) else { return nil }
    return Engine(model: model, tokenizer: tokenizer, sequenceLength: sequenceLength)
  }

  /// Load (and, for an uncompiled `.mlpackage`, compile) the CoreML model from `url`.
  private static func loadModel(at url: URL) throws -> MLModel {
    let config = MLModelConfiguration()
    config.computeUnits = .all  // permit ANE placement
    if url.pathExtension == "mlmodelc" {
      return try MLModel(contentsOf: url, configuration: config)
    }
    let compiled = try MLModel.compileModel(at: url)
    return try MLModel(contentsOf: compiled, configuration: config)
  }
}

// MARK: - Pure CSC decode (testable without CoreML)

/// PURE per-position decode of a masked-LM / CSC logits tensor into a corrected character string.
/// Split out (mirroring `FamoVectorMath`) so the decode contract is unit-testable independent of
/// CoreML/the model: given the original characters, the argmax-id per position, and a tokenizer to
/// map id→char, reconstruct the corrected run. The number of model positions includes `[CLS]` …
/// `[SEP]`; the corrected run is exactly the `original.count` content positions in between.
enum FamoCscDecode {
  /// Decode the corrected run from per-position argmax token ids.
  ///
  /// - Parameters:
  ///   - original: the original converted characters (defines the expected output length).
  ///   - argmaxIDs: the argmax token id at EACH model position, in order, INCLUDING the leading
  ///     `[CLS]` and trailing `[SEP]` (i.e. `original.count + 2` content+special positions at the
  ///     front; trailing padding positions are ignored). We read positions `1 ... original.count`.
  ///   - tokenizer: maps an id back to its piece (`token(for:)`).
  /// - Returns: the corrected character string, or `nil` when the shape is unusable (too few
  ///   positions, or any content position decodes to a non-single-character piece — treat as junk
  ///   and fall back to no-correction rather than emit a broken string).
  static func corrected(
    original: String,
    argmaxIDs: [Int],
    tokenizer: FamoBertTokenizer
  ) -> String? {
    let originalChars = Array(original)
    let n = originalChars.count
    guard n > 0 else { return original }
    // Need [CLS] + n content positions (+ [SEP] which we don't read). Require at least 1 + n.
    guard argmaxIDs.count >= n + 1 else { return nil }
    var out = ""
    out.reserveCapacity(n)
    for i in 0..<n {
      // Content positions are offset by 1 for the leading [CLS].
      let id = argmaxIDs[i + 1]
      guard let piece = tokenizer.token(for: id) else {
        // Unknown id at this position → keep the original character (conservative: never drop).
        out.append(originalChars[i])
        continue
      }
      // A CSC content position must decode to exactly one CJK character. Anything else (a special
      // token, a multi-char piece, [UNK]) → keep the original character rather than corrupt the run.
      if piece.count == 1, let scalar = piece.unicodeScalars.first, FamoBertTokenizer.isCJK(scalar) {
        out.append(piece)
      } else {
        out.append(originalChars[i])
      }
    }
    return out
  }
}

// MARK: - CoreML inference engine

extension FamoMacbertCscScorer {
  /// Holds the loaded model + tokenizer and turns a converted run into a corrected run. Created only
  /// when both artifacts are present; otherwise the scorer never constructs one.
  fileprivate struct Engine {
    let model: MLModel
    let tokenizer: FamoBertTokenizer
    let sequenceLength: Int

    /// Tokenize `text`, run the model, argmax each position, and decode the corrected run. `nil` on
    /// any tokenizer / inference / shape failure so the caller falls back to no-correction.
    func correct(_ text: String) -> String? {
      let ids = tokenizer.encode(text)
      guard ids.count >= 2 else { return nil }  // at least [CLS] [SEP]
      let (inputIDs, attentionMask) = padded(ids)
      guard
        let idArray = makeIntArray(inputIDs),
        let maskArray = makeIntArray(attentionMask)
      else { return nil }

      let inputs: [String: MLFeatureValue] = [
        "input_ids": MLFeatureValue(multiArray: idArray),
        "attention_mask": MLFeatureValue(multiArray: maskArray),
      ]
      guard
        let provider = try? MLDictionaryFeatureProvider(dictionary: inputs),
        let output = try? model.prediction(from: provider),
        let name = output.featureNames.first(where: { output.featureValue(for: $0)?.multiArrayValue != nil }),
        let logits = output.featureValue(for: name)?.multiArrayValue
      else {
        return nil
      }
      // Argmax over the vocab axis at each position, then decode positions 1...text.count.
      guard let argmaxIDs = argmaxPerPosition(logits) else { return nil }
      return FamoCscDecode.corrected(original: text, argmaxIDs: argmaxIDs, tokenizer: tokenizer)
    }

    /// Truncate to `sequenceLength` (keeping `[CLS]`…`[SEP]`) and right-pad with `0`; build the
    /// matching attention mask (`1` for real tokens, `0` for padding).
    private func padded(_ ids: [Int]) -> (ids: [Int], mask: [Int]) {
      var truncated = ids
      if truncated.count > sequenceLength {
        truncated = Array(truncated.prefix(sequenceLength))
        truncated[sequenceLength - 1] = FamoBertTokenizer.sepID
      }
      let realCount = truncated.count
      var padded = truncated
      if padded.count < sequenceLength {
        padded.append(contentsOf: Array(repeating: 0, count: sequenceLength - padded.count))
      }
      let mask = (0..<sequenceLength).map { $0 < realCount ? 1 : 0 }
      return (padded, mask)
    }

    /// Argmax over the vocab axis at each sequence position. The macbert4csc logits tensor is
    /// `[1, seq, vocab]` (or `[seq, vocab]`); we read the trailing two axes as seq × vocab. Returns
    /// one id per position, or `nil` if the shape is not a rank-≥2 seq×vocab tensor.
    private func argmaxPerPosition(_ logits: MLMultiArray) -> [Int]? {
      let shape = logits.shape.map { $0.intValue }
      guard shape.count >= 2 else { return nil }
      let vocabSize = shape[shape.count - 1]
      let seqLen = shape[shape.count - 2]
      guard vocabSize > 0, seqLen > 0 else { return nil }
      let count = logits.count
      guard count >= seqLen * vocabSize else { return nil }
      // Flat layout is row-major: position p's logits occupy [p*vocabSize, (p+1)*vocabSize).
      var result = [Int](repeating: 0, count: seqLen)
      for p in 0..<seqLen {
        let base = p * vocabSize
        var bestID = 0
        var bestVal = -Double.greatestFiniteMagnitude
        for v in 0..<vocabSize {
          let val = logits[base + v].doubleValue
          if val > bestVal {
            bestVal = val
            bestID = v
          }
        }
        result[p] = bestID
      }
      return result
    }

    /// Pack an `[Int]` into a 1×seq `Int32` `MLMultiArray`.
    private func makeIntArray(_ values: [Int]) -> MLMultiArray? {
      guard let array = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32) else {
        return nil
      }
      for (i, v) in values.enumerated() {
        array[i] = NSNumber(value: Int32(v))
      }
      return array
    }
  }
}
