# Lessons from verified work

Each entry keeps the rule, reason, regression, and dates observed. Count distinct
review dates, not retries. Keep deterministic checks in the local gate.

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
