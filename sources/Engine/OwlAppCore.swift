import Foundation

private protocol NilRepresentable {
  static var nilValue: Self { get }
}
extension Optional: NilRepresentable {
  static var nilValue: Self { nil }
}

private struct OwlAppCoreResponse<Value: Decodable>: Decodable {
  enum CodingKeys: String, CodingKey { case isOK = "ok", value, error, committed }
  let isOK: Bool
  let value: Value?
  let error: String?
  let committed: Bool?
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
    defer { owl_msime_string_free(response) }
    let data = Data(bytes: response, count: strlen(response))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(OwlAppCoreResponse<Value>.self, from: data)
    if decoded.isOK {
      if let value = decoded.value {
        return value
      }
      if let nilType = Value.self as? NilRepresentable.Type {
        return nilType.nilValue as! Value
      }
    }
    let code = decoded.error ?? "invalid_response"
    let failure = OwlStorageHost.failure(code)
    if case OwlTemplateError.invalid(let msg) = failure, msg == code {
      throw Failure(code: code)
    }
    throw failure
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
    let switches: [KeyboardSwitch]
    let fuzzy: [FuzzySwitch]
    let schemas: [SchemaConfiguration]
    let doublePinyinSchemas: [String: String]
    let wubiSchemas: [String: String]
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

/// Rust-native storage adapter. Standard storage operations execute directly in Rust via
/// `FilesystemHost` guarded by `msime-path-trust` without re-entrant C callbacks.
final class OwlStorageHost {
  private struct ItemsReply: Decodable { let removedItems: [String]? }
  let dataDir: URL
  let checkpoint: (String) throws -> Void
  var errors: [String: Error] = [:]
  init(dataDir: URL, checkpoint: @escaping (String) throws -> Void = { _ in }) {
    self.dataDir = dataDir
    self.checkpoint = checkpoint
  }
  private static let lock = NSRecursiveLock()
  static func exclusively<T>(_ action: () throws -> T) rethrows -> T {
    lock.lock(); defer { lock.unlock() }; return try action()
  }
  func call<Value: Decodable>(_ operation: String, _ args: [String: Any] = [:], decoder: JSONDecoder = JSONDecoder()) throws -> Value {
    try Self.exclusively {
      var failCheckpoint: String?
      if ["library_save", "library_delete", "import_commit"].contains(operation) {
        do { try checkpoint(OwlTemplateStore.fileName) }
        catch {
          failCheckpoint = OwlTemplateStore.fileName
          errors["checkpoint_failed"] = error
        }
      } else if operation == "user_reset" {
        let items = (try? OwlStorageHost(dataDir: dataDir).call("user_reset_items", [:]) as ItemsReply)?.removedItems ?? []
        for item in items {
          do { try checkpoint(item) }
          catch {
            failCheckpoint = item
            errors["checkpoint_failed"] = error
            break
          }
        }
      }
      var payload: [String: Any] = [
        "operation": "storage",
        "data_dir": dataDir.path,
        "storage_op": operation,
        "args": args,
      ]
      if let failCheckpoint { payload["fail_checkpoint"] = failCheckpoint }
      let bytes = try JSONSerialization.data(withJSONObject: payload)
      let response = bytes.withUnsafeBytes { buffer in
        owl_app_call(OwlAppCore.abiVersion, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
      }
      guard let response else { throw OwlAppCore.Failure(code: "missing_response") }
      defer { owl_msime_string_free(response) }
      let decoded = try decoder.decode(OwlAppCoreResponse<Value>.self, from: Data(bytes: response, count: strlen(response)))
      if decoded.committed == true {
        OwlTemplateStore.notifyCommittedLibrary(dataDir: dataDir)
      }
      if decoded.isOK {
        if let value = decoded.value {
          return value
        }
        if let nilType = Value.self as? NilRepresentable.Type {
          return nilType.nilValue as! Value
        }
      }
      let code = decoded.error ?? "invalid_response"
      if let error = errors[code] { throw error }
      throw Self.failure(code)
    }
  }
  static func failure(_ code: String) -> Error {
    let fixed: [String: Error] = [
      "changed_on_disk": OwlTemplateError.changedOnDisk,
      "automatic_invalid": OwlAutomaticExpansionIndex.ValidationError.invalidTrigger,
      "automatic_duplicate": OwlAutomaticExpansionIndex.ValidationError.duplicateTrigger,
      "automatic_prefix": OwlAutomaticExpansionIndex.ValidationError.immediatePrefixConflict
    ]
    if let failure = fixed[code] { return failure }
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
    defer { owl_msime_string_free(response) }
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
      defer { owl_msime_string_free(response) }
      let decoded = try JSONDecoder().decode(OwlAppCoreResponse<T>.self, from: Data(bytes: response, count: strlen(response)))
      if decoded.isOK {
        if let value = decoded.value {
          return value
        }
        if let nilType = T.self as? NilRepresentable.Type {
          return nilType.nilValue as! T
        }
      }
      throw OwlAppCore.Failure(code: decoded.error ?? "invalid_response")
  }
}
