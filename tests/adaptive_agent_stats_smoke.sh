#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PS_TEST="$ROOT/tests/adaptive_agent_stats_smoke.ps1"
command -v wslpath >/dev/null 2>&1 && PS_TEST="$(wslpath -w "$PS_TEST")"
if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS_TEST"
elif command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$PS_TEST"
else
  echo 'PowerShell is required for the adaptive statistics spool smoke test' >&2
  exit 1
fi
