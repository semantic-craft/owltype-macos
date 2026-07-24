#!/usr/bin/env bash
# Canonical Famo identity manifest + reusable built-app identity-residue scan.
#
# Single source of truth for identity values and forbidden/allowed tokens.
# Sourced by check-identity-residual.sh (runs the scans), check-installed.sh and
# check-release.sh (identity values). Data + one pure function; no side effects.
#
# This file legitimately contains the forbidden literals as scan patterns, so the
# residual scanner excludes it (see check-identity-residual.sh -g globs).

# ---- Canonical Famo identity ----
FAMO_PRODUCT_NAME="Famo Input Method"
FAMO_PRODUCT_NAME_ZH="法墨输入法"
FAMO_BUNDLE_ID="im.famo.inputmethod.Famo"
FAMO_SOURCE_ID_HANS="im.famo.inputmethod.Famo.Hans"
FAMO_SOURCE_ID_HANT="im.famo.inputmethod.Famo.Hant"
FAMO_CONNECTION="Famo_Connection"
FAMO_INSTALL_PATH="/Library/Input Methods/Famo.app"
FAMO_DATA_ROOT="$HOME/Library/Application Support/Famo"
# Icon manifest (Gate 2, check-manifest.sh). CFBundleIconFile is the base name only:
# Xcode strips the .icns suffix at build time, so the built app carries "Famo", not "Famo.icns".
FAMO_ICON_FILE="Famo"
# tsInputModeMenuIconFileKey / tsInputModeAlternateMenuIconFileKey template (kept as-is, .pdf intact).
FAMO_MENU_ICON="FamoMenuIcon.pdf"

# ---- Squirrel coexistence (read-only; Famo never modifies these) ----
# Built with printf so the literal id is present as data without the scanner
# needing a self-exclusion for consumers that only want the value.
SQUIRREL_BUNDLE_ID="$(printf '%s.%s.%s.%s' im rime inputmethod Squirrel)"
SQUIRREL_APP="/Library/Input Methods/Squirrel.app"

# ---- Forbidden identity residue ----
# HARD: residue that would make the system, a user, or support mis-identify Famo
# as Squirrel, or that breaks the ~/Library/Rime data boundary. Never downgraded.
FAMO_FORBIDDEN_HARD=(
  "Squirrel_Connection"
  "im.rime.inputmethod.Squirrel"
  "rime.squirrel"
)
# PRODUCT: product-visible legacy resource/branding names. Warning by default;
# FAMO_IDENTITY_STRICT=1 flips them to fail once the resource-cleanup (W1.2) and
# copy-split (W1.3) child tasks land. That flag is how those tasks prove "clean".
FAMO_FORBIDDEN_PRODUCT=(
  "RimeIcon"
  "rime.pdf"
  "Rime.icns"
  "Rime.appiconset"
)

# famo_scan_app_identity <app_dir>
# Scans a built/installed .app for identity residue in Info.plist text and product
# Resource filenames. Sets FAMO_SCAN_HARD / FAMO_SCAN_PRODUCT to hit counts and
# prints each hit to stderr. Returns 0 always; the caller decides fail vs warn.
#
# Deliberately does NOT scan the Mach-O binary (librime symbols are legitimate
# provenance — binary-strings scanning is a later, warning-only add) nor
# Contents/SharedSupport (rime_ice.* schemas are allowed engine data).
famo_scan_app_identity() {
  local app="$1"
  FAMO_SCAN_HARD=0
  FAMO_SCAN_PRODUCT=0
  if [[ ! -d "$app" ]]; then
    printf 'skip: no app to scan at %s\n' "$app" >&2
    return 0
  fi

  local plist="$app/Contents/Info.plist"
  local plist_text tok hit
  plist_text="$(/usr/bin/plutil -convert xml1 -o - "$plist" 2>/dev/null || /bin/cat "$plist" 2>/dev/null || true)"

  for tok in "${FAMO_FORBIDDEN_HARD[@]}"; do
    if grep -qF "$tok" <<<"$plist_text"; then
      printf 'HARD     Info.plist: %s\n' "$tok" >&2
      FAMO_SCAN_HARD=$((FAMO_SCAN_HARD + 1))
    fi
  done
  for tok in "${FAMO_FORBIDDEN_PRODUCT[@]}"; do
    if grep -qF "$tok" <<<"$plist_text"; then
      printf 'PRODUCT  Info.plist: %s\n' "$tok" >&2
      FAMO_SCAN_PRODUCT=$((FAMO_SCAN_PRODUCT + 1))
    fi
  done

  # Product resource filenames only (SharedSupport engine data is allowlisted).
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    printf 'PRODUCT  resource file: %s\n' "${hit#"$app"/}" >&2
    FAMO_SCAN_PRODUCT=$((FAMO_SCAN_PRODUCT + 1))
  done < <(find "$app/Contents/Resources" \( -iname '*rime*' -o -iname '*squirrel*' \) 2>/dev/null || true)

  return 0
}
