#!/usr/bin/env bash
# Gate 2 — Manifest consistency. Asserts the built/installed Famo.app Info.plist
# identity fields equal the canonical constants in famo-identity.sh, so a stray
# rename (connection name, source id, icon) can never ship silently.
#
# Read-only. Resolves an app the same way check-identity-residual.sh does; if none
# is present it notes and skips (source trees carry unresolved $(VAR) placeholders,
# so this gate is inherently a built-app gate — release.sh runs it after `make release-artifacts`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/famo-identity.sh
. "$ROOT/scripts/famo-identity.sh"

APP="${FAMO_APP:-}"
if [[ -z "$APP" ]]; then
  for cand in "$ROOT/build/Build/Products/Release/Famo.app" "$FAMO_INSTALL_PATH" "$HOME/Library/Input Methods/Famo.app"; do
    if [[ -d "$cand" ]]; then APP="$cand"; break; fi
  done
fi
if [[ -z "$APP" || ! -d "$APP" ]]; then
  printf 'note: no built/installed Famo.app to check; skipping manifest gate\n'
  exit 0
fi

PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || { printf 'FAIL: %s has no Info.plist\n' "$APP" >&2; exit 1; }
printf '== manifest gate: %s ==\n' "$APP"

fail=0
plb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

assert_eq() {
  local label="$1" key="$2" expected="$3"
  local actual; actual="$(plb "$key")"
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS: %s = %s\n' "$label" "$actual"
  else
    printf 'FAIL: %s = %q (expected %q)\n' "$label" "$actual" "$expected" >&2
    fail=1
  fi
}

C='ComponentInputModeDict:tsInputModeListKey'

assert_eq "CFBundleIdentifier"        "CFBundleIdentifier"        "$FAMO_BUNDLE_ID"
assert_eq "InputMethodConnectionName" "InputMethodConnectionName" "$FAMO_CONNECTION"
assert_eq "TISInputSourceID"          "TISInputSourceID"          "$FAMO_BUNDLE_ID"

# CFBundleIconFile: normalize away a trailing .icns (Xcode stores the base name in
# built apps, the source plist keeps the extension) before comparing.
icon_actual="$(plb CFBundleIconFile)"; icon_actual="${icon_actual%.icns}"
if [[ "$icon_actual" == "$FAMO_ICON_FILE" ]]; then
  printf 'PASS: CFBundleIconFile = %s\n' "$icon_actual"
else
  printf 'FAIL: CFBundleIconFile = %q (expected %q)\n' "$icon_actual" "$FAMO_ICON_FILE" >&2
  fail=1
fi

assert_eq "Hans TISInputSourceID" "$C:$FAMO_SOURCE_ID_HANS:TISInputSourceID" "$FAMO_SOURCE_ID_HANS"
assert_eq "Hant TISInputSourceID" "$C:$FAMO_SOURCE_ID_HANT:TISInputSourceID" "$FAMO_SOURCE_ID_HANT"

for mode in "$FAMO_SOURCE_ID_HANS" "$FAMO_SOURCE_ID_HANT"; do
  assert_eq "$mode menuIcon"    "$C:$mode:tsInputModeMenuIconFileKey"          "$FAMO_MENU_ICON"
  assert_eq "$mode altMenuIcon" "$C:$mode:tsInputModeAlternateMenuIconFileKey" "$FAMO_MENU_ICON"
done

if (( fail )); then
  printf 'FAIL: Famo manifest consistency gate\n' >&2
  exit 1
fi
printf 'PASS: Famo manifest consistency gate\n'
