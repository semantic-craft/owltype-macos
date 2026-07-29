#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 两种模式：
#   无参            —— 扫可达 git 历史（原有行为，privacy-gate / CI 走这条）。
#   --artifacts P…  —— 扫**发布产物**（app bundle、源码包），转交 check-artifact-secrets.sh。
#                      历史干净不等于产物干净：源码包里带 submodule 源码（librime/plum/opencc），
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
  --log-level=error \
  --report-format=json \
  --report-path="$gitleaks_report" \
  --log-opts=--all \
  "$repo_root" >"$gitleaks_log" 2>&1
gitleaks_status=$?
set -e

if (( gitleaks_status != 0 )); then
  python3 - "$gitleaks_report" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        findings = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    findings = []

if findings:
    for finding in findings:
        rule = finding.get("RuleID", "unknown")
        path = finding.get("File", "unknown")
        print(f"potential secret found: scanner=gitleaks rule={rule} file={path}", file=sys.stderr)
else:
    print(
        "Gitleaks failed; raw output was suppressed. "
        "Run scripts/check-secrets.sh locally for private diagnosis.",
        file=sys.stderr,
    )
PY
  exit "$gitleaks_status"
fi

set +e
trufflehog git "file://$repo_root" \
  --results=verified,unknown,unverified \
  --fail \
  --fail-on-scan-errors \
  --no-update \
  --json >"$trufflehog_output" 2>"$trufflehog_log"
trufflehog_status=$?
set -e

if (( trufflehog_status != 0 )); then
  python3 - "$trufflehog_output" "$trufflehog_log" <<'PY'
import json
import sys

reported = False
with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    for line in handle:
        try:
            finding = json.loads(line)
        except json.JSONDecodeError:
            continue
        # trufflehog 的运行日志也是 JSON（{"level":"info-0","msg":"scanning repo"}）。
        # 它们本不该出现在这条流里（stderr 已单独重定向），但版本升级随时可能把日志改到
        # stdout；没有 DetectorName 的行一律不是命中，跳过，别再报成 detector=unknown。
        detector = finding.get("DetectorName")
        if not detector:
            continue
        git_data = (
            finding.get("SourceMetadata", {})
            .get("Data", {})
            .get("Git", {})
        )
        # 命中在 commit message 里时 trufflehog 不给 file（键缺失或为 null），只报
        # `file=unknown` 就没法定位；补上 commit，否则得手工再扫一遍才知道是哪条。
        path = git_data.get("file") or "(commit message)"
        commit = (git_data.get("commit") or "")[:12] or "unknown"
        print(
            f"potential secret found: scanner=trufflehog "
            f"detector={detector} file={path} commit={commit}",
            file=sys.stderr,
        )
        reported = True

if not reported:
    # stderr 已单独重定向，所以走到这里意味着「非零退出但没有任何命中」= 扫描本身出错
    # （--fail-on-scan-errors）。把 trufflehog 自己的最后几行日志带出来，别只给一句套话。
    print(
        "TruffleHog exited non-zero with no findings — treat as a scan error, not a pass:",
        file=sys.stderr,
    )
    try:
        with open(sys.argv[2], encoding="utf-8", errors="replace") as log:
            for line in log.readlines()[-3:]:
                print("  " + line.rstrip(), file=sys.stderr)
    except OSError:
        print("  (no trufflehog log captured)", file=sys.stderr)
PY
  exit "$trufflehog_status"
fi

echo "PASS: Gitleaks and TruffleHog found no secrets in reachable history"
