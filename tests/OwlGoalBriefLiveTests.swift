//
//  OwlGoalBriefLiveTests.swift
//  OwltypeTests — 任务书（目标七问）「实盘」集成测试
//
//  与 OwlPromptOptimizeLiveTests 同一约定：**默认跳过**，Key（`ARK_API_KEY`）经 `OwlLiveKey`
//  从环境读，用 `bash scripts/live-test.sh` 运行；CI 与他人机器上 XCTSkip 略过。
//
//  为什么需要它：任务书是全仓最长的单次产出（七问逐节 + 推断标注），mock fetcher 验不出
//  真实供应商的两件事——①返回 JSON 的真实形状（围栏/status 缺省/超长 questions）；②整份
//  任务书的生成时长是否扛得住 60 秒超时（提示词优化当年就是 mock 测不出真实延迟才吃过亏）。
//  本测试打火山方舟豆包 Pro（2026-07-31 起的产品高质量档；turbo 是 2026-07-28 的旧实测目标），
//  走产品同款 Responses 请求，把原始响应落到 /tmp 供人工核对。
//
//  Key 从仓库外的文件读，绝不落进代码、环境变量导出或日志。
//

import Foundation
import XCTest

@testable import Owltype

@MainActor
final class OwlGoalBriefLiveTests: XCTestCase {

  /// 火山方舟 Responses 端点 + 豆包 Pro（与 `OwlLLMProviderCatalog.presets` 的 doubao 预设
  /// 同端点同模型；2026-07-31 起豆包全面走 Responses：store=false + thinking:{disabled}）。
  private let endpoint = URL(
    string: "https://ark.cn-beijing.volces.com/api/v3/responses")!
  private let model = "doubao-seed-2-1-pro-260628"

  private func testAPIKey() throws -> String { try OwlLiveKey.ark.value() }

  /// 用真实代码构造的请求体直接 POST（产品同款 Responses wire），把原始响应落盘供人工核对形状。
  @discardableResult
  private func dumpRawResponse(draft: String, apiKey: String, label: String) async throws -> String {
    let payload = OwlGoalBrief.chatRequest(forDraft: draft, model: model, providerID: "doubao")
    let request = try OwlResponsesWire.request(
      endpoint: endpoint,
      model: model,
      messages: payload.messages,
      apiKey: apiKey,
      authHeaderStyle: .bearer,
      dialect: .ark,
      stream: false,
      webSearch: false,
      temperature: payload.temperature,
      timeout: 60)

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    let body = String(data: data, encoding: .utf8) ?? ""
    try? body.write(
      toFile: "/tmp/owl-live-goalbrief-\(label).json", atomically: true, encoding: .utf8)
    XCTAssertEqual(status, 200, "方舟返回非 200：\(body.prefix(400))")

    let content = (try? OwlResponsesWire.parse(data))?.text ?? ""
    try? content.write(
      toFile: "/tmp/owl-live-goalbrief-\(label)-content.txt", atomically: true, encoding: .utf8)
    return content
  }

  // MARK: - 完成态：模糊但意图可辨的需求应当直接产出七问俱全的任务书

  func testVagueRequirementProducesSevenSectionBriefEndToEnd() async throws {
    let apiKey = try testAPIKey()
    // 刻意选「目的/完成态可推断、其余五问全缺」的口述体草稿——正是本技能的目标场景。
    let draft = """
      我们输入法的词库下载老是断，用户一断网就得重头下，帮我把这个下载搞稳一点，\
      最好断了能接着下，下载完还得校验一下别装出坏包。
      """

    let started = Date()
    let content = try await dumpRawResponse(draft: draft, apiKey: apiKey, label: "ready")
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertFalse(content.isEmpty, "模型返回空 content")
    // 60 秒是产品侧硬超时；实盘留出重试余量，超过 55 秒就该报警而不是等线上掐断。
    XCTAssertLessThan(elapsed, 55, "整份任务书生成耗时 \(elapsed)s，逼近 60s 硬超时")

    // 真实客户端全链路（编码 → POST → 解码 → 解析 → 遥测）。
    let client = OwlStructuredDrafting.live(
      OwlGoalBrief.structuredDraftingConfiguration,
      routing: OwlCloudRouting(providerID: "", endpoint: endpoint, model: model,
                               secretName: nil, authHeaderStyle: .bearer),
      apiKey: apiKey)
    let outcome = try await client.draft(draft)

    guard case let .ready(brief) = outcome else {
      return XCTFail("意图可辨的草稿应当直接出任务书，实际 \(outcome)")
    }
    XCTAssertFalse(brief.isEmpty)
    XCTAssertFalse(
      brief.hasPrefix("{"), "任务书不该是 JSON 原文——那说明解析层漏了，会把 JSON 粘进用户编辑器")

    // 七问一节不缺：system prompt 规定小节标题与顺序固定，缺节说明模型没吃住契约。
    for section in ["目的", "完成态", "证据", "反作弊", "边界", "取舍", "未知"] {
      XCTAssertTrue(brief.contains(section), "任务书缺〈\(section)〉一节：\(brief.prefix(200))")
    }
  }

  // MARK: - 澄清态：目的与完成态都没影的草稿应当反问而不是编造

  func testHopelesslyVagueDraftAsksOrSurfacesUnknowns() async throws {
    let apiKey = try testAPIKey()
    let draft = "把那个东西弄一下"

    let content = try await dumpRawResponse(draft: draft, apiKey: apiKey, label: "clarify")
    XCTAssertFalse(content.isEmpty)

    let client = OwlStructuredDrafting.live(
      OwlGoalBrief.structuredDraftingConfiguration,
      routing: OwlCloudRouting(providerID: "", endpoint: endpoint, model: model,
                               secretName: nil, authHeaderStyle: .bearer),
      apiKey: apiKey)
    let outcome = try await client.draft(draft)

    switch outcome {
    case let .needsClarification(questions):
      XCTAssertFalse(questions.isEmpty)
      XCTAssertLessThanOrEqual(
        questions.count, OwlPromptOptimizer.maxClarificationQuestions,
        "问题数必须被截到上限内，否则预填会撑爆单行输入框")
    case let .ready(brief):
      // 模型选择出书而非反问也算合理，但必须把说不清的事落进〈未知〉而不是编造细节。
      XCTAssertFalse(brief.hasPrefix("{"), "退化成 JSON 原文说明解析层漏了")
      XCTAssertTrue(brief.contains("未知"), "没反问就必须有〈未知〉一节承载缺失")
    }
  }
}
