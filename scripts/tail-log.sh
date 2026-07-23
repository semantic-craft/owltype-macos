#!/usr/bin/env bash
# tail-log.sh — stream 法墨输入法 (Famo) + librime logs from the unified log.
set -euo pipefail

log stream \
  --predicate 'process == "Famo" OR process == "Squirrel" OR subsystem CONTAINS "rime" OR category CONTAINS "rime"' \
  --style compact \
  --level debug
