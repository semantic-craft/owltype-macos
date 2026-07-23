//
//  BertTokenizerTests.swift
//  FamoTests — 退格 LM 纠错 · 端上 CSC tokenizer (task 06-22-backspace-typo-correction)
//
//  Locks the pure-Swift BERT WordPiece tokenizer (shared by `FamoMacbertCscScorer`) on four axes,
//  all with a TINY FIXTURE vocab (no real 21128-line vocab, no model, no I/O):
//    1. `[CLS]`/`[SEP]` wrapping (ids 101 / 102) around every encode/tokenize;
//    2. every CJK char becomes its own token;
//    3. greedy longest-match subword with `##` continuation pieces;
//    4. unknown spans collapse to `[UNK]`; an empty vocab is unavailable (→ scorer fallback).
//

import Foundation
import XCTest
@testable import Famo

final class BertTokenizerTests: XCTestCase {

  // MARK: - Fixture vocab

  /// A small fixture vocab covering the special tokens, a few CJK chars, and an English word split
  /// into `play` + `##ing` so greedy WordPiece has a real continuation piece to find.
  private func fixtureTokenizer() -> FamoBertTokenizer {
    let tokens: [(String, Int)] = [
      ("[PAD]", 0),
      ("[UNK]", 100),
      ("[CLS]", 101),
      ("[SEP]", 102),
      ("正", 200),
      ("当", 201),
      ("防", 202),
      ("卫", 203),
      ("play", 300),
      ("##ing", 301),
      ("un", 302),
      ("##aff", 303),
      ("##able", 304),
    ]
    var map: [String: Int] = [:]
    for (t, id) in tokens { map[t] = id }
    return FamoBertTokenizer(vocab: map)
  }

  // MARK: - 1. [CLS]/[SEP] wrapping

  func testTokenizeWrapsWithClsAndSep() {
    let tok = fixtureTokenizer()
    let tokens = tok.tokenize("正当")
    XCTAssertEqual(tokens.first, "[CLS]")
    XCTAssertEqual(tokens.last, "[SEP]")
    XCTAssertEqual(tokens, ["[CLS]", "正", "当", "[SEP]"])
  }

  func testEncodeWrapsWithClsSepIDs() {
    let tok = fixtureTokenizer()
    let ids = tok.encode("正")
    XCTAssertEqual(ids.first, 101)  // [CLS]
    XCTAssertEqual(ids.last, 102)   // [SEP]
    XCTAssertEqual(ids, [101, 200, 102])
  }

  // MARK: - 2. CJK char per token

  func testEachCJKCharIsItsOwnToken() {
    let tok = fixtureTokenizer()
    XCTAssertEqual(tok.wordPieceTokens("正当防卫"), ["正", "当", "防", "卫"])
  }

  func testCJKCharsSplitEvenWithoutSpaces() {
    let tok = fixtureTokenizer()
    // No whitespace between the chars — they must still each become a single token.
    let ids = tok.encode("防卫")
    XCTAssertEqual(ids, [101, 202, 203, 102])
  }

  // MARK: - 3. Greedy `##` subword

  func testGreedyWordPieceContinuationPieces() {
    let tok = fixtureTokenizer()
    // "playing" → "play" + "##ing" (greedy longest-match leading piece, then continuation).
    XCTAssertEqual(tok.wordPieceTokens("playing"), ["play", "##ing"])
  }

  func testGreedyMultiPieceSubword() {
    let tok = fixtureTokenizer()
    // "unaffable" → "un" + "##aff" + "##able".
    XCTAssertEqual(tok.wordPieceTokens("unaffable"), ["un", "##aff", "##able"])
  }

  // MARK: - 4. Unknown → [UNK]

  func testUnknownWordCollapsesToUnk() {
    let tok = fixtureTokenizer()
    // No prefix of "xyz" is in the vocab → whole token is [UNK].
    XCTAssertEqual(tok.wordPieceTokens("xyz"), ["[UNK]"])
  }

  func testUnknownCJKCharIsUnk() {
    let tok = fixtureTokenizer()
    // "案" is not in the fixture vocab → [UNK] (still its own CJK token first).
    let ids = tok.encode("案")
    XCTAssertEqual(ids, [101, 100, 102])  // [CLS] [UNK] [SEP]
  }

  func testPartiallyUnknownWordCollapsesEntirely() {
    let tok = fixtureTokenizer()
    // "play" is known but "playz" has an unmatchable tail → BERT WordPiece makes the WHOLE token UNK.
    XCTAssertEqual(tok.wordPieceTokens("playz"), ["[UNK]"])
  }

  // MARK: - Availability / fallback signal

  func testEmptyVocabIsUnavailable() {
    let tok = FamoBertTokenizer(vocab: [:])
    XCTAssertFalse(tok.isAvailable)
    XCTAssertTrue(tok.encode("正当防卫").isEmpty)
    XCTAssertTrue(tok.tokenize("正当防卫").isEmpty)
  }

  func testBlankVocabTextIsUnavailable() {
    let tok = FamoBertTokenizer(vocabText: "   \n\n   ")
    XCTAssertFalse(tok.isAvailable)
  }

  func testVocabTextLineIndexIsID() {
    // Build from vocab.txt form: line index == id.
    let text = "[PAD]\n[UNK]\nfoo\nbar"
    // [PAD]=0, [UNK]=1, foo=2, bar=3 — but special-token ids fall back to canon for [CLS]/[SEP].
    let tok = FamoBertTokenizer(vocabText: text)
    XCTAssertTrue(tok.isAvailable)
    XCTAssertEqual(tok.id(for: "foo"), 2)
    XCTAssertEqual(tok.id(for: "bar"), 3)
  }
}
