# Lessons from verified work

Each entry keeps the rule, reason, regression, and dates observed. Count distinct
review dates, not retries. Keep deterministic checks in the local gate.

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
