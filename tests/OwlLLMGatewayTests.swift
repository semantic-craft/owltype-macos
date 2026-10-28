//
//  OwlLLMGatewayTests.swift
//  OwltypeTests — LLM gateway: one table of provider requests, retry, cancellation, telemetry
//
//  Offline: every request goes through a recording transport. `recorded` was captured from the
//  pre-gateway clients (2026-10-28, revision 2a7b1d0) through a URLProtocol stub, so a refactor
//  that changes any provider's URL, timeout, headers or body breaks here first.
//

import CryptoKit
import XCTest
@testable import Owltype

/// Closure-backed transport for tests that need one canned reply or a thrown error.
struct OwlStubTransport: OwlLLMTransport {
  let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
    self.handler = handler
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await handler(request)
  }
}

/// Records every request, then answers with `handler`.
final class OwlRecordingTransport: OwlLLMTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  private let handler: (URLRequest) async throws -> (Data, URLResponse)

  init(_ handler: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
    self.handler = handler
  }

  /// Answers every request with `data` and `status`.
  static func replying(_ data: Data, status: Int = 200) -> OwlRecordingTransport {
    OwlRecordingTransport { request in
      (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
  }

  var requests: [URLRequest] {
    lock.lock(); defer { lock.unlock() }
    return recorded
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    lock.lock(); recorded.append(request); lock.unlock()
    return try await handler(request)
  }
}

extension OwlStructuredDrafting {
  /// The production adapter over a fixed routing, as the live tests drive it.
  static func live(
    _ configuration: OwlStructuredDraftingConfiguration,
    routing: OwlCloudRouting,
    apiKey: String,
    gateway: OwlLLMGateway = OwlLLMGateway()
  ) -> OwlStructuredDrafting {
    OwlStructuredDrafting(
      configuration: configuration,
      cloudEnabled: { true },
      authorization: { .ready(routing: routing, apiKey: apiKey) },
      remote: OwlStructuredDraftingClient(gateway: gateway)
    )
  }
}

@MainActor
final class OwlLLMGatewayTests: XCTestCase {
  /// One reply both shells accept: Chat reads `choices`, Responses reads `output_text`.
  private static let bothShells = Data(
    #"{"choices":[{"message":{"content":"{\"candidates\":[\"x\"]}"}}],"output_text":"{\"candidates\":[\"x\"]}","model":"m"}"#
      .utf8)

  private static func routing(_ providerID: String, _ endpoint: String, _ model: String) -> OwlCloudRouting {
    OwlCloudRouting(
      providerID: providerID, endpoint: URL(string: endpoint)!, model: model,
      secretName: nil, authHeaderStyle: .bearer)
  }

  private static let matrix: [(String, String, String)] = [
    ("deepseek", "https://api.deepseek.com/chat/completions", "deepseek-chat"),
    ("deepseek", "https://api.deepseek.com/chat/completions", "deepseek-flash"),
    ("qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen3.7-plus"),
    ("doubao", "https://ark.cn-beijing.volces.com/api/v3/chat/completions", "doubao-seed-1.6"),
    ("openai", "https://api.openai.com/v1/chat/completions", "gpt-4o"),
    ("gemini", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "gemini-3.8-flash"),
    ("minimax", "https://api.minimax.io/v1/chat/completions", "MiniMax-M3"),
    ("minimax", "https://api.minimax.io/v1/chat/completions", "MiniMax-M3.1-Flash"),
    // An unstamped custom profile on 百炼 hosting a DeepSeek model: the host decides, 百炼 wins.
    ("", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "deepseek-v4-flash"),
  ]

  private static let recorded: [String: (url: String, timeout: Double, bodySHA256: String)] = [
    "polish|deepseek|deepseek-chat": ("https://api.deepseek.com/chat/completions", 8, "8079349496a71239be6c668650d00e72293d25a40c0435fff79d2f43130765e8"),
    "drafting|deepseek|deepseek-chat": ("https://api.deepseek.com/chat/completions", 60, "53b0a37a10184234282ba5d70ce959d59a43fd1c26fdef133631161a645b7ba7"),
    "probe|deepseek|deepseek-chat": ("https://api.deepseek.com/chat/completions", 20, "f7d7633d70a9bef76b8d96ffcadcedd3c5136fb18b3cc5ea668cdd37d40c2efd"),
    "polish|deepseek|deepseek-flash": ("https://api.deepseek.com/responses", 8, "a4995e4f14328eb98c6512684404a2b3586ad1a0bdb1dbafc30e14511a0b6948"),
    "drafting|deepseek|deepseek-flash": ("https://api.deepseek.com/responses", 60, "ac55cda51277ce71aaa4872319d8036936399eea8ee59ea2842ba8fa46cb4a63"),
    "probe|deepseek|deepseek-flash": ("https://api.deepseek.com/responses", 20, "784b296600dcae2aa72096308b6ea673ef69e1b64551cdca899c662cd45327bb"),
    "polish|qwen|qwen3.7-plus": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 8, "51732659db0a66644d72f260d68ae47c80d0788e064bb6e1409ea18a26daad67"),
    "drafting|qwen|qwen3.7-plus": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 60, "eb08b98404a6afd347e45ad7f51bb52907d712443934642dec4a0c6e000e65ff"),
    "probe|qwen|qwen3.7-plus": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 20, "0d0601bcbaf587f002ae11942a146596c7e854d11c21b951a8acc1b326f8ddbd"),
    "polish|doubao|doubao-seed-1.6": ("https://ark.cn-beijing.volces.com/api/v3/responses", 8, "fd01ca1846fe574f767085bd47ba40dc213ac4d93aa5857e6c0c1500e0c20da7"),
    "drafting|doubao|doubao-seed-1.6": ("https://ark.cn-beijing.volces.com/api/v3/responses", 60, "4595ce00a420597b7f6cfa8d7995c0371f0d0b12ec4ed61260d61281e72b6134"),
    "probe|doubao|doubao-seed-1.6": ("https://ark.cn-beijing.volces.com/api/v3/responses", 20, "21d1513e01998c266971269bd1c69102c33c58f0c4331dffd25f00f03f15158f"),
    "polish|openai|gpt-4o": ("https://api.openai.com/v1/chat/completions", 8, "80fa5eb6200ffdce478ad04a691f56c65257db8d5fdf076e925c4ab7c2b0650d"),
    "drafting|openai|gpt-4o": ("https://api.openai.com/v1/chat/completions", 60, "0923ebfb990429af637be76dd190ea9bfd043444d7235ad185a2d6bbac39e46d"),
    "probe|openai|gpt-4o": ("https://api.openai.com/v1/chat/completions", 20, "f0e6ed428ec4872ef1d3b2ffd31930d5fa4f1bb00286eae02322c22cc3b2c4ff"),
    "polish|gemini|gemini-3.8-flash": ("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", 8, "34165900efca36c26d52d6ec69d74ba7fc2c7d37ed0eeaf8f9906f953e84593a"),
    "drafting|gemini|gemini-3.8-flash": ("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", 60, "cd8988d94ed9a475210c8e58c9f6eddb2e7d6d4b965c9295299ab9ec9e51f4b4"),
    "probe|gemini|gemini-3.8-flash": ("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", 20, "ad6f4f7c09e86db681df5bffa071641b6a8b172fd22bf94d9ec69f05e9037853"),
    "polish|minimax|MiniMax-M3": ("https://api.minimax.io/v1/chat/completions", 8, "540e705034162a78357f05b7a23bfdc4d050ae70f89662f4d86790955ff629aa"),
    "drafting|minimax|MiniMax-M3": ("https://api.minimax.io/v1/chat/completions", 60, "21fc25920b0b221bc672d1d38aeb21e2aa11b425b8a88e555c63aad9ee02495e"),
    "probe|minimax|MiniMax-M3": ("https://api.minimax.io/v1/chat/completions", 20, "f5d86f0110a6372a737f5d854d93147a162a92d1223cd86428f37089b6c5ec96"),
    "polish|minimax|MiniMax-M3.1-Flash": ("https://api.minimax.io/v1/chat/completions", 8, "0e531562f26b9f2710b55cd80248a2384745ca575f2e9f10a7998c7b7b6cd6df"),
    "drafting|minimax|MiniMax-M3.1-Flash": ("https://api.minimax.io/v1/chat/completions", 60, "716c131c6fe493e8031e4a0a9713d00cc957f0cb066967647423fc17a7f74252"),
    "probe|minimax|MiniMax-M3.1-Flash": ("https://api.minimax.io/v1/chat/completions", 20, "d23f7a2cf10b07ea683d3fb2b571e0d855efcfca7e7771450b90a99928f5d0ef"),
    "polish||deepseek-v4-flash": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 8, "5e6241ed135444f3c8a5e47eb234e72bdadb5ef5b31e37ee35668454b3893020"),
    "drafting||deepseek-v4-flash": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 60, "77b5358f5c87fe8a109024b375e4aa48c1bdcf166124f691530aecd546e8a15e"),
    "probe||deepseek-v4-flash": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 20, "ee61d68bc0492547aef467806770a98310335abf3f16430f90ff8b19c0f3ba7a"),
  ]

  private var savedVariant: String?

  override func setUp() async throws {
    try await super.setUp()
    OwlCloudPreferences.resetForTesting()
    OwlCloudUsageTelemetry.resetForTesting()
    savedVariant = OwlExperimentalPreferences.selectionPolishPromptVariant
    OwlExperimentalPreferences.selectionPolishPromptVariant = OwlPolishPromptCatalog.legacyVariantID
  }

  override func tearDown() async throws {
    OwlExperimentalPreferences.selectionPolishPromptVariant = savedVariant
    OwlCloudPreferences.resetForTesting()
    OwlCloudUsageTelemetry.resetForTesting()
    try await super.tearDown()
  }

  private func assertMatchesRecording(_ request: URLRequest, _ key: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let expected = try XCTUnwrap(Self.recorded[key], "no recording for \(key)", file: file, line: line)
    XCTAssertEqual(request.url?.absoluteString, expected.url, key, file: file, line: line)
    XCTAssertEqual(request.timeoutInterval, expected.timeout, key, file: file, line: line)
    XCTAssertEqual(request.httpMethod, "POST", key, file: file, line: line)
    XCTAssertEqual(
      request.allHTTPHeaderFields,
      ["Authorization": "Bearer sk-test", "Content-Type": "application/json"], key, file: file, line: line)
    // Dictionary-built bodies have no stable key order, so compare the canonical (sorted) JSON.
    let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
    let canonical = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(digest, expected.bodySHA256, "\(key) body changed", file: file, line: line)
  }

  func testEveryProviderRequestMatchesTheRecordedPreGatewayRequest() async throws {
    for (providerID, endpoint, model) in Self.matrix {
      let routing = Self.routing(providerID, endpoint, model)
      let suffix = "\(providerID)|\(model)"

      let polish = OwlRecordingTransport.replying(Self.bothShells)
      _ = try await OwlSelectionPolishClient(routing: routing, gateway: OwlLLMGateway(transport: polish))
        .fetchPolishedRewrites(for: "他撤销了合同", apiKey: "sk-test")
      XCTAssertEqual(polish.requests.count, 1)
      try assertMatchesRecording(try XCTUnwrap(polish.requests.first), "polish|\(suffix)")

      let drafting = OwlRecordingTransport.replying(Self.bothShells)
      _ = try await OwlStructuredDrafting.live(
        OwlPromptOptimizer.structuredDraftingConfiguration, routing: routing, apiKey: "sk-test",
        gateway: OwlLLMGateway(transport: drafting)
      ).draft("帮我写个爬虫")
      XCTAssertEqual(drafting.requests.count, 1)
      try assertMatchesRecording(try XCTUnwrap(drafting.requests.first), "drafting|\(suffix)")

      let probe = OwlRecordingTransport.replying(Self.bothShells)
      _ = await OwlProviderConnectivityCheck.run(
        endpoint: routing.endpoint, providerID: providerID, model: model,
        apiKey: "sk-test", authStyle: .bearer, transport: probe)
      XCTAssertEqual(probe.requests.count, 1)
      try assertMatchesRecording(try XCTUnwrap(probe.requests.first), "probe|\(suffix)")
    }
  }

  func testPurposeFixesTimeoutAndRetry() {
    XCTAssertEqual(OwlLLMCallPurpose.interactiveRewrite.timeout, 8)
    XCTAssertEqual(OwlLLMCallPurpose.interactiveRewrite.maxAttempts, 2)
    XCTAssertEqual(OwlLLMCallPurpose.drafting.timeout, 60)
    XCTAssertEqual(OwlLLMCallPurpose.drafting.maxAttempts, 1)
    XCTAssertEqual(OwlLLMCallPurpose.connectivityProbe.timeout, 20)
    XCTAssertEqual(OwlLLMCallPurpose.connectivityProbe.maxAttempts, 1)
  }

  private func payload(_ routing: OwlCloudRouting, _ text: String = "他撤销了合同") throws -> OwlDeepSeekChatRequest {
    try OwlSelectionPolish.chatRequest(for: text, model: routing.model, providerID: routing.providerID)
  }

  func testInteractiveRewriteRetriesOneTransientServerError() async throws {
    let routing = Self.routing("openai", "https://api.openai.com/v1/chat/completions", "gpt-4o")
    var statuses = [503, 200]
    let flaky = OwlRecordingTransport { request in
      let status = statuses.removeFirst()
      return (Self.bothShells, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    let text = try await OwlLLMGateway(transport: flaky)
      .complete(try payload(routing), routing: routing, apiKey: "sk-test", purpose: .interactiveRewrite)

    XCTAssertEqual(text, #"{"candidates":["x"]}"#)
    XCTAssertEqual(flaky.requests.count, 2, "503 is transient → exactly one retry")
  }

  func testDraftingNeverRetries() async throws {
    let routing = Self.routing("openai", "https://api.openai.com/v1/chat/completions", "gpt-4o")
    let transport = OwlRecordingTransport.replying(Data(), status: 503)

    do {
      _ = try await OwlLLMGateway(transport: transport)
        .complete(try payload(routing), routing: routing, apiKey: "sk-test", purpose: .drafting)
      XCTFail("503 must surface")
    } catch let error as OwlCloudRequestError {
      XCTAssertEqual(error, .badHTTPStatus(503))
    }
    XCTAssertEqual(transport.requests.count, 1)
  }

  func testCancellingTheCallerCancelsTheRequestWithoutRetry() async throws {
    let routing = Self.routing("openai", "https://api.openai.com/v1/chat/completions", "gpt-4o")
    let transport = OwlRecordingTransport { _ in
      try await Task.sleep(nanoseconds: 10_000_000_000)
      return (Data(), URLResponse())
    }
    let gateway = OwlLLMGateway(transport: transport)
    let body = try payload(routing)
    let task = Task {
      try await gateway.complete(body, routing: routing, apiKey: "sk-test", purpose: .interactiveRewrite)
    }
    while transport.requests.isEmpty { await Task.yield() }

    let started = Date()
    task.cancel()
    let result = await task.result

    XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    XCTAssertEqual(transport.requests.count, 1, "a cancelled call is not retried")
  }

  func testStreamPicksTheWireFromCapabilities() async throws {
    let cases: [(OwlCloudRouting, String, String)] = [
      (Self.routing("openai", "https://api.openai.com/v1/chat/completions", "gpt-4o"),
       "data: {\"choices\":[{\"delta\":{\"content\":\"甲\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"乙\"}}]}\n\ndata: [DONE]\n\n",
       "https://api.openai.com/v1/chat/completions"),
      (Self.routing("qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen3.7-plus"),
       "data: {\"type\":\"response.output_text.delta\",\"delta\":\"甲\"}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"乙\"}\n\ndata: {\"type\":\"response.completed\"}\n\n",
       "https://dashscope.aliyuncs.com/compatible-mode/v1/responses"),
    ]
    for (routing, sse, url) in cases {
      let transport = OwlRecordingTransport.replying(Data(sse.utf8))
      var text = ""
      for try await delta in OwlLLMGateway(transport: transport)
        .stream(messages: [OwlDeepSeekMessage(role: "user", content: "问")], routing: routing, apiKey: "sk-test") {
        text += delta
      }
      XCTAssertEqual(text, "甲乙", routing.providerID)
      XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [url], routing.providerID)
    }
  }

  func testStreamFinishesWithTheHTTPStatusOnRefusal() async throws {
    let routing = Self.routing("openai", "https://api.openai.com/v1/chat/completions", "gpt-4o")
    let transport = OwlRecordingTransport.replying(Data(), status: 401)
    do {
      for try await _ in OwlLLMGateway(transport: transport)
        .stream(messages: [], routing: routing, apiKey: "sk-test") {}
      XCTFail("401 must surface")
    } catch let error as OwlStreamingError {
      XCTAssertEqual(error, .badHTTPStatus(401))
    }
  }

  func testTelemetryRecordsTokenCountsButNeverText() async throws {
    let sentinel = "SENTINEL_甲乙丙"
    let replies: [(OwlCloudRouting, String)] = [
      (Self.routing("openai", "https://api.openai.com/v1/chat/completions", "gpt-4o"),
       #"{"choices":[{"message":{"content":"SENTINEL_甲乙丙"}}],"model":"gpt-4o","usage":{"completion_tokens":3,"prompt_tokens":5,"total_tokens":8}}"#),
      (Self.routing("qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen3.7-plus"),
       #"{"output_text":"SENTINEL_甲乙丙","model":"qwen3.7-plus","usage":{"input_tokens":5,"output_tokens":3,"total_tokens":8}}"#),
    ]
    for (routing, reply) in replies {
      OwlCloudUsageTelemetry.resetForTesting()
      let transport = OwlRecordingTransport.replying(Data(reply.utf8))

      let text = try await OwlLLMGateway(transport: transport)
        .complete(try payload(routing, sentinel), routing: routing, apiKey: "sk-test", purpose: .drafting)

      XCTAssertEqual(text, sentinel)
      let usage = try XCTUnwrap(OwlCloudUsageTelemetry.lastUsage, routing.providerID)
      XCTAssertEqual(usage.model, routing.model)
      XCTAssertEqual(usage.totalTokens, 8)
      let stored = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
      XCTAssertFalse(stored.contains("SENTINEL"), "telemetry must never carry request or reply text")
    }
  }
}
