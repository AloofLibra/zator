#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/lib/supersweep_transport.sh"
. "$ROOT/lib/adaptive_lan_transport.sh"

BASE="$TMP/runs"
LOCK="$TMP/shared.lock"
QUEUE="$TMP/queues"
PROC="$TMP/proc"
BOOT="$TMP/boot_id"
CALLS="$TMP/iptables.log"
ID=0123456789abcdef0123456789abcdef
RUN="$BASE/$ID"
Z2R_ADAPTIVE_LOCK_DIR="$LOCK"
Z2R_ADAPTIVE_QUEUE_FILE="$QUEUE"
Z2R_ADAPTIVE_PROC_ROOT="$PROC"
Z2R_ADAPTIVE_BOOT_ID_FILE="$BOOT"
ZATOR_ROOT="$TMP/zator"
FWTYPE=iptables
printf 'boot-test\n' > "$BOOT"

iptables() {
  printf '%s\n' "$*" >> "$CALLS"
  case " $* " in
    *' -C '*) return 0 ;;
    *' -S Z2R_ADAPTIVE_LAN '*|*' -S Z2R_ADAPTIVE_LAN_POST '*) return 0 ;;
    *) return 0 ;;
  esac
}

prepare_stale_run() {
  rm -rf "$BASE" "$LOCK" "$PROC"
  : > "$CALLS"
  : > "$QUEUE"
  mkdir -p "$RUN/leases" "$RUN/probe" "$LOCK" "$PROC"
  touch "$RUN/probe/locked.lua"
  printf '1\tiptables\t%s\t0x10000000\t0x40000000\n' "$ID" > "$RUN/probe/transport.tsv"
  printf 'probing\n' > "$RUN/state"
  printf '%s\t192.168.1.20\t62000\t142.250.72.14\t443\t2000000000\ttls-http1-v1\n' "$ID" > "$RUN/leases/$ID.tsv"
  printf 'adaptive-lan\t2147483000\tboot-test\n' > "$LOCK/owner"
}

prepare_stale_run
adaptive_lan_transport_recover_stale "$BASE"
[[ "$(cat "$RUN/state")" = failed && "$(cat "$RUN/error")" = controller_crash_recovered ]] || {
  echo 'stale adaptive run was not marked recovered' >&2; exit 1;
}
[[ ! -e "$RUN/probe/transport.tsv" ]] || { echo 'stale transport state was not removed' >&2; exit 1; }
[[ ! -e "$LOCK" ]] || { echo 'stale adaptive mutex was not released' >&2; exit 1; }
for rule in z2r-adaptive-lan-reply z2r-adaptive-lan-original z2r-adaptive-lan-post; do
  grep -q -- "-D .*${rule}" "$CALLS" || { echo "stale ${rule} hook was not removed" >&2; exit 1; }
done
grep -q -- '-X Z2R_ADAPTIVE_LAN' "$CALLS" || { echo 'stale adaptive chain was not removed' >&2; exit 1; }
grep -q -- '-X Z2R_ADAPTIVE_LAN_POST' "$CALLS" || { echo 'stale postrouting chain was not removed' >&2; exit 1; }

prepare_stale_run
printf '65535 %s 0 2 0 0 0 0 1\n' "$$" > "$QUEUE"
mkdir -p "$PROC/$$"
printf '%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=65535' > "$PROC/$$/cmdline"
if adaptive_lan_transport_recover_stale "$BASE"; then
  echo 'recovery accepted a queue owner without its private probe Lua' >&2; exit 1
fi
[[ -d "$LOCK" && "$(wc -l < "$CALLS")" = 0 ]] || { echo 'unknown queue owner was touched' >&2; exit 1; }
kill -0 "$$" 2>/dev/null || { echo 'recovery killed the live smoke process' >&2; exit 1; }

prepare_stale_run
printf 'adaptive-lan\t%s\tboot-test\n' "$$" > "$LOCK/owner"
mkdir -p "$PROC/$$"
printf '%s\0' "$ZATOR_ROOT/tools/adaptive-controller.sh" > "$PROC/$$/cmdline"
if adaptive_lan_transport_recover_stale "$BASE"; then
  echo 'recovery took over a live controller' >&2; exit 1
fi
[[ -d "$LOCK" && "$(wc -l < "$CALLS")" = 0 ]] || { echo 'live controller state was mutated' >&2; exit 1; }

echo 'adaptive LAN stale recovery smoke: ok'
