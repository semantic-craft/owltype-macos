# Installation and activation constraints

This is a navigation and behaviour reference for the current implementation, not a
claim that every macOS version or clean-install scenario has been tested.
Release composition remains in the [publishing checklist](../PUBLISHING_CHECKLIST.md).

## Two installation paths

| Path | Implementation | Current behaviour and boundary |
| --- | --- | --- |
| DMG GUI installer | [Installer](../../installer/Sources/Installer.swift), [policy](../../installer/Sources/InstallerActivationPolicy.swift), [verifier](../../installer/Sources/InstallerActivationVerifier.swift), [TIS probe](../../installer/Sources/InstallerTISProbe.swift) | Samples existing bundle, running process and selected source before replacement. Chooses an enabled, selectable system ASCII keyboard when parking is needed, selects through a fresh CLI process and verifies readback before proceeding. |
| PKG / Sparkle | [preinstall](../../scripts/preinstall), [postinstall](../../scripts/postinstall), [first-install distribution](../../package/Distribution), [update distribution](../../package/Distribution-update) | Saves pre-replacement state across package phases. First-install PKG declares logout; update PKG does not. The parking step still attempts ABC best-effort; it does not use the GUI installer's available-keyboard selection and readback. |

Do not apply the GUI installer's US-only regression result to the PKG path. Changing
that path is separate implementation work, not a documentation correction.

## Constraints implemented today

- Existing-install detection uses the pre-existing bundle or running process, captured
  before termination/replacement. Updates skip the first-install enable sequence.
  The GUI policy's first-install plan enables the parent and primary mode once each.
- An update restores Owltype only when it interrupted the user's selection of Owltype.
  It does not select Owltype over another source chosen before the update.
- The GUI verifier reads a fresh-process probe: parent enabled and primary-mode
  membership in the enabled-only list. Primary-mode `IsEnabled` alone is not the
  verification signal. Selection capability is diagnostic, not sufficient for success.
- Verification accepts late consent after its soft deadline; the extended deadline
  ends retries and leaves logout guidance. A process signal is not proof of host typing.
- The PKG path delays menu refresh and selection restoration until the receipt boundary;
  see the deferred task in postinstall for its budget and no-steal conditions.
- The shared CLI's [exact-ID selection](../../sources/Activation/InputSource.swift)
  prints missing-source or selection failure without a failure exit status. Callers
  needing a guarantee must read back the selected source, as the GUI installer does.
- [App startup](../../sources/Main.swift) rejects non-installed bundles before IMK
  registration. Unit tests and the isolated settings-preview mode take separate paths.

## Evidence and limits

[Installer policy tests](../../tests/InstallerActivationPolicyTests.swift) cover the
activation truth table, US-only parking selection, probe parsing, late consent and
logout states. [Activation tests](../../tests/ActivationPolicyTests.swift) cover the
installed-bundle boundary. [Release self-tests](../../scripts/check-release.selftest.sh)
check package-state handling. These do not replace native TIS/IMK acceptance.

The [input-habits acceptance record](../input-habits-design.md) records the GUI installer
ASCII-keyboard repair and actual host results. Older comments about repeated-enable
“ghost” states, default-on mode flags and stale process snapshots came from historical
macOS observations. Their original numbered diagnostic notebook is no longer present;
treat them as rationale for retained safeguards, not independently reproduced platform
laws. The current implementation and the tests above define the maintained contract.

After an authorized installed update, follow the publishing checklist's live-process
check and test composition/commit in a newly opened host. A successful TIS probe alone
does not establish that an already-open host has reconnected.
