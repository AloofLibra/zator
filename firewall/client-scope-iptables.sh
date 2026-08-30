#!/usr/bin/env bash
# Classify LAN clients by source IPv4 before NAT using a private mark namespace.

CLIENT_SCOPE_CHAIN="${CLIENT_SCOPE_CHAIN:-ZATOR_CLIENT_SCOPE}"
CLIENT_SCOPE_TABLE="${CLIENT_SCOPE_TABLE:-mangle}"
CLIENT_SCOPE_COMMENT="${CLIENT_SCOPE_COMMENT:-zator-client-scope}"
CLIENT_SCOPE_MAP_FILE="${CLIENT_SCOPE_MAP_FILE:-${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/client_scope.tsv}"
CLIENT_SCOPE_MARK_SHIFT="${CLIENT_SCOPE_MARK_SHIFT:-8}"
CLIENT_SCOPE_MARK_MAX="${CLIENT_SCOPE_MARK_MAX:-255}"
CLIENT_SCOPE_MARK_MASK="${CLIENT_SCOPE_MARK_MASK:-0xff00}"

_client_scope_iptables() {
  command -v iptables >/dev/null 2>&1 || return 127
  iptables -t "$CLIENT_SCOPE_TABLE" "$@"
}

_client_scope_enabled() {
  [ "${CLIENT_SCOPE_ENABLE:-0}" = 1 ]
}

_client_scope_valid_ipv4() {
  local ip=$1 octet count=0
  printf '%s\n' "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$' || return 1
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    [ "$octet" -le 255 ] 2>/dev/null || return 1
    count=$((count + 1))
  done
  [ "$count" -eq 4 ]
}

_client_scope_mark_value() {
  local id=$1
  printf '%d\n' $((id << CLIENT_SCOPE_MARK_SHIFT))
}

_client_scope_delete_owned() {
  local line rule_chain rule
  # Read only our chain. Never flush a table or a chain belonging to another
  # component; each generated rule carries a stable comment as a second guard.
  while IFS= read -r line; do
    case "$line" in
      "-A $CLIENT_SCOPE_CHAIN "*"--comment $CLIENT_SCOPE_COMMENT"*|\
      "-A $CLIENT_SCOPE_CHAIN "*"--comment \"$CLIENT_SCOPE_COMMENT\""*)
        rule=${line#-A "$CLIENT_SCOPE_CHAIN" }
        # iptables -S shell-quotes comment values.  Strip only our known
        # comment quotes before word-splitting the locally generated rule.
        rule=${rule//--comment \"$CLIENT_SCOPE_COMMENT\"/--comment $CLIENT_SCOPE_COMMENT}
        # shellcheck disable=SC2086 -- rule is emitted by iptables -S locally.
        _client_scope_iptables -D "$CLIENT_SCOPE_CHAIN" $rule || true
        ;;
    esac
  done < <(_client_scope_iptables -S "$CLIENT_SCOPE_CHAIN" 2>/dev/null || true)
  if _client_scope_iptables -C PREROUTING -m comment --comment "$CLIENT_SCOPE_COMMENT" -j "$CLIENT_SCOPE_CHAIN" 2>/dev/null; then
    _client_scope_iptables -D PREROUTING -m comment --comment "$CLIENT_SCOPE_COMMENT" -j "$CLIENT_SCOPE_CHAIN" || true
  fi
}

apply() {
  local entry scope ip id mark
  _client_scope_enabled || return 0
  command -v iptables >/dev/null 2>&1 || return 0
  [ -r "$CLIENT_SCOPE_MAP_FILE" ] || return 0
  _client_scope_iptables -N "$CLIENT_SCOPE_CHAIN" 2>/dev/null || true
  _client_scope_delete_owned
  # Вставляемся ПЕРВЫМИ в PREROUTING: magitrickle и подобные метят пакеты
  # для политической маршрутизации полной 32-битной маркой (/0xffffffff)
  # и затирают всё, что стояло до них. Наша маска 0xff00 после их правил
  # ломала бы их марку (Telegram-медиа через VPN). Первыми — значит для
  # VPN-направленных пакетов победит их марка (скоп деградирует до default),
  # для остальных останется наша.
  _client_scope_iptables -I PREROUTING 1 -m comment --comment "$CLIENT_SCOPE_COMMENT" -j "$CLIENT_SCOPE_CHAIN" || return 1
  while IFS=$'\t' read -r scope ip _ || [ -n "${scope:-}" ]; do
    [ -n "$scope" ] || continue
    case "$scope" in mark:*) id=${scope#mark:};; *) continue;; esac
    printf '%s\n' "$id" | grep -Eq '^[1-9][0-9]*$' || continue
    [ "$id" -le "$CLIENT_SCOPE_MARK_MAX" ] 2>/dev/null || continue
    _client_scope_valid_ipv4 "$ip" || continue
    mark=$(_client_scope_mark_value "$id")
    _client_scope_iptables -A "$CLIENT_SCOPE_CHAIN" -s "$ip" -m comment --comment "$CLIENT_SCOPE_COMMENT" -j MARK --set-mark "$mark/$CLIENT_SCOPE_MARK_MASK" || return 1
  done < "$CLIENT_SCOPE_MAP_FILE"
}

cleanup() {
  command -v iptables >/dev/null 2>&1 || return 0
  _client_scope_delete_owned
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    apply) apply ;;
    cleanup|remove) cleanup ;;
    *) printf 'usage: %s {apply|cleanup}\n' "$0" >&2; exit 2 ;;
  esac
fi