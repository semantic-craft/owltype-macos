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
trap 'rm -rf "$work_dir"' EXIT

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

for artifact in "$@"; do
  if [[ ! -e "$artifact" ]]; then
    printf 'SKIP: artifact secret scan (not built yet): %s\n' "$artifact"
    continue
  fi

  label="$artifact"
  case "$artifact" in
    *.tar.gz|*.tgz)
      target="$work_dir/$(basename "$artifact").d"
      mkdir -p "$target"
      tar -xzf "$artifact" -C "$target"
      ;;
    *)
      target="$artifact"
      ;;
  esac

  gitleaks_report="$work_dir/gitleaks-$(basename "$artifact").json"
  set +e
  gitleaks dir "$target" \
    --redact=100 \
    --no-banner \
    --no-color \
    --log-level=error \
    --report-format=json \
    --report-path="$gitleaks_report" >"$work_dir/gitleaks.log" 2>&1
  gitleaks_status=$?
  set -e

  if (( gitleaks_status != 0 )); then
    python3 - "$gitleaks_report" "$label" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        findings = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    findings = []

for finding in findings:
    print(
        f"potential secret found in artifact: scanner=gitleaks "
        f"artifact={sys.argv[2]} rule={finding.get('RuleID', 'unknown')} "
        f"file={finding.get('File', 'unknown')}",
        file=sys.stderr,
    )
if not findings:
    print(
        f"Gitleaks failed on {sys.argv[2]}; raw output was suppressed. "
        "Run scripts/check-secrets.sh --artifacts <path> locally for private diagnosis.",
        file=sys.stderr,
    )
PY
    exit "$gitleaks_status"
  fi

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

  # 已知误报按「检出器 + 取值形状 + 出现位置」三重条件逐条排除，绝不整文件放行。
  python3 - "$trufflehog_output" "$label" "$target" <<'PY'
import json
import pathlib
import re
import sys

output, label, root = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])

HASH_MANIFESTS = {"FAMOTYPE-FILE-MANIFEST.sha256", "FAMOTYPE-SOURCE-MANIFEST.sha256"}
SHA256 = re.compile(r"^[0-9a-f]{64}$")
# 清单每行的形状是 `<64位小写hex><两个空格><路径>`（shasum 输出格式）。只放行长在这个形状里的
# 那一列 —— 清单文件里混进别的东西照样会报。
MANIFEST_LINE = re.compile(r"^[0-9a-f]{64} {2}\S")
# Swift 符号修饰：`$s<模块名长度><模块名>…`，本项目模块名是 Famo。实测命中过
# s4Famo0A18…ViewVwtk（swift-demangle → value witness for Famo.FamoAIConversationView）。中段
# 故意省略：那串是 32 位字母数字，Box 检出器只要在它前约 40 字符内看见 box 就报，而本文件通篇
# 在讲各检出器的误报 —— 写全了等于给未来某句带 Box 的注释埋雷，害整个 privacy-gate 长红。
SWIFT_MANGLED = re.compile(r"^s\d+Famo")


def manifest_hash_column(finding, path_str, raw):
    """PhraseAccessToken 规则匹配 64-hex，会把 SHA-256 清单里的每个哈希都当成 phrase.com 令牌。"""
    if finding.get("DetectorName") != "PhraseAccessToken":
        return False
    if not SHA256.match(raw):
        return False
    path = pathlib.Path(path_str)
    if path.name not in HASH_MANIFESTS:
        return False
    line_no = finding.get("SourceMetadata", {}).get("Data", {}).get("Filesystem", {}).get("line")
    if not line_no:
        return False
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for index, line in enumerate(handle, start=1):
                if index == line_no:
                    # 命中值必须**就是**该行开头那个摘要。只验行形状不够：清单里若有个文件名形如
                    # `phrase_<64位token>`，该行仍是 `<正常摘要>  ./phrase_<token>` 的合规形状，
                    # 而 trufflehog 报的是来自文件名的那个 token —— 那是真泄漏，不能豁免。
                    return bool(MANIFEST_LINE.match(line)) and line[:64] == raw
    except OSError:
        return False
    return False


def swift_symbol(finding, path_str, raw):
    """编译产物里的 Swift 符号名是高熵字母数字串，Box 等检出器会撞上。"""
    if not SWIFT_MANGLED.match(raw):
        return False
    path = pathlib.Path(path_str)
    return path.is_file() and path.parent.name in {"MacOS", "Frameworks", "PlugIns"}


ALLOWED = (
    ("SHA-256 清单的哈希列", manifest_hash_column),
    ("Swift 符号修饰", swift_symbol),
)

real, waived = [], []
for line in open(output, encoding="utf-8", errors="replace"):
    try:
        finding = json.loads(line)
    except json.JSONDecodeError:
        continue
    raw = finding.get("Raw", "")
    path_str = (
        finding.get("SourceMetadata", {})
        .get("Data", {})
        .get("Filesystem", {})
        .get("file", "")
    )
    for reason, predicate in ALLOWED:
        if predicate(finding, path_str, raw):
            waived.append(reason)
            break
    else:
        real.append((finding.get("DetectorName", "unknown"), path_str))

if real:
    for detector, path_str in real:
        print(
            f"potential secret found in artifact: scanner=trufflehog "
            f"artifact={label} detector={detector} file={path_str}",
            file=sys.stderr,
        )
    sys.exit(1)

suffix = ""
if waived:
    counts = {}
    for reason in waived:
        counts[reason] = counts.get(reason, 0) + 1
    suffix = "（已按既有误报判据豁免：" + "，".join(f"{k} {v} 条" for k, v in counts.items()) + "）"
print(f"PASS: no secrets in artifact {label}{suffix}")
PY

  scanned=$((scanned + 1))
done

if (( scanned == 0 )); then
  printf 'SKIP: artifact secret gate had nothing to scan\n'
fi
