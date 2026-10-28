//
//  OwlGoalBriefTests.swift
//  OwltypeTests — 任务书技能（目标七问）
//
//  Shared admission ordering, protected-draft assembly, clarification transport, wire transport,
//  parsing and outcome safety live in OwlStructuredDraftingModuleTests. This file locks only the
//  GoalBrief domain contract and one façade-to-module integration path.
//

import XCTest
@testable import Owltype

final class OwlGoalBriefTests: XCTestCase {

  private func encodedRequestBody() throws -> String {
    let request = OwlGoalBrief.chatRequest(
      forDraft: "帮我把词库下载做稳",
      model: "qwen-plus"
    )
    return try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
  }

  func testRequestBodyCarriesAllSevenQuestionsInOrder() throws {
    let body = try encodedRequestBody()
    let orderedQuestions = [
      "1. 目的 Why",
      "2. 完成态 Done",
      "3. 证据 Proof",
      "4. 反作弊 Anti",
      "5. 边界 Bounds",
      "6. 取舍 Trade",
      "7. 未知 Unknown",
    ]

    var remaining = body.startIndex..<body.endIndex
    for question in orderedQuestions {
      let range = try XCTUnwrap(
        body.range(of: question, range: remaining),
        "目标七问缺少或顺序错误：\(question)"
      )
      remaining = range.upperBound..<body.endIndex
    }
    XCTAssertTrue(body.contains("帮我把词库下载做稳"), "草稿必须进入实际请求体")
  }

  func testRequestBodyLocksInferenceMarkingRule() throws {
    let body = try encodedRequestBody()

    XCTAssertTrue(body.contains("某问缺失但能从草稿合理推断"))
    XCTAssertTrue(body.contains("句末标注「（推断）」"), "每一处补写都必须显式标成推断")
    XCTAssertTrue(body.contains("让用户一眼看出哪些是你补的"))
  }

  func testRequestBodyLocksEveryUnknownItemRule() throws {
    let body = try encodedRequestBody()

    XCTAssertTrue(body.contains("无法合理推断的：写进〈未知 Unknown〉一节，不要编造"))
    XCTAssertTrue(body.contains("没有未知项就写「无」"))
    XCTAssertTrue(body.contains("技术选型（编程语言、框架、库、运行环境）"))
    XCTAssertTrue(body.contains("既不推断也不反问"))
    XCTAssertTrue(body.contains("在〈未知〉一节列一条「未指定」"))
    XCTAssertTrue(body.contains("其余小节不得出现具体选型"))
    XCTAssertTrue(body.contains("举例（「如 Python」）也不要"))
  }

  func testRequestBodyLocksTheNarrowClarificationGate() throws {
    let body = try encodedRequestBody()

    XCTAssertTrue(body.contains("只有「目的」与「完成态」都无法从草稿推断"))
    XCTAssertTrue(body.contains("任务书写了也没意义时，最多问 3 个问题"))
    XCTAssertTrue(body.contains("needs_clarification"))
    XCTAssertTrue(body.contains("questions"))
  }

  func testConfigurationKeepsGoalBriefAdmissionErrorsAndUserCopy() throws {
    let configuration = OwlGoalBrief.structuredDraftingConfiguration

    XCTAssertEqual(configuration.systemPrompt, OwlGoalBrief.systemPrompt)
    XCTAssertEqual(configuration.maxDraftLength, OwlSelectionPolish.maxSelectionLength)
    XCTAssertEqual(configuration.temperature, 0.2)
    XCTAssertEqual(configuration.traceName, "goal-brief")

    let disabled = try XCTUnwrap(
      configuration.admissionError(.disabled) as? OwlGoalBriefError)
    let empty = try XCTUnwrap(
      configuration.admissionError(.emptyDraft) as? OwlGoalBriefError)
    let tooLong = try XCTUnwrap(
      configuration.admissionError(.draftTooLong(4_001)) as? OwlGoalBriefError)
    let missingKey = try XCTUnwrap(
      configuration.admissionError(.missingAPIKey) as? OwlGoalBriefError)

    XCTAssertEqual(disabled, .disabled)
    XCTAssertEqual(disabled.userMessage, "云端 AI 已关闭，无法整理任务书。")
    XCTAssertEqual(empty, .emptyDraft)
    XCTAssertEqual(empty.userMessage, "请先选中要整理的需求描述。")
    XCTAssertEqual(tooLong, .draftTooLong(4_001))
    XCTAssertEqual(
      tooLong.userMessage,
      "选中内容过长（4001 字），请选中不超过 \(OwlSelectionPolish.maxSelectionLength) 字的内容。"
    )
    XCTAssertEqual(missingKey, .missingAPIKey)
    XCTAssertEqual(missingKey.userMessage, "尚未配置可用 AI 供应商或 API Key。")
  }
}

@MainActor
final class OwlGoalBriefServiceTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    OwlCloudPreferences.resetForTesting()
  }

  override func tearDown() async throws {
    OwlCloudPreferences.resetForTesting()
    try await super.tearDown()
  }

  func testComposeUsesGoalBriefConfigurationThroughStructuredDrafting() async throws {
    OwlCloudPreferences.isEnabled = true
    let remote = MockStructuredDraftingRemote()
    remote.response = "{\"status\":\"ok\",\"prompt\":\"### 目的 Why\\n让下载可恢复\"}"
    let service = OwlGoalBriefService(
      remote: remote,
      apiKeyProvider: { "sk-test" },
      profileProvider: { nil }
    )

    let outcome = try await service.compose("把词库下载做稳")

    XCTAssertEqual(outcome, .ready("### 目的 Why\n让下载可恢复"))
    let request = try XCTUnwrap(remote.requests.first)
    XCTAssertEqual(remote.requests.count, 1)
    XCTAssertEqual(request.apiKey, "sk-test")
    XCTAssertEqual(request.traceName, "goal-brief")
    XCTAssertEqual(request.payload.messages.first?.content, OwlGoalBrief.systemPrompt)
    XCTAssertTrue(request.payload.messages[1].content.contains("把词库下载做稳"))
  }
}
