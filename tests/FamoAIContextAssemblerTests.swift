//
//  FamoAIContextAssemblerTests.swift
//  FamoTests — cloud-request privacy boundary
//

import Foundation
import XCTest
@testable import Famo

final class FamoAIContextAssemblerTests: XCTestCase {

  func testGeneralQuestionContainsOnlySystemPromptAndExplicitQuestion() {
    let messages = FamoAIContextAssembler.assemble(question: "  帮我解释善意取得  ")

    XCTAssertEqual(messages.map(\.role), ["system", "user"])
    XCTAssertEqual(messages.last?.content, "帮我解释善意取得")
  }

  func testExplicitSelectionIsIncludedOnceBeforeQuestion() {
    let messages = FamoAIContextAssembler.assemble(
      selectedText: "买卖合同第三条",
      question: "改得更正式"
    )

    XCTAssertEqual(messages.map(\.role), ["system", "system", "user"])
    XCTAssertEqual(messages.filter { $0.content.contains("买卖合同第三条") }.count, 1)
    XCTAssertEqual(messages.last?.content, "改得更正式")
  }

  func testWhitespaceSelectionIsNotAdded() {
    let messages = FamoAIContextAssembler.assemble(selectedText: " \n\t ", question: "你好")
    XCTAssertEqual(messages.map(\.role), ["system", "user"])
  }

  func testSelectionProcessingRuleRidesWithSelectionOnly() throws {
    // 带选区：加工规则拼在选区消息里（不可信文本之后），保证「把引号替换掉」这类指令只回结果。
    let withSelection = FamoAIContextAssembler.assemble(selectedText: "选中原文", question: "把引号替换掉")
    let selectionMessage = withSelection[1].content
    XCTAssertTrue(selectionMessage.contains(FamoAIContextAssembler.selectionProcessingRule))
    let textIndex = try XCTUnwrap(selectionMessage.range(of: "选中原文")).lowerBound
    let ruleIndex = try XCTUnwrap(selectionMessage.range(of: "[选中文本加工规则]")).lowerBound
    XCTAssertLessThan(textIndex, ruleIndex, "rule must come AFTER the untrusted selection text")

    // 无选区的纯提问：任何消息都不带加工规则，一般问答不受影响。
    let withoutSelection = FamoAIContextAssembler.assemble(question: "什么是善意取得？")
    XCTAssertFalse(withoutSelection.contains { $0.content.contains("[选中文本加工规则]") })
  }

  func testSelectionCapMatchesSelectionMenuGate() {
    // 划词菜单放行 ≤ maxSelectionLength 的选区；装配器上限必须不小于它，否则菜单放进来的长选区
    // 会被静默截残（加工结果缺尾）。
    XCTAssertEqual(FamoAIContextAssembler.selectedTextCharCap, FamoSelectionPolish.maxSelectionLength)
  }

  func testLongExplicitSelectionIsTruncated() {
    let selection = String(repeating: "甲", count: FamoAIContextAssembler.selectedTextCharCap + 50)
    let messages = FamoAIContextAssembler.assemble(selectedText: selection, question: "概括")
    let context = messages[1].content

    // 截断保留恰好 cap 个字符 + 省略号（加工规则拼在其后，故不再断言 hasSuffix）。
    XCTAssertTrue(context.contains(String(repeating: "甲", count: FamoAIContextAssembler.selectedTextCharCap) + "…"))
    XCTAssertFalse(context.contains(selection))
  }

  func testHistoryRendersAsAlternatingExplicitTurnsBeforeNewQuestion() {
    let messages = FamoAIContextAssembler.assemble(
      history: [
        FamoConversationTurn(question: "什么是善意取得？", answer: "善意取得是指…"),
        FamoConversationTurn(question: "它的构成要件呢？", answer: "需要满足三项…")
      ],
      question: "第三项能举个例子吗？"
    )

    XCTAssertEqual(
      messages.map(\.role),
      ["system", "user", "assistant", "user", "assistant", "user"]
    )
    XCTAssertEqual(messages[1].content, "什么是善意取得？")
    XCTAssertEqual(messages[2].content, "善意取得是指…")
    XCTAssertEqual(messages.last?.content, "第三项能举个例子吗？")
  }

  func testExplicitSelectionIsInjectedOnceAcrossLongHistory() {
    let history = (1...6).map {
      FamoConversationTurn(question: "问题\($0)", answer: "回答\($0)")
    }
    let messages = FamoAIContextAssembler.assemble(
      selectedText: "买卖合同第三条",
      history: history,
      question: "再追问一句"
    )

    XCTAssertEqual(messages.filter { $0.content.contains("买卖合同第三条") }.count, 1)
    XCTAssertEqual(messages.filter { $0.role == "system" }.count, 2)
    let firstUserIndex = messages.firstIndex { $0.role == "user" } ?? messages.count
    let lastSystemIndex = messages.lastIndex { $0.role == "system" } ?? -1
    XCTAssertLessThan(lastSystemIndex, firstUserIndex)
  }
}
