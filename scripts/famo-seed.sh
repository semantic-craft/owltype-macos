#!/usr/bin/env bash
#
# Build the self-contained Rime data used by the open-source local core.
# Every network input is pinned. Wubi and octagram data are intentionally absent
# until their provenance and redistribution bundle pass the repository license gate.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${FAMOTYPE_SEED_CACHE:-/tmp/famotype-rime-seed}"
source_dir="$cache_root/rime-ice"
essay_dir="$cache_root/rime-essay"
output_dir="$repo_root/data/famo-rime"
rime_ice_remote="https://github.com/iDvel/rime-ice.git"
rime_ice_sha="b681a34f788795034b3b288830f4861980bc8b0d"
rime_essay_remote="https://github.com/rime/rime-essay.git"
rime_essay_sha="e9b1a374a6ea015fca5bdd04318924b4483ac35a"
unihan_version="16.0.0"
unihan_remote="https://www.unicode.org/Public/$unihan_version/ucd/Unihan.zip"
unihan_sha="b8f000df69de7828d21326a2ffea462b04bc7560022989f7cc704f10521ef3e0"
unihan_archive="$cache_root/Unihan-$unihan_version.zip"
spdx_license_tag="v3.28.0"
license_cache="$cache_root/spdx-license-list-$spdx_license_tag"
license_specs=(
  "Apache-2.0 074e6e32c86a4c0ef8b3ed25b721ca23aca83df277cd88106ef7177c354615ff"
  "BSD-3-Clause 5a93d5831e1297ab10fe643e1a631e83be392896da14ee2951285a79012df69d"
  "CC-BY-3.0 e6bc9e9c474700b708f568bac9e5a8a9bcb2b1dad53442f5ba449fcb848b8e76"
  "GPL-3.0-only fb981668c18a279e285fc4d83fba1e836cc84dd4daa73c9697d3cfd2d8aca6e0"
  "LGPL-3.0-only 996af0513df21f7496288951c41428a03c174e9e4a9d63665c57d670f845ccb1"
  "MIT b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5"
  "Unicode-3.0 f7db81051789b729fea528a63ec4c938fdcb93d9d61d97dc8cc2e9df6d47f2a1"
)

fetch_license() {
  local license_id="$1"
  local expected_sha="$2"
  local target="$license_cache/$license_id.txt"
  mkdir -p "$license_cache"
  if [[ ! -f "$target" ]] || ! echo "$expected_sha  $target" | shasum -a 256 --check --status; then
    curl --fail --location \
      "https://raw.githubusercontent.com/spdx/license-list-data/$spdx_license_tag/text/$license_id.txt" \
      --output "$target"
  fi
  echo "$expected_sha  $target" | shasum -a 256 --check
}

if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$cache_root"
  git init "$source_dir"
  git -C "$source_dir" remote add origin "$rime_ice_remote"
fi

git -C "$source_dir" fetch --depth 1 origin "$rime_ice_sha"
git -C "$source_dir" checkout --detach "$rime_ice_sha"

if [[ ! -d "$essay_dir/.git" ]]; then
  git init "$essay_dir"
  git -C "$essay_dir" remote add origin "$rime_essay_remote"
fi
git -C "$essay_dir" fetch --depth 1 origin "$rime_essay_sha"
git -C "$essay_dir" checkout --detach "$rime_essay_sha"

if [[ ! -f "$unihan_archive" ]] || ! echo "$unihan_sha  $unihan_archive" | shasum -a 256 --check --status; then
  curl --fail --location "$unihan_remote" --output "$unihan_archive"
fi
echo "$unihan_sha  $unihan_archive" | shasum -a 256 --check

rm -rf "$output_dir"
mkdir -p "$output_dir/_user_seed" "$output_dir/cn_dicts" "$output_dir/licenses"

for license_spec in "${license_specs[@]}"; do
  read -r license_id license_sha <<<"$license_spec"
  fetch_license "$license_id" "$license_sha"
  cp "$license_cache/$license_id.txt" "$output_dir/licenses/"
done

cp -R \
  "$source_dir/lua" \
  "$source_dir/opencc" \
  "$output_dir/"
sed \
  -e '/^[[:space:]]*- melt_eng[[:space:]]/d' \
  -e '/^[[:space:]]*- radical_pinyin[[:space:]]/d' \
  -e '/affix_segmentor@radical_lookup/d' \
  -e '/table_translator@melt_eng/d' \
  -e '/table_translator@cn_en/d' \
  -e '/table_translator@radical_lookup/d' \
  -e '/reverse_lookup_filter@radical_reverse_lookup/d' \
  -e '/lua_filter@\*search@radical_pinyin/d' \
  "$source_dir/rime_ice.schema.yaml" > "$output_dir/rime_ice.schema.yaml"
cp "$repo_root/data/rime_ice.public.dict.yaml" "$output_dir/rime_ice.dict.yaml"
python3 "$repo_root/scripts/unihan-to-rime.py" \
  "$unihan_archive" "$output_dir/cn_dicts/famotype_unicode.dict.yaml"
cp "$essay_dir/essay.txt" "$output_dir/essay.txt"
cp "$source_dir/default.yaml" "$output_dir/"
cp \
  "$source_dir"/symbols_v.yaml \
  "$source_dir"/symbols_caps_v.yaml \
  "$source_dir"/custom_phrase.txt \
  "$output_dir/" 2>/dev/null || true

if compgen -G "$repo_root/data/opencc/*" >/dev/null; then
  cp "$repo_root"/data/opencc/* "$output_dir/opencc/"
fi

cp "$source_dir/LICENSE" "$output_dir/rime-ice.LICENSE"
cp "$source_dir/others/docs/Credits.md" "$output_dir/rime-ice-Credits.md"
cp "$essay_dir/LICENSE" "$output_dir/rime-essay.LICENSE"
cp "$essay_dir/AUTHORS" "$output_dir/rime-essay.AUTHORS"
cp "$repo_root/librime/LICENSE" "$output_dir/librime.LICENSE"
cp "$repo_root/librime-lua/LICENSE" "$output_dir/librime-lua.LICENSE"
cp "$repo_root/plum/LICENSE" "$output_dir/plum.LICENSE"
cp "$repo_root/librime/deps/opencc/LICENSE" "$output_dir/OpenCC.LICENSE"
cp "$repo_root/data/famo.yaml" "$output_dir/famo.yaml"
cp "$repo_root/rime/"*.custom.yaml "$output_dir/_user_seed/"

cat > "$output_dir/FAMOTYPE-SEED-SOURCES.md" <<EOF
# Famotype public seed source map

The Chinese dictionary in this seed has exactly two data inputs:

- \`cn_dicts/famotype_unicode.dict.yaml\` is generated from Unicode $unihan_version
  \`Unihan_Readings.txt\` field \`kMandarin\` under Unicode-3.0.
- \`essay.txt\` is the preset vocabulary from rime-essay revision
  \`$rime_essay_sha\` under LGPL-3.0-only.

The rime-ice schemas, Lua helpers, OpenCC tables, symbols, and configuration are
from revision \`$rime_ice_sha\` under GPL-3.0-only with its retained Credits.

No rime-ice \`cn_dicts\` or \`en_dicts\` file is distributed. In particular,
the upstream 8105, base, ext, 41448, Tencent, and miscellaneous dictionaries are
excluded rather than relying on an unverified or mixed-source license chain.
EOF

{
  echo "Famotype local-core Rime seed"
  echo "rime-ice $rime_ice_sha"
  echo "source $rime_ice_remote"
  echo "rime-essay $rime_essay_sha"
  echo "source $rime_essay_remote"
  echo "unicode-unihan $unihan_version $unihan_sha"
  echo "source $unihan_remote"
  echo "license-texts SPDX license-list-data $spdx_license_tag"
  echo "dictionary inputs limited to Unicode Unihan kMandarin and rime-essay"
  echo "rime-ice cn_dicts and en_dicts omitted after provenance review"
  echo "wubi omitted pending provenance review"
  echo "octagram data omitted from the local-core seed"
} > "$output_dir/FAMOTYPE-SEED-MANIFEST.txt"

echo "[famotype-seed] assembled pinned rime-ice seed at $output_dir"
