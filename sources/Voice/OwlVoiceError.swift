//
//  OwlVoiceError.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

enum OwlVoiceError: LocalizedError, Equatable, Sendable {
  case missingAPIKey
  case invalidToken(status: Int, message: String?)
  case emptyAudioData
  case badHTTPStatus(status: Int, message: String?)
  case emptyTranscript
  case decodingError(String)
  case networkTimeout
  case cancelled

  var errorDescription: String? {
    let preset = OwlVoiceASRCatalog.preset(id: OwlVoiceSettings.asrProviderID)
    switch self {
    case .missingAPIKey:
      return "未配置 \(preset.keyLabel)，请在 AI 设置中配置。"
    case .invalidToken(let status, let msg):
      return "\(preset.displayName) 认证失败 (\(status)): \(msg ?? "API Key 无效或已过期")"
    case .emptyAudioData:
      return "录音数据为空，无法转写。"
    case .badHTTPStatus(let status, let msg):
      return "\(preset.displayName) 语音服务响应异常 (\(status)): \(msg ?? "未知错误")"
    case .emptyTranscript:
      return "未能识别到有效语音内容。"
    case .decodingError(let detail):
      return "解析语音识别结果失败: \(detail)"
    case .networkTimeout:
      return "语音转写请求超时，请检查网络连接。"
    case .cancelled:
      return "语音识别已取消。"
    }
  }
}
