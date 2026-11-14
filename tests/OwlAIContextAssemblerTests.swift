//
//  OwlAIContextAssemblerTests.swift
//  OwltypeTests — cloud-request privacy boundary
//

import Foundation
import XCTest
@testable import Owltype

@MainActor
final class OwlAIContextAssemblerTests: XCTestCase {

  private final class SpyAskAnything: OwlAskAnythingOpening {
    private(set) var lastMessages: [OwlDeepSeekMessage] = []
    private let readinessValue = OwlStreamingReadiness.ready(
      routing: OwlCloudRouting(
        providerID: "openai",
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: "gpt-4o",
        secretName: nil,
        authHeaderStyle: .bearer
      ),
      apiKey: "sk-test"
    )

    func readiness() -> OwlStreamingReadiness { readinessValue }

    func open(messages: [OwlDeepSeekMessage]) -> Result<OwlAskStreamOpen, OwlStreamingReadiness> {
      lastMessages = messages
      let stream = AsyncThrowingStream<String, Error> { continuation in
        continuation.yield("答复")
        continuation.finish()
      }
      return .success(OwlAskStreamOpen(stream: stream, searchProviderID: nil))
    }
  }

  private func waitUntil(_ predicate: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2.0)
    while !predicate() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private func assembleMessages(selectedText: String? = nil, question: String) -> [OwlDeepSeekMessage] {
    let spy = SpyAskAnything()
    let model = OwlAIConversationModel(selectedText: selectedText, askAnything: spy)
    model.submit(question: question)
    model.teardown()
    return spy.lastMessages
  }

  func testGeneralQuestionContainsOnlySystemPromptAndExplicitQuestion() {
    let messages = assembleMessages(question: "  帮我解释善意取得  ")

    XCTAssertEqual(messages.map(\.role), ["system", "user"])
    XCTAssertEqual(messages.last?.content, "帮我解释善意取得")
  }

  func testExplicitSelectionIsIncludedOnceBeforeQuestion() {
    let messages = assembleMessages(
      selectedText: "买卖合同第三条",
      question: "改得更正式"
    )

    XCTAssertEqual(messages.map(\.role), ["system", "system", "user"])
    XCTAssertEqual(messages.filter { $0.content.contains("买卖合同第三条") }.count, 1)
    XCTAssertEqual(messages.last?.content, "改得更正式")
  }

  func testWhitespaceSelectionIsNotAdded() {
    let messages = assembleMessages(selectedText: " \n\t ", question: "你好")
    XCTAssertEqual(messages.map(\.role), ["system", "user"])
  }

  func testSelectionProcessingRuleRidesWithSelectionOnly() throws {
    // 带选区：加工规则拼在选区消息里（不可信文本之后），保证「把引号替换掉」这类指令只回结果。
    let withSelection = assembleMessages(selectedText: "选中原文", question: "把引号替换掉")
    let selectionMessage = withSelection[1].content
    let textIndex = try XCTUnwrap(selectionMessage.range(of: "选中原文")).lowerBound
    let ruleIndex = try XCTUnwrap(selectionMessage.range(of: "[选中文本加工规则]")).lowerBound
    XCTAssertLessThan(textIndex, ruleIndex, "rule must come AFTER the untrusted selection text")

    // 无选区的纯提问：任何消息都不带加工规则，一般问答不受影响。
    let withoutSelection = assembleMessages(question: "什么是善意取得？")
    XCTAssertFalse(withoutSelection.contains { $0.content.contains("[选中文本加工规则]") })
  }

  func testSelectionCapMatchesSelectionMenuGate() {
    // 划词菜单放行 ≤ maxSelectionLength 的选区；装配器上限必须不小于它，否则菜单放进来的长选区
    // 会被静默截残（加工结果缺尾）。
    let atCap = String(repeating: "甲", count: OwlSelectionPolish.maxSelectionLength)
    let messages = assembleMessages(selectedText: atCap, question: "概括")
    XCTAssertTrue(messages[1].content.contains(atCap))
    XCTAssertFalse(messages[1].content.contains(atCap + "…"))
  }

  func testLongExplicitSelectionIsTruncated() {
    let selection = String(repeating: "甲", count: OwlSelectionPolish.maxSelectionLength + 50)
    let messages = assembleMessages(selectedText: selection, question: "概括")
    let context = messages[1].content

    // 截断保留恰好 cap 个字符 + 省略号（加工规则拼在其后，故不再断言 hasSuffix）。
    XCTAssertTrue(context.contains(String(repeating: "甲", count: OwlSelectionPolish.maxSelectionLength) + "…"))
    XCTAssertFalse(context.contains(selection))
  }

  func testHistoryRendersAsAlternatingExplicitTurnsBeforeNewQuestion() async {
    let spy = SpyAskAnything()
    let model = OwlAIConversationModel(askAnything: spy)
    model.submit(question: "什么是善意取得？")
    await waitUntil { model.turns.count == 1 }
    model.submit(question: "它的构成要件呢？")
    await waitUntil { model.turns.count == 2 }
    model.submit(question: "第三项能举个例子吗？")
    let messages = spy.lastMessages
    model.teardown()

    XCTAssertEqual(
      messages.map(\.role),
      ["system", "user", "assistant", "user", "assistant", "user"]
    )
    XCTAssertEqual(messages[1].content, "什么是善意取得？")
    XCTAssertEqual(messages[2].content, "答复")
    XCTAssertEqual(messages[3].content, "它的构成要件呢？")
    XCTAssertEqual(messages[4].content, "答复")
    XCTAssertEqual(messages.last?.content, "第三项能举个例子吗？")
  }

  func testExplicitSelectionIsInjectedOnceAcrossLongHistory() async {
    let spy = SpyAskAnything()
    let model = OwlAIConversationModel(selectedText: "买卖合同第三条", askAnything: spy)
    for i in 1...6 {
      model.submit(question: "问题\(i)")
      await waitUntil { model.turns.count == i }
    }
    model.submit(question: "再追问一句")
    let messages = spy.lastMessages
    model.teardown()

    XCTAssertEqual(messages.filter { $0.content.contains("买卖合同第三条") }.count, 1)
    XCTAssertEqual(messages.filter { $0.role == "system" }.count, 2)
    let firstUserIndex = messages.firstIndex { $0.role == "user" } ?? messages.count
    let lastSystemIndex = messages.lastIndex { $0.role == "system" } ?? -1
    XCTAssertLessThan(lastSystemIndex, firstUserIndex)
  }

  func testOversizedExplicitTextUsesBusinessLimitsWithoutAnABIFailure() {
    let text = String(repeating: "文", count: 1_500_000)
    let messages = assembleMessages(selectedText: text, question: text)
    XCTAssertEqual(messages.last?.content, text)
    XCTAssertEqual(OwlAIContextAssembler.selectionSummary(text), String(repeating: "文", count: 2000) + "…")
    XCTAssertEqual(OwlSelectionPolish.rejectionReason(for: text), .selectionTooLong(1_500_000))
    let raw = "{\"status\":\"ok\",\"prompt\":\"" + text + "\"}"
    XCTAssertEqual(OwlStructuredDrafting.parse(raw), .ready(text))
  }

}
