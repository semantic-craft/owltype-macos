#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

failed=0

bash scripts/check-public-privacy.sh

# The complete product — including the cloud/AI layer — is developed in the private
# Cursor Origin repository. This gate protects the corresponding-source snapshot
# distributed with each binary release by blocking what must never leave the private tree:
# generated artifacts, license-restricted data sources, key material, personal
# paths, and drift of the pinned Sparkle update anchor.

while IFS= read -r tracked_path; do
  case "$tracked_path" in
    bin/.placeholder|lib/.placeholder)
      continue
      ;;
  esac

  case "$tracked_path" in
    build/*|download/*|bin/*|lib/*|Frameworks/*|data/opencc/*|data/plum/*|data/owl-rime/*|.wrangler/*|*.xcresult/*)
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

if ! python3 - resources/Info.plist Owltype.xcodeproj/project.pbxproj scripts/sparkle-key-transition.json <<'PY'
import json
import plistlib
import re
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
if info.get("SUFeedURL") != "https://downloads.responsay.com/owltype/v2/appcast.xml":
    raise SystemExit("Sparkle feed differs from the reviewed endpoint")
if info.get("SUPublicEDKey") != "dWrr6gck5aoy5F7V00SizqQM6w9MHmZzeeQFSqYTlfM=":
    raise SystemExit("Sparkle public verification key is not the Owltype key")
versions = set(re.findall(r"MARKETING_VERSION = ([0-9.]+);", open(sys.argv[2]).read()))
policy = json.load(open(sys.argv[3], encoding="utf-8"))
if versions != {policy.get("releaseVersion")}:
    raise SystemExit("Sparkle transition policy is not locked to the project release")
if policy.get("toPublicKey") != info.get("SUPublicEDKey"):
    raise SystemExit("Sparkle transition target differs from the App public key")
if policy.get("successorFeedKey") != "owltype/v2/appcast.xml":
    raise SystemExit("Sparkle transition successor feed differs from the reviewed endpoint")
PY
then
  failed=1
fi

if (( failed != 0 )); then
  exit 1
fi

printf 'public-source boundary check passed\n'
