//
//  OwlServerErrorCopyTests.swift
//  OwltypeTests — what a refused cloud request says to the user
//
//  Offline. The server's raw message never reaches a cursor-side surface; a known error code maps
//  to one Chinese sentence, an unknown one falls back to the status copy pinned in
//  `CandidateStoreTests.testDeepSeekStatusMessagesAreSpecific`.
//

import XCTest
@testable import Owltype

@MainActor
final class OwlServerErrorCopyTests: XCTestCase {
  private static func body(_ json: String) -> Data { Data(json.utf8) }

  // MARK: - Parsing

  func testParsesEachDocumentedBodyShape() {
    XCTAssertEqual(
      OwlServerErrorDetail.parse(Self.body(
        #"{"error":{"message":"Incorrect API key provided: sk-ab***cd","type":"invalid_request_error","code":"invalid_api_key"}}"#)),
      OwlServerErrorDetail(code: "invalid_api_key", message: "Incorrect API key provided: sk-ab***cd"))
    // 百炼 native shape: code and message at the top level.
    XCTAssertEqual(
      OwlServerErrorDetail.parse(Self.body(#"{"code":"Arrearage","message":"Access denied.","request_id":"x"}"#)),
      OwlServerErrorDetail(code: "Arrearage", message: "Access denied."))
    // A numeric code (the HTTP status again) gives way to the string status; an array is unwrapped.
    XCTAssertEqual(
      OwlServerErrorDetail.parse(Self.body(
        #"[{"error":{"code":429,"message":"Resource exhausted","status":"RESOURCE_EXHAUSTED"}}]"#)),
      OwlServerErrorDetail(code: "RESOURCE_EXHAUSTED", message: "Resource exhausted"))
    // 方舟: no code, only type.
    XCTAssertEqual(
      OwlServerErrorDetail.parse(Self.body(#"{"error":{"type":"NotFound","message":"m"}}"#))?.code, "NotFound")
    XCTAssertNil(OwlServerErrorDetail.parse(Self.body("<html>502 Bad Gateway</html>")))
    XCTAssertNil(OwlServerErrorDetail.parse(Self.body(#"{"error":{}}"#)))
    XCTAssertNil(OwlServerErrorDetail.parse(Data()))
  }

  func testSanitizedMessageMasksKeysAndStaysShort() {
    let detail = OwlServerErrorDetail(
      code: nil, message: "Incorrect key sk-placeholder-placeholder and\n\n the-profile-placeholder here")
    let shown = detail.sanitized(removing: "the-profile-placeholder")
    XCTAssertFalse(shown.contains("placeholder"))
    XCTAssertFalse(shown.contains("the-profile-placeholder"))
    XCTAssertEqual(shown, "Incorrect key *** and *** here")

    let long = OwlServerErrorDetail(code: nil, message: String(repeating: "长", count: 400))
    XCTAssertEqual(long.sanitized(removing: "").count, 161, "160 characters plus the ellipsis")
  }

  // MARK: - The one Chinese mapper

  func testKnownCodesMapToOneSentenceOnBothErrorSpaces() {
    let cases: [(Int, String, String)] = [
      (401, "InvalidApiKey", "云端 AI 的 API Key 无效"),
      (401, "AuthenticationError", "云端 AI 的 API Key 无效"),
      (404, "model_not_found", "云端 AI 不提供这个型号，检查供应商档案里的型号"),
      (404, "ModelNotOpen", "云端 AI 不提供这个型号，检查供应商档案里的型号"),
      (400, "Arrearage", "云端 AI 账户余额不足"),
      (403, "AccountOverdueError", "云端 AI 账户余额不足"),
      (429, "QuotaExceeded", "云端 AI 的用量额度已用完"),
      (429, "RateLimitExceeded.EndpointRPMExceeded", "云端 AI 请求过于频繁，请稍后再试"),
      (400, "data_inspection_failed", "云端 AI 的内容审核拦下了这次请求"),
      (400, "SensitiveContentDetected", "云端 AI 的内容审核拦下了这次请求"),
    ]
    for (status, code, expected) in cases {
      let detail = OwlServerErrorDetail(code: code, message: "raw server text")
      XCTAssertEqual(
        OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(status, detail: detail)), expected, code)
      XCTAssertEqual(
        OwlCloudPreferences.message(for: OwlStreamingError.badHTTPStatus(status, detail: detail)), expected, code)
      XCTAssertFalse(
        OwlCloudPreferences.message(for: OwlStreamingError.badHTTPStatus(status, detail: detail))
          .contains("raw server text"), "raw text never reaches the cursor")
    }
  }

  func testUnknownCodeFallsBackToTheStatusCopy() {
    let detail = OwlServerErrorDetail(code: "something_new", message: "whatever")
    XCTAssertEqual(
      OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(402, detail: detail)), "云端 AI 账户余额不足")
    XCTAssertEqual(
      OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(403)), "云端 AI 拒绝访问，检查 API Key 的权限")
    XCTAssertEqual(
      OwlCloudPreferences.message(for: OwlCloudRequestError.badHTTPStatus(404)), "云端 AI 找不到这个型号或端点")
  }

  /// 任意提问 used to show the generic sentence for every refusal: streaming errors never matched.
  func testAskRefusalsNowSayWhatIsWrong() {
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlStreamingError.badHTTPStatus(401)), "云端 AI 的 API Key 无效")
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlStreamingError.badHTTPStatus(402)), "云端 AI 账户余额不足")
    XCTAssertEqual(OwlCloudPreferences.message(for: OwlStreamingError.emptyResponse), "云端 AI 请求失败")
    XCTAssertEqual(OwlCloudPreferences.message(for: URLError(.timedOut)), "云端 AI 请求失败")
  }

  // MARK: - Where the detail comes from

  func testGatewayCarriesTheBodyDetail() async throws {
    let routing = OwlCloudRouting(
      providerID: "openai", endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o", secretName: nil, authHeaderStyle: .bearer)
    let transport = OwlRecordingTransport.replying(
      Self.body(#"{"error":{"code":"credit_balance_exhausted","message":"no credit"}}"#), status: 429)
    do {
      _ = try await OwlLLMGateway(transport: transport).complete(
        try OwlSelectionPolish.chatRequest(for: "他撤销了合同", model: routing.model, providerID: routing.providerID),
        routing: routing, apiKey: "sk-test", purpose: .interactiveRewrite)
      XCTFail("429 must surface")
    } catch {
      XCTAssertEqual(OwlCloudPreferences.message(for: error), "云端 AI 账户余额不足")
    }
    XCTAssertEqual(transport.requests.count, 1, "a 429 is still not retried")
  }

  func testStreamingClientsReadTheRefusalBody() async throws {
    let routing = OwlCloudRouting(
      providerID: "qwen",
      endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
      model: "qwen3.7-plus", secretName: nil, authHeaderStyle: .bearer)
    let transport = OwlRecordingTransport.replying(
      Self.body(#"{"error":{"code":"invalid_api_key","message":"Incorrect API key"}}"#), status: 401)
    do {
      for try await _ in OwlLLMGateway(transport: transport)
        .stream(messages: [], routing: routing, apiKey: "sk-test") {}
      XCTFail("401 must surface")
    } catch let error as OwlStreamingError {
      XCTAssertEqual(
        error, .badHTTPStatus(401, detail: OwlServerErrorDetail(code: "invalid_api_key", message: "Incorrect API key")))
    }
  }

  // MARK: - Settings connectivity probe

  func testProbeShowsTheSanitizedServerTextAndTheCodeHint() {
    let response = HTTPURLResponse(
      url: URL(string: "https://ark.cn-beijing.volces.com/api/v3/responses")!,
      statusCode: 404, httpVersion: nil, headerFields: nil)
    let outcome = OwlProviderConnectivityCheck.outcome(
      data: Self.body(#"{"error":{"code":"ModelNotOpen","message":"Model not activated for ak-placeholder-placeholder"}}"#),
      response: response, latencyMS: 10, apiKey: "ak-placeholder-placeholder")
    XCTAssertEqual(
      outcome,
      .rejected(status: 404, message: "Model not activated for ***", code: "ModelNotOpen"))
    XCTAssertEqual(
      outcome.statusText,
      "对方拒绝了这次请求，HTTP 404（云端 AI 不提供这个型号，检查供应商档案里的型号）：Model not activated for ***")
  }
}
