//
//  RimeConfigDiagnosticsTests.swift
//  FamoTests — schema 配置一致性只读诊断 (task 07-07-schema-consistency-guard)
//
//  Locks the PURE classifier `FamoRimeConfigDiagnostics.classify`:
//    - healthy (preferred reachable across seed/build/schema_list, no shadow) → no headline code;
//    - each of FAMO-SCHEMA-001..004 fires on its own layer;
//    - FAMO-SCHEMA-005 (~/Library/Rime present) is ADVISORY (ok:nil) — never a headline failure;
//    - precedence: the headline names the most UPSTREAM failure (seed → build → schema_list).
//
//  No filesystem, no librime: pure value logic over synthetic observations, mirrors
//  ActivationPolicyTests / FamoForcedFinalizeTests.
//

import Foundation
import XCTest
@testable import Famo

final class RimeConfigDiagnosticsTests: XCTestCase {

  private func obs(
    preferred: String = "rime_ice",
    schemaList: [String] = ["rime_ice", "wubi86_jidian"],
    built: [String] = ["rime_ice", "wubi86_jidian"],
    seed: [String] = ["rime_ice", "wubi86_jidian"],
    manifestBase: String? = "rime-ice",
    shadow: Bool = false,
    foreignPresent: Bool = false,
    foreignHasPreferred: Bool? = nil
  ) -> RimeConfigObservation {
    RimeConfigObservation(
      preferredSchemaID: preferred, userSchemaList: schemaList, userBuiltSchemas: built,
      seedSchemas: seed, seedManifestBase: manifestBase, userDefaultYamlShadow: shadow,
      foreignRimeDirPresent: foreignPresent, foreignRimeHasPreferred: foreignHasPreferred)
  }

  private func layer(_ diag: RimeConfigDiagnosis, _ l: RimeConfigLayer) -> RimeConfigLayerResult {
    diag.layers.first { $0.layer == l }!
  }

  // Healthy machine: preferred reachable everywhere, no shadow, no foreign dir → no headline code.
  func testHealthyHasNoHeadlineCode() {
    let diag = FamoRimeConfigDiagnostics.classify(obs())
    XCTAssertNil(diag.code)
    XCTAssertNil(diag.firstFailingLayer)
    XCTAssertEqual(layer(diag, .seed).ok, true)
    XCTAssertEqual(layer(diag, .userBuild).ok, true)
    XCTAssertEqual(layer(diag, .userSchemaList).ok, true)
    XCTAssertEqual(layer(diag, .shadow).ok, true)
    XCTAssertNil(layer(diag, .prefs).ok)      // informational
    XCTAssertNil(layer(diag, .foreignDir).ok) // advisory ceiling
  }

  // Seed doesn't carry preferred → FAMO-SCHEMA-003 (stale install).
  func testStaleSeedIsCode003() {
    let diag = FamoRimeConfigDiagnostics.classify(obs(seed: ["wubi86_jidian"]))
    XCTAssertEqual(diag.code, "FAMO-SCHEMA-003")
    XCTAssertEqual(diag.firstFailingLayer, .seed)
    XCTAssertEqual(layer(diag, .seed).ok, false)
  }

  // Seed ok, but user build/ hasn't compiled preferred → FAMO-SCHEMA-002.
  func testUserBuildMissingIsCode002() {
    let diag = FamoRimeConfigDiagnostics.classify(obs(built: ["wubi86_jidian"]))
    XCTAssertEqual(diag.code, "FAMO-SCHEMA-002")
    XCTAssertEqual(diag.firstFailingLayer, .userBuild)
  }

  // Seed + build ok, but user schema_list dropped preferred (drift) → FAMO-SCHEMA-001.
  func testSchemaListDriftIsCode001() {
    let diag = FamoRimeConfigDiagnostics.classify(obs(schemaList: ["wubi86_jidian", "pinyin_simp"]))
    XCTAssertEqual(diag.code, "FAMO-SCHEMA-001")
    XCTAssertEqual(diag.firstFailingLayer, .userSchemaList)
  }

  // A full default.yaml in the user dir shadows the shared layer → FAMO-SCHEMA-004.
  func testUserDefaultYamlShadowIsCode004() {
    let diag = FamoRimeConfigDiagnostics.classify(obs(shadow: true))
    XCTAssertEqual(diag.code, "FAMO-SCHEMA-004")
    XCTAssertEqual(diag.firstFailingLayer, .shadow)
  }

  // ~/Library/Rime present but everything else healthy: FAMO-SCHEMA-005 is ADVISORY only — it tags
  // the foreignDir layer (ok:nil) but is NEVER the headline failure code.
  func testForeignRimeDirIsAdvisoryNotFailure() {
    let diag = FamoRimeConfigDiagnostics.classify(obs(foreignPresent: true, foreignHasPreferred: false))
    XCTAssertNil(diag.code)                             // not a headline failure
    XCTAssertNil(diag.firstFailingLayer)
    XCTAssertNil(layer(diag, .foreignDir).ok)           // advisory ceiling, never scored
    XCTAssertEqual(layer(diag, .foreignDir).code, "FAMO-SCHEMA-005")
  }

  // No ~/Library/Rime → foreignDir layer carries no advisory code.
  func testNoForeignRimeDirHasNoAdvisoryCode() {
    let diag = FamoRimeConfigDiagnostics.classify(obs(foreignPresent: false))
    XCTAssertNil(layer(diag, .foreignDir).code)
  }

  // Multiple failures → the headline names the most UPSTREAM one (seed before build before list).
  func testHeadlinePrefersMostUpstreamFailure() {
    let diag = FamoRimeConfigDiagnostics.classify(obs(schemaList: [], built: [], seed: []))
    XCTAssertEqual(diag.code, "FAMO-SCHEMA-003")   // seed is upstream of build/list
    XCTAssertEqual(diag.firstFailingLayer, .seed)
    // downstream failures are still reported in their layers
    XCTAssertEqual(layer(diag, .userBuild).ok, false)
    XCTAssertEqual(layer(diag, .userSchemaList).ok, false)
  }
}
