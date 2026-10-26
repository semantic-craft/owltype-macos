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
//    2. The marked branches: both prompt forms → `.invoke(entry)` preserving the exact selected version.
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
    XCTAssertEqual(action, .invoke(entry("hetong", "合同审查", "请审查合同正文。")))
    XCTAssertEqual(store.queries.count, 1)
    XCTAssertEqual(store.queries.first?.title, "合同审查", "marker must be stripped before lookup")
  }

  func testMarkedPromptWithVariablesPresentsFillIn() {
    let prompt = entry("fanyi", "翻译", "把下面译成{{语言}}：{{原文}}")
    let store = FakePromptStore(entries: [prompt])
    let action = resolvePromptCommit(code: "fanyi", committedTitle: marker + "翻译", store: store)
    XCTAssertEqual(action, .invoke(prompt))
  }

  func testExplicitQuickPhrasePromptRetainsInvocationContext() {
    let prompt = entry("fanyi", "翻译", "把下面译成{{语言}}：{{原文}}")
    let store = FakePromptStore(entries: [prompt])
    XCTAssertEqual(resolvePromptCommit(code: "Kfanyi", committedTitle: marker + "翻译", store: store), .invoke(prompt))
    XCTAssertEqual(store.queries.first?.code, "fanyi")
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

  // MARK: - Shared invocation (real parser and fill model, synthetic host)

  func testResolvedCandidateAndSelectedEntryHaveSameInvocationSemantics() {
    for body in ["  多行\n\t正文🙂  ", "{{语言}}: {{原文}} / {{语言}}"] {
      let selected = entry("sample", "模板", body)
      let store = FakePromptStore(entries: [selected])
      guard case .invoke(let candidate) = resolvePromptCommit(
        code: "sample", committedTitle: marker + selected.title, store: store
      ) else { return XCTFail("candidate must enter the shared invocation") }
      for content in [OwlTemplateInvocation.Content.prompt(selected), .prompt(candidate)] {
        var events: [String] = []
        let broker = OwlPanelInsertionBroker(captureFrontmost: { .init(restore: { events.append("restore original") }, isRestored: { true }) },
                                            pasteboardWrite: { _ in XCTFail("must not copy"); return false })
        broker.capture()
        let invocation = OwlTemplateInvocation(content: content, broker: broker,
                                               deliver: { events.append($0.text); return .confirmed })
        var fill: OwlPromptFillModel?
        invocation.start { fill = OwlPromptFillModel(entry: selected, invocation: $0) }
        if let fill {
          XCTAssertEqual(fill.variables, ["语言", "原文"])
          fill.values = ["语言": "中文", "原文": "🙂\n第二行"]
          let preview = fill.filledBody
          invocation.confirm(values: fill.values)
          XCTAssertEqual(events, ["restore original", preview])
          XCTAssertEqual(preview, "中文: 🙂\n第二行 / 中文")
        } else {
          XCTAssertEqual(events, ["restore original", body])
        }
        // Repeated confirmation and cancellation cannot deliver a second time.
        invocation.confirm(values: ["语言": "different"])
        invocation.cancel(.windowClosed)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(invocation.content, .prompt(selected))
      }
    }
  }

  func testPlainTextDoesNotInterpretBracesOrNormalizeWhitespace() {
    let text = "  {{原样}}\n\t{clipboard}🙂  "
    var output: [String] = []
    let broker = OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { _ in XCTFail("direct insertion must not touch clipboard"); return false })
    let invocation = OwlTemplateInvocation(content: .plainText(text), broker: broker,
                                           deliver: { output.append($0.text); return .confirmed })
    invocation.start { _ in XCTFail("plain text must not request parameters") }
    invocation.start { _ in XCTFail("already submitted") }
    XCTAssertEqual(output, [text])
    XCTAssertEqual(invocation.state, .completed(.init(text: text), .confirmed))
  }

  func testCancelAndCloseDoNotInsertAndRetainTheirReason() {
    for reason in [OwlTemplateInvocation.Cancellation.user, .windowClosed, .replaced] {
      var restores = 0
      let broker = OwlPanelInsertionBroker(captureFrontmost: { .init(restore: { restores += 1 }, isRestored: { true }) },
                                          pasteboardWrite: { _ in XCTFail("no copy on cancel"); return false })
      broker.capture()
      let invocation = OwlTemplateInvocation(content: .prompt(entry("a", "A", "{{材料}}")),
                                             broker: broker, deliver: { _ in XCTFail("no insert"); return .notAttempted(.missingHost) })
      var presentations = 0
      invocation.start { _ in presentations += 1 }
      invocation.start { _ in presentations += 1 }
      invocation.cancel(reason, restoreFocus: reason != .replaced)
      invocation.confirm(values: ["材料": "must not insert"])
      XCTAssertEqual(invocation.state, .cancelled(reason))
      XCTAssertEqual(presentations, 1)
      XCTAssertEqual(restores, reason == .replaced ? 0 : 1)
    }
  }

  func testLegacyEmptyValuesAndRepeatedParameterArePreserved() {
    let selected = entry("a", "A", "{{材料}}/{{材料}}")
    var output: String?
    let invocation = OwlTemplateInvocation(content: .prompt(selected),
      broker: OwlPanelInsertionBroker(captureFrontmost: { nil }, pasteboardWrite: { _ in true }),
      deliver: { output = $0.text; return .confirmed })
    let model = OwlPromptFillModel(entry: selected, invocation: invocation)
    XCTAssertEqual(model.variables, ["材料"])
    XCTAssertEqual(model.values, ["材料": ""])
    XCTAssertEqual(model.filledBody, "/")
    invocation.confirm(values: model.values)
    XCTAssertEqual(output, "/")
  }

  // MARK: - Commit mode transition

  func testOnlyStandaloneDollarCommitEntersEnglishMode() {
    let examples: [(text: String, entersEnglish: Bool)] = [
      ("$", true),
      ("¥", false),
      ("$100", false),
      ("普通文本", false)
    ]

    for example in examples {
      let session = FakeRimeSession(optionState: [.asciiMode: false])
      applyCommitModeTransition(after: example.text, to: session)
      XCTAssertEqual(session.option(.asciiMode), example.entersEnglish, example.text)
    }
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
