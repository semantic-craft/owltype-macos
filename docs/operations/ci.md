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

## CI ownership

| Service | File | Responsibility |
| --- | --- | --- |
| Depot CI | `.depot/workflows/ci.yml` | Portable source, privacy, script, secret, license, and policy checks on Linux |
| Buildkite | `.buildkite/pipeline.yml` | Native Swift/Xcode tests, Debug and Release builds, release gates, and an installed input-method smoke on hosted Apple Silicon macOS |

Depot deliberately does not build or test the macOS app. Its only lane is the
small cross-platform policy surface that can produce a truthful result on
Linux. The explicit repository and organization keep the retained GitHub
remote from being selected accidentally:

```bash
depot ci run --repo xianwei/famotype-macos --org 2wztpgtn69 \
  --workflow .depot/workflows/ci.yml --job policy
```

Buildkite targets the hosted `macos-medium` queue. It uses the repository's own
Make targets: `make test`, Debug and Release builds, release/cohort self-tests,
secret and artifact gates, and the existing dev-install plus
`check-installed.sh` smoke. That smoke verifies the installed bundle, unique TIS
enumeration, Hans enablement/selectability, structured diagnostics, and a real
Rime candidate probe. A hosted runner has no active text client through which to
truthfully assert the current/selected input source; the script's default local
mode retains that stricter current-source assertion. The installed smoke is
meaningful only because the hosted runner is disposable; it must never be copied
into a persistent developer or release machine without a separate safety review.

The Release target keeps its normal optimized configuration but CI disables the
index store and whole-module batching for that invocation. A single Famo
whole-module Swift frontend exceeds the macOS memory high-watermark; compiling
the same Release configuration per file avoids an infrastructure-only failure
without weakening optimization or source coverage.

The Buildkite pipeline repository provider is `Origin (xianwei)` and its
checkout URL is the Cursor Origin repository, never the retained GitHub backup.
Buildkite may remain enabled only while its existing hosted-macOS entitlement
does not require a purchase or renewal. Paying for a plan is a separate
maintainer decision.

## Pull requests

Create and inspect Origin pull requests with:

```bash
origin pr create --push --status open
origin pr checks <number>
origin pr view <number> --checks
origin pr merge <number> --merge
```

The default branch merge rules require an up-to-date branch plus the exact
`Depot CI` and `Buildkite / famotype-macos` status checks. A separate push
ruleset blocks force pushes and deletion. Origin Early Beta currently treats
its own merge transaction as a direct push, so the direct-push checkbox stays
disabled; project protocol still prohibits direct pushes to `main`.
