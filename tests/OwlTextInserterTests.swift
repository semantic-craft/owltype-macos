//
//  OwlTextInserterTests.swift
//  OwltypeTests — 技能输出回填插入（Vulcan 多策略兜底）
//
//  锁死梯子排序 + 编排 + 按 App 缓存（原语注入，无 AX/CGEvent）。真机三场景冒烟见 task AC7。
//  用 fresh OwlTextInserter() 实例避免 .shared 缓存跨测试泄漏。
//

import XCTest
@testable import Owltype

@MainActor
final class OwlTextInserterTests: XCTestCase {

  func testCaretInsertionPrefersIMKThenFallsBackToPaste() {
    var pasteCalled = false
    let directOutcome = OwlTemplateHostDelivery.insertCaretOrFallback(
      "hello",
      imkInsert: { _ in true },
      paste: { _ in pasteCalled = true; return true },
      copyOnly: { _ in }
    )
    XCTAssertEqual(directOutcome, .inserted(.imkInsert))
    XCTAssertFalse(pasteCalled)

    let fallbackOutcome = OwlTemplateHostDelivery.insertCaretOrFallback(
      "world",
      imkInsert: { _ in false },
      paste: { _ in pasteCalled = true; return true },
      copyOnly: { _ in }
    )
    XCTAssertEqual(fallbackOutcome, .inserted(.paste))
    XCTAssertTrue(pasteCalled)
  }

  // MARK: - AC2 AX 成功

  func testAXSuccessInsertsDirectlyWithoutFallbacks() {
    var pasteCalled = false
    var copyCalled = false
    let inserter = OwlTextInserter()
    let outcome = inserter.insert(
      "x", bundleID: "com.a",
      axSet: { true },
      paste: { _ in pasteCalled = true; return true },
      copyOnly: { _ in copyCalled = true }
    )
    XCTAssertEqual(outcome, .inserted(.axSelectedText))
    XCTAssertFalse(pasteCalled)
    XCTAssertFalse(copyCalled)
  }

  // MARK: - AC3 AX 失败 → paste

  func testPasteFallbackWhenAXFails() {
    var copyCalled = false
    let inserter = OwlTextInserter()
    let outcome = inserter.insert(
      "x", bundleID: "com.a",
      axSet: { false },
      paste: { _ in true },
      copyOnly: { _ in copyCalled = true }
    )
    XCTAssertEqual(outcome, .inserted(.paste))
    XCTAssertFalse(copyCalled)
  }

  // MARK: - AC4 都失败 → clipboardOnly 终态

  func testClipboardOnlyWhenAXAndPasteFail() {
    var copied: String?
    let inserter = OwlTextInserter()
    let outcome = inserter.insert(
      "hello", bundleID: "com.a",
      axSet: { false },
      paste: { _ in false },
      copyOnly: { copied = $0 }
    )
    XCTAssertEqual(outcome, .copiedToClipboard)
    XCTAssertEqual(copied, "hello")
  }

  // MARK: - AC5 缓存

  func testCacheTriesLastWinnerFirst() {
    let inserter = OwlTextInserter()
    // 首次：AX 失败、paste 赢 → 缓存 com.a = .paste。
    _ = inserter.insert("x", bundleID: "com.a", axSet: { false }, paste: { _ in true }, copyOnly: { _ in })
    // 二次：paste 应先试；axSet 不该被调用。
    var axCalled = false
    let outcome = inserter.insert(
      "y", bundleID: "com.a",
      axSet: { axCalled = true; return true },
      paste: { _ in true },
      copyOnly: { _ in }
    )
    XCTAssertEqual(outcome, .inserted(.paste))
    XCTAssertFalse(axCalled)
  }

  func testCacheIsPerBundle() {
    let inserter = OwlTextInserter()
    _ = inserter.insert("x", bundleID: "com.a", axSet: { false }, paste: { _ in true }, copyOnly: { _ in })
    // 另一个 bundle → 无缓存 → axSet 先试。
    var axCalled = false
    _ = inserter.insert(
      "y", bundleID: "com.b",
      axSet: { axCalled = true; return true },
      paste: { _ in true },
      copyOnly: { _ in }
    )
    XCTAssertTrue(axCalled)
  }
}
