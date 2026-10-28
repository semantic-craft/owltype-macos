//
//  OwlLLMGateway.swift
//  猫头鹰输入法 (Owltype) — the one way a non-streaming AI skill reaches a model
//
//  Selection polish and structured drafting used to fork Chat vs `/responses`, build the request,
//  check the status, parse two reply shells and record usage each on their own. That sequence —
//  and every provider quirk inside it — now lives here, above a transport seam, so one table of
//  recorded requests covers every caller (see `OwlLLMGatewayTests`).
//
//  Never reachable from the input hot path: `scripts/check-ai-off-hot-path.sh` fails the gate if
//  `sources/Controller` or `sources/Engine` names this file's types or `URLSession`.
//

import Foundation

/// What a provider profile's wire supports, resolved once from `(providerID, model, host)`.
/// Callers ask this value instead of re-deriving provider identity.
struct OwlProviderCapabilities {
  /// The `/responses` dialect, or nil when the provider stays on Chat Completions.
  let dialect: OwlResponsesDialect?
  /// The provider's lowest-latency thinking fields for Chat requests (`OwlThinkingControl`).
  let thinkingOff: OwlThinkingControl.Fields
  private let model: String

  /// `endpoint` is nil for a request builder that has no URL (the Chat payload) or a form without
  /// one; provider id then decides alone, exactly as the host fallback would with no host.
  init(providerID: String, model: String, endpoint: URL? = nil) {
    self.dialect = OwlResponsesWire.dialect(providerID: providerID, model: model, endpoint: endpoint)
    self.thinkingOff = OwlThinkingControl.offFields(providerID: providerID, model: model)
    self.model = model
  }

  init(routing: OwlCloudRouting) {
    self.init(providerID: routing.providerID, model: routing.model, endpoint: routing.endpoint)
  }

  /// Chat `response_format: json_object`. MiniMax documents no JSON mode; keep prompt + local
  /// validation as the contract there.
  var sendsChatJSONMode: Bool { thinkingOff.reasoningSplit == nil }

  /// The sampling temperature to send, or nil when the model rejects sampling controls.
  func temperature(_ value: Double) -> Double? {
    OwlChatSamplingControl.temperature(value, model: model)
  }
}

/// Why an AI skill is calling. It fixes the timeout and retry policy, so callers never pass them.
enum OwlLLMCallPurpose {
  /// 划词润色：用户盯着菜单等，8 秒内要有结果；瞬时故障重试一次。
  case interactiveRewrite
  /// 提示词优化 / 任务书：要生成一整段结构化文本，实测百炼 qwen3.6-flash 生成约 1.3KB 中文要
  /// 约 20 秒，8 秒必然掐断。用户已看到「正在优化…」，等十几秒可以接受、卡死不行，故 60 秒硬上限；
  /// 不重试（重来一遍的等待比报错更糟）。
  case drafting
  /// 「验证连通性」：一次真实请求，20 秒；不重试 —— 用户要的是这一发的真实结论。
  case connectivityProbe

  var timeout: TimeInterval {
    switch self {
    case .interactiveRewrite: return OwlCloudPreferences.requestTimeout
    case .drafting: return 60
    case .connectivityProbe: return 20
    }
  }

  var maxAttempts: Int {
    switch self {
    case .interactiveRewrite: return OwlCloudRetry.maxAttempts
    case .drafting, .connectivityProbe: return 1
    }
  }
}

/// The seam under the gateway: send one request, return the bytes and the response.
/// Adapters: `OwlURLSessionTransport` in production, a recording fake in tests.
protocol OwlLLMTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct OwlURLSessionTransport: OwlLLMTransport {
  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }
}

/// One JSON-mode completion for a non-streaming AI skill. Resolves provider capabilities, picks the
/// Chat or `/responses` wire, applies the purpose's timeout and retry, parses either reply shell and
/// records usage telemetry — model name and token counts only, never text.
struct OwlLLMGateway: Sendable {
  let transport: OwlLLMTransport

  init(transport: OwlLLMTransport = OwlURLSessionTransport()) {
    self.transport = transport
  }

  /// Returns the model's reply text. `payload` is the skill's Chat-shaped request; the Responses
  /// providers reuse its messages and temperature. Cancelling the calling task cancels the request
  /// and any pending retry.
  func complete(
    _ payload: OwlDeepSeekChatRequest,
    routing: OwlCloudRouting,
    apiKey: String,
    purpose: OwlLLMCallPurpose
  ) async throws -> String {
    var lastError: Error = OwlCloudRequestError.emptyResponse
    for attempt in 0..<purpose.maxAttempts {
      do {
        return try await completeOnce(payload, routing: routing, apiKey: apiKey, purpose: purpose)
      } catch {
        lastError = error
        guard attempt + 1 < purpose.maxAttempts, OwlCloudRetry.isRetryable(error) else { throw error }
        try await Task.sleep(nanoseconds: OwlCloudRetry.backoffNanoseconds)
      }
    }
    throw lastError
  }

  private func completeOnce(
    _ payload: OwlDeepSeekChatRequest,
    routing: OwlCloudRouting,
    apiKey: String,
    purpose: OwlLLMCallPurpose
  ) async throws -> String {
    let dialect = OwlProviderCapabilities(routing: routing).dialect
    let request: URLRequest
    if let dialect {
      request = try OwlResponsesWire.request(
        endpoint: routing.endpoint,
        model: routing.model,
        messages: payload.messages,
        apiKey: apiKey,
        authHeaderStyle: routing.authHeaderStyle,
        dialect: dialect,
        stream: false,
        webSearch: false,
        // Mirrors the Chat payload's `response_format`. Only the `.deepseek` dialect writes
        // `text.format`; Qwen / 豆包 never carried it on Responses (see `OwlResponsesWire.body`).
        jsonObject: true,
        temperature: payload.temperature,
        timeout: purpose.timeout)
    } else {
      var chatRequest = URLRequest(url: routing.endpoint)
      chatRequest.httpMethod = "POST"
      chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      routing.authHeaderStyle.apply(to: &chatRequest, apiKey: apiKey)
      chatRequest.timeoutInterval = purpose.timeout
      chatRequest.httpBody = try JSONEncoder().encode(payload)
      request = chatRequest
    }

    let (data, response) = try await transport.send(request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw OwlCloudRequestError.badHTTPStatus(http.statusCode)
    }

    if dialect != nil {
      let decoded = try OwlResponsesWire.parse(data)
      if let usage = decoded.usage {
        OwlCloudUsageTelemetry.record(OwlCloudUsageSnapshot(
          model: decoded.model ?? routing.model,
          completionTokens: usage.outputTokens,
          promptTokens: usage.inputTokens,
          promptCacheHitTokens: usage.cachedTokens,
          promptCacheMissTokens: max(0, usage.inputTokens - usage.cachedTokens),
          totalTokens: usage.totalTokens))
      }
      guard !decoded.text.isEmpty else { throw OwlCloudRequestError.emptyResponse }
      return decoded.text
    }

    let decoded = try JSONDecoder().decode(OwlDeepSeekClient.Response.self, from: data)
    if let usage = decoded.usage {
      OwlCloudUsageTelemetry.record(OwlCloudUsageSnapshot(
        model: decoded.model ?? routing.model,
        completionTokens: usage.completionTokens,
        promptTokens: usage.promptTokens,
        promptCacheHitTokens: usage.promptCacheHitTokens ?? 0,
        promptCacheMissTokens: usage.promptCacheMissTokens ?? 0,
        totalTokens: usage.totalTokens))
    }
    guard let content = decoded.choices.first?.message.content else {
      throw OwlCloudRequestError.emptyResponse
    }
    return content
  }
}
