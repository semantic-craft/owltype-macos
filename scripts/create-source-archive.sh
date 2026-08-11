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
app="$output_root/Build/Products/Release/Famo.app"
output_dir="$output_root/release"
[[ -f "$app/Contents/Info.plist" ]] || {
  echo "缺少已构建的 Famo.app: ${app}（从干净输出根重跑 scripts/release.sh）" >&2
  exit 1
}

# provenance 里的 app-manifest 必须指向**出厂那份 app** 的盘点，也就是 notarized-app 在签名 +
# 公证 + staple 之后写出来的这份。曾经它指向 bundle 内那份 finalize 期清单，而 make source-archive
# 会重跑 finalize、在 staple 之后再写一次 —— 于是源码包记的哈希在任何出厂产物里都找不到。
app_manifest="$output_dir/FAMOTYPE-FILE-MANIFEST.sha256"
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
[[ -d "$repo_root/data/famo-rime" ]] || {
  echo "data/famo-rime is missing; run make famo-seed" >&2
  exit 1
}
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]] || {
  echo "source archive requires a clean worktree" >&2
  exit 1
}

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
build_version="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
revision="$(git -C "$repo_root" rev-parse HEAD)"
archive_root="Famotype-macOS-$version-source"
archive_name="$archive_root.tar.gz"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/$archive_root" "$output_dir"
git -C "$repo_root" archive HEAD | tar -x -C "$stage/$archive_root"

while read -r submodule_revision submodule_path _; do
  [[ "$submodule_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "submodule is uninitialized or differs from the recorded revision: $submodule_path" >&2
    exit 1
  }
  mkdir -p "$stage/$archive_root/$submodule_path"
  git -C "$repo_root/$submodule_path" archive HEAD | \
    tar -x -C "$stage/$archive_root/$submodule_path"
done < <(git -C "$repo_root" submodule status --recursive)

mkdir -p "$stage/$archive_root/data/famo-rime"
rsync -a "$repo_root/data/famo-rime/." "$stage/$archive_root/data/famo-rime/"

{
  echo "Famotype source release $version"
  echo "build-version $build_version"
  echo "root $revision"
  echo "cohort $cohort_id"
  git -C "$repo_root" submodule status --recursive
  echo "seed $(shasum -a 256 "$repo_root/data/famo-rime/FAMOTYPE-SEED-MANIFEST.txt" | awk '{print $1}')"
  echo "app-manifest $(shasum -a 256 "$app_manifest" | awk '{print $1}')"
} > "$stage/$archive_root/FAMOTYPE-SOURCE-PROVENANCE.txt"

(
  cd "$stage/$archive_root"
  python3 - <<'PY'
import hashlib
from pathlib import Path

for path in sorted(
    (
        item
        for item in Path(".").rglob("*")
        if item.is_file() and item.name != "FAMOTYPE-SOURCE-MANIFEST.sha256"
    ),
    key=lambda item: item.as_posix().encode(),
):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    print(f"{digest.hexdigest()}  {path.as_posix()}")
PY
) > "$stage/$archive_root/FAMOTYPE-SOURCE-MANIFEST.sha256"

COPYFILE_DISABLE=1 tar -czf "$output_dir/$archive_name" -C "$stage" "$archive_root"
(
  cd "$output_dir"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

echo "PASS: corresponding source archive written to $output_dir/$archive_name"
echo "PASS: source revision $revision"
python3 "$repo_root/scripts/release-cohort-state.py" register-output \
  "$output_root" source-archive "$output_dir/$archive_name"
