#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk '
  /^adaptive_controller_start_recovery_watchdog\(\) \{/ { copying=1; depth=0 }
  copying {
    print
    line=$0
    opens=gsub(/\{/, "{", line)
    closes=gsub(/\}/, "}", line)
    depth += opens - closes
    if (depth == 0) exit
  }
' "$ROOT/tools/adaptive-controller.sh" > "$tmp/watchdog.sh"
grep -q '^adaptive_controller_start_recovery_watchdog()' "$tmp/watchdog.sh" || {
  echo 'controller recovery watchdog function not found' >&2; exit 1;
}

mkdir -p "$tmp/base/0123456789abcdef0123456789abcdef" "$tmp/lock"
printf 'probing\n' > "$tmp/base/0123456789abcdef0123456789abcdef/state"
printf 'adaptive-lan\t424242\tboot-test\n' > "$tmp/lock/owner"
chmod 600 "$tmp/lock/owner"
cat >> "$tmp/watchdog.sh" <<'STUBS'
_adaptive_lan_controller_alive() { return 1; }
adaptive_lan_transport_recover_stale() { printf '%s\n' "$1" > "$WATCHDOG_RECOVERY_LOG"; }
STUBS

WATCHDOG_RECOVERY_LOG="$tmp/recovery.log" bash -c '
  . "$1"
  adaptive_controller_start_recovery_watchdog "$2" "$3" "$4" 424242 boot-test
  watchdog_pid="$Z2R_ADAPTIVE_RECOVERY_WATCHDOG_PID"
  wait "$watchdog_pid"
' _ "$tmp/watchdog.sh" "$tmp/base/0123456789abcdef0123456789abcdef" "$tmp/base" "$tmp/lock"
[[ "$(cat "$tmp/recovery.log")" = "$tmp/base" ]] || {
  echo 'dead controller watchdog did not invoke scoped stale-run recovery' >&2; exit 1;
}

echo 'adaptive controller recovery watchdog smoke: ok'
