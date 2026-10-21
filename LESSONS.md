# Lessons from verified work

Each entry keeps the rule, reason, regression, and dates observed. Count distinct
review dates, not retries. Keep deterministic checks in the local gate.

## An existing App directory is not an existing install

**Classify first install versus update by `Contents/Info.plist`, not by the App directory.**

- Reason: a user's Mac had `/Library/Input Methods/Owltype.app` without `Contents/Info.plist`
  (an incomplete earlier removal). The GUI installer treated it as an update, and
  `--commit-install` failed reading the old Info.plist (`NSCocoaErrorDomain` 260,
  `INSTALL_FILES_FAILED`). preinstall would have failed too, running the missing executable.
- Prevention: the commit moves such a shell to the installer's `retained/` and publishes a
  first install; GUI and preinstall use the same Info.plist test, so session activation
  registers and enables the source instead of waiting for an update that has none.
- Regression: `testIncompleteLiveAppIsRetainedOutsideInputMethodsAndInstalledFresh` in
  [OwlInstallFilesTests](tests/OwlInstallFilesTests.swift). The GUI and preinstall
  classification has no offline test; a native install over an empty shell remains unverified.
- Seen on 1 distinct date: 2026-10-21.

## Compare canonical paths with realpath, and test under /private

**Symlink checks must use realpath(3) on the raw path; file-system tests must run under the real `/private/...` path.**

- Reason: 2.0.16 moved install intermediates to `/private/var/db/...`. The candidate check
  compared `resolvingSymlinksInPath()` with the path, and Foundation drops a leading `/private`
  (so does `standardizedFileURL`), so the first real PKG install failed with `ELOOP` in
  `--commit-install`. The tests passed because their temp root was `/var/folders/...`, itself a
  symlinked path that Foundation round-trips unchanged. The live App stayed on 2.0.15; nothing
  was published.
- Prevention: `OwlBundleSwap.isCanonical` uses `realpath` against `url.path`; both bundle tests
  build their root with `realpath`, so it starts with `/private`.
- Regression: [OwlInstallFilesTests](tests/OwlInstallFilesTests.swift) and
  [OwlBundleSwapTests](tests/OwlBundleSwapTests.swift); the old check fails 4 of 8
  OwlInstallFilesTests. They run in [the merge gate](scripts/gate.sh). Offline tests still do not
  replace a real signed PKG install before publishing.
- Seen on 1 distinct date: 2026-10-20.

## Pin every gzip parameter a fixture depends on

**Fixtures that feed the canonical-archive gate must pass `compresslevel=9`, not rely on Python's default.**

- Reason: Python 3.15 lowered `gzip.GzipFile`'s default level from 9 to 6, which writes
  XFL `0x00` instead of `0x02`. The release-source and release-chain fixtures omitted the
  level, so the gzip header gate rejected them before the ownership and member-type checks
  they meant to exercise, and the full gate failed on main. The production writer already
  pinned the level and was unaffected.
- Prevention: pin `compresslevel=9` and `mtime=0` in every fixture that builds a
  `.tar.gz` for `check-archive-metadata`.
- Regression: [release-source-archive.selftest.py](scripts/release-source-archive.selftest.py)
  now recompresses a valid archive at level 6 and requires the gzip-metadata rejection.
  It runs in [the merge gate](scripts/gate.sh).
- Seen on 1 distinct date: 2026-10-19.

## Never install an ad hoc build as the input method

**Installed copies must carry a stable certificate requirement, not a per-build cdhash.**

- Reason: `install-dev.sh` re-signed the installed App ad hoc and `make install*` copied
  ad hoc or unsigned builds over the notarized copy. Keychain grants follow the designated
  requirement, so each rebuild would re-prompt for the login password; leftover ad hoc
  claims of the same bundle id made macOS resolve the input method to a dead build at login
  ([conclusion A](docs/default-input-method-plan.md)). Sonori hit the Keychain prompt on
  three dates (2026-10-13, 10-16, 10-19).
- Prevention: [stable-sign-identity.sh](scripts/stable-sign-identity.sh) picks the identity;
  `install-dev.sh` rejects `# designated => cdhash` and identity changes before copying; the
  `make install*` targets refuse. Real upgrade with silent Keychain reads still needs a
  human-run install, which the self-test does not cover.
- Regression: [install-dev.selftest.sh](scripts/install-dev.selftest.sh) runs the real script
  with a fake bundle and mocked `codesign`/`security`; it failed 8/8 cases on the old script.
  It runs in [the merge gate](scripts/gate.sh).
- Seen in this project on 1 distinct date: 2026-10-19 (found by audit; same class as Sonori).

## Every bundle that claims the id is a menu entry

**Uninstall and repair must clear all Owltype claims, not just the installed App.**

- Reason: a user's input menu showed two「猫头鹰输入法」entries, one with the 2.0.15 profile
  owl and one with the ≤2.0.14 badge icon. The old uninstaller deleted only
  `/Library/Input Methods/Owltype.app`, so older copies, installer `.Owltype.*` leftovers
  (LaunchServices registers them; 33 were on the development Mac) and stale records survived
  a reinstall. Which copy the user's Mac held is unconfirmed.
- Prevention: [repair-owltype.sh](scripts/repair-owltype.sh) and
  [uninstall-owltype.sh](scripts/uninstall-owltype.sh) share
  [owltype-maintenance-lib.sh](scripts/owltype-maintenance-lib.sh): remove stray copies,
  unregister every other claim, purge the list caches that mention the id, restart the menu agents.
- Regression: [uninstall-repair.selftest.sh](scripts/uninstall-repair.selftest.sh) runs both
  scripts against a fake system root with mocked privileged tools. It runs in
  [the merge gate](scripts/gate.sh). Not yet run on the affected Mac.
- Seen on 1 distinct date: 2026-10-20.

## A librime session id is not a session identity

**Prove a session was recreated by its wrapper, never by comparing `RimeSessionId`s.**

- Reason: librime returns the `Session`'s heap address as its id
  ([service.cc](librime/src/rime/service.cc)), so destroy-then-create often gets the
  freed address back. `testControllerRoundTrip` asserted a new id after applying
  settings and failed once in `gate.sh --quick`
  (`20261020T080929Z-quick-idniri2m`, both ids `524545235096`) while the next
  assertions, including the new page size, passed. A probe reused the id in 1250 of
  3000 destroy/create pairs. The `start_maintenance failed` line in that log came
  from a later test and is unrelated.
- Prevention: assert the old wrapper is invalid (`destroy` zeroes its id) and the
  controller holds a different wrapper. Product staleness checks that key on
  `sessionID` (snapshots, pin and expansion callbacks) also see reused ids; they pair
  it with input and revision state.
- Regression: [OwlInputHabitsIntegrationTests](tests/OwlInputHabitsIntegrationTests.swift)
  now checks wrapper identity, which is independent of allocator reuse. It runs in
  [the merge gate](scripts/gate.sh).
- Seen on 1 distinct date: 2026-10-20.

## Require positive evidence before judging a live trace

**An empty or unfinished trace is unverified, even when its error count is zero.**

- Reason: `omnibox judge` returned success for an empty file and a composition
  that never cleared. Zero `commitComposition finalize` lines did not show that
  the intended interaction happened.
- Prevention: require a non-empty composition and a final zero-length clear
  before emitting PASS; keep forced-finalize rejection. The judge covers these
  trace properties only; host identity, the actual input sequence, and visual
  acceptance remain the live host matrix's responsibility.
- Regression: [smoke-live.selftest.py](scripts/smoke-live.selftest.py) invokes the
  actual shell judge with empty, unrelated, clear-only, unfinished, valid and
  forced-finalize logs. It runs in [the merge gate](scripts/gate.sh).
- Seen on 1 distinct date: 2026-10-15.

## Commit endpoint and replacement key reference together

**Write a replacement key under an independent secret name before committing its endpoint.**

- Reason: saving the endpoint first exposed the old key if Keychain failed and rollback
  also failed. An atomic config write can also succeed before permission hardening throws;
  a thrown save does not prove that nothing was persisted.
- Prevention: commit endpoint and new secret reference together; retire the old key only
  after confirmed success and only if no profile references it. An ambiguous save retains
  both keys; a readable old reference with no staged-key reference permits staged-key cleanup.
  Compare scheme/host/default-normalized port against the persisted profile: origin changes
  require a nonblank replacement key. Same-origin edits preserve the persisted key reference,
  and failed-save retries refresh the editing profile from the reloaded list.
  Probe requests also require a replacement key when the origin changes.
- Regression: `ProviderProfileStoreTests` reloads the real JSON store and checks both
  `defaultProfile` and `OwlCloudRouting` for retired/custom defaults. Post-write errors and
  key-write plus rollback failures produced 8 assertion failures before the fix.
- Scope: isolated file storage and injected secret-store failures; no live Keychain or
  installed-app upgrade acceptance is claimed.
- Seen on 1 distinct date: 2026-10-21.
