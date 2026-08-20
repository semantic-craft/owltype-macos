//
//  OwlPolishPromptCatalogTests.swift
//  OwltypeTests — 润色提示词变体注册表 (issue #136)
//
//  测试红线（项目记忆 famo-app-options-test-fake-coverage）：断言必须「真读回」——通过
//  OwlExperimentalPreferences 设置 variant 后走到请求构造层（chatRequest 默认参数解析），
//  断言请求体里的 system prompt / temperature 真的切换了；只断言 catalog 常量文本是假覆盖。
//

import Foundation
import XCTest
@testable import Owltype

final class OwlPolishPromptCatalogTests: XCTestCase {

  override func setUp() {
    super.setUp()
    OwlExperimentalPreferences.resetForTesting()
  }

  override func tearDown() {
    OwlExperimentalPreferences.resetForTesting()
    super.tearDown()
  }

  // MARK: - Resolution / fallback

  func testDefaultResolvesLegacyVariant() throws {
    // 未设置偏好 → v1-legacy 出厂行为：legacy prompt + temp 0.3，逐字节不变。
    XCTAssertNil(OwlExperimentalPreferences.selectionPolishPromptVariant)
    XCTAssertEqual(OwlPolishPromptCatalog.resolveActive().id, OwlPolishPromptCatalog.legacyVariantID)

    let request = try OwlSelectionPolish.chatRequest(for: "他撤销了合同")
    XCTAssertEqual(request.messages.first?.content, OwlPolishPromptCatalog.legacySystemPrompt)
    XCTAssertEqual(request.temperature, 0.3)
  }

  func testUnknownVariantFallsBackToLegacyWithoutCrashing() throws {
    OwlExperimentalPreferences.selectionPolishPromptVariant = "v9-does-not-exist"
    XCTAssertEqual(OwlPolishPromptCatalog.resolveActive().id, OwlPolishPromptCatalog.legacyVariantID)

    // 请求构造层同样回退 v1，不崩、不空 prompt。
    let request = try OwlSelectionPolish.chatRequest(for: "他撤销了合同")
    XCTAssertEqual(request.messages.first?.content, OwlPolishPromptCatalog.legacySystemPrompt)
    XCTAssertEqual(request.temperature, 0.3)
  }

  func testLegacyAliasStaysByteIdentical() {
    // OwlSelectionPolish.systemPrompt 是 v1 的别名——两处必须永远同一份字节
    // （v1 的内容本身可演进，如 2026-07-31 的保真硬线，但别名不许漂移）。
    XCTAssertEqual(OwlSelectionPolish.systemPrompt, OwlPolishPromptCatalog.legacySystemPrompt)
    XCTAssertTrue(OwlPolishPromptCatalog.legacySystemPrompt.contains("{\"candidates\":"))
  }

  /// 2026-07-31 保真硬线（真读回：经 chatRequest 落进请求体）。旧基线 qwen3.7-flash 实盘把
  /// 「可能撤销合同」润成「或许解除该合同」——撤销/解除是不同法律效果，两个变体都必须带
  /// 「动作词不得互换」的红线，缺了就是把同一坑再挖开。
  func testBothVariantsCarryTheActionWordFidelityHardLine() throws {
    let v1 = try OwlSelectionPolish.chatRequest(for: "他可能撤销合同")
    let v1System = v1.messages.first?.content ?? ""
    XCTAssertTrue(v1System.contains("撤销"), "v1 必须点名法律动作词示例")
    XCTAssertTrue(v1System.contains("degree of certainty"), "v1 必须保确定度")

    OwlExperimentalPreferences.selectionPolishPromptVariant =
      OwlPolishPromptCatalog.responsayAlignedVariantID
    let v2 = try OwlSelectionPolish.chatRequest(for: "他可能撤销合同")
    let v2System = v2.messages.first?.content ?? ""
    XCTAssertTrue(v2System.contains("Do not swap action/effect words"), "v2 红线段必须含动作词条")
    XCTAssertTrue(v2System.contains("撤销 / 解除"), "v2 必须点名互不替换的动作词")
  }

  // MARK: - True read-back: preference → request body

  func testVariantSwitchReachesRequestBody() throws {
    // 真读回：设置偏好（不直接传 variant 参数）→ chatRequest 默认参数解析 → 请求体切到 v2。
    OwlExperimentalPreferences.selectionPolishPromptVariant = OwlPolishPromptCatalog.responsayAlignedVariantID

    let request = try OwlSelectionPolish.chatRequest(for: "他撤销了合同")
    let system = request.messages.first?.content ?? ""
    XCTAssertEqual(system, OwlPolishPromptCatalog.responsayAlignedSystemPrompt)
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
    OwlExperimentalPreferences.selectionPolishPromptVariant = OwlPolishPromptCatalog.legacyVariantID
    let reverted = try OwlSelectionPolish.chatRequest(for: "他撤销了合同")
    XCTAssertEqual(reverted.messages.first?.content, OwlPolishPromptCatalog.legacySystemPrompt)
    XCTAssertEqual(reverted.temperature, 0.3)
  }

  func testV2KeepsCandidatesJSONContract() {
    // v2 沿用 {"candidates":[...]} json_object 契约，OwlNumberedRewriteParser 不需要任何改动。
    let prompt = OwlPolishPromptCatalog.responsayAlignedSystemPrompt
    XCTAssertTrue(prompt.contains("{\"candidates\":"))
    XCTAssertTrue(prompt.lowercased().contains("json"))
  }

  // MARK: - Thinking control per provider (真读回：编码后的请求体)

  func testThinkingControlDispatchesByModelPrefix() throws {
    // 三态契约（2026-07-20 实盘百炼定）：deepseek/mimo/doubao 走 thinking:{disabled}
    // （OwlThinkingControl 同一 deepSeekStyle 形状；豆包 doubao-seed-2-1-turbo 实测默认开
    // 思考，短回复也烧 reasoning token，2026-07-28 火山方舟）；qwen 走
    // enable_thinking:false（qwen3.6-flash 默认开思考，实测润色 948 reasoning token / 5.4s，
    // 打爆 8s 交互超时；关掉后 0.6s）；其余供应商两个字段都必须省略（body 逐字节不变）。
    for model in ["deepseek-v4-flash", "MiMo-8B", "doubao-seed-2-1-turbo-260628"] {
      let request = try OwlSelectionPolish.chatRequest(for: "他撤销了合同", model: model)
      let body = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
      XCTAssertTrue(body.contains("\"thinking\""), "\(model) 必须带 thinking:{disabled}")
      XCTAssertFalse(body.contains("enable_thinking"), "\(model) 不得混入 qwen 的字段")
    }

    let qwen = try OwlSelectionPolish.chatRequest(for: "他撤销了合同", model: "qwen3.6-flash")
    let qwenBody = String(data: try JSONEncoder().encode(qwen), encoding: .utf8) ?? ""
    XCTAssertTrue(qwenBody.contains("\"enable_thinking\":false"))
    XCTAssertFalse(qwenBody.contains("\"thinking\""))

    let other = try OwlSelectionPolish.chatRequest(for: "他撤销了合同", model: "gpt-4o")
    let otherBody = String(data: try JSONEncoder().encode(other), encoding: .utf8) ?? ""
    XCTAssertFalse(otherBody.contains("thinking"), "非 deepseek/mimo/doubao/qwen 不得携带任何思考控制字段")
  }

  func testProviderIDBeatsModelPrefixForTheChatThinkingDialect() throws {
    // 档案 id 优先于模型名前缀：豆包档案上托管一个 qwen-* 型号，仍要发方舟的 thinking:{disabled}。
    // 不再拿百炼举例——它自 2026-07-31 起整体走 Responses，见下面那条测试。
    let hosted = try OwlSelectionPolish.chatRequest(
      for: "他撤销了合同", model: "qwen3.7-plus", providerID: "doubao")
    XCTAssertEqual(hosted.thinking, .disabled, "档案是方舟，就该走方舟的字段")
    XCTAssertNil(hosted.enableThinking, "方舟不认 enable_thinking")

    let unknown = try OwlSelectionPolish.chatRequest(for: "他撤销了合同", model: "deepseek-v3")
    XCTAssertEqual(unknown.thinking, .disabled, "没有档案 id 时按模型名前缀判")
  }

  /// 百炼档案（含它托管的非 qwen 型号）一律解析为 Responses，`chatRequest` 的 `enableThinking`
  /// 发不出去——关思考由 `reasoning.effort:none` 负责。钉的是「旧 chat 回退已拆掉」。
  func testDashScopeProfileResolvesToResponsesSoTheChatThinkingFieldNeverShips() {
    let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")!
    for model in ["qwen3.7-plus", "deepseek-v3"] {
      XCTAssertEqual(
        OwlResponsesWire.dialect(providerID: "qwen", model: model, endpoint: endpoint),
        .qwen,
        "百炼档案配 \(model) 必须走 Responses，而不是回退 chat 带 enable_thinking")
    }
  }

}
