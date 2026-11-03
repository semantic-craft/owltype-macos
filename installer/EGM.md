# Installer blueprint

## Overview

`project.yml` declares the separate `OwltypeInstaller` macOS application target using `Sources/`, with Swift 5, macOS 13 deployment, hardened runtime, and no sandbox entitlement. Packaging supplies the main app's marketing/build versions and embeds the validated app at `Contents/Library/Owltype.app`.

## Subdirectories & Boundaries

- [Sources](./Sources/EGM.md): GUI installation/removal, pure activation policy, and fresh-process TIS diagnostics.
- [Shared](./Shared/EGM.md): atomic file replacement and injected user-session restart sequence, shared with installation callers outside the standalone GUI target.

## Interface

- `[project.yml:targets.OwltypeInstaller]` is the XcodeGen application target. Its source list contains `Sources`; it does not include `Shared` directly.
- `[Sources/Installer.swift:Installer.install()]` is the GUI installation boundary; `[Shared/OwlBundleSwap.swift:OwlBundleSwap]` and `[Shared/OwlSessionRestart.swift:OwlSessionRestart]` define file/session contracts.

## Invariants

- `[project.yml:targets.OwltypeInstaller.settings.base]` sets `GENERATE_INFOPLIST_FILE=NO` and `ENABLE_HARDENED_RUNTIME=YES`; version placeholders derive from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- `[Sources/Installer.swift:install()]` validates the payload and installed app and requires successful session-command output before reporting completion.

## Side Effects

- `[Sources/Installer.swift:install()]` and `uninstall()` perform privileged file operations and user-session changes through their documented CLI/system boundaries. Generating the Xcode project writes the ignored `OwltypeInstaller.xcodeproj`.

## Verification

From the repository root: `make test` for the main project. For the independent GUI build, use the commands in [Sources](./Sources/EGM.md). This documentation pass did not install, launch, or build the application.
