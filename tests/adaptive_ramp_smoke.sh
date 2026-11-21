#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if command -v uv >/dev/null 2>&1; then
  uv run --no-project --with lupa python tests/adaptive_ramp_smoke.py
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command 'uv run --no-project --with lupa python tests/adaptive_ramp_smoke.py'
else
  echo 'uv is required for the adaptive Ramp smoke test' >&2
  exit 1
fi
