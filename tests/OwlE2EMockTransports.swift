//
//  OwlE2EMockTransports.swift
//  OwltypeTests — Offline Mock Transports & Test Fixtures for E2E Test Suite
//
//  Provides 100% offline, hermetic mock implementations, protocol definitions,
//  and test harnesses for Lanes A, B, and C with 0 network calls and 0 real API keys.
//

import Foundation
import XCTest
@testable import Owltype

// MARK: - ====================================================================
// MARK: - Lane A: Cloud AI Candidate & Jev Reranking Mocks
// MARK: - ====================================================================

/// Ticket representing a typing session state snapshot for AI candidate generation.
public struct OwlE2EAICandidateTicket: Equatable, Sendable {
  public let sessionID: UInt64
  public let generation: UInt64
  public let rawInput: String
  public let actionEpoch: UInt64

  public init(sessionID: UInt64, generation: UInt64, rawInput: String, actionEpoch: UInt64) {
    self.sessionID = sessionID
    self.generation = generation
    self.rawInput = rawInput
    self.actionEpoch = actionEpoch
  }
}

/// Preferences for Cloud AI candidates.
public final class OwlE2EAICandidatePreferences: @unchecked Sendable {
  private let lock = NSLock()
  private var _aiAssociationEnabled: Bool
  private var _aiEnglishCandidateEnabled: Bool

  public init(aiAssociationEnabled: Bool = true, aiEnglishCandidateEnabled: Bool = false) {
    self._aiAssociationEnabled = aiAssociationEnabled
    self._aiEnglishCandidateEnabled = aiEnglishCandidateEnabled
  }

  public var aiAssociationEnabled: Bool {
    get { lock.lock(); defer { lock.unlock() }; return _aiAssociationEnabled }
    set { lock.lock(); defer { lock.unlock() }; _aiAssociationEnabled = newValue }
  }

  public var aiEnglishCandidateEnabled: Bool {
    get { lock.lock(); defer { lock.unlock() }; return _aiEnglishCandidateEnabled }
    set { lock.lock(); defer { lock.unlock() }; _aiEnglishCandidateEnabled = newValue }
  }
}

/// Provenance of a candidate item in candidate window.
public enum OwlE2ECandidateProvenance: Equatable, Sendable {
  case local
  case ai
}

/// Candidate item representing a slot in the UI.
public struct OwlE2ECandidateItem: Equatable, Sendable {
  public let text: String
  public let provenance: OwlE2ECandidateProvenance
  public let score: Double

  public init(text: String, provenance: OwlE2ECandidateProvenance = .local, score: Double = 0.0) {
    self.text = text
    self.provenance = provenance
    self.score = score
  }
}

/// Service protocol for Cloud AI candidates and Jev reranking.
public protocol OwlE2EAICandidateServiceProtocol: Sendable {
  func generateCandidates(ticket: OwlE2EAICandidateTicket, preContext: String?) async throws -> [String]
  func rerankCandidates(preContext: String?, pinyin: String, localCandidates: [String]) async throws -> Int?
}

/// Thread-safe mock implementation of Cloud AI Candidate & Jev Reranking service.
public final class OwlE2EMockCloudCandidateService: OwlE2EAICandidateServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  public var cannedCandidates: [String: [String]] = [:]
  public var defaultCandidates: [String] = ["联想候选词"]
  public var rerankRule: (([String]) -> Int?)?
  public var simulatedDelay: TimeInterval = 0.0
  public var shouldFailNetwork: Bool = false
  public private(set) var recordedTickets: [OwlE2EAICandidateTicket] = []
  public private(set) var recordedPreContexts: [String?] = []
  public private(set) var recordedRerankRequests: [(preContext: String?, pinyin: String, candidates: [String])] = []

  public init() {}

  public func setCandidates(for input: String, candidates: [String]) {
    lock.lock(); defer { lock.unlock() }
    cannedCandidates[input] = candidates
  }

  public func generateCandidates(ticket: OwlE2EAICandidateTicket, preContext: String?) async throws -> [String] {
    if simulatedDelay > 0 {
      try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
    }
    lock.lock()
    defer { lock.unlock() }
    if shouldFailNetwork {
      throw URLError(.notConnectedToInternet)
    }
    recordedTickets.append(ticket)
    recordedPreContexts.append(preContext)
    return cannedCandidates[ticket.rawInput] ?? defaultCandidates
  }

  public func rerankCandidates(preContext: String?, pinyin: String, localCandidates: [String]) async throws -> Int? {
    if simulatedDelay > 0 {
      try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
    }
    lock.lock()
    defer { lock.unlock() }
    if shouldFailNetwork {
      throw URLError(.notConnectedToInternet)
    }
    recordedRerankRequests.append((preContext, pinyin, localCandidates))
    if let rule = rerankRule {
      return rule(localCandidates)
    }
    // Default: find best match or nil
    return localCandidates.indices.first
  }
}

/// Layout simulator for candidate window ensuring slot layout rules and non-jump stability.
public struct OwlE2ECandidateWindowLayoutSimulator {
  public let pageSize: Int

  public init(pageSize: Int = 5) {
    self.pageSize = pageSize
  }

  /// Places 1st AI candidate at slot `pageSize - 1` without moving local candidates `0 ..< (pageSize - 1)`.
  public func layout(localCandidates: [String], aiCandidate: String?) -> [OwlE2ECandidateItem] {
    var items: [OwlE2ECandidateItem] = localCandidates.map { OwlE2ECandidateItem(text: $0, provenance: .local) }
    guard let ai = aiCandidate, !ai.isEmpty else {
      return items
    }

    if items.count < pageSize {
      // If local candidates fewer than pageSize, append AI candidate at end
      items.append(OwlE2ECandidateItem(text: ai, provenance: .ai))
    } else {
      // Slot pageSize - 1 is reserved for 1st AI candidate
      let aiIndex = pageSize - 1
      let localReplaced = items[aiIndex]
      items[aiIndex] = OwlE2ECandidateItem(text: ai, provenance: .ai)
      // Displaced local item is pushed to next position, preserving all previous items exactly
      items.insert(localReplaced, at: aiIndex + 1)
    }
    return items
  }

  /// Simulates discriminative Jev reranking promotion: promotes index to rank 0.
  public func promote(localCandidates: [String], targetIndex: Int) -> [String] {
    guard localCandidates.indices.contains(targetIndex) else { return localCandidates }
    var result = localCandidates
    let item = result.remove(at: targetIndex)
    result.insert(item, at: 0)
    return result
  }
}

/// Secure input detector and gate to enforce 100% network blocking in password fields.
public final class OwlE2ESecureInputGate: @unchecked Sendable {
  private let lock = NSLock()
  private var _isSecure: Bool = false

  public init(isSecure: Bool = false) {
    self._isSecure = isSecure
  }

  public var isSecureInput: Bool {
    get { lock.lock(); defer { lock.unlock() }; return _isSecure }
    set { lock.lock(); defer { lock.unlock() }; _isSecure = newValue }
  }

  public func allowsNetworkRequest() -> Bool {
    return !isSecureInput
  }
}

// MARK: - ====================================================================
// MARK: - Lane B: Voice Input Pipeline Mocks (Grok ASR + DeepSeek Polish)
// MARK: - ====================================================================

public protocol OwlE2EAudioRecorderProtocol: Sendable {
  func startRecording(onAudioLevel: @escaping @Sendable (Float) -> Void) throws
  func stopRecording() async throws -> Data
}

public protocol OwlE2EVoiceHotwordsExtractorProtocol: Sendable {
  func extractHotwords(limit: Int) -> [String]
  func buildPrompt(preContext: String?, hotwords: [String], maxBytes: Int) -> String
}

public protocol OwlE2EVoiceASRServiceProtocol: Sendable {
  func transcribe(audioWavData: Data, prompt: String?) async throws -> String
}

public protocol OwlE2EVoicePolishServiceProtocol: Sendable {
  func polish(rawTranscript: String) async throws -> String
}

/// Pure in-memory 16kHz mono 16-bit WAV recorder simulator.
public final class OwlE2EMockAudioRecorder: OwlE2EAudioRecorderProtocol, @unchecked Sendable {
  private let lock = NSLock()
  public private(set) var isRecording: Bool = false
  public var sampleRate: Int = 16000
  public var channels: Int = 1
  public var bitsPerSample: Int = 16
  public var simulatedAudioLevels: [Float] = [0.1, 0.4, 0.7, 0.9, 0.3]
  public var simulatedSamplesCount: Int = 16000 // 1 second of audio

  public init() {}

  public func startRecording(onAudioLevel: @escaping @Sendable (Float) -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    isRecording = true
    for level in simulatedAudioLevels {
      onAudioLevel(level)
    }
  }

  public func stopRecording() async throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    isRecording = false
    return makeWavData(sampleCount: simulatedSamplesCount)
  }

  /// Builds a valid in-memory 44-byte RIFF WAV byte array.
  public func makeWavData(sampleCount: Int) -> Data {
    var data = Data()
    let byteRate = sampleRate * channels * (bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    let dataSize = sampleCount * (bitsPerSample / 8)
    let chunkSize = 36 + dataSize

    // RIFF chunk descriptor
    data.append(contentsOf: "RIFF".utf8)
    var chunkSizeLE = UInt32(chunkSize).littleEndian
    data.append(Data(bytes: &chunkSizeLE, count: 4))
    data.append(contentsOf: "WAVE".utf8)

    // fmt sub-chunk
    data.append(contentsOf: "fmt ".utf8)
    var subchunk1Size: UInt32 = 16
    data.append(Data(bytes: &subchunk1Size, count: 4))
    var audioFormat: UInt16 = 1 // PCM
    data.append(Data(bytes: &audioFormat, count: 2))
    var numChannels = UInt16(channels).littleEndian
    data.append(Data(bytes: &numChannels, count: 2))
    var sRate = UInt32(sampleRate).littleEndian
    data.append(Data(bytes: &sRate, count: 4))
    var bRate = UInt32(byteRate).littleEndian
    data.append(Data(bytes: &bRate, count: 4))
    var bAlign = UInt16(blockAlign).littleEndian
    data.append(Data(bytes: &bAlign, count: 2))
    var bPerSample = UInt16(bitsPerSample).littleEndian
    data.append(Data(bytes: &bPerSample, count: 2))

    // data sub-chunk
    data.append(contentsOf: "data".utf8)
    var dSize = UInt32(dataSize).littleEndian
    data.append(Data(bytes: &dSize, count: 4))

    // Fill with simulated 16-bit PCM samples
    let pcmBytes = [UInt8](repeating: 0x80, count: dataSize)
    data.append(contentsOf: pcmBytes)
    return data
  }

  /// Verifies standard 44-byte WAV header properties.
  public static func verifyWavHeader(_ data: Data) -> (isValid: Bool, sampleRate: Int, channels: Int) {
    guard data.count >= 44 else { return (false, 0, 0) }
    let riff = String(data: data[0..<4], encoding: .utf8)
    let wave = String(data: data[8..<12], encoding: .utf8)
    guard riff == "RIFF", wave == "WAVE" else { return (false, 0, 0) }

    let channels = Int(data[22]) | (Int(data[23]) << 8)
    let sampleRate = Int(data[24]) | (Int(data[25]) << 8) | (Int(data[26]) << 16) | (Int(data[27]) << 24)
    return (true, sampleRate, channels)
  }
}

/// 3-Source Hotwords Extractor extracting from pinned words, custom words, and high-frequency bigrams.
public final class OwlE2EMockHotwordsExtractor: OwlE2EVoiceHotwordsExtractorProtocol, @unchecked Sendable {
  public var pinnedWords: [String]
  public var customWords: [String]
  public var frequentBigrams: [String]

  public init(
    pinnedWords: [String] = ["人工智能", "大语言模型"],
    customWords: [String] = ["声智科技", "猫头鹰输入法"],
    frequentBigrams: [String] = ["部署上线", "快速响应"]
  ) {
    self.pinnedWords = pinnedWords
    self.customWords = customWords
    self.frequentBigrams = frequentBigrams
  }

  public func extractHotwords(limit: Int = 20) -> [String] {
    var seen = Set<String>()
    var result: [String] = []

    func addWords(_ words: [String]) {
      for word in words {
        if !seen.contains(word) && result.count < limit {
          seen.insert(word)
          result.append(word)
        }
      }
    }

    addWords(pinnedWords)
    addWords(customWords)
    addWords(frequentBigrams)
    return result
  }

  public func buildPrompt(preContext: String?, hotwords: [String], maxBytes: Int = 800) -> String {
    var segments: [String] = []
    if let ctx = preContext, !ctx.isEmpty {
      segments.append("前文: \(ctx)")
    }
    if !hotwords.isEmpty {
      segments.append("热词: " + hotwords.joined(separator: ", "))
    }
    let full = segments.joined(separator: "\n")

    // Token-safe UTF-8 byte budgeting: truncate without corrupting UTF-8 characters
    let utf8 = full.utf8
    if utf8.count <= maxBytes {
      return full
    }

    // Binary search or prefix slice at character boundary
    var accumulated = ""
    for char in full {
      let candidate = accumulated + String(char)
      if candidate.utf8.count <= maxBytes {
        accumulated = candidate
      } else {
        break
      }
    }
    return accumulated
  }
}

/// Mock xAI Grok ASR Service.
public final class OwlE2EMockGrokASRService: OwlE2EVoiceASRServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  public var defaultTranscript: String = "今天天气很好我们去开会"
  public var cannedTranscripts: [String: String] = [:]
  public private(set) var recordedAudioDataCount: Int = 0
  public private(set) var recordedPrompt: String?
  public var shouldFail: Bool = false

  public init() {}

  public func transcribe(audioWavData: Data, prompt: String?) async throws -> String {
    lock.lock()
    defer { lock.unlock() }
    if shouldFail {
      throw URLError(.cannotConnectToHost)
    }
    recordedAudioDataCount = audioWavData.count
    recordedPrompt = prompt
    return cannedTranscripts[prompt ?? ""] ?? defaultTranscript
  }
}

/// Mock DeepSeek LLM Voice Polish Service.
public final class OwlE2EMockDeepSeekPolishService: OwlE2EVoicePolishServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  public var simulatedLatency: TimeInterval = 0.1
  public var shouldTimeout: Bool = false
  public var shouldFail: Bool = false
  public var thinkingDisabled: Bool = true
  public private(set) var recordedRawTranscripts: [String] = []

  public init() {}

  public func polish(rawTranscript: String) async throws -> String {
    if shouldTimeout {
      // Sleep longer than the 4.0s timeout threshold
      try await Task.sleep(nanoseconds: 4_500_000_000)
    } else if simulatedLatency > 0 {
      try await Task.sleep(nanoseconds: UInt64(simulatedLatency * 1_000_000_000))
    }

    lock.lock()
    defer { lock.unlock() }
    if shouldFail {
      throw URLError(.timedOut)
    }
    recordedRawTranscripts.append(rawTranscript)

    // Polish rules: remove fillers ("那个", "呃", "嗯", "然后", "啊"), fix homophones, add punctuation
    var polished = rawTranscript
      .replacingOccurrences(of: "那个", with: "")
      .replacingOccurrences(of: "呃", with: "")
      .replacingOccurrences(of: "嗯", with: "")
      .replacingOccurrences(of: "啊", with: "")
      .replacingOccurrences(of: "部属", with: "部署") // Homophone fix
      .replacingOccurrences(of: "第四季度的敏捷迭代", with: "季度敏捷迭代")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if !polished.hasSuffix("。") && !polished.hasSuffix("！") && !polished.hasSuffix("？") && !polished.isEmpty {
      polished += "。"
    }
    return polished
  }
}

/// E2E Orchestrator for Voice Input Pipeline with 4.0s timeout fallback.
public final class OwlE2EVoicePipeline: @unchecked Sendable {
  public let recorder: OwlE2EAudioRecorderProtocol
  public let hotwordsExtractor: OwlE2EVoiceHotwordsExtractorProtocol
  public let asrService: OwlE2EVoiceASRServiceProtocol
  public let polishService: OwlE2EVoicePolishServiceProtocol
  public let timeoutSeconds: TimeInterval

  public init(
    recorder: OwlE2EAudioRecorderProtocol,
    hotwordsExtractor: OwlE2EVoiceHotwordsExtractorProtocol,
    asrService: OwlE2EVoiceASRServiceProtocol,
    polishService: OwlE2EVoicePolishServiceProtocol,
    timeoutSeconds: TimeInterval = 4.0
  ) {
    self.recorder = recorder
    self.hotwordsExtractor = hotwordsExtractor
    self.asrService = asrService
    self.polishService = polishService
    self.timeoutSeconds = timeoutSeconds
  }

  /// Runs voice pipeline: returns (rawTranscript, finalOutput, wasFallbackUsed).
  public func processVoiceInput(
    preContext: String?,
    onSubtitlePreview: @escaping @Sendable (String) -> Void
  ) async throws -> (raw: String, final: String, fallbackUsed: Bool) {
    // 1. Audio recording stopped -> WAV data
    let audioData = try await recorder.stopRecording()

    // 2. Extract hotwords and build prompt <= 800 bytes
    let hotwords = hotwordsExtractor.extractHotwords(limit: 20)
    let prompt = hotwordsExtractor.buildPrompt(preContext: preContext, hotwords: hotwords, maxBytes: 800)

    // 3. Grok ASR transcription
    let rawTranscript = try await asrService.transcribe(audioWavData: audioData, prompt: prompt)

    // 4. Instant subtitle preview
    onSubtitlePreview(rawTranscript)

    // 5. DeepSeek polish with 4.0s timeout fallback
    var finalResult = rawTranscript
    var fallbackUsed = false

    do {
      finalResult = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          try await self.polishService.polish(rawTranscript: rawTranscript)
        }
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
          throw URLError(.timedOut)
        }
        let firstSuccess = try await group.next()!
        group.cancelAll()
        return firstSuccess
      }
    } catch {
      // Timeout or error: seamless zero-loss fallback to raw transcript
      finalResult = rawTranscript
      fallbackUsed = true
    }

    return (rawTranscript, finalResult, fallbackUsed)
  }
}

// MARK: - ====================================================================
// MARK: - Lane C: AI Writing Auxiliary Panel Mocks
// MARK: - ====================================================================

public enum OwlE2EPolishStyle: String, CaseIterable, Sendable {
  case originalFidelity = "原意保真"
  case conciseWritten = "精炼书面"
  case properBusiness = "得体商务"
  case spokenToWritten = "口语转书面"
}

public enum OwlE2EReplyTemplate: String, CaseIterable, Sendable {
  case agree = "认同赞成"
  case decline = "委婉拒绝"
  case inquiry = "进一步询问"
  case gratitude = "感谢致意"
  case followUp = "推进催办"
}

public enum OwlE2EAIInvocationContext: Equatable, Sendable {
  case typing(preedit: String)
  case selection(selectedText: String)
  case standalone
}

public protocol OwlE2ESelectionPolishClientProtocol: Sendable {
  func polishSelection(text: String, style: OwlE2EPolishStyle) async throws -> [String]
}

public protocol OwlE2EReplyGeneratorProtocol: Sendable {
  func generateReplies(contextText: String, template: OwlE2EReplyTemplate) async throws -> [String]
}

/// Mock selection polish client returning exactly 2 candidates per style.
public final class OwlE2EMockSelectionPolishClient: OwlE2ESelectionPolishClientProtocol, @unchecked Sendable {
  private let lock = NSLock()
  public private(set) var recordedRequests: [(text: String, style: OwlE2EPolishStyle)] = []
  public var latency: TimeInterval = 0.0

  public init() {}

  public func polishSelection(text: String, style: OwlE2EPolishStyle) async throws -> [String] {
    if latency > 0 {
      try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }
    lock.lock()
    defer { lock.unlock() }
    recordedRequests.append((text, style))

    switch style {
    case .originalFidelity:
      return ["\(text)（经校准保真版）", "\(text)（清晰原意版）"]
    case .conciseWritten:
      return ["精炼书面候选 1：\(text.prefix(10))", "精炼书面候选 2：\(text.prefix(15))"]
    case .properBusiness:
      return ["尊敬的收件人，关于\(text)，谨此汇报。", "敬启者：针对\(text)事项，特呈此件。"]
    case .spokenToWritten:
      return ["书面表述一：规范化\(text)", "书面表述二：标准化\(text)"]
    }
  }
}

/// Mock reply generator returning exactly 3 candidates per template.
public final class OwlE2EMockReplyGenerator: OwlE2EReplyGeneratorProtocol, @unchecked Sendable {
  private let lock = NSLock()
  public private(set) var recordedRequests: [(contextText: String, template: OwlE2EReplyTemplate)] = []

  public init() {}

  public func generateReplies(contextText: String, template: OwlE2EReplyTemplate) async throws -> [String] {
    lock.lock()
    defer { lock.unlock() }
    recordedRequests.append((contextText, template))

    switch template {
    case .agree:
      return [
        "完全赞同您的观点，我们立即按此推进。",
        "赞同，方案非常周全，我们全力配合。",
        "收到，同意按计划执行。"
      ]
    case .decline:
      return [
        "非常感谢您的提议，但由于当前资源受限，暂无法开展。",
        "抱歉，目前该安排与现有排期冲突，请容我们后续再议。",
        "感谢理解，当前阶段暂不建议启动该项目。"
      ]
    case .inquiry:
      return [
        "请问该方案预期的交付时间节点是怎样的？",
        "可否进一步提供关于该需求的技术细节或背景？",
        "想了解一下相关的预算和人员投入情况。"
      ]
    case .gratitude:
      return [
        "衷心感谢您一直以来的大力支持！",
        "非常感谢您的快速响应与专业解答！",
        "感谢各位团队成员的辛勤付出！"
      ]
    case .followUp:
      return [
        "温馨提醒一下，上述事项目前进展如何？",
        "请教一下该流程的最新状态，如需协助请随时沟通。",
        "为保障下周节点，能否请您协助先行确认该文件？"
      ]
    }
  }
}

/// Simulator for the Floating AI Dialog Panel and Host Focus/Writeback.
public final class OwlE2EAIWritingPanelSimulator: @unchecked Sendable {
  private let lock = NSLock()
  public private(set) var isVisible: Bool = false
  public private(set) var activeContext: OwlE2EAIInvocationContext?
  public private(set) var currentHostText: String = ""
  public private(set) var currentSelectionRange: NSRange = NSRange(location: 0, length: 0)

  public init(initialHostText: String = "") {
    self.currentHostText = initialHostText
  }

  /// Invocations via Shift+K or /ai.
  public func invoke(mode: OwlE2EAIInvocationContext) {
    lock.lock()
    defer { lock.unlock() }
    isVisible = true
    activeContext = mode

    // When invoking during typing, immediately clear preedit in host
    if case .typing(let preedit) = mode {
      if currentHostText.hasSuffix(preedit) {
        currentHostText.removeLast(preedit.count)
      }
    }
  }

  public func dismiss() {
    lock.lock()
    defer { lock.unlock() }
    isVisible = false
    activeContext = nil
  }

  /// Writeback action: "上屏 (↩)" -> inserts text at cursor.
  public func commitToCursor(text: String) {
    lock.lock()
    defer { lock.unlock() }
    currentHostText.append(text)
    isVisible = false
  }

  /// Writeback action: "替换选区 (↩)" -> replaces selection in host.
  public func replaceSelection(with text: String, targetRange: NSRange) {
    lock.lock()
    defer { lock.unlock() }
    let nsString = currentHostText as NSString
    if targetRange.location != NSNotFound && targetRange.location + targetRange.length <= nsString.length {
      currentHostText = nsString.replacingCharacters(in: targetRange, with: text)
    } else {
      currentHostText.append(text)
    }
    isVisible = false
  }
}

// MARK: - ====================================================================
// MARK: - Quality & Hot Path Guardrail Checkers
// MARK: - ====================================================================

public struct OwlE2EHotPathPurityChecker {
  public static func verifyHotPathIsFreeOfAISymbols(rootPath: String) -> (isPure: Bool, violations: [String]) {
    let controllerDir = URL(fileURLWithPath: rootPath).appendingPathComponent("sources/Controller")
    let engineDir = URL(fileURLWithPath: rootPath).appendingPathComponent("sources/Engine")

    let pattern = "\\b(OwlLLMGateway|OwlLLMTransport|OwlURLSessionTransport|" +
      "OwlSelectionPolishClient|OwlStructuredDraftingClient|URLSession|" +
      "OwlAgentBridge[A-Za-z]*|OwlAgentAccess[A-Za-z]*|OwlAgentPeerVerifier)\\b|" +
      "\\b(accept|listen|getpeereid)\\("
    let forbiddenRegex = try! NSRegularExpression(pattern: pattern, options: [])

    var violations: [String] = []
    let fileManager = FileManager.default

    for dir in [controllerDir, engineDir] {
      guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
      for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        let range = NSRange(location: 0, length: (content as NSString).length)
        let matches = forbiddenRegex.matches(in: content, options: [], range: range)
        for match in matches {
          let matchedStr = (content as NSString).substring(with: match.range)
          violations.append("\(fileURL.lastPathComponent): contains '\(matchedStr)'")
        }
      }
    }

    return (violations.isEmpty, violations)
  }
}
