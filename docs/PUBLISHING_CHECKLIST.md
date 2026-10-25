# Binary and corresponding-source publishing checklist

Every distributed change must pass the applicable gates below before merge. A private development
repository limits future disclosure; it does not retract copies of previously distributed source
archives or reduce recipients' GPL rights.

## Never import

Do not copy the old product repository's Git history. Export reviewed files from the private mother
repository through an allowlist, then create a new root commit.

The corresponding-source archive and all public artifacts must exclude secrets and private data,
but must not omit source merely because the implementation is sensitive. If code is compiled,
linked, or required to generate, install, or run the distributed binary, it belongs in the complete
corresponding source. A feature whose source cannot be given to recipients cannot ship in that
binary. Exclude only:

- credentials, Keychain contents, EdDSA private keys, signing/notarization identities and release
  credentials (source code that uses Keychain or implements packaging remains corresponding source);
- private audit reports, absolute home-directory paths, private email addresses and local caches;
- Wubi dictionary data without a pinned source, preserved Apache-2.0 license, and verified derived
  SQLite digest; the reviewed `rime-wubi86-jidian` pin used by the public seed meets those conditions;
- octagram model data and plugin binaries until corresponding-source and license obligations are
  satisfied for the exact release.

The local-only prompt, phrase and scene-term features are allowed only while they keep user content
on-device, store it with restrictive permissions and never log its text.

## Installation mechanisms

For GUI versus PKG activation, state restoration, current tests and historical evidence
boundaries, read [installation constraints](operations/installation.md).

## Authoritative release flow

Start from a clean worktree at the exact commit to publish. Review the staged diff, confirm the Git
author uses a public noreply identity, and verify that no dependency or data source is on a floating
branch. Then use the only release entrypoint:

```sh
DEV_ID='Developer ID common name' \
NOTARY_PROFILE='notarytool keychain profile' \
bash scripts/release.sh --output-root build/release-<version>-<short-sha>
```

Both the input method and the DMG installer explicitly build `arm64` and `x86_64`.
Their build steps verify both slices before signing; the host Mac’s active architecture
must not narrow the published artifacts.

The one-time 2.0.1 trust bridge must additionally set
`SPARKLE_ED25519_ACCOUNT=ed25519`. Releases after 2.0.1 omit that override (or explicitly use
`owltype-ed25519`); the predecessor account must never become a permanent default.

To inspect the same order without invoking builds, Apple tools, scanners, or remote services:

```sh
bash scripts/release.sh --dry-run --output-root build/release-cohort
```

The entrypoint runs tests, creates one Release build, and drives the App, `Owltype.pkg`,
`Owltype-update.pkg`, and the versioned DMG through the shared
`built -> signed -> notarized -> stapled` cohort transitions. It inventories the final App, creates
an appcast and corresponding-source archive that both embed that cohort ID, and then runs the
release, privacy, shared secret-policy, and local publishing-contract gates. Any revision, version,
inventory, artifact, appcast, source, or cohort mismatch stops the chain. A `complete` cohort means
only that all four binary artifacts reached `stapled`; it is not permission to publish. The
entrypoint creates a local, cohort-and-asset-bound publish-authorization receipt only after all
eight release, privacy, secret, and publishing-contract stages pass. Re-running the entrypoint
reruns the tests, then verifies and reuses a complete valid Release cohort without another Release
build; a partial, failed, or mismatched cohort must be removed explicitly and rebuilt under a fresh
output root.

The cohort binds the marketing version (`CFBundleShortVersionString`) and Sparkle build version
(`CFBundleVersion`) separately. The versioned DMG and source archive use the marketing version;
Sparkle comparison and the immutable update-package URL use the build version.

The cohort also binds an exact file-and-mode snapshot of the selected Git revision and every pinned
submodule revision, plus a stable digest of the complete generated seed shipped in
`Owltype.app/Contents/SharedSupport`. The corresponding-source archive must contain exactly that
tracked source, its declared manifest and provenance, and a `data/owl-rime` tree identical to the
App seed. Self-consistent replacement archives are rejected even when their internal manifest and
checksum sidecar have been recomputed.

The App cohort identity includes normalized entry type and permission mode as well as file contents
and symlink targets. `Contents/MacOS/Owltype` must remain a regular executable file. The appcast must
declare `sparkle:installationType="package"`, and its EdDSA signature over the exact cohort-bound
update package must verify with `SUPublicEDKey` from that cohort's App.

The final local publishing gate lists ten cohort-verified assets as `WOULD_PUBLISH`. The release
script does not upload assets or deploy the feed. After every local gate passes, inspect the exact
remote order without changing state:

```sh
python3 scripts/owl_distribution.py --dry-run --output-root build/release-<version>-<short-sha>
```

Publication is a separate, explicit maintainer decision:

```sh
gh auth status   # needs push access to semantic-craft/downloads
python3 scripts/owl_distribution.py --publish --output-root build/release-<version>-<short-sha>
```

Both publisher modes require the local publish-authorization receipt before constructing a remote
plan. `downloads.responsay.com` is a Cloudflare Pages site deployed from the public
`semantic-craft/downloads` repository; nothing is stored in R2. The publisher uploads the PKGs, DMG
and source archive as GitHub Release assets (tag `owltype-<build version>`), maps their
`owltype/releases/<build version>/` URLs to those assets in `site/_redirects`, and stages the other
assets, `owltype/latest.json` and `owltype/v3/appcast.xml` (2.0.10 and later) as files under `site/`.
One push then makes the pointer and the feed public together, after every asset; the publisher
waits for the Pages deployment and verifies every public hash and all four website aliases. The v2 feed is frozen at 2.0.9 after loss of its signing key; users must manually install 2.0.10 once to adopt the new key and v3 feed. For the historical one-time 2.0.1 bridge only, it writes the predecessor Owltype feed
`owltype/appcast.xml` last; 2.0.2 and later never touch that frozen bridge feed. A versioned object
that already exists with different bytes stops publication; an identical object is reused.

The shared artifact secret policy scans the App and all ten listed assets. It safely expands PKGs,
mounts DMGs read-only and detaches them on both success and failure, and extracts tar archives while
rejecting links, special members, duplicate paths, and traversal before scanning their contents.

The App inventory is taken **after** Developer ID signing and stapling, because both rewrite the
bundle. `OWLTYPE-FILE-MANIFEST.sha256`, `OWLTYPE-SBOM.spdx.json`, App provenance, and the cohort
record live outside the App and ship with the packages, DMG, appcast, source archive, and source
checksum. A downloader can verify the App with
`cd Owltype.app && shasum -a 256 -c /path/to/OWLTYPE-FILE-MANIFEST.sha256`.

Public source and public binaries remain separate legal decisions. A complete cohort without a valid
publish-authorization receipt must never be published, and no receipt may be issued while any
provenance, corresponding-source, license, secret, or human-review gate is open.
Local tests use fake adapters, unsigned system packaging tools, and synthetic Sparkle keys only;
they do not replace a maintainer's final Developer ID signing, notarization, stapling, and installed
update validation on the exact release artifacts.
After an installed update, run `python3 scripts/check-installed-process.py` before real typing.
This checks the live executable inode, not just the version on disk: macOS may restart the old
input method while the installer waits for authorization. The installer stops that process again
after replacement and waits for exit before activating the installed copy. The read-only check's
captured stale-process regression can be replayed with `--self-test`.
The product test entrypoint explicitly excludes the five credential-gated Live suites; the offline
`OwlLiveInputTraceTests` privacy regression remains enabled. `scripts/gate.sh` and the release
entrypoint must never rely on default skip behavior or run an unfiltered `xcodebuild test`.

## Interrupted publication and release closeout

The publisher updates immutable assets first, then the website pointer and finally
the client feed. These remote writes are sequential, not one atomic transaction.
A failure after the website pointer changes can leave website downloads newer than
the Sparkle feed; record which write/readback failed before choosing recovery.

| Failure point | Recovery within the authorized release |
| --- | --- |
| Local tests/signing/cohort validation | No upload has occurred through the release entrypoint. Fix the cause; reuse only a verified complete cohort. Retain failed evidence and use a fresh output root for a partial or mismatched cohort. |
| Immutable asset upload/readback | Retry the publisher with the same verified output root and valid authorization receipt. Identical remote objects are reused; differing bytes at a versioned key are a hard stop, not permission to overwrite. |
| Website aliases or final feed verification | Preserve the same cohort and retry after the transport/cache cause is resolved. The publisher rechecks immutable assets, rewrites the mutable pointers and verifies public responses. Do not rebuild a different binary under the same published build version. |
| A published product regression | Stop further distribution changes and select a recovery scope. Prefer a corrected, higher build version through the complete release chain; pointing the feed at an older version does not make installed Sparkle clients downgrade. |

Before publishing, retain the prior and intended `latest.json` and active appcast
bytes, their hashes, and both cohort identities in the local release record. Restoring
mutable pointers is a separate, explicitly authorized operation: verify the prior
assets still exist, restore the reviewed bytes, then recheck website aliases and feed.
There is no automatic remote rollback command. Never modify the frozen v2 or bridge
feeds for ordinary recovery. Installed-machine recovery follows the
[installation acceptance procedure](operations/installation.md#installed-acceptance-and-recovery-record).

Close the release in the existing PR/issue or acceptance record with source commit,
tag if created, marketing/build versions, cohort ID, public artifact verification,
installed-path results and remaining gaps. Distinguish built, published, installed
and user-accepted states. Keep required logs and native evidence outside temporary
and build directories using the [evidence location](operations/ci.md#focused-feedback-and-retained-evidence);
review/redact any excerpt before posting it. Historical temporary paths are evidence
locators only, not a guarantee those files still exist.
