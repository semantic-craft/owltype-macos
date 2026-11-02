//
//  OwlVoiceDeepSeekPolisher.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

public final class OwlVoiceDeepSeekPolisher: OwlVoicePolishServiceProtocol, @unchecked Sendable {
  public static let shared = OwlVoiceDeepSeekPolisher()

  public let endpoint: URL
  public let model: String
  public let temperature: Double
  public let transport: OwlVoiceNetworkTransport
  public var requestTimeout: TimeInterval
  public var timeout: TimeInterval {
    get { requestTimeout }
    set { requestTimeout = newValue }
  }
  public let apiKeyProvider: @Sendable () throws -> String?
  public var isEnabledChecker: @Sendable () -> Bool

  public static let defaultSystemPrompt = """
  你是一个专业的中文语音输入后处理与润色引擎。你的任务是对语音转写的原始文本进行口语清理与纠偏，要求：
  1. 去除无意义口水词、停顿语气词（如“嗯”、“啊”、“那个”、“就是说”、“然后”、“这个”、“呃”）及口吃重复词。
  2. 根据 <personal_hotwords> 提供的个人专名热词列表与 <preceding_context> 光标前文语境，纠正同音或音近的错别字、专有名词、人名与产品名。
  3. 自动补全并规范缺失的中文标点符号（句号、逗号、问号、感叹号等），确保输出符合书面中文标点规范。
  4. 严格保真原意，切勿改写语气、添加额外主观观点或无端改动未读错的字句。
  5. 严禁回答问题、严禁续写解释、严禁输出对话式回复（如“好的”、“润色如下”等客套话），只输出最终润色完成的纯文本，绝不包裹任何 XML 标签或 Markdown 代码块。
  """

  public init(
    endpoint: URL = URL(string: "https://api.deepseek.com/chat/completions")!,
    model: String = "deepseek-chat",
    temperature: Double = 0.1,
    transport: OwlVoiceNetworkTransport = OwlURLSessionVoiceTransport(),
    requestTimeout: TimeInterval = 4.0,
    apiKeyProvider: (@Sendable () throws -> String?)? = nil,
    isEnabledChecker: (@Sendable () -> Bool)? = nil
  ) {
    self.endpoint = endpoint
    self.model = model
    self.temperature = temperature
    self.transport = transport
    self.requestTimeout = requestTimeout
    self.apiKeyProvider = apiKeyProvider ?? {
      if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !env.isEmpty {
        return env
      }
      return try OwlVoiceKeychain.readDeepSeekAPIKey()
    }
    self.isEnabledChecker = isEnabledChecker ?? { true }
  }

  // MARK: - Prompt Construction

  public static func buildUserPrompt(rawTranscript: String, hotwords: [String], preContext: String?) -> String {
    let contextClean = preContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let contextTag = "<preceding_context>\(contextClean)</preceding_context>"
    let hotwordsClean = hotwords.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let hotwordsTag = "<personal_hotwords>\(hotwordsClean.joined(separator: "，"))</personal_hotwords>"
    let transcriptTag = "<asr_transcript>\(rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines))</asr_transcript>"
    return "\(contextTag)\n\(hotwordsTag)\n\(transcriptTag)"
  }

  // MARK: - Core Polishing with 100% Zero-Text-Loss Degradation

  public func polish(
    rawTranscript: String,
    hotwords: [String] = [],
    preContext: String? = nil
  ) async throws -> String {
    try Task.checkCancellation()

    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return rawTranscript }
    guard isEnabledChecker() else { return rawTranscript }

    do {
      let rawResult = try await polishWithTimeout(rawTranscript: trimmed, hotwords: hotwords, preContext: preContext)
      try Task.checkCancellation()

      let cleaned = Self.sanitize(polished: rawResult)
      guard Self.validate(raw: trimmed, polished: cleaned) else {
        return trimmed // Anti-hallucination fallback
      }
      return cleaned
    } catch is CancellationError {
      throw CancellationError() // Must rethrow Esc cancellation
    } catch {
      // 100% Zero Text Loss Graceful Degradation
      return trimmed
    }
  }

  public func polish(rawTranscript: String) async throws -> String {
    try await polish(rawTranscript: rawTranscript, hotwords: [], preContext: nil)
  }

  public func polishWithFallback(
    rawTranscript: String,
    hotwords: [String] = [],
    preContext: String? = nil
  ) async -> (text: String, fallbackUsed: Bool) {
    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ("", false) }
    do {
      let polished = try await polishWithTimeout(rawTranscript: trimmed, hotwords: hotwords, preContext: preContext)
      let cleaned = Self.sanitize(polished: polished)
      if Self.validate(raw: trimmed, polished: cleaned) {
        return (cleaned, false)
      } else {
        return (trimmed, true)
      }
    } catch {
      return (trimmed, true)
    }
  }

  // MARK: - Structured Concurrency Timeout Race

  public func polishWithTimeout(
    rawTranscript: String,
    hotwords: [String] = [],
    preContext: String? = nil
  ) async throws -> String {
    try Task.checkCancellation()

    guard let apiKey = try apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
      throw OwlVoiceError.missingAPIKey
    }

    let timeoutSecs = self.timeout
    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        try await self.performNetworkRequest(
          rawTranscript: rawTranscript,
          hotwords: hotwords,
          preContext: preContext,
          apiKey: apiKey
        )
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeoutSecs * 1_000_000_000))
        try Task.checkCancellation()
        throw OwlVoiceError.networkTimeout
      }
      guard let first = try await group.next() else {
        throw OwlVoiceError.networkTimeout
      }
      group.cancelAll()
      return first
    }
  }

  // MARK: - Private Network Request

  public func performNetworkRequest(
    rawTranscript: String,
    hotwords: [String],
    preContext: String?,
    apiKey: String
  ) async throws -> String {
    let userPrompt = Self.buildUserPrompt(rawTranscript: rawTranscript, hotwords: hotwords, preContext: preContext)

    struct MessageDTO: Codable {
      let role: String
      let content: String
    }

    struct RequestDTO: Codable {
      let model: String
      let messages: [MessageDTO]
      let temperature: Double
      let stream: Bool
      let thinking: OwlDeepSeekThinking
    }

    let requestBody = RequestDTO(
      model: model,
      messages: [
        MessageDTO(role: "system", content: Self.defaultSystemPrompt),
        MessageDTO(role: "user", content: userPrompt)
      ],
      temperature: temperature,
      stream: false,
      thinking: .disabled
    )

    let encodedBody = try JSONEncoder().encode(requestBody)

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = requestTimeout
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = encodedBody

    let (data, response) = try await transport.send(request)
    try Task.checkCancellation()

    guard let httpResponse = response as? HTTPURLResponse else {
      throw OwlVoiceError.badHTTPStatus(status: 0, message: "非 HTTP 协议响应")
    }

    if httpResponse.statusCode != 200 {
      let errorMsg = Self.parseErrorMessage(from: data)
      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw OwlVoiceError.invalidToken(status: httpResponse.statusCode, message: errorMsg)
      } else {
        throw OwlVoiceError.badHTTPStatus(status: httpResponse.statusCode, message: errorMsg)
      }
    }

    struct ResponseDTO: Decodable {
      struct Choice: Decodable {
        struct Message: Decodable {
          let role: String?
          let content: String?
        }
        let message: Message
      }
      let choices: [Choice]
    }

    let decoded: ResponseDTO
    do {
      decoded = try JSONDecoder().decode(ResponseDTO.self, from: data)
    } catch {
      throw OwlVoiceError.decodingError(error.localizedDescription)
    }

    guard let choice = decoded.choices.first, let content = choice.message.content else {
      throw OwlVoiceError.emptyTranscript
    }

    return content
  }

  // MARK: - Anti-Hallucination & Sanitization

  public static func validate(raw: String, polished: String) -> Bool {
    let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let maxAllowed = max(raw.count * 2 + 15, 30)
    return trimmed.count <= maxAllowed
  }

  public static func sanitize(polished: String) -> String {
    var text = polished.trimmingCharacters(in: .whitespacesAndNewlines)

    // Strip markdown code fences if wrapped in ```
    if text.hasPrefix("```") {
      let lines = text.components(separatedBy: .newlines)
      let filtered = lines.filter { !$0.hasPrefix("```") }
      text = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Strip common conversational preambles
    let prefixesToStrip = [
      "润色后：", "润色结果：", "润色：", "修改后：", "修改结果：",
      "以下是润色后的文本：", "以下是润色结果：", "优化后："
    ]
    for prefix in prefixesToStrip {
      if text.hasPrefix(prefix) {
        text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    // Strip echoed XML tags
    let xmlTagPairs = [
      ("<asr_transcript>", "</asr_transcript>"),
      ("<raw_transcript>", "</raw_transcript>")
    ]
    for (opening, closing) in xmlTagPairs {
      if text.hasPrefix(opening) && text.hasSuffix(closing) {
        text = String(text.dropFirst(opening.count).dropLast(closing.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        if text.hasPrefix(opening) {
          text = String(text.dropFirst(opening.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasSuffix(closing) {
          text = String(text.dropLast(closing.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
    }
    for tag in ["<asr_transcript>", "</asr_transcript>", "<raw_transcript>", "</raw_transcript>"] {
      if text.contains(tag) {
        text = text.replacingOccurrences(of: tag, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func sanitizeAndVerify(rawTranscript: String, polishedOutput: String) -> String? {
    let cleaned = sanitize(polished: polishedOutput)
    guard validate(raw: rawTranscript, polished: cleaned) else {
      return nil
    }
    return cleaned
  }

  public static func parseErrorMessage(from data: Data) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
        return msg
      }
      if let msg = json["message"] as? String {
        return msg
      }
    }
    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
      return String(text.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return "未知错误"
  }
}

public typealias OwlVoiceDeepSeekPostProcessor = OwlVoiceDeepSeekPolisher
