//
//  OwlRustEngineTests.swift
//  OwltypeTests
//
//  Unit and integration tests for the narrow C-ABI Rust engine adapter
//  (`OwlRustEngine` / `OwlRustSession`) backing #249.
//

import Foundation
import Carbon
import SQLite3
import XCTest
@testable import Owltype

final class OwlRustEngineTests: XCTestCase {

  // Opt-in transport for scripts/pinyin-parity.py. Uses the same public host seam as IMK;
  // all preferences and learning state are isolated from the installed input method.
  func testExportPinyinParityTrace() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let requestPath = environment["OWL_PINYIN_PARITY_REQUEST"],
          let outputPath = environment["OWL_PINYIN_PARITY_OUTPUT"] else {
      throw XCTSkip("Run scripts/pinyin-parity.py with a current .xctestrun to export a trace")
    }
    let request = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: URL(fileURLWithPath: requestPath))) as? [String: Any])
    let events = try XCTUnwrap(request["events"] as? [[String: Any]])
    let resources = URL(fileURLWithPath: try XCTUnwrap(request["resources"] as? String))
    let defaults = OwlDefaults.standard
    XCTAssertTrue(OwlDefaults.isRunningUnitTests)
    let saved = defaults.persistentDomain(forName: OwlDefaults.testSuiteName)
    defaults.removePersistentDomain(forName: OwlDefaults.testSuiteName)
    defer {
      defaults.removePersistentDomain(forName: OwlDefaults.testSuiteName)
      if let saved { defaults.setPersistentDomain(saved, forName: OwlDefaults.testSuiteName) }
    }
    OwlKeyboardPreferences.pageSize = try XCTUnwrap(request["page_size"] as? Int)
    // The runner owns this fresh temporary root across separate test-host processes.
    let stateRoot = try XCTUnwrap(request["state_root"] as? String)
    let temporary = URL(fileURLWithPath: stateRoot)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let engine = OwlRustEngine(sharedSupportURL: resources, userDataURL: temporary,
                               activeGenerationProvider: { nil })
    var session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }
    let schema = request["schema"] as? String ?? "rime_ice"
    guard session.selectSchema(schema) else {
      XCTFail("Requested parity schema is unsupported: \(schema)")
      return
    }
    let commands: [String: UInt32] = [
      "backspace": 0xff08, "commit": 0xff0d, "cancel": 0xff1b,
      "left": 0xff51, "right": 0xff53, "home": 0xff50, "end": 0xff57,
      "delete": 0xffff, "next-page": 0xff56, "previous-page": 0xff55
    ]
    var steps: [[String: Any]] = []
    for event in events {
      let op = try XCTUnwrap(event["op"] as? String)
      let consumed: Bool
      switch op {
      case "schema":
        XCTAssertTrue(session.selectSchema(try XCTUnwrap(event["schema"] as? String)))
        session.setOption(.linear, event["left_right"] as? Bool ?? true)
        consumed = true
      case "character":
        let value = try XCTUnwrap(event["value"] as? String)
        let scalar = try XCTUnwrap(value.unicodeScalars.first)
        XCTAssertEqual(value.utf8.count, 1)
        consumed = session.process(keycode: scalar.value, modifiers: 0)
      case "command":
        let value = try XCTUnwrap(event["value"] as? String)
        let parts = value.split(separator: "-", maxSplits: 1).map(String.init)
        let chord = parts.count == 2 && ["ctrl", "shift"].contains(parts[0])
        let key = chord ? parts[1] : value
        let modifiers = chord ? (parts[0] == "ctrl" ? kControlMask.rawValue : kShiftMask.rawValue) : 0
        consumed = session.process(keycode: try XCTUnwrap(commands[key]), modifiers: modifiers)
      case "select":
        let index = try XCTUnwrap(event["index"] as? Int)
        let visible = try XCTUnwrap(session.composition())
        XCTAssertTrue(visible.candidates.indices.contains(index))
        consumed = session.selectCandidate(index)
      case "remove":
        let index = try XCTUnwrap(event["index"] as? Int)
        consumed = session.removeCandidate(OwlCandidateToken(
          sessionID: session.sessionID, generation: session.generation, candidateID: index))
      case "restart":
        session.destroy()
        XCTAssertTrue(engine.finalize(), "Restart must close cached learning handles")
        session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
        XCTAssertTrue(session.selectSchema(schema))
        consumed = true
      default:
        XCTFail("Unsupported parity event: \(op)")
        return
      }
      let composition = try XCTUnwrap(session.composition())
      steps.append([
        "event": event, "consumed": consumed, "input": session.input() ?? "",
        "preedit": composition.preedit, "caret": session.caretPos(),
        "page": composition.pageNo, "page_size": composition.pageSize,
        "has_more": !composition.isLastPage, "highlighted": composition.highlightedIndex,
        "candidates": composition.candidates.map(\.text),
        "commit": session.takeCommit() as Any? ?? NSNull()
      ])
    }
    let result: [String: Any] = [
      "run_id": try XCTUnwrap(request["run_id"] as? String),
      "steps": steps,
      "preferences": defaults.persistentDomain(forName: OwlDefaults.testSuiteName) ?? [:],
      "configuration": ["schema": schema, "page_size": OwlKeyboardPreferences.pageSize,
                        "wubi_auto_commit_unique": OwlKeyboardPreferences.wubiAutoCommitUnique,
                        "wubi_fifth_code_top_commit": OwlKeyboardPreferences.wubiFifthCodeTopCommit,
                        "wubi_code_hint": OwlKeyboardPreferences.wubiCodeHint,
                        "wubi_z_wildcard": OwlKeyboardPreferences.wubiZWildcard,
                        "wubi_auto_clear": OwlKeyboardPreferences.wubiAutoClear,
                        "wubi_candidate_mode": OwlKeyboardPreferences.wubiCandidateMode.rawValue,
                        "wubi_z_reverse_lookup": OwlKeyboardPreferences.wubiZReverseLookup,
                        "wubi_english_channel": OwlKeyboardPreferences.wubiEnglishChannel,
                        "wubi_user_dict_learning": OwlKeyboardPreferences.wubiUserDictLearning,
                        "rerank": OwlRerankConfiguration.current(sharedSupportURL: resources).serialized() ?? ""]
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: outputPath), options: .atomic)
  }

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
    engine.setup(
      OwlEngineTraits(
        sharedDataDir: seedDir,
        userDataDir: userDir,
        logDir: userDir,
        appName: OwlRimeIdentity.appName
      )
    )
    return engine
  }

  private func removeResourceTestTree(_ root: URL) {
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
      while let url = enumerator?.nextObject() as? URL {
        if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
          try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
      }
      try FileManager.default.removeItem(at: root)
    } catch { XCTFail("isolated resource cleanup failed: \(error)") }
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

  private func classifiedCapsLockTransition(
    physicalLockBefore: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> (keycode: UInt32, modifiers: UInt32) {
    let lastModifiers: NSEvent.ModifierFlags = physicalLockBefore ? [.capsLock] : []
    let modifierFlags: NSEvent.ModifierFlags = physicalLockBefore ? [] : [.capsLock]
    let event = OwlKeyEvent(
      type: .flagsChanged,
      keyCode: UInt16(kVK_CapsLock),
      characters: nil,
      charactersIgnoringModifiers: nil,
      modifierFlags: modifierFlags,
      lastModifiers: lastModifiers
    )
    guard case let .flagsChanged(revert, events, _, handled) =
      OwlUserActionClassifier.classify(event) else {
      XCTFail("Expected classified Caps Lock flagsChanged", file: file, line: line)
      return (keycode: 0, modifiers: 0)
    }
    XCTAssertTrue(events.isEmpty, file: file, line: line)
    XCTAssertFalse(handled, file: file, line: line)
    guard let transition = revert else {
      XCTFail("Expected a Caps Lock revert event", file: file, line: line)
      return (keycode: 0, modifiers: 0)
    }
    XCTAssertEqual(transition.keycode, UInt32(XK_Caps_Lock), file: file, line: line)
    return transition
  }

  private func asciiKeycode(_ character: Character) -> UInt32 {
    UInt32(character.asciiValue!)
  }

  private func visibleAndPeekedCandidates(
    in session: RimeSession,
    count: Int = 100
  ) -> [RimeCandidate] {
    guard let composition = session.composition() else { return [] }
    let start = composition.pageSize
    return composition.candidates + session.peekCandidates(from: start, count: count)
  }

  private func makeHostPhraseUserDirectory() throws -> URL {
    let userDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-rust-host-phrases-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: userDir) }
    return userDir
  }

  private func makeHostPhraseEngine(userDataURL: URL) throws -> OwlRustEngine {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let seedDir = repoRoot.appendingPathComponent("data/owl-rime")
    let pinyinDB = seedDir.appendingPathComponent("msime/msime-pinyin.db")
    guard FileManager.default.fileExists(atPath: pinyinDB.path) else {
      throw XCTSkip("msime-pinyin.db not generated yet at \(pinyinDB.path)")
    }
    return OwlRustEngine(sharedSupportURL: seedDir, userDataURL: userDataURL)
  }

  private func waitForSettledRerankReady(
    _ session: OwlRustSession,
    timeout: TimeInterval = 30
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      session.syncRerankPreferences()
      if session.settledRerankReady {
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    XCTFail("settled rerank model did not become ready within \(timeout) seconds")
  }

  private func writeHostPhrase(
    _ contents: String,
    fileName: String,
    to userDataURL: URL
  ) throws {
    try contents.write(
      to: userDataURL.appendingPathComponent(fileName),
      atomically: true,
      encoding: .utf8
    )
  }

  func testRerankConfigurationDefaultsOffAndUsesStablePackagePaths() throws {
    let defaults = OwlDefaults.standard
    let keyboardKey = "OwlExperimentalKeyboardRerankEnabled"
    let settledKey = "OwlExperimentalSettledRerankEnabled"
    let savedKeyboard = defaults.object(forKey: keyboardKey)
    let savedSettled = defaults.object(forKey: settledKey)
    defer {
      if let savedKeyboard {
        defaults.set(savedKeyboard, forKey: keyboardKey)
      } else {
        defaults.removeObject(forKey: keyboardKey)
      }
      if let savedSettled {
        defaults.set(savedSettled, forKey: settledKey)
      } else {
        defaults.removeObject(forKey: settledKey)
      }
    }
    defaults.removeObject(forKey: keyboardKey)
    defaults.removeObject(forKey: settledKey)

    let root = URL(fileURLWithPath: "/private/tmp/owl-rerank-config", isDirectory: true)
    let disabled = OwlRerankConfiguration.current(sharedSupportURL: root)
    XCTAssertFalse(disabled.keyboard.enabled)
    XCTAssertFalse(disabled.settled.enabled)
    XCTAssertEqual(
      disabled.keyboard.path,
      root.appendingPathComponent("msime/models/keyboard-model.bin").path
    )
    XCTAssertEqual(
      disabled.settled.path,
      root.appendingPathComponent("msime/models/settled-model.bin").path
    )

    let first = try XCTUnwrap(disabled.serialized())
    XCTAssertEqual(first, disabled.serialized())
    XCTAssertTrue(first.contains("\"expected_sha256\""))
    XCTAssertTrue(first.contains(OwlRerankModelDescriptor.keyboard.expectedSHA256))
    XCTAssertTrue(first.contains(OwlRerankModelDescriptor.settled.expectedSHA256))

    OwlExperimentalPreferences.keyboardRerankEnabled = true
    OwlExperimentalPreferences.settledRerankEnabled = true
    let enabled = OwlRerankConfiguration.current(sharedSupportURL: root)
    XCTAssertTrue(enabled.keyboard.enabled)
    XCTAssertTrue(enabled.settled.enabled)
    XCTAssertNotEqual(enabled.serialized(), first)
    OwlExperimentalPreferences.keyboardRerankEnabled = false
    let desktopOnly = OwlRerankConfiguration.current(sharedSupportURL: root)
    XCTAssertFalse(desktopOnly.keyboard.enabled)
    XCTAssertTrue(desktopOnly.settled.enabled)
    OwlExperimentalPreferences.keyboardRerankEnabled = true
    OwlExperimentalPreferences.settledRerankEnabled = false
    let keyboardOnly = OwlRerankConfiguration.current(sharedSupportURL: root)
    XCTAssertTrue(keyboardOnly.keyboard.enabled)
    XCTAssertFalse(keyboardOnly.settled.enabled)
  }

  func testSettledRerankTicketPreservesFullGenerationAndRejectsStalePresentations() {
    let highGeneration = (UInt64(1) << 63) | 0x5a5a
    let ticket = OwlSettledRerankTicket(
      sessionID: 42,
      generation: highGeneration,
      rawInput: "nihao",
      configurationEpoch: 7
    )
    XCTAssertTrue(ticket.isCurrent(
      sessionID: 42,
      generation: highGeneration,
      rawInput: "nihao",
      configurationEpoch: 7
    ))
    XCTAssertFalse(ticket.isCurrent(
      sessionID: 43,
      generation: highGeneration,
      rawInput: "nihao",
      configurationEpoch: 7
    ))
    XCTAssertFalse(ticket.isCurrent(
      sessionID: 42,
      generation: highGeneration + 1,
      rawInput: "nihao",
      configurationEpoch: 7
    ))
    XCTAssertFalse(ticket.isCurrent(
      sessionID: 42,
      generation: highGeneration,
      rawInput: "nihaoa",
      configurationEpoch: 7
    ))
    XCTAssertFalse(ticket.isCurrent(
      sessionID: 42,
      generation: highGeneration,
      rawInput: "nihao",
      configurationEpoch: 8
    ))
  }

  func testSettledRerankRefreshesVisibleSnapshotBeforeDigitSelection() throws {
    let defaults = OwlDefaults.standard
    let keyboardKey = "OwlExperimentalKeyboardRerankEnabled"
    let settledKey = "OwlExperimentalSettledRerankEnabled"
    let savedKeyboard = defaults.object(forKey: keyboardKey)
    let savedSettled = defaults.object(forKey: settledKey)
    defer {
      if let savedKeyboard {
        defaults.set(savedKeyboard, forKey: keyboardKey)
      } else {
        defaults.removeObject(forKey: keyboardKey)
      }
      if let savedSettled {
        defaults.set(savedSettled, forKey: settledKey)
      } else {
        defaults.removeObject(forKey: settledKey)
      }
    }
    OwlExperimentalPreferences.keyboardRerankEnabled = false
    OwlExperimentalPreferences.settledRerankEnabled = true

    for usesToken in [false, true] {
      // Each selection path starts with a blank learning journal.
      let engine = try makeSharedSupportSeedEngine()
      let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
      defer { session.destroy() }
      waitForSettledRerankReady(session)

      // Pinned 0.55.0 with the official dictionary keeps zhongguoren unchanged.
      // The desktop model changes this sentence's first two rows in a blank state.
      typeText("tadefangjian", into: session)
      let before = try XCTUnwrap(session.composition())
      let beforeGeneration = session.generation

      let started = session.startSettledRerank()
      let moved: Bool
      let current: Bool
      if let token = started.token {
        var result = OwlSettledRerankPollResult(
          pending: true,
          current: false,
          moved: false,
          error: nil
        )
        let deadline = Date().addingTimeInterval(30)
        repeat {
          RunLoop.current.run(until: Date().addingTimeInterval(0.02))
          result = session.pollSettledRerank(token: token, accept: true)
        } while result.pending && Date() < deadline
        XCTAssertFalse(result.pending, "settled rerank poll did not finish")
        XCTAssertNil(result.error)
        moved = result.moved
        current = result.current
      } else {
        XCTAssertNil(started.error)
        moved = started.moved
        current = started.current
      }

      XCTAssertTrue(current)
      XCTAssertTrue(moved, "real settled model must move the tadefangjian candidate order")
      let refreshed = try XCTUnwrap(session.composition())
      XCTAssertGreaterThan(session.generation, beforeGeneration)
      XCTAssertNotEqual(
        refreshed.candidates.map(\.text),
        before.candidates.map(\.text),
        "a moved settled result must refresh the visible candidate order"
      )
      let visibleFirst = try XCTUnwrap(refreshed.candidates.first)
      if usesToken {
        let stale = OwlCandidateToken(
          sessionID: session.sessionID,
          generation: beforeGeneration,
          candidateID: 0,
          isAbsolute: false
        )
        XCTAssertFalse(session.selectCandidate(stale))
        XCTAssertNil(session.takeCommit())
        let fresh = OwlCandidateToken(
          sessionID: session.sessionID,
          generation: session.generation,
          candidateID: 0,
          isAbsolute: false
        )
        XCTAssertTrue(session.selectCandidate(fresh))
      } else {
        XCTAssertTrue(session.process(keycode: UInt32(XK_1), modifiers: 0))
      }
      XCTAssertEqual(
        session.takeCommit(),
        visibleFirst.text,
        "selection must commit the candidate currently visible after reranking"
      )
    }
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

  func testRustAppEnglishListOverridesTheDefaultWithoutBecomingGlobal() {
    let listed = OwlRustSchemaMap.initialASCIIMode(
      forApp: "com.example.Editor",
      englishBundleIDs: ["com.example.Editor"],
      defaultASCIIMode: false
    )
    let unlisted = OwlRustSchemaMap.initialASCIIMode(
      forApp: "com.example.Notes",
      englishBundleIDs: ["com.example.Editor"],
      defaultASCIIMode: false
    )

    XCTAssertTrue(listed)
    XCTAssertFalse(unlisted)
  }

  func testShuangpinSemicolonSpellingPrecedesCandidateShortcut() throws {
    let original = OwlKeyboardPreferences.select23Semicolon
    defer { OwlKeyboardPreferences.select23Semicolon = original }
    let engine = try makeSharedSupportSeedEngine()
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }
    for shortcut in [false, true] {
      OwlKeyboardPreferences.select23Semicolon = shortcut
      for schema in ["double_pinyin_sogou", "double_pinyin_ziguang"] {
        session.clearComposition()
        XCTAssertTrue(session.selectSchema(schema))
        typeText("y;", into: session)
        XCTAssertNil(session.takeCommit(), "\(schema), shortcut=\(shortcut)")
        XCTAssertEqual(session.composition()?.preedit, "y;")
        XCTAssertFalse(session.composition()?.candidates.isEmpty ?? true)
        // Backspace must restore the semicolon as a spelling key.
        XCTAssertTrue(session.process(keycode: UInt32(XK_BackSpace), modifiers: 0))
        XCTAssertEqual(session.composition()?.preedit, "y")
        typeText(";", into: session)
        let visible = try XCTUnwrap(session.composition()?.candidates.first?.text)
        XCTAssertTrue(session.process(keycode: UInt32(XK_space), modifiers: 0))
        XCTAssertEqual(session.takeCommit(), visible)
      }
    }
  }

  func testSegmentChordEditsPinyinRatherThanPassingToHost() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }
    for (schema, code, leftCaret) in [("double_pinyin_flypy", "nihc", 2), ("rime_ice", "nihao", 2)] {
      XCTAssertTrue(session.selectSchema(schema))
      typeText(code, into: session)
      XCTAssertTrue(session.process(keycode: UInt32(XK_Left), modifiers: kControlMask.rawValue))
      XCTAssertEqual(session.caretPos(), leftCaret)
      XCTAssertTrue(session.process(keycode: UInt32(XK_Right), modifiers: kShiftMask.rawValue))
      XCTAssertEqual(session.caretPos(), code.utf8.count)
      XCTAssertTrue(session.process(keycode: UInt32(XK_BackSpace), modifiers: kControlMask.rawValue))
      XCTAssertEqual(session.input(), "ni")
      session.clearComposition()
      XCTAssertFalse(session.process(keycode: UInt32(XK_Left), modifiers: kControlMask.rawValue))
    }
  }

  func testShuangpinSegmentEditingAndShoudaoSelection() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }
    XCTAssertTrue(session.selectSchema(OwlDoublePinyin.shoudao.schemaId))
    typeText("nihd", into: session)
    XCTAssertTrue(session.composition()?.candidates.contains { $0.text == "你好" } == true)
    session.setOption(.linear, false)
    XCTAssertTrue(session.process(keycode: UInt32(XK_Left), modifiers: 0))
    XCTAssertEqual(session.caretPos(), 2, "double pinyin edits whole syllables")
    XCTAssertTrue(session.process(keycode: UInt32(XK_Right), modifiers: 0))
    XCTAssertEqual(session.caretPos(), 4)
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertNotNil(session.takeCommit())
  }

  func testIncompleteGenerationCannotOmitAuxiliaryResources() throws {
    let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("data/owl-rime")
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-incomplete-generation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let built = try OwlRustCompatibleResources.build(sharedSupport: seed, at: temporary, version: 2)
    try FileManager.default.removeItem(at: temporary.appendingPathComponent("files/msime-others.db"))
    XCTAssertThrowsError(try OwlRustCompatibleResources.validate(at: temporary, manifest: built.manifest,
                                                               requireCompleteMarker: false))
  }

  func testPinnedWubiIdentityRejectsAValidDigestWithAnEmpty98Table() throws {
    let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("data/owl-rime")
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-empty-wubi98-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let built = try OwlRustCompatibleResources.build(sharedSupport: seed, at: temporary, version: 3)
    let wubi = temporary.appendingPathComponent("files/msime-wubi.db")
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(wubi.path, &database), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(database, "DELETE FROM wubi98", nil, nil, nil), SQLITE_OK)
    sqlite3_close(database)
    let files = try built.manifest.files.map { file -> OwlRustResourceFile in
      guard file.path == "files/msime-wubi.db" else { return file }
      let attributes = try FileManager.default.attributesOfItem(atPath: wubi.path)
      return OwlRustResourceFile(path: file.path, role: file.role, mediaType: file.mediaType,
        size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
        digest: try OwlRustResourceVerifier.digestOfFile(wubi))
    }
    let unsigned = OwlRustResourceManifest(schemaVersion: 1, packageId: built.manifest.packageId,
      inputKind: .pinyinWubi, version: 3, digest: OwlRustResourceManifest.zeroDigest,
      license: built.manifest.license, engineCompatibility: built.manifest.engineCompatibility, files: files)
    let changed = OwlRustResourceManifest(schemaVersion: 1, packageId: unsigned.packageId,
      inputKind: unsigned.inputKind, version: 3, digest: try unsigned.calculatedDigest(),
      license: unsigned.license, engineCompatibility: unsigned.engineCompatibility, files: files)
    // Both tables still have valid schemas and every byte agrees with this new manifest.
    XCTAssertNoThrow(try OwlRustResourceVerifier.verifyGeneration(at: temporary, manifest: changed,
      engine: .owlRustNativeInputV1, requireCompleteMarker: false))
    XCTAssertThrowsError(try OwlRustCompatibleResources.validate(at: temporary, manifest: changed,
      requireCompleteMarker: false)) { error in
      guard case OwlRustResourceError.incompatibleEngine = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testProductionUpdatePreparesTheCompletePinnedCombination() async throws {
    let user = URL(fileURLWithPath: "/private/tmp/owl-pinned-update-\(UUID().uuidString)")
    defer { removeResourceTestTree(user) }
    let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("data/owl-rime")
    let backend = OwlDictPackCenterRustBackend.production(userRoot: user, sharedSupport: seed)
    let prepared = try await backend.prepare(backend.environment, nil)
    XCTAssertNil(try backend.environment.activeState(), "preparing must not activate")
    XCTAssertEqual(prepared.version, OwlRustCompatibleResources.packageVersion)
    let names = Set(prepared.resource.record.manifest.files.map(\.path))
    for name in OwlRustCompatibleResources.requiredFiles + ["compatibility.txt"] {
      XCTAssertTrue(names.contains("files/" + name), "complete payload lacks \(name)")
    }
    XCTAssertGreaterThan(prepared.stats.pinyinEntries, 900_000)
    XCTAssertEqual(prepared.stats.wubiEntries, 126_078)
    XCTAssertGreaterThan(prepared.stats.englishEntries, 70_000)
    let preparedResources = try backend.environment.validatedGeneration(prepared.resource.record).resourcesURL
    let model = preparedResources.appendingPathComponent("models/keyboard-model.bin")
    let originalModel = try Data(contentsOf: model)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: model.path)
    try Data("corrupt model".utf8).write(to: model)
    do {
      _ = try await backend.activate(backend.environment, prepared.resource)
      XCTFail("a corrupt prepared model must never activate")
    } catch is OwlRustResourceError {}
    XCTAssertNil(try backend.environment.activeState())
    try originalModel.write(to: model)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: model.path)
    let installed = try await backend.activate(backend.environment, prepared.resource)
    XCTAssertEqual(try backend.environment.activeGeneration()?.contentID, installed.state.current.generationId)
    let engine = OwlRustEngine(sharedSupportURL: seed, userDataURL: user)
    let session = engine.createSession()
    defer { session.destroy() }
    XCTAssertTrue(session.isValid)
    typeText("tadefangjian", into: session)
    XCTAssertEqual(session.composition()?.candidates.first?.text, "它的房间")
  }

  func testActivatedGenerationUsesItsOwnAuxiliaryResources() throws {
    let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("data/owl-rime")
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-complete-generation-\(UUID().uuidString)")
    let resources = temporary.appendingPathComponent("msime")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    for name in ["msime-pinyin.db", "msime-english.db", "msime-bigram.bin", "msime-trigram.bin"] {
      try FileManager.default.copyItem(at: seed.appendingPathComponent("msime/" + name),
                                      to: resources.appendingPathComponent(name))
    }
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(resources.appendingPathComponent("msime-others.db").path, &database), SQLITE_OK)
    defer { sqlite3_close(database) }
    XCTAssertEqual(sqlite3_exec(database, """
      CREATE TABLE emoji (emoji TEXT PRIMARY KEY, category TEXT, sort_order INTEGER, keywords TEXT, pinyin TEXT);
      CREATE TABLE emoji_pinyin (key TEXT, emoji TEXT, sort_order INTEGER, PRIMARY KEY(key, emoji));
      INSERT INTO emoji VALUES ('🦉🦉', 'Nature', 0, '苹果', 'pingguo');
      INSERT INTO emoji_pinyin VALUES ('pingguo', '🦉🦉', 0);
      """, nil, nil, nil), SQLITE_OK)
    try FileManager.default.copyItem(at: seed.appendingPathComponent("msime/models"),
                                    to: resources.appendingPathComponent("models"))
    let missingBundle = temporary.appendingPathComponent("bundle")
    try FileManager.default.createDirectory(at: missingBundle, withIntermediateDirectories: true)
    let savedSettled = OwlExperimentalPreferences.settledRerankEnabled
    let savedKeyboard = OwlExperimentalPreferences.keyboardRerankEnabled
    OwlExperimentalPreferences.keyboardRerankEnabled = false
    OwlExperimentalPreferences.settledRerankEnabled = true
    defer {
      OwlExperimentalPreferences.settledRerankEnabled = savedSettled
      OwlExperimentalPreferences.keyboardRerankEnabled = savedKeyboard
    }
    let generation = OwlRustResourceGeneration(resourcesURL: resources, contentID: "complete-resource-test")
    let engine = OwlRustEngine(sharedSupportURL: missingBundle,
      userDataURL: temporary.appendingPathComponent("user"), activeGenerationProvider: { generation })
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }
    session.setOption(.emojiSuggestion, true)
    typeText("pingguo", into: session)
    let candidates = session.peekCandidates(from: 0, count: 100)
    XCTAssertTrue(candidates.contains { $0.text == "🦉🦉" }, "the activated auxiliary database must be used")
    XCTAssertFalse(candidates.contains { $0.text == "🍎" || $0.text == "🍏" }, "do not mix bundled auxiliary data")
    waitForSettledRerankReady(session)
    session.clearComposition()
    typeText("tadefangjian", into: session)
    XCTAssertEqual(session.composition()?.candidates.first?.text, "它的房间")
    let started = session.startSettledRerank()
    if let token = started.token {
      var result = session.pollSettledRerank(token: token, accept: true)
      let deadline = Date().addingTimeInterval(30)
      while result.pending && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        result = session.pollSettledRerank(token: token, accept: true)
      }
      XCTAssertFalse(result.pending)
      XCTAssertTrue(result.current)
      XCTAssertTrue(result.moved)
      XCTAssertNil(result.error)
    } else {
      XCTAssertTrue(started.current)
      XCTAssertTrue(started.moved)
      XCTAssertNil(started.error)
    }
    XCTAssertEqual(session.composition()?.candidates.first?.text, "他的房间",
                   "generation-owned model must score even when bundle models are unavailable")
  }

  func testRustSessionSelectsCustomShuangpinProfilesAndRejectsUnknownSchema() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }

    let cases = [
      ("double_pinyin_sogou", "nihk"),
      ("double_pinyin_ziguang", "nihq"),
      ("double_pinyin_jiajia", "nihd")
    ]
    for (schema, code) in cases {
      session.clearComposition()
      XCTAssertTrue(session.selectSchema(schema), schema)
      XCTAssertEqual(session.status()?.schemaId, schema)
      typeText(code, into: session)
      XCTAssertEqual(session.composition()?.preedit, code, schema)
      XCTAssertTrue(
        session.composition()?.candidates.contains(where: { $0.text == "你好" }) == true,
        schema
      )
    }

    XCTAssertFalse(session.selectSchema("unknown_schema"))
    XCTAssertEqual(session.status()?.schemaId, "double_pinyin_jiajia")
    session.clearComposition()
    typeText("nihd", into: session)
    XCTAssertEqual(
      session.composition()?.candidates.contains(where: { $0.text == "你好" }),
      true,
      "a rejected schema must leave the previous custom table active"
    )
  }

  func testRuntimePreferenceSyncAppliesCJKPunctuationOnlyAfterSuccess() throws {
    let original = OwlKeyboardPreferences.cjkPunctToggle
    defer { OwlKeyboardPreferences.cjkPunctToggle = original }

    let engine = try makeSharedSupportSeedEngine()
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }

    OwlKeyboardPreferences.cjkPunctToggle = true
    XCTAssertTrue(session.syncRuntimePreferences(includeHostPhrases: false))
    XCTAssertTrue(session.option(.asciiPunct))

    OwlKeyboardPreferences.cjkPunctToggle = false
    XCTAssertTrue(session.syncRuntimePreferences(includeHostPhrases: false))
    XCTAssertFalse(session.option(.asciiPunct))
  }

  func testRustPunctuationMenusMatchRimeOrderAndContinueTyping() throws {
    let originalSlash = OwlKeyboardPreferences.slashSymbolMenu
    let originalAngle = OwlKeyboardPreferences.angleSymbolMenu
    defer {
      OwlKeyboardPreferences.slashSymbolMenu = originalSlash
      OwlKeyboardPreferences.angleSymbolMenu = originalAngle
    }
    OwlKeyboardPreferences.slashSymbolMenu = true
    OwlKeyboardPreferences.angleSymbolMenu = true

    let engine = try makeSharedSupportSeedEngine()
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }

    let slash = UInt32(UInt8(ascii: "/"))
    XCTAssertTrue(session.process(keycode: slash, modifiers: 0))
    XCTAssertEqual(session.composition()?.preedit, "/")
    XCTAssertEqual(session.composition()?.candidates.map(\.text), ["、", "/", "／", "÷"])
    XCTAssertFalse(session.option(.asciiMode), "the slash menu must not switch to English")

    XCTAssertTrue(session.process(keycode: slash, modifiers: 0))
    XCTAssertEqual(session.composition()?.highlightedIndex, 1)
    XCTAssertTrue(session.process(keycode: UInt32(UInt8(ascii: "2")), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), "/")

    let angle = UInt32(UInt8(ascii: "<"))
    XCTAssertTrue(session.process(keycode: angle, modifiers: 0))
    XCTAssertEqual(session.composition()?.candidates.map(\.text), ["《", "〈", "<", "「", "“"])
    XCTAssertTrue(session.process(keycode: UInt32(UInt8(ascii: "a")), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), "《")
    XCTAssertEqual(session.composition()?.preedit, "a", "typing continues after the selected symbol")
  }

  func testRustAngleMenuOffKeepsDirectPunctuation() throws {
    let original = OwlKeyboardPreferences.angleSymbolMenu
    defer { OwlKeyboardPreferences.angleSymbolMenu = original }
    OwlKeyboardPreferences.angleSymbolMenu = false

    let engine = try makeSharedSupportSeedEngine()
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }

    XCTAssertTrue(session.process(keycode: UInt32(UInt8(ascii: "<")), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), "《")
    XCTAssertNil(session.composition()?.candidates.first)
  }

  func testRustCurrencyMenuOffersDollarThenYuan() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }

    let four = UInt32(XK_4)
    XCTAssertTrue(session.process(keycode: four, modifiers: kShiftMask.rawValue))
    XCTAssertEqual(session.composition()?.preedit, "$")
    XCTAssertEqual(session.composition()?.candidates.map(\.text), ["$", "¥"])

    XCTAssertTrue(session.process(keycode: four, modifiers: kShiftMask.rawValue))
    XCTAssertEqual(session.composition()?.highlightedIndex, 1)
    XCTAssertTrue(session.process(keycode: UInt32(XK_2), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), "¥")
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

  @MainActor
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
    defer { removeResourceTestTree(userRoot) }

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

    let defaults = OwlDefaults.standard
    let learningKey = "OwlKeyboardWubiUserDictLearning"
    let savedLearning = defaults.object(forKey: learningKey)
    defaults.set(true, forKey: learningKey)
    defer {
      if let savedLearning { defaults.set(savedLearning, forKey: learningKey) }
      else { defaults.removeObject(forKey: learningKey) }
    }

    func assertWubi(_ session: any RimeSession, learned86: Bool, learned98: Bool) {
      for (schema, code, learned) in [("wubi86_jidian", "go", learned86), ("wubi98", "gu", learned98)] {
        XCTAssertTrue(session.selectSchema(schema))
        typeText(code, into: session)
        XCTAssertEqual(session.composition()?.candidates.first?.text, "来")
        session.clearComposition()
        typeText("gggg", into: session)
        XCTAssertEqual(session.composition()?.candidates.first?.text, learned ? "五一" : "王")
        session.clearComposition()
      }
      XCTAssertTrue(session.selectSchema("rime_ice"))
    }

    func learnWubi(_ session: any RimeSession, schema: String) {
      XCTAssertTrue(session.selectSchema(schema))
      typeText("gggg", into: session)
      XCTAssertTrue(session.selectCandidate(1))
      XCTAssertEqual(session.takeCommit(), "五一")
      XCTAssertTrue(session.selectSchema("rime_ice"))
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
      let built = try OwlRustCompatibleResources.build(sharedSupport: seedDir, at: packageRoot, version: version)
      if version == 2 {
        let others = packageRoot.appendingPathComponent("files/msime-others.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(others.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, """
          UPDATE emoji SET emoji='🦉🦉' WHERE emoji='🍎';
          UPDATE emoji_pinyin SET emoji='🦉🦉' WHERE emoji='🍎';
          DELETE FROM emoji_pinyin WHERE emoji='🍏';
          """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let files = try built.manifest.files.map { file -> OwlRustResourceFile in
          guard file.path == "files/msime-others.db" else { return file }
          let attributes = try FileManager.default.attributesOfItem(atPath: others.path)
          return OwlRustResourceFile(path: file.path, role: file.role, mediaType: file.mediaType,
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            digest: try OwlRustResourceVerifier.digestOfFile(others))
        }
        let unsigned = OwlRustResourceManifest(schemaVersion: 1, packageId: built.manifest.packageId,
          inputKind: .pinyinWubi, version: version, digest: OwlRustResourceManifest.zeroDigest,
          license: built.manifest.license, engineCompatibility: built.manifest.engineCompatibility, files: files)
        let manifest = OwlRustResourceManifest(schemaVersion: 1, packageId: unsigned.packageId,
          inputKind: unsigned.inputKind, version: version, digest: try unsigned.calculatedDigest(),
          license: unsigned.license, engineCompatibility: unsigned.engineCompatibility, files: files)
        try manifest.canonicalData().write(to: packageRoot.appendingPathComponent("manifest.json"))
      }
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
    assertWubi(sessionA, learned86: false, learned98: false)
    learnWubi(sessionA, schema: "wubi86_jidian")
    XCTAssertTrue(sessionA.process(keycode: UInt32(XK_n), modifiers: 0))

    let packageB = try makePackage(version: 2)
    let faulting = try OwlRustResourceStore(configuration: environment.configuration,
      engine: .owlRustNativeInputV1, faults: .fail(at: .beforeActiveRename))
    do {
      _ = try await faulting.install(OwlRustResourceDirectorySource(root: packageB))
      XCTFail("interrupted activation must fail")
    } catch let error as OwlRustResourceError {
      XCTAssertEqual(error, .faultInjected(.beforeActiveRename))
    }
    XCTAssertEqual(try environment.activeGeneration()?.contentID, installedA.state.current.generationId)
    let recovered = try await store.recover(inputKind: .pinyinWubi)
    XCTAssertEqual(recovered.current.generationId, installedA.state.current.generationId)
    let installedB = try await store.install(OwlRustResourceDirectorySource(root: packageB))
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
    sessionA.clearComposition()
    sessionA.setOption(.emojiSuggestion, true)
    typeText("pingguo", into: sessionA)
    XCTAssertTrue(sessionA.peekCandidates(from: 0, count: 100).contains { $0.text == "🍎" || $0.text == "🍏" })
    XCTAssertFalse(sessionA.peekCandidates(from: 0, count: 100).contains { $0.text == "🦉🦉" })
    sessionA.clearComposition()
    assertWubi(sessionA, learned86: true, learned98: false)
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
    assertWubi(sessionB, learned86: true, learned98: false)
    learnWubi(sessionB, schema: "wubi98")
    assertWubi(sessionB, learned86: true, learned98: true)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: dictionaries.appendingPathComponent(
        "\(installedB.state.current.generationId)/.ready"
      ).path
    ))
    sessionB.setOption(.emojiSuggestion, true)
    typeText("pingguo", into: sessionB)
    XCTAssertTrue(sessionB.peekCandidates(from: 0, count: 100).contains { $0.text == "🦉🦉" })
    XCTAssertFalse(sessionB.peekCandidates(from: 0, count: 100).contains { $0.text == "🍎" || $0.text == "🍏" })
    sessionB.clearComposition()
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

    // A complete marker cannot hide a missing/corrupt sidecar. Fresh sessions
    // recover the last verified combination and replay the same learning journal.
    let activeResources = try XCTUnwrap(environment.activeGeneration()).resourcesURL
    let sidecar = activeResources.appendingPathComponent("msime-others.db")
    let originalSidecar = try Data(contentsOf: sidecar)
    for missing in [true, false] {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: activeResources.path)
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path)
      if missing { try FileManager.default.removeItem(at: sidecar) }
      else { try Data("corrupt auxiliary resource".utf8).write(to: sidecar) }
      XCTAssertEqual(try environment.activeGeneration()?.contentID, installedA.state.current.generationId)
      let recoveredSession = engineB.createSession()
      recoveredSession.setOption(.emojiSuggestion, true)
      typeText("pingguo", into: recoveredSession)
      XCTAssertTrue(recoveredSession.peekCandidates(from: 0, count: 100).contains { $0.text == "🍎" || $0.text == "🍏" })
      XCTAssertFalse(recoveredSession.peekCandidates(from: 0, count: 100).contains { $0.text == "🦉🦉" })
      recoveredSession.clearComposition()
      typeText("nigu", into: recoveredSession)
      XCTAssertEqual(recoveredSession.composition()?.candidates.first?.text, learned)
      recoveredSession.clearComposition()
      assertWubi(recoveredSession, learned86: true, learned98: true)
      recoveredSession.destroy()
      try originalSidecar.write(to: sidecar)
      try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: sidecar.path)
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: activeResources.path)
    }

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
    sessionAReopened.clearComposition()
    sessionAReopened.setOption(.emojiSuggestion, true)
    typeText("pingguo", into: sessionAReopened)
    XCTAssertTrue(sessionAReopened.peekCandidates(from: 0, count: 100).contains { $0.text == "🍎" || $0.text == "🍏" })
    XCTAssertFalse(sessionAReopened.peekCandidates(from: 0, count: 100).contains { $0.text == "🦉🦉" })
    sessionAReopened.clearComposition()
    assertWubi(sessionAReopened, learned86: true, learned98: true)
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

    // The pinned host consumes paging while composition is active even when
    // already at a boundary; passing it through would scroll the host document.
    XCTAssertTrue(session.process(keycode: UInt32(XK_Page_Up), modifiers: 0))
    XCTAssertEqual(session.composition()?.pageNo, 0)
    XCTAssertEqual(session.composition()?.candidates.map(\.text), page0.candidates.map(\.text))

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
    while session.composition()?.isLastPage == false {
      XCTAssertTrue(session.changePage(up: false))
    }
    let lastPage = try XCTUnwrap(session.composition())
    XCTAssertTrue(session.process(keycode: UInt32(XK_Page_Down), modifiers: 0))
    XCTAssertEqual(session.composition()?.pageNo, lastPage.pageNo)
    XCTAssertEqual(session.composition()?.candidates.map(\.text), lastPage.candidates.map(\.text))
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "shi")
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

  func testCapsLockUsesClassifiedPreFlipLockStateAndCommitsInFlightComposition() throws {
    let engine = try makeSharedSupportSeedEngine()
    let originalShiftSwitch = OwlKeyboardPreferences.shiftSwitchCJK
    let originalGoodOldCapsLock = OwlKeyboardPreferences.goodOldCapsLock
    defer {
      OwlKeyboardPreferences.shiftSwitchCJK = originalShiftSwitch
      OwlKeyboardPreferences.goodOldCapsLock = originalGoodOldCapsLock
    }

    OwlKeyboardPreferences.shiftSwitchCJK = true
    let transition = try classifiedCapsLockTransition(physicalLockBefore: false)
    XCTAssertEqual(transition.modifiers & kLockMask.rawValue, 0,
                   "Caps Lock must reach the session with the pre-flip lock state")

    for (goodOldCapsLock, expectedHandled) in [(false, true), (true, false)] {
      OwlKeyboardPreferences.goodOldCapsLock = goodOldCapsLock
      let session = engine.createSession()
      defer { session.destroy() }
      typeText("ni", into: session)

      XCTAssertEqual(
        session.process(keycode: transition.keycode, modifiers: transition.modifiers),
        expectedHandled
      )
      XCTAssertTrue(session.option(.asciiMode))
      XCTAssertEqual(session.takeCommit(), "ni")
    }
  }

  func testGoodOldCapsLockFalseAlignsModeToEachPhysicalDirection() throws {
    let engine = try makeSharedSupportSeedEngine()
    let originalShiftSwitch = OwlKeyboardPreferences.shiftSwitchCJK
    let originalGoodOldCapsLock = OwlKeyboardPreferences.goodOldCapsLock
    defer {
      OwlKeyboardPreferences.shiftSwitchCJK = originalShiftSwitch
      OwlKeyboardPreferences.goodOldCapsLock = originalGoodOldCapsLock
    }
    OwlKeyboardPreferences.shiftSwitchCJK = true
    OwlKeyboardPreferences.goodOldCapsLock = false

    for (physicalLockBefore, initialASCII, expectedASCII) in [
      (false, false, true),
      (true, true, false)
    ] {
      let session = engine.createSession()
      defer { session.destroy() }
      session.setOption(.asciiMode, initialASCII)
      let transition = try classifiedCapsLockTransition(physicalLockBefore: physicalLockBefore)

      XCTAssertEqual(
        (transition.modifiers & kLockMask.rawValue) != 0,
        physicalLockBefore
      )
      XCTAssertTrue(session.process(keycode: transition.keycode, modifiers: transition.modifiers))
      XCTAssertEqual(session.option(.asciiMode), expectedASCII)
    }
  }

  func testGoodOldCapsLockTrueAlignsAndKeepsASCIISetByOtherInput() throws {
    let engine = try makeSharedSupportSeedEngine()
    let originalShiftSwitch = OwlKeyboardPreferences.shiftSwitchCJK
    let originalGoodOldCapsLock = OwlKeyboardPreferences.goodOldCapsLock
    defer {
      OwlKeyboardPreferences.shiftSwitchCJK = originalShiftSwitch
      OwlKeyboardPreferences.goodOldCapsLock = originalGoodOldCapsLock
    }
    OwlKeyboardPreferences.shiftSwitchCJK = true
    OwlKeyboardPreferences.goodOldCapsLock = true

    let aligned = engine.createSession()
    defer { aligned.destroy() }
    let turnOn = try classifiedCapsLockTransition(physicalLockBefore: false)
    let turnOff = try classifiedCapsLockTransition(physicalLockBefore: true)
    XCTAssertFalse(aligned.process(keycode: turnOn.keycode, modifiers: turnOn.modifiers))
    XCTAssertTrue(aligned.option(.asciiMode))
    XCTAssertFalse(aligned.process(keycode: turnOff.keycode, modifiers: turnOff.modifiers))
    XCTAssertFalse(aligned.option(.asciiMode))

    let switchedByOtherInput = engine.createSession()
    defer { switchedByOtherInput.destroy() }
    switchedByOtherInput.setOption(.asciiMode, true)
    XCTAssertFalse(
      switchedByOtherInput.process(keycode: turnOn.keycode, modifiers: turnOn.modifiers),
      "The first Caps Lock press must not blindly reverse ASCII entered by Shift/defaults"
    )
    XCTAssertTrue(switchedByOtherInput.option(.asciiMode))
  }

  func testCapsLockedLettersFollowGoodOldCapsLockForHostAndIME() throws {
    let engine = try makeSharedSupportSeedEngine()
    let originalShiftSwitch = OwlKeyboardPreferences.shiftSwitchCJK
    let originalGoodOldCapsLock = OwlKeyboardPreferences.goodOldCapsLock
    defer {
      OwlKeyboardPreferences.shiftSwitchCJK = originalShiftSwitch
      OwlKeyboardPreferences.goodOldCapsLock = originalGoodOldCapsLock
    }
    OwlKeyboardPreferences.shiftSwitchCJK = true
    let event = OwlKeyEvent(
      type: .keyDown,
      keyCode: 0,
      characters: "A",
      charactersIgnoringModifiers: "a",
      modifierFlags: [.capsLock],
      lastModifiers: [.capsLock]
    )
    guard case let .keyDown(keycode, modifiers) = OwlUserActionClassifier.classify(event) else {
      return XCTFail("Expected classified Caps Locked A keyDown")
    }
    XCTAssertEqual(keycode, "A".unicodeScalars.first!.value)
    XCTAssertEqual(modifiers & kLockMask.rawValue, kLockMask.rawValue)

    OwlKeyboardPreferences.goodOldCapsLock = false
    let imeSession = engine.createSession()
    defer { imeSession.destroy() }
    imeSession.setOption(.asciiMode, false)
    XCTAssertTrue(imeSession.process(keycode: keycode, modifiers: modifiers))
    XCTAssertEqual(imeSession.takeCommit(), "a")

    OwlKeyboardPreferences.goodOldCapsLock = true
    let hostSession = engine.createSession()
    defer { hostSession.destroy() }
    hostSession.setOption(.asciiMode, false)
    XCTAssertFalse(hostSession.process(keycode: keycode, modifiers: modifiers))
    XCTAssertNil(hostSession.takeCommit())
  }

  func testCapsLockDoesNotOverrideShiftSwitchWhenMasterPreferenceIsOff() throws {
    let engine = try makeSharedSupportSeedEngine()
    let originalShiftSwitch = OwlKeyboardPreferences.shiftSwitchCJK
    defer { OwlKeyboardPreferences.shiftSwitchCJK = originalShiftSwitch }
    OwlKeyboardPreferences.shiftSwitchCJK = false

    let session = engine.createSession()
    defer { session.destroy() }
    typeText("ni", into: session)
    let transition = try classifiedCapsLockTransition(physicalLockBefore: false)

    XCTAssertFalse(session.process(keycode: transition.keycode, modifiers: transition.modifiers))
    XCTAssertFalse(session.option(.asciiMode))
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "ni")
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

  func testUnicodeModeRoutesDigitsHexAndKeypadBeforeCandidateSelection() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    XCTAssertTrue(session.process(keycode: asciiKeycode("U"), modifiers: kShiftMask.rawValue))
    XCTAssertEqual(session.input(), "U")
    XCTAssertTrue(session.process(keycode: asciiKeycode("+"), modifiers: kShiftMask.rawValue))
    XCTAssertTrue(session.process(keycode: asciiKeycode("4"), modifiers: 0))
    XCTAssertTrue(session.process(keycode: asciiKeycode("E"), modifiers: kShiftMask.rawValue))
    XCTAssertTrue(session.process(keycode: asciiKeycode("2"), modifiers: 0))
    XCTAssertTrue(session.process(keycode: asciiKeycode("D"), modifiers: kShiftMask.rawValue))
    XCTAssertEqual(session.input(), "U+4E2D")
    let plusHex = try XCTUnwrap(session.composition())
    let middleIndex = try XCTUnwrap(plusHex.candidates.firstIndex { $0.text == "中" })
    XCTAssertTrue(session.selectCandidate(middleIndex))
    XCTAssertEqual(session.takeCommit(), "中")

    XCTAssertTrue(session.process(keycode: asciiKeycode("U"), modifiers: kShiftMask.rawValue))
    for keycode in [UInt32(XK_KP_0), UInt32(XK_KP_0), UInt32(XK_KP_4), UInt32(XK_KP_1)] {
      XCTAssertTrue(session.process(keycode: keycode, modifiers: 0))
    }
    XCTAssertEqual(session.input(), "U0041")
    let keypadHex = try XCTUnwrap(session.composition())
    let aIndex = try XCTUnwrap(keypadHex.candidates.firstIndex { $0.text == "A" })
    XCTAssertTrue(session.selectCandidate(aIndex))
    XCTAssertEqual(session.takeCommit(), "A")
  }

  func testTraditionalUnicodeModePreservesNullScalar() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    session.setOption(.traditionalization, true)
    XCTAssertTrue(session.process(keycode: asciiKeycode("U"), modifiers: kShiftMask.rawValue))
    typeText("0000", into: session)
    let composition = try XCTUnwrap(session.composition())
    XCTAssertEqual(composition.candidates.first?.text, "\0")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "\0")
  }

  func testKaomojiModeReadsPinnedLicensedCatalogAndCommitsVisibleRow() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    XCTAssertTrue(session.process(keycode: asciiKeycode("M"), modifiers: kShiftMask.rawValue))
    typeText("kiss", into: session)
    let composition = try XCTUnwrap(session.composition())
    // First matching row in the hash-pinned upstream kaomoji table (sort_order 0).
    XCTAssertEqual(composition.candidates.first?.text, "!(*￣(￣　*)")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "!(*￣(￣　*)")
    XCTAssertTrue(session.process(keycode: asciiKeycode("S"), modifiers: kShiftMask.rawValue))
    typeText("sum", into: session)
    XCTAssertEqual(session.composition()?.candidates.first?.text, "∑")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "∑")
  }

  func testShiftTForwardingKeepsDigitSelectionForVisibleCandidate() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    XCTAssertTrue(session.process(keycode: asciiKeycode("T"), modifiers: kShiftMask.rawValue))
    typeText("rq", into: session)
    let composition = try XCTUnwrap(session.composition())
    XCTAssertEqual(composition.preedit, "Trq")
    let visibleFirst = try XCTUnwrap(composition.candidates.first)

    XCTAssertTrue(session.process(keycode: UInt32(XK_1), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), visibleFirst.text)
  }

  func testShiftVUsesUpstreamDisabledExpressionDefault() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    XCTAssertTrue(session.process(keycode: asciiKeycode("V"), modifiers: kShiftMask.rawValue))
    XCTAssertEqual(session.input(), "V")
    // Keep the native default: these keys may use ordinary selection/punctuation routes,
    // but must not activate expression spelling and offer the calculated result.
    _ = session.process(keycode: UInt32(XK_KP_1), modifiers: 0)
    _ = session.process(keycode: asciiKeycode("+"), modifiers: kShiftMask.rawValue)
    _ = session.process(keycode: UInt32(XK_KP_2), modifiers: 0)
    XCTAssertNotEqual(session.composition()?.preedit, "V1+2")
    XCTAssertFalse(session.composition()?.candidates.contains { $0.text == "3" } == true)
    _ = session.takeCommit()
    session.clearComposition()
    typeText("ni", into: session)
    XCTAssertFalse(try XCTUnwrap(session.composition()).candidates.isEmpty)
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

  // Literal oracle: pinned upstream client-base/chinese_conversion.rs s2t fixtures.
  // ICU Hans-Hant emits 裡面; OpenCC standard emits 裏面.
  func testPhraseAwareTraditionalOutputKeepsSelectionIdentity() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    typeText("limian", into: session)
    let simplified = try XCTUnwrap(session.composition())
    let index = try XCTUnwrap(simplified.candidates.firstIndex { $0.text == "里面" })
    let generation = session.generation
    session.setOption(.traditionalization, true)
    let traditional = try XCTUnwrap(session.composition())
    XCTAssertEqual(traditional.candidates[index].text, "裏面")
    XCTAssertEqual(session.peekCandidates(from: index, count: 1).first?.text, "裏面")
    XCTAssertEqual(session.generation, generation)
    let token = OwlCandidateToken(sessionID: session.sessionID, generation: generation,
                                  candidateID: index, isAbsolute: false)
    XCTAssertTrue(session.selectCandidate(token))
    XCTAssertEqual(session.takeCommit(), "裏面")
    session.setOption(.traditionalization, false)
    typeText("limian", into: session)
    XCTAssertTrue(session.selectCandidate(index))
    XCTAssertEqual(session.takeCommit(), "里面")
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

  func testTraditionalPinUsesCertifiedSourceBeforeHostConversion() throws {
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }

    session.setOption(.traditionalization, true)
    session.setOption(.simplification, false)
    typeText("shi", into: session)
    let initial = try XCTUnwrap(session.composition())
    let initialIndex = try XCTUnwrap(initial.candidates.firstIndex { $0.text == "時" })
    XCTAssertGreaterThan(initialIndex, 0)

    let packed = "shi\t1\t時"
    let sources = OwlPinnedWords.traditionalSources(engineValue: packed)
    XCTAssertEqual(sources, [
      OwlTraditionalPinSource(code: "shi", text: "時", source: "时")
    ])
    session.setProperty(name: OwlPinnedWords.property, value: packed)
    session.clearComposition()
    typeText("shi", into: session)

    let pinned = try XCTUnwrap(session.composition())
    XCTAssertEqual(pinned.candidates.first?.text, "時")
    XCTAssertEqual(pinned.candidates.first?.comment, "置顶")
  }

  func testTraditionalPinSourcesRejectLossyFoundationRoundTrips() {
    let packed = "fa\t1\t髮\nfa\t1\t發\ntoufa\t1\t頭髮\nshi\t1\t時"
    XCTAssertEqual(
      OwlPinnedWords.traditionalSources(engineValue: packed).map(\.text),
      ["發", "頭髮", "時"]
    )
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

  func testWubi98ProfileSwitchUsesOfficialTableAndHints() throws {
    let defaults = OwlDefaults.standard
    let keys = ["OwlKeyboardWubiScheme", "OwlKeyboardInputMethod", "OwlKeyboardWubiCodeHint"]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
      }
    }
    defaults.set(true, forKey: keys[2])
    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    let session = engine.createSession()
    defer { session.destroy() }
    typeText("go", into: session)
    XCTAssertEqual(session.composition()?.candidates.first?.text, "来")
    XCTAssertEqual(session.composition()?.candidates.first?.comment, "goi")
    session.clearComposition()
    XCTAssertTrue(session.selectSchema("wubi98"))
    typeText("gu", into: session)
    XCTAssertEqual(session.composition()?.candidates.first?.text, "来")
    XCTAssertEqual(session.composition()?.candidates.first?.comment, "gusi")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "来")
    typeText("sbbv", into: session)
    XCTAssertEqual(session.takeCommit(), "极限")
    session.clearComposition()
    XCTAssertTrue(session.selectSchema("wubi98_pinyin"))
    typeText("zhongguo", into: session)
    XCTAssertTrue(try XCTUnwrap(session.composition()).candidates.contains { $0.text == "中国" })
    session.clearComposition()
    XCTAssertTrue(session.selectSchema("wubi98_trad"))
    typeText("gu", into: session)
    XCTAssertEqual(session.composition()?.candidates.first?.text, "來")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "來")
    XCTAssertTrue(session.selectSchema("wubi98_trad_pinyin"))
    typeText("zhongguo", into: session)
    XCTAssertTrue(try XCTUnwrap(session.composition()).candidates.contains { $0.text == "中國" })
    session.clearComposition()
    XCTAssertTrue(session.selectSchema("wubi86_jidian"))
    typeText("go", into: session)
    XCTAssertEqual(session.composition()?.candidates.first?.text, "来")
    XCTAssertEqual(session.composition()?.candidates.first?.comment, "goi")
    session.clearComposition()
    typeText("sebv", into: session)
    XCTAssertEqual(session.takeCommit(), "极限")
    let choice = try XCTUnwrap(OwlWubiScheme(rawValue: "jidian98"))
    let state = OwlSettingsState()
    state.keyboardInputMethod = .wubi
    OwlKeyboardPreferences.inputMethod = .wubi
    OwlSettingsActions.selectWubiScheme(choice, state: state) { schema in
      XCTAssertTrue(session.selectSchema(schema))
    }
    XCTAssertEqual(state.keyboardWubiScheme, choice)
    XCTAssertEqual(OwlKeyboardPreferences.preferredSchemaID, "wubi98")
    XCTAssertEqual(choice.schemaId, "wubi98")
    XCTAssertEqual(OwlWubiScheme(rawValue: "pinyinMix")?.schemaId, "wubi86_jidian_pinyin")
    XCTAssertTrue(engine.selectSchema(choice.schemaId))
    let restored = engine.createSession()
    defer { restored.destroy() }
    typeText("gu", into: restored)
    XCTAssertEqual(restored.composition()?.candidates.first?.text, "来")
    XCTAssertEqual(restored.composition()?.candidates.first?.comment, "gusi")
  }

  func testWubiNativeCodeHintsWildcardAndLookupUseCurrentSettings() throws {
    let defaults = OwlDefaults.standard
    let keys = ["OwlKeyboardWubiCodeHint", "OwlKeyboardWubiZWildcard", "OwlKeyboardWubiZReverseLookup"]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
      }
    }
    keys.forEach { defaults.removeObject(forKey: $0) }
    XCTAssertTrue(OwlKeyboardPreferences.wubiCodeHint, "Pinned native Wubi code hints default on")
    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
    defer { session.destroy() }
    defaults.set(true, forKey: keys[0])
    typeText("i", into: session)
    let initial = try XCTUnwrap(session.composition())
    let zibo = try XCTUnwrap(initial.candidates.firstIndex { $0.text == "淄博" })
    // Literal native oracle: code=ivfg, typed=i => suffix vfg. Short-code 不 falls back to gii.
    XCTAssertEqual(initial.candidates[zibo].comment, "vfg")
    XCTAssertEqual(initial.candidates.first?.comment, "gii")
    let peek = session.peekCandidates(from: zibo, count: 1)
    XCTAssertEqual(peek.first?.text, "淄博")
    XCTAssertEqual(peek.first?.comment, "vfg")
    defaults.set(false, forKey: keys[0])
    session.clearComposition()
    typeText("i", into: session)
    XCTAssertEqual(session.composition()?.candidates[zibo].comment, "ivfg")
    XCTAssertTrue(session.selectCandidate(zibo))
    XCTAssertEqual(session.takeCommit(), "淄博")

    // Hint-off native rendering retains the reverse-lookup annotation.
    typeText("znihao", into: session)
    let lookup = try XCTUnwrap(session.composition())
    let hello = try XCTUnwrap(lookup.candidates.firstIndex { $0.text == "你好" })
    XCTAssertEqual(lookup.candidates[hello].comment, "wqvb")
    session.clearComposition()
    defaults.set(true, forKey: keys[1])
    typeText("iz", into: session)
    XCTAssertEqual(session.input(), "iz")
    XCTAssertFalse(try XCTUnwrap(session.composition()).candidates.isEmpty)
    session.clearComposition()
    typeText("z", into: session)
    XCTAssertEqual(session.input(), "z")
    XCTAssertFalse(try XCTUnwrap(session.composition()).candidates.isEmpty,
                   "Leading z is wildcard, not a bare Pinyin lookup prefix")
    session.clearComposition()
    defaults.set(false, forKey: keys[1])
    defaults.set(false, forKey: keys[2])
    XCTAssertTrue(session.selectSchema("wubi86_jidian_pinyin"))
    typeText("zhongguo", into: session)
    XCTAssertTrue(try XCTUnwrap(session.composition()).candidates.contains { $0.text == "中国" },
                  "Mixed input uses z as a spelling letter even when temporary lookup is disabled")
  }

  func testWubiLearningDefaultsToNativeAndPreservesExplicitOptOut() throws {
    let defaults = OwlDefaults.standard
    let key = "OwlKeyboardWubiUserDictLearning"
    let saved = defaults.object(forKey: key)
    defer {
      if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    for learning in [true, false] {
      if learning { defaults.removeObject(forKey: key) } else { defaults.set(false, forKey: key) }
      let engine = try makeSharedSupportSeedEngine()
      XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
      var session = engine.createSession()
      typeText("gggg", into: session)
      XCTAssertEqual(Array(try XCTUnwrap(session.composition()).candidates.prefix(2).map(\.text)), ["王", "五一"])
      XCTAssertTrue(session.selectCandidate(1))
      XCTAssertEqual(session.takeCommit(), "五一")
      session.destroy()
      XCTAssertTrue(engine.finalize())
      session = engine.createSession()
      typeText("gggg", into: session)
      // Independently pinned Host API: a single selection promotes 五一 only with learning on.
      XCTAssertEqual(session.composition()?.candidates.first?.text, learning ? "五一" : "王")
      session.destroy()
      XCTAssertTrue(engine.finalize())
      XCTAssertEqual(OwlKeyboardPreferences.wubiUserDictLearning, learning)
    }
  }

  func testWubiCommitPreferencesApplyToCurrentSession() throws {
    let defaults = OwlDefaults.standard
    let keys = ["OwlKeyboardWubiAutoCommitUnique", "OwlKeyboardWubiFifthCodeTopCommit"]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
      }
    }
    keys.forEach { defaults.removeObject(forKey: $0) }
    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    let session = engine.createSession()
    defer { session.destroy() }

    // The fixed official table has one exact sebv row: 极限. The upstream default commits it.
    typeText("sebv", into: session)
    XCTAssertEqual(session.takeCommit(), "极限")
    typeText("seb", into: session)
    defaults.set(false, forKey: keys[0])
    typeText("v", into: session)
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "sebv", "A changed setting must affect the next key without clearing composition")
    XCTAssertEqual(session.composition()?.candidates.first?.text, "极限")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "极限")
    defaults.set(true, forKey: keys[0])
    typeText("sebv", into: session)
    XCTAssertEqual(session.takeCommit(), "极限")

    XCTAssertTrue(session.selectSchema("wubi86_jidian_pinyin"))
    typeText("gggg", into: session)
    XCTAssertNil(session.takeCommit())
    defaults.set(false, forKey: keys[1])
    // Real pinned Host API refuses this invalid Pinyin continuation instead of topping 王.
    XCTAssertFalse(session.process(keycode: asciiKeycode("x"), modifiers: 0))
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "gggg")
    session.clearComposition()
    defaults.set(true, forKey: keys[1])
    typeText("gggg", into: session)
    let mixedFirst = try XCTUnwrap(session.composition()?.candidates.first?.text)
    typeText("x", into: session)
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "x")
    XCTAssertEqual(session.composition()?.preedit, mixedFirst + "x")
    session.clearComposition()

    // Upstream still tops in pure Wubi: the fifth letter cannot fit the four-code buffer.
    defaults.set(false, forKey: keys[1])
    XCTAssertTrue(session.selectSchema("wubi86_jidian"))
    typeText("gggg", into: session)
    let pureFirst = try XCTUnwrap(session.composition()?.candidates.first?.text)
    typeText("x", into: session)
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "x")
    XCTAssertEqual(session.composition()?.preedit, pureFirst + "x")
    session.clearComposition()
    typeText("aaab", into: session)
    XCTAssertFalse(session.process(keycode: asciiKeycode("x"), modifiers: 0))
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "aaab")
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

  func testMixedWubiExactPinyinCodeRowsAndSelectionIdentity() throws {
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

    // Paging keeps the upstream code rows and selection commits the
    // candidate visible on the page that the user actually navigated to.
    typeText("shi", into: session)
    let candidates = visibleAndPeekedCandidates(in: session)
    XCTAssertGreaterThan(candidates.count, (session.composition()?.pageSize ?? 9))
    // The official Wubi table keeps different code rows with the same text.
    // Native MSIME displays both 椒 rows; removing one changes later visible selection.
    XCTAssertEqual(Array(candidates.prefix(2).map(\.text)), ["椒", "椒"])
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

    // An ambiguous four-code stays open. Native phrase_preedit holds its first
    // candidate before the next code; it is not committed to the client yet.
    typeText("aaaa", into: session)
    XCTAssertNil(session.takeCommit())
    let ambiguous = try XCTUnwrap(session.composition())
    XCTAssertGreaterThan(ambiguous.candidates.count, 1)
    let firstAmbiguous = try XCTUnwrap(ambiguous.candidates.first?.text)
    typeText("x", into: session)
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.input(), "x")
    XCTAssertEqual(session.composition()?.preedit, firstAmbiguous + "x")
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
    XCTAssertEqual(session.composition()?.candidates.first?.comment, "aaaa",
                   "Native hint-off rendering retains the engine full-code annotation")
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
    let previousPageSize = OwlKeyboardPreferences.pageSize
    OwlKeyboardPreferences.pageSize = 6
    defer { OwlKeyboardPreferences.pageSize = previousPageSize }
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

    // The unmodified pinned host's exact order for zongguo without fuzzy rules,
    // then with its z-zh rule. The existing Swift switch maps to that same mask.
    typeText("zongguo", into: session)
    XCTAssertEqual(session.composition()?.candidates.map(\.text),
                   ["总国", "纵谷哦", "纵谷噢", "纵谷喔", "纵谷嚄", "宗谷哦"])
    session.clearComposition()
    OwlFuzzyPreferences.zhz = true
    XCTAssertTrue(engine.selectSchema("rime_ice"))
    let fuzzySession = engine.createSession()
    defer { fuzzySession.destroy() }
    typeText("zongguo", into: fuzzySession)
    XCTAssertEqual(fuzzySession.input(), "zongguo")
    XCTAssertEqual(fuzzySession.composition()?.candidates.map(\.text),
                   ["中国", "种过", "种果", "中过", "中果", "总国"])
  }

  // Exact first-page rows observed from the unmodified macOS 0.55.0 host API,
  // empty learning state and its default six-row page. #280 replaces #259's
  // former Chinese-only protection with the upstream mixed-input order.
  func testPinnedUpstreamMixedEnglishAndEmojiOrder() throws {
    let previousPageSize = OwlKeyboardPreferences.pageSize
    OwlKeyboardPreferences.pageSize = 6
    defer { OwlKeyboardPreferences.pageSize = previousPageSize }
    let engine = try makeSharedSupportSeedEngine()
    let session = engine.createSession()
    defer { session.destroy() }
    for (input, expected) in [
      ("xi", ["洗", "xi", "西", "喜", "系", "息"]),
      ("chan", ["产", "chan", "颤", "缠", "禅", "蝉"]),
      ("nihao", ["你好", "👋", "尼好", "你好吗", "你好啊", "拟好"])
    ] {
      typeText(input, into: session)
      XCTAssertEqual(session.composition()?.candidates.map(\.text), expected, input)
      session.clearComposition()
    }
  }

  func testMixedChineseEnglishRankingCompletionPagingPinBackspaceAndLatency() throws {
    let engine = try makeSharedSupportSeedEngine()
    XCTAssertTrue(engine.selectSchema("rime_ice"))
    let session = engine.createSession()
    defer { session.destroy() }

    // Exact English words and desktop prefixes of at least five letters are selectable
    // through the bounded candidate list. The display spelling of GitHub is preserved.
    for input in ["hello", "dir", "github"] {
      typeText(input, into: session)
      let candidates = visibleAndPeekedCandidates(in: session)
      let expected = input == "github" ? "GitHub" : input
      XCTAssertTrue(candidates.contains(where: { $0.text == expected }))
      session.clearComposition()
    }
    for (prefix, expected) in [("githu", "GitHub")] {
      typeText(prefix, into: session)
      let candidates = visibleAndPeekedCandidates(in: session)
      XCTAssertTrue(candidates.contains(where: { $0.text == expected }))
      session.clearComposition()
    }

    // Short exact English remains valid, but shorter-than-five prefixes do not
    // request English completions in the pinned desktop host.
    for (prefix, excluded) in [("hel", "hello"), ("gith", "GitHub")] {
      typeText(prefix, into: session)
      XCTAssertFalse(visibleAndPeekedCandidates(in: session).contains { $0.text == excluded })
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

    // Pinned 0.55.0: neighbor, transposition and missing-letter correction; the
    // extra-letter spelling nihaao is also legal pinyin and retains its literal top row.
    for (typo, expected) in [("nihso", "你好"), ("niaho", "你好"), ("zhngguo", "中国"), ("nihaao", "你哈傲")] {
      for scalar in typo.unicodeScalars {
        XCTAssertTrue(session.process(keycode: scalar.value, modifiers: 0))
      }
      let comp = try XCTUnwrap(session.composition())
      let all = comp.candidates + session.peekCandidates(from: comp.pageSize, count: 15)
      XCTAssertTrue(all.contains(where: { $0.text == expected }), "Expected \(expected) for typo \(typo)")
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

    // Pinned full resources replace the former Owl-only mixed lexicon. Keep the
    // actual upstream top row rather than requiring words absent from its table.
    for (input, expected) in [("xguang", "星光"), ("txu", "特许")] {
      typeText(input, into: session)
      XCTAssertEqual(session.composition()?.candidates.first?.text, expected)
      session.clearComposition()
    }
    typeText("upan", into: session)
    XCTAssertEqual(session.composition()?.candidates.count, 0)
  }

  func testOwlEnhancementsRequireExplicitKWithoutChangingOrdinaryCandidates() throws {
    let userDir = try makeHostPhraseUserDirectory()
    let baselineDir = try makeHostPhraseUserDirectory()
    var entry = OwlTemplateEntry(title: "增强测试", body: "模板正文")
    entry.trigger = "ni"
    entry.invocationMode = .candidate
    try OwlTemplateStore.save(.init(entries: [entry]), writer: OwlConfigWriter(rimeDir: userDir))
    let engine = try makeHostPhraseEngine(userDataURL: userDir)
    let baselineEngine = try makeHostPhraseEngine(userDataURL: baselineDir)
    let session = engine.createSession()
    let baseline = baselineEngine.createSession()
    defer { session.destroy(); baseline.destroy() }
    typeText("ni", into: session)
    typeText("ni", into: baseline)
    XCTAssertEqual(visibleAndPeekedCandidates(in: session).map(\.text),
                   visibleAndPeekedCandidates(in: baseline).map(\.text))
    let visible = try XCTUnwrap(session.composition()?.candidates.first?.text)
    XCTAssertTrue(session.process(keycode: UInt32(XK_space), modifiers: 0))
    XCTAssertEqual(session.takeCommit(), visible)
    XCTAssertNil(session.takeCommit())
    let templateText = OwlTemplateStore.candidateText(entry)
    XCTAssertTrue(session.process(keycode: asciiKeycode("K"), modifiers: kShiftMask.rawValue))
    typeText("n", into: session)
    XCTAssertFalse(visibleAndPeekedCandidates(in: session).contains { $0.text == templateText })
    XCTAssertTrue(session.process(keycode: UInt32(XK_space), modifiers: 0))
    XCTAssertNotEqual(session.takeCommit(), templateText)
    session.clearComposition()
    XCTAssertTrue(session.process(keycode: asciiKeycode("K"), modifiers: kShiftMask.rawValue))
    typeText("ni", into: session)
    let candidates = visibleAndPeekedCandidates(in: session)
    let index = try XCTUnwrap(candidates.firstIndex { $0.text == templateText })
    XCTAssertTrue(session.selectCandidate(OwlCandidateToken(sessionID: session.sessionID,
      generation: session.generation, candidateID: index, isAbsolute: true)))
    XCTAssertEqual(session.takeCommit(), templateText)
    XCTAssertEqual(session.lastCommittedInput(), "Kni")
    XCTAssertEqual(OwlTemplateStore.resolveCandidate(code: session.lastCommittedInput(), text: templateText,
      loadLibrary: { try OwlTemplateStore.load(rimeDir: userDir) })?.id, entry.id)
    XCTAssertNil(session.takeCommit())
    XCTAssertTrue(session.process(keycode: asciiKeycode("K"), modifiers: kShiftMask.rawValue))
    typeText("ni", into: session)
    XCTAssertTrue(session.process(keycode: UInt32(XK_Escape), modifiers: 0))
    XCTAssertNil(session.takeCommit())
    typeText("ni", into: session)
    XCTAssertFalse(visibleAndPeekedCandidates(in: session).contains { $0.text == templateText })
  }

  func testLegacyHostPhrasesLoadPromptsQuickSendAndCustomPhrase() throws {
    let userDir = try makeHostPhraseUserDirectory()
    let quickSendContent = "user@example.com\towlmail\t100000\n"
    try writeHostPhrase(
      quickSendContent,
      fileName: OwlQuickSendStore.dictFileName,
      to: userDir
    )
    let promptContent = "📝周报生成\towlreport\t100000\n"
    try writeHostPhrase(
      promptContent,
      fileName: OwlPromptStore.dictFileName,
      to: userDir
    )
    try writeHostPhrase(
      "共享短语\towlcustom\t100000\n",
      fileName: "custom_phrase.txt",
      to: userDir
    )
    XCTAssertEqual(OwlTemplateStore.mode(rimeDir: userDir), .legacy)

    let engine = try makeHostPhraseEngine(userDataURL: userDir)
    let session = engine.createSession()
    defer { session.destroy() }

    // 1. Explicit K invocation exposes the complete host quick phrase.
    for scalar in "Kowlmail".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let yxComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(yxComp.candidates.first?.text, "user@example.com")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "user@example.com")
    XCTAssertEqual(session.lastCommittedInput(), "Kowlmail")

    // 2. Explicit K invocation exposes the prompt candidate.
    for scalar in "Kowlreport".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let zbComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(zbComp.candidates.first?.text, "📝周报生成")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "📝周报生成")
    XCTAssertEqual(session.lastCommittedInput(), "Kowlreport")

    // 3. The shared custom phrase remains available in legacy mode.
    for scalar in "Kowlcustom".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let cstComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(cstComp.candidates.first?.text, "共享短语")
    XCTAssertTrue(session.selectCandidate(0))
    XCTAssertEqual(session.takeCommit(), "共享短语")
    XCTAssertEqual(session.lastCommittedInput(), "Kowlcustom")

    // 4. Replacing a host phrase refreshes the runtime table without duplicating it.
    let updatedQuickPhrase = "updated@example.com\towlmail\t100000\n"
    try writeHostPhrase(
      updatedQuickPhrase,
      fileName: OwlQuickSendStore.dictFileName,
      to: userDir
    )
    XCTAssertTrue(engine.deployConfigFile(OwlQuickSendStore.dictFileName, versionKey: "config_version"))
    for scalar in "Kowlmail".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let updatedComp = try XCTUnwrap(session.composition())
    XCTAssertEqual(
      updatedComp.candidates.filter { $0.text == "updated@example.com" }.count,
      1
    )
    XCTAssertFalse(updatedComp.candidates.contains(where: { $0.text == "user@example.com" }))
    session.clearComposition()

    // Duplicate rows in the packed host table still produce exactly one candidate.
    try writeHostPhrase(
      updatedQuickPhrase + updatedQuickPhrase,
      fileName: OwlQuickSendStore.dictFileName,
      to: userDir
    )
    XCTAssertTrue(engine.deployConfigFile(OwlQuickSendStore.dictFileName, versionKey: "config_version"))
    for scalar in "Kowlmail".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
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
    for scalar in "Kowlmail".unicodeScalars {
      XCTAssertTrue(restarted.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let restartedComp = try XCTUnwrap(restarted.composition())
    XCTAssertEqual(
      restartedComp.candidates.filter { $0.text == "updated@example.com" }.count,
      1
    )
    restarted.clearComposition()

    // 6. Clearing quick-send removes only those rows; prompts and custom phrases remain.
    try writeHostPhrase(
      "",
      fileName: OwlQuickSendStore.dictFileName,
      to: userDir
    )
    XCTAssertTrue(engine.deployConfigFile(OwlQuickSendStore.dictFileName, versionKey: "config_version"))
    for scalar in "Kowlmail".unicodeScalars {
      XCTAssertTrue(restarted.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let yxAfterDelete = try XCTUnwrap(restarted.composition())
    XCTAssertFalse(yxAfterDelete.candidates.contains(where: { $0.text == "user@example.com" }))
    XCTAssertFalse(yxAfterDelete.candidates.contains(where: { $0.text == "updated@example.com" }))
    restarted.clearComposition()

    for scalar in "Kowlreport".unicodeScalars {
      XCTAssertTrue(restarted.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    XCTAssertEqual(try XCTUnwrap(restarted.composition()).candidates.first?.text, "📝周报生成")
    restarted.clearComposition()

    for scalar in "Kowlcustom".unicodeScalars {
      XCTAssertTrue(restarted.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    XCTAssertEqual(try XCTUnwrap(restarted.composition()).candidates.first?.text, "共享短语")
  }

  func testUnifiedHostPhrasesIgnoreLegacyCatalogAndDropDeletedTemplates() throws {
    let userDir = try makeHostPhraseUserDirectory()
    var entry = OwlTemplateEntry(title: "项目记录", body: "整理项目记录")
    entry.trigger = "owlrecord"
    entry.invocationMode = .candidate
    try OwlTemplateStore.save(
      OwlTemplateLibrary(entries: [entry]),
      writer: OwlConfigWriter(rimeDir: userDir)
    )
    XCTAssertEqual(OwlTemplateStore.mode(rimeDir: userDir), .unified)

    // These stale projections must not be merged back after migration to the unified store.
    try writeHostPhrase(
      "📝遗留提示词\towlreport\t100000\n",
      fileName: OwlPromptStore.dictFileName,
      to: userDir
    )
    try writeHostPhrase(
      "legacy@example.com\towlmail\t100000\n",
      fileName: OwlQuickSendStore.dictFileName,
      to: userDir
    )
    try writeHostPhrase(
      "共享短语\towlcustom\t100000\n",
      fileName: "custom_phrase.txt",
      to: userDir
    )

    let engine = try makeHostPhraseEngine(userDataURL: userDir)
    let session = engine.createSession()
    defer { session.destroy() }

    session.setOption(.transcription, true)
    for scalar in "Kowlrecord".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let ftComp = try XCTUnwrap(session.composition())
    let templatePrefix = "\(OwlTemplateStore.candidatePrefix)\(entry.id.uuidString)]"
    XCTAssertTrue(ftComp.candidates.first?.text.hasPrefix(templatePrefix) == true)
    XCTAssertTrue(session.selectCandidate(0))
    let committedTemplate = try XCTUnwrap(session.takeCommit())
    XCTAssertEqual(session.lastCommittedInput(), "Kowlrecord")
    XCTAssertEqual(
      OwlTemplateStore.resolveCandidate(
        code: session.lastCommittedInput(),
        text: committedTemplate,
        loadLibrary: { try OwlTemplateStore.load(rimeDir: userDir) }
      )?.id,
      entry.id
    )
    session.setOption(.transcription, false)

    for (input, staleText) in [("owlreport", "📝遗留提示词"), ("owlmail", "legacy@example.com")] {
      for scalar in ("K" + input).unicodeScalars {
        XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
      }
      let comp = try XCTUnwrap(session.composition())
      XCTAssertFalse(comp.candidates.contains(where: { $0.text == staleText }))
      session.clearComposition()
    }

    for scalar in "Kowlcustom".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    XCTAssertEqual(try XCTUnwrap(session.composition()).candidates.first?.text, "共享短语")
    session.clearComposition()

    // Deleting the committed record refreshes the projection without touching the seed table.
    try OwlTemplateStore.save(
      OwlTemplateLibrary(),
      writer: OwlConfigWriter(rimeDir: userDir)
    )
    XCTAssertTrue(engine.deployConfigFile(OwlTemplateStore.dictFileName, versionKey: "config_version"))
    for scalar in "Kowlrecord".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let deletedComp = try XCTUnwrap(session.composition())
    XCTAssertFalse(
      deletedComp.candidates.contains {
        $0.text.hasPrefix(OwlTemplateStore.candidatePrefix)
      }
    )
    session.clearComposition()

    // This native row is in the pinned full resource set (the old synthetic X光 row is not).
    typeText("yyds", into: session)
    XCTAssertTrue(visibleAndPeekedCandidates(in: session).contains { $0.text == "永远滴神" })
    session.clearComposition()
    XCTAssertTrue(session.process(keycode: asciiKeycode("K"), modifiers: kShiftMask.rawValue))
    typeText("yy", into: session)
    XCTAssertTrue(visibleAndPeekedCandidates(in: session).contains { $0.text == "永远滴神" },
                  "native database K prefix matching survives the Owl enhancement boundary")
  }

  func testHostPhraseModesEmptyAndUnavailableFailClosed() throws {
    let emptyDir = try makeHostPhraseUserDirectory()
    try writeHostPhrase(
      "共享短语\towlcustom\t100000\n",
      fileName: "custom_phrase.txt",
      to: emptyDir
    )
    XCTAssertEqual(OwlTemplateStore.mode(rimeDir: emptyDir), .empty)
    let emptyEngine = try makeHostPhraseEngine(userDataURL: emptyDir)
    let emptySession = emptyEngine.createSession()
    defer { emptySession.destroy() }
    for scalar in "Kowlcustom".unicodeScalars {
      XCTAssertTrue(emptySession.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    XCTAssertEqual(try XCTUnwrap(emptySession.composition()).candidates.first?.text, "共享短语")

    let unavailableDir = try makeHostPhraseUserDirectory()
    try writeHostPhrase(
      "📝旧提示词\towlreport\t100000\n",
      fileName: OwlPromptStore.dictFileName,
      to: unavailableDir
    )
    try writeHostPhrase(
      "old@example.com\towlmail\t100000\n",
      fileName: OwlQuickSendStore.dictFileName,
      to: unavailableDir
    )
    try writeHostPhrase(
      "不可回退短语\towlcustom\t100000\n",
      fileName: "custom_phrase.txt",
      to: unavailableDir
    )
    try writeHostPhrase(
      "{not-json",
      fileName: OwlTemplateStore.stateFileName,
      to: unavailableDir
    )
    guard case .unavailable = OwlTemplateStore.mode(rimeDir: unavailableDir) else {
      return XCTFail("corrupt unified state must block host phrase loading")
    }
    let unavailableEngine = try makeHostPhraseEngine(userDataURL: unavailableDir)
    let unavailableSession = unavailableEngine.createSession()
    defer { unavailableSession.destroy() }
    for (input, staleText) in [
      ("owlreport", "📝旧提示词"),
      ("owlmail", "old@example.com"),
      ("owlcustom", "不可回退短语")
    ] {
      for scalar in ("K" + input).unicodeScalars {
        XCTAssertTrue(unavailableSession.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
      }
      let comp = try XCTUnwrap(unavailableSession.composition())
      XCTAssertFalse(comp.candidates.contains(where: { $0.text == staleText }))
      unavailableSession.clearComposition()
    }
  }

  func testUnifiedHostCandidateDigitAndMouseSelectionStayAligned() throws {
    let userDir = try makeHostPhraseUserDirectory()
    var entry = OwlTemplateEntry(title: "映射测试", body: "模板正文")
    entry.trigger = "owlmapping"
    entry.invocationMode = .candidate
    try OwlTemplateStore.save(
      OwlTemplateLibrary(entries: [entry]),
      writer: OwlConfigWriter(rimeDir: userDir)
    )
    let templateText = OwlTemplateStore.candidateText(entry)
    try writeHostPhrase(
      "自定义映射\towlmapping\t100000\n",
      fileName: "custom_phrase.txt",
      to: userDir
    )

    let engine = try makeHostPhraseEngine(userDataURL: userDir)
    let session = engine.createSession()
    defer { session.destroy() }

    for scalar in "Kowlmapping".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let composition = try XCTUnwrap(session.composition())
    let templateIndex = try XCTUnwrap(composition.candidates.firstIndex { $0.text == templateText })
    XCTAssertTrue(composition.candidates.contains(where: { $0.text == "自定义映射" }))
    XCTAssertGreaterThanOrEqual(composition.candidates.count, 2)
    XCTAssertEqual(Array(composition.labels.prefix(composition.candidates.count)),
                   (1...composition.candidates.count).map(String.init))

    let digitKeycode = UInt32(XK_1) + UInt32(templateIndex)
    XCTAssertTrue(session.process(keycode: digitKeycode, modifiers: 0))
    XCTAssertEqual(session.takeCommit(), templateText)
    XCTAssertEqual(session.lastCommittedInput(), "Kowlmapping")
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(
      OwlTemplateStore.resolveCandidate(
        code: session.lastCommittedInput(),
        text: templateText,
        loadLibrary: { try OwlTemplateStore.load(rimeDir: userDir) }
      )?.id,
      entry.id
    )

    for scalar in "Kowlmapping".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let mouseComposition = try XCTUnwrap(session.composition())
    let mouseIndex = try XCTUnwrap(mouseComposition.candidates.firstIndex { $0.text == templateText })
    let token = OwlCandidateToken(
      sessionID: session.sessionID,
      generation: session.generation,
      candidateID: mouseIndex,
      isAbsolute: false
    )
    XCTAssertTrue(session.selectCandidate(token))
    XCTAssertEqual(session.takeCommit(), templateText)
    XCTAssertEqual(session.lastCommittedInput(), "Kowlmapping")
    XCTAssertNil(session.takeCommit())

    for scalar in "Kowlmapping".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    XCTAssertTrue(session.process(keycode: UInt32(XK_Escape), modifiers: 0))
    XCTAssertNil(session.takeCommit())
    XCTAssertEqual(session.composition()?.preedit, "")
    XCTAssertTrue(session.composition()?.candidates.isEmpty == true)

    XCTAssertTrue(session.selectSchema("wubi86_jidian"))
    for scalar in "Kowlmapping".unicodeScalars {
      XCTAssertTrue(session.process(keycode: scalar.value, modifiers: scalar.value == asciiKeycode("K") ? kShiftMask.rawValue : 0))
    }
    let switched = try XCTUnwrap(session.composition())
    XCTAssertEqual(switched.candidates.filter { $0.text == templateText }.count, 1)
    XCTAssertNil(session.takeCommit())
  }

  func testWubiDoesNotLeakLegacyCustomPhraseOrUsurpFirstSlotForHostPhrases() throws {
    let origCandidateMode = OwlKeyboardPreferences.wubiCandidateMode
    defer { OwlKeyboardPreferences.wubiCandidateMode = origCandidateMode }
    OwlKeyboardPreferences.wubiCandidateMode = .normal

    let engine = try makeSharedSupportSeedEngine()
    for schema in ["wubi86_jidian", "wubi86_jidian_pinyin"] {
      XCTAssertTrue(engine.selectSchema(schema))
      let session = engine.createSession()
      defer { session.destroy() }

      typeText("i", into: session)
      let iComp = try XCTUnwrap(session.composition(), "schema: \(schema)")
      XCTAssertEqual(iComp.candidates.first?.text, "不", "schema: \(schema)")
      for leaked in ["一", "以", "已", "亦"] {
        XCTAssertFalse(
          iComp.candidates.contains(where: { $0.text == leaked }),
          "schema \(schema) leaked \(leaked) into `i`: \(iComp.candidates.map(\.text))"
        )
      }
      session.clearComposition()

      typeText("go", into: session)
      let goComp = try XCTUnwrap(session.composition(), "schema: \(schema)")
      XCTAssertEqual(goComp.candidates.first?.text, "来", "schema: \(schema)")
      XCTAssertFalse(
        goComp.candidates.contains(where: { $0.text == "go" }),
        "schema \(schema) leaked English `go` into `go`: \(goComp.candidates.map(\.text))"
      )
      session.clearComposition()
    }

    // Host phrases remain explicit Owl enhancements: ordinary Wubi keeps the primary row,
    // and K plus the complete trigger can still invoke the user's entry.
    let userDir = try makeHostPhraseUserDirectory()
    try writeHostPhrase(
      "自定一\ti\t100000\n自定GO\tgo\t100000\n",
      fileName: "custom_phrase.txt",
      to: userDir
    )
    let customEngine = try makeHostPhraseEngine(userDataURL: userDir)
    XCTAssertTrue(customEngine.selectSchema("wubi86_jidian"))
    let customSession = customEngine.createSession()
    defer { customSession.destroy() }

    typeText("i", into: customSession)
    let customIComp = try XCTUnwrap(customSession.composition())
    XCTAssertEqual(customIComp.candidates.first?.text, "不")
    XCTAssertFalse(customIComp.candidates.contains { $0.text == "自定一" })
    customSession.clearComposition()
    XCTAssertTrue(customSession.process(keycode: asciiKeycode("K"), modifiers: kShiftMask.rawValue))
    typeText("i", into: customSession)
    XCTAssertTrue(visibleAndPeekedCandidates(in: customSession).contains { $0.text == "自定一" })
    customSession.clearComposition()

    typeText("go", into: customSession)
    let customGoComp = try XCTUnwrap(customSession.composition())
    XCTAssertEqual(customGoComp.candidates.first?.text, "来")
    XCTAssertFalse(customGoComp.candidates.contains { $0.text == "自定GO" })
    customSession.clearComposition()
    XCTAssertTrue(customSession.process(keycode: asciiKeycode("K"), modifiers: kShiftMask.rawValue))
    typeText("go", into: customSession)
    XCTAssertTrue(visibleAndPeekedCandidates(in: customSession).contains { $0.text == "自定GO" })
  }
}
