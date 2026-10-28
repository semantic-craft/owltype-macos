# GitHub and local gate operations

GitHub is the canonical code, issue, and pull-request home for this repository:

```text
git@github.com:semantic-craft/owltype-macos.git
```

The local remote topology has one canonical remote:

- `origin`: the private GitHub development repository, used for fetch, branches, pull requests,
  and merges.

Signed installers, the Sparkle appcast, and the corresponding source for every
distributed version remain on `downloads.responsay.com`. GitHub Releases is not a
release surface for Owltype.

## The gate

There is no hosted CI. GitHub Actions remains disabled; checks and release credentials
stay on the maintainer's Mac. Repository visibility changes do not enable hosted runners. A missing hosted check is not a pass: the merger owns the local gate
result for the exact pull-request head.

`scripts/gate.sh` checks the required tools, initializes the submodules at their pinned
revisions (a fresh worktree needs no manual setup before its first run), then runs the
public-source and privacy boundaries, portable-script syntax and self-tests, the
secret-finding policy with gitleaks and trufflehog over reachable history, licensing
checks, dependency bootstrap, clean-room seed generation, SwiftLint, release self-tests,
the Swift test suite, Debug and Release builds, manifest, identity-residual,
artifact-chain, cohort and release-chain gates, built-App secret checks, and Periphery.
`--quick` stops after the test suite.

## Focused feedback and retained evidence

Use [the verification runner](../../scripts/verify.py) during editing. It runs the
existing checks and records their commands, elapsed time, exit status and coverage
limits. Pick the relevant scope; none of the focused scopes replaces the full gate:

```sh
python3 scripts/verify.py navigation
python3 scripts/verify.py workflow
python3 scripts/verify.py distribution
python3 scripts/verify.py swift --test OwlKeyboardSettingsApplicationTests
python3 scripts/verify.py swift --test OwlInputHabitsIntegrationTests --test EngineSeamTests
```

`navigation` checks maintained references and their regression tests. `workflow`
also tests the verification runner. `distribution` tests the publisher, stale-process
detector and release orchestration using fixtures; it does not sign or publish.
`swift` uses the same seed preparation and test host as `make test`, selecting only
the named classes or `Class/method` cases. A new checkout still needs the dependency
setup in [CONTRIBUTING](../../CONTRIBUTING.md). Swift builds and seed preparation
are still required; selected tests are not a promise of a seconds-long cold build.
Use `--dry-run` to inspect any scope without running it or writing evidence.

Direct `scripts/gate.sh` and `scripts/gate.sh --quick` calls also use the recorder.
`--quick` retains history scans and the complete offline product suite: it is a
pre-merge subset, not the everyday focused check. Gate and release calls explicitly
clear `TEST_ONLY`, so a focused selection cannot silently narrow release validation.

Each run creates a private directory under
`~/Projects/_shared-work/owltype/verification` with `result.json`, `summary.md` and
numbered command logs. Set `OWL_VERIFICATION_DIR` to use another durable location
outside the checkout. These files survive worktree/build cleanup. They are local
evidence and may contain machine paths; review and redact before sharing.

The receipt captures HEAD, working-tree status, tracked diff hashes, untracked file
hashes and submodule state before and after execution. A submodule that matches its
gitlink records as `pinned` whether or not it is initialized, so the gate's own submodule
initialization is not a source change; a modified or re-pointed submodule is recorded in
full. A changed source snapshot returns failure even when every command passed. Ignored
build inputs and edits reverted before the final snapshot are outside this check. A
dirty-tree pass
describes that snapshot, not an exact committed PR head. Failed commands retain their
exit status and later commands remain `not-run`; a `running` record left by a hard
kill is incomplete evidence. Normal interruption terminates the check subprocesses.

For PR closeout, include the tested commit, commands, result, scope omissions and
evidence location in the existing PR. Keep required screenshots, selected xcresult
bundles and host-acceptance records alongside the receipt before deleting temporary
files. Large logs remain local; the durable PR summary must stand on its own.

One step is deliberately not in the gate: the installed input-method smoke
(`install-dev.sh` followed by `check-installed.sh`). Installing a development input
method mutates the persistent machine and needs its own explicit safety and acceptance
plan.

The Release build keeps its optimized configuration, but the gate disables the index
store and whole-module batching for that invocation. One whole-module Swift frontend
can exceed the macOS memory high-watermark; compiling per file avoids an
infrastructure-only failure without weakening optimization or source coverage.

## Navigation references

Run `python3 scripts/check-navigation.py` and
`python3 scripts/check-navigation.selftest.py` for navigation changes; both run in the
local gate. The scope is the agent entry and its routing documents, installation
constraints, and the installation code comments that refer to those constraints.
The explicit source list is maintained in the checker; a missing source also fails.

Markdown links/images and standalone backtick file paths are checked for existence.
Markdown paths are relative to their document; source-comment paths are repository-relative.
Links with URL schemes, network URLs and fragment-only links are excluded; anchors
inside an existing file are not validated. Fenced examples are excluded. For a historical
or optional reference outside a fence, put `<!-- reference-check: historical -->` or
`<!-- reference-check: optional -->` on that line only, and explain its context in prose.
New required navigation belongs in ordinary links, not in exempt examples.

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
gh pr merge <number> --squash --delete-branch
```

The repository accepts only squash merges. The commit on `main` takes the pull request
title as its subject and the pull request body as its message, so write the body to
stand as the commit message.

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

For project-wide housekeeping, first complete [issue reconciliation](../agents/issue-tracker.md#project-housekeeping-and-closeout).
The cleanup below handles build artifacts and registrations; its success alone
does not establish that the project's open work has been audited.

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
- Stale LaunchServices registrations for `Owltype.app` and the apps its builds contain
  or produce: Sparkle's `Updater.app`, `OwltypeInstaller.app` with the `Owltype.app` it
  carries, the UI-test runner, and the patched Sparkle build under
  `build/sparkle-patched/`. Each is removed by its exact dead path; live paths and other
  products' apps are left alone. The script never rebuilds the whole LaunchServices
  database. [clean-dev.selftest.sh](../../scripts/clean-dev.selftest.sh) checks the
  selection against a canned registration dump.

It never deletes Time Machine snapshots. Recently deleted files may stay pinned by a
local snapshot, so free space can lag behind a successful cleanup.
