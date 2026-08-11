# Public publishing checklist

Every public change must pass the applicable gates below before merge. A clean repository limits
future disclosure; it does not retract copies of previously published source archives.

## Never import

Do not copy the old product repository's Git history. Export reviewed files from the private mother
repository through an allowlist, then create a new root commit.

The public repository and all public artifacts must exclude:

- cloud AI, provider clients, search clients, credentials and Keychain integration;
- Accessibility selection readers, host-app inspection and surrounding-text capture;
- clipboard readers or history, global event taps and background keystroke listeners;
- appcast generation/deployment, EdDSA private keys, signing/notarization material, package builders
  and release credentials (the pinned Sparkle client and its public verification key are allowed);
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

The final local publishing gate lists ten cohort-verified assets as `WOULD_PUBLISH`. The script does
not create a GitHub Release, upload assets, change tags, deploy the feed, or validate a remote URL.
Those remote actions remain a separate maintainer decision after every local gate passes.
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
