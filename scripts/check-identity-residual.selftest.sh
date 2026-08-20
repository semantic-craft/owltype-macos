#!/usr/bin/env bash
# Self-test for the artifact layers of check-identity-residual.sh — the built app (3), pkg
# payload (4a) and dmg (4b). Builds throwaway artifacts poisoned with the old 法墨/Famo
# identity and asserts the gate FAILS on them, PASSES with no artifacts present, and that
# the hard/product tier split and the strict flag behave as documented.
#
# It drives `--artifacts` on purpose. The source layer scans this working tree, so its
# verdict is whatever the rename has reached so far; the artifact layers are fixture-driven
# and therefore the part that can be pinned. Real on-disk artifacts are left untouched —
# every run points OWL_APP/OWL_INSTALLER_APP/OWL_PKG/OWL_DMG at nonexistent paths,
# overriding per-case.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-identity-residual.sh"
work="$(mktemp -d /tmp/owl-idselftest.XXXXXX)"
trap 'rm -rf "$work"' EXIT

pass=0 ; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

# Run the gate's artifact layers with all real artifacts overridden away; caller args
# add/override env (last wins). Output is captured so a case can assert WHY the gate
# failed: with four layers each able to fail, an exit code alone lets one layer's
# complaint stand in for the one under test.
gate_out=""
run_gate() {
  local status=0
  gate_out="$(env OWL_APP=/nonexistent OWL_INSTALLER_APP=/nonexistent \
      OWL_PKG=/nonexistent OWL_DMG=/nonexistent "$@" \
      bash "$GATE" --artifacts 2>&1)" || status=$?
  return "$status"
}

# expect_fail <label> <expected substring in the gate's own output>
expect_fail() {
  local label="$1" reason="$2"
  if grep -qF "$reason" <<<"$gate_out"; then
    ok "$label"
  else
    bad "$label — failed, but not over \"$reason\": $(head -3 <<<"$gate_out" | tr '\n' '|')"
  fi
}

# write_app <dir> <identifier> [extra-plist-entry]
write_app() {
  local dir="$1" identifier="$2" extra="${3:-}"
  mkdir -p "$dir/Contents"
  cat > "$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${identifier}</string>
  ${extra}
</dict></plist>
PLIST
}

write_app "$work/clean-app/Owltype.app" "im.owltype.inputmethod.Owltype"
write_app "$work/poison-app/Owltype.app" "im.famo.inputmethod.Famo"
write_app "$work/brand-app/Owltype.app" "im.owltype.inputmethod.Owltype" \
  '<key>CFBundleName</key><string>法墨输入法</string>'

# --- positive: no artifacts present → artifact layers pass (no false positive) ---
if run_gate; then ok "positive: no artifacts present passes"; else bad "positive: no-artifact run should exit 0"; fi

# --- negative A: built app carries the old bundle id → fails even non-strict ---
if run_gate OWL_APP="$work/poison-app/Owltype.app"; then
  bad "negative A: built app with the old bundle id should fail the gate"
else
  expect_fail "negative A: built app with the old bundle id fails the gate" \
    "hard identity residue in built app"
fi

# --- tier split: brand-only residue (no hard id) warns, and OWL_IDENTITY_STRICT=1 fails it.
# That flag is what §2.5 gates the merge on, so both directions are pinned. ---
if run_gate OWL_APP="$work/brand-app/Owltype.app"; then
  ok "tier split: brand-only residue warns in non-strict mode"
else
  bad "tier split: brand-only residue should not fail the gate in non-strict mode"
fi
if run_gate OWL_IDENTITY_STRICT=1 OWL_APP="$work/brand-app/Owltype.app"; then
  bad "tier split: brand-only residue should fail under OWL_IDENTITY_STRICT=1"
else
  expect_fail "tier split: brand-only residue fails under OWL_IDENTITY_STRICT=1" \
    "product identity residue in built app (strict)"
fi

# --- strict demands every layer was actually looked at: a layer with nothing to scan reads
# exactly like a clean one, which is how a renamed artifact would slip through §7 Gate 1. ---
if run_gate OWL_IDENTITY_STRICT=1; then
  bad "strict: a missing built app should fail the gate"
else
  expect_fail "strict: a missing built app fails the gate" \
    "OWL_APP must name the built app in strict mode"
fi
if run_gate OWL_IDENTITY_STRICT=1 OWL_APP="$work/clean-app/Owltype.app"; then
  bad "strict: a missing pkg should fail the gate"
else
  expect_fail "strict: a missing pkg fails the gate" \
    "OWL_PKG must name the built installer pkg in strict mode"
fi

# --- negative B: pkg payload plist carries a HARD token → fails even non-strict ---
mkdir -p "$work/pkgroot"
cp -R "$work/poison-app/Owltype.app" "$work/pkgroot/Owltype.app"
pkgbuild --root "$work/pkgroot" --identifier im.owltype.inputmethod.Owltype \
  --install-location "/Library/Input Methods" --version 0.0 "$work/Owltype-component.pkg" >/dev/null 2>&1
productbuild --synthesize --package "$work/Owltype-component.pkg" "$work/dist.xml" >/dev/null 2>&1
productbuild --distribution "$work/dist.xml" --package-path "$work" "$work/poison.pkg" >/dev/null 2>&1
if run_gate OWL_PKG="$work/poison.pkg"; then
  bad "negative B: poison pkg (old bundle id in payload plist) should fail the gate"
else
  expect_fail "negative B: poison pkg (old bundle id in payload plist) fails the gate" \
    "hard identity residue in pkg payload"
fi

# --- negative C: DMG loose file carries a HARD token → gate must fail ---
mkdir -p "$work/dmgroot"
printf '#!/bin/sh\n# %s\n' "Famo_Connection" > "$work/dmgroot/uninstall-owltype.sh"
hdiutil create -volname OwltypeSelfTest -srcfolder "$work/dmgroot" -ov -format UDZO "$work/poison.dmg" >/dev/null 2>&1
if run_gate OWL_DMG="$work/poison.dmg"; then
  bad "negative C: poison DMG loose file (Famo_Connection) should fail the gate"
else
  expect_fail "negative C: poison DMG loose file (Famo_Connection) fails the gate" \
    "hard identity residue in DMG loose files"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
