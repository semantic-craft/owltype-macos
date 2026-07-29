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

## Required gates

- `bash scripts/check-public-source.sh` passes on the exact commit to be published;
- Gitleaks and TruffleHog report no verified or unreviewed secrets on the exact Git history;
- the full test suite and a clean unsigned Release build pass;
- the final App bundle is inventoried, including every executable, dynamic library and data set. The
  inventory is taken **after** Developer ID signing and `xcrun stapler staple`, because both rewrite
  the bundle, and it is written outside the bundle so that taking it cannot alter what it describes.
  `FAMOTYPE-FILE-MANIFEST.sha256` and `FAMOTYPE-SBOM.spdx.json` land under `<derived-data>/release/`
  and are published alongside the App, so anyone can verify a download with
  `cd Famo.app && shasum -a 256 -c /path/to/FAMOTYPE-FILE-MANIFEST.sha256`;
- `THIRD_PARTY_NOTICES.md`, complete license texts, Credits, pinned source revisions and corresponding
  source are shipped for that exact inventory;
- no dependency or data source remains on a floating branch for a public binary release;
- a maintainer manually reviews the staged diff and confirms that the Git author uses a public
  noreply identity.

Run `make famo-seed` and then `make release-gate DERIVED_DATA_PATH=build/release-gate` on a clean
worktree. The gate emits the corresponding source archive, its SHA-256 file, and the App inventory
under `build/release-gate/release/`; publish those files with the exact App built by the same
invocation. The archive's `FAMOTYPE-SOURCE-PROVENANCE.txt` records the App manifest's own SHA-256 as
`app-manifest`, which is what ties the published source to the published binary — so the inventory
must already exist when the archive is built, and `make source-archive` deliberately does not rebuild
the App (rebuilding would strip the signatures off the bundle that actually shipped).

Public source and public binaries are separate decisions. Passing the source gates does not permit a
binary release while any provenance or corresponding-source gate remains open.
