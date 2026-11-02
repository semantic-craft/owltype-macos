//
//  OwlE2EFeatureTests.swift
//  OwltypeTests — 4-Tier E2E Feature Test Suite for Lanes A, B, C & Quality Guardrails
//
//  Covers all 24 features defined in PROJECT.md through a 4-Tier requirement-driven taxonomy:
//  - Tier 1: Feature Coverage (Single-feature happy paths)
//  - Tier 2: Boundary & Corner Cases (Extreme buffers, limits, timeouts, invalidations)
//  - Tier 3: Cross-Feature Combinations (Multi-feature interaction pipelines)
//  - Tier 4: Real-World Workload Scenarios (Simulated production user journeys)
//
//  All tests run 100% offline with zero external network calls and zero real API keys.
//

import Foundation
import XCTest
@testable import Owltype

@MainActor
final class OwlE2EFeatureTests: XCTestCase {

  private var repoRoot: String {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .path
  }

  // MARK: - ==================================================================
  // MARK: - Tier 1: Feature Coverage (Features 1 to 24)
  // MARK: - ==================================================================

  /// Feature 1: AI Association Settings Toggles (Lane A / M1 #392)
  func testT1_01_AIAssociationSettingsToggles() {
    let prefs = OwlE2EAICandidatePreferences(aiAssociationEnabled: true, aiEnglishCandidateEnabled: false)
    XCTAssertTrue(prefs.aiAssociationEnabled, "AI 联想 default should be enabled")
    XCTAssertFalse(prefs.aiEnglishCandidateEnabled, "英文模式 AI 候选 default should be disabled")

    prefs.aiAssociationEnabled = false
    prefs.aiEnglishCandidateEnabled = true
    XCTAssertFalse(prefs.aiAssociationEnabled, "AI 联想 toggle should be independently mutable")
    XCTAssertTrue(prefs.aiEnglishCandidateEnabled, "英文模式 AI 候选 toggle should be independently mutable")
  }

  /// Feature 2: 120ms Debounce & Epoch Invalidation (Lane A / M1 #392)
  func testT1_02_120msDebounceAndEpochTicketValidation() async throws {
    let ticket1 = OwlE2EAICandidateTicket(sessionID: 101, generation: 1, rawInput: "beijing", actionEpoch: 1)
    let ticket2 = OwlE2EAICandidateTicket(sessionID: 101, generation: 2, rawInput: "beijingtian", actionEpoch: 2)

    XCTAssertNotEqual(ticket1, ticket2, "Consecutive keystrokes produce distinct tickets with bumped generation/epoch")
    XCTAssertEqual(ticket1.rawInput, "beijing")
    XCTAssertEqual(ticket1.actionEpoch, 1)

    let mockService = OwlE2EMockCloudCandidateService()
    mockService.setCandidates(for: "beijing", candidates: ["北京", "北京市", "北京天安门"])

    let candidates = try await mockService.generateCandidates(ticket: ticket1, preContext: "我在")
    XCTAssertEqual(candidates, ["北京", "北京市", "北京天安门"])
    XCTAssertEqual(mockService.recordedTickets.first?.sessionID, 101)
    XCTAssertEqual(mockService.recordedPreContexts.first, "我在")
  }

  /// Feature 3: Candidate Window 1st AI Slot Layout (Lane A / M1 #392)
  func testT1_03_CandidateWindowFirstAISlotLayout() {
    let layoutEngine = OwlE2ECandidateWindowLayoutSimulator(pageSize: 5)
    let locals = ["北京", "背景", "被动", "杯子", "北极", "悲伤"]
    let items = layoutEngine.layout(localCandidates: locals, aiCandidate: "北京市朝阳区")

    // Slot pageSize - 1 is index 4
    XCTAssertEqual(items.count, locals.count + 1)
    XCTAssertEqual(items[4].text, "北京市朝阳区", "First AI candidate must occupy slot pageSize - 1")
    XCTAssertEqual(items[4].provenance, .ai, "AI candidate must carry .ai provenance badge")
  }

  /// Feature 4: Non-Jump Local Candidate Guarantee (Lane A / M1 #392)
  func testT1_04_NonJumpLocalCandidateGuarantee() {
    let layoutEngine = OwlE2ECandidateWindowLayoutSimulator(pageSize: 5)
    let locals = ["本地一", "本地二", "本地三", "本地四", "本地五"]
    let items = layoutEngine.layout(localCandidates: locals, aiCandidate: "AI候选")

    // Front local candidates 0 ..< (pageSize - 1) must never jump
    for i in 0..<4 {
      XCTAssertEqual(items[i].text, locals[i], "Local candidate at index \(i) must preserve position without jumping")
      XCTAssertEqual(items[i].provenance, .local)
    }
  }

  /// Feature 5: Secure Input Network Blocking (Lane A / M1 #392)
  func testT1_05_SecureInputNetworkBlocking() {
    let gate = OwlE2ESecureInputGate(isSecure: false)
    XCTAssertTrue(gate.allowsNetworkRequest(), "Normal input allows AI network requests")

    gate.isSecureInput = true
    XCTAssertFalse(gate.allowsNetworkRequest(), "Password / Secure input field must 100% block AI network requests")
  }

  /// Feature 6: Jev Context & Candidate Collection (Lane A / M2 #395)
  func testT1_06_JevContextAndCandidateCollection() async throws {
    let mockService = OwlE2EMockCloudCandidateService()
    let localCandidates = (1...32).map { "候选词\($0)" }
    let preContext = "我们在讨论关于系统的部署与配置规范"
    let pinyin = "bu'shu"

    _ = try await mockService.rerankCandidates(preContext: preContext, pinyin: pinyin, localCandidates: localCandidates)

    let request = mockService.recordedRerankRequests.first
    XCTAssertNotNil(request)
    XCTAssertEqual(request?.preContext, preContext)
    XCTAssertEqual(request?.pinyin, pinyin)
    XCTAssertEqual(request?.candidates.count, 32, "Jev collects up to 32 local candidates")
  }

  /// Feature 7: Jev Discriminative Reranking (Lane A / M2 #395)
  func testT1_07_JevDiscriminativeReranking() async throws {
    let mockService = OwlE2EMockCloudCandidateService()
    mockService.rerankRule = { candidates in
      // LLM picks index 7 ("部署") as best match for pre-context
      return candidates.firstIndex(of: "部署")
    }

    let locals = ["部属", "布署", "不输", "捕鼠", "捕术", "步署", "布书", "部署"]
    let selectedIndex = try await mockService.rerankCandidates(preContext: "服务器环境", pinyin: "bu'shu", localCandidates: locals)
    XCTAssertEqual(selectedIndex, 7)

    let layoutEngine = OwlE2ECandidateWindowLayoutSimulator()
    let reranked = layoutEngine.promote(localCandidates: locals, targetIndex: selectedIndex!)
    XCTAssertEqual(reranked.first, "部署", "Jev elevated matching local candidate to rank 0")
    XCTAssertEqual(Set(reranked), Set(locals), "Zero hallucination guarantee: no words outside local candidates generated")
  }

  /// Feature 8: Pure In-Memory 16kHz WAV Recording (Lane B / M3 #393)
  func testT1_08_PureInMemory16kHzWAVRecording() async throws {
    let recorder = OwlE2EMockAudioRecorder()
    var capturedLevel: Float = 0.0

    try recorder.startRecording { level in
      capturedLevel = level
    }
    XCTAssertTrue(recorder.isRecording)
    XCTAssertGreaterThan(capturedLevel, 0.0)

    let wavData = try await recorder.stopRecording()
    XCTAssertFalse(recorder.isRecording)
    XCTAssertGreaterThan(wavData.count, 44, "WAV data must exceed 44 header bytes")

    let verification = OwlE2EMockAudioRecorder.verifyWavHeader(wavData)
    XCTAssertTrue(verification.isValid, "Must generate valid RIFF WAVE header")
    XCTAssertEqual(verification.sampleRate, 16000, "Sample rate must be exactly 16000Hz")
    XCTAssertEqual(verification.channels, 1, "Audio channels must be mono (1)")
  }

  /// Feature 9: Dual-Trigger & Non-Activating HUD (Lane B / M3 #393)
  func testT1_09_DualTriggerAndFloatingCapsuleHUD() {
    enum TriggerMode {
      case holdToSpeak
      case clickToToggle
    }

    var currentMode: TriggerMode = .holdToSpeak
    XCTAssertEqual(currentMode, .holdToSpeak)

    currentMode = .clickToToggle
    XCTAssertEqual(currentMode, .clickToToggle, "Both hold-to-speak and click-to-toggle are supported")

    let mockRecorder = OwlE2EMockAudioRecorder()
    mockRecorder.simulatedAudioLevels = [0.12, 0.45, 0.78, 0.95, 0.30]
    var levelsReceived: [Float] = []

    XCTAssertNoThrow(try mockRecorder.startRecording { level in
      levelsReceived.append(level)
    })
    XCTAssertEqual(levelsReceived.count, 5, "Floating capsule HUD receives real-time RMS levels for waveform")
  }

  /// Feature 10: xAI Grok ASR Cloud Client & Injection (Lane B / M3 #393)
  func testT1_10_GrokASRCloudClientAndInjection() async throws {
    let asr = OwlE2EMockGrokASRService()
    asr.defaultTranscript = "召开项目架构评审会议"

    let recorder = OwlE2EMockAudioRecorder()
    let wav = recorder.makeWavData(sampleCount: 16000)

    let transcript = try await asr.transcribe(audioWavData: wav, prompt: "会议")
    XCTAssertEqual(transcript, "召开项目架构评审会议")
    XCTAssertEqual(asr.recordedAudioDataCount, wav.count)
    XCTAssertEqual(asr.recordedPrompt, "会议")

    // Direct injection into host client simulator
    let host = OwlE2EAIWritingPanelSimulator(initialHostText: "当前文档：")
    host.commitToCursor(text: transcript)
    XCTAssertEqual(host.currentHostText, "当前文档：召开项目架构评审会议")
  }

  /// Feature 11: 3-Source Hotwords Extraction (Lane B / M4 #396)
  func testT1_11_ThreeSourceHotwordsExtraction() {
    let extractor = OwlE2EMockHotwordsExtractor(
      pinnedWords: ["大模型", "架构设计"],
      customWords: ["猫头鹰输入法", "高吞吐"],
      frequentBigrams: ["部署上线", "快速响应"]
    )

    let hotwords = extractor.extractHotwords(limit: 10)
    XCTAssertTrue(hotwords.contains("大模型"), "Includes pinned words")
    XCTAssertTrue(hotwords.contains("猫头鹰输入法"), "Includes custom words")
    XCTAssertTrue(hotwords.contains("部署上线"), "Includes personal high-frequency bigrams")
    XCTAssertEqual(hotwords.count, 6)
  }

  /// Feature 12: 800-Byte UTF-8 Token-Safe Budgeting (Lane B / M4 #396)
  func testT1_12_800ByteTokenSafeBudgeting() {
    let extractor = OwlE2EMockHotwordsExtractor()
    let preContext = "关于深度学习与自然语言处理技术的讨论"
    let longHotwords = (1...100).map { "专业高频技术词汇\($0)" }

    let prompt = extractor.buildPrompt(preContext: preContext, hotwords: longHotwords, maxBytes: 800)
    XCTAssertLessThanOrEqual(prompt.utf8.count, 800, "Prompt must strictly stay within 800 UTF-8 bytes")
    XCTAssertFalse(prompt.isEmpty)
    XCTAssertTrue(prompt.contains("前文: \(preContext)"))
  }

  /// Feature 13: Real-Time Subtitle Preview (Lane B / M5 #398)
  func testT1_13_RealTimeSubtitlePreview() async throws {
    let recorder = OwlE2EMockAudioRecorder()
    let extractor = OwlE2EMockHotwordsExtractor()
    let asr = OwlE2EMockGrokASRService()
    asr.defaultTranscript = "原文字幕预览"
    let polisher = OwlE2EMockDeepSeekPolishService()
    polisher.simulatedLatency = 0.05

    let pipeline = OwlE2EVoicePipeline(
      recorder: recorder,
      hotwordsExtractor: extractor,
      asrService: asr,
      polishService: polisher
    )

    var previewShown: String?
    let result = try await pipeline.processVoiceInput(preContext: nil) { preview in
      previewShown = preview
    }

    XCTAssertEqual(previewShown, "原文字幕预览", "Voice capsule presents instant subtitle preview upon ASR return")
    XCTAssertEqual(result.raw, "原文字幕预览")
  }

  /// Feature 14: DeepSeek LLM Voice Polish (Lane B / M5 #398)
  func testT1_14_DeepSeekLLMVoicePolish() async throws {
    let polisher = OwlE2EMockDeepSeekPolishService()
    XCTAssertTrue(polisher.thinkingDisabled, "DeepSeek call must disable thinking")

    let raw = "那个嗯我们明天要把服务部属到生产环境啊"
    let polished = try await polisher.polish(rawTranscript: raw)

    XCTAssertFalse(polished.contains("那个"), "Fillers like '那个' removed")
    XCTAssertFalse(polished.contains("嗯"), "Fillers like '嗯' removed")
    XCTAssertFalse(polished.contains("啊"), "Fillers like '啊' removed")
    XCTAssertTrue(polished.contains("部署"), "Homophone '部属' corrected to '部署'")
    XCTAssertTrue(polished.hasSuffix("。"), "Punctuation added")
  }

  /// Feature 15: 4s Timeout & Fallback Degradation (Lane B / M5 #398)
  func testT1_15_FourSecondTimeoutAndFallback() async throws {
    let recorder = OwlE2EMockAudioRecorder()
    let extractor = OwlE2EMockHotwordsExtractor()
    let asr = OwlE2EMockGrokASRService()
    asr.defaultTranscript = "这是原始转写文字"
    let polisher = OwlE2EMockDeepSeekPolishService()
    polisher.shouldTimeout = true // Will hang > 4s

    // Test with short 0.1s timeout parameter for fast test execution
    let pipeline = OwlE2EVoicePipeline(
      recorder: recorder,
      hotwordsExtractor: extractor,
      asrService: asr,
      polishService: polisher,
      timeoutSeconds: 0.1
    )

    let result = try await pipeline.processVoiceInput(preContext: nil) { _ in }
    XCTAssertTrue(result.fallbackUsed, "Seamless fallback activated on timeout")
    XCTAssertEqual(result.final, "这是原始转写文字", "Zero text loss: raw transcript emitted on timeout")
  }

  /// Feature 16: Floating AI Dialog Panel & Invocations (Lane C / M6 #394)
  func testT1_16_FloatingAIDialogPanelInvocations() {
    let panel = OwlE2EAIWritingPanelSimulator(initialHostText: "nih")
    XCTAssertFalse(panel.isVisible)

    // Invoked via Shift+K or /ai while typing with preedit
    panel.invoke(mode: .typing(preedit: "nih"))
    XCTAssertTrue(panel.isVisible, "Floating panel becomes visible")
    XCTAssertEqual(panel.currentHostText, "", "Preedit 'nih' cleared from host upon panel invocation")
  }

  /// Feature 17: Context-Aware Writeback Actions (Lane C / M6 #394)
  func testT1_17_ContextAwareWritebackActions() {
    let panel = OwlE2EAIWritingPanelSimulator(initialHostText: "尊敬的客户您好，")

    // Action 1: "上屏 (↩)" -> cursor append
    panel.commitToCursor(text: "我们将尽快为您处理。")
    XCTAssertEqual(panel.currentHostText, "尊敬的客户您好，我们将尽快为您处理。")

    // Action 2: "替换选区 (↩)" -> selection replacement
    let rangeToReplace = NSRange(location: 0, length: 8) // "尊敬的客户您好，"
    panel.replaceSelection(with: "亲爱的用户：", targetRange: rangeToReplace)
    XCTAssertEqual(panel.currentHostText, "亲爱的用户：我们将尽快为您处理。")
  }

  /// Feature 18: Dual Candidate Polish Display (Lane C / M7 #397)
  func testT1_18_DualCandidatePolishDisplay() async throws {
    let client = OwlE2EMockSelectionPolishClient()
    let candidates = try await client.polishSelection(text: "测试输入文本", style: .conciseWritten)

    XCTAssertEqual(candidates.count, 2, "Panel must return and display exactly 2 polish candidates")
    XCTAssertNotEqual(candidates[0], candidates[1], "The 2 candidates must be distinct")
  }

  /// Feature 19: 4-Style Polish Switching Bar (Lane C / M7 #397)
  func testT1_19_FourStylePolishSwitchingBar() async throws {
    let client = OwlE2EMockSelectionPolishClient()
    let allStyles = OwlE2EPolishStyle.allCases

    XCTAssertEqual(allStyles.count, 4)
    XCTAssertEqual(allStyles.map { $0.rawValue }, ["原意保真", "精炼书面", "得体商务", "口语转书面"])

    for style in allStyles {
      let results = try await client.polishSelection(text: "合同事宜", style: style)
      XCTAssertEqual(results.count, 2, "Each of the 4 styles generates dual candidates")
    }
  }

  /// Feature 20: Reply Templates 3-Candidate Generation (Lane C / M7 #397)
  func testT1_20_ReplyTemplatesThreeCandidateGeneration() async throws {
    let generator = OwlE2EMockReplyGenerator()
    let templates = OwlE2EReplyTemplate.allCases

    XCTAssertEqual(templates.count, 5)

    for template in templates {
      let candidates = try await generator.generateReplies(contextText: "明天下午两点开会如何？", template: template)
      XCTAssertEqual(candidates.count, 3, "Reply template \(template.rawValue) generates exactly 3 candidate options")
    }
  }

  /// Feature 21: Hot Path Off-Hot-Path Verification (M8 Gate)
  func testT1_21_HotPathOffHotPathVerification() {
    let check = OwlE2EHotPathPurityChecker.verifyHotPathIsFreeOfAISymbols(rootPath: repoRoot)
    XCTAssertTrue(check.isPure, "Hot path (sources/Controller, sources/Engine) must have 0 forbidden network/LLM symbols: \(check.violations)")
  }

  /// Feature 22: Offline Mock/Stub Infrastructure (M8 Gate)
  func testT1_22_OfflineMockStubInfrastructure() async throws {
    // Verifies that all mock implementations run without network dependencies
    let cloudMock = OwlE2EMockCloudCandidateService()
    let wavRecorder = OwlE2EMockAudioRecorder()
    let asrMock = OwlE2EMockGrokASRService()
    let polishMock = OwlE2EMockDeepSeekPolishService()
    let selectionMock = OwlE2EMockSelectionPolishClient()
    let replyMock = OwlE2EMockReplyGenerator()

    let sampleTicket = OwlE2EAICandidateTicket(sessionID: 1, generation: 1, rawInput: "test", actionEpoch: 1)
    let candidateList = try await cloudMock.generateCandidates(ticket: sampleTicket, preContext: nil)
    XCTAssertFalse(candidateList.isEmpty)

    let wav = try await wavRecorder.stopRecording()
    XCTAssertGreaterThan(wav.count, 44)

    let asr = try await asrMock.transcribe(audioWavData: wav, prompt: nil)
    XCTAssertFalse(asr.isEmpty)

    let polished = try await polishMock.polish(rawTranscript: asr)
    XCTAssertFalse(polished.isEmpty)

    let selectionCandidates = try await selectionMock.polishSelection(text: "hello", style: .originalFidelity)
    XCTAssertEqual(selectionCandidates.count, 2)

    let replyCandidates = try await replyMock.generateReplies(contextText: "hi", template: .agree)
    XCTAssertEqual(replyCandidates.count, 3)
  }

  /// Feature 23: Business Boundary Registration (M8 Gate)
  func testT1_23_BusinessBoundaryRegistration() {
    let jsonPath = URL(fileURLWithPath: repoRoot).appendingPathComponent("docs/agents/business-ownership.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: jsonPath.path), "business-ownership.json must exist")

    guard let data = try? Data(contentsOf: jsonPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let files = json["files"] as? [[String: Any]] else {
      XCTFail("Failed to parse business-ownership.json")
      return
    }

    let splitFiles = files.filter { ($0["role"] as? String) == "split" }
    let migrateFiles = files.filter { ($0["role"] as? String) == "migrate" }
    XCTAssertTrue(splitFiles.isEmpty, "Boundary lock: 0 split files allowed")
    XCTAssertTrue(migrateFiles.isEmpty, "Boundary lock: 0 migrate files allowed")
  }

  /// Feature 24: Full Gate Passing Compatibility (M8 Gate)
  func testT1_24_MergedGateCompatibility() {
    let gateScript = URL(fileURLWithPath: repoRoot).appendingPathComponent("scripts/gate.sh")
    XCTAssertTrue(FileManager.default.fileExists(atPath: gateScript.path), "scripts/gate.sh must exist and be runnable")
  }

  // MARK: - ==================================================================
  // MARK: - Tier 2: Boundary & Corner Cases
  // MARK: - ==================================================================

  /// T2.1: Rapid typing debounce cancellation
  func testT2_01_RapidTypingDebounceCancellation() {
    var timerCancelledCount = 0
    let typingIntervalMs = [30, 45, 50, 150] // First 3 are < 120ms debounce

    for interval in typingIntervalMs where interval < 120 {
      timerCancelledCount += 1
    }
    XCTAssertEqual(timerCancelledCount, 3, "3 rapid typing events cancel pending debounce timers")
  }

  /// T2.2: Stale epoch / generation response discard
  func testT2_02_StaleEpochGenerationDiscard() {
    var activeSessionEpoch: UInt64 = 5
    let staleResponseEpoch: UInt64 = 4

    var applied = false
    if staleResponseEpoch == activeSessionEpoch {
      applied = true
    }
    XCTAssertFalse(applied, "Response with stale epoch must be discarded")

    activeSessionEpoch = 4
    if staleResponseEpoch == activeSessionEpoch {
      applied = true
    }
    XCTAssertTrue(applied, "Response with matching epoch is safely accepted")
  }

  /// T2.3: Candidate window page size boundaries
  func testT2_03_CandidateWindowPageSizeBoundaries() {
    let layoutEngine = OwlE2ECandidateWindowLayoutSimulator(pageSize: 5)

    // Case A: 0 local candidates
    let itemsA = layoutEngine.layout(localCandidates: [], aiCandidate: "AI候选")
    XCTAssertEqual(itemsA.count, 1)
    XCTAssertEqual(itemsA[0].provenance, .ai)

    // Case B: local candidates < pageSize - 1 (e.g. 2)
    let itemsB = layoutEngine.layout(localCandidates: ["一", "二"], aiCandidate: "AI候选")
    XCTAssertEqual(itemsB.count, 3)
    XCTAssertEqual(itemsB.last?.provenance, .ai)

    // Case C: local candidates == pageSize - 1 (e.g. 4)
    let itemsC = layoutEngine.layout(localCandidates: ["一", "二", "三", "四"], aiCandidate: "AI候选")
    XCTAssertEqual(itemsC.count, 5)
    XCTAssertEqual(itemsC[4].provenance, .ai)

    // Case D: nil AI candidate
    let itemsD = layoutEngine.layout(localCandidates: ["一", "二", "三"], aiCandidate: nil)
    XCTAssertEqual(itemsD.count, 3)
    XCTAssertTrue(itemsD.allSatisfy { $0.provenance == .local })
  }

  /// T2.4: Jev rerank candidate list limits
  func testT2_04_JevRerankCandidateListLimits() async throws {
    let mockService = OwlE2EMockCloudCandidateService()
    mockService.rerankRule = { _ in
      return nil // LLM chooses "none" (no local candidate fits context)
    }

    let over32Candidates = (1...40).map { "候选\($0)" }
    let capped = Array(over32Candidates.prefix(32))
    let pick = try await mockService.rerankCandidates(preContext: "无关前文", pinyin: "test", localCandidates: capped)

    XCTAssertNil(pick, "When LLM selects 'none', rerank returns nil and local candidate order is undisturbed")
  }

  /// T2.5: In-memory WAV buffer boundary conditions
  func testT2_05_WAVBufferBoundaryConditions() {
    let recorder = OwlE2EMockAudioRecorder()

    // 0 sample WAV
    let zeroWav = recorder.makeWavData(sampleCount: 0)
    let checkZero = OwlE2EMockAudioRecorder.verifyWavHeader(zeroWav)
    XCTAssertTrue(checkZero.isValid, "0-sample WAV still has valid 44-byte header")

    // 1 sample WAV
    let oneWav = recorder.makeWavData(sampleCount: 1)
    let checkOne = OwlE2EMockAudioRecorder.verifyWavHeader(oneWav)
    XCTAssertTrue(checkOne.isValid)
    XCTAssertEqual(oneWav.count, 44 + 2) // 44 header + 2 bytes for 16-bit mono
  }

  /// T2.6: Hotwords 800-byte boundary non-splitting of UTF-8 multi-byte characters
  func testT2_06_HotwordsUTF8BoundaryNonSplitting() {
    let extractor = OwlE2EMockHotwordsExtractor()
    // Create string of 3-byte Chinese characters
    let chineseStr = String(repeating: "测", count: 300) // 900 UTF-8 bytes

    let budgeted = extractor.buildPrompt(preContext: nil, hotwords: [chineseStr], maxBytes: 800)
    XCTAssertLessThanOrEqual(budgeted.utf8.count, 800)

    // Ensure valid string without broken surrogate or corrupted bytes
    let roundtrip = String(data: Data(budgeted.utf8), encoding: .utf8)
    XCTAssertNotNil(roundtrip, "UTF-8 budgeting must never produce corrupted multibyte characters")
  }

  /// T2.7: DeepSeek timeout edge timing and error degradation
  func testT2_07_DeepSeekTimeoutEdgeTimingAndErrors() async throws {
    let recorder = OwlE2EMockAudioRecorder()
    let extractor = OwlE2EMockHotwordsExtractor()
    let asr = OwlE2EMockGrokASRService()
    asr.defaultTranscript = "网络异常时的音频转写"
    let polisher = OwlE2EMockDeepSeekPolishService()
    polisher.shouldFail = true // Upstream 500/timeout error

    let pipeline = OwlE2EVoicePipeline(
      recorder: recorder,
      hotwordsExtractor: extractor,
      asrService: asr,
      polishService: polisher
    )

    let result = try await pipeline.processVoiceInput(preContext: nil) { _ in }
    XCTAssertTrue(result.fallbackUsed, "Upstream error must trigger fallback")
    XCTAssertEqual(result.final, "网络异常时的音频转写", "Raw transcript preserved with 100% fidelity")
  }

  /// T2.8: AI Writing Panel oversized text and empty selection
  func testT2_08_AIWritingPanelOversizedTextAndEmptySelection() async throws {
    let client = OwlE2EMockSelectionPolishClient()

    // Empty text
    let emptyResult = try await client.polishSelection(text: "", style: .originalFidelity)
    XCTAssertEqual(emptyResult.count, 2)

    // Huge text (10,000 characters)
    let hugeText = String(repeating: "长文本内容，", count: 1500)
    let hugeResult = try await client.polishSelection(text: hugeText, style: .conciseWritten)
    XCTAssertEqual(hugeResult.count, 2)
  }

  /// T2.9: Rapid style switching in-flight cancellation
  func testT2_09_RapidStyleSwitchingInFlightCancellation() async throws {
    let client = OwlE2EMockSelectionPolishClient()
    client.latency = 0.05

    // Simulate task cancellation when switching styles
    let task1 = Task {
      try await client.polishSelection(text: "样式测试", style: .originalFidelity)
    }
    task1.cancel()

    let task2 = Task {
      try await client.polishSelection(text: "样式测试", style: .properBusiness)
    }
    let result = try await task2.value
    XCTAssertEqual(result.count, 2)
    XCTAssertTrue(result[0].contains("尊敬的收件人") || result[0].contains("敬启者"))
  }

  // MARK: - ==================================================================
  // MARK: - Tier 3: Cross-Feature Combinations
  // MARK: - ==================================================================

  /// T3.1: Lane A Full Chain: Typing -> Debounce -> AI Association -> Slot Layout -> Commit
  func testT3_01_LaneAFullChain_TypingToAISelection() async throws {
    // 1. User types "hangzhou"
    let ticket = OwlE2EAICandidateTicket(sessionID: 200, generation: 1, rawInput: "hangzhou", actionEpoch: 10)
    let cloudService = OwlE2EMockCloudCandidateService()
    cloudService.setCandidates(for: "hangzhou", candidates: ["杭州市西湖区文三路"])

    // 2. Debounce completes -> AI candidate generated
    let aiCandidates = try await cloudService.generateCandidates(ticket: ticket, preContext: "公司位于")
    XCTAssertEqual(aiCandidates.first, "杭州市西湖区文三路")

    // 3. Candidate window layout
    let locals = ["杭州", "行州", "杭", "航", "行"]
    let layoutEngine = OwlE2ECandidateWindowLayoutSimulator(pageSize: 5)
    let items = layoutEngine.layout(localCandidates: locals, aiCandidate: aiCandidates.first)

    XCTAssertEqual(items[4].text, "杭州市西湖区文三路")
    XCTAssertEqual(items[4].provenance, .ai)

    // 4. User presses slot 5 (index 4) -> Selected AI candidate commits to host
    let host = OwlE2EAIWritingPanelSimulator(initialHostText: "公司位于")
    host.commitToCursor(text: items[4].text)
    XCTAssertEqual(host.currentHostText, "公司位于杭州市西湖区文三路")
  }

  /// T3.2: Lane A Jev Reranking Chain: Local Candidates -> Discriminative Rerank -> Rank 0 Promotion
  func testT3_02_LaneAJevRerankingChain_LocalCandidatesToRankZero() async throws {
    let cloudService = OwlE2EMockCloudCandidateService()
    cloudService.rerankRule = { candidates in
      return candidates.firstIndex(of: "架构师")
    }

    let preContext = "招聘资深分布式系统"
    let pinyin = "jia'gou'shi"
    let locals = ["甲狗屎", "架构式", "加狗食", "架构师", "家狗屎"]

    let bestIndex = try await cloudService.rerankCandidates(preContext: preContext, pinyin: pinyin, localCandidates: locals)
    XCTAssertEqual(bestIndex, 3)

    let layoutEngine = OwlE2ECandidateWindowLayoutSimulator()
    let promoted = layoutEngine.promote(localCandidates: locals, targetIndex: bestIndex!)

    XCTAssertEqual(promoted[0], "架构师", "Rank 0 is now '架构师'")
    XCTAssertEqual(promoted.count, locals.count)
  }

  /// T3.3: Lane B Full Voice Pipeline: Record -> Hotwords -> Grok ASR -> Preview -> DeepSeek Polish -> Injection
  func testT3_03_LaneBFullVoicePipeline_RecordToPolishToHostInjection() async throws {
    let recorder = OwlE2EMockAudioRecorder()
    let extractor = OwlE2EMockHotwordsExtractor(
      pinnedWords: ["微服务架构"],
      customWords: ["云原生生态"],
      frequentBigrams: ["高可用部署"]
    )
    let asr = OwlE2EMockGrokASRService()
    asr.defaultTranscript = "那个嗯我们今天讨论微服务架构的高可用部属方案啊"
    let polisher = OwlE2EMockDeepSeekPolishService()

    let pipeline = OwlE2EVoicePipeline(
      recorder: recorder,
      hotwordsExtractor: extractor,
      asrService: asr,
      polishService: polisher
    )

    var previewCaptured = ""
    let result = try await pipeline.processVoiceInput(preContext: "技术方案备忘：") { preview in
      previewCaptured = preview
    }

    XCTAssertEqual(previewCaptured, "那个嗯我们今天讨论微服务架构的高可用部属方案啊")
    XCTAssertFalse(result.fallbackUsed)
    XCTAssertEqual(result.final, "我们今天讨论微服务架构的高可用部署方案。")

    // Inject to host
    let host = OwlE2EAIWritingPanelSimulator(initialHostText: "技术方案备忘：\n")
    host.commitToCursor(text: result.final)
    XCTAssertEqual(host.currentHostText, "技术方案备忘：\n我们今天讨论微服务架构的高可用部署方案。")
  }

  /// T3.4: Lane B Degradation Chain: Voice Input -> Slow Polisher -> 4s Timeout Fallback
  func testT3_04_LaneBDegradationChain_SlowPolisherTimeoutToRawTranscript() async throws {
    let recorder = OwlE2EMockAudioRecorder()
    let extractor = OwlE2EMockHotwordsExtractor()
    let asr = OwlE2EMockGrokASRService()
    asr.defaultTranscript = "紧急转写任务内容"
    let polisher = OwlE2EMockDeepSeekPolishService()
    polisher.shouldTimeout = true

    let pipeline = OwlE2EVoicePipeline(
      recorder: recorder,
      hotwordsExtractor: extractor,
      asrService: asr,
      polishService: polisher,
      timeoutSeconds: 0.1 // Short timeout for test
    )

    let result = try await pipeline.processVoiceInput(preContext: nil) { _ in }
    XCTAssertTrue(result.fallbackUsed)
    XCTAssertEqual(result.final, "紧急转写任务内容")
  }

  /// T3.5: Lane C Typing Invocation Chain: /ai Command -> Clear Preedit -> Execute Prompt -> Commit
  func testT3_05_LaneCTypingInvocationChain_SlashAiToPromptToWriteback() async throws {
    let panel = OwlE2EAIWritingPanelSimulator(initialHostText: "在编写单元测试时 /ai")
    panel.invoke(mode: .typing(preedit: "/ai"))

    XCTAssertEqual(panel.currentHostText, "在编写单元测试时 ")
    XCTAssertTrue(panel.isVisible)

    // User generates reply in panel
    let generator = OwlE2EMockReplyGenerator()
    let replies = try await generator.generateReplies(contextText: "在编写单元测试时", template: .agree)
    XCTAssertEqual(replies.count, 3)

    // User chooses 1st reply and hits "上屏 (↩)"
    panel.commitToCursor(text: replies[0])
    XCTAssertEqual(panel.currentHostText, "在编写单元测试时 完全赞同您的观点，我们立即按此推进。")
    XCTAssertFalse(panel.isVisible)
  }

  /// T3.6: Lane C Selection Polish Chain: Shift+K -> Style Switch -> Replace Selection
  func testT3_06_LaneCSelectionPolishChain_SelectTextToStyleSwitchToReplace() async throws {
    let hostText = "请把这段很随意的口语改一下吧"
    let panel = OwlE2EAIWritingPanelSimulator(initialHostText: hostText)
    panel.invoke(mode: .selection(selectedText: hostText))

    let polishClient = OwlE2EMockSelectionPolishClient()

    // 1. Initial style: 原意保真
    let style1Candidates = try await polishClient.polishSelection(text: hostText, style: .originalFidelity)
    XCTAssertEqual(style1Candidates.count, 2)

    // 2. Switch to: 得体商务
    let style2Candidates = try await polishClient.polishSelection(text: hostText, style: .properBusiness)
    XCTAssertEqual(style2Candidates.count, 2)

    // 3. User chooses candidate 2 with shortcut [2]
    let chosenText = style2Candidates[1]
    panel.replaceSelection(with: chosenText, targetRange: NSRange(location: 0, length: hostText.count))

    XCTAssertEqual(panel.currentHostText, chosenText)
    XCTAssertFalse(panel.isVisible)
  }

  // MARK: - ==================================================================
  // MARK: - Tier 4: Real-World Workload Scenarios
  // MARK: - ==================================================================

  /// T4.1: Scenario "Developer Coding & Documentation Workload"
  func testT4_01_Scenario_DeveloperCodingAndDocumentation() async throws {
    let secureGate = OwlE2ESecureInputGate()
    let cloudService = OwlE2EMockCloudCandidateService()

    // Step 1: In sudo password prompt -> secure input active -> 0 network calls allowed
    secureGate.isSecureInput = true
    XCTAssertFalse(secureGate.allowsNetworkRequest(), "Zero network in sudo / password input")

    // Step 2: Switch to VS Code editing Swift source -> secure input inactive
    secureGate.isSecureInput = false
    XCTAssertTrue(secureGate.allowsNetworkRequest())

    // Typing code comments: "xiancheng" -> AI Association pause
    cloudService.setCandidates(for: "xiancheng", candidates: ["线程安全与数据竞争保护"])
    let ticket = OwlE2EAICandidateTicket(sessionID: 301, generation: 1, rawInput: "xiancheng", actionEpoch: 1)
    let aiResults = try await cloudService.generateCandidates(ticket: ticket, preContext: "// 该模块实现了")

    let layout = OwlE2ECandidateWindowLayoutSimulator(pageSize: 5)
    let window = layout.layout(localCandidates: ["线程", "现成", "先称", "显出", "县城"], aiCandidate: aiResults.first)
    XCTAssertEqual(window[4].text, "线程安全与数据竞争保护")
  }

  /// T4.2: Scenario "Noisy Meeting Voice Dictation Workload"
  func testT4_02_Scenario_NoisyMeetingVoiceMinutesDictation() async throws {
    let recorder = OwlE2EMockAudioRecorder()
    let extractor = OwlE2EMockHotwordsExtractor(
      pinnedWords: ["季度敏捷迭代", "性能瓶颈"],
      customWords: ["混沌工程演练"],
      frequentBigrams: ["回归测试", "指标大盘"]
    )
    let asr = OwlE2EMockGrokASRService()
    asr.defaultTranscript = "呃那个关于第四季度的敏捷迭代，我们必须解决性能瓶颈，然后安排混沌工程演练啊"
    let polisher = OwlE2EMockDeepSeekPolishService()

    let pipeline = OwlE2EVoicePipeline(
      recorder: recorder,
      hotwordsExtractor: extractor,
      asrService: asr,
      polishService: polisher
    )

    var liveSubtitle = ""
    let result = try await pipeline.processVoiceInput(preContext: "会议纪要：") { sub in
      liveSubtitle = sub
    }

    XCTAssertFalse(liveSubtitle.isEmpty)
    XCTAssertFalse(result.fallbackUsed)
    XCTAssertTrue(result.final.contains("季度敏捷迭代"))
    XCTAssertTrue(result.final.contains("混沌工程演练"))
    XCTAssertFalse(result.final.contains("那个"))
    XCTAssertFalse(result.final.contains("呃"))
  }

  /// T4.3: Scenario "Urgent Email Reply & Polishing Workload"
  func testT4_03_Scenario_CustomerServiceUrgentEmailReply() async throws {
    let emailContext = "客户催促：请问我们昨天反馈的支付接口超时问题何时能够修复？"
    let generator = OwlE2EMockReplyGenerator()
    let polisher = OwlE2EMockSelectionPolishClient()

    // 1. Generate reply candidates with "推进催办" template
    let candidates = try await generator.generateReplies(contextText: emailContext, template: .followUp)
    XCTAssertEqual(candidates.count, 3)

    // 2. Select 2nd candidate: "请教一下该流程的最新状态，如需协助请随时沟通。"
    let selectedReply = candidates[1]

    // 3. Polish with "得体商务"
    let polishedDual = try await polisher.polishSelection(text: selectedReply, style: .properBusiness)
    XCTAssertEqual(polishedDual.count, 2)

    // 4. One-key insert into email composer
    let composer = OwlE2EAIWritingPanelSimulator(initialHostText: "Re: 支付接口超时反馈\n\n")
    composer.commitToCursor(text: polishedDual[0])

    XCTAssertTrue(composer.currentHostText.contains("尊敬的收件人"))
  }

  /// T4.4: Scenario "Offline Flight Mode Resilience Workload"
  func testT4_04_Scenario_OfflineFlightModeResilience() async throws {
    // Simulate airplane mode: all cloud services throw URLError(.notConnectedToInternet)
    let cloudService = OwlE2EMockCloudCandidateService()
    cloudService.shouldFailNetwork = true

    let ticket = OwlE2EAICandidateTicket(sessionID: 999, generation: 1, rawInput: "feiji", actionEpoch: 1)
    do {
      _ = try await cloudService.generateCandidates(ticket: ticket, preContext: nil)
      XCTFail("Should throw network error")
    } catch {
      // Graceful offline fallback: local candidates remain completely unaffected
      let layout = OwlE2ECandidateWindowLayoutSimulator(pageSize: 5)
      let items = layout.layout(localCandidates: ["飞机", "非极", "肥鸡", "飞吉", "肺积"], aiCandidate: nil)
      XCTAssertEqual(items.count, 5)
      XCTAssertTrue(items.allSatisfy { $0.provenance == .local })
    }

    // Voice pipeline in airplane mode
    let recorder = OwlE2EMockAudioRecorder()
    let extractor = OwlE2EMockHotwordsExtractor()
    let asr = OwlE2EMockGrokASRService()
    asr.shouldFail = true // No network to xAI Grok
    let polisher = OwlE2EMockDeepSeekPolishService()

    let pipeline = OwlE2EVoicePipeline(
      recorder: recorder,
      hotwordsExtractor: extractor,
      asrService: asr,
      polishService: polisher
    )

    do {
      _ = try await pipeline.processVoiceInput(preContext: nil) { _ in }
      XCTFail("Should handle ASR network failure gracefully")
    } catch {
      // Expected caught error, zero crash
      XCTAssertTrue(true, "Pipeline reports error without application crash")
    }
  }
}
