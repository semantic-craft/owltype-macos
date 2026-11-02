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

  public let endpoint: URL
  public let model: String
  public let transport: OwlVoiceNetworkTransport
  public let apiKeyProvider: @Sendable () throws -> String?
  public var requestTimeout: TimeInterval

  public init(
    endpoint: URL = URL(string: "https://api.x.ai/v1/audio/transcriptions")!,
    model: String = "grok-asr",
    transport: OwlVoiceNetworkTransport = OwlURLSessionVoiceTransport(),
    requestTimeout: TimeInterval = 15.0,
    apiKeyProvider: @escaping @Sendable () throws -> String? = {
      if let env = ProcessInfo.processInfo.environment["XAI_API_KEY"], !env.isEmpty {
        return env
      }
      return try OwlVoiceKeychain.readXAIAPIKey()
    }
  ) {
    self.endpoint = endpoint
    self.model = model
    self.transport = transport
    self.requestTimeout = requestTimeout
    self.apiKeyProvider = apiKeyProvider
  }

  public func transcribe(audioWavData: Data, prompt: String?) async throws -> String {
    try Task.checkCancellation()

    // 1. Pre-flight validations
    guard !audioWavData.isEmpty && audioWavData.count >= 44 else {
      throw OwlVoiceError.emptyAudioData
    }

    guard let apiKey = try apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
      throw OwlVoiceError.missingAPIKey
    }

    // 2. Build multipart payload in memory
    let boundary = "Boundary-\(UUID().uuidString)"
    let payload = Self.buildMultipartBody(
      audioData: audioWavData,
      model: model,
      prompt: prompt,
      boundary: boundary
    )

    // 3. Construct URLRequest
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = requestTimeout
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = payload

    // 4. Perform network request via transport abstraction
    let (data, response) = try await transport.send(request)
    try Task.checkCancellation()

    guard let httpResponse = response as? HTTPURLResponse else {
      throw OwlVoiceError.badHTTPStatus(status: 0, message: "非 HTTP 协议响应")
    }

    // 5. Status code checking & error decoding
    if httpResponse.statusCode != 200 {
      let parsedMessage = Self.parseErrorMessage(from: data)
      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw OwlVoiceError.invalidToken(status: httpResponse.statusCode, message: parsedMessage)
      } else {
        throw OwlVoiceError.badHTTPStatus(status: httpResponse.statusCode, message: parsedMessage)
      }
    }

    // 6. Decode successful JSON transcript
    struct ResponseDTO: Decodable {
      let text: String
    }

    let decoded: ResponseDTO
    do {
      decoded = try JSONDecoder().decode(ResponseDTO.self, from: data)
    } catch {
      throw OwlVoiceError.decodingError(error.localizedDescription)
    }

    let trimmed = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw OwlVoiceError.emptyTranscript
    }

    return trimmed
  }

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

  public static func parseErrorMessage(from data: Data) -> String? {
    struct ErrorWrapper: Decodable {
      struct InnerError: Decodable {
        let message: String?
        let code: String?
      }
      let error: InnerError?
    }
    if let wrapper = try? JSONDecoder().decode(ErrorWrapper.self, from: data), let msg = wrapper.error?.message {
      return msg
    }
    return nil
  }
}
