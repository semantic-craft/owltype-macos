#!/usr/bin/env bash
# tail-log.sh — stream 猫头鹰输入法 (Owltype) + librime logs from the unified log.
set -euo pipefail

log stream \
  --predicate 'process == "Owltype" OR process == "Squirrel" OR subsystem CONTAINS "rime" OR category CONTAINS "rime"' \
  --style compact \
  --level debug
