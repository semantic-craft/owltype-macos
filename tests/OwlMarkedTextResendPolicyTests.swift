//
//  OwlMarkedTextResendPolicyTests.swift
//  OwltypeTests — #89（spec 主线仓#88 §3）
//
//  行为锁：合成期任意按键序列 → setMarkedText 重发次数 = 合成期回合数（防内容去重回归，
//  即 #89 任务 3a）。以 (previous, next) preedit 序列模拟 show() 的逐键决策——决策层与
//  show() 共用 OwlMarkedTextResendPolicy，故此处锁死策略即锁死 show() 的重发语义。
//

import XCTest
@testable import Owltype

final class OwlMarkedTextResendPolicyTests: XCTestCase {

  /// 逐键回放：rounds = 每轮渲染出的 marked text（时序），返回会真正重发的轮数。
  private func sendCount(initial: String = "", rounds: [String]) -> Int {
    var previous = initial
    var sent = 0
    // 未重发的轮 previous 不更新——镜像 show() 早退时 self.preedit 保持不变的语义。
    for next in rounds where OwlMarkedTextResendPolicy.shouldSend(previous: previous, next: next) {
      sent += 1
      previous = next
    }
    return sent
  }

  // MARK: - 每键重发（去重回归锁）

  func test_constantPlaceholder_everyKeyResends() {
    // no_inline 常量全角空格占位：内容逐键不变——旧守卫在此静默（squirrel#906 根因），
    // 新契约每键必发。5 个合成期回合 → 5 次重发。
    XCTAssertEqual(sendCount(rounds: ["　", "　", "　", "　", "　"]), 5)
  }

  func test_inlineCandidate_backspaceKeepsFirstCandidate_everyKeyResends() {
    // inline candidate 退格后首候选常不变（#88 §1 inline 模式死因）：内容相同仍必须重发。
    XCTAssertEqual(sendCount(rounds: ["中华", "中华", "中华"]), 3)
  }

  func test_typingSequence_everyConsumedKeyResends() {
    // 正常组码 + 逐码退格 + 删空收尾：每个合成期回合都发；最后的空→空闲置轮不发。
    let rounds = ["z", "zh", "zho", "zh", "z", "", ""]
    XCTAssertEqual(sendCount(rounds: rounds), 6)  // 只有末轮（空→空）被短路
  }

  // MARK: - 清理回合必发（zws 退出面）

  func test_escClearingRound_sends() {
    // 非空→空 = ESC/删空的清理回合：必须发 setMarkedText("") 清客户端 marked text。
    XCTAssertTrue(OwlMarkedTextResendPolicy.shouldSend(previous: "zhong", next: ""))
    // zws keep-alive 之后的清理同样必发（zws 非空 → 空）。
    XCTAssertTrue(OwlMarkedTextResendPolicy.shouldSend(
      previous: EngineCompositionRenderer.compositionKeepAlive, next: ""))
  }

  // MARK: - 唯一短路：空→空（闲置轮零 IPC 现状）

  func test_idleRounds_doNotSend() {
    XCTAssertFalse(OwlMarkedTextResendPolicy.shouldSend(previous: "", next: ""))
    // 连续闲置（ASCII 模式打字、handled=false 穿透轮）：零重发。
    XCTAssertEqual(sendCount(rounds: ["", "", "", ""]), 0)
  }

  func test_compositionStartAfterIdle_sends() {
    // 闲置 → 首个组码键：空→非空必发（合成建立）。
    XCTAssertEqual(sendCount(rounds: ["", "z", "zh"]), 2)
  }
}
