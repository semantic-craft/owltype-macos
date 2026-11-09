#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${OWLTYPE_SEED_CACHE:-/tmp/owltype-rime-seed}"
if [[ -z "${OWLTYPE_SEED_LOCKED:-}" ]]; then
  mkdir -p "$cache_root"
  OWLTYPE_SEED_LOCKED=1 exec /usr/bin/lockf -t 1800 "$cache_root/.owl-seed.lock" bash "$0" "$@"
fi
output_dir="$repo_root/data/owl-rime"
msime_release="$(python3 "$repo_root/scripts/msime_pin.py" get release)"
msime_manifest_sha="$(python3 "$repo_root/scripts/msime_pin.py" get manifest-sha256)"
python_pinyin_license="$repo_root/licenses/python-pinyin.LICENSE"
python_pinyin_license_sha256="1e6c90014b4912815c296ee64bb6f6280af47e6d4c5d80e86232dfc5defe764c"
rime_ice_license="$repo_root/licenses/rime-ice.LICENSE"
rime_ice_license_sha256="3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
rime_ice_credits="$repo_root/licenses/rime-ice-Credits.md"
rime_ice_credits_sha256="3fddb596e5bbd3c9997fbf1d382819632c5ed3d22d58a16bf100e97fe05dae14"
wubi86_license_sha256="43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1"
chinese_ime_lm_license="$repo_root/rust/crates/chinese-ime-lm/LICENSE"
chinese_ime_lm_license_sha256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
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

rm -rf "$output_dir"
mkdir -p "$output_dir/licenses"

for license_spec in "${license_specs[@]}"; do
  read -r license_id license_sha <<<"$license_spec"
  fetch_license "$license_id" "$license_sha"
  cp "$license_cache/$license_id.txt" "$output_dir/licenses/"
done

echo "$chinese_ime_lm_license_sha256  $chinese_ime_lm_license" | shasum -a 256 --check
cp "$chinese_ime_lm_license" "$output_dir/licenses/chinese-ime-lm.LICENSE"
cp "$repo_root/rust/plugins/phrase_table/LICENSE" "$output_dir/licenses/msime-latex-symbols-MIT.txt"
cp "$repo_root/rust/resources/licenses/rime-wanxiang-CC-BY-4.0.txt" "$output_dir/licenses/"

echo "$rime_ice_license_sha256  $rime_ice_license" | shasum -a 256 --check
cp "$rime_ice_license" "$output_dir/rime-ice.LICENSE"
echo "$rime_ice_credits_sha256  $rime_ice_credits" | shasum -a 256 --check
cp "$rime_ice_credits" "$output_dir/rime-ice-Credits.md"
echo "$python_pinyin_license_sha256  $python_pinyin_license" | shasum -a 256 --check
cp "$python_pinyin_license" "$output_dir/python-pinyin.LICENSE"
cp "$repo_root/licenses/rime-kaomoji.LICENSE" "$output_dir/rime-kaomoji.LICENSE"
cp "$license_cache/Apache-2.0.txt" "$output_dir/OpenCC.LICENSE"
echo "$wubi86_license_sha256  $repo_root/licenses/wubi86-jidian.LICENSE" | shasum -a 256 --check
cp "$repo_root/licenses/wubi86-jidian.LICENSE" "$output_dir/wubi86-jidian.LICENSE"
python3 "$repo_root/scripts/fetch-msime-others.py" \
  --output "$output_dir/msime/msime-others.db"
python3 "$repo_root/scripts/fetch-msime-resources.py" --seed "$output_dir"
cp "$repo_root/data/msime-others-NOTICE.txt" "$output_dir/"

cp "$repo_root/licenses/CC-BY-SA-4.0.txt" "$output_dir/licenses/CC-BY-SA-4.0.txt"
cp "$repo_root/data/msime-resources-NOTICE.md" "$output_dir/msime-resources-NOTICE.md"
cp "$repo_root/data/msime-upstream-licensing-NOTICE.md" "$output_dir/msime-upstream-licensing-NOTICE.md"
echo "0bdebfeda07d45dada625ae1317c6f833186e798b171d0db640bcf32e92a8240  $repo_root/licenses/Unlicense.txt" | shasum -a 256 --check
echo "ee820ff0db4ce628569e0975ac27dc926052a9f85d102b101edb104311ef4d90  $repo_root/licenses/Administrative-divisions-of-China-WTFPL.txt" | shasum -a 256 --check
cp "$repo_root/licenses/Unlicense.txt" "$output_dir/licenses/Unlicense.txt"
cp "$repo_root/licenses/Administrative-divisions-of-China-WTFPL.txt" "$output_dir/licenses/Administrative-divisions-of-China-WTFPL.txt"

cat > "$output_dir/OWLTYPE-SEED-SOURCES.md" <<EOF
# Owltype production resource sources

The production Rust engine uses the complete pinned official $msime_release
pinyin, split Wubi86/Wubi98 and English data plus both bigram/trigram scoring sidecars.
All official dictionary files are published unchanged; no Owl Wubi overlay is applied.
See msime-resources-NOTICE.md, msime-upstream-licensing-NOTICE.md,
msime/msime-dictionary-manifest.json and msime/OWLTYPE-UPSTREAM-RESOURCES.json
for sources, byte sizes, digests, adaptations, and redistribution boundaries.
The product's others DB remains the audited four-table emoji/kaomoji derivative.
EOF
cat > "$output_dir/OWLTYPE-SEED-MANIFEST.txt" <<EOF
Owltype production seed
official-resource-set $msime_release
manifest-sha256 $msime_manifest_sha
resource-identities msime/OWLTYPE-UPSTREAM-RESOURCES.json
wubi-resource msime/msime-wubi.db; upstream identity in resource-identities
wubi86-license $wubi86_license_sha256 wubi86-jidian.LICENSE
others-policy audited-emoji-kaomoji-four-tables; full upstream auxiliary artifact retained in build cache
model-policy separately pinned; defaults unchanged
EOF

echo "[owltype-seed] assembled official pinned production resources at $output_dir"
