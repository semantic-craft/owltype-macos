//
//  OwlRustResourceTransactionTests.swift
//  OwltypeTests
//
//  Synthetic install, rollback, recovery, and lease coverage for #255 B1/B2.
//

import Darwin
import Foundation
import XCTest
@testable import Owltype

private struct OwlRustResourceTestEnvironment {
  let root: URL
  let configuration: OwlRustResourceConfiguration
}

private actor OwlRustResourceFailOnceState {
  private var shouldFail = true

  func claimFailure() -> Bool {
    defer { shouldFail = false }
    return shouldFail
  }
}

private struct OwlRustResourceFailOnceSource: OwlRustResourceSource {
  let base: OwlRustResourceDirectorySource
  let state: OwlRustResourceFailOnceState

  func readManifest() async throws -> Data {
    try await base.readManifest()
  }

  func copyFile(_ file: OwlRustResourceFile, to destination: URL) async throws {
    if await state.claimFailure() {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try Data("interrupted payload".utf8).write(to: destination)
      throw OwlRustResourceError.sourceReadFailed("synthetic interrupted copy")
    }
    try await base.copyFile(file, to: destination)
  }
}

private actor OwlRustResourceStartGate {
  private var started = false

  func markStarted() {
    started = true
  }

  func waitUntilStarted() async {
    while !started {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}

private struct OwlRustResourceSlowSource: OwlRustResourceSource {
  let base: OwlRustResourceDirectorySource
  let gate: OwlRustResourceStartGate

  func readManifest() async throws -> Data {
    try await base.readManifest()
  }

  func copyFile(_ file: OwlRustResourceFile, to destination: URL) async throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("partial payload".utf8).write(to: destination)
    await gate.markStarted()
    try await Task.sleep(for: .seconds(5))
  }
}

final class OwlRustResourceTransactionTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    let raw = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-rust-resource-transaction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    root = try Self.canonicalDirectory(raw)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testInstallPublishesCompleteDigestAndRepeatsIdempotently() async throws {
    let environment = try makeEnvironment()
    let package = try makePackage(in: environment, name: "v1", version: 1)
    let store = try makeStore(environment)
    let before = try userBytes(environment)

    let first = try await store.install(source(for: package))
    XCTAssertEqual(first.disposition, .installed)
    XCTAssertEqual(first.state.current.manifest.version, 1)
    XCTAssertEqual(
      first.state.current.generationId,
      "sha256-" + package.manifest.digest.dropFirst("sha256:".count)
    )
    let generation = generationURL(environment, record: first.state.current)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: generation.appendingPathComponent(".complete").path
    ))
    let activeBefore = try Data(contentsOf: activeURL(environment, inputKind: .pinyin))

    let repeated = try await store.install(source(for: package))
    XCTAssertEqual(repeated.disposition, .alreadyActive)
    XCTAssertEqual(repeated.state, first.state)
    XCTAssertEqual(
      try Data(contentsOf: activeURL(environment, inputKind: .pinyin)),
      activeBefore
    )
    XCTAssertEqual(try userBytes(environment), before)
  }

  func testPreparePublishesWithoutSwitchingAndActivateIsExplicitAndIdempotent() async throws {
    let environment = try makeEnvironment()
    let first = try makePackage(
      in: environment, name: "v1", version: 1, candidate: "合成甲"
    )
    let second = try makePackage(
      in: environment, name: "v2", version: 2, candidate: "合成乙"
    )
    let store = try makeStore(environment)
    let installedFirst = try await store.install(source(for: first))
    let activeBefore = try Data(contentsOf: activeURL(environment, inputKind: .pinyin))
    let userBefore = try userBytes(environment)

    let prepared = try await store.prepare(source(for: second))

    XCTAssertEqual(prepared.record.manifest.version, 2)
    XCTAssertEqual(
      prepared.previousGenerationId, installedFirst.state.current.generationId
    )
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: generationURL(environment, record: prepared.record)
        .appendingPathComponent(".complete").path
    ))
    XCTAssertEqual(
      try Data(contentsOf: activeURL(environment, inputKind: .pinyin)),
      activeBefore
    )
    XCTAssertEqual(try userBytes(environment), userBefore)

    let activated = try await store.activate(prepared)
    XCTAssertEqual(activated.disposition, .installed)
    XCTAssertEqual(activated.state.current, prepared.record)
    XCTAssertEqual(
      activated.state.previous, installedFirst.state.current
    )
    XCTAssertEqual(try userBytes(environment), userBefore)

    let repeated = try await store.activate(prepared)
    XCTAssertEqual(repeated.disposition, .alreadyActive)
    XCTAssertEqual(repeated.state, activated.state)
  }

  func testStalePreparedActivationCannotOverwriteANewerActiveGeneration() async throws {
    let environment = try makeEnvironment()
    let first = try makePackage(in: environment, name: "v1", version: 1)
    let second = try makePackage(in: environment, name: "v2", version: 2)
    let third = try makePackage(in: environment, name: "v3", version: 3)
    let store = try makeStore(environment)
    _ = try await store.install(source(for: first))
    let preparedSecond = try await store.prepare(source(for: second))
    let preparedThird = try await store.prepare(source(for: third))
    let installedThird = try await store.activate(preparedThird)
    let activeBefore = try Data(contentsOf: activeURL(environment, inputKind: .pinyin))

    let error = await thrownError {
      _ = try await store.activate(preparedSecond)
    }
    XCTAssertResourceError(error) {
      guard case .activeStateInvalid(let message) = $0 else { return false }
      return message.contains("changed after preparation")
    }
    XCTAssertEqual(
      try Data(contentsOf: activeURL(environment, inputKind: .pinyin)),
      activeBefore
    )
    let recovered = try await store.recover(inputKind: .pinyin)
    XCTAssertEqual(recovered, installedThird.state)
  }

  func testSameVersionWithDifferentDigestIsRejectedWithoutReplacingActive() async throws {
    let environment = try makeEnvironment()
    let firstPackage = try makePackage(
      in: environment, name: "first", version: 1, candidate: "合成甲"
    )
    let conflictingPackage = try makePackage(
      in: environment, name: "conflict", version: 1, candidate: "合成乙"
    )
    let store = try makeStore(environment)
    let installed = try await store.install(source(for: firstPackage))
    let activeBefore = try Data(contentsOf: activeURL(environment, inputKind: .pinyin))
    let before = try userBytes(environment)

    let error = await thrownError {
      _ = try await store.install(source(for: conflictingPackage))
    }
    XCTAssertResourceError(error) {
      guard case .versionDigestConflict = $0 else { return false }
      return true
    }
    let recovered = try await store.recover(inputKind: .pinyin)
    XCTAssertEqual(recovered, installed.state)
    XCTAssertEqual(
      try Data(contentsOf: activeURL(environment, inputKind: .pinyin)),
      activeBefore
    )
    XCTAssertEqual(try userBytes(environment), before)
  }

  func testFsyncFaultsLeaveOldActiveAndCompletedStagingCanResume() async throws {
    let preActiveFaults: [OwlRustResourceFaultPoint] = [
      .afterPayloadWrite,
      .afterPayloadSync,
      .afterManifestSync,
      .afterStagingDirectorySync,
      .afterGenerationPublish,
      .beforeActiveRename,
    ]
    for (index, point) in preActiveFaults.enumerated() {
      let environment = try makeEnvironment(name: "fault-\(index)")
      let first = try makePackage(
        in: environment, name: "v1", version: 1, candidate: "合成甲"
      )
      let second = try makePackage(
        in: environment, name: "v2", version: 2, candidate: "合成乙"
      )
      let store = try makeStore(environment)
      let installed = try await store.install(source(for: first))
      let faulting = try makeStore(environment, faults: .fail(at: point))

      let error = await thrownError {
        _ = try await faulting.install(source(for: second))
      }
      XCTAssertResourceError(error) {
        guard case .faultInjected(let observed) = $0 else { return false }
        return observed == point
      }
      let recovered = try await faulting.recover(inputKind: .pinyin)
      XCTAssertEqual(
        recovered.current.generationId,
        installed.state.current.generationId
      )

      let resumed = try await store.install(source(for: second))
      XCTAssertEqual(resumed.disposition, .installed)
      XCTAssertEqual(resumed.state.current.manifest.version, 2)
    }
  }

  func testReadOnlyFailureAfterPublishKeepsOldActiveAndRetryRepairsFinalTree() async throws {
    let environment = try makeEnvironment()
    let first = try makePackage(in: environment, name: "v1", version: 1, candidate: "合成甲")
    let second = try makePackage(in: environment, name: "v2", version: 2, candidate: "合成乙")
    let store = try makeStore(environment)
    let installed = try await store.install(source(for: first))
    let activeBefore = try Data(contentsOf: activeURL(environment, inputKind: .pinyin))
    let nextRecord = OwlRustResourceRecord(
      generationId: "sha256-" + second.manifest.digest.dropFirst("sha256:".count),
      digest: second.manifest.digest,
      manifest: second.manifest
    )
    let published = generationURL(environment, record: nextRecord)
    let failingPermissions = OwlRustResourcePermissionOperations { url, mode in
      if mode == 0o555, url.path == published.path {
        throw OwlRustResourceError.fileOperationFailed(
          path: url.path, message: "synthetic read-only failure"
        )
      }
      try OwlRustResourcePermissionOperations.system.setMode(url, mode)
    }
    let faulting = try makeStore(environment, permissions: failingPermissions)

    let error = await thrownError {
      _ = try await faulting.install(source(for: second))
    }
    XCTAssertResourceError(error) {
      guard case .fileOperationFailed(let path, _) = $0 else { return false }
      return path == published.path
    }
    XCTAssertTrue(directoryExists(published))
    XCTAssertNotEqual(try permissions(of: published) & 0o222, 0)
    XCTAssertEqual(
      try Data(contentsOf: activeURL(environment, inputKind: .pinyin)),
      activeBefore
    )

    let recovered = try await faulting.recover(inputKind: .pinyin)
    XCTAssertEqual(recovered.current.generationId, installed.state.current.generationId)
    XCTAssertEqual(recovered.current.manifest.version, 1)

    let retried = try await store.install(source(for: second))
    XCTAssertEqual(retried.disposition, .installed)
    XCTAssertEqual(retried.state.current.manifest.version, 2)
    try XCTAssertReadOnlyGeneration(published)
  }

  func testFaultAfterActiveRenameIsRecoveredFromPublishedActive() async throws {
    let environment = try makeEnvironment()
    let first = try makePackage(in: environment, name: "v1", version: 1)
    let second = try makePackage(in: environment, name: "v2", version: 2)
    let store = try makeStore(environment)
    _ = try await store.install(source(for: first))
    let faulting = try makeStore(environment, faults: .fail(at: .afterActiveRename))

    let error = await thrownError {
      _ = try await faulting.install(source(for: second))
    }
    XCTAssertResourceError(error) {
      guard case .faultInjected(.afterActiveRename) = $0 else { return false }
      return true
    }
    let recovered = try await faulting.recover(inputKind: .pinyin)
    XCTAssertEqual(recovered.current.manifest.version, 2)
    XCTAssertEqual(recovered.previous?.manifest.version, 1)
  }

  func testLeasesKeepGenerationRuntimesUntilTheirOwnRelease() async throws {
    let environment = try makeEnvironment()
    let first = try makePackage(in: environment, name: "v1", version: 1, candidate: "合成甲")
    let second = try makePackage(in: environment, name: "v2", version: 2, candidate: "合成乙")
    let store = try makeStore(environment)
    let before = try userBytes(environment)
    _ = try await store.install(source(for: first))
    let oldLease = try await store.acquireLease(inputKind: .pinyin)
    _ = try await store.install(source(for: second))
    let newLease = try await store.acquireLease(inputKind: .pinyin)

    XCTAssertNotEqual(oldLease.generationId, newLease.generationId)
    XCTAssertNotEqual(oldLease.runtimeURL, newLease.runtimeURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldLease.runtimeURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newLease.runtimeURL.path))
    XCTAssertNotEqual(
      try Data(contentsOf: oldLease.runtimeURL.appendingPathComponent("files/dictionary.db")),
      try Data(contentsOf: newLease.runtimeURL.appendingPathComponent("files/dictionary.db"))
    )

    _ = try await store.recover(inputKind: .pinyin)
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldLease.runtimeURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newLease.runtimeURL.path))

    try await store.releaseLease(oldLease)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldLease.runtimeURL.path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: leaseURL(environment, id: oldLease.id).path
    ))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newLease.runtimeURL.path))
    try await store.releaseLease(oldLease)

    let rolledBack = try await store.rollback(inputKind: .pinyin)
    XCTAssertEqual(rolledBack.current.manifest.version, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: newLease.runtimeURL.path))
    try await store.releaseLease(newLease)
    XCTAssertEqual(try userBytes(environment), before)
  }

  func testRollbackRevalidatesThePreviousGenerationBeforeSwitching() async throws {
    let environment = try makeEnvironment()
    let first = try makePackage(in: environment, name: "v1", version: 1, candidate: "合成甲")
    let second = try makePackage(in: environment, name: "v2", version: 2, candidate: "合成乙")
    let store = try makeStore(environment)
    let before = try userBytes(environment)
    let installedFirst = try await store.install(source(for: first))
    let installedSecond = try await store.install(source(for: second))
    let database = generationURL(environment, record: installedFirst.state.current)
      .appendingPathComponent("files/dictionary.db")
    let originalDatabase = try Data(contentsOf: database)
    XCTAssertEqual(chmod(database.path, 0o600), 0)
    try Data("corrupt".utf8).write(to: database)

    let error = await thrownError {
      _ = try await store.rollback(inputKind: .pinyin)
    }
    XCTAssertResourceError(error) {
      switch $0 {
      case .fileSizeMismatch, .fileDigestMismatch: return true
      default: return false
      }
    }
    let recovered = try await store.recover(inputKind: .pinyin)
    XCTAssertEqual(recovered.current.generationId, installedSecond.state.current.generationId)

    try originalDatabase.write(to: database)
    let rolledBack = try await store.rollback(inputKind: .pinyin)
    XCTAssertEqual(rolledBack.current.generationId, installedFirst.state.current.generationId)
    XCTAssertEqual(rolledBack.previous?.generationId, installedSecond.state.current.generationId)
    XCTAssertEqual(try userBytes(environment), before)
  }

  func testInterruptedCopyLeavesActiveUsableAndNextAttemptCanFinish() async throws {
    let environment = try makeEnvironment()
    let first = try makePackage(in: environment, name: "v1", version: 1)
    let second = try makePackage(in: environment, name: "v2", version: 2)
    let store = try makeStore(environment)
    let installed = try await store.install(source(for: first))
    let before = try userBytes(environment)
    let interrupt = OwlRustResourceFailOnceSource(
      base: source(for: second),
      state: OwlRustResourceFailOnceState()
    )

    let error = await thrownError {
      _ = try await store.install(interrupt)
    }
    XCTAssertResourceError(error) {
      guard case .sourceReadFailed = $0 else { return false }
      return true
    }
    let recovered = try await store.recover(inputKind: .pinyin)
    XCTAssertEqual(recovered.current.generationId, installed.state.current.generationId)

    let completed = try await store.install(source(for: second))
    XCTAssertEqual(completed.state.current.manifest.version, 2)
    XCTAssertEqual(try userBytes(environment), before)
  }

  func testCancellingCallerCancelsDetachedWorkerBeforeActivation() async throws {
    let environment = try makeEnvironment()
    let first = try makePackage(in: environment, name: "v1", version: 1)
    let second = try makePackage(in: environment, name: "v2", version: 2)
    let store = try makeStore(environment)
    let installed = try await store.install(source(for: first))
    let gate = OwlRustResourceStartGate()
    let slow = OwlRustResourceSlowSource(base: source(for: second), gate: gate)
    let task = Task {
      try await store.install(slow)
    }
    await gate.waitUntilStarted()
    task.cancel()

    let error = await thrownError {
      _ = try await task.value
    }
    XCTAssertTrue(error is CancellationError)
    let recovered = try await store.recover(inputKind: .pinyin)
    XCTAssertEqual(recovered.current.generationId, installed.state.current.generationId)
  }

  func testRecoveryRemovesOnlyProvablyDeadLeases() async throws {
    let environment = try makeEnvironment()
    let package = try makePackage(in: environment, name: "v1", version: 1)
    let store = try makeStore(environment)
    _ = try await store.install(source(for: package))
    let lease = try await store.acquireLease(inputKind: .pinyin)
    let metadata = leaseURL(environment, id: lease.id)

    _ = try await store.recover(inputKind: .pinyin)
    XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: lease.runtimeURL.path))

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadata))
        as? [String: Any]
    )
    var process = try XCTUnwrap(object["process"] as? [String: Any])
    process["processId"] = 999_999
    process["startedAtSeconds"] = 1
    process["startedAtMicroseconds"] = 0
    object["process"] = process
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      .write(to: metadata)

    _ = try await store.recover(inputKind: .pinyin)
    XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: lease.runtimeURL.path))
  }

  func testConfigurationRejectsOverlapBeforeWritingIntoUserRoot() throws {
    let environment = try makeEnvironment()
    let overlap = environment.configuration.userRoot
      .appendingPathComponent("resource-state", isDirectory: true)
    let configuration = OwlRustResourceConfiguration(
      libraryRoot: environment.configuration.libraryRoot,
      stagingRoot: environment.configuration.stagingRoot,
      runtimeRoot: environment.configuration.runtimeRoot,
      stateRoot: overlap,
      userRoot: environment.configuration.userRoot,
      cacheRoot: environment.configuration.cacheRoot
    )

    XCTAssertThrowsError(try configuration.prepared(using: .system)) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .invalidConfiguration = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: overlap.path))
  }

  func testConfigurationRejectsDifferentVolumesAndSymlinkedRoots() throws {
    let environment = try makeEnvironment()
    let differentVolumes = OwlRustResourceVolumeIdentity { url in
      url.lastPathComponent == "staging" ? "volume-b" : "volume-a"
    }
    XCTAssertThrowsError(
      try environment.configuration.prepared(using: differentVolumes)
    ) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .stagingAndLibraryOnDifferentVolumes = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    let target = environment.root.appendingPathComponent("runtime-target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = environment.root.appendingPathComponent("runtime-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let symlinked = OwlRustResourceConfiguration(
      libraryRoot: environment.configuration.libraryRoot,
      stagingRoot: environment.configuration.stagingRoot,
      runtimeRoot: link,
      stateRoot: environment.configuration.stateRoot,
      userRoot: environment.configuration.userRoot,
      cacheRoot: environment.configuration.cacheRoot
    )
    XCTAssertThrowsError(try symlinked.prepared(using: .system)) { error in
      guard let resourceError = error as? OwlRustResourceError,
            case .invalidConfiguration = resourceError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  private func makeEnvironment(name: String = "environment") throws -> OwlRustResourceTestEnvironment {
    let base = root.appendingPathComponent(name, isDirectory: true)
    let user = base.appendingPathComponent("user", isDirectory: true)
    try FileManager.default.createDirectory(
      at: user.appendingPathComponent("notes", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("synthetic user state".utf8)
      .write(to: user.appendingPathComponent("notes/state.txt"))
    let configuration = OwlRustResourceConfiguration(
      libraryRoot: base.appendingPathComponent("library", isDirectory: true),
      stagingRoot: base.appendingPathComponent("staging", isDirectory: true),
      runtimeRoot: base.appendingPathComponent("runtime", isDirectory: true),
      stateRoot: base.appendingPathComponent("state", isDirectory: true),
      userRoot: user,
      cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
    )
    return OwlRustResourceTestEnvironment(root: base, configuration: configuration)
  }

  private func makeStore(
    _ environment: OwlRustResourceTestEnvironment,
    faults: OwlRustResourceFaultInjection = .none,
    permissions: OwlRustResourcePermissionOperations = .system
  ) throws -> OwlRustResourceStore {
    try OwlRustResourceStore(
      configuration: environment.configuration,
      engine: OwlRustResourceTestFixtures.defaultEngine(),
      faults: faults,
      permissions: permissions
    )
  }

  private func makePackage(
    in environment: OwlRustResourceTestEnvironment,
    name: String,
    version: Int,
    candidate: String = "合成词条"
  ) throws -> OwlRustResourceTestFixtures.Package {
    try OwlRustResourceTestFixtures.makePackage(
      at: environment.root.appendingPathComponent("packages", isDirectory: true),
      name: name,
      version: version,
      candidate: candidate
    )
  }

  private func source(
    for package: OwlRustResourceTestFixtures.Package
  ) -> OwlRustResourceDirectorySource {
    OwlRustResourceDirectorySource(root: package.root)
  }

  private func generationURL(
    _ environment: OwlRustResourceTestEnvironment,
    record: OwlRustResourceRecord
  ) -> URL {
    environment.configuration.libraryRoot
      .appendingPathComponent(record.manifest.packageId, isDirectory: true)
      .appendingPathComponent("generations", isDirectory: true)
      .appendingPathComponent(record.generationId, isDirectory: true)
  }

  private func activeURL(
    _ environment: OwlRustResourceTestEnvironment,
    inputKind: OwlRustResourceInputKind
  ) -> URL {
    environment.configuration.stateRoot
      .appendingPathComponent("active", isDirectory: true)
      .appendingPathComponent(inputKind.rawValue + ".json")
  }

  private func leaseURL(
    _ environment: OwlRustResourceTestEnvironment,
    id: UUID
  ) -> URL {
    environment.configuration.stateRoot
      .appendingPathComponent("leases", isDirectory: true)
      .appendingPathComponent(id.uuidString + ".json")
  }

  private func userBytes(
    _ environment: OwlRustResourceTestEnvironment
  ) throws -> [String: Data] {
    let user = environment.configuration.userRoot
    let enumerator = FileManager.default.enumerator(
      at: user, includingPropertiesForKeys: [.isRegularFileKey]
    )
    var result: [String: Data] = [:]
    while let url = enumerator?.nextObject() as? URL {
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        let relative = String(url.path.dropFirst(user.path.count + 1))
        result[relative] = try Data(contentsOf: url)
      }
    }
    return result
  }

  private func permissions(of url: URL) throws -> mode_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: String(cString: strerror(errno))
      )
    }
    return info.st_mode & 0o777
  }

  private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func XCTAssertReadOnlyGeneration(
    _ root: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isDirectoryKey]
    )
    var entries = [root]
    while let url = enumerator?.nextObject() as? URL {
      entries.append(url)
    }
    for url in entries {
      let isDirectory =
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      XCTAssertEqual(
        try permissions(of: url), isDirectory ? 0o555 : 0o444,
        "unexpected mode for \(url.path)", file: file, line: line
      )
    }
  }

  private func thrownError(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
  ) async -> Error? {
    do {
      try await operation()
      XCTFail("expected an error", file: file, line: line)
      return nil
    } catch {
      return error
    }
  }

  private func XCTAssertResourceError(
    _ error: Error?,
    file: StaticString = #filePath,
    line: UInt = #line,
    matches: (OwlRustResourceError) -> Bool
  ) {
    guard let resourceError = error as? OwlRustResourceError else {
      return XCTFail("expected OwlRustResourceError, got \(String(describing: error))",
                     file: file, line: line)
    }
    XCTAssertTrue(matches(resourceError), "unexpected resource error: \(resourceError)",
                  file: file, line: line)
  }

  private static func canonicalDirectory(_ url: URL) throws -> URL {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &resolved) != nil else {
      throw OwlRustResourceError.invalidConfiguration(
        "realpath failed for \(url.path)"
      )
    }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
  }
}
