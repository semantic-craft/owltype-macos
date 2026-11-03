//
//  OwlAICommandDetector.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M6 / Issue #394)
//
//  Pure Swift state machine running in OwlInputController to intercept the "/ai" sequence
//  without touching networking, LLM gateways, or Rime engine internals.
//

import Foundation

final class OwlAICommandDetector {
  enum State: Equatable {
    case idle
    case sawSlash(timestamp: Date)
    case sawSlashA(timestamp: Date)
  }

  private(set) var state: State = .idle
  var timeout: TimeInterval = 1.0

  init(timeout: TimeInterval = 1.0) {
    self.timeout = timeout
  }

  var isArmed: Bool {
    state != .idle
  }

  /// Processes an incoming character string.
  /// - Returns:
  ///   - `isTriggered`: `true` if `/ai` sequence was successfully completed.
  ///   - `shouldFlush`: tuple indicating whether buffered '/' and/or 'a' should be flushed to client.
  func process(
    character: String,
    at now: Date = Date()
  ) -> (isTriggered: Bool, shouldFlush: (slash: Bool, a: Bool)) {
    switch state {
    case .idle:
      if character == "/" {
        state = .sawSlash(timestamp: now)
        return (false, (false, false))
      }
      return (false, (false, false))

    case let .sawSlash(timestamp):
      if now.timeIntervalSince(timestamp) > timeout {
        if character == "/" {
          state = .sawSlash(timestamp: now)
          return (false, (true, false))
        }
        state = .idle
        return (false, (true, false))
      }

      if character.caseInsensitiveCompare("a") == .orderedSame {
        state = .sawSlashA(timestamp: now)
        return (false, (false, false))
      }

      if character == "/" {
        state = .sawSlash(timestamp: now)
        return (false, (true, false))
      }

      state = .idle
      return (false, (true, false))

    case let .sawSlashA(timestamp):
      if now.timeIntervalSince(timestamp) > timeout {
        if character == "/" {
          state = .sawSlash(timestamp: now)
          return (false, (true, true))
        }
        state = .idle
        return (false, (true, true))
      }

      if character.caseInsensitiveCompare("i") == .orderedSame {
        state = .idle
        return (true, (false, false))
      }

      if character == "/" {
        state = .sawSlash(timestamp: now)
        return (false, (true, true))
      }

      state = .idle
      return (false, (true, true))
    }
  }

  /// Return a partially typed command to normal host input before abandoning detection.
  func flushPendingText() -> String {
    defer { reset() }
    switch state {
    case .idle: return ""
    case .sawSlash: return "/"
    case .sawSlashA: return "/a"
    }
  }

  func reset() {
    state = .idle
  }
}
