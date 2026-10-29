#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 两种模式：
#   无参            —— 扫可达 git 历史（scripts/release.sh / CI 走这条）。
#   --artifacts P…  —— 扫**发布产物**（app bundle、源码包），转交 check-artifact-secrets.sh。
#                      历史干净不等于产物干净：源码包里带 submodule 源码（Sparkle），
#                      而历史扫描只覆盖主仓；app bundle 里还有编译产物与出厂种子。
if [[ "${1:-}" == "--artifacts" ]]; then
  shift
  exec bash "$repo_root/scripts/check-artifact-secrets.sh" "$@"
fi

scan_dir="$(mktemp -d)"
gitleaks_report="$scan_dir/gitleaks.json"
gitleaks_log="$scan_dir/gitleaks.log"
trufflehog_output="$scan_dir/trufflehog.jsonl"
trufflehog_log="$scan_dir/trufflehog.log"
gitleaks_findings_status=10
trap 'rm -rf "$scan_dir"' EXIT

command -v gitleaks >/dev/null || {
  echo "gitleaks is required for the public release gate" >&2
  exit 1
}
command -v trufflehog >/dev/null || {
  echo "trufflehog is required for the public release gate" >&2
  exit 1
}

set +e
gitleaks git \
  --redact=100 \
  --no-banner \
  --no-color \
  --exit-code="$gitleaks_findings_status" \
  --log-level=error \
  --report-format=json \
  --report-path="$gitleaks_report" \
  --log-opts=--all \
  "$repo_root" >"$gitleaks_log" 2>&1
gitleaks_status=$?
set -e

if (( gitleaks_status != 0 )); then
  if (( gitleaks_status == gitleaks_findings_status )); then
    set +e
    python3 "$repo_root/scripts/secret-finding-policy.py" \
      history gitleaks "$gitleaks_report"
    gitleaks_policy_status=$?
    set -e
    if (( gitleaks_policy_status == 1 )); then
      # The dedicated scanner status plus a valid report proves discovery.
      exit 1
    fi
  fi
  echo "ERROR: Gitleaks scan failed (exit $gitleaks_status); raw output was suppressed." >&2
  exit "$gitleaks_status"
fi

# Fail closed if a future Gitleaks version ever writes findings while returning
# zero.  The policy owns rejection and safe reporting in either exit-code shape.
python3 "$repo_root/scripts/secret-finding-policy.py" \
  history gitleaks "$gitleaks_report"

set +e
# 这里**不**传 `--fail`（2026-08-06 改，与 check-artifact-secrets.sh 同一处置）：命中与否交给
# 下面的 python 过滤器判断，于是退出码里不存在「因发现命中而非零」这回事，任何非零都是扫描
# 本身出了问题（配合 --fail-on-scan-errors）。改这条的原因是这道门此前没有任何豁免机制，
# 一条误报就能让全仓所有分支长红 —— Lob 检出器 2026-08-06 正是这么发作的。
trufflehog git "file://$repo_root" \
  --results=verified,unknown,unverified \
  --fail-on-scan-errors \
  --no-update \
  --json >"$trufflehog_output" 2>"$trufflehog_log"
trufflehog_status=$?
set -e

if (( trufflehog_status != 0 )); then
  echo "TruffleHog exited non-zero — treat as a scan error, not a pass:" >&2
  tail -3 "$trufflehog_log" >&2 || echo "  (no trufflehog log captured)" >&2
  exit "$trufflehog_status"
fi

# The history adapter only normalizes Git metadata.  All predicates and safe
# reporting are shared with the artifact gate in secret-finding-policy.py.
python3 "$repo_root/scripts/secret-finding-policy.py" \
  history trufflehog "$trufflehog_output"

echo "PASS: Gitleaks and TruffleHog found no secrets in reachable history"
