# Contributing to Owltype

Thank you for improving Owltype. This repository is the complete source for the macOS
product, so every accepted change must remain independently buildable and auditable
from this repository alone.

## What we accept

Good contributions include focused bug fixes, tests, documentation, accessibility and
performance improvements, and narrowly scoped product or release-engineering changes.
Please open an issue before starting a feature that changes user-visible behavior, the
release boundary, bundled data, or a third-party dependency.

Do not submit generated build products, credentials, private data, local logs or agent
state, personal home-directory paths, license-restricted datasets, private repository
references, or a change that requires unavailable source or an untracked private service.

## Set up and verify a change

Development requires macOS 14 or later and Xcode 26 or later. From a fresh checkout:

```sh
git submodule update --init --recursive
make setup-dev
make bootstrap
make owl-seed
make test
```

`make bootstrap` uses the pinned prebuilt dependencies the gate builds against. Contributors
who want to build those dependencies from source may use `make deps` instead. Before opening
a pull request, also run the public-source boundary relevant to every change:

```sh
bash scripts/check-public-source.sh
```

Run the narrowest additional test that exercises the changed behavior. Pull requests are
opened on GitHub. There is no hosted CI: `scripts/gate.sh` runs the portable
source and policy checks plus the native macOS tests, builds and release gates on the
development Mac (`--quick` for the fast subset), and a pull request is merged only after
it passes. Contributors do not need signing or notarization credentials and should not
attempt to publish a release.

The gate leaves build products behind, and every build of `Owltype.app` adds another
LaunchServices claim on the same bundle identifier — enough of them and macOS can start
launching a stale development build instead of the installed input method.
`scripts/clean-dev.sh` clears both; it reports by default and deletes only with
`--apply`. Run it after tearing down worktrees, or whenever a development machine's
input method starts misbehaving. See [docs/operations/ci.md](docs/operations/ci.md).

## Public-source and licensing boundary

All source, tests, fixtures, and build inputs needed by a contribution must be present in
this repository under a compatible license. Update `THIRD_PARTY_NOTICES.md`,
`PROVENANCE.md`, or the source manifest machinery when a change affects third-party code,
bundled data, or corresponding-source obligations. Never include secrets or real user
content in a fixture; use synthetic placeholders.

Security vulnerabilities must be reported through GitHub's private
[Report a vulnerability](https://github.com/semantic-craft/owltype-macos/security/advisories/new)
flow, not a public issue. See [SECURITY.md](SECURITY.md).

## Pull requests and review

Keep each GitHub pull request focused, explain its user-visible and source-boundary
effects, and link the originating GitHub issue. No service check is required; the
merger is responsible for `scripts/gate.sh` passing on the exact pull-request head
before merge and recording that result in the pull request.

The project currently has one maintainer, so the branch rules require a pull request and
resolved review threads but zero approving reviews. They do not require a hosted status check;
the recorded local gate result is the merge contract.
`CODEOWNERS` is intentionally absent because it would not create a real
independent review boundary. When a second maintainer is available, the project will add
real ownership boundaries where useful and require a non-author approval.

By participating, you agree to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
