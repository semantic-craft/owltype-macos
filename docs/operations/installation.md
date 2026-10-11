# Installation and activation constraints

This describes the branch implementation. Native acceptance and failures are recorded in
[the no-logout investigation](no-logout-install-update.md); unit tests do not establish host typing.
Release composition remains in the [publishing checklist](../PUBLISHING_CHECKLIST.md).

## Shared file and session phases

Both the GUI installer and package scripts invoke the installed payload's CLI:

| Phase | Owner | Contract |
| --- | --- | --- |
| Capture | GUI / preinstall | Capture existing installation and exact selected source before replacement. Missing update context fails closed. |
| Stage | PackageKit / privileged file helper | PKG payload contains only `/Library/Input Methods/.Owltype.pkg-staging/Owltype.app.zip`. postinstall unpacks into a fresh root-only directory, verifies and commits, then removes that private unpack directory before session recovery. The live App and all nested bundles are absent from the PackageKit payload. |
| Commit | `--commit-install` as root | Copy into a protected candidate, validate signature and unchanged identities, preserve the live App shell, exchange `Contents` and `.Contents.update` with `RENAME_SWAP`. Move retired contents outside the App before strict signature verification. First install uses `RENAME_EXCL`. |
| Activate | `--finish-install` as console user | End old installed server instances, register/enable parent and primary mode only on first install, read back selection, refresh only TextInputMenuAgent/TextInputSwitcher, launch the installed App, and poll its state. |
| Verify | Fresh user-session probe | Require enabled input sources, expected selection, one server at the installed executable path, expected LS version and current executable inode. Default budget is 45 seconds. |

Implementation: [file primitive](../../installer/Shared/OwlBundleSwap.swift),
[privileged file phase](../../sources/Activation/OwlInstallFiles.swift),
[session sequence](../../installer/Shared/OwlSessionRestart.swift),
[native effects](../../sources/Activation/OwlInstallSession.swift),
[GUI](../../installer/Sources/Installer.swift),
[preinstall](../../scripts/preinstall), [postinstall](../../scripts/postinstall).

The privileged phase does not manipulate input sources, user processes, dictionaries, or preferences.
A private lock serializes commits. Interrupted prepared/retired directories are retained; do not
blindly remove them or retry over an unknown `.Contents.update`. Validate identities before recovery.
On a post-exchange validation failure, the file primitive swaps back and retains the failed candidate.
A failure of recovery itself stops the operation and requires inspection of both locations.

Updates preserve the exact Hans/Hant mode when Owltype was selected. When another source was selected,
the session sequence performs no select operation; a changed readback fails self-check instead of
forcing a different source. Uninstallation still uses an available ASCII keyboard for parking.
First-install consent must be accepted by the user; a process/TIS self-check cannot substitute for it.

Strict signature verification rejects `.Contents.update` inside an App as unsealed contents. Retired
contents must leave the bundle before validation and before the installer starts the new server.
The native macl spike confirmed that keeping the App shell preserves its inode and macl on the tested
host. That result is not a general proof for every macOS version or filesystem.

## Recovery guidance

Neither package requests RequireLogout. The GUI reports success only after the shared self-check;
its former 30-second logout timer is gone. The input menu has no permanent logout action.
A version change, including a downgrade, never arms a logout prompt. An explicit failed session
self-check can notify the running App to offer recovery guidance at an input-safe time. The default
button keeps the session open. The GUI also reports a failed self-check without requesting logout.

Sparkle's existing package installer remains in use on this branch at present. Its upstream lifecycle
may terminate the host before package execution. Download-only handoff and the real Sparkle entrypoint
remain unresolved and must not be presented as verified. Native logs disproved the previous empty-component-list
assumption: PackageKit still registered the staged App after postinstall and the process/TIS self-check.
The revised format gives PackageKit only an inert archive. Release, identity and secret gates unpack and
inspect its real contents; they reject direct App payloads, escaping archive paths and unsafe links.
A direct-pkg native run confirmed menu visibility, preserved selection and old/new host typing;
the designated new-host check completed outside the 60-second window, so full timed acceptance
remains pending. Receipt-based obsoleting during migration from an older
live-bundle receipt also remains unverified; App rollback does not restore that older receipt.

## Acceptance and recovery

Use [the read-only live probe](../../scripts/check-live-ime-version.sh) with the artifact's target build
and recorded installation times. It checks path/start time, inode, installed/LS/target version equality,
and selected source. Success is labelled `PASS_VERSION_ONLY` until human evidence is recorded.

For each GUI/PKG first install and update, preserve an already-open TextEdit process, open a distinct
TextEdit process after installation, and commit “你好” with the user's actual input scheme in both.
Capture the input menu and note any delayed logout guidance. All required success evidence must be
within 60 seconds, with later unwanted prompts also recorded as failures. Test an update with another
input method selected before installation separately. Never edit HIToolbox files to manufacture state.

Bind hosts with [the local window helper](../../scripts/ime-acceptance-host.swift), using PID, process
launch time, executable, window ID and document URL. A restored copy of the old document in a new
TextEdit process is not old-host evidence. `focus` validates the saved identity before raising the
exact window; `new` starts a fresh TextEdit with per-process state restoration disabled. It never
reopens an old document by path or silently rebinds a missing window. Accessibility and screenshot
permissions must be checked in the executing terminal before any privileged operation.

[The save observer](../../scripts/check-ime-host-evidence.py) requires the bound window focused
with Owltype Hans selected before a new saved “你好”, within the shared 60-second deadline. If focus
has moved after saving, the exact new text count must already have been observed in the focused
Owltype host before saving. Both observations must still resolve the same bound process/window,
and the saved count must match its final window text; blur alone is neither success nor failure. It compares
with the bound window's text baseline, since another process may have saved the same file. This is
supporting evidence, not proof of physical Wubi keystrokes; human confirmation remains required.
Run a no-install rehearsal before another native update when changing this harness. Never count a
rehearsal as installation acceptance. Offline failure replays live in
[host evidence tests](../../scripts/check-ime-host-evidence.selftest.py).

Before native installation, obtain user execution/approval and identify a verified App backup.
On failure preserve the failed App and logs, restore the agreed App only, and recheck process mapping
and typing. App rollback does not undo the package receipt or dictionary changes. Do not remove user
data or log out as a test workaround. Source-built acceptance artifacts, signing constraints, clean
first-install setup, Intel, and macOS 14/15 remain explicit coverage items in the investigation.
