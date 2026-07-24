#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scan_dir="$(mktemp -d)"
gitleaks_report="$scan_dir/gitleaks.json"
gitleaks_log="$scan_dir/gitleaks.log"
trufflehog_output="$scan_dir/trufflehog.jsonl"
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
  --json >"$trufflehog_output" 2>&1
trufflehog_status=$?
set -e

if (( trufflehog_status != 0 )); then
  python3 - "$trufflehog_output" <<'PY'
import json
import sys

reported = False
with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    for line in handle:
        try:
            finding = json.loads(line)
        except json.JSONDecodeError:
            continue
        detector = finding.get("DetectorName", "unknown")
        git_data = (
            finding.get("SourceMetadata", {})
            .get("Data", {})
            .get("Git", {})
        )
        path = git_data.get("file", "unknown")
        print(
            f"potential secret found: scanner=trufflehog "
            f"detector={detector} file={path}",
            file=sys.stderr,
        )
        reported = True

if not reported:
    print(
        "TruffleHog failed or found a secret; raw output was suppressed. "
        "Run scripts/check-secrets.sh locally for private diagnosis.",
        file=sys.stderr,
    )
PY
  exit "$trufflehog_status"
fi

echo "PASS: Gitleaks and TruffleHog found no secrets in reachable history"
