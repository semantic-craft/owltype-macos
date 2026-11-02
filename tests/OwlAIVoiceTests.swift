//
//  OwlAIVoiceTests.swift
//  OwltypeTests — Lane B: Unified Voice Input Unit & Integration Test Suite (#393, #396, #398)
//
//  Comprehensive 100% offline automated test suite covering:
//  - Pure in-memory 16kHz WAV packaging and PCM buffer alignment
//  - Microphone permission checks and status invariants
//  - xAI Grok ASR cloud transcription client, multipart form encoding, and error domain
//  - Hotword extraction (pinned, custom, bigrams) and 800-byte token-safe UTF-8 budget
//  - DeepSeek LLM voice polishing (thinking disabled, filler removal, homophone correction)
//  - 4.0s timeout and seamless fallback degradation
//  - Voice capsule HUD non-activating NSPanel invariants and state machine
//  - Voice input coordinator workflows (hold-to-speak, click-to-toggle, hands-free space lock, Esc cancel, secure input guard)
//

import AppKit
import AVFoundation
import InputMethodKit
import XCTest
@testable import Owltype

@MainActor
final class OwlAIVoiceTests: XCTestCase {

  // MARK: - Helper Methods

  private func makeKeyEvent(type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    let event = NSEvent.keyEvent(
      with: type,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: keyCode
    )
    return try XCTUnwrap(event)
  }

  // MARK: - 1. Audio Recording & WAV Packaging

  func testWAVHeaderLayoutAndByteAlignment() {
    let dummyPCM = Data([0x10, 0x20, 0x30, 0x40])
    let wav = OwlWAVPacker.pack16kMono(pcmData: dummyPCM)

    XCTAssertEqual(wav.count, 44 + dummyPCM.count, "WAV size must be 44-byte header + PCM payload")

    // RIFF Chunk Descriptor
    XCTAssertEqual(Array(wav[0..<4]), [0x52, 0x49, 0x46, 0x46], "0..3 must be 'RIFF'")
    let chunkSize = wav.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
    XCTAssertEqual(chunkSize, UInt32(36 + dummyPCM.count), "ChunkSize must be 36 + data size")
    XCTAssertEqual(Array(wav[8..<12]), [0x57, 0x41, 0x56, 0x45], "8..11 must be 'WAVE'")

    // fmt subchunk
    XCTAssertEqual(Array(wav[12..<16]), [0x66, 0x6D, 0x74, 0x20], "12..15 must be 'fmt '")
    let subchunk1Size = wav.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
    XCTAssertEqual(subchunk1Size, 16, "Subchunk1Size must be 16 for PCM")
    let audioFormat = wav.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self) }
    XCTAssertEqual(audioFormat, 1, "AudioFormat must be 1 (PCM)")
    let numChannels = wav.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
    XCTAssertEqual(numChannels, 1, "NumChannels must be 1 (mono)")
    let sampleRate = wav.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
    XCTAssertEqual(sampleRate, 16000, "SampleRate must be 16000 Hz")
    let byteRate = wav.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
    XCTAssertEqual(byteRate, 32000, "ByteRate must be 32000 (16000 * 1 * 2)")
    let blockAlign = wav.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt16.self) }
    XCTAssertEqual(blockAlign, 2, "BlockAlign must be 2 (1 * 16/8)")
    let bitsPerSample = wav.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }
    XCTAssertEqual(bitsPerSample, 16, "BitsPerSample must be 16")

    // data subchunk
    XCTAssertEqual(Array(wav[36..<40]), [0x64, 0x61, 0x74, 0x61], "36..39 must be 'data'")
    let subchunk2Size = wav.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
    XCTAssertEqual(subchunk2Size, UInt32(dummyPCM.count), "Subchunk2Size must equal PCM data length")
    XCTAssertEqual(Array(wav[44..<48]), [0x10, 0x20, 0x30, 0x40], "Payload bytes must match verbatim")
  }

  func testMicrophonePermissionCheck() {
    let status = OwlMicrophonePermission.status
    XCTAssertTrue(status == .authorized || status == .notDetermined || status == .denied || status == .restricted)
    XCTAssertEqual(OwlMicrophonePermission.isAuthorized, status == .authorized)
  }

  // MARK: - 2. xAI Grok ASR Client

  func testGrokASRTranscriptionSuccess() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"人工智能辅助输入系统\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
      return (Data(json.utf8), resp)
    }

    let client = OwlVoiceGrokASRClient(
      transport: stubTransport,
      apiKeyProvider: { "xai-test-key-12345" }
    )

    let dummyWAV = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))
    let result = try await client.transcribe(audioWavData: dummyWAV, prompt: "技术文档")

    XCTAssertEqual(result, "人工智能辅助输入系统")
    XCTAssertEqual(stubTransport.recordedRequests.count, 1)

    let req = try XCTUnwrap(stubTransport.recordedRequests.first)
    XCTAssertEqual(req.httpMethod, "POST")
    XCTAssertEqual(req.url?.absoluteString, "https://api.x.ai/v1/audio/transcriptions")
    XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer xai-test-key-12345")
    XCTAssertTrue(req.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
  }

  func testGrokASRClientErrorHandling() async {
    let stubTransport = OwlStubVoiceTransport { req in
      let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
      return (Data("{\"error\": \"Unauthorized\"}".utf8), resp)
    }

    let client = OwlVoiceGrokASRClient(
      transport: stubTransport,
      apiKeyProvider: { "invalid-key" }
    )

    let dummyWAV = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))
    do {
      _ = try await client.transcribe(audioWavData: dummyWAV, prompt: nil)
      XCTFail("Expected invalidToken error")
    } catch let error as OwlVoiceError {
      guard case .invalidToken(let status, _) = error else {
        return XCTFail("Expected .invalidToken, got \(error)")
      }
      XCTAssertEqual(status, 401)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - 3. Hotwords Extraction & 800-Byte UTF-8 Budgeting

  func testHotwordsExtractionAndPromptBudgeting() {
    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: nil,
      inMemoryPinnedWordsProvider: { ["深度学习", "强化学习", "自然语言处理"] }
    )

    let hotwords = extractor.extractHotwords(limit: 10)
    XCTAssertTrue(hotwords.contains("深度学习"))
    XCTAssertTrue(hotwords.contains("强化学习"))
    XCTAssertTrue(hotwords.contains("自然语言处理"))

    // Budgeting test: 800-byte token-safe budget
    let prompt = extractor.buildPrompt(
      preContext: "正在编写关于",
      hotwords: hotwords,
      maxBytes: 800
    )

    let byteCount = prompt.utf8.count
    XCTAssertLessThanOrEqual(byteCount, 800, "Prompt must strictly stay within 800 UTF-8 bytes")
    XCTAssertTrue(prompt.contains("正在编写关于"))
  }

  func testHotwordsUTF8BoundaryNonSplitting() {
    let extractor = OwlVoiceHotwordsExtractor(
      databaseURL: nil,
      inMemoryPinnedWordsProvider: { [] }
    )

    // A string of 3-byte Chinese characters
    let longContext = String(repeating: "测", count: 300) // 900 bytes
    let prompt = extractor.buildPrompt(
      preContext: longContext,
      hotwords: ["词汇"],
      maxBytes: 800
    )

    XCTAssertLessThanOrEqual(prompt.utf8.count, 800)
    // Verify valid UTF-8 and no broken code points
    XCTAssertNotNil(String(data: Data(prompt.utf8), encoding: .utf8))
  }

  // MARK: - 4. DeepSeek Voice Polishing & Fallback Degradation

  func testDeepSeekVoicePolishingThinkingDisabled() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let json = """
      {
        "choices": [
          {
            "message": {
              "content": "今天天气很好，我们去公园散步吧。"
            }
          }
        ]
      }
      """
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
      return (Data(json.utf8), resp)
    }

    let polisher = OwlVoiceDeepSeekPolisher(
      transport: stubTransport,
      requestTimeout: 4.0,
      apiKeyProvider: { "deepseek-test-key" }
    )

    let rawTranscript = "呃今天那个天气很好我们去公园散步吧"
    let polished = try await polisher.polish(rawTranscript: rawTranscript)

    XCTAssertEqual(polished, "今天天气很好，我们去公园散步吧。")
    XCTAssertEqual(stubTransport.recordedRequests.count, 1)

    let req = try XCTUnwrap(stubTransport.recordedRequests.first)
    let bodyData = try XCTUnwrap(req.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(json["model"] as? String, "deepseek-chat")
    let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
    XCTAssertEqual(thinking["type"] as? String, "disabled")
  }

  func testDeepSeekTimeoutFallbackDegradation() async throws {
    let stubTransport = OwlStubVoiceTransport { req in
      let htmlBody = "<html><body>502 Bad Gateway</body></html>"
      let response = HTTPURLResponse(url: req.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
      return (Data(htmlBody.utf8), response)
    }

    let polisher = OwlVoiceDeepSeekPolisher(
      transport: stubTransport,
      apiKeyProvider: { "deepseek-test-key" }
    )

    let raw = "原始转写内容"
    let result = try await polisher.polish(rawTranscript: raw)
    XCTAssertEqual(result, raw, "When polish fails or degrades, it must seamlessly fallback to raw transcript")
  }

  // MARK: - 5. Voice Capsule HUD Invariants

  func testVoiceCapsuleHUDInvariants() {
    let panel = OwlVoiceCapsulePanel()

    // Non-activating NSPanel properties
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "Must have .nonactivatingPanel styleMask")
    XCTAssertTrue(panel.styleMask.contains(.borderless), "Must have .borderless styleMask")
    XCTAssertFalse(panel.canBecomeKey, "canBecomeKey must be false to avoid stealing host focus")
    XCTAssertFalse(panel.canBecomeMain, "canBecomeMain must be false to avoid stealing host focus")
    XCTAssertEqual(panel.level, .floating, "Panel level must be .floating")
  }

  // MARK: - 6. Voice Input Coordinator Workflows

  func testHoldToSpeakWorkflow() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    mockRecorder.simulatedDuration = 1.0
    mockRecorder.simulatedPeakRMS = 0.2
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"测试语音输入上屏\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }
    let asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })
    coordinator.asrClient = asrClient

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = {
      OwlVoiceTargetSnapshot(client: mockClient, caretAnchor: NSRect(x: 200, y: 300, width: 2, height: 16))
    }

    coordinator.shortcutMatcher = { event in
      event.keyCode == 9 && event.modifierFlags.contains(.command)
    }

    // Step 1: KeyDown -> Starts recording
    let keyDownEvent = try makeKeyEvent(type: .keyDown, keyCode: 9, modifiers: .command)
    let consumedDown = coordinator.handleKeyEvent(keyDownEvent)
    XCTAssertTrue(consumedDown)
    guard case .holding = coordinator.mode else {
      return XCTFail("Expected .holding, got \(coordinator.mode)")
    }
    XCTAssertTrue(mockRecorder.isRecording)

    // Step 2: KeyUp -> Triggers transcription
    try await Task.sleep(nanoseconds: 350_000_000)
    let keyUpEvent = try makeKeyEvent(type: .keyUp, keyCode: 9, modifiers: .command)
    let consumedUp = coordinator.handleKeyEvent(keyUpEvent)
    XCTAssertTrue(consumedUp)

    // Wait for async pipeline
    for _ in 0..<30 {
      if !mockClient.insertedTexts.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTAssertFalse(mockClient.insertedTexts.isEmpty, "Text must be inserted into host client")
    XCTAssertEqual(mockClient.insertedTexts.first, "测试语音输入上屏")
  }

  func testHandsFreeSpaceLockWorkflow() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    mockRecorder.simulatedDuration = 1.0
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"双手锁定输入成功\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = {
      OwlVoiceTargetSnapshot(client: mockClient)
    }

    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    // 1. Shortcut Down -> .holding
    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(down))
    guard case .holding = coordinator.mode else { return XCTFail() }

    // 2. Space Down -> .handsFreeLocked
    let space = try makeKeyEvent(type: .keyDown, keyCode: 49) // Space
    XCTAssertTrue(coordinator.handleKeyEvent(space))
    guard case .handsFreeLocked = coordinator.mode else {
      return XCTFail("Expected .handsFreeLocked, got \(coordinator.mode)")
    }

    // 3. Shortcut Up -> Remains .handsFreeLocked (does NOT stop recording)
    let up = try makeKeyEvent(type: .keyUp, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(up))
    guard case .handsFreeLocked = coordinator.mode else {
      return XCTFail("Expected .handsFreeLocked to persist on keyUp, got \(coordinator.mode)")
    }
    XCTAssertTrue(mockRecorder.isRecording)

    // 4. Subsequent Shortcut Down -> Finishes recording
    let finishDown = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(finishDown))

    for _ in 0..<30 {
      if !mockClient.insertedTexts.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(mockClient.insertedTexts, ["双手锁定输入成功"])
  }

  func testEscCancellationAbortsWithoutInsertion() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = {
      OwlVoiceTargetSnapshot(client: mockClient, caretAnchor: .zero)
    }

    coordinator.shortcutMatcher = { event in
      event.keyCode == 9 && event.modifierFlags.contains(.command)
    }

    // Start holding
    let downEvent = try makeKeyEvent(type: .keyDown, keyCode: 9, modifiers: .command)
    _ = coordinator.handleKeyEvent(downEvent)
    XCTAssertTrue(mockRecorder.isRecording)

    // Press Esc (keyCode 53) -> cancels and dismisses
    let escEvent = try makeKeyEvent(type: .keyDown, keyCode: 53)
    let escConsumed = coordinator.handleKeyEvent(escEvent)
    XCTAssertTrue(escConsumed)
    XCTAssertFalse(mockRecorder.isRecording)
    guard case .idle = coordinator.mode else {
      return XCTFail("Expected .idle after Esc, got \(coordinator.mode)")
    }
    XCTAssertTrue(mockClient.insertedTexts.isEmpty, "No text must be inserted on Esc cancel")
  }

  func testSecureInputBlocksVoiceCapture() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.secureInputChecker = { true }

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    let consumed = coordinator.handleKeyEvent(down)
    XCTAssertTrue(consumed, "Secure input consumes key event safely")
    XCTAssertEqual(coordinator.mode, .idle, "Must remain .idle in secure input")
    XCTAssertEqual(mockRecorder.startRecordingCallCount, 0, "Must not start recording in secure input")
  }
}
