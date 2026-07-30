//
//  FamoPolishPromptCatalogTests.swift
//  FamoTests — 润色提示词变体注册表 (issue #136)
//
//  测试红线（项目记忆 famo-app-options-test-fake-coverage）：断言必须「真读回」——通过
//  FamoExperimentalPreferences 设置 variant 后走到请求构造层（chatRequest 默认参数解析），
//  断言请求体里的 system prompt / temperature 真的切换了；只断言 catalog 常量文本是假覆盖。
//

import Foundation
import XCTest
@testable import Famo

final class FamoPolishPromptCatalogTests: XCTestCase {

  override func setUp() {
    super.setUp()
    FamoExperimentalPreferences.resetForTesting()
  }

  override func tearDown() {
    FamoExperimentalPreferences.resetForTesting()
    super.tearDown()
  }

  // MARK: - Resolution / fallback

  func testDefaultResolvesLegacyVariant() throws {
    // 未设置偏好 → v1-legacy 出厂行为：legacy prompt + temp 0.3，逐字节不变。
    XCTAssertNil(FamoExperimentalPreferences.selectionPolishPromptVariant)
    XCTAssertEqual(FamoPolishPromptCatalog.resolveActive().id, FamoPolishPromptCatalog.legacyVariantID)

    let request = try FamoSelectionPolish.chatRequest(for: "他撤销了合同")
    XCTAssertEqual(request.messages.first?.content, FamoPolishPromptCatalog.legacySystemPrompt)
    XCTAssertEqual(request.temperature, 0.3)
  }

  func testUnknownVariantFallsBackToLegacyWithoutCrashing() throws {
    FamoExperimentalPreferences.selectionPolishPromptVariant = "v9-does-not-exist"
    XCTAssertEqual(FamoPolishPromptCatalog.resolveActive().id, FamoPolishPromptCatalog.legacyVariantID)

    // 请求构造层同样回退 v1，不崩、不空 prompt。
    let request = try FamoSelectionPolish.chatRequest(for: "他撤销了合同")
    XCTAssertEqual(request.messages.first?.content, FamoPolishPromptCatalog.legacySystemPrompt)
    XCTAssertEqual(request.temperature, 0.3)
  }

  func testLegacyAliasStaysByteIdentical() {
    // FamoSelectionPolish.systemPrompt 是 v1 的别名——两处必须永远同一份字节
    // （v1 的内容本身可演进，如 2026-07-31 的保真硬线，但别名不许漂移）。
    XCTAssertEqual(FamoSelectionPolish.systemPrompt, FamoPolishPromptCatalog.legacySystemPrompt)
    XCTAssertTrue(FamoPolishPromptCatalog.legacySystemPrompt.contains("{\"candidates\":"))
  }

  /// 2026-07-31 保真硬线（真读回：经 chatRequest 落进请求体）。旧基线 qwen3.7-flash 实盘把
  /// 「可能撤销合同」润成「或许解除该合同」——撤销/解除是不同法律效果，两个变体都必须带
  /// 「动作词不得互换」的红线，缺了就是把同一坑再挖开。
  func testBothVariantsCarryTheActionWordFidelityHardLine() throws {
    let v1 = try FamoSelectionPolish.chatRequest(for: "他可能撤销合同")
    let v1System = v1.messages.first?.content ?? ""
    XCTAssertTrue(v1System.contains("撤销"), "v1 必须点名法律动作词示例")
    XCTAssertTrue(v1System.contains("degree of certainty"), "v1 必须保确定度")

    FamoExperimentalPreferences.selectionPolishPromptVariant =
      FamoPolishPromptCatalog.responsayAlignedVariantID
    let v2 = try FamoSelectionPolish.chatRequest(for: "他可能撤销合同")
    let v2System = v2.messages.first?.content ?? ""
    XCTAssertTrue(v2System.contains("Do not swap action/effect words"), "v2 红线段必须含动作词条")
    XCTAssertTrue(v2System.contains("撤销 / 解除"), "v2 必须点名互不替换的动作词")
  }

  // MARK: - True read-back: preference → request body

  func testVariantSwitchReachesRequestBody() throws {
    // 真读回：设置偏好（不直接传 variant 参数）→ chatRequest 默认参数解析 → 请求体切到 v2。
    FamoExperimentalPreferences.selectionPolishPromptVariant = FamoPolishPromptCatalog.responsayAlignedVariantID

    let request = try FamoSelectionPolish.chatRequest(for: "他撤销了合同")
    let system = request.messages.first?.content ?? ""
    XCTAssertEqual(system, FamoPolishPromptCatalog.responsayAlignedSystemPrompt)
    XCTAssertEqual(request.temperature, 0.2, "v2 对齐 Responsay rewrite 线 temp 0.2")

    // 三块硬护栏都在 system prompt 里（spec §2.2）。
    XCTAssertTrue(system.contains("byte-for-byte"), "护栏①: preserve 清单")
    XCTAssertTrue(system.contains("Keep hedges as hedges"), "护栏②: 忠实度红线（不改确定度）")
    XCTAssertTrue(system.contains("Work only with the selected text"), "护栏③: 只处理明确选区")
    XCTAssertTrue(system.contains("Never translate"), "同语种硬规则独立成段")

    // 编码后的实际 HTTP 请求体也切换了（不是只有内存对象）。
    let body = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
    XCTAssertTrue(body.contains("Heavy Rewriter"))
    XCTAssertTrue(body.contains("0.2"))

    // 切回 v1 → 请求体还原。
    FamoExperimentalPreferences.selectionPolishPromptVariant = FamoPolishPromptCatalog.legacyVariantID
    let reverted = try FamoSelectionPolish.chatRequest(for: "他撤销了合同")
    XCTAssertEqual(reverted.messages.first?.content, FamoPolishPromptCatalog.legacySystemPrompt)
    XCTAssertEqual(reverted.temperature, 0.3)
  }

  func testV2KeepsCandidatesJSONContract() {
    // v2 沿用 {"candidates":[...]} json_object 契约，FamoNumberedRewriteParser 不需要任何改动。
    let prompt = FamoPolishPromptCatalog.responsayAlignedSystemPrompt
    XCTAssertTrue(prompt.contains("{\"candidates\":"))
    XCTAssertTrue(prompt.lowercased().contains("json"))
  }

  // MARK: - Thinking control per provider (真读回：编码后的请求体)

  func testThinkingControlDispatchesByModelPrefix() throws {
    // 三态契约（2026-07-20 实盘百炼定）：deepseek/mimo/doubao 走 thinking:{disabled}
    // （FamoThinkingControl 同一 deepSeekStyle 形状；豆包 doubao-seed-2-1-turbo 实测默认开
    // 思考，短回复也烧 reasoning token，2026-07-28 火山方舟）；qwen 走
    // enable_thinking:false（qwen3.6-flash 默认开思考，实测润色 948 reasoning token / 5.4s，
    // 打爆 8s 交互超时；关掉后 0.6s）；其余供应商两个字段都必须省略（body 逐字节不变）。
    for model in ["deepseek-v4-flash", "MiMo-8B", "doubao-seed-2-1-turbo-260628"] {
      let request = try FamoSelectionPolish.chatRequest(for: "他撤销了合同", model: model)
      let body = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
      XCTAssertTrue(body.contains("\"thinking\""), "\(model) 必须带 thinking:{disabled}")
      XCTAssertFalse(body.contains("enable_thinking"), "\(model) 不得混入 qwen 的字段")
    }

    let qwen = try FamoSelectionPolish.chatRequest(for: "他撤销了合同", model: "qwen3.6-flash")
    let qwenBody = String(data: try JSONEncoder().encode(qwen), encoding: .utf8) ?? ""
    XCTAssertTrue(qwenBody.contains("\"enable_thinking\":false"))
    XCTAssertFalse(qwenBody.contains("\"thinking\""))

    let other = try FamoSelectionPolish.chatRequest(for: "他撤销了合同", model: "gpt-4o")
    let otherBody = String(data: try JSONEncoder().encode(other), encoding: .utf8) ?? ""
    XCTAssertFalse(otherBody.contains("thinking"), "非 deepseek/mimo/doubao/qwen 不得携带任何思考控制字段")
  }

  func testProviderIDBeatsModelPrefixSoDashScopeHostedDeepSeekGetsTheRightField() throws {
    // 百炼上托管着 deepseek-* 型号：只看模型名会发 thinking:{disabled}（百炼不认），
    // 得按档案的 providerID 发 enable_thinking:false。传空串才退回模型名判定。
    let hosted = try FamoSelectionPolish.chatRequest(
      for: "他撤销了合同", model: "deepseek-v3", providerID: "qwen")
    XCTAssertEqual(hosted.enableThinking, false, "档案是百炼，就该走百炼的字段")
    XCTAssertNil(hosted.thinking, "百炼没有 thinking 字段，塞进去只会 400")

    let unknown = try FamoSelectionPolish.chatRequest(for: "他撤销了合同", model: "deepseek-v3")
    XCTAssertEqual(unknown.thinking, .disabled, "没有档案 id 时按模型名前缀判")
  }

}
