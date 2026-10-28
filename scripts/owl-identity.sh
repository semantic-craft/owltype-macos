#!/usr/bin/env bash
# Canonical Owltype identity manifest + reusable built-app identity-residue scan.
#
# Single source of truth for identity values and forbidden/allowed tokens.
# Sourced by check-identity-residual.sh (runs the scans), check-installed.sh and
# check-release.sh (identity values). Data + one pure function; no side effects.
#
# This file legitimately contains the forbidden literals as scan patterns, so the
# residual scanner excludes it (see check-identity-residual.sh -g globs).

# ---- Canonical Owltype identity (docs/rename-owltype-plan.md §0) ----
OWL_PRODUCT_NAME="Owltype Input Method"
OWL_PRODUCT_NAME_ZH="猫头鹰输入法"
OWL_BUNDLE_ID="im.owltype.inputmethod.Owltype"
OWL_SOURCE_ID_HANS="im.owltype.inputmethod.Owltype.Hans"
OWL_SOURCE_ID_HANT="im.owltype.inputmethod.Owltype.Hant"
OWL_CONNECTION="Owltype_Connection"
OWL_INSTALL_PATH="/Library/Input Methods/Owltype.app"
OWL_DATA_ROOT="$HOME/Library/Application Support/Owltype"
# Icon manifest (Gate 2, check-manifest.sh). CFBundleIconFile is the base name only:
# Xcode strips the .icns suffix at build time, so the built app carries "Owltype", not "Owltype.icns".
OWL_ICON_FILE="Owltype"
# tsInputModeMenuIconFileKey / tsInputModeAlternateMenuIconFileKey template (kept as-is, .pdf intact).
OWL_MENU_ICON="OwlMenuIcon.pdf"

# ---- Squirrel coexistence (read-only; Owltype never modifies these) ----
# Built with printf so the literal id is present as data without the scanner
# needing a self-exclusion for consumers that only want the value.
SQUIRREL_BUNDLE_ID="$(printf '%s.%s.%s.%s' im rime inputmethod Squirrel)"
SQUIRREL_APP="/Library/Input Methods/Squirrel.app"

# ---- Forbidden identity residue ----
# HARD: the product's former self (Famo / 法墨, renamed in 2.0.0), forbidden at every
# layer and never downgraded to a warning. A bundle still carrying these ids resolves as
# the wrong input source, and an uninstaller still keyed to them deletes the wrong tree.
# Mentioning them is residue too: after 2.0.0 nothing in the tree has any reason to.
OWL_FORBIDDEN_HARD=(
  "im.famo.inputmethod.Famo"
  "Famo_Connection"
  "/Library/Input Methods/Famo.app"
  "Application Support/Famo"
)
# CLAIM: Squirrel's ids, which Owltype must never claim — its frontend descends from Squirrel
# and has to coexist with an installed Squirrel, not displace it. A live guarantee, unrelated
# to the rename, so it outlives it.
#
# Enforced on shipped artifacts only (Info.plist, resource filenames, DMG loose files),
# because claiming an id is something a built bundle does, not something source text does.
# Source legitimately *names* Squirrel: PROVENANCE.md documents the coexistence, and the
# activation tests assert Owltype classifies Squirrel as foreign. A fixed-string source
# scan cannot tell "claims" from "mentions", and the version that failed on mentions was
# telling us to delete the very tests that prove the guarantee holds. The positive check
# is what actually pins the built identity: check-manifest.sh asserts CFBundleIdentifier /
# InputMethodConnectionName / TISInputSourceID equal the canonical Owltype values above.
OWL_FORBIDDEN_CLAIM=(
  "Squirrel_Connection"
  "im.rime.inputmethod.Squirrel"
  "rime.squirrel"
)
# PRODUCT: the old brand as a user reads it. Matched case-insensitively, so these two
# tokens cover Famo / famo / FAMO_ / Famotype / famotype. Warning by default;
# OWL_IDENTITY_STRICT=1 flips them to fail. That flag is how the rename batches
# (plan §2.2–§2.4) prove "clean", and §2.5 requires it green before the merge to main.
OWL_FORBIDDEN_PRODUCT=(
  "famo"
  "法墨"
)

# owl_scan_app_identity <app_dir>
# Scans a built/installed .app for identity residue in Info.plist text, exact hard
# identities embedded in its main executable, and product Resource filenames.
# Sets OWL_SCAN_HARD / OWL_SCAN_PRODUCT to hit counts and
# prints each hit to stderr. Returns 0 always; the caller decides fail vs warn.
#
# The executable scan is deliberately limited to OWL_FORBIDDEN_HARD. Generic brand
# fragments and Squirrel provenance symbols are legitimate provenance and would create
# false positives. Contents/SharedSupport is likewise engine data, not product identity.
owl_scan_app_identity() {
  local app="$1"
  OWL_SCAN_HARD=0
  OWL_SCAN_PRODUCT=0
  if [[ ! -d "$app" ]]; then
    printf 'skip: no app to scan at %s\n' "$app" >&2
    return 0
  fi

  local plist="$app/Contents/Info.plist"
  local plist_text tok hit
  plist_text="$(/usr/bin/plutil -convert xml1 -o - "$plist" 2>/dev/null || /bin/cat "$plist" 2>/dev/null || true)"

  for tok in "${OWL_FORBIDDEN_HARD[@]}" "${OWL_FORBIDDEN_CLAIM[@]}"; do
    if grep -qF "$tok" <<<"$plist_text"; then
      printf 'HARD     Info.plist: %s\n' "$tok" >&2
      OWL_SCAN_HARD=$((OWL_SCAN_HARD + 1))
    fi
  done
  for tok in "${OWL_FORBIDDEN_PRODUCT[@]}"; do
    if grep -qiF "$tok" <<<"$plist_text"; then
      printf 'PRODUCT  Info.plist: %s\n' "$tok" >&2
      OWL_SCAN_PRODUCT=$((OWL_SCAN_PRODUCT + 1))
    fi
  done

  local executable_name executable_path executable_strings
  executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null || true)"
  [[ -n "$executable_name" ]] || executable_name="Owltype"
  executable_path="$app/Contents/MacOS/$executable_name"
  if [[ -f "$executable_path" ]]; then
    executable_strings="$(/usr/bin/strings -a "$executable_path" 2>/dev/null || true)"
    for tok in "${OWL_FORBIDDEN_HARD[@]}"; do
      if grep -qF "$tok" <<<"$executable_strings"; then
        printf 'HARD     executable: %s\n' "$tok" >&2
        OWL_SCAN_HARD=$((OWL_SCAN_HARD + 1))
      fi
    done
  fi

  # Product resource filenames only (SharedSupport engine data is allowlisted).
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    printf 'PRODUCT  resource file: %s\n' "${hit#"$app"/}" >&2
    OWL_SCAN_PRODUCT=$((OWL_SCAN_PRODUCT + 1))
  done < <(find "$app/Contents/Resources" \( -iname '*famo*' -o -iname '*squirrel*' \) 2>/dev/null || true)

  return 0
}
