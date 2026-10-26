import AppKit
import InputMethodKit
import XCTest
@testable import Owltype

/// Exercises production controller → Rust engine → native text storage without registering an IME.
/// The IMK IPC transport and TIS source detection are the only substituted boundaries.
final class OwlInputHabitsIntegrationTests: XCTestCase {
  @MainActor
  func testNativeApplicationChordsFinishCompositionBeforePassthrough() throws {
    for flags: NSEvent.ModifierFlags in [.command, .control, .option] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-finish-chord-\(UUID())")
      defer { try? FileManager.default.removeItem(at: root) }
      let engine = OwlRustEngine(sharedSupportURL: try XCTUnwrap(Bundle.main.sharedSupportURL),
        userDataURL: root, activeGenerationProvider: { nil })
      let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
      controller.destroySession()
      controller.rime = engine.createSession()
      let client = HabitsTextClient()
      client.appID = "com.apple.TextEdit"
      controller.client = client
      defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
      controller.rime?.setOption(.asciiMode, false)
      try type("ni", into: controller, client: client)
      XCTAssertFalse(controller.handle(try key("c", code: 8, flags: flags), client: client))
      XCTAssertEqual(client.text.string, "你", "application receives its chord only after native FinishComposition")
      XCTAssertEqual(controller.rime?.input(), "")
      XCTAssertFalse(client.text.hasMarkedText())
      // The input method's own segment-editing chord must keep ownership.
      try type("nihao", into: controller, client: client)
      XCTAssertTrue(controller.handle(try key("\u{f702}", code: 123, flags: .control), client: client))
      XCTAssertEqual(controller.rime?.input(), "nihao")
      XCTAssertTrue(client.text.hasMarkedText())
    }
  }

  @MainActor
  func testWubiApplicationChordFinishesCandidateBeforePassthrough() throws {
    let restore = useWubiPreferences()
    defer { restore() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-wubi-chord-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OwlRustEngine(sharedSupportURL: try XCTUnwrap(Bundle.main.sharedSupportURL),
      userDataURL: root, activeGenerationProvider: { nil })
    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = engine.createSession()
    let client = HabitsTextClient()
    client.appID = "com.apple.TextEdit"
    controller.client = client
    defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
    controller.rime?.setOption(.asciiMode, false)
    try type("i", into: controller, client: client)
    XCTAssertEqual(controller.rime?.status()?.schemaId, "wubi86_jidian")
    XCTAssertEqual(controller.rime?.composition()?.candidates.first?.text, "不")
    XCTAssertFalse(controller.handle(try key("c", code: 8, flags: .command), client: client))
    XCTAssertEqual(client.text.string, "不")
    XCTAssertEqual(controller.rime?.input(), "")
    XCTAssertFalse(client.text.hasMarkedText())
  }

  @MainActor
  func testWubiFactoryPairingUsesNativeMarkedClosingAndPunctuationTail() throws {
    let restore = useWubiPreferences()
    let defaults = OwlDefaults.standard
    let pairKey = "OwlKeyboardAutoPairBrackets"
    let savedPair = defaults.object(forKey: pairKey)
    defer {
      restore()
      OwlKeyboardPreferences.autoPairBrackets = (savedPair as? NSNumber)?.boolValue ?? true
      if let savedPair { defaults.set(savedPair, forKey: pairKey) } else { defaults.removeObject(forKey: pairKey) }
    }
    defaults.removeObject(forKey: pairKey)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-wubi-pair-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OwlRustEngine(sharedSupportURL: try XCTUnwrap(Bundle.main.sharedSupportURL),
      userDataURL: root, activeGenerationProvider: { nil })
    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = engine.createSession()
    let client = HabitsTextClient()
    client.appID = "com.apple.TextEdit"
    controller.client = client
    defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
    controller.rime?.setOption(.asciiMode, false)
    controller.rime?.setOption(.asciiPunct, false)
    XCTAssertTrue(OwlKeyboardPreferences.autoPairBrackets)
    XCTAssertTrue(controller.handle(try key("(", code: 25, flags: .shift), client: client))
    XCTAssertEqual(client.text.string, "（）")
    XCTAssertEqual(client.text.markedRange(), NSRange(location: 1, length: 1))
    try type("i ", into: controller, client: client)
    XCTAssertEqual(client.text.string, "（不）")
    XCTAssertFalse(client.text.hasMarkedText())
    try type("i", into: controller, client: client)
    XCTAssertTrue(controller.handle(try key("(", code: 25, flags: .shift), client: client))
    // Pinned Host API commits 不（; native InputController holds ） after that punctuation tail.
    XCTAssertEqual(client.text.string, "（不）不（）")
    XCTAssertEqual(client.text.markedRange().length, 1)
    controller.commitComposition(client)
    XCTAssertFalse(client.text.hasMarkedText())
    OwlKeyboardPreferences.autoPairBrackets = false
    XCTAssertTrue(controller.handle(try key("(", code: 25, flags: .shift), client: client))
    XCTAssertEqual(client.text.string, "（不）不（）（", "explicit stored false keeps pairing off")
  }

  @MainActor
  func testWubiFocusFinishCommitsAndLearnsHighlightedCandidate() throws {
    let restore = useWubiPreferences()
    defer { restore() }
    let defaults = OwlDefaults.standard
    let learningKey = "OwlKeyboardWubiUserDictLearning"
    let saved = defaults.object(forKey: learningKey)
    defer {
      if let saved { defaults.set(saved, forKey: learningKey) } else { defaults.removeObject(forKey: learningKey) }
    }
    defaults.removeObject(forKey: learningKey)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-wubi-focus-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OwlRustEngine(sharedSupportURL: try XCTUnwrap(Bundle.main.sharedSupportURL),
      userDataURL: root, activeGenerationProvider: { nil })
    XCTAssertTrue(engine.selectSchema("wubi86_jidian"))
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = engine.createSession()
    let client = HabitsTextClient()
    client.appID = "com.apple.TextEdit"
    controller.client = client
    defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
    controller.rime?.setOption(.asciiMode, false)
    try type("gggg", into: controller, client: client)
    XCTAssertEqual(controller.rime?.composition()?.candidates.prefix(2).map(\.text), ["王", "五一"])
    XCTAssertTrue(controller.handle(try key("\u{f701}", code: 125), client: client))
    XCTAssertEqual(controller.rime?.composition()?.highlightedIndex, 1)
    controller.commitComposition(client)
    XCTAssertEqual(client.text.string, "五一")
    XCTAssertEqual(controller.rime?.input(), "")
    XCTAssertFalse(client.text.hasMarkedText())
    controller.destroySession()
    XCTAssertTrue(engine.finalize())
    let reopened = engine.createSession()
    defer { reopened.destroy() }
    for scalar in "gggg".unicodeScalars {
      XCTAssertTrue(reopened.process(keycode: scalar.value, modifiers: 0))
    }
    // Independent pinned native FinishOnFocusLoss replay promotes 五一 after this one finish.
    XCTAssertEqual(reopened.composition()?.candidates.first?.text, "五一")
  }

  @MainActor
  func testNativePairedPunctuationHoldsClosingAndReopensQuotes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-native-pairs-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OwlRustEngine(sharedSupportURL: try XCTUnwrap(Bundle.main.sharedSupportURL),
      userDataURL: root, activeGenerationProvider: { nil })
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = engine.createSession()
    let client = HabitsTextClient()
    client.appID = "com.apple.TextEdit"
    controller.client = client
    defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
    XCTAssertTrue(OwlKeyboardPreferences.autoPairBrackets, "pinned native default is paired punctuation on")
    controller.rime?.setOption(.asciiMode, false)
    controller.rime?.setOption(.asciiPunct, false)
    XCTAssertTrue(controller.handle(try key("(", code: 25, flags: .shift), client: client))
    XCTAssertEqual(client.text.string, "（）")
    XCTAssertEqual(client.text.markedRange(), NSRange(location: 1, length: 1))
    XCTAssertEqual(client.text.selectedRange(), NSRange(location: 1, length: 0))
    try type("ni", into: controller, client: client)
    XCTAssertTrue(client.text.string.hasSuffix("）"))
    XCTAssertLessThanOrEqual(client.text.selectedRange().location, NSMaxRange(client.text.markedRange()) - 1)
    try type(" ", into: controller, client: client)
    XCTAssertEqual(client.text.string, "（你）")
    XCTAssertFalse(client.text.hasMarkedText())
    client.text.setSelectedRange(NSRange(location: 2, length: 0))
    XCTAssertTrue(controller.handle(try key("）", code: 0), client: client))
    XCTAssertEqual(client.text.string, "（你）", "skip only a closing mark this host owns")
    XCTAssertEqual(client.text.selectedRange().location, 3)
    for _ in 0..<2 {
      XCTAssertTrue(controller.handle(try key("\"", code: 39, flags: .shift), client: client))
      XCTAssertTrue(client.text.string.hasSuffix("“”"), "each fresh paired quote reopens upstream alternation")
      XCTAssertEqual(client.text.markedRange().length, 1)
      try type("hao ", into: controller, client: client)
    }
    XCTAssertEqual(client.text.string, "（你）“好”“好”")
    for _ in 0..<2 {
      XCTAssertTrue(controller.handle(try key("<", code: 43, flags: .shift), client: client))
      XCTAssertTrue(client.text.string.hasSuffix("《》"), "host autoclose must balance the engine nesting state")
      controller.commitComposition(client)
    }
    try type("nihao", into: controller, client: client)
    XCTAssertTrue(controller.handle(try key("(", code: 25, flags: .shift), client: client))
    XCTAssertTrue(client.text.string.hasSuffix("你好（）"), "punctuation tail after a candidate opens a pair")
    controller.commitComposition(client)
    XCTAssertFalse(client.text.hasMarkedText(), "host composition end must flush the held closing exactly once")
    XCTAssertTrue(client.text.string.hasSuffix("你好（）"))
    let complete = client.text.string
    client.appID = "org.owltype.untrusted-host"
    client.text.setSelectedRange(NSRange(location: complete.utf16.count - 1, length: 0))
    XCTAssertFalse(controller.handle(try key("）", code: 0), client: client),
      "an unverified host must receive the key without a replacement write")
    XCTAssertEqual(client.text.string, complete)
    client.appID = "com.apple.TextEdit"
    client.text.setSelectedRange(NSRange(location: complete.utf16.count, length: 0))
    XCTAssertTrue(controller.handle(try key("(", code: 25, flags: .shift), client: client))
    try type("ni", into: controller, client: client)
    let nextClient = HabitsTextClient()
    nextClient.appID = "com.apple.TextEdit"
    XCTAssertTrue(controller.handle(try key("h", code: 4), client: nextClient))
    XCTAssertTrue(client.text.string.hasSuffix("（你）"), "old field completes before client replacement")
    XCTAssertFalse(client.text.hasMarkedText())
    XCTAssertFalse(nextClient.text.string.contains("）"), "a closing tail cannot move to another field")
    controller.deactivateServer(nextClient)
  }

  @MainActor
  func testCandidateDeletionUsesPhysicalChordAndRejectsOldMenuToken() throws {
    let shared = try XCTUnwrap(Bundle.main.sharedSupportURL)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-delete-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OwlRustEngine(sharedSupportURL: shared, userDataURL: root,
                               activeGenerationProvider: { nil })
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = engine.createSession()
    let client = HabitsTextClient()
    controller.client = client
    defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
    let session = try XCTUnwrap(controller.rime)
    XCTAssertTrue(session.selectSchema("rime_ice"))
    for ch in "nihao".unicodeScalars { XCTAssertTrue(session.process(keycode: ch.value, modifiers: 0)) }
    let before = try XCTUnwrap(session.composition())
    let index = try XCTUnwrap(before.candidates.firstIndex { $0.text == "你好吗" })
    let token = OwlCandidateToken(sessionID: session.sessionID, generation: session.generation,
                                  candidateID: index)
    session.clearComposition()
    for ch in "nihao".unicodeScalars { XCTAssertTrue(session.process(keycode: ch.value, modifiers: 0)) }
    XCTAssertFalse(controller.removeCandidate(token), "An old context menu cannot delete a new row")
    XCTAssertTrue(session.composition()?.candidates.contains { $0.text == "你好吗" } == true)
    let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]
    let current = try XCTUnwrap(session.composition()?.candidates.firstIndex { $0.text == "你好吗" })
    // Deliberately layout-dependent text: deletion must use the physical key code.
    XCTAssertTrue(controller.handle(try key("$", code: codes[current],
      flags: [.control, .option, .shift]), client: client))
    XCTAssertFalse(session.composition()?.candidates.contains { $0.text == "你好吗" } == true)
    XCTAssertNil(session.takeCommit())
    XCTAssertTrue(controller.handle(try key("\u{1b}", code: 53), client: client))
    XCTAssertEqual(client.text.string, "", "Cancel clears only marked text; deletion must not commit the chord")
    controller.destroySession()
    XCTAssertTrue(engine.finalize())
    controller.rime = engine.createSession()
    let reopened = try XCTUnwrap(controller.rime)
    XCTAssertTrue(reopened.selectSchema("rime_ice"))
    for ch in "nihao".unicodeScalars { XCTAssertTrue(reopened.process(keycode: ch.value, modifiers: 0)) }
    XCTAssertFalse(reopened.composition()?.candidates.contains { $0.text == "你好吗" } == true)
    controller.rimeUpdate()
    let menuIndex = try XCTUnwrap(reopened.composition()?.candidates.firstIndex { $0.text == "你好啊" })
    let menuToken = OwlCandidateToken(sessionID: reopened.sessionID, generation: reopened.generation,
                                      candidateID: menuIndex)
    let menuAction = try XCTUnwrap(NSApp.owlAppDelegate.owlPanel?.onRemove)
    menuAction(menuToken)
    XCTAssertFalse(reopened.composition()?.candidates.contains { $0.text == "你好啊" } == true)
  }

  @MainActor
  func testSettledPauseUsesRealModelAndKeepsNativeSelectionAndEditsCurrent() throws {
    let defaults = OwlDefaults.standard
    let saved = defaults.persistentDomain(forName: OwlDefaults.testSuiteName)
    defaults.removePersistentDomain(forName: OwlDefaults.testSuiteName)
    defer {
      defaults.removePersistentDomain(forName: OwlDefaults.testSuiteName)
      if let saved { defaults.setPersistentDomain(saved, forName: OwlDefaults.testSuiteName) }
    }
    OwlKeyboardPreferences.inputMethod = .pinyin
    OwlKeyboardPreferences.pageSize = 6
    OwlExperimentalPreferences.keyboardRerankEnabled = false
    OwlExperimentalPreferences.settledRerankEnabled = true
    let shared = try XCTUnwrap(Bundle.main.sharedSupportURL)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: shared.appendingPathComponent("msime/models/settled-model.bin").path
    ), "the official desktop model must run, not skip")

    for action in ["token", "digit", "backspace", "schema", "focus", "select-before-poll", "page"] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-settled-host-\(UUID())")
      defer { try? FileManager.default.removeItem(at: root) }
      let engine = OwlRustEngine(sharedSupportURL: shared, userDataURL: root, activeGenerationProvider: { nil })
      let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
      controller.destroySession()
      let session = try XCTUnwrap(engine.createSession() as? OwlRustSession)
      controller.rime = session
      let client = HabitsTextClient()
      controller.client = client
      defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
      XCTAssertTrue(session.selectSchema("rime_ice"))
      session.setOption(.asciiMode, false)
      var now: UInt64 = 1_000_000_000
      controller.settledRerankNow = { now }
      let readyDeadline = Date().addingTimeInterval(30)
      repeat {
        session.syncRerankPreferences()
        if session.settledRerankReady { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
      } while Date() < readyDeadline
      XCTAssertTrue(session.settledRerankReady)
      XCTAssertEqual(OwlKeyboardPreferences.pageSize, 6, "isolated model oracle requires native six-row page")
      try type("tadefangjian", into: controller, client: client)
      let before = try XCTUnwrap(session.composition())
      XCTAssertEqual(before.candidates.map(\.text),
        ["它的房间", "他的房间", "她的房间", "它的放吉安", "他的放吉安", "她的放吉安"])
      let oldToken = OwlCandidateToken(sessionID: session.sessionID, generation: session.generation,
        candidateID: 0, isAbsolute: false)
      now += 149_999_999
      try XCTUnwrap(controller.settledRerankDebounceTimer).fire()
      XCTAssertNil(controller.settledRerankJob)
      now += 1
      try XCTUnwrap(controller.settledRerankDebounceTimer).fire()
      XCTAssertNotNil(controller.settledRerankJob, "real model work starts only at the pause: \(action)")

      switch action {
      case "backspace":
        XCTAssertTrue(controller.handle(try key("\u{7f}", code: 51), client: client))
      case "schema":
        XCTAssertEqual(controller.switchLiveSessionSchema(to: "double_pinyin_flypy"), .ok)
      case "focus":
        controller.deactivateServer(client)
      case "select-before-poll":
        XCTAssertTrue(controller.selectCandidate(oldToken))
        XCTAssertEqual(client.text.string, before.candidates[0].text)
      case "page":
        XCTAssertTrue(controller.page(up: false))
        XCTAssertEqual(session.composition()?.pageNo, 1)
      default: break
      }
      let afterAction = try XCTUnwrap(session.composition())
      let actionInput = session.input()
      let actionGeneration = session.generation
      let textAfterAction = client.text.string
      let deadline = Date().addingTimeInterval(30)
      repeat {
        controller.settledRerankPollTimer?.fire()
        if controller.settledRerankJob == nil { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
      } while Date() < deadline
      XCTAssertNil(controller.settledRerankJob, action)
      let published = try XCTUnwrap(session.composition())
      if action == "token" || action == "digit" {
        XCTAssertEqual(published.candidates.map(\.text),
          ["他的房间", "它的房间", "她的房间", "它的放吉安", "他的放吉安", "她的放吉安"])
        XCTAssertGreaterThan(session.generation, oldToken.generation)
        XCTAssertFalse(controller.selectCandidate(oldToken), "stale visible identities cannot select a new seat")
        if action == "token" {
          let fresh = OwlCandidateToken(sessionID: session.sessionID, generation: session.generation,
            candidateID: 1, isAbsolute: false)
          XCTAssertTrue(controller.selectCandidate(fresh))
        } else {
          XCTAssertTrue(controller.handle(try key("2", code: 19), client: client))
        }
        XCTAssertEqual(client.text.string, published.candidates[1].text)
        XCTAssertFalse(client.text.hasMarkedText())
      } else {
        XCTAssertEqual(session.generation, actionGeneration, action)
        XCTAssertEqual(session.input(), actionInput, action)
        XCTAssertEqual(published.candidates.map(\.text), afterAction.candidates.map(\.text), action)
        XCTAssertEqual(published.pageNo, afterAction.pageNo, action)
        XCTAssertEqual(client.text.string, textAfterAction, action)
      }
    }
  }

  @MainActor
  func testSmartPunctuationUsesHostContextAndRepeatCorrection() throws {
    let shared = try XCTUnwrap(Bundle.main.sharedSupportURL)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-smart-punct-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OwlRustEngine(sharedSupportURL: shared, userDataURL: root)
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = engine.createSession()
    let client = HabitsTextClient()
    client.appID = "com.apple.TextEdit"
    controller.client = client
    defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
    controller.rime?.setOption(.asciiMode, false)
    controller.rime?.setOption(.asciiPunct, false)
    client.text.string = "1"
    client.text.setSelectedRange(NSRange(location: 1, length: 0))
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertEqual(client.text.string, "1.")
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertEqual(client.text.string, "1。")
    client.text.string = "1."
    client.text.setSelectedRange(NSRange(location: 0, length: 0))
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertEqual(client.text.string, "。1.", "A moved caret invalidates replacement ownership")
    let previous = OwlKeyboardPreferences.smartPunctuation
    OwlKeyboardPreferences.smartPunctuation = false
    defer { OwlKeyboardPreferences.smartPunctuation = previous }
    client.text.string = "1"
    client.text.setSelectedRange(NSRange(location: 1, length: 0))
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertEqual(client.text.string, "1。", "Changing the setting immediately changes actual host output")
  }

  @MainActor
  func testSmartPunctuationSpaceGestureIsOptInAndReversible() throws {
    let shared = try XCTUnwrap(Bundle.main.sharedSupportURL)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-smart-punct-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OwlRustEngine(sharedSupportURL: shared, userDataURL: root)
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = engine.createSession()
    let client = HabitsTextClient()
    client.appID = "com.apple.TextEdit"
    controller.client = client
    defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
    controller.rime?.setOption(.asciiMode, false)
    controller.rime?.setOption(.asciiPunct, false)
    let previous = OwlKeyboardPreferences.smartPunctuationSpace
    OwlKeyboardPreferences.smartPunctuationSpace = true
    defer { OwlKeyboardPreferences.smartPunctuationSpace = previous }
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertEqual(client.text.string, "。")
    XCTAssertTrue(controller.handle(try key(" ", code: 49), client: client))
    XCTAssertEqual(client.text.string, ".", "The correcting space is swallowed")
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertEqual(client.text.string, "。")
    controller.smartPunctuation.reset()
    client.text.string = ""
    client.text.setSelectedRange(NSRange(location: 0, length: 0))
    OwlKeyboardPreferences.smartPunctuationSpace = false
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertFalse(controller.handle(try key(" ", code: 49), client: client))
    XCTAssertEqual(client.text.string, "。")
  }

  @MainActor
  func testSmartPunctuationUnreadableHostUsesOnlyOwnedShadow() throws {
    let shared = try XCTUnwrap(Bundle.main.sharedSupportURL)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-smart-punct-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OwlRustEngine(sharedSupportURL: shared, userDataURL: root)
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    controller.rime = engine.createSession()
    let client = HabitsTextClient()
    client.appID = "com.apple.TextEdit"
    controller.client = client
    defer { controller.destroySession(); NSApp.owlAppDelegate.owlPanel?.hidePanel() }
    controller.rime?.setOption(.asciiMode, false)
    controller.rime?.setOption(.asciiPunct, false)
    client.exposesText = false
    var posted = 0
    controller.smartPunctuation.postRewrite = { _, replacement in
      posted += 1
      let range = client.text.selectedRange()
      client.text.insertText(replacement, replacementRange: NSRange(location: range.location - 1, length: 1))
      return true
    }
    XCTAssertFalse(controller.handle(try key("1", code: 18), client: client))
    client.insertText("1", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertEqual(client.text.string, "1.")
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertEqual(client.text.string, "1。")
    XCTAssertEqual(posted, 1)
    controller.smartPunctuation.reset()
    XCTAssertTrue(controller.handle(try key(".", code: 47), client: client))
    XCTAssertEqual(posted, 1, "No document text and no owned shadow cannot authorize a rewrite")
  }

  @MainActor
  func testControllerRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owl-habits-integration-\(UUID())")
    let shared = try XCTUnwrap(Bundle.main.sharedSupportURL)
    try FileManager.default.copyItem(at: shared.appendingPathComponent("_user_seed"), to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let previousUserDir = ProcessInfo.processInfo.environment["OWL_TEST_USER_DIR"]
    setenv("OWL_TEST_USER_DIR", root.path, 1)
    defer {
      if let previousUserDir { setenv("OWL_TEST_USER_DIR", previousUserDir, 1) } else { unsetenv("OWL_TEST_USER_DIR") }
    }
    let availability = OwlPinyinCandidateDeployment.available
    defer { OwlPinyinCandidateDeployment.available = availability }
    try OwlPinyinCandidateDeployment.apply(userDir: root, sharedDir: shared)
    let engine = OwlRustEngine(sharedSupportURL: shared, userDataURL: root)
    engine.setup(
      OwlEngineTraits(
        sharedDataDir: shared,
        userDataDir: root,
        logDir: root,
        appName: OwlRimeIdentity.appName
      )
    )
    defer { engine.cleanupAllSessions(); _ = engine.finalize() }
    XCTAssertTrue(engine.startMaintenance(fullCheck: true))
    engine.joinMaintenance()
    let delegate = NSApp.owlAppDelegate
    let originalEngine = delegate.engine
    delegate.engine = engine
    let method = OwlKeyboardPreferences.inputMethod
    OwlKeyboardPreferences.inputMethod = .pinyin
    let initial = OwlKeyboardPreferences.defaultAsciiMode
    OwlKeyboardPreferences.defaultAsciiMode = false
    defer {
      delegate.engine = originalEngine
      OwlKeyboardPreferences.inputMethod = method
      OwlKeyboardPreferences.defaultAsciiMode = initial
    }
    let client = HabitsTextClient()
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { controller.destroySession(); delegate.owlPanel?.hidePanel() }
    XCTAssertTrue(controller.rime?.isValid == true)
    XCTAssertEqual(controller.schemaId, "rime_ice")
    controller.client = client
    controller.activateServer(client)
    var complete = false
    client.text.onChange = { _, done, _ in complete = done }
    try type("nihao ", into: controller, client: client)
    XCTAssertEqual(client.text.string, "你好")
    XCTAssertFalse(complete)
    try type(",maotouying", into: controller, client: client)
    XCTAssertFalse(complete, "Uncommitted candidates cannot finish practice")
    try type(" ", into: controller, client: client)
    XCTAssertEqual(client.text.string, OwlPracticeProof.target)
    XCTAssertTrue(complete, "Real engine commits must complete the native practice field")
    clear(client)
    XCTAssertFalse(complete)

    let pins = OwlPinnedWords.shared
    let pin = OwlPinnedWord(code: "shixing", text: "试行", traditional: false)
    XCTAssertFalse(pins.words.contains(pin))
    defer { pins.remove(pin) }
    try type("shixing", into: controller, client: client)
    XCTAssertNotNil(controller.pinnedTarget(text: pin.text))
    let panel = try XCTUnwrap(delegate.owlPanel)
    XCTAssertTrue(panel.canPin?(pin.text) == true)
    panel.onPin?(pin.text)
    XCTAssertTrue(pins.words.contains(pin))
    XCTAssertEqual(controller.rime?.composition()?.candidates.first?.text, pin.text)
    XCTAssertNotEqual(client.text.string, pin.text, "Pinning must not commit")
    try type(" ", into: controller, client: client)
    XCTAssertEqual(client.text.string, pin.text)
    clear(client)
    try type("shixing1", into: controller, client: client)
    XCTAssertEqual(client.text.string, pin.text, "Numeric selection must agree with the visible first row")
    clear(client)
    try type("shixing", into: controller, client: client)
    XCTAssertTrue(controller.handle(try key("P", code: 35, flags: [.control, .shift]), client: client))
    XCTAssertFalse(pins.words.contains(pin), "The hotkey must unpin the highlighted word")
    XCTAssertFalse(
      controller.rime?.composition()?.candidates.contains {
        $0.text == pin.text && $0.comment == "置顶"
      } ?? true,
      "Unpinning must remove the candidate annotation even when it otherwise ranks first"
    )
    XCTAssertTrue(controller.handle(try key("\u{1b}", code: 53), client: client))
    XCTAssertEqual(client.text.string, "", "Escape must leave no committed text or keep-alive character")

    try type("lvshi", into: controller, client: client)
    XCTAssertNotNil(controller.pinnedTarget(text: "律师"), "Full pinyin with ü must be pinnable")
    XCTAssertTrue(controller.handle(try key("\u{1b}", code: 53), client: client))

    try type("lue", into: controller, client: client)
    let umlautPin = try XCTUnwrap(controller.pinnedTarget(text: "略"), "Rime's lue → lve display must not disable full-code pinning")
    defer { pins.remove(umlautPin) }
    panel.onPin?("略")
    XCTAssertTrue(pins.words.contains(umlautPin))
    XCTAssertEqual(controller.rime?.input(), "lue", "Normalization must not change the actual code")
    try type("1", into: controller, client: client)
    XCTAssertEqual(client.text.string, "略")
    clear(client)

    let memory = OwlAppInputMemory.shared
    let enabled = memory.enabled
    memory.enabled = true
    let other = HabitsTextClient()
    other.appID = "com.owltype.test.habits.other"
    defer { memory.forget(client.appID); memory.forget(other.appID); memory.enabled = enabled }
    XCTAssertNil(memory.modes[client.appID], "Initial mode must not create a choice")
    controller.rime?.setOption(.asciiMode, true)
    controller.rimeUpdate()
    XCTAssertEqual(memory.modes[client.appID], true)
    for _ in 0..<20 {
      controller.deactivateServer(client)
      controller.activateServer(other)
      XCTAssertFalse(controller.rime?.option(.asciiMode) ?? true)
      controller.deactivateServer(other)
      controller.activateServer(client)
      XCTAssertTrue(controller.rime?.option(.asciiMode) == true)
    }
    XCTAssertFalse(controller.handle(try key("a", code: 0), client: client), "English passes through to the host")
    // A second window of the same app changes the remembered mode. The old controller must
    // neither overwrite that choice on deactivation nor resurrect its stale mode on return.
    let second = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { second.destroySession() }
    second.activateServer(client)
    let statusPanel = OwlInputStatusPanel.shared
    XCTAssertTrue(statusPanel.isVisible)
    let currentStatusView = statusPanel.contentView
    statusPanel.refresh(controller)
    statusPanel.deactivate(controller)
    XCTAssertTrue(statusPanel.isVisible, "Old sessions cannot hide the active status bar")
    XCTAssertTrue(statusPanel.contentView === currentStatusView, "Old sessions cannot repaint the active status bar")
    XCTAssertTrue(second.rime?.option(.asciiMode) == true)
    second.rime?.setOption(.asciiMode, false)
    second.rimeUpdate()
    second.deactivateServer(client)
    XCTAssertFalse(statusPanel.isVisible)
    controller.deactivateServer(client)
    XCTAssertEqual(memory.modes[client.appID], false)
    controller.activateServer(client)
    XCTAssertFalse(controller.rime?.option(.asciiMode) ?? true)
    controller.rime?.setOption(.asciiMode, true)
    controller.rimeUpdate()
    memory.enabled = false
    controller.deactivateServer(client)
    controller.activateServer(client)
    XCTAssertFalse(controller.rime?.option(.asciiMode) ?? true)
    XCTAssertEqual(memory.modes[client.appID], true, "Disabling memory must retain the stored choice")
    memory.enabled = true
    controller.deactivateServer(client)
    controller.activateServer(client)
    XCTAssertTrue(controller.rime?.option(.asciiMode) == true)
    memory.forget(client.appID)
    controller.deactivateServer(client)
    controller.activateServer(client)
    XCTAssertFalse(controller.rime?.option(.asciiMode) ?? true, "Forget restores the initial mode")
    try type("nihao ", into: controller, client: client)
    XCTAssertEqual(client.text.string, "你好")

    // Exercise the complete settings production path, including live and background controllers.
    clear(client)
    try type("nihao", into: controller, client: client)
    let previousPageSize = OwlKeyboardPreferences.pageSize
    defer { OwlKeyboardPreferences.pageSize = previousPageSize }
    let previousSession = try XCTUnwrap(controller.rime)
    OwlKeyboardPreferences.pageSize = 3
    let applied = try delegate.applyKeyboardSettings(.config, directory: root)
    XCTAssertTrue(applied.succeeded)
    // Prove the recreate by the wrapper instead: the old one is destroyed, a new one is live.
    XCTAssertFalse(previousSession.isValid, "Applying settings must destroy the old session")
    XCTAssertFalse(controller.rime === previousSession, "The active controller must get a new session")
    XCTAssertEqual(controller.rime?.input(), "nihao", "Applying settings must retain in-flight composition")
    XCTAssertEqual(controller.rime?.composition()?.pageSize, 3, "The running engine must read the saved setting")
    XCTAssertFalse(second.rime?.isValid == true, "Background sessions must wait for their next activation")
    try type(" ", into: controller, client: client)
    XCTAssertEqual(client.text.string, "你好", "The replayed composition must still commit normally")
  }

  @MainActor
  private func useWubiPreferences() -> () -> Void {
    let defaults = OwlDefaults.standard
    let keys = ["OwlKeyboardInputMethod", "OwlKeyboardWubiScheme"]
    let saved = keys.map { defaults.object(forKey: $0) }
    OwlKeyboardPreferences.inputMethod = .wubi
    OwlKeyboardPreferences.wubiScheme = .jidian86
    return {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
      }
    }
  }

  private func clear(_ client: HabitsTextClient) {
    client.text.string = ""
    client.text.didChangeText()
  }

  private func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
      isARepeat: false, keyCode: code))
  }

  @MainActor
  private func type(_ text: String, into controller: OwlInputController, client: HabitsTextClient) throws {
    for character in text {
      XCTAssertTrue(controller.handle(try key(String(character), code: character == " " ? 49 : 0), client: client))
    }
  }
}

private final class HabitsTextClient: NSObject, IMKTextInput {
  let text = OwlPracticeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
  var appID = "com.owltype.test.habits"
  var exposesText = true
  override init() { super.init(); text.sourceIsOwl = { true } }
  func insertText(_ string: Any!, replacementRange: NSRange) { text.insertText(string as Any, replacementRange: replacementRange) }
  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
    text.setMarkedText(string as Any, selectedRange: selectionRange, replacementRange: replacementRange)
  }
  func selectedRange() -> NSRange { exposesText ? text.selectedRange() : NSRange(location: NSNotFound, length: 0) }
  func markedRange() -> NSRange { text.markedRange() }
  func attributedSubstring(from range: NSRange) -> NSAttributedString! {
    guard exposesText, range.location != NSNotFound, NSMaxRange(range) <= text.string.utf16.count else { return nil }
    return text.textStorage?.attributedSubstring(from: range)
  }
  func length() -> Int { text.string.utf16.count }
  func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                      inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
  func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
    lineRect?.pointee = NSRect(x: 100, y: 200, width: 1, height: 20)
    return [:]
  }
  func validAttributesForMarkedText() -> [Any]! { [] }
  func overrideKeyboard(withKeyboardNamed name: String!) {}
  func selectMode(_ modeIdentifier: String!) {}
  func supportsUnicode() -> Bool { true }
  func bundleIdentifier() -> String! { appID }
  func windowLevel() -> CGWindowLevel { 0 }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
  func uniqueClientIdentifierString() -> String! { appID }
  func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
    actualRange?.pointee = range
    return (text.string as NSString).substring(with: range)
  }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect {
    actualRange?.pointee = range
    return NSRect(x: 100, y: 200, width: 1, height: 20)
  }
}
