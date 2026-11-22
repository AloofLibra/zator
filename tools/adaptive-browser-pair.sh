#!/usr/bin/env bash
# Provision narrowly-scoped browser credentials; independent of adaptive-pair.sh's agent token.
set -eu

ROOT="${ZATOR_ROOT:-/opt/zator}"
CONFIG="${ZAPRET2_ROOT:-/opt/zapret2}/config"
TOKEN_DIR="$ROOT/extra_strats/cache/adaptive"
CLIENTS_FILE="${Z2R_ADAPTIVE_BROWSER_CLIENTS_FILE:-$TOKEN_DIR/browser-clients.tsv}"
. "$ROOT/z2r_lib/config.sh"
. "$ROOT/z2r_lib/orchestra_state.sh"
. "$ROOT/z2r_lib/adaptive_browser.sh"
CONFIG_FILE="$CONFIG"
ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
CLIENT_SCOPE_MAP_FILE="${CLIENT_SCOPE_MAP_FILE:-$ROOT/extra_strats/cache/client_scope.tsv}"

action="${1:-list}"
RANKINGS_OPT_IN="$TOKEN_DIR/browser-rankings-opt-in"
STATS_OPT_IN="$TOKEN_DIR/browser-flow-upload-opt-in"
STATS_TOKEN="$TOKEN_DIR/browser-flow-upload-token"
STATS_QUEUE="$TOKEN_DIR/browser-flow-queue.tsv"
case "$action" in create|rotate|revoke|revoke-all|list|rankings-on|rankings-off|rankings-status|stats-on|stats-off|stats-status|stats-flush) ;; *) echo 'Usage: adaptive-browser-pair.sh {create IPv4 mark:N|default|rotate ID|revoke ID|revoke-all|list|rankings-on|rankings-off|rankings-status|stats-on|stats-off|stats-status|stats-flush}' >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root on the router.' >&2; exit 1; }
[ ! -L "$TOKEN_DIR" ] && [ ! -L "$CLIENTS_FILE" ] && [ ! -L "$RANKINGS_OPT_IN" ] && [ ! -L "$STATS_OPT_IN" ] && [ ! -L "$STATS_TOKEN" ] && [ ! -L "$STATS_QUEUE" ] || { echo 'Refusing symlinked browser pairing state.' >&2; exit 1; }
mkdir -p "$TOKEN_DIR"

private_lan_ipv4() {
  local ip="$1" a b c d
  [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  (( (a == 10) || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) ))
}

validate_scope() {
  local ip="$1" scope="$2" answer
  private_lan_ipv4 "$ip" || { echo 'Browser pairing requires a private IPv4 LAN address.' >&2; return 1; }
  case "$scope" in
    mark:*)
      answer="$(client_scope_ip_get "$ip" 2>/dev/null || true)"
      [[ "$answer" = "$scope" ]] && adaptive_browser_context_valid 00000000000000000000000000000000 "$ip" "$scope" || {
        echo 'The IP must already map to a unique, enabled client scope mark:N.' >&2; return 1;
      }
      ;;
    default)
      [[ "$(cat "$TOKEN_DIR/apply-default-scope" 2>/dev/null || true)" = 1 ]] || {
        echo 'LAN-wide pairing is unavailable until explicit Beta LAN consent is enabled.' >&2; return 1;
      }
      [ -t 0 ] || { echo 'LAN-wide pairing requires an interactive confirmation.' >&2; return 1; }
      echo 'WARNING: default scope can affect every LAN device.' >&2
      read -r -p 'Type LAN-WIDE to pair this browser with LAN-wide scope: ' confirmation
      [[ "$confirmation" = LAN-WIDE ]] || { echo 'LAN-wide pairing cancelled.' >&2; return 1; }
      ;;
    *) echo 'Scope must be mark:N or default.' >&2; return 1 ;;
  esac
}

with_locked_file() {
  local lock="$CLIENTS_FILE.lock" tries=0
  mkdir -p "$(dirname "$CLIENTS_FILE")"
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 30 )) || return 1
    sleep 0.1
  done
  local rc=0
  if "$@"; then rc=0; else rc=$?; fi
  rmdir "$lock" || return 1
  return "$rc"
}

write_record() {
  local id="$1" hash="$2" ip="$3" scope="$4" expires="$5" action="$6"
  local tmp row ver old_id old_hash old_ip old_scope old_expiry extra count=0 found=0
  [[ -f "$CLIENTS_FILE" && ! -L "$CLIENTS_FILE" ]] || : > "$CLIENTS_FILE"
  [[ $(wc -c < "$CLIENTS_FILE") -le 8192 ]] || return 1
  tmp="$(mktemp "$TOKEN_DIR/.browser-clients.XXXXXX")" || return 1
  while IFS= read -r row || [[ -n "$row" ]]; do
    IFS=$'\t' read -r ver old_id old_hash old_ip old_scope old_expiry extra <<< "$row"
    [[ "$ver" = 1 && "$old_id" =~ ^[a-f0-9]{32}$ && "$old_hash" =~ ^[a-f0-9]{64}$ &&
       "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( "$old_scope" = default || "$old_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
       "$old_expiry" =~ ^[0-9]{1,10}$ && -z "${extra:-}" ]] || { rm -f "$tmp"; return 1; }
    count=$((count + 1)); (( count <= 8 )) || { rm -f "$tmp"; return 1; }
    [[ "$action" != revoke-all ]] || continue
    if [[ "$action" = create && "$old_ip" = "$ip" ]] || [[ "$action" != create && "$old_id" = "$id" ]]; then
      found=1
      if [[ "$action" = create ]]; then rm -f "$tmp"; return 2; fi
      [[ "$action" != revoke ]] || continue
      printf '1\t%s\t%s\t%s\t%s\t%s\n' "$id" "$hash" "$ip" "$scope" "$expires" >> "$tmp"
      continue
    fi
    printf '%s\n' "$row" >> "$tmp"
  done < "$CLIENTS_FILE"
  case "$action" in
    create) (( count < 8 )) || { rm -f "$tmp"; return 3; }
      printf '1\t%s\t%s\t%s\t%s\t%s\n' "$id" "$hash" "$ip" "$scope" "$expires" >> "$tmp" ;;
    rotate) (( found )) || { rm -f "$tmp"; return 4; } ;;
    revoke) (( found )) || { rm -f "$tmp"; return 4; } ;;
    revoke-all) : ;;
  esac
  chmod 600 "$tmp" && mv -f "$tmp" "$CLIENTS_FILE" || { rm -f "$tmp"; return 1; }
}

show_clients() {
  local row ver id hash ip scope expiry extra count=0
  [[ -r "$CLIENTS_FILE" && ! -L "$CLIENTS_FILE" ]] || { echo 'No browser clients paired.'; return 0; }
  while IFS= read -r row || [[ -n "$row" ]]; do
    IFS=$'\t' read -r ver id hash ip scope expiry extra <<< "$row"
    [[ "$ver" = 1 && "$id" =~ ^[a-f0-9]{32}$ && "$hash" =~ ^[a-f0-9]{64}$ && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
       ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$expiry" =~ ^[0-9]{1,10}$ && -z "${extra:-}" ]] || continue
    printf '%s\t%s\t%s\n' "$id" "$ip" "$scope"
    count=$((count + 1))
  done < "$CLIENTS_FILE"
  (( count > 0 )) || echo 'No browser clients paired.'
}

case "$action" in
  list)
    show_clients
    ;;
  rankings-status)
    if adaptive_browser_rankings_opted_in; then echo 'Shared adaptive rankings: enabled.'; else echo 'Shared adaptive rankings: disabled.'; fi
    ;;
  rankings-on)
    [ -t 0 ] || { echo 'Ranking consent requires an interactive terminal.' >&2; exit 1; }
    echo 'The router may request provider/profile/protocol rankings from the configured HTTPS stats endpoint while selecting a browser trial.' >&2
    echo 'The request sends no target hostname, destination IP, browser token, or result history; the stats host still sees the router public IP.' >&2
    read -r -p 'Type USE-REDIS-RANKINGS to enable this separate opt-in: ' confirmation
    [[ "$confirmation" = USE-REDIS-RANKINGS ]] || { echo 'Ranking opt-in cancelled.' >&2; exit 1; }
    printf '1\n' > "$RANKINGS_OPT_IN.tmp.$$" && chmod 600 "$RANKINGS_OPT_IN.tmp.$$" && mv -f "$RANKINGS_OPT_IN.tmp.$$" "$RANKINGS_OPT_IN"
    echo 'Shared adaptive rankings enabled.'
    ;;
  rankings-off)
    rm -f "$RANKINGS_OPT_IN"
    echo 'Shared adaptive rankings disabled.'
    ;;
  stats-status)
    if adaptive_browser_stats_opted_in; then
      pending=0; [[ ! -f "$STATS_QUEUE" || -L "$STATS_QUEUE" ]] || pending="$(wc -l < "$STATS_QUEUE")"
      if [[ -f "$STATS_TOKEN" && ! -L "$STATS_TOKEN" ]]; then echo "Browser outcome sharing: enabled; queued rows: $pending."
      else echo "Browser outcome sharing: enabled but token is missing; queued rows: $pending."; fi
    else echo 'Browser outcome sharing: disabled.'; fi
    ;;
  stats-on)
    [ -t 0 ] || { echo 'Statistics consent requires an interactive terminal.' >&2; exit 1; }
    echo 'Only aggregate profile/protocol/strategy fingerprint/outcome dimensions are sent. No hostname, destination IP, browser token, URL, or visit history is uploaded. The stats host sees the router public IP.' >&2
    echo 'This uses a separate server-issued installation token; it does not enable Redis ranking downloads.' >&2
    read -r -p 'Type SHARE-BROWSER-STATS to enable upload: ' confirmation
    [[ "$confirmation" = SHARE-BROWSER-STATS ]] || { echo 'Browser outcome sharing cancelled.' >&2; exit 1; }
    read -r -s -p 'Paste the separately issued adaptive V2 client token: ' stats_token; printf '\n' >&2
    [[ "$stats_token" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || { echo 'Invalid installation token format.' >&2; exit 1; }
    tmp="$STATS_TOKEN.tmp.$$"
    (umask 077; printf '%s\n' "$stats_token" > "$tmp") && chmod 600 "$tmp" && mv -f "$tmp" "$STATS_TOKEN" || { rm -f "$tmp"; echo 'Could not store the installation token.' >&2; exit 1; }
    printf '1\n' > "$STATS_OPT_IN.tmp.$$" && chmod 600 "$STATS_OPT_IN.tmp.$$" && mv -f "$STATS_OPT_IN.tmp.$$" "$STATS_OPT_IN"
    echo 'Browser outcome upload enabled. It runs only after browser trial outcomes; pending data can be sent with stats-flush.'
    ;;
  stats-off)
    rm -f "$STATS_OPT_IN"
    rm -f "$STATS_TOKEN" "$STATS_QUEUE"
    echo 'Browser outcome sharing disabled; its token and queued results were removed.'
    ;;
  stats-flush)
    if adaptive_browser_stats_flush; then echo 'Browser outcome queue flushed (if the endpoint accepted it).'
    else echo 'Browser outcome queue remains pending; upload failed or consent/token/provider is unavailable.' >&2; exit 1; fi
    ;;
  create)
    [[ $# = 3 ]] || { echo 'Usage: adaptive-browser-pair.sh create CLIENT_IPV4 mark:N|default' >&2; exit 2; }
    client_ip="$2"; scope="$3"; validate_scope "$client_ip" "$scope"
    id="$(adaptive_browser_random_hex 16)"
    token="$(adaptive_browser_random_hex 32)"
    [[ "$id" =~ ^[a-f0-9]{32}$ && "$token" =~ ^[a-f0-9]{64}$ ]] || { echo 'Secure random token generation failed.' >&2; exit 1; }
    now="$(date +%s)"; expiry=$((now + 2592000)); hash="$(printf '%s' "$token" | sha256sum | awk '{print $1}')"
    if with_locked_file write_record "$id" "$hash" "$client_ip" "$scope" "$expiry" create; then
      printf 'Browser client ID: %s\nBrowser token (shown once): %s\nExpires in 30 days.\n' "$id" "$token"
      echo 'Enter this token only in the Zator Browser Feedback extension. It is separate from the Windows-agent token.'
    else
      rc=$?; case "$rc" in 2) echo 'A browser is already paired for this LAN IP; use rotate or revoke first.' >&2;; 3) echo 'Browser pairing limit reached (8 clients).' >&2;; *) echo 'Browser pairing failed.' >&2;; esac; exit 1
    fi
    ;;
  rotate)
    [[ $# = 2 && "$2" =~ ^[a-f0-9]{32}$ ]] || { echo 'Usage: adaptive-browser-pair.sh rotate CLIENT_ID' >&2; exit 2; }
    id="$2"; current="$(awk -F '\t' -v id="$id" '$1==1 && $2==id {print $4 "\t" $5; exit}' "$CLIENTS_FILE" 2>/dev/null)"
    [[ -n "$current" ]] || { echo 'Browser client not found.' >&2; exit 1; }
    IFS=$'\t' read -r client_ip scope <<< "$current"; validate_scope "$client_ip" "$scope"
    token="$(adaptive_browser_random_hex 32)"; [[ "$token" =~ ^[a-f0-9]{64}$ ]] || exit 1
    now="$(date +%s)"; expiry=$((now + 2592000)); hash="$(printf '%s' "$token" | sha256sum | awk '{print $1}')"
    with_locked_file write_record "$id" "$hash" "$client_ip" "$scope" "$expiry" rotate || { echo 'Browser token rotation failed.' >&2; exit 1; }
    printf 'Browser token rotated (shown once): %s\nExpires in 30 days.\n' "$token"
    ;;
  revoke)
    [[ $# = 2 && "$2" =~ ^[a-f0-9]{32}$ ]] || { echo 'Usage: adaptive-browser-pair.sh revoke CLIENT_ID' >&2; exit 2; }
    with_locked_file write_record "$2" - - - 0 revoke || { echo 'Browser client not found or could not be revoked.' >&2; exit 1; }
    echo 'Browser client revoked.'
    ;;
  revoke-all)
    with_locked_file write_record - - - - 0 revoke-all || exit 1
    echo 'All browser clients revoked.'
    ;;
esac
