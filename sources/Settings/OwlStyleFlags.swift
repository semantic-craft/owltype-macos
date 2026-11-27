//
//  OwlStyleFlags.swift
//  法墨输入法 (Owltype) — candidate-window layout flags (not theming)
//
//  The candidate-window LAYOUT flags the IMK path reads from `EngineRuntime`:
//    linear / vertical → which engine options the hot path (`processKey`) syncs;
//    inlinePreedit / inlineCandidate → how `engineUpdate` assembles the inline preview;
//    statusMessageType → how the status HUD picks long vs. short labels.
//
//  Derived from `OwlCandidatePanelSettings` off the IMK hot path; the struct itself is
//  `Sendable` plain data.
//

import Foundation

/// Candidate-window layout flags driven by `OwlCandidatePanelSettings`.
struct OwlStyleFlags: Sendable, Equatable {
  var linear = true
  var vertical = false
  var inlinePreedit = true
  var inlineCandidate = false
  var statusMessageType: OwlStatusMessageType = .mix
}
