//
//  OwlRustEngineTests.swift
//  OwltypeTests
//
//  Unit and integration tests for the narrow C-ABI Rust engine adapter
//  (`OwlRustEngine` / `OwlRustSession`) backing #249.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlRustEngineTests: XCTestCase {

  private func makeSharedSupportSeedEngine() throws -> OwlRustEngine {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let seedDir = repoRoot.appendingPathComponent("data/owl-rime")
    let pinyinDB = seedDir.appendingPathComponent("msime/msime-pinyin.db")
    guard FileManager.default.fileExists(atPath: pinyinDB.path) else {
      throw XCTSkip("msime-pinyin.db not generated yet at \(pinyinDB.path)")
    }
    let userDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-rust-engine-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: userDir)
    }
    let engine = OwlRustEngine(sharedSupportURL: seedDir, userDataURL: userDir)
    var traits = RimeTraits.rimeStructInit()
    engine.setup(&traits)
    engine.initialize(nil)
    return engine
  }

  func testEngineMetadataAndSchemaSelection() throws {
    let engine = try makeSharedSupportSeedEngine()
    XCTAssertEqual(engine.version(), "msime-rust-0.1")
    let schemas = engine.schemaList()
    XCTAssertTrue(schemas.contains(where: { $0.id == "rime_ice" }))
    XCTAssertEqual(engine.currentSchema(), "rime_ice")
    XCTAssertTrue(engine.selectSchema("rime_ice"))
    XCTAssertTrue(engine.selectSchema("double_pinyin_flypy"))
    XCTAssertEqual(engine.currentSchema(), "double_pinyin_flypy")
    XCTAssertFalse(engine.selectSchema("unknown_schema"))
  }

  func testQuanpinTypingProducesPreeditAndCandidatesAndSpaceCommits() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    XCTAssertTrue(session.isValid)

    for scalar in "nihao".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }

    XCTAssertEqual(session.input(), "nihao")
    let comp = try XCTUnwrap(session.composition())
    XCTAssertFalse(comp.preedit.isEmpty)
    XCTAssertFalse(comp.candidates.isEmpty)
    XCTAssertTrue(comp.candidates.contains(where: { $0.text == "你好" }))
    XCTAssertEqual(comp.commitTextPreview, comp.candidates.first?.text)

    // Space commits the highlighted candidate.
    XCTAssertTrue(session.process(keycode: UInt32(XK_space), modifiers: 0))
    let committed = try XCTUnwrap(session.takeCommit())
    XCTAssertEqual(committed, "你好")
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "")
    XCTAssertEqual(session.composition()?.preedit, "")
  }

  func testCandidateSelectionByDigitAndSelectCandidateMethod() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    for scalar in "nihao".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let comp = try XCTUnwrap(session.composition())
    guard comp.candidates.count >= 2 else {
      XCTFail("Expected at least 2 candidates for nihao")
      return
    }
    let secondText = comp.candidates[1].text

    // Press '2' to select the 2nd visible candidate (0-based index 1).
    XCTAssertTrue(session.process(keycode: UInt32(XK_2), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), secondText)

    // Type again and use selectCandidate(_:) directly (mouse click path).
    for scalar in "nihao".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let comp2 = try XCTUnwrap(session.composition())
    let firstText = try XCTUnwrap(comp2.candidates.first?.text)
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), firstText)
  }

  func testBackspaceReturnAndEscapeHandling() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    for scalar in "ni".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    XCTAssertEqual(session.input(), "ni")

    // Backspace shrinks raw input to "n".
    XCTAssertTrue(session.process(keycode: UInt32(XK_BackSpace), modifiers: 0))
    XCTAssertEqual(session.input(), "n")

    // Return commits raw input "n".
    XCTAssertTrue(session.process(keycode: UInt32(XK_Return), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), "n")
    XCTAssertEqual(session.input(), "")

    // Escape clears active composition without committing.
    for scalar in "hao".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    XCTAssertEqual(session.input(), "hao")
    XCTAssertTrue(session.process(keycode: UInt32(XK_Escape), modifiers: 0))
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "")
  }

  func testPaginationAndHighlightNavigation() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    for scalar in "shi".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let page0 = try XCTUnwrap(session.composition())
    XCTAssertEqual(page0.pageNo, 0)
    XCTAssertEqual(page0.highlightedIndex, 0)

    // Down arrow moves highlight within current page.
    XCTAssertTrue(session.process(keycode: UInt32(XK_Down), modifiers: 0))
    let afterDown = try XCTUnwrap(session.composition())
    XCTAssertEqual(afterDown.highlightedIndex, 1)

    // Page down advances page when more candidates exist.
    if !page0.isLastPage {
      XCTAssertTrue(session.changePage(up: false))
      let page1 = try XCTUnwrap(session.composition())
      XCTAssertEqual(page1.pageNo, 1)
      XCTAssertTrue(session.changePage(up: true))
      let backTo0 = try XCTUnwrap(session.composition())
      XCTAssertEqual(backTo0.pageNo, 0)
    }
  }

  func testShiftToggleSwitchesASCIIModeAndCommitsInFlightComposition() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    XCTAssertFalse(session.option(.asciiMode))
    for scalar in "ni".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }

    // Press and release Shift_L without intervening key -> commits raw input and enters ASCII mode.
    _ = session.process(keycode: UInt32(XK_Shift_L), modifiers: kShiftMask.rawValue)
    _ = session.process(keycode: UInt32(XK_Shift_L), modifiers: kReleaseMask.rawValue)
    XCTAssertTrue(session.option(.asciiMode))
    XCTAssertEqual(session.takeCommit(), "ni")

    // In ASCII mode, typing letters is not consumed by the IME.
    XCTAssertFalse(session.process(keycode: UInt32(XK_a), modifiers: 0))
  }

  func testCancelReturnsEmptyContextToClearHostMarkedText() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    for scalar in "nihao".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    XCTAssertTrue(session.process(keycode: UInt32(XK_Escape), modifiers: 0))
    let cleared = try XCTUnwrap(session.composition(), "The IMK renderer needs an empty context to clear marked text")
    XCTAssertEqual(cleared.preedit, "")
    XCTAssertTrue(cleared.candidates.isEmpty)
    XCTAssertNil(session.takeCommit())
    XCTAssertTrue(session.process(keycode: UInt32(XK_n), modifiers: 0))
    XCTAssertTrue(session.process(keycode: UInt32(XK_BackSpace), modifiers: 0))
    XCTAssertEqual(session.composition()?.preedit, "")
    XCTAssertTrue(session.composition()?.candidates.isEmpty == true)
  }

  func testKeypadDigitSelectsVisibleCandidate() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    for scalar in "nihao".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let expected = try XCTUnwrap(session.composition()?.candidates.first?.text)
    XCTAssertTrue(session.process(keycode: UInt32(XK_KP_1), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), expected)
  }

  func testTraditionalOutputMatchesVisibleAndPeekedCandidatesAndCanBeDisabled() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    for scalar in "zhongguo".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let simplified = try XCTUnwrap(session.composition())
    let index = try XCTUnwrap(simplified.candidates.firstIndex { $0.text == "中国" })
    let options: [RimeOption] = [.traditional, .traditionalization, .zhTrad, .transcription]
    for option in options { session.setOption(option, true) }
    session.setOption(.simplification, false)
    let traditional = try XCTUnwrap(session.composition())
    XCTAssertEqual(traditional.candidates[index].text, "中國")
    XCTAssertEqual(session.peekCandidates(from: index, count: 1).first?.text, "中國")
    let token = OwlCandidateToken(sessionID: session.sessionID, generation: session.generation,
                                  candidateID: index, isAbsolute: false)
    XCTAssertTrue(session.selectCandidate(token))
    XCTAssertEqual(session.takeCommit(), "中國")
    for option in options { session.setOption(option, false) }
    session.setOption(.simplification, true)
    for scalar in "zhongguo".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let restored = try XCTUnwrap(session.composition())
    let restoredIndex = try XCTUnwrap(restored.candidates.firstIndex { $0.text == "中国" })
    XCTAssertTrue(session.selectCandidate(restoredIndex))
    XCTAssertEqual(session.takeCommit(), "中国")
  }

  func testTokenBasedSelectionPeekCandidatesAndStaleGenerationRejection() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    for scalar in "shi".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let comp = try XCTUnwrap(session.composition())
    let gen = session.generation
    XCTAssertGreaterThan(gen, 0)

    // Peek candidates beyond the first page without changing the session's current page.
    let peeked = session.peekCandidates(from: comp.pageSize, count: comp.pageSize)
    XCTAssertFalse(peeked.isEmpty)
    XCTAssertEqual(session.composition()?.pageNo, 0)

    // Stale generation token must be rejected without committing.
    let staleToken = OwlCandidateToken(
      sessionID: session.sessionID,
      generation: gen + 777,
      candidateID: 0,
      isAbsolute: false
    )
    XCTAssertFalse(session.selectCandidate(staleToken))
    XCTAssertNil(session.takeCommit())

    // Wrong sessionID token must be rejected.
    let wrongSessionToken = OwlCandidateToken(
      sessionID: session.sessionID + 99,
      generation: session.generation,
      candidateID: 0,
      isAbsolute: false
    )
    XCTAssertFalse(session.selectCandidate(wrongSessionToken))
    XCTAssertNil(session.takeCommit())

    // Valid absolute token selects candidate from peeked page directly.
    let absTargetText = peeked[0].text
    let absToken = OwlCandidateToken(
      sessionID: session.sessionID,
      generation: session.generation,
      candidateID: comp.pageSize,
      isAbsolute: true
    )
    XCTAssertTrue(session.selectCandidate(absToken))
    XCTAssertEqual(session.takeCommit(), absTargetText)
  }

  func testPinnedWordsReorderingAndCaretOffsets() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    for scalar in "shijie".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let initialComp = try XCTUnwrap(session.composition())
    guard initialComp.candidates.count >= 2 else {
      XCTFail("Expected at least 2 candidates for shijie")
      return
    }
    // Verify raw_input caretPos vs preedit cursorPos ("shijie" = 6 bytes, "shi'jie" = 7 bytes).
    XCTAssertEqual(session.caretPos(), 6)
    XCTAssertEqual(initialComp.cursorPos, initialComp.preedit.utf8.count)
    let targetWord = initialComp.candidates[1].text
    XCTAssertNotNil(
      OwlPinnedWords.target(
        schema: "rime_ice",
        input: session.input() ?? "",
        composition: initialComp,
        candidate: targetWord,
        traditional: false,
        caret: session.caretPos()
      )
    )

    // Pin the second candidate to the top and replay "shijie".
    session.setProperty(name: OwlPinnedWords.property, value: "shijie\t0\t\(targetWord)")
    session.clearComposition()
    for scalar in "shijie".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let pinnedComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(pinnedComp.candidates.first?.text, targetWord)
    XCTAssertEqual(pinnedComp.candidates.first?.comment, "置顶")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), targetWord)
  }

  func testPunctuationAndCaretNavigation() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    session.setOption(.asciiPunct, false)

    for scalar in "nihao".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    // Move caret to Home (0) and back to End (5).
    XCTAssertTrue(session.process(keycode: UInt32(XK_Home), modifiers: 0))
    XCTAssertEqual(session.caretPos(), 0)
    XCTAssertEqual(session.composition()?.cursorPos, 0)

    session.setCaretPos(5)
    XCTAssertEqual(session.caretPos(), 5)
    XCTAssertEqual(session.composition()?.cursorPos, 6)

    // Comma in Chinese punctuation mode commits highlighted candidate + "，".
    XCTAssertTrue(session.process(keycode: UInt32(XK_comma), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), "你好，")
  }

  func testWubi86PureAndMixedSchemasZLookupAndPreferences() throws {
    let origCodeHint = OwlKeyboardPreferences.wubiCodeHint
    let origAutoClear = OwlKeyboardPreferences.wubiAutoClear
    let origCandMode = OwlKeyboardPreferences.wubiCandidateMode
    let origZLookup = OwlKeyboardPreferences.wubiZReverseLookup
    let origEngChannel = OwlKeyboardPreferences.wubiEnglishChannel
    defer {
      OwlKeyboardPreferences.wubiCodeHint = origCodeHint
      OwlKeyboardPreferences.wubiAutoClear = origAutoClear
      OwlKeyboardPreferences.wubiCandidateMode = origCandMode
      OwlKeyboardPreferences.wubiZReverseLookup = origZLookup
      OwlKeyboardPreferences.wubiEnglishChannel = origEngChannel
    }

    OwlKeyboardPreferences.wubiCodeHint = false
    OwlKeyboardPreferences.wubiAutoClear = false
    OwlKeyboardPreferences.wubiCandidateMode = .normal
    OwlKeyboardPreferences.wubiZReverseLookup = true
    OwlKeyboardPreferences.wubiEnglishChannel = false

    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    let session = engine.createSession()
    defer { session.destroy() }

    // 1. Pure Wubi 4-code unique auto-commit: sebv -> 极限
    for scalar in "sebv".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    XCTAssertEqual(session.takeCommit(), "极限")
    XCTAssertEqual(session.input(), "")

    // 2. Z reverse lookup in pure Wubi: zhao -> 找 / 好 with Wubi code comment even when wubiCodeHint is false
    for scalar in "zhao".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let zComp = try XCTUnwrap(session.composition())
    XCTAssertTrue(zComp.candidates.contains(where: { $0.text == "找" || $0.text == "好" }))
    XCTAssertTrue(zComp.candidates.contains(where: { ($0.comment ?? "").isEmpty == false }))
    session.clearComposition()

    // Multi-syllable z reverse lookup: zzhongguo -> 中国
    for scalar in "zzhongguo".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let zzComp = try XCTUnwrap(session.composition())
    XCTAssertTrue(zzComp.candidates.contains(where: { $0.text == "中国" }))
    session.clearComposition()

    // Disabling wubiZReverseLookup stops z from triggering pinyin lookup
    OwlKeyboardPreferences.wubiZReverseLookup = false
    for scalar in "zhao".unicodeScalars {
      _ = session.process(keycode: scalar.value, modifiers: 0)
    }
    let zDisabledCandidates = session.composition()?.candidates.map(\.text) ?? []
    XCTAssertFalse(zDisabledCandidates.contains("找"))
    session.clearComposition()
    OwlKeyboardPreferences.wubiZReverseLookup = true

    // 3. wubiAutoClear on 4-code empty miss (`aaab` miss -> auto-cleared)
    OwlKeyboardPreferences.wubiAutoClear = true
    for scalar in "aaab".unicodeScalars {
      _ = session.process(keycode: scalar.value, modifiers: 0)
    }
    XCTAssertEqual(session.input(), "")
    OwlKeyboardPreferences.wubiAutoClear = false

    // 4. wubiEnglishChannel (`hello)
    OwlKeyboardPreferences.wubiEnglishChannel = true
    for scalar in "`hello".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    XCTAssertEqual(session.input(), "`hello")
    let engComp = try XCTUnwrap(session.composition())
    XCTAssertTrue(engComp.candidates.contains(where: { $0.text.lowercased() == "hello" }))
    session.clearComposition()

    // 5. Switch to Mixed Wubi-Pinyin (`wubi86_jidian_pinyin`, #251-#254)
    XCTAssertTrue(session.selectSchema("wubi86_jidian_pinyin"))
    for scalar in "jixu".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    // Must NOT auto-commit 曳光弹 on 4th key when pinyin "继续" also matches (#251)
    XCTAssertNil(session.takeCommit())
    let jixuComp = try XCTUnwrap(session.composition())
    let jixuTexts = jixuComp.candidates.map(\.text)
    XCTAssertTrue(jixuTexts.contains("继续"))
    XCTAssertTrue(jixuTexts.contains("曳光弹"))
    session.clearComposition()

    // Exact 3-key pinyin `edu` (`额度`) outranks 4-code Wubi completion `edui`/`eduq` (#252)
    for scalar in "edu".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let eduComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(eduComp.candidates.first?.text, "额度")
    session.clearComposition()

    // 5th-key continuation into multi-syllable pinyin (#253): hang -> hanguo -> 韩国
    for scalar in "hanguo".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let hanguoComp = try XCTUnwrap(session.composition())
    XCTAssertTrue(hanguoComp.candidates.contains(where: { $0.text == "韩国" }))
    session.clearComposition()
  }

  func testPinyinTypoAutocorrectAndMixedChineseEnglishCandidates() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    // #256: Adjacent-key (`nihso`), transposition (`niaho`), missing-letter (`zhngguo`), and extra-letter (`nihaao`) typo tolerance
    for (typo, expected) in [("nihso", "你好"), ("niaho", "你好"), ("zhngguo", "中国"), ("nihaao", "你好")] {
      for scalar in typo.unicodeScalars {
        XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
      }
      let comp = try XCTUnwrap(session.composition())
      let all = comp.candidates + session.peekCandidates(from: comp.pageSize, count: 15)
      XCTAssertTrue(all.contains(where: { $0.text == expected }), "Expected \(expected) for typo \(typo)")
      session.clearComposition()
    }

    // #259 AC 1: Complete Chinese syllables (`di`, `shi`, `nihao`) have all-Chinese first page
    for py in ["di", "shi", "nihao"] {
      for scalar in py.unicodeScalars {
        XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
      }
      let comp = try XCTUnwrap(session.composition())
      XCTAssertFalse(comp.candidates.isEmpty)
      for cand in comp.candidates {
        let isASCIIOnly = cand.text.unicodeScalars.allSatisfy(\.isASCII)
        XCTAssertFalse(isASCIIOnly, "First page for \(py) should not contain pure ASCII candidate \(cand.text)")
      }
      session.clearComposition()
    }

    // #259 AC 2 & 3: Direct English word & prefix completion (`hello`, `github`)
    for scalar in "github".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let ghComp = try XCTUnwrap(session.composition())
    let ghAll = ghComp.candidates + session.peekCandidates(from: ghComp.pageSize, count: 10)
    XCTAssertTrue(ghAll.contains(where: { $0.text == "GitHub" }))
    session.clearComposition()

    // #259 AC 4: Mixed CN-EN lexicon entries (`xguang` -> `X光`, `txu` -> `T恤`, `upan` -> `U盘`)
    for (input, expected) in [("xguang", "X光"), ("txu", "T恤"), ("upan", "U盘")] {
      for scalar in input.unicodeScalars {
        XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
      }
      let comp = try XCTUnwrap(session.composition())
      let all = comp.candidates + session.peekCandidates(from: comp.pageSize, count: 10)
      XCTAssertTrue(all.contains(where: { $0.text == expected }), "Expected \(expected) for \(input)")
      session.clearComposition()
    }
  }

  func testHostQuickPhrasesPromptsAndTemplatesAtTopOfFirstPage() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let seedDir = repoRoot.appendingPathComponent("data/owl-rime")
    let userDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-rust-phrases-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: userDir) }

    let quickSendContent = "user@example.com\tyx\t100000\n"
    try quickSendContent.write(
      to: userDir.appendingPathComponent(OwlQuickSendStore.dictFileName),
      atomically: true,
      encoding: .utf8
    )
    let promptContent = "📝周报生成\tzb\t100000\n"
    try promptContent.write(
      to: userDir.appendingPathComponent(OwlPromptStore.dictFileName),
      atomically: true,
      encoding: .utf8
    )
    let templateID = UUID()
    let templateCandidate = "\(OwlTemplateStore.candidatePrefix)\(templateID.uuidString)]法条引用"
    let templateContent = "\(templateCandidate)\tft\t100000\n"
    try templateContent.write(
      to: userDir.appendingPathComponent(OwlTemplateStore.dictFileName),
      atomically: true,
      encoding: .utf8
    )

    let engine = OwlRustEngine(sharedSupportURL: seedDir, userDataURL: userDir)
    let session = engine.createSession()
    defer { session.destroy() }

    // 1. Quick phrase `yx` -> `user@example.com` at top of page 0
    for scalar in "yx".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let yxComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(yxComp.candidates.first?.text, "user@example.com")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "user@example.com")
    XCTAssertEqual(session.lastCommittedInput(), "yx")

    // 2. Prompt `zb` -> `📝周报生成` at top of page 0
    for scalar in "zb".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let zbComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(zbComp.candidates.first?.text, "📝周报生成")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "📝周报生成")
    XCTAssertEqual(session.lastCommittedInput(), "zb")

    // 3. Unified template `ft` -> `🦉[UUID]法条引用` preserves ID marker even in Traditional mode
    session.setOption(.transcription, true)
    for scalar in "ft".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let ftComp = try XCTUnwrap(session.composition())
    XCTAssertTrue(ftComp.candidates.first?.text.hasPrefix("\(OwlTemplateStore.candidatePrefix)\(templateID.uuidString)]") == true)
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), templateCandidate)
    XCTAssertEqual(session.lastCommittedInput(), "ft")

    // 4. Replacing a host phrase refreshes the runtime table without duplicating it.
    let updatedQuickPhrase = "updated@example.com\tyx\t100000\n"
    try updatedQuickPhrase.write(
      to: userDir.appendingPathComponent(OwlQuickSendStore.dictFileName),
      atomically: true,
      encoding: .utf8
    )
    XCTAssertTrue(engine.deployConfigFile(OwlQuickSendStore.dictFileName, versionKey: "config_version"))
    for scalar in "yx".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let updatedComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(
      updatedComp.candidates.filter { $0.text == "updated@example.com" }.count,
      1
    )
    XCTAssertFalse(updatedComp.candidates.contains(where: { $0.text == "user@example.com" }))
    session.clearComposition()

    // Duplicate rows in the packed host table still produce exactly one candidate.
    try (updatedQuickPhrase + updatedQuickPhrase).write(
      to: userDir.appendingPathComponent(OwlQuickSendStore.dictFileName),
      atomically: true,
      encoding: .utf8
    )
    XCTAssertTrue(engine.deployConfigFile(OwlQuickSendStore.dictFileName, versionKey: "config_version"))
    for scalar in "yx".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let deduplicatedComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(
      deduplicatedComp.candidates.filter { $0.text == "updated@example.com" }.count,
      1
    )
    session.clearComposition()

    // 5. A newly created session reads the current host files and keeps the base phrase table.
    session.destroy()
    let restarted = engine.createSession()
    defer { restarted.destroy() }
    for scalar in "yx".unicodeScalars {
      XCTAssertTrue(restarted.process(keycode: scalar.value, modifiers: 0))
    }
    let restartedComp = try XCTUnwrap(restarted.composition())
    XCTAssertEqual(
      restartedComp.candidates.filter { $0.text == "updated@example.com" }.count,
      1
    )
    restarted.clearComposition()

    // 6. Clearing the host file removes only host rows. Prompts, templates and seed quick phrases remain.
    try "".write(
      to: userDir.appendingPathComponent(OwlQuickSendStore.dictFileName),
      atomically: true,
      encoding: .utf8
    )
    XCTAssertTrue(engine.deployConfigFile(OwlQuickSendStore.dictFileName, versionKey: "config_version"))
    restarted.setOption(.transcription, false)
    for scalar in "yx".unicodeScalars {
      XCTAssertTrue(restarted.process(keycode: scalar.value, modifiers: 0))
    }
    let yxAfterDelete = try XCTUnwrap(restarted.composition())
    XCTAssertFalse(yxAfterDelete.candidates.contains(where: { $0.text == "user@example.com" }))
    XCTAssertFalse(yxAfterDelete.candidates.contains(where: { $0.text == "updated@example.com" }))
    restarted.clearComposition()

    for scalar in "zb".unicodeScalars {
      XCTAssertTrue(restarted.process(keycode: scalar.value, modifiers: 0))
    }
    XCTAssertEqual(try XCTUnwrap(restarted.composition()).candidates.first?.text, "📝周报生成")
    restarted.clearComposition()

    for (input, expected) in [("xguang", "X光"), ("ft", templateCandidate)] {
      for scalar in input.unicodeScalars {
        XCTAssertTrue(restarted.process(keycode: scalar.value, modifiers: 0))
      }
      let comp = try XCTUnwrap(restarted.composition())
      XCTAssertTrue(comp.candidates.contains(where: { $0.text == expected }))
      restarted.clearComposition()
    }
  }
}
