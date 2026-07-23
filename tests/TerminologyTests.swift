//
//  TerminologyTests.swift
//  FamoTests — 术语锁 (Terminology Lock, blueprint_v2 P0 pillar, task 06-20-famo-terminology-lock)
//
//  Locks the 术语锁 contract on two axes:
//    1. The PURE `FamoTerminology.apply(candidates:rules:)` reordering/filtering function:
//       preferred forms promoted to the top, forbidden variants removed, allowed variants kept,
//       plus the boundary cases (empty rules → unchanged; preferred not present → synthesized /
//       no-op without disturbing the rest).
//    2. `FamoProject` codec backward-compatibility: a `project.json` written before terminology
//       existed (no `termRules` key) still decodes, with `termRules` defaulting to empty; and a
//       round-trip preserves rules once present.
//
//  No network, no librime, no disk: `apply` is pure and the codec test drives JSON in memory.
//

import Foundation
import XCTest
@testable import Famo

final class TerminologyTests: XCTestCase {

  // MARK: - Helpers

  /// A smart-lane candidate carrying `text` for a fixed snapshot. `source`/`commitMode` mirror
  /// the project-word injection path so promotion/removal is tested on realistic candidates.
  private func smart(_ text: String, score: Double = 0) -> EnhancedCandidate {
    EnhancedCandidate(
      snapshotID: 1,
      source: .localStat,
      lane: .smart,
      text: text,
      score: score,
      commitMode: .externalText
    )
  }

  private func texts(_ candidates: [EnhancedCandidate]) -> [String] {
    candidates.map(\.text)
  }

  // MARK: - Preferred promoted (≥3)

  func testPreferredPromotedFromMiddle() {
    let rules = [FamoTermRule(preferred: "正当防卫")]
    let input = [smart("紧急避险"), smart("正当防卫"), smart("自首")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertEqual(texts(out), ["正当防卫", "紧急避险", "自首"])
  }

  func testPreferredPromotedFromTail() {
    let rules = [FamoTermRule(preferred: "管辖权")]
    let input = [smart("受理"), smart("立案"), smart("管辖权")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertEqual(texts(out).first, "管辖权")
    // The non-preferred candidates keep their original relative order.
    XCTAssertEqual(texts(out), ["管辖权", "受理", "立案"])
  }

  func testMultipleRulesPromotedInRuleOrder() {
    let rules = [
      FamoTermRule(preferred: "撤销"),
      FamoTermRule(preferred: "变更"),
    ]
    let input = [smart("驳回"), smart("变更"), smart("维持"), smart("撤销")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    // Both preferred forms at the front, in RULE order (撤销 before 变更), rest after.
    XCTAssertEqual(texts(out), ["撤销", "变更", "驳回", "维持"])
  }

  func testPreferredAbsentIsSynthesizedToTop() {
    // Preferred form not among the candidates → synthesized at the top with 「项目」provenance,
    // leaving the existing candidates untouched after it.
    let rules = [FamoTermRule(preferred: "上诉")]
    let input = [smart("申诉"), smart("再审")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertEqual(texts(out), ["上诉", "申诉", "再审"])
    // The synthesized preferred candidate carries the 「项目」provenance (smart + localNeural).
    XCTAssertEqual(out.first?.provenance(), .project)
  }

  // MARK: - Forbidden removed (≥3)

  func testForbiddenVariantRemoved() {
    let rules = [FamoTermRule(preferred: "原告", forbiddenVariants: ["告方"])]
    let input = [smart("原告"), smart("告方"), smart("被告")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertFalse(texts(out).contains("告方"))
    XCTAssertEqual(texts(out), ["原告", "被告"])
  }

  func testMultipleForbiddenVariantsRemoved() {
    let rules = [FamoTermRule(preferred: "上诉人", forbiddenVariants: ["上告人", "抗诉人"])]
    let input = [smart("上诉人"), smart("上告人"), smart("被上诉人"), smart("抗诉人")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertEqual(texts(out), ["上诉人", "被上诉人"])
  }

  func testForbiddenAcrossSeveralRulesRemoved() {
    let rules = [
      FamoTermRule(preferred: "合同", forbiddenVariants: ["契约"]),
      FamoTermRule(preferred: "解除", forbiddenVariants: ["撤销"]),
    ]
    let input = [smart("合同"), smart("契约"), smart("解除"), smart("撤销"), smart("终止")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertEqual(texts(out), ["合同", "解除", "终止"])
  }

  func testPreferredFormIsNeverRemovedEvenIfAlsoForbiddenElsewhere() {
    // 撤销 is preferred in one rule and forbidden in another → preferred wins, it is kept + promoted.
    let rules = [
      FamoTermRule(preferred: "撤销"),
      FamoTermRule(preferred: "解除", forbiddenVariants: ["撤销"]),
    ]
    let input = [smart("解除"), smart("撤销"), smart("终止")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertTrue(texts(out).contains("撤销"), "a preferred term must never be removed by a forbidden list")
    XCTAssertEqual(texts(out), ["撤销", "解除", "终止"])
  }

  // MARK: - Allowed kept (≥3)

  func testAllowedVariantKept() {
    let rules = [FamoTermRule(preferred: "证据", allowedVariants: ["书证"])]
    let input = [smart("证据"), smart("书证"), smart("物证")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertTrue(texts(out).contains("书证"), "allowed variants are never removed")
    XCTAssertEqual(texts(out), ["证据", "书证", "物证"])
  }

  func testAllowedVariantNotPromotedOverPreferred() {
    // Allowed variant present before the preferred form; preferred is still promoted to the top,
    // the allowed variant stays in the body (kept, not promoted).
    let rules = [FamoTermRule(preferred: "判决", allowedVariants: ["裁判"])]
    let input = [smart("裁判"), smart("判决"), smart("裁定")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertEqual(texts(out), ["判决", "裁判", "裁定"])
  }

  func testAllowedKeptWhileForbiddenRemovedInSameRule() {
    let rules = [
      FamoTermRule(preferred: "管辖", allowedVariants: ["专属管辖"], forbiddenVariants: ["管辖区"]),
    ]
    let input = [smart("管辖"), smart("专属管辖"), smart("管辖区"), smart("级别管辖")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertTrue(texts(out).contains("专属管辖"), "allowed variant kept")
    XCTAssertFalse(texts(out).contains("管辖区"), "forbidden variant removed")
    XCTAssertEqual(texts(out), ["管辖", "专属管辖", "级别管辖"])
  }

  // MARK: - Boundaries

  func testEmptyRulesReturnsCandidatesUnchanged() {
    let input = [smart("甲"), smart("乙"), smart("丙")]
    let out = FamoTerminology.apply(candidates: input, rules: [])
    XCTAssertEqual(texts(out), texts(input))
    // Identity: same candidate ids, same order.
    XCTAssertEqual(out.map(\.id), input.map(\.id))
  }

  func testRulesWithBlankPreferredAndNoForbiddenAreNoOp() {
    let rules = [FamoTermRule(preferred: "   ")]  // inert: blank preferred, no forbidden
    let input = [smart("甲"), smart("乙")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertEqual(out.map(\.id), input.map(\.id), "an inert rule must leave candidates unchanged")
  }

  func testEmptyCandidatesReturnsEmpty() {
    let rules = [FamoTermRule(preferred: "上诉", forbiddenVariants: ["上告"])]
    let out = FamoTerminology.apply(candidates: [], rules: rules)
    XCTAssertTrue(out.isEmpty, "no candidates → nothing to synthesize from; empty stays empty")
  }

  func testForbiddenOnlyRuleFiltersWithoutPromotion() {
    // A forbidden-only rule (blank preferred) removes the variant but adds no promoted block.
    let rules = [FamoTermRule(preferred: "  ", forbiddenVariants: ["告方"])]
    let input = [smart("原告"), smart("告方"), smart("被告")]
    let out = FamoTerminology.apply(candidates: input, rules: rules)
    XCTAssertEqual(texts(out), ["原告", "被告"])
  }

  // MARK: - FamoProject codec backward-compatibility

  func testOldProjectJSONWithoutTermRulesStillDecodes() throws {
    // A project.json written before 术语锁 existed has NO `termRules` key. It must still decode,
    // with `termRules` defaulting to empty.
    let legacyJSON = """
    {
      "id" : "abc123",
      "name" : "旧项目",
      "words" : ["本院认为", "依照"],
      "abbreviations" : { "民诉" : "民事诉讼法" },
      "createdAt" : "2026-06-19T10:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = Data(legacyJSON.utf8)

    let project = try decoder.decode(FamoProject.self, from: data)
    XCTAssertEqual(project.id, "abc123")
    XCTAssertEqual(project.name, "旧项目")
    XCTAssertEqual(project.words, ["本院认为", "依照"])
    XCTAssertEqual(project.abbreviations, ["民诉": "民事诉讼法"])
    XCTAssertTrue(project.termRules.isEmpty, "missing termRules key must default to empty")
  }

  func testProjectTermRulesRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let rule = FamoTermRule(
      preferred: "正当防卫",
      allowedVariants: ["防卫"],
      forbiddenVariants: ["自卫"]
    )
    let project = FamoProject(name: "刑法", words: ["故意"], termRules: [rule])

    let data = try encoder.encode(project)
    let reloaded = try decoder.decode(FamoProject.self, from: data)

    XCTAssertEqual(reloaded.termRules.count, 1)
    XCTAssertEqual(reloaded.termRules.first?.preferred, "正当防卫")
    XCTAssertEqual(reloaded.termRules.first?.allowedVariants, ["防卫"])
    XCTAssertEqual(reloaded.termRules.first?.forbiddenVariants, ["自卫"])
    XCTAssertEqual(reloaded.termRules.first?.id, rule.id, "rule id round-trips")
  }
}
