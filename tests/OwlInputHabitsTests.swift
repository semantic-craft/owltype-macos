import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import Owltype

final class OwlInputHabitsTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUp() {
    suite = "OwlInputHabitsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }
  override func tearDown() { defaults.removePersistentDomain(forName: suite) }

  func testModeMemoryOverridesInitialEnglishAndSurvivesRestart() {
    let memory = OwlAppInputMemory(defaults: defaults)
    XCTAssertTrue(memory.initialMode(app: "com.apple.dt.Xcode", fallback: true))
    memory.remember(app: "com.apple.dt.Xcode", ascii: false)
    memory.remember(app: "com.tencent.xinWeChat", ascii: true)
    let restarted = OwlAppInputMemory(defaults: defaults)
    XCTAssertFalse(restarted.initialMode(app: "com.apple.dt.Xcode", fallback: true))
    XCTAssertTrue(restarted.initialMode(app: "com.tencent.xinWeChat", fallback: false))
    XCTAssertFalse(restarted.initialMode(app: "com.apple.Notes", fallback: false))
  }

  func testDisabledMemoryAndForgetReturnToFallbackWithoutErasingOthers() {
    let memory = OwlAppInputMemory(defaults: defaults)
    memory.remember(app: "com.example.one", ascii: true)
    memory.remember(app: "com.example.two", ascii: true)
    memory.enabled = false
    memory.remember(app: "com.example.one", ascii: false)
    XCTAssertFalse(memory.initialMode(app: "com.example.one", fallback: false))
    memory.enabled = true
    XCTAssertTrue(memory.initialMode(app: "com.example.one", fallback: false))
    memory.forget("com.example.one")
    XCTAssertFalse(memory.initialMode(app: "com.example.one", fallback: false))
    XCTAssertTrue(memory.initialMode(app: "com.example.two", fallback: false))
    memory.remember(app: "UnknownApp42", ascii: true)
    memory.remember(app: "", ascii: true)
    XCTAssertEqual(memory.modes.count, 1)
  }

  func testInitialModeIsNotRecordedAsAUserChange() {
    var observation = OwlAppModeObservation()
    XCTAssertFalse(observation.changed(to: true))
    observation.seed(false)
    XCTAssertFalse(observation.changed(to: false))
    XCTAssertTrue(observation.changed(to: true))
    XCTAssertFalse(observation.changed(to: true))
  }

  func testPracticeNeedsAnOwlCompositionAndExactCommittedText() {
    var proof = OwlPracticeProof()
    proof.inserted(fromOwl: true, hadComposition: false)
    XCTAssertFalse(proof.isComplete(text: OwlPracticeProof.target, hasMarkedText: false))
    proof.inserted(fromOwl: true, hadComposition: true)
    XCTAssertFalse(proof.isComplete(text: OwlPracticeProof.target, hasMarkedText: true))
    XCTAssertFalse(proof.isComplete(text: "你好", hasMarkedText: false))
    XCTAssertTrue(proof.isComplete(text: OwlPracticeProof.target, hasMarkedText: false))
    proof.inserted(fromOwl: false, hadComposition: true)
    XCTAssertFalse(proof.isComplete(text: OwlPracticeProof.target, hasMarkedText: false))
  }

  @MainActor
  func testNativePracticeFieldRejectsPasteAndOtherInputSource() {
    let view = OwlPracticeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
    var complete = false
    var hint: String?
    view.onChange = { _, done, message in complete = done; hint = message }
    view.sourceIsOwl = { true }
    view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: .empty)
    view.insertText(OwlPracticeProof.target, replacementRange: .empty)
    XCTAssertTrue(complete)
    view.paste(nil)
    XCTAssertFalse(complete)
    XCTAssertEqual(view.string, OwlPracticeProof.target)
    XCTAssertNotNil(hint)
    view.string = ""
    view.didChangeText()
    view.sourceIsOwl = { false }
    view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: .empty)
    view.insertText(OwlPracticeProof.target, replacementRange: .empty)
    XCTAssertFalse(complete)
    XCTAssertNotNil(hint)
  }

  func testPinOrderPersistenceRemovalAndModeIsolation() {
    let pins = OwlPinnedWords(defaults: defaults)
    let first = OwlPinnedWord(code: "shixing", text: "施行", traditional: false)
    let second = OwlPinnedWord(code: "shixing", text: "试行", traditional: false)
    let trad = OwlPinnedWord(code: "shixing", text: "試行", traditional: true)
    XCTAssertTrue(pins.toggle(first))
    XCTAssertTrue(pins.toggle(second))
    XCTAssertTrue(pins.toggle(trad))
    XCTAssertEqual(pins.words, [trad, second, first])
    XCTAssertEqual(OwlPinnedWords(defaults: defaults).words, pins.words)
    XCTAssertTrue(pins.engineValue.contains("shixing\t1\t試行"))
    XCTAssertFalse(pins.toggle(second))
    pins.remove(first)
    XCTAssertEqual(pins.words, [trad])
  }

  func testPinEligibilityRejectsAbbreviationCompletionAndPartialSentence() {
    XCTAssertNotNil(target())
    XCTAssertNil(target(schema: "double_pinyin"))
    XCTAssertNil(target(input: "sx", preedit: "s x"))
    XCTAssertNil(target(input: "n", preedit: "n", text: "你"))
    XCTAssertNil(target(input: "shi", preedit: "shi"))
    XCTAssertNil(target(text: "GitHub"))
    XCTAssertNil(target(text: "施行📌"))
    XCTAssertNil(target(selStart: 3))
    XCTAssertNil(target(caret: 2))
    XCTAssertNotNil(target(input: "lue", preedit: "lve", text: "略", caret: 3))
    XCTAssertNotNil(target(input: "jv", preedit: "ju", text: "居", caret: 2))
    XCTAssertNotNil(target(input: "lvshi", preedit: "lü shi", text: "律师", caret: 5))
    XCTAssertNil(target(input: "ls", preedit: "l s", text: "律师", caret: 2))
    XCTAssertNotNil(target(input: "xi'an", preedit: "xi an", text: "西安", caret: 5))
  }

  func testPinShortcutDefaultYieldsToExistingUserShortcut() {
    let original = Dictionary(uniqueKeysWithValues: OwlHotKeySlot.allCases.map {
      ($0.defaultsKey, OwlDefaults.standard.object(forKey: $0.defaultsKey))
    })
    defer {
      for (key, value) in original {
        if let value { OwlDefaults.standard.set(value, forKey: key) } else { OwlDefaults.standard.removeObject(forKey: key) }
      }
    }
    for slot in OwlHotKeySlot.allCases { OwlDefaults.standard.removeObject(forKey: slot.defaultsKey) }
    let shortcut = OwlRecordedHotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | shiftKey))
    XCTAssertEqual(OwlHotKeySlot.pinCandidate.current, shortcut)
    OwlHotKeySlot.quickSendPanel.current = shortcut
    XCTAssertNil(OwlHotKeySlot.pinCandidate.current)
    OwlHotKeySlot.quickSendPanel.current = nil
    XCTAssertEqual(OwlHotKeySlot.pinCandidate.current, shortcut)
    OwlHotKeySlot.pinCandidate.current = nil
    XCTAssertNil(OwlHotKeySlot.pinCandidate.current)
  }

  @MainActor
  func testPracticeFieldFitsOnboardingWindow() throws {
    let view = OwlOnboardingView(onOpenSystemSettings: {}, onSelectSchema: { _ in },
      onOpenInputSettings: {}, onFinish: {}, initialStep: 4)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()
    func findField(_ root: NSView) -> OwlPracticeTextView? {
      if let field = root as? OwlPracticeTextView { return field }
      return root.subviews.compactMap { findField($0) }.first
    }
    let field = try XCTUnwrap(findField(host))
    let visible = field.convert(field.visibleRect, to: host)
    XCTAssertGreaterThan(visible.width, 350)
    XCTAssertGreaterThan(visible.height, 60)
    XCTAssertTrue(host.bounds.contains(visible))
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/tmp/owltype-onboarding-practice.png"))
    window.close()
  }

  private func target(schema: String = "rime_ice", input: String = "shixing", preedit: String = "shi xing",
                      text: String = "施行", selStart: Int = 0, caret: Int? = nil) -> OwlPinnedWord? {
    let composition = EngineComposition(preedit: preedit, selStart: selStart, selEnd: preedit.utf8.count,
      cursorPos: preedit.utf8.count, commitTextPreview: text, candidates: [EngineCandidate(text: text, comment: nil)],
      labels: ["1"], pageNo: 0, pageSize: 8, isLastPage: false, highlightedIndex: 0, numCandidates: 1)
    return OwlPinnedWords.target(schema: schema, input: input, composition: composition,
      candidate: text, traditional: false, caret: caret ?? input.utf8.count)
  }
}
