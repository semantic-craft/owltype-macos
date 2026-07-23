#!/usr/bin/env bash

set -euo pipefail

rime_version="1.17.0"
rime_git_hash="33e7814"

rime_archive="rime-${rime_git_hash}-macOS-universal.tar.bz2"
rime_archive_sha256="11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850"
rime_download_url="https://github.com/rime/librime/releases/download/${rime_version}/${rime_archive}"

rime_deps_archive="rime-deps-${rime_git_hash}-macOS-universal.tar.bz2"
rime_deps_archive_sha256="dfe6047e87be271963d7466bd1a6e3d9e660c30e5e73e4bb94e8782c0a6ac8df"
rime_deps_download_url="https://github.com/rime/librime/releases/download/${rime_version}/${rime_deps_archive}"

plum_packages=(
  "bopomofo 6085c9a38a4a728047862b33d67eee18aa86f3b9"
  "cangjie 52d90a1b1312e74042b38c1cbc8142defbc53171"
  "essay e9b1a374a6ea015fca5bdd04318924b4483ac35a"
  "luna-pinyin 56b934b099dfbeab842320f13aa8b461a6ab3e42"
  "prelude 082425ea0684bca36474415d4a0e8db9b016487e"
  "quick 5dcdb9e353d314239e9c8cddc0f42d52da4837bb"
  "stroke 3a4b0f4013e2b4c14b1e80c92b1d4723eb65f39c"
  "terra-pinyin 8a2c895ad7ee8e2b137d91be77f18f86b04d7fc9"
)

download_archive() {
  local url="$1"
  local output="$2"
  if [[ "${FAMOTYPE_NO_DOWNLOAD:-0}" == "1" ]]; then
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

ensure_rpath() {
  local executable="$1"
  if ! otool -l "$executable" | grep -Fq '@loader_path/../Frameworks'; then
    xcrun install_name_tool -add_rpath '@loader_path/../Frameworks' "$executable"
  fi
}

rm -rf lib/rime-plugins data/opencc data/plum
mkdir -p download bin lib/rime-plugins data/opencc data/plum
download_archive "$rime_download_url" "download/${rime_archive}"
download_archive "$rime_deps_download_url" "download/${rime_deps_archive}"
verify_archive "$rime_archive_sha256" "download/${rime_archive}"
verify_archive "$rime_deps_archive_sha256" "download/${rime_deps_archive}"

tar --bzip2 -xf "download/${rime_archive}" -C download
tar --bzip2 -xf "download/${rime_deps_archive}" -C download

cp -L download/dist/lib/librime.1.dylib lib/
cp -L download/dist/lib/rime-plugins/librime-lua.dylib lib/rime-plugins/
cp download/dist/bin/rime_deployer bin/
cp download/dist/bin/rime_dict_manager bin/
ensure_rpath bin/rime_deployer
ensure_rpath bin/rime_dict_manager

cp -R download/share/opencc/. data/opencc/

git submodule update --init --recursive librime librime-lua plum

for package_spec in "${plum_packages[@]}"; do
  read -r package_name package_sha <<<"$package_spec"
  package_dir="plum/package/rime/$package_name"
  if [[ ! -d "$package_dir/.git" ]]; then
    mkdir -p "$package_dir"
    git -C "$package_dir" init
    git -C "$package_dir" remote add origin "https://github.com/rime/rime-${package_name}.git"
  fi
  [[ -z "$(git -C "$package_dir" status --porcelain)" ]] || {
    echo "dirty pinned plum package checkout: $package_dir" >&2
    exit 1
  }
  git -C "$package_dir" fetch --depth 1 origin "$package_sha"
  git -C "$package_dir" checkout --detach "$package_sha"
  [[ "$(git -C "$package_dir" rev-parse HEAD)" == "$package_sha" ]]
  (
    cd plum
    no_update=1 bash scripts/install-packages.sh \
      "${package_name}@${package_sha}" ../data/plum
  )
done

cp plum/rime-install bin/

echo "Famotype build dependencies are ready."
