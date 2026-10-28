#!/usr/bin/env bash

set -euo pipefail

sparkle_version="2.6.2"

sparkle_archive="Sparkle-${sparkle_version}.tar.xz"
sparkle_archive_sha256="2300a7dc2545a4968e54621b7f351d388ddf1a5cb49e79f6c99e9a09d826f5e8"
sparkle_download_url="https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/${sparkle_archive}"

download_archive() {
  local url="$1"
  local output="$2"
  if [[ "${OWLTYPE_NO_DOWNLOAD:-0}" == "1" ]]; then
    [[ -f "$output" ]] || { echo "missing cached archive: $output" >&2; exit 1; }
  else
    curl --fail --location --output "$output" "$url"
  fi
}

verify_archive() {
  local expected="$1"
  local file="$2"
  echo "${expected}  ${file}" | shasum -a 256 --check
}

rm -rf data/opencc Frameworks
mkdir -p download Frameworks
download_archive "$sparkle_download_url" "download/${sparkle_archive}"
verify_archive "$sparkle_archive_sha256" "download/${sparkle_archive}"

tar -xJf "download/${sparkle_archive}" -C download

git submodule update --init --recursive Sparkle
python3 scripts/build-sparkle.py

echo "Owltype build dependencies are ready."
