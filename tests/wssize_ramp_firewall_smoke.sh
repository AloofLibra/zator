#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/wssize-ramp-firewall.$$
trap 'rm -f "$TMP.rules" "$TMP.exempt" "$TMP.ips"' EXIT HUP INT TERM
: >"$TMP.rules"
: >"$TMP.exempt"

QNUM=300
FWTYPE=nftables
NFQWS2_ENABLE=1
Z2R_WSSIZE_RAMP_ENABLE=1
Z2R_WSSIZE_RAMP_IPSET="$TMP.ips"
printf '# googlevideo IPv4; generated=test\n188.244.8.77\n188.244.8.78\n' > "$TMP.ips"
NFQWS2_TCP_PKT_OUT=20
NFQWS2_TCP_PKT_IN=10
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000
ZAPRET_NFT_TABLE=zapret2
FLOWOFFLOAD=donttouch
get_postchain() { printf '%s' postnat; }
get_prechain() { printf '%s' prenat; }
nft_rule_exists() { grep -Fxq "$1 $2" "$TMP.rules"; }
nft_add_rule() {
	chain=$1; shift
	printf '%s %s\n' "$chain" "$*" >>"$TMP.rules"
}
nft_add_nfqws_flow_exempt_rule() { printf '%s\n' "$1" >>"$TMP.exempt"; }
. "$ROOT/tools/wssize-ramp-firewall.sh"

zapret_custom_firewall_nft
[ "$(wc -l <"$TMP.rules" | tr -d ' ')" = 4 ] || { echo "expected two direction rules per IP" >&2; exit 1; }
grep -Fq 'postnat_hook meta nfproto ipv4 ip daddr 188.244.8.77 tcp dport 443 ct original packets > 20' "$TMP.rules"
grep -Fq 'prenat_hook meta nfproto ipv4 ip saddr 188.244.8.77 tcp sport 443 ct reply packets > 10' "$TMP.rules"
grep -Fq 'queue num 300 bypass' "$TMP.rules"

# Re-applying the custom callback must not add duplicate rules.
zapret_custom_firewall_nft
[ "$(wc -l <"$TMP.rules" | tr -d ' ')" = 4 ] || { echo "duplicate rules after reapply" >&2; exit 1; }

# Production nft teardown deletes the whole zapret2 table before the flush
# callback; model that lifecycle and verify a fresh apply is clean.
: >"$TMP.rules"
zapret_custom_firewall_nft_flush
zapret_custom_firewall_nft
[ "$(wc -l <"$TMP.rules" | tr -d ' ')" = 4 ] || { echo "rules missing after remove/reapply" >&2; exit 1; }

Z2R_WSSIZE_RAMP_ENABLE=0
zapret_custom_firewall_nft
[ "$(wc -l <"$TMP.rules" | tr -d ' ')" = 4 ] || { echo "disabled mode changed firewall" >&2; exit 1; }
Z2R_WSSIZE_RAMP_ENABLE=1
printf '# googlevideo IPv4; generated=test\n999.1.1.1\n' > "$TMP.ips"
if zapret_custom_firewall_nft 2>/dev/null; then echo "invalid IP accepted" >&2; exit 1; fi

# Platforms without the postnat/prenat split use the native hook chains.
printf '# googlevideo IPv4; generated=test\n188.244.8.77\n188.244.8.78\n' > "$TMP.ips"
: >"$TMP.rules"
get_postchain() { printf '%s' postrouting; }
get_prechain() { printf '%s' prerouting; }
zapret_custom_firewall_nft
grep -Fq 'postrouting meta nfproto ipv4 ip daddr 188.244.8.77 tcp dport 443 ct original packets > 20' "$TMP.rules"
grep -Fq 'prerouting meta nfproto ipv4 ip saddr 188.244.8.77 tcp sport 443 ct reply packets > 10' "$TMP.rules"
grep -Fq 'daddr 188.244.8.78' "$TMP.rules"
echo "wssize_ramp firewall smoke ok"
