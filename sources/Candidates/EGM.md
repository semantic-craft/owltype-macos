# Candidate values and composition snapshots

## Overview

Shared candidate presentation values and an immutable snapshot boundary between native input processing and asynchronous readers.

## Interface

- `CandidatePanelState`, `CandidateViewModel`, `OwlScrollRow` and `OwlCandidateToken` carry rendering state and candidate/session/generation identity. [OwlCandidatePanelState.swift:CandidatePanelState]
- `OwlAICandidateLayout.applyAICandidate` and `applyJevRerank` modify supplied candidate arrays; palette/theme/provenance values support rendering. [OwlCandidatePanelState.swift:OwlAICandidateLayout] [OwlCandidatePanelState.swift:OwlCandidateTheme] [OwlCandidatePanelState.swift:OwlProvenance]
- `EngineCandidateSnapshot`, `OwlCompositionSnapshot` and `OwlSnapshotIDGenerator.next` provide copied, Sendable composition values. [OwlCompositionSnapshot.swift:OwlCompositionSnapshot]
- `OwlSnapshotEmitter` publishes composing/cleared states and commit/schema serial changes; `OwlSnapshotRegistry.update` and `isCurrent` hold and compare the live snapshot. [OwlSnapshotEmitter.swift:OwlSnapshotEmitter] [OwlSnapshotRegistry.swift:OwlSnapshotRegistry]

## Invariants

- AI insertion and reranking require matching session, generation and raw input and operate on page zero; reranking preserves original selection tokens when relabelling. [OwlCandidatePanelState.swift:OwlAICandidateLayout]
- Freshness compares sessionID, schemaID, rawInput, preedit, pageNo and commitSerial, excluding snapshot ID and capture time; nil current state is stale. [OwlSnapshotRegistry.swift:isCurrent]
- Emitter and registry are MainActor-isolated; repeated idle clears do not increment commitSerial. Snapshot values contain no engine handle. [OwlSnapshotEmitter.swift:emitCleared] [OwlSnapshotRegistry.swift:OwlSnapshotRegistry] [OwlCompositionSnapshot.swift:OwlCompositionSnapshot]
- Reduce Motion disables animation even when preferences enable it; compact comments require a Wubi schema and a nonempty comment. [OwlCandidatePanelState.swift:animationsAllowed] [OwlCandidatePanelState.swift:showsCompactComment]

## Side Effects

- Updates observable candidate and registry state; emitter increments serials and publishes snapshots. [OwlCandidatePanelState.swift:CandidatePanelState] [OwlSnapshotEmitter.swift:OwlSnapshotEmitter]
- Snapshot ID generation mutates a UInt64 under os_unfair_lock using wrapping addition. [OwlCompositionSnapshot.swift:OwlSnapshotIDGenerator.next]

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target.
