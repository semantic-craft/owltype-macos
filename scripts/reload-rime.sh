#!/usr/bin/env bash
# reload-rime.sh — trigger a Rime redeploy on the installed 法墨输入法 (Famo).
set -euo pipefail

APP="$HOME/Library/Input Methods/Famo.app"
EXE="$APP/Contents/MacOS/Famo"

if [[ ! -x "$EXE" ]]; then
  echo "ERROR: Famo executable not found: $EXE"
  echo "Build and install first: scripts/install-dev.sh"
  exit 1
fi

"$EXE" --reload
echo "RIME reload requested. Watch logs (scripts/tail-log.sh) for deployment errors."
echo "After reload, the 深大红 candidate skin (famo.custom.yaml) should be visible."
