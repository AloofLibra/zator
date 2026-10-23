#!/bin/sh
# Sourced by supersweep: start/stop MUST run in the same shell, not $(...).
# Caller owns the root-protected run directory, lock and nfqws2 queue lifecycle.
# Start nfqws2 on queue 65535 before start; stop transport before stopping nfqws2.
# nft inserts into native zapret hooks: ACCEPT in a separate base chain would
# NOT bypass production NFQUEUE. No production table/chain is ever flushed.
Z2R_SUPERSWEEP_QNUM=65535
Z2R_SUPERSWEEP_PORTS=62000-62999

_supersweep_transport_error() {
  printf 'Supersweep transport: %s\n' "$*" >&2
  return 1
}

_supersweep_transport_ipt() {
  iptables ${_Z2R_SS_IPT_WAIT:+$_Z2R_SS_IPT_WAIT} -t mangle "$@"
}

_supersweep_transport_mark_safe() {
  local mark="$1" digits
  # Validate before shell arithmetic; malformed config must not terminate sh.
  case "$mark" in
    0) ;;
    0x*) digits="${mark#0x}"
      case "$digits" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
      [ "${#digits}" -le 8 ] || return 1 ;;
    *) case "$mark" in ''|*[!0-9]*|0*) return 1 ;; esac
      [ "${#mark}" -le 10 ] || return 1 ;;
  esac
  [ "$((mark))" -ge 0 ] && [ "$((mark))" -le 4294967295 ] &&
    [ "$((mark & 0x08000000))" -eq 0 ]
}

_supersweep_transport_hook() {
  local action="$1" hook="$2"
  shift 2
  case "$hook" in
    OUTPUT)
      _supersweep_transport_ipt "$action" OUTPUT -p tcp --sport 62000:62999 --dport 443 \
        -m owner --uid-owner 0 -m mark ! --mark "$_Z2R_SS_DESYNC/$_Z2R_SS_DESYNC" -j Z2R_SS_OUT ;;
    RAWOUTPUT)
      _supersweep_transport_ipt "$action" OUTPUT -p tcp --sport 62000:62999 --dport 443 \
        -m owner --uid-owner 65533 -j Z2R_SS_RAW ;;
    SOCKETOUTPUT)
      _supersweep_transport_ipt "$action" OUTPUT -p tcp --sport 62000:62999 --dport 443 \
        -m owner ! --socket-exists -m mark ! --mark "$_Z2R_SS_DESYNC/$_Z2R_SS_DESYNC" -j Z2R_SS_OUT ;;
    POSTROUTING)
      _supersweep_transport_ipt "$action" POSTROUTING -p tcp --sport 62000:62999 --dport 443 \
        -m mark ! --mark "$_Z2R_SS_DESYNC/$_Z2R_SS_DESYNC" \
        -m mark --mark 0x08000000/0x08000000 -m conntrack --ctdir ORIGINAL -j Z2R_SS_POST ;;
    PREROUTING|INPUT)
      local target=Z2R_SS_PRE
      [ "$hook" != INPUT ] || target=Z2R_SS_IN
      _supersweep_transport_ipt "$action" "$hook" -p tcp --sport 443 --dport 62000:62999 \
        -m mark ! --mark "$_Z2R_SS_DESYNC/$_Z2R_SS_DESYNC" \
        -m conntrack --ctstate ESTABLISHED --ctdir REPLY \
        -m connmark --mark 0x08000000/0x08000000 -j "$target" ;;
    *) return 1 ;;
  esac
}

_supersweep_transport_install() {
  local chain hook
  for chain in Z2R_SS_OUT Z2R_SS_POST Z2R_SS_PRE Z2R_SS_IN Z2R_SS_RAW; do
    if ! _supersweep_transport_ipt -N "$chain" 2>/dev/null; then
      [ "${_Z2R_SS_RECLAIM:-0}" = 1 ] || return 1
      _supersweep_transport_ipt -F "$chain" 2>/dev/null || return 1
      _supersweep_transport_ipt -X "$chain" 2>/dev/null || return 1
      _supersweep_transport_ipt -N "$chain" || return 1
    fi
    _Z2R_SS_CHAINS="$chain ${_Z2R_SS_CHAINS:-}"
  done
  _supersweep_transport_ipt -A Z2R_SS_OUT -p tcp --sport 62000:62999 --dport 443 \
    -m mark ! --mark "$_Z2R_SS_DESYNC/$_Z2R_SS_DESYNC" \
    -j MARK --set-xmark 0x08000000/0x08000000 || return 1
  _supersweep_transport_ipt -A Z2R_SS_OUT -j CONNMARK --or-mark 0x08000000 || return 1
  _supersweep_transport_ipt -A Z2R_SS_OUT -j ACCEPT || return 1
  _supersweep_transport_ipt -A Z2R_SS_RAW -j MARK --or-mark "$((_Z2R_SS_DESYNC | 0x08000000))" || return 1
  _supersweep_transport_ipt -A Z2R_SS_RAW -j ACCEPT || return 1
  _supersweep_transport_ipt -A Z2R_SS_PRE -j CONNMARK --restore-mark \
    --nfmask 0x08000000 --ctmask 0x08000000 || return 1
  # ACCEPT ends the current mangle hook, bypassing the production NFQ path.
  _supersweep_transport_ipt -A Z2R_SS_PRE -j ACCEPT || return 1
  for chain in Z2R_SS_POST Z2R_SS_IN; do
    _supersweep_transport_ipt -A "$chain" -j NFQUEUE --queue-num 65535 --queue-bypass || return 1
    _supersweep_transport_ipt -A "$chain" -j ACCEPT || return 1
  done
  # Activate classification last: partially installed rules cannot mark traffic.
  for hook in POSTROUTING PREROUTING INPUT OUTPUT RAWOUTPUT SOCKETOUTPUT; do
    _supersweep_transport_hook -I "$hook" || return 1
    _Z2R_SS_HOOKS="$hook ${_Z2R_SS_HOOKS:-}"
  done
}

_supersweep_transport_nft_owned() {
  local listing
  listing="$(nft -a list table inet "$_Z2R_SS_NFT_TABLE")" || return 1
  printf '%s\n' "$listing" | awk -v table="$_Z2R_SS_NFT_TABLE" '
    $1 == "chain" { chain=$2 }
    /comment "z2r_supersweep"/ {
      for (i=1; i<NF; i++) if ($i=="handle" && $(i+1) ~ /^[0-9]+$/)
        print "delete rule inet " table " " chain " handle " $(i+1)
    }'
}

_supersweep_transport_nft_install() {
  local post=postnat_hook pre=prenat_hook rules out reply
  _Z2R_SS_NFT_TABLE="${ZAPRET_NFT_TABLE:-zapret2}"
  case "$_Z2R_SS_NFT_TABLE" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  if [ "${POSTNAT:-1}" = 0 ] && [ "${POSTNAT_ALL:-0}" != 1 ]; then
    post=postrouting_hook; pre=prerouting_hook
  fi
  _Z2R_SS_NFT_COUNT=10
  [ "$post" != postnat_hook ] || _Z2R_SS_NFT_COUNT=11
  nft list chain inet "$_Z2R_SS_NFT_TABLE" predefrag >/dev/null 2>&1 &&
    nft list chain inet "$_Z2R_SS_NFT_TABLE" "$post" >/dev/null 2>&1 &&
    nft list chain inet "$_Z2R_SS_NFT_TABLE" "$pre" >/dev/null 2>&1 || return 1
  rules="$(_supersweep_transport_nft_owned)" || return 1
  [ -z "$rules" ] || { _supersweep_transport_error 'foreign/stale nft probe rules exist'; return 1; }
  if nft list chain inet "$_Z2R_SS_NFT_TABLE" z2r_supersweep_output >/dev/null 2>&1; then
    _supersweep_transport_error 'foreign/stale nft probe output chain exists'; return 1
  fi
  out="meta nfproto ipv4 meta mark & $_Z2R_SS_DESYNC == 0 meta mark & 0x08000000 != 0 tcp sport 62000-62999 tcp dport 443"
  reply="meta nfproto ipv4 ct direction reply ct state established ct mark & 0x08000000 != 0 tcp sport 443 tcp dport 62000-62999"
  # One atomic transaction. Insertions are reversed: mark, queue, return.
  {
    # После mangle OUTPUT: policy routing иначе затирает ранний mark и
    # отправляет пробы в VPN. route-chain пересчитывает только наши потоки.
    printf 'create chain inet %s z2r_supersweep_output { type route hook output priority -1; policy accept; }\n' "$_Z2R_SS_NFT_TABLE"
    printf 'insert rule inet %s %s %s return comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE" "$post" "$out"
    printf 'insert rule inet %s %s %s queue num 65535 bypass comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE" "$post" "$out"
    printf 'insert rule inet %s %s %s ct mark set ct mark | 0x08000000 comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE" "$post" "$out"
    if [ "$post" = postnat_hook ]; then
      printf 'insert rule inet %s %s %s meta mark set meta mark | %s comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE" "$post" "$out" "${DESYNC_MARK_POSTNAT:-0x20000000}"
    fi
    printf 'insert rule inet %s %s %s return comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE" "$pre" "$reply"
    printf 'insert rule inet %s %s %s queue num 65535 bypass comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE" "$pre" "$reply"
    printf 'insert rule inet %s %s %s meta mark set meta mark | 0x08000000 comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE" "$pre" "$reply"
    printf 'add rule inet %s z2r_supersweep_output meta nfproto ipv4 meta skuid 0 meta mark & %s == 0 tcp sport 62000-62999 tcp dport 443 meta mark set meta mark | 0x08000000 comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE" "$_Z2R_SS_DESYNC"
    printf 'add rule inet %s z2r_supersweep_output meta nfproto ipv4 meta skuid 65533 tcp sport 62000-62999 tcp dport 443 meta mark set meta mark | %s | 0x08000000 comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE" "$_Z2R_SS_DESYNC"
    # После close() TLS close_notify/FIN/RST могут идти уже без socket UID.
    # Сначала исключаем ВСЕ прочие сокеты (включая основной nfqws2), затем
    # маркируем только socketless-пакеты наших зарезервированных портов.
    printf 'add rule inet %s z2r_supersweep_output meta nfproto ipv4 meta skuid >= 0 tcp sport 62000-62999 tcp dport 443 return comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE"
    printf 'add rule inet %s z2r_supersweep_output meta nfproto ipv4 tcp sport 62000-62999 tcp dport 443 meta mark set meta mark | 0x08000000 comment "z2r_supersweep"\n' "$_Z2R_SS_NFT_TABLE"
  } | nft -f - || return 1
  _Z2R_SS_NFT_CHAIN=1
  _Z2R_SS_NFT_ACTIVE=1
}

supersweep_transport_start() {
  local first last extra range_file mark
  [ "${_Z2R_SS_ACTIVE:-0}" != 1 ] || return 0
  [ -z "${_Z2R_SS_CHAINS:-}${_Z2R_SS_HOOKS:-}" ] || {
    _supersweep_transport_error 'unfinished cleanup; call supersweep_transport_stop first'; return 1;
  }
  case "${FWTYPE:-}" in
    iptables|nftables|nft) ;;
    *) _supersweep_transport_error 'FWTYPE must explicitly select iptables or nftables'; return 1 ;;
  esac
  range_file="${Z2R_SUPERSWEEP_PORT_RANGE_FILE:-/proc/sys/net/ipv4/ip_local_port_range}"
  # busybox read берёт из /proc-файлов этого ядра только первый кусок: читаем
  # через cat и разбиение по IFS — одинаково в ash и bash.
  set -- $(cat "$range_file" 2>/dev/null) || :
  first=${1:-} last=${2:-} extra=${3:-}
  [ -n "$first" ] || {
    _supersweep_transport_error 'cannot read kernel ephemeral port range'; return 1;
  }
  case "$first:$last" in *[!0-9:]*|:*|*:) _supersweep_transport_error 'invalid kernel ephemeral port range'; return 1 ;; esac
  [ -z "$extra" ] && [ "${#first}" -le 5 ] && [ "${#last}" -le 5 ] &&
    [ "$first" -gt 0 ] && [ "$last" -ge "$first" ] && [ "$last" -le 65535 ] || {
    _supersweep_transport_error 'invalid kernel ephemeral port range'; return 1;
  }
  [ "$last" -lt 62000 ] || [ "$first" -gt 62999 ] || {
    _supersweep_transport_error 'reserved ports 62000-62999 overlap kernel ephemeral range'; return 1;
  }
  _Z2R_SS_DESYNC="${DESYNC_MARK:-0x40000000}"
  for mark in "$_Z2R_SS_DESYNC" "${DESYNC_MARK_POSTNAT:-0x20000000}" "${FILTER_MARK:-0}" "${CLIENT_SCOPE_MARK_MASK:-0}"; do
    _supersweep_transport_mark_safe "$mark" || {
      _supersweep_transport_error 'invalid firewall mark or collision with reserved mark 0x08000000'; return 1;
    }
  done
  [ "$((_Z2R_SS_DESYNC))" -gt 0 ] || {
    _supersweep_transport_error 'DESYNC_MARK must not be zero'; return 1;
  }
  if [ "$FWTYPE" != iptables ]; then
    if _supersweep_transport_nft_install; then _Z2R_SS_ACTIVE=1; return 0; fi
    _supersweep_transport_error 'native nft hook installation failed; no fallback to production NFQUEUE'
    return 1
  fi
  if [ -z "${_Z2R_SS_IPT_WAIT_DONE:-}" ]; then
    if iptables -w 5 -t mangle -L OUTPUT -n >/dev/null 2>&1; then
      _Z2R_SS_IPT_WAIT='-w 5'
    elif iptables -w -t mangle -L OUTPUT -n >/dev/null 2>&1; then
      _Z2R_SS_IPT_WAIT='-w'
    else
      _Z2R_SS_IPT_WAIT=''
    fi
    _Z2R_SS_IPT_WAIT_DONE=1
  fi
  if _supersweep_transport_install; then
    _Z2R_SS_ACTIVE=1
    return 0
  fi
  _supersweep_transport_error 'iptables installation failed; removing partial transport' || :
  supersweep_transport_stop || :
  return 1
}

supersweep_transport_teardown_blind() {
  local hook chain
  _Z2R_SS_DESYNC="${_Z2R_SS_DESYNC:-${DESYNC_MARK:-0x40000000}}"
  for hook in POSTROUTING PREROUTING INPUT OUTPUT RAWOUTPUT SOCKETOUTPUT; do
    _supersweep_transport_hook -D "$hook" 2>/dev/null || :
  done
  for chain in Z2R_SS_OUT Z2R_SS_POST Z2R_SS_PRE Z2R_SS_IN Z2R_SS_RAW; do
    _supersweep_transport_ipt -F "$chain" 2>/dev/null || :
    _supersweep_transport_ipt -X "$chain" 2>/dev/null || :
  done
  _Z2R_SS_HOOKS=
  _Z2R_SS_CHAINS=
  _Z2R_SS_ACTIVE=0
}

supersweep_transport_reinstall() {
  [ "${FWTYPE:-}" = iptables ] || return 1
  supersweep_transport_teardown_blind
  _Z2R_SS_RECLAIM=1
  supersweep_transport_start
}

supersweep_transport_reconcile() {
  [ "${FWTYPE:-}" = iptables ] || return 0
  _Z2R_SS_DESYNC="${DESYNC_MARK:-0x40000000}"
  if _supersweep_transport_hook -C SOCKETOUTPUT 2>/dev/null; then
    return 0
  fi
  local t=0
  until supersweep_transport_reinstall; do
    t=$((t + 1))
    [ "$t" -lt 5 ] || return 1
    sleep 3
  done
}

supersweep_transport_check() {
  local hook chain owned
  [ "${_Z2R_SS_ACTIVE:-0}" = 1 ] || return 1
  if [ "${_Z2R_SS_NFT_ACTIVE:-0}" = 1 ]; then
    owned="$(_supersweep_transport_nft_owned)" || return 1
    [ "$(printf '%s\n' "$owned" | grep -c '^delete rule ')" = "$_Z2R_SS_NFT_COUNT" ]
    return $?
  fi
  for hook in ${_Z2R_SS_HOOKS:-}; do
    _supersweep_transport_hook -C "$hook" >/dev/null 2>&1 || return 1
  done
  for chain in Z2R_SS_POST Z2R_SS_IN; do
    _supersweep_transport_ipt -C "$chain" -j NFQUEUE --queue-num 65535 --queue-bypass >/dev/null 2>&1 || return 1
    _supersweep_transport_ipt -C "$chain" -j ACCEPT >/dev/null 2>&1 || return 1
  done
  _supersweep_transport_ipt -C Z2R_SS_RAW -j MARK --or-mark "$((_Z2R_SS_DESYNC | 0x08000000))" >/dev/null 2>&1 &&
    _supersweep_transport_ipt -C Z2R_SS_RAW -j ACCEPT >/dev/null 2>&1 || return 1
  return 0
}

supersweep_transport_stop() {
  local hook chain chains= rc=0 hooks_live=0 remaining=
  if [ "${_Z2R_SS_NFT_ACTIVE:-0}" = 1 ]; then
    local rules
    rules="$(_supersweep_transport_nft_owned)" || return 1
    if [ "${_Z2R_SS_NFT_CHAIN:-0}" = 1 ] \
      && nft list chain inet "$_Z2R_SS_NFT_TABLE" z2r_supersweep_output >/dev/null 2>&1; then
      rules="$rules
delete chain inet $_Z2R_SS_NFT_TABLE z2r_supersweep_output"
    fi
    [ -z "$rules" ] || printf '%s\n' "$rules" | nft -f - || return 1
    _Z2R_SS_NFT_CHAIN=0
    _Z2R_SS_NFT_ACTIVE=0
  fi
  _Z2R_SS_ACTIVE=0
  # Disable marking, then the reply queue, then its production-bypass guard.
  # Keenetic ndm периодически переприменяет firewall и выметает чужие цепи:
  # исчезнувшее правило — не ошибка. -D может отказать и транзиентно (чужой
  # xtables lock), поэтому факт существования правила проверяется листингом
  # цепи: правило на месте — останавливаемся и ретраим, исчезло — идём дальше.
  for hook in ${_Z2R_SS_HOOKS:-}; do
    if ! _supersweep_transport_hook -D "$hook" 2>/dev/null; then
      local live_chain="$hook"
      case "$hook" in RAWOUTPUT|SOCKETOUTPUT) live_chain=OUTPUT ;; esac
      if _supersweep_transport_ipt -nL "$live_chain" 2>/dev/null | grep -aq 'Z2R_SS_'; then
        hooks_live=1
        remaining="$remaining $hook"
        continue
      fi
    fi
  done
  _Z2R_SS_HOOKS="${remaining# }"
  if [ "$hooks_live" = 0 ]; then
    for chain in ${_Z2R_SS_CHAINS:-}; do
      if _supersweep_transport_ipt -F "$chain" 2>/dev/null && _supersweep_transport_ipt -X "$chain" 2>/dev/null; then
        :
      elif _supersweep_transport_ipt -nL "$chain" >/dev/null 2>&1; then
        chains="$chains $chain"; rc=1
      fi
    done
    _Z2R_SS_CHAINS="$chains"
  fi
  if [ "$hooks_live" = 1 ] || [ "$rc" -eq 1 ]; then
    _supersweep_transport_error 'cleanup incomplete; retry stop before exiting'
    return 1
  fi
}
