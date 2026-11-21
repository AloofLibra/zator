#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
if command -v uv >/dev/null 2>&1; then
  uv run --no-project --with lupa python tests/adaptive_rule_selection.py
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command 'uv run --no-project --with lupa python tests/adaptive_rule_selection.py'
else
  echo 'uv is required for the adaptive Lua selector smoke test' >&2
  exit 1
fi
