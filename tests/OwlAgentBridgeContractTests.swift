//
//  OwlAgentBridgeContractTests.swift
//  OwltypeTests
//
//  The Swift side of the agent-bridge contract: every sample in
//  rust/shared/contracts/agent-bridge/samples decodes and encodes back to the same JSON, every
//  sample in samples/invalid is rejected. owl-agent-mcp's contract_samples test runs the same files.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlAgentBridgeContractTests: XCTestCase {
  private typealias Bridge = OwlAgentBridgeProtocol

  private let contract = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("rust/shared/contracts/agent-bridge", isDirectory: true)

  private func samples(_ directory: String) throws -> [(String, OwlJSONValue)] {
    let folder = contract.appendingPathComponent(directory, isDirectory: true)
    return try FileManager.default.contentsOfDirectory(atPath: folder.path)
      .filter { $0.hasSuffix(".json") }
      .sorted()
      .map { name in
        let data = try Data(contentsOf: folder.appendingPathComponent(name))
        return (name, try JSONDecoder().decode(OwlJSONValue.self, from: data))
      }
  }

  private enum SampleError: Error {
    case badSample
  }

  private func decodeResponse(_ value: OwlJSONValue) throws -> Bridge.Response {
    guard case .object(let object) = value else { throw SampleError.badSample }
    let response: Bridge.Response = object["error"] != nil
      ? .failure(try Bridge.decodeStrict(Bridge.Failure.self, from: value))
      : .success(try Bridge.decodeStrict(Bridge.Success.self, from: value))
    switch response {
    case .success(let success) where success.jsonrpc != "2.0": throw Bridge.ContractError.unsupportedJSONRPC
    case .failure(let failure) where failure.jsonrpc != "2.0": throw Bridge.ContractError.unsupportedJSONRPC
    default: return response
    }
  }

  private func encodeRequest(id: Bridge.RequestID, call: Bridge.Call) -> Bridge.Request {
    let params: OwlJSONValue? = switch call {
    case .hello(let value): OwlJSONValue(encoding: value)
    case .owltypeStatus, .templatesList: nil
    case .templateGet(let value): OwlJSONValue(encoding: value)
    case .templateRender(let value): OwlJSONValue(encoding: value)
    case .deliverText(let value): OwlJSONValue(encoding: value)
    }
    return Bridge.Request(id: id, method: call.method.rawValue, params: params)
  }

  private func decodeResult(_ method: Bridge.Method, _ value: OwlJSONValue) throws -> any Codable {
    switch method {
    case .hello: return try Bridge.decodeStrict(Bridge.HelloResult.self, from: value)
    case .owltypeStatus: return try Bridge.decodeStrict(Bridge.Status.self, from: value)
    case .templatesList: return try Bridge.decodeStrict(Bridge.TemplateList.self, from: value)
    case .templateGet: return try Bridge.decodeStrict(Bridge.TemplateDetail.self, from: value)
    case .templateRender: return try Bridge.decodeStrict(Bridge.Render.self, from: value)
    case .deliverText: return try Bridge.decodeStrict(Bridge.DeliverResult.self, from: value)
    }
  }

  /// `<method>.request[.variant].json`, `<method>.response[.variant].json` or `error.<code>.json`.
  private func encodedBack(_ name: String, _ value: OwlJSONValue) throws -> OwlJSONValue {
    let parts = name.replacingOccurrences(of: ".json", with: "").split(separator: ".").map(String.init)
    if parts[0] == "error" {
      guard case .failure(let failure) = try decodeResponse(value) else { throw SampleError.badSample }
      XCTAssertEqual(parts[1], failure.error.code.name, name)
      return OwlJSONValue(encoding: failure)
    }
    guard let method = Bridge.Method(rawValue: parts[0]) else { throw Bridge.ContractError.unknownMethod(parts[0]) }
    switch parts[1] {
    case "request":
      let request = try Bridge.decodeStrict(Bridge.Request.self, from: value)
      let call = try request.call()
      XCTAssertEqual(call.method, method, name)
      return OwlJSONValue(encoding: encodeRequest(id: request.id, call: call))
    case "response":
      guard case .success(var success) = try decodeResponse(value) else { throw SampleError.badSample }
      success.result = OwlJSONValue(encoding: try decodeResult(method, success.result))
      return OwlJSONValue(encoding: success)
    default:
      throw SampleError.badSample
    }
  }

  func testValidSamplesRoundTrip() throws {
    let all = try samples("samples")
    XCTAssertGreaterThanOrEqual(all.count, 30)
    for (name, value) in all {
      XCTAssertEqual(try encodedBack(name, value), value, name)
    }
  }

  func testInvalidSamplesAreRejected() throws {
    let all = try samples("samples/invalid")
    XCTAssertFalse(all.isEmpty)
    for (name, value) in all {
      XCTAssertThrowsError(try encodedBack(name, value), name)
    }
  }

  func testSchemaListsMatchTheTypes() throws {
    let schema = try JSONDecoder().decode(OwlJSONValue.self, from: Data(contentsOf: contract.appendingPathComponent("bridge.schema.json")))
    XCTAssertEqual(schema["contractVersion"], .number(1))
    XCTAssertEqual(schema["protocolVersion"], .number(Double(Bridge.protocolVersion)))
    XCTAssertEqual(schema["methods"], .array(Bridge.Method.allCases.map { .string($0.rawValue) }))
    guard case .object(let codes) = schema["errorCodes"] else { return XCTFail("errorCodes") }
    XCTAssertEqual(codes, Dictionary(uniqueKeysWithValues: Bridge.ErrorCode.allCases.map { ($0.name, .number(Double($0.rawValue))) }))
    XCTAssertEqual(schema["deliverStatuses"], .array(["delivered", "cancelled", "target_changed", "expired"].map { .string($0) }))
    XCTAssertEqual(schema["targetChangedReasons"], .array(Bridge.TargetChangedReason.allCases.map { .string($0.rawValue) }))
    let deliver = schema["$defs"]?["deliverParams"]?["properties"]
    XCTAssertEqual(deliver?["text"]?["maxLength"], .number(20_000))
    XCTAssertEqual(deliver?["timeoutMs"]?["minimum"], .number(5_000))
    XCTAssertEqual(deliver?["timeoutMs"]?["maximum"], .number(600_000))
    XCTAssertEqual(deliver?["timeoutMs"]?["default"], .number(120_000))
  }

  func testUnknownFieldInParamsIsInvalidParams() throws {
    let line = Data(#"{"jsonrpc":"2.0","id":1,"method":"deliver_text","params":{"requestId":"a","text":"x","target":"Notes"}}"#.utf8)
    let value = try JSONDecoder().decode(OwlJSONValue.self, from: line)
    let request = try Bridge.decodeStrict(Bridge.Request.self, from: value)
    XCTAssertThrowsError(try request.call()) { XCTAssertEqual($0 as? Bridge.ContractError, .invalidParams("params")) }
  }
}
