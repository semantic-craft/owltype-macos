#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

failed=0

while IFS= read -r tracked_path; do
  case "$tracked_path" in
    build/*|download/*|bin/*|lib/*|Frameworks/*|data/opencc/*|data/plum/*|data/famo-rime/*|*.xcresult/*)
      printf 'forbidden generated artifact: %s\n' "$tracked_path" >&2
      failed=1
      ;;
  esac

  case "$tracked_path" in
    *Cloud*|*Provider*|*SearchClient*|*SelectionReader*|*ClipboardHistory*|*GlobalEvent*|*Keychain*|*Appcast*|*Notarization*)
      printf 'forbidden sensitive/release path: %s\n' "$tracked_path" >&2
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

if git grep -n -I -E \
  '(URLSession|AXUIElement|CGEventTap|SecItem(Add|CopyMatching|Delete|Update)|kSecAttr|com\.apple\.security\.network\.client)' \
  -- sources resources Famo.xcodeproj data rime package scripts tools tests ':!scripts/check-public-source.sh'; then
  printf 'forbidden API, entitlement, key material or local path found\n' >&2
  failed=1
fi

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

if git grep -n -I -E '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|/Users/[^/]+/)' \
  -- ':!librime' ':!librime-lua' ':!plum' ':!scripts/check-public-source.sh'; then
  printf 'private key material or absolute home-directory path found\n' >&2
  failed=1
fi

if (( failed != 0 )); then
  exit 1
fi

printf 'public-source boundary check passed\n'
