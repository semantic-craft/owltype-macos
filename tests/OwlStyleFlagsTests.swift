//
//  OwlStyleFlagsTests.swift
//  OwltypeTests — inline 旗标决策纯函数锁（2026-07-12，#90 真机诊断产出）
//
//  Locks `OwlStyleFlags.sessionInline` — the per-session inline resolution hoisted out of
//  `rimeUpdate` when the flags moved to per-round recompute (B3 闩锁修复). The precedence it
//  pins: global style ∧ ¬no_inline, with the app_options `inline` force-override winning for
//  the PREEDIT only (squirrel#435 先例，Chromium omnibox 规避). Pure value math — no config,
//  no librime.
//

import XCTest
@testable import Owltype

final class OwlStyleFlagsTests: XCTestCase {

  private func flags(inlinePreedit: Bool, inlineCandidate: Bool) -> OwlStyleFlags {
    var made = OwlStyleFlags()
    made.inlinePreedit = inlinePreedit
    made.inlineCandidate = inlineCandidate
    return made
  }

  func test_globalInline_normalHost() {
    // 出厂 famo.yaml：inline_preedit=true / inline_candidate=false；普通宿主无选项。
    let r = OwlStyleFlags.sessionInline(
      style: flags(inlinePreedit: true, inlineCandidate: false), noInline: false, inlineForced: false)
    XCTAssertTrue(r.preedit)
    XCTAssertFalse(r.candidate)
  }

  func test_noInline_terminalHost_disablesBoth() {
    // iTerm2/Terminal app_options no_inline=true：内嵌全关（全角占位模式）。
    let r = OwlStyleFlags.sessionInline(
      style: flags(inlinePreedit: true, inlineCandidate: true), noInline: true, inlineForced: false)
    XCTAssertFalse(r.preedit)
    XCTAssertFalse(r.candidate)
  }

  func test_inlineForced_overridesNoInline_forPreeditOnly() {
    // Chrome app_options inline=true：preedit 强制内嵌，压过 no_inline；candidate 不被强制。
    let r = OwlStyleFlags.sessionInline(
      style: flags(inlinePreedit: true, inlineCandidate: true), noInline: true, inlineForced: true)
    XCTAssertTrue(r.preedit)
    XCTAssertFalse(r.candidate)
  }

  func test_inlineForced_rescuesDegradedStyle() {
    // 承重回归锁：styleFlags 被毒化成全默认（inlinePreedit=false，B1/B2 场景）时，Chrome 的
    // inline 强制仍须让 preedit 内嵌——这正是本次诊断里「Chrome 曾正常」的机制，不能丢。
    let r = OwlStyleFlags.sessionInline(
      style: OwlStyleFlags(), noInline: false, inlineForced: true)
    XCTAssertTrue(r.preedit)
    XCTAssertFalse(r.candidate)
  }

  func test_degradedStyle_noForce_isPlaceholderMode() {
    // 毒化 + 无强制 = 占位模式（本 bug 的用户可见形态）；此案例记录现象、防语义漂移。
    let r = OwlStyleFlags.sessionInline(style: OwlStyleFlags(), noInline: false, inlineForced: false)
    XCTAssertFalse(r.preedit)
    XCTAssertFalse(r.candidate)
  }
}
