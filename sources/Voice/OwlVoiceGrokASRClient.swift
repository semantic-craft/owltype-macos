//
//  OwlVoiceGrokASRClient.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

public protocol OwlVoiceASRServiceProtocol: Sendable {
  func transcribe(audioWavData: Data, prompt: String?) async throws -> String
}

public final class OwlVoiceGrokASRClient: OwlVoiceASRServiceProtocol, @unchecked Sendable {
  public static let shared = OwlVoiceGrokASRClient()

  private let explicitProviderID: String?
  private let explicitEndpoint: URL?
  private let explicitModel: String?
  public var providerID: String { explicitProviderID ?? OwlVoiceSettings.asrProviderID }
  public var endpoint: URL { explicitEndpoint ?? OwlVoiceSettings.asrEndpointURL }
  public var model: String { explicitModel ?? OwlVoiceSettings.asrModel }
  public let transport: OwlVoiceNetworkTransport
  public let apiKeyProvider: @Sendable () throws -> String?
  let loginCredentialProvider: @Sendable (_ forceRefresh: Bool) async throws -> OwlVoiceOpenAILoginCredential
  public var requestTimeout: TimeInterval

  public init(
    providerID: String? = nil,
    endpoint: URL? = nil,
    model: String? = nil,
    transport: OwlVoiceNetworkTransport = OwlURLSessionVoiceTransport(),
    requestTimeout: TimeInterval = 15.0,
    apiKeyProvider: @escaping @Sendable () throws -> String? = {
      try OwlVoiceKeychain.readActiveASRAPIKey()
    }
  ) {
    self.explicitProviderID = providerID
    self.explicitEndpoint = endpoint
    self.explicitModel = model
    self.transport = transport
    self.requestTimeout = requestTimeout
    self.apiKeyProvider = apiKeyProvider
    self.loginCredentialProvider = { forceRefresh in
      try await OwlVoiceOpenAILoginInspector.fetchCredential(forceRefresh: forceRefresh)
    }
  }

  init(
    providerID: String?,
    endpoint: URL? = nil,
    model: String? = nil,
    transport: OwlVoiceNetworkTransport = OwlURLSessionVoiceTransport(),
    requestTimeout: TimeInterval = 15.0,
    apiKeyProvider: @escaping @Sendable () throws -> String? = { nil },
    loginCredentialProvider: @escaping @Sendable (_ forceRefresh: Bool) async throws -> OwlVoiceOpenAILoginCredential
  ) {
    self.explicitProviderID = providerID
    self.explicitEndpoint = endpoint
    self.explicitModel = model
    self.transport = transport
    self.requestTimeout = requestTimeout
    self.apiKeyProvider = apiKeyProvider
    self.loginCredentialProvider = loginCredentialProvider
  }

  public func transcribe(audioWavData: Data, prompt: String?) async throws -> String {
    try Task.checkCancellation()

    guard !audioWavData.isEmpty && audioWavData.count >= 44 else {
      throw OwlVoiceError.emptyAudioData
    }

    let preset = OwlVoiceASRCatalog.preset(id: providerID)
    if preset.isOpenAILogin {
      return try await transcribeViaOpenAILogin(audioWavData: audioWavData)
    }

    guard let apiKey = try apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
      throw OwlVoiceError.missingAPIKey
    }

    if preset.id == OwlVoiceASRCatalog.gemini.id {
      return try await transcribeViaGeminiGenerateContent(
        audioWavData: audioWavData,
        prompt: prompt,
        apiKey: apiKey
      )
    }

    return try await transcribeViaMultipart(
      audioWavData: audioWavData,
      prompt: prompt,
      apiKey: apiKey
    )
  }

  // MARK: - Route 1: OpenAI & Multipart Transcriptions

  private func transcribeViaMultipart(
    audioWavData: Data,
    prompt: String?,
    apiKey: String
  ) async throws -> String {
    let boundary = "Boundary-\(UUID().uuidString)"
    let payload = Self.buildMultipartBody(
      audioData: audioWavData,
      model: model,
      prompt: prompt,
      boundary: boundary
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = requestTimeout
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = payload

    let (data, response) = try await transport.send(request)
    try Task.checkCancellation()

    guard let httpResponse = response as? HTTPURLResponse else {
      throw OwlVoiceError.badHTTPStatus(status: 0, message: "非 HTTP 协议响应")
    }

    if httpResponse.statusCode != 200 {
      let parsedMessage = Self.parseErrorMessage(from: data, removing: apiKey)
      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw OwlVoiceError.invalidToken(status: httpResponse.statusCode, message: parsedMessage)
      } else {
        throw OwlVoiceError.badHTTPStatus(status: httpResponse.statusCode, message: parsedMessage)
      }
    }

    return try Self.decodeTranscript(from: data, isGeminiGenerateContent: false)
  }

  // MARK: - Route 2: Google Gemini Native generateContent

  private func transcribeViaGeminiGenerateContent(
    audioWavData: Data,
    prompt: String?,
    apiKey: String
  ) async throws -> String {
    let targetURL = Self.resolveGeminiGenerateContentEndpoint(baseEndpoint: endpoint, model: model)
    let payload = try Self.buildGeminiGenerateContentBody(audioData: audioWavData, prompt: prompt)

    var request = URLRequest(url: targetURL)
    request.httpMethod = "POST"
    request.timeoutInterval = requestTimeout
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = payload

    let (data, response) = try await transport.send(request)
    try Task.checkCancellation()

    guard let httpResponse = response as? HTTPURLResponse else {
      throw OwlVoiceError.badHTTPStatus(status: 0, message: "非 HTTP 协议响应")
    }

    if httpResponse.statusCode != 200 {
      let parsedMessage = Self.parseErrorMessage(from: data, removing: apiKey)
      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw OwlVoiceError.invalidToken(status: httpResponse.statusCode, message: parsedMessage)
      } else {
        throw OwlVoiceError.badHTTPStatus(status: httpResponse.statusCode, message: parsedMessage)
      }
    }

    return try Self.decodeTranscript(from: data, isGeminiGenerateContent: true)
  }

  // MARK: - Route 3: OpenAI Login (ChatGPT Dictation via Codex CLI)

  private func transcribeViaOpenAILogin(audioWavData: Data) async throws -> String {
    let trimmed = try await recognizeViaOpenAILogin(audioWavData: audioWavData)
    guard !trimmed.isEmpty else {
      throw OwlVoiceError.emptyTranscript
    }
    return trimmed
  }

  /// 执行 ChatGPT 听写请求并返回去除首尾空白的原始文本（静音允许返回空字符串，供连接验证复用）。
  func recognizeViaOpenAILogin(audioWavData: Data, language: String = "zh") async throws -> String {
    let boundary = "Boundary-\(UUID().uuidString)"
    let payload = Self.buildChatGPTDictationMultipartBody(
      audioData: audioWavData,
      language: language,
      boundary: boundary
    )

    for attempt in 0..<2 {
      let forceRefresh = attempt > 0
      let credential = try await loginCredentialProvider(forceRefresh)
      try Task.checkCancellation()

      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = requestTimeout
      request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("Owltype/2.4.1", forHTTPHeaderField: "User-Agent")
      request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
      request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
      var currentToken = ""
      credential.withBearerRouting { token, accountId in
        currentToken = token
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
      }
      request.httpBody = payload

      let (data, response) = try await transport.send(request)
      try Task.checkCancellation()

      guard let httpResponse = response as? HTTPURLResponse else {
        throw OwlVoiceError.badHTTPStatus(status: 0, message: "非 HTTP 协议响应")
      }

      let code = httpResponse.statusCode
      if code == 401 {
        if attempt == 0 {
          continue
        }
        OwlVoiceOpenAILoginInspector.clearCachedCredential()
        let parsedMessage = Self.parseErrorMessage(from: data, removing: currentToken)
          ?? "ChatGPT 登录已失效。请在终端运行 codex login 重新登录。"
        throw OwlVoiceError.invalidToken(status: 401, message: parsedMessage)
      }

      if code == 403 {
        let parsedMessage = Self.parseErrorMessage(from: data, removing: currentToken)
          ?? "ChatGPT 拒绝了听写请求（HTTP 403）：账号可能受限，或接口已调整。"
        throw OwlVoiceError.invalidToken(status: 403, message: parsedMessage)
      }

      if code == 429 {
        let parsedMessage = Self.parseErrorMessage(from: data, removing: currentToken)
          ?? "ChatGPT 听写请求过多（HTTP 429），请稍后再试。"
        throw OwlVoiceError.badHTTPStatus(status: 429, message: parsedMessage)
      }

      if (300..<400).contains(code) || code == 404 || code == 405 || code == 410 {
        throw OwlVoiceError.badHTTPStatus(
          status: code,
          message: "ChatGPT 听写接口返回异常，可能已调整，暂不可用。"
        )
      }

      if code != 200 {
        let parsedMessage = Self.parseErrorMessage(from: data, removing: currentToken)
          ?? ((500..<600).contains(code)
            ? "ChatGPT 听写服务暂时不可用（HTTP \(code)），请稍后再试。"
            : "ChatGPT 听写请求失败（HTTP \(code)）。")
        throw OwlVoiceError.badHTTPStatus(status: code, message: parsedMessage)
      }

      return try Self.decodeRawOpenAITranscript(from: data)
    }

    OwlVoiceOpenAILoginInspector.clearCachedCredential()
    throw OwlVoiceError.invalidToken(status: 401, message: "ChatGPT 登录已失效。请在终端运行 codex login 重新登录。")
  }

  // MARK: - Pure Boundary Builders & Parsers

  public static func buildMultipartBody(
    audioData: Data,
    model: String,
    prompt: String?,
    boundary: String
  ) -> Data {
    var body = Data()
    let boundaryPrefix = "--\(boundary)\r\n"

    // Model field
    body.append(Data(boundaryPrefix.utf8))
    body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n".utf8))

    // Response format field
    body.append(Data(boundaryPrefix.utf8))
    body.append(Data("Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))

    // Optional prompt field
    if let prompt = prompt, !prompt.isEmpty {
      body.append(Data(boundaryPrefix.utf8))
      body.append(Data("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\(prompt)\r\n".utf8))
    }

    // Audio file field
    body.append(Data(boundaryPrefix.utf8))
    body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n".utf8))
    body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
    body.append(audioData)
    body.append(Data("\r\n".utf8))

    // Closing boundary
    body.append(Data("--\(boundary)--\r\n".utf8))
    return body
  }

  public static func buildChatGPTDictationMultipartBody(
    audioData: Data,
    language: String = "zh",
    boundary: String
  ) -> Data {
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n".utf8))
    body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
    body.append(audioData)
    body.append(Data("\r\n--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n".utf8))
    body.append(Data("--\(boundary)--\r\n".utf8))
    return body
  }

  public static func resolveGeminiGenerateContentEndpoint(baseEndpoint: URL, model: String) -> URL {
    let rawBase = baseEndpoint.path.contains("/audio/transcriptions")
      ? OwlVoiceASRCatalog.gemini.endpoint
      : baseEndpoint.absoluteString
    let raw = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if raw.hasSuffix(":generateContent") {
      return URL(string: raw) ?? baseEndpoint
    }
    let cleanModel = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
    if raw.hasSuffix("/models") {
      return URL(string: "\(raw)/\(cleanModel):generateContent") ?? baseEndpoint
    }
    return URL(string: "\(raw)/models/\(cleanModel):generateContent") ?? baseEndpoint
  }

  public static func buildGeminiGenerateContentBody(
    audioData: Data,
    prompt: String?
  ) throws -> Data {
    var instruction = "请逐字转写这段音频中的语音内容，只输出转写文本本身，不要添加任何解释、前缀或格式标记。"
    if let prompt, !prompt.isEmpty {
      instruction += "\n上下文与常用词参考：\n\(prompt)"
    }
    let payload: [String: Any] = [
      "contents": [
        [
          "parts": [
            ["text": instruction],
            [
              "inlineData": [
                "mimeType": "audio/wav",
                "data": audioData.base64EncodedString()
              ]
            ]
          ]
        ]
      ],
      "generationConfig": [
        "temperature": 0
      ]
    ]
    return try JSONSerialization.data(withJSONObject: payload)
  }

  public static func decodeTranscript(from data: Data, isGeminiGenerateContent: Bool) throws -> String {
    struct OpenAIResponseDTO: Decodable {
      let text: String
    }
    struct GeminiResponseDTO: Decodable {
      struct Candidate: Decodable {
        struct Content: Decodable {
          struct AudioTranscription: Decodable {
            let text: String?
          }
          struct Part: Decodable {
            let text: String?
            let audioTranscription: AudioTranscription?
          }
          let parts: [Part]?
        }
        let content: Content?
      }
      let candidates: [Candidate]?
    }

    if isGeminiGenerateContent,
       let gemini = try? JSONDecoder().decode(GeminiResponseDTO.self, from: data),
       let parts = gemini.candidates?.first?.content?.parts {
      let combined = parts
        .compactMap { $0.text ?? $0.audioTranscription?.text }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !combined.isEmpty else {
        throw OwlVoiceError.emptyTranscript
      }
      return combined
    }

    let trimmed = try decodeRawOpenAITranscript(from: data)
    guard !trimmed.isEmpty else {
      throw OwlVoiceError.emptyTranscript
    }
    return trimmed
  }

  static func decodeRawOpenAITranscript(from data: Data) throws -> String {
    struct OpenAIResponseDTO: Decodable {
      let text: String
    }
    let decoded: OpenAIResponseDTO
    do {
      decoded = try JSONDecoder().decode(OpenAIResponseDTO.self, from: data)
    } catch {
      throw OwlVoiceError.decodingError(error.localizedDescription)
    }
    return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func parseErrorMessage(from data: Data, removing apiKey: String = "") -> String? {
    struct ErrorWrapper: Decodable {
      struct InnerError: Decodable {
        let message: String?
        let code: String?
      }
      let error: InnerError?
    }
    if let wrapper = try? JSONDecoder().decode(ErrorWrapper.self, from: data), let msg = wrapper.error?.message {
      let cleaned = OwlServerErrorDetail(code: wrapper.error?.code, message: msg).sanitized(removing: apiKey)
      return cleaned.isEmpty ? nil : cleaned
    }
    return nil
  }
}
