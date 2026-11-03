# Input-source activation and installation

## Overview

macOS TIS activation, read-only activation diagnostics, the privileged bundle file phase, and the user-session restart driver.

## Interface

- `OwlInstaller` registers, enables, selects and disables exact input-source IDs; `InputMode`, `SelectOutcome`, `makeDefaultPlan` and `makeDefault` expose explicit selection outcomes. [InputSource.swift:OwlInstaller]
- `TISSourceState`, `TISDiagnosis`, `OwlTISReport` and `LSClaimReport` describe activation and LaunchServices observations; `OwlTISDiagnostics` delegates classification rules to `OwlAppCore`. [InputSource.swift:OwlTISDiagnostics]
- `OwlInstallFiles.commit(source:)` installs a validated bundle; the injectable `Layout` overload supplies verification and ownership effects. [OwlInstallFiles.swift:OwlInstallFiles]
- `OwlInstallSession` implements `OwlSessionRestart.Effects`, with `finish`, `recheck`, `enableForFirstInstall` and `probe` for the installed executable. [OwlInstallSession.swift:OwlInstallSession]

## Invariants

- An empty enable request preserves already enabled modes; explicit default selection prefers an enabled Owltype mode. Registration repair registers/notifies/refreshes without selecting a source. [InputSource.swift:OwlInstaller.enable] [InputSource.swift:OwlInstaller.makeDefaultPlan] [InputSource.swift:OwlInstaller.repairRegistrationForInstalledBundle]
- The privileged file entry requires root; work directories must be owned directories rather than symlinks, work/live locations must share a volume, and existing identity/connection/mode metadata must match before replacement. [OwlInstallFiles.swift:commit] [OwlInstallFiles.swift:privateDirectory] [OwlInstallFiles.swift:requireSameVolume]
- Session completion requires the canonical installed bundle, expected version and a non-root console-user session; timed-out commands throw and cannot become successful probes. [OwlInstallSession.swift:finish] [OwlInstallSession.swift:command]
- LaunchServices claim warnings remain outside the headline TIS summary; unknown observation layers remain nullable. [InputSource.swift:OwlTISDiagnostics.buildReport] [InputSource.swift:LayerResult]

## Side Effects

- TIS mutations and distributed notifications; input-menu agent refresh executes killall. [InputSource.swift:OwlInstaller]
- Copies, validates, changes ownership and swaps app files through `OwlBundleSwap`; locks installation with a directory and removes successful-run leftovers. [OwlInstallFiles.swift:commit]
- Stops old processes, launches the installed app, executes bounded subprocesses with temporary file-backed output, and records/posts self-check status. [OwlInstallSession.swift:command] [OwlInstallSession.swift:reportSelfCheck]
- Host-event health writes/reads a timestamp in the temporary directory; diagnostic reporting reads TIS, filesystem metadata and signatures. [InputSource.swift:OwlActivationHealth] [InputSource.swift:OwlTISDiagnostics]

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target.
