# GitHub and local gate operations

GitHub is the canonical code, issue, and pull-request home for this repository:

```text
git@github.com:semantic-craft/owltype-macos.git
```

The local remote topology has one canonical remote:

- `origin`: the public GitHub repository, used for fetch, branches, pull requests,
  and merges.

Signed installers, the Sparkle appcast, and the corresponding source for every
distributed version remain on `downloads.responsay.com`. GitHub Releases is not a
release surface for Owltype.

## The gate

There is no hosted CI. GitHub Actions remains disabled; checks and release credentials
stay on the maintainer's Mac. Making the source public does not enable hosted runners. A missing hosted check is not a pass: the merger owns the local gate
result for the exact pull-request head.

`scripts/gate.sh` runs the public-source and privacy boundaries, portable-script
syntax and self-tests, the secret-finding policy with gitleaks and trufflehog over
reachable history, licensing checks, dependency bootstrap, clean-room seed generation,
SwiftLint, release self-tests, the Swift test suite, Debug and Release builds, manifest,
identity-residual, artifact-chain, cohort and release-chain gates, built-App secret
checks, and Periphery. `--quick` stops after the test suite.

One step is deliberately not in the gate: the installed input-method smoke
(`install-dev.sh` followed by `check-installed.sh`). Installing a development input
method mutates the persistent machine and needs its own explicit safety and acceptance
plan.

The Release build keeps its optimized configuration, but the gate disables the index
store and whole-module batching for that invocation. One whole-module Swift frontend
can exceed the macOS memory high-watermark; compiling per file avoids an
infrastructure-only failure without weakening optimization or source coverage.

## Pull requests

Start from a fresh canonical baseline and keep each branch focused:

```bash
git fetch --prune origin
git switch -c codex/<topic> origin/main
git push -u origin codex/<topic>
gh pr create --fill
```

Before the final gate, update the branch from fresh `origin/main`. Then run the narrowest
focused checks plus `scripts/gate.sh` on the exact head and record the commands and
result in the pull request. Merge through GitHub only while that baseline is still current:

```bash
gh pr merge <number> --merge --delete-branch
```

The default-branch ruleset requires a pull request and resolved review threads. It
requires zero approving reviews while the project has one maintainer and has no required
hosted status check. It also blocks branch deletion and non-fast-forward updates. Fresh
baseline verification and direct-push prohibition are project protocol because no hosted
check can enforce the local-gate relationship.

When a second maintainer is available, add real ownership boundaries where useful and
require a non-author approval.

## Release ownership

Signing, notarization, cohort composition, and publication stay local:

```bash
scripts/release.sh
python3 scripts/owl_distribution.py --publish --output-root <verified-output-root>
```

Publication is complete only after the publisher has remote-read and SHA-256 verified
all immutable artifacts, then committed `owltype/latest.json` and
`owltype/v3/appcast.xml` (2.0.10 onward). The v2 feed stays frozen at 2.0.9; recovery from the lost signing key requires a one-time manual installation. Repository migration or cleanup must not change the frozen older feeds.

## Cleaning up after the gate

`scripts/clean-dev.sh` is the gate's companion. It reports by default and deletes only
with `--apply`:

```bash
scripts/clean-dev.sh           # report only
scripts/clean-dev.sh --apply   # remove reviewed leftovers
```

Builds and worktrees leave derived artifacts and LaunchServices claims behind. Enough
dead `Owltype.app` registrations can make macOS resolve the input method to an ad-hoc
development build instead of the installed notarized copy.

The cleanup covers three bounded surfaces:

- Build output in this repository and its worktrees. A release cohort's `release/`
  directory is retained because it is the signed record of a shipped version.
- Orphaned Xcode DerivedData whose recorded workspace belonged to this repository and
  no longer exists. Other projects and live workspaces are untouched.
- Stale LaunchServices registrations for `Owltype.app`, removed one exact dead path at
  a time. The script never rebuilds the whole LaunchServices database.

It never deletes Time Machine snapshots. Recently deleted files may stay pinned by a
local snapshot, so free space can lag behind a successful cleanup.
