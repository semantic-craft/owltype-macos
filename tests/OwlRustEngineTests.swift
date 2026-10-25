//
//  OwlRustEngineTests.swift
//  OwltypeTests
//
//  Unit and integration tests for the narrow C-ABI Rust engine adapter
//  (`OwlRustEngine` / `OwlRustSession`) backing #249.
//

import Foundation
import SQLite3
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

  func testUpstreamGenerationKeepsJournalUnderMsimeUserAndResourcesUntouched() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let seedDir = repoRoot.appendingPathComponent("data/owl-rime")
    let resourcesDir = seedDir.appendingPathComponent("msime")
    let pinyinURL = resourcesDir.appendingPathComponent("msime-pinyin.db")
    guard FileManager.default.fileExists(atPath: pinyinURL.path) else {
      throw XCTSkip("msime-pinyin.db not generated yet at \(pinyinURL.path)")
    }
    let userDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-rust-roots-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: userDir) }
    let resourcesBefore = try Data(contentsOf: pinyinURL)

    let engine = OwlRustEngine(sharedSupportURL: seedDir, userDataURL: userDir)
    let session = engine.createSession()
    defer { session.destroy() }

    XCTAssertTrue(session.isValid)
    for scalar in "nihao".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
    }
    XCTAssertTrue(session.process(keycode: UInt32(XK_space), modifiers: 0))
    XCTAssertNotNil(session.takeCommit())
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: userDir.appendingPathComponent("msime-user/msime_user.db").path
    ))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: userDir.appendingPathComponent("msime_user.db").path
    ))
    let generationsURL = userDir.appendingPathComponent(
      "msime-user/dictionaries", isDirectory: true
    )
    let generationURLs = try FileManager.default.contentsOfDirectory(
      at: generationsURL, includingPropertiesForKeys: nil
    )
    let generationURL = try XCTUnwrap(generationURLs.first)
    XCTAssertEqual(generationURLs.count, 1)
    XCTAssertTrue(generationURL.lastPathComponent.hasPrefix("seed-"))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: generationURL.appendingPathComponent(".ready").path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: generationURL.appendingPathComponent("msime-pinyin.db").path
    ))
    XCTAssertEqual(try Data(contentsOf: pinyinURL), resourcesBefore)
  }

  func testGenerationSwitchRollbackColdStartAndJournalReplayKeepUserState() async throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let seedDir = repoRoot.appendingPathComponent("data/owl-rime")
    let seedResources = seedDir.appendingPathComponent("msime", isDirectory: true)
    let pinyinURL = seedResources.appendingPathComponent("msime-pinyin.db")
    let englishURL = seedResources.appendingPathComponent("msime-english.db")
    guard FileManager.default.fileExists(atPath: pinyinURL.path),
          FileManager.default.fileExists(atPath: englishURL.path) else {
      throw XCTSkip("Rust seed dictionaries are not generated at \(seedResources.path)")
    }

    let userRoot = URL(
      fileURLWithPath: "/private/tmp/owl-rust-generation-lifecycle-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: userRoot, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: userRoot) }

    let protectedFiles: [String: Data] = [
      "owltype/settings.json": Data(#"{"skin":"deepred","pageSize":7}"#.utf8),
      "owltype/skins/deepred.json": Data(##"{"accent":"#8f1d22"}"##.utf8),
      "rime_ice.custom.yaml": Data("patch:\n  style/inline_preedit: true\n".utf8),
      "notes/personal.txt": Data("not dictionary state\n".utf8),
    ]
    for (relativePath, data) in protectedFiles {
      let url = userRoot.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try data.write(to: url)
    }

    let environment = OwlRustResourceEnvironment.production(userRoot: userRoot)
    let store = try environment.makeStore()
    let packagesRoot = userRoot.deletingLastPathComponent()
      .appendingPathComponent("owl-rust-generation-packages-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: packagesRoot) }

    func makePackage(version: Int) throws -> URL {
      let packageRoot = packagesRoot.appendingPathComponent(
        "v\(version)", isDirectory: true
      )
      let filesRoot = packageRoot.appendingPathComponent("files", isDirectory: true)
      try FileManager.default.createDirectory(
        at: filesRoot, withIntermediateDirectories: true
      )
      let pinyin = filesRoot.appendingPathComponent("msime-pinyin.db")
      let english = filesRoot.appendingPathComponent("msime-english.db")
      let license = filesRoot.appendingPathComponent("rime-ice.LICENSE")
      try FileManager.default.copyItem(at: pinyinURL, to: pinyin)
      try FileManager.default.copyItem(at: englishURL, to: english)
      try FileManager.default.copyItem(
        at: seedDir.appendingPathComponent("rime-ice.LICENSE"), to: license
      )
      let fileEntries = try [
        ("files/msime-pinyin.db", pinyin, OwlRustResourceFileRole.mainDictionary),
        ("files/msime-english.db", english, OwlRustResourceFileRole.englishDictionary),
        ("files/rime-ice.LICENSE", license, OwlRustResourceFileRole.license),
      ].map { path, url, role in
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return OwlRustResourceFile(
          path: path,
          role: role,
          mediaType: role == .license ? "text/plain" : "application/vnd.sqlite3",
          size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
          digest: try OwlRustResourceVerifier.digestOfFile(url)
        )
      }
      let unsigned = OwlRustResourceManifest(
        schemaVersion: OwlRustResourceManifest.schemaVersionV1,
        packageId: "owltype-dictpack",
        inputKind: .pinyinWubi,
        version: version,
        digest: OwlRustResourceManifest.zeroDigest,
        license: [
          OwlRustResourceLicense(
            identifier: "GPL-3.0-only",
            attribution: "test fixture",
            files: ["files/rime-ice.LICENSE"]
          )
        ],
        engineCompatibility: OwlRustResourceEngineCompatibility(
          minimumContractVersion: 1,
          maximumContractVersion: 1,
          requiredCapabilities: [
            "dictionary-contract-v1",
            "pinyin-wubi-v1",
            "persistent-user-journal-v1",
          ]
        ),
        files: fileEntries
      )
      let digest = try unsigned.calculatedDigest()
      let manifest = OwlRustResourceManifest(
        schemaVersion: unsigned.schemaVersion,
        packageId: unsigned.packageId,
        inputKind: unsigned.inputKind,
        version: unsigned.version,
        digest: digest,
        license: unsigned.license,
        engineCompatibility: unsigned.engineCompatibility,
        files: unsigned.files
      )
      try manifest.canonicalData().write(
        to: packageRoot.appendingPathComponent("manifest.json")
      )
      return packageRoot
    }

    let provider: @Sendable () -> OwlRustResourceGeneration? = {
      try? environment.activeGeneration()
    }
    let installedA = try await store.install(
      OwlRustResourceDirectorySource(root: makePackage(version: 1))
    )
    let engineA = OwlRustEngine(
      sharedSupportURL: seedDir,
      userDataURL: userRoot,
      activeGenerationProvider: provider
    )
    let sessionA = engineA.createSession()
    XCTAssertTrue(sessionA.isValid)
    XCTAssertTrue(sessionA.process(keycode: UInt32(XK_n), modifiers: 0))

    let installedB = try await store.install(
      OwlRustResourceDirectorySource(root: makePackage(version: 2))
    )
    XCTAssertEqual(installedB.disposition, .installed)
    XCTAssertEqual(
      installedB.state.previous?.generationId,
      installedA.state.current.generationId
    )
    XCTAssertTrue(
      sessionA.process(keycode: UInt32(XK_i), modifiers: 0),
      "activating another generation must not disturb the live old session"
    )
    XCTAssertEqual(sessionA.input(), "ni")
    sessionA.destroy()

    let dictionaries = userRoot.appendingPathComponent(
      "msime-user/dictionaries", isDirectory: true
    )
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: dictionaries.appendingPathComponent(
        "\(installedA.state.current.generationId)/.ready"
      ).path
    ))

    // A fresh engine instance sees the persisted active generation.
    let engineB = OwlRustEngine(
      sharedSupportURL: seedDir,
      userDataURL: userRoot,
      activeGenerationProvider: provider
    )
    let sessionB = engineB.createSession()
    XCTAssertTrue(sessionB.isValid)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: dictionaries.appendingPathComponent(
        "\(installedB.state.current.generationId)/.ready"
      ).path
    ))
    for scalar in "nigu".unicodeScalars {
      XCTAssertTrue(sessionB.process(keycode: scalar.value, modifiers: 0))
    }
    let learned = "拟古"
    let learnedIndex = try XCTUnwrap(
      sessionB.peekCandidates(from: 0, count: 1_000)
        .firstIndex(where: { $0.text == learned })
    )
    XCTAssertTrue(sessionB.selectCandidateAbsolute(learnedIndex))
    XCTAssertEqual(sessionB.takeCommit(), learned)
    sessionB.destroy()

    let journal = userRoot.appendingPathComponent("msime-user/msime_user.db")
    func learnedOperationCount() -> Int {
      var database: OpaquePointer?
      guard sqlite3_open_v2(
        journal.path, &database, SQLITE_OPEN_READONLY, nil
      ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        return 0
      }
      defer { sqlite3_close(database) }
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(
        database,
        "SELECT count(*) FROM user_dictionary_operations",
        -1,
        &statement,
        nil
      ) == SQLITE_OK, let statement else {
        if let statement { sqlite3_finalize(statement) }
        return 0
      }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
      return Int(sqlite3_column_int(statement, 0))
    }
    let journalDeadline = Date().addingTimeInterval(5)
    var persistedOperations = learnedOperationCount()
    while persistedOperations == 0, Date() < journalDeadline {
      try await Task.sleep(nanoseconds: 100_000_000)
      persistedOperations = learnedOperationCount()
    }
    XCTAssertGreaterThan(
      persistedOperations, 0,
      "personal learning must reach the shared journal before rollback"
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: userRoot.appendingPathComponent("msime_user.db").path
    ))

    let rolledBack = try await store.rollback(
      inputKind: OwlRustResourceEnvironment.activeInputKind
    )
    XCTAssertEqual(rolledBack.current.generationId, installedA.state.current.generationId)
    let sessionAReopened = engineB.createSession()
    XCTAssertTrue(sessionAReopened.isValid)
    for scalar in "nigu".unicodeScalars {
      XCTAssertTrue(sessionAReopened.process(keycode: scalar.value, modifiers: 0))
    }
    XCTAssertEqual(
      sessionAReopened.composition()?.candidates.first?.text, learned,
      "a rolled-back generation must replay learning from the shared journal"
    )
    sessionAReopened.destroy()

    for (relativePath, expected) in protectedFiles {
      XCTAssertEqual(
        try Data(contentsOf: userRoot.appendingPathComponent(relativePath)),
        expected,
        "generation switching must not rewrite \(relativePath)"
      )
    }
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
