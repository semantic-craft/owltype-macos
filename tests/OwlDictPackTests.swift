//
//  OwlDictPackTests.swift
//  OwltypeTests — 完整词库生命周期：首启提示判定、方案判定、Rust 资源代次的准备/启用/回退。
//

import Foundation
import XCTest
@testable import Owltype

final class OwlDictPackTests: XCTestCase {

  // MARK: - 知情同意提示的纯判定（2026-07-27 改版）

  /// 注入用小清单：只认 wubi86_jidian 一个方案，逻辑与线上清单内容解耦。
  private func promptManifest() -> OwlDictPackManifest {
    OwlDictPackManifest(version: 1, files: [
      .init(repo: "KyleBing/rime-wubi86-jidian", ref: "deadbeef", path: "wubi86_jidian.schema.yaml",
            dest: "wubi86_jidian.schema.yaml", sha256: String(repeating: "a", count: 64), size: 1, patch: nil)
    ])
  }

  func testDictPackManagedSchemaOnlyMatchesManifestSchemas() {
    let manifest = promptManifest()
    XCTAssertTrue(OwlDictPackPrompt.isDictPackManagedSchema("wubi86_jidian", manifest: manifest))
    // 随包分发的方案不归 dict-pack 管——切它失败是真·未编译，不该弹版权说明。
    XCTAssertFalse(OwlDictPackPrompt.isDictPackManagedSchema("rime_ice", manifest: manifest))
    XCTAssertFalse(OwlDictPackPrompt.isDictPackManagedSchema("", manifest: manifest))
    // 只认 <id>.schema.yaml，不能被同前缀的 dict 条目误判。
    XCTAssertFalse(OwlDictPackPrompt.isDictPackManagedSchema("wubi86_jidian.schema", manifest: manifest))
  }

  /// 已装/自备/进行中都不该再弹；未装与失败态才弹（失败后仍要给用户再来一次的入口）。
  func testAbsentDictPackSchemaGatesOnStatus() {
    let manifest = promptManifest()
    let absent: [OwlDictPackStatus] = [.notInstalled, .failed("network")]
    for status in absent {
      XCTAssertTrue(
        OwlDictPackPrompt.isAbsentDictPackSchema(schemaID: "wubi86_jidian", manifest: manifest, status: status),
        "\(status) 应判为缺失")
    }
    let present: [OwlDictPackStatus] = [
      .installed(version: 1), .preparing(progress: 0.5),
      .prepared(version: 2), .activating, .rollingBack,
    ]
    for status in present {
      XCTAssertFalse(
        OwlDictPackPrompt.isAbsentDictPackSchema(schemaID: "wubi86_jidian", manifest: manifest, status: status),
        "\(status) 不应再弹")
    }
    // 未装，但方案本就随包分发 → 仍不弹。
    XCTAssertFalse(
      OwlDictPackPrompt.isAbsentDictPackSchema(schemaID: "rime_ice", manifest: manifest, status: .notInstalled))
  }

  /// 线上清单必须真的覆盖会触发提示的那批方案——漏一个，用户切过去只会看到「尚未编译」的
  /// 误导提示，且永远没有下载入口。
  func testCurrentManifestCoversPromptableSchemas() {
    for id in ["wubi86_jidian", "wubi86_jidian_pinyin", "wubi86_jidian_trad",
               "wubi86_jidian_trad_pinyin", "pinyin_simp", "double_pinyin_flypy"] {
      XCTAssertTrue(OwlDictPackPrompt.isDictPackManagedSchema(id), "清单未覆盖 \(id)")
      XCTAssertNotEqual(OwlDictPackPrompt.displayName(for: id), id, "\(id) 缺中文名，弹窗会显示裸 id")
    }
  }

  func testLaunchActionDefersToOnboardingBeforeFirstRunCompletes() {
    // 引导未走完 ⟺ 本次启动引导会弹，它的词库步骤讲同一件事、写同一个 promptShown ——
    // 此时武装调度器就会在引导窗上再弹一次模态问同一个问题。
    XCTAssertEqual(
      OwlDictPackPrompt.launchAction(
        needsFetch: true, autoFetch: false, promptShown: false, onboardingDone: false),
      .deferToOnboarding)
    // 引导走完过（含老用户升级上来）→ 常规首启告知。
    XCTAssertEqual(
      OwlDictPackPrompt.launchAction(
        needsFetch: true, autoFetch: false, promptShown: false, onboardingDone: true),
      .armPrompt)
  }

  func testLaunchActionHonoursInstalledAndConsentFlags() {
    // 已装 / 用户自备（needsFetch=false）：任何组合都不动。
    for done in [true, false] {
      for shown in [true, false] {
        XCTAssertEqual(
          OwlDictPackPrompt.launchAction(
            needsFetch: false, autoFetch: false, promptShown: shown, onboardingDone: done),
          .doNothing)
      }
    }
    // 问过了就不再问 —— 引导是否走完都一样（引导里作出选择同样置真 promptShown）。
    XCTAssertEqual(
      OwlDictPackPrompt.launchAction(
        needsFetch: true, autoFetch: false, promptShown: true, onboardingDone: false),
      .doNothing)
    // autoFetch 是用户显式授权，优先于一切提示（含引导让路）。
    XCTAssertEqual(
      OwlDictPackPrompt.launchAction(
        needsFetch: true, autoFetch: true, promptShown: false, onboardingDone: false),
      .fetchSilently)
  }

  func testDisplayNameFallsBackToRawID() {
    XCTAssertEqual(OwlDictPackPrompt.displayName(for: "wubi86_jidian"), "极点五笔86")
    XCTAssertEqual(OwlDictPackPrompt.displayName(for: "double_pinyin_mspy"), "双拼")
    XCTAssertEqual(OwlDictPackPrompt.displayName(for: "some_unknown_schema"), "some_unknown_schema")
  }
}


@MainActor
final class OwlDictPackCenterTests: XCTestCase {
  /// The prompt decision reads Rust resource state only.
  func testPromptIsNeededUntilTheBundledGenerationIsActive() {
    XCTAssertTrue(OwlDictPackCenter.needsPrompt(activeVersion: nil, bundledVersion: 3))
    XCTAssertTrue(OwlDictPackCenter.needsPrompt(activeVersion: 2, bundledVersion: 3))
    XCTAssertFalse(OwlDictPackCenter.needsPrompt(activeVersion: 3, bundledVersion: 3))
    XCTAssertFalse(OwlDictPackCenter.needsPrompt(activeVersion: 4, bundledVersion: 3))
  }

  /// Regression: a current legacy YAML download record (`.owl-dictpack.json`) and the
  /// old dictionary files used to answer "no prompt" while no Rust generation was active.
  func testLegacyYamlRecordWithoutRustStateStillNeedsPrompt() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(component: "owl-dictpack-legacy-record-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root.appending(component: "cn_dicts"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let record = Data(#"{"files":{},"version":1}"#.utf8)
    try record.write(to: root.appending(component: ".owl-dictpack.json"))
    try Data("legacy\n".utf8).write(to: root.appending(path: "cn_dicts/base.dict.yaml"))

    let center = OwlDictPackCenter(rustBackend: .production(userRoot: root, sharedSupport: nil))
    XCTAssertTrue(center.needsPrompt, "no Rust resources are active, so the user must still be asked")
    center.refresh()
    XCTAssertEqual(center.status, .notInstalled, "legacy YAML files are not a Rust state")
    XCTAssertEqual(try Data(contentsOf: root.appending(component: ".owl-dictpack.json")), record,
                   "user data on disk stays untouched")
  }

  func testOutdatedIncompatibleActiveGenerationRefreshesAsNotInstalledWhileCurrentCorruptFails() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(component: "owl-dictpack-legacy-v1-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = OwlRustResourceEnvironment.production(userRoot: root)
    let activeDir = environment.configuration.stateRoot.appending(component: "active", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let legacyV1 = OwlRustResourceActiveState(
      schemaVersion: 1,
      inputKind: .pinyinWubi,
      current: fixtureRecord(version: 1, seed: "1"),
      previous: nil,
      activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try encoder.encode(legacyV1).write(to: activeDir.appending(component: "pinyin-wubi.json"))

    let center = OwlDictPackCenter(rustBackend: .production(userRoot: root, sharedSupport: nil))
    XCTAssertTrue(center.needsPrompt, "outdated v1 generation still needs the current bundled generation")
    center.refresh()
    XCTAssertEqual(
      center.status, .notInstalled,
      "an older generation lacking v4 files (like msime-wubi.db) must not lock the UI in an error banner"
    )

    let corruptCurrent = OwlRustResourceActiveState(
      schemaVersion: 1,
      inputKind: .pinyinWubi,
      current: fixtureRecord(version: OwlRustCompatibleResources.packageVersion, seed: "4"),
      previous: nil,
      activatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    try encoder.encode(corruptCurrent).write(to: activeDir.appending(component: "pinyin-wubi.json"))
    center.refresh()
    guard case .failed(let message) = center.status else {
      return XCTFail("corrupt current generation must still report failure, got \(center.status)")
    }
    XCTAssertTrue(message.contains("Rust 词库状态无法读取：资源文件缺失："), "unexpected message: \(message)")
  }

  func testRustPrepareActivateAndRollback() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(component: "owl-dictpack-center-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let previous = fixtureRecord(version: 6, seed: "b")
    let current = fixtureRecord(version: 7, seed: "a")
    let activeState = OwlRustResourceActiveState(
      schemaVersion: 1,
      inputKind: .pinyinWubi,
      current: current,
      previous: previous,
      activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let rolledBackState = OwlRustResourceActiveState(
      schemaVersion: 1,
      inputKind: .pinyinWubi,
      current: previous,
      previous: nil,
      activatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let prepared = OwlRustDictPackPreparedResources(
      resource: OwlRustResourcePrepared(record: current, previousGenerationId: previous.generationId),
      stats: OwlRustResourceBuildStats(
        pinyinEntries: 21,
        wubiEntries: 22,
        englishEntries: 23,
        rejectedPinyinEntries: 1,
        rejectedWubiEntries: 2,
        rejectedEnglishEntries: 3
      )
    )

    let calls = OwlDictPackCenterBackendCalls(
      prepared: prepared,
      activeState: activeState,
      rolledBackState: rolledBackState
    )
    let refreshRecorder = OwlDictPackLiveSessionRefreshRecorder(deferred: true)
    let backend = OwlDictPackCenterRustBackend(
      environment: OwlRustResourceEnvironment.production(userRoot: root),
      prepare: { _, progress in
        progress?(0.5)
        return await calls.prepare()
      },
      activate: { _, _ in
        await calls.activate()
      },
      rollback: { _, _ in
        await calls.rollback()
      }
    )
    let center = OwlDictPackCenter(
      rustBackend: backend,
      liveSessionRefresh: refreshRecorder.schedule
    )

    center.prepare()
    try await waitUntil { center.status == .prepared(version: 7) }

    XCTAssertEqual(center.status, .prepared(version: 7))
    XCTAssertEqual(center.preparedCandidate, OwlDictPackCandidate(prepared: prepared))
    XCTAssertEqual(center.preparedCandidate?.licenseIdentifiers, ["MIT", "Zlib"])
    XCTAssertEqual(center.preparedCandidate?.rejectedEntries, 6)
    let prepareCalls = await calls.prepareCalls
    let activateCallsBeforeConfirmation = await calls.activateCalls
    XCTAssertEqual(prepareCalls, 1)
    XCTAssertEqual(activateCallsBeforeConfirmation, 0, "preparing a candidate must not activate it")

    center.activate()
    try await waitUntil { center.status == .installed(version: 7) }

    let activateCalls = await calls.activateCalls
    XCTAssertEqual(activateCalls, 1)
    XCTAssertEqual(center.rollbackTargetVersion, 6)
    XCTAssertTrue(center.isAwaitingLiveSessionRefresh)
    XCTAssertEqual(refreshRecorder.calls, 1)

    center.rollback()
    try await waitUntil { center.status == .installed(version: 6) }

    let rollbackCalls = await calls.rollbackCalls
    XCTAssertEqual(rollbackCalls, 1)
    XCTAssertNil(center.rollbackTargetVersion)
    XCTAssertTrue(center.isAwaitingLiveSessionRefresh)
    XCTAssertEqual(refreshRecorder.calls, 2)

    refreshRecorder.finish()
    XCTAssertFalse(center.isAwaitingLiveSessionRefresh)
  }

  func testRustActivationWaitsForPartialSelectionToFinishBeforeSwitchingSessions() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(component: "owl-dictpack-idle-refresh-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let previous = fixtureRecord(version: 6, seed: "b")
    let current = fixtureRecord(version: 7, seed: "a")
    let activeState = OwlRustResourceActiveState(
      schemaVersion: 1,
      inputKind: .pinyinWubi,
      current: current,
      previous: previous,
      activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let prepared = OwlRustDictPackPreparedResources(
      resource: OwlRustResourcePrepared(record: current, previousGenerationId: previous.generationId),
      stats: OwlRustResourceBuildStats(
        pinyinEntries: 21,
        wubiEntries: 22,
        englishEntries: 23,
        rejectedPinyinEntries: 1,
        rejectedWubiEntries: 2,
        rejectedEnglishEntries: 3
      )
    )
    let backend = OwlDictPackCenterRustBackend(
      environment: OwlRustResourceEnvironment.production(userRoot: root),
      prepare: { _, _ in prepared },
      activate: { _, _ in
        OwlRustResourceInstallResult(disposition: .installed, state: activeState)
      },
      rollback: { _, _ in
        XCTFail("rollback is not part of this activation path")
        return activeState
      }
    )
    let delegate = NSApp.owlAppDelegate
    let previousEngine = delegate.runtime.engine
    let previousActive = delegate.runtime.activeInputController
    delegate.runtime.engine = FakeInputEngine()
    let active = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    let background = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    active.destroySession()
    background.destroySession()
    defer {
      delegate.runtime.liveControllers.remove(active)
      delegate.runtime.liveControllers.remove(background)
      delegate.runtime.activeInputController = previousActive
      delegate.runtime.engine = previousEngine
      _ = delegate.runtime.applyPendingLiveSessionRefreshIfIdle()
    }

    let partialSelection = EngineComposition(
      preedit: "西te'le",
      selStart: 3,
      selEnd: 9,
      cursorPos: 9,
      commitTextPreview: "西特乐",
      candidates: [EngineCandidate(text: "西特乐", comment: "xi'te'le")],
      labels: ["1"],
      pageNo: 0,
      pageSize: 1,
      isLastPage: true,
      highlightedIndex: 0,
      numCandidates: 1
    )
    let activeOld = FakeEngineSession(
      sessionID: 10,
      composition: partialSelection,
      input: "te'le"
    )
    let backgroundOld = FakeEngineSession(
      sessionID: 20,
      composition: partialSelection,
      input: "te'le"
    )
    let activeFresh = FakeEngineSession(sessionID: 11)
    let engine = FakeInputEngine(vendedSession: activeFresh)
    delegate.runtime.engine = engine

    active.engineSession = activeOld
    active.schemaId = "rime_ice"
    active.preedit = "西te'le"
    background.engineSession = backgroundOld
    background.schemaId = "rime_ice"
    delegate.runtime.registerLiveController(active)
    delegate.runtime.registerLiveController(background)
    delegate.runtime.activeInputController = active

    let center = OwlDictPackCenter(rustBackend: backend)
    center.prepare()
    try await waitUntil { center.status == .prepared(version: 7) }
    center.activate()
    try await waitUntil { center.status == .installed(version: 7) }

    XCTAssertTrue(center.isAwaitingLiveSessionRefresh)
    XCTAssertFalse(activeOld.destroyed, "an in-flight partial selection must not be torn down")
    XCTAssertFalse(backgroundOld.destroyed, "all live sessions wait for the active composition")
    XCTAssertEqual(engine.createdSessionCount, 0)

    activeOld.scriptedInput = ""
    activeOld.scriptedComposition = nil
    active.preedit = ""
    active.engineUpdate()

    XCTAssertFalse(activeOld.destroyed, "an unfinished background session must also block the handoff")
    XCTAssertFalse(backgroundOld.destroyed)
    XCTAssertEqual(engine.createdSessionCount, 0)
    XCTAssertTrue(center.isAwaitingLiveSessionRefresh)

    backgroundOld.scriptedInput = ""
    backgroundOld.scriptedComposition = nil
    // A stale UI preedit is not source of truth: the underlying session is idle.
    background.preedit = "stale"
    active.engineUpdate()

    XCTAssertTrue(activeOld.destroyed)
    XCTAssertTrue(backgroundOld.destroyed)
    XCTAssertEqual(engine.createdSessionCount, 1, "only the active controller is eagerly recreated")
    XCTAssertTrue(activeFresh.processedKeys.isEmpty, "the idle handoff must not replay stale raw input")
    XCTAssertFalse(center.isAwaitingLiveSessionRefresh)
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out waiting for dict-pack center state")
  }

  private func fixtureRecord(version: Int, seed: Character) -> OwlRustResourceRecord {
    let digest = "sha256:" + String(repeating: String(seed), count: 64)
    let licenseFiles = ["files/msime-pinyin.db"]
    let manifest = OwlRustResourceManifest(
      schemaVersion: 1,
      packageId: "owltype-dictpack",
      inputKind: .pinyinWubi,
      version: version,
      digest: digest,
      license: [
        OwlRustResourceLicense(identifier: "Zlib", attribution: "Fixture Z", files: licenseFiles),
        OwlRustResourceLicense(identifier: "MIT", attribution: "Fixture M", files: licenseFiles),
      ],
      engineCompatibility: OwlRustResourceEngineCompatibility(
        minimumContractVersion: 1,
        maximumContractVersion: 1,
        requiredCapabilities: []
      ),
      files: []
    )
    return OwlRustResourceRecord(
      generationId: "sha256-" + String(repeating: String(seed), count: 64),
      digest: digest,
      manifest: manifest
    )
  }
}

private actor OwlDictPackCenterBackendCalls {
  private let prepared: OwlRustDictPackPreparedResources
  private let activeState: OwlRustResourceActiveState
  private let rolledBackState: OwlRustResourceActiveState
  private(set) var prepareCalls = 0
  private(set) var activateCalls = 0
  private(set) var rollbackCalls = 0

  init(
    prepared: OwlRustDictPackPreparedResources,
    activeState: OwlRustResourceActiveState,
    rolledBackState: OwlRustResourceActiveState
  ) {
    self.prepared = prepared
    self.activeState = activeState
    self.rolledBackState = rolledBackState
  }

  func prepare() -> OwlRustDictPackPreparedResources {
    prepareCalls += 1
    return prepared
  }

  func activate() -> OwlRustResourceInstallResult {
    activateCalls += 1
    return OwlRustResourceInstallResult(disposition: .installed, state: activeState)
  }

  func rollback() -> OwlRustResourceActiveState {
    rollbackCalls += 1
    return rolledBackState
  }
}

@MainActor
private final class OwlDictPackLiveSessionRefreshRecorder {
  private(set) var calls = 0
  private let deferred: Bool
  private var completions: [@MainActor () -> Void] = []

  init(deferred: Bool) {
    self.deferred = deferred
  }

  func schedule(completion: @escaping @MainActor () -> Void) -> Bool {
    calls += 1
    guard deferred else {
      completion()
      return false
    }
    completions.append(completion)
    return true
  }

  func finish() {
    let pending = completions
    completions.removeAll()
    for completion in pending {
      completion()
    }
  }
}
