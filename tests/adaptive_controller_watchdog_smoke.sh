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
awk '
  /^_adaptive_lan_controller_alive\(\) \{/ { copying=1; depth=0 }
  copying {
    print
    line=$0
    opens=gsub(/\{/, "{", line)
    closes=gsub(/\}/, "}", line)
    depth += opens - closes
    if (depth == 0) exit
  }
' "$ROOT/lib/adaptive_lan_transport.sh" >> "$tmp/watchdog.sh"
grep -q '^_adaptive_lan_controller_alive()' "$tmp/watchdog.sh" || {
  echo 'controller identity check not found' >&2; exit 1;
}

controller_path=/opt/zator/tools/adaptive-controller.sh
mkdir -p "$tmp/base/0123456789abcdef0123456789abcdef" "$tmp/lock" "$tmp/proc"
printf 'probing\n' > "$tmp/base/0123456789abcdef0123456789abcdef/state"
chmod 700 "$tmp/base/0123456789abcdef0123456789abcdef"
chmod 600 "$tmp/base/0123456789abcdef0123456789abcdef/state"
chmod 700 "$tmp/lock"
chmod 700 "$tmp/proc"
exec -a "$controller_path" bash -c 'while :; do read -r -t 1 _ || :; done' &
controller_pid=$!
printf 'adaptive-lan\t%s\tboot-test\n' "$controller_pid" > "$tmp/lock/owner"
chmod 600 "$tmp/lock/owner"
cat >> "$tmp/watchdog.sh" <<'STUBS'
adaptive_lan_transport_recover_stale() { printf '%s\n' "$1" > "$WATCHDOG_RECOVERY_LOG"; }
STUBS

Z2R_ADAPTIVE_PROC_ROOT="$tmp/proc" WATCHDOG_RECOVERY_LOG="$tmp/recovery.log" bash -c '
  . "$1"
  mkdir -p "$5/$7"
  printf "%s\\0" "$6" > "$5/$7/cmdline"
  adaptive_controller_start_recovery_watchdog "$2" "$3" "$4" "$7" boot-test
  watchdog_pid="$Z2R_ADAPTIVE_RECOVERY_WATCHDOG_PID"
  kill -KILL "$7"
  wait "$watchdog_pid"
' _ "$tmp/watchdog.sh" "$tmp/base/0123456789abcdef0123456789abcdef" "$tmp/base" "$tmp/lock" "$tmp/proc" "$controller_path" "$controller_pid"
wait "$controller_pid" 2>/dev/null || :
[[ "$(cat "$tmp/recovery.log")" = "$tmp/base" ]] || {
  echo 'SIGKILLed controller watchdog did not invoke scoped stale-run recovery' >&2; exit 1;
}

echo 'adaptive controller SIGKILL recovery watchdog smoke: ok'
