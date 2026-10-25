//
//  RimeConfigDiagnosticsTests.swift
//  OwltypeTests — schema 配置一致性只读诊断 (task 07-07-schema-consistency-guard)
//
//  Locks the PURE classifier `OwlRimeConfigDiagnostics.classify`:
//    - healthy (preferred reachable across seed/build/schema_list, no shadow) → no headline code;
//    - each of OWL-SCHEMA-001..004 fires on its own layer;
//    - OWL-SCHEMA-005 (~/Library/Rime present) is ADVISORY (ok:nil) — never a headline failure;
//    - precedence: the headline names the most UPSTREAM failure (seed → build → schema_list).
//
//  No filesystem, no librime: pure value logic over synthetic observations, mirrors
//  ActivationPolicyTests / OwlForcedFinalizeTests.
//

import Foundation
import XCTest
@testable import Owltype

final class RimeConfigDiagnosticsTests: XCTestCase {

  private func obs(
    preferred: String = "rime_ice",
    schemaList: [String] = ["rime_ice", "wubi86_jidian"],
    built: [String] = ["rime_ice", "wubi86_jidian"],
    seed: [String] = ["rime_ice", "wubi86_jidian"],
    dictPackManaged: Bool = false,
    manifestBase: String? = "rime-ice",
    shadow: Bool = false,
    foreignPresent: Bool = false,
    foreignHasPreferred: Bool? = nil
  ) -> RimeConfigObservation {
    RimeConfigObservation(
      preferredSchemaID: preferred, userSchemaList: schemaList, userBuiltSchemas: built,
      seedSchemas: seed, preferredIsDictPackManaged: dictPackManaged,
      seedManifestBase: manifestBase, userDefaultYamlShadow: shadow,
      foreignRimeDirPresent: foreignPresent, foreignRimeHasPreferred: foreignHasPreferred)
  }

  private func layer(_ diag: RimeConfigDiagnosis, _ l: RimeConfigLayer) -> RimeConfigLayerResult {
    diag.layers.first { $0.layer == l }!
  }

  // Healthy machine: preferred reachable everywhere, no shadow, no foreign dir → no headline code.
  func testHealthyHasNoHeadlineCode() {
    let diag = OwlRimeConfigDiagnostics.classify(obs())
    XCTAssertNil(diag.code)
    XCTAssertNil(diag.firstFailingLayer)
    XCTAssertEqual(layer(diag, .seed).ok, true)
    XCTAssertEqual(layer(diag, .userBuild).ok, true)
    XCTAssertEqual(layer(diag, .userSchemaList).ok, true)
    XCTAssertEqual(layer(diag, .shadow).ok, true)
    XCTAssertNil(layer(diag, .prefs).ok)      // informational
    XCTAssertNil(layer(diag, .foreignDir).ok) // advisory ceiling
  }

  // Seed doesn't carry preferred → OWL-SCHEMA-003 (stale install).
  func testStaleSeedIsCode003() {
    let diag = OwlRimeConfigDiagnostics.classify(obs(seed: ["wubi86_jidian"]))
    XCTAssertEqual(diag.code, "OWL-SCHEMA-003")
    XCTAssertEqual(diag.firstFailingLayer, .seed)
    XCTAssertEqual(layer(diag, .seed).ok, false)
  }

  // Dict-pack schemas intentionally do not ship in SharedSupport. Once Wubi is present in the
  // user build and schema_list, a missing bundled seed is healthy rather than a stale installer.
  func testDictPackSchemaDoesNotRequireBundledSeed() {
    let diag = OwlRimeConfigDiagnostics.classify(obs(
      preferred: "wubi86_jidian",
      schemaList: ["wubi86_jidian"],
      built: ["wubi86_jidian"],
      seed: ["rime_ice"],
      dictPackManaged: true
    ))
    XCTAssertNil(diag.code)
    XCTAssertEqual(layer(diag, .seed).ok, true)
  }

  // Seed ok, but user build/ hasn't compiled preferred → OWL-SCHEMA-002.
  func testUserBuildMissingIsCode002() {
    let diag = OwlRimeConfigDiagnostics.classify(obs(built: ["wubi86_jidian"]))
    XCTAssertEqual(diag.code, "OWL-SCHEMA-002")
    XCTAssertEqual(diag.firstFailingLayer, .userBuild)
  }

  // Seed + build ok, but user schema_list dropped preferred (drift) → OWL-SCHEMA-001.
  func testSchemaListDriftIsCode001() {
    let diag = OwlRimeConfigDiagnostics.classify(obs(schemaList: ["wubi86_jidian", "pinyin_simp"]))
    XCTAssertEqual(diag.code, "OWL-SCHEMA-001")
    XCTAssertEqual(diag.firstFailingLayer, .userSchemaList)
  }

  // A full default.yaml in the user dir shadows the shared layer → OWL-SCHEMA-004.
  func testUserDefaultYamlShadowIsCode004() {
    let diag = OwlRimeConfigDiagnostics.classify(obs(shadow: true))
    XCTAssertEqual(diag.code, "OWL-SCHEMA-004")
    XCTAssertEqual(diag.firstFailingLayer, .shadow)
  }

  // ~/Library/Rime present but everything else healthy: OWL-SCHEMA-005 is ADVISORY only — it tags
  // the foreignDir layer (ok:nil) but is NEVER the headline failure code.
  func testForeignRimeDirIsAdvisoryNotFailure() {
    let diag = OwlRimeConfigDiagnostics.classify(obs(foreignPresent: true, foreignHasPreferred: false))
    XCTAssertNil(diag.code)                             // not a headline failure
    XCTAssertNil(diag.firstFailingLayer)
    XCTAssertNil(layer(diag, .foreignDir).ok)           // advisory ceiling, never scored
    XCTAssertEqual(layer(diag, .foreignDir).code, "OWL-SCHEMA-005")
  }

  // No ~/Library/Rime → foreignDir layer carries no advisory code.
  func testNoForeignRimeDirHasNoAdvisoryCode() {
    let diag = OwlRimeConfigDiagnostics.classify(obs(foreignPresent: false))
    XCTAssertNil(layer(diag, .foreignDir).code)
  }

  // Multiple failures → the headline names the most UPSTREAM one (seed before build before list).
  func testHeadlinePrefersMostUpstreamFailure() {
    let diag = OwlRimeConfigDiagnostics.classify(obs(schemaList: [], built: [], seed: []))
    XCTAssertEqual(diag.code, "OWL-SCHEMA-003")   // seed is upstream of build/list
    XCTAssertEqual(diag.firstFailingLayer, .seed)
    // downstream failures are still reported in their layers
    XCTAssertEqual(layer(diag, .userBuild).ok, false)
    XCTAssertEqual(layer(diag, .userSchemaList).ok, false)
  }
}

// `--build` 回归（2026-07-24）：目录 trait 缺失时，构建会落到进程 cwd；任意目录跑
// `Owltype --build` 会就地生成 installation.yaml + build/，而真正的
// ~/Library/Application Support/Owltype 完全没被构建。锁死 --build 的 traits 与主启动路径
// (setupRime) 同一目录三元组。放本文件以免动 project.pbxproj（仓库先例：Main.swift 注释）。
final class OwlBuilderTraitsTests: XCTestCase {
  func testBuilderTraitsCarrySameDirectoryTripleAsMainLaunchPath() {
    let traits = OwlApp.makeBuilderTraits()
    XCTAssertEqual(traits.sharedDataDir.path, Bundle.main.sharedSupportPath)
    XCTAssertEqual(traits.userDataDir.path, OwlApp.userDir.path)
    XCTAssertEqual(traits.logDir.path, OwlApp.logDir.path)
    XCTAssertEqual(traits.appName, OwlRimeIdentity.builderAppName)
  }
}
