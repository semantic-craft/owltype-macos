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

  func testLongExplicitSelectionIsTruncated() {
    let selection = String(repeating: "甲", count: FamoAIContextAssembler.selectedTextCharCap + 50)
    let messages = FamoAIContextAssembler.assemble(selectedText: selection, question: "概括")
    let context = messages[1].content

    XCTAssertTrue(context.hasSuffix("…"))
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
