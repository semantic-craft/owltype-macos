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
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
if info.get("SUFeedURL") != "https://downloads.responsay.com/owltype/v2/appcast.xml":
    raise SystemExit("Sparkle feed differs from the reviewed endpoint")
if info.get("SUPublicEDKey") != "dWrr6gck5aoy5F7V00SizqQM6w9MHmZzeeQFSqYTlfM=":
    raise SystemExit("Sparkle public verification key is not the Owltype key")
versions = set(re.findall(r"MARKETING_VERSION = ([0-9.]+);", open(sys.argv[2]).read()))
if len(versions) != 1:
    raise SystemExit("project must declare one marketing version")
version = next(iter(versions))
policy_path = Path(sys.argv[3])
index_entry = subprocess.run(
    ["git", "ls-files", "--stage", "--", str(policy_path)],
    check=True,
    stdout=subprocess.PIPE,
    text=True,
).stdout.strip()
index_mode = index_entry.split(maxsplit=1)[0] if index_entry else None
worktree_present = os.path.lexists(policy_path)
worktree_regular = (
    worktree_present
    and not policy_path.is_symlink()
    and policy_path.is_file()
)
if version == "2.0.1":
    if index_mode not in {"100644", "100755"} or not worktree_regular:
        raise SystemExit(
            "2.0.1 requires a Git-tracked regular Sparkle transition policy"
        )
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    if policy.get("releaseVersion") != version:
        raise SystemExit("Sparkle transition policy is not locked to the project release")
    if policy.get("toPublicKey") != info.get("SUPublicEDKey"):
        raise SystemExit("Sparkle transition target differs from the App public key")
    if policy.get("successorFeedKey") != "owltype/v2/appcast.xml":
        raise SystemExit("Sparkle transition successor feed differs from the reviewed endpoint")
elif index_mode is not None or worktree_present:
    raise SystemExit("Sparkle transition policy must be removed after 2.0.1")
PY
then
  failed=1
fi

if (( failed != 0 )); then
  exit 1
fi

printf 'public-source boundary check passed\n'
