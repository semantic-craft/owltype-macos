#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

failed=0

bash scripts/check-public-privacy.sh

# Since the single-repo adoption (2026-07), the complete product — including the
# cloud/AI layer — is developed in the open. This gate no longer polices feature
# boundaries; it blocks only what must never be committed to a public tree:
# generated artifacts, license-restricted data sources, key material, personal
# paths, and drift of the pinned Sparkle update anchor.

while IFS= read -r tracked_path; do
  case "$tracked_path" in
    bin/.placeholder|lib/.placeholder)
      continue
      ;;
  esac

  case "$tracked_path" in
    build/*|download/*|bin/*|lib/*|Frameworks/*|data/opencc/*|data/plum/*|data/famo-rime/*|*.xcresult/*)
      printf 'forbidden generated artifact: %s\n' "$tracked_path" >&2
      failed=1
      ;;
  esac

  case "$tracked_path" in
    data/*wubi*|data/*Wubi*|data/*octagram*|data/*Octagram*)
      printf 'blocked data source: %s\n' "$tracked_path" >&2
      failed=1
      ;;
  esac
done < <(git ls-files)

if ! python3 - resources/Info.plist <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
if info.get("SUFeedURL") != "https://responsay.com/famo/appcast.xml":
    raise SystemExit("Sparkle feed differs from the reviewed endpoint")
if not info.get("SUPublicEDKey"):
    raise SystemExit("Sparkle public verification key is missing")
PY
then
  failed=1
fi

if (( failed != 0 )); then
  exit 1
fi

printf 'public-source boundary check passed\n'
