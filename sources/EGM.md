# sources

## Overview

The native macOS application shell for Owltype: process startup and isolated test storage, InputMethodKit integration, SwiftUI/AppKit surfaces, and native adapters for the Rust engine/application core. The bridge header imports both C ABIs; Swift modules own platform effects while Rust owns the associated policies and domain state. [Main.swift:OwlApp] [Bridging-Header.h]

## Interface

- `OwlApp` defines bundle/shared/user/log locations. `Main.swift` dispatches command-line actions or starts the IMK application, engine, dictionary prompt, and Agent access lifecycle. [Main.swift:OwlApp]
- `OwlTestStorage` and `OwlDefaults` isolate test filesystem/preferences; `OwlPrivateStorage` applies private file/directory permissions. `OwlPerf` provides timing output. [Main.swift:OwlTestStorage] [Main.swift:OwlDefaults] [Main.swift:OwlPrivateStorage] [Main.swift:OwlPerf]
- [Activation](Activation/EGM.md): TIS registration, enablement, installation/self-check orchestration, and diagnostic evidence.
- [Agent](Agent/EGM.md): local Agent bridge, exposed template access, confirmation requests, and receipts.
- [Candidates](Candidates/EGM.md): candidate snapshots, styles, and composition identity.
- [Controller](Controller/EGM.md): process-wide engine lifecycle, per-client IMK sessions, composition, native delivery, and application delegate.
- [Data](Data/EGM.md): symbol and emoji data adapters.
- [DictPack](DictPack/EGM.md): bundled resource preparation, verification, explicit activation/rollback, and optional download adapter.
- [Engine](Engine/EGM.md): C ABI ownership, native ports, runtime configuration, and host capability/context adapters.
- [Lane](Lane/EGM.md): AI providers/transports, explicit conversations and writing, optional composition candidates, searches, and writeback.
- [Settings](Settings/EGM.md): settings/onboarding, preferences, template editing/migration/backup, and diagnostics UI.
- [Theme](Theme/EGM.md): shared candidate/settings color and typography values.
- [UI](UI/EGM.md): native panels, candidate geometry, global hotkeys, template delivery/receipts, and AI/voice presentation.
- [UserMigration](UserMigration/EGM.md): legacy user-dictionary migration and staged reset.
- [Voice](Voice/EGM.md): explicit microphone capture, WAV transcription, provider transport, and optional polish.

## Invariants

- Production data belongs under Owltype's own Application Support directory; private directories use mode `0700` and files `0600`. A test override must be absolute and must not overlap the production root in either direction. Invalid test roots exit with configuration failure; generated test roots and defaults suites are removed at process exit. [Main.swift:OwlPrivateStorage] [Main.swift:OwlTestStorage] [Main.swift:OwlDefaults]
- Test hosts bypass normal engine/IMK startup. Normal graphical launch is admitted only from a system or user `Library/Input Methods` parent, preventing accidental activation of a development copy. [Main.swift]
- Retired `--sync`, `--build`, `--diagnose-rime-config`, and `--apply-keyboard-patch` commands fail with usage status and replacement guidance. TIS registration, enablement, selection, diagnosis, and installer/self-check commands have separate entry points and outcomes. [Main.swift]
- Native callbacks and asynchronous provider results must preserve the owning host/session and current generation; an accepted preference, posted event, or displayed result is not by itself proof of a host text mutation. See [Controller](Controller/EGM.md), [UI](UI/EGM.md), and [Lane](Lane/EGM.md).
- Ordinary typing remains local unless optional cloud candidate features are enabled. Explicit AI, voice, Agent, clipboard, and resource activation have their own admission boundaries; do not infer one module's permission from another's state. See [Lane](Lane/EGM.md), [Voice](Voice/EGM.md), [Agent](Agent/EGM.md), and [Settings](Settings/EGM.md).

## Side Effects

Startup creates/private-modes local directories, changes the working directory to bundled SharedSupport, initializes native application/IMK services, starts the engine and optional bridge services, and enters the application run loop. CLI routes may modify TIS registration/enablement/selection or installation state, post distributed notifications, and print diagnostic results; the ASCII query has a bounded notification reply wait. Subdirectory documents specify host writes, network requests, Keychain, microphone, clipboard, and filesystem effects. [Main.swift]

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target. Native installation, TIS attachment, real-host typing, provider calls, microphone capture, and logout remain distinct live acceptance steps.
