//
//  FamoBertTokenizer.swift
//  法墨输入法 (Famo) — 退格 LM 纠错 · 端上 CSC tokenizer (task 06-22-backspace-typo-correction)
//
//  A pure-Swift Chinese BERT WordPiece tokenizer shared by the on-device CSC scorer
//  (`FamoMacbertCscScorer`). No model, no I/O on the hot path: the vocab is INJECTED at init (the
//  scorer loads the real `vocab.txt` from the bundle when present; tests pass a tiny fixture vocab).
//  When the vocab is absent/empty, `isAvailable == false` so the scorer falls back to a no-op.
//
//  Pipeline (mirrors HF `BertTokenizer`, `do_lower_case`/CJK split as used by macbert4csc):
//    1. basic tokenization — lowercase, strip control chars, split on whitespace + punctuation,
//       and split EVERY CJK character into its own token (so 中文 → "中","文");
//    2. WordPiece — greedy longest-match over the vocab; continuation pieces get a `##` prefix;
//       a token with no match becomes `[UNK]`;
//    3. wrap with `[CLS]` (id 101) … `[SEP]` (id 102) and map every piece to its vocab id.
//
//  Boundary: pure value type, deterministic, off the IMK hot path — only the post-pause / batch
//  CSC step calls it (never per-keystroke). It touches no librime handle and no rime config.
//

import Foundation

/// Pure-Swift Chinese BERT WordPiece tokenizer. Construct with a `token -> id` vocab; an empty
/// vocab yields `isAvailable == false` so callers can fall back without any model present.
struct FamoBertTokenizer {
  /// BERT special tokens. ids match the canonical `bert-base-chinese` / macbert4csc vocab.
  static let clsToken = "[CLS]"
  static let sepToken = "[SEP]"
  static let unkToken = "[UNK]"
  static let clsID = 101
  static let sepID = 102
  static let unkID = 100

  /// Continuation-piece prefix WordPiece uses for non-leading subwords.
  private static let continuationPrefix = "##"
  /// Longest WordPiece span we will try to match — guards a pathological greedy loop.
  private static let maxInputCharsPerWord = 100

  /// `token -> id`. Empty when no vocab was provided (→ `isAvailable == false`).
  private let vocab: [String: Int]
  /// `id -> token`, the inverse of `vocab`. Built once at init so a masked-LM / CSC scorer can
  /// decode an argmax output id per position back to its piece (additive — an `encode`-only
  /// caller never touches it). On duplicate ids the first (lowest line) wins, matching how
  /// `vocab` keeps the first occurrence of a token.
  private let idToToken: [Int: String]
  /// Whether every special token resolves to its canonical id, so the WordPiece ids are usable.
  private let unkID: Int

  /// True only when a non-empty vocab containing the required special tokens was loaded.
  var isAvailable: Bool { !vocab.isEmpty }

  /// Build from a `token -> id` map (the scorer passes the parsed bundle vocab; tests pass a
  /// fixture). The special-token ids fall back to the canonical constants when the map omits them.
  init(vocab: [String: Int]) {
    self.vocab = vocab
    self.unkID = vocab[Self.unkToken] ?? Self.unkID
    var inverse: [Int: String] = [:]
    for (token, id) in vocab where inverse[id] == nil {
      inverse[id] = token
    }
    self.idToToken = inverse
  }

  /// Parse a BERT `vocab.txt` (one token per line, line index == id) into a tokenizer. An empty or
  /// whitespace-only string yields an unavailable tokenizer (`isAvailable == false`).
  init(vocabText: String) {
    var map: [String: Int] = [:]
    var id = 0
    vocabText.enumerateLines { line, _ in
      // BERT vocab.txt entries are bare tokens, one per line; the line index is the id. Real BERT
      // tokens carry no surrounding whitespace, so a whitespace-only line is not a token — trim and
      // skip it (this also makes a blank vocab text yield an unavailable tokenizer). The id still
      // advances per physical line so genuine tokens keep their canonical line-index ids.
      let token = line.trimmingCharacters(in: .whitespaces)
      if !token.isEmpty {
        if map[token] == nil { map[token] = id }
      }
      id += 1
    }
    self.init(vocab: map)
  }

  /// Look up a token's id, or `nil` if absent.
  func id(for token: String) -> Int? { vocab[token] }

  /// Inverse lookup: the piece for an id, or `nil` if absent. Used by the CSC scorer to decode a
  /// per-position argmax id back to its character. A leading `##` continuation prefix is stripped so
  /// the caller gets the bare CJK character (CSC corrects single CJK chars, which tokenize as
  /// leading, prefix-less pieces — the strip is belt-and-suspenders).
  func token(for id: Int) -> String? {
    guard let piece = idToToken[id] else { return nil }
    if piece.hasPrefix(Self.continuationPrefix) {
      return String(piece.dropFirst(Self.continuationPrefix.count))
    }
    return piece
  }

  /// Tokenize `text` into WordPiece tokens WITHOUT special-token wrapping (for inspection / tests).
  func wordPieceTokens(_ text: String) -> [String] {
    guard isAvailable else { return [] }
    var pieces: [String] = []
    for basic in basicTokenize(text) {
      pieces.append(contentsOf: wordPiece(basic))
    }
    return pieces
  }

  /// Full token sequence with `[CLS]` … `[SEP]` wrapping. Empty when unavailable.
  func tokenize(_ text: String) -> [String] {
    guard isAvailable else { return [] }
    return [Self.clsToken] + wordPieceTokens(text) + [Self.sepToken]
  }

  /// Encode `text` to vocab ids, wrapped with `[CLS]`/`[SEP]`. Unknown pieces map to `[UNK]`'s id.
  /// Returns `[]` when the tokenizer is unavailable (no vocab) — the caller then falls back.
  func encode(_ text: String) -> [Int] {
    guard isAvailable else { return [] }
    return tokenize(text).map { vocab[$0] ?? unkID }
  }

  // MARK: - Basic tokenization

  /// Lowercase, drop control chars, split on whitespace + punctuation, and split each CJK char into
  /// its own token. Returns the whitespace/punctuation/CJK-segmented word list fed to WordPiece.
  private func basicTokenize(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""

    func flush() {
      if !current.isEmpty {
        tokens.append(current)
        current = ""
      }
    }

    for scalar in text.unicodeScalars {
      if Self.isControl(scalar) { continue }
      if Self.isWhitespace(scalar) {
        flush()
        continue
      }
      if Self.isCJK(scalar) {
        // Each CJK char is its own token: flush the pending run, emit the char, keep going.
        flush()
        tokens.append(String(scalar).lowercased())
        continue
      }
      if Self.isPunctuation(scalar) {
        flush()
        tokens.append(String(scalar))
        continue
      }
      current.unicodeScalars.append(scalar)
      // Lowercasing is applied per-flush below so multi-scalar graphemes stay intact.
    }
    flush()
    return tokens.map { $0.lowercased() }
  }

  // MARK: - WordPiece

  /// Greedy longest-match WordPiece over `token`. Non-leading pieces are `##`-prefixed; if no
  /// prefix of the remaining span is in the vocab, the WHOLE token becomes a single `[UNK]`.
  private func wordPiece(_ token: String) -> [String] {
    let chars = Array(token)
    if chars.count > Self.maxInputCharsPerWord { return [Self.unkToken] }

    var pieces: [String] = []
    var start = 0
    while start < chars.count {
      var end = chars.count
      var matched: String? = nil
      while start < end {
        var piece = String(chars[start..<end])
        if start > 0 { piece = Self.continuationPrefix + piece }
        if vocab[piece] != nil {
          matched = piece
          break
        }
        end -= 1
      }
      guard let found = matched else {
        // Any unmatched span makes the entire token unknown (BERT WordPiece semantics).
        return [Self.unkToken]
      }
      pieces.append(found)
      start = end
    }
    return pieces
  }

  // MARK: - Character classes (mirrors HF BasicTokenizer)

  /// CJK ranges treated as single-character tokens (matches HF `_is_chinese_char`).
  static func isCJK(_ scalar: UnicodeScalar) -> Bool {
    let v = scalar.value
    return (0x4E00...0x9FFF).contains(v)
      || (0x3400...0x4DBF).contains(v)
      || (0x20000...0x2A6DF).contains(v)
      || (0x2A700...0x2B73F).contains(v)
      || (0x2B740...0x2B81F).contains(v)
      || (0x2B820...0x2CEAF).contains(v)
      || (0xF900...0xFAFF).contains(v)
      || (0x2F800...0x2FA1F).contains(v)
  }

  private static func isWhitespace(_ scalar: UnicodeScalar) -> Bool {
    if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { return true }
    return scalar.properties.generalCategory == .spaceSeparator
  }

  private static func isControl(_ scalar: UnicodeScalar) -> Bool {
    if scalar == "\t" || scalar == "\n" || scalar == "\r" { return false }
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator:
      return true
    default:
      return false
    }
  }

  private static func isPunctuation(_ scalar: UnicodeScalar) -> Bool {
    let v = scalar.value
    // HF treats the ASCII non-alphanumeric punctuation bands as punctuation too.
    if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) {
      return true
    }
    switch scalar.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
         .initialPunctuation, .finalPunctuation, .otherPunctuation:
      return true
    default:
      return false
    }
  }
}
