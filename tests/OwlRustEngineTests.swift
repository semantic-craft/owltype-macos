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

  private func typeText(
    _ text: String,
    into session: RimeSession,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for scalar in text.unicodeScalars {
      XCTAssertTrue(
        session.process(keycode: scalar.value, modifiers: 0),
        "Expected \(String(scalar)) in \(text) to be consumed",
        file: file,
        line: line
      )
    }
  }

  private func visibleAndPeekedCandidates(
    in session: RimeSession,
    count: Int = 100
  ) -> [RimeCandidate] {
    guard let composition = session.composition() else { return [] }
    let start = composition.pageSize
    return composition.candidates + session.peekCandidates(from: start, count: count)
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

    // 5. Switch to Mixed Wubi-Pinyin (`wubi86_jidian_pinyin`, #252-#254)
    XCTAssertTrue(session.selectSchema("wubi86_jidian_pinyin"))
    for scalar in "jixu".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    // Must NOT auto-commit 曳光弹 on 4th key when pinyin "继续" also matches (#252).
    XCTAssertNil(session.takeCommit())
    let jixuComp = try XCTUnwrap(session.composition())
    let jixuTexts = jixuComp.candidates.map(\.text)
    XCTAssertTrue(jixuTexts.contains("继续"))
    XCTAssertTrue(jixuTexts.contains("曳光弹"))
    session.clearComposition()

    // Exact 3-key pinyin `edu` (`额度`) outranks 4-code Wubi completion `edui`/`eduq` (#251).
    for scalar in "edu".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    let eduComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(eduComp.candidates.first?.text, "额度")
    session.clearComposition()
  }

  func testMixedWubiExactPinyinCompletionsDedupAndSelectionIdentity() throws {
    let origCandidateMode = OwlKeyboardPreferences.wubiCandidateMode
    let origCodeHint = OwlKeyboardPreferences.wubiCodeHint
    let origAutoClear = OwlKeyboardPreferences.wubiAutoClear
    let origZLookup = OwlKeyboardPreferences.wubiZReverseLookup
    defer {
      OwlKeyboardPreferences.wubiCandidateMode = origCandidateMode
      OwlKeyboardPreferences.wubiCodeHint = origCodeHint
      OwlKeyboardPreferences.wubiAutoClear = origAutoClear
      OwlKeyboardPreferences.wubiZReverseLookup = origZLookup
    }

    OwlKeyboardPreferences.wubiCandidateMode = .normal
    OwlKeyboardPreferences.wubiCodeHint = true
    OwlKeyboardPreferences.wubiAutoClear = false
    OwlKeyboardPreferences.wubiZReverseLookup = true

    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("wubi86_jidian_pinyin"))
    let session = engine.createSession()
    defer { session.destroy() }

    // #251 AC 1: an exact pinyin word outranks Wubi rows that only complete a longer code.
    typeText("edu", into: session)
    let exactPinyin = try XCTUnwrap(session.composition())
    XCTAssertEqual(exactPinyin.candidates.first?.text, "额度")
    let eduCandidates = visibleAndPeekedCandidates(in: session)
    XCTAssertTrue(
      eduCandidates.contains(where: { $0.text == "膫" }),
      "edu candidates: \(eduCandidates.map(\.text))"
    )
    session.clearComposition()

    // The same letters without an exact pinyin word still return the full Wubi code.
    typeText("edui", into: session)
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "edui")
    XCTAssertTrue(
      visibleAndPeekedCandidates(in: session).contains(where: { $0.text == "膫" }),
      "edui candidates: \(visibleAndPeekedCandidates(in: session).map(\.text))"
    )
    session.clearComposition()

    // Mixed Wubi can still answer a longer ASCII sequence with pinyin fallback, so the
    // key contract is that it stays open instead of silently committing or dropping keys.
    typeText("aaab", into: session)
    XCTAssertEqual(session.input(), "aaab")
    XCTAssertNil(session.takeCommit())
    XCTAssertNotNil(session.composition())
    session.clearComposition()

    // #251 AC 2: `ya` is exact pinyin for 讶 and also a prefix of Wubi codes yaht/ya.
    // The two routes surface one selectable row, not two indistinguishable copies.
    typeText("ya", into: session)
    let yaCandidates = visibleAndPeekedCandidates(in: session)
    let yaRows = yaCandidates.enumerated().filter { $0.element.text == "讶" }
    XCTAssertEqual(yaRows.count, 1)
    let yaIndex = try XCTUnwrap(yaRows.first?.offset)
    let yaToken = OwlCandidateToken(
      sessionID: session.sessionID,
      generation: session.generation,
      candidateID: yaIndex,
      isAbsolute: yaIndex >= (session.composition()?.pageSize ?? 0)
    )
    XCTAssertTrue(session.selectCandidate(yaToken))
    XCTAssertEqual(session.takeCommit(), "讶")

    // #251 AC 3: paging keeps a stable, unique candidate list and selection commits the
    // candidate visible on the page that the user actually navigated to.
    typeText("shi", into: session)
    let candidates = visibleAndPeekedCandidates(in: session)
    XCTAssertGreaterThan(candidates.count, (session.composition()?.pageSize ?? 9))
    XCTAssertEqual(
      candidates.map(\.text).count,
      Set(candidates.map(\.text)).count,
      "shi candidates: \(candidates.map(\.text))"
    )
    XCTAssertTrue(session.changePage(up: false))
    let secondPage = try XCTUnwrap(session.composition())
    XCTAssertEqual(secondPage.pageNo, 1)
    XCTAssertFalse(secondPage.candidates.isEmpty)
    let secondPageFirst = try XCTUnwrap(secondPage.candidates.first?.text)
    XCTAssertTrue(session.process(keycode: UInt32(XK_1), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), secondPageFirst)
  }

  func testWubiSingleFirstModeReordersAmbiguousCandidates() throws {
    let origCandidateMode = OwlKeyboardPreferences.wubiCandidateMode
    defer { OwlKeyboardPreferences.wubiCandidateMode = origCandidateMode }

    OwlKeyboardPreferences.wubiCandidateMode = .normal
    let normalEngine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(normalEngine.selectSchema("wubi86_jidian"))
    let normal = normalEngine.createSession()
    typeText("aaar", into: normal)
    XCTAssertEqual(normal.composition()?.candidates.first?.text, "工匠")
    normal.destroy()

    OwlKeyboardPreferences.wubiCandidateMode = .singleFirst
    let reorderedEngine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(reorderedEngine.selectSchema("wubi86_jidian"))
    let reordered = reorderedEngine.createSession()
    defer { reordered.destroy() }
    typeText("aaar", into: reordered)
    let first = try XCTUnwrap(reordered.composition()?.candidates.first?.text)
    XCTAssertEqual(first.unicodeScalars.count, 1)
    XCTAssertNotEqual(first, "工匠")
    XCTAssertTrue(visibleAndPeekedCandidates(in: reordered).contains(where: { $0.text == "工匠" }))
  }

  func testPureWubiAmbiguityFifthKeyBackspaceSpaceAndModeSwitch() throws {
    let origAutoClear = OwlKeyboardPreferences.wubiAutoClear
    let origCandidateMode = OwlKeyboardPreferences.wubiCandidateMode
    defer {
      OwlKeyboardPreferences.wubiAutoClear = origAutoClear
      OwlKeyboardPreferences.wubiCandidateMode = origCandidateMode
    }
    OwlKeyboardPreferences.wubiAutoClear = false
    OwlKeyboardPreferences.wubiCandidateMode = .normal

    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    let session = engine.createSession()
    defer { session.destroy() }

    // #252 AC 3: a unique four-code in pure Wubi commits on the fourth key. The next
    // physical key starts a new composition rather than disappearing.
    typeText("jixu", into: session)
    XCTAssertEqual(session.takeCommit(), "曳光弹")
    XCTAssertEqual(session.input(), "")
    typeText("n", into: session)
    XCTAssertEqual(session.input(), "n")
    session.clearComposition()

    // An ambiguous four-code stays open. A non-continuing fifth key commits its first
    // visible candidate and starts the next code with that key.
    typeText("aaaa", into: session)
    XCTAssertNil(session.takeCommit())
    let ambiguous = try XCTUnwrap(session.composition())
    XCTAssertGreaterThan(ambiguous.candidates.count, 1)
    let firstAmbiguous = try XCTUnwrap(ambiguous.candidates.first?.text)
    typeText("x", into: session)
    XCTAssertEqual(
      session.takeCommit(),
      firstAmbiguous,
      "four-code candidates: \(ambiguous.candidates.map(\.text)), input: \(session.input() ?? "nil")"
    )
    XCTAssertEqual(session.input(), "x")
    session.clearComposition()

    // Backspace restores a shorter code and keeps its candidate list live.
    typeText("aaaa", into: session)
    XCTAssertTrue(session.process(keycode: UInt32(XK_BackSpace), modifiers: 0))
    XCTAssertEqual(session.input(), "aaa")
    XCTAssertFalse(session.composition()?.candidates.isEmpty ?? true)
    typeText("r", into: session)
    XCTAssertEqual(session.input(), "aaar")
    XCTAssertTrue(session.composition()?.candidates.contains(where: { $0.text == "工匠" }) == true)
    session.clearComposition()

    // Space commits the visible first candidate of an ambiguous complete code.
    typeText("aaaa", into: session)
    let spaceCommit = try XCTUnwrap(session.composition()?.candidates.first?.text)
    XCTAssertTrue(session.process(keycode: UInt32(XK_space), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), spaceCommit)
    XCTAssertEqual(session.input(), "")

    // #252 AC 1: the same jixu code remains open in mixed mode, then restores the
    // pure-Wubi top-on-fourth-key behavior when the mode is switched back.
    XCTAssertTrue(session.selectSchema("wubi86_jidian_pinyin"))
    typeText("jixu", into: session)
    XCTAssertNil(session.takeCommit())
    let mixed = try XCTUnwrap(session.composition())
    XCTAssertTrue(mixed.candidates.contains(where: { $0.text == "继续" }))
    XCTAssertTrue(mixed.candidates.contains(where: { $0.text == "曳光弹" }))
    XCTAssertTrue(session.selectSchema("wubi86_jidian"))
    typeText("jixu", into: session)
    XCTAssertEqual(session.takeCommit(), "曳光弹")
  }

  func testMixedWubiPartialPhraseSelectionContinuesInPinyinTail() throws {
    let origCandidateMode = OwlKeyboardPreferences.wubiCandidateMode
    defer { OwlKeyboardPreferences.wubiCandidateMode = origCandidateMode }
    OwlKeyboardPreferences.wubiCandidateMode = .normal

    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("wubi86_jidian_pinyin"))
    let session = engine.createSession()
    defer { session.destroy() }

    // #253 AC 1 and 3: selecting a leading pinyin word with the keyboard keeps the
    // composition open in phrase preedit; the remaining letters stay pinyin.
    typeText("nihaowo", into: session)
    let prefixPage = try XCTUnwrap(session.composition())
    let prefixIndex = try XCTUnwrap(prefixPage.candidates.firstIndex(where: { $0.text == "你好" }))
    XCTAssertLessThan(prefixIndex, 9)
    XCTAssertTrue(session.process(
      keycode: UInt32(XK_1) + UInt32(prefixIndex),
      modifiers: 0
    ))
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "wo")
    let tail = try XCTUnwrap(session.composition())
    XCTAssertTrue(tail.preedit.contains("你好"))
    XCTAssertTrue(tail.candidates.contains(where: { $0.text == "我" }))

    // Appending `men` updates the consumed reading to `women`; selecting the tail
    // with the mouse path commits one combined phrase.
    typeText("men", into: session)
    XCTAssertEqual(session.input(), "women")
    let tailPage = try XCTUnwrap(session.composition())
    let tailIndex = try XCTUnwrap(tailPage.candidates.firstIndex(where: { $0.text == "我们" }))
    XCTAssertTrue(session.selectCandidate(tailIndex))
    XCTAssertEqual(session.takeCommit(), "你好我们")
    XCTAssertEqual(session.input(), "")

    // A pure-Wubi selection commits at once and cannot leave a pinyin tail behind.
    XCTAssertTrue(session.selectSchema("wubi86_jidian"))
    typeText("aaaa", into: session)
    let pureFirst = try XCTUnwrap(session.composition()?.candidates.first?.text)
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), pureFirst)
    XCTAssertEqual(session.input(), "")

    // #253 AC 2: clear, cancel and schema changes discard the tail. A following Wubi
    // code behaves as a fresh composition instead of inheriting pinyin state.
    XCTAssertTrue(session.selectSchema("wubi86_jidian_pinyin"))
    typeText("nihaowo", into: session)
    let clearPrefix = try XCTUnwrap(session.composition())
    let clearIndex = try XCTUnwrap(clearPrefix.candidates.firstIndex(where: { $0.text == "你好" }))
    XCTAssertTrue(session.selectCandidate(clearIndex))
    XCTAssertEqual(session.input(), "wo")
    session.clearComposition()
    XCTAssertEqual(session.input(), "")
    typeText("sebv", into: session)
    XCTAssertEqual(session.takeCommit(), "极限")

    typeText("nihaowo", into: session)
    let cancelPrefix = try XCTUnwrap(session.composition())
    let cancelIndex = try XCTUnwrap(cancelPrefix.candidates.firstIndex(where: { $0.text == "你好" }))
    XCTAssertTrue(session.selectCandidate(cancelIndex))
    XCTAssertEqual(session.input(), "wo")
    XCTAssertTrue(session.process(keycode: UInt32(XK_Escape), modifiers: 0))
    XCTAssertEqual(session.input(), "")
    typeText("sebv", into: session)
    XCTAssertEqual(session.takeCommit(), "极限")

    typeText("nihaowo", into: session)
    let switchPrefix = try XCTUnwrap(session.composition())
    let switchIndex = try XCTUnwrap(switchPrefix.candidates.firstIndex(where: { $0.text == "你好" }))
    XCTAssertTrue(session.selectCandidate(switchIndex))
    XCTAssertEqual(session.input(), "wo")
    XCTAssertTrue(session.selectSchema("wubi86_jidian"))
    XCTAssertEqual(session.input(), "")
    typeText("jixu", into: session)
    XCTAssertEqual(session.takeCommit(), "曳光弹")
  }

  func testWubiZReverseLookupAcrossSchemasSwitchesDeletionAndSelection() throws {
    let origZLookup = OwlKeyboardPreferences.wubiZReverseLookup
    let origCodeHint = OwlKeyboardPreferences.wubiCodeHint
    let origCandidateMode = OwlKeyboardPreferences.wubiCandidateMode
    defer {
      OwlKeyboardPreferences.wubiZReverseLookup = origZLookup
      OwlKeyboardPreferences.wubiCodeHint = origCodeHint
      OwlKeyboardPreferences.wubiCandidateMode = origCandidateMode
    }
    OwlKeyboardPreferences.wubiCandidateMode = .normal
    OwlKeyboardPreferences.wubiCodeHint = false
    OwlKeyboardPreferences.wubiZReverseLookup = true

    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    let session = engine.createSession()
    defer { session.destroy() }

    // #254 AC 1 and 3: pure-Wubi reverse lookup is on even when ordinary code hints
    // are off, and the reverse-lookup rows carry their own Wubi-code comments.
    typeText("zhao", into: session)
    let zhao = visibleAndPeekedCandidates(in: session)
    let lookupRow = try XCTUnwrap(
      zhao.first(where: { $0.text == "好" }),
      "zhao candidates: \(zhao.map { "\($0.text)[\($0.comment ?? "")]" })"
    )
    XCTAssertTrue(lookupRow.comment?.isEmpty == false)
    session.clearComposition()

    typeText("a", into: session)
    XCTAssertTrue(session.composition()?.candidates.allSatisfy({ $0.comment?.isEmpty != false }) == true)
    session.clearComposition()

    // Numeric and mouse selection both commit the reverse-lookup row.
    typeText("zhao", into: session)
    let firstLookupText = try XCTUnwrap(session.composition()?.candidates.first?.text)
    XCTAssertTrue(session.process(keycode: UInt32(XK_1), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), firstLookupText)

    typeText("zzhongguo", into: session)
    let lookupPage = try XCTUnwrap(session.composition())
    let lookupCandidates = visibleAndPeekedCandidates(in: session)
    XCTAssertGreaterThan(lookupCandidates.count, lookupPage.pageSize)
    let lookupIndex = try XCTUnwrap(
      lookupCandidates.firstIndex(where: { $0.text == "中国" }),
      "zzhongguo candidates: \(lookupCandidates.map(\.text))"
    )
    let lookupToken = OwlCandidateToken(
      sessionID: session.sessionID,
      generation: session.generation,
      candidateID: lookupIndex,
      isAbsolute: true
    )
    XCTAssertTrue(session.selectCandidate(lookupToken))
    XCTAssertEqual(session.takeCommit(), "中国")
    XCTAssertEqual(session.input(), "")

    // Multi-syllable reverse lookup and deleting the last key both leave a clean
    // composition that accepts the next code normally.
    typeText("zzhongguo", into: session)
    XCTAssertTrue(visibleAndPeekedCandidates(in: session).contains(where: { $0.text == "中国" }))
    while session.input()?.isEmpty == false {
      XCTAssertTrue(session.process(keycode: UInt32(XK_BackSpace), modifiers: 0))
    }
    XCTAssertEqual(session.input(), "")
    XCTAssertTrue(session.composition()?.candidates.isEmpty == true)
    typeText("a", into: session)
    XCTAssertTrue(session.composition()?.candidates.contains(where: { $0.text == "工" }) == true)
    session.clearComposition()

    // Turning the setting off disables the z-guided lookup in pure Wubi.
    OwlKeyboardPreferences.wubiZReverseLookup = false
    XCTAssertFalse(session.process(keycode: UInt32(Character("z").asciiValue!), modifiers: 0))
    XCTAssertEqual(session.input(), "")

    // In mixed Wubi, z is an ordinary pinyin letter and the dedicated lookup switch
    // does not change that route.
    XCTAssertTrue(session.selectSchema("wubi86_jidian_pinyin"))
    typeText("zhao", into: session)
    XCTAssertEqual(session.input(), "zhao")
    XCTAssertFalse(visibleAndPeekedCandidates(in: session).isEmpty)
    session.clearComposition()
    OwlKeyboardPreferences.wubiZReverseLookup = true
    typeText("zhao", into: session)
    XCTAssertEqual(session.input(), "zhao")
    XCTAssertFalse(visibleAndPeekedCandidates(in: session).isEmpty)
  }

  func testPinyinAutocorrectAmbiguityJianpinFuzzyReturnAndContinuation() throws {
    let origFuzzy = OwlFuzzySnapshot.current()
    defer {
      OwlFuzzyPreferences.zhz = origFuzzy.zhz
      OwlFuzzyPreferences.chc = origFuzzy.chc
      OwlFuzzyPreferences.shs = origFuzzy.shs
      OwlFuzzyPreferences.nl = origFuzzy.nl
      OwlFuzzyPreferences.rl = origFuzzy.rl
      OwlFuzzyPreferences.fh = origFuzzy.fh
      OwlFuzzyPreferences.anang = origFuzzy.anang
      OwlFuzzyPreferences.eneng = origFuzzy.eneng
      OwlFuzzyPreferences.ining = origFuzzy.ining
    }
    OwlFuzzyPreferences.zhz = false
    OwlFuzzyPreferences.chc = false
    OwlFuzzyPreferences.shs = false
    OwlFuzzyPreferences.nl = false
    OwlFuzzyPreferences.rl = false
    OwlFuzzyPreferences.fh = false
    OwlFuzzyPreferences.anang = false
    OwlFuzzyPreferences.eneng = false
    OwlFuzzyPreferences.ining = false

    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("rime_ice"))
    let session = engine.createSession()
    defer { session.destroy() }

    // #256 AC 1: legal whole-syllable ambiguity stays literal instead of being
    // rewritten to one correction, while both common readings remain selectable.
    typeText("xian", into: session)
    XCTAssertEqual(session.input(), "xian")
    let xian = visibleAndPeekedCandidates(in: session)
    XCTAssertTrue(xian.contains(where: { $0.text == "先" }))
    XCTAssertTrue(xian.contains(where: { $0.text == "西安" }))
    session.clearComposition()

    // Initials are not treated as a misspelling: they remain a normal short input.
    typeText("nh", into: session)
    XCTAssertEqual(session.input(), "nh")
    XCTAssertTrue(visibleAndPeekedCandidates(in: session).contains(where: { $0.text == "你好" }))
    session.clearComposition()

    // Committing raw input rejects the correction for this spelling. The FFI
    // regression above checks the corrected flag directly; this engine-facing test
    // checks that the exact input remains usable without surfacing a stale annotation.
    typeText("nihso", into: session)
    XCTAssertTrue(visibleAndPeekedCandidates(in: session).contains(where: { $0.text == "你好" }))
    XCTAssertTrue(session.process(keycode: UInt32(XK_Return), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), "nihso")
    typeText("nihso", into: session)
    XCTAssertEqual(session.input(), "nihso")
    let repeatedCorrection = visibleAndPeekedCandidates(in: session)
    XCTAssertFalse(
      repeatedCorrection.contains(where: { $0.text == "你好" && $0.comment == "nihso" }),
      "repeated nihso candidates: \(repeatedCorrection.map { "\($0.text)[\($0.comment ?? "")]" })"
    )

    // Backspace and retype keep the rejected spelling stable rather than reviving
    // the correction on a stale composition generation.
    XCTAssertTrue(session.process(keycode: UInt32(XK_BackSpace), modifiers: 0))
    XCTAssertEqual(session.input(), "nihs")
    typeText("o", into: session)
    XCTAssertEqual(session.input(), "nihso")
    let retypedCorrection = visibleAndPeekedCandidates(in: session)
    XCTAssertFalse(
      retypedCorrection.contains(where: { $0.text == "你好" && $0.comment == "nihso" }),
      "retyped nihso candidates: \(retypedCorrection.map { "\($0.text)[\($0.comment ?? "")]" })"
    )
    session.clearComposition()

    // After a normal exact selection, continued typing starts from a clean
    // composition and does not carry stale autocorrect state.
    typeText("nihao", into: session)
    let niHaoIndex = try XCTUnwrap(session.composition()?.candidates.firstIndex(where: { $0.text == "你好" }))
    XCTAssertTrue(session.selectCandidate(niHaoIndex))
    XCTAssertEqual(session.takeCommit(), "你好")
    typeText("shijie", into: session)
    let shiJieIndex = try XCTUnwrap(session.composition()?.candidates.firstIndex(where: { $0.text == "世界" }))
    XCTAssertTrue(session.selectCandidate(shiJieIndex))
    XCTAssertEqual(session.takeCommit(), "世界")
    session.clearComposition()

    // With the existing fuzzy zh=z rule enabled, the relaxed spelling reaches the
    // exact Chinese word without changing the user's typed preedit.
    OwlFuzzyPreferences.zhz = true
    XCTAssertTrue(engine.selectSchema("rime_ice"))
    let fuzzySession = engine.createSession()
    defer { fuzzySession.destroy() }
    typeText("zongguo", into: fuzzySession)
    XCTAssertEqual(fuzzySession.input(), "zongguo")
    XCTAssertTrue(
      visibleAndPeekedCandidates(in: fuzzySession).contains(where: { $0.text == "中国" })
    )
  }

  func testMixedChineseEnglishRankingCompletionPagingPinBackspaceAndLatency() throws {
    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("rime_ice"))
    let session = engine.createSession()
    defer { session.destroy() }

    // #259 AC 1: complete Chinese readings, including ambiguous `you`, keep a
    // Chinese-only first page; mixed English rows remain available after that.
    for input in ["di", "shi", "nihao", "you"] {
      typeText(input, into: session)
      let page = try XCTUnwrap(session.composition(), "Missing composition for \(input)")
      XCTAssertFalse(page.candidates.isEmpty)
      XCTAssertTrue(
        page.candidates.allSatisfy { candidate in
          candidate.text.unicodeScalars.contains(where: { !$0.isASCII })
        },
        "First page for \(input) leaked an ASCII-only candidate"
      )
      session.clearComposition()
    }

    // Exact English words and prefixes are selectable through the bounded candidate
    // list. The display spelling of GitHub is preserved.
    for input in ["hello", "dir", "github"] {
      typeText(input, into: session)
      let candidates = visibleAndPeekedCandidates(in: session)
      let expected = input == "github" ? "GitHub" : input
      XCTAssertTrue(candidates.contains(where: { $0.text == expected }))
      session.clearComposition()
    }
    for (prefix, expected) in [("hel", "hello"), ("gith", "GitHub")] {
      typeText(prefix, into: session)
      let candidates = visibleAndPeekedCandidates(in: session)
      XCTAssertTrue(candidates.contains(where: { $0.text == expected }))
      session.clearComposition()
    }

    // Returning raw input always commits exactly what was typed.
    typeText("owltypo", into: session)
    XCTAssertEqual(session.input(), "owltypo")
    XCTAssertTrue(session.process(keycode: UInt32(XK_Return), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), "owltypo")

    // Multi-page expansion exposes each candidate once, and cursor/page changes do
    // not lose or duplicate words.
    typeText("shi", into: session)
    let expanded = visibleAndPeekedCandidates(in: session, count: 200)
    XCTAssertGreaterThan(expanded.count, session.composition()?.pageSize ?? 9)
    XCTAssertEqual(expanded.map(\.text).count, Set(expanded.map(\.text)).count)
    var visited = Set(session.composition()?.candidates.map(\.text) ?? [])
    while session.composition()?.isLastPage == false {
      XCTAssertTrue(session.changePage(up: false))
      let pageTexts = session.composition()?.candidates.map(\.text) ?? []
      XCTAssertTrue(visited.isDisjoint(with: pageTexts))
      visited.formUnion(pageTexts)
    }
    session.clearComposition()

    // A pinned candidate keeps its exact input identity and leads on replay.
    typeText("you", into: session)
    let pinTarget = try XCTUnwrap(
      visibleAndPeekedCandidates(in: session).first(where: { $0.text == "又" })?.text
    )
    session.setProperty(name: OwlPinnedWords.property, value: "you\t0\t\(pinTarget)")
    session.clearComposition()
    typeText("you", into: session)
    XCTAssertEqual(session.composition()?.candidates.first?.text, pinTarget)
    XCTAssertEqual(session.composition()?.candidates.first?.comment, "置顶")
    session.clearComposition()

    // Backspace preserves the live prefix and still finds the expected completion.
    typeText("github", into: session)
    XCTAssertTrue(session.process(keycode: UInt32(XK_BackSpace), modifiers: 0))
    XCTAssertEqual(session.input(), "githu")
    XCTAssertTrue(visibleAndPeekedCandidates(in: session).contains(where: { $0.text == "GitHub" }))
    XCTAssertTrue(session.process(keycode: UInt32(XK_BackSpace), modifiers: 0))
    XCTAssertEqual(session.input(), "gith")
    session.clearComposition()

    // The production seed answers a six-letter full reading well inside one frame
    // budget at the engine boundary; this is not native host latency evidence.
    let started = Date()
    typeText("zhongguo", into: session)
    XCTAssertTrue(
      visibleAndPeekedCandidates(in: session).contains(where: { $0.text == "中国" })
    )
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
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
