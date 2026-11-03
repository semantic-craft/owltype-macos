# Shared installation primitives

## Overview

These Foundation/Darwin primitives separate atomic bundle replacement from user-session restart. Callers provide signature checks, protected staging, serialization, and concrete session effects; this directory does not implement the privileged entry point.

## Interface

- `[OwlBundleSwap.swift:OwlBundleSwap.exchangeContents(in:)]` exchanges `Contents` and `.Contents.update`; `publishFirstInstall(from:to:)` publishes without replacing an existing destination; `commitPreparedApp(_:to:retired:validate:)` validates and commits a staged app with rollback.
- `[OwlBundleSwap.swift:OwlBundleSwap.isCanonical(_:)]` checks the raw file URL against `realpath`.
- `[OwlSessionRestart.swift:OwlSessionRestart.Request]`, `Observation`, and `Server` describe the expected selection/version and fresh process/input-source evidence. `Effects` supplies bounded session operations to `run(_:effects:timeout:consentTimeout:)`.
- `[OwlSessionRestart.swift:OwlSessionRestart.unmetConditions(_:request:)]`, `unmetServerConditions(_:expectedVersion:)`, `diagnose(_:request:stage:lastObservation:)`, and `Diagnosis.summary` turn failures into stage-specific evidence. `serverQuery(uid:name:)`, `server(pid:mapping:installedInode:)`, and `mapsInstalledExecutable(_:inode:)` support native process probes.

## Invariants

- `[OwlBundleSwap.swift:exchangeContents(in:)]` requires canonical directories and matching device IDs, then uses `RENAME_SWAP`. `[OwlBundleSwap.swift:publishFirstInstall(from:to:)]` uses `RENAME_EXCL`. There is no copy/two-move fallback.
- `[OwlBundleSwap.swift:commitPreparedApp(_:to:retired:validate:)]` validates before publishing, rejects an existing retired path, moves retired contents outside the app before live validation, and attempts reversal on validation failure; recovery errors propagate.
- `[OwlSessionRestart.swift:Request.selectionTarget]` chooses Hans for first installation, preserves Hans/Hant on update, and otherwise leaves the prior input source selected.
- `[OwlSessionRestart.swift:run(_:effects:timeout:consentTimeout:)]` rejects a non-user session or missing context, waits at most five seconds for old processes (forcing after two), separates enable-consent time from verification time, and requires fresh observations after selection.
- `[OwlSessionRestart.swift:unmetServerConditions(_:expectedVersion:)]` requires parent/mode enabled and exactly one positive-PID server at the installed executable, with the expected bundle version and matching mapped executable inode. This is session evidence, not host typing acceptance.

## Side Effects

- `[OwlBundleSwap.swift:rename(_:to:flags:)]` mutates filesystem directory names with `renamex_np`; old contents remain available for caller-managed retirement.
- `[OwlSessionRestart.swift:executablePath(of:)]` and `bundleVersion(of:mapping:)` read process and filesystem metadata. `[OwlSessionRestart.swift:run(_:effects:timeout:consentTimeout:)]` invokes injected effects to stop processes, enable/select input sources, refresh services, launch the installed app, and wait.

## Verification

From the repository root: `make test`. This invokes the main Xcode test graph and can build/download dependencies; it does not establish real-host typing acceptance. No build or session operation was run to generate this contract.
