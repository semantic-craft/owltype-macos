# Origin and CI operations

Cursor Origin is the canonical code and pull-request forge for this repository.
GitHub is the private issue tracker, release surface, and retained backup. The
canonical clone URL is:

```text
https://origin.cursor.com/xianwei/famotype-macos.git
```

Keep the local remotes distinct:

- `origin`: Cursor Origin, used for fetch, development branches, and pull requests.
- `github`: the private GitHub backup, issue tracker, and release surface.

The repositories are not mirrored automatically after detaching Origin from
GitHub. Do not push code changes to `github` after the migration unless a
maintainer explicitly authorizes a backup refresh or release operation.

## The gate

There is no hosted CI. Depot (a portable policy lane on Linux) and Buildkite
(hosted Apple Silicon macOS) ran for a few days after the Origin migration;
both were trials of paid services with no free tier that fits a one-person
project, and Buildkite's hosted macOS queue stopped accepting builds on
2026-08-19. They were retired rather than paid for.

`scripts/gate.sh` runs on the development Mac exactly what those two lanes ran:
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
disables the index store and whole-module batching for that invocation, as CI
did: a single Famo whole-module Swift frontend exceeds the macOS memory
high-watermark, and compiling per file avoids an infrastructure-only failure
without weakening optimization or source coverage.

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
