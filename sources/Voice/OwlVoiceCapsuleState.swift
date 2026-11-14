//
//  OwlVoiceCapsuleState.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

enum OwlVoiceCapsuleState: Equatable, Sendable {
  case idle
  case recording(level: Float, duration: TimeInterval, isHandsFreeLocked: Bool)
  case recognizing
  case polishing(rawTranscript: String)
  case completed(finalText: String)
  case failed(String)
}
