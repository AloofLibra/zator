#!/usr/bin/env bash
# Client scopes are classified in prerouting because the mapping is based on
# the LAN source IP. This is independent of zapret2's global POSTNAT mode.

# Keep the table canonical so cleanup cannot be redirected to arbitrary state.
CLIENT_SCOPE_NFT_TABLE=zator_client_scope
CLIENT_SCOPE_NFT_CHAIN="${CLIENT_SCOPE_NFT_CHAIN:-classify}"
CLIENT_SCOPE_COMMENT="${CLIENT_SCOPE_COMMENT:-zator-client-scope}"
CLIENT_SCOPE_MAP_FILE="${CLIENT_SCOPE_MAP_FILE:-${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/client_scope.tsv}"
CLIENT_SCOPE_MARK_SHIFT="${CLIENT_SCOPE_MARK_SHIFT:-8}"
CLIENT_SCOPE_MARK_MAX="${CLIENT_SCOPE_MARK_MAX:-255}"
CLIENT_SCOPE_MARK_MASK="${CLIENT_SCOPE_MARK_MASK:-0xff00}"

_nft() { command -v nft >/dev/null 2>&1 || return 127; nft "$@"; }
_enabled() { [ "${CLIENT_SCOPE_ENABLE:-0}" = 1 ]; }
_valid_ipv4() {
  local value="$1" part count=0
  [[ "$value" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  local old_ifs="$IFS"; IFS=.
  read -r -a parts <<< "$value"
  IFS="$old_ifs"
  for part in "${parts[@]}"; do
    [ "$part" -le 255 ] 2>/dev/null || return 1
    count=$((count + 1))
  done
  [ "$count" -eq 4 ]
}
_valid_ipv6() { printf '%s\n' "$1" | grep -Eq '^[0-9A-Fa-f:]+$' && printf '%s\n' "$1" | grep -q ':'; }
_valid_id() { printf '%s\n' "$1" | grep -Eq '^[1-9][0-9]*$' && [ "$1" -le "$CLIENT_SCOPE_MARK_MAX" ] 2>/dev/null; }
_valid_nft_name() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_.-]{0,31}$'; }
_valid_comment() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.:/ -]{1,64}$'; }

_apply_ruleset() {
  local hook="$1" tmp entry scope ip id mark family rule mask_clear
  _valid_nft_name "$CLIENT_SCOPE_NFT_CHAIN" || return 0
  _valid_comment "$CLIENT_SCOPE_COMMENT" || return 0
  [ -r "$CLIENT_SCOPE_MAP_FILE" ] || return 0
  mask_clear=$(printf '0x%08x' $((0xffffffff ^ CLIENT_SCOPE_MARK_MASK)))
  tmp="${TMPDIR:-/tmp}/zator-client-scope-nft.$$.rules"
  {
    printf 'add table inet %s\n' "$CLIENT_SCOPE_NFT_TABLE"
    printf 'add chain inet %s %s { type filter hook %s priority mangle; policy accept; }\n' \
      "$CLIENT_SCOPE_NFT_TABLE" "$CLIENT_SCOPE_NFT_CHAIN" "$hook"
    while IFS=$'\t' read -r scope ip _ || [ -n "${scope:-}" ]; do
      [ -n "$scope" ] || continue
      case "$scope" in mark:*) id=${scope#mark:};; *) continue;; esac
      _valid_id "$id" || continue
      if _valid_ipv4 "$ip"; then family=ip; elif _valid_ipv6 "$ip"; then family=ip6; else continue; fi
      mark=$((id << CLIENT_SCOPE_MARK_SHIFT))
      # The comment is deliberately in our private table, not a zapret/policy bit.
      printf 'add rule inet %s %s %s saddr %s meta mark set ((meta mark & %s) | %d) ct mark set meta mark comment "%s"\n' \
        "$CLIENT_SCOPE_NFT_TABLE" "$CLIENT_SCOPE_NFT_CHAIN" "$family" "$ip" "$mask_clear" "$mark" "$CLIENT_SCOPE_COMMENT"
    done < "$CLIENT_SCOPE_MAP_FILE"
  } > "$tmp"
  _nft -f "$tmp"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

apply() {
  _enabled || return 0
  command -v nft >/dev/null 2>&1 || return 0
  # Validate all interpolated nft identifiers before replacing the table.
  _valid_nft_name "$CLIENT_SCOPE_NFT_CHAIN" || return 0
  _valid_comment "$CLIENT_SCOPE_COMMENT" || return 0
  # Client scopes are derived from the LAN source IP. That information exists
  # before NAT, so this isolated table must always use prerouting. The global
  # zapret2 POSTNAT setting controls zapret2's own flow, not client mapping.
  # Do not require CLIENT_SCOPE_PRENAT or silently create a postrouting table:
  # postrouting is too late and cannot reliably identify the LAN client.
  local hook=prerouting
  _nft "delete table inet $CLIENT_SCOPE_NFT_TABLE" 2>/dev/null || true
  _apply_ruleset "$hook"
}

cleanup() {
  command -v nft >/dev/null 2>&1 || return 0
  # The table name is private and configurable; delete only that table.
  _nft delete table inet "$CLIENT_SCOPE_NFT_TABLE" 2>/dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    apply) apply ;;
    cleanup|remove) cleanup ;;
    *) printf 'usage: %s {apply|cleanup}\n' "$0" >&2; exit 2 ;;
  esac
fi
