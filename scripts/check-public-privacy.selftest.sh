#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
suite_root="$(mktemp -d)"
trap 'rm -rf "$suite_root"' EXIT

new_case() {
  case_repo="$(mktemp -d "$suite_root/case.XXXXXX")"
  git -C "$case_repo" init -q
  mkdir -p "$case_repo/scripts"
  cp "$repo_root/scripts/check-public-privacy.sh" "$case_repo/scripts/"
  printf 'safe\n' > "$case_repo/README.md"
  git -C "$case_repo" add .
  git -C "$case_repo" \
    -c user.name=security-test \
    -c user.email=12345+security-test@users.noreply.github.com \
    commit -q -m 'safe fixture'
}

expect_failure() {
  if git -C "$case_repo" status --porcelain >/dev/null &&
     (cd "$case_repo" && bash scripts/check-public-privacy.sh >/dev/null 2>&1); then
    printf 'expected privacy gate failure: %s\n' "$1" >&2
    exit 1
  fi
}

new_case
(cd "$case_repo" && bash scripts/check-public-privacy.sh >/dev/null)

new_case
printf 'local path: /Users/example/secret\n' > "$case_repo/notes.txt"
git -C "$case_repo" add notes.txt
expect_failure "personal absolute path"

new_case
printf 'local only\n' > "$case_repo/.env.production"
git -C "$case_repo" add -f .env.production
expect_failure "sensitive filename"

new_case
printf 'identity\n' > "$case_repo/identity.txt"
git -C "$case_repo" add identity.txt
git -C "$case_repo" \
  -c user.name=security-test \
  -c user.email=developer@example.test \
  commit -q -m 'identity fixture'
expect_failure "non-noreply commit identity"

new_case
git -C "$case_repo" remote add private \
  git@github.com:semantic-craft/famoime-mac-private-archive-20260724.git
expect_failure "private remote"

printf 'public privacy self-test passed\n'
