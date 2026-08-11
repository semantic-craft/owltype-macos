#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/famo-identity.sh
. "$ROOT/scripts/famo-identity.sh"

fail=0

# The scan scripts legitimately carry forbidden literals as patterns/fixtures.
SELF_EXCLUDE=(-g '!scripts/check-identity-residual.sh' -g '!scripts/famo-identity.sh' \
              -g '!scripts/check-identity-residual.selftest.sh')

check_absent() {
  local label="$1"
  local pattern="$2"
  shift 2
  if rg -n --fixed-strings "${SELF_EXCLUDE[@]}" "$pattern" "$@"; then
    printf 'FAIL: %s\n' "$label" >&2
    fail=1
  fi
}

# Consumes FAMO_SCAN_HARD / FAMO_SCAN_PRODUCT (set by famo_scan_app_identity) for the
# just-scanned layer <label>: hard residue always fails; product residue warns unless
# FAMO_IDENTITY_STRICT=1 (then it fails too).
report_app_scan() {
  local label="$1"
  if (( FAMO_SCAN_HARD > 0 )); then
    printf 'FAIL: %d hard identity residue in %s\n' "$FAMO_SCAN_HARD" "$label" >&2
    fail=1
  fi
  if (( FAMO_SCAN_PRODUCT > 0 )); then
    if [[ "${FAMO_IDENTITY_STRICT:-0}" == "1" ]]; then
      printf 'FAIL: %d product identity residue in %s (strict)\n' "$FAMO_SCAN_PRODUCT" "$label" >&2
      fail=1
    else
      printf 'WARN: %d product identity residue in %s (non-strict; W1.2/W1.3 will clean)\n' "$FAMO_SCAN_PRODUCT" "$label"
    fi
  fi
}

check_absent "legacy librime app name" "rime.squirrel" sources resources Famo.xcodeproj package scripts Makefile data
check_absent "legacy IMK connection" "Squirrel_Connection" sources resources Famo.xcodeproj package scripts Makefile
check_absent "legacy input-source id" "im.rime.inputmethod.Squirrel" sources resources Famo.xcodeproj package scripts Makefile
check_absent "legacy reload notification" "SquirrelReloadNotification" sources resources Famo.xcodeproj package scripts Makefile
check_absent "legacy sync notification" "SquirrelSyncNotification" sources resources Famo.xcodeproj package scripts Makefile
check_absent "legacy ASCII notification" "SquirrelToggleASCIIModeNotification" sources resources Famo.xcodeproj package scripts Makefile
check_absent "legacy ASCII notification" "SquirrelGetASCIIModeNotification" sources resources Famo.xcodeproj package scripts Makefile
check_absent "legacy ASCII notification" "SquirrelASCIIModeResponse" sources resources Famo.xcodeproj package scripts Makefile
check_absent "legacy ASCII notification" "SquirrelSetASCIIModeNotification" sources resources Famo.xcodeproj package scripts Makefile
check_absent "legacy ASCII notification" "SquirrelReportASCIIModeNotification" sources resources Famo.xcodeproj package scripts Makefile

# ponytail: comment/attribution mentions are allowed; this strips Swift line comments
# before looking for old runtime type references.
swift_code_without_comments=$(
  sed 's,//.*,,' sources/*.swift
)
if grep -En 'Squirrel(InputController|ApplicationDelegate|Panel|Theme|View|Config|App|Installer|Keycode)' <<<"$swift_code_without_comments"; then
  printf 'FAIL: legacy Squirrel Swift runtime type reference\n' >&2
  fail=1
fi

# --- Product-visible legacy tokens in source (RimeIcon / rime.pdf / Rime.icns /
# Rime.appiconset). Not caught by the hard checks above; warns until the resource
# (W1.2) and copy (W1.3) tasks land, then FAMO_IDENTITY_STRICT=1 makes it fail. ---
product_rg=()
for tok in "${FAMO_FORBIDDEN_PRODUCT[@]}"; do product_rg+=(-e "$tok"); done
product_hits=$(rg -n --fixed-strings "${SELF_EXCLUDE[@]}" "${product_rg[@]}" \
  sources resources Assets.xcassets Famo.xcodeproj package Makefile 2>/dev/null || true)
if [[ -n "$product_hits" ]]; then
  if [[ "${FAMO_IDENTITY_STRICT:-0}" == "1" ]]; then
    printf '%s\n' "$product_hits" >&2
    printf 'FAIL: product identity residue in source (strict)\n' >&2
    fail=1
  else
    printf 'WARN: product identity residue in source (non-strict; W1.2/W1.3 will clean):\n'
    printf '%s\n' "$product_hits"
  fi
fi

# --- Product-doc copy (W1.3): README's first screen must not re-frame Famo as a
# Squirrel derivative. Everything from the "来源与许可 · Source & Licenses" heading
# down is legal/provenance copy and is allowed, as are PROVENANCE.md /
# THIRD_PARTY_NOTICES.md (not scanned here). Warns by default; strict flips to fail. ---
if [[ -f README.md ]]; then
  readme_product=$(awk '/^## .*(来源与许可|Source & Licenses)/{exit} {print}' README.md)
  copy_hits=$(grep -nE 'Squirrel|鼠须管|派生' <<<"$readme_product" || true)
  if [[ -n "$copy_hits" ]]; then
    if [[ "${FAMO_IDENTITY_STRICT:-0}" == "1" ]]; then
      printf '%s\n' "$copy_hits" >&2
      printf 'FAIL: Squirrel framing in README product copy (strict)\n' >&2
      fail=1
    else
      printf 'WARN: Squirrel framing in README product copy (non-strict):\n'
      printf '%s\n' "$copy_hits"
    fi
  fi
fi

# --- Uninstaller whitelist audit (B2): uninstall-famo.sh ships standalone in the DMG and
# cannot source this manifest at runtime, so its hardcoded delete-whitelist must stay pinned
# to the canonical identity. Assert the identity tokens + the Squirrel/Rime safety gate are
# all present, so the whitelist can never silently drift off-identity (a delete path is a
# safety-critical surface). ---
uninstaller="scripts/uninstall-famo.sh"
if [[ -f "$uninstaller" ]]; then
  audit_missing=()
  grep -qF "$FAMO_BUNDLE_ID" "$uninstaller"        || audit_missing+=("bundle id $FAMO_BUNDLE_ID")
  grep -qF "$FAMO_INSTALL_PATH" "$uninstaller"      || audit_missing+=("install path $FAMO_INSTALL_PATH")
  grep -qF "Application Support/Famo" "$uninstaller" || audit_missing+=("data root Application Support/Famo")
  grep -qE 'forbidden=.*Library/Rime' "$uninstaller" || audit_missing+=("Squirrel/Rime safety gate")
  if (( ${#audit_missing[@]} )); then
    printf 'FAIL: uninstaller whitelist drifted off identity manifest: %s\n' "${audit_missing[*]}" >&2
    fail=1
  else
    printf 'PASS: uninstaller whitelist matches identity manifest\n'
  fi
fi

# --- Built/installed app residue: source can be clean while shipped bytes are not. ---
# ponytail: famo_scan_app_identity scans Info.plist text + product Resource filenames, not the
# Mach-O binary. A `strings -a` binary scan is deferred (warning-only, later): librime links
# thousands of legitimate rime_* symbols, so it needs a heavy allowlist to not drown in noise.
app_to_scan="${FAMO_APP:-}"
if [[ -z "$app_to_scan" ]]; then
  for cand in "build/Build/Products/Release/Famo.app" "$FAMO_INSTALL_PATH" "$HOME/Library/Input Methods/Famo.app"; do
    if [[ -d "$cand" ]]; then app_to_scan="$cand"; break; fi
  done
fi
if [[ -n "$app_to_scan" ]]; then
  printf '== scanning built app: %s ==\n' "$app_to_scan"
  famo_scan_app_identity "$app_to_scan"
  report_app_scan "built app"
else
  printf 'note: no built app found to scan (source-only run)\n'
fi

# --- DMG installer app (layer 3): FamoInstaller.app is a separate GUI app with its own
# identity surface (Info.plist + Resources). The embedded Famo.app lives under
# Contents/Library, which famo_scan_app_identity does not walk, so it is only counted
# once (as the built-app layer). Scan the unmounted build product — no DMG mount needed. ---
installer_app="${FAMO_INSTALLER_APP:-installer/build/Build/Products/Release/FamoInstaller.app}"
if [[ -d "$installer_app" ]]; then
  printf '== scanning DMG installer app: %s ==\n' "$installer_app"
  famo_scan_app_identity "$installer_app"
  report_app_scan "FamoInstaller.app"
else
  printf 'note: no FamoInstaller.app found to scan (%s)\n' "$installer_app"
fi

# --- Consolidated cleanup for the pkg-expand tmp dir and any mounted DMG. Registered once;
# the pkg (4a) and dmg (4b) layers write their artifacts into these vars so a single EXIT trap
# tears everything down even if set -e aborts mid-scan — no leaked mounts or tmp dirs. ---
_pkg_tmp=""
_dmg_mnt=""
cleanup() {
  if [[ -n "$_pkg_tmp" ]]; then rm -rf "$_pkg_tmp"; fi
  if [[ -n "$_dmg_mnt" ]]; then hdiutil detach "$_dmg_mnt" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# --- pkg payload (layer 4a): expand the package and scan the payload app's real content
# (Info.plist text + product Resource filenames) via famo_scan_app_identity — not just payload
# filenames. §7 Gate 1 wants each of the four layers independently at 0 hard residue; the pkg
# payload is a cp of the built app, but scanning it directly makes the pkg layer self-standing
# instead of inheriting the built-app pass. Expand path matches check-release.sh.
# ponytail: no separate payload-filename Squirrel guard — check-release.sh already asserts
# SharedSupport carries no squirrel.* config names at release time; not worth duplicating. ---
pkg="${FAMO_PKG:-package/Famo.pkg}"
if [[ -f "$pkg" ]]; then
  printf '== scanning pkg payload content: %s ==\n' "$pkg"
  # pkgutil --expand-full refuses a pre-existing target, so use an uncreated `mktemp -u` name.
  _pkg_tmp="$(mktemp -u /tmp/famo-pkg-scan.XXXXXX)"
  if pkgutil --expand-full "$pkg" "$_pkg_tmp" >/dev/null 2>&1; then
    pkg_app="$_pkg_tmp/Famo-component.pkg/Payload/Famo.app"
    if [[ -d "$pkg_app" ]]; then
      famo_scan_app_identity "$pkg_app"
      report_app_scan "pkg payload"
    else
      printf 'note: pkg expanded but no payload app at Famo-component.pkg/Payload/Famo.app\n' >&2
    fi
  else
    printf 'note: pkgutil --expand-full failed for %s\n' "$pkg" >&2
  fi
  rm -rf "$_pkg_tmp"; _pkg_tmp=""
else
  printf 'note: no pkg found to scan (%s)\n' "$pkg"
fi

# --- DMG (layer 4b): scan the assembled installer DMG as a whole. Mount read-only, run the
# full identity scan on the FamoInstaller.app inside it, and hard-token-scan ONLY the two loose
# files (卸载法墨.command / uninstall-famo.sh). Those two legitimately carry [Ss]quirrel /
# /Library/Rime / im.rime safety-gate copy but no hard literal, so a product/word scan would
# false-positive the safety gate — hard-only is the correct depth. Detach via the EXIT trap. ---
dmg="${FAMO_DMG:-}"
if [[ -z "$dmg" ]]; then
  if [[ "${FAMO_IDENTITY_STRICT:-0}" == "1" ]]; then
    printf 'FAIL: FAMO_DMG must name the cohort-bound versioned DMG in strict mode\n' >&2
    fail=1
  else
    printf 'note: no cohort-bound DMG configured for identity scan\n'
  fi
elif [[ -f "$dmg" ]]; then
  printf '== scanning DMG: %s ==\n' "$dmg"
  _dmg_mnt="$(hdiutil attach -readonly -nobrowse -noverify "$dmg" 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"
  if [[ -n "$_dmg_mnt" && -d "$_dmg_mnt" ]]; then
    if [[ -d "$_dmg_mnt/FamoInstaller.app" ]]; then
      famo_scan_app_identity "$_dmg_mnt/FamoInstaller.app"
      report_app_scan "DMG FamoInstaller.app"
    else
      printf 'note: DMG has no FamoInstaller.app at its root\n'
    fi
    dmg_hard=0
    for loose in "卸载法墨.command" "uninstall-famo.sh"; do
      loose_path="${_dmg_mnt}/${loose}"
      [[ -f "$loose_path" ]] || continue
      for tok in "${FAMO_FORBIDDEN_HARD[@]}"; do
        if grep -qF "$tok" "$loose_path"; then
          printf 'HARD     DMG loose %s: %s\n' "$loose" "$tok" >&2
          dmg_hard=$((dmg_hard + 1))
        fi
      done
    done
    if (( dmg_hard > 0 )); then
      printf 'FAIL: %d hard identity residue in DMG loose files\n' "$dmg_hard" >&2
      fail=1
    fi
    hdiutil detach "$_dmg_mnt" >/dev/null 2>&1 || true
    _dmg_mnt=""
  else
    printf 'note: could not mount DMG %s\n' "$dmg" >&2
    _dmg_mnt=""
  fi
else
  printf 'note: no DMG found to scan (%s)\n' "$dmg"
fi

if (( fail )); then
  exit 1
fi

printf 'PASS: Famo identity residual gate\n'
