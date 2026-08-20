//
//  OwlPromptOptimizeLiveTests.swift
//  OwltypeTests — 提示词优化「实盘」集成测试 (issue #138)
//
//  这是全仓唯一会打真实网络的测试，**默认跳过**：只有当 `~/.owl-test-key` 存在时才跑。
//  CI 与他人机器上没有该文件，`XCTSkip` 静默略过，不影响 780+ 的离线套件。
//
//  为什么需要它：#138 的整条链路此前只用 mock fetcher 验过，真实供应商返回的 JSON 长什么样
//  （套不套 markdown 围栏、status 给不给全、questions 会不会超 3 条）一个样本都没有，解析层
//  的防御全是凭推测写的。这条测试打真实的阿里云百炼，把原始响应落到 /tmp 供人工核对，并跑通
//  真实的 `OwlPromptOptimizeClient`（编码 → POST → 解码 → 解析全链路）。
//
//  Key 从仓库外的文件读，绝不落进代码、环境变量导出或日志。
//

import Foundation
import XCTest

@testable import Owltype

@MainActor
final class OwlPromptOptimizeLiveTests: XCTestCase {

  /// `~/.owl-test-workspace` 可填 Workspace ID、完整 API Host 或 Responses URL；不把任何
  /// 个人 Workspace 写进仓库。未配置时才回退通用域名。
  private let endpoint: URL = {
    let path = ("~/.owl-test-workspace" as NSString).expandingTildeInPath
    let workspace = (try? String(contentsOfFile: path, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let workspace, let endpoint = OwlQwenWorkspace.responsesEndpoint(for: workspace) {
      return endpoint
    }
    return URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)!
  }()
  /// 默认跟着百炼预设走（测的应当是新用户真会用上的那个型号，2026-07-31 起即 qwen3.7-plus），
  /// `~/.owl-test-model` 可覆盖 —— 「这个技能该用 3.7-plus 还是 3.7-max」只能靠同一套用例
  /// 分别打两次来回答。用文件而不是环境变量的原因见 `OwlSkillsLiveTests.model`
  /// （xcodebuild 不转发 shell env）。
  private let model: String = {
    let path = ("~/.owl-test-model" as NSString).expandingTildeInPath
    let override = (try? String(contentsOfFile: path, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let override, !override.isEmpty { return override }
    return OwlLLMProviderCatalog.preset(id: "qwen")?.model ?? "qwen3.7-plus"
  }()

  /// 读仓库外的测试 Key；没有就返回 nil → 测试跳过。永不打印内容。
  private func testAPIKey() throws -> String {
    let path = ("~/.owl-test-key" as NSString).expandingTildeInPath
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw XCTSkip("无 ~/.owl-test-key，跳过实盘测试（离线套件不受影响）")
    }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty {
      throw XCTSkip("~/.owl-test-key 为空，跳过实盘测试")
    }
    return key
  }

  /// 用真实代码构造的请求体直接 POST，把原始响应落盘供人工核对形状。
  @discardableResult
  private func dumpRawResponse(draft: String, apiKey: String, label: String) async throws -> String {
    let payload = OwlPromptOptimizer.chatRequest(
      forDraft: draft, model: model, providerID: "qwen")
    let request = try OwlResponsesWire.request(
      endpoint: endpoint, model: model, messages: payload.messages,
      apiKey: apiKey, authHeaderStyle: .bearer, dialect: .qwen,
      stream: false, webSearch: false, temperature: payload.temperature, timeout: 60)

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    let body = String(data: data, encoding: .utf8) ?? ""
    try? body.write(
      toFile: "/tmp/owl-live-\(label).json", atomically: true, encoding: .utf8)
    XCTAssertEqual(status, 200, "百炼返回非 200：\(body.prefix(400))")

    // 取出模型真正吐的那段 content（解析层要处理的就是它）。这里刻意不复用产品的解码器：
    // 目的是看清「原样」，产品解码器挑不挑得动是另一条断言的事。
    let content = (try? OwlResponsesWire.parse(data).text) ?? ""
    try? content.write(
      toFile: "/tmp/owl-live-\(label)-content.txt", atomically: true, encoding: .utf8)
    return content
  }

  // MARK: - 完成态：信息完整的草稿应当直接产出终稿

  func testWellSpecifiedDraftReturnsReadyPromptEndToEnd() async throws {
    let apiKey = try testAPIKey()
    let draft = """
      帮我给深圳大学法学院的研究助理写一份提示词，让 AI 把裁判文书的争议焦点整理成表格，\
      供我们做实证研究的编码底稿用。
      """

    let content = try await dumpRawResponse(draft: draft, apiKey: apiKey, label: "ready")
    XCTAssertFalse(content.isEmpty, "模型返回空 content")

    // 真实客户端全链路（编码 → POST → 解码 → 解析）。
    let client = OwlPromptOptimizeClient(
      endpoint: endpoint, model: model, providerID: "qwen", authHeaderStyle: .bearer)
    let outcome = try await client.fetchOptimizedPrompt(
      forDraft: draft, clarifications: [], apiKey: apiKey)

    guard case let .ready(prompt) = outcome else {
      return XCTFail("信息完整的草稿应当直接出终稿，实际 \(outcome)")
    }
    XCTAssertFalse(prompt.isEmpty)
    XCTAssertFalse(
      prompt.hasPrefix("{"), "终稿不该是 JSON 原文——那说明解析层漏了，会把 JSON 粘进用户编辑器")
    XCTAssertFalse(prompt.contains("```"), "终稿不该带 markdown 围栏")
  }

  // MARK: - 澄清态：信息不足的草稿应当反问

  func testInformationPoorDraftAsksForClarification() async throws {
    let apiKey = try testAPIKey()
    let draft = "帮我写个爬虫"

    let content = try await dumpRawResponse(draft: draft, apiKey: apiKey, label: "clarify")
    XCTAssertFalse(content.isEmpty)

    let client = OwlPromptOptimizeClient(
      endpoint: endpoint, model: model, providerID: "qwen", authHeaderStyle: .bearer)
    let outcome = try await client.fetchOptimizedPrompt(
      forDraft: draft, clarifications: [], apiKey: apiKey)

    switch outcome {
    case let .needsClarification(questions):
      XCTAssertFalse(questions.isEmpty)
      XCTAssertLessThanOrEqual(
        questions.count, OwlPromptOptimizer.maxClarificationQuestions,
        "问题数必须被截到上限内，否则预填会撑爆单行输入框")
    case let .ready(prompt):
      // 模型选择自行补全而非反问也算合理产出，但仍不能漏出 JSON 原文。
      XCTAssertFalse(prompt.hasPrefix("{"), "退化成 JSON 原文说明解析层漏了")
      XCTAssertFalse(prompt.contains("```"))
    }
  }

  // MARK: - 补答重跑：带上澄清答案后应当产出终稿

  func testClarificationAnswersProduceReadyPrompt() async throws {
    let apiKey = try testAPIKey()
    let client = OwlPromptOptimizeClient(
      endpoint: endpoint, model: model, providerID: "qwen", authHeaderStyle: .bearer)

    let outcome = try await client.fetchOptimizedPrompt(
      forDraft: "帮我写个爬虫",
      clarifications: [
        OwlPromptClarification(question: "这份提示词要给谁用？", answer: "给实验室新来的研究助理"),
        OwlPromptClarification(
          question: "产出用来做什么？", answer: "抓裁判文书网的公开判决书做实证研究语料")
      ],
      apiKey: apiKey
    )

    guard case let .ready(prompt) = outcome else {
      return XCTFail("补答之后应当能产出终稿，实际 \(outcome)")
    }
    XCTAssertFalse(prompt.isEmpty)
    XCTAssertFalse(prompt.hasPrefix("{"))
  }
}
