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
  public var endpoint: URL {
    if let explicitEndpoint { return explicitEndpoint }
    if let explicitProviderID { return URL(string: OwlVoiceASRCatalog.preset(id: explicitProviderID).endpoint)! }
    return OwlVoiceSettings.resolvedASREndpointURL
  }
  public var model: String {
    if let explicitModel { return explicitModel }
    if let explicitProviderID { return OwlVoiceASRCatalog.preset(id: explicitProviderID).defaultModel }
    return OwlVoiceSettings.resolvedASRModel
  }
  public let transport: OwlVoiceNetworkTransport
  public let apiKeyProvider: @Sendable () throws -> String?
  public var requestTimeout: TimeInterval

  public init(
    providerID: String? = nil,
    endpoint: URL? = nil,
    model: String? = nil,
    transport: OwlVoiceNetworkTransport = OwlURLSessionVoiceTransport(),
    requestTimeout: TimeInterval = 15.0,
    apiKeyProvider: (@Sendable () throws -> String?)? = nil
  ) {
    self.explicitProviderID = providerID
    self.explicitEndpoint = endpoint
    self.explicitModel = model
    self.transport = transport
    self.requestTimeout = requestTimeout
    self.apiKeyProvider = apiKeyProvider ?? {
      if let providerID { return try OwlVoiceSettings.readASRAPIKey(forProviderID: providerID) }
      return try OwlVoiceSettings.readActiveASRAPIKey()
    }
  }

  public func transcribe(audioWavData: Data, prompt: String?) async throws -> String {
    try Task.checkCancellation()

    guard !audioWavData.isEmpty && audioWavData.count >= 44 else {
      throw OwlVoiceError.emptyAudioData
    }

    let preset = OwlVoiceASRCatalog.preset(id: providerID)
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
      boundary: boundary,
      fileOnly: providerID == OwlVoiceASRCatalog.deepseek.id
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

  // MARK: - Pure Boundary Builders & Parsers

  public static func buildMultipartBody(
    audioData: Data,
    model: String,
    prompt: String?,
    boundary: String,
    fileOnly: Bool = false
  ) -> Data {
    var body = Data()
    let boundaryPrefix = "--\(boundary)\r\n"

    if !fileOnly {
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
