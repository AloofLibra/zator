#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/wssize-ramp-firewall.$$
trap 'rm -f "$TMP.rules" "$TMP.set" "$TMP.ips"' EXIT HUP INT TERM
: >"$TMP.rules"; : >"$TMP.set"; NFT_SET_CREATED=0
QNUM=300 FWTYPE=nftables NFQWS2_ENABLE=1 Z2R_WSSIZE_RAMP_ENABLE=1
Z2R_WSSIZE_RAMP_IPSET="$TMP.ips" NFQWS2_TCP_PKT_OUT=20 NFQWS2_TCP_PKT_IN=10
DESYNC_MARK=0x40000000 DESYNC_MARK_POSTNAT=0x20000000 ZAPRET_NFT_TABLE=zapret2 FLOWOFFLOAD=donttouch
printf '# googlevideo IPv4; generated=test\n188.244.8.77\n188.244.8.78\n' > "$TMP.ips"
get_postchain() { echo postnat; }; get_prechain() { echo prenat; }
nft() {
  if [ "$1" = list ] && [ "$2" = set ]; then
    [ "$NFT_SET_CREATED" = 1 ] || return 1
    [ ! -s "$TMP.set" ] || { printf 'elements = { '; paste -sd, "$TMP.set"; printf ' }\n'; }
    return 0
  fi
  if [ "$1" = add ] && [ "$2" = set ]; then NFT_SET_CREATED=1; return 0; fi
  if [ "$1" = -f ]; then
    sed -n 's/.*{ \(.*\) }/\1/p' "$2" | tr ',' '\n' | tr -d ' ' >> "$TMP.set"
    sort -u "$TMP.set" -o "$TMP.set"; return 0
  fi
  return 2
}
nft_rule_exists() { grep -Fxq "$1 $2" "$TMP.rules"; }
nft_insert_rule() { chain=$1; shift; printf '%s %s\n' "$chain" "$*" >> "$TMP.rules"; }
nft_add_rule() { chain=$1; shift; printf '%s %s\n' "$chain" "$*" >> "$TMP.rules"; }
nft_add_nfqws_flow_exempt_rule() { :; }
. "$ROOT/tools/wssize-ramp-firewall.sh"

zapret_custom_firewall_nft
[ "$(wc -l < "$TMP.rules" | tr -d ' ')" = 4 ] || { echo "expected two mark and two Full late rules" >&2; exit 1; }
grep -Fq 'daddr @z2r_googlevideo4 tcp dport 443' "$TMP.rules"
grep -Fq 'saddr @z2r_googlevideo4 tcp sport 443' "$TMP.rules"
grep -Fq 'ct original packets > 20' "$TMP.rules"
grep -Fq 'ct reply packets > 10' "$TMP.rules"
[ "$(wc -l < "$TMP.set" | tr -d ' ')" = 2 ]

# Reapplying leaves the rule count fixed; new addresses merge into the kernel set.
zapret_custom_firewall_nft
[ "$(wc -l < "$TMP.rules" | tr -d ' ')" = 4 ] || { echo "duplicate rules after reapply" >&2; exit 1; }
printf '# googlevideo IPv4; generated=test\n188.244.8.77\n188.244.8.78\n188.244.8.79\n' > "$TMP.ips"
zapret_custom_firewall_nft
[ "$(wc -l < "$TMP.rules" | tr -d ' ')" = 4 ] || { echo "IP update changed rule count" >&2; exit 1; }
grep -Fxq 188.244.8.79 "$TMP.set"

# Lite relies on the normal 20/10 profile limits and installs no late ACK rules.
: > "$TMP.rules"
Z2R_WSSIZE_RAMP_MODE=lite
zapret_custom_firewall_nft
[ "$(wc -l < "$TMP.rules" | tr -d ' ')" = 2 ] || { echo "Lite installed late packet rules" >&2; exit 1; }
! grep -q 'ct original packets\|ct reply packets' "$TMP.rules"

# Disabled callback adds no rules and never flushes dnsmasq's live set.
Z2R_WSSIZE_RAMP_ENABLE=0
before=$(wc -l < "$TMP.set")
zapret_custom_firewall_nft
[ "$(wc -l < "$TMP.rules" | tr -d ' ')" = 2 ]
[ "$(wc -l < "$TMP.set")" = "$before" ]
echo 'wssize_ramp nft set smoke ok'
