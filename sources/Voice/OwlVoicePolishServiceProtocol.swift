//
//  OwlVoicePolishServiceProtocol.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

public protocol OwlVoicePolishServiceProtocol: Sendable {
  func polish(rawTranscript: String, hotwords: [String], preContext: String?) async throws -> String
}

public extension OwlVoicePolishServiceProtocol {
  func polish(rawTranscript: String) async throws -> String {
    try await polish(rawTranscript: rawTranscript, hotwords: [], preContext: nil)
  }

  func polish(rawTranscript: String, hotwords: [String]) async throws -> String {
    try await polish(rawTranscript: rawTranscript, hotwords: hotwords, preContext: nil)
  }
}
