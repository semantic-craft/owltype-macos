# Native engine and application-core boundary

## Overview

Swift ports and adapters around the Rust input engine and application core. The input seam returns Swift values while retaining opaque handles inside adapters; AppKit-facing rendering, key conversion, host facts, native storage primitives and diagnostics are represented separately.

## Interface

- `InputEngine` and `EngineSession` define lifecycle, schema, key processing, commit/composition, candidate, option, caret and settled-rerank operations. `SnapshotReading`, `SnapshotEmitting`, `SelectionPolishing` and `PromptResolving` are narrow controller service ports. [EngineSeam.swift:InputEngine] [EngineSeam.swift:EngineSession] [EngineSeam.swift:SnapshotReading] [EngineSeam.swift:SnapshotEmitting] [EngineSeam.swift:SelectionPolishing] [EngineSeam.swift:PromptResolving]
- `EngineCandidate`, `EngineComposition`, `EngineStatus` and `EngineOption` define value/option boundaries. `EngineCompositionRenderer.markedText` returns UTF-16 marked-text/caret/selection values. [EngineValueTypes.swift:EngineComposition] [EngineOption.swift:EngineOption] [EngineCompositionRenderer.swift:EngineCompositionRenderer]
- `OwlRustEngine` / `OwlRustSession` implement the input ports via owl_msime functions; `OwlRustSchemaMap` projects the Rust keyboard catalog. Snapshot/rerank DTOs remain internal transport types. [OwlRustEngine.swift:OwlRustEngine] [OwlRustEngine.swift:OwlRustSession] [OwlRustEngine.swift:OwlRustSchemaMap] [OwlRustPayloads.swift:OwlRustSnapshotDTO]
- `OwlAppCore.call`, `required` and `payload` transport versioned JSON requests; `OwlAppSession` owns stateful Rust sessions and `OwlStorageHost.call` exposes native effects to Rust-owned storage protocols. [OwlAppCore.swift:OwlAppCore] [OwlAppCore.swift:OwlAppSession] [OwlAppCore.swift:OwlStorageHost]
- `OwlKeycode`, `OwlKeyEvent`, `OwlUserActionClassifier`, `OwlCapsLockKeyState` and OwlRustSession key-routing helpers translate platform key facts and preferences. [MacOSKeyCodes.swift:OwlKeycode] [OwlUserAction.swift:OwlKeyEvent] [OwlUserAction.swift:OwlUserActionClassifier] [OwlRustEngine+KeyRouting.swift:OwlCapsLockKeyState]
- `OwlClientCapabilityPolicy.evaluate` projects Rust policy from host/privacy/workaround values; `OwlElectronHostDetector` supplies bundle-framework facts. [OwlClientCapabilityPolicy.swift:OwlClientCapabilityPolicy] [OwlElectronHostDetector.swift:OwlElectronHostDetector]
- `OwlForcedFinalize`, `OwlMarkedTextResendPolicy`, `OwlSchemaSelectionGate` and `SchemaSwitchResult` represent finalization/resend/schema decisions; `OwlUserDictReset` adapts reset storage operations. [OwlForcedFinalize.swift:OwlForcedFinalize] [OwlMarkedTextResendPolicy.swift:OwlMarkedTextResendPolicy] [OwlSchemaSelectionGate.swift:OwlSchemaSelectionGate] [OwlUserDictReset.swift:OwlUserDictReset]
- `OwlLatencyTrace` emits signposts and `OwlLiveInputTrace` provides opt-in lazy file tracing. [OwlLatencyTrace.swift:OwlLatencyTrace] [OwlLiveInputTrace.swift:OwlLiveInputTrace]

## Invariants

- InputEngine/EngineSession are synchronous and require the IMK callback thread. OwlAppSession is likewise owner-thread state, not a concurrently shared handle. FFI-owned response strings and sessions are explicitly freed. [EngineSeam.swift:EngineSession] [OwlAppCore.swift:OwlAppSession] [OwlRustEngine.swift:OwlRustSession.destroy]
- Engine composition offsets are UTF-8 bytes; renderer output offsets are UTF-16. An otherwise empty rendering during nonempty composition gets U+200B; genuinely empty input remains empty. [EngineValueTypes.swift:EngineComposition] [EngineCompositionRenderer.swift:markedText]
- Candidate token selection rejects mismatched nonzero session IDs and passes nonzero generations to Rust; removal additionally requires an exact session, nonzero generation and page-relative index. [OwlRustEngine.swift:OwlRustSession.selectCandidate] [OwlRustEngine.swift:OwlRustSession.removeCandidate]
- A live-session schema ID changes only after all configuration actions and clearing succeed. Preferences marked requiresIdle defer through the Rust can-apply policy; applied-value caches update after successful actions. [OwlRustEngine.swift:OwlRustSession.selectSchema] [OwlRustEngine.swift:applyChanged]
- Settled readiness requires enabled, ready and attached; configuration changes bump the epoch. Rerank tickets compare session, generation, raw input and epoch. [OwlRustEngine.swift:applyRerankStatus] [OwlRustEngine.swift:syncRerankConfiguration] [EngineSeam.swift:OwlSettledRerankTicket]
- `takeCommit` drains its pending string once. Forced-finalize sequencing always invokes emitCleared, even without input; its text-choice policy is delegated to forced_finalize_commit_text. [OwlRustEngine.swift:OwlRustSession.takeCommit] [OwlForcedFinalize.swift:finalize]
- NSEvent character properties are read only for keyDown. Disabled live tracing never evaluates its message closure. Capability projections use an eight-entry locked cache; unresolved running Electron hosts are not cached. [OwlUserAction.swift:OwlKeyEvent.init] [OwlLiveInputTrace.swift:write] [OwlClientCapabilityPolicy.swift:evaluate] [OwlElectronHostDetector.swift:linksElectron]
- App-core required calls fail loudly on ABI/decoding incompatibility instead of installing independent Swift defaults. Storage calls release newly acquired locks on exit and map native error tokens back to their original errors. [OwlAppCore.swift:OwlAppCore.required] [OwlAppCore.swift:OwlStorageHost.call]

## Side Effects

- Creates/destroys engine sessions, mutates Rust conversion/learning state, configures rerank workers, updates runtime status and calls engine notifications. Generation resolution reads active resources or hashes bundled files; host phrase loading reads the selected library exports. [OwlRustEngine.swift:OwlRustEngine.createSession] [OwlRustEngine.swift:resolvedSessionGeneration] [OwlRustEngine.swift:loadPackedHostPhrases] [OwlRustEngine.swift:OwlRustSession]
- OwlStorageHost performs restricted storage writes/replacements/removals, path moves, locks, checkpoint callbacks and library-committed notifications; transaction policy remains in Rust. [OwlAppCore.swift:OwlStorageHost]
- Reset effects inspect/copy/remove user data under Rust user_reset policy; callers own stopping/restarting engine sessions. [OwlUserDictReset.swift:execute]
- Host detection reads running-app bundle contents; privacy facts query Secure Event Input. Diagnostic tracing emits signposts or writes a temporary log with mode 0600 when enabled. [OwlElectronHostDetector.swift:bundleLinksElectron] [OwlClientCapabilityPolicy.swift:OwlClientPrivacyState.current] [OwlLatencyTrace.swift:OwlLatencyTrace] [OwlLiveInputTrace.swift:write]

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target.
