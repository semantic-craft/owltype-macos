#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="${1:-}"

[[ -n "$output_root" ]] || {
  echo "usage: $0 /path/to/release-output-root" >&2
  exit 1
}
[[ -d "$output_root" ]] || {
  echo "缺少构建输出根目录: $output_root（从干净输出根重跑 scripts/release.sh）" >&2
  exit 1
}
output_root="$(cd "$output_root" && pwd -P)"
app="$output_root/Build/Products/Release/Owltype.app"
output_dir="$output_root/release"
[[ -f "$app/Contents/Info.plist" ]] || {
  echo "缺少已构建的 Owltype.app: ${app}（从干净输出根重跑 scripts/release.sh）" >&2
  exit 1
}

# provenance 里的 app-manifest 必须指向**出厂那份 app** 的盘点，也就是 notarized-app 在签名 +
# 公证 + staple 之后写出来的这份。曾经它指向 bundle 内那份 finalize 期清单，而 make source-archive
# 会重跑 finalize、在 staple 之后再写一次 —— 于是源码包记的哈希在任何出厂产物里都找不到。
app_manifest="$output_dir/OWLTYPE-FILE-MANIFEST.sha256"
[[ -f "$app_manifest" ]] || {
  # 变量名必须加花括号：紧跟其后的是全角括号，裸 $app_manifest 会把它的首字节吃进变量名。
  echo "缺少出厂盘点 ${app_manifest}（从干净输出根重跑 scripts/release.sh）" >&2
  exit 1
}

# 「盘点存在」不等于「盘点描述的就是这份源码构建出来的 app」：DerivedData 跨 commit 存活，
# 而本脚本要求洁净工作区，若操作者在 cohort build 后、源码归档前另行提交，就会让
# HEAD 走了。不验的话，就是拿今天的源码配昨天的二进制，正是本次改动要消灭的那类错位。
# cohort check 复核 HEAD、版本、输出根、盘点与 bundle 全部属于同一构建。
python3 "$repo_root/scripts/inventory-release-bundle.py" check "$output_root"
cohort_id="$(python3 "$repo_root/scripts/release-cohort-state.py" id "$output_root")"
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]] || {
  echo "source archive requires a clean worktree" >&2
  exit 1
}

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
build_version="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
revision="$(git -C "$repo_root" rev-parse HEAD)"
archive_root="Owltype-macOS-$version-source"
archive_name="$archive_root.tar.gz"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$output_dir"
python3 "$repo_root/scripts/release_source.py" stage \
  "$repo_root" "$revision" "$stage/$archive_root"
mkdir -p "$stage/$archive_root/data/owl-rime"
rsync -a "$app/Contents/SharedSupport/." "$stage/$archive_root/data/owl-rime/"

read -r source_tree seed_tree < <(python3 - "$output_dir/OWLTYPE-RELEASE-COHORT.json" <<'PY'
import json
import sys

cohort = json.load(open(sys.argv[1]))
print(cohort["sourceSha256"], cohort["seedSha256"])
PY
)

{
  echo "Owltype source release $version"
  echo "build-version $build_version"
  echo "root $revision"
  echo "cohort $cohort_id"
  echo "source-tree $source_tree"
  echo "seed-tree $seed_tree"
  echo "app-manifest $(shasum -a 256 "$app_manifest" | awk '{print $1}')"
} > "$stage/$archive_root/OWLTYPE-SOURCE-PROVENANCE.txt"

(
  cd "$stage/$archive_root"
  python3 - <<'PY'
import hashlib
from pathlib import Path

for path in sorted(
    (
        item
        for item in Path(".").rglob("*")
        if item.is_file() and item.name != "OWLTYPE-SOURCE-MANIFEST.sha256"
    ),
    key=lambda item: item.as_posix().encode(),
):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    print(f"{digest.hexdigest()}  {path.as_posix()}")
PY
) > "$stage/$archive_root/OWLTYPE-SOURCE-MANIFEST.sha256"

python3 "$repo_root/scripts/release_source.py" archive \
  "$stage/$archive_root" "$output_dir/$archive_name"
(
  cd "$output_dir"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

echo "PASS: corresponding source archive written to $output_dir/$archive_name"
echo "PASS: source revision $revision"
python3 "$repo_root/scripts/release-cohort-state.py" register-output \
  "$output_root" source-archive "$output_dir/$archive_name"
