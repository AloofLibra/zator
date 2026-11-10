#!/bin/sh
# zapret2 custom firewall hooks. Add address-specific queue rules only after
# the normal packet caps; keep nftables and iptables lifecycles independent.

z2r_wssize_ramp_valid_ipv4() {
	local ip="$1" o1 o2 o3 o4 extra
	case "$ip" in *[!0-9.]*|.*|*.|*..*) return 1 ;; esac
	oldifs="$IFS"; IFS=.; set -- $ip; IFS="$oldifs"
	[ "$#" -eq 4 ] || return 1
	for octet in "$@"; do
		case "$octet" in ''|*[!0-9]*) return 1 ;; esac
		[ "$octet" -le 255 ] 2>/dev/null || return 1
	done
	return 0
}

zapret_custom_firewall_nft() {
	[ "$NFQWS2_ENABLE" = 1 ] || return 0
	[ "$Z2R_WSSIZE_RAMP_ENABLE" = 1 ] || return 0
	z2r_wssize_ramp_valid_ipv4 "$Z2R_WSSIZE_RAMP_IP" || {
		echo "wssize_ramp: invalid IPv4 address; no extra queue rules installed" >&2
		return 1
	}
	[ "$FWTYPE" = nftables ] || return 0

	local post pre out in rule
	post="$(get_postchain)"
	pre="$(get_prechain)"
	# OpenWrt's postnat_hook/prenat_hook only jump into postnat/prenat while
	# DESYNC_MARK is absent. The stock NFQUEUE rules set that conntrack mark on
	# early packets, so late target packets never reach rules appended to the
	# inner chains. Append after the jump in the hook chain instead; this keeps
	# the normal 20/10 ranges first and still sees marked packets after them.
	[ "$post" != postnat ] || post=postnat_hook
	[ "$pre" != prenat ] || pre=prenat_hook
	out="${NFQWS2_TCP_PKT_OUT:-20}"
	in="${NFQWS2_TCP_PKT_IN:-10}"
	case "$out:$in" in *[!0-9:]*|:*) echo "wssize_ramp: invalid TCP packet limits" >&2; return 1 ;; esac

	# Queue only packets that have passed the ordinary limiter. This preserves
	# the normal 20/10 packet behavior for every other destination and avoids
	# placing a duplicate NFQUEUE verdict on the first packets of this flow.
	rule="meta nfproto ipv4 ip daddr $Z2R_WSSIZE_RAMP_IP tcp dport 443 ct original packets > $out"
	if ! nft_rule_exists "$post" "$rule counter meta mark set meta mark or $DESYNC_MARK_POSTNAT ct mark set ct mark or $DESYNC_MARK queue num $QNUM bypass"; then
		nft_add_rule "$post" $rule counter meta mark set meta mark or "$DESYNC_MARK_POSTNAT" ct mark set ct mark or "$DESYNC_MARK" queue num "$QNUM" bypass || return 1
	fi
	rule="meta nfproto ipv4 ip saddr $Z2R_WSSIZE_RAMP_IP tcp sport 443 ct reply packets > $in"
	if ! nft_rule_exists "$pre" "$rule counter ct mark set ct mark or $DESYNC_MARK queue num $QNUM bypass"; then
		nft_add_rule "$pre" $rule counter ct mark set ct mark or "$DESYNC_MARK" queue num "$QNUM" bypass || return 1
	fi
	# OpenWrt flow offload otherwise bypasses the late packets altogether.
	rule="meta nfproto ipv4 ip daddr $Z2R_WSSIZE_RAMP_IP tcp dport 443"
	if [ "$FLOWOFFLOAD" = software ] || [ "$FLOWOFFLOAD" = hardware ]; then
		if ! nft_rule_exists flow_offload_zapret "$rule return comment \"direct flow offloading exemption\""; then
			nft_add_nfqws_flow_exempt_rule "$rule"
		fi
	fi
	return 0
}

# nftables teardown deletes the entire zapret2 table before this hook runs.
zapret_custom_firewall_nft_flush() { return 0; }

z2r_wssize_iptables_remove_jump() {
	local chain="$1" target="$2"
	while iptables -t mangle -C "$chain" -j "$target" >/dev/null 2>&1; do
		iptables -t mangle -D "$chain" -j "$target" || return 1
	done
	return 0
}

z2r_wssize_iptables_remove_chain() {
	local chain="$1"
	iptables -t mangle -nL "$chain" >/dev/null 2>&1 || return 0
	iptables -t mangle -F "$chain" || return 1
	iptables -t mangle -X "$chain" || return 1
}

z2r_wssize_iptables_cleanup() {
	local hook
	z2r_wssize_iptables_remove_jump POSTROUTING Z2R_WS_OUT || return 1
	for hook in INPUT FORWARD; do
		z2r_wssize_iptables_remove_jump "$hook" Z2R_WS_IN || return 1
	done
	z2r_wssize_iptables_remove_chain Z2R_WS_OUT || return 1
	z2r_wssize_iptables_remove_chain Z2R_WS_IN
}

z2r_wssize_iptables_install() {
	local ip="$1" out="$2" in="$3" qnum="$4" mark="$5"
	local out_from=$((out + 1)) in_from=$((in + 1)) hook
	local out_rule="-d $ip -p tcp --dport 443 -m connbytes --connbytes-dir original --connbytes-mode packets --connbytes $out_from: -m mark ! --mark $mark/$mark -j NFQUEUE --queue-num $qnum --queue-bypass"
	local in_rule="-s $ip -p tcp --sport 443 -m connbytes --connbytes-dir reply --connbytes-mode packets --connbytes $in_from: -j NFQUEUE --queue-num $qnum --queue-bypass"

	# Build the chains before adding jumps. A restart flushes and replaces their
	# contents, which also removes stale address rules if the configured IP changed.
	# Append the hooks after zapret2's own rules: packets 1..N still reach its
	# normal NFQUEUE limiter first, and existing mark/ACCEPT decisions keep priority.
	iptables -t mangle -N Z2R_WS_OUT 2>/dev/null || :
	iptables -t mangle -N Z2R_WS_IN 2>/dev/null || :
	iptables -t mangle -F Z2R_WS_OUT || return 1
	iptables -t mangle -F Z2R_WS_IN || return 1
	iptables -t mangle -A Z2R_WS_OUT $out_rule || return 1
	iptables -t mangle -A Z2R_WS_IN $in_rule || return 1
	for hook in POSTROUTING; do
		iptables -t mangle -C "$hook" -j Z2R_WS_OUT >/dev/null 2>&1 ||
			iptables -t mangle -A "$hook" -j Z2R_WS_OUT || return 1
	done
	for hook in INPUT FORWARD; do
		iptables -t mangle -C "$hook" -j Z2R_WS_IN >/dev/null 2>&1 ||
			iptables -t mangle -A "$hook" -j Z2R_WS_IN || return 1
	done
	return 0
}

zapret_custom_firewall() {
	local action="${1:-}" ip out in qnum mark
	case "$action" in
		0) z2r_wssize_iptables_cleanup; return $? ;;
		1) ;;
		*) echo "wssize_ramp: invalid iptables action" >&2; return 1 ;;
	esac
	[ "$FWTYPE" = iptables ] || return 0
	if [ "$NFQWS2_ENABLE" != 1 ] || [ "$Z2R_WSSIZE_RAMP_ENABLE" != 1 ]; then
		z2r_wssize_iptables_cleanup
		return $?
	fi
	ip="$Z2R_WSSIZE_RAMP_IP"
	z2r_wssize_ramp_valid_ipv4 "$ip" || {
		echo "wssize_ramp: invalid IPv4 address; no iptables rules installed" >&2
		return 1
	}
	out="${NFQWS2_TCP_PKT_OUT:-20}"
	in="${NFQWS2_TCP_PKT_IN:-10}"
	qnum="${QNUM:-}"
	mark="${DESYNC_MARK:-}"
	case "$out:$in:$qnum:$mark" in *[!0-9A-Fa-fx:]*|:*|*::*|*:) echo "wssize_ramp: invalid iptables queue/mark/packet limits" >&2; return 1 ;; esac
	case "$out:$in" in *[!0-9:]*|:*) echo "wssize_ramp: invalid TCP packet limits" >&2; return 1 ;; esac
	z2r_wssize_iptables_install "$ip" "$out" "$in" "$qnum" "$mark"
}
