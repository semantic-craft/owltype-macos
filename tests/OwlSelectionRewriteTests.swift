import XCTest
@testable import Owltype

@MainActor
final class OwlSelectionRewriteTests: XCTestCase {
  private let actions: [OwlSelectionMenuAction] = [.polish, .promptOptimize, .goalBrief, .publishFormatting]

  func testEveryRewriteConfirmsBeforeDeliveryAndReportsItsOutcome() async {
    for action in actions {
      var events: [String] = []
      await OwlSelectionRewrite(
        generate: { received, text in
          XCTAssertEqual(received, action)
          XCTAssertEqual(text, "原文")
          events.append("generate")
          return .ready("改写")
        },
        confirm: { text, _ in XCTAssertEqual(text, "改写"); events.append("confirm"); return true },
        deliver: { text in XCTAssertEqual(text, "改写"); events.append("deliver"); return .inserted(.axSelectedText) },
        clarify: { _, _ in XCTFail("Unexpected clarification") },
        notify: { events.append($0) }
      ).run(action, text: "原文")
      XCTAssertEqual(Array(events.dropFirst().dropLast()), ["generate", "confirm", "deliver"])
      XCTAssertTrue(events.last?.hasPrefix("已替换") == true)
    }
  }

  func testDeclinedConfirmationNeverDeliversForAnyRewrite() async {
    for action in actions {
      var messages: [String] = []
      await OwlSelectionRewrite(
        generate: { _, _ in .ready("改写") }, confirm: { _, _ in false },
        deliver: { _ in XCTFail("Cancelled rewrite must not deliver"); return .inserted(.axSelectedText) },
        clarify: { _, _ in XCTFail("Unexpected clarification") }, notify: { messages.append($0) }
      ).run(action, text: "原文")
      XCTAssertEqual(messages.last, "已取消替换。")
    }
  }

  func testClarificationPreservesOriginalTextWithoutConfirmationOrDelivery() async {
    let task = OwlAIComposerTask(label: "补充信息", clarifications: ["用途？"], placeholder: "回答", scaffold: "指令")
    var receivedText: String?
    var receivedTask: OwlAIComposerTask?
    await OwlSelectionRewrite(
      generate: { _, _ in .clarification(task) },
      confirm: { _, _ in XCTFail("Clarification must not confirm a replacement"); return true },
      deliver: { _ in XCTFail("Clarification must not deliver"); return .inserted(.axSelectedText) },
      clarify: { receivedText = $0; receivedTask = $1 }, notify: { _ in }
    ).run(.promptOptimize, text: "原文")
    XCTAssertEqual(receivedText, "原文")
    XCTAssertEqual(receivedTask, task)
  }

  func testClipboardAndFailureAreNotReportedAsInsertion() async {
    for outcome in [OwlInsertOutcome.copiedToClipboard, .failed("无法定位原选区")] {
      var messages: [String] = []
      await OwlSelectionRewrite(
        generate: { _, _ in .ready("改写") }, confirm: { _, _ in true }, deliver: { _ in outcome },
        clarify: { _, _ in XCTFail("Unexpected clarification") }, notify: { messages.append($0) }
      ).run(.polish, text: "原文")
      XCTAssertEqual(messages.last, outcome == .copiedToClipboard ? "已复制改写，⌘V 替换" : "无法定位原选区")
    }
  }

  func testCancellationAndGenerationFailureNeverConfirmOrDeliver() async {
    for cancelled in [true, false] {
      var messages: [String] = []
      await OwlSelectionRewrite(
        generate: { _, _ in
          if cancelled { throw CancellationError() }
          throw NSError(domain: "test", code: 1)
        },
        confirm: { _, _ in XCTFail("Failed generation must not confirm"); return true },
        deliver: { _ in XCTFail("Failed generation must not deliver"); return .inserted(.axSelectedText) },
        clarify: { _, _ in XCTFail("Unexpected clarification") }, notify: { messages.append($0) }
      ).run(.polish, text: "原文")
      XCTAssertEqual(messages.count, cancelled ? 1 : 2)
    }
  }

  func testCancellationAfterGenerationPreventsPreview() async {
    var messages: [String] = []
    let task = Task { @MainActor in
      await OwlSelectionRewrite(
        generate: { _, _ in
          withUnsafeCurrentTask { $0?.cancel() }
          return .ready("迟到的改写")
        },
        confirm: { _, _ in XCTFail("Cancelled task must not preview"); return true },
        deliver: { _ in XCTFail("Cancelled task must not deliver"); return .inserted(.axSelectedText) },
        clarify: { _, _ in XCTFail("Unexpected clarification") }, notify: { messages.append($0) }
      ).run(.goalBrief, text: "原文")
    }
    await task.value
    XCTAssertEqual(messages, ["正在整理任务书…"])
  }
}
