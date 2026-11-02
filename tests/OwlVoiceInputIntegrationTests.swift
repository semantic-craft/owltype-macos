//
//  OwlVoiceInputIntegrationTests.swift
//  OwltypeTests — Lane B: Voice Input Gesture Coordinator & Integration Tests (#393)
//

import AppKit
import InputMethodKit
import XCTest
@testable import Owltype

@MainActor
final class OwlVoiceInputIntegrationTests: XCTestCase {

  // MARK: - 1. Hold-to-Speak Workflow

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

    // Custom matcher: keyCode 9 (V) with command
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

    // Step 2: Wait > 300ms, then KeyUp -> Triggers transcription
    try await Task.sleep(nanoseconds: 350_000_000) // 350ms
    let keyUpEvent = try makeKeyEvent(type: .keyUp, keyCode: 9, modifiers: .command)
    let consumedUp = coordinator.handleKeyEvent(keyUpEvent)
    XCTAssertTrue(consumedUp)

    // Wait for async ASR task
    for _ in 0..<30 {
      if !mockClient.insertedTexts.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTAssertEqual(mockClient.insertedTexts, ["测试语音输入上屏"])
  }

  // MARK: - 2. Hands-Free Space Lock Workflow

  func testHandsFreeSpaceLockWorkflow() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
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

  // MARK: - 3. Click-to-Toggle Workflow

  func testClickToToggleWorkflow() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"单击切换转写\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot(client: mockClient) }
    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    // 1. Down -> .holding
    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(down))

    // 2. Up immediately (<300ms) -> .toggled
    let up = try makeKeyEvent(type: .keyUp, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(up))
    guard case .toggled = coordinator.mode else {
      return XCTFail("Expected .toggled, got \(coordinator.mode)")
    }
    XCTAssertTrue(mockRecorder.isRecording)

    // 3. Second Click Down -> Finishes recording
    let finishDown = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(finishDown))

    for _ in 0..<30 {
      if !mockClient.insertedTexts.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(mockClient.insertedTexts, ["单击切换转写"])
  }

  // MARK: - 4. Esc Cancellation

  func testEscCancellationDuringRecording() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot(client: mockClient) }
    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    // Start
    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(down))
    XCTAssertTrue(mockRecorder.isRecording)

    // Esc (keyCode 53)
    let esc = try makeKeyEvent(type: .keyDown, keyCode: 53)
    let consumedEsc = coordinator.handleKeyEvent(esc)
    XCTAssertTrue(consumedEsc)
    XCTAssertEqual(coordinator.mode, .idle)
    XCTAssertFalse(mockRecorder.isRecording)
    XCTAssertEqual(mockRecorder.cancelRecordingCallCount, 1)
    XCTAssertTrue(mockClient.insertedTexts.isEmpty)
  }

  // MARK: - 5. Secure Input Mode Guard

  func testSecureInputModeGuard() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.secureInputChecker = { true } // Secure mode active

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder
    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(down))
    XCTAssertEqual(coordinator.mode, .idle)
    XCTAssertEqual(mockRecorder.startRecordingCallCount, 0)
  }

  // MARK: - 6. Text Insertion Ladder

  func testDirectClientInsertion() {
    let coordinator = OwlVoiceInputCoordinator()
    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot(client: mockClient) }
    coordinator.startVoiceInput()

    coordinator.deliverFinalText("直接上屏测试")
    XCTAssertEqual(mockClient.insertedTexts, ["直接上屏测试"])
  }

  // MARK: - 7. Adversarial Challenges (Gesture & HUD)

  func testEscTakesUnconditionalPrecedenceOverHandsFreeLock() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    // 1. Shortcut Down -> .holding
    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(down))
    guard case .holding = coordinator.mode else { return XCTFail() }

    // 2. Space Down -> .handsFreeLocked
    let space = try makeKeyEvent(type: .keyDown, keyCode: 49) // Space
    XCTAssertTrue(coordinator.handleKeyEvent(space))
    guard case .handsFreeLocked = coordinator.mode else {
      return XCTFail("Expected .handsFreeLocked")
    }
    XCTAssertTrue(mockRecorder.isRecording)

    // 3. Esc Down -> Must unconditionally cancel hands-free lock
    let esc = try makeKeyEvent(type: .keyDown, keyCode: 53) // Esc
    let consumedEsc = coordinator.handleKeyEvent(esc)
    XCTAssertTrue(consumedEsc, "Esc must be consumed even when locked in hands-free mode")
    XCTAssertEqual(coordinator.mode, .idle, "Mode must reset to .idle immediately on Esc")
    XCTAssertFalse(mockRecorder.isRecording, "Audio recording must be stopped")
    XCTAssertEqual(mockRecorder.cancelRecordingCallCount, 1, "cancelRecording must be invoked")
  }

  func testClickStormRapidShortcutTogglingDoesNotRaceOrLeak() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder
    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    // Rapid storm: 20 rapid down/up transitions simulating erratic user tapping
    for _ in 0..<10 {
      let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
      _ = coordinator.handleKeyEvent(down)
      let up = try makeKeyEvent(type: .keyUp, keyCode: 9)
      _ = coordinator.handleKeyEvent(up)
    }

    // After storm, an unconditional Esc must safely restore idle state
    let esc = try makeKeyEvent(type: .keyDown, keyCode: 53)
    _ = coordinator.handleKeyEvent(esc)
    XCTAssertEqual(coordinator.mode, .idle)
    XCTAssertFalse(mockRecorder.isRecording)
  }

  func testHostAppTerminationSafeFallbackInsertion() {
    let coordinator = OwlVoiceInputCoordinator()
    // Simulated dead client (nil client, nil frontmostApp)
    coordinator.targetSnapshotProvider = {
      OwlVoiceTargetSnapshot(client: nil, frontmostApp: nil)
    }
    coordinator.startVoiceInput()

    // Must not crash, but safely write to clipboard / fallback
    coordinator.deliverFinalText("宿主崩溃容错测试")
    XCTAssertEqual(coordinator.mode, .completed(finalText: "宿主崩溃容错测试"))
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "宿主崩溃容错测试")
  }

  func testSecureInputModeZeroArmZeroAudioCapture() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.secureInputChecker = { true } // Password field active

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder
    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    let handled = coordinator.handleKeyEvent(down)
    XCTAssertTrue(handled)
    XCTAssertEqual(coordinator.mode, .idle, "Must never transition away from idle in secure input")
    XCTAssertEqual(mockRecorder.startRecordingCallCount, 0, "Must not arm audio recording")
    XCTAssertFalse(mockRecorder.isRecording)
    XCTAssertNil(coordinator.targetSnapshot, "Must not snapshot host input field in secure input")
  }

  func testMisTouchShortDurationAbortsWithoutNetwork() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    mockRecorder.simulatedDuration = 0.15 // 150ms < 300ms
    mockRecorder.simulatedPeakRMS = 0.2
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport()
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    // KeyDown -> starts recording (.holding)
    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(down))
    guard case .holding = coordinator.mode else { return XCTFail() }

    // Simulate hold for > 300ms coordinator elapsed time, but recorder measures 150ms
    try await Task.sleep(nanoseconds: 350_000_000)
    let up = try makeKeyEvent(type: .keyUp, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(up))

    try await Task.sleep(nanoseconds: 50_000_000)

    // Coordinator must catch recordingTooShort, abort, reset to idle, and make ZERO network requests
    XCTAssertEqual(coordinator.mode, .idle, "Mode must reset to idle on short duration abort")
    XCTAssertEqual(stubTransport.recordedRequests.count, 0, "Must not perform any network calls")
    XCTAssertFalse(mockRecorder.isRecording)
  }

  func testMisTouchSilenceAbortsWithoutNetwork() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    mockRecorder.simulatedDuration = 1.0 // 1.0s >= 300ms
    mockRecorder.simulatedPeakRMS = 0.003 // Below 0.008 silence threshold
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport()
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    // KeyDown -> starts recording (.holding)
    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(down))
    guard case .holding = coordinator.mode else { return XCTFail() }

    // Wait > 300ms, then KeyUp
    try await Task.sleep(nanoseconds: 350_000_000)
    let up = try makeKeyEvent(type: .keyUp, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(up))

    try await Task.sleep(nanoseconds: 50_000_000)

    // Coordinator must catch pureSilence, abort, reset to idle, and make ZERO network requests
    XCTAssertEqual(coordinator.mode, .idle, "Mode must reset to idle on pure silence abort")
    XCTAssertEqual(stubTransport.recordedRequests.count, 0, "Must not perform any network calls")
    XCTAssertFalse(mockRecorder.isRecording)
  }

  func testRapidSuccessiveKeyEventsChaosStress() throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport()
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    let keyCodes: [UInt16] = [9, 9, 49, 9, 53, 9, 49, 53, 9, 9, 9]
    let types: [NSEvent.EventType] = [.keyDown, .keyUp]

    for round in 0..<20 {
      for kc in keyCodes {
        let t = types[round % 2]
        let event = try makeKeyEvent(type: t, keyCode: kc)
        _ = coordinator.handleKeyEvent(event)
      }
    }

    // After all chaotic events, cancelVoiceInput must return cleanly to .idle
    coordinator.cancelVoiceInput()
    XCTAssertEqual(coordinator.mode, .idle)
    XCTAssertFalse(mockRecorder.isRecording)
  }

  // MARK: - 8. Milestone M5 Adversarial Challenges (#398)

  func testEscCancellationDuringPolishingPhaseAbortsAndDismissesHUD() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.isPolishEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"嗯那个今天天气很好啊\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    let trackingPanel = TestTrackingVoiceCapsulePanel()
    coordinator.hudPanel = trackingPanel

    let mockPolisher = OwlMockVoicePolisher()
    mockPolisher.delayNanoseconds = 500_000_000 // 500ms delay to keep in .polishing
    mockPolisher.polishHandler = { raw, _, _ in
      return "今天天气很好。"
    }
    coordinator.postProcessor = mockPolisher

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot(client: mockClient) }
    coordinator.shortcutMatcher = { $0.keyCode == 9 }

    // Start recording
    let down = try makeKeyEvent(type: .keyDown, keyCode: 9)
    XCTAssertTrue(coordinator.handleKeyEvent(down))
    guard case .holding = coordinator.mode else { return XCTFail() }

    // Finish recording -> starts transcription
    coordinator.finishRecordingAndTranscribe()

    // Wait until coordinator enters .polishing
    var reachedPolishing = false
    for _ in 0..<50 {
      if case .polishing = coordinator.mode {
        reachedPolishing = true
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000) // 10ms
    }
    XCTAssertTrue(reachedPolishing, "Coordinator must transition to .polishing")
    XCTAssertEqual(coordinator.mode, .polishing(rawTranscript: "嗯那个今天天气很好啊"))
    XCTAssertEqual(trackingPanel.viewModel.state, .polishing(rawTranscript: "嗯那个今天天气很好啊"))

    // User presses Esc (keyCode 53) while in .polishing
    let esc = try makeKeyEvent(type: .keyDown, keyCode: 53)
    let handledEsc = coordinator.handleKeyEvent(esc)
    XCTAssertTrue(handledEsc, "Esc must be consumed in .polishing")

    // Immediately verify state is reset to idle and HUD is dismissed
    XCTAssertEqual(coordinator.mode, .idle, "Mode must reset to .idle immediately upon Esc")
    XCTAssertEqual(trackingPanel.viewModel.state, .idle, "HUD state must reset to .idle")
    XCTAssertNil(coordinator.targetSnapshot, "targetSnapshot must be cleared")

    // Wait long enough for the 500ms delay to complete
    try await Task.sleep(nanoseconds: 600_000_000)

    // Verify NOTHING was inserted into host input field
    XCTAssertTrue(mockClient.insertedTexts.isEmpty, "Zero text must be inserted into host field on Esc cancellation, got \(mockClient.insertedTexts)")
    XCTAssertEqual(coordinator.mode, .idle, "Mode must stay .idle and not resurrect")
  }

  func testHotwordPropagationToASRPromptAndDeepSeekPolisher() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.isPolishEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"明天去语义工坊开会\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }
    let asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })
    coordinator.asrClient = asrClient

    let mockExtractor = OwlMockHotwordsExtractor()
    mockExtractor.hotwordsToReturn = ["语义工坊", "DeepSeek", "张伟"]
    coordinator.hotwordsExtractor = mockExtractor

    let mockPolisher = OwlMockVoicePolisher()
    mockPolisher.polishHandler = { raw, hotwords, preContext in
      return "明天去语义工坊开会。"
    }
    coordinator.postProcessor = mockPolisher

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = {
      OwlVoiceTargetSnapshot(client: mockClient, preContext: "关于项目计划，")
    }

    coordinator.startVoiceInput()
    coordinator.finishRecordingAndTranscribe()

    // Wait for completion
    for _ in 0..<50 {
      if !mockClient.insertedTexts.isEmpty { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    // 1. Verify hotwordsExtractor extractHotwords was invoked with limit: 50
    XCTAssertEqual(mockExtractor.lastExtractLimit, 50, "Coordinator must request up to 50 hotwords")

    // 2. Verify prompt sent to ASR contains hotwords & preContext
    XCTAssertEqual(mockExtractor.lastBuiltPreContext, "关于项目计划，")
    XCTAssertEqual(mockExtractor.lastBuiltHotwords, ["语义工坊", "DeepSeek", "张伟"])
    XCTAssertEqual(mockExtractor.lastBuiltMaxBytes, 800)

    // 3. Verify polisher received rawTranscript, hotwords, and preContext
    XCTAssertEqual(mockPolisher.recordedCalls.count, 1)
    if let call = mockPolisher.recordedCalls.first {
      XCTAssertEqual(call.raw, "明天去语义工坊开会")
      XCTAssertEqual(call.hotwords, ["语义工坊", "DeepSeek", "张伟"])
      XCTAssertEqual(call.preContext, "关于项目计划，")
    }

    // 4. Verify polished text delivered to client
    XCTAssertEqual(mockClient.insertedTexts, ["明天去语义工坊开会。"])
  }

  func testSettingsToggleDisablingSkipsLLMAndTransitionsDirectly() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.isPolishEnabledOverride = false // Polish disabled

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"这是原始转写文本\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    let trackingPanel = TestTrackingVoiceCapsulePanel()
    coordinator.hudPanel = trackingPanel

    let mockPolisher = OwlMockVoicePolisher()
    coordinator.postProcessor = mockPolisher

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot(client: mockClient) }

    coordinator.startVoiceInput()
    coordinator.finishRecordingAndTranscribe()

    for _ in 0..<50 {
      if !mockClient.insertedTexts.isEmpty { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    // Verify polisher was NEVER called (zero LLM requests)
    XCTAssertEqual(mockPolisher.recordedCalls.count, 0, "Must dispatch zero LLM requests when polish is disabled")

    // Verify raw transcript inserted
    XCTAssertEqual(mockClient.insertedTexts, ["这是原始转写文本"], "Must insert raw transcript directly")

    // Verify HUD transitions directly from recognizing to final text delivery (no .polishing)
    let polishingStates = trackingPanel.recordedStates.filter { state in
      if case .polishing = state { return true }
      return false
    }
    XCTAssertTrue(polishingStates.isEmpty, "HUD must transition directly without entering .polishing state when polish is disabled, but recorded: \(trackingPanel.recordedStates)")
  }

  func testPolishErrorGracefulDegradationInsertsRawTranscript() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.isPolishEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"口语转写原始\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    let mockPolisher = OwlMockVoicePolisher()
    mockPolisher.polishHandler = { _, _, _ in
      throw OwlVoiceError.networkTimeout
    }
    coordinator.postProcessor = mockPolisher

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot(client: mockClient) }

    coordinator.startVoiceInput()
    coordinator.finishRecordingAndTranscribe()

    for _ in 0..<50 {
      if !mockClient.insertedTexts.isEmpty { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    // Must gracefully fall back to raw transcript: zero text loss!
    XCTAssertEqual(mockClient.insertedTexts, ["口语转写原始"])
  }

  func testEscCancellationWithFailingPolisherDoesNotResurrectHUDOrInsertText() async throws {
    let coordinator = OwlVoiceInputCoordinator()
    coordinator.isEnabledOverride = true
    coordinator.isPolishEnabledOverride = true

    let mockRecorder = OwlMockAudioRecorder()
    coordinator.audioRecorder = mockRecorder

    let stubTransport = OwlStubVoiceTransport { req in
      let json = "{\"text\": \"测试文本\"}"
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(json.utf8), resp)
    }
    coordinator.asrClient = OwlVoiceGrokASRClient(transport: stubTransport, apiKeyProvider: { "mock-key" })

    let trackingPanel = TestTrackingVoiceCapsulePanel()
    coordinator.hudPanel = trackingPanel

    let mockPolisher = OwlMockVoicePolisher()
    mockPolisher.delayNanoseconds = 200_000_000 // 200ms
    mockPolisher.polishHandler = { _, _, _ in
      throw OwlVoiceError.networkTimeout
    }
    coordinator.postProcessor = mockPolisher

    let mockClient = MockVoiceTextInputClient()
    coordinator.targetSnapshotProvider = { OwlVoiceTargetSnapshot(client: mockClient) }

    coordinator.startVoiceInput()
    coordinator.finishRecordingAndTranscribe()

    // Wait until .polishing
    for _ in 0..<50 {
      if case .polishing = coordinator.mode { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(coordinator.mode, .polishing(rawTranscript: "测试文本"))

    // Esc pressed
    let esc = try makeKeyEvent(type: .keyDown, keyCode: 53)
    XCTAssertTrue(coordinator.handleKeyEvent(esc))
    XCTAssertEqual(coordinator.mode, .idle)

    // Wait for polisher task to fail
    try await Task.sleep(nanoseconds: 350_000_000)

    // Verify zero text inserted into host client
    XCTAssertTrue(mockClient.insertedTexts.isEmpty, "No text must be inserted when cancelled, got \(mockClient.insertedTexts)")
    XCTAssertEqual(coordinator.mode, .idle, "Mode must remain .idle")
  }

  // MARK: - Helper

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
}

// MARK: - Mock IMKTextInput Client

final class MockVoiceTextInputClient: NSObject, IMKTextInput {
  var insertedTexts: [String] = []
  var replacementRanges: [NSRange] = []

  func insertText(_ string: Any!, replacementRange: NSRange) {
    if let str = string as? String {
      insertedTexts.append(str)
      replacementRanges.append(replacementRange)
    }
  }

  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
  func length() -> Int { 0 }
  func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
  func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { nil }
  func validAttributesForMarkedText() -> [Any]! { [] }
  func overrideKeyboard(withKeyboardNamed name: String!) {}
  func selectMode(_ modeIdentifier: String!) {}
  func supportsUnicode() -> Bool { true }
  func bundleIdentifier() -> String! { "com.test.app" }
  func windowLevel() -> CGWindowLevel { 0 }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
  func uniqueClientIdentifierString() -> String! { "com.test.app" }
  func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

// MARK: - M5 Test Mocks

@MainActor
final class TestTrackingVoiceCapsulePanel: OwlVoiceCapsulePanel {
  var recordedStates: [OwlVoiceCapsuleState] = []

  override func present(state: OwlVoiceCapsuleState, anchor: NSRect) {
    recordedStates.append(state)
    super.present(state: state, anchor: anchor)
  }

  override func updateState(_ state: OwlVoiceCapsuleState, anchor: NSRect? = nil) {
    recordedStates.append(state)
    super.updateState(state, anchor: anchor)
  }
}

final class OwlMockVoicePolisher: OwlVoicePolishServiceProtocol, @unchecked Sendable {
  var polishHandler: ((String, [String], String?) async throws -> String)?
  var recordedCalls: [(raw: String, hotwords: [String], preContext: String?)] = []
  var delayNanoseconds: UInt64 = 0

  func polish(rawTranscript: String, hotwords: [String], preContext: String?) async throws -> String {
    recordedCalls.append((rawTranscript, hotwords, preContext))
    if delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    if let polishHandler {
      return try await polishHandler(rawTranscript, hotwords, preContext)
    }
    return rawTranscript
  }
}

final class OwlMockHotwordsExtractor: OwlVoiceHotwordsExtracting, @unchecked Sendable {
  var hotwordsToReturn: [String] = []
  var lastExtractLimit: Int?
  var lastBuiltPreContext: String?
  var lastBuiltHotwords: [String]?
  var lastBuiltMaxBytes: Int?

  func extractHotwords(limit: Int) -> [String] {
    lastExtractLimit = limit
    return Array(hotwordsToReturn.prefix(limit))
  }

  func buildPrompt(preContext: String?, hotwords: [String]?, maxBytes: Int) -> String {
    lastBuiltPreContext = preContext
    lastBuiltHotwords = hotwords
    lastBuiltMaxBytes = maxBytes
    return "prompt:\(hotwords?.joined(separator: ",") ?? "")"
  }
}

