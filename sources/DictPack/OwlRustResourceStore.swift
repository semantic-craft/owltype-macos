//
//  OwlRustResourceStore.swift
//  Owltype
//
//  Transactional resource generations and per-session leases. Library
//  generations are immutable; runtime directories are disposable and each
//  lease receives its own copy. userRoot is an explicit exclusion boundary.
//

import Darwin
import Foundation

struct OwlRustResourceConfiguration: Sendable {
  let libraryRoot: URL
  let stagingRoot: URL
  let runtimeRoot: URL
  let stateRoot: URL
  let userRoot: URL
  let cacheRoot: URL

  func prepared(using volumes: OwlRustResourceVolumeIdentity) throws -> Self {
    let rawRoots = [libraryRoot, stagingRoot, runtimeRoot, stateRoot, userRoot, cacheRoot]
    guard rawRoots.allSatisfy(\.isFileURL) else {
      throw OwlRustResourceError.invalidConfiguration("所有根必须为 file URL")
    }
    guard rawRoots.allSatisfy({ $0.path.hasPrefix("/") }) else {
      throw OwlRustResourceError.invalidConfiguration("所有根必须为绝对路径")
    }
    guard rawRoots.allSatisfy(Self.hasNoRelativeComponents) else {
      throw OwlRustResourceError.invalidConfiguration("所有根必须为规范路径")
    }
    guard directoryExists(userRoot) else {
      throw OwlRustResourceError.invalidConfiguration("userRoot 必须已存在：\(userRoot.path)")
    }
    for root in rawRoots {
      try Self.rejectSymlinkComponents(root)
    }
    for leftIndex in rawRoots.indices {
      for rightIndex in rawRoots.indices where rightIndex > leftIndex {
        guard !Self.pathsOverlap(rawRoots[leftIndex], rawRoots[rightIndex]) else {
          throw OwlRustResourceError.invalidConfiguration(
            "根目录重叠：\(rawRoots[leftIndex].path) / \(rawRoots[rightIndex].path)"
          )
        }
      }
    }

    for root in [libraryRoot, stagingRoot, runtimeRoot, stateRoot, cacheRoot] {
      do {
        try FileManager.default.createDirectory(
          at: root, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw OwlRustResourceError.invalidConfiguration(
          "无法创建 \(root.path)：\(error.localizedDescription)"
        )
      }
    }

    let canonical = Self(
      libraryRoot: try Self.canonicalDirectory(libraryRoot),
      stagingRoot: try Self.canonicalDirectory(stagingRoot),
      runtimeRoot: try Self.canonicalDirectory(runtimeRoot),
      stateRoot: try Self.canonicalDirectory(stateRoot),
      userRoot: try Self.canonicalDirectory(userRoot),
      cacheRoot: try Self.canonicalDirectory(cacheRoot)
    )
    let roots = [
      canonical.libraryRoot, canonical.stagingRoot, canonical.runtimeRoot,
      canonical.stateRoot, canonical.userRoot, canonical.cacheRoot,
    ]
    for leftIndex in roots.indices {
      for rightIndex in roots.indices where rightIndex > leftIndex {
        guard !Self.pathsOverlap(roots[leftIndex], roots[rightIndex]) else {
          throw OwlRustResourceError.invalidConfiguration(
            "根目录重叠：\(roots[leftIndex].path) / \(roots[rightIndex].path)"
          )
        }
      }
    }
    guard try volumes.identifier(canonical.libraryRoot)
      == volumes.identifier(canonical.stagingRoot) else {
      throw OwlRustResourceError.stagingAndLibraryOnDifferentVolumes
    }
    return canonical
  }

  private static func rejectSymlinkComponents(_ url: URL) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.path.split(separator: "/").map(String.init) {
      current.appendPathComponent(component, isDirectory: true)
      var info = stat()
      if lstat(current.path, &info) != 0 {
        if errno == ENOENT {
          return
        }
        throw OwlRustResourceError.invalidConfiguration(
          "无法检查路径 \(current.path)：\(String(cString: strerror(errno)))"
        )
      }
      guard (info.st_mode & S_IFMT) != S_IFLNK else {
        throw OwlRustResourceError.invalidConfiguration("路径不得含 symlink：\(current.path)")
      }
      guard (info.st_mode & S_IFMT) == S_IFDIR else {
        throw OwlRustResourceError.invalidConfiguration("路径祖先不是目录：\(current.path)")
      }
    }
  }

  private static func hasNoRelativeComponents(_ url: URL) -> Bool {
    let components = url.path.split(separator: "/", omittingEmptySubsequences: false)
    return components.first == "" && components.dropFirst().allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  private static func canonicalDirectory(_ url: URL) throws -> URL {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &resolved) != nil else {
      throw OwlRustResourceError.invalidConfiguration(
        "无法解析目录 \(url.path)：\(String(cString: strerror(errno)))"
      )
    }
    let canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    guard directoryExists(canonical) else {
      throw OwlRustResourceError.invalidConfiguration("不是目录：\(canonical.path)")
    }
    return canonical
  }

  private static func pathsOverlap(_ left: URL, _ right: URL) -> Bool {
    let lhs = left.path
    let rhs = right.path
    return lhs == rhs
      || lhs.hasPrefix(rhs == "/" ? "/" : rhs + "/")
      || rhs.hasPrefix(lhs == "/" ? "/" : lhs + "/")
  }
}

struct OwlRustResourceVolumeIdentity: Sendable {
  let identifier: @Sendable (URL) throws -> String

  static let system = Self { url in
    var info = stat()
    guard stat(url.path, &info) == 0 else {
      throw OwlRustResourceError.invalidConfiguration(
        "无法读取文件系统身份 \(url.path)：\(String(cString: strerror(errno)))"
      )
    }
    return String(info.st_dev)
  }
}

protocol OwlRustResourceSource: Sendable {
  func readManifest() async throws -> Data
  func copyFile(_ file: OwlRustResourceFile, to destination: URL) async throws
}

/// Adapter used by synthetic tests and local package providers. Network/package
/// transports can implement OwlRustResourceSource after B3 fixes its contract.
struct OwlRustResourceDirectorySource: OwlRustResourceSource, Sendable {
  let root: URL

  init(root: URL) {
    self.root = root
  }

  func readManifest() async throws -> Data {
    do {
      return try Data(contentsOf: root.appendingPathComponent("manifest.json"))
    } catch {
      throw OwlRustResourceError.sourceReadFailed(error.localizedDescription)
    }
  }

  func copyFile(_ file: OwlRustResourceFile, to destination: URL) async throws {
    let source: URL
    do {
      source = try OwlRustResourceVerifier.safeFileURL(
        relativePath: file.path, under: root
      )
    } catch {
      throw OwlRustResourceError.sourceReadFailed(
        "\(file.path)：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
      )
    }
    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      let input = try FileHandle(forReadingFrom: source)
      defer { try? input.close() }
      guard FileManager.default.createFile(
        atPath: destination.path, contents: nil,
        attributes: [.posixPermissions: 0o600]
      ) else {
        throw OwlRustResourceError.fileOperationFailed(
          path: destination.path, message: "无法创建目标文件"
        )
      }
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }
      while true {
        try Task.checkCancellation()
        guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else {
          break
        }
        try output.write(contentsOf: chunk)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as OwlRustResourceError {
      throw error
    } catch {
      throw OwlRustResourceError.fileOperationFailed(
        path: file.path, message: error.localizedDescription
      )
    }
  }
}

enum OwlRustResourceFaultPoint: String, CaseIterable, Sendable {
  case afterPayloadWrite
  case afterPayloadSync
  case afterManifestSync
  case afterStagingDirectorySync
  case afterGenerationPublish
  case beforeActiveRename
  case afterActiveRename
}

struct OwlRustResourceFaultInjection: Sendable {
  let check: @Sendable (OwlRustResourceFaultPoint) throws -> Void

  static let none = Self { _ in }

  static func fail(at point: OwlRustResourceFaultPoint) -> Self {
    Self { observed in
      if observed == point {
        throw OwlRustResourceError.faultInjected(observed)
      }
    }
  }
}

struct OwlRustResourcePermissionOperations: Sendable {
  let setMode: @Sendable (URL, mode_t) throws -> Void

  static let system = Self { url, mode in
    guard chmod(url.path, mode) == 0 else {
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: String(cString: strerror(errno))
      )
    }
  }
}

struct OwlRustResourceRecord: Codable, Equatable, Sendable {
  let generationId: String
  let digest: String
  let manifest: OwlRustResourceManifest
}

struct OwlRustResourceActiveState: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let inputKind: OwlRustResourceInputKind
  let current: OwlRustResourceRecord
  let previous: OwlRustResourceRecord?
  let activatedAt: Date
}

enum OwlRustResourceInstallDisposition: String, Equatable, Sendable {
  case installed
  case alreadyActive
}

struct OwlRustResourceInstallResult: Equatable, Sendable {
  let disposition: OwlRustResourceInstallDisposition
  let state: OwlRustResourceActiveState
}

struct OwlRustResourcePrepared: Equatable, Sendable {
  let record: OwlRustResourceRecord
  let previousGenerationId: String?
}

struct OwlRustResourceLease: Codable, Equatable, Sendable {
  let id: UUID
  let inputKind: OwlRustResourceInputKind
  let generationId: String
  let runtimeURL: URL
  let acquiredAt: Date
}

private struct OwlRustResourceLeaseRecord: Codable, Equatable, Sendable {
  let lease: OwlRustResourceLease
  let process: OwlRustResourceProcessIdentity
}

private struct OwlRustResourceProcessIdentity: Codable, Equatable, Sendable {
  let processId: UInt32
  let startedAtSeconds: UInt64
  let startedAtMicroseconds: UInt64

  static func current() throws -> Self {
    var info = proc_bsdinfo()
    let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
    errno = 0
    let actual = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, expected)
    guard actual == expected else {
      throw OwlRustResourceError.processIdentityUnavailable(
        String(cString: strerror(errno == 0 ? EIO : errno))
      )
    }
    return Self(
      processId: info.pbi_pid,
      startedAtSeconds: UInt64(info.pbi_start_tvsec),
      startedAtMicroseconds: UInt64(info.pbi_start_tvusec)
    )
  }

  var isDefinitelyDead: Bool {
    var info = proc_bsdinfo()
    let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
    errno = 0
    let actual = proc_pidinfo(
      Int32(bitPattern: processId), PROC_PIDTBSDINFO, 0, &info, expected
    )
    if actual != expected {
      return errno == ESRCH
    }
    return info.pbi_pid != processId
      || info.pbi_start_tvsec != startedAtSeconds
      || info.pbi_start_tvusec != startedAtMicroseconds
  }
}

private enum OwlRustResourceTransactionPhase: String, Codable, Sendable {
  case prepared
  case generationPublished
  case activeWritten
  case failed
}

private struct OwlRustResourceTransactionJournal: Codable, Sendable {
  let schemaVersion: Int
  let id: UUID
  let inputKind: OwlRustResourceInputKind
  let phase: OwlRustResourceTransactionPhase
  let oldGenerationId: String?
  let newGenerationId: String
  let updatedAt: Date
  let message: String?
}

actor OwlRustResourceStore {
  private let worker: OwlRustResourceWorker

  init(
    configuration: OwlRustResourceConfiguration,
    engine: OwlRustEngineIdentity,
    volumes: OwlRustResourceVolumeIdentity = .system,
    faults: OwlRustResourceFaultInjection = .none,
    permissions: OwlRustResourcePermissionOperations = .system
  ) throws {
    let prepared = try configuration.prepared(using: volumes)
    worker = OwlRustResourceWorker(
      configuration: prepared, engine: engine, faults: faults,
      permissions: permissions
    )
  }

  func install(
    _ source: any OwlRustResourceSource,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> OwlRustResourceInstallResult {
    let worker = worker
    return try await runResourceWorker {
      try Task.checkCancellation()
      return try await worker.install(source, progress: progress)
    }
  }

  func prepare(
    _ source: any OwlRustResourceSource,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> OwlRustResourcePrepared {
    let worker = worker
    return try await runResourceWorker {
      try Task.checkCancellation()
      return try await worker.prepare(source, progress: progress)
    }
  }

  func activate(
    _ prepared: OwlRustResourcePrepared
  ) async throws -> OwlRustResourceInstallResult {
    let worker = worker
    return try await runResourceWorker {
      try Task.checkCancellation()
      return try await worker.activate(prepared)
    }
  }

  func acquireLease(inputKind: OwlRustResourceInputKind) async throws -> OwlRustResourceLease {
    let worker = worker
    return try await runResourceWorker {
      try Task.checkCancellation()
      return try await worker.acquireLease(inputKind: inputKind)
    }
  }

  func releaseLease(_ lease: OwlRustResourceLease) async throws {
    let worker = worker
    try await runResourceWorker {
      try Task.checkCancellation()
      try await worker.releaseLease(lease)
    }
  }

  func rollback(
    inputKind: OwlRustResourceInputKind
  ) async throws -> OwlRustResourceActiveState {
    let worker = worker
    return try await runResourceWorker {
      try Task.checkCancellation()
      return try await worker.rollback(inputKind: inputKind)
    }
  }

  func recover(
    inputKind: OwlRustResourceInputKind
  ) async throws -> OwlRustResourceActiveState {
    let worker = worker
    return try await runResourceWorker {
      try Task.checkCancellation()
      return try await worker.recover(inputKind: inputKind)
    }
  }
}

private func runResourceWorker<T: Sendable>(
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let task = Task.detached(priority: .utility, operation: operation)
  return try await withTaskCancellationHandler {
    try await task.value
  } onCancel: {
    task.cancel()
  }
}

private struct OwlRustResourceWorker: Sendable {
  let configuration: OwlRustResourceConfiguration
  let engine: OwlRustEngineIdentity
  let faults: OwlRustResourceFaultInjection
  let permissions: OwlRustResourcePermissionOperations

  func install(
    _ source: any OwlRustResourceSource,
    progress: (@Sendable (Double) -> Void)?
  ) async throws -> OwlRustResourceInstallResult {
    let prepared = try await prepare(source, progress: progress)
    return try await activate(prepared)
  }

  func prepare(
    _ source: any OwlRustResourceSource,
    progress: (@Sendable (Double) -> Void)?
  ) async throws -> OwlRustResourcePrepared {
    let manifestData = try await source.readManifest()
    let manifest: OwlRustResourceManifest
    do {
      manifest = try JSONDecoder().decode(OwlRustResourceManifest.self, from: manifestData)
      try manifest.validateDigest()
      try OwlRustResourceVerifier.verifyEngineCompatibility(manifest: manifest, engine: engine)
    } catch let error as OwlRustResourceError {
      throw error
    } catch {
      throw OwlRustResourceError.invalidManifest(error.localizedDescription)
    }

    return try await withInputLock(manifest.inputKind) {
      try Task.checkCancellation()
      if let active = try readActive(manifest.inputKind) {
        try verifyCurrentActive(active, expectedManifest: manifest)
        if active.current.digest == manifest.digest {
          return OwlRustResourcePrepared(
            record: active.current,
            previousGenerationId: active.previous?.generationId
          )
        }
        guard active.current.manifest.version < manifest.version else {
          if active.current.manifest.version == manifest.version {
            throw OwlRustResourceError.versionDigestConflict(
              packageId: manifest.packageId,
              inputKind: manifest.inputKind,
              version: manifest.version
            )
          }
          throw OwlRustResourceError.invalidManifest(
            "新资源版本 \(manifest.version) 不高于 active \(active.current.manifest.version)"
          )
        }
      }
      try rejectDifferentDigestForVersion(manifest)

      let newRecord = OwlRustResourceRecord(
        generationId: Self.generationId(for: manifest.digest),
        digest: manifest.digest,
        manifest: manifest
      )
      let oldState = try readActive(manifest.inputKind)
      let transactionId = UUID()
      try writeJournal(
        OwlRustResourceTransactionJournal(
          schemaVersion: 1,
          id: transactionId,
          inputKind: manifest.inputKind,
          phase: .prepared,
          oldGenerationId: oldState?.current.generationId,
          newGenerationId: newRecord.generationId,
          updatedAt: Self.currentTimestamp(),
          message: nil
        )
      )

      do {
        try Task.checkCancellation()
        try await stageAndVerify(source: source, manifest: manifest, progress: progress)
        try Task.checkCancellation()
        try writeJournal(
          OwlRustResourceTransactionJournal(
            schemaVersion: 1,
            id: transactionId,
            inputKind: manifest.inputKind,
            phase: .generationPublished,
            oldGenerationId: oldState?.current.generationId,
            newGenerationId: newRecord.generationId,
            updatedAt: Self.currentTimestamp(),
            message: nil
          )
        )
        return OwlRustResourcePrepared(
          record: newRecord,
          previousGenerationId: oldState?.current.generationId
        )
      } catch {
        try? writeJournal(
          OwlRustResourceTransactionJournal(
            schemaVersion: 1,
            id: transactionId,
            inputKind: manifest.inputKind,
            phase: .failed,
            oldGenerationId: oldState?.current.generationId,
            newGenerationId: newRecord.generationId,
            updatedAt: Self.currentTimestamp(),
            message: String(describing: error)
          )
        )
        throw error
      }
    }
  }

  func activate(
    _ prepared: OwlRustResourcePrepared
  ) async throws -> OwlRustResourceInstallResult {
    let inputKind = prepared.record.manifest.inputKind
    return try await withInputLock(inputKind) {
      try Task.checkCancellation()
      guard prepared.record.digest == prepared.record.manifest.digest,
            prepared.record.generationId
              == Self.generationId(for: prepared.record.digest) else {
        throw OwlRustResourceError.activeStateInvalid(
          "prepared generation identity is inconsistent"
        )
      }
      try OwlRustResourceVerifier.verifyGeneration(
        at: generationURL(for: prepared.record),
        manifest: prepared.record.manifest,
        engine: engine,
        requireCompleteMarker: true
      )

      let active = try readActive(inputKind)
      if let active, active.current.digest == prepared.record.digest {
        return OwlRustResourceInstallResult(
          disposition: .alreadyActive, state: active
        )
      }
      guard active?.current.generationId == prepared.previousGenerationId else {
        throw OwlRustResourceError.activeStateInvalid(
          "active generation changed after preparation"
        )
      }
      if let active {
        guard active.current.manifest.version < prepared.record.manifest.version else {
          if active.current.manifest.version == prepared.record.manifest.version {
            throw OwlRustResourceError.versionDigestConflict(
              packageId: prepared.record.manifest.packageId,
              inputKind: inputKind,
              version: prepared.record.manifest.version
            )
          }
          throw OwlRustResourceError.invalidManifest(
            "新资源版本 \(prepared.record.manifest.version) 不高于 active "
              + "\(active.current.manifest.version)"
          )
        }
      }

      let transactionId = UUID()
      let oldGenerationId = active?.current.generationId
      try writeJournal(OwlRustResourceTransactionJournal(
        schemaVersion: 1, id: transactionId, inputKind: inputKind,
        phase: .generationPublished, oldGenerationId: oldGenerationId,
        newGenerationId: prepared.record.generationId,
        updatedAt: Self.currentTimestamp(), message: "activation"
      ))
      let nextState = OwlRustResourceActiveState(
        schemaVersion: 1,
        inputKind: inputKind,
        current: prepared.record,
        previous: active?.current,
        activatedAt: Self.currentTimestamp()
      )
      do {
        try Task.checkCancellation()
        try writeActive(nextState)
        try writeJournal(OwlRustResourceTransactionJournal(
          schemaVersion: 1, id: transactionId, inputKind: inputKind,
          phase: .activeWritten, oldGenerationId: oldGenerationId,
          newGenerationId: prepared.record.generationId,
          updatedAt: Self.currentTimestamp(), message: "activation"
        ))
        return OwlRustResourceInstallResult(
          disposition: .installed, state: nextState
        )
      } catch {
        try? writeJournal(OwlRustResourceTransactionJournal(
          schemaVersion: 1, id: transactionId, inputKind: inputKind,
          phase: .failed, oldGenerationId: oldGenerationId,
          newGenerationId: prepared.record.generationId,
          updatedAt: Self.currentTimestamp(), message: String(describing: error)
        ))
        throw error
      }
    }
  }

  func acquireLease(inputKind: OwlRustResourceInputKind) async throws -> OwlRustResourceLease {
    try await withInputLock(inputKind) {
      guard let active = try readActive(inputKind) else {
        throw OwlRustResourceError.activeStateMissing(inputKind)
      }
      try verifyActiveRecord(active.current)

      let id = UUID()
      let runtime = try safeDestination(
        relativePath: [
          inputKind.rawValue, active.current.generationId, id.uuidString,
        ].joined(separator: "/"),
        under: configuration.runtimeRoot
      )
      let lease = OwlRustResourceLease(
        id: id,
        inputKind: inputKind,
        generationId: active.current.generationId,
        runtimeURL: runtime,
        acquiredAt: Self.currentTimestamp()
      )
      do {
        try Task.checkCancellation()
        let process = try OwlRustResourceProcessIdentity.current()
        try FileManager.default.createDirectory(
          at: runtime.deletingLastPathComponent(),
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
        try createUniqueDirectory(runtime)
        for file in active.current.manifest.files.sorted(by: { $0.path < $1.path }) {
          try Task.checkCancellation()
          let source = try OwlRustResourceVerifier.safeFileURL(
            relativePath: file.path,
            under: generationURL(for: active.current)
          )
          let destination = try safeDestination(relativePath: file.path, under: runtime)
          try copyFileSynced(from: source, to: destination)
        }
        let marker = runtime.appendingPathComponent(".owl-runtime-complete")
        try writeSyncedData(Data((active.current.digest + "\n").utf8), to: marker)
        try syncDirectoryTree(runtime)
        try Task.checkCancellation()
        try writeSyncedData(
          try sortedJSON(OwlRustResourceLeaseRecord(
            lease: lease, process: process
          )),
          to: leaseURL(id)
        )
        return lease
      } catch {
        if FileManager.default.fileExists(atPath: runtime.path) {
          try? FileManager.default.removeItem(at: runtime)
        }
        throw error
      }
    }
  }

  func releaseLease(_ lease: OwlRustResourceLease) async throws {
    try await withInputLock(lease.inputKind) {
      let metadata = leaseURL(lease.id)
      guard FileManager.default.fileExists(atPath: metadata.path) else { return }
      let record: OwlRustResourceLeaseRecord
      do {
        record = try resourceJSONDecoder().decode(
          OwlRustResourceLeaseRecord.self, from: Data(contentsOf: metadata)
        )
      } catch {
        throw OwlRustResourceError.activeStateInvalid(
          "lease \(lease.id.uuidString) 元数据无法读取：\(error.localizedDescription)"
        )
      }
      guard record.lease.id == lease.id,
            record.lease.inputKind == lease.inputKind,
            record.lease.generationId == lease.generationId else {
        throw OwlRustResourceError.leaseNotFound(lease.id)
      }
      try removeLeaseFiles(record.lease)
    }
  }

  func rollback(inputKind: OwlRustResourceInputKind) async throws -> OwlRustResourceActiveState {
    try await withInputLock(inputKind) {
      guard let active = try readActive(inputKind) else {
        throw OwlRustResourceError.activeStateMissing(inputKind)
      }
      guard let previous = active.previous else {
        throw OwlRustResourceError.rollbackUnavailable(inputKind)
      }

      // .complete is only a hint. Revalidate every byte and the trusted engine
      // schema before publishing the old generation again.
      try verifyActiveRecord(previous)
      let transactionId = UUID()
      try writeJournal(
        OwlRustResourceTransactionJournal(
          schemaVersion: 1,
          id: transactionId,
          inputKind: inputKind,
          phase: .prepared,
          oldGenerationId: active.current.generationId,
          newGenerationId: previous.generationId,
          updatedAt: Self.currentTimestamp(),
          message: "rollback"
        )
      )
      let rolledBack = OwlRustResourceActiveState(
        schemaVersion: 1,
        inputKind: inputKind,
        current: previous,
        previous: active.current,
        activatedAt: Self.currentTimestamp()
      )
      do {
        try writeActive(rolledBack)
        try writeJournal(
          OwlRustResourceTransactionJournal(
            schemaVersion: 1,
            id: transactionId,
            inputKind: inputKind,
            phase: .activeWritten,
            oldGenerationId: active.current.generationId,
            newGenerationId: previous.generationId,
            updatedAt: Self.currentTimestamp(),
            message: "rollback"
          )
        )
        return rolledBack
      } catch {
        try? writeJournal(
          OwlRustResourceTransactionJournal(
            schemaVersion: 1,
            id: transactionId,
            inputKind: inputKind,
            phase: .failed,
            oldGenerationId: active.current.generationId,
            newGenerationId: previous.generationId,
            updatedAt: Self.currentTimestamp(),
            message: String(describing: error)
          )
        )
        throw error
      }
    }
  }

  func recover(inputKind: OwlRustResourceInputKind) async throws -> OwlRustResourceActiveState {
    try await withInputLock(inputKind) {
      guard let active = try readActive(inputKind) else {
        throw OwlRustResourceError.activeStateMissing(inputKind)
      }
      try verifyActiveRecord(active.current)
      try cleanupDeadLeases(inputKind: inputKind)
      return active
    }
  }

  private func stageAndVerify(
    source: any OwlRustResourceSource,
    manifest: OwlRustResourceManifest,
    progress: (@Sendable (Double) -> Void)?
  ) async throws {
    try Task.checkCancellation()
    let staging = try safeDestination(
      relativePath: [
        manifest.packageId, Self.generationId(for: manifest.digest),
      ].joined(separator: "/"),
      under: configuration.stagingRoot
    )
    if FileManager.default.fileExists(atPath: staging.path) {
      guard directoryExists(staging), !isSymbolicLink(staging) else {
        throw OwlRustResourceError.generationCorrupt("staging 路径不是目录")
      }
      try makeWritableTree(staging)
    } else {
      try FileManager.default.createDirectory(
        at: staging.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try createUniqueDirectory(staging)
    }
    var completedBytes = 0
    let totalBytes = max(manifest.files.reduce(0) { $0 + $1.size }, 1)
    progress?(0)

    for file in manifest.files.sorted(by: { $0.path < $1.path }) {
      try Task.checkCancellation()
      let destination = try safeDestination(relativePath: file.path, under: staging)
      if FileManager.default.fileExists(atPath: destination.path),
         (try? OwlRustResourceVerifier.verifyFile(destination, expected: file)) != nil {
        completedBytes += file.size
        progress?(min(Double(completedBytes) / Double(totalBytes), 1))
        continue
      }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      let partial = destination.appendingPathExtension("part")
      if FileManager.default.fileExists(atPath: partial.path) {
        try FileManager.default.removeItem(at: partial)
      }

      do {
        try await source.copyFile(file, to: partial)
        try Task.checkCancellation()
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as OwlRustResourceError {
        throw error
      } catch {
        throw OwlRustResourceError.sourceReadFailed(error.localizedDescription)
      }
      try faults.check(.afterPayloadWrite)
      try OwlRustResourceVerifier.verifyFile(partial, expected: file)
      try syncFile(partial)
      try faults.check(.afterPayloadSync)
      try renameExclusive(from: partial, to: destination)
      try syncDirectory(destination.deletingLastPathComponent())

      completedBytes += file.size
      progress?(min(Double(completedBytes) / Double(totalBytes), 1))
    }

    try Task.checkCancellation()
    let manifestURL = staging.appendingPathComponent("manifest.json", isDirectory: false)
    try writeSyncedData(try manifest.canonicalData(), to: manifestURL)
    try faults.check(.afterManifestSync)

    let completeURL = staging.appendingPathComponent(".complete", isDirectory: false)
    try writeSyncedData(Data((manifest.digest + "\n").utf8), to: completeURL)
    try applyReadOnlyPermissions(to: staging, manifest: manifest)
    try syncDirectoryTree(staging)
    try faults.check(.afterStagingDirectorySync)
    try OwlRustResourceVerifier.verifyGeneration(
      at: staging, manifest: manifest, engine: engine, requireCompleteMarker: true
    )
    try Task.checkCancellation()

    let final = generationURL(for: OwlRustResourceRecord(
      generationId: Self.generationId(for: manifest.digest),
      digest: manifest.digest,
      manifest: manifest
    ))
    if FileManager.default.fileExists(atPath: final.path) {
      try OwlRustResourceVerifier.verifyGeneration(
        at: final, manifest: manifest, engine: engine, requireCompleteMarker: true
      )
      // A previous transaction may have renamed a complete generation and then
      // failed while applying directory modes. Repair that state before reuse.
      try applyReadOnlyPermissions(to: final, manifest: manifest)
      try applyReadOnlyDirectories(to: final)
      try syncDirectoryTree(final)
      try makeWritableTree(staging)
      try? FileManager.default.removeItem(at: staging)
    } else {
      let generations = final.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true
      )
      try renameExclusive(from: staging, to: final)
      try syncDirectory(generations)
      try applyReadOnlyDirectories(to: final)
      try syncDirectoryTree(final)
    }
    try faults.check(.afterGenerationPublish)
  }

  private func writeActive(_ state: OwlRustResourceActiveState) throws {
    let directory = configuration.stateRoot.appendingPathComponent("active", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(
      state.inputKind.rawValue + ".json", isDirectory: false
    )
    let temporary = directory.appendingPathComponent(
      ".\(state.inputKind.rawValue).\(UUID().uuidString).tmp", isDirectory: false
    )
    try writeSyncedData(try sortedJSON(state), to: temporary)
    do {
      try Task.checkCancellation()
      try faults.check(.beforeActiveRename)
      try renameExclusive(from: temporary, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
    try faults.check(.afterActiveRename)
    try syncDirectory(directory)
  }

  private func readActive(
    _ inputKind: OwlRustResourceInputKind
  ) throws -> OwlRustResourceActiveState? {
    let url = configuration.stateRoot
      .appendingPathComponent("active", isDirectory: true)
      .appendingPathComponent(inputKind.rawValue + ".json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let state = try resourceJSONDecoder().decode(
        OwlRustResourceActiveState.self, from: Data(contentsOf: url)
      )
      guard state.schemaVersion == 1, state.inputKind == inputKind else {
        throw OwlRustResourceError.activeStateInvalid("schema 或 inputKind 不符")
      }
      return state
    } catch let error as OwlRustResourceError {
      throw error
    } catch {
      throw OwlRustResourceError.activeStateInvalid(error.localizedDescription)
    }
  }

  private func verifyCurrentActive(
    _ state: OwlRustResourceActiveState,
    expectedManifest: OwlRustResourceManifest
  ) throws {
    guard state.current.manifest.packageId == expectedManifest.packageId else {
      throw OwlRustResourceError.invalidManifest(
        "同一 inputKind 的 active packageId 为 \(state.current.manifest.packageId)"
      )
    }
    try verifyActiveRecord(state.current)
  }

  private func verifyActiveRecord(_ record: OwlRustResourceRecord) throws {
    guard record.digest == record.manifest.digest,
          record.generationId == Self.generationId(for: record.digest) else {
      throw OwlRustResourceError.activeStateInvalid(
        "generationId 与 manifest digest 不一致"
      )
    }
    try OwlRustResourceVerifier.verifyGeneration(
      at: generationURL(for: record),
      manifest: record.manifest,
      engine: engine,
      requireCompleteMarker: true
    )
  }

  private func rejectDifferentDigestForVersion(
    _ manifest: OwlRustResourceManifest
  ) throws {
    let generations = configuration.libraryRoot
      .appendingPathComponent(manifest.packageId, isDirectory: true)
      .appendingPathComponent("generations", isDirectory: true)
    guard FileManager.default.fileExists(atPath: generations.path) else { return }
    let children = try FileManager.default.contentsOfDirectory(
      at: generations, includingPropertiesForKeys: nil
    )
    for child in children {
      let manifestURL = child.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: manifestURL),
            let existing = try? JSONDecoder().decode(OwlRustResourceManifest.self, from: data) else {
        throw OwlRustResourceError.generationCorrupt(
          "无法读取 \(child.lastPathComponent)/manifest.json"
        )
      }
      if existing.inputKind == manifest.inputKind,
         existing.version == manifest.version,
         existing.packageId == manifest.packageId,
         existing.digest != manifest.digest {
        throw OwlRustResourceError.versionDigestConflict(
          packageId: manifest.packageId,
          inputKind: manifest.inputKind,
          version: manifest.version
        )
      }
    }
  }

  private func generationURL(for record: OwlRustResourceRecord) -> URL {
    configuration.libraryRoot
      .appendingPathComponent(record.manifest.packageId, isDirectory: true)
      .appendingPathComponent("generations", isDirectory: true)
      .appendingPathComponent(record.generationId, isDirectory: true)
  }

  private func leaseURL(_ id: UUID) -> URL {
    configuration.stateRoot
      .appendingPathComponent("leases", isDirectory: true)
      .appendingPathComponent(id.uuidString + ".json", isDirectory: false)
  }

  private func leaseRuntimeURL(_ lease: OwlRustResourceLease) throws -> URL {
    guard Self.isGenerationId(lease.generationId) else {
      throw OwlRustResourceError.generationCorrupt(
        "lease generationId 无效：\(lease.generationId)"
      )
    }
    return try safeDestination(
      relativePath: [
        lease.inputKind.rawValue, lease.generationId, lease.id.uuidString,
      ].joined(separator: "/"),
      under: configuration.runtimeRoot
    )
  }

  private func cleanupDeadLeases(inputKind: OwlRustResourceInputKind) throws {
    let directory = configuration.stateRoot.appendingPathComponent("leases", isDirectory: true)
    guard directoryExists(directory) else { return }
    let records = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    for url in records.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      where url.pathExtension == "json" {
      guard let record = try? resourceJSONDecoder().decode(
        OwlRustResourceLeaseRecord.self, from: Data(contentsOf: url)
      ), record.lease.inputKind == inputKind else {
        continue
      }
      if record.process.isDefinitelyDead {
        try removeLeaseFiles(record.lease)
      }
    }
  }

  private func removeLeaseFiles(_ lease: OwlRustResourceLease) throws {
    let runtime = try leaseRuntimeURL(lease)
    if FileManager.default.fileExists(atPath: runtime.path) {
      do {
        try FileManager.default.removeItem(at: runtime)
        try syncDirectory(runtime.deletingLastPathComponent())
      } catch {
        throw OwlRustResourceError.fileOperationFailed(
          path: runtime.path, message: error.localizedDescription
        )
      }
    }

    let metadata = leaseURL(lease.id)
    if FileManager.default.fileExists(atPath: metadata.path) {
      do {
        try FileManager.default.removeItem(at: metadata)
        try syncDirectory(metadata.deletingLastPathComponent())
      } catch {
        throw OwlRustResourceError.fileOperationFailed(
          path: metadata.path, message: error.localizedDescription
        )
      }
    }
  }

  private func withInputLock<T>(
    _ inputKind: OwlRustResourceInputKind,
    operation: () async throws -> T
  ) async throws -> T {
    let directories = [
      configuration.stagingRoot.appendingPathComponent(inputKind.rawValue, isDirectory: true),
      configuration.stateRoot.appendingPathComponent("locks", isDirectory: true),
      configuration.stateRoot.appendingPathComponent("transactions", isDirectory: true),
      configuration.stateRoot.appendingPathComponent("leases", isDirectory: true),
    ]
    for directory in directories {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let lockURL = directories[1].appendingPathComponent(inputKind.rawValue + ".lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw OwlRustResourceError.fileOperationFailed(
        path: lockURL.path, message: String(cString: strerror(errno))
      )
    }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EAGAIN else {
        throw OwlRustResourceError.fileOperationFailed(
          path: lockURL.path, message: String(cString: strerror(errno))
        )
      }
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(20))
    }
    defer { flock(descriptor, LOCK_UN) }
    return try await operation()
  }

  private func writeJournal(_ journal: OwlRustResourceTransactionJournal) throws {
    let directory = configuration.stateRoot.appendingPathComponent("transactions", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(journal.id.uuidString + ".json")
    let temporary = directory.appendingPathComponent(
      ".\(journal.id.uuidString).\(UUID().uuidString).tmp"
    )
    try writeSyncedData(try sortedJSON(journal), to: temporary)
    try renameExclusive(from: temporary, to: url)
    try syncDirectory(directory)
  }

  private func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  private func resourceJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private func safeDestination(relativePath: String, under root: URL) throws -> URL {
    try OwlRustResourceManifest.validateRelativePath(relativePath)
    var current = root
    let components = relativePath.split(separator: "/").map(String.init)
    for (index, component) in components.enumerated() {
      current.appendPathComponent(component, isDirectory: index < components.count - 1)
      var info = stat()
      if lstat(current.path, &info) != 0 {
        if errno == ENOENT {
          continue
        }
        throw OwlRustResourceError.fileOperationFailed(
          path: current.path, message: String(cString: strerror(errno))
        )
      }
      guard (info.st_mode & S_IFMT) != S_IFLNK else {
        throw OwlRustResourceError.fileNotRegular(relativePath)
      }
      if index < components.count - 1, (info.st_mode & S_IFMT) != S_IFDIR {
        throw OwlRustResourceError.fileNotRegular(relativePath)
      }
    }
    return current
  }

  private func createUniqueDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: error.localizedDescription
      )
    }
  }

  private func copyFileSynced(from source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let partial = destination.appendingPathExtension("part")
    if FileManager.default.fileExists(atPath: partial.path) {
      try FileManager.default.removeItem(at: partial)
    }
    guard FileManager.default.createFile(
      atPath: partial.path, contents: nil,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw OwlRustResourceError.fileOperationFailed(
        path: partial.path, message: "无法创建 runtime 文件"
      )
    }
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: partial)
    defer {
      try? input.close()
      try? output.close()
    }
    while true {
      try Task.checkCancellation()
      guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else {
        break
      }
      try output.write(contentsOf: chunk)
    }
    try output.synchronize()
    try renameExclusive(from: partial, to: destination)
  }

  private func writeSyncedData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    guard FileManager.default.createFile(
      atPath: url.path, contents: nil,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: "无法创建文件"
      )
    }
    let handle = try FileHandle(forWritingTo: url)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: error.localizedDescription
      )
    }
  }

  private func syncFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: String(cString: strerror(errno))
      )
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: String(cString: strerror(errno))
      )
    }
  }

  private func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: String(cString: strerror(errno))
      )
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw OwlRustResourceError.fileOperationFailed(
        path: url.path, message: String(cString: strerror(errno))
      )
    }
  }

  private func syncDirectoryTree(_ root: URL) throws {
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    var directories = [root]
    while let url = enumerator?.nextObject() as? URL {
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(url)
      }
    }
    for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
      try syncDirectory(directory)
    }
  }

  private func renameExclusive(from source: URL, to destination: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
      throw OwlRustResourceError.fileOperationFailed(
        path: destination.path, message: String(cString: strerror(errno))
      )
    }
  }

  private func makeWritableTree(_ root: URL) throws {
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isDirectoryKey]
    )
    var entries = [root]
    while let url = enumerator?.nextObject() as? URL {
      entries.append(url)
    }
    for url in entries.sorted(by: { $0.path.count > $1.path.count }) {
      var info = stat()
      guard lstat(url.path, &info) == 0,
            (info.st_mode & S_IFMT) != S_IFLNK else {
        throw OwlRustResourceError.generationCorrupt(
          "可写化目录树含 symlink 或无法读取：\(url.path)"
        )
      }
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      try permissions.setMode(url, isDirectory ? 0o700 : 0o600)
    }
  }

  private func applyReadOnlyPermissions(
    to root: URL, manifest: OwlRustResourceManifest
  ) throws {
    for file in manifest.files {
      let url = root.appendingPathComponent(file.path)
      try permissions.setMode(url, 0o444)
    }
    let manifestURL = root.appendingPathComponent("manifest.json")
    try permissions.setMode(manifestURL, 0o444)
    let completeURL = root.appendingPathComponent(".complete")
    try permissions.setMode(completeURL, 0o444)
  }

  private func applyReadOnlyDirectories(to root: URL) throws {
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isDirectoryKey]
    )
    var directories = [root]
    while let url = enumerator?.nextObject() as? URL {
      var info = stat()
      guard lstat(url.path, &info) == 0,
            (info.st_mode & S_IFMT) != S_IFLNK else {
        throw OwlRustResourceError.generationCorrupt(
          "只读化目录树含 symlink 或无法读取：\(url.path)"
        )
      }
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(url)
      }
    }
    for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
      try permissions.setMode(directory, 0o555)
    }
  }

  private static func generationId(for digest: String) -> String {
    "sha256-" + digest.dropFirst("sha256:".count)
  }

  private static func currentTimestamp() -> Date {
    Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
  }

  private static func isGenerationId(_ generationId: String) -> Bool {
    guard generationId.hasPrefix("sha256-"), generationId.count == 71 else {
      return false
    }
    return OwlRustResourceManifest.isValidDigest(
      "sha256:" + generationId.dropFirst("sha256-".count)
    )
  }
}

private func directoryExists(_ url: URL) -> Bool {
  var isDirectory: ObjCBool = false
  return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    && isDirectory.boolValue
}

private func isSymbolicLink(_ url: URL) -> Bool {
  var info = stat()
  guard lstat(url.path, &info) == 0 else { return false }
  return (info.st_mode & S_IFMT) == S_IFLNK
}
