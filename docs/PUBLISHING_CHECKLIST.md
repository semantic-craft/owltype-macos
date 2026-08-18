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
- Wubi dictionary data until its complete relicensing chain is publicly verifiable;
- octagram model data and plugin binaries until corresponding-source and license obligations are
  satisfied for the exact release.

The local-only prompt, phrase and scene-term features are allowed only while they keep user content
on-device, store it with restrictive permissions and never log its text.

## Authoritative release flow

Start from a clean worktree at the exact commit to publish. Review the staged diff, confirm the Git
author uses a public noreply identity, and verify that no dependency or data source is on a floating
branch. Then use the only release entrypoint:

```sh
DEV_ID='Developer ID common name' \
NOTARY_PROFILE='notarytool keychain profile' \
bash scripts/release.sh --output-root build/release-cohort
```

To inspect the same order without invoking builds, Apple tools, scanners, or remote services:

```sh
bash scripts/release.sh --dry-run --output-root build/release-cohort
```

The entrypoint runs tests, creates one Release build, and drives the App, `Famo.pkg`,
`Famo-update.pkg`, and the versioned DMG through the shared
`built -> signed -> notarized -> stapled` cohort transitions. It inventories the final App, creates
an appcast and corresponding-source archive that both embed that cohort ID, and then runs the
release, privacy, shared secret-policy, and local publishing-contract gates. Any revision, version,
inventory, artifact, appcast, source, or cohort mismatch stops the chain. Re-running the entrypoint
reruns the tests, then verifies and reuses a complete valid Release cohort without another Release
build; a partial, failed, or mismatched cohort must be removed explicitly and rebuilt under a fresh
output root.

The cohort binds the marketing version (`CFBundleShortVersionString`) and Sparkle build version
(`CFBundleVersion`) separately. The versioned DMG and source archive use the marketing version;
Sparkle comparison and the immutable update-package URL use the build version.

The cohort also binds an exact file-and-mode snapshot of the selected Git revision and every pinned
submodule revision, plus a stable digest of the complete generated seed shipped in
`Famo.app/Contents/SharedSupport`. The corresponding-source archive must contain exactly that
tracked source, its declared manifest and provenance, and a `data/famo-rime` tree identical to the
App seed. Self-consistent replacement archives are rejected even when their internal manifest and
checksum sidecar have been recomputed.

The App cohort identity includes normalized entry type and permission mode as well as file contents
and symlink targets. `Contents/MacOS/Famo` must remain a regular executable file. The appcast must
declare `sparkle:installationType="package"`, and its EdDSA signature over the exact cohort-bound
update package must verify with `SUPublicEDKey` from that cohort's App.

The final local publishing gate lists ten cohort-verified assets as `WOULD_PUBLISH`. The release
script does not upload assets or deploy the feed. After every local gate passes, inspect the exact
remote order without changing state:

```sh
python3 scripts/famo_distribution.py --dry-run --output-root build/release-cohort
```

Publication is a separate, explicit maintainer decision:

```sh
npm install --global wrangler@4.123.0
python3 scripts/famo_distribution.py --publish --output-root build/release-cohort
```

The publisher requires exactly Wrangler 4.123.0. It stores all ten assets under the immutable
build-version prefix in the `responsay-downloads` R2 bucket, reads them back, and verifies their
public hashes. It then replaces one cohort JSON pointer that atomically switches every manual
binary/source download, verifies those website routes, and replaces `famo/appcast.xml` last. A
versioned object that already exists with different bytes stops publication; an identical object is
reused.

The shared artifact secret policy scans the App and all ten listed assets. It safely expands PKGs,
mounts DMGs read-only and detaches them on both success and failure, and extracts tar archives while
rejecting links, special members, duplicate paths, and traversal before scanning their contents.

The App inventory is taken **after** Developer ID signing and stapling, because both rewrite the
bundle. `FAMOTYPE-FILE-MANIFEST.sha256`, `FAMOTYPE-SBOM.spdx.json`, App provenance, and the cohort
record live outside the App and ship with the packages, DMG, appcast, source archive, and source
checksum. A downloader can verify the App with
`cd Famo.app && shasum -a 256 -c /path/to/FAMOTYPE-FILE-MANIFEST.sha256`.

Public source and public binaries remain separate legal decisions. A complete cohort does not permit
a binary release while any provenance, corresponding-source, license, or human-review gate is open.
Local tests use fake adapters, unsigned system packaging tools, and synthetic Sparkle keys only;
they do not replace a maintainer's final Developer ID signing, notarization, stapling, and installed
update validation on the exact release artifacts.
The product test entrypoint explicitly excludes the five credential-gated Live suites; the offline
`FamoLiveInputTraceTests` privacy regression remains enabled. Release and source CI must never rely
on default skip behavior or run an unfiltered `xcodebuild test`.
