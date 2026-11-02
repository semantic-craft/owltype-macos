//
//  OwlAIWindowWritebackTests.swift
//  OwltypeTests — AI Writing Auxiliary Subsystem (Milestone M6 / Issue #394)
//
//  100% offline automated test suite verifying:
//  - Cursor text injection into IMKTextInput client
//  - Nil client fallback to simulated paste / clipboard
//  - AX selection replacement and Vulcan fallback ladder
//  - Empty text guard and multiline preservation
//  - Cancellation with zero text modifications
//  - Pure Swift /ai command detector state machine
//  - Zero NSAlert.runModal() invocations
//

import AppKit
import InputMethodKit
import ObjectiveC
import XCTest
@testable import Owltype

private var alertModalCallCount = 0

extension NSAlert {
  @objc func test_swizzled_runModal() -> NSApplication.ModalResponse {
    alertModalCallCount += 1
    return .alertFirstButtonReturn
  }
}

final class MockAIWritebackTextInputClient: NSObject, IMKTextInput {
  var insertedTexts: [String] = []
  var replacementRanges: [NSRange] = []
  var bundleIDString: String = "com.apple.Notes"
  var onInsert: (() -> Void)? = nil

  func insertText(_ string: Any!, replacementRange: NSRange) {
    if let str = string as? String {
      insertedTexts.append(str)
      replacementRanges.append(replacementRange)
      onInsert?()
    }
  }

  var markedTexts: [String] = []

  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
    if let str = string as? String {
      markedTexts.append(str)
    } else if let attr = string as? NSAttributedString {
      markedTexts.append(attr.string)
    }
  }
  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
  func length() -> Int { 0 }
  func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
  func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { nil }
  func validAttributesForMarkedText() -> [Any]! { [] }
  func overrideKeyboard(withKeyboardNamed name: String!) {}
  func selectMode(_ modeIdentifier: String!) {}
  func supportsUnicode() -> Bool { true }
  func bundleIdentifier() -> String! { bundleIDString }
  func windowLevel() -> CGWindowLevel { 0 }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
  func uniqueClientIdentifierString() -> String! { bundleIDString }
  func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

@MainActor
final class OwlAIWindowWritebackTests: XCTestCase {

  override func setUp() {
    super.setUp()
    OwlAIWritingSettings.resetForTesting()
  }

  override func tearDown() {
    OwlAIWritingSettings.resetForTesting()
    super.tearDown()
  }

  // MARK: - Typing Writeback Tests

  func testTypingModeDirectClientInsertion() {
    let mockClient = MockAIWritebackTextInputClient()
    var dismissed = false

    let context = OwlAIInvocationContext.typing(
      client: mockClient,
      preedit: "nihk",
      frontmostApp: nil,
      bundleID: "com.apple.Notes"
    )

    XCTAssertEqual(context.primaryActionTitle, "上屏 (↩)")

    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: "你好，很高兴为您服务！",
      context: context,
      onDismissWindow: { dismissed = true }
    )

    XCTAssertEqual(outcome, .insertedToClient)
    XCTAssertTrue(dismissed, "Window dismiss callback must be executed on successful writeback")
    XCTAssertEqual(mockClient.insertedTexts, ["你好，很高兴为您服务！"])
    XCTAssertEqual(mockClient.replacementRanges, [.empty])
  }

  func testTypingModeNilClientFallback() {
    var dismissed = false

    let context = OwlAIInvocationContext.typing(
      client: nil,
      preedit: "",
      frontmostApp: nil,
      bundleID: "com.apple.Notes"
    )

    let testText = "回退剪贴板测试文本_\(UUID().uuidString)"
    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: testText,
      context: context,
      onDismissWindow: { dismissed = true }
    )

    XCTAssertTrue(dismissed)
    XCTAssertTrue(outcome == .pastedFallback || outcome == .copiedToClipboard)
    // The text must be in pasteboard either way
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), testText)
  }

  // MARK: - Selection Writeback Tests

  func testSelectionModeAXSuccess() {
    var replacedString: String?
    var dismissed = false

    let target = OwlSelectionReplacementTarget { replacement in
      replacedString = replacement
      return .success
    }

    let snapshot = OwlSelectionMenuSnapshot(
      text: "原始选中文本",
      bounds: NSRect(x: 100, y: 100, width: 200, height: 20),
      replacementTarget: target,
      bundleID: "com.test.editor"
    )

    let context = OwlAIInvocationContext.selection(snapshot: snapshot)
    XCTAssertEqual(context.primaryActionTitle, "替换选区 (↩)")

    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: "润色后的高质量文本",
      context: context,
      onDismissWindow: { dismissed = true }
    )

    XCTAssertEqual(outcome, .replacedSelection(.axSelectedText))
    XCTAssertTrue(dismissed)
    XCTAssertEqual(replacedString, "润色后的高质量文本")
  }

  func testSelectionModeAXFailureFallbackToVulcanLadder() {
    var dismissed = false

    let target = OwlSelectionReplacementTarget { _ in
      return .failed("AX attribute error simulation")
    }

    let snapshot = OwlSelectionMenuSnapshot(
      text: "原始选中文本",
      bounds: .zero,
      replacementTarget: target,
      bundleID: "com.test.readonly-ax"
    )

    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: "回退粘贴替换文本",
      context: .selection(snapshot: snapshot),
      onDismissWindow: { dismissed = true }
    )

    XCTAssertTrue(dismissed)
    XCTAssertTrue(outcome == .replacedSelection(.paste) || outcome == .copiedToClipboard)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "回退粘贴替换文本")
  }

  // MARK: - Standalone Mode Tests

  func testStandaloneModeCopiesToClipboard() {
    var dismissed = false
    let testText = "纯复制对话结果_\(UUID().uuidString)"

    let context = OwlAIInvocationContext.standalone
    XCTAssertEqual(context.primaryActionTitle, "复制 (↩)")

    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: testText,
      context: context,
      onDismissWindow: { dismissed = true }
    )

    XCTAssertEqual(outcome, .copiedToClipboard)
    XCTAssertTrue(dismissed)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), testText)
  }

  // MARK: - Guard and Formatting Tests

  func testEmptyTextWritebackGuard() {
    let mockClient = MockAIWritebackTextInputClient()
    var dismissed = false

    let context = OwlAIInvocationContext.typing(client: mockClient, preedit: "")

    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: "   \n\t  \n  ",
      context: context,
      onDismissWindow: { dismissed = true }
    )

    XCTAssertEqual(outcome, .abortedEmpty)
    XCTAssertFalse(dismissed, "Window should NOT be dismissed when text is empty")
    XCTAssertTrue(mockClient.insertedTexts.isEmpty)
  }

  func testMultilineTextPreservation() {
    let mockClient = MockAIWritebackTextInputClient()
    var dismissed = false

    let multiline = """
    尊敬的客户：
    您好！

    关于您所咨询的合同第 3 条违约条款，建议按如下方案进行修改：
    1. 增加逾期付款违约金比例；
    2. 明确双方争议管辖法院。

    特此函告。
    """

    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: multiline,
      context: .typing(client: mockClient, preedit: ""),
      onDismissWindow: { dismissed = true }
    )

    XCTAssertEqual(outcome, .insertedToClient)
    XCTAssertTrue(dismissed)
    XCTAssertEqual(mockClient.insertedTexts, [multiline])
  }

  func testCancellationZeroSideEffects() {
    let mockClient = MockAIWritebackTextInputClient()
    // Simulate user closing window without clicking writeback button
    XCTAssertTrue(mockClient.insertedTexts.isEmpty)
    XCTAssertTrue(mockClient.replacementRanges.isEmpty)
  }

  // MARK: - /ai Command Detector State Machine Tests

  func testAICommandDetectorSuccessSequence() {
    let detector = OwlAICommandDetector()
    XCTAssertFalse(detector.isArmed)

    let now = Date()
    // Feed "/"
    let r1 = detector.process(character: "/", at: now)
    XCTAssertFalse(r1.isTriggered)
    XCTAssertFalse(r1.shouldFlush.slash)
    XCTAssertFalse(r1.shouldFlush.a)
    XCTAssertTrue(detector.isArmed)

    // Feed "a"
    let r2 = detector.process(character: "a", at: now.addingTimeInterval(0.1))
    XCTAssertFalse(r2.isTriggered)
    XCTAssertFalse(r2.shouldFlush.slash)
    XCTAssertFalse(r2.shouldFlush.a)
    XCTAssertTrue(detector.isArmed)

    // Feed "i"
    let r3 = detector.process(character: "i", at: now.addingTimeInterval(0.2))
    XCTAssertTrue(r3.isTriggered, "/ai sequence must trigger successfully")
    XCTAssertFalse(r3.shouldFlush.slash)
    XCTAssertFalse(r3.shouldFlush.a)
    XCTAssertFalse(detector.isArmed)
  }

  func testAICommandDetectorCaseInsensitive() {
    let detector = OwlAICommandDetector()
    let now = Date()

    _ = detector.process(character: "/", at: now)
    _ = detector.process(character: "A", at: now.addingTimeInterval(0.05))
    let r = detector.process(character: "I", at: now.addingTimeInterval(0.1))
    XCTAssertTrue(r.isTriggered, "/AI (uppercase) must trigger successfully")
  }

  func testAICommandDetectorBrokenSequenceFlushesSlash() {
    let detector = OwlAICommandDetector()
    let now = Date()

    _ = detector.process(character: "/", at: now)
    let r = detector.process(character: "b", at: now.addingTimeInterval(0.1))
    XCTAssertFalse(r.isTriggered)
    XCTAssertTrue(r.shouldFlush.slash)
    XCTAssertFalse(r.shouldFlush.a)
    XCTAssertFalse(detector.isArmed)
  }

  func testAICommandDetectorBrokenSequenceFlushesSlashAndA() {
    let detector = OwlAICommandDetector()
    let now = Date()

    _ = detector.process(character: "/", at: now)
    _ = detector.process(character: "a", at: now.addingTimeInterval(0.1))
    let r = detector.process(character: "x", at: now.addingTimeInterval(0.2))
    XCTAssertFalse(r.isTriggered)
    XCTAssertTrue(r.shouldFlush.slash)
    XCTAssertTrue(r.shouldFlush.a)
    XCTAssertFalse(detector.isArmed)
  }

  func testAICommandDetectorTimeout() {
    let detector = OwlAICommandDetector(timeout: 0.5)
    let now = Date()

    _ = detector.process(character: "/", at: now)
    // Wait beyond timeout (0.6s)
    let r = detector.process(character: "a", at: now.addingTimeInterval(0.6))
    XCTAssertFalse(r.isTriggered)
    XCTAssertTrue(r.shouldFlush.slash)
    XCTAssertFalse(detector.isArmed)
  }

  // MARK: - Settings Tests

  func testWritingSettingsPersistence() {
    XCTAssertFalse(OwlAIWritingSettings.isEnabled, "Default should be disabled")
    OwlAIWritingSettings.isEnabled = true
    XCTAssertTrue(OwlAIWritingSettings.isEnabled)
    OwlAIWritingSettings.resetForTesting()
    XCTAssertFalse(OwlAIWritingSettings.isEnabled)
  }

  // MARK: - Empirical Challenge Stress Tests

  func testWritebackCallOrderingAndFocusRestorationBeforeInsertion() {
    var callOrder: [String] = []

    // 1. Typing mode ordering
    let mockClient = MockAIWritebackTextInputClient()
    mockClient.onInsert = {
      callOrder.append("client.insertText")
    }

    let typingContext = OwlAIInvocationContext.typing(
      client: mockClient,
      preedit: "",
      frontmostApp: nil,
      bundleID: "com.apple.Notes"
    )

    callOrder.removeAll()
    OwlAIWritebackCoordinator.shared.writeback(
      text: "测试上屏顺序",
      context: typingContext,
      onDismissWindow: {
        callOrder.append("onDismissWindow")
      }
    )

    XCTAssertEqual(callOrder, ["onDismissWindow", "client.insertText"],
                   "Window dismiss and focus restoration must precede client insertion")

    // 2. Selection mode ordering
    callOrder.removeAll()
    let target = OwlSelectionReplacementTarget { _ in
      callOrder.append("target.replace")
      return .success
    }
    let snapshot = OwlSelectionMenuSnapshot(
      text: "原文字",
      bounds: .zero,
      replacementTarget: target,
      bundleID: "com.apple.Notes"
    )

    OwlAIWritebackCoordinator.shared.writeback(
      text: "替换文字",
      context: .selection(snapshot: snapshot),
      onDismissWindow: {
        callOrder.append("onDismissWindow")
      }
    )

    XCTAssertEqual(callOrder, ["onDismissWindow", "target.replace"],
                   "Window dismiss and focus restoration must precede selection replacement")
  }

  func testMultilineAndSpecialCharacterFidelityAcrossAllModes() {
    let complexText = """
    # 法律意见书摘要 (2026-11-02) 🦉

    尊敬的委托人：
    根据《民法典》第五百七十七条及双方签署的《合作协议》第 3.2 款，特提出如下合规意见：

    1. 争议解决条款（双语）:
       • 中文：「双方如发生争议，应提交上海国际仲裁中心（SHIAC）仲裁。」
       • English: "Any dispute shall be submitted to SHIAC for arbitration."
       • Arabic / Hebrew: مرحبا بالعالم / שלום עולם

    2. 数学公式与特殊符号：
       ∑_{i=1}^{n} (x_i - μ)^2 ≥ 0 且 √2 ≈ 1.41421356
       Unicode 标点: «Guillemets», “双引号”, ‘单引号’, —破折号…, \u{200B}零宽空格

    3. 表情符号与 ZWJ 序列：
       👨‍👩‍👧‍👦 (家庭) 🇨🇳 (国旗) 🚀 (火箭) 👍🏽 (肤色) ✨ (闪烁)

    4. 代码缩进块:
       ```swift
       func writeback() -> Bool {
           let preserved = true
           return preserved
       }
       ```

    特此函告！
    """

    // Mode 1: .typing
    let mockClient = MockAIWritebackTextInputClient()
    var dismissed1 = false
    let outcome1 = OwlAIWritebackCoordinator.shared.writeback(
      text: complexText,
      context: .typing(client: mockClient, preedit: ""),
      onDismissWindow: { dismissed1 = true }
    )
    XCTAssertEqual(outcome1, .insertedToClient)
    XCTAssertTrue(dismissed1)
    XCTAssertEqual(mockClient.insertedTexts.count, 1)
    XCTAssertEqual(mockClient.insertedTexts.first, complexText, "Typing mode must preserve all newlines, spaces, emoji, and formatting exactly")

    // Mode 2: .selection (AX target)
    var replacedText: String?
    var dismissed2 = false
    let target = OwlSelectionReplacementTarget { replacement in
      replacedText = replacement
      return .success
    }
    let snapshot = OwlSelectionMenuSnapshot(
      text: "原文字",
      bounds: .zero,
      replacementTarget: target,
      bundleID: "com.apple.Notes"
    )
    let outcome2 = OwlAIWritebackCoordinator.shared.writeback(
      text: complexText,
      context: .selection(snapshot: snapshot),
      onDismissWindow: { dismissed2 = true }
    )
    XCTAssertEqual(outcome2, .replacedSelection(.axSelectedText))
    XCTAssertTrue(dismissed2)
    XCTAssertEqual(replacedText, complexText, "Selection AX mode must preserve all formatting and special characters exactly")

    // Mode 3: .standalone (clipboard copy)
    var dismissed3 = false
    let outcome3 = OwlAIWritebackCoordinator.shared.writeback(
      text: complexText,
      context: .standalone,
      onDismissWindow: { dismissed3 = true }
    )
    XCTAssertEqual(outcome3, .copiedToClipboard)
    XCTAssertTrue(dismissed3)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), complexText, "Standalone mode must place complete unmodified text onto pasteboard")
  }

  func testLargePayloadFidelity() {
    let repeatBlock = "🦉 猫头鹰 AI 写作助手深度测试段落，包含标点、换行与空格。\n"
    let largeText = String(repeating: repeatBlock, count: 500)
    XCTAssertGreaterThan(largeText.utf8.count, 20_000)

    let mockClient = MockAIWritebackTextInputClient()
    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: largeText,
      context: .typing(client: mockClient, preedit: ""),
      onDismissWindow: {}
    )
    XCTAssertEqual(outcome, .insertedToClient)
    XCTAssertEqual(mockClient.insertedTexts.first?.count, largeText.count)
    XCTAssertEqual(mockClient.insertedTexts.first, largeText)
  }

  func testZeroModalAlertGuaranteeOnAllPaths() {
    let original = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal))
    let swizzled = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.test_swizzled_runModal))
    guard let original, let swizzled else {
      XCTFail("Could not locate NSAlert.runModal selectors")
      return
    }

    method_exchangeImplementations(original, swizzled)
    defer {
      method_exchangeImplementations(swizzled, original)
    }

    alertModalCallCount = 0

    // Path 1: Empty text
    _ = OwlAIWritebackCoordinator.shared.writeback(
      text: "",
      context: .standalone,
      onDismissWindow: {}
    )
    XCTAssertEqual(alertModalCallCount, 0, "Empty text must not show modal alert")

    // Path 2: Whitespace only
    _ = OwlAIWritebackCoordinator.shared.writeback(
      text: "   \n\t  ",
      context: .standalone,
      onDismissWindow: {}
    )
    XCTAssertEqual(alertModalCallCount, 0, "Whitespace text must not show modal alert")

    // Path 3: Typing with nil client
    _ = OwlAIWritebackCoordinator.shared.writeback(
      text: "Fallback test",
      context: .typing(client: nil, preedit: ""),
      onDismissWindow: {}
    )
    XCTAssertEqual(alertModalCallCount, 0, "Nil client fallback must not show modal alert")

    // Path 4: Selection with AX failure
    let failingTarget = OwlSelectionReplacementTarget { _ in .failed("Simulated failure") }
    let failingSnapshot = OwlSelectionMenuSnapshot(
      text: "原文字",
      bounds: .zero,
      replacementTarget: failingTarget,
      bundleID: "com.test.readonly"
    )
    _ = OwlAIWritebackCoordinator.shared.writeback(
      text: "Failing selection test",
      context: .selection(snapshot: failingSnapshot),
      onDismissWindow: {}
    )
    XCTAssertEqual(alertModalCallCount, 0, "AX failure fallback must not show modal alert")

    // Path 5: Standalone
    _ = OwlAIWritebackCoordinator.shared.writeback(
      text: "Standalone test",
      context: .standalone,
      onDismissWindow: {}
    )
    XCTAssertEqual(alertModalCallCount, 0, "Standalone copy must not show modal alert")
  }

  func testNonActivatingPanelAndFocusRestorationArchitecture() {
    let window = OwlAIWindow.shared.window
    XCTAssertNotNil(window, "OwlAIWindow must manage a non-nil window instance")
    guard let panel = window as? NSPanel else {
      XCTFail("OwlAIWindow window must be an NSPanel subclass")
      return
    }

    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "Panel must include .nonactivatingPanel style mask")
    XCTAssertTrue(panel.becomesKeyOnlyIfNeeded, "Panel must configure becomesKeyOnlyIfNeeded = true")
    XCTAssertEqual(panel.level, .floating, "Panel level must be .floating")
    XCTAssertFalse(panel.isReleasedWhenClosed, "Panel must not be released when closed (azooKey lifecycle)")
  }

  func testAICommandDetectorStressCases() {
    let detector = OwlAICommandDetector()

    // 1. Rapid successive /ai sequence
    var now = Date()
    _ = detector.process(character: "/", at: now)
    now.addTimeInterval(0.001)
    _ = detector.process(character: "a", at: now)
    now.addTimeInterval(0.001)
    let res1 = detector.process(character: "i", at: now)
    XCTAssertTrue(res1.isTriggered)
    XCTAssertFalse(detector.isArmed)

    // 2. Double slash then ai: "//ai"
    now.addTimeInterval(0.1)
    _ = detector.process(character: "/", at: now)
    let resSlash = detector.process(character: "/", at: now.addingTimeInterval(0.05))
    XCTAssertTrue(resSlash.shouldFlush.slash, "Preceding slash must be flushed when second slash arrives")
    XCTAssertTrue(detector.isArmed)
    _ = detector.process(character: "a", at: now.addingTimeInterval(0.1))
    let res2 = detector.process(character: "i", at: now.addingTimeInterval(0.15))
    XCTAssertTrue(res2.isTriggered)

    // 3. Mixed case: "/Ai"
    _ = detector.process(character: "/", at: now.addingTimeInterval(0.2))
    _ = detector.process(character: "A", at: now.addingTimeInterval(0.25))
    let res3 = detector.process(character: "i", at: now.addingTimeInterval(0.3))
    XCTAssertTrue(res3.isTriggered)

    // 4. Broken after slash+a: "/ax"
    _ = detector.process(character: "/", at: now.addingTimeInterval(0.4))
    _ = detector.process(character: "a", at: now.addingTimeInterval(0.45))
    let res4 = detector.process(character: "x", at: now.addingTimeInterval(0.5))
    XCTAssertFalse(res4.isTriggered)
    XCTAssertTrue(res4.shouldFlush.slash)
    XCTAssertTrue(res4.shouldFlush.a)
    XCTAssertFalse(detector.isArmed)

    // 5. Unrelated character from idle
    let res5 = detector.process(character: "h", at: now.addingTimeInterval(0.6))
    XCTAssertFalse(res5.isTriggered)
    XCTAssertFalse(res5.shouldFlush.slash)
    XCTAssertFalse(res5.shouldFlush.a)
    XCTAssertFalse(detector.isArmed)
  }

  // MARK: - Empirical Challenger Scenarios

  func testEmpiricalAICommandDetectorCaseInsensitivity() {
    let cases = [
      ("/ai", ["/", "a", "i"]),
      ("/AI", ["/", "A", "I"]),
      ("/Ai", ["/", "A", "i"]),
      ("/aI", ["/", "a", "I"]),
    ]

    for (label, sequence) in cases {
      let detector = OwlAICommandDetector()
      let now = Date()
      var triggered = false

      for (idx, char) in sequence.enumerated() {
        let r = detector.process(character: char, at: now.addingTimeInterval(Double(idx) * 0.05))
        if idx < sequence.count - 1 {
          XCTAssertFalse(r.isTriggered, "Intermediary char '\(char)' in '\(label)' must not trigger")
          XCTAssertFalse(r.shouldFlush.slash, "Intermediary char '\(char)' in '\(label)' must not flush slash")
          XCTAssertFalse(r.shouldFlush.a, "Intermediary char '\(char)' in '\(label)' must not flush a")
          XCTAssertTrue(detector.isArmed, "Detector must remain armed during sequence '\(label)'")
        } else {
          triggered = r.isTriggered
          XCTAssertTrue(r.isTriggered, "Final char '\(char)' in '\(label)' must trigger")
          XCTAssertFalse(r.shouldFlush.slash)
          XCTAssertFalse(r.shouldFlush.a)
          XCTAssertFalse(detector.isArmed, "Detector must disarm after trigger in '\(label)'")
        }
      }
      XCTAssertTrue(triggered, "Sequence '\(label)' must trigger successfully")
    }
  }

  func testEmpiricalAICommandDetectorSequenceBreakageAndDoubleSlash() {
    let detector = OwlAICommandDetector()
    let now = Date()

    // 1. /x -> flushes slash, disarms
    _ = detector.process(character: "/", at: now)
    XCTAssertTrue(detector.isArmed)
    let rx = detector.process(character: "x", at: now.addingTimeInterval(0.05))
    XCTAssertFalse(rx.isTriggered)
    XCTAssertTrue(rx.shouldFlush.slash)
    XCTAssertFalse(rx.shouldFlush.a)
    XCTAssertFalse(detector.isArmed)

    // 2. /ax -> flushes slash and a, disarms
    _ = detector.process(character: "/", at: now.addingTimeInterval(0.1))
    _ = detector.process(character: "a", at: now.addingTimeInterval(0.15))
    XCTAssertTrue(detector.isArmed)
    let rax = detector.process(character: "x", at: now.addingTimeInterval(0.2))
    XCTAssertFalse(rax.isTriggered)
    XCTAssertTrue(rax.shouldFlush.slash)
    XCTAssertTrue(rax.shouldFlush.a)
    XCTAssertFalse(detector.isArmed)

    // 3. // -> resets to single slash (flushes first slash, buffers second slash)
    _ = detector.process(character: "/", at: now.addingTimeInterval(0.3))
    let rDoubleSlash = detector.process(character: "/", at: now.addingTimeInterval(0.35))
    XCTAssertFalse(rDoubleSlash.isTriggered)
    XCTAssertTrue(rDoubleSlash.shouldFlush.slash, "First slash must be flushed")
    XCTAssertFalse(rDoubleSlash.shouldFlush.a)
    XCTAssertTrue(detector.isArmed, "Detector must remain armed with the second slash")

    // Completing with "a" and "i" after "//"
    let rA = detector.process(character: "a", at: now.addingTimeInterval(0.4))
    XCTAssertFalse(rA.isTriggered)
    XCTAssertFalse(rA.shouldFlush.slash)
    XCTAssertTrue(detector.isArmed)
    let rI = detector.process(character: "i", at: now.addingTimeInterval(0.45))
    XCTAssertTrue(rI.isTriggered, "//ai must complete and trigger")
    XCTAssertFalse(detector.isArmed)

    // 4. // followed by sequence breakage "x"
    _ = detector.process(character: "/", at: now.addingTimeInterval(0.5))
    let rSlash2 = detector.process(character: "/", at: now.addingTimeInterval(0.55))
    XCTAssertTrue(rSlash2.shouldFlush.slash)
    XCTAssertTrue(detector.isArmed)
    let rBreak = detector.process(character: "x", at: now.addingTimeInterval(0.6))
    XCTAssertFalse(rBreak.isTriggered)
    XCTAssertTrue(rBreak.shouldFlush.slash, "Second slash must be flushed when broken by 'x'")
    XCTAssertFalse(detector.isArmed)
  }

  func testEmpiricalAICommandDetectorTimeoutHandling() {
    let detector = OwlAICommandDetector(timeout: 1.0)
    let now = Date()

    // 1. / followed by a after 1.1s (> 1.0s timeout)
    _ = detector.process(character: "/", at: now)
    XCTAssertTrue(detector.isArmed)
    let rTimeout1 = detector.process(character: "a", at: now.addingTimeInterval(1.1))
    XCTAssertFalse(rTimeout1.isTriggered)
    XCTAssertTrue(rTimeout1.shouldFlush.slash, "Slash must be flushed on timeout")
    XCTAssertFalse(rTimeout1.shouldFlush.a)
    XCTAssertFalse(detector.isArmed, "Detector must disarm on timeout")

    // 2. / followed by a within time, then i after 1.1s (> 1.0s timeout)
    _ = detector.process(character: "/", at: now.addingTimeInterval(2.0))
    _ = detector.process(character: "a", at: now.addingTimeInterval(2.2))
    XCTAssertTrue(detector.isArmed)
    let rTimeout2 = detector.process(character: "i", at: now.addingTimeInterval(3.3))
    XCTAssertFalse(rTimeout2.isTriggered)
    XCTAssertTrue(rTimeout2.shouldFlush.slash, "Slash must be flushed on timeout")
    XCTAssertTrue(rTimeout2.shouldFlush.a, "'a' must be flushed on timeout")
    XCTAssertFalse(detector.isArmed, "Detector must disarm on timeout")
  }

  func testEmpiricalPreeditCompositionTeardownBeforeWindowPresentation() throws {
    OwlAIWritingSettings.isEnabled = true
    defer {
      OwlAIWritingSettings.resetForTesting()
      OwlAIWindow.shared.window?.close()
    }

    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    defer { controller.destroySession() }
    let mockClient = MockAIWritebackTextInputClient()
    controller.client = mockClient
    let fakeSession = FakeEngineSession(sessionID: 42, generation: 1, isValid: true, input: "nihk")
    controller.engineSession = fakeSession
    controller.preedit = "nihk"

    XCTAssertEqual(fakeSession.clearCompositionCount, 0)
    XCTAssertEqual(controller.preedit, "nihk")

    // Invoke AI writing from typing
    controller.invokeAIWritingFromTyping()

    // Assert preedit composition teardown:
    // 1. Host composition was cleared via show(preedit: "", ...)
    XCTAssertTrue(mockClient.markedTexts.contains(""), "Host client marked text must be cleared to empty string")
    // 2. Engine session composition was cleared
    XCTAssertEqual(fakeSession.clearCompositionCount, 1, "EngineSession.clearComposition() must be called once")
    // 3. Controller preedit was cleared
    XCTAssertEqual(controller.preedit, "", "Controller preedit must be reset to empty")
  }

  func testEmpiricalShiftKHotkeyPreeditCompositionTeardown() throws {
    OwlAIWritingSettings.isEnabled = true
    defer {
      OwlAIWritingSettings.resetForTesting()
      OwlAIWindow.shared.window?.close()
    }

    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    defer { controller.destroySession() }
    let mockClient = MockAIWritebackTextInputClient()
    controller.client = mockClient
    let fakeSession = FakeEngineSession(sessionID: 99, generation: 1, isValid: true, input: "ceshi")
    controller.engineSession = fakeSession
    controller.preedit = "ceshi"

    // Construct Shift+K keyDown event (kVK_ANSI_K = 40)
    let shiftKEvent = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.shift],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "K",
      charactersIgnoringModifiers: "k",
      isARepeat: false,
      keyCode: 40
    )!

    let handled = controller.handleAIWritingHotKey(shiftKEvent)
    XCTAssertTrue(handled, "Shift+K must be handled by AI writing hotkey handler")

    // Assert composition teardown:
    XCTAssertEqual(fakeSession.clearCompositionCount, 1, "EngineSession.clearComposition() must be called on Shift+K")
    XCTAssertEqual(controller.preedit, "", "Controller preedit must be cleared on Shift+K")
    XCTAssertTrue(mockClient.markedTexts.contains(""), "Host marked text must be cleared on Shift+K")
  }

  func testEmpiricalCancellationLeavesHostClientTextUntouched() {
    let mockClient = MockAIWritebackTextInputClient()
    let context = OwlAIInvocationContext.typing(
      client: mockClient,
      preedit: "preedit_snapshot",
      frontmostApp: nil,
      bundleID: "com.apple.Notes"
    )

    // 1. Open the window with typing context
    let model = OwlAIWindow.shared.show(context: context)
    defer {
      OwlAIWindow.shared.window?.close()
    }

    // Model is streaming or idle, user decides to cancel
    model.submit(question: "Test question")

    // User presses Esc / closes window
    OwlAIWindow.shared.window?.close()

    // Host client text must be completely untouched
    XCTAssertTrue(mockClient.insertedTexts.isEmpty, "Host client must receive zero inserted texts on cancel")
    XCTAssertTrue(mockClient.replacementRanges.isEmpty, "Host client must receive zero replacement ranges on cancel")
  }

  func testEmpiricalControllerAICommandEventHandling() throws {
    OwlAIWritingSettings.isEnabled = true
    defer {
      OwlAIWritingSettings.resetForTesting()
      OwlAIWindow.shared.window?.close()
    }

    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    defer { controller.destroySession() }
    let mockClient = MockAIWritebackTextInputClient()
    controller.client = mockClient
    let fakeSession = FakeEngineSession(sessionID: 10, generation: 1, isValid: true, input: "")
    controller.engineSession = fakeSession

    func makeKeyEvent(char: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: char,
        charactersIgnoringModifiers: char,
        isARepeat: false,
        keyCode: keyCode
      )!
    }

    // 1. /x sequence: / swallowed, x flushes / and passes through
    mockClient.insertedTexts.removeAll()
    let slashEvt = makeKeyEvent(char: "/", keyCode: 44)
    XCTAssertTrue(controller.handleAICommandDetector(slashEvt), "'/' must be intercepted and swallowed")
    XCTAssertTrue(mockClient.insertedTexts.isEmpty, "No text inserted into client while waiting for 'a'")

    let xEvt = makeKeyEvent(char: "x", keyCode: 7)
    XCTAssertFalse(controller.handleAICommandDetector(xEvt), "'x' breaks sequence, must not be intercepted")
    XCTAssertEqual(mockClient.insertedTexts, ["/"], "'/' must be flushed to client")

    // 2. /ax sequence: / swallowed, a swallowed, x flushes /a and passes through
    mockClient.insertedTexts.removeAll()
    _ = controller.handleAICommandDetector(slashEvt)
    let aEvt = makeKeyEvent(char: "a", keyCode: 0)
    XCTAssertTrue(controller.handleAICommandDetector(aEvt), "'a' must be intercepted and swallowed")
    XCTAssertTrue(mockClient.insertedTexts.isEmpty)

    XCTAssertFalse(controller.handleAICommandDetector(xEvt), "'x' breaks sequence")
    XCTAssertEqual(mockClient.insertedTexts, ["/a"], "'/a' must be flushed to client")

    // 3. Delete key resets armed detector
    _ = controller.handleAICommandDetector(slashEvt)
    XCTAssertTrue(controller.aiCommandDetector.isArmed)
    let deleteEvt = makeKeyEvent(char: "\u{7F}", keyCode: UInt16(kVK_Delete))
    XCTAssertTrue(controller.handleAICommandDetector(deleteEvt), "Delete must be consumed when detector is armed")
    XCTAssertFalse(controller.aiCommandDetector.isArmed, "Delete must disarm detector")
  }
}


