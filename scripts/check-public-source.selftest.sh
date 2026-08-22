#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
suite_root="$(mktemp -d)"
trap 'rm -rf "$suite_root"' EXIT
case_repo="$suite_root/successor"

git -C "$suite_root" init -q successor
mkdir -p "$case_repo/resources" "$case_repo/Owltype.xcodeproj" "$case_repo/scripts"
cp "$repo_root/scripts/check-public-source.sh" "$case_repo/scripts/"
cp "$repo_root/scripts/check-public-privacy.sh" "$case_repo/scripts/"
cp "$repo_root/resources/Info.plist" "$case_repo/resources/Info.plist"
printf 'MARKETING_VERSION = 2.0.2;\n' >"$case_repo/Owltype.xcodeproj/project.pbxproj"
printf 'successor source fixture\n' >"$case_repo/README.md"
git -C "$case_repo" add .
git -C "$case_repo" \
  -c user.name=public-source-test \
  -c user.email=12345+public-source-test@users.noreply.github.com \
  commit -q -m 'successor source fixture'

(cd "$case_repo" && bash scripts/check-public-source.sh >/dev/null)

ln -s /tmp/owltype-policy-outside-source.json \
  "$case_repo/scripts/sparkle-key-transition.json"
git -C "$case_repo" add scripts/sparkle-key-transition.json
git -C "$case_repo" \
  -c user.name=public-source-test \
  -c user.email=12345+public-source-test@users.noreply.github.com \
  commit -q -m 'attempt policy symlink bypass'
if (cd "$case_repo" && bash scripts/check-public-source.sh >/dev/null 2>&1); then
  printf 'successor source gate accepted a tracked policy symlink\n' >&2
  exit 1
fi

printf 'public-source successor self-test passed\n'
