#!/usr/bin/env bash
# Self-test for the pkg (4a) / dmg (4b) layers of check-identity-residual.sh.
# Builds throwaway poisoned artifacts and asserts the gate FAILS on injected hard residue and
# PASSES with no artifacts present. Real on-disk artifacts are left untouched — every run points
# FAMO_APP/FAMO_INSTALLER_APP/FAMO_PKG/FAMO_DMG at nonexistent paths, overriding per-case.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-identity-residual.sh"
work="$(mktemp -d /tmp/famo-idselftest.XXXXXX)"
trap 'rm -rf "$work"' EXIT

pass=0 ; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

# Run the gate with all real artifacts overridden away; caller args add/override env (last wins).
run_gate() {
  env FAMO_APP=/nonexistent FAMO_INSTALLER_APP=/nonexistent \
      FAMO_PKG=/nonexistent FAMO_DMG=/nonexistent "$@" \
      bash "$GATE" >/dev/null 2>&1
}

# --- positive: no artifacts present → gate passes (new pkg/dmg code adds no false positive) ---
if run_gate; then ok "positive: source-only run passes"; else bad "positive: source-only run should exit 0"; fi

# --- negative A: pkg payload plist carries a HARD token → gate must fail (even non-strict) ---
mkdir -p "$work/pkgroot/Famo.app/Contents"
cat > "$work/pkgroot/Famo.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>im.famo.inputmethod.Famo</string>
  <key>FamoSelfTestPoison</key><string>Squirrel_Connection</string>
</dict></plist>
PLIST
pkgbuild --root "$work/pkgroot" --identifier im.famo.inputmethod.Famo \
  --install-location "/Library/Input Methods" --version 0.0 "$work/Famo-component.pkg" >/dev/null 2>&1
productbuild --synthesize --package "$work/Famo-component.pkg" "$work/dist.xml" >/dev/null 2>&1
productbuild --distribution "$work/dist.xml" --package-path "$work" "$work/poison.pkg" >/dev/null 2>&1
if run_gate FAMO_PKG="$work/poison.pkg"; then
  bad "negative A: poison pkg (Squirrel_Connection in payload plist) should fail the gate"
else
  ok "negative A: poison pkg (Squirrel_Connection in payload plist) fails the gate"
fi

# --- negative B: DMG loose file carries a HARD token → gate must fail ---
mkdir -p "$work/dmgroot"
printf '#!/bin/sh\n# %s\n' "im.rime.inputmethod.Squirrel" > "$work/dmgroot/uninstall-famo.sh"
hdiutil create -volname FamoSelfTest -srcfolder "$work/dmgroot" -ov -format UDZO "$work/poison.dmg" >/dev/null 2>&1
if run_gate FAMO_DMG="$work/poison.dmg"; then
  bad "negative B: poison DMG loose file (im.rime.inputmethod.Squirrel) should fail the gate"
else
  ok "negative B: poison DMG loose file (im.rime.inputmethod.Squirrel) fails the gate"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
