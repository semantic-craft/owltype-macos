//
//  FamoSkillsLiveTests.swift
//  FamoTests — 全部 AI 技能对阿里云百炼的「实盘」验收
//
//  与 `FamoPromptOptimizeLiveTests` 同一契约：**默认跳过**，仅当 `~/.famo-test-key`（仓库外）
//  存在时才跑。目的不是回归（离线套件管回归），而是回答「每个 AI 技能在真实供应商上到底
//  能不能达到预期效果」——mock 喂的永远是我们自己想象的响应形状。
//
//  覆盖的四条真实链路（提示词优化已在 FamoPromptOptimizeLiveTests）：
//    A. SSE 流式（FamoStreamingChatClient）—— 翻译 / 润色·多版本 / 润色·仿范例 / 公文排版 /
//       辅助检索共用的传输，逐技能用真实 prompt 打，断言产出符合各自的输出契约。
//    B. 任意提问·联网搜索 —— 同一流式客户端 + qwen 的 enable_search extraBody。
//    C. 划词润色（FamoSelectionPolishClient）—— 非流式 json_object 候选契约，v1/v2 变体各一发。
//    D. 来源核验（FamoSourceVerificationService）—— DashScope 原生 generation 端点 +
//       forced_search/enable_source，与其他技能完全不同的一条 wire。
//

import Foundation
import XCTest

@testable import Famo

@MainActor
final class FamoSkillsLiveTests: XCTestCase {

  private static let endpoint = URL(
    string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
  private static let model = "qwen3.6-flash"

  private var routing: FamoCloudRouting {
    FamoCloudRouting(
      providerID: "qwen", endpoint: Self.endpoint, model: Self.model,
      secretName: "famo.live.test", authHeaderStyle: .bearer)
  }

  private func testAPIKey() throws -> String {
    let path = ("~/.famo-test-key" as NSString).expandingTildeInPath
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw XCTSkip("无 ~/.famo-test-key，跳过实盘测试（离线套件不受影响）")
    }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty { throw XCTSkip("~/.famo-test-key 为空，跳过实盘测试") }
    return key
  }

  override func setUp() async throws {
    try await super.setUp()
    FamoCloudPreferences.resetForTesting()
    FamoExperimentalPreferences.resetForTesting()
  }

  override func tearDown() async throws {
    FamoCloudPreferences.resetForTesting()
    FamoExperimentalPreferences.resetForTesting()
    try await super.tearDown()
  }

  /// 消费整条 SSE 流为完整回答；落盘供人工核对。qwen3.6-flash 有静默推理段，上限放宽到 90s。
  private func streamAnswer(
    question: String, selectedText: String? = nil,
    extraBody: [String: Any] = [:], label: String
  ) async throws -> String {
    let apiKey = try testAPIKey()
    let client = FamoStreamingChatClient(timeout: 90)
    let messages = FamoAIContextAssembler.assemble(
      selectedText: selectedText, question: question)

    var answer = ""
    for try await delta in client.stream(
      messages: messages, routing: routing, apiKey: apiKey, extraBody: extraBody) {
      answer += delta
    }
    try? answer.write(
      toFile: "/tmp/famo-skill-\(label).txt", atomically: true, encoding: .utf8)
    return answer
  }

  // MARK: - A. 流式窗口技能（各自的输出契约）

  func testTranslateSkillTurnsChineseIntoEnglishOnly() async throws {
    let answer = try await streamAnswer(
      question: FamoSelectionSkillPrompts.translationQuestion,
      selectedText: "本院认为，双方当事人签订的买卖合同系真实意思表示，合法有效。",
      label: "translate")

    XCTAssertFalse(answer.isEmpty)
    XCTAssertNotNil(
      answer.range(of: "[A-Za-z]{4,}", options: .regularExpression),
      "中文选区应译成英文")
    XCTAssertFalse(answer.contains("```"), "契约要求不使用 Markdown 代码块")
    XCTAssertFalse(
      answer.contains("直译") || answer.contains("反思"),
      "内部三步法不得泄漏到输出（只输出最终意译）")
  }

  // 公文排版 / 润色·多版本挑选 / 润色·仿我的范例 的活体契约测试已随技能删除（2026-07-26 技能
  // 精简）：个性化加工由「任意提问」对选区直接下指令兜底，没有固定输出契约可断言。

  func testResearchAssistSkillReturnsSearchPlan() async throws {
    let answer = try await streamAnswer(
      question: FamoSelectionSkillPrompts.researchAssistQuestion,
      selectedText: "夫妻共同债务的认定标准",
      label: "research")

    XCTAssertFalse(answer.isEmpty)
    XCTAssertTrue(
      answer.contains("检索") || answer.contains("关键词"),
      "辅助检索应产出可复制的检索方案")
  }

  // MARK: - B. 任意提问 · 联网搜索（qwen enable_search）

  func testAskWithWebSearchStreamsAnAnswer() async throws {
    let extraBody = FamoSearchControl.extraBody(
      providerID: "qwen", host: Self.endpoint.host ?? "")
    XCTAssertEqual(extraBody["enable_search"] as? Bool, true, "qwen 联网走顶层 enable_search")

    let answer = try await streamAnswer(
      question: "最高人民法院现任院长是谁？只答姓名与就任年份。",
      extraBody: extraBody,
      label: "websearch")

    XCTAssertFalse(answer.isEmpty, "联网搜索路由下必须仍能流式出答案")
  }

  // MARK: - C. 划词润色（非流式 json_object 候选契约，v1 / v2 变体）

  func testSelectionPolishReturnsRewritesOnBothPromptVariants() async throws {
    let apiKey = try testAPIKey()

    for variantID in [
      FamoPolishPromptCatalog.legacyVariantID,
      FamoPolishPromptCatalog.responsayAlignedVariantID
    ] {
      FamoExperimentalPreferences.selectionPolishPromptVariant = variantID
      let client = FamoSelectionPolishClient(
        endpoint: Self.endpoint, model: Self.model, authHeaderStyle: .bearer)
      let rewrites = try await client.fetchPolishedRewrites(
        for: "这个事情我们得赶紧弄一下，不然要出问题。", apiKey: apiKey)

      XCTAssertFalse(rewrites.isEmpty, "变体 \(variantID) 未产出任何改写")
      XCTAssertFalse(
        rewrites[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "变体 \(variantID) 首个改写为空")
      try? rewrites.joined(separator: "\n---\n").write(
        toFile: "/tmp/famo-skill-polish-\(variantID).txt", atomically: true, encoding: .utf8)
    }
  }

  // MARK: - D. 来源核验（DashScope 原生端点 + forced_search/enable_source）

  func testSourceVerificationReturnsContentAndSources() async throws {
    let apiKey = try testAPIKey()
    FamoCloudPreferences.isEnabled = true

    let profile = FamoProviderProfile(
      displayName: "阿里云百炼（实盘测试）",
      endpoint: Self.endpoint, model: Self.model,
      providerID: "qwen", secretName: "famo.live.test", isDefault: true)
    let service = FamoSourceVerificationService(
      profileProvider: { profile },
      profileSecretProvider: { _ in apiKey })

    let outcome = try await service.verifyStructured(
      "《中华人民共和国民法典》自2021年1月1日起施行。")
    try? outcome.content.write(
      toFile: "/tmp/famo-skill-verify.txt", atomically: true, encoding: .utf8)

    XCTAssertFalse(outcome.content.isEmpty, "核验必须给出结论文本")
    XCTAssertFalse(
      outcome.sources.isEmpty,
      "forced_search + enable_source 下应返回可跳查的来源；为空说明来源抽取断了")
  }
}
