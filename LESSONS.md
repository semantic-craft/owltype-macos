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
