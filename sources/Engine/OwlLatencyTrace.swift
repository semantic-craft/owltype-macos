//
//  OwlLatencyTrace.swift
//  Owltype
//
//  Low-overhead signposts for macOS IME latency. Names describe phases and counts only; never
//  include preedit, committed text, candidate text, prompt bodies, or surrounding host text.
//

import os

enum OwlLatencyTrace {
  typealias Interval = OSSignpostIntervalState

  private static let signposter = OSSignposter(
    subsystem: "im.owltype.inputmethod.Owltype",
    category: "latency"
  )

  @inline(__always)
  static func event(_ name: StaticString) {
    signposter.emitEvent(name)
  }

  @inline(__always)
  static func begin(_ name: StaticString) -> Interval {
    signposter.beginInterval(name)
  }

  @inline(__always)
  static func end(_ name: StaticString, _ state: Interval) {
    signposter.endInterval(name, state)
  }
}
