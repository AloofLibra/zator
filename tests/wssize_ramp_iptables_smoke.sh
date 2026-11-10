#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

MOCK_CHAINS='POSTROUTING INPUT FORWARD'
MOCK_RULES=''

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
	! mock_has_chain Z2R_WS_OUT && ! mock_has_chain Z2R_WS_IN || { echo 'custom chains remain' >&2; exit 1; }
	assert_no_rule POSTROUTING '-j Z2R_WS_OUT'
	assert_no_rule INPUT '-j Z2R_WS_IN'
	assert_no_rule FORWARD '-j Z2R_WS_IN'
}

FWTYPE=iptables
NFQWS2_ENABLE=1
Z2R_WSSIZE_RAMP_ENABLE=1
Z2R_WSSIZE_RAMP_IP=178.17.48.174
NFQWS2_TCP_PKT_OUT=20
NFQWS2_TCP_PKT_IN=10
QNUM=300
DESYNC_MARK=0x40000000
. "$ROOT/tools/wssize-ramp-firewall.sh"

zapret_custom_firewall 1
assert_rule Z2R_WS_OUT '-d 178.17.48.174 -p tcp --dport 443 -m connbytes --connbytes-dir original --connbytes-mode packets --connbytes 21: -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num 300 --queue-bypass'
assert_rule Z2R_WS_IN '-s 178.17.48.174 -p tcp --sport 443 -m connbytes --connbytes-dir reply --connbytes-mode packets --connbytes 11: -j NFQUEUE --queue-num 300 --queue-bypass'
assert_rule POSTROUTING '-j Z2R_WS_OUT'
assert_rule INPUT '-j Z2R_WS_IN'
assert_rule FORWARD '-j Z2R_WS_IN'

# Reapply must preserve one target rule and one hook per chain.
zapret_custom_firewall 1
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^Z2R_WS_OUT|')" = 1 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^Z2R_WS_IN|')" = 1 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^POSTROUTING|-j Z2R_WS_OUT$')" = 1 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^INPUT|-j Z2R_WS_IN$')" = 1 ]
[ "$(printf '%s\n' "$MOCK_RULES" | grep -c '^FORWARD|-j Z2R_WS_IN$')" = 1 ]

# An address change replaces the owned chain content instead of leaving stale IP rules.
Z2R_WSSIZE_RAMP_IP=178.17.48.175
zapret_custom_firewall 1
assert_no_rule Z2R_WS_OUT '-d 178.17.48.174 -p tcp --dport 443 -m connbytes --connbytes-dir original --connbytes-mode packets --connbytes 21: -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num 300 --queue-bypass'
assert_rule Z2R_WS_OUT '-d 178.17.48.175 -p tcp --dport 443 -m connbytes --connbytes-dir original --connbytes-mode packets --connbytes 21: -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num 300 --queue-bypass'

# Invalid input leaves the currently installed rules intact; disable and stop remove all owned rules.
Z2R_WSSIZE_RAMP_IP=999.1.1.1
if zapret_custom_firewall 1 2>/dev/null; then echo 'invalid IP accepted' >&2; exit 1; fi
assert_rule Z2R_WS_OUT '-d 178.17.48.175 -p tcp --dport 443 -m connbytes --connbytes-dir original --connbytes-mode packets --connbytes 21: -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num 300 --queue-bypass'
Z2R_WSSIZE_RAMP_ENABLE=0
zapret_custom_firewall 1
assert_chains_removed
Z2R_WSSIZE_RAMP_ENABLE=1
Z2R_WSSIZE_RAMP_IP=178.17.48.174
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
