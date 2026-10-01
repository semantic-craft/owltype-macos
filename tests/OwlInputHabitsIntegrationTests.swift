import AppKit
import InputMethodKit
import XCTest
@testable import Owltype

/// Exercises production controller → live librime → native text storage without registering an IME.
/// The IMK IPC transport and TIS source detection are the only substituted boundaries.
final class OwlInputHabitsIntegrationTests: XCTestCase {
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
    let availability = OwlPinnedWordsDeployment.available
    defer { OwlPinnedWordsDeployment.available = availability }
    try OwlPinnedWordsDeployment.apply(userDir: root, sharedDir: shared)
    let engine = LiveRimeEngine()
    var traits = RimeTraits.rimeStructInit()
    traits.setCString(shared.path, to: \.shared_data_dir)
    traits.setCString(root.path, to: \.user_data_dir)
    traits.setCString(root.path, to: \.log_dir)
    traits.setCString(OwlRimeIdentity.appName, to: \.app_name)
    engine.setup(&traits)
    engine.initialize(nil)
    defer { engine.cleanupAllSessions(); engine.finalize() }
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
    XCTAssertNotEqual(controller.rime?.composition()?.candidates.first?.text, pin.text)
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
    XCTAssertTrue(second.rime?.option(.asciiMode) == true)
    second.rime?.setOption(.asciiMode, false)
    second.rimeUpdate()
    second.deactivateServer(client)
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
  }

  @MainActor
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
  override init() { super.init(); text.sourceIsOwl = { true } }
  func insertText(_ string: Any!, replacementRange: NSRange) { text.insertText(string as Any, replacementRange: replacementRange) }
  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
    text.setMarkedText(string as Any, selectedRange: selectionRange, replacementRange: replacementRange)
  }
  func selectedRange() -> NSRange { text.selectedRange() }
  func markedRange() -> NSRange { text.markedRange() }
  func attributedSubstring(from range: NSRange) -> NSAttributedString! { text.textStorage?.attributedSubstring(from: range) }
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
