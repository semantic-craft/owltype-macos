#!/usr/bin/env bash
# reload-rime.sh — trigger a Rime redeploy on the installed 猫头鹰输入法 (Owltype).
set -euo pipefail

APP="$HOME/Library/Input Methods/Owltype.app"
EXE="$APP/Contents/MacOS/Owltype"

if [[ ! -x "$EXE" ]]; then
  echo "ERROR: Owltype executable not found: $EXE"
  echo "Build and install first: scripts/install-dev.sh"
  exit 1
fi

"$EXE" --reload
echo "RIME reload requested. Watch logs (scripts/tail-log.sh) for deployment errors."
echo "After reload, the 深大红 candidate skin (owltype.custom.yaml) should be visible."
