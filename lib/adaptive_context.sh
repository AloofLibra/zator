# Network-context primitives for the adaptive controller.
# This file is POSIX sh / BusyBox ash compatible and has no source-time effects.

adaptive_network_context_snapshot() {
  local state_dir state_file route4 route6 iface addresses mac resolvers fingerprint
  local old_version old_epoch old_fingerprint epoch route4_state route6_state dns_state
  local nfqws_state nfqueue_state mem_available_kb load1 now tmp_file

  old_version=""
  old_epoch=0
  old_fingerprint=""
  state_dir="${Z2R_ADAPTIVE_STATE_DIR:-/tmp/zator-adaptive}"
  state_file="$state_dir/network-epoch.tsv"
  mkdir -p "$state_dir" 2>/dev/null || return 1

  route4=""
  route6=""
  if command -v ip >/dev/null 2>&1; then
    route4="$(ip -4 route show default 2>/dev/null | awk '{$1=$1; print}')"
    route6="$(ip -6 route show default 2>/dev/null | awk '{$1=$1; print}')"
    route4_state=present
    route6_state=present
    [ -n "$route4" ] || route4_state=missing
    [ -n "$route6" ] || route6_state=missing
  else
    route4_state=unknown
    route6_state=unknown
  fi

  iface="$(printf '%s\n' "$route4" "$route6" | awk '
    { for (i=1; i<NF; i++) if ($i=="dev") { print $(i+1); exit } }
  ')"
  addresses=""
  mac=""
  if [ -n "$iface" ] && command -v ip >/dev/null 2>&1; then
    addresses="$(ip -o addr show dev "$iface" scope global 2>/dev/null | awk '{$1=$1; print}')"
    [ ! -r "/sys/class/net/$iface/address" ] || mac="$(cat "/sys/class/net/$iface/address" 2>/dev/null)"
  fi
  resolvers="$(awk '$1=="nameserver" && NF>1 { print $2 }' /etc/resolv.conf 2>/dev/null)"
  fingerprint="$(printf '%s\n--route4--\n%s\n--route6--\n%s\n--iface--\n%s\n--mac--\n%s\n--addresses--\n%s\n--resolvers--\n%s\n' \
    "$route4" "$route6" "$iface" "$mac" "$addresses" "$resolvers" | cksum | awk '{print $1 "-" $2}')"
  [ -n "$fingerprint" ] || fingerprint=unknown

  if [ -r "$state_file" ]; then
    read -r old_version old_epoch old_fingerprint < "$state_file"
  fi
  case "$old_epoch" in ''|*[!0-9]*) old_epoch=0 ;; esac
  if [ "$old_version" = v1 ] && [ "$old_fingerprint" = "$fingerprint" ]; then
    epoch="$old_epoch"
  else
    epoch=$((old_epoch + 1))
    tmp_file="$state_file.$$"
    if ! { printf 'v1\t%s\t%s\n' "$epoch" "$fingerprint" > "$tmp_file" && mv -f "$tmp_file" "$state_file"; }; then
      rm -f "$tmp_file" 2>/dev/null || true
      return 1
    fi
  fi

  if [ -n "$resolvers" ]; then dns_state=configured; else dns_state=missing; fi
  if command -v pidof >/dev/null 2>&1; then
    if pidof nfqws2 >/dev/null 2>&1; then nfqws_state=running; else nfqws_state=stopped; fi
  else
    nfqws_state=unknown
  fi
  if [ -r /proc/net/netfilter/nfnetlink_queue ]; then
    nfqueue_state="present:$(awk 'END {print NR+0}' /proc/net/netfilter/nfnetlink_queue)"
  else
    nfqueue_state=unknown
  fi
  mem_available_kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  load1="$(awk '{print $1; exit}' /proc/loadavg 2>/dev/null)"
  [ -n "$mem_available_kb" ] || mem_available_kb=unknown
  [ -n "$load1" ] || load1=unknown
  now="$(date +%s 2>/dev/null)"
  [ -n "$now" ] || now=0

  printf 'NETWORK_CONTEXT\tv1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$epoch" "$fingerprint" "$route4_state" "$route6_state" \
    "${iface:-unknown}" "$dns_state" "$nfqws_state" "$nfqueue_state" \
    "$mem_available_kb" "$load1"
}
