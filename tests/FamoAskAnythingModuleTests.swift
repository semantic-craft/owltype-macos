//
//  FamoAskAnythingModuleTests.swift
//  FamoTests — 任意提问用例 seam（issue #107）
//
//  The module is driven through an in-memory transport. These tests intentionally know nothing
//  about provider priority tables or Responses dialects: the seam accepts messages and returns a
//  streamed answer plus attribution, while the adapter records only plain vs built-in-search use.
//

import Foundation
import XCTest
@testable import Famo

@MainActor
final class FamoAskAnythingModuleTests: XCTestCase {

  func testConfiguredQwenSearchStreamsThroughTheSeamAndKeepsAttribution() async throws {
    let transport = InMemoryAskTransport(
      builtInStream: Self.stream(deltas: ["本院", "认为"]))
    let module = makeModule(searchEnabled: true, transport: transport)

    guard case let .success(open) = module.open(
      messages: [FamoDeepSeekMessage(role: "user", content: "今天有什么新规？")]) else {
      return XCTFail("configured Qwen search should open")
    }

    XCTAssertEqual(open.searchProviderID, "qwen")
    XCTAssertEqual(transport.calls, [.builtInSearch(providerID: "qwen")])
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["本院", "认为"])
    XCTAssertEqual(open.searchProviderID, "qwen", "stream completion must keep the actual signer")
  }

  func testSearchOffUsesPlainAnswerWithoutSearchAttribution() async throws {
    let transport = InMemoryAskTransport(plainStream: Self.stream(deltas: ["普通回答"]))
    let module = makeModule(searchEnabled: false, transport: transport)

    guard case let .success(open) = module.open(
      messages: [FamoDeepSeekMessage(role: "user", content: "解释一下")]) else {
      return XCTFail("plain ask should still open")
    }

    XCTAssertNil(open.searchProviderID)
    XCTAssertEqual(transport.calls, [.plain(providerID: "qwen")])
    let deltas = try await collect(open.stream)
    XCTAssertEqual(deltas, ["普通回答"])
  }

  func testMissingConfigurationReturnsReadinessWithoutOpeningATransport() {
    let transport = InMemoryAskTransport()
    let gate = FamoProviderAuthGate(
      profileProvider: { nil },
      profileSecretProvider: { _ in XCTFail("no profile means no profile secret read"); return nil },
      legacyKeyProvider: { nil })
    let resolver = FamoAskSearchResolver(
      isEnabled: { true }, profilesProvider: { [] }, defaultProfileProvider: { nil },
      preferredProviderID: { nil }, secretProvider: { _ in nil })
    let module = FamoAskAnythingModule(
      gate: gate,
      transport: transport,
      searchResolver: resolver,
      isWebSearchEnabled: { true },
      webSearchProvider: { nil },
      webSearchKeyProvider: { _ in nil })

    guard case let .failure(readiness) = module.open(messages: []) else {
      return XCTFail("missing configuration must not open a stream")
    }
    XCTAssertEqual(readiness, .unconfigured)
    XCTAssertTrue(transport.calls.isEmpty, "readiness failures must have zero network side effects")
  }

  func testRequestErrorDoesNotOpenFallbackOrAnotherTransport() async {
    let transport = InMemoryAskTransport(
      builtInStream: Self.failingStream(URLError(.notConnectedToInternet)),
      plainStream: Self.stream(deltas: ["不应出现"]))
    let module = makeModule(searchEnabled: true, transport: transport)

    guard case let .success(open) = module.open(messages: []) else {
      return XCTFail("transport failures surface from the opened stream")
    }
    do {
      _ = try await collect(open.stream)
      XCTFail("the transport error should surface")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
    }
    XCTAssertEqual(
      transport.calls, [.builtInSearch(providerID: "qwen")],
      "a real request error must not fan out into fallback requests")
  }

  func testCancellationStopsTheActiveAdapterWithoutOpeningFallback() async {
    let innerCancelled = expectation(description: "active in-memory adapter cancelled")
    let consumerStarted = expectation(description: "consumer is waiting on the active adapter")
    let inner = AsyncThrowingStream<String, Error> { continuation in
      continuation.yield("第一段")
      continuation.onTermination = { _ in innerCancelled.fulfill() }
    }
    let transport = InMemoryAskTransport(
      builtInStream: inner,
      plainStream: Self.stream(deltas: ["不应出现"]))
    let module = makeModule(searchEnabled: true, transport: transport)

    guard case let .success(open) = module.open(messages: []) else {
      return XCTFail("configured Qwen search should open")
    }
    let consumer = Task {
      var iterator = open.stream.makeAsyncIterator()
      let first = try await iterator.next()
      XCTAssertEqual(first, "第一段")
      consumerStarted.fulfill()
      return try await iterator.next()
    }
    await fulfillment(of: [consumerStarted], timeout: 1)
    consumer.cancel()
    _ = try? await consumer.value
    await fulfillment(of: [innerCancelled], timeout: 1)

    XCTAssertEqual(
      transport.calls, [.builtInSearch(providerID: "qwen")],
      "cancellation must not open a retry or plain fallback")
  }

  private func makeModule(
    searchEnabled: Bool,
    transport: InMemoryAskTransport
  ) -> FamoAskAnythingModule {
    let profile = Self.qwenProfile
    let gate = FamoProviderAuthGate(
      profileProvider: { profile },
      profileSecretProvider: { _ in "sk-qwen" },
      legacyKeyProvider: { nil })
    let resolver = FamoAskSearchResolver(
      isEnabled: { searchEnabled },
      profilesProvider: { [profile] },
      defaultProfileProvider: { profile },
      preferredProviderID: { nil },
      secretProvider: { _ in "sk-qwen" })
    return FamoAskAnythingModule(
      gate: gate,
      transport: transport,
      searchResolver: resolver,
      isWebSearchEnabled: { searchEnabled },
      webSearchProvider: { nil },
      webSearchKeyProvider: { _ in nil })
  }

  private static var qwenProfile: FamoProviderProfile {
    FamoProviderProfile(
      id: "qwen",
      displayName: "通义千问",
      endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")!,
      model: "qwen3.7-plus",
      providerID: "qwen",
      secretName: "famo.provider.qwen.apiKey",
      isDefault: true)
  }

  private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var output: [String] = []
    for try await delta in stream { output.append(delta) }
    return output
  }

  private static func stream(deltas: [String]) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      for delta in deltas { continuation.yield(delta) }
      continuation.finish()
    }
  }

  private static func failingStream(_ error: Error) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish(throwing: error) }
  }
}

@MainActor
private final class InMemoryAskTransport: FamoAskAnythingTransporting {
  enum Call: Equatable {
    case plain(providerID: String)
    case builtInSearch(providerID: String)
  }

  private(set) var calls: [Call] = []
  private let plainStream: AsyncThrowingStream<String, Error>
  private let builtInStream: AsyncThrowingStream<String, Error>?

  init(
    builtInStream: AsyncThrowingStream<String, Error>? = nil,
    plainStream: AsyncThrowingStream<String, Error> = AsyncThrowingStream { $0.finish() }
  ) {
    self.builtInStream = builtInStream
    self.plainStream = plainStream
  }

  func streamPlain(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error> {
    calls.append(.plain(providerID: routing.providerID))
    return plainStream
  }

  func streamBuiltInSearch(
    messages: [FamoDeepSeekMessage],
    routing: FamoCloudRouting,
    apiKey: String
  ) -> AsyncThrowingStream<String, Error>? {
    calls.append(.builtInSearch(providerID: routing.providerID))
    return builtInStream
  }
}
