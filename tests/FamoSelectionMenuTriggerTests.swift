//
//  FamoSelectionMenuTriggerTests.swift
//  FamoTests
//
//  划词菜单事件驱动触发判定（2026-07-21 轮询卡顿修复）：150ms 常轮询已删，改为「划选结束」
//  事件触发。isSelectionEndTrigger 是纯函数，这里锁死它的判定表。
//

import XCTest
@testable import Famo

final class FamoSelectionMenuTriggerTests: XCTestCase {
  func testLeftMouseUpAlwaysTriggers() {
    // 拖选/双击/三击放手都是 mouseUp；shift-click 扩选放手时 shift 仍按着，也要触发。
    XCTAssertTrue(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .leftMouseUp, flags: []))
    XCTAssertTrue(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .leftMouseUp, flags: [.shift]))
  }

  func testFlagsChangedTriggersOnlyWhenAllSelectionModifiersReleased() {
    // shift+方向 / ⌘A 收尾＝最后一个修饰键松开的那次 flagsChanged。
    XCTAssertTrue(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .flagsChanged, flags: []))
    // 修饰键按下（或还剩别的修饰键没松）不触发。
    XCTAssertFalse(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .flagsChanged, flags: [.shift]))
    XCTAssertFalse(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .flagsChanged, flags: [.command]))
    XCTAssertFalse(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .flagsChanged, flags: [.shift, .command]))
    // capsLock 之类的非划选修饰键不挡触发。
    XCTAssertTrue(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .flagsChanged, flags: [.capsLock]))
  }

  func testOtherEventsNeverTrigger() {
    XCTAssertFalse(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .keyDown, flags: []))
    XCTAssertFalse(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .leftMouseDown, flags: []))
    XCTAssertFalse(FamoSelectionMenuCoordinator.isSelectionEndTrigger(type: .rightMouseUp, flags: []))
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
  /// 脚本化 `FamoConversationStreaming`：要么吐一串 delta，要么以 readiness 失败。formatter 只用 stream()。
  /// 协议是 @MainActor，嵌套类型不继承外层隔离，故须显式标注。
  @MainActor
  private final class ScriptedStreamer: FamoConversationStreaming {
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
