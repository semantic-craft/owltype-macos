//
//  OwlVoicePolishServiceProtocol.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

protocol OwlVoicePolishServiceProtocol: Sendable {
  func polish(rawTranscript: String, hotwords: [String], preContext: String?) async throws -> String
}
