#!/usr/bin/env bash
# Authoritative local release chain. It never publishes, tags, or mutates a remote release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/scripts/release-cohort-state.py"
dry_run=0
output_root="$ROOT/build"

usage() {
  printf 'usage: %s [--dry-run] [--output-root PATH]\n' "${0##*/}" >&2
  exit 64
}

while (($#)); do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --output-root)
      (($# >= 2)) || usage
      output_root="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

mkdir_command() {
  local rendered
  printf -v rendered ' %q' "$@"
  printf 'DRY-RUN:%s\n' "$rendered"
}

run() {
  if ((dry_run)); then
    mkdir_command "$@"
  else
    "$@"
  fi
}

if [[ "$output_root" != /* ]]; then
  output_root="$ROOT/$output_root"
fi
app="$output_root/Build/Products/Release/Owltype.app"
release_dir="$output_root/release"
cohort_file="$release_dir/OWLTYPE-RELEASE-COHORT.json"
dev_id="${DEV_ID:-}"
notary_profile="${NOTARY_PROFILE:-xw-notary}"

run python3 "$STATE" revoke-publish "$output_root"

if ((!dry_run)) && [[ -z "$dev_id" ]]; then
  echo >&2 "ERROR: set DEV_ID to the Developer ID common name"
  exit 1
fi
if ((dry_run)) && [[ -z "$dev_id" ]]; then
  dev_id='<Developer ID common name>'
fi

cd "$ROOT"

echo "==> 1/8 validate clean source, signing, and notarization readiness"
if ((dry_run)); then
  mkdir_command git status --porcelain --untracked-files=all
  mkdir_command security find-identity -v -p codesigning
  mkdir_command security find-identity -v
  mkdir_command xcrun notarytool history --keychain-profile "$notary_profile"
else
  if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo >&2 "ERROR: release requires a clean worktree at the exact cohort revision"
    exit 1
  fi
  security find-identity -v -p codesigning 2>/dev/null |
    grep -q "Developer ID Application: ${dev_id}" || {
      echo >&2 "ERROR: Developer ID Application identity is unavailable"
      exit 1
    }
  security find-identity -v 2>/dev/null |
    grep -q "Developer ID Installer: ${dev_id}" || {
      echo >&2 "ERROR: Developer ID Installer identity is unavailable"
      exit 1
    }
  xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 || {
    echo >&2 "ERROR: NOTARY_PROFILE points to an unavailable notarytool keychain profile"
    exit 1
  }
fi

reuse=0
if ((!dry_run)) && [[ -e "$cohort_file" ]]; then
  echo "==> existing cohort state found; verify it instead of building again"
  python3 "$STATE" verify-chain "$output_root"
  reuse=1
fi

echo "==> 2/8 run the full test suite"
run make test "DERIVED_DATA_PATH=$output_root/tests"

echo "==> 3/8 assemble exactly one signed, notarized, stapled artifact cohort"
if ((reuse)); then
  echo "REUSE: complete current cohort; release build and composition remain unchanged"
else
  run make owl-seed
  run make release-artifacts \
    "DEV_ID=$dev_id" \
    "NOTARY_PROFILE=$notary_profile" \
    "RELEASE_OUTPUT_ROOT=$output_root"
fi

echo "==> 4/8 create and bind corresponding source"
if ((reuse)); then
  echo "REUSE: source archive already belongs to the current cohort"
else
  run bash "$ROOT/scripts/create-source-archive.sh" "$output_root"
fi

echo "==> 5/8 verify the complete cohort contract"
run python3 "$STATE" verify-chain "$output_root"

if ((dry_run)); then
  dmg='<cohort versioned DMG>'
  pkg='<cohort installer pkg>'
  published_assets=(
    '<cohort Owltype.pkg>'
    '<cohort Owltype-update.pkg>'
    '<cohort Owltype-version.dmg>'
    '<cohort appcast.xml>'
    '<cohort source.tar.gz>'
    '<cohort source.tar.gz.sha256>'
    '<cohort OWLTYPE-FILE-MANIFEST.sha256>'
    '<cohort OWLTYPE-SBOM.spdx.json>'
    '<cohort OWLTYPE-APP-PROVENANCE.txt>'
    '<cohort OWLTYPE-RELEASE-COHORT.json>'
  )
else
  dmg="$(python3 "$STATE" artifact-path "$output_root" dmg)"
  pkg="$(python3 "$STATE" artifact-path "$output_root" installer-pkg)"
  asset_list_file="$(mktemp "${TMPDIR:-/tmp}/owl-published-assets.XXXXXX")"
  if ! bash "$ROOT/scripts/check-published-release.sh" --print0 \
      "$output_root" >"$asset_list_file"; then
    rm -f "$asset_list_file"
    exit 1
  fi
  published_assets=()
  while IFS= read -r -d '' asset; do
    published_assets+=("$asset")
  done <"$asset_list_file"
  rm -f "$asset_list_file"
  [[ "${#published_assets[@]}" -eq 10 ]] || {
    echo >&2 "ERROR: centralized artifact policy did not return ten published assets"
    exit 1
  }
fi

echo "==> 6/8 run release and identity gates"
run env OWL_IDENTITY_STRICT=1 "OWL_APP=$app" "OWL_PKG=$pkg" "OWL_DMG=$dmg" \
  bash "$ROOT/scripts/check-identity-residual.sh"
run env "OWL_APP=$app" bash "$ROOT/scripts/check-manifest.sh"
run env "RELEASE_OUTPUT_ROOT=$output_root" \
  bash "$ROOT/scripts/check-release.sh" --automated-only

echo "==> 7/8 run privacy and centralized secret gates"
run python3 "$STATE" verify-chain "$output_root"
run bash "$ROOT/scripts/check-public-source.sh"
run bash "$ROOT/scripts/check-public-privacy.selftest.sh"
run bash "$ROOT/scripts/check-secrets.sh"
run bash "$ROOT/scripts/check-secrets.sh" --artifacts \
  "$app" \
  "${published_assets[@]}"

echo "==> 8/8 verify the local publishing contract without publishing"
run bash "$ROOT/scripts/check-published-release.sh" --dry-run "$output_root"
run env OWL_RELEASE_AUTHORIZATION_DRIVER=release.sh:8/8 \
  python3 "$STATE" authorize-publish "$output_root"

if ((dry_run)); then
  printf 'DRY-RUN: complete release order rendered; no step was executed\n'
else
  printf 'PASS: one release cohort completed every local gate and is authorized for publishing; no remote state was changed\n'
fi
