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
