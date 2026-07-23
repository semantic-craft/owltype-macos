//
//  FamoSnapshotEmitter.swift
//  法墨输入法 (Famo) — P0 bypass candidate infrastructure (spec P0-02, emitter part)
//
//  The ONE place that touches the IMK hot-path region. It runs strictly AFTER librime and the
//  main candidate lane have already updated (post-update / post-commit), copies the public
//  composition state into an immutable `FamoCompositionSnapshot`, registers it, and mirrors the
//  Rime candidates into the store's main lane. It NEVER calls process_key / setMarkedText /
//  insertText / commit, never holds a librime pointer, never throws, and never affects the
//  caller — capture failure must not influence input (parent prd hard constraint).
//
//  Ownership: this emitter owns `commitSerial`, the monotonic counter bumped on every
//  commit / clear / escape / schema switch. A snapshot taken before such an event is therefore
//  detectably stale via `FamoSnapshotRegistry.isCurrent(_:)`.
//
//  Concurrency: `@MainActor`-isolated. All call sites are IMK main-thread callbacks; the
//  controller bridges in via `MainActor.assumeIsolated { ... }` (it is itself non-isolated, to
//  match the non-isolated `IMKInputController`, so we cannot annotate the controller).
//

import Foundation

/// Hot-path-adjacent, side-effect-free snapshot emitter (P0-02). Single shared instance because
/// `commitSerial` is one process-wide composition timeline and `FamoSnapshotRegistry`/
/// `FamoCandidateStore` are likewise singletons.
@MainActor
final class FamoSnapshotEmitter {
  /// Shared emitter. The controller's three appended call sites use `FamoSnapshotEmitter.shared`.
  static let shared = FamoSnapshotEmitter()

  /// Commit serial at the head of the composition timeline. Bumped on commit / clear / escape /
  /// schema switch so any snapshot captured earlier is detectably stale.
  private(set) var commitSerial: UInt64 = 0

  /// Whether we believe a composition is currently active. Guards `emitCleared()` against
  /// over-incrementing `commitSerial` on repeated idle (no-composition) updates.
  private var wasComposing: Bool = false

  /// The previous composition's converted-text delta, kept so the backspace-correction hook can
  /// detect a backspace-over-conversion (a shrinking converted run) by comparing to the new one.
  /// `nil` until the first composing update; reset on clear. See `FamoBackspaceCorrection`.
  private var previousDelta: FamoCompositionDelta?

  /// On-device CSC corrector for the 退格 LM 纠错 hook (narrow `FamoCscCorrecting` port). Default
  /// is the concrete `FamoMacbertCscScorer` probing no bundle (no model) → a pure no-op until the
  /// model is bundled; injectable so a test can swap a scripted corrector. Only invoked when the
  /// backspace-correction experiment is on (see `injectBackspaceCorrection`).
  var csc: FamoCscCorrecting = FamoMacbertCscScorer()

  /// Source of the active project for smart-lane injection. Defaults to the shared store;
  /// injectable so a test can point it at an isolated temp directory instead of the real
  /// `~/Library/Application Support/Famo`.
  var projectStore: FamoProjectStore = .shared

  /// Candidate write-sink port. Defaults to the shared store (production composition root);
  /// injectable so a test can assert the emitted candidates without a real store. See
  /// `CandidateStoring` in RimeSeam.swift / `famo-dependency-seams.md`.
  var store: CandidateStoring = FamoCandidateStore.shared

  init() {}

  /// A commit just happened. Bump the serial so pre-commit snapshots are stale. The composition
  /// will be re-emitted (or cleared) by the subsequent `rimeUpdate()`; we do not clear here.
  func noteCommit() {
    commitSerial &+= 1
  }

  /// The active schema changed. Bump the serial so snapshots from the previous schema are stale.
  func noteSchemaChange() {
    commitSerial &+= 1
  }

  /// Emit a fresh snapshot for an active composition. Called from `rimeUpdate()` AFTER the engine
  /// state and the main candidate lane have already been shown. Registers the snapshot and mirrors
  /// the Rime candidates into the store's main lane (source `.rime`, lane `.main`).
  ///
  /// - Important: pure observation. Builds plain values only; touches no librime handle.
  func emitComposing(
    sessionID: UInt64,
    schemaID: String,
    rawInput: String,
    preedit: String,
    cursor: Int,
    pageNo: Int,
    candidates: [RimeCandidateSnapshot]
  ) {
    let snapshot = FamoCompositionSnapshot(
      id: FamoSnapshotIDGenerator.shared.next(),
      sessionID: sessionID,
      schemaID: schemaID,
      rawInput: rawInput,
      preedit: preedit,
      cursor: cursor,
      pageNo: pageNo,
      candidates: candidates,
      commitSerial: commitSerial,
      createdAtNanos: DispatchTime.now().uptimeNanoseconds
    )

    FamoSnapshotRegistry.shared.update(snapshot)

    let mainLane = candidates.map { c in
      EnhancedCandidate(
        snapshotID: snapshot.id,
        source: .rime,
        lane: .main,
        text: c.text,
        comment: c.comment,
        baseRimeIndex: c.index,
        score: c.quality ?? 0,
        commitMode: .rimeIndex
      )
    }
    store.setMainCandidates(mainLane)

    // 项目输入空间 (blueprint_v2 P0): when a project is active, surface its words in the
    // smart lane with the 「项目」provenance. This is the SAME snapshotID-gated upsert path
    // local enhancement services use — a stale composition is dropped by the store — and it
    // touches neither the IMK hot path nor the Rime main lane above. No project active →
    // nothing is injected (smart lane stays as set by P1+ services).
    injectActiveProjectWords(snapshotID: snapshot.id)

    // 退格 LM 纠错: detect a backspace-over-converted-text transition and, when the experiment is
    // on AND a model proposes a different string, surface a correction candidate in the smart lane
    // via the SAME snapshotID-gated upsert. Default-OFF + no-model → complete no-op. Computes the
    // current delta and stores it for the next update's comparison regardless of the toggle.
    let current = FamoCompositionDelta(
      convertedText: FamoBackspaceCorrection.convertedRun(in: preedit),
      rawInput: rawInput,
      isComposing: true
    )
    injectBackspaceCorrection(snapshotID: snapshot.id, previous: previousDelta, current: current)
    previousDelta = current

    wasComposing = true
  }

  /// Inject a backspace correction candidate into the smart lane for `snapshotID`, IFF the
  /// experiment is on AND the `previous → current` transition is a backspace-over-conversion AND a
  /// bundled CSC model proposes a different string. The candidate goes through the SAME
  /// snapshotID-gated upsert as project words, so a stale snapshot drops it. Touches
  /// neither the IMK hot path nor the Rime main lane.
  ///
  /// Exact bypass when off: returns BEFORE constructing or probing the scorer, so the default-OFF
  /// path never runs CSC inference. When on but no model is bundled, the scorer's `correct` returns
  /// the input unchanged → `FamoBackspaceCorrection` yields `nil` → no upsert (no-op).
  private func injectBackspaceCorrection(
    snapshotID: UInt64,
    previous: FamoCompositionDelta?,
    current: FamoCompositionDelta
  ) {
    guard FamoExperimentalPreferences.backspaceCorrectionEnabled else { return }
    guard let previous else { return }
    guard let candidate = FamoBackspaceCorrection.proposeCorrection(
      previous: previous,
      current: current,
      correct: csc.correct
    ) else { return }

    // Surface as a smart-lane external-text candidate. `.localStat` source maps to the 「个人」
    // provenance (a local, non-project on-device suggestion — distinct from project ordering).
    // The comment carries the 纠错 hint for the panel. Committed via the external broker (the
    // delete-then-insert is the broker's job; this only describes the candidate).
    let enhanced = EnhancedCandidate(
      snapshotID: snapshotID,
      source: .localStat,
      lane: .smart,
      text: candidate.displayText,
      comment: "纠错",
      baseRimeIndex: nil,
      score: 0,
      commitMode: .externalText
    )
    store.upsertSmartCandidates([enhanced], snapshotID: snapshotID)
  }

  /// Inject the active project's words into the smart lane for `snapshotID`, IFF a project is
  /// active. Pure observation + the guarded store call: builds `.project`-provenance candidates
  /// (smart lane + `.localNeural` source, which the existing `EnhancedCandidate.provenance`
  /// derivation maps to `.project`), applies the project's 术语锁 rules (`FamoTerminology.apply`)
  /// in the SAME enhancement step — promoting preferred forms to the top and dropping forbidden
  /// variants — then hands the terminology-enforced list to the snapshotID-gated upsert, so a late /
  /// stale snapshot is dropped exactly like any late local result. No-op when no project is active
  /// AND no rules would fire. Touches neither the IMK hot path nor the Rime main lane.
  private func injectActiveProjectWords(snapshotID: UInt64) {
    guard let project = projectStore.activeProject else { return }
    let words = project.normalizedWords
    let rules = project.termRules
    // Nothing to contribute (no project words and no actionable terminology rules) → skip.
    guard !words.isEmpty || !rules.isEmpty else { return }
    let candidates = words.enumerated().map { offset, word in
      EnhancedCandidate(
        snapshotID: snapshotID,
        source: .localNeural,
        lane: .smart,
        text: word,
        comment: nil,
        baseRimeIndex: nil,
        score: Double(words.count - offset),
        commitMode: .externalText
      )
    }
    // 术语锁: enhancement-layer only — reorder/filter the smart-lane candidates, never the main lane.
    let enforced = FamoTerminology.apply(candidates: candidates, rules: rules)
    guard !enforced.isEmpty else { return }
    store.upsertSmartCandidates(enforced, snapshotID: snapshotID)
  }

  /// Composition ended (no context / hidePalettes). Bumps the serial ONCE per active-composition
  /// teardown, clears the registry and all lanes. A no-op when we were already idle, so repeated
  /// idle updates never inflate `commitSerial`.
  func emitCleared() {
    guard wasComposing else { return }
    commitSerial &+= 1
    FamoSnapshotRegistry.shared.update(nil)
    store.clearForSnapshotChange()
    store.setMainCandidates([])
    wasComposing = false
    // Composition gone → drop the backspace-correction delta so the next composition starts fresh
    // (a shrink across a clear is never a backspace-over-conversion within one composition).
    previousDelta = nil
  }
}
