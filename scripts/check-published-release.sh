#!/usr/bin/env bash
# Local publishing-contract gate. It validates and enumerates assets but never touches a remote.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/scripts/release-cohort-state.py"
dry_run=0

if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
  shift
fi
output_root="${1:?usage: check-published-release.sh [--dry-run] /path/to/release-output-root}"
(($# == 1)) || {
  echo >&2 "usage: check-published-release.sh [--dry-run] /path/to/release-output-root"
  exit 64
}

python3 "$STATE" verify-chain "$output_root"
installer_pkg="$(python3 "$STATE" artifact-path "$output_root" installer-pkg)"
update_pkg="$(python3 "$STATE" artifact-path "$output_root" update-pkg)"
dmg="$(python3 "$STATE" artifact-path "$output_root" dmg)"
appcast="$(python3 "$STATE" output-path "$output_root" appcast)"
source_archive="$(python3 "$STATE" output-path "$output_root" source-archive)"
release_dir="$(cd "$output_root/release" && pwd -P)"

assets=(
  "$installer_pkg"
  "$update_pkg"
  "$dmg"
  "$appcast"
  "$source_archive"
  "$source_archive.sha256"
  "$release_dir/FAMOTYPE-FILE-MANIFEST.sha256"
  "$release_dir/FAMOTYPE-SBOM.spdx.json"
  "$release_dir/FAMOTYPE-APP-PROVENANCE.txt"
  "$release_dir/FAMOTYPE-RELEASE-COHORT.json"
)

for asset in "${assets[@]}"; do
  [[ -s "$asset" ]] || {
    echo >&2 "FAIL: publishing contract asset is missing or empty: $asset"
    exit 1
  }
  if ((dry_run)); then
    printf 'WOULD_PUBLISH: %s\n' "$asset"
  else
    printf 'PUBLISHABLE: %s\n' "$asset"
  fi
done

printf 'PASS: local publishing contract contains %d cohort-verified assets; nothing was published\n' \
  "${#assets[@]}"
