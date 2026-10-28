//
//  OwlLLMStreamingRecordingTests.swift
//  OwltypeTests — streaming chat and 任意提问: one table of recorded provider requests
//
//  Offline: a URLProtocol stub on `URLSession.shared` answers every request and records it, so the
//  live default composition (no injected client) is what gets measured. `recorded` was captured from
//  the pre-gateway streaming clients (2026-10-28, revision ba25e99); a refactor that changes any
//  provider's URL, timeout, headers or body breaks here first.
//

import CryptoKit
import XCTest
@testable import Owltype

/// Answers every request with a canned SSE / search reply and records what was sent.
final class OwlRecordingURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var recordedRequests: [(request: URLRequest, body: Data)] = []

  static var requests: [(request: URLRequest, body: Data)] {
    lock.lock(); defer { lock.unlock() }
    return recordedRequests
  }

  static func reset() {
    lock.lock(); recordedRequests = []; lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let body = request.httpBody ?? Self.drain(request.httpBodyStream)
    Self.lock.lock(); Self.recordedRequests.append((request, body)); Self.lock.unlock()

    let path = request.url?.path ?? ""
    let reply: String
    if path.hasSuffix("/tools/search") {
      reply = #"{"results":[{"title":"甲","url":"https://example.com/a","content":"乙"}]}"#
    } else if path.hasSuffix("/responses") {
      reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"答[1]\"}\n\ndata: {\"type\":\"response.completed\"}\n\n"
    } else {
      reply = "data: {\"choices\":[{\"delta\":{\"content\":\"答[1]\"}}]}\n\ndata: [DONE]\n\n"
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(reply.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func drain(_ stream: InputStream?) -> Data {
    guard let stream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

@MainActor
final class OwlLLMStreamingRecordingTests: XCTestCase {
  private static let messages = [
    OwlDeepSeekMessage(role: "system", content: "你是助手"),
    OwlDeepSeekMessage(role: "user", content: "今天上海天气如何"),
  ]

  private static let matrix: [(String, String, String)] = [
    ("deepseek", "https://api.deepseek.com/chat/completions", "deepseek-chat"),
    ("deepseek", "https://api.deepseek.com/chat/completions", "deepseek-flash"),
    // A DeepSeek proxy: search still applies, but the profile's model is kept.
    ("deepseek", "https://proxy.example.com/v1/chat/completions", "deepseek-chat"),
    ("qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen3.7-plus"),
    ("doubao", "https://ark.cn-beijing.volces.com/api/v3/chat/completions", "doubao-seed-1.6"),
    ("openai", "https://api.openai.com/v1/chat/completions", "gpt-4o"),
    ("gemini", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "gemini-3.8-flash"),
    ("minimax", "https://api.minimax.io/v1/chat/completions", "MiniMax-M3"),
    ("minimax", "https://api.minimax.io/v1/chat/completions", "MiniMax-M3.1-Flash"),
    // An unstamped custom profile on 百炼 hosting a DeepSeek model: the host decides, 百炼 wins.
    ("", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "deepseek-v4-flash"),
  ]

  /// `flow|providerID|host|model#n` → the n-th request that flow sent.
  private static let recorded: [String: (url: String, timeout: Double, headers: String, bodySHA256: String)] = [
    "plain|deepseek|api.deepseek.com|deepseek-chat#0": ("https://api.deepseek.com/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=213;Content-Type=application/json", "e150098eaec6da7ba8673b4f8176b0ff6d73d9c8721ced0e375f702e29fa0591"),
    "ask|deepseek|api.deepseek.com|deepseek-chat#0": ("https://api.deepseek.com/v1/tools/search", 10, "Authorization=Bearer sk-test;Content-Length=88;Content-Type=application/json", "b40b261b740d12eb682c971749bde1ebb16db6a12b7c417656c173f0823e593f"),
    "ask|deepseek|api.deepseek.com|deepseek-chat#1": ("https://api.deepseek.com/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=667;Content-Type=application/json", "3e19f96e0027b7a7841769d081fd2df0713e2ceea842b63c3b0689e77d18f42e"),
    "plain|deepseek|api.deepseek.com|deepseek-flash#0": ("https://api.deepseek.com/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=272;Content-Type=application/json", "0077da7ba03fced9e92411704ffef0abfb5bca81ee18ed0710238ec54053c20e"),
    "ask|deepseek|api.deepseek.com|deepseek-flash#0": ("https://api.deepseek.com/v1/tools/search", 10, "Authorization=Bearer sk-test;Content-Length=88;Content-Type=application/json", "b40b261b740d12eb682c971749bde1ebb16db6a12b7c417656c173f0823e593f"),
    "ask|deepseek|api.deepseek.com|deepseek-flash#1": ("https://api.deepseek.com/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=667;Content-Type=application/json", "3e19f96e0027b7a7841769d081fd2df0713e2ceea842b63c3b0689e77d18f42e"),
    "plain|deepseek|proxy.example.com|deepseek-chat#0": ("https://proxy.example.com/v1/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=213;Content-Type=application/json", "e150098eaec6da7ba8673b4f8176b0ff6d73d9c8721ced0e375f702e29fa0591"),
    "ask|deepseek|proxy.example.com|deepseek-chat#0": ("https://proxy.example.com/v1/tools/search", 10, "Authorization=Bearer sk-test;Content-Length=88;Content-Type=application/json", "b40b261b740d12eb682c971749bde1ebb16db6a12b7c417656c173f0823e593f"),
    "ask|deepseek|proxy.example.com|deepseek-chat#1": ("https://proxy.example.com/v1/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=577;Content-Type=application/json", "b9f16876ba8d894c02e9293f46cbc99317e4e08e2919d440d9b9b8b54ced7adf"),
    "plain|qwen|dashscope.aliyuncs.com|qwen3.7-plus#0": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=222;Content-Type=application/json", "4a281a3c57fda233cb1589ad92571cff5e45fda6320ef6434c8343040ef33f08"),
    "ask|qwen|dashscope.aliyuncs.com|qwen3.7-plus#0": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=222;Content-Type=application/json", "4a281a3c57fda233cb1589ad92571cff5e45fda6320ef6434c8343040ef33f08"),
    "plain|doubao|ark.cn-beijing.volces.com|doubao-seed-1.6#0": ("https://ark.cn-beijing.volces.com/api/v3/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=288;Content-Type=application/json", "169125bff3139b541bf27054b02c44f056a04782b24e48e02212416d57cc6fbf"),
    "ask|doubao|ark.cn-beijing.volces.com|doubao-seed-1.6#0": ("https://ark.cn-beijing.volces.com/api/v3/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=288;Content-Type=application/json", "169125bff3139b541bf27054b02c44f056a04782b24e48e02212416d57cc6fbf"),
    "plain|openai|api.openai.com|gpt-4o#0": ("https://api.openai.com/v1/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=159;Content-Type=application/json", "e1f8b2fe199f65980fd6aafcd05f843e1683a15a38e5759c519de36fc465f6ed"),
    "ask|openai|api.openai.com|gpt-4o#0": ("https://api.openai.com/v1/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=159;Content-Type=application/json", "e1f8b2fe199f65980fd6aafcd05f843e1683a15a38e5759c519de36fc465f6ed"),
    "plain|gemini|generativelanguage.googleapis.com|gemini-3.8-flash#0": ("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=151;Content-Type=application/json", "9f0727618136344d2c41256e5d7018965cf3913abf03c27e835dc0ff0ad171ff"),
    "ask|gemini|generativelanguage.googleapis.com|gemini-3.8-flash#0": ("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=151;Content-Type=application/json", "9f0727618136344d2c41256e5d7018965cf3913abf03c27e835dc0ff0ad171ff"),
    "plain|minimax|api.minimax.io|MiniMax-M3#0": ("https://api.minimax.io/v1/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=233;Content-Type=application/json", "117f94f54b9eb09464eb21a1c5672f749896e4ffd4e023917269bfd727b10f96"),
    "ask|minimax|api.minimax.io|MiniMax-M3#0": ("https://api.minimax.io/v1/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=233;Content-Type=application/json", "117f94f54b9eb09464eb21a1c5672f749896e4ffd4e023917269bfd727b10f96"),
    "plain|minimax|api.minimax.io|MiniMax-M3.1-Flash#0": ("https://api.minimax.io/v1/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=235;Content-Type=application/json", "b66d2551966164f0bde35c31703a3eb352c9ae62d539c492c54572919b5fdb1c"),
    "ask|minimax|api.minimax.io|MiniMax-M3.1-Flash#0": ("https://api.minimax.io/v1/chat/completions", 30, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=235;Content-Type=application/json", "b66d2551966164f0bde35c31703a3eb352c9ae62d539c492c54572919b5fdb1c"),
    "plain||dashscope.aliyuncs.com|deepseek-v4-flash#0": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=227;Content-Type=application/json", "9eaaecbaa8fdea1444647b99abb7fb1b98d6fbfb7b920d4a0707e1fee43ed826"),
    "ask||dashscope.aliyuncs.com|deepseek-v4-flash#0": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=227;Content-Type=application/json", "9eaaecbaa8fdea1444647b99abb7fb1b98d6fbfb7b920d4a0707e1fee43ed826"),
    "responses-search|qwen|qwen3.7-plus#0": ("https://dashscope.aliyuncs.com/compatible-mode/v1/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=279;Content-Type=application/json", "41db8200ef252140318160475ec116ffde0c2df0f84681da2d99f7e385154d3b"),
    "responses-search|doubao|doubao-seed-1.6#0": ("https://ark.cn-beijing.volces.com/api/v3/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=365;Content-Type=application/json", "364870d6e31e65763e4785180cbb5805bac693c0cc4da2383176655a4512fca2"),
    "responses-search|deepseek|deepseek-flash#0": ("https://api.deepseek.com/responses", 90, "Accept=text/event-stream;Authorization=Bearer sk-test;Content-Length=299;Content-Type=application/json", "d7de1b73b86d1455ecebbbf8041f396993d5916294dc88f26dec37f29cf540a3"),
  ]

  override func setUp() async throws {
    try await super.setUp()
    OwlRecordingURLProtocol.reset()
    URLProtocol.registerClass(OwlRecordingURLProtocol.self)
  }

  override func tearDown() async throws {
    URLProtocol.unregisterClass(OwlRecordingURLProtocol.self)
    OwlRecordingURLProtocol.reset()
    try await super.tearDown()
  }

  private static func profile(_ providerID: String, _ endpoint: String, _ model: String) -> OwlProviderProfile {
    OwlProviderProfile(
      id: "p", displayName: "P", endpoint: URL(string: endpoint)!, model: model,
      providerID: providerID.isEmpty ? nil : providerID, secretName: "owltype.provider.p.apiKey",
      isDefault: true)
  }

  private static func digest(_ body: Data) throws -> String {
    // Dictionary-built bodies have no stable key order, so hash the canonical (sorted) JSON.
    let object = try JSONSerialization.jsonObject(with: body)
    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
  }

  private static func headers(_ request: URLRequest) -> String {
    (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
  }

  private func drain(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var text = ""
    for try await delta in stream { text += delta }
    return text
  }

  /// Takes what the stub saw since the last call and checks it against `recorded`.
  private func check(_ flow: String, _ lines: inout [String]) throws {
    let seen = OwlRecordingURLProtocol.requests
    OwlRecordingURLProtocol.reset()
    XCTAssertFalse(seen.isEmpty, "\(flow) sent nothing")
    for (index, entry) in seen.enumerated() {
      let key = "\(flow)#\(index)"
      let url = entry.request.url?.absoluteString ?? ""
      let timeout = entry.request.timeoutInterval
      let headers = Self.headers(entry.request)
      let sha = try Self.digest(entry.body)
      XCTAssertEqual(entry.request.httpMethod, "POST", key)
      lines.append(#"    "\#(key)": ("\#(url)", \#(Int(timeout)), "\#(headers)", "\#(sha)"),"#)
      guard let expected = Self.recorded[key] else {
        XCTFail("no recording for \(key)")
        continue
      }
      XCTAssertEqual(url, expected.url, key)
      XCTAssertEqual(timeout, expected.timeout, key)
      XCTAssertEqual(headers, expected.headers, key)
      XCTAssertEqual(sha, expected.bodySHA256, "\(key) body changed")
    }
    XCTAssertEqual(
      seen.count, Self.recorded.keys.filter { $0.hasPrefix("\(flow)#") }.count, "\(flow) request count")
  }

  func testEveryStreamingAndAskRequestMatchesTheRecordedPreGatewayRequest() async throws {
    var lines: [String] = []
    for (providerID, endpoint, model) in Self.matrix {
      let profile = Self.profile(providerID, endpoint, model)
      let suffix = "\(providerID)|\(URL(string: endpoint)!.host!)|\(model)"

      // Plain streaming (划词技能 / 普通生成): the service resolves the profile and streams.
      let plain = OwlStreamingChatService(
        profileProvider: { profile }, profileSecretProvider: { _ in "sk-test" },
        legacyKeyProvider: { nil })
      guard case let .success(plainStream) = plain.stream(messages: Self.messages) else {
        return XCTFail("plain not ready: \(suffix)")
      }
      _ = try await drain(plainStream)
      try check("plain|\(suffix)", &lines)

      // 任意提问 with 联网 on and this profile as the only one: DeepSeek searches then answers;
      // every other provider falls back to the plain answer.
      let ask = OwlAskAnythingModule(
        profileProvider: { profile }, profileSecretProvider: { _ in "sk-test" },
        legacyKeyProvider: { nil },
        searchResolver: OwlAskSearchResolver(
          isEnabled: { true }, profilesProvider: { [profile] },
          defaultProfileProvider: { profile }, secretProvider: { _ in "sk-test" }))
      guard case let .success(open) = ask.open(messages: Self.messages) else {
        return XCTFail("ask not ready: \(suffix)")
      }
      _ = try await drain(open.stream)
      try check("ask|\(suffix)", &lines)
    }

    // The Responses client's built-in search body, still used by the live tests.
    for (providerID, endpoint, model, dialect) in [
      ("qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen3.7-plus", OwlResponsesDialect.qwen),
      ("doubao", "https://ark.cn-beijing.volces.com/api/v3/chat/completions", "doubao-seed-1.6", .ark),
      ("deepseek", "https://api.deepseek.com/chat/completions", "deepseek-flash", .deepseek),
    ] {
      let routing = OwlCloudRouting(
        providerID: providerID, endpoint: URL(string: endpoint)!, model: model,
        secretName: nil, authHeaderStyle: .bearer)
      _ = try await drain(OwlResponsesStreamingClient().stream(
        messages: Self.messages, routing: routing, apiKey: "sk-test", dialect: dialect, webSearch: true))
      try check("responses-search|\(providerID)|\(model)", &lines)
    }
    // On a deliberate wire change, re-record from this output.
    if testRun?.failureCount ?? 0 > 0 { print(lines.joined(separator: "\n")) }
  }
}
