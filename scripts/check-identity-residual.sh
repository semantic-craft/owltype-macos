#!/usr/bin/env bash
# Identity residual gate. Since 2.0.0 (法墨/Famo → 猫头鹰/Owltype) this is the machine
# acceptance check for that rename: it drives the old brand's residue to zero across the
# repository and every shipped layer (docs/rename-owltype-plan.md §2.1 and §2.5).
#
#   scripts/check-identity-residual.sh              # repository source + every artifact layer
#   scripts/check-identity-residual.sh --source     # repository source only
#   scripts/check-identity-residual.sh --artifacts  # built app / installer app / pkg / dmg only
#
# OWL_IDENTITY_STRICT=1 turns product-tier residue from a warning into a failure.
# OWL_APP / OWL_INSTALLER_APP / OWL_PKG / OWL_DMG name the artifacts to scan.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/owl-identity.sh
. "$ROOT/scripts/owl-identity.sh"

layer="all"
case "${1:-}" in
  "")          ;;
  --source)    layer="source" ;;
  --artifacts) layer="artifacts" ;;
  *) printf 'usage: scripts/check-identity-residual.sh [--source|--artifacts]\n' >&2; exit 2 ;;
esac

fail=0

# The scan scripts legitimately carry the forbidden literals as patterns and fixtures.
# check-public-privacy.sh and its self-test are the same category for a different gate: the
# retired private repositories really are named after the old brand, and that gate exists to
# keep those exact names out of the public tree. Rewriting the literals there would silently
# disarm it, so they stay verbatim and this gate looks away.
# CHANGELOG keeps its historical entries verbatim, and the two plan documents are the
# record of the 法墨 era, deliberately left as written (plan §2.5; the same whitelist is
# fixed in .scratch/rename-owltype/EXECUTION.md §3). The submodules are upstream vendor
# trees — not this product's identity surface and not ours to rewrite. .claude/ is local
# agent state (settings, throwaway worktrees), whose stale paths are the repo-rename
# ticket's business, not this gate's.
#
# --hidden is not optional: .gitignore, .periphery.yml and .github/ carry identity
# strings, and ripgrep skips dotfiles by default — a scan without it reads clean while
# the release artifact patterns still name the old product.
SCAN_EXCLUDE=(
  --hidden
  -g '!.git/**'
  -g '!.claude/**'
  -g '!.scratch/**'
  -g '!scripts/check-identity-residual.sh'
  -g '!scripts/check-identity-residual.selftest.sh'
  -g '!scripts/owl-identity.sh'
  -g '!scripts/check-public-privacy.sh'
  -g '!scripts/check-public-privacy.selftest.sh'
  -g '!CHANGELOG.md'
  -g '!docs/rename-owltype-plan.md'
  -g '!docs/default-input-method-plan.md'
  -g '!librime/**'
  -g '!librime-lua/**'
  -g '!plum/**'
  -g '!Sparkle/**'
)

# Per-file hit counts for one tier's tokens, worst file first. Counting rather than
# listing every line is what keeps a mid-rename run readable: while the batches land the
# residue is five figures, and the file list IS the remaining work (plan §2.2–§2.4).
count_by_file() {
  rg --count-matches --no-messages "${SCAN_EXCLUDE[@]}" "$@" . 2>/dev/null \
    | sed 's|^\./||' | sort -t: -k2 -rn || true
}

tier_files() { grep -c . <<<"$1"; }
tier_hits()  { awk -F: '{ total += $NF } END { print total + 0 }' <<<"$1"; }
# Capped at 20 rows so one tier cannot bury the other, with the remainder stated —
# a silent truncation would read as "nearly clean".
tier_rows() {
  local counts="$1" shown=20 total
  total="$(tier_files "$counts")"
  head -n "$shown" <<<"$counts" | sed 's/^/    /'
  if (( total > shown )); then
    printf '    … and %d more file(s)\n' "$((total - shown))"
  fi
}

scan_source() {
  local tok hard_args=() product_args=() counts summary
  for tok in "${OWL_FORBIDDEN_HARD[@]}";    do hard_args+=(-e "$tok"); done
  for tok in "${OWL_FORBIDDEN_PRODUCT[@]}"; do product_args+=(-e "$tok"); done

  counts="$(count_by_file --fixed-strings "${hard_args[@]}")"
  if [[ -n "$counts" ]]; then
    printf 'FAIL: hard identity residue in source: %s hit(s) in %s file(s)\n' \
      "$(tier_hits "$counts")" "$(tier_files "$counts")" >&2
    tier_rows "$counts" >&2
    fail=1
  fi

  counts="$(count_by_file --fixed-strings --ignore-case "${product_args[@]}")"
  if [[ -n "$counts" ]]; then
    summary="$(printf 'product identity residue in source: %s hit(s) in %s file(s)' \
      "$(tier_hits "$counts")" "$(tier_files "$counts")")"
    if [[ "${OWL_IDENTITY_STRICT:-0}" == "1" ]]; then
      printf 'FAIL: %s (strict)\n' "$summary" >&2
      tier_rows "$counts" >&2
      fail=1
    else
      printf 'WARN: %s (non-strict; the rename batches are what clear it)\n' "$summary"
      tier_rows "$counts"
    fi
  fi
}

# Consumes OWL_SCAN_HARD / OWL_SCAN_PRODUCT (set by owl_scan_app_identity) for the
# just-scanned layer <label>: hard residue always fails; product residue warns unless
# OWL_IDENTITY_STRICT=1 (then it fails too).
report_app_scan() {
  local label="$1"
  if (( OWL_SCAN_HARD > 0 )); then
    printf 'FAIL: %d hard identity residue in %s\n' "$OWL_SCAN_HARD" "$label" >&2
    fail=1
  fi
  if (( OWL_SCAN_PRODUCT > 0 )); then
    if [[ "${OWL_IDENTITY_STRICT:-0}" == "1" ]]; then
      printf 'FAIL: %d product identity residue in %s (strict)\n' "$OWL_SCAN_PRODUCT" "$label" >&2
      fail=1
    else
      printf 'WARN: %d product identity residue in %s (non-strict)\n' "$OWL_SCAN_PRODUCT" "$label"
    fi
  fi
}

if [[ "$layer" != "artifacts" ]]; then
  scan_source

  # --- Uninstaller whitelist audit (B2): uninstall-owltype.sh ships standalone in the DMG and
  # cannot source this manifest at runtime, so its hardcoded delete-whitelist must stay pinned
  # to the canonical identity. Assert the identity tokens + the Squirrel/Rime safety gate are
  # all present, so the whitelist can never silently drift off-identity (a delete path is a
  # safety-critical surface). ---
  uninstaller="scripts/uninstall-owltype.sh"
  if [[ -f "$uninstaller" ]]; then
    audit_missing=()
    grep -qF "$OWL_BUNDLE_ID" "$uninstaller"             || audit_missing+=("bundle id $OWL_BUNDLE_ID")
    grep -qF "$OWL_INSTALL_PATH" "$uninstaller"          || audit_missing+=("install path $OWL_INSTALL_PATH")
    grep -qF "Application Support/Owltype" "$uninstaller" || audit_missing+=("data root Application Support/Owltype")
    grep -qE 'forbidden=.*Library/Rime' "$uninstaller"    || audit_missing+=("Squirrel/Rime safety gate")
    if (( ${#audit_missing[@]} )); then
      printf 'FAIL: uninstaller whitelist drifted off identity manifest: %s\n' "${audit_missing[*]}" >&2
      fail=1
    else
      printf 'PASS: uninstaller whitelist matches identity manifest\n'
    fi
  else
    printf 'note: no uninstaller at %s to audit\n' "$uninstaller"
  fi
fi

# Artifact layers, kept at the file's own indentation under the layer switch: this block is
# what --artifacts selects and --source skips.
if [[ "$layer" != "source" ]]; then

# --- Built/installed app residue: source can be clean while shipped bytes are not. ---
# ponytail: owl_scan_app_identity scans Info.plist text + product Resource filenames, not the
# Mach-O binary. A `strings -a` binary scan is deferred (warning-only, later): librime links
# thousands of legitimate rime_* symbols, so it needs a heavy allowlist to not drown in noise.
app_to_scan="${OWL_APP:-}"
if [[ -z "$app_to_scan" ]]; then
  for cand in "build/Build/Products/Release/Owltype.app" "$OWL_INSTALL_PATH" "$HOME/Library/Input Methods/Owltype.app"; do
    if [[ -d "$cand" ]]; then app_to_scan="$cand"; break; fi
  done
fi
# -d, not -n: an OWL_APP pointing at a path that does not exist would otherwise take the
# scan branch, find nothing, and report the layer clean.
if [[ -d "$app_to_scan" ]]; then
  printf '== scanning built app: %s ==\n' "$app_to_scan"
  owl_scan_app_identity "$app_to_scan"
  report_app_scan "built app"
elif [[ "${OWL_IDENTITY_STRICT:-0}" == "1" ]]; then
  # Strict mode is the release/merge gate (§2.5, §7 Gate 1): every layer must actually have
  # been scanned. A layer that quietly finds nothing to look at reads exactly like a clean
  # one, which is the failure mode this gate exists to prevent.
  printf 'FAIL: OWL_APP must name the built app in strict mode\n' >&2
  fail=1
else
  printf 'note: no built app found to scan (source-only run)\n'
fi

# --- DMG installer app (layer 3): OwltypeInstaller.app is a separate GUI app with its own
# identity surface (Info.plist + Resources). The embedded Owltype.app lives under
# Contents/Library, which owl_scan_app_identity does not walk, so it is only counted
# once (as the built-app layer). Scan the unmounted build product — no DMG mount needed. ---
installer_app="${OWL_INSTALLER_APP:-installer/build/Build/Products/Release/OwltypeInstaller.app}"
if [[ -d "$installer_app" ]]; then
  printf '== scanning DMG installer app: %s ==\n' "$installer_app"
  owl_scan_app_identity "$installer_app"
  report_app_scan "OwltypeInstaller.app"
else
  printf 'note: no OwltypeInstaller.app found to scan (%s)\n' "$installer_app"
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
# (Info.plist text + product Resource filenames) via owl_scan_app_identity — not just payload
# filenames. §7 Gate 1 wants each of the four layers independently at 0 hard residue; the pkg
# payload is a cp of the built app, but scanning it directly makes the pkg layer self-standing
# instead of inheriting the built-app pass. Expand path matches check-release.sh.
# ponytail: no separate payload-filename Squirrel guard — check-release.sh already asserts
# SharedSupport carries no squirrel.* config names at release time; not worth duplicating. ---
pkg="${OWL_PKG:-package/Owltype.pkg}"
if [[ -f "$pkg" ]]; then
  printf '== scanning pkg payload content: %s ==\n' "$pkg"
  # pkgutil --expand-full refuses a pre-existing target, so use an uncreated `mktemp -u` name.
  _pkg_tmp="$(mktemp -u /tmp/owl-pkg-scan.XXXXXX)"
  if pkgutil --expand-full "$pkg" "$_pkg_tmp" >/dev/null 2>&1; then
    pkg_app="$_pkg_tmp/Owltype-component.pkg/Payload/Owltype.app"
    if [[ -d "$pkg_app" ]]; then
      owl_scan_app_identity "$pkg_app"
      report_app_scan "pkg payload"
    else
      pkg_unscanned="pkg expanded but no payload app at Owltype-component.pkg/Payload/Owltype.app"
    fi
  else
    pkg_unscanned="pkgutil --expand-full failed for $pkg"
  fi
  rm -rf "$_pkg_tmp"; _pkg_tmp=""
  # An expand path that drifted (component pkg renamed, payload moved) leaves this layer
  # unscanned while everything above it still says PASS. Strict mode refuses that.
  if [[ -n "${pkg_unscanned:-}" ]]; then
    if [[ "${OWL_IDENTITY_STRICT:-0}" == "1" ]]; then
      printf 'FAIL: %s (strict)\n' "$pkg_unscanned" >&2
      fail=1
    else
      printf 'note: %s\n' "$pkg_unscanned" >&2
    fi
  fi
elif [[ "${OWL_IDENTITY_STRICT:-0}" == "1" ]]; then
  printf 'FAIL: OWL_PKG must name the built installer pkg in strict mode\n' >&2
  fail=1
else
  printf 'note: no pkg found to scan (%s)\n' "$pkg"
fi

# --- DMG (layer 4b): scan the assembled installer DMG as a whole. Mount read-only, run the
# full identity scan on the OwltypeInstaller.app inside it, and hard-token-scan ONLY the two
# loose files (卸载猫头鹰.command / uninstall-owltype.sh). Those two legitimately carry
# [Ss]quirrel / /Library/Rime / im.rime safety-gate copy but no hard literal, so a
# product/word scan would false-positive the safety gate — hard-only is the correct depth.
# Detach via the EXIT trap. ---
dmg="${OWL_DMG:-}"
if [[ ! -f "$dmg" ]]; then
  if [[ "${OWL_IDENTITY_STRICT:-0}" == "1" ]]; then
    printf 'FAIL: OWL_DMG must name the cohort-bound versioned DMG in strict mode\n' >&2
    fail=1
  else
    printf 'note: no cohort-bound DMG configured for identity scan (%s)\n' "${dmg:-unset}"
  fi
else
  printf '== scanning DMG: %s ==\n' "$dmg"
  _dmg_mnt="$(hdiutil attach -readonly -nobrowse -noverify "$dmg" 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"
  if [[ -n "$_dmg_mnt" && -d "$_dmg_mnt" ]]; then
    if [[ -d "$_dmg_mnt/OwltypeInstaller.app" ]]; then
      owl_scan_app_identity "$_dmg_mnt/OwltypeInstaller.app"
      report_app_scan "DMG OwltypeInstaller.app"
    else
      printf 'note: DMG has no OwltypeInstaller.app at its root\n'
    fi
    dmg_hard=0
    for loose in "卸载猫头鹰.command" "uninstall-owltype.sh"; do
      loose_path="${_dmg_mnt}/${loose}"
      [[ -f "$loose_path" ]] || continue
      for tok in "${OWL_FORBIDDEN_HARD[@]}"; do
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
    _dmg_mnt=""
    # Same silent-skip rule as the pkg layer: an unmountable DMG leaves this layer unscanned.
    if [[ "${OWL_IDENTITY_STRICT:-0}" == "1" ]]; then
      printf 'FAIL: could not mount DMG %s (strict)\n' "$dmg" >&2
      fail=1
    else
      printf 'note: could not mount DMG %s\n' "$dmg" >&2
    fi
  fi
fi

fi  # end artifact layers

if (( fail )); then
  exit 1
fi

printf 'PASS: Owltype identity residual gate\n'
