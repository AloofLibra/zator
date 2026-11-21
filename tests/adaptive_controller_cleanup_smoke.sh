#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTROLLER="$ROOT/tools/adaptive-controller.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Extract only the cleanup function; its dependencies below record call order.
awk '
  /^cleanup\(\) \{/ { copying=1; depth=0 }
  copying {
    print
    line=$0
    opens=gsub(/\{/, "{", line)
    closes=gsub(/\}/, "}", line)
    depth += opens - closes
    if (depth == 0) exit
  }
' "$CONTROLLER" > "$tmp/cleanup.sh"
grep -q '^cleanup()' "$tmp/cleanup.sh" || { echo 'controller cleanup function not found' >&2; exit 1; }

cat >> "$tmp/cleanup.sh" <<'STUBS'
events="${TMPDIR_TEST}/events"
Z2R_ADAPTIVE_TRANSPORT_ACTIVE=1
Z2R_ADAPTIVE_LOCK_HELD=1
Z2R_ADAPTIVE_NFQWS2_PID=4321
run="$TMPDIR_TEST/run"
mkdir -p "$run"
adaptive_lan_transport_stop() { printf 'firewall\n' >> "$events"; }
kill() { printf 'kill\n' >> "$events"; }
wait() { printf 'wait\n' >> "$events"; }
adaptive_lan_probe_lock_release() { printf 'unlock\n' >> "$events"; }
STUBS

TMPDIR_TEST="$tmp" bash -c '. "$1"; cleanup' _ "$tmp/cleanup.sh"
actual="$(cat "$tmp/events")"
expected=$'firewall\nkill\nwait\nunlock'
[[ "$actual" == "$expected" ]] || {
  printf 'unexpected cleanup order:\n%s\n' "$actual" >&2
  exit 1
}
echo 'adaptive controller cleanup ordering passed'
