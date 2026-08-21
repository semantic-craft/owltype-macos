#!/usr/bin/env bash

# 扫**发布产物**里的凭据泄漏：app bundle 与源码包。入口是 `check-secrets.sh --artifacts P…`。
#
# 为什么单独一道：`check-secrets.sh` 的历史扫描只覆盖主仓可达历史，而
#   * 源码包里带 submodule 源码（librime / plum / librime-lua / Sparkle），历史扫描碰不到；
#   * app bundle 里还有编译产物、出厂种子词库这些不在 git 里的东西。
# 2026-07-29 手工补扫时两面都干净，但当时没有任何东西会在下次发版自动扫。
#
# 传入 .tar.gz 会先解包再扫目录，而不是直接扫压缩包：trufflehog 扫压缩包时报的路径是压缩包
# 自身（只给一个 line 号，没有内层路径），下面那条按「哪个文件的哪一行」判定的 allowlist 就
# 失效了，只能退化成对整包放行 64-hex —— 太宽。解包一次 54 MB 约 2 秒，换来可审计的精确度。

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
mounted_dmg=""
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$mounted_dmg" ]]; then
    /usr/bin/hdiutil detach "$mounted_dmg" >/dev/null 2>&1 || result=70
    mounted_dmg=""
  fi
  rm -rf "$work_dir"
  exit "$result"
}
trap cleanup EXIT

command -v gitleaks >/dev/null || {
  echo "gitleaks is required for the artifact secret gate" >&2
  exit 1
}
command -v trufflehog >/dev/null || {
  echo "trufflehog is required for the artifact secret gate" >&2
  exit 1
}

(( $# > 0 )) || {
  echo "usage: check-secrets.sh --artifacts <app-bundle|source.tar.gz|dir> …" >&2
  exit 2
}

scanned=0
gitleaks_findings_status=10

for artifact in "$@"; do
  if [[ ! -e "$artifact" ]]; then
    printf 'SKIP: artifact secret scan (not built yet): %s\n' "$artifact"
    continue
  fi

  label="$artifact"
  case "$artifact" in
    *.tar.gz|*.tgz)
      target="$work_dir/$scanned-tar"
      python3 "$repo_root/scripts/safe-extract-tar.py" "$artifact" "$target"
      ;;
    *.pkg)
      target="$work_dir/$scanned-pkg"
      /usr/sbin/pkgutil --expand-full "$artifact" "$target" >/dev/null || {
        echo "ERROR: pkgutil failed to safely expand $label" >&2
        exit 70
      }
      ;;
    *.dmg)
      target="$work_dir/$scanned-dmg"
      mkdir -p "$target"
      /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$target" \
        "$artifact" >/dev/null || {
        echo "ERROR: hdiutil failed to mount $label read-only" >&2
        exit 70
      }
      mounted_dmg="$target"
      ;;
    *)
      target="$artifact"
      ;;
  esac

  gitleaks_report="$work_dir/gitleaks-$(basename "$artifact").json"
  set +e
  gitleaks dir "$target" \
    --config="$repo_root/.gitleaks.toml" \
    --redact=100 \
    --no-banner \
    --no-color \
    --exit-code="$gitleaks_findings_status" \
    --log-level=error \
    --report-format=json \
    --report-path="$gitleaks_report" >"$work_dir/gitleaks.log" 2>&1
  gitleaks_status=$?
  set -e

  if (( gitleaks_status != 0 )); then
    if (( gitleaks_status == gitleaks_findings_status )); then
      set +e
      python3 "$repo_root/scripts/secret-finding-policy.py" \
        artifact gitleaks "$gitleaks_report" --label "$label"
      gitleaks_policy_status=$?
      set -e
      if (( gitleaks_policy_status == 1 )); then
        exit 1
      fi
    fi
    echo "ERROR: Gitleaks failed to scan $label (exit $gitleaks_status); raw output was suppressed." >&2
    exit "$gitleaks_status"
  fi

  python3 "$repo_root/scripts/secret-finding-policy.py" \
    artifact gitleaks "$gitleaks_report" --label "$label"

  trufflehog_output="$work_dir/trufflehog-$(basename "$artifact").jsonl"
  set +e
  trufflehog filesystem "$target" \
    --results=verified,unknown,unverified \
    --fail-on-scan-errors \
    --no-update \
    --json >"$trufflehog_output" 2>"$work_dir/trufflehog.log"
  trufflehog_status=$?
  set -e

  # 这里**不**传 `--fail`，命中与否交给下面的 python 过滤器判断 —— 也就是说退出码里不存在
  # 「因发现命中而非零」这回事，任何非零都是扫描本身出了问题（配合 --fail-on-scan-errors，
  # 读不了的文件、解不开的归档都会走到这里）。曾误写成 `> 1`，等于把扫描错误当成功放行。
  if (( trufflehog_status != 0 )); then
    echo "ERROR: trufflehog failed to scan $label (exit $trufflehog_status)" >&2
    tail -3 "$work_dir/trufflehog.log" >&2
    exit "$trufflehog_status"
  fi

  # The filesystem adapter only normalizes scanner metadata.  The same deep
  # policy used for reachable history owns every exemption and rejection.
  python3 "$repo_root/scripts/secret-finding-policy.py" \
    artifact trufflehog "$trufflehog_output" --label "$label"

  if [[ -n "$mounted_dmg" ]]; then
    /usr/bin/hdiutil detach "$mounted_dmg" >/dev/null || {
      echo "ERROR: hdiutil failed to detach $label" >&2
      exit 70
    }
    mounted_dmg=""
  fi

  scanned=$((scanned + 1))
done

if (( scanned == 0 )); then
  printf 'SKIP: artifact secret gate had nothing to scan\n'
fi
