#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if command -v uv >/dev/null 2>&1; then
  uv run --no-project --with lupa python tests/adaptive_browser_trials.py
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command 'uv run --no-project --with lupa python tests/adaptive_browser_trials.py'
else
  echo 'uv is required for the adaptive browser trial smoke test' >&2
  exit 1
fi
