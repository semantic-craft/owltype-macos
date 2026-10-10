#!/bin/bash
# Read-only: no install, registration, selection, launch, or service restart.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == --self-test && $# == 1 ]]; then
  exec python3 -B "$script_dir/check-live-ime-version.selftest.py"
fi
exec python3 -B "$script_dir/check-live-ime-version.py" "$@"
