# Installer application

## Overview

The standalone SwiftUI installer finds its embedded Owltype app, validates it, invokes the input method's privileged file-commit and user-session finishing commands, and presents the result. Its build target is declared in `installer/project.yml`.

## Interface

- `[main.swift:--tis-probe]` prints fresh TIS diagnostics before SwiftUI starts; otherwise it invokes `[OwltypeInstallerApp.swift:OwltypeInstallerApp]`. `AppDelegate` makes the app foreground-visible and terminates after its last window closes.
- `[ContentView.swift:InstallerViewModel.install()]`, `uninstall()`, `failureText(for:)`, and `ContentView` expose installation/removal with busy-state UI and main-queue result updates.
- `[Installer.swift:Installer.embeddedOwltypeAppURL()]`, `install()`, `uninstall()`, and `runProcess(_:_:)` provide payload discovery, validated installation, scoped removal, and checked CLI execution. `InstallerError` distinguishes missing payload, cancellation, validation, privileged-command, and activation failures.
- `[InstallerActivationPolicy.swift:InstallerActivationPolicy.plan(bundlePreexisted:owltypeProcessWasRunning:owltypeWasCurrentSource:)]` derives enable/select decisions; `parkingSourceID(preferredID:selectableASCIIKeyboardIDs:)` selects an available ASCII keyboard; `probeOutput(_:)` and `parseProbeOutput(_:)` define the diagnostic text protocol.
- `[InstallerTISProbe.swift:InstallerTISProbe.output()]` reads parent enable state, primary-mode membership in enabled sources, and select capability.

## Invariants

- `[Installer.swift:validatePayload(at:)]` checks the expected bundle ID, numeric version components, executable, non-nested bundle layout, and expected Developer ID signature chain/team. `[Installer.swift:installKind(for:)]` rejects downgrades and a different bundle ID at the installation path.
- `[Installer.swift:install()]` samples prior bundle/process/source state before replacement, validates the installed app afterward, and returns only when `--finish-install` output contains `INSTALL_SESSION_OK `.
- `[InstallerActivationPolicy.swift:plan(bundlePreexisted:owltypeProcessWasRunning:owltypeWasCurrentSource:)]` treats either an existing bundle or running process as an existing installation. Only first installation requests initial enablement; selection on update depends on whether Owltype was selected.
- `[InstallerActivationPolicy.swift:parseProbeOutput(_:)]` requires `parent` and `hans` values of `0` or `1`; malformed required values return `nil`.
- `[Installer.swift:runProcess(_:_:)]` drains the shared stdout/stderr pipe before waiting and rejects nonzero exit status.

## Side Effects

- `[Installer.swift:privilegedReplace(fromAppPath:)]` runs embedded Owltype `--commit-install` using an AppleScript administrator authorization dialog; `[Installer.swift:install()]` runs installed Owltype `--finish-install` in the user session.
- `[Installer.swift:uninstall()]` parks an active Owltype input source, disables/quits it, terminates the user's Owltype process, removes the explicit Owltype user-data paths, and uses privileged removal for the installed app/state and package receipt when present.
- `[ContentView.swift:InstallerViewModel]` dispatches work to a background queue and publishes results on the main queue. `[InstallerTISProbe.swift:currentSignals()]` reads Carbon TIS state.

## Verification

From the repository root: `make test` covers policy/shared behavior through the main Xcode project. The standalone app can be generated and built from `installer/` with `xcodegen generate` followed by `xcodebuild -project OwltypeInstaller.xcodeproj -scheme OwltypeInstaller -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`. Build success does not prove administrator authorization, TIS enablement, or real-host typing. These commands were not run for this documentation pass.
