//
//  FamoResponsesStreamingClientTests.swift
//  FamoTests — 普通问答 / 联网搜索的 `/responses` 流式传输（Qwen / 豆包 / OpenAI）
//
//  The headline test here is `testResponsesFramesActuallyProduceDeltas` + its twin
//  `testChatCompletionsParserSilentlyProducesNothingForResponsesFrames`. Pointing the existing
//  `/chat/completions` parser at Responses frames is NOT an error — it finishes cleanly with zero
//  content, i.e. a blank answer with no crash and no log. Both halves are pinned so that silent
//  failure can never ship: one proves the new parser reads the frames, the other proves the old
//  one doesn't (so nobody "simplifies" the two back into one).
//
//  Everything else asserts what actually went ON THE WIRE — the decoded `URLRequest.httpBody`,
//  not the dictionary we handed in: rewritten `/responses` URL, `stream: true`, Qwen's
//  Chat-compatible input messages, and the 方舟/OpenAI `input_text` dialect.
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

  private func qwenRouting() -> FamoCloudRouting {
    FamoCloudRouting(
      providerID: "qwen",
      endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
      model: "qwen3.7-plus",
      secretName: "famo.provider.qwen.apiKey",
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
      client.stream(
        messages: [], routing: arkRouting(), apiKey: "sk-test", dialect: .ark, webSearch: true))
    XCTAssertEqual(deltas, ["根据", "最新检索"])
  }

  func testClientFinishesWithUpstreamFailureInsteadOfABlankAnswer() async {
    let client = makeClient(status: 200, chunks: [
      #"data: {"type":"response.output_text.delta","delta":"部分"}"# + "\n\n",
      #"data: {"type":"response.failed","response":{"error":{"message":"tool call failed"}}}"# + "\n\n",
    ])
    do {
      _ = try await collect(
        client.stream(
          messages: [], routing: arkRouting(), apiKey: "sk-test", dialect: .ark, webSearch: true))
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
        client.stream(
          messages: [], routing: arkRouting(), apiKey: "sk-test", dialect: .ark, webSearch: true))
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
    dialect: FamoResponsesDialect,
    webSearch: Bool = true,
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
      client.stream(
        messages: messages, routing: routing, apiKey: "sk-test",
        dialect: dialect, webSearch: webSearch))
    guard let request = await box.get(),
          let data = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      XCTFail("expected a JSON request body")
      return (nil, [:])
    }
    return (request.url, object)
  }

  func testArkRequestGoesToResponsesWithSearchToolAndStreaming() async throws {
    let captured = try await captureRequest(routing: arkRouting(), dialect: .ark)
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
    XCTAssertEqual(
      captured.body["store"] as? Bool, false,
      "方舟 Responses store 默认 true；Famo 不检索历史响应，必须显式关闭")
  }

  func testArkPlainRequestStillDisablesThinkingAndStorage() async throws {
    // 2026-07-31 豆包全面走 Responses 后，关思考与 store=false 不再只属于搜索请求：
    // 方舟 Responses `store` 默认 true、思考默认开（官方示例一句寒暄烧 211 reasoning token），
    // 普通生成漏掉任一字段都是回归。
    let captured = try await captureRequest(
      routing: arkRouting(), dialect: .ark, webSearch: false,
      messages: [FamoDeepSeekMessage(role: "user", content: "你好")])
    XCTAssertEqual(
      captured.url?.absoluteString,
      "https://ark.cn-beijing.volces.com/api/v3/responses")
    XCTAssertEqual((captured.body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
    XCTAssertEqual(captured.body["store"] as? Bool, false)
    XCTAssertNil(captured.body["tools"], "普通生成不带搜索工具")
    XCTAssertNil(captured.body["max_tool_calls"])
    XCTAssertNil(captured.body["reasoning"], "reasoning.effort 是 qwen 的字段，方舟不认")
  }

  func testOpenAIRequestOmitsVolcengineOnlyFields() async throws {
    // OpenAI 400s on 方舟's tool extras and has no `thinking` field.
    let captured = try await captureRequest(routing: openAIRouting(), dialect: .openAI)
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
      routing: arkRouting(), dialect: .ark, messages: messages)
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

  func testQwenPlainRequestUsesResponsesWithoutSearchFields() async throws {
    let captured = try await captureRequest(
      routing: qwenRouting(), dialect: .qwen, webSearch: false,
      messages: [FamoDeepSeekMessage(role: "user", content: "你好")])
    XCTAssertEqual(
      captured.url?.absoluteString,
      "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")
    XCTAssertEqual(captured.body["model"] as? String, "qwen3.7-plus")
    XCTAssertEqual(captured.body["stream"] as? Bool, true)
    XCTAssertEqual(
      captured.body["store"] as? Bool, false,
      "Famo 不使用响应检索/多轮 Response ID；必须关闭百炼默认开启的服务端存储")
    XCTAssertNil(captured.body["messages"])
    XCTAssertNil(captured.body["tools"])
    XCTAssertNil(captured.body["enable_thinking"])
    XCTAssertEqual(
      (captured.body["reasoning"] as? [String: Any])?["effort"] as? String,
      "none")
  }

  func testQwenSearchRequestUsesBuiltInWebSearchAndRequiresATool() async throws {
    let captured = try await captureRequest(routing: qwenRouting(), dialect: .qwen)
    let tools = try XCTUnwrap(captured.body["tools"] as? [[String: Any]])
    XCTAssertEqual(
      tools.map { $0["type"] as? String }, ["web_search"],
      "只挂 web_search 一个：required 模式只准一个工具，web_extractor 又进不了非思考模式（实测双 400）")
    XCTAssertEqual(tools.first?.count, 1)
    XCTAssertEqual(captured.body["tool_choice"] as? String, "required")
    XCTAssertEqual(captured.body["store"] as? Bool, false)
    XCTAssertNil(captured.body["enable_search"])
    XCTAssertNil(captured.body["search_options"])
  }

  func testQwenUsesTheDocumentedChatCompatibleMessageInput() async throws {
    let messages = [
      FamoDeepSeekMessage(role: "system", content: "你是法律助理"),
      FamoDeepSeekMessage(role: "user", content: "第一问"),
      FamoDeepSeekMessage(role: "assistant", content: "第一答"),
    ]
    let captured = try await captureRequest(
      routing: qwenRouting(), dialect: .qwen, webSearch: false, messages: messages)
    let input = try XCTUnwrap(captured.body["input"] as? [[String: Any]])
    XCTAssertEqual(input.compactMap { $0["role"] as? String }, ["system", "user", "assistant"])
    XCTAssertEqual(input.compactMap { $0["content"] as? String }, ["你是法律助理", "第一问", "第一答"])
  }

  func testQwenNonStreamingPayloadParsesOutputUsageAndSearchSources() throws {
    let data = Data(#"""
      {
        "model":"qwen3.7-plus",
        "output":[
          {"type":"web_search_call","action":{"sources":[
            {"type":"url","url":"https://example.com/a"},
            {"type":"url","url":"https://example.com/a"}
          ]}},
          {"type":"message","content":[{"type":"output_text","text":"结论"}]}
        ],
        "usage":{"input_tokens":12,"output_tokens":7,"total_tokens":19,
          "input_tokens_details":{"cached_tokens":3}}
      }
      """#.utf8)
    let parsed = try FamoResponsesWire.parse(data)
    XCTAssertEqual(parsed.text, "结论")
    XCTAssertEqual(parsed.model, "qwen3.7-plus")
    XCTAssertEqual(parsed.usage?.inputTokens, 12)
    XCTAssertEqual(parsed.usage?.outputTokens, 7)
    XCTAssertEqual(parsed.usage?.totalTokens, 19)
    XCTAssertEqual(parsed.usage?.cachedTokens, 3)
    XCTAssertEqual(parsed.sources, [FamoResponsesSource(title: "", url: "https://example.com/a")])
  }

  func testQwenStructuredSkillsUseResponsesWithoutUnsupportedChatFields() throws {
    let payloads = [
      try FamoSelectionPolish.chatRequest(
        for: "他撤销了合同", model: "qwen3.7-plus", providerID: "qwen"),
      FamoPromptOptimizer.chatRequest(
        forDraft: "帮我写个爬虫", model: "qwen3.7-plus", providerID: "qwen"),
      FamoGoalBrief.chatRequest(
        forDraft: "把词库下载做稳", model: "qwen3.7-plus", providerID: "qwen"),
    ]
    let legacyEndpoint = URL(
      string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!

    for payload in payloads {
      let request = try FamoResponsesWire.request(
        endpoint: legacyEndpoint,
        model: payload.model,
        messages: payload.messages,
        apiKey: "sk-test",
        authHeaderStyle: .bearer,
        dialect: .qwen,
        stream: false,
        webSearch: false,
        temperature: payload.temperature,
        timeout: 60)
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
      XCTAssertEqual((body["input"] as? [[String: Any]])?.count, payload.messages.count)
      XCTAssertNil(body["messages"])
      XCTAssertNil(body["response_format"], "Qwen Responses 文档未列出旧 json_object 字段")
      XCTAssertNil(body["enable_thinking"])
      XCTAssertEqual(body["store"] as? Bool, false)
      XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
    }
  }

  // MARK: - URL rewriting (`FamoResponsesWire`)

  /// 百炼是**平台级** Responses 供应商：型号不参与判定。这条曾经是反的（非 qwen 型号回退
  /// `/chat/completions`），2026-07-31 产品决定旧模式不再兼容后语义反转——百炼上托管的
  /// `deepseek-*` 也必须走 `/responses`，不被服务时由上游 400 说话，而不是静默换一条旧链路。
  func testEveryDashScopeRoutingSpeaksResponsesRegardlessOfModel() {
    let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")!
    XCTAssertTrue(FamoResponsesWire.isQwen(providerID: "custom", endpoint: endpoint))
    XCTAssertTrue(FamoResponsesWire.isQwen(providerID: "qwen", endpoint: endpoint))
    // providerID 认百炼时，端点是不是阿里域名都不改变结论。
    XCTAssertTrue(FamoResponsesWire.isQwen(
      providerID: "qwen", endpoint: URL(string: "https://example.com/v1/responses")!))
    for model in ["qwen3.7-plus", "deepseek-v3.2", "kimi-k2", "glm-4.6"] {
      XCTAssertEqual(
        FamoResponsesWire.dialect(providerID: "qwen", model: model, endpoint: endpoint),
        .qwen,
        "百炼档案配 \(model) 仍必须走 Responses——回退 chat/completions 正是本次要拆掉的旧模式")
    }
  }

  /// **本次改动唯一的失败模式**：判定点漏改一处，那条链路就悄悄退回 `/chat/completions` ——
  /// 用户看不见任何错误，只是在用一条已被判定为不兼容的旧协议。所以把百炼 + 非 qwen 型号在每个
  /// 判定点上扫一遍。
  ///
  /// 第 6 处（`FamoSelectionPolish.makeRequest` 的 provider 分派）是 private，它的**可达闸门**
  /// 正是这里断言的 `sourceSupport`（见 FamoSelectionPolish.swift:382 的 guard）—— 那道闸放行后
  /// 才轮到 makeRequest，所以断言闸门等于断言了这条路进得去。
  func testDashScopeHostedNonQwenModelSpeaksResponsesAtEveryDecisionPoint() throws {
    let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")!
    let model = "deepseek-v3"

    // 1. wire 方言判定
    XCTAssertEqual(
      FamoResponsesWire.dialect(providerID: "qwen", model: model, endpoint: endpoint), .qwen)

    // 2. 联网搜索的传输选择
    XCTAssertEqual(
      FamoSearchControl.transport(providerID: "qwen", host: endpoint.host ?? ""),
      .responses(.qwen))

    // 3. 来源核验能力闸（也是第 6 处私有分派的可达前提）
    let profile = FamoProviderProfile(
      displayName: "阿里云百炼", endpoint: endpoint, model: model, providerID: "qwen")
    XCTAssertTrue(
      FamoLLMProviderCatalog.sourceSupport(for: profile).supportsSourceVerification,
      "百炼的来源核验能力属于平台，不该因为型号名不是 qwen 就降级成辅助检索")

    // 4. 连通性验证的请求体：Responses 用 `input`，绝不能回退成 chat 的 `messages`
    let body = FamoProviderConnectivityCheck.body(
      providerID: "qwen", model: model, endpoint: endpoint)
    XCTAssertNotNil(body["input"], "连通性验证必须发 Responses 形状")
    XCTAssertNil(body["messages"], "回退到 chat 形状就是本次要拆掉的旧模式")
    XCTAssertNil(body["enable_thinking"], "关思考在 Responses 里由 reasoning.effort 负责")
    XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
    XCTAssertEqual(body["store"] as? Bool, false, "百炼整面维持 store=false")

    // 5. 连通性验证打到的 URL
    let request = try FamoProviderConnectivityCheck.request(
      endpoint: endpoint, providerID: "qwen", model: model,
      apiKey: "sk-test", authStyle: .bearer)
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")
  }

  /// 反向守卫：`isArk` 刻意**不**跟着放开。方舟托管的第三方模型各有各的 wire，只有百炼被判定为
  /// 平台级 Responses。这处不对称一旦被"顺手对齐"，豆包档案上的第三方模型就会被错发 Responses。
  func testArkStillRequiresTheModelPrefix() {
    let endpoint = URL(string: "https://ark.cn-beijing.volces.com/api/v3/responses")!
    XCTAssertTrue(FamoResponsesWire.isArk(
      providerID: "doubao", model: "doubao-seed-2-1-pro-260628", endpoint: endpoint))
    XCTAssertFalse(FamoResponsesWire.isArk(
      providerID: "doubao", model: "deepseek-v3.2", endpoint: endpoint))
  }

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
