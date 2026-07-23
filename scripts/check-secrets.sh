#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v gitleaks >/dev/null || {
  echo "gitleaks is required for the public release gate" >&2
  exit 1
}
command -v trufflehog >/dev/null || {
  echo "trufflehog is required for the public release gate" >&2
  exit 1
}

gitleaks git --redact=100 --log-opts=HEAD "$repo_root"
trufflehog git "file://$repo_root" \
  --branch=HEAD \
  --results=verified,unknown,unverified \
  --fail \
  --fail-on-scan-errors \
  --no-update

echo "PASS: Gitleaks and TruffleHog found no secrets in HEAD history"
