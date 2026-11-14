//
//  OwlSelectionMenuTriggerTests.swift
//  OwltypeTests
//
//  划词工具箱触发判定（2026-07-26 重设计）：「选中即自动弹出」管线已删（isSelectionEndTrigger
//  判定表随之退役），唯一手势 = 选中后双击 ⌥。OwlOptionDoubleTapDetector 是纯状态机（事件与
//  时间戳全注入），这里锁死它的判定表：轻击×2 触发；长按、间隔超时、组合键、键鼠插入都不触发。
//

import XCTest
@testable import Owltype

final class OwlOptionDoubleTapDetectorTests: XCTestCase {
  private let t0 = Date(timeIntervalSinceReferenceDate: 10_000)
  private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

  func testQuickDoubleTapFiresOnSecondRelease() {
    var d = OwlOptionDoubleTapDetector()
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0)))      // 第一击按下
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.1)))           // 第一击松开
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0.3)))    // 第二击按下
    XCTAssertTrue(d.processFlagsChanged([], at: at(0.4)), "第二击松开的瞬间触发")
  }

  func testFireResetsSoThirdTapStartsAFreshPair() {
    var d = OwlOptionDoubleTapDetector()
    _ = d.processFlagsChanged([.option], at: at(0))
    _ = d.processFlagsChanged([], at: at(0.1))
    _ = d.processFlagsChanged([.option], at: at(0.2))
    XCTAssertTrue(d.processFlagsChanged([], at: at(0.3)))
    // 触发后回 idle：紧接着的第三击只是新序列的第一击，不得连发。
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0.4)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.5)))
  }

  func testSlowGapDoesNotFire() {
    let tapMaxGap: TimeInterval = 0.45
    var d = OwlOptionDoubleTapDetector()
    _ = d.processFlagsChanged([.option], at: at(0))
    _ = d.processFlagsChanged([], at: at(0.1))
    // 间隔超过 tapMaxGap：第二次按下降级为新的第一击。
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0.1 + tapMaxGap + 0.05)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.1 + tapMaxGap + 0.15)))
  }

  func testLongHoldIsNotATap() {
    let tapMaxHold: TimeInterval = 0.5
    var d = OwlOptionDoubleTapDetector()
    // 第一击按住超时（按住 ⌥ 拖选/等组合键的形态）→ 松开不算轻击。
    _ = d.processFlagsChanged([.option], at: at(0))
    XCTAssertFalse(d.processFlagsChanged([], at: at(tapMaxHold + 0.1)))
    _ = d.processFlagsChanged([.option], at: at(1.0))
    XCTAssertFalse(d.processFlagsChanged([], at: at(1.1)), "前一击已作废，这只是新序列的第一击")

    // 第二击按住超时同样作废。
    var d2 = OwlOptionDoubleTapDetector()
    _ = d2.processFlagsChanged([.option], at: at(0))
    _ = d2.processFlagsChanged([], at: at(0.1))
    _ = d2.processFlagsChanged([.option], at: at(0.2))
    XCTAssertFalse(d2.processFlagsChanged([], at: at(0.2 + tapMaxHold + 0.1)))
  }

  func testOtherModifierAbortsTheGesture() {
    var d = OwlOptionDoubleTapDetector()
    _ = d.processFlagsChanged([.option], at: at(0))
    // ⌥ 还按着又加了 ⇧（⌥⇧ 组合）：整个手势作废，随后的松开也不触发。
    XCTAssertFalse(d.processFlagsChanged([.option, .shift], at: at(0.1)))
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0.2)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.3)), "作废后这只是第一击的收尾，不得触发")
  }

  func testKeyOrMouseBetweenTapsInvalidates() {
    var d = OwlOptionDoubleTapDetector()
    _ = d.processFlagsChanged([.option], at: at(0))
    _ = d.processFlagsChanged([], at: at(0.1))
    d.invalidate()  // 两击之间来了键盘/鼠标事件（⌥ 在被当真修饰键用）
    _ = d.processFlagsChanged([.option], at: at(0.2))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.3)), "被作废后重按只是新的第一击")
  }

  func testCapsLockFlagDoesNotInterfere() {
    var d = OwlOptionDoubleTapDetector()
    // capsLock 位随事件带着不影响判定（与旧划选判定同口径：只看四大修饰键）。
    XCTAssertFalse(d.processFlagsChanged([.option, .capsLock], at: at(0)))
    XCTAssertFalse(d.processFlagsChanged([.capsLock], at: at(0.1)))
    XCTAssertFalse(d.processFlagsChanged([.option, .capsLock], at: at(0.2)))
    XCTAssertTrue(d.processFlagsChanged([.capsLock], at: at(0.3)))
  }

  func testLoneOtherModifierNeverFires() {
    var d = OwlOptionDoubleTapDetector()
    // 双击 ⇧（中英切换的手势域）绝不能串进来。
    XCTAssertFalse(d.processFlagsChanged([.shift], at: at(0)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.1)))
    XCTAssertFalse(d.processFlagsChanged([.shift], at: at(0.2)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.3)))
  }
}

// MARK: - 规范排版：确定性规则（纯函数，无偏好域 / 无网络，零污染）

final class OwlChineseTypesettingTests: XCTestCase {
  func testPreCleanStripsTrailingSpaceAndCollapsesBlankLines() {
    XCTAssertEqual(OwlChineseTypesetting.preClean("a  \n\n\n\nb  "), "a\n\nb")
  }
}

// MARK: - 规范排版：执行体（脚本化假流，验证规则优先 + 指纹护栏）

@MainActor
final class OwlSelectionPublishFormatterTests: XCTestCase {
  /// 脚本化 `OwlPlainStreaming`：要么吐一串 delta，要么以 readiness 失败。formatter 只用 stream()。
  /// 协议是 @MainActor，嵌套类型不继承外层隔离，故须显式标注。
  @MainActor
  private final class ScriptedStreamer: OwlPlainStreaming {
    enum Mode { case deltas([String]); case fail(OwlStreamingReadiness) }
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }

    func stream(
      messages: [OwlDeepSeekMessage]
    ) -> Result<AsyncThrowingStream<String, Error>, OwlStreamingReadiness> {
      switch mode {
      case .fail(let r):
        return .failure(r)
      case .deltas(let deltas):
        return .success(AsyncThrowingStream { continuation in
          for d in deltas { continuation.yield(d) }
          continuation.finish()
        })
      }
    }
  }

  func testReflowThenDeterministicNormalize() async throws {
    // AI 只合并硬换行、原样保留半角标点；规则最后一道把标点规范成全角。
    let input = "这是一段被硬换行\n拆断的文字,\n应该合并."
    let streamer = ScriptedStreamer(.deltas(["这是一段被硬换行拆断的文字,应该合并."]))
    let result = try await OwlSelectionPublishFormatter(streamer: streamer).generateReplacement(for: input)
    XCTAssertEqual(result, "这是一段被硬换行拆断的文字，应该合并。")
  }

  func testFingerprintGuardRejectsAITampering() async throws {
    // 模型擅自加了一句 → 指纹不符 → 丢弃 AI 结果、回退纯规则（预清洗后的原文）。
    let input = "原文内容。"
    let streamer = ScriptedStreamer(.deltas(["原文内容。这是模型擅自加的一句。"]))
    let result = try await OwlSelectionPublishFormatter(streamer: streamer).generateReplacement(for: input)
    XCTAssertEqual(result, "原文内容。")
    XCTAssertFalse(result.contains("擅自"), "AI 篡改的内容不得进入替换结果")
  }

  func testProviderUnavailableThrows() async {
    let streamer = ScriptedStreamer(.fail(.unconfigured))
    do {
      _ = try await OwlSelectionPublishFormatter(streamer: streamer).generateReplacement(for: "文本")
      XCTFail("供应商不可用时应抛错")
    } catch let error as OwlSelectionPublishFormattingError {
      XCTAssertEqual(error, .providerUnavailable)
    } catch {
      XCTFail("应抛 OwlSelectionPublishFormattingError.providerUnavailable，实际：\(error)")
    }
  }
}
