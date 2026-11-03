# Dictionary resource generations

## Overview

Typed resource manifests, generation lifecycle adapters and the settings/consent state for the Rust dictionaries. Production preparation copies bundled msime resources through `prepareBundled`; the legacy generated download manifest remains available to identify managed schemas. Some existing prompt copy still describes downloading, so it should not be used to infer the current transport.

## Interface

- `OwlDictPackStatus` / `OwlDictPackPreferences` represent preparation/activation/rollback state and consent preferences; `OwlDictPackManifest.current` provides the legacy pinned file list. [OwlDictPack.swift:OwlDictPackStatus] [OwlDictPack.swift:OwlDictPackPreferences] [OwlDictPackManifestData.swift:OwlDictPackManifest.current]
- MainActor `OwlDictPackCenter` exposes refresh, prepare, activate, rollback, retry and prompt orchestration over the resourceCenter Rust session; `OwlDictPackCenterRustBackend` injects asynchronous work. [OwlDictPackCenter.swift:OwlDictPackCenter] [OwlDictPackCenter.swift:OwlDictPackCenterRustBackend]
- `OwlDictPackPrompt` and `OwlDictPackPromptScheduler` implement native consent presentation and safe-time scheduling. [OwlDictPackCenter.swift:OwlDictPackPrompt] [OwlDictPackCenter.swift:OwlDictPackPromptScheduler]
- `OwlRustResourceEnvironment` supplies production roots, stores and active/validated generations; `OwlRustCompatibleResources` delegates catalog/build/validation operations and `OwlDictPackCandidate` projects statistics for UI. [OwlRustDictPackResource.swift:OwlRustResourceEnvironment] [OwlRustDictPackResource.swift:OwlRustCompatibleResources] [OwlRustDictPackResource.swift:OwlDictPackCandidate]
- `OwlRustResourceManifest`, file/role/license/compatibility types and `OwlRustEngineIdentity` define typed contracts; `OwlRustResourceVerifier` delegates generation/file/SQLite compatibility checks through `OwlResourceBusiness`. [OwlRustResourceContract.swift:OwlRustResourceManifest] [OwlRustResourceContract.swift:OwlRustResourceVerifier] [OwlRustResourceContract.swift:OwlResourceBusiness]
- Actor `OwlRustResourceStore` offers install, prepare, prepareBundled, activate, acquireLease, releaseLease, rollback and recover; `OwlRustResourceSource` abstracts manifest reads and file copies. Configuration, active-state/record/prepared/lease values and fault/volume/permission adapters support this boundary. [OwlRustResourceStore.swift:OwlRustResourceStore] [OwlRustResourceStore.swift:OwlRustResourceSource]

## Invariants

- All configured roots must be file URLs; normalization/exclusion and staging/library volume comparison are delegated to resource contract operations. The user learning directory is supplied separately from generation roots. [OwlRustResourceStore.swift:OwlRustResourceConfiguration.prepared] [OwlRustDictPackResource.swift:OwlRustResourceEnvironment.production]
- Resource business errors retain typed Swift identities through `OwlResourceBusiness.map`; manifest validation and engine requirements come from the Rust contract and engine identity, not a source filename. [OwlRustResourceContract.swift:OwlResourceBusiness] [OwlRustResourceContract.swift:OwlRustEngineIdentity]
- Blocking filesystem locking and synchronous Rust calls execute on a GCD utility worker. Cancellation propagates into detached operations; the asynchronous transport bridge waits for its copy task to finish before returning cancellation. [OwlRustResourceStore.swift:OwlRustResourceWorker.call] [OwlRustResourceStore.swift:resourceTransport]
- Native tree permission changes reject symlink entries; synchronized opens use O_NOFOLLOW. Resource process identity includes start time, preventing PID reuse alone from retaining a dead lease. [OwlRustResourceStore.swift:makeWritableTree] [OwlRustResourceStore.swift:applyReadOnlyDirectories] [OwlRustResourceStore.swift:syncFile] [OwlRustResourceStore.swift:OwlRustResourceProcessIdentity]
- Activation can be committed while live-session refresh waits for idle; the center exposes that distinction through isAwaitingLiveSessionRefresh. [OwlDictPackCenter.swift:OwlDictPackCenter.execute]
- Startup consent can defer to onboarding, and scheduler presentation waits for the shared safe-input verdict; autoFetch defaults false. [OwlDictPackCenter.swift:promptOrFetchIfNeeded] [OwlDictPackCenter.swift:OwlDictPackPromptScheduler.tick] [OwlDictPack.swift:OwlDictPackPreferences.autoFetch]

## Side Effects

- Resource worker native effects create/copy/read/write/remove files, fsync files/directories, rename paths, chmod trees, acquire flock locks and inspect process identities, as directed by Rust resource operations. [OwlRustResourceStore.swift:OwlRustResourceWorker]
- Production preparation creates and removes a temporary compatible-resource package directory and updates active/resource state through the backend; live sessions may be refreshed after activation/rollback. [OwlDictPackCenter.swift:OwlDictPackCenterRustBackend.production] [OwlDictPackCenter.swift:OwlDictPackCenter.execute]
- Preferences persist to defaults; prompts show modal UI, activate settings/Owltype, restore the captured application on deferral, poll input idle/snapshots and log lifecycle events. [OwlDictPack.swift:OwlDictPackPreferences] [OwlDictPackCenter.swift:OwlDictPackPromptScheduler]

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target.
