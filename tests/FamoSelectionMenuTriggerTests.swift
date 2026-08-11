//
//  FamoSelectionMenuTriggerTests.swift
//  FamoTests
//
//  划词工具箱触发判定（2026-07-26 重设计）：「选中即自动弹出」管线已删（isSelectionEndTrigger
//  判定表随之退役），唯一手势 = 选中后双击 ⌥。FamoOptionDoubleTapDetector 是纯状态机（事件与
//  时间戳全注入），这里锁死它的判定表：轻击×2 触发；长按、间隔超时、组合键、键鼠插入都不触发。
//

import XCTest
@testable import Famo

final class FamoOptionDoubleTapDetectorTests: XCTestCase {
  private let t0 = Date(timeIntervalSinceReferenceDate: 10_000)
  private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

  func testQuickDoubleTapFiresOnSecondRelease() {
    var d = FamoOptionDoubleTapDetector()
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0)))      // 第一击按下
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.1)))           // 第一击松开
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0.3)))    // 第二击按下
    XCTAssertTrue(d.processFlagsChanged([], at: at(0.4)), "第二击松开的瞬间触发")
  }

  func testFireResetsSoThirdTapStartsAFreshPair() {
    var d = FamoOptionDoubleTapDetector()
    _ = d.processFlagsChanged([.option], at: at(0))
    _ = d.processFlagsChanged([], at: at(0.1))
    _ = d.processFlagsChanged([.option], at: at(0.2))
    XCTAssertTrue(d.processFlagsChanged([], at: at(0.3)))
    // 触发后回 idle：紧接着的第三击只是新序列的第一击，不得连发。
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0.4)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.5)))
  }

  func testSlowGapDoesNotFire() {
    var d = FamoOptionDoubleTapDetector()
    _ = d.processFlagsChanged([.option], at: at(0))
    _ = d.processFlagsChanged([], at: at(0.1))
    // 间隔超过 tapMaxGap：第二次按下降级为新的第一击。
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0.1 + FamoOptionDoubleTapDetector.tapMaxGap + 0.05)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.1 + FamoOptionDoubleTapDetector.tapMaxGap + 0.15)))
  }

  func testLongHoldIsNotATap() {
    var d = FamoOptionDoubleTapDetector()
    // 第一击按住超时（按住 ⌥ 拖选/等组合键的形态）→ 松开不算轻击。
    _ = d.processFlagsChanged([.option], at: at(0))
    XCTAssertFalse(d.processFlagsChanged([], at: at(FamoOptionDoubleTapDetector.tapMaxHold + 0.1)))
    _ = d.processFlagsChanged([.option], at: at(1.0))
    XCTAssertFalse(d.processFlagsChanged([], at: at(1.1)), "前一击已作废，这只是新序列的第一击")

    // 第二击按住超时同样作废。
    var d2 = FamoOptionDoubleTapDetector()
    _ = d2.processFlagsChanged([.option], at: at(0))
    _ = d2.processFlagsChanged([], at: at(0.1))
    _ = d2.processFlagsChanged([.option], at: at(0.2))
    XCTAssertFalse(d2.processFlagsChanged([], at: at(0.2 + FamoOptionDoubleTapDetector.tapMaxHold + 0.1)))
  }

  func testOtherModifierAbortsTheGesture() {
    var d = FamoOptionDoubleTapDetector()
    _ = d.processFlagsChanged([.option], at: at(0))
    // ⌥ 还按着又加了 ⇧（⌥⇧ 组合）：整个手势作废，随后的松开也不触发。
    XCTAssertFalse(d.processFlagsChanged([.option, .shift], at: at(0.1)))
    XCTAssertFalse(d.processFlagsChanged([.option], at: at(0.2)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.3)), "作废后这只是第一击的收尾，不得触发")
  }

  func testKeyOrMouseBetweenTapsInvalidates() {
    var d = FamoOptionDoubleTapDetector()
    _ = d.processFlagsChanged([.option], at: at(0))
    _ = d.processFlagsChanged([], at: at(0.1))
    d.invalidate()  // 两击之间来了键盘/鼠标事件（⌥ 在被当真修饰键用）
    _ = d.processFlagsChanged([.option], at: at(0.2))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.3)), "被作废后重按只是新的第一击")
  }

  func testCapsLockFlagDoesNotInterfere() {
    var d = FamoOptionDoubleTapDetector()
    // capsLock 位随事件带着不影响判定（与旧划选判定同口径：只看四大修饰键）。
    XCTAssertFalse(d.processFlagsChanged([.option, .capsLock], at: at(0)))
    XCTAssertFalse(d.processFlagsChanged([.capsLock], at: at(0.1)))
    XCTAssertFalse(d.processFlagsChanged([.option, .capsLock], at: at(0.2)))
    XCTAssertTrue(d.processFlagsChanged([.capsLock], at: at(0.3)))
  }

  func testLoneOtherModifierNeverFires() {
    var d = FamoOptionDoubleTapDetector()
    // 双击 ⇧（中英切换的手势域）绝不能串进来。
    XCTAssertFalse(d.processFlagsChanged([.shift], at: at(0)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.1)))
    XCTAssertFalse(d.processFlagsChanged([.shift], at: at(0.2)))
    XCTAssertFalse(d.processFlagsChanged([], at: at(0.3)))
  }
}

// MARK: - 规范排版：确定性规则（纯函数，无偏好域 / 无网络，零污染）

final class FamoChineseTypesettingTests: XCTestCase {
  func testStraightQuotesPairIntoCurly() {
    XCTAssertEqual(FamoChineseTypesetting.normalizeQuotes("选\"甲\"与'乙'"), "选“甲”与‘乙’")
  }

  func testAsciiApostropheInContractionPreserved() {
    // don't / O'Brien 的撇号是 ASCII 字母之间，保留；不要误当中文引号翻卷。
    XCTAssertEqual(FamoChineseTypesetting.normalizeQuotes("don't 与 O'Brien"), "don't 与 O'Brien")
  }

  func testCornerQuotesFoldToMainland() {
    XCTAssertEqual(FamoChineseTypesetting.normalizeQuotes("「书名」『篇』"), "“书名”‘篇’")
  }

  func testPunctuationWidthOnlyBesideCJK() {
    XCTAssertEqual(FamoChineseTypesetting.normalizePunctuationWidth("中文,句号."), "中文，句号。")
    XCTAssertEqual(FamoChineseTypesetting.normalizePunctuationWidth("确定(是)吗"), "确定（是）吗")
    // 拉丁 / 数字语境的半角不动：小数点、缩写点、千分位。
    XCTAssertEqual(FamoChineseTypesetting.normalizePunctuationWidth("iOS 18.5"), "iOS 18.5")
    XCTAssertEqual(FamoChineseTypesetting.normalizePunctuationWidth("e.g. test"), "e.g. test")
    XCTAssertEqual(FamoChineseTypesetting.normalizePunctuationWidth("共 1,000 元"), "共 1,000 元")
  }

  func testEllipsisAndDash() {
    XCTAssertEqual(FamoChineseTypesetting.normalizeEllipsisAndDash("等等..."), "等等……")
    XCTAssertEqual(FamoChineseTypesetting.normalizeEllipsisAndDash("啊。。。"), "啊……")
    XCTAssertEqual(FamoChineseTypesetting.normalizeEllipsisAndDash("范围--结束"), "范围——结束")
    XCTAssertEqual(FamoChineseTypesetting.normalizeEllipsisAndDash("他—说"), "他——说")
    // 单个 ASCII 连字符 / 数字区间不动。
    XCTAssertEqual(FamoChineseTypesetting.normalizeEllipsisAndDash("2020-2021"), "2020-2021")
  }

  func testSpaceRemovalCJKCJKAndDigitsStayTight() {
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("中 文 字"), "中文字")
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("共 3 人"), "共3人")   // CJK↔数字不留空
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("第3条"), "第3条")
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("hello world"), "hello world")
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("a  b"), "a b")
  }

  func testPanguSpacingBetweenCJKAndLatinLetters() {
    // 盘古之白：中文与英文字母之间恰好一个空格——原文缺空格要补、有空格要留、多空格要并。
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("看iOS系统"), "看 iOS 系统")
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("看 iOS 系统"), "看 iOS 系统")
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("看  iOS  系统"), "看 iOS 系统")
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("基于GPT架构"), "基于 GPT 架构")
    XCTAssertEqual(FamoChineseTypesetting.normalizeSpaces("详见See id."), "详见 See id.")
  }

  func testPreCleanStripsTrailingSpaceAndCollapsesBlankLines() {
    XCTAssertEqual(FamoChineseTypesetting.preClean("a  \n\n\n\nb  "), "a\n\nb")
  }

  func testContentFingerprintIgnoresPunctuationAndWhitespace() {
    XCTAssertEqual(
      FamoChineseTypesetting.contentFingerprint("你好，world 123！"),
      FamoChineseTypesetting.contentFingerprint("你好world123")
    )
    XCTAssertNotEqual(
      FamoChineseTypesetting.contentFingerprint("原文内容"),
      FamoChineseTypesetting.contentFingerprint("原文内容多一句")
    )
  }

  func testFinalizeNeverChangesContentFingerprint() {
    // 规范化只动标点形态与空白，绝不动文字——这条不变式是「排版绝不改字」的机械保证。
    let messy = "他说\"你好\",这是...一段  测试文字—end。看 iOS 好"
    XCTAssertEqual(
      FamoChineseTypesetting.contentFingerprint(FamoChineseTypesetting.finalize(messy)),
      FamoChineseTypesetting.contentFingerprint(messy)
    )
  }
}

// MARK: - 规范排版：执行体（脚本化假流，验证规则优先 + 指纹护栏）

@MainActor
final class FamoSelectionPublishFormatterTests: XCTestCase {
  /// 脚本化 `FamoPlainStreaming`：要么吐一串 delta，要么以 readiness 失败。formatter 只用 stream()。
  /// 协议是 @MainActor，嵌套类型不继承外层隔离，故须显式标注。
  @MainActor
  private final class ScriptedStreamer: FamoPlainStreaming {
    enum Mode { case deltas([String]); case fail(FamoStreamingReadiness) }
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }

    func readiness() -> FamoStreamingReadiness { .unconfigured }  // 未被 formatter 调用

    func stream(
      messages: [FamoDeepSeekMessage]
    ) -> Result<AsyncThrowingStream<String, Error>, FamoStreamingReadiness> {
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
    let result = try await FamoSelectionPublishFormatter(streamer: streamer).generateReplacement(for: input)
    XCTAssertEqual(result, "这是一段被硬换行拆断的文字，应该合并。")
  }

  func testFingerprintGuardRejectsAITampering() async throws {
    // 模型擅自加了一句 → 指纹不符 → 丢弃 AI 结果、回退纯规则（预清洗后的原文）。
    let input = "原文内容。"
    let streamer = ScriptedStreamer(.deltas(["原文内容。这是模型擅自加的一句。"]))
    let result = try await FamoSelectionPublishFormatter(streamer: streamer).generateReplacement(for: input)
    XCTAssertEqual(result, "原文内容。")
    XCTAssertFalse(result.contains("擅自"), "AI 篡改的内容不得进入替换结果")
  }

  func testProviderUnavailableThrows() async {
    let streamer = ScriptedStreamer(.fail(.unconfigured))
    do {
      _ = try await FamoSelectionPublishFormatter(streamer: streamer).generateReplacement(for: "文本")
      XCTFail("供应商不可用时应抛错")
    } catch let error as FamoSelectionPublishFormattingError {
      XCTAssertEqual(error, .providerUnavailable)
    } catch {
      XCTFail("应抛 FamoSelectionPublishFormattingError.providerUnavailable，实际：\(error)")
    }
  }
}
