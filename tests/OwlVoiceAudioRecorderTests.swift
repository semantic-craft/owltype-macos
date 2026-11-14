//
//  OwlVoiceAudioRecorderTests.swift
//  OwltypeTests — Lane B: Audio Recorder & WAV Packaging Tests (#393)
//

import AVFoundation
import XCTest
@testable import Owltype

final class OwlVoiceAudioRecorderTests: XCTestCase {

  // MARK: - 1. Canonical 44-byte WAV Header Layout & Endianness

  func testWAVHeaderLayoutAndByteAlignment() {
    let dummyPCM = Data([0x01, 0x02, 0x03, 0x04])
    let wav = OwlWAVPacker.pack16kMono(pcmData: dummyPCM)

    XCTAssertEqual(wav.count, 44 + dummyPCM.count)

    // 0..3: "RIFF"
    XCTAssertEqual(Array(wav[0..<4]), [0x52, 0x49, 0x46, 0x46])
    // 4..7: ChunkSize = 36 + 4 = 40 (0x28)
    let chunkSize = wav.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
    XCTAssertEqual(chunkSize, 40)

    // 8..11: "WAVE"
    XCTAssertEqual(Array(wav[8..<12]), [0x57, 0x41, 0x56, 0x45])
    // 12..15: "fmt "
    XCTAssertEqual(Array(wav[12..<16]), [0x66, 0x6D, 0x74, 0x20])
    // 16..19: Subchunk1Size = 16
    let s1Size = wav.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
    XCTAssertEqual(s1Size, 16)
    // 20..21: AudioFormat = 1 (PCM)
    let format = wav.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self) }
    XCTAssertEqual(format, 1)
    // 22..23: NumChannels = 1
    let channels = wav.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
    XCTAssertEqual(channels, 1)
    // 24..27: SampleRate = 16000
    let sampleRate = wav.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
    XCTAssertEqual(sampleRate, 16000)
    // 28..31: ByteRate = 32000
    let byteRate = wav.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
    XCTAssertEqual(byteRate, 32000)
    // 32..33: BlockAlign = 2
    let blockAlign = wav.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt16.self) }
    XCTAssertEqual(blockAlign, 2)
    // 34..35: BitsPerSample = 16
    let bits = wav.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }
    XCTAssertEqual(bits, 16)
    // 36..39: "data"
    XCTAssertEqual(Array(wav[36..<40]), [0x64, 0x61, 0x74, 0x61])
    // 40..43: Subchunk2Size = 4
    let s2Size = wav.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
    XCTAssertEqual(s2Size, 4)
    // 44..47: PCM data payload
    XCTAssertEqual(Array(wav[44..<48]), [0x01, 0x02, 0x03, 0x04])
  }

  // MARK: - 2. AVFoundation Compatibility

  func testWAVHeaderParsedByAVAudioFile() throws {
    let sampleCount = 1600 // 100ms
    var pcm = Data(capacity: sampleCount * 2)
    for i in 0..<sampleCount {
      var sample = Int16(sin(Double(i) * 0.1) * 20000).littleEndian
      pcm.append(Data(bytes: &sample, count: 2))
    }
    let wav = OwlWAVPacker.pack16kMono(pcmData: pcm)

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_\(UUID().uuidString).wav")
    try wav.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let file = try AVAudioFile(forReading: tempURL)
    XCTAssertEqual(file.processingFormat.sampleRate, 16000)
    XCTAssertEqual(file.processingFormat.channelCount, 1)
    XCTAssertEqual(file.length, 1600)
  }

  // MARK: - 3. 60-Second Cap & Byte Math

  func test60SecondsCapBoundary() {
    let maxPCM = OwlVoiceAudioRecorder.maxPCMBytes
    XCTAssertEqual(maxPCM, 1_920_000)

    let fullWAV = OwlWAVPacker.pack16kMono(pcmData: Data(count: maxPCM))
    XCTAssertEqual(fullWAV.count, 1_920_044)
  }

  // MARK: - 4. Normalization & Decibel Math

  func testNormalizedLevelForRMS() {
    // 1. Extreme silence
    XCTAssertEqual(OwlVoiceAudioRecorder.normalizedLevel(for: 0.00001), 0.0)

    // 2. Normal speech (RMS ≈ 0.1, -20 dBFS -> (-20 - (-45)) / 40 = 25/40 = 0.625)
    let normalLevel = OwlVoiceAudioRecorder.normalizedLevel(for: 0.10)
    XCTAssertEqual(normalLevel, 0.625, accuracy: 0.01)

    // 3. Loud speech (RMS ≈ 0.35, ~ -9 dBFS)
    let loudLevel = OwlVoiceAudioRecorder.normalizedLevel(for: 0.35)
    XCTAssertGreaterThan(loudLevel, 0.85)
    XCTAssertLessThanOrEqual(loudLevel, 1.0)

    // 4. Clamped to 1.0 max
    XCTAssertEqual(OwlVoiceAudioRecorder.normalizedLevel(for: 1.0), 1.0)
    XCTAssertEqual(OwlVoiceAudioRecorder.normalizedLevel(for: 5.0), 1.0)
  }

  // MARK: - 5. Audio Recorder Mock Verification

  func testMockAudioRecorderWorkflow() throws {
    let mock = OwlMockAudioRecorder()
    XCTAssertFalse(mock.isRecording)

    try mock.startRecording()
    XCTAssertTrue(mock.isRecording)
    XCTAssertEqual(mock.startRecordingCallCount, 1)

    var receivedLevel: Float = 0
    mock.audioLevelHandler = { receivedLevel = $0 }
    mock.emitLevel(0.75)
    XCTAssertEqual(receivedLevel, 0.75)

    var autoStopFired = false
    mock.autoStopHandler = { autoStopFired = true }
    mock.triggerAutoStop()
    XCTAssertTrue(autoStopFired)

    let wav = try mock.stopRecording()
    XCTAssertFalse(mock.isRecording)
    XCTAssertEqual(mock.stopRecordingCallCount, 1)
    XCTAssertGreaterThan(wav.count, 44)
  }

  func testMockAudioRecorderDurationGuard() {
    let mock = OwlMockAudioRecorder()
    mock.simulatedDuration = 0.20 // 200ms < 300ms
    try? mock.startRecording()

    XCTAssertThrowsError(try mock.stopRecording()) { error in
      guard case OwlVoiceAudioError.recordingTooShort(let d) = error else {
        return XCTFail("Expected recordingTooShort, got \(error)")
      }
      XCTAssertEqual(d, 0.20, accuracy: 0.001)
    }
  }

  func testMockAudioRecorderSilenceGuard() {
    let mock = OwlMockAudioRecorder()
    mock.simulatedDuration = 1.0
    mock.simulatedPeakRMS = 0.003 // Below 0.008 threshold
    try? mock.startRecording()

    XCTAssertThrowsError(try mock.stopRecording()) { error in
      XCTAssertEqual(error as? OwlVoiceAudioError, .pureSilence)
    }
  }

  func testMockAudioRecorderCancel() {
    let mock = OwlMockAudioRecorder()
    try? mock.startRecording()
    XCTAssertTrue(mock.isRecording)
    mock.cancelRecording()
    XCTAssertFalse(mock.isRecording)
    XCTAssertEqual(mock.cancelRecordingCallCount, 1)
  }

  // MARK: - Adversarial Attacks (challenger_m3_1)

  func testWAVPackerEmptyData() throws {
    let emptyData = Data()
    let wav = OwlWAVPacker.pack16kMono(pcmData: emptyData)

    // Strictly 44-byte RIFF header
    XCTAssertEqual(wav.count, 44)

    // chunkSize = 36 + 0 = 36
    let chunkSize = wav.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
    XCTAssertEqual(chunkSize, 36)

    // subchunk2Size = 0
    let s2Size = wav.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
    XCTAssertEqual(s2Size, 0)

    // Parse with AVAudioFile
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_empty_\(UUID().uuidString).wav")
    try wav.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let file = try AVAudioFile(forReading: tempURL)
    XCTAssertEqual(file.length, 0)
    XCTAssertEqual(file.processingFormat.sampleRate, 16000)
    XCTAssertEqual(file.processingFormat.channelCount, 1)
  }

  func testWAVPackerOddByteCount() throws {
    // 5 bytes = 2 full 16-bit samples + 1 dangling odd byte
    let oddPCM = Data([0x01, 0x02, 0x03, 0x04, 0x05])
    let wav = OwlWAVPacker.pack16kMono(pcmData: oddPCM)

    let chunkSize = wav.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
    let s2Size = wav.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }

    // Odd byte (5th byte) is sanitized/truncated to maintain 2-byte sample alignment:
    // 44-byte header + 4 bytes data = 48 bytes total
    XCTAssertEqual(wav.count, 48)
    XCTAssertEqual(chunkSize, 40)
    XCTAssertEqual(s2Size, 4)
    XCTAssertEqual(Array(wav[44..<48]), [0x01, 0x02, 0x03, 0x04])

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_odd_\(UUID().uuidString).wav")
    try wav.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let file = try AVAudioFile(forReading: tempURL)
    XCTAssertEqual(file.length, 2)
    XCTAssertEqual(file.processingFormat.sampleRate, 16000)
    XCTAssertEqual(file.processingFormat.channelCount, 1)
  }

  func testCancelRecordingOnUnstartedRecorderCompletesImmediatelyWithoutHang() {
    let recorder = OwlVoiceAudioRecorder()

    // Calling cancel on an unstarted recorder must return immediately without hang or deadlock
    recorder.cancelRecording()
  }

  func testStopRecordingOnUnstartedRecorderThrowsWithoutHang() {
    let recorder = OwlVoiceAudioRecorder()

    // Calling stop on an unstarted recorder must throw recordingTooShort(0) without hang or deadlock
    XCTAssertThrowsError(try recorder.stopRecording()) { error in
      XCTAssertEqual(error as? OwlVoiceAudioError, .recordingTooShort(0))
    }
  }

  func testMockStopAndCancelWhenNotRecordingSafety() {
    let mock = OwlMockAudioRecorder()
    XCTAssertFalse(mock.isRecording)

    // Calling cancel when not recording should be safe
    mock.cancelRecording()
    XCTAssertFalse(mock.isRecording)
    XCTAssertEqual(mock.cancelRecordingCallCount, 1)

    // Calling stop when not recording should throw recordingTooShort(0)
    mock.simulatedDuration = 0.0
    XCTAssertThrowsError(try mock.stopRecording()) { error in
      guard case OwlVoiceAudioError.recordingTooShort(let d) = error else {
        return XCTFail("Expected recordingTooShort, got \(error)")
      }
      XCTAssertEqual(d, 0.0)
    }
  }
}

// MARK: - Helper Mock for Tests

public final class OwlMockAudioRecorder: OwlAudioRecordingProtocol, @unchecked Sendable {
  public var audioLevelHandler: (@Sendable (Float) -> Void)?
  public var autoStopHandler: (@Sendable () -> Void)?

  public var isRecording: Bool = false
  public var startRecordingCallCount = 0
  public var stopRecordingCallCount = 0
  public var cancelRecordingCallCount = 0

  public var simulatedDuration: TimeInterval = 1.0
  public var simulatedPeakRMS: Float = 0.1
  public var simulatedWAVData: Data? = nil
  public var shouldThrowOnStart: Error? = nil
  public var shouldThrowOnStop: Error? = nil

  public init() {}

  public func startRecording() throws {
    if let error = shouldThrowOnStart {
      throw error
    }
    startRecordingCallCount += 1
    isRecording = true
  }

  public func stopRecording() throws -> Data {
    stopRecordingCallCount += 1
    isRecording = false
    if let error = shouldThrowOnStop {
      throw error
    }
    if simulatedDuration < OwlVoiceAudioRecorder.minDuration {
      throw OwlVoiceAudioError.recordingTooShort(simulatedDuration)
    }
    if simulatedPeakRMS < OwlVoiceAudioRecorder.silenceThresholdRMS {
      throw OwlVoiceAudioError.pureSilence
    }
    if let data = simulatedWAVData {
      return data
    }
    let pcmCount = Int(simulatedDuration * 16000 * 2)
    return OwlWAVPacker.pack16kMono(pcmData: Data(count: pcmCount))
  }

  public func cancelRecording() {
    cancelRecordingCallCount += 1
    isRecording = false
  }

  public func emitLevel(_ level: Float) {
    audioLevelHandler?(level)
  }

  public func triggerAutoStop() {
    autoStopHandler?()
  }
}
