//
//  OwlVoiceAudioRecorder.swift
//  Owltype — Voice Input Subsystem
//

import Accelerate
import AVFoundation
import Foundation
import os

public final class OwlVoiceAudioRecorder: OwlAudioRecordingProtocol, @unchecked Sendable {
  public static let shared = OwlVoiceAudioRecorder()

  public static let maxDuration: TimeInterval = 60.0
  public static let maxPCMBytes = 16000 * 2 * 60 // 1,920,000 bytes
  public static let minDuration: TimeInterval = 0.30
  public static let silenceThresholdRMS: Float = 0.008

  public var audioLevelHandler: (@Sendable (Float) -> Void)?
  public var autoStopHandler: (@Sendable () -> Void)?

  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?

  private struct RecorderState {
    var isRecording: Bool = false
    var startTime: Date?
    var pcmData: Data = Data()
    var peakRMS: Float = 0.0
    var autoStopTriggered: Bool = false
  }

  private let lock = OSAllocatedUnfairLock(initialState: RecorderState())

  public init() {}

  public func startRecording() throws {
    // 1. Check microphone permission
    guard OwlMicrophonePermission.isAuthorized else {
      throw OwlVoiceAudioError.microphonePermissionDenied
    }

    try lock.withLock { state in
      guard !state.isRecording else {
        throw OwlVoiceAudioError.alreadyRecording
      }
      state.isRecording = true
      state.startTime = Date()
      state.pcmData = Data(capacity: 32000 * 5)
      state.peakRMS = 0.0
      state.autoStopTriggered = false
    }

    let input = engine.inputNode
    let nativeFormat = input.outputFormat(forBus: 0)

    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16000,
      channels: 1,
      interleaved: true
    ) else {
      lock.withLock { $0.isRecording = false }
      throw OwlVoiceAudioError.converterCreationFailed
    }

    guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
      lock.withLock { $0.isRecording = false }
      throw OwlVoiceAudioError.converterCreationFailed
    }
    self.converter = converter

    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
      self?.processIncomingBuffer(buffer, targetFormat: targetFormat)
    }

    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      lock.withLock { $0.isRecording = false }
      throw OwlVoiceAudioError.engineFailedToStart(error.localizedDescription)
    }
  }

  public func stopRecording() throws -> Data {
    let (wasRecording, pcm, dur, peak) = lock.withLock { state -> (Bool, Data, TimeInterval, Float) in
      let prev = state.isRecording
      state.isRecording = false
      guard prev else {
        return (false, state.pcmData, 0, state.peakRMS)
      }
      let d = state.startTime.map { Date().timeIntervalSince($0) } ?? 0
      return (true, state.pcmData, d, state.peakRMS)
    }

    guard wasRecording else {
      throw OwlVoiceAudioError.recordingTooShort(0)
    }

    engine.stop()
    engine.inputNode.removeTap(onBus: 0)

    // Mis-touch validation
    if dur < Self.minDuration {
      throw OwlVoiceAudioError.recordingTooShort(dur)
    }
    if peak < Self.silenceThresholdRMS {
      throw OwlVoiceAudioError.pureSilence
    }

    return OwlWAVPacker.pack16kMono(pcmData: pcm)
  }

  public func cancelRecording() {
    let wasRecording = lock.withLock { state -> Bool in
      let prev = state.isRecording
      state.isRecording = false
      state.pcmData.removeAll(keepingCapacity: false)
      return prev
    }
    guard wasRecording else { return }
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
  }

  private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
    guard let converter = self.converter,
          let channelData = buffer.floatChannelData else { return }

    // 1. RMS Calculation via Accelerate vDSP
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return }

    var rms: Float = 0
    vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameLength))

    // 2. Logarithmic dBFS normalization (-45dB to -5dB) -> 0.0...1.0
    let level = Self.normalizedLevel(for: rms)
    DispatchQueue.main.async { [weak self] in
      self?.audioLevelHandler?(level)
    }

    // 3. Resample & Convert to 16kHz Int16 Mono
    let sampleRatio = 16000.0 / buffer.format.sampleRate
    let targetCapacity = AVAudioFrameCount(ceil(Double(frameLength) * sampleRatio)) + 32
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else { return }

    var hasSuppliedInput = false
    var convError: NSError?
    _ = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
      if hasSuppliedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      hasSuppliedInput = true
      outStatus.pointee = .haveData
      return buffer
    }

    guard convError == nil,
          outputBuffer.frameLength > 0,
          let int16Ptr = outputBuffer.int16ChannelData?[0] else { return }

    let byteCount = Int(outputBuffer.frameLength) * 2
    let rawData = Data(bytes: int16Ptr, count: byteCount)

    // 4. Thread-safe accumulation and 60s cap check
    let shouldTriggerAutoStop = appendPCMData(rawData, rms: rms)

    if shouldTriggerAutoStop {
      DispatchQueue.main.async { [weak self] in
        self?.autoStopHandler?()
      }
    }
  }

  @discardableResult
  internal func appendPCMData(_ rawData: Data, rms: Float) -> Bool {
    var shouldTriggerAutoStop = false
    lock.withLock { state in
      guard state.isRecording else { return }
      state.peakRMS = max(state.peakRMS, rms)
      let remaining = max(0, Self.maxPCMBytes - state.pcmData.count)
      if remaining > 0 {
        state.pcmData.append(rawData.prefix(remaining))
      }
      if state.pcmData.count >= Self.maxPCMBytes, !state.autoStopTriggered {
        state.autoStopTriggered = true
        shouldTriggerAutoStop = true
      }
    }
    return shouldTriggerAutoStop
  }

  public static func normalizedLevel(for rms: Float) -> Float {
    if rms < 0.0001 { return 0.0 }
    let dB = 20.0 * log10(max(rms, 0.00001))
    let minDB: Float = -45.0
    let maxDB: Float = -5.0
    let normalized = (dB - minDB) / (maxDB - minDB)
    return min(max(normalized, 0.0), 1.0)
  }
}
