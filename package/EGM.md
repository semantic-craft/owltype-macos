# Distribution package composition

## Overview

Shell entry points compose installer/update packages, the standalone-installer DMG, and Sparkle appcasts from a selected release output root. Release-cohort state and bundle inventory remain owned by the repository's `scripts/` helpers.

## Interface

- `[common.sh:get_app_version]` returns the build version; `get_marketing_version` reads the marketing version from the main Xcode project.
- `[make_package:RELEASE_OUTPUT_ROOT]` takes an absolute output root and emits `Owltype.pkg` and `Owltype-update.pkg` from one component package. `Distribution` and `Distribution-update` contain the cohort identity and package reference.
- `[make_dmg:RELEASE_OUTPUT_ROOT]` takes an absolute output root, builds `OwltypeInstaller`, embeds the selected Owltype app, and composes `Owltype-<marketing version>.dmg` with repair/removal entry points.
- `[sign_app:DEV_ID]` forwards the identity, output root, and notary profile to the cohort `seal` action for `app`.
- `[apple_tool_adapter:action]` implements `cohort-id`, `sign`, `notarize`, and `staple` for supported artifact kinds; retryable errors use exit 75 and rejected notarization uses exit 65.
- `[make_archive:write_appcast]` generates production, testing, and local debug appcasts, using the update package's EdDSA signature, size, SHA-256, and cohort identity.
- `[修复猫头鹰.command:CANDIDATES]` and `[卸载猫头鹰.command:CANDIDATES]` locate and invoke the corresponding bundled or repository maintenance script, then preserve its exit status.

## Invariants

- `[make_package:COHORT_STATE]` and `[make_dmg:COHORT_STATE]` require eligible cohort states and successful inventory checking before packaging. Signed builds require stapled inputs; the unsigned path permits built/stapled inputs.
- `[make_package:PAYLOAD_PARENT]` gives PackageKit an inert `Owltype.app.zip` under `.Owltype.pkg-staging`; the copied pre/postinstall scripts own subsequent installation work.
- `[make_dmg:EMBED_DIR]` places Owltype under installer `Contents/Library`; outer installer signing omits `--deep` to preserve the embedded app's existing signature. Both supported architectures are checked with `lipo`.
- `[make_archive:sparkle_mode]` requires cohort mode `bridge` or `successor`, an eligible appcast-ready cohort, and a real update package. Bridge signing requires explicit `ed25519`; successor signing requires `owltype-ed25519`. An explicitly supplied private-key file must be readable and does not fall back to Keychain.
- `[make_archive:app_version]` keeps Sparkle comparison/build version separate from the displayed marketing version. `[apple_tool_adapter:cohort-id]` verifies the embedded package/DMG cohort identity against the expected value.

## Side Effects

- `[make_package:pkgbuild]`/`productbuild`, `[make_dmg:xcodebuild]`/`hdiutil`, and `[make_archive:write_appcast]` create packages, build/stage an installer, create a DMG, and write appcasts; cohort registration updates release state via `scripts/release-cohort-state.py`.
- `[apple_tool_adapter:sign]`, `notarize`, and `staple` invoke signing tools, submit artifacts to Apple, and staple/validate tickets. `[make_archive:sign_update]` accesses the explicitly selected signing-key source.
- `[apple_tool_adapter:cohort-id]` expands packages or mounts DMGs read-only into temporary locations, then cleans up. The repair/removal `.command` wrappers invoke scripts that can change the installed system.

## Verification

From the repository root: `make release-cohort-selftest` exercises the release state/composition regression suite. `make release-cohort-check RELEASE_OUTPUT_ROOT=<existing-output-root>` checks a selected cohort without rebuilding it. Packaging, signing, notarization, and installation entry points are operational commands, not documentation validation; none were executed for this contract.
