#!/usr/bin/env bash
# verify-rime-config.sh — 法墨输入法 (Famo) RIME 配置预检
# READ-ONLY. Never modifies the user's ~/Library/Rime or Squirrel install. Only reports + suggests.
set -euo pipefail

FAMO_USER_DIR="$HOME/Library/Application Support/Famo"
FAMO_SHARED_DIR="$HOME/Library/Input Methods/Famo.app/Contents/SharedSupport"

echo "Checking Famo user directory: $FAMO_USER_DIR"

if [[ ! -d "$FAMO_USER_DIR" ]]; then
  echo "MISSING: $FAMO_USER_DIR"
  echo "Install and launch Famo first; this script will not create or modify user data."
  exit 1
fi

missing=0

check_file() {
  local file="$1"
  if [[ -f "$FAMO_USER_DIR/$file" ]]; then
    echo "OK: $file"
  else
    echo "MISSING: $file"
    missing=1
  fi
}

# Famo frontend skin + user-level schema selection
check_file "famo.custom.yaml"
check_file "default.custom.yaml"
check_file "rime_ice.custom.yaml"

if [[ ! -d "$FAMO_SHARED_DIR" ]]; then
  echo "MISSING: $FAMO_SHARED_DIR"
  missing=1
fi

check_shared_file() {
  local file="$1"
  if [[ -f "$FAMO_SHARED_DIR/$file" ]]; then
    echo "OK: SharedSupport/$file"
  else
    echo "MISSING: SharedSupport/$file"
    missing=1
  fi
}

check_shared_file "famo.yaml"
check_shared_file "wubi86_jidian.schema.yaml"

# 雾凇全拼（rime_ice，rime-ice 底座）
if [[ -f "$FAMO_SHARED_DIR/rime_ice.schema.yaml" ]]; then
  echo "OK: rime_ice.schema.yaml"
else
  echo "MISSING: rime_ice.schema.yaml"
  missing=1
fi

echo
echo "Schema list references (Famo default.custom.yaml):"
grep -R "rime_ice\|wubi86_jidian" \
  "$FAMO_USER_DIR/default.custom.yaml" \
  2>/dev/null || echo "  (no rime_ice / wubi86_jidian references found)"

if [[ "$missing" -ne 0 ]]; then
  echo
  echo "Some files are missing. This script does NOT modify user config."
  echo "Suggested Famo default.custom.yaml patch (apply manually, after backup):"
  cat <<'YAML'
patch:
  schema_list:
    - {schema: rime_ice}
    - {schema: wubi86_jidian}
YAML
  exit 1
fi

echo
echo "RIME config preflight passed."
