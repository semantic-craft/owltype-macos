//
//  OwlVoiceHotwordsExtractorTests.swift
//  OwltypeTests — Lane B: Hotwords Extraction & 800-Byte Prompt Budgeting Tests (#396)
//

import AppKit
import InputMethodKit
import SQLite3
import XCTest
@testable import Owltype

final class OwlVoiceHotwordsExtractorTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hotwords_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("msime_user.db")
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: tempDir.path) {
      try? FileManager.default.removeItem(at: tempDir)
    }
    tempDir = nil
    dbURL = nil
    try super.tearDownWithError()
  }

  // MARK: - Test Database Builder Helper

  private func createTestDatabase(
    pinned: [(key: String, value: String, updated: Int)] = [],
    custom: [(dict: String, key: String, value: String, op: String, weight: Int, userInserted: Int, updated: Int)] = [],
    bigrams: [(prev: String, word: String, count: Int)] = []
  ) {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }

    let ddl = """
    CREATE TABLE pinned_candidates(context_key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL DEFAULT(unixepoch()));
    CREATE TABLE user_dictionary_operations(dictionary TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, operation TEXT NOT NULL, weight INTEGER NOT NULL DEFAULT 0, display TEXT NOT NULL DEFAULT '', user_inserted INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT(unixepoch()), PRIMARY KEY(dictionary,key,value));
    CREATE TABLE personal_bigram(previous TEXT NOT NULL, word TEXT NOT NULL, count INTEGER NOT NULL CHECK(count>0), PRIMARY KEY(previous,word)) WITHOUT ROWID;
    """
    XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)

    for p in pinned {
      let sql = "INSERT INTO pinned_candidates VALUES ('\(p.key)', '\(p.value)', \(p.updated));"
      XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    for c in custom {
      let sql = "INSERT INTO user_dictionary_operations VALUES ('\(c.dict)', '\(c.key)', '\(c.value)', '\(c.op)', \(c.weight), '', \(c.userInserted), \(c.updated));"
      XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    for b in bigrams {
      let prevSql: String
      if b.prev == "\u{0001}" {
        prevSql = "char(1)"
      } else if b.prev == "\u{0000}" {
        prevSql = "char(0)"
      } else if b.prev == "\u{0002}" {
        prevSql = "char(2)"
      } else {
        prevSql = "'\(b.prev)'"
      }
      let sql = "INSERT INTO personal_bigram VALUES (\(prevSql), '\(b.word)', \(b.count));"
      XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
  }

  // MARK: - 1. Three-Source Extraction & Priority Ordering

  func testExtractHotwordsFromAllThreeSources() {
    createTestDatabase(
      pinned: [("k1", "深度学习", 100)],
      custom: [("pinyin", "k2", "自然语言处理", "upsert", 10, 1, 200)],
      bigrams: [("大语言", "模型", 80), ("\u{0001}", "人工智能", 50)]
    )

    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { ["内存置顶词"] }
    )

    let hotwords = extractor.extractHotwords(limit: 10)
    XCTAssertEqual(hotwords, ["内存置顶词", "深度学习", "自然语言处理", "大语言模型", "人工智能"])
  }

  // MARK: - 2. Priority Deduplication (Pinned > Custom > Bigram)

  func testPriorityDeduplicationPreservesHigherTier() {
    createTestDatabase(
      pinned: [("k1", "重复词", 100)],
      custom: [("pinyin", "k2", "重复词", "upsert", 100, 1, 500), ("pinyin", "k3", "自造词", "upsert", 50, 1, 200)],
      bigrams: [("\u{0001}", "重复词", 1000), ("\u{0001}", "自造词", 2000), ("\u{0001}", "二元词", 500)]
    )

    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { ["重复词"] }
    )

    let hotwords = extractor.extractHotwords(limit: 10)
    XCTAssertEqual(hotwords, ["重复词", "自造词", "二元词"])
    XCTAssertEqual(hotwords.filter { $0 == "重复词" }.count, 1)
  }

  // MARK: - 3. Bigram Sentence-Start and Low-Frequency Filtering

  func testBigramSentenceStartConcatenationAndOccurrenceFiltering() {
    createTestDatabase(
      bigrams: [
        ("\u{0001}", "始发词", 100),
        ("", "空前导词", 80),
        ("联合", "发展", 50),
        ("罕见", "词汇", 1) // count <= 1 must be filtered out
      ]
    )

    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { [] }
    )

    let hotwords = extractor.extractHotwords(limit: 10)
    XCTAssertTrue(hotwords.contains("始发词"))
    XCTAssertTrue(hotwords.contains("空前导词"))
    XCTAssertTrue(hotwords.contains("联合发展"))
    XCTAssertFalse(hotwords.contains("罕见词汇"))
  }

  // MARK: - 4. Deleted Custom Words Tombstone Exclusion

  func testTombstonedCustomWordsExcluded() {
    createTestDatabase(
      custom: [
        ("pinyin", "k1", "活跃自造词", "upsert", 10, 1, 100),
        ("pinyin", "k2", "已删除词", "delete", 0, 1, 200)
      ]
    )

    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { [] }
    )

    let hotwords = extractor.extractHotwords(limit: 10)
    XCTAssertEqual(hotwords, ["活跃自造词"])
    XCTAssertFalse(hotwords.contains("已删除词"))
  }

  // MARK: - 5. Sanitization: Single-Char, Punctuation, Whitespace, Commas

  func testSanitizeTokenFilteringRules() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })

    // Single-character tokens (count <= 1) are rejected
    XCTAssertNil(extractor.sanitizeToken("我"))
    XCTAssertNil(extractor.sanitizeToken("a"))
    XCTAssertNil(extractor.sanitizeToken("1"))
    XCTAssertNil(extractor.sanitizeToken("🇨🇳"))

    // Pure punctuation and symbols are rejected
    XCTAssertNil(extractor.sanitizeToken("——"))
    XCTAssertNil(extractor.sanitizeToken("..."))
    XCTAssertNil(extractor.sanitizeToken("！？"))
    XCTAssertNil(extractor.sanitizeToken("，。、；："))
    XCTAssertNil(extractor.sanitizeToken("+=-*&^%$#@!"))
    XCTAssertNil(extractor.sanitizeToken("😀😁🎉"))

    // Newlines and control characters are rejected
    XCTAssertNil(extractor.sanitizeToken("猫头\n鹰"))
    XCTAssertNil(extractor.sanitizeToken("Deep\r\nSeek"))
    XCTAssertNil(extractor.sanitizeToken("\u{0001}Hello"))
    XCTAssertNil(extractor.sanitizeToken("   "))

    // Valid multi-character words with alphanumeric/CJK are preserved
    XCTAssertEqual(extractor.sanitizeToken("  猫头鹰  "), "猫头鹰")
    XCTAssertEqual(extractor.sanitizeToken("AI"), "AI")
    XCTAssertEqual(extractor.sanitizeToken("C++"), "C++")
    XCTAssertEqual(extractor.sanitizeToken("A/B"), "A/B")
    XCTAssertEqual(extractor.sanitizeToken("iOS 18"), "iOS 18")
    XCTAssertEqual(extractor.sanitizeToken("Grok-3"), "Grok-3")

    // Internal commas are converted to spaces without delimiter corruption
    XCTAssertEqual(extractor.sanitizeToken("TCP,IP"), "TCP IP")
    XCTAssertEqual(extractor.sanitizeToken("你好，世界"), "你好 世界")
  }

  // MARK: - 6. Character-Safe Suffix Slicing (CJK & Emoji ZWJ Boundaries)

  func testTokenSafeSuffixCJKAndEmojiBoundaries() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })

    // 1. CJK slicing: "你好猫" (9 bytes) with maxBytes: 5
    // '猫' is 3 bytes <= 5; '好' would make 6 bytes > 5. Returns "猫".
    let cjkSuffix = extractor.tokenSafeSuffix("你好猫", maxBytes: 5)
    XCTAssertEqual(cjkSuffix, "猫")
    XCTAssertEqual(cjkSuffix.utf8.count, 3)

    // 2. Complex ZWJ Emoji: 👨‍👩‍👧‍👦 (25 bytes)
    let familyEmoji = "👨‍👩‍👧‍👦"
    let text = "Hello " + familyEmoji

    // Budget of 20 bytes cannot fit family emoji (25 bytes). Must return empty string cleanly without ZWJ corruption.
    let emojiSuffixCapped = extractor.tokenSafeSuffix(text, maxBytes: 20)
    XCTAssertEqual(emojiSuffixCapped, "")

    // Budget of 35 bytes fits both "Hello " (6B) and family (25B) = 31B
    let emojiSuffixFit = extractor.tokenSafeSuffix(text, maxBytes: 35)
    XCTAssertEqual(emojiSuffixFit, text)

    // 3. Flag emoji: 🇨🇳 (8 bytes) with maxBytes: 6 -> returns empty
    XCTAssertEqual(extractor.tokenSafeSuffix("🇨🇳", maxBytes: 6), "")

    // 4. Combining acute accent: e + \u{0301} (3 bytes) with maxBytes: 2 -> returns empty
    XCTAssertEqual(extractor.tokenSafeSuffix("e\u{0301}", maxBytes: 2), "")
  }

  // MARK: - 7. Token-Safe 800-Byte UTF-8 Budget Truncation

  func testBuildPromptEnforces800BytesWithoutChoppingToken() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })

    // Generate 200 distinct 4-character words (each ~12 bytes + 3 bytes separator = ~15 bytes each)
    let words = (0..<200).map { String(format: "热词测试%03d", $0) }
    let prompt = extractor.buildPrompt(preContext: "正在编写代码", hotwords: words, maxBytes: 800)

    XCTAssertLessThanOrEqual(prompt.utf8.count, 800)
    XCTAssertTrue(prompt.hasPrefix("前文：正在编写代码\n热词："))
    XCTAssertNotNil(prompt.data(using: .utf8), "Must be valid well-formed UTF-8")

    // Ensure prompt never ends with a trailing separator
    XCTAssertFalse(prompt.hasSuffix("，"))
    XCTAssertFalse(prompt.hasSuffix(","))

    // Ensure the last token is complete
    let lastToken = prompt.components(separatedBy: "，").last ?? ""
    XCTAssertFalse(lastToken.isEmpty)
    XCTAssertTrue(lastToken.hasPrefix("热词测试"))
    XCTAssertEqual(lastToken.count, 7) // "热词测试" (4) + 3 digits = 7 characters
  }

  func testBuildPromptPreContextSuffixTrimmingOnLongContext() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })
    let longContext = String(repeating: "超长前文上下文测试句子。", count: 50)
    let prompt = extractor.buildPrompt(preContext: longContext, hotwords: ["置顶词"], maxBytes: 800)

    XCTAssertLessThanOrEqual(prompt.utf8.count, 800)
    XCTAssertTrue(prompt.contains("热词：置顶词"))
    XCTAssertTrue(prompt.hasPrefix("前文："))
  }

  // MARK: - 8. Prompt Assembly Template Variations

  func testPromptAssemblyTemplateVariations() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })

    // Both preContext and hotwords
    let both = extractor.buildPrompt(preContext: "正在打字", hotwords: ["猫头鹰", "输入法"], maxBytes: 800)
    XCTAssertEqual(both, "前文：正在打字\n热词：猫头鹰，输入法")

    // Context only (hotwords empty)
    let ctxOnly = extractor.buildPrompt(preContext: "正在打字", hotwords: [], maxBytes: 800)
    XCTAssertEqual(ctxOnly, "前文：正在打字")

    // Hotwords only (context nil/empty)
    let hotwordsOnly = extractor.buildPrompt(preContext: nil, hotwords: ["猫头鹰", "输入法"], maxBytes: 800)
    XCTAssertEqual(hotwordsOnly, "热词：猫头鹰，输入法")

    // Both nil or empty
    let bothEmpty = extractor.buildPrompt(preContext: "   ", hotwords: [], maxBytes: 800)
    XCTAssertEqual(bothEmpty, "")
  }

  // MARK: - 9. Safe Fallback on Missing or Corrupted Database

  func testMissingDatabaseFallback() {
    let missingURL = tempDir.appendingPathComponent("nonexistent.db")
    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: missingURL,
      inMemoryPinnedWordsProvider: { ["降级置顶词"] }
    )

    let hotwords = extractor.extractHotwords(limit: 10)
    XCTAssertEqual(hotwords, ["降级置顶词"])
  }

  func testCorruptedDatabaseFallback() throws {
    try Data([0xFF, 0xEE, 0xDD, 0xCC, 0xBB]).write(to: dbURL)
    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { ["降级置顶词"] }
    )

    let hotwords = extractor.extractHotwords(limit: 10)
    XCTAssertEqual(hotwords, ["降级置顶词"])
  }

  // MARK: - 10. Coordinator Integration with Prompt Injection

  @MainActor
  func testCoordinatorIntegrationPassesHotwordPromptToASR() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    var capturedPrompt: String?
    let stubTransport = OwlStubVoiceTransport { req in
      let bodyData = req.httpBody ?? Data()
      let bodyString = String(decoding: bodyData, as: UTF8.self)
      // Extract prompt from multipart body if present
      if let promptRange = bodyString.range(of: "name=\"prompt\"\r\n\r\n") {
        let remainder = bodyString[promptRange.upperBound...]
        if let endRange = remainder.range(of: "\r\n") {
          capturedPrompt = String(remainder[..<endRange.lowerBound])
        }
      }

      let json = "{\"text\": \"转写上屏完成\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }

    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    // Inject custom hotwords extractor
    let mockExtractor = OwlVoiceHotwordsExtractor(
      databaseURL: nil,
      inMemoryPinnedWordsProvider: { ["专有名词", "热词"] }
    )
    coordinator.hotwordsExtractor = mockExtractor

    let mockClient = MockVoiceTextInputClientWithPreContext(
      simulatedPreContext: "上一句话的前文"
    )
    coordinator.targetSnapshotProvider = {
      OwlVoiceTargetSnapshot(
        client: mockClient,
        caretAnchor: NSRect(x: 100, y: 100, width: 2, height: 16),
        preContext: mockClient.preContextString
      )
    }

    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    // Trigger key down
    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(down))

    // Verify snapshot preContext was captured
    XCTAssertEqual(coordinator.targetSnapshot?.preContext, "上一句话的前文")

    // Finish recording and transcribe
    coordinator.finishRecordingAndTranscribe()

    // Wait for async task to complete
    for _ in 0..<30 {
      if !mockClient.insertedTexts.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTAssertEqual(mockClient.insertedTexts, ["转写上屏完成"])
    XCTAssertNotNil(capturedPrompt)
    XCTAssertTrue(capturedPrompt?.contains("前文：上一句话的前文") == true)
    XCTAssertTrue(capturedPrompt?.contains("热词：专有名词，热词") == true)
  }

  // MARK: - Adversarial Stress Tests: Boundary Conditions & Unicode Attacks (#396 Challenger)

  func testAdversarialBoundaryExact800Bytes() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })

    // Case 1: Without preContext.
    // Header is "热词：" (9 UTF-8 bytes).
    // Word is exactly 791 ASCII bytes.
    // Total assembled prompt = 9 + 791 = 800 bytes exactly.
    let word791 = String(repeating: "A", count: 791)
    let promptNoCtx = extractor.buildPrompt(preContext: nil, hotwords: [word791], maxBytes: 800)

    XCTAssertEqual(promptNoCtx.utf8.count, 800)
    XCTAssertEqual(promptNoCtx, "热词：" + word791)
    XCTAssertNotNil(String(data: Data(promptNoCtx.utf8), encoding: .utf8), "Must be valid UTF-8")

    // Case 2: With preContext.
    // "前文测试" is 12 UTF-8 bytes.
    // Context part: "前文：前文测试" (9 + 12 = 21 bytes).
    // Header: "前文：前文测试\n热词：" (21 + 1 + 9 = 31 bytes).
    // Word: exactly (800 - 31) = 769 ASCII bytes.
    // Total assembled prompt = 31 + 769 = 800 bytes exactly.
    let word769 = String(repeating: "B", count: 769)
    let promptWithCtx = extractor.buildPrompt(preContext: "前文测试", hotwords: [word769], maxBytes: 800)

    XCTAssertEqual(promptWithCtx.utf8.count, 800)
    XCTAssertTrue(promptWithCtx.hasPrefix("前文：前文测试\n热词："))
    XCTAssertTrue(promptWithCtx.hasSuffix(word769))
    XCTAssertNotNil(String(data: Data(promptWithCtx.utf8), encoding: .utf8), "Must be valid UTF-8")
  }

  func testAdversarialBoundary801BytesDropping() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })

    // Case 1: First word leaves budget such that adding second word exceeds 800 by exactly 1 byte (801 bytes).
    // Header: "热词：" (9 bytes).
    // Word 1: 785 bytes ASCII.
    // Current bytes after word 1 = 9 + 785 = 794 bytes.
    // Separator "，" is 3 bytes.
    // Remaining budget = 800 - 794 - 3 = 3 bytes.
    // Word 2: 4 bytes ("Drop").
    // Needed for Word 2 = 3 + 4 = 7 bytes. 794 + 7 = 801 bytes > 800!
    // Result: Word 2 must be dropped. Total bytes must be 794 (<= 800).
    let word1 = String(repeating: "X", count: 785)
    let word2 = "Drop"
    let prompt = extractor.buildPrompt(preContext: nil, hotwords: [word1, word2], maxBytes: 800)

    XCTAssertEqual(prompt.utf8.count, 794)
    XCTAssertLessThanOrEqual(prompt.utf8.count, 800)
    XCTAssertEqual(prompt, "热词：" + word1)
    XCTAssertFalse(prompt.contains("Drop"))
    XCTAssertFalse(prompt.hasSuffix("，"))
    XCTAssertNotNil(String(data: Data(prompt.utf8), encoding: .utf8))

    // Case 2: Single hotword of 792 bytes causes header (9) + word (792) = 801 bytes.
    // Must be completely rejected, returning empty string.
    let word792 = String(repeating: "Y", count: 792)
    let promptSingleOver = extractor.buildPrompt(preContext: nil, hotwords: [word792], maxBytes: 800)
    XCTAssertEqual(promptSingleOver, "")
    XCTAssertEqual(promptSingleOver.utf8.count, 0)
  }

  func testAdversarialSingleExtremeHotword805Bytes() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })
    let word805 = String(repeating: "Z", count: 805)

    // Sub-case A: Nil preContext.
    // 805-byte word exceeds maxBytes (800). Must be rejected without slicing into a truncated token.
    let promptNoCtx = extractor.buildPrompt(preContext: nil, hotwords: [word805], maxBytes: 800)
    XCTAssertEqual(promptNoCtx, "")
    XCTAssertEqual(promptNoCtx.utf8.count, 0)

    // Sub-case B: With preContext.
    // Context is preserved, but 805-byte word is rejected completely.
    let promptWithCtx = extractor.buildPrompt(preContext: "光标前文", hotwords: [word805], maxBytes: 800)
    XCTAssertEqual(promptWithCtx, "前文：光标前文")
    XCTAssertEqual(promptWithCtx.utf8.count, "前文：光标前文".utf8.count)
    XCTAssertFalse(promptWithCtx.contains("Z"))
    XCTAssertNotNil(String(data: Data(promptWithCtx.utf8), encoding: .utf8))
  }

  func testAdversarialPreContext1000Characters() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })

    // Construct 1000 distinct Unicode characters:
    // 400 ASCII chars ("a"..."z")
    // 300 CJK chars (3 bytes each)
    // 100 Astral code points (U+20BB7 '𠮷', 4 bytes each)
    // 100 Combining accent chars ("e\u{0301}", 3 bytes each)
    // 100 Emoji chars ("🌟", 4 bytes each)
    // Total = 1000 Characters (extended grapheme clusters)
    var text1000 = ""
    for i in 0..<400 {
      text1000.append(Character(UnicodeScalar(97 + (i % 26))!))
    }
    for _ in 0..<300 {
      text1000.append("语")
    }
    for _ in 0..<100 {
      text1000.append("𠮷")
    }
    for _ in 0..<100 {
      text1000.append(Character("e\u{0301}"))
    }
    for _ in 0..<100 {
      text1000.append("🌟")
    }

    XCTAssertEqual(text1000.count, 1000)

    // Test tokenSafeSuffix with maxContextBytes = 300
    let suffix = extractor.tokenSafeSuffix(text1000, maxBytes: 300)
    XCTAssertLessThanOrEqual(suffix.utf8.count, 300)
    XCTAssertGreaterThan(suffix.utf8.count, 0)
    XCTAssertTrue(text1000.hasSuffix(suffix), "Must preserve suffix closest to cursor")
    XCTAssertNotNil(String(data: Data(suffix.utf8), encoding: .utf8), "Must not break UTF-8 sequences")

    // Verify in buildPrompt
    let prompt = extractor.buildPrompt(preContext: text1000, hotwords: ["置顶词", "专有名词"], maxBytes: 800)
    XCTAssertLessThanOrEqual(prompt.utf8.count, 800)
    XCTAssertTrue(prompt.hasPrefix("前文："))
    XCTAssertTrue(prompt.contains("热词：置顶词，专有名词"))
    XCTAssertNotNil(String(data: Data(prompt.utf8), encoding: .utf8), "Full prompt must be valid UTF-8")
  }

  func testAdversarialUnicodeGraphemeClustersCombos() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })

    // 1. Combining accents: "café" with decomposed 'e' + '\u{0301}' (3 bytes)
    let combiningText = "caf" + "e\u{0301}"
    for budget in 1...15 {
      let suffix = extractor.tokenSafeSuffix(combiningText, maxBytes: budget)
      XCTAssertLessThanOrEqual(suffix.utf8.count, budget)
      XCTAssertTrue(combiningText.hasSuffix(suffix))
      XCTAssertNotNil(String(data: Data(suffix.utf8), encoding: .utf8), "Never corrupt combining mark at budget \(budget)")
    }
    // With budget 2, "e\u{0301}" (3 bytes) cannot fit, so suffix is empty
    XCTAssertEqual(extractor.tokenSafeSuffix("e\u{0301}", maxBytes: 2), "")
    // With budget 3, "e\u{0301}" fits completely
    XCTAssertEqual(extractor.tokenSafeSuffix("e\u{0301}", maxBytes: 3), "e\u{0301}")

    // 2. 4-byte astral characters (U+20BB7 '𠮷')
    let astralText = "汉字𠮷"
    for budget in 1...15 {
      let suffix = extractor.tokenSafeSuffix(astralText, maxBytes: budget)
      XCTAssertLessThanOrEqual(suffix.utf8.count, budget)
      XCTAssertTrue(astralText.hasSuffix(suffix))
      XCTAssertNotNil(String(data: Data(suffix.utf8), encoding: .utf8), "Never split astral character at budget \(budget)")
    }
    XCTAssertEqual(extractor.tokenSafeSuffix("𠮷", maxBytes: 3), "")
    XCTAssertEqual(extractor.tokenSafeSuffix("𠮷", maxBytes: 4), "𠮷")

    // 3. Flag emojis: 2 regional indicators (8 UTF-8 bytes)
    let flagUS = "🇺🇸" // \u{1F1FA}\u{1F1F8} = 8 bytes
    for budget in 1...7 {
      XCTAssertEqual(extractor.tokenSafeSuffix(flagUS, maxBytes: budget), "", "Flag cannot fit in < 8 bytes")
    }
    XCTAssertEqual(extractor.tokenSafeSuffix(flagUS, maxBytes: 8), flagUS)

    // 4. Family ZWJ emoji: 👨‍👩‍👧‍👦 (25 UTF-8 bytes)
    let family = "👨‍👩‍👧‍👦"
    for budget in 1...24 {
      XCTAssertEqual(extractor.tokenSafeSuffix(family, maxBytes: budget), "", "Family ZWJ cannot fit in < 25 bytes")
    }
    XCTAssertEqual(extractor.tokenSafeSuffix(family, maxBytes: 25), family)

    // 5. Additional complex ZWJ emojis:
    // Woman technologist: 👩‍💻 (11 bytes)
    let technologist = "👩‍💻"
    for budget in 1...10 {
      XCTAssertEqual(extractor.tokenSafeSuffix(technologist, maxBytes: budget), "")
    }
    XCTAssertEqual(extractor.tokenSafeSuffix(technologist, maxBytes: 11), technologist)

    // Rainbow flag: 🏳️‍🌈 (14 UTF-8 bytes: \u{1F3F3}\u{FE0F}\u{200D}\u{1F308})
    let rainbow = "🏳️‍🌈"
    for budget in 1...13 {
      XCTAssertEqual(extractor.tokenSafeSuffix(rainbow, maxBytes: budget), "", "Rainbow flag cannot fit in < 14 bytes")
    }
    XCTAssertEqual(extractor.tokenSafeSuffix(rainbow, maxBytes: 14), rainbow)

    // Keycap number: 1️⃣ (7 bytes)
    let keycap = "1️⃣"
    for budget in 1...6 {
      XCTAssertEqual(extractor.tokenSafeSuffix(keycap, maxBytes: budget), "")
    }
    XCTAssertEqual(extractor.tokenSafeSuffix(keycap, maxBytes: 7), keycap)

    // Skin tone modifier: 👍🏽 (8 bytes)
    let skinTone = "👍🏽"
    for budget in 1...7 {
      XCTAssertEqual(extractor.tokenSafeSuffix(skinTone, maxBytes: budget), "")
    }
    XCTAssertEqual(extractor.tokenSafeSuffix(skinTone, maxBytes: 8), skinTone)
  }

  func testAdversarialGraphemeClustersInBuildPrompt() {
    let extractor = OwlVoiceHotwordsExtractor(databaseURL: nil, inMemoryPinnedWordsProvider: { [] })

    let context = "复杂的上下文：包含 🇨🇳 国旗、👨‍👩‍👧‍👦 家庭表情以及 𠮷 汉字和 café\u{0301}"
    let hotwords = [
      "Swift 6.0",
      "C++20",
      "👨‍💻开发者",
      "🇺🇸硅谷",
      "café\u{0301}馆",
      "深度学习",
      "大模型"
    ]

    let prompt = extractor.buildPrompt(preContext: context, hotwords: hotwords, maxBytes: 800)

    XCTAssertLessThanOrEqual(prompt.utf8.count, 800)
    XCTAssertTrue(prompt.hasPrefix("前文："))
    XCTAssertTrue(prompt.contains("\n热词："))
    XCTAssertFalse(prompt.hasSuffix("，"))
    XCTAssertNotNil(String(data: Data(prompt.utf8), encoding: .utf8), "Prompt must be strictly valid UTF-8")

    // Verify every hotword in the prompt is complete and not truncated
    let parts = prompt.components(separatedBy: "\n热词：")
    XCTAssertEqual(parts.count, 2)
    let promptWords = parts[1].components(separatedBy: "，")
    for pw in promptWords {
      XCTAssertTrue(hotwords.contains(pw), "Token '\(pw)' must be one of the original hotwords, not a chopped slice")
    }
  }

  // MARK: - Adversarial Stress Tests: SQLite Resilience & Bigram Token Attacks (#396 Challenger)

  func testAdversarialSQLiteDatabaseCorruptionsAndTruncations() throws {
    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { ["降级词1", "降级词2"] }
    )

    // 1. Zero-byte truncated file
    try Data().write(to: dbURL)
    XCTAssertEqual(extractor.extractHotwords(limit: 10), ["降级词1", "降级词2"])

    // 2. Valid 16-byte SQLite header followed by corrupted garbage bytes
    var headerAndGarbage = "SQLite format 3\0".data(using: .utf8)!
    headerAndGarbage.append(contentsOf: [0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10])
    try headerAndGarbage.write(to: dbURL)
    XCTAssertEqual(extractor.extractHotwords(limit: 10), ["降级词1", "降级词2"])

    // 3. Database URL pointing to a directory instead of a regular file
    let dirURL = tempDir.appendingPathComponent("directory_as_db")
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    let dirExtractor = OwlVoiceHotwordsExtractor(
      databaseURL: dirURL,
      inMemoryPinnedWordsProvider: { ["目录降级词"] }
    )
    XCTAssertEqual(dirExtractor.extractHotwords(limit: 10), ["目录降级词"])

    // 4. File with 000 permissions (unreadable file)
    let unreadableURL = tempDir.appendingPathComponent("unreadable.db")
    try Data([0x01, 0x02, 0x03]).write(to: unreadableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableURL.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableURL.path)
    }
    let unreadableExtractor = OwlVoiceHotwordsExtractor(
      databaseURL: unreadableURL,
      inMemoryPinnedWordsProvider: { ["无权限降级词"] }
    )
    XCTAssertEqual(unreadableExtractor.extractHotwords(limit: 10), ["无权限降级词"])
  }

  func testAdversarialSQLiteAlteredSchemaAndMissingColumns() {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }

    // Table with wrong column name for pinned_candidates
    // Table user_dictionary_operations missing 'operation'
    // Table personal_bigram missing 'count'
    // Extra dummy table
    let brokenDDL = """
    CREATE TABLE pinned_candidates(context_key TEXT PRIMARY KEY, wrong_column TEXT);
    INSERT INTO pinned_candidates VALUES ('k1', '错列词');
    CREATE TABLE user_dictionary_operations(dictionary TEXT, key TEXT, value TEXT, weight INT);
    INSERT INTO user_dictionary_operations VALUES ('dict', 'k2', '少列词', 10);
    CREATE TABLE personal_bigram(previous TEXT, word TEXT);
    INSERT INTO personal_bigram VALUES ('前', '词');
    CREATE TABLE foreign_table(id INT, info TEXT);
    INSERT INTO foreign_table VALUES (1, '外来表数据');
    """
    XCTAssertEqual(sqlite3_exec(db, brokenDDL, nil, nil, nil), SQLITE_OK)

    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { ["内存置顶词"] }
    )

    // Extractor must not crash or leak, and should gracefully return the in-memory pins
    let hotwords = extractor.extractHotwords(limit: 10)
    XCTAssertEqual(hotwords, ["内存置顶词"])
  }

  func testAdversarialSQLiteBusyTimeoutAndLockRecovery() {
    createTestDatabase(
      pinned: [("k1", "已置顶词", 100)]
    )

    // Open an external writer connection and lock the database exclusively
    var writerDb: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dbURL.path, &writerDb), SQLITE_OK)
    defer {
      if let writerDb { sqlite3_close(writerDb) }
    }

    // Begin exclusive transaction
    XCTAssertEqual(sqlite3_exec(writerDb, "BEGIN EXCLUSIVE TRANSACTION;", nil, nil, nil), SQLITE_OK)

    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { ["锁超时降级词"] }
    )

    // While locked, extractor queries should time out after ~1000ms (busy_timeout) and return gracefully
    let startTime = ProcessInfo.processInfo.systemUptime
    let lockedResult = extractor.extractHotwords(limit: 10)
    let elapsed = ProcessInfo.processInfo.systemUptime - startTime

    // Must return within ~0.8 - 5.0 seconds
    XCTAssertGreaterThanOrEqual(elapsed, 0.8, "Should respect busy timeout around 1 second")
    XCTAssertLessThan(elapsed, 5.0, "Must not hang indefinitely")
    XCTAssertEqual(lockedResult, ["锁超时降级词"])

    // Release lock (COMMIT)
    XCTAssertEqual(sqlite3_exec(writerDb, "COMMIT;", nil, nil, nil), SQLITE_OK)
    sqlite3_close(writerDb)
    writerDb = nil

    // After lock is released, extractor should immediately succeed and extract hotwords
    let recoveredResult = extractor.extractHotwords(limit: 10)
    XCTAssertTrue(recoveredResult.contains("已置顶词"))
    XCTAssertTrue(recoveredResult.contains("锁超时降级词"))
  }

  func testAdversarialSQLiteHighVolumeRowsAndLimit() {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }

    let ddl = """
    CREATE TABLE pinned_candidates(context_key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL DEFAULT(unixepoch()));
    CREATE TABLE user_dictionary_operations(dictionary TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, operation TEXT NOT NULL, weight INTEGER NOT NULL DEFAULT 0, display TEXT NOT NULL DEFAULT '', user_inserted INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT(unixepoch()), PRIMARY KEY(dictionary,key,value));
    CREATE TABLE personal_bigram(previous TEXT NOT NULL, word TEXT NOT NULL, count INTEGER NOT NULL CHECK(count>0), PRIMARY KEY(previous,word)) WITHOUT ROWID;
    """
    XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)

    // Insert 5,000 bigrams inside a single transaction for speed
    XCTAssertEqual(sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil), SQLITE_OK)
    var stmt: OpaquePointer?
    XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO personal_bigram VALUES (?, ?, ?);", -1, &stmt, nil), SQLITE_OK)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for i in 0..<5000 {
      sqlite3_bind_text(stmt, 1, "词前\(i)", -1, transient)
      sqlite3_bind_text(stmt, 2, "词后\(i)", -1, transient)
      sqlite3_bind_int(stmt, 3, Int32(i + 2))
      XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
      sqlite3_reset(stmt)
    }
    sqlite3_finalize(stmt)
    XCTAssertEqual(sqlite3_exec(db, "COMMIT;", nil, nil, nil), SQLITE_OK)

    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { [] }
    )

    // Query with limit: 5
    let top5 = extractor.extractHotwords(limit: 5)
    XCTAssertEqual(top5.count, 5)
    // The highest counts are at the end of the loop: 4999 (count: 5001), 4998, 4997, 4996, 4995
    XCTAssertEqual(top5[0], "词前4999词后4999")
    XCTAssertEqual(top5[1], "词前4998词后4998")

    // Test limit <= 0
    XCTAssertEqual(extractor.extractHotwords(limit: 0), [])
    XCTAssertEqual(extractor.extractHotwords(limit: -10), [])
  }

  func testAdversarialBigramSentenceStartAndUnicodeAttacks() {
    createTestDatabase(
      bigrams: [
        ("\u{0001}", "句首词语", 100),              // previous is char(1)
        ("", "空前导词语", 90),                     // previous is empty string
        ("猫头鹰", "输入法", 80),                    // multi-byte Chinese concatenation
        ("🚀", "发射中心", 70),                     // emoji + Chinese
        ("👨‍👩‍👧‍👦", "家庭旅行", 60),                   // complex ZWJ emoji + Chinese
        ("TCP,", "IP协议", 50),                    // internal comma in bigram
        ("🎉", "✨", 40),                          // pure symbols -> must be sanitized away
        ("\u{0002}", "控制符前导", 35),              // control character in previous -> sanitized away
        ("", "含\u{0007}控制符", 30),                // control character in word -> sanitized away
        ("罕见", "字词", 1)                         // count <= 1 -> filtered out
      ]
    )

    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: dbURL,
      inMemoryPinnedWordsProvider: { [] }
    )

    let hotwords = extractor.extractHotwords(limit: 20)

    // 1. Sentence-start char(1) yields 'word' without char(1)
    XCTAssertTrue(hotwords.contains("句首词语"))
    XCTAssertFalse(hotwords.contains("\u{0001}句首词语"))

    // 2. Empty string yields 'word'
    XCTAssertTrue(hotwords.contains("空前导词语"))

    // 3. Multi-byte Chinese concatenated cleanly
    XCTAssertTrue(hotwords.contains("猫头鹰输入法"))

    // 4. Emoji + Chinese preserved without UTF-8 corruption
    XCTAssertTrue(hotwords.contains("🚀发射中心"))
    XCTAssertTrue(hotwords.contains("👨‍👩‍👧‍👦家庭旅行"))

    // 5. Internal commas converted to space
    XCTAssertTrue(hotwords.contains("TCP IP协议"))

    // 6. Pure emoji/symbols discarded
    XCTAssertFalse(hotwords.contains("🎉✨"))

    // 7. Control characters discarded
    XCTAssertFalse(hotwords.contains("\u{0002}控制符前导"))
    XCTAssertFalse(hotwords.contains("控制符前导"))
    XCTAssertFalse(hotwords.contains("含\u{0007}控制符"))

    // 8. Low frequency count <= 1 filtered
    XCTAssertFalse(hotwords.contains("罕见字词"))

    // Verify all returned hotwords are valid UTF-8
    for hw in hotwords {
      XCTAssertNotNil(hw.data(using: .utf8))
    }
  }

  // MARK: - Event Helper

  private func makeKeyEvent(type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    let event = NSEvent.keyEvent(
      with: type,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: keyCode
    )
    return try XCTUnwrap(event)
  }
}

// MARK: - Mock IMKTextInput with Pre-Context

private final class MockVoiceTextInputClientWithPreContext: NSObject, IMKTextInput {
  let preContextString: String
  var insertedTexts: [String] = []

  init(simulatedPreContext: String) {
    self.preContextString = simulatedPreContext
  }

  func insertText(_ string: Any!, replacementRange: NSRange) {
    if let str = string as? String {
      insertedTexts.append(str)
    }
  }

  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {}

  func selectedRange() -> NSRange {
    NSRange(location: preContextString.count, length: 0)
  }

  func markedRange() -> NSRange {
    NSRange(location: NSNotFound, length: 0)
  }

  func attributedSubstring(from range: NSRange) -> NSAttributedString! {
    let str = (preContextString as NSString).substring(with: range)
    return NSAttributedString(string: str)
  }

  func length() -> Int { preContextString.count }
  func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
  func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { nil }
  func validAttributesForMarkedText() -> [Any]! { [] }
  func overrideKeyboard(withKeyboardNamed name: String!) {}
  func selectMode(_ modeIdentifier: String!) {}
  func supportsUnicode() -> Bool { true }
  func bundleIdentifier() -> String! { "com.test.app" }
  func windowLevel() -> CGWindowLevel { 0 }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
  func uniqueClientIdentifierString() -> String! { "com.test.app" }
  func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}
