//
//  FamoResponsesStreamingClientTests.swift
//  FamoTests — 任意提问「联网搜索」的 `/responses` 流式传输（豆包 / OpenAI）
//
//  The headline test here is `testResponsesFramesActuallyProduceDeltas` + its twin
//  `testChatCompletionsParserSilentlyProducesNothingForResponsesFrames`. Pointing the existing
//  `/chat/completions` parser at Responses frames is NOT an error — it finishes cleanly with zero
//  content, i.e. a blank answer with no crash and no log. Both halves are pinned so that silent
//  failure can never ship: one proves the new parser reads the frames, the other proves the old
//  one doesn't (so nobody "simplifies" the two back into one).
//
//  Everything else asserts what actually went ON THE WIRE — the decoded `URLRequest.httpBody`,
//  not the dictionary we handed in: rewritten `/responses` URL, `stream: true`, every role
//  (assistant included) as `input_text`, and the 方舟/OpenAI body dialects.
//
//  No network, no Keychain, no librime.
//

import Foundation
import XCTest
@testable import Famo

final class FamoResponsesStreamingClientTests: XCTestCase {

  // MARK: - Pure `/responses` parser

  func testResponsesFramesActuallyProduceDeltas() {
    // The reason this whole file exists: a Responses `output_text.delta` must become content.
    var parser = FamoResponsesStreamParser()
    let deltas = parser.consume(
      #"data: {"type":"response.output_text.delta","delta":"本院"}"# + "\n\n")
    XCTAssertEqual(deltas, ["本院"], "/responses 帧必须真的产出 delta，否则用户看到空白答案")
    XCTAssertFalse(parser.isFinished)
    XCTAssertNil(parser.failure)
  }

  func testChatCompletionsParserSilentlyProducesNothingForResponsesFrames() {
    // The trap, pinned from the other side: the chat parser does not throw on Responses frames —
    // it returns nothing at all. That is why `/responses` needs its own parser, not a tweak.
    var chatParser = FamoSSEChatParser()
    let deltas = chatParser.consume(
      #"data: {"type":"response.output_text.delta","delta":"本院"}"# + "\n\n"
        + "data: [DONE]\n\n")
    XCTAssertEqual(deltas, [], "chat/completions 解析器读 /responses 帧＝静默零内容（不报错）")
    XCTAssertTrue(chatParser.isFinished, "……而且流还“正常”结束了 —— 正是这个组合最危险")
  }

  func testParserMultipleDeltasYieldInOrderAndCompletedEndsTheStream() {
    var parser = FamoResponsesStreamParser()
    let body = [
      #"data: {"type":"response.created","response":{"id":"resp_1"}}"#,
      "",
      #"data: {"type":"response.output_text.delta","delta":"本院"}"#,
      "",
      #"data: {"type":"response.output_text.delta","delta":"认为"}"#,
      "",
      #"data: {"type":"response.completed"}"#,
      "",
    ].joined(separator: "\n") + "\n"
    XCTAssertEqual(parser.consume(body), ["本院", "认为"])
    XCTAssertTrue(parser.isFinished)
    // After the terminal frame further input is ignored.
    XCTAssertEqual(
      parser.consume(#"data: {"type":"response.output_text.delta","delta":"乙"}"# + "\n"), [])
  }

  func testParserDoneAlsoEndsTheStream() {
    var parser = FamoResponsesStreamParser()
    _ = parser.consume(#"data: {"type":"response.output_text.delta","delta":"甲"}"# + "\n")
    XCTAssertEqual(parser.consume("data: [DONE]\n\n"), [])
    XCTAssertTrue(parser.isFinished)
  }

  func testParserRecordsUpstreamFailureMessage() {
    var parser = FamoResponsesStreamParser()
    let deltas = parser.consume(
      #"data: {"type":"response.failed","response":{"error":{"message":"search quota exhausted"}}}"#
        + "\n\n")
    XCTAssertEqual(deltas, [])
    XCTAssertTrue(parser.isFinished)
    XCTAssertEqual(parser.failure, "search quota exhausted", "失败帧必须被记住，否则退化成空答案")
  }

  func testParserRecordsBareErrorFrame() {
    var parser = FamoResponsesStreamParser()
    _ = parser.consume(#"data: {"type":"error","error":{"message":"bad request"}}"# + "\n\n")
    XCTAssertEqual(parser.failure, "bad request")
  }

  func testParserIgnoresScaffoldingCommentsAndEventLines() {
    // Reasoning / output-item / content-part events and SSE framing carry no answer text.
    var parser = FamoResponsesStreamParser()
    let body = [
      ": keepalive",
      "event: response.output_item.added",
      #"data: {"type":"response.output_item.added","item":{"type":"reasoning"}}"#,
      "",
      #"data: {"type":"response.content_part.added"}"#,
      "",
      #"data: {"type":"response.output_text.delta","delta":""}"#,
      "",
      #"data: {"type":"response.output_text.delta"}"#,
      "",
      "data: {not json",
      "",
      #"data: {"type":"response.output_text.delta","delta":"管辖"}"#,
      "",
    ].joined(separator: "\n") + "\n"
    XCTAssertEqual(parser.consume(body), ["管辖"])
    XCTAssertNil(parser.failure)
    XCTAssertFalse(parser.isFinished)
  }

  func testParserReassemblesDeltaSplitAcrossChunks() {
    var parser = FamoResponsesStreamParser()
    XCTAssertEqual(parser.consume(#"data: {"type":"response.output_text.de"#), [])
    XCTAssertEqual(parser.consume(#"lta","delta":"裁定"}"# + "\n\n"), ["裁定"])
  }

  func testParserFinishFlushesATrailingLineWithoutNewline() {
    var parser = FamoResponsesStreamParser()
    XCTAssertEqual(parser.consume(#"data: {"type":"response.output_text.delta","delta":"末"}"#), [])
    XCTAssertEqual(parser.finish(), ["末"])
  }

  // MARK: - Client (injected scripted byte source — no socket)

  private func makeClient(status: Int, chunks: [String]) -> FamoResponsesStreamingClient {
    FamoResponsesStreamingClient(bytesProvider: { _ in
      let http = HTTPURLResponse(
        url: URL(string: "https://ark.cn-beijing.volces.com/api/v3/responses")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
      )
      let stream = AsyncThrowingStream<String, Error> { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }
      return FamoStreamingBytesSource(response: http, chunks: stream)
    })
  }

  private func arkRouting() -> FamoCloudRouting {
    FamoCloudRouting(
      providerID: "doubao",
      endpoint: URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!,
      model: "doubao-seed-1.6",
      secretName: "famo.provider.doubao.apiKey",
      authHeaderStyle: .bearer
    )
  }

  private func openAIRouting() -> FamoCloudRouting {
    FamoCloudRouting(
      providerID: "openai",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-5.1",
      secretName: "famo.provider.openai.apiKey",
      authHeaderStyle: .bearer
    )
  }

  private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var out: [String] = []
    for try await delta in stream { out.append(delta) }
    return out
  }

  func testClientStreamsResponsesDeltasEndToEnd() async throws {
    let client = makeClient(status: 200, chunks: [
      #"data: {"type":"response.created"}"# + "\n\n",
      #"data: {"type":"response.output_text.delta","delta":"根据"}"# + "\n\n",
      #"data: {"type":"response.output_text.delta","delta":"最新检索"}"# + "\n\n",
      #"data: {"type":"response.completed"}"# + "\n\n",
    ])
    let deltas = try await collect(
      client.stream(messages: [], routing: arkRouting(), apiKey: "sk-test", isOpenAI: false))
    XCTAssertEqual(deltas, ["根据", "最新检索"])
  }

  func testClientFinishesWithUpstreamFailureInsteadOfABlankAnswer() async {
    let client = makeClient(status: 200, chunks: [
      #"data: {"type":"response.output_text.delta","delta":"部分"}"# + "\n\n",
      #"data: {"type":"response.failed","response":{"error":{"message":"tool call failed"}}}"# + "\n\n",
    ])
    do {
      _ = try await collect(
        client.stream(messages: [], routing: arkRouting(), apiKey: "sk-test", isOpenAI: false))
      XCTFail("a response.failed frame must surface as an error, not a truncated success")
    } catch let error as FamoStreamingError {
      XCTAssertEqual(error, .upstreamFailure("tool call failed"))
    } catch {
      XCTFail("expected FamoStreamingError.upstreamFailure, got \(error)")
    }
  }

  func testClientNon2xxFinishesWithBadHTTPStatus() async {
    let client = makeClient(status: 401, chunks: [])
    do {
      _ = try await collect(
        client.stream(messages: [], routing: arkRouting(), apiKey: "sk-test", isOpenAI: false))
      XCTFail("a non-2xx status must finish the stream with an error")
    } catch let error as FamoStreamingError {
      XCTAssertEqual(error, .badHTTPStatus(401))
    } catch {
      XCTFail("expected FamoStreamingError.badHTTPStatus, got \(error)")
    }
  }

  // MARK: - Request on the wire

  /// Capture the `URLRequest` the client builds, without opening a socket.
  private func captureRequest(
    routing: FamoCloudRouting,
    isOpenAI: Bool,
    messages: [FamoDeepSeekMessage] = []
  ) async throws -> (url: URL?, body: [String: Any]) {
    let box = ResponsesRequestBox()
    let client = FamoResponsesStreamingClient(bytesProvider: { request in
      await box.set(request)
      return FamoStreamingBytesSource(
        response: HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil),
        chunks: AsyncThrowingStream { $0.finish() })
    })
    _ = try await collect(
      client.stream(messages: messages, routing: routing, apiKey: "sk-test", isOpenAI: isOpenAI))
    guard let request = await box.get(),
          let data = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      XCTFail("expected a JSON request body")
      return (nil, [:])
    }
    return (request.url, object)
  }

  func testArkRequestGoesToResponsesWithSearchToolAndStreaming() async throws {
    let captured = try await captureRequest(routing: arkRouting(), isOpenAI: false)
    XCTAssertEqual(
      captured.url?.absoluteString,
      "https://ark.cn-beijing.volces.com/api/v3/responses",
      "/chat/completions 必须被改写到 /responses —— 联网搜索只在那条端点上")
    XCTAssertEqual(captured.body["model"] as? String, "doubao-seed-1.6")
    XCTAssertEqual(captured.body["stream"] as? Bool, true)
    guard let tools = captured.body["tools"] as? [[String: Any]], let tool = tools.first else {
      return XCTFail("方舟 must carry a web_search tool")
    }
    XCTAssertEqual(tool["type"] as? String, "web_search")
    XCTAssertEqual(tool["max_keyword"] as? Int, 2)
    XCTAssertEqual(tool["limit"] as? Int, 3)
    // 方舟 的联网与思考互斥，且并行工具调用要封顶。
    XCTAssertEqual((captured.body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
    XCTAssertEqual(captured.body["max_tool_calls"] as? Int, 3)
  }

  func testOpenAIRequestOmitsVolcengineOnlyFields() async throws {
    // OpenAI 400s on 方舟's tool extras and has no `thinking` field.
    let captured = try await captureRequest(routing: openAIRouting(), isOpenAI: true)
    XCTAssertEqual(captured.url?.absoluteString, "https://api.openai.com/v1/responses")
    guard let tools = captured.body["tools"] as? [[String: Any]], let tool = tools.first else {
      return XCTFail("OpenAI must carry a web_search tool")
    }
    XCTAssertEqual(tool["type"] as? String, "web_search")
    XCTAssertEqual(tool.count, 1, "OpenAI 的 web_search 工具不吃 max_keyword/limit（会 400）")
    XCTAssertNil(captured.body["thinking"])
    XCTAssertNil(captured.body["max_tool_calls"])
  }

  func testEveryRoleIncludingAssistantIsSentAsInputText() async throws {
    // Tagging an assistant turn `output_text` makes 方舟 demand id+status+type → HTTP 400
    // `MissingParameter: input.status` on the 2nd turn. Famo is single-turn today; this test is
    // what keeps 追问 from breaking the day it lands.
    let messages = [
      FamoDeepSeekMessage(role: "system", content: "你是法律助理"),
      FamoDeepSeekMessage(role: "user", content: "什么是正当防卫"),
      FamoDeepSeekMessage(role: "assistant", content: "指为了使……"),
      FamoDeepSeekMessage(role: "user", content: "那紧急避险呢"),
    ]
    let captured = try await captureRequest(
      routing: arkRouting(), isOpenAI: false, messages: messages)
    guard let input = captured.body["input"] as? [[String: Any]] else {
      return XCTFail("expected an input array")
    }
    XCTAssertEqual(input.count, 4)
    XCTAssertEqual(input.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
    for item in input {
      guard let content = item["content"] as? [[String: Any]], let part = content.first else {
        return XCTFail("每个 input 项都要有 content 数组")
      }
      XCTAssertEqual(
        part["type"] as? String, "input_text",
        "所有角色（含 assistant 历史）都必须是 input_text，否则第二轮 400")
    }
    XCTAssertEqual(input.last?["content"] as? [[String: String]] ?? [], [["type": "input_text", "text": "那紧急避险呢"]])
  }

  // MARK: - URL rewriting (`FamoResponsesWire`)

  func testResponsesURLRewritesTheChatSuffix() {
    XCTAssertEqual(
      FamoResponsesWire.url(from: URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!)?
        .absoluteString,
      "https://ark.cn-beijing.volces.com/api/v3/responses")
  }

  func testResponsesURLLeavesAnAlreadyResponsesEndpointAlone() {
    XCTAssertEqual(
      FamoResponsesWire.url(from: URL(string: "https://api.openai.com/v1/responses")!)?.absoluteString,
      "https://api.openai.com/v1/responses")
  }

  func testResponsesURLAppendsToABareBaseURL() {
    XCTAssertEqual(
      FamoResponsesWire.url(from: URL(string: "https://api.openai.com/v1")!)?.absoluteString,
      "https://api.openai.com/v1/responses")
    XCTAssertEqual(
      FamoResponsesWire.url(from: URL(string: "https://api.openai.com/v1/")!)?.absoluteString,
      "https://api.openai.com/v1/responses")
  }

  func testResponsesURLDropsQueryAndFragment() {
    XCTAssertEqual(
      FamoResponsesWire.url(from: URL(string: "https://example.com/v1/chat/completions?x=1#f")!)?
        .absoluteString,
      "https://example.com/v1/responses")
  }
}

/// Carries the captured `URLRequest` out of the (concurrent) bytes provider closure.
private actor ResponsesRequestBox {
  private var request: URLRequest?
  func set(_ request: URLRequest) { self.request = request }
  func get() -> URLRequest? { request }
}
