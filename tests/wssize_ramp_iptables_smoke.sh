#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

MOCK_CHAINS='PREROUTING POSTROUTING INPUT FORWARD'
MOCK_RULES=''
MOCK_IPSET_FILE="${TMPDIR:-/tmp}/wssize-ramp-iptables-set.$$"
: > "$MOCK_IPSET_FILE"

ipset() {
	case "$1" in
		create) return 0 ;;
		restore)
			while IFS= read -r line; do
				case "$line" in add\ z2r_googlevideo4\ *) ip=${line#add z2r_googlevideo4 }; ip=${ip%% *}; grep -Fxq "$ip" "$MOCK_IPSET_FILE" || echo "$ip" >> "$MOCK_IPSET_FILE" ;; esac
			done
			return 0 ;;
		*) return 0 ;;
	esac
}

mock_has_chain() {
	case " $MOCK_CHAINS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

mock_has_rule() {
	local key="$1|$2" line
	while IFS= read -r line; do [ "$line" != "$key" ] || return 0; done <<< "$MOCK_RULES"
	return 1
}

iptables() {
	[ "$1" = -t ] && [ "$2" = mangle ] || return 2
	shift 2
	local op="$1" chain rule key line next removed
	shift
	case "$op" in
		-N)
			chain="$1"; mock_has_chain "$chain" && return 1
			MOCK_CHAINS="$MOCK_CHAINS $chain"; return 0 ;;
		-nL)
			mock_has_chain "$1" ;;
		-F)
			chain="$1"; mock_has_chain "$chain" || return 1
			next=''; while IFS= read -r line; do case "$line" in "$chain"\|*) ;; *) [ -z "$line" ] || next="${next}${line}"$'\n' ;; esac; done <<< "$MOCK_RULES"
			MOCK_RULES="$next"; return 0 ;;
		-X)
			chain="$1"; mock_has_chain "$chain" || return 1
			next=''; for line in $MOCK_CHAINS; do [ "$line" = "$chain" ] || next="$next $line"; done
			MOCK_CHAINS="$next"
			return 0 ;;
		-A)
			chain="$1"; shift; rule="$*"; mock_has_chain "$chain" || return 1
			MOCK_RULES="${MOCK_RULES}${chain}|${rule}"$'\n'; return 0 ;;
		-I)
			chain="$1"; shift; [ "${1:-}" != 1 ] || shift; rule="$*"; mock_has_chain "$chain" || return 1
			MOCK_RULES="${chain}|${rule}"$'\n'"$MOCK_RULES"; return 0 ;;
		-C)
			chain="$1"; shift; rule="$*"; mock_has_rule "$chain" "$rule" ;;
		-D)
			chain="$1"; shift; rule="$*"; key="$chain|$rule"; next=''; removed=0
			while IFS= read -r line; do
				if [ "$removed" = 0 ] && [ "$line" = "$key" ]; then removed=1; continue; fi
				[ -z "$line" ] || next="${next}${line}"$'\n'
			done <<< "$MOCK_RULES"
			[ "$removed" = 1 ] || return 1; MOCK_RULES="$next"; return 0 ;;
		*) return 2 ;;
	esac
}

assert_rule() { mock_has_rule "$1" "$2" || { echo "missing rule: $1 $2" >&2; exit 1; }; }
assert_no_rule() { ! mock_has_rule "$1" "$2" || { echo "stale rule: $1 $2" >&2; exit 1; }; }
assert_chains_removed() {
	! mock_has_chain Z2R_WS_OUT && ! mock_has_chain Z2R_WS_IN && ! mock_has_chain Z2R_WS_MARK || { echo 'custom chains remain' >&2; exit 1; }
	assert_no_rule POSTROUTING '-j Z2R_WS_OUT'
	assert_no_rule INPUT '-j Z2R_WS_IN'
	assert_no_rule FORWARD '-j Z2R_WS_IN'
	assert_no_rule PREROUTING '-j Z2R_WS_MARK'
	assert_no_rule POSTROUTING '-j Z2R_WS_MARK'
}

FWTYPE=iptables
NFQWS2_ENABLE=1
Z2R_WSSIZE_RAMP_ENABLE=1
Z2R_WSSIZE_RAMP_IPSET="${TMPDIR:-/tmp}/wssize-ramp-iptables-ips.$$"
printf '# googlevideo IPv4; generated=test\n178.17.48.174\n' > "$Z2R_WSSIZE_RAMP_IPSET"
trap 'rm -f "$Z2R_WSSIZE_RAMP_IPSET" "$MOCK_IPSET_FILE"' EXIT
NFQWS2_TCP_PKT_OUT=20
NFQWS2_TCP_PKT_IN=10
QNUM=300
DESYNC_MARK=0x40000000
. "$ROOT/tools/wssize-ramp-firewall.sh"

zapret_custom_firewall 1
assert_rule Z2R_WS_MARK '-m set --match-set z2r_googlevideo4 dst -p tcp --dport 443 -m mark ! --mark 0x40000000/0x40000000 -j MARK --set-xmark 0x04000000/0x04000000'
assert_rule Z2R_WS_MARK '-m set --match-set z2r_googlevideo4 src -p tcp --sport 443 -m mark ! --mark 0x40000000/0x40000000 -j MARK --set-xmark 0x04000000/0x04000000'
assert_rule Z2R_WS_OUT '-m mark --mark 0x04000000/0x04000000 -p tcp --dport 443 -m connbytes --connbytes-dir original --connbytes-mode packets --connbytes 21: -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num 300 --queue-bypass'
assert_rule Z2R_WS_IN '-m mark --mark 0x04000000/0x04000000 -p tcp --sport 443 -m connbytes --connbytes-dir reply --connbytes-mode packets --connbytes 11: -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num 300 --queue-bypass'
assert_rule PREROUTING '-j Z2R_WS_MARK'
assert_rule POSTROUTING '-j Z2R_WS_MARK'
assert_rule POSTROUTING '-j Z2R_WS_OUT'
assert_rule INPUT '-j Z2R_WS_IN'
assert_rule FORWARD '-j Z2R_WS_IN'

# Reapply must preserve one target rule and one hook per chain.
zapret_custom_firewall 1
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^Z2R_WS_MARK|')" = 2 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^Z2R_WS_OUT|')" = 1 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^Z2R_WS_IN|')" = 1 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^POSTROUTING|-j Z2R_WS_OUT$')" = 1 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^INPUT|-j Z2R_WS_IN$')" = 1 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^FORWARD|-j Z2R_WS_IN$')" = 1 ]

# Adding a DNS address updates only the shared kernel set, not firewall rules.
printf '# googlevideo IPv4; generated=test\n178.17.48.175\n' > "$Z2R_WSSIZE_RAMP_IPSET"
zapret_custom_firewall 1
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^Z2R_WS_OUT|')" = 1 ]
grep -Fxq 178.17.48.174 "$MOCK_IPSET_FILE" || { echo 'existing kernel set member was lost' >&2; exit 1; }
grep -Fxq 178.17.48.175 "$MOCK_IPSET_FILE" || { echo 'kernel set did not merge new address' >&2; exit 1; }

# Invalid input leaves the currently installed rules intact; disable and stop remove all owned rules.
printf '# googlevideo IPv4; generated=test\n999.1.1.1\n' > "$Z2R_WSSIZE_RAMP_IPSET"
if zapret_custom_firewall 1 2>/dev/null; then echo 'invalid IP accepted' >&2; exit 1; fi
assert_rule Z2R_WS_MARK '-m set --match-set z2r_googlevideo4 dst -p tcp --dport 443 -m mark ! --mark 0x40000000/0x40000000 -j MARK --set-xmark 0x04000000/0x04000000'
printf '# googlevideo IPv4; generated=test\n178.17.48.175\n' > "$Z2R_WSSIZE_RAMP_IPSET"
Z2R_WSSIZE_RAMP_MODE=lite
zapret_custom_firewall 1
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^Z2R_WS_OUT|')" = 0 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^Z2R_WS_IN|')" = 0 ]
assert_rule Z2R_WS_MARK '-m set --match-set z2r_googlevideo4 dst -p tcp --dport 443 -m mark ! --mark 0x40000000/0x40000000 -j MARK --set-xmark 0x04000000/0x04000000'
Z2R_WSSIZE_RAMP_ENABLE=0
zapret_custom_firewall 1
assert_chains_removed
Z2R_WSSIZE_RAMP_ENABLE=1
Z2R_WSSIZE_RAMP_MODE=full
printf '# googlevideo IPv4; generated=test\n178.17.48.174\n' > "$Z2R_WSSIZE_RAMP_IPSET"
zapret_custom_firewall 1
zapret_custom_firewall 0
assert_chains_removed
zapret_custom_firewall 0
assert_chains_removed
zapret_custom_firewall 1
NFQWS2_ENABLE=0
zapret_custom_firewall 1
assert_chains_removed
echo 'wssize_ramp iptables smoke ok'
