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
    // FamoSelectionPolish.systemPrompt 是 v1 的别名——catalog 迁移不许改出厂 prompt 一个字节。
    XCTAssertEqual(FamoSelectionPolish.systemPrompt, FamoPolishPromptCatalog.legacySystemPrompt)
    XCTAssertTrue(FamoPolishPromptCatalog.legacySystemPrompt.contains("{\"candidates\":"))
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

}
