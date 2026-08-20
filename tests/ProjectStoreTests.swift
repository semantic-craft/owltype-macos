//
//  ProjectStoreTests.swift
//  OwltypeTests — 项目输入空间 (blueprint_v2 P0 pillar, task 06-20-owl-project-input-space)
//
//  Locks three contracts:
//    1. `OwlProjectStore` CRUD round-trips through `project.json` (create → read → rename →
//       set-words → delete), against an isolated temp directory + temp UserDefaults suite.
//    2. The active-project pointer persists (UserDefaults) and clears when its project is
//       deleted; `activeProject` reads back the on-disk project.
//    3. Project words reach the SMART lane only when the upsert's snapshotID matches the live
//       snapshot — a stale snapshot is dropped — and an end-to-end `emitComposing` with an
//       active project lands the words in the smart lane with `.project` provenance.
//
//  No network, no librime. The store is pointed at a unique temp root so it never touches the
//  real ~/Library/Application Support/Owltype.
//

import Foundation
import XCTest
@testable import Owltype

final class ProjectStoreTests: XCTestCase {

  private var tempRoot: URL!
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwlProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    suiteName = "OwlProjectStoreTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDownWithError() throws {
    if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
      try FileManager.default.removeItem(at: tempRoot)
    }
    if let suiteName {
      defaults.removePersistentDomain(forName: suiteName)
    }
    try super.tearDownWithError()
  }

  private func makeStore() -> OwlProjectStore {
    OwlProjectStore(root: tempRoot, defaults: defaults)
  }

  // MARK: - CRUD round-trip

  func testCreatePersistsReadableJSON() throws {
    let store = makeStore()
    let project = try store.create(name: "  行政法课程  ")

    XCTAssertEqual(project.name, "行政法课程", "name should be trimmed")
    let url = store.fileURL(for: project.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "project.json must be written")
    let rootMode = try FileManager.default.attributesOfItem(atPath: tempRoot.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(rootMode?.intValue, 0o700)
    XCTAssertEqual(fileMode?.intValue, 0o600)

    // Human-readable JSON (pretty-printed, ISO8601 createdAt) round-trips back to the project.
    let json = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(json.contains("\"name\" : \"行政法课程\""), "project.json must be human-readable")

    let reloaded = try XCTUnwrap(store.load(id: project.id))
    XCTAssertEqual(reloaded.id, project.id)
    XCTAssertEqual(reloaded.name, project.name)
    XCTAssertEqual(reloaded.words, project.words)
    // ISO8601 encoding is whole-second; createdAt round-trips within a second.
    XCTAssertEqual(reloaded.createdAt.timeIntervalSince1970, project.createdAt.timeIntervalSince1970, accuracy: 1.0)
  }

  func testEmptyNameRejected() {
    let store = makeStore()
    XCTAssertThrowsError(try store.create(name: "   ")) { error in
      XCTAssertEqual(error as? OwlProjectError, .emptyName)
    }
  }

  func testRenameAndSetWordsRoundTrip() throws {
    let store = makeStore()
    let project = try store.create(name: "刑法")

    try store.rename(id: project.id, to: "刑法分论")
    try store.setWords(id: project.id, words: ["正当防卫", " ", "正当防卫", "紧急避险"])

    let reloaded = try XCTUnwrap(store.load(id: project.id))
    XCTAssertEqual(reloaded.name, "刑法分论")
    // Raw words are stored verbatim; normalization dedupes + trims at read time.
    XCTAssertEqual(reloaded.normalizedWords, ["正当防卫", "紧急避险"])
  }

  func testLoadAllReturnsEveryProjectInStableOrder() throws {
    let store = makeStore()
    let first = try store.create(name: "A")
    let second = try store.create(name: "B")

    // Both projects are returned, and the order is deterministic across repeated reads
    // (createdAt, then id as a same-second tiebreaker).
    let all = store.loadAll()
    XCTAssertEqual(Set(all.map(\.id)), [first.id, second.id])
    XCTAssertEqual(all.map(\.id), store.loadAll().map(\.id), "loadAll order must be stable")
  }

  func testDeleteRemovesProjectFolder() throws {
    let store = makeStore()
    let project = try store.create(name: "待删除")
    try store.delete(id: project.id)

    XCTAssertNil(store.load(id: project.id))
    XCTAssertTrue(store.loadAll().isEmpty)
  }

  func testRenameUnknownIDThrowsNotFound() {
    let store = makeStore()
    XCTAssertThrowsError(try store.rename(id: "missing", to: "x")) { error in
      XCTAssertEqual(error as? OwlProjectError, .notFound("missing"))
    }
  }

  // MARK: - Active switching persistence

  func testActivePersistsAcrossStoreInstances() throws {
    let store = makeStore()
    let a = try store.create(name: "项目甲")
    let b = try store.create(name: "项目乙")

    try store.activate(id: a.id)
    XCTAssertEqual(store.activeProjectID, a.id)
    XCTAssertEqual(store.activeProject?.id, a.id)

    // A fresh store reading the same defaults + root sees the same active project.
    let reopened = OwlProjectStore(root: tempRoot, defaults: defaults)
    XCTAssertEqual(reopened.activeProjectID, a.id)

    try store.activate(id: b.id)
    XCTAssertEqual(store.activeProject?.id, b.id)
  }

  func testDeletingActiveProjectClearsPointer() throws {
    let store = makeStore()
    let project = try store.create(name: "激活后删除")
    try store.activate(id: project.id)
    XCTAssertEqual(store.activeProjectID, project.id)

    try store.delete(id: project.id)
    XCTAssertNil(store.activeProjectID, "deleting the active project must clear the pointer")
    XCTAssertNil(store.activeProject)
  }

  func testActivateUnknownIDThrowsNotFound() {
    let store = makeStore()
    XCTAssertThrowsError(try store.activate(id: "nope")) { error in
      XCTAssertEqual(error as? OwlProjectError, .notFound("nope"))
    }
  }

  // MARK: - Candidate injection (snapshotID-gated smart lane)

  private func projectCandidates(
    _ words: [String],
    snapshotID: UInt64
  ) -> [EnhancedCandidate] {
    words.map { word in
      EnhancedCandidate(
        snapshotID: snapshotID,
        source: .localNeural,
        lane: .smart,
        text: word,
        commitMode: .externalText
      )
    }
  }

  private func makeSnapshot(id: UInt64, rawInput: String = "byrw") -> OwlCompositionSnapshot {
    OwlCompositionSnapshot(
      id: id,
      sessionID: 200,
      schemaID: "wubi86_jidian",
      rawInput: rawInput,
      preedit: "本院",
      cursor: 2,
      pageNo: 0,
      candidates: [],
      commitSerial: 0
    )
  }

  @MainActor
  func testProjectWordsLandInSmartLaneWhenSnapshotMatches() {
    let store = OwlCandidateStore.shared
    store.clearForSnapshotChange()
    OwlSnapshotRegistry.shared.update(makeSnapshot(id: 50))

    store.upsertSmartCandidates(projectCandidates(["本院", "本院认为"], snapshotID: 50), snapshotID: 50)

    XCTAssertEqual(store.smart.count, 2)
    XCTAssertEqual(store.smart.first?.text, "本院")
    // Provenance derivation: smart lane + localNeural source → 「项目」label.
    XCTAssertEqual(store.smart.first?.provenance(), .project)

    OwlSnapshotRegistry.shared.update(nil)
    store.clearForSnapshotChange()
  }

  @MainActor
  func testStaleProjectWordsDropped() {
    let store = OwlCandidateStore.shared
    store.clearForSnapshotChange()
    // User has moved on: live snapshot is id 61, but a project upsert for id 60 arrives late.
    OwlSnapshotRegistry.shared.update(makeSnapshot(id: 61, rawInput: "byrwr"))

    store.upsertSmartCandidates(projectCandidates(["本院"], snapshotID: 60), snapshotID: 60)

    XCTAssertTrue(store.smart.isEmpty, "a stale project upsert must never reach the smart lane")

    OwlSnapshotRegistry.shared.update(nil)
    store.clearForSnapshotChange()
  }

  @MainActor
  func testEmitComposingInjectsActiveProjectWords() throws {
    // Drive the emitter end-to-end with an active project and assert the smart lane carries
    // the project words for the live snapshot. The emitter is pointed at our isolated temp
    // store so the real ~/Library/Application Support/Owltype is never touched.
    let emitter = OwlSnapshotEmitter()
    let store = makeStore()
    emitter.projectStore = store

    let project = try store.create(name: "Emit 测试项目")
    try store.setWords(id: project.id, words: ["本院认为", "依照"])
    try store.activate(id: project.id)

    defer {
      OwlSnapshotRegistry.shared.update(nil)
      OwlCandidateStore.shared.clearForSnapshotChange()
    }

    emitter.emitComposing(
      sessionID: 300,
      schemaID: "wubi86_jidian",
      rawInput: "byrw",
      preedit: "本院",
      cursor: 2,
      pageNo: 0,
      candidates: [RimeCandidateSnapshot(index: 0, text: "本院", quality: 1)]
    )

    let smart = OwlCandidateStore.shared.smart
    XCTAssertEqual(smart.map(\.text), ["本院认为", "依照"])
    XCTAssertEqual(smart.first?.provenance(), .project)
    // The main (Rime) lane is untouched by the project injection.
    XCTAssertEqual(OwlCandidateStore.shared.main.map(\.text), ["本院"])
  }

  @MainActor
  func testEmitComposingWithoutActiveProjectLeavesSmartLaneEmpty() throws {
    let emitter = OwlSnapshotEmitter()
    emitter.projectStore = makeStore()  // no active project

    defer {
      OwlSnapshotRegistry.shared.update(nil)
      OwlCandidateStore.shared.clearForSnapshotChange()
    }

    emitter.emitComposing(
      sessionID: 301,
      schemaID: "wubi86_jidian",
      rawInput: "byrw",
      preedit: "本院",
      cursor: 2,
      pageNo: 0,
      candidates: [RimeCandidateSnapshot(index: 0, text: "本院", quality: 1)]
    )

    XCTAssertTrue(OwlCandidateStore.shared.smart.isEmpty, "no active project → no project words")
    XCTAssertEqual(OwlCandidateStore.shared.main.map(\.text), ["本院"])
  }
}
