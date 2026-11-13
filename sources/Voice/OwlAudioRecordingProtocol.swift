//
//  OwlAudioRecordingProtocol.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

public enum OwlVoiceAudioError: LocalizedError, Equatable, Sendable {
  case microphonePermissionDenied
  case engineFailedToStart(String)
  case converterCreationFailed
  case recordingTooShort(TimeInterval)
  case pureSilence
  case alreadyRecording
  case notRecording

  public var errorDescription: String? {
    switch self {
    case .microphonePermissionDenied:
      return "麦克风访问权限未授予，请在系统设置中允许法墨输入法访问麦克风。"
    case .engineFailedToStart(let reason):
      return "音频引擎启动失败: \(reason)"
    case .converterCreationFailed:
      return "无法创建音频格式转换器。"
    case .recordingTooShort(let duration):
      return String(format: "录音时间过短 (%.2f秒)，已取消。", duration)
    case .pureSilence:
      return "未检测到有效声音，已取消。"
    case .alreadyRecording:
      return "录音已在进行中。"
    case .notRecording:
      return "当前未在录音。"
    }
  }
}

public protocol OwlAudioRecordingProtocol: AnyObject, Sendable {
  var audioLevelHandler: (@Sendable (Float) -> Void)? { get set }
  var autoStopHandler: (@Sendable () -> Void)? { get set }
  var isRecording: Bool { get }
  var duration: TimeInterval { get }

  func startRecording() throws
  func stopRecording() throws -> Data
  func cancelRecording()
}
