//
//  FamoGoalBriefLiveTests.swift
//  FamoTests — 任务书（目标七问）「实盘」集成测试
//
//  与 FamoPromptOptimizeLiveTests 同一约定：**默认跳过**，只有 `~/.famo-test-key-doubao`
//  存在时才跑；CI 与他人机器上 XCTSkip 静默略过，不影响离线套件。
//
//  为什么需要它：任务书是全仓最长的单次产出（七问逐节 + 推断标注），mock fetcher 验不出
//  真实供应商的两件事——①返回 JSON 的真实形状（围栏/status 缺省/超长 questions）；②整份
//  任务书的生成时长是否扛得住 60 秒超时（提示词优化当年就是 mock 测不出真实延迟才吃过亏）。
//  本测试打火山方舟豆包 turbo，把原始响应落到 /tmp 供人工核对。
//
//  Key 从仓库外的文件读，绝不落进代码、环境变量导出或日志。
//

import Foundation
import XCTest

@testable import Famo

@MainActor
final class FamoGoalBriefLiveTests: XCTestCase {

  /// 火山方舟 OpenAI 兼容端点 + 豆包 turbo（与 `FamoLLMProviderCatalog.presets` 的 doubao
  /// 预设同端点；模型用 turbo 是机主 2026-07-28 指定的实测目标）。
  private let endpoint = URL(
    string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!
  private let model = "doubao-seed-2-1-turbo-260628"

  /// 读仓库外的测试 Key；没有就返回 nil → 测试跳过。永不打印内容。
  private func testAPIKey() throws -> String {
    let path = ("~/.famo-test-key-doubao" as NSString).expandingTildeInPath
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw XCTSkip("无 ~/.famo-test-key-doubao，跳过实盘测试（离线套件不受影响）")
    }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty {
      throw XCTSkip("~/.famo-test-key-doubao 为空，跳过实盘测试")
    }
    return key
  }

  /// 用真实代码构造的请求体直接 POST，把原始响应落盘供人工核对形状。
  @discardableResult
  private func dumpRawResponse(draft: String, apiKey: String, label: String) async throws -> String {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 60
    request.httpBody = try JSONEncoder().encode(
      FamoGoalBrief.chatRequest(forDraft: draft, model: model)
    )

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    let body = String(data: data, encoding: .utf8) ?? ""
    try? body.write(
      toFile: "/tmp/famo-live-goalbrief-\(label).json", atomically: true, encoding: .utf8)
    XCTAssertEqual(status, 200, "方舟返回非 200：\(body.prefix(400))")

    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let choices = root?["choices"] as? [[String: Any]]
    let message = choices?.first?["message"] as? [String: Any]
    let content = message?["content"] as? String ?? ""
    try? content.write(
      toFile: "/tmp/famo-live-goalbrief-\(label)-content.txt", atomically: true, encoding: .utf8)
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
    let client = FamoGoalBriefClient(endpoint: endpoint, model: model, authHeaderStyle: .bearer)
    let outcome = try await client.fetchOptimizedPrompt(
      forDraft: draft, clarifications: [], apiKey: apiKey)

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

    let client = FamoGoalBriefClient(endpoint: endpoint, model: model, authHeaderStyle: .bearer)
    let outcome = try await client.fetchOptimizedPrompt(
      forDraft: draft, clarifications: [], apiKey: apiKey)

    switch outcome {
    case let .needsClarification(questions):
      XCTAssertFalse(questions.isEmpty)
      XCTAssertLessThanOrEqual(
        questions.count, FamoPromptOptimizer.maxClarificationQuestions,
        "问题数必须被截到上限内，否则预填会撑爆单行输入框")
    case let .ready(brief):
      // 模型选择出书而非反问也算合理，但必须把说不清的事落进〈未知〉而不是编造细节。
      XCTAssertFalse(brief.hasPrefix("{"), "退化成 JSON 原文说明解析层漏了")
      XCTAssertTrue(brief.contains("未知"), "没反问就必须有〈未知〉一节承载缺失")
    }
  }
}
