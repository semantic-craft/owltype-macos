//
//  OwlPromptInterceptionTests.swift
//  OwltypeTests — 提示词提交拦截的纯决策逻辑（R2）
//
//  The IMK side-effect (the actual `insertText`) can't be unit-tested (headless `IMKInputController`,
//  documented limitation), but the BRANCH logic at the commit chokepoint is extracted into the pure
//  `resolvePromptCommit(code:committedTitle:store:)` over the injected `PromptResolving` port, plus
//  the pure `OwlPromptStore.matchEntry` / `strippingMarker`. This locks:
//    1. The cheap 📝 gate: an unmarked commit returns `.passThrough` WITHOUT a store lookup, so
//       ordinary pinyin commits never read owl_prompts.json.
//    2. The marked branches: no-variable prompt → `.insert(body)`; `{{变量}}` prompt → `.fillIn`.
//    3. A marked-but-unknown title (store miss) → `.passThrough`.
//    4. `matchEntry`: (code, title) double match, the collision-proof `v{code}` tolerance, exact
//       precedence, and the title/code/empty miss cases.
//    5. `strippingMarker`: drops the 📝 prefix (and a following half/full-width space).
//
//  Uses `FakePromptStore` (defined in SeamPortsTests.swift) — no librime, no disk.
//

import Foundation
import XCTest
@testable import Owltype

@MainActor
final class OwlPromptInterceptionTests: XCTestCase {

  private let marker = OwlPromptStore.candidateMarker

  private func entry(_ code: String, _ title: String, _ body: String) -> OwlPromptEntry {
    OwlPromptEntry(code: code, title: title, body: body)
  }

  // MARK: - resolvePromptCommit branches

  func testUnmarkedCommitPassesThroughWithoutStoreLookup() {
    let store = FakePromptStore(entries: [entry("hetong", "合同审查", "正文")])
    // A normal pinyin commit (no 📝) must not even touch the store.
    let action = resolvePromptCommit(code: "hetong", committedTitle: "和通", store: store)
    XCTAssertEqual(action, .passThrough)
    XCTAssertTrue(store.queries.isEmpty, "ordinary commit must skip the store lookup (cheap 📝 gate)")
  }

  func testMarkedPromptWithoutVariablesInserts() {
    let store = FakePromptStore(entries: [entry("hetong", "合同审查", "请审查合同正文。")])
    let action = resolvePromptCommit(code: "hetong", committedTitle: marker + "合同审查", store: store)
    XCTAssertEqual(action, .insert("请审查合同正文。"))
    XCTAssertEqual(store.queries.count, 1)
    XCTAssertEqual(store.queries.first?.title, "合同审查", "marker must be stripped before lookup")
  }

  func testMarkedPromptWithVariablesPresentsFillIn() {
    let prompt = entry("fanyi", "翻译", "把下面译成{{语言}}：{{原文}}")
    let store = FakePromptStore(entries: [prompt])
    let action = resolvePromptCommit(code: "fanyi", committedTitle: marker + "翻译", store: store)
    XCTAssertEqual(action, .fillIn(prompt))
  }

  func testMarkedButUnknownTitlePassesThrough() {
    let store = FakePromptStore(entries: [entry("hetong", "合同审查", "正文")])
    // 📝 present but the store has no entry for this (code,title) → not a Owltype prompt.
    let action = resolvePromptCommit(code: "qita", committedTitle: marker + "其他", store: store)
    XCTAssertEqual(action, .passThrough)
    XCTAssertEqual(store.queries.count, 1, "a marked commit does consult the store once")
  }

  func testNilCodePassesThroughWithoutStoreLookup() {
    let store = FakePromptStore(entries: [entry("hetong", "合同审查", "正文")])
    let action = resolvePromptCommit(code: nil, committedTitle: marker + "合同审查", store: store)
    XCTAssertEqual(action, .passThrough)
    XCTAssertTrue(store.queries.isEmpty, "no originating code → no lookup")
  }

  // MARK: - matchEntry (the live resolver's pure core)

  private let pool = [
    OwlPromptEntry(code: "hetong", title: "合同审查", body: "B1"),
    OwlPromptEntry(code: "fanyi", title: "翻译", body: "B2"),
    OwlPromptEntry(code: "vhetong", title: "另一条", body: "B3"),
  ]

  func testMatchEntryExactCodeAndTitle() {
    XCTAssertEqual(OwlPromptStore.matchEntry(code: "hetong", title: "合同审查", in: pool)?.body, "B1")
  }

  func testMatchEntryCollisionProofVPrefix() {
    // Typing the collision-proof `vhetong` while the "合同审查" candidate (code hetong) was shown.
    XCTAssertEqual(OwlPromptStore.matchEntry(code: "vhetong", title: "合同审查", in: pool)?.code, "hetong")
  }

  func testMatchEntryExactCodeWinsOverVStrip() {
    // `vhetong` is itself a real code (title 另一条); an exact match must win over the v-strip path.
    XCTAssertEqual(OwlPromptStore.matchEntry(code: "vhetong", title: "另一条", in: pool)?.body, "B3")
  }

  func testMatchEntryTitleMismatchIsNil() {
    XCTAssertNil(OwlPromptStore.matchEntry(code: "hetong", title: "不同标题", in: pool))
  }

  func testMatchEntryCodeMismatchIsNil() {
    XCTAssertNil(OwlPromptStore.matchEntry(code: "zzz", title: "合同审查", in: pool))
  }

  func testMatchEntryEmptyCodeIsNil() {
    XCTAssertNil(OwlPromptStore.matchEntry(code: "  ", title: "合同审查", in: pool))
  }

  func testMatchEntryLowercasesCode() {
    XCTAssertEqual(OwlPromptStore.matchEntry(code: "HETONG", title: "合同审查", in: pool)?.body, "B1")
  }

  // MARK: - strippingMarker

  func testStrippingMarker() {
    XCTAssertEqual(OwlPromptStore.strippingMarker("📝合同审查"), "合同审查")
    XCTAssertEqual(OwlPromptStore.strippingMarker("📝 合同审查"), "合同审查", "ASCII space after marker dropped")
    XCTAssertEqual(OwlPromptStore.strippingMarker("📝\u{3000}合同审查"), "合同审查", "full-width space dropped")
    XCTAssertEqual(OwlPromptStore.strippingMarker("普通候选"), "普通候选", "no marker → unchanged")
  }
}
