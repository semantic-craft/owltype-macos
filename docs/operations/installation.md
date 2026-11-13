# Installation and activation constraints

Unit tests do not establish host typing; installed-host behaviour needs a live check.
Release composition remains in the [publishing checklist](../PUBLISHING_CHECKLIST.md).

## Acceptance data isolation

Never create test templates, Agent calls or temporary preferences in the daily input method.
The #362 acceptance left `;;owlnative362`, automatic expansion enabled, and a `test 1.0`
call in the user's live library/log. Cleanup after testing is not an isolation mechanism.

- Settings acceptance uses the candidate executable with `--ui-test-show-settings`.
  This does not claim IMK or establish real typing acceptance. XCTest and this mode create
  a private `OwltypeAcceptance-<uuid>/` under the system temporary directory, with data
  (templates, learning data and AgentBridge/calls.json) and logs subdirectories.
  Preferences, including the Agent access switch and service admission, use a separate
  per-process suite. Normal exit removes the owned directory
  and suite. Never copy the user's library or credentials into a test root.
- Existing harnesses may set absolute `OWL_TEST_USER_DIR` / `OWL_TEST_LOG_DIR` paths;
  setting either enables preference and credential isolation too, and the missing path
  gets an isolated default. Paths overlapping production storage (including symlinks) are
  rejected. The harness owns cleanup of explicit fixture directories, including on failure.
  Do not launch an older candidate that lacks these safeguards without explicit isolated
  paths and its verified preference isolation.
- Both personal provider and legacy Keychain access are disabled in isolated hosts.
  Provider tests inject synthetic secret stores; a real-service test needs a separately
  supplied test credential, never a fallback to the daily account.
- Installed Chrome/TextEdit typing and MCP bridge acceptance use a separate macOS test
  account/session with its own data and helper socket. A second same-user process can
  claim the same IMK endpoint, and the default MCP helper connects to that user's daily
  socket: changing only an App data path does not isolate either boundary. Do not run
  test MCP calls against the daily helper. Installation/upgrade checks on the user's
  actual account preserve existing data and do not add synthetic entries.

## Shared file and session phases

Both the GUI installer and package scripts invoke the installed payload's CLI:

| Phase | Owner | Contract |
| --- | --- | --- |
| Capture | GUI / preinstall | Capture existing installation and exact selected source before replacement. Missing update context fails closed. |
| Stage | PackageKit / privileged file helper | PKG payload contains only `/Library/Input Methods/.Owltype.pkg-staging/Owltype.app.zip`. postinstall unpacks into a fresh root-only directory under the installer state directory, verifies and commits, then removes that unpack directory, the consumed archive and the staging directory before session recovery. The live App and all nested bundles are absent from the PackageKit payload. |
| Commit | `--commit-install` as root | Copy into a protected candidate in the work directory, validate signature and bundle identity (`CFBundleIdentifier == im.owltype.inputmethod.Owltype`), preserve the live App shell, exchange `Contents` and `.Contents.update` with `RENAME_SWAP`. Move retired contents outside the App before strict signature verification. First install uses `RENAME_EXCL`. A live App without a readable `Contents/Info.plist` counts as absent: GUI and preinstall classify the run as a first install, and the commit moves that shell to `retained` first. After the installed App validates, remove the retired contents and the candidate wrapper. |
| Activate | `--finish-install` as console user | Reconcile LaunchServices registrations (`lsregister -u` on non-canonical paths, `lsregister -f` on `/Library/Input Methods/Owltype.app`), purge `com.apple.IntlDataCache.le*` caches referencing Owltype, end old installed server instances, register/enable parent and primary mode on first install (or repair install), refresh `TextInputMenuAgent`/`TextInputSwitcher`/`CursorUIViewService`, launch the installed App, and report `INSTALL_SESSION_OK` (`status=ready` when verified immediately, or `status=deferred` when macOS awaits user input-source enablement or selection). |
| Verify | Fresh user-session probe | Wait up to a bounded window for the parent and mode to be enabled and the canonical server at `/Library/Input Methods/Owltype.app/Contents/MacOS/Owltype` to come up; the probe uses `proc_pidpath` and `stat` inode verification with `lsof` fallback, never `lsappinfo` text. Deferred TIS selection after `SecurityAgent` SecureInput does not fail an already-committed installation or arm a false-negative logout prompt. |

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

### Where intermediates live

LaunchServices and the input menu register bundles found under `/Library/Input Methods`, hidden
`.Owltype.*` directories included, so each leftover copy can become a second「猫头鹰输入法」entry.
Up to 2.0.15 the installer kept its lock, candidates, retired contents, unpack directories and
abandoned payloads there. Now only the live App and the PackageKit staging archive touch it:

| Path under `/private/var/db/im.owltype.inputmethod.Owltype-installer/` | Contents | Lifetime |
| --- | --- | --- |
| `work/install-lock` | commit lock | removed when `--commit-install` exits |
| `work/prepared-<uuid>/Owltype.app` | candidate copy | removed after a validated commit; retained on failure |
| `work/retired-<uuid>` | old `Contents` after the swap | removed after a validated commit; retained on failure |
| `unpack.<random>/Owltype.app` | postinstall's extracted archive | removed after the commit; retained on failure |
| `retained/<name>` | a previous staging tree with anything but the archive, and `.Owltype.*` directories an older installer left in Input Methods | kept for inspection |
| `retained/incomplete-Owltype-<uuid>` | a live `Owltype.app` without `Contents/Info.plist`, moved aside by `--commit-install`, which then installs fresh | kept for inspection |

Removing the retired contents early does not change what a still-running old server sees: it
resolves bundle paths through `Owltype.app/Contents`, which already holds the new files after the
swap, and files it has open or mapped keep their inodes. Nothing restores from `retired-*`;
rollback uses a separately verified App backup.

The state directory is on the same volume as Input Methods (the Data volume); `--commit-install`
checks `st_dev` and fails with `EXDEV` before touching the live App if it is not, so the
`RENAME_SWAP`/`RENAME_EXCL` steps never cross volumes. preinstall unregisters each entry it moves
into `retained` (and any App inside it) from both root's and the console user's LaunchServices
database, then renames it; it never deletes one. A staging tree holding only the consumed archive
is discarded. preinstall leaves legacy directories alone while an older installer's
`.Owltype.install-lock` exists and a `--commit-install` process is running; a lock without that
process is stale and is retained with the rest. The GUI installer does not run preinstall, so legacy leftovers on a
GUI-only Mac still need the repair script. Offline regression:
[pkg-leftovers.selftest.sh](../../scripts/pkg-leftovers.selftest.sh) and
[OwlInstallFilesTests](../../tests/OwlInstallFilesTests.swift).

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

A failed self-check records its stage, the error and the conditions the last probe missed (#207).
The CLI prints `INSTALL_SESSION_DIAGNOSIS:` after `INSTALL_SESSION_FAILED:`, so the GUI dialog and
`/var/log/install.log` (the PKG path, including updates started from 检查更新) carry the reason. The
App keeps the same record beside the failed version. At the input-safe time it runs the installer's
probe again and compares the server conditions only, not the selection, which the user may have
changed since; when every condition holds it marks the record recovered and shows nothing. Otherwise
the alert states what failed then and what the re-probe saw, and the support bundle (设置 → 诊断支持包)
carries the record under 「安装自检」 until a later self-check passes. Offline regression:
[OwlSessionRestartTests](../../tests/OwlSessionRestartTests.swift) and
[OwlUpdateLogoutPromptTests](../../tests/OwlUpdateLogoutPromptTests.swift). A tester's 2.0.20 alert
(2026-10-22) carried a real failure's diagnosis and showed two probe faults: the re-probe could not
see the App that runs it (`pgrep` hides its ancestors without `-a`), and the server's path and
version parsed from `lsappinfo` were empty. Both are fixed; a passing re-probe on a tester's Mac is
not yet verified.

The user approved retaining official Sparkle on 2026-10-11 (#204): Sparkle owns downloading,
EdDSA verification and invoking the system package installer; the package owns atomic file commit
and user-session recovery. The earlier download-only requirement is superseded. Sparkle 2.6.2 has
no public verified-download-path handoff. Returning false from its relaunch delegate can abort
installation, so it is not a way to suppress only a duplicate launch. The progress agent now has a tracked source patch: application bundles use
openApplicationAtURL and wait for completion before cleanup. The legacy openURL route requested
a read-write sandbox extension and triggered App Management in the isolated test. See
[the dependency patch](../../patches/sparkle/README.md). Download, verification and pkg installation
remain official Sparkle code; the dependency is a patched build, not the unmodified upstream binary.
An update started by an older installed App still uses its old helper; the repair takes effect when
the updated helper starts the next update. Full Sparkle installation with the rebuilt helper passed on the tested arm64 host with Owltype initially selected; remaining cases are tracked in #204/#205.
Native logs disproved the previous empty-component-list
assumption: PackageKit still registered the staged App after postinstall and the process/TIS self-check.
The revised format gives PackageKit only an inert archive. Release, identity and secret gates unpack and
inspect its real contents; they reject direct App payloads, escaping archive paths and unsafe links.
A bound-host direct-pkg run confirmed menu visibility and preserved WeType selection. The original
TextEdit process saved Wubi input at 24.83 seconds and the new process at 17.85 seconds; the user
confirmed no logout prompt, including a later follow-up. This covers the local ad-hoc test App on
arm64 macOS 27.0.1, not Sparkle, GUI, first installation or an initially selected Owltype source. Receipt-based obsoleting during migration from an older
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
first-install setup and macOS 14/15 remain explicit coverage items in the investigation.
Starting with 2.5.1, Intel Macs are unsupported; both PKGs restrict installation to Apple Silicon.

## Uninstall and repair on a user's Mac

`OwltypeInstaller.app` provides a unified two-step wizard with four built-in actions (`安装 / 更新 / 重新安装`, `修复安装`, `清空修复`, and `彻底卸载` with an option to keep or remove user dictionary data). In addition, the DMG ships two double-click entries next to the installer that share
[owltype-maintenance-lib.sh](../../scripts/owltype-maintenance-lib.sh) and only act on
Owltype's bundle id and paths.

- `修复猫头鹰.command` runs [repair-owltype.sh](../../scripts/repair-owltype.sh). Use it when
  the input menu shows two「猫头鹰输入法」entries or an old icon: macOS lists every bundle that
  claims the id, so an older copy in `~/Library/Input Methods`, a leftover `.Owltype.*`
  directory from an interrupted install, or a stale LaunchServices record each add an entry.
  It removes those copies, unregisters every other claim, re-registers the installed App
  (`--activate-once`), deletes only the `com.apple.IntlDataCache.le*` caches that mention
  the id, and restarts the input menu agents. User data stays. If two entries remain, a
  logout rebuilds the list.
- `卸载猫头鹰.command` runs [uninstall-owltype.sh](../../scripts/uninstall-owltype.sh), which
  does the same cleanup and also removes the installed App, preferences, caches, the receipt
  and (unless `--keep-data`) the data root and preferences, so a reinstall starts clean.
  Without a runnable installed App it parks the input source through a surviving older copy.

Neither edits HIToolbox preferences; uninstall disables the input source through the App's
own `--disable-input-source` before deleting it. Both refuse to run during any install phase: OwltypeInstaller, Installer, `installer`,
Sparkle's Autoupdate, this package's pre/postinstall, the commit/finish CLI phases, or a
held `.Owltype.install-lock`. Offline
regression: [uninstall-repair.selftest.sh](../../scripts/uninstall-repair.selftest.sh).

## Development installs

[install-dev.sh](../../scripts/install-dev.sh) is the only development install path. It signs
the build with a stable certificate identity from
[stable-sign-identity.sh](../../scripts/stable-sign-identity.sh) (Developer ID Application,
whose designated requirement matches the shipped App, else Apple Development;
`OWL_SIGN_IDENTITY` overrides) and refuses a candidate whose requirement is an ad hoc
`cdhash` or whose identity differs from the installed copy. Ad hoc installs make Keychain ask
for the login password after every rebuild and leave LaunchServices claims that shadow the
notarized input method. The former `make install*` targets now refuse. Offline regression:
[install-dev.selftest.sh](../../scripts/install-dev.selftest.sh).
