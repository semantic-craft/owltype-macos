#!/usr/bin/env bash
# All worktrees/agents use the same explicit TeslaHub coordinator store.
set -euo pipefail
: "${TESLAHUB_HOME:?Set TESLAHUB_HOME to the maintained TeslaHub checkout}"
: "${TESLAHUB_DATA_DIR:?Set TESLAHUB_DATA_DIR to the shared Owltype coordinator store}"
[[ -f "$TESLAHUB_HOME/board/claims.mjs" ]] || { echo 'TeslaHub claims entry missing' >&2; exit 1; }
case "${1:-}" in
  reserve|bind|in-review|report|rework|stuck|integrate|status|list|mark-unknown|resolve-manual|recover-merged) ;;
  *) echo 'Use the TeslaHub claims commands documented in docs/input-alignment.md' >&2; exit 2 ;;
esac
exec node "$TESLAHUB_HOME/board/claims.mjs" "$@" --data-dir "$TESLAHUB_DATA_DIR"
