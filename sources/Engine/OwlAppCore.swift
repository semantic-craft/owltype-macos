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
    let decoded = try JSONDecoder().decode(OwlAppCoreResponse<Value>.self, from: data)
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
    do { return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    catch { preconditionFailure("Invalid native App core payload") }
  }

  static let defaultKeyboard: EffectiveKeyboard = required(["operation": "keyboard_effective", "raw": [:]])

  static func required<Value: Decodable>(_ request: [String: Any]) -> Value {
    do { return try call(request) } catch { preconditionFailure("Incompatible Owltype App core ABI") }
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
