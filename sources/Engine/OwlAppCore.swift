import Foundation

private struct OwlAppCoreResponse<Value: Decodable>: Decodable {
  enum CodingKeys: String, CodingKey { case isOK = "ok", value, error }
  let isOK: Bool
  let value: Value?
  let error: String?
}

/// Transport only. Business defaults, validation and decisions live in owl-app-core.
enum OwlAppCore {
  static let abiVersion: UInt32 = 1

  struct Failure: Error, Equatable {
    let code: String
  }

  static func call<Value: Decodable>(_ request: [String: Any],
                                     version: UInt32 = abiVersion) throws -> Value {
    let bytes = try JSONSerialization.data(withJSONObject: request)
    let response = bytes.withUnsafeBytes { buffer in
      owl_app_call(version, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
    }
    guard let response else { throw Failure(code: "missing_response") }
    defer { owl_app_string_free(response) }
    let data = Data(bytes: response, count: strlen(response))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(OwlAppCoreResponse<Value>.self, from: data)
    guard decoded.isOK, let value = decoded.value else {
      throw Failure(code: decoded.error ?? "invalid_response")
    }
    return value
  }

  static func initialASCIIMode(bundleID: String, englishBundleIDs: [String], defaultASCIIMode: Bool) -> Bool {
    // All fields are statically constructed. A failure here indicates incompatible linked code,
    // not a recoverable user setting; do not silently introduce a second Swift rule.
    do {
      return try call(["operation": "initial_ascii_mode", "bundle_id": bundleID,
                       "english_bundle_ids": englishBundleIDs, "default_ascii": defaultASCIIMode])
    } catch {
      preconditionFailure("Incompatible Owltype App core ABI")
    }
  }
}

extension OwlAppCore {
  static func payload<Value: Encodable>(_ value: Value) -> Any {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    do { return try JSONSerialization.jsonObject(with: encoder.encode(value)) }
    catch { preconditionFailure("Invalid native App core payload") }
  }

  static let defaultKeyboard: EffectiveKeyboard = required(["operation": "keyboard_effective", "raw": [:]])

  static func required<Value: Decodable>(_ request: [String: Any]) -> Value {
    do { return try call(request) } catch { preconditionFailure("Incompatible Owltype App core ABI: \(error)") }
  }

  struct KeyboardSwitch: Decodable {
    let id: String
    let key: String
    let defaultValue: Bool
    let application: String
    let option: String
    let requiresIdle: Bool
    let reappliesConfiguration: Bool
  }
  struct FuzzySwitch: Decodable {
    let id: String
    let key: String
    let defaultValue: Bool
  }
  struct SchemaConfiguration: Decodable {
    let id: String
    let name: String
    let validConfigID: Bool
    let inputMode: String
    let wubiProfile: String
    let doublePinyinScheme: String
    let pinyinScheme: String
    let traditional: Bool
    let customProfile: [String: [[String]]]?
  }
  struct KeyboardCatalog: Decodable {
    let idleSettings: Set<String>
    let auxiliaryDefaults: [String: Bool]
    let exportDefaults: [String: Bool]
    let exportTargets: [OwlWubiPatchTarget]
    let switches: [KeyboardSwitch]
    let fuzzy: [FuzzySwitch]
    let schemas: [SchemaConfiguration]
    let doublePinyinSchemas: [String: String]
    let wubiSchemas: [String: String]
    let candidateFilters: [String: String?]
  }
  static let keyboardCatalog: KeyboardCatalog = required(["operation": "keyboard_catalog"])

  struct EffectiveKeyboard: Decodable {
    let inputMethod: String
    let wubiScheme: String
    let doublePinyin: String
    let candidateMode: String
    let pageSize: Int
    let preferredSchemaID: String
  }
  private struct RawKeyboard: Equatable {
    let inputMethod: String?
    let wubiScheme: String?
    let doublePinyin: String?
    let candidateMode: String?
    let pageSize: Int
    var payload: [String: Any] {
      ["inputMethod": inputMethod as Any? ?? NSNull(), "wubiScheme": wubiScheme as Any? ?? NSNull(),
       "doublePinyin": doublePinyin as Any? ?? NSNull(), "candidateMode": candidateMode as Any? ?? NSNull(),
       "pageSize": pageSize]
    }
  }
  // The host caches a value projection, not a second policy. External defaults writes are
  // visible on the next read, without decoding a JSON response for each setting or keystroke.
  private static var keyboardCache: (raw: RawKeyboard, effective: EffectiveKeyboard)?
  static var effectiveKeyboard: EffectiveKeyboard {
    let defaults = OwlDefaults.standard
    let raw = RawKeyboard(inputMethod: defaults.string(forKey: "OwlKeyboardInputMethod"),
                          wubiScheme: defaults.string(forKey: "OwlKeyboardWubiScheme"),
                          doublePinyin: defaults.string(forKey: "OwlKeyboardDoublePinyin"),
                          candidateMode: defaults.string(forKey: "OwlKeyboardWubiCandidateMode"),
                          pageSize: defaults.integer(forKey: "OwlKeyboardPageSize"))
    if let cached = keyboardCache, cached.raw == raw { return cached.effective }
    let value: EffectiveKeyboard = required(["operation": "keyboard_effective", "raw": raw.payload])
    keyboardCache = (raw, value)
    return value
  }

  private static var fuzzyCache: (snapshot: OwlFuzzySnapshot, mask: UInt32)?
  static func fuzzyMask(_ snapshot: OwlFuzzySnapshot) -> UInt32 {
    if let cached = fuzzyCache, cached.snapshot == snapshot { return cached.mask }
    let mask: UInt32 = required(["operation": "keyboard_fuzzy_mask", "values":
      [snapshot.zhz, snapshot.chc, snapshot.shs, snapshot.nl, snapshot.rl, snapshot.fh,
       snapshot.anang, snapshot.eneng, snapshot.ining]])
    fuzzyCache = (snapshot, mask)
    return mask
  }

  struct KeyboardSelection: Decodable { let schema: String? }

  struct KeyboardApplication: Decodable {
    let blocked: Bool
    let effects: [String]
  }
}

/// Native services for Rust-owned storage protocols. This adapter performs one primitive
/// at a time; it has no knowledge of library modes, write ordering or recovery phases.
final class OwlStorageHost {
  let dataDir: URL
  let checkpoint: (String) throws -> Void
  let writerCheckpoint: (String) throws -> Void
  var nativeEffect: ((String, [String: Any]) throws -> Any)?
  var errors: [String: Error] = [:]
  private var heldLockKeys: [String] = []
  private var heldProcessDepth = 0
  private var response: UnsafeMutablePointer<CChar>?
  init(dataDir: URL, checkpoint: @escaping (String) throws -> Void = { _ in },
       writerCheckpoint: @escaping (String) throws -> Void = { _ in }) {
    self.dataDir = dataDir
    self.checkpoint = checkpoint
    self.writerCheckpoint = writerCheckpoint
  }
  deinit { free(response) }
  private func url(_ name: String) -> URL {
    name.hasPrefix("/") ? URL(fileURLWithPath: name) : dataDir.appendingPathComponent(name)
  }
  private func perform(_ operation: String, _ args: [String: Any]) throws -> Any {
    if (operation.hasPrefix("user_native_") || operation.hasPrefix("resource_native_")), let nativeEffect { return try nativeEffect(operation, args) }
    if ["title_ranks", "case_contains", "localized_contains"].contains(operation) {
      return try compare(operation, args)
    }
    if ["path", "file_url", "sibling", "rename"].contains(operation) { return try paths(operation, args) }
    if ["library_committed", "uuid", "checkpoint", "process_lock", "process_unlock", "lock", "unlock"].contains(operation) {
      return try control(operation, args)
    }
    let name = args["name"] as? String ?? ""
    let target = url(name)
    let fm = FileManager.default
    switch operation {
    case "read":
      guard fm.fileExists(atPath: target.path) else { return NSNull() }
      return Array(try Data(contentsOf: target))
    case "write":
      let bytes = Data((args["bytes"] as? [UInt8]) ?? [])
      try OwlPrivateStorage.prepareDirectory(target.deletingLastPathComponent())
      try bytes.write(to: target, options: .atomic)
      try fm.setAttributes([.posixPermissions: args["permissions"] as? Int ?? 0o600], ofItemAtPath: target.path)
      return true
    case "replace":
      let bytes = Data((args["bytes"] as? [UInt8]) ?? [])
      try OwlPrivateStorage.prepareDirectory(target.deletingLastPathComponent())
      let temporary = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + "." + (args["suffix"] as? String ?? "owl.tmp"))
      try bytes.write(to: temporary, options: .atomic)
      if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temporary) }
      else { try fm.moveItem(at: temporary, to: target) }
      try OwlPrivateStorage.hardenFile(target)
      return true
    case "remove":
      if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
      return true
    case "permissions":
      guard fm.fileExists(atPath: target.path) else { return NSNull() }
      return (try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber) ?? NSNumber(value: 0o600)
    case "relative":
      let target = URL(fileURLWithPath: args["path"] as? String ?? "").standardizedFileURL
      let root = dataDir.standardizedFileURL.path
      return target.path.hasPrefix(root + "/") ? String(target.path.dropFirst(root.count + 1)) : target.lastPathComponent
    default: throw OwlAppCore.Failure(code: "unknown_native_effect")
    }
  }
  private func control(_ operation: String, _ args: [String: Any]) throws -> Any {
    let name = args["name"] as? String ?? ""
    switch operation {
    case "library_committed": OwlTemplateStore.notifyCommittedLibrary(dataDir: dataDir); return true
    case "uuid": return UUID().uuidString
    case "checkpoint":
      if args["channel"] as? String == "writer" { try writerCheckpoint(name) }
      else { try checkpoint(name) }
      return true
    case "process_lock": Self.lock.lock(); heldProcessDepth += 1; return true
    case "process_unlock": Self.lock.unlock(); heldProcessDepth -= 1; return true
    case "lock": heldLockKeys.append(try Self.acquire(dataDir)); return true
    case "unlock": if let key = heldLockKeys.popLast() { Self.release(key) }; return true
    default: throw OwlAppCore.Failure(code: "unknown_native_control")
    }
  }
  private func paths(_ operation: String, _ args: [String: Any]) throws -> Any {
    let target = url(args["name"] as? String ?? "")
    let fm = FileManager.default
    switch operation {
    case "path": return target.path
    case "file_url": return target.absoluteString
    case "sibling": return target.deletingLastPathComponent().appendingPathComponent(args["sibling"] as? String ?? "").path
    case "rename":
      let source = url(args["source"] as? String ?? "")
      let destination = url(args["destination"] as? String ?? "")
      if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: source, options: .usingNewMetadataOnly) }
      else { try fm.moveItem(at: source, to: destination) }
      return true
    default: throw OwlAppCore.Failure(code: "unknown_native_path_effect")
    }
  }
  private func compare(_ operation: String, _ args: [String: Any]) throws -> Any {
    switch operation {
    case "title_ranks":
      let titles = args["titles"] as? [String] ?? []
      let order = titles.indices.sorted { titles[$0].localizedStandardCompare(titles[$1]) == .orderedAscending }
      var ranks = [Int](repeating: 0, count: titles.count)
      var rank = 0
      for (position, index) in order.enumerated() {
        if position > 0 && titles[order[position - 1]].localizedStandardCompare(titles[index]) != .orderedSame { rank += 1 }
        ranks[index] = rank
      }
      return ranks
    case "case_contains":
      let values = args["values"] as? [String] ?? []
      let value = args["value"] as? String ?? ""
      return values.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    case "localized_contains":
      return (args["text"] as? String ?? "").localizedCaseInsensitiveContains(args["query"] as? String ?? "")
    default: throw OwlAppCore.Failure(code: "unknown_native_comparison")
    }
  }
  fileprivate func respond(_ request: UnsafePointer<CChar>) -> UnsafePointer<CChar>? {
    free(response)
    let result: [String: Any]
    do {
      let data = Data(bytes: request, count: strlen(request))
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
      result = ["ok": true, "value": try perform(object["operation"] as? String ?? "", object["args"] as? [String: Any] ?? [:])]
    } catch {
      let token = "native:" + UUID().uuidString
      errors[token] = error
      result = ["ok": false, "error": token]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) else { return nil }
    response = strdup(String(decoding: data, as: UTF8.self))
    return response.map { UnsafePointer($0) }
  }
  private static let lock = NSRecursiveLock()
  private static var locks: [String: (descriptor: Int32, depth: Int)] = [:]
  static func exclusively<T>(_ action: () throws -> T) rethrows -> T {
    lock.lock(); defer { lock.unlock() }; return try action()
  }
  static func acquire(_ dataDir: URL) throws -> String {
    lock.lock()
    let directory = dataDir.standardizedFileURL.resolvingSymlinksInPath()
    let key = directory.path
    if var held = locks[key] { held.depth += 1; locks[key] = held; return key }
    do {
      try OwlPrivateStorage.prepareDirectory(directory)
      let descriptor = open(directory.appendingPathComponent(".owl-template-write.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
      guard descriptor >= 0 else { throw OwlTemplateError.invalid("无法锁定模板库，请检查目录权限。") }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor); throw OwlTemplateError.invalid("另一个实例正在修改模板库，请稍后重试。")
      }
      locks[key] = (descriptor, 1)
      return key
    } catch { lock.unlock(); throw error }
  }
  static func release(_ key: String) {
    guard var held = locks[key] else { return }
    held.depth -= 1
    if held.depth == 0 { flock(held.descriptor, LOCK_UN); close(held.descriptor); locks.removeValue(forKey: key) }
    else { locks[key] = held }
    lock.unlock()
  }
  func call<Value: Decodable>(_ operation: String, _ args: [String: Any] = [:], decoder: JSONDecoder = JSONDecoder()) throws -> Value {
    let initialDepth = heldLockKeys.count
    let initialProcessDepth = heldProcessDepth
    defer {
      while heldLockKeys.count > initialDepth { Self.release(heldLockKeys.removeLast()) }
      while heldProcessDepth > initialProcessDepth { Self.lock.unlock(); heldProcessDepth -= 1 }
    }
    let bytes = try JSONSerialization.data(withJSONObject: ["operation": operation, "args": args])
    let response = bytes.withUnsafeBytes { buffer in
      owl_app_storage_call(OwlAppCore.abiVersion, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count,
        Unmanaged.passUnretained(self).toOpaque()) { context, request in
          guard let context, let request else { return nil }
          return Unmanaged<OwlStorageHost>.fromOpaque(context).takeUnretainedValue().respond(request)
        }
    }
    guard let response else { throw OwlAppCore.Failure(code: "missing_response") }
    defer { owl_app_string_free(response) }
    let decoded = try decoder.decode(OwlAppCoreResponse<Value>.self, from: Data(bytes: response, count: strlen(response)))
    guard decoded.isOK, let value = decoded.value else {
      let code = decoded.error ?? "invalid_response"
      if let error = errors[code] { throw error }
      if code.hasPrefix("never_touch:") { throw OwlConfigWriteError.refusedNeverTouch(String(code.dropFirst(12))) }
      if code.hasPrefix("unmanaged:") { throw OwlConfigWriteError.refusedUnmanagedFile(String(code.dropFirst(10))) }
      if (code.hasPrefix("resource:") || code.hasPrefix("user_stage:") || code.hasPrefix("user_import:")) { throw OwlAppCore.Failure(code: code) }
      throw Self.failure(code)
    }

    return value
  }
  static func failure(_ code: String) -> Error {
    let fixed: [String: Error] = [
      "legacy_requires_migration": OwlTemplateError.legacyRequiresMigration,
      "changed_on_disk": OwlTemplateError.changedOnDisk,
      "recovery_failed": OwlTemplateError.recoveryFailed,
      "migration_invalidJournal": OwlTemplateMigration.Failure.invalidJournal,
      "migration_changed": OwlTemplateMigration.Failure.changed,
      "migration_recovery": OwlTemplateMigration.Failure.recovery,
      "migration_issues": OwlTemplateMigration.Failure.issues,
      "migration_conflict": OwlTemplateMigration.Failure.conflict,
      "migration_alreadyUnified": OwlTemplateMigration.Failure.alreadyUnified,
      "automatic_invalid": OwlAutomaticExpansionIndex.ValidationError.invalidTrigger,
      "automatic_duplicate": OwlAutomaticExpansionIndex.ValidationError.duplicateTrigger,
      "automatic_prefix": OwlAutomaticExpansionIndex.ValidationError.immediatePrefixConflict,
      "quick_text": OwlQuickSendError.invalidText,
      "quick_code": OwlQuickSendError.invalidCode,
      "prompt_title": OwlPromptError.invalidTitle,
      "prompt_body": OwlPromptError.invalidBody,
      "prompt_code": OwlPromptError.invalidCode,
      "invalid_patch": OwlConfigWriteError.fileHasNoPatchAndCannotCreate
    ]
    if let failure = fixed[code] { return failure }
    if code.hasPrefix("prompt_duplicate:") { return OwlPromptError.duplicateCode(String(code.dropFirst(17))) }
    if code.hasPrefix("automatic_template:") { return OwlAutomaticExpansionIndex.ValidationError.invalidTemplate(String(code.dropFirst(19))) }
    return OwlTemplateError.invalid(code)
  }

}

/// Owned Rust state; used only on the native owner thread, never across callbacks concurrently.
final class OwlAppSession {
  private let handle: OpaquePointer
  init(_ kind: String, args: Any = NSNull()) throws {
    let bytes = try JSONSerialization.data(withJSONObject: ["kind": kind, "args": args])
    var response: UnsafeMutablePointer<CChar>?
    let pointer = bytes.withUnsafeBytes { owl_app_session_new(OwlAppCore.abiVersion, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &response) }
    defer { owl_app_string_free(response) }
    guard let pointer else {
      let failure = response.flatMap { try? JSONDecoder().decode(OwlAppCoreResponse<Bool>.self, from: Data(bytes: $0, count: strlen($0))) }
      throw OwlAppCore.Failure(code: failure?.error ?? "invalid_session")
    }
    handle = pointer
  }
  deinit { owl_app_session_free(handle) }
  func call<T: Decodable>(_ event: String, _ args: [String: Any] = [:], index: OwlAppSession? = nil) -> T {
    do { return try request(event, args, index: index) }
    catch { preconditionFailure("Incompatible Owltype session ABI") }
  }
  func request<T: Decodable>(_ event: String, _ args: [String: Any] = [:], index: OwlAppSession? = nil) throws -> T {
      let bytes = try JSONSerialization.data(withJSONObject: ["event": event, "args": args])
      let response = bytes.withUnsafeBytes { owl_app_session_call(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, index?.handle) }
      guard let response else { throw OwlAppCore.Failure(code: "missing_response") }
      defer { owl_app_string_free(response) }
      let decoded = try JSONDecoder().decode(OwlAppCoreResponse<T>.self, from: Data(bytes: response, count: strlen(response)))
      guard decoded.isOK, let value = decoded.value else { throw OwlAppCore.Failure(code: decoded.error ?? "invalid_response") }
      return value
  }
}
