#!/usr/bin/env bash
# Diagnose English candidates in the installed full-pinyin schema without touching live user data.
# Optional argument: a fixture user-data directory, copied before deployment.
# Returns 1 when hello is absent from the first candidate page; not part of the release gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${OWL_APP:-/Library/Input Methods/Owltype.app}"
SS="$APP/Contents/SharedSupport"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/owl-english-repro.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/user"
cp -R "${1:-$SS/_user_seed}/." "$WORK/user/"
clang++ -std=c++17 -I"$ROOT/librime/src" \
  -Wl,-rpath,"$APP/Contents/Frameworks" \
  "$ROOT/tools/owl-rime-probe.cc" "$APP/Contents/Frameworks/librime.1.dylib" \
  -o "$WORK/probe"
export DYLD_LIBRARY_PATH="$APP/Contents/Frameworks:$APP/Contents/Frameworks/rime-plugins:${DYLD_LIBRARY_PATH:-}"
if ! output="$("$WORK/probe" "$SS" "$WORK/user" rime_ice hello 2>"$WORK/engine.log")"; then
  cat "$WORK/engine.log" >&2
  exit 2
fi
printf '%s\n' "$output"
if printf '%s\n' "$output" | grep -Eq '^candidate\[[0-9]+\]=hello([[:space:]]|$)'; then
  echo 'PASS: hello is available as a candidate'
else
  echo 'FAIL: hello is absent from the first candidate page'
  exit 1
fi
