//
//  OwlVoiceGrokASRClientTests.swift
//  OwltypeTests — Lane B: xAI Grok Cloud ASR Client Tests (#393)
//

import XCTest
@testable import Owltype

final class OwlVoiceGrokASRClientTests: XCTestCase {

  // MARK: - 1. Multipart Payload Byte Structure

  func testMultipartPayloadEncoding() {
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02, 0x03, 0x04]))
    let boundary = "Boundary-TEST-UUID"
    let body = OwlVoiceGrokASRClient.buildMultipartBody(
      audioData: mockWav,
      model: "grok-asr",
      prompt: "前文：你好\n热词：猫头鹰输入法",
      boundary: boundary
    )

    let bodyString = String(decoding: body, as: UTF8.self)
    XCTAssertTrue(bodyString.contains("--Boundary-TEST-UUID\r\n"))
    XCTAssertTrue(bodyString.contains("name=\"model\"\r\n\r\ngrok-asr\r\n"))
    XCTAssertTrue(bodyString.contains("name=\"response_format\"\r\n\r\njson\r\n"))
    XCTAssertTrue(bodyString.contains("name=\"prompt\"\r\n\r\n前文：你好\n热词：猫头鹰输入法\r\n"))
    XCTAssertTrue(bodyString.contains("name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
    XCTAssertTrue(bodyString.hasSuffix("--Boundary-TEST-UUID--\r\n"))
  }

  func testMultipartPayloadOmitsPromptWhenNilOrEmpty() {
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))
    let boundary = "Boundary-TEST-UUID"

    let bodyNil = OwlVoiceGrokASRClient.buildMultipartBody(
      audioData: mockWav,
      model: "grok-asr",
      prompt: nil,
      boundary: boundary
    )
    XCTAssertFalse(String(decoding: bodyNil, as: UTF8.self).contains("name=\"prompt\""))

    let bodyEmpty = OwlVoiceGrokASRClient.buildMultipartBody(
      audioData: mockWav,
      model: "grok-asr",
      prompt: "",
      boundary: boundary
    )
    XCTAssertFalse(String(decoding: bodyEmpty, as: UTF8.self).contains("name=\"prompt\""))
  }

  // MARK: - 2. Successful Transcription & Whitespace Handling

  func testSuccessfulTranscription() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      XCTAssertEqual(req.httpMethod, "POST")
      XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-123")
      XCTAssertTrue(req.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)

      let json = "{\"text\": \"  今天天气很好我们去开会  \\n\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }

    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "test-key-123" })
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02, 0x03, 0x04]))
    let result = try await client.transcribe(audioWavData: mockWav, prompt: "开会")
    XCTAssertEqual(result, "今天天气很好我们去开会")
  }

  // MARK: - 3. Empty Transcript Validation

  func testEmptyTranscriptThrowsError() async {
    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"   \\n\\t  \"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }

    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "test-key" })
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))
    do {
      _ = try await client.transcribe(audioWavData: mockWav, prompt: nil)
      XCTFail("Expected emptyTranscript error")
    } catch let error as OwlVoiceError {
      XCTAssertEqual(error, .emptyTranscript)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - 4. Pre-Flight Guards

  func testMissingAPIKeyThrowsWithoutNetwork() async {
    let stubTransport = OwlStubVoiceTransport()
    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { nil })
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))

    do {
      _ = try await client.transcribe(audioWavData: mockWav, prompt: nil)
      XCTFail("Expected missingAPIKey")
    } catch let error as OwlVoiceError {
      XCTAssertEqual(error, .missingAPIKey)
      XCTAssertTrue(stubTransport.recordedRequests.isEmpty)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testEmptyAudioDataThrowsWithoutNetwork() async {
    let stubTransport = OwlStubVoiceTransport()
    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "test-key" })

    do {
      _ = try await client.transcribe(audioWavData: Data(), prompt: nil)
      XCTFail("Expected emptyAudioData")
    } catch let error as OwlVoiceError {
      XCTAssertEqual(error, .emptyAudioData)
      XCTAssertTrue(stubTransport.recordedRequests.isEmpty)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - 5. Error Code & Server Message Handling

  func testHTTP401InvalidToken() async {
    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"error\": {\"message\": \"Incorrect API key provided\", \"code\": \"invalid_api_key\"}}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }

    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "bad-key" })
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))

    do {
      _ = try await client.transcribe(audioWavData: mockWav, prompt: nil)
      XCTFail("Expected invalidToken")
    } catch let error as OwlVoiceError {
      XCTAssertEqual(error, .invalidToken(status: 401, message: "Incorrect API key provided"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testHTTP502BadGatewayHTMLResponse() async {
    let stubTransport = OwlStubVoiceTransport { req in
      let html = "<html><body>502 Bad Gateway</body></html>"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
      return (Data(html.utf8), resp)
    }

    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "key" })
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))

    do {
      _ = try await client.transcribe(audioWavData: mockWav, prompt: nil)
      XCTFail("Expected badHTTPStatus 502")
    } catch let error as OwlVoiceError {
      XCTAssertEqual(error, .badHTTPStatus(status: 502, message: nil))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - 6. Adversarial Challenges (Payload & Transport)

  func testStrictRFC7578CRLFBoundariesAndHeaders() {
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0xAA, 0xBB, 0xCC, 0xDD]))
    let boundary = "STRICT-BOUNDARY-42"
    let body = OwlVoiceGrokASRClient.buildMultipartBody(
      audioData: mockWav,
      model: "grok-asr-adv",
      prompt: "热词：测试",
      boundary: boundary
    )

    // Verify all byte occurrences of 0x0A (\n) outside the binary payload are preceded by 0x0D (\r)
    let bodyBytes = [UInt8](body)
    var i = 0
    while i < bodyBytes.count {
      if bodyBytes[i] == 0x0A {
        XCTAssertGreaterThan(i, 0, "Line feed cannot be first byte")
        XCTAssertEqual(bodyBytes[i - 1], 0x0D, "RFC 7578 violation: found bare LF (0x0A) not preceded by CR (0x0D) at index \(i)")
      }
      i += 1
    }

    // Verify closing boundary
    let expectedEnding = "--\(boundary)--\r\n".data(using: .utf8)!
    XCTAssertEqual(body.suffix(expectedEnding.count), expectedEnding)
  }

  func testServer503ServiceUnavailableHTMLResponse() async {
    let stubTransport = OwlStubVoiceTransport { req in
      let html = "<!DOCTYPE html><html><head><title>503 Service Temporarily Unavailable</title></head><body><h1>503 Service Unavailable</h1></body></html>"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
      return (Data(html.utf8), resp)
    }

    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "valid-key" })
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))

    do {
      _ = try await client.transcribe(audioWavData: mockWav, prompt: nil)
      XCTFail("Expected badHTTPStatus 503")
    } catch let error as OwlVoiceError {
      XCTAssertEqual(error, .badHTTPStatus(status: 503, message: nil))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testServer200OKWithNonJSONHTMLReturnsDecodingError() async {
    let stubTransport = OwlStubVoiceTransport { req in
      let html = "<!DOCTYPE html><html><body>Captive Portal Login Required</body></html>"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
      return (Data(html.utf8), resp)
    }

    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "valid-key" })
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))

    do {
      _ = try await client.transcribe(audioWavData: mockWav, prompt: nil)
      XCTFail("Expected decodingError")
    } catch let error as OwlVoiceError {
      guard case .decodingError = error else {
        return XCTFail("Expected decodingError, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testNetworkTimeoutThrowsUnderlyingError() async {
    let stubTransport = OwlStubVoiceTransport { _ in
      throw URLError(.timedOut)
    }

    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "valid-key" })
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))

    do {
      _ = try await client.transcribe(audioWavData: mockWav, prompt: nil)
      XCTFail("Expected URLError.timedOut")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testConnectionSeveredMidUploadThrowsUnderlyingError() async {
    let stubTransport = OwlStubVoiceTransport { _ in
      throw URLError(.networkConnectionLost)
    }

    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "valid-key" })
    let mockWav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))

    do {
      _ = try await client.transcribe(audioWavData: mockWav, prompt: nil)
      XCTFail("Expected URLError.networkConnectionLost")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .networkConnectionLost)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}
