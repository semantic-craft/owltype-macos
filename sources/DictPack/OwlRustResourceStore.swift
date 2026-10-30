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

struct OwlRustResourceConfiguration: Codable, Sendable {
  let libraryRoot: URL
  let stagingRoot: URL
  let runtimeRoot: URL
  let stateRoot: URL
  let userRoot: URL
  let cacheRoot: URL

  func prepared(using volumes: OwlRustResourceVolumeIdentity) throws -> Self {
    let urls = [libraryRoot, stagingRoot, runtimeRoot, stateRoot, userRoot, cacheRoot]
    guard urls.allSatisfy(\.isFileURL) else { throw OwlRustResourceError.invalidConfiguration("所有根必须为 file URL") }
    let paths: [String: String] = try OwlResourceBusiness.call("configuration", [
      "libraryRoot": libraryRoot.path, "stagingRoot": stagingRoot.path, "runtimeRoot": runtimeRoot.path,
      "stateRoot": stateRoot.path, "userRoot": userRoot.path, "cacheRoot": cacheRoot.path,
    ])
    func url(_ name: String) -> URL { URL(fileURLWithPath: paths[name]!, isDirectory: true) }
    let prepared = Self(libraryRoot: url("libraryRoot"), stagingRoot: url("stagingRoot"), runtimeRoot: url("runtimeRoot"),
      stateRoot: url("stateRoot"), userRoot: url("userRoot"), cacheRoot: url("cacheRoot"))
    let _: Bool = try OwlResourceBusiness.call("volumes", ["library": volumes.identifier(prepared.libraryRoot), "staging": volumes.identifier(prepared.stagingRoot)])
    return prepared
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

enum OwlRustResourceInstallDisposition: String, Codable, Equatable, Sendable {
  case installed
  case alreadyActive
}

struct OwlRustResourceInstallResult: Codable, Equatable, Sendable {
  let disposition: OwlRustResourceInstallDisposition
  let state: OwlRustResourceActiveState
}

struct OwlRustResourcePrepared: Codable, Equatable, Sendable {
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

actor OwlRustResourceStore {
  private let worker: OwlRustResourceWorker

  init(
    configuration: OwlRustResourceConfiguration,
    engine: OwlRustEngineIdentity,
    volumes: OwlRustResourceVolumeIdentity = .system,
    faults: OwlRustResourceFaultInjection = .none,
    permissions: OwlRustResourcePermissionOperations = .system,
    requireCompatibleResources: Bool = false
  ) throws {
    let prepared = try configuration.prepared(using: volumes)
    worker = OwlRustResourceWorker(
      configuration: prepared, engine: engine, faults: faults,
      permissions: permissions, requireCompatibleResources: requireCompatibleResources
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

  func prepareBundled(sharedSupport: URL, at root: URL, progress: (@Sendable (Double) -> Void)?) async throws -> OwlRustDictPackPreparedResources {
    let worker = worker
    return try await runResourceWorker { try await worker.prepareBundled(sharedSupport: sharedSupport, at: root, progress: progress) }
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
  let requireCompatibleResources: Bool

  func install(_ source: any OwlRustResourceSource, progress: (@Sendable (Double) -> Void)?) async throws -> OwlRustResourceInstallResult {
    try await sourceCall("resource_install", source: source, progress: progress)
  }
  func prepare(_ source: any OwlRustResourceSource, progress: (@Sendable (Double) -> Void)?) async throws -> OwlRustResourcePrepared {
    try await sourceCall("resource_prepare", source: source, progress: progress)
  }
  private func sourceCall<T: Decodable & Sendable>(_ operation: String, source: any OwlRustResourceSource, progress: (@Sendable (Double) -> Void)?) async throws -> T {
    let data = try await source.readManifest()
    let manifest: OwlRustResourceManifest
    do { manifest = try JSONDecoder().decode(OwlRustResourceManifest.self, from: data) }
    catch { throw OwlRustResourceError.invalidManifest(error.localizedDescription) }
    return try await call(operation, ["manifest": payload(manifest)], source: source, progress: progress)
  }
  func prepareBundled(sharedSupport: URL, at root: URL, progress: (@Sendable (Double) -> Void)?) async throws -> OwlRustDictPackPreparedResources {
    try await call("resource_prepare_bundled", ["sharedSupport": sharedSupport.path, "root": root.path], progress: progress)
  }

  func activate(_ prepared: OwlRustResourcePrepared) async throws -> OwlRustResourceInstallResult {
    try await call("resource_activate", ["prepared": payload(prepared)])
  }
  func acquireLease(inputKind: OwlRustResourceInputKind) async throws -> OwlRustResourceLease {
    try await call("resource_acquire", ["inputKind": inputKind.rawValue])
  }
  func releaseLease(_ lease: OwlRustResourceLease) async throws {
    let _: Bool = try await call("resource_release", ["lease": payload(lease)])
  }
  func rollback(inputKind: OwlRustResourceInputKind) async throws -> OwlRustResourceActiveState {
    try await call("resource_rollback", ["inputKind": inputKind.rawValue])
  }
  func recover(inputKind: OwlRustResourceInputKind) async throws -> OwlRustResourceActiveState {
    try await call("resource_recover", ["inputKind": inputKind.rawValue])
  }
  private func payload<T: Encodable>(_ value: T) -> Any {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try! JSONSerialization.jsonObject(with: encoder.encode(value))
  }
  private func decode<T: Decodable>(_ value: Any) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: value))
  }
  private func readEffect(_ operation: String, _ args: [String: Any]) throws -> Any {
    let path = args["path"] as? String ?? ""
    let url = URL(fileURLWithPath: path)
    let fm = FileManager.default
    switch operation {
    case "resource_native_exists": return fm.fileExists(atPath: path)
    case "resource_native_kind": return directoryExists(url) && !isSymbolicLink(url) ? "directory" : "other"
    case "resource_native_now": return ISO8601DateFormatter().string(from: Self.currentTimestamp())
    case "resource_native_uuid": return UUID().uuidString
    case "resource_native_safe":
        return try safeDestination(relativePath: args["relative"] as? String ?? "", under: URL(fileURLWithPath: args["root"] as? String ?? "")).path
    case "resource_native_safe_file":
        return try OwlRustResourceVerifier.safeFileURL(relativePath: args["relative"] as? String ?? "", under: URL(fileURLWithPath: args["root"] as? String ?? "")).path
    case "resource_native_list": return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).map(\.path)
    case "resource_native_read_json": return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    case "resource_native_decode_active": let _: OwlRustResourceActiveState = try decode(args["state"]!); return true
    case "resource_native_read_lease":
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let _: OwlRustResourceLeaseRecord = try decode(value)
        return value
    case "resource_native_file_url": return url.absoluteString
    case "resource_native_process": return payload(try OwlRustResourceProcessIdentity.current())
    case "resource_native_process_dead": let process: OwlRustResourceProcessIdentity = try decode(args["process"]!); return process.isDefinitelyDead
    default: throw OwlAppCore.Failure(code: "unknown_resource_read_effect")
    }
  }
  private func writeEffect(_ operation: String, _ args: [String: Any], cancellation: OwlResourceCancellation) throws -> Any {
    let path = args["path"] as? String ?? ""
    let url = URL(fileURLWithPath: path)
    let fm = FileManager.default
    switch operation {
    case "resource_native_mkdir": try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return true
    case "resource_native_sync": try syncFile(url); return true
    case "resource_native_remove": if fm.fileExists(atPath: path) { try fm.removeItem(at: url) }; return true
    case "resource_native_write": try writeSyncedData(Data(args["bytes"] as? [UInt8] ?? []), to: url); return true
    case "resource_native_rename":
        try renameExclusive(from: URL(fileURLWithPath: args["source"] as? String ?? ""), to: URL(fileURLWithPath: args["destination"] as? String ?? "")); return true
    case "resource_native_writable_tree": try makeWritableTree(url); return true
    case "resource_native_unique_directory": try createUniqueDirectory(url); return true
    case "resource_native_sync_tree": try syncDirectoryTree(url); return true
    case "resource_native_readonly_directories": try applyReadOnlyDirectories(to: url); return true
    case "resource_native_chmod": try permissions.setMode(url, mode_t(args["mode"] as? Int ?? 0)); return true
    case "resource_native_copy_synced":
        try copyFileSynced(from: URL(fileURLWithPath: args["source"] as? String ?? ""), to: URL(fileURLWithPath: args["destination"] as? String ?? ""), cancellation: cancellation); return true
    default: throw OwlAppCore.Failure(code: "unknown_resource_write_effect")
    }
  }
  private func acquireNativeLock(_ path: String, cancellation: OwlResourceCancellation) throws -> Int32 {
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw OwlRustResourceError.fileOperationFailed(path: path, message: String(cString: strerror(errno))) }
    do {
      while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EAGAIN else { throw OwlRustResourceError.fileOperationFailed(path: path, message: String(cString: strerror(errno))) }
        try cancellation.check()
        usleep(20_000)
      }
    } catch { close(fd); throw error }
    return fd
  }
  /// Filesystem locking and the synchronous Rust ABI run on a GCD worker. They
  /// must not occupy a cooperative Task thread while awaiting an async source.
  private func call<T: Decodable & Sendable>(_ operation: String, _ args: [String: Any],
                                            source: (any OwlRustResourceSource)? = nil,
                                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> T {
    let bytes = try JSONSerialization.data(withJSONObject: args)
    let cancellation = OwlResourceCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          do {
            try cancellation.check()
            let arguments = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let value: T = try callBlocking(operation, arguments, source: source, progress: progress, cancellation: cancellation)
            continuation.resume(returning: value)
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: { cancellation.cancel() }
  }

  private func callBlocking<T: Decodable>(_ operation: String, _ args: [String: Any],
                                 source: (any OwlRustResourceSource)? = nil,
                                 progress: (@Sendable (Double) -> Void)? = nil, cancellation: OwlResourceCancellation) throws -> T {
    let host = OwlStorageHost(dataDir: configuration.stateRoot)
    var descriptors: [Int32] = []
    defer { for fd in descriptors { flock(fd, LOCK_UN); close(fd) } }
    host.nativeEffect = { operation, args in
      let path = args["path"] as? String ?? ""
      if ["resource_native_exists", "resource_native_kind", "resource_native_now", "resource_native_uuid", "resource_native_safe", "resource_native_safe_file", "resource_native_list", "resource_native_read_json", "resource_native_decode_active", "resource_native_read_lease", "resource_native_file_url", "resource_native_process", "resource_native_process_dead"].contains(operation) { return try readEffect(operation, args) }
      if ["resource_native_mkdir", "resource_native_sync", "resource_native_remove", "resource_native_write", "resource_native_rename", "resource_native_writable_tree", "resource_native_unique_directory", "resource_native_sync_tree", "resource_native_readonly_directories", "resource_native_chmod", "resource_native_copy_synced"].contains(operation) { return try writeEffect(operation, args, cancellation: cancellation) }
      switch operation {
      case "resource_native_cancel": try cancellation.check(); return true
      case "resource_native_fault": try faults.check(OwlRustResourceFaultPoint(rawValue: args["point"] as? String ?? "")!); return true
      case "resource_native_progress": progress?(args["fraction"] as? Double ?? 0); return true
      case "resource_native_copy_source":
        let transport: any OwlRustResourceSource
        if let source { transport = source }
        else if let root = args["sourceRoot"] as? String { transport = OwlRustResourceDirectorySource(root: URL(fileURLWithPath: root)) }
        else { throw OwlRustResourceError.sourceReadFailed("missing transport") }
        let file: OwlRustResourceFile = try decode(args["file"]!)
        let destination = URL(fileURLWithPath: args["destination"] as? String ?? "")
        do { try resourceTransport(cancellation: cancellation) { try await transport.copyFile(file, to: destination) } }
        catch is CancellationError { throw CancellationError() }
        catch let error as OwlRustResourceError { throw error }
        catch { throw OwlRustResourceError.sourceReadFailed(error.localizedDescription) }
        return true
      case "resource_native_lock": descriptors.append(try acquireNativeLock(path, cancellation: cancellation)); return true
      case "resource_native_unlock": if let fd = descriptors.popLast() { flock(fd, LOCK_UN); close(fd) }; return true
      default: throw OwlAppCore.Failure(code: "unknown_resource_effect")
      }
    }
    var request = args
    request["configuration"] = ["libraryRoot": configuration.libraryRoot.path, "stagingRoot": configuration.stagingRoot.path,
      "runtimeRoot": configuration.runtimeRoot.path, "stateRoot": configuration.stateRoot.path,
      "userRoot": configuration.userRoot.path, "cacheRoot": configuration.cacheRoot.path]
    request["engine"] = payload(engine)
    request["compatible"] = requireCompatibleResources
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do { return try host.call(operation, request, decoder: decoder) }
    catch let failure as OwlAppCore.Failure { throw OwlResourceBusiness.map(failure) }
  }

  private func safeDestination(relativePath: String, under root: URL) throws -> URL {
    let path: String = try OwlResourceBusiness.call("safe_destination", ["path": relativePath, "root": root.path])
    return URL(fileURLWithPath: path)
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

  private func copyFileSynced(from source: URL, to destination: URL, cancellation: OwlResourceCancellation) throws {
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
      try cancellation.check()
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

  private static func currentTimestamp() -> Date {
    Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
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

/// Bridges an asynchronous source primitive on the dedicated resource worker only.
/// Cancellation joins the transport before returning so no abandoned copy can write
/// into a later transaction. No AppKit callback or input-path caller uses this bridge.
private final class OwlResourceTransportResult<T>: @unchecked Sendable {
  let lock = NSLock()
  var result: Result<T, Error>?
  func set(_ value: Result<T, Error>) { lock.lock(); result = value; lock.unlock() }
  func get() throws -> T { lock.lock(); defer { lock.unlock() }; return try result!.get() }
}

private func resourceTransport<T: Sendable>(cancellation: OwlResourceCancellation, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
  let result = OwlResourceTransportResult<T>()
  let finished = DispatchSemaphore(value: 0)
  let task = Task.detached(priority: .utility) {
    do { result.set(.success(try await operation())) }
    catch { result.set(.failure(error)) }
    finished.signal()
  }
  while finished.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
    if cancellation.isCancelled { task.cancel() }
  }
  try cancellation.check()
  return try result.get()
}

private final class OwlResourceCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  func check() throws { if isCancelled { throw CancellationError() } }
}
