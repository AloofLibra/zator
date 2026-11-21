#!/usr/bin/env bash
# Mock-only recovery for an adaptive nft lease erased during a firewall rebuild.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zator-adaptive-nft-reconcile.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
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
FWTYPE=nftables
DESYNC_MARK=0x40000000
POSTNAT=1
ZAPRET_NFT_TABLE=zapret2
NFT_ACTIVE="$TMP/active"
NFT_CALLS="$TMP/nft.log"
export ID RUN Z2R_ADAPTIVE_DIR Z2R_ADAPTIVE_LOCK_DIR Z2R_ADAPTIVE_QUEUE_FILE
export Z2R_ADAPTIVE_PROC_ROOT Z2R_ADAPTIVE_BOOT_ID_FILE Z2R_ADAPTIVE_NFQWS2_PID
export Z2R_SUPERSWEEP_DIR ZATOR_ROOT FWTYPE DESYNC_MARK POSTNAT ZAPRET_NFT_TABLE
mkdir -p "$RUN/leases" "$RUN/probe" "$TMP/proc/$$" "$TMP/proc/2000000000" "$ZATOR_ROOT/extra_strats/cache/adaptive"
touch "$RUN/probe/locked.lua"
printf 'boot-test\n' > "$Z2R_ADAPTIVE_BOOT_ID_FILE"
printf 'TEST_ONLY\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
printf '65535 2000000000 0 2 0 0 0 0 1\n' > "$Z2R_ADAPTIVE_QUEUE_FILE"
printf '%s\0%s\0%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=65535' '--uid=65533:65533' "--lua-init=@$RUN/probe/locked.lua" > "$TMP/proc/2000000000/cmdline"
printf '%s\0%s\0%s\0' "$ZATOR_ROOT/tools/adaptive-controller.sh" "$ID" "$RUN" > "$TMP/proc/$$/cmdline"
adaptive_lan_lease_write "$RUN/leases" "$ID" 192.168.1.20 62000 142.250.72.14 "$(( $(date +%s) + 120 ))" "$(date +%s)" tls-http1-v1
_adaptive_lan_write_transport_state "$RUN" "$ID" 0x10000000 "$DESYNC_MARK"
mkdir "$Z2R_ADAPTIVE_LOCK_DIR"
printf 'adaptive-lan\t%s\tboot-test\n' "$$" > "$Z2R_ADAPTIVE_LOCK_DIR/owner"
touch "$NFT_ACTIVE"

nft() {
  printf '%s\n' "$*" >> "$NFT_CALLS"
  case "$*" in
    '-a list chain inet zapret2 postnat_hook')
      if [[ -e "$NFT_ACTIVE" ]]; then printf '%s\n' 'chain postnat_hook {' ' jump z2r_adaptive_lan comment "z2r_adaptive_lan_post" # handle 101'; else printf '%s\n' 'chain postnat_hook {'; fi ;;
    '-a list chain inet zapret2 prenat_hook')
      if [[ -e "$NFT_ACTIVE" && ! -e "$TMP/partial" ]]; then printf '%s\n' 'chain prenat_hook {' ' jump z2r_adaptive_lan comment "z2r_adaptive_lan_pre" # handle 102'; else printf '%s\n' 'chain prenat_hook {'; fi ;;
    '-a list chain inet zapret2 z2r_adaptive_lan')
      [[ -e "$NFT_ACTIVE" ]] || return 1
      printf '%s\n' 'chain z2r_adaptive_lan {'
      for direction in original reply; do
        offset=0; [[ "$direction" != reply ]] || offset=3
        printf ' rule meta l4proto tcp ct direction %s ct original ip saddr 192.168.1.20 ct original proto-src 62000 ct original ip daddr 142.250.72.14 ct original proto-dst 443 meta mark set meta mark | 0x10000000 comment "z2r_adaptive_lan" # handle %s\n' "$direction" "$((201 + offset))"
        printf ' rule meta l4proto tcp ct direction %s ct original ip saddr 192.168.1.20 ct original proto-src 62000 ct original ip daddr 142.250.72.14 ct original proto-dst 443 queue flags bypass to 65535 comment "z2r_adaptive_lan" # handle %s\n' "$direction" "$((202 + offset))"
        printf ' rule meta l4proto tcp ct direction %s ct original ip saddr 192.168.1.20 ct original proto-src 62000 ct original ip daddr 142.250.72.14 ct original proto-dst 443 accept comment "z2r_adaptive_lan" # handle %s\n' "$direction" "$((203 + offset))"
      done ;;
    'list chain inet zapret2 z2r_adaptive_lan') [[ -e "$NFT_ACTIVE" ]] ;;
    '-a list ruleset')
      if [[ -e "$NFT_ACTIVE" ]]; then
        printf '%s\n' 'table inet zapret2 {' ' chain z2r_adaptive_lan {' '  meta mark set meta mark | 0x10000000 comment "z2r_adaptive_lan"' ' }' '}'
      else printf '%s\n' 'table inet zapret2 { }'; fi ;;
    '-f -')
      cat > "$TMP/batch"
      touch "$NFT_ACTIVE"
      ;;
    *) return 1 ;;
  esac
}

# Model a fw4 reload that erased this private lease chain while nfqws2 stayed up.
rm -f "$NFT_ACTIVE"
adaptive_lan_transport_reconcile
[[ -e "$NFT_ACTIVE" ]] || { echo 'nft lease chain was not restored after rebuild' >&2; exit 1; }
[[ "$(_adaptive_lan_pick_test_mark)" = 0x10000000 ]] || { echo 'mark selection collided with its own restored nft chain' >&2; exit 1; }
stat() { return 127; }
adaptive_lan_transport_reconcile || { echo 'intact nft lease was not stable under repeated reconcile' >&2; exit 1; }
unset -f stat
grep -q 'insert rule inet zapret2 postnat_hook jump z2r_adaptive_lan' "$TMP/batch" || { echo 'nft postnat jump was not rebuilt' >&2; exit 1; }
grep -q 'insert rule inet zapret2 prenat_hook jump z2r_adaptive_lan' "$TMP/batch" || { echo 'nft prenat jump was not rebuilt' >&2; exit 1; }
grep -q 'queue flags bypass to 65535' "$TMP/batch" || { echo 'test queue routing was not rebuilt' >&2; exit 1; }
touch "$TMP/partial"
before="$(grep -c '^-f -$' "$NFT_CALLS" || true)"
if adaptive_lan_transport_reconcile; then echo 'partial nft lease state was accepted' >&2; exit 1; fi
[[ "$(grep -c '^-f -$' "$NFT_CALLS" || true)" = "$before" ]] || { echo 'partial nft state caused firewall mutation' >&2; exit 1; }
echo 'adaptive LAN nft reconcile smoke: ok'
