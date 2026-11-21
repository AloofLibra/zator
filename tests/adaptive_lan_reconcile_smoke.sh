#!/usr/bin/env bash
# Mock-only NDM rebuild recovery; no root, network, or real firewall changes.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zator-adaptive-reconcile.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
grep -q 'adaptive-lan-reconcile.sh' "$ROOT/Entware/000-zapret2.sh" || { echo 'NDM hook does not invoke the Bash reconcile helper' >&2; exit 1; }
grep -Fq '"$_adaptive_bash" "$_adaptive_reconcile"' "$ROOT/Entware/000-zapret2.sh" || { echo 'NDM hook does not invoke the reconcile helper through Bash' >&2; exit 1; }
grep -Fq 'PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH' "$ROOT/Entware/000-zapret2.sh" || { echo 'NDM hook does not include the Entware Bash path' >&2; exit 1; }
grep -q "adaptive-lan-reconcile.sh" "$ROOT/z2r.sh" || { echo 'runtime updater omits the NDM reconcile helper' >&2; exit 1; }
grep -q "adaptive-lan-reconcile.sh" "$ROOT/webui-src/scripts/pack-zator-tar.mjs" || { echo 'release package omits the NDM reconcile helper' >&2; exit 1; }
. "$ROOT/lib/supersweep_transport.sh"
. "$ROOT/lib/adaptive_lan_transport.sh"

ID=0123456789abcdef0123456789abcdef
RUN="$TMP/runs/$ID"
Z2R_ADAPTIVE_DIR="$TMP/runs"
Z2R_ADAPTIVE_LOCK_DIR="$TMP/shared.lock"
Z2R_ADAPTIVE_QUEUE_FILE="$TMP/queues"
Z2R_ADAPTIVE_PROC_ROOT="$TMP/proc"
Z2R_ADAPTIVE_BOOT_ID_FILE="$TMP/boot_id"
Z2R_ADAPTIVE_NFQWS2_PID=2000000000
Z2R_SUPERSWEEP_DIR="$RUN"
ZATOR_ROOT="$TMP/zator"
FWTYPE=iptables
DESYNC_MARK=0x40000000
IPT_MAIN=0
IPT_POST=0
CALLS="$TMP/iptables.log"
mkdir -p "$RUN/leases" "$RUN/probe" "$TMP/proc/$$" "$TMP/proc/2000000000" "$ZATOR_ROOT/extra_strats/cache/adaptive"
touch "$RUN/probe/locked.lua"
printf 'boot-test\n' > "$Z2R_ADAPTIVE_BOOT_ID_FILE"
printf 'TEST_ONLY\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
printf '65535 2000000000 0 2 0 0 0 0 1\n' > "$Z2R_ADAPTIVE_QUEUE_FILE"
printf '%s\0%s\0%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=65535' '--uid=65533:65533' "--lua-init=@$RUN/probe/locked.lua" > "$TMP/proc/2000000000/cmdline"
printf '%s\0%s\0%s\0' "$ZATOR_ROOT/tools/adaptive-controller.sh" "$ID" "$RUN" > "$TMP/proc/$$/cmdline"
adaptive_lan_lease_write "$RUN/leases" "$ID" 192.168.1.20 62000 142.250.72.14 "$(( $(date +%s) + 120 ))" "$(date +%s)" tls-http1-v1

iptables() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$*" in
    *' -N Z2R_ADAPTIVE_LAN_POST'*) IPT_POST=1 ;;
    *' -N Z2R_ADAPTIVE_LAN'*) IPT_MAIN=1 ;;
    *' -X Z2R_ADAPTIVE_LAN_POST'*) IPT_POST=0 ;;
    *' -X Z2R_ADAPTIVE_LAN'*) IPT_MAIN=0 ;;
    *' -S Z2R_ADAPTIVE_LAN_POST'*) [[ "$IPT_POST" = 1 ]] && return 0 || return 1 ;;
    *' -S Z2R_ADAPTIVE_LAN'*) [[ "$IPT_MAIN" = 1 ]] && return 0 || return 1 ;;
    *' -C FORWARD '*z2r-adaptive-lan-reply*) [[ "$IPT_MAIN" = 1 ]] && return 0 || return 1 ;;
    *' -C FORWARD '*z2r-adaptive-lan-original*) [[ "$IPT_MAIN" = 1 ]] && return 0 || return 1 ;;
    *' -C POSTROUTING '*z2r-adaptive-lan-post*) [[ "$IPT_POST" = 1 ]] && return 0 || return 1 ;;
    *' -S '*) return 0 ;;
    *) return 0 ;;
  esac
}

adaptive_lan_transport_start "$RUN/leases" "$ID" "$(date +%s)"
_adaptive_lan_write_transport_state "$RUN" "$ID" "$_Z2R_ADAPTIVE_LAN_MARK" "$DESYNC_MARK"
[[ -s "$RUN/probe/transport.tsv" && "$(stat -c %a "$RUN/probe/transport.tsv")" = 600 ]] || {
  echo 'private transport recovery record was not written' >&2; exit 1;
}

# Model NDM replacing its firewall tables while the controller and q65535 owner live.
IPT_MAIN=0
IPT_POST=0
adaptive_lan_transport_reconcile
[[ "$IPT_MAIN" = 1 && "$IPT_POST" = 1 ]] || { echo 'active adaptive rules were not restored' >&2; exit 1; }
grep -q -- '-I FORWARD 1 .*z2r-adaptive-lan-reply' "$CALLS" || { echo 'reply hook was not restored before production NFQUEUE' >&2; exit 1; }
grep -q -- '-I POSTROUTING 1 .*z2r-adaptive-lan-post' "$CALLS" || { echo 'postrouting production bypass was not restored' >&2; exit 1; }

adaptive_lan_transport_stop
[[ ! -e "$RUN/probe/transport.tsv" && ! -e "$Z2R_ADAPTIVE_LOCK_DIR" ]] || {
  echo 'restored transport cleanup left state or mutex behind' >&2; exit 1;
}

# A valid but changed lease must not widen the tuple rules after a rebuild.
mkdir "$Z2R_ADAPTIVE_LOCK_DIR"
printf 'adaptive-lan\t%s\tboot-test\n' "$$" > "$Z2R_ADAPTIVE_LOCK_DIR/owner"
_adaptive_lan_write_transport_state "$RUN" "$ID" 0x10000000 "$DESYNC_MARK"
adaptive_lan_lease_write "$RUN/leases" "$ID" 192.168.1.20 62000 142.250.72.15 \
  "$(( $(date +%s) + 120 ))" "$(date +%s)" tls-http1-v1
before="$(wc -l < "$CALLS")"
if adaptive_lan_transport_reconcile; then
  echo 'reconcile accepted a lease tuple changed after rules were installed' >&2; exit 1
fi
[[ "$IPT_MAIN" = 0 && "$IPT_POST" = 0 && "$(wc -l < "$CALLS")" = "$before" ]] || {
  echo 'reconcile mutated firewall for a mismatched lease' >&2; exit 1;
}
echo 'adaptive LAN NDM reconcile smoke: ok'
