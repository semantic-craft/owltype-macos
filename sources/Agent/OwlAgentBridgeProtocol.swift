//
//  OwlAgentBridgeProtocol.swift
//  Owltype
//
//  The Owl Agent Bridge messages (rust/shared/contracts/agent-bridge): JSON-RPC 2.0, one JSON
//  object per line, between owltype-mcp and OwlAgentBridge. owl-agent-mcp's `bridge` module has
//  the same types; both decode the contract samples.
//
//  `decodeStrict` re-encodes what it decoded and requires the same JSON back, so an unknown field
//  (one that might carry input text) is an error rather than silently dropped.
//

import Foundation

enum OwlAgentBridgeProtocol {
  static let protocolVersion = 1
  static let contractVersion = 1
  static let maxLineBytes = 1 << 20
  static let maxDeliverCharacters = 20_000
  static let defaultDeliverTimeoutMs = 120_000
  static let deliverTimeoutRangeMs = 5_000...600_000

  enum ContractError: Error, Equatable {
    case notJSON
    case unknownFields
    case unsupportedJSONRPC
    case unknownMethod(String)
    case invalidParams(String)
  }

  enum Method: String, CaseIterable, Sendable {
    case hello
    case owltypeStatus = "owltype_status"
    case templatesList = "templates_list"
    case templateGet = "template_get"
    case templateRender = "template_render"
    case deliverText = "deliver_text"
  }

  enum RequestID: Codable, Hashable, Sendable {
    case number(UInt64)
    case text(String)

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let number = try? container.decode(UInt64.self) { self = .number(number) } else { self = .text(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .number(let number): try container.encode(number)
      case .text(let text): try container.encode(text)
      }
    }
  }

  struct Request: Codable, Equatable, Sendable {
    var jsonrpc = "2.0"
    var id: RequestID
    var method: String
    var params: OwlJSONValue?

    init(id: RequestID, call: Call) {
      self.id = id
      method = call.method.rawValue
      switch call {
      case .hello(let params): self.params = OwlJSONValue(encoding: params)
      case .owltypeStatus, .templatesList: self.params = nil
      case .templateGet(let params): self.params = OwlJSONValue(encoding: params)
      case .templateRender(let params): self.params = OwlJSONValue(encoding: params)
      case .deliverText(let params): self.params = OwlJSONValue(encoding: params)
      }
    }

    func call() throws -> Call {
      guard jsonrpc == "2.0" else { throw ContractError.unsupportedJSONRPC }
      guard let method = Method(rawValue: method) else { throw ContractError.unknownMethod(self.method) }
      func required<T: Codable>(_ type: T.Type) throws -> T {
        guard let params else { throw ContractError.invalidParams("params") }
        do { return try OwlAgentBridgeProtocol.decodeStrict(type, from: params) } catch { throw ContractError.invalidParams("params") }
      }
      switch method {
      case .hello: return .hello(try required(HelloParams.self))
      case .owltypeStatus, .templatesList:
        if let params, params != .object([:]) { throw ContractError.invalidParams("params") }
        return method == .owltypeStatus ? .owltypeStatus : .templatesList
      case .templateGet: return .templateGet(try required(TemplateRef.self))
      case .templateRender: return .templateRender(try required(RenderParams.self))
      case .deliverText:
        let params = try required(DeliverParams.self)
        if let field = params.invalidField { throw ContractError.invalidParams(field) }
        return .deliverText(params)
      }
    }
  }

  enum Call: Equatable, Sendable {
    case hello(HelloParams)
    case owltypeStatus
    case templatesList
    case templateGet(TemplateRef)
    case templateRender(RenderParams)
    case deliverText(DeliverParams)

    var method: Method {
      switch self {
      case .hello: return .hello
      case .owltypeStatus: return .owltypeStatus
      case .templatesList: return .templatesList
      case .templateGet: return .templateGet
      case .templateRender: return .templateRender
      case .deliverText: return .deliverText
      }
    }
  }

  struct Component: Codable, Equatable, Sendable {
    var name: String
    var version: String
  }

  struct HelloParams: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var helper: Component
    var agentClient: Component?
  }

  struct AppBuild: Codable, Equatable, Sendable {
    var version: String
    var build: String
  }

  struct HelloResult: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var app: AppBuild
  }

  /// Redacted App state. It never carries composing, committed, clipboard or host text.
  enum InputMode: String, Codable, Sendable { case chinese, english }

  struct InputSchema: Codable, Equatable, Sendable {
    var id: String
    var name: String
  }

  struct Status: Codable, Equatable, Sendable {
    var appVersion: String
    var appBuild: String
    var resourceGeneration: String
    var inputSchema: InputSchema
    var inputMode: InputMode
    var exposedTemplateCount: Int
  }

  struct Parameter: Codable, Equatable, Sendable {
    var key: String
    var name: String
    var isRequired: Bool
    var defaultValue: String?
    var options: [String]
  }

  enum Requirement: String, Codable, Sendable { case clipboard, date }

  struct TemplateSummary: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var parameters: [Parameter]
    var requirements: [Requirement]
  }

  struct TemplateList: Codable, Equatable, Sendable { var templates: [TemplateSummary] }

  struct TemplateRef: Codable, Equatable, Sendable { var id: String }

  struct Template: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var parameters: [Parameter]
    var requirements: [Requirement]
  }

  struct TemplateDetail: Codable, Equatable, Sendable { var template: Template }

  struct RenderParams: Codable, Equatable, Sendable {
    var id: String
    var arguments: [String: String]?
  }

  /// A preview only; nothing is written to any field. `cursorOffset` counts UTF-16 code units.
  enum Severity: String, Codable, Sendable { case warning, error }

  struct Diagnostic: Codable, Equatable, Sendable {
    var severity: Severity
    var message: String
  }

  struct Render: Codable, Equatable, Sendable {
    var previewText: String
    var cursorOffset: Int?
    var missingKeys: [String]
    var diagnostics: [Diagnostic]
  }

  /// `requestId` is the caller's idempotency key: resubmitting it, also after a reconnect, never
  /// writes twice.
  struct DeliverParams: Codable, Equatable, Sendable {
    var requestId: String
    var text: String
    var timeoutMs: Int?

    var invalidField: String? {
      let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:".utf8)
      if !(1...128).contains(requestId.utf8.count) || !requestId.utf8.allSatisfy(allowed.contains) { return "requestId" }
      if text.isEmpty || text.unicodeScalars.count > OwlAgentBridgeProtocol.maxDeliverCharacters { return "text" }
      if let timeoutMs, !OwlAgentBridgeProtocol.deliverTimeoutRangeMs.contains(timeoutMs) { return "timeoutMs" }
      return nil
    }

    var effectiveTimeoutMs: Int { timeoutMs ?? OwlAgentBridgeProtocol.defaultDeliverTimeoutMs }
  }

  enum TargetChangedReason: String, Codable, CaseIterable, Sendable {
    case focusChanged = "focus_changed"
    case targetQuit = "target_quit"
    case secureInput = "secure_input"
    case noTarget = "no_target"
    case unverifiableTarget = "unverifiable_target"
  }

  /// The closed set of `deliver_text` outcomes.
  enum DeliverStatus: Equatable, Sendable {
    case delivered(verified: Bool)
    case cancelled
    case targetChanged(TargetChangedReason)
    case expired

    static let names = ["delivered", "cancelled", "target_changed", "expired"]

    var name: String {
      switch self {
      case .delivered: return "delivered"
      case .cancelled: return "cancelled"
      case .targetChanged: return "target_changed"
      case .expired: return "expired"
      }
    }
  }

  struct DeliverResult: Codable, Equatable, Sendable {
    // swiftlint:disable:next nesting
    private enum CodingKeys: String, CodingKey { case requestId, status, verified, reason, replayed }
    var requestId: String
    var status: DeliverStatus
    var replayed: Bool

    init(requestId: String, status: DeliverStatus, replayed: Bool) {
      self.requestId = requestId
      self.status = status
      self.replayed = replayed
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      requestId = try container.decode(String.self, forKey: .requestId)
      replayed = try container.decode(Bool.self, forKey: .replayed)
      switch try container.decode(String.self, forKey: .status) {
      case "delivered": status = .delivered(verified: try container.decode(Bool.self, forKey: .verified))
      case "cancelled": status = .cancelled
      case "target_changed": status = .targetChanged(try container.decode(TargetChangedReason.self, forKey: .reason))
      case "expired": status = .expired
      case let other:
        throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "unknown status \(other)")
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(requestId, forKey: .requestId)
      try container.encode(status.name, forKey: .status)
      switch status {
      case .delivered(let verified): try container.encode(verified, forKey: .verified)
      case .targetChanged(let reason): try container.encode(reason, forKey: .reason)
      case .cancelled, .expired: break
      }
      try container.encode(replayed, forKey: .replayed)
    }
  }

  enum ErrorCode: Int, Codable, CaseIterable, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    case unsupportedProtocolVersion = -32001
    case helloRequired = -32002
    case agentAccessDisabled = -32003
    case templateNotFound = -32004
    case deliveryBusy = -32005

    var name: String {
      switch self {
      case .parseError: return "parse_error"
      case .invalidRequest: return "invalid_request"
      case .methodNotFound: return "method_not_found"
      case .invalidParams: return "invalid_params"
      case .internalError: return "internal_error"
      case .unsupportedProtocolVersion: return "unsupported_protocol_version"
      case .helloRequired: return "hello_required"
      case .agentAccessDisabled: return "agent_access_disabled"
      case .templateNotFound: return "template_not_found"
      case .deliveryBusy: return "delivery_busy"
      }
    }
  }

  struct ErrorData: Codable, Equatable, Sendable {
    var field: String?
    var supportedProtocolVersions: [Int]?
  }

  struct ErrorObject: Codable, Equatable, Sendable {
    var code: ErrorCode
    var message: String
    var data: ErrorData?
  }

  struct Success: Codable, Equatable, Sendable {
    var jsonrpc = "2.0"
    var id: RequestID
    var result: OwlJSONValue
  }

  struct Failure: Codable, Equatable, Sendable {
    // swiftlint:disable:next nesting
    private enum CodingKeys: String, CodingKey { case jsonrpc, id, error }
    var jsonrpc = "2.0"
    var id: RequestID?
    var error: ErrorObject

    init(id: RequestID?, error: ErrorObject) {
      self.id = id
      self.error = error
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
      id = try container.decodeIfPresent(RequestID.self, forKey: .id)
      error = try container.decode(ErrorObject.self, forKey: .error)
    }

    /// JSON-RPC requires `id`, as null when the request's id could not be read.
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(jsonrpc, forKey: .jsonrpc)
      if let id { try container.encode(id, forKey: .id) } else { try container.encodeNil(forKey: .id) }
      try container.encode(error, forKey: .error)
    }
  }

  enum Response: Equatable, Sendable {
    case success(Success)
    case failure(Failure)

    static func decode(_ value: OwlJSONValue) throws -> Response {
      guard case .object(let object) = value else { throw ContractError.notJSON }
      let response: Response = object["error"] != nil
        ? .failure(try decodeStrict(Failure.self, from: value))
        : .success(try decodeStrict(Success.self, from: value))
      switch response {
      case .success(let success) where success.jsonrpc != "2.0": throw ContractError.unsupportedJSONRPC
      case .failure(let failure) where failure.jsonrpc != "2.0": throw ContractError.unsupportedJSONRPC
      default: return response
      }
    }

    var value: OwlJSONValue {
      switch self {
      case .success(let success): return OwlJSONValue(encoding: success)
      case .failure(let failure): return OwlJSONValue(encoding: failure)
      }
    }
  }

  /// The typed result of `method`.
  static func decodeResult(_ method: Method, _ value: OwlJSONValue) throws -> any Codable {
    switch method {
    case .hello: return try decodeStrict(HelloResult.self, from: value)
    case .owltypeStatus: return try decodeStrict(Status.self, from: value)
    case .templatesList: return try decodeStrict(TemplateList.self, from: value)
    case .templateGet: return try decodeStrict(TemplateDetail.self, from: value)
    case .templateRender: return try decodeStrict(Render.self, from: value)
    case .deliverText: return try decodeStrict(DeliverResult.self, from: value)
    }
  }

  static func decodeStrict<T: Codable>(_ type: T.Type, from value: OwlJSONValue) throws -> T {
    let decoded = try JSONDecoder().decode(T.self, from: value.data)
    guard OwlJSONValue(encoding: decoded) == value else { throw ContractError.unknownFields }
    return decoded
  }

  static func decodeStrict<T: Codable>(_ type: T.Type, from line: Data) throws -> T {
    guard let value = try? JSONDecoder().decode(OwlJSONValue.self, from: line) else { throw ContractError.notJSON }
    return try decodeStrict(type, from: value)
  }
}

/// Any JSON value, compared structurally. Numbers are compared as Double.
enum OwlJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([OwlJSONValue])
  case object([String: OwlJSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([OwlJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: OwlJSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value):
      if value.rounded() == value, abs(value) < 9.0e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  /// Encodes a bridge type; bridge types always encode.
  init<T: Encodable>(encoding value: T) {
    let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
    self = (try? JSONDecoder().decode(OwlJSONValue.self, from: data)) ?? .null
  }

  /// One line of the wire format: compact JSON, no trailing newline.
  var data: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)) ?? Data("null".utf8)
  }

  subscript(key: String) -> OwlJSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }
}
