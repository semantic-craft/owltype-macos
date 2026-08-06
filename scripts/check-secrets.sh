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

# 已知误报按「检出器 + 取值形状 + 出现位置」三重条件逐条排除，绝不整文件放行 —— 与
# check-artifact-secrets.sh 同一套判据。**两处的 Lob 判据必须同步改动**：同一个检出器同时
# 打这两道门（历史扫描与产物扫描），只补一处就是只修一半，另一处照样红。
python3 - "$trufflehog_output" <<'PY'
import json
import pathlib
import re
import sys

# Lob 的检出器认 `test_` / `live_` 前缀 + 35 位字母数字下划线，于是恰好 35 字符的**测试函数名**
# 整个撞上（本仓建仓提交里的两个 Swift 测试方法名）。本项目不使用 Lob，也不存在 Lob 凭据。
# 判据取「令牌体里含下划线」：真凭据是不可读的随机令牌，下划线是标识符分词才有的东西。
# 命中值一律不写进注释：本文件自己也在扫描范围内，写全了就是埋雷。
LOB_TEST_IDENTIFIER = re.compile(r"^(?:test|live)_(?=.*_)[A-Za-z0-9_]+$")
SOURCE_SUFFIXES = {
    ".swift", ".py", ".cpp", ".cc", ".c", ".h", ".hpp", ".m", ".mm",
    ".go", ".rs", ".java", ".js", ".ts", ".rb", ".lua",
}


def lob_test_identifier(detector, path, raw):
    """Lob 检出器把恰好 35 字符的 `test_`/`live_` 开头函数名当成 API key。"""
    if detector != "Lob":
        return False
    if not LOB_TEST_IDENTIFIER.match(raw):
        return False
    # 命中在 commit message 里时没有 file，`path` 是那个占位串、取不到后缀，于是不豁免 ——
    # 提交信息里出现凭据形状的东西本来就该报。
    return pathlib.Path(path).suffix in SOURCE_SUFFIXES


real, waived = [], 0
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
        if lob_test_identifier(detector, path, finding.get("Raw", "")):
            waived += 1
            continue
        real.append((detector, path, commit))

if real:
    for detector, path, commit in real:
        print(
            f"potential secret found: scanner=trufflehog "
            f"detector={detector} file={path} commit={commit}",
            file=sys.stderr,
        )
    sys.exit(1)

suffix = f"（已按既有误报判据豁免：Lob 撞测试函数名 {waived} 条）" if waived else ""
print(f"PASS: TruffleHog found no secrets in reachable history{suffix}")
PY

echo "PASS: Gitleaks and TruffleHog found no secrets in reachable history"
