#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -Fq "Ramp audit is paused until Ramp-first is explicitly enabled for the configured Googlevideo pool" "$ROOT/tools/adaptive-agent.ps1" || {
  echo 'Ramp audit consent guidance is missing from the Windows watcher' >&2; exit 1;
}
if grep -Fq 'Adaptive Ramp audit is unsupported on this Keenetic hardware' "$ROOT/tools/adaptive-agent.ps1"; then
  echo 'Ramp audit still treats a missing consent as a Keenetic hardware limitation' >&2; exit 1;
fi
PS_TEST="$ROOT/tests/adaptive_agent_state_smoke.ps1"
command -v wslpath >/dev/null 2>&1 && PS_TEST="$(wslpath -w "$PS_TEST")"
if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS_TEST"
elif command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$PS_TEST"
else
  echo 'PowerShell is required for the adaptive agent exploration-state smoke test' >&2
  exit 1
fi
