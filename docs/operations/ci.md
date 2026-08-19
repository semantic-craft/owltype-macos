# Origin and CI operations

Cursor Origin is the canonical code and pull-request forge for this repository.
GitHub is the private issue tracker and a retained archival backup — it is not
the release surface: `downloads.responsay.com` serves the signed installers,
the Sparkle appcast, and the corresponding source for every distributed
version. The canonical clone URL is:

```text
https://origin.cursor.com/xianwei/famotype-macos.git
```

Keep the local remotes distinct:

- `origin`: Cursor Origin, used for fetch, development branches, and pull requests.
- `github`: the private GitHub issue tracker and archival backup. It runs no
  builds and publishes nothing.

The repositories are not mirrored automatically after detaching Origin from
GitHub. Do not push code changes to `github` after the migration unless a
maintainer explicitly authorizes a backup refresh.

## The gate

There is no hosted CI, on any service. Depot (a portable policy lane on Linux)
and Buildkite (hosted Apple Silicon macOS) ran for a few days after the Origin
migration; both were trials of paid services with no free tier that fits a
one-person project, and Buildkite's hosted macOS queue stopped accepting builds
on 2026-08-19. They were retired rather than paid for. GitHub Actions was
retired the same day, for the same reason plus three of its own — see
[GitHub Actions, retired 2026-08-19](#github-actions-retired-2026-08-19).

`scripts/gate.sh` runs on the development Mac exactly what those lanes ran:
the public-source and privacy boundaries, portable-script syntax and
self-tests, the secret-finding policy with gitleaks and trufflehog over
reachable history, the licensing files; then `make bootstrap`, `make famo-seed`,
`swiftlint`, the release self-test, `make test`, Debug and Release builds, the
manifest, identity-residual, artifact-chain, cohort and release-chain gates,
`check-secrets.sh` over the tree and the built App, and `periphery`.
`--quick` stops after `make test`.

One step is deliberately **not** in the gate: the installed input-method smoke
(`install-dev.sh` followed by `check-installed.sh`). It was meaningful only
because the hosted runner was disposable; it must never be copied onto a
persistent developer or release machine without a separate safety review.

The Release build keeps its normal optimized configuration but the gate
disables the index store and whole-module batching for that invocation, as the
hosted lanes did: a single Famo whole-module Swift frontend exceeds the macOS
memory high-watermark, and compiling per file avoids an infrastructure-only
failure without weakening optimization or source coverage.

## Cleaning up after the gate

`scripts/clean-dev.sh` is the gate's companion: the gate and every worktree
build leave derived artifacts behind, and this removes the ones nothing can
reach any more. It reports by default and only deletes with `--apply`:

```bash
scripts/clean-dev.sh           # report what would go, change nothing
scripts/clean-dev.sh --apply   # remove it
```

It exists because the leftovers are not merely wasted disk. Every build of
`Famo.app` registers another bundle claiming `im.famo.inputmethod.Famo` with
LaunchServices, and the claim outlives the directory it points at. Enough dead
claims and macOS can resolve the input method to an ad-hoc development build
instead of the installed, notarized one — a working install starts failing for
reasons that have nothing to do with the code. The first sweep, on 2026-08-19,
found 98 dead claims against a single live one, beside 66 GB of orphaned Xcode
DerivedData. Run it after a release, after tearing down worktrees, or whenever
the input method starts behaving strangely on a development machine.

Three things it clears, and the limits on each:

- **Build output in this repository and its worktrees**, including
  `installer/build`. A release cohort's `release/` directory is kept: it is the
  signed record of a shipped version, it is small, and re-creating it would mean
  another notarization round trip. Only the build intermediates around it go.
- **Orphaned Xcode DerivedData that belonged to this repository** — entries
  whose recorded workspace was under this repository (or an agent worktree of
  it) *and* no longer exists. The product builds into the repository, so this
  mostly catches Sparkle submodule builds. Another project's entries are never
  touched, nor is any entry whose workspace is still on disk.
- **Stale LaunchServices registrations for `Famo.app`** — each dead path is
  unregistered individually with `lsregister -u`. The script deliberately does
  not run a database rebuild (`lsregister -kill -r`): a rebuild would reset file
  associations far outside this project, and unregistering the exact stale paths
  achieves the same result without that blast radius. If more than one *live*
  registration remains, it says so — normally only
  `/Library/Input Methods/Famo.app` should be there, and a stray build product
  can shadow it.

It never deletes a Time Machine snapshot. Recently deleted files stay pinned by
local snapshots, so free space may not move until macOS thins them; that is
expected and is not a failed cleanup.

## GitHub Actions, retired 2026-08-19

`.github/workflows/` held five workflows — `commit-ci.yml`,
`pull-request-ci.yml`, `source-ci.yml`, `release-ci.yml`, `codeql.yml` — plus a
`dependabot.yml`. All six files were deleted on 2026-08-19. Nothing replaced
them; `scripts/gate.sh` was already the gate and did not need a single new
check.

Why they went:

- **They were billable.** Actions minutes are free and unmetered only on public
  repositories; this one is private, so it draws on a small included monthly
  allowance and pays for every minute beyond it. All five workflows ran a
  `macos-26` job — `codeql.yml` through the `swift` leg of its language matrix —
  and macOS bills at the highest per-minute multiplier among GitHub's standard
  runners, so the allowance did not survive contact with them. `codeql.yml`
  additionally needs GitHub Advanced Security to report on a private repository,
  which is a separate paid product. Retiring Depot and Buildkite while leaving
  these running would have kept the same builds on a third paid meter.
- **They gated nothing.** Code review and merges happen on Cursor Origin, where
  these workflows never ran. A commit reaches `github` only through an
  authorized backup refresh — after `scripts/gate.sh` has already passed
  locally — so the workflows re-ran, hours later and at cost, checks whose
  verdict was already known.
- **They had stopped even reporting.** Every run on 2026-08-19 failed within
  five seconds, annotated "The job was not started because recent account
  payments have failed or your spending limit needs to be increased". By the end
  they produced red marks and no signal.
- **They could not release.** `release-ci.yml` said so in its own comments: the
  EdDSA update key and the Developer ID identity are deliberately absent from
  CI, so it built as far as `package` and stopped. `scripts/release.sh` on the
  maintainer's Mac owns signing, notarization and cohort composition, and
  `scripts/famo_distribution.py --publish` ships the cohort to
  `downloads.responsay.com`.

`source-ci.yml` was the only workflow carrying gate-shaped checks, and
`scripts/gate.sh` already ran all of them: `check-public-source.sh` and
`check-public-privacy.selftest.sh`; `bash -n` over the portable scripts and
`py_compile` over the Python entrypoints; `famo-distribution.selftest.py` and
`release-source-archive.selftest.py`; `make bootstrap`, `make famo-seed`,
`make test`, `make release`; the artifact-chain, cohort, cohort-transition,
release-chain and release self-tests; `secret-finding-policy.selftest.py`; and
`check-secrets.sh` over both the tree and the built App.

Three things went away on purpose and have no local replacement:

- **CodeQL.** Buying GitHub Advanced Security is out of scope for this project.
  The finding class this repository actually cares about — credentials and
  personal data escaping into source, history or a build product — is covered on
  the development Mac by gitleaks and trufflehog over reachable history,
  `scripts/secret-finding-policy.py`, and `scripts/check-secrets.sh` over the
  tree and the built App, all inside `scripts/gate.sh`, plus the `make setup-dev`
  pre-push hook.
- **The `x86_64` half of `action-build.sh package`.** `action-build.sh` exported
  `ARCHS='arm64 x86_64'`, and it was the only place in this project that ever
  compiled for Intel: both build configurations pin `ONLY_ACTIVE_ARCH = YES`,
  neither `scripts/gate.sh` nor `scripts/release.sh` overrides it, and the
  shipped, Developer ID-signed 1.6.3 App is `arm64`-only. So nothing that ships
  loses coverage; what is gone is the early warning that would matter if Intel
  support were ever wanted back. The `.pkg` assembly the workflow also exercised
  still runs — in `make release-artifacts` under `scripts/release.sh`, against
  the real signing identity — but no longer on every push.
- **Dependabot.** Its `github-actions` ecosystem entry lost its subject when the
  workflows went. Its `gitsubmodule` entry went with the file: submodule pins
  are reviewed by hand and move through `make bootstrap`, and a Dependabot pull
  request opened against `github` could not be merged anyway, because `github`
  is not the code-review forge.

## GitHub repository settings

Settings on `semantic-craft/famotype-macos` were changed on 2026-08-19 to match
the deletion:

- **Actions are disabled** for the repository
  (`repos/semantic-craft/famotype-macos/actions/permissions` → `enabled: false`).
  With no workflow files left this changes nothing today; it exists so that a
  workflow file pushed back by accident — a stale branch, a restore from an
  archived state — cannot start a billable job. Reversible from
  Settings → Actions. Disabling also cleared the repository's
  `sha_pinning_required` setting, which had been on: anyone re-enabling Actions
  must turn SHA pinning back on before a workflow is allowed to run, because
  the pinned-action guarantee the deleted workflows relied on does not come
  back by itself.
- **The `Protect default branch` ruleset (id 19646616)** lost its
  `required_status_checks` and `pull_request` rules. The two required contexts,
  `public-source-boundary` and `release-gate`, came from `source-ci.yml`;
  leaving them in place would have frozen `main` on GitHub permanently, because
  a check that no longer exists can never report. The `pull_request` rule went
  with them: an authorized backup refresh is a fast-forward push, not a pull
  request, and GitHub is not the review forge. `deletion` and `non_fast_forward`
  remain, so the branch still cannot be deleted or rewritten.

An authorized backup refresh is therefore a single fast-forward push:

```bash
git push git@github.com:semantic-craft/famotype-macos.git origin/main:main
```

SSH rather than HTTPS on purpose: the local `gh` token carries the `repo` scope
but not `workflow`, so an HTTPS push of any commit that touches
`.github/workflows/` — including the commit that deletes those files — is
rejected.

GitHub issues, releases and secrets were not touched.

## Pull requests

Create and inspect Origin pull requests with:

```bash
origin pr create --push --status open
origin pr checks <number>
origin pr view <number> --checks
origin pr merge <number> --merge
```

The default branch merge rule requires an up-to-date branch and no service
status check, so the ruleset cannot prove the gate ran: `scripts/gate.sh`
passing on the branch as it will merge is the contract, and whoever merges —
person or agent — owns it. A separate push ruleset blocks force pushes and
deletion. Origin Early Beta currently treats its own merge transaction as a
direct push, so the direct-push checkbox stays disabled; project protocol
still prohibits direct pushes to `main`. Origin also reports
`require_branch_up_to_date failed … forge commit is orphan` *after* the merge
commit has landed, leaving the PR record open: verify the merge from remote
refs, then close the record by hand.
