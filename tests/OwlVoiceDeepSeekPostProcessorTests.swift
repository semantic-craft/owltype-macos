//
//  OwlVoiceDeepSeekPostProcessorTests.swift
//  OwltypeTests — Lane B: DeepSeek Voice Post-Processor Tests (#398)
//

import Foundation
import XCTest
@testable import Owltype

final class OwlVoiceDeepSeekPostProcessorTests: XCTestCase {

  // MARK: - 1. Wire Structure & Request Serialization

  func testSuccessfulPolishWithThinkingDisabled() async throws {
    let stubTransport = OwlStubVoiceTransport { request in
      // Verify Request Method and Headers
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock-key")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

      // Verify Body JSON
      let bodyData = try XCTUnwrap(request.httpBody)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
      XCTAssertEqual(json["model"] as? String, "deepseek-chat")
      XCTAssertEqual(json["temperature"] as? Double, 0.1)
      XCTAssertEqual(json["stream"] as? Bool, false)

      let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
      XCTAssertEqual(thinking["type"] as? String, "disabled")

      let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.count, 2)
      XCTAssertEqual(messages[0]["role"] as? String, "system")
      XCTAssertEqual(messages[1]["role"] as? String, "user")

      // Return standard DeepSeek chat completion response
      let responseJSON = """
      {
        "choices": [
          {
            "message": {
              "role": "assistant",
              "content": "今天天气很好。"
            }
          }
        ]
      }
      """
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(responseJSON.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "嗯今天天气很好啊")
    XCTAssertEqual(result, "今天天气很好。")
    XCTAssertEqual(stubTransport.recordedRequests.count, 1)
  }

  func testPromptAssemblyWithHotwordsAndPreContext() async throws {
    let stubTransport = OwlStubVoiceTransport { request in
      let bodyData = try XCTUnwrap(request.httpBody)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
      let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
      let userContent = try XCTUnwrap(messages[1]["content"] as? String)

      XCTAssertTrue(userContent.contains("<preceding_context>关于下周日程，</preceding_context>"))
      XCTAssertTrue(userContent.contains("<personal_hotwords>小明，张伟</personal_hotwords>"))
      XCTAssertTrue(userContent.contains("<asr_transcript>明天开会</asr_transcript>"))

      let responseJSON = "{\"choices\": [{\"message\": {\"content\": \"明天开会。\"}}]}"
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(responseJSON.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(
      rawTranscript: "明天开会",
      hotwords: ["小明", "张伟"],
      preContext: "关于下周日程，"
    )
    XCTAssertEqual(result, "明天开会。")
  }

  func testPromptAssemblyWithEmptyContextAndHotwords() async throws {
    let userPrompt = OwlVoicePolisher.buildUserPrompt(
      rawTranscript: "测试文本",
      hotwords: [],
      preContext: nil
    )
    XCTAssertTrue(userPrompt.contains("<preceding_context></preceding_context>"))
    XCTAssertTrue(userPrompt.contains("<personal_hotwords></personal_hotwords>"))
    XCTAssertTrue(userPrompt.contains("<asr_transcript>测试文本</asr_transcript>"))
  }

  func testSystemPromptInstructionsContainGuardrails() {
    let prompt = OwlVoicePolisher.defaultSystemPrompt
    XCTAssertTrue(prompt.contains("去除无意义口水词"))
    XCTAssertTrue(prompt.contains("<personal_hotwords>"))
    XCTAssertTrue(prompt.contains("<preceding_context>"))
    XCTAssertTrue(prompt.contains("自动补全并规范缺失的中文标点符号"))
    XCTAssertTrue(prompt.contains("严格保真原意"))
    XCTAssertTrue(prompt.contains("严禁回答问题"))
    XCTAssertTrue(prompt.contains("绝不包裹任何 XML 标签或 Markdown 代码块"))
  }

  // MARK: - 2. Timeout Architecture & Cancellation

  func testHardTimeoutCancellationAndImmediateFallback() async throws {
    let stubTransport = OwlStubVoiceTransport { _ in
      // Simulate slow response > timeout
      Thread.sleep(forTimeInterval: 0.3) // 300ms
      let responseJSON = "{\"choices\": [{\"message\": {\"content\": \"超时润色结果\"}}]}"
      let response = HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(responseJSON.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      requestTimeout: 0.05, // 50ms timeout
      apiKeyProvider: { "mock-key" }
    )

    let start = Date()
    let result = try await polisher.polish(rawTranscript: "原始未润色语音文本")
    let elapsed = Date().timeIntervalSince(start)

    // Must return rawTranscript immediately upon 50ms timeout
    XCTAssertEqual(result, "原始未润色语音文本")
    XCTAssertLessThan(elapsed, 0.35, "Timeout must fire promptly without blocking")
  }

  func testZeroRetriesAttemptedOnTimeout() async throws {
    let stubTransport = OwlStubVoiceTransport { _ in
      Thread.sleep(forTimeInterval: 0.2)
      throw OwlVoiceError.networkTimeout
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      requestTimeout: 0.05,
      apiKeyProvider: { "mock-key" }
    )

    _ = try await polisher.polish(rawTranscript: "测试单次超时")
    XCTAssertEqual(stubTransport.recordedRequests.count, 1, "Must never perform retries upon timeout")
  }

  // MARK: - 3. Graceful Degradation Matrix (Zero Text Loss)

  func testDegradationCondition1DisabledSettings() async throws {
    let stubTransport = OwlStubVoiceTransport()
    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" },
      isEnabledChecker: { false } // Disabled in settings
    )

    let result = try await polisher.polish(rawTranscript: "设置关闭语音文本")
    XCTAssertEqual(result, "设置关闭语音文本")
    XCTAssertEqual(stubTransport.recordedRequests.count, 0, "Must make zero network requests when disabled")
  }

  func testDegradationCondition2AMissingAPIKey() async throws {
    let stubTransport = OwlStubVoiceTransport()
    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { nil } // No key configured
    )

    let result = try await polisher.polish(rawTranscript: "无凭据语音文本")
    XCTAssertEqual(result, "无凭据语音文本")
    XCTAssertEqual(stubTransport.recordedRequests.count, 0, "Must not make network requests without API key")
  }

  func testDegradationCondition2BInvalidToken401() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let errorBody = "{\"error\": {\"message\": \"Authentication Fails: Invalid API Key\"}}"
      let response = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
      return (Data(errorBody.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "invalid-token" }
    )

    let result = try await polisher.polish(rawTranscript: "无效令牌语音文本")
    XCTAssertEqual(result, "无效令牌语音文本")
  }

  func testDegradationCondition4AHTTP502BadGatewayHTML() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let htmlBody = "<html><body>502 Bad Gateway</body></html>"
      let response = HTTPURLResponse(url: req.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
      return (Data(htmlBody.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "网关故障语音文本")
    XCTAssertEqual(result, "网关故障语音文本")
  }

  func testDegradationCondition4BHTTP503ServiceUnavailable() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"message\": \"Service Temporarily Unavailable\"}"
      let response = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "服务不可用语音文本")
    XCTAssertEqual(result, "服务不可用语音文本")
  }

  func testDegradationCondition4CHTTP429RateLimit() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"error\": \"Rate limit exceeded\"}"
      let response = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "限流降级语音文本")
    XCTAssertEqual(result, "限流降级语音文本")
  }

  func testDegradationCondition5AOfflineURLError() async throws {
    let stubTransport = OwlStubVoiceTransport { _ in
      throw URLError(.notConnectedToInternet)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "离线降级语音文本")
    XCTAssertEqual(result, "离线降级语音文本")
  }

  func testDegradationCondition5BConnectionSeveredMidUpload() async throws {
    let stubTransport = OwlStubVoiceTransport { _ in
      throw URLError(.networkConnectionLost)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "网络断开降级语音文本")
    XCTAssertEqual(result, "网络断开降级语音文本")
  }

  // MARK: - 4. Anti-Hallucination & Sanitization Guardrails

  func testAntiHallucinationEmptyResponseFallback() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"choices\": [{\"message\": {\"content\": \"   \\n\\t  \"}}]}"
      let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "真实语音内容")
    XCTAssertEqual(result, "真实语音内容", "Empty or whitespace response must fall back to raw transcript")
  }

  func testAntiHallucinationExcessiveLengthFallback() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      // 120-character essay for 4-character input
      let longEssay = String(repeating: "这是一段大模型幻觉生成的长篇大论回答", count: 8)
      let json = "{\"choices\": [{\"message\": {\"content\": \"\(longEssay)\"}}]}"
      let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "今天开会")
    XCTAssertEqual(result, "今天开会", "Excessive narrative expansion must fall back to raw transcript")
  }

  func testAntiHallucinationExactBoundaries() {
    // Formula: max(raw.count * 2 + 15, 30)

    // L_raw = 1 ("啊"): max(17, 30) = 30
    XCTAssertTrue(OwlVoicePolisher.validate(raw: "啊", polished: String(repeating: "字", count: 30)))
    XCTAssertFalse(OwlVoicePolisher.validate(raw: "啊", polished: String(repeating: "字", count: 31)))

    // L_raw = 7: max(29, 30) = 30
    XCTAssertTrue(OwlVoicePolisher.validate(raw: "今天下午开会吗", polished: String(repeating: "字", count: 30)))
    XCTAssertFalse(OwlVoicePolisher.validate(raw: "今天下午开会吗", polished: String(repeating: "字", count: 31)))

    // L_raw = 8: max(31, 30) = 31
    XCTAssertTrue(OwlVoicePolisher.validate(raw: "今天下午去开会吗", polished: String(repeating: "字", count: 31)))
    XCTAssertFalse(OwlVoicePolisher.validate(raw: "今天下午去开会吗", polished: String(repeating: "字", count: 32)))

    // L_raw = 10: max(35, 30) = 35
    XCTAssertTrue(OwlVoicePolisher.validate(raw: "那个就是今天天气很好", polished: String(repeating: "字", count: 35)))
    XCTAssertFalse(OwlVoicePolisher.validate(raw: "那个就是今天天气很好", polished: String(repeating: "字", count: 36)))
  }

  func testSanitizationStripsXMLWrapperTagsAndPreamble() {
    // XML Tag strip
    let tagEcho = "<asr_transcript>今天天气很好。</asr_transcript>"
    XCTAssertEqual(OwlVoicePolisher.sanitize(polished: tagEcho), "今天天气很好。")

    // Preamble strip
    let preambleEcho = "润色结果：今天天气很好。"
    XCTAssertEqual(OwlVoicePolisher.sanitize(polished: preambleEcho), "今天天气很好。")

    // Code fence strip
    let fencedEcho = "```\n今天天气很好。\n```"
    XCTAssertEqual(OwlVoicePolisher.sanitize(polished: fencedEcho), "今天天气很好。")
  }

  // MARK: - 5. Cancellation Behavior (Esc Key)

  func testTaskCancellationRethrowsCancellationError() async throws {
    let stubTransport = OwlStubVoiceTransport { _ in
      Thread.sleep(forTimeInterval: 0.2)
      let json = "{\"choices\": [{\"message\": {\"content\": \"测试\"}}]}"
      let resp = HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let task = Task {
      try await polisher.polish(rawTranscript: "取消测试文本")
    }

    // Cancel task immediately
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Must rethrow CancellationError when task is cancelled")
    } catch is CancellationError {
      // Expected: CancellationError rethrown
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  // MARK: - 6. Direct polishWithTimeout Throws

  func testPolishWithTimeoutDirectThrows() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let response = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
      return (Data("{\"error\": \"Unauthorized\"}".utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "bad-key" }
    )

    do {
      _ = try await polisher.polishWithTimeout(rawTranscript: "测试报错抛出")
      XCTFail("polishWithTimeout must throw on 401")
    } catch let error as OwlVoiceError {
      if case .invalidToken(let status, _) = error {
        XCTAssertEqual(status, 401)
      } else {
        XCTFail("Expected .invalidToken, got \(error)")
      }
    }

    // Missing key
    let noKeyPolisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { nil }
    )
    do {
      _ = try await noKeyPolisher.polishWithTimeout(rawTranscript: "测试无Key抛出")
      XCTFail("polishWithTimeout must throw missingAPIKey")
    } catch let error as OwlVoiceError {
      XCTAssertEqual(error, .missingAPIKey)
    }

    // Echoed credential in 401 error body is masked
    let echoedValue = "echoed-fixture-value"
    let echoingTransport = OwlStubVoiceTransport { req in
      let response = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
      return (Data("{\"error\": {\"message\": \"Invalid credential \(echoedValue)\"}}".utf8), response)
    }
    let echoingPolisher = OwlVoicePolisher(
      transport: echoingTransport,
      apiKeyProvider: { echoedValue }
    )
    do {
      _ = try await echoingPolisher.polishWithTimeout(rawTranscript: "测试Key掩码")
      XCTFail("polishWithTimeout must throw on 401")
    } catch let error as OwlVoiceError {
      if case .invalidToken(let status, let message) = error {
        XCTAssertEqual(status, 401)
        XCTAssertFalse(message?.contains(echoedValue) ?? true, "Echoed credential must be masked")
      } else {
        XCTFail("Expected .invalidToken, got \(error)")
      }
    }
  }

  // MARK: - 7. Challenger Adversarial Stress Tests

  func testStressTimeoutRace4SecondsWith10SecondDelayTransport() async throws {
    let transport = AsyncDelayedVoiceTransport(delaySecs: 10.0)
    let polisher = OwlVoicePolisher(
      transport: transport,
      requestTimeout: 4.0,
      apiKeyProvider: { "mock-key" }
    )

    let start = Date()
    let result = try await polisher.polish(rawTranscript: "延迟超时降级测试文本")
    let elapsed = Date().timeIntervalSince(start)

    // Must return raw transcript on timeout
    XCTAssertEqual(result, "延迟超时降级测试文本")
    // Must abort at ~4.0s without hanging for 10s
    XCTAssertGreaterThanOrEqual(elapsed, 3.8, "Must wait until 4.0s timeout")
    XCTAssertLessThan(elapsed, 5.5, "Must abort around 4.0s and never hang for 10s")
    // Must cancel in-flight network task
    XCTAssertTrue(transport.wasCancelled, "In-flight task must be cancelled by Task.cancel()")
    // Must perform 0 retries (exactly 1 request initiated)
    XCTAssertEqual(transport.sendCount, 1, "Must perform 0 retries")
  }

  func testStressTimeoutRaceFastCancellation() async throws {
    let transport = AsyncDelayedVoiceTransport(delaySecs: 5.0)
    let polisher = OwlVoicePolisher(
      transport: transport,
      requestTimeout: 0.05, // 50ms fast timeout
      apiKeyProvider: { "mock-key" }
    )

    let start = Date()
    let result = try await polisher.polish(rawTranscript: "快速超时测试")
    let elapsed = Date().timeIntervalSince(start)

    XCTAssertEqual(result, "快速超时测试")
    XCTAssertLessThan(elapsed, 0.5, "Must abort promptly around 50ms")
    XCTAssertTrue(transport.wasCancelled, "In-flight task must be cancelled")
    XCTAssertEqual(transport.sendCount, 1, "Must perform 0 retries")
  }

  func testStressDegradationHTTP403Forbidden() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let response = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
      return (Data("{\"error\": {\"message\": \"Forbidden\"}}".utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "forbidden-key" }
    )

    let result = try await polisher.polish(rawTranscript: "403降级测试")
    XCTAssertEqual(result, "403降级测试")
    XCTAssertEqual(stubTransport.recordedRequests.count, 1)
  }

  func testStressDegradationHTTP500PlainTextBody() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let response = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
      return (Data("Internal Server Error 500".utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "500纯文本降级测试")
    XCTAssertEqual(result, "500纯文本降级测试", "Must return raw transcript on HTTP 500 without crashing")
  }

  func testStressDegradationHTTP500EmptyBody() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let response = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
      return (Data(), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "500空包体降级测试")
    XCTAssertEqual(result, "500空包体降级测试")
  }

  func testStressDegradationHTTP500BinaryJunkData() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let response = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
      return (Data([0x00, 0xFF, 0xFE, 0x12, 0x89, 0xAB]), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "500二进制垃圾数据降级测试")
    XCTAssertEqual(result, "500二进制垃圾数据降级测试")
  }

  func testStressDegradationNetworkDNSFailureAndTimeout() async throws {
    let dnsFailTransport = OwlStubVoiceTransport { _ in
      throw URLError(.cannotFindHost)
    }
    let polisher1 = OwlVoicePolisher(
      transport: dnsFailTransport,
      apiKeyProvider: { "mock-key" }
    )
    let res1 = try await polisher1.polish(rawTranscript: "DNS错误降级")
    XCTAssertEqual(res1, "DNS错误降级")

    let timeoutTransport = OwlStubVoiceTransport { _ in
      throw URLError(.timedOut)
    }
    let polisher2 = OwlVoicePolisher(
      transport: timeoutTransport,
      apiKeyProvider: { "mock-key" }
    )
    let res2 = try await polisher2.polish(rawTranscript: "URLError超时降级")
    XCTAssertEqual(res2, "URLError超时降级")
  }

  func testStressAntiHallucinationPureWhitespaceAndEmpty() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"choices\": [{\"message\": {\"content\": \"   \\n\\t\\r  \"}}]}"
      let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "空白测试文本")
    XCTAssertEqual(result, "空白测试文本", "Pure whitespace must fall back to raw transcript")
  }

  func testStressAntiHallucinationExactBoundaries() {
    // Formula: B = max(2 * L_raw + 15, 30)
    // 1. L_raw = 1 ("啊"): 2(1) + 15 = 17 <= 30 => B = 30
    XCTAssertTrue(OwlVoicePolisher.validate(raw: "啊", polished: String(repeating: "字", count: 30)))
    XCTAssertFalse(OwlVoicePolisher.validate(raw: "啊", polished: String(repeating: "字", count: 31)))

    // 2. L_raw = 7 ("今天下午开会吗"): 2(7) + 15 = 29 <= 30 => B = 30
    XCTAssertTrue(OwlVoicePolisher.validate(raw: "今天下午开会吗", polished: String(repeating: "字", count: 30)))
    XCTAssertFalse(OwlVoicePolisher.validate(raw: "今天下午开会吗", polished: String(repeating: "字", count: 31)))

    // 3. L_raw = 10 ("那个就是今天天气很好"): 2(10) + 15 = 35 >= 30 => B = 35
    XCTAssertTrue(OwlVoicePolisher.validate(raw: "那个就是今天天气很好", polished: String(repeating: "字", count: 35)))
    XCTAssertFalse(OwlVoicePolisher.validate(raw: "那个就是今天天气很好", polished: String(repeating: "字", count: 36)))
  }

  func testStressConversationalExpansionAttack() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      // 100-character conversational answering to a 5-character question
      let answer = "关于今天下午的会议安排，我们将在第二会议室准时举行，请各位准时参加并带好相关的汇报材料与笔记本电脑，谢谢配合。"
      let json = "{\"choices\": [{\"message\": {\"content\": \"\(answer)\"}}]}"
      let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "下午开会吗")
    XCTAssertEqual(result, "下午开会吗", "Conversational answer exceeding boundary must be rejected and fall back to raw transcript")
  }

  func testStressXMLTagLeakingASRTranscript() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"choices\": [{\"message\": {\"content\": \"<asr_transcript>今天天气很好。</asr_transcript>\"}}]}"
      let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let result = try await polisher.polish(rawTranscript: "今天天气很好")
    XCTAssertEqual(result, "今天天气很好。", "Must strip <asr_transcript> tags")
  }

  func testStressXMLTagLeakingRawTranscriptProbe() async throws {
    let sanitized = OwlVoicePolisher.sanitize(polished: "<raw_transcript>你好</raw_transcript>")
    let asrSanitized = OwlVoicePolisher.sanitize(polished: "<asr_transcript>你好</asr_transcript>")
    XCTAssertEqual(asrSanitized, "你好", "<asr_transcript> is stripped")
    XCTAssertEqual(sanitized, "你好", "<raw_transcript> must be stripped")
  }

  func testStressXMLTagLeakingRawTranscriptInPolish() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let leakedContent = "<raw_transcript>今天下午我们在第一会议室讨论产品发布方案。</raw_transcript>"
      let json = "{\"choices\": [{\"message\": {\"content\": \"\(leakedContent)\"}}]}"
      let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), response)
    }

    let polisher = OwlVoicePolisher(
      transport: stubTransport,
      apiKeyProvider: { "mock-key" }
    )

    let raw = "今天下午我们在第一会议室讨论产品发布方案"
    let result = try await polisher.polish(rawTranscript: raw)
    XCTAssertEqual(result, "今天下午我们在第一会议室讨论产品发布方案。", "Leaked <raw_transcript> XML tags must be stripped before delivery")
  }
}

// MARK: - Challenger Helper Transport

final class AsyncDelayedVoiceTransport: OwlVoiceNetworkTransport, @unchecked Sendable {
  let delaySecs: TimeInterval
  private let lock = NSLock()
  private(set) var sendCount = 0
  private(set) var wasCancelled = false

  init(delaySecs: TimeInterval) {
    self.delaySecs = delaySecs
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    lock.lock()
    sendCount += 1
    lock.unlock()

    do {
      try await Task.sleep(nanoseconds: UInt64(delaySecs * 1_000_000_000))
      let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = "{\"choices\":[{\"message\":{\"content\":\"延迟润色结果\"}}]}".data(using: .utf8)!
      return (body, resp)
    } catch is CancellationError {
      lock.lock()
      wasCancelled = true
      lock.unlock()
      throw CancellationError()
    }
  }
}

