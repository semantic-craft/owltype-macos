#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-}"
output_dir="${2:-}"

[[ -f "$app/Contents/Info.plist" ]] || {
  echo "usage: $0 /path/to/Famo.app /path/to/output-directory" >&2
  exit 1
}
[[ -n "$output_dir" ]] || {
  echo "usage: $0 /path/to/Famo.app /path/to/output-directory" >&2
  exit 1
}
[[ -d "$repo_root/data/famo-rime" ]] || {
  echo "data/famo-rime is missing; run make famo-seed" >&2
  exit 1
}
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]] || {
  echo "source archive requires a clean worktree" >&2
  exit 1
}

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
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
  echo "root $revision"
  git -C "$repo_root" submodule status --recursive
  echo "seed $(shasum -a 256 "$repo_root/data/famo-rime/FAMOTYPE-SEED-MANIFEST.txt" | awk '{print $1}')"
  echo "app-manifest $(shasum -a 256 "$app/Contents/Resources/FAMOTYPE-FILE-MANIFEST.sha256" | awk '{print $1}')"
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
