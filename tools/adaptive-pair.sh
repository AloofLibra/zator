#!/usr/bin/env bash
# This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
set -eu

ROOT="${ZATOR_ROOT:-/opt/zator}"
TOKEN_DIR="$ROOT/extra_strats/cache/adaptive"
TOKEN_FILE="$TOKEN_DIR/token"
TOKEN_EXPIRY_FILE="$TOKEN_DIR/token.expires"
MODE_FILE="$TOKEN_DIR/mode"
BASE="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}"
EVENTS_FILE="${Z2R_ADAPTIVE_EVENTS_FILE:-$BASE/events.tsv}"
[ -r "$ROOT/z2r_lib/adaptive_queue.sh" ] && . "$ROOT/z2r_lib/adaptive_queue.sh"
if [ -r "$ROOT/z2r_lib/config.sh" ] && [ -r "$ROOT/z2r_lib/adaptive_lan_transport.sh" ]; then
  . "$ROOT/z2r_lib/config.sh"
  . "$ROOT/z2r_lib/adaptive_lan_transport.sh"
  CONFIG_FILE="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  FWTYPE="$(config_get_var "$CONFIG_FILE" FWTYPE 2>/dev/null | tr -d '"\047')"
  ZAPRET_NFT_TABLE="$(config_get_var "$CONFIG_FILE" ZAPRET_NFT_TABLE 2>/dev/null | tr -d '"\047')"
  POSTNAT="$(config_get_var "$CONFIG_FILE" POSTNAT 2>/dev/null | tr -d '"\047')"
  POSTNAT_ALL="$(config_get_var "$CONFIG_FILE" POSTNAT_ALL 2>/dev/null | tr -d '"\047')"
fi
Z2R_ADAPTIVE_LOCK_DIR="${Z2R_ADAPTIVE_LOCK_DIR:-/tmp/z2r-supersweep.lock}"
action="${1:-create}"
case "$action" in status|doctor|create|rotate|disable|observe|test-only|pause|events|clear-events) ;; *) echo 'Usage: adaptive-pair.sh [status|doctor|create|rotate|disable|observe|test-only|pause|events|clear-events]' >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root on the router.' >&2; exit 1; }
[ ! -L "$TOKEN_DIR" ] || { echo 'Refusing a symlinked adaptive token directory.' >&2; exit 1; }
adaptive_mode() {
  local mode
  mode="$(cat "$MODE_FILE" 2>/dev/null || printf 'OFF')"
  case "$mode" in OBSERVE|TEST_ONLY) printf '%s\n' "$mode" ;; *) printf 'OFF\n' ;; esac
}
adaptive_set_mode() {
  local mode="$1" tmp
  mkdir -p "$TOKEN_DIR" || return 1
  tmp="$(mktemp "$TOKEN_DIR/.mode.XXXXXX")" || return 1
  printf '%s\n' "$mode" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$MODE_FILE" || {
    rm -f "$tmp"; return 1;
  }
}
adaptive_token_valid() {
  local token expiry now
  [ -s "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ] && [ -r "$TOKEN_EXPIRY_FILE" ] && [ ! -L "$TOKEN_EXPIRY_FILE" ] || return 1
  token="$(cat "$TOKEN_FILE" 2>/dev/null)"
  expiry="$(cat "$TOKEN_EXPIRY_FILE" 2>/dev/null)"
  now="$(date +%s)" || return 1
  [[ "$token" =~ ^[a-f0-9]{64}$ && "$expiry" =~ ^[0-9]{1,10}$ && "$now" =~ ^[0-9]{1,10}$ ]] || return 1
  (( expiry > now ))
}
adaptive_prepare_events() {
  local config user uid gid
  [ ! -L "$BASE" ] && [ ! -L "$EVENTS_FILE" ] || return 1
  config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  user="$(awk -F= '$1=="WS_USER" {gsub(/["[:space:]]/, "", $2); print $2; exit}' "$config" 2>/dev/null)"
  [ -n "$user" ] || user=nobody
  uid="$(id -u "$user" 2>/dev/null)"; gid="$(id -g "$user" 2>/dev/null)"
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
  mkdir -p "$TOKEN_DIR" "$BASE" && touch "$EVENTS_FILE" || return 1
  chown 0:0 "$TOKEN_DIR" && chmod 711 "$TOKEN_DIR" || return 1
  chown "$uid:$gid" "$EVENTS_FILE" && chmod 600 "$EVENTS_FILE"
}
adaptive_pause_mode() {
  local tmp run run_id
  [ ! -L "$EVENTS_FILE" ] || return 1
  mkdir -p "$TOKEN_DIR"
  tmp="$(mktemp "$TOKEN_DIR/.mode.XXXXXX")" || return 1
  printf 'OFF\n' > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$MODE_FILE" || { rm -f "$tmp"; return 1; }
  [ ! -e "$EVENTS_FILE" ] || chmod 400 "$EVENTS_FILE"
  if [ -d "$BASE" ] && [ ! -L "$BASE" ]; then
    for run in "$BASE"/*; do
      [ -d "$run" ] && [ ! -L "$run" ] || continue
      run_id="${run##*/}"
      case "$run_id" in *[!a-f0-9]*|'') continue ;; esac
      [ "${#run_id}" = 32 ] || continue
      : > "$run/cancel" 2>/dev/null || true
    done
  fi
}
adaptive_wait_probe_cleanup() {
  local attempt run run_id state active
  for ((attempt=0; attempt<15; attempt++)); do
    active=0
    if [ -d "$BASE" ] && [ ! -L "$BASE" ]; then
      for run in "$BASE"/*; do
        [ -d "$run" ] && [ ! -L "$run" ] || continue
        run_id="${run##*/}"
        case "$run_id" in *[!a-f0-9]*|'') continue ;; esac
        [ "${#run_id}" = 32 ] || continue
        state="$(cat "$run/state" 2>/dev/null || true)"
        [ "$state" != cleanup_failed ] || return 1
        case "$state" in complete|failed) ;; *) active=1 ;; esac
      done
    fi
    [ "$active" = 0 ] && return 0
    sleep 1
  done
  if type adaptive_lan_transport_recover_stale >/dev/null 2>&1; then
    adaptive_lan_transport_recover_stale "$BASE" || return 1
    active=0
    if [ -d "$BASE" ] && [ ! -L "$BASE" ]; then
      for run in "$BASE"/*; do
        [ -d "$run" ] && [ ! -L "$run" ] || continue
        run_id="${run##*/}"
        case "$run_id" in *[!a-f0-9]*|'') continue ;; esac
        [ "${#run_id}" = 32 ] || continue
        state="$(cat "$run/state" 2>/dev/null || true)"
        case "$state" in complete|failed) ;; *) active=1 ;; esac
      done
    fi
    [ "$active" = 0 ] && return 0
  fi
  return 1
}
if [ "$action" = status ]; then
  if adaptive_token_valid; then
    echo 'Adaptive agent pairing: paired'
  elif [ -s "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ]; then
    echo 'Adaptive agent pairing: expired or invalid; rotate the token'
  else
    echo 'Adaptive agent pairing: disabled'
  fi
  printf 'Adaptive observation: %s\n' "$(adaptive_mode)"
  echo 'Automatic strategy application: disabled'
  BASE="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}"
  active=0; cleanup_failed=0
  if [ -d "$BASE" ] && [ ! -L "$BASE" ]; then
    for run in "$BASE"/*; do
      [ -d "$run" ] && [ ! -L "$run" ] || continue
      run_id="${run##*/}"
      case "$run_id" in *[!a-f0-9]*|'') continue ;; esac
      [ "${#run_id}" = 32 ] || continue
      state="$(cat "$run/state" 2>/dev/null || true)"
      case "$state" in cleanup_failed) cleanup_failed=$((cleanup_failed + 1)) ;; complete|failed) ;; *) active=$((active + 1)) ;; esac
    done
  fi
  printf 'Active probes: %s; cleanup failures: %s\n' "$active" "$cleanup_failed"
  queue_file="${Z2R_ADAPTIVE_QUEUE_FILE:-/proc/net/netfilter/nfnetlink_queue}"
  if [ -r "$queue_file" ]; then
    queue_pid="$(awk '$1==65535 {n++; pid=$2} END {if(n==1) print pid; else if(n>1) print "duplicate"}' "$queue_file")"
    [ -n "$queue_pid" ] && printf 'Test NFQUEUE 65535: registered (PID %s)\n' "$queue_pid" \
      || echo 'Test NFQUEUE 65535: free'
  else
    echo 'Test NFQUEUE 65535: unavailable'
  fi
  rules_file="${Z2R_ADAPTIVE_RULES_FILE:-$BASE/rules.tsv}"
  if [ ! -r "$rules_file" ]; then rules_file="$TOKEN_DIR/rules.tsv"; fi
  now="$(date +%s)"
  rules=0
  [ ! -r "$rules_file" ] || rules="$(awk -F '\t' -v now="$now" '
    NF==11 && $1==1 && $11 ~ /^[0-9]+$/ && $11>now {n++}
    END {print n+0}
  ' "$rules_file")"
  printf 'Stored exact rules: %s\n' "$rules"
  event_count=0
  [ ! -r "$EVENTS_FILE" ] || event_count="$(awk -F '\t' 'NR<=128 && NF==8 && $1==1 && ($2=="seen" || $2=="needs_verify" || $2=="suspected_failure") {n++} END {print n+0}' "$EVENTS_FILE")"
  printf 'Observation events: %s\n' "$event_count"
  exit 0
fi
if [ "$action" = doctor ]; then
  doctor_fail=0
  doctor_check() {
    local label="$1" result="$2" required="${3:-1}"
    printf '%-34s %s\n' "$label" "$result"
    [ "$result" = OK ] || [ "$required" = 0 ] || doctor_fail=1
  }
  config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  nfqws="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
  doctor_check 'zapret2 config' "$([ -r "$config" ] && [ ! -L "$config" ] && printf OK || printf MISSING)"
  doctor_check 'adaptive controller' "$([ -x "$ROOT/tools/adaptive-controller.sh" ] && [ ! -L "$ROOT/tools/adaptive-controller.sh" ] && printf OK || printf MISSING)"
  doctor_check 'LAN transport helper' "$([ -r "$ROOT/z2r_lib/adaptive_lan_transport.sh" ] && [ ! -L "$ROOT/z2r_lib/adaptive_lan_transport.sh" ] && printf OK || printf MISSING)"
  doctor_check 'nfqws2 binary' "$([ -x "$nfqws" ] && [ ! -L "$nfqws" ] && printf OK || printf MISSING)"
  token_state=MISSING
  if adaptive_token_valid; then token_state=OK
  elif [ -s "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ]; then token_state=EXPIRED_OR_INVALID; fi
  doctor_check 'paired agent token' "$token_state"
  mode="$(adaptive_mode)"
  case "$mode" in OBSERVE|TEST_ONLY) doctor_check 'runtime mode' "$mode" 0 ;; *) doctor_check 'runtime mode' OFF 0 ;; esac
  fwtype="$(awk -F= '$1=="FWTYPE" {gsub(/["[:space:]]/, "", $2); print $2; exit}' "$config" 2>/dev/null)"
  case "$fwtype" in
    nft|nftables) backend=nft; command -v nft >/dev/null 2>&1 && backend_state=OK || backend_state=MISSING ;;
    iptables|'') backend=iptables; command -v iptables >/dev/null 2>&1 && backend_state=OK || backend_state=MISSING ;;
    *) backend="$fwtype"; backend_state=UNSUPPORTED ;;
  esac
  doctor_check "firewall backend ($backend)" "$backend_state"
  queue_file="${Z2R_ADAPTIVE_QUEUE_FILE:-/proc/net/netfilter/nfnetlink_queue}"
  if [ -r "$queue_file" ]; then
    queue_state="$(awk '$1==65535 {n++; pid=$2} END {if(n==0) print "FREE"; else if(n==1) print "BUSY:" pid; else print "DUPLICATE"}' "$queue_file")"
    case "$queue_state" in
      FREE) doctor_check 'test NFQUEUE 65535' OK ;;
      BUSY:*) doctor_check 'test NFQUEUE 65535' "$queue_state" ;;
      *) doctor_check 'test NFQUEUE 65535' "$queue_state" ;;
    esac
  else doctor_check 'test NFQUEUE 65535' UNAVAILABLE; fi
  echo 'AUTO mode: unavailable; pending Windows agent/API end-to-end, firewall rebuild/crash recovery, alternate route/offload, and load/resource acceptance.'
  echo 'This check is read-only; it does not install firewall rules or start a probe.'
  exit "$doctor_fail"
fi
if [ "$action" = observe ]; then
  adaptive_wait_probe_cleanup || { echo 'Active probe cleanup did not finish; observation mode was not changed.' >&2; exit 1; }
  adaptive_prepare_events || { echo 'Could not prepare private observation queue.' >&2; exit 1; }
  adaptive_set_mode OBSERVE || exit 1
  echo 'Observation enabled. Restart zapret2 to load the mode; strategy selection remains unchanged.'
  exit 0
fi
if [ "$action" = test-only ]; then
  [ -s "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ] || { echo 'Pair the agent first with: adaptive-pair.sh create' >&2; exit 1; }
  adaptive_wait_probe_cleanup || { echo 'Active probe cleanup did not finish; TEST_ONLY mode was not changed.' >&2; exit 1; }
  adaptive_prepare_events || { echo 'Could not prepare private observation queue.' >&2; exit 1; }
  adaptive_set_mode TEST_ONLY || { echo 'Could not enable test-only mode.' >&2; exit 1; }
  echo 'TEST_ONLY enabled: restart zapret2 to load event observation; authenticated probes may run, automatic strategy application remains disabled.'
  exit 0
fi
if [ "$action" = pause ]; then
  adaptive_pause_mode || { echo 'Could not disable observation.' >&2; exit 1; }
  adaptive_wait_probe_cleanup || { echo 'Active probe cleanup did not finish; adaptive mode is OFF but needs cleanup.' >&2; exit 1; }
  echo 'Observation paused. Restart zapret2 to reload the mode.'
  exit 0
fi
if [ "$action" = events ]; then
  if [ -r "$EVENTS_FILE" ]; then
    awk -F '\t' 'NR<=128 && NF==8 && $1==1 && ($2=="seen" || $2=="needs_verify" || $2=="suspected_failure") && $3 ~ /^[a-z0-9][a-z0-9.-]*[a-z0-9]$/ && $4 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && $5 ~ /^[1-4]$/ && $6=="tls" && ($7=="default" || $7 ~ /^mark:[0-9]+$/) && $8 ~ /^[0-9]+$/ {print $2 "\t" $3 "\t" $4 "\tprofile=" $5 "\t" $8}' "$EVENTS_FILE"
  fi
  exit 0
fi
if [ "$action" = clear-events ]; then
  [ ! -L "$EVENTS_FILE" ] || { echo 'Refusing a symlinked observation queue.' >&2; exit 1; }
  adaptive_pause_mode || { echo 'Could not pause observation.' >&2; exit 1; }
  adaptive_wait_probe_cleanup || { echo 'Active probe cleanup did not finish; adaptive mode is OFF but events were not cleared.' >&2; exit 1; }
  if type adaptive_queue_clear >/dev/null 2>&1; then adaptive_queue_clear || { echo 'Could not clear queued probe requests.' >&2; exit 1; }; fi
  if [ -e "$EVENTS_FILE" ]; then
    tmp="$(mktemp "$EVENTS_FILE.tmp.XXXXXX")" || exit 1
    owner="$(stat -c '%u:%g' "$EVENTS_FILE" 2>/dev/null)"
    [[ "$owner" =~ ^[0-9]+:[0-9]+$ ]] || { rm -f "$tmp"; exit 1; }
    chown "$owner" "$tmp" && chmod 400 "$tmp" && mv -f "$tmp" "$EVENTS_FILE" || {
      rm -f "$tmp"; exit 1;
    }
  fi
  echo 'Observation queue cleared and paused; restart zapret2 to reload the mode.'
  exit 0
fi
if [ "$action" = disable ]; then
  adaptive_pause_mode || true
  adaptive_wait_probe_cleanup || { echo 'Probe cleanup did not finish; check the adaptive probe state before uninstalling.' >&2; exit 1; }
  if type adaptive_queue_clear >/dev/null 2>&1; then adaptive_queue_clear || { echo 'Could not clear queued probe requests.' >&2; exit 1; }; fi
  rm -f "$EVENTS_FILE"
  rm -f "$TOKEN_FILE" "$TOKEN_EXPIRY_FILE" "$TOKEN_FILE.tmp."* "$TOKEN_EXPIRY_FILE.tmp."*
  if [ -f "$ROOT/z2r_lib/adaptive_rules.sh" ]; then
    . "$ROOT/z2r_lib/adaptive_rules.sh"
    adaptive_rules_invalidate || { echo 'Could not clear adaptive rules.' >&2; exit 1; }
  fi
  echo 'Adaptive agent disabled; active probes are cancelling through cleanup.'
  exit 0
fi
if [ "$action" = create ] && [ -e "$TOKEN_FILE" ]; then
  echo 'Adaptive pairing already exists; use rotate to revoke it and create a new token.' >&2
  exit 1
fi
mkdir -p "$TOKEN_DIR"
umask 077
token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
case "$token" in *[!a-f0-9]*|'') echo 'Secure random token generation failed.' >&2; exit 1 ;; esac
[ "${#token}" = 64 ] || { echo 'Secure random token generation failed.' >&2; exit 1; }
now="$(date +%s)" || exit 1
[[ "$now" =~ ^[0-9]{1,10}$ ]] || { echo 'System clock is invalid; pairing token was not created.' >&2; exit 1; }
expiry=$((now + 2592000))
tmp="$(mktemp "$TOKEN_DIR/.token.XXXXXX")" || exit 1
expiry_tmp="$(mktemp "$TOKEN_DIR/.token-expiry.XXXXXX")" || { rm -f "$tmp"; exit 1; }
printf '%s' "$token" > "$tmp" && printf '%s\n' "$expiry" > "$expiry_tmp" || {
  rm -f "$tmp" "$expiry_tmp"; exit 1;
}
chmod 600 "$tmp" "$expiry_tmp"
mv -f "$tmp" "$TOKEN_FILE" && mv -f "$expiry_tmp" "$TOKEN_EXPIRY_FILE" || {
  rm -f "$tmp" "$expiry_tmp" "$TOKEN_FILE" "$TOKEN_EXPIRY_FILE"; exit 1;
}
printf 'Adaptive agent token: %s\n' "$token"
printf 'Token expires at Unix time: %s (30 days)\n' "$expiry"
printf 'Keep it private. Rotate with: %s rotate\n' "$0"
