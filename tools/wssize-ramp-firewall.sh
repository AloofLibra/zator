#!/bin/sh
# Mark Googlevideo flows from the shared kernel set before nfqws2 profile
# selection. Full mode adds a constant number of late queue rules; Lite uses
# only the normal packet limits.

Z2R_GOOGLEVIDEO_SET=z2r_googlevideo4
Z2R_WSSIZE_MARK="${Z2R_WSSIZE_MARK:-0x04000000}"
Z2R_WSSIZE_MARK_MASK="$Z2R_WSSIZE_MARK"

zapret_custom_daemons() {
	local listener=/opt/zator/tools/googlevideo-dns-listener.sh
	[ -x "$listener" ] || return 0
	if [ "$1" != 1 ]; then "$listener" stop; return 0; fi
	[ "$NFQWS2_ENABLE" = 1 ] && [ "$Z2R_WSSIZE_RAMP_ENABLE" = 1 ] || return 0
	if command -v procd_open_instance >/dev/null 2>&1; then
		command -v ubus >/dev/null 2>&1 || return 0
		ubus list 2>/dev/null | grep -Fxq dnsmasq.dns || return 0
		procd_open_instance z2r_googlevideo_dns
		procd_set_param command /bin/bash "$listener" run
		procd_set_param respawn 3600 5 5
		procd_set_param stdout 1
		procd_set_param stderr 1
		procd_close_instance
	else
		"$listener" start
	fi
}

z2r_wssize_ramp_valid_ipv4() {
	local ip="$1" oldifs="$IFS"
	case "$ip" in *[!0-9.]*|.*|*.|*..*) return 1 ;; esac
	IFS=.; set -- $ip; IFS="$oldifs"
	[ "$#" -eq 4 ] || return 1
	for octet in "$@"; do
		case "$octet" in ''|*[!0-9]*) return 1 ;; esac
		[ "$octet" -le 255 ] 2>/dev/null || return 1
	done
	return 0
}

z2r_wssize_ramp_ips() {
	local file="${Z2R_WSSIZE_RAMP_IPSET:-/opt/zator/lists/googlevideo-ipv4.txt}" ip count=0
	[ -s "$file" ] || return 0
	while IFS= read -r ip; do
		case "$ip" in ''|\#*) continue ;; esac
		z2r_wssize_ramp_valid_ipv4 "$ip" || { echo "wssize_ramp: invalid IPv4 in $file" >&2; return 1; }
		printf '%s\n' "$ip"
		count=$((count + 1))
		[ "$count" -le 8192 ] || { echo "wssize_ramp: too many IPs in $file" >&2; return 1; }
	done < "$file"
}

z2r_wssize_mark_validate() {
	local mark
	case "$Z2R_WSSIZE_MARK:$Z2R_WSSIZE_MARK_MASK" in *[!0-9A-Fa-fxX:]*|:*|*:) echo "wssize_ramp: invalid mark" >&2; return 1 ;; esac
	[ "$Z2R_WSSIZE_MARK" != 0 ] && [ "$Z2R_WSSIZE_MARK_MASK" != 0 ] || { echo "wssize_ramp: zero mark" >&2; return 1; }
	# Keep the Ramp selector out of zapret, postnat, generic-filter,
	# client-scope and SuperSweep mark fields.
	for mark in "${DESYNC_MARK:-0}" "${DESYNC_MARK_POSTNAT:-0}" "${FILTER_MARK:-0}" \
		"${CLIENT_SCOPE_MARK_MASK:-0}" "${Z2R_SUPERSWEEP_MARK:-0x08000000}"; do
		case "$mark" in ''|0) continue ;; *[!0-9A-Fa-fxX]*) return 1 ;; esac
		[ $((Z2R_WSSIZE_MARK & mark)) -eq 0 ] || {
			echo "wssize_ramp: mark $Z2R_WSSIZE_MARK conflicts with $mark" >&2
			return 1
		}
	done
	return 0
}

z2r_wssize_nft_set_ensure() {
	local table="${ZAPRET_NFT_TABLE:-zapret2}"
	case "$table" in ''|*[!a-zA-Z0-9_]*) echo "wssize_ramp: invalid nft table name" >&2; return 1 ;; esac
	if ! nft list set inet "$table" "$Z2R_GOOGLEVIDEO_SET" >/dev/null 2>&1; then
		nft add set inet "$table" "$Z2R_GOOGLEVIDEO_SET" \
			'{ type ipv4_addr; flags timeout; timeout 7d; size 8192; }' || return 1
	fi
	return 0
}

z2r_wssize_nft_set_merge_file() {
	local ips="$1" table="${ZAPRET_NFT_TABLE:-zapret2}" elements missing tmp
	[ -n "$ips" ] || return 0
	missing="$( { nft list set inet "$table" "$Z2R_GOOGLEVIDEO_SET" 2>/dev/null | grep -oE '([0-9]{1,3}\\.){3}[0-9]{1,3}' || true
		printf '%s\n' '#Z2R_IP_END'
		printf '%s\n' "$ips"
	} | awk '$0 == "#Z2R_IP_END" { phase=1; next } !phase { present[$0]=1; next } NF && !present[$1] { print $1 }' | sort -u)" || return 1
	[ -n "$missing" ] || return 0
	elements="$(printf '%s\n' "$missing" | awk 'NF { if (n++) printf ", "; printf "%s", $0 }')"
	[ -n "$elements" ] || return 0
	tmp="${TMPDIR:-/tmp}/z2r-wssize-nft.$$"
	printf 'add element inet %s %s { %s }\n' "$table" "$Z2R_GOOGLEVIDEO_SET" "$elements" > "$tmp" || { rm -f "$tmp"; return 1; }
	nft -f "$tmp"; local rc=$?
	rm -f "$tmp"
	if [ "$rc" -ne 0 ]; then
		# DNSMasq may race a central merge by inserting the same member. Re-read
		# the set and retry the remaining deltas once.
		[ "${Z2R_WSSIZE_NFT_RETRY:-0}" = 1 ] && return "$rc"
		Z2R_WSSIZE_NFT_RETRY=1 z2r_wssize_nft_set_merge_file "$ips"
		return $?
	fi
	return "$rc"
}

z2r_wssize_ipset_ensure() {
	command -v ipset >/dev/null 2>&1 || { echo "wssize_ramp: ipset is required for iptables mode" >&2; return 1; }
	ipset create "$Z2R_GOOGLEVIDEO_SET" hash:ip family inet timeout 604800 -exist
}

z2r_wssize_ipset_merge_file() {
	local ips="$1" ip
	[ -n "$ips" ] || return 0
	{
		for ip in $ips; do printf 'add %s %s -exist\n' "$Z2R_GOOGLEVIDEO_SET" "$ip"; done
	} | ipset restore -exist
}

z2r_wssize_nft_mark_install() {
	local post pre mark_rule
	post="$(get_postchain)"; pre="$(get_prechain)"
	[ "$post" != postnat ] || post=postnat_hook
	[ "$pre" != prenat ] || pre=prenat_hook
	mark_rule="meta nfproto ipv4 ip daddr @$Z2R_GOOGLEVIDEO_SET tcp dport 443 meta mark & $Z2R_WSSIZE_MARK_MASK == 0 meta mark set meta mark or $Z2R_WSSIZE_MARK"
	if ! nft_rule_exists "$post" "$mark_rule"; then
		nft_insert_rule "$post" meta nfproto ipv4 ip daddr "@$Z2R_GOOGLEVIDEO_SET" tcp dport 443 meta mark \& "$Z2R_WSSIZE_MARK_MASK" == 0 meta mark set meta mark or "$Z2R_WSSIZE_MARK" || return 1
	fi
	mark_rule="meta nfproto ipv4 ip saddr @$Z2R_GOOGLEVIDEO_SET tcp sport 443 meta mark & $Z2R_WSSIZE_MARK_MASK == 0 meta mark set meta mark or $Z2R_WSSIZE_MARK"
	if ! nft_rule_exists "$pre" "$mark_rule"; then
		nft_insert_rule "$pre" meta nfproto ipv4 ip saddr "@$Z2R_GOOGLEVIDEO_SET" tcp sport 443 meta mark \& "$Z2R_WSSIZE_MARK_MASK" == 0 meta mark set meta mark or "$Z2R_WSSIZE_MARK" || return 1
	fi
	if [ "$FLOWOFFLOAD" = software ] || [ "$FLOWOFFLOAD" = hardware ]; then
		mark_rule="ip daddr @$Z2R_GOOGLEVIDEO_SET tcp dport 443"
		if ! nft_rule_exists flow_offload "$mark_rule return comment \"direct flow offloading exemption\""; then
			nft_add_nfqws_flow_exempt_rule "$mark_rule" || return 1
		fi
	fi
}

z2r_wssize_nft_late_install() {
	local post pre out in rule
	post="$(get_postchain)"; pre="$(get_prechain)"
	[ "$post" != postnat ] || post=postnat_hook
	[ "$pre" != prenat ] || pre=prenat_hook
	out="${NFQWS2_TCP_PKT_OUT:-20}"; in="${NFQWS2_TCP_PKT_IN:-10}"
	case "$out:$in" in *[!0-9:]*|:*) echo "wssize_ramp: invalid TCP packet limits" >&2; return 1 ;; esac
	rule="meta mark & $Z2R_WSSIZE_MARK_MASK == $Z2R_WSSIZE_MARK_MASK meta mark & $DESYNC_MARK == 0 meta nfproto ipv4 tcp dport 443 ct original packets > $out"
	if ! nft_rule_exists "$post" "$rule counter meta mark set meta mark or $DESYNC_MARK_POSTNAT ct mark set ct mark or $DESYNC_MARK queue num $QNUM bypass"; then
		nft_add_rule "$post" meta mark \& "$Z2R_WSSIZE_MARK_MASK" == "$Z2R_WSSIZE_MARK_MASK" meta mark \& "$DESYNC_MARK" == 0 meta nfproto ipv4 tcp dport 443 ct original packets \> "$out" counter meta mark set meta mark or "$DESYNC_MARK_POSTNAT" ct mark set ct mark or "$DESYNC_MARK" queue num "$QNUM" bypass || return 1
	fi
	rule="meta mark & $Z2R_WSSIZE_MARK_MASK == $Z2R_WSSIZE_MARK_MASK meta mark & $DESYNC_MARK == 0 meta nfproto ipv4 tcp sport 443 ct reply packets > $in"
	if ! nft_rule_exists "$pre" "$rule counter ct mark set ct mark or $DESYNC_MARK queue num $QNUM bypass"; then
		nft_add_rule "$pre" meta mark \& "$Z2R_WSSIZE_MARK_MASK" == "$Z2R_WSSIZE_MARK_MASK" meta mark \& "$DESYNC_MARK" == 0 meta nfproto ipv4 tcp sport 443 ct reply packets \> "$in" counter ct mark set ct mark or "$DESYNC_MARK" queue num "$QNUM" bypass || return 1
	fi
}

zapret_custom_firewall_nft() {
	[ "$FWTYPE" = nftables ] || return 0
	[ "$NFQWS2_ENABLE" = 1 ] && [ "$Z2R_WSSIZE_RAMP_ENABLE" = 1 ] || return 0
	z2r_wssize_nft_set_ensure || return 1
	local ips
	ips="$(z2r_wssize_ramp_ips)" || return 1
	z2r_wssize_nft_set_merge_file "$ips" || return 1
	z2r_wssize_mark_validate || return 1
	z2r_wssize_nft_mark_install || return 1
	[ "${Z2R_WSSIZE_RAMP_MODE:-full}" = full ] || return 0
	z2r_wssize_nft_late_install
}

# Keep the shared set intact: dnsmasq populates it independently of zapret2.
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

z2r_wssize_iptables_late_cleanup() {
	local hook
	z2r_wssize_iptables_remove_jump POSTROUTING Z2R_WS_OUT || return 1
	for hook in INPUT FORWARD; do z2r_wssize_iptables_remove_jump "$hook" Z2R_WS_IN || return 1; done
	z2r_wssize_iptables_remove_chain Z2R_WS_OUT || return 1
	z2r_wssize_iptables_remove_chain Z2R_WS_IN
}

z2r_wssize_iptables_mark_cleanup() {
	local hook
	z2r_wssize_iptables_remove_jump PREROUTING Z2R_WS_MARK || return 1
	z2r_wssize_iptables_remove_jump POSTROUTING Z2R_WS_MARK || return 1
	z2r_wssize_iptables_remove_chain Z2R_WS_MARK
}

z2r_wssize_iptables_cleanup() {
	z2r_wssize_iptables_late_cleanup || return 1
	z2r_wssize_iptables_mark_cleanup
}

z2r_wssize_iptables_mark_install() {
	local hook
	iptables -t mangle -N Z2R_WS_MARK 2>/dev/null || :
	iptables -t mangle -F Z2R_WS_MARK || return 1
	iptables -t mangle -A Z2R_WS_MARK -m set --match-set "$Z2R_GOOGLEVIDEO_SET" dst -p tcp --dport 443 -m mark ! --mark "$DESYNC_MARK/$DESYNC_MARK" -j MARK --set-xmark "$Z2R_WSSIZE_MARK/$Z2R_WSSIZE_MARK_MASK" || return 1
	iptables -t mangle -A Z2R_WS_MARK -m set --match-set "$Z2R_GOOGLEVIDEO_SET" src -p tcp --sport 443 -m mark ! --mark "$DESYNC_MARK/$DESYNC_MARK" -j MARK --set-xmark "$Z2R_WSSIZE_MARK/$Z2R_WSSIZE_MARK_MASK" || return 1
	# The early mark must be present before zapret2's normal NFQUEUE rules see
	# the SYN. Remove and reinsert only our owned jumps to prevent duplicates.
	for hook in PREROUTING POSTROUTING; do
		z2r_wssize_iptables_remove_jump "$hook" Z2R_WS_MARK || return 1
		iptables -t mangle -I "$hook" 1 -j Z2R_WS_MARK || return 1
	done
}

z2r_wssize_iptables_late_install() {
	local out="$1" in="$2" qnum="$3" mark="$4" out_from=$((out + 1)) in_from=$((in + 1)) hook
	iptables -t mangle -N Z2R_WS_OUT 2>/dev/null || :
	iptables -t mangle -N Z2R_WS_IN 2>/dev/null || :
	iptables -t mangle -F Z2R_WS_OUT || return 1
	iptables -t mangle -F Z2R_WS_IN || return 1
	iptables -t mangle -A Z2R_WS_OUT -m mark --mark "$Z2R_WSSIZE_MARK/$Z2R_WSSIZE_MARK_MASK" -p tcp --dport 443 -m connbytes --connbytes-dir original --connbytes-mode packets --connbytes "$out_from": -m mark ! --mark "$mark/$mark" -j NFQUEUE --queue-num "$qnum" --queue-bypass || return 1
	iptables -t mangle -A Z2R_WS_IN -m mark --mark "$Z2R_WSSIZE_MARK/$Z2R_WSSIZE_MARK_MASK" -p tcp --sport 443 -m connbytes --connbytes-dir reply --connbytes-mode packets --connbytes "$in_from": -m mark ! --mark "$mark/$mark" -j NFQUEUE --queue-num "$qnum" --queue-bypass || return 1
	iptables -t mangle -C POSTROUTING -j Z2R_WS_OUT >/dev/null 2>&1 || iptables -t mangle -A POSTROUTING -j Z2R_WS_OUT || return 1
	for hook in INPUT FORWARD; do
		iptables -t mangle -C "$hook" -j Z2R_WS_IN >/dev/null 2>&1 || iptables -t mangle -A "$hook" -j Z2R_WS_IN || return 1
	done
}

zapret_custom_firewall() {
	local action="${1:-}" ips out in qnum mark
	[ "$FWTYPE" = iptables ] || return 0
	case "$action" in 0) z2r_wssize_iptables_cleanup; return $? ;; 1) ;; *) echo "wssize_ramp: invalid iptables action" >&2; return 1 ;; esac
	if [ "$NFQWS2_ENABLE" != 1 ] || [ "$Z2R_WSSIZE_RAMP_ENABLE" != 1 ]; then
		z2r_wssize_iptables_cleanup
		return $?
	fi
	z2r_wssize_mark_validate || return 1
	z2r_wssize_ipset_ensure || return 1
	ips="$(z2r_wssize_ramp_ips)" || return 1
	z2r_wssize_ipset_merge_file "$ips" || return 1
	z2r_wssize_iptables_mark_install || return 1
	if [ "${Z2R_WSSIZE_RAMP_MODE:-full}" != full ]; then z2r_wssize_iptables_late_cleanup; return $?; fi
	out="${NFQWS2_TCP_PKT_OUT:-20}"; in="${NFQWS2_TCP_PKT_IN:-10}"
	qnum="${QNUM:-}"; mark="${DESYNC_MARK:-}"
	case "$out:$in:$qnum:$mark" in *[!0-9A-Fa-fx:]*|:*|*::*|*:) echo "wssize_ramp: invalid iptables queue/mark/packet limits" >&2; return 1 ;; esac
	case "$out:$in" in *[!0-9:]*|:*) echo "wssize_ramp: invalid TCP packet limits" >&2; return 1 ;; esac
	z2r_wssize_iptables_late_install "$out" "$in" "$qnum" "$mark"
}
