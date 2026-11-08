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
    XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
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

    // Step 1: Press Right Option -> Starts recording
    let pressEvent = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: [.option]
    )
    let consumedDown = coordinator.handleKeyEvent(pressEvent)
    XCTAssertTrue(consumedDown)
    guard case .holding = coordinator.mode else {
      return XCTFail("Expected .holding, got \(coordinator.mode)")
    }
    XCTAssertTrue(mockRecorder.isRecording)

    // Step 2: Release Right Option -> Triggers transcription
    try await Task.sleep(nanoseconds: 50_000_000)
    let releaseEvent = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: []
    )
    let consumedUp = coordinator.handleKeyEvent(releaseEvent)
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

    // 1. Right Option Down -> .holding
    let down = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: [.option]
    )
    XCTAssertTrue(coordinator.handleKeyEvent(down))
    guard case .holding = coordinator.mode else { return XCTFail() }

    // 2. Space Down -> .handsFreeLocked
    let space = try makeKeyEvent(type: .keyDown, keyCode: 49, modifiers: [.option]) // Space
    XCTAssertTrue(coordinator.handleKeyEvent(space))
    guard case .handsFreeLocked = coordinator.mode else {
      return XCTFail("Expected .handsFreeLocked, got \(coordinator.mode)")
    }

    // 3. Right Option Up -> Remains .handsFreeLocked (does NOT stop recording)
    let up = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: []
    )
    XCTAssertTrue(coordinator.handleKeyEvent(up))
    guard case .handsFreeLocked = coordinator.mode else {
      return XCTFail("Expected .handsFreeLocked to persist on Right Option release, got \(coordinator.mode)")
    }
    XCTAssertTrue(mockRecorder.isRecording)

    // 4. Subsequent Right Option Down -> Finishes recording
    let finishDown = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: [.option]
    )
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

    // Start holding Right Option
    let downEvent = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: [.option]
    )
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

    let down = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: [.option]
    )
    let consumed = coordinator.handleKeyEvent(down)
    XCTAssertTrue(consumed, "Secure input consumes key event safely")
    XCTAssertEqual(coordinator.mode, .idle, "Must remain .idle in secure input")
    XCTAssertEqual(mockRecorder.startRecordingCallCount, 0, "Must not start recording in secure input")
  }

  func testMicrophonePermissionNotDeterminedRequestsBeforeRecording() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.secureInputChecker = { false }

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot() }

    var permissionRequestedCount = 0
    coordinator.microphonePermissionStatusProvider = { .notDetermined }
    coordinator.microphonePermissionRequester = {
      permissionRequestedCount += 1
      return true
    }

    coordinator.startVoiceInput()
    for _ in 0..<20 {
      if mockRecorder.startRecordingCallCount > 0 { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    XCTAssertEqual(permissionRequestedCount, 1, "Must request microphone permission when .notDetermined")
    XCTAssertEqual(mockRecorder.startRecordingCallCount, 1, "Must start recording once permission is granted")
  }

  func testRightOptionHoldToSpeakAndReleaseTranscribes() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.holdRightOptionEnabledOverride = true
    coordinator.secureInputChecker = { false }

    let mockRecorder = OwlMockAudioRecorder()
    mockRecorder.simulatedDuration = 1.0
    mockRecorder.simulatedPeakRMS = 0.25
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"右Option按住说话上屏\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = {
      OwlVoiceTargetSnapshot(client: mockClient, caretAnchor: NSRect(x: 160, y: 240, width: 2, height: 16))
    }

    // 1. Press Right Option (keyCode 61, .option) -> starts recording in .holding
    let pressEvent = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: [.option]
    )
    XCTAssertTrue(coordinator.handleKeyEvent(pressEvent))
    XCTAssertTrue(coordinator.isHoldingRightOption)
    guard case .holding = coordinator.mode else {
      return XCTFail("Expected .holding after pressing Right Option, got \(coordinator.mode)")
    }
    XCTAssertTrue(mockRecorder.isRecording)

    // 2. Release Right Option (keyCode 61, []) -> finishes recording & transcribes
    let releaseEvent = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: []
    )
    XCTAssertTrue(coordinator.handleKeyEvent(releaseEvent))
    XCTAssertFalse(coordinator.isHoldingRightOption)

    for _ in 0..<30 {
      if !mockClient.insertedTexts.isEmpty { break }
      try await Task.sleep(nanoseconds: 30_000_000)
    }
    XCTAssertEqual(mockClient.insertedTexts.first, "右Option按住说话上屏")
  }

  func testRightOptionChordCancelAbortsRecordingAndPassesKeyToHost() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.holdRightOptionEnabledOverride = true
    coordinator.secureInputChecker = { false }

    let mockRecorder = OwlMockAudioRecorder()
    mockRecorder.simulatedDuration = 1.0
    coordinator.audioRecorder = mockRecorder
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot() }

    // 1. Hold Right Option -> enters .holding
    let pressRightOption = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: [.option]
    )
    XCTAssertTrue(coordinator.handleKeyEvent(pressRightOption))
    XCTAssertTrue(coordinator.isHoldingRightOption)
    XCTAssertTrue(mockRecorder.isRecording)

    // 2. Press 'a' (keyCode 0) while holding Option -> ChordCancel cancels voice input and returns false
    let chordKeyDown = try makeKeyEvent(type: .keyDown, keyCode: 0, modifiers: [.option])
    let consumed = coordinator.handleKeyEvent(chordKeyDown)
    XCTAssertFalse(consumed, "ChordCancel must return false so Option+key chord reaches the host app")
    XCTAssertFalse(coordinator.isHoldingRightOption)
    XCTAssertEqual(coordinator.mode, .idle)
    XCTAssertEqual(mockRecorder.cancelRecordingCallCount, 1)
    XCTAssertEqual(mockRecorder.stopRecordingCallCount, 0)
  }

  func testRightOptionHoldSpaceLocksHandsFreeAndSecondTapFinishes() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.holdRightOptionEnabledOverride = true
    coordinator.secureInputChecker = { false }

    let mockRecorder = OwlMockAudioRecorder()
    mockRecorder.simulatedDuration = 1.0
    coordinator.audioRecorder = mockRecorder
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot() }

    // 1. Hold Right Option -> .holding
    let pressRightOption = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: [.option]
    )
    XCTAssertTrue(coordinator.handleKeyEvent(pressRightOption))
    guard case .holding = coordinator.mode else {
      return XCTFail("Expected .holding, got \(coordinator.mode)")
    }

    // 2. Tap Space (keyCode 49) while holding Right Option -> .handsFreeLocked
    let spaceDown = try makeKeyEvent(type: .keyDown, keyCode: 49, modifiers: [.option])
    XCTAssertTrue(coordinator.handleKeyEvent(spaceDown))
    guard case .handsFreeLocked = coordinator.mode else {
      return XCTFail("Expected .handsFreeLocked after Space, got \(coordinator.mode)")
    }

    // 3. Release Right Option -> stays in .handsFreeLocked and keeps recording
    let releaseRightOption = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: []
    )
    XCTAssertTrue(coordinator.handleKeyEvent(releaseRightOption))
    guard case .handsFreeLocked = coordinator.mode else {
      return XCTFail("Releasing Right Option in .handsFreeLocked must keep recording, got \(coordinator.mode)")
    }
    XCTAssertTrue(mockRecorder.isRecording)

    // 4. Press Right Option again -> finishes recording
    XCTAssertTrue(coordinator.handleKeyEvent(pressRightOption))
    XCTAssertEqual(mockRecorder.stopRecordingCallCount, 1)
  }

  func testRightOptionHIDReleasePollingFallbackFinishesRecording() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.holdRightOptionEnabledOverride = true
    coordinator.secureInputChecker = { false }

    var physicalHeld = true
    coordinator.physicalRightOptionHeldProvider = { physicalHeld }

    let mockRecorder = OwlMockAudioRecorder()
    mockRecorder.simulatedDuration = 1.0
    coordinator.audioRecorder = mockRecorder
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot() }

    let pressRightOption = try makeKeyEvent(
      type: .flagsChanged,
      keyCode: OwlVoiceInputCoordinator.rightOptionKeyCode,
      modifiers: [.option]
    )
    XCTAssertTrue(coordinator.handleKeyEvent(pressRightOption))
    XCTAssertTrue(coordinator.isHoldingRightOption)

    // While physicalHeld is true, polling keeps .holding
    coordinator.pollPhysicalRightOptionReleaseIfNeeded()
    XCTAssertTrue(coordinator.isHoldingRightOption)
    XCTAssertEqual(mockRecorder.stopRecordingCallCount, 0)

    // When physical key is released without a flagsChanged event (e.g. focus shift), polling finishes recording
    physicalHeld = false
    coordinator.pollPhysicalRightOptionReleaseIfNeeded()
    XCTAssertFalse(coordinator.isHoldingRightOption)
    XCTAssertEqual(mockRecorder.stopRecordingCallCount, 1)
  }

  // MARK: - 7. Voice ASR Settings & DeepSeek Profile Key Reuse

  func testSaveVoiceASRSettingsPersistsKeyEndpointAndModel() {
    let suiteName = "OwlVoiceASRSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var savedKey: String?
    let res = OwlSettingsActions.saveVoiceASRSettings(
      providerID: "openai",
      endpoint: " https://api.openai.com/v1/audio/transcriptions ",
      model: " gpt-4o-mini-transcribe ",
      apiKey: " sk-openai-secret-999 ",
      isKeyAlreadyConfigured: false,
      saveKey: { savedKey = $0 },
      defaults: defaults
    )

    XCTAssertEqual(savedKey, "sk-openai-secret-999")
    XCTAssertEqual(res.input, "", "Write-only Keychain input must clear after save")
    XCTAssertEqual(res.endpoint, "https://api.openai.com/v1/audio/transcriptions")
    XCTAssertEqual(res.model, "gpt-4o-mini-transcribe")
    XCTAssertTrue(res.status.contains("已保存"))
    XCTAssertEqual(defaults.string(forKey: OwlVoiceSettings.asrEndpointKey), "https://api.openai.com/v1/audio/transcriptions")
    XCTAssertEqual(defaults.string(forKey: OwlVoiceSettings.asrModelKey), "gpt-4o-mini-transcribe")

    // Updating model while key is already configured and input is blank preserves existing key
    var overwriteCount = 0
    let updateRes = OwlSettingsActions.saveVoiceASRSettings(
      providerID: "openai",
      endpoint: "https://api.openai.com/v1/audio/transcriptions",
      model: "gpt-4o-transcribe",
      apiKey: "",
      isKeyAlreadyConfigured: true,
      saveKey: { _ in overwriteCount += 1 },
      defaults: defaults
    )
    XCTAssertEqual(overwriteCount, 0)
    XCTAssertEqual(updateRes.model, "gpt-4o-transcribe")
    XCTAssertEqual(defaults.string(forKey: OwlVoiceSettings.asrModelKey), "gpt-4o-transcribe")

    // OpenAI Login mode saves without requiring an API key
    let loginRes = OwlSettingsActions.saveVoiceASRSettings(
      providerID: "openai-login",
      endpoint: "",
      model: "",
      apiKey: "",
      isKeyAlreadyConfigured: false,
      saveKey: { _ in XCTFail("OpenAI Login mode must not write a Keychain API key") },
      defaults: defaults
    )
    XCTAssertEqual(loginRes.endpoint, "https://chatgpt.com/backend-api/transcribe")
    XCTAssertEqual(loginRes.model, "chatgpt-dictation")
    XCTAssertTrue(loginRes.status.contains("Codex 登录态"))

    // Rejects non-https endpoint
    let insecure = OwlSettingsActions.saveVoiceASRSettings(
      providerID: "openai",
      endpoint: "http://api.openai.com/v1/audio/transcriptions",
      model: "gpt-4o-mini-transcribe",
      apiKey: "sk-123",
      isKeyAlreadyConfigured: false,
      saveKey: { _ in XCTFail("Must not save key on invalid endpoint") },
      defaults: defaults
    )
    XCTAssertEqual(insecure.status, "端点必须是 https。")

    var deleted = false
    let clearStatus = OwlSettingsActions.clearVoiceASRAPIKey(providerID: "openai", deleteKey: { deleted = true })
    XCTAssertTrue(deleted)
    XCTAssertEqual(clearStatus, "已清除 OpenAI API Key。")
  }

  func testGrokASRClientFollowsLiveVoiceSettingsWhenNotExplicitlyOverridden() async throws {
    let savedProvider = OwlDefaults.standard.object(forKey: OwlVoiceSettings.asrProviderIDKey)
    let savedEndpoint = OwlDefaults.standard.object(forKey: OwlVoiceSettings.asrEndpointKey)
    let savedModel = OwlDefaults.standard.object(forKey: OwlVoiceSettings.asrModelKey)
    defer {
      if let savedProvider { OwlDefaults.standard.set(savedProvider, forKey: OwlVoiceSettings.asrProviderIDKey) }
      else { OwlDefaults.standard.removeObject(forKey: OwlVoiceSettings.asrProviderIDKey) }
      if let savedEndpoint { OwlDefaults.standard.set(savedEndpoint, forKey: OwlVoiceSettings.asrEndpointKey) }
      else { OwlDefaults.standard.removeObject(forKey: OwlVoiceSettings.asrEndpointKey) }
      if let savedModel { OwlDefaults.standard.set(savedModel, forKey: OwlVoiceSettings.asrModelKey) }
      else { OwlDefaults.standard.removeObject(forKey: OwlVoiceSettings.asrModelKey) }
    }

    OwlVoiceSettings.asrProviderID = "openai"
    OwlVoiceSettings.asrEndpoint = "https://custom.openai.example/v1/audio/transcriptions"
    OwlVoiceSettings.asrModel = "gpt-4o-mini-transcribe"

    let stubTransport = OwlStubVoiceTransport { req in
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data("{\"text\": \"测试动态配置\"}".utf8), resp)
    }
    let client = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "sk-test" })
    let wav = OwlWAVPacker.pack16kMono(pcmData: Data([0x01, 0x02]))
    _ = try await client.transcribe(audioWavData: wav, prompt: nil)

    let req = try XCTUnwrap(stubTransport.recordedRequests.first)
    XCTAssertEqual(req.url?.absoluteString, "https://custom.openai.example/v1/audio/transcriptions")
    let bodyStr = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
    XCTAssertTrue(bodyStr.contains("name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n"))
  }

  func testConfiguredGeminiProviderProfileAutoSwitchesVoiceASRAndFormatsErrorsWithGeminiName() throws {
    let suiteName = "OwlVoiceAutoGeminiTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = OwlProviderProfileStore(root: tempDir)
    let geminiProfile = try store.add(OwlProviderProfile(
      displayName: "Google Gemini",
      endpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!,
      model: "gemini-3.8-flash",
      providerID: "gemini",
      isDefault: true
    ))

    final class InMemorySecrets: OwlSecretStoring {
      var values: [String: String] = [:]
      func secret(named name: String) throws -> String? { values[name] }
      func setSecret(_ value: String, named name: String) throws { values[name] = value }
      func deleteSecret(named name: String) throws { values.removeValue(forKey: name) }
    }
    let secrets = InMemorySecrets()
    try secrets.setSecret("AIza-gemini-key", named: geminiProfile.secretName)

    // Even when defaults had no ASR provider or had unconfigured "openai" or legacy "grok",
    // resolvedASRProviderID automatically selects "gemini" because the user configured Gemini!
    XCTAssertEqual(
      OwlVoiceSettings.resolvedASRProviderID(defaults: defaults, store: store, secrets: secrets),
      "gemini"
    )
    defaults.set("grok", forKey: OwlVoiceSettings.asrProviderIDKey)
    XCTAssertEqual(
      OwlVoiceSettings.resolvedASRProviderID(defaults: defaults, store: store, secrets: secrets),
      "gemini"
    )
    defaults.set("openai", forKey: OwlVoiceSettings.asrProviderIDKey)
    XCTAssertEqual(
      OwlVoiceSettings.resolvedASRProviderID(defaults: defaults, store: store, secrets: secrets),
      "gemini"
    )

    // Verify OwlVoiceError uses the active preset name instead of hardcoded "xAI"
    let savedProvider = OwlDefaults.standard.object(forKey: OwlVoiceSettings.asrProviderIDKey)
    defer {
      if let savedProvider { OwlDefaults.standard.set(savedProvider, forKey: OwlVoiceSettings.asrProviderIDKey) }
      else { OwlDefaults.standard.removeObject(forKey: OwlVoiceSettings.asrProviderIDKey) }
    }
    OwlVoiceSettings.asrProviderID = "gemini"
    XCTAssertEqual(
      OwlVoiceError.missingAPIKey.errorDescription,
      "未配置 Gemini API Key，请在 AI 设置中配置。"
    )
    XCTAssertEqual(
      OwlVoiceError.invalidToken(status: 401, message: "bad key").errorDescription,
      "Google Gemini 认证失败 (401): bad key"
    )
    XCTAssertEqual(
      OwlVoiceError.badHTTPStatus(status: 503, message: "unavailable").errorDescription,
      "Google Gemini 语音服务响应异常 (503): unavailable"
    )
  }

  func testVoiceKeychainReadsConfiguredDeepSeekProfileKey() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = OwlProviderProfileStore(root: tempDir)
    let profile = try store.add(OwlProviderProfile(
      displayName: "DeepSeek",
      endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
      model: "deepseek-chat",
      providerID: "deepseek",
      isDefault: true
    ))

    final class InMemorySecrets: OwlSecretStoring {
      var values: [String: String] = [:]
      func secret(named name: String) throws -> String? { values[name] }
      func setSecret(_ value: String, named name: String) throws { values[name] = value }
      func deleteSecret(named name: String) throws { values.removeValue(forKey: name) }
    }
    let secrets = InMemorySecrets()
    try secrets.setSecret(" sk-deepseek-from-profile ", named: profile.secretName)

    let resolved = OwlVoiceKeychain.readConfiguredDeepSeekProfileKey(store: store, secrets: secrets)
    XCTAssertEqual(resolved, "sk-deepseek-from-profile")
  }

  func testThreePresetASRCatalogOpenAIGeminiAndOpenAILogin() throws {
    XCTAssertEqual(
      OwlVoiceASRCatalog.presets.map(\.id),
      ["openai", "gemini", "openai-login"]
    )
    XCTAssertEqual(OwlVoiceASRCatalog.preset(id: "openai").defaultModel, "gpt-transcribe")
    XCTAssertEqual(OwlVoiceASRCatalog.preset(id: "gemini").defaultModel, "gemini-3.5-transcribe")
    XCTAssertTrue(OwlVoiceASRCatalog.preset(id: "openai").sharesProviderProfileKey)
    XCTAssertTrue(OwlVoiceASRCatalog.preset(id: "openai").requiresAPIKey)
    XCTAssertTrue(OwlVoiceASRCatalog.preset(id: "gemini").sharesProviderProfileKey)
    XCTAssertTrue(OwlVoiceASRCatalog.preset(id: "gemini").requiresAPIKey)
    XCTAssertFalse(OwlVoiceASRCatalog.preset(id: "openai-login").sharesProviderProfileKey)
    XCTAssertTrue(OwlVoiceASRCatalog.preset(id: "openai-login").isOpenAILogin)
    // Legacy/retired preset IDs fall back to OpenAI
    XCTAssertEqual(OwlVoiceASRCatalog.preset(id: "grok").id, "openai")

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = OwlProviderProfileStore(root: tempDir)
    let openAIProfile = try store.add(OwlProviderProfile(
      displayName: "OpenAI",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      providerID: "openai",
      isDefault: true
    ))
    let geminiProfile = try store.add(OwlProviderProfile(
      displayName: "Google Gemini",
      endpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!,
      model: "gemini-3.8-flash",
      providerID: "gemini",
      isDefault: false
    ))

    final class InMemorySecrets: OwlSecretStoring {
      var values: [String: String] = [:]
      func secret(named name: String) throws -> String? { values[name] }
      func setSecret(_ value: String, named name: String) throws { values[name] = value }
      func deleteSecret(named name: String) throws { values.removeValue(forKey: name) }
    }
    let secrets = InMemorySecrets()
    try secrets.setSecret(" sk-openai-from-provider-profile ", named: openAIProfile.secretName)
    try secrets.setSecret(" AIza-gemini-from-provider-profile ", named: geminiProfile.secretName)

    XCTAssertEqual(
      try OwlVoiceKeychain.readAPIKey(forProviderID: "openai", store: store, secrets: secrets),
      "sk-openai-from-provider-profile"
    )
    XCTAssertEqual(
      try OwlVoiceKeychain.readAPIKey(forProviderID: "gemini", store: store, secrets: secrets),
      "AIza-gemini-from-provider-profile"
    )
    XCTAssertNil(
      try OwlVoiceKeychain.readAPIKey(forProviderID: "openai-login", store: store, secrets: secrets)
    )
    XCTAssertTrue(OwlVoiceKeychain.isASRKeyConfigured(forProviderID: "openai", store: store, secrets: secrets))
    XCTAssertTrue(OwlVoiceKeychain.isASRKeyConfigured(forProviderID: "gemini", store: store, secrets: secrets))
    XCTAssertFalse(OwlVoiceKeychain.isASRKeyConfigured(forProviderID: "openai-login", store: store, secrets: secrets))

    // Verify OpenAI Login status state machine & JWT claim extraction
    XCTAssertEqual(OwlVoiceOpenAILoginStatus.unchecked.statusText, "尚未检查 Codex 登录")
    XCTAssertEqual(OwlVoiceOpenAILoginStatus.signedIn(plan: "plus").statusText, "Codex 已用 ChatGPT 账号登录 · plus")
    XCTAssertTrue(OwlVoiceOpenAILoginStatus.signedIn(plan: "plus").isReady)
    XCTAssertTrue(OwlVoiceOpenAILoginStatus.signedOut.needsTerminalLogin)
    XCTAssertTrue(OwlVoiceOpenAILoginStatus.cliMissing.needsTerminalLogin)
    XCTAssertTrue(OwlVoiceOpenAILoginStatus.notChatGPT(method: "apikey").needsTerminalLogin)
  }
}
