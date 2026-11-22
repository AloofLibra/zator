#!/usr/bin/env bash
# This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
set -eu

ROOT="${ZATOR_ROOT:-/opt/zator}"
TOKEN_DIR="$ROOT/extra_strats/cache/adaptive"
TOKEN_FILE="$TOKEN_DIR/token"
TOKEN_EXPIRY_FILE="$TOKEN_DIR/token.expires"
MODE_FILE="$TOKEN_DIR/mode"
DEFAULT_SCOPE_FILE="$TOKEN_DIR/apply-default-scope"
RAMP_POOL_FILE="$TOKEN_DIR/ramp-pool"
RAMP_POOL_ARM_FILE="$TOKEN_DIR/ramp-pool-armed"
BASE="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}"
EVENTS_FILE="${Z2R_ADAPTIVE_EVENTS_FILE:-$BASE/events.tsv}"
RAMP_TARGETS_FILE="${Z2R_ADAPTIVE_RAMP_TARGETS_FILE:-$BASE/ramp-targets.tsv}"
[ -r "$ROOT/z2r_lib/adaptive_queue.sh" ] && . "$ROOT/z2r_lib/adaptive_queue.sh"
[ -r "$ROOT/tools/adaptive-ramp-proof.sh" ] && . "$ROOT/tools/adaptive-ramp-proof.sh"
if [ -r "$ROOT/z2r_lib/config.sh" ] && [ -r "$ROOT/z2r_lib/adaptive_lan_transport.sh" ]; then
  . "$ROOT/z2r_lib/config.sh"
  . "$ROOT/z2r_lib/adaptive_lan_transport.sh"
  [ ! -r "$ROOT/z2r_lib/googlevideo_ips.sh" ] || . "$ROOT/z2r_lib/googlevideo_ips.sh"
  CONFIG_FILE="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  FWTYPE="$(config_get_var "$CONFIG_FILE" FWTYPE 2>/dev/null | tr -d '"\047')"
  ZAPRET_NFT_TABLE="$(config_get_var "$CONFIG_FILE" ZAPRET_NFT_TABLE 2>/dev/null | tr -d '"\047')"
  POSTNAT="$(config_get_var "$CONFIG_FILE" POSTNAT 2>/dev/null | tr -d '"\047')"
  POSTNAT_ALL="$(config_get_var "$CONFIG_FILE" POSTNAT_ALL 2>/dev/null | tr -d '"\047')"
fi
Z2R_ADAPTIVE_LOCK_DIR="${Z2R_ADAPTIVE_LOCK_DIR:-/tmp/z2r-supersweep.lock}"
action="${1:-create}"
case "$action" in status|doctor|create|rotate|disable|observe|test-only|beta|beta-lan|ramp-pool-arm|ramp-pool-on|ramp-pool-proof-on|ramp-pool-off|pause|events|clear-events) ;; *) echo 'Usage: adaptive-pair.sh [status|doctor|create|rotate|disable|observe|test-only|beta|beta-lan|ramp-pool-arm|ramp-pool-on|ramp-pool-off|pause|events|clear-events]' >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root on the router.' >&2; exit 1; }
[ ! -L "$TOKEN_DIR" ] || { echo 'Refusing a symlinked adaptive token directory.' >&2; exit 1; }
adaptive_mode() {
  local mode
  mode="$(cat "$MODE_FILE" 2>/dev/null || printf 'OFF')"
  case "$mode" in OBSERVE|TEST_ONLY|AGENT_BETA) printf '%s\n' "$mode" ;; *) printf 'OFF\n' ;; esac
}
adaptive_set_mode() {
  local mode="$1" tmp
  if [ "$mode" != AGENT_BETA ] && [ "$(adaptive_mode)" = AGENT_BETA ]; then
    adaptive_ramp_pool_restore || return 1
  fi
  mkdir -p "$TOKEN_DIR" || return 1
  if [ "$mode" != AGENT_BETA ]; then rm -f "$DEFAULT_SCOPE_FILE" || return 1; fi
  tmp="$(mktemp "$TOKEN_DIR/.mode.XXXXXX")" || return 1
  printf '%s\n' "$mode" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$MODE_FILE" || {
    rm -f "$tmp"; return 1;
  }
}
adaptive_set_default_scope() {
  local value="$1" tmp
  case "$value" in 0|1) ;; *) return 2 ;; esac
  if [ "$value" = 0 ]; then rm -f "$DEFAULT_SCOPE_FILE"; return $?; fi
  tmp="$(mktemp "$TOKEN_DIR/.default-scope.XXXXXX")" || return 1
  printf '1\n' > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$DEFAULT_SCOPE_FILE" || {
    rm -f "$tmp"; return 1;
  }
}
adaptive_ramp_pool_supported() {
  local config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [ -r "$config" ] && [ ! -L "$config" ] || return 1
  [ "$(config_get_var "$config" NFQWS2_ENABLE 2>/dev/null | tr -d '"\047')" = 1 ] || return 1
  grep -q -- '--lua-desync=wssize_ramp' "$config" || return 1
  [ -s "$ROOT/lua/wssize-ramp.lua" ] && [ ! -L "$ROOT/lua/wssize-ramp.lua" ] || return 1
  local ipset path
  ipset="$(config_get_var "$config" Z2R_WSSIZE_RAMP_IPSET 2>/dev/null | tr -d '"\047')"
  case "$ipset" in
    /opt/zator/*) path="$ROOT/${ipset#/opt/zator/}" ;;
    /opt/zapret2/*) path="${ZAPRET2_ROOT:-/opt/zapret2}/${ipset#/opt/zapret2/}" ;;
    /*) path="$ipset" ;;
    *) return 1 ;;
  esac
  [ -s "$path" ] && [ ! -L "$path" ] || return 1
  command -v googlevideo_ips_validate >/dev/null 2>&1 || return 1
  googlevideo_ips_validate "$path"
}
adaptive_ramp_pool_fingerprint() {
  local config="${ZAPRET2_ROOT:-/opt/zapret2}/config" key value
  [ -r "$config" ] && [ ! -L "$config" ] || return 1
  for key in NFQWS2_ENABLE Z2R_WSSIZE_RAMP_MODE Z2R_WSSIZE_RAMP_WSIZE Z2R_WSSIZE_RAMP_SCALE \
    Z2R_WSSIZE_RAMP_OPEN Z2R_WSSIZE_RAMP_SYNDATA Z2R_WSSIZE_RAMP_SYN_BLOB Z2R_WSSIZE_RAMP_IPSET Z2R_WSSIZE_MARK; do
    value="$(config_get_var "$config" "$key" 2>/dev/null | tr -d '"\047')" || return 1
    printf '%s=%s\n' "$key" "$value"
  done | sha256sum | awk '{print $1}'
}
adaptive_ramp_pool_write_state() {
  local ownership="$1" basis="${2:-manual_unverified}" fingerprint="${3:-}" proof="${4:-}" tmp
  [[ "$ownership" = managed || "$ownership" = preexisting ]] || return 1
  if [ "$ownership" = managed ]; then [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  else [ -z "$fingerprint" ] || return 1; fi
  case "$basis" in
    manual_unverified) [ -z "$proof" ] || return 1 ;;
    proof_verified) [[ "$ownership" = managed && "$proof" =~ ^[a-f0-9]{64}$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  mkdir -p "$TOKEN_DIR" || return 1
  [ ! -L "$TOKEN_DIR" ] && [ ! -L "$RAMP_POOL_FILE" ] || return 1
  tmp="$(mktemp "$TOKEN_DIR/.ramp-pool.XXXXXX")" || return 1
  (umask 077; if [ "$ownership" = managed ]; then
    if [ "$basis" = proof_verified ]; then printf '1\tmanaged\t%s\t%s\t%s\n' "$basis" "$fingerprint" "$proof" > "$tmp"
    else printf '1\tmanaged\t%s\t%s\n' "$basis" "$fingerprint" > "$tmp"; fi
  else
    printf '1\tpreexisting\t%s\n' "$basis" > "$tmp"
  fi) && chmod 600 "$tmp" && mv -f "$tmp" "$RAMP_POOL_FILE" || { rm -f "$tmp"; return 1; }
}
adaptive_ramp_pool_enabled() {
  local version ownership basis fingerprint extra proof
  [ -f "$RAMP_POOL_FILE" ] && [ ! -L "$RAMP_POOL_FILE" ] && [ "$(wc -c < "$RAMP_POOL_FILE")" -le 256 ] || return 1
  IFS=$'\t' read -r version ownership basis fingerprint extra < "$RAMP_POOL_FILE" || return 1
  if [ "$ownership" = managed ]; then
    if [ "$basis" = manual_unverified ]; then [[ "$version" = 1 && "$fingerprint" =~ ^[a-f0-9]{64}$ && -z "$extra" ]]
    else IFS=$'\t' read -r version ownership basis fingerprint extra proof < "$RAMP_POOL_FILE" || return 1
      [[ "$version" = 1 && "$ownership" = managed && "$basis" = proof_verified && "$fingerprint" =~ ^[a-f0-9]{64}$ && "$extra" =~ ^[a-f0-9]{64}$ && -z "$proof" ]]
    fi
  else [[ "$version" = 1 && "$ownership" = preexisting && "$basis" = manual_unverified && -z "$fingerprint" && -z "$extra" ]]; fi
}
adaptive_ramp_pool_armed() {
  local version state fingerprint extra current
  [ -f "$RAMP_POOL_ARM_FILE" ] && [ ! -L "$RAMP_POOL_ARM_FILE" ] && [ "$(wc -c < "$RAMP_POOL_ARM_FILE")" -le 256 ] || return 1
  IFS=$'\t' read -r version state fingerprint extra < "$RAMP_POOL_ARM_FILE" || return 1
  [[ "$version" = 1 && "$state" = armed && "$fingerprint" =~ ^[a-f0-9]{64}$ && -z "$extra" ]] || return 1
  [ "$(adaptive_mode)" = AGENT_BETA ] && [ "$(cat "$DEFAULT_SCOPE_FILE" 2>/dev/null || true)" = 1 ] || return 1
  [ "$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')" = 0 ] || return 1
  current="$(adaptive_ramp_pool_fingerprint)" || return 1
  [ "$fingerprint" = "$current" ]
}
adaptive_ramp_pool_arm() {
  local current fingerprint tmp
  [ "$(adaptive_mode)" = AGENT_BETA ] && [ "$(cat "$DEFAULT_SCOPE_FILE" 2>/dev/null || true)" = 1 ] || {
    echo 'Proof-triggered Ramp-first requires AGENT_BETA with explicit LAN-wide scope consent.' >&2; return 1;
  }
  adaptive_ramp_pool_supported || { echo 'Ramp-first is unavailable on this platform or its Googlevideo pool is not ready.' >&2; return 1; }
  current="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')"
  [ "$current" = 0 ] || { echo 'Ramp is already enabled; use ramp-pool-on for explicit manual consent.' >&2; return 1; }
  [ ! -e "$RAMP_POOL_FILE" ] && [ ! -e "$RAMP_POOL_ARM_FILE" ] || { echo 'Ramp pool consent or proof is already active.' >&2; return 1; }
  fingerprint="$(adaptive_ramp_pool_fingerprint)" || return 1
  mkdir -p "$TOKEN_DIR" || return 1
  tmp="$(mktemp "$TOKEN_DIR/.ramp-pool-armed.XXXXXX")" || return 1
  printf '1\tarmed\t%s\n' "$fingerprint" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$RAMP_POOL_ARM_FILE" || { rm -f "$tmp"; return 1; }
  echo 'Ramp-first proof armed for observed Googlevideo targets. Production config is unchanged; Ramp will be enabled only after a route-verified Ramp/plain/Ramp media proof.'
}
adaptive_ramp_pool_enable_proven() {
  local host="$1" ip="$2" scope="$3" ids="$4" proof current fingerprint config ramp_ipset now
  local ver row_host row_ip row_scope seen provenance group state dns_expiry media extra exact=0 conflict=0
  proof="$(adaptive_ramp_proof_validate "$ids" "$host" "$ip" "$scope")" || {
    echo 'Ramp-first controller results did not verify.' >&2; return 1;
  }
  adaptive_ramp_pool_armed || { echo 'Ramp-first proof consent or configuration changed; refusing automatic enable.' >&2; return 1; }
  config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  current="$(config_get_var "$config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')"
  [ "$current" = 0 ] || { echo 'Ramp enable flag changed during proof; refusing automatic enable.' >&2; return 1; }
  _adaptive_lan_public_ipv4_valid "$ip" && [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || return 1
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 1; fi
  now="$(date +%s)" || return 1
  [[ -r "$RAMP_TARGETS_FILE" && ! -L "$RAMP_TARGETS_FILE" ]] || return 1
  while IFS=$'\t' read -r ver row_host row_ip row_scope seen provenance group state dns_expiry media extra || [[ -n "$ver$row_host$row_ip" ]]; do
    [[ "$ver" = 1 && "$provenance" = tls-observed && "$seen" =~ ^[0-9]{1,10}$ ]] || continue
    (( seen >= now - 86400 && seen <= now + 60 )) || continue
    [[ "$dns_expiry" =~ ^[0-9]{1,10}$ ]] && (( dns_expiry == 0 || dns_expiry > now )) || continue
    if [[ "$row_ip" = "$ip" && ( "$row_host" != "$host" || "$row_scope" != "$scope" ) ]] ||
       [[ "$row_host" = "$host" && ( "$row_ip" != "$ip" || "$row_scope" != "$scope" ) ]] ||
       [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" = "$scope" && "$state" = conflict ]]; then conflict=1; fi
    [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" = "$scope" ]] && exact=1
  done < "$RAMP_TARGETS_FILE"
  (( exact && ! conflict )) || { echo 'Ramp-first proof target is no longer an exact, conflict-free observation.' >&2; return 1; }
  ramp_ipset="$(config_get_var "$config" Z2R_WSSIZE_RAMP_IPSET 2>/dev/null | tr -d '"\047')"
  case "$ramp_ipset" in /opt/zator/*) ramp_ipset="$ROOT/${ramp_ipset#/opt/zator/}" ;; /opt/zapret2/*) ramp_ipset="${ZAPRET2_ROOT:-/opt/zapret2}/${ramp_ipset#/opt/zapret2/}" ;; esac
  [ -r "$ramp_ipset" ] && [ ! -L "$ramp_ipset" ] && grep -Fqx -- "$ip" "$ramp_ipset" || {
    echo 'Ramp-first proof target is no longer in the configured Googlevideo pool.' >&2; return 1;
  }
  fingerprint="$(adaptive_ramp_pool_fingerprint)" || return 1
  adaptive_ramp_pool_set_config 1 || return 1
  if ! adaptive_ramp_pool_write_state managed proof_verified "$fingerprint" "$proof"; then
    adaptive_ramp_pool_set_config 0 || echo 'WARNING: Ramp config rollback failed after proof-state write failure.' >&2
    return 1
  fi
  rm -f "$RAMP_POOL_ARM_FILE" || {
    adaptive_ramp_pool_set_config 0 || echo 'WARNING: Ramp config rollback failed after arm-state cleanup failure.' >&2
    rm -f "$RAMP_POOL_FILE"
    return 1
  }
  echo 'Ramp-first enabled for the configured Googlevideo IP pool after local media proof. Restart zapret2 to apply it.'
}
adaptive_ramp_pool_set_config() {
  local enabled="$1" config="${ZAPRET2_ROOT:-/opt/zapret2}/config" tmp
  [ "$enabled" = 0 ] || [ "$enabled" = 1 ] || return 1
  [ -f "$config" ] && [ ! -L "$config" ] || return 1
  tmp="$(mktemp "${config}.adaptive.XXXXXX")" || return 1
  cp -p "$config" "$tmp" && config_set_var "$tmp" Z2R_WSSIZE_RAMP_ENABLE "$enabled" && mv -f "$tmp" "$config" || {
    rm -f "$tmp"
    return 1
  }
}
adaptive_ramp_pool_enable() {
  local current fingerprint
  [ "$(adaptive_mode)" = AGENT_BETA ] && [ "$(cat "$DEFAULT_SCOPE_FILE" 2>/dev/null || true)" = 1 ] || {
    echo 'Ramp-first requires AGENT_BETA with explicit LAN-wide scope consent.' >&2; return 1;
  }
  adaptive_ramp_pool_supported || { echo 'Ramp-first is unavailable on this platform or its Googlevideo pool is not ready.' >&2; return 1; }
  [ ! -e "$RAMP_POOL_ARM_FILE" ] || { echo 'Proof-triggered Ramp-first is armed; use ramp-pool-off before choosing manual enable.' >&2; return 1; }
  if [ -e "$RAMP_POOL_FILE" ]; then
    adaptive_ramp_pool_enabled || { echo 'Ramp pool state is invalid; refusing to overwrite it.' >&2; return 1; }
    echo 'Ramp-first is already enabled with explicit manual_unverified consent.'
    return 0
  fi
  current="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')"
  case "$current" in 0|1) ;; *) echo 'Ramp enable flag is missing or invalid.' >&2; return 1 ;; esac
  if [ "$current" = 1 ]; then
    adaptive_ramp_pool_write_state preexisting || return 1
    echo 'Ramp-first consent recorded; the existing manual Ramp setting was not changed.'
    return 0
  fi
  adaptive_ramp_pool_set_config 1 || { echo 'Could not atomically enable the Googlevideo Ramp pool.' >&2; return 1; }
  fingerprint="$(adaptive_ramp_pool_fingerprint)" || fingerprint=
  if ! adaptive_ramp_pool_write_state managed manual_unverified "$fingerprint"; then
    adaptive_ramp_pool_set_config 0 || echo 'WARNING: Ramp rollback failed; inspect the config before continuing.' >&2
    echo 'Could not save Ramp-first ownership state.' >&2
    return 1
  fi
  echo 'Ramp-first enabled for the configured Googlevideo IP pool (basis: manual_unverified). Restart zapret2 to apply it.'
}
adaptive_ramp_pool_restore() {
  local version ownership basis fingerprint extra proof current current_fingerprint
  if [ -e "$RAMP_POOL_ARM_FILE" ]; then
    adaptive_ramp_pool_armed || { echo 'Ramp-first proof arm is invalid or stale; it was not removed.' >&2; return 1; }
    rm -f "$RAMP_POOL_ARM_FILE" || return 1
  fi
  [ -e "$RAMP_POOL_FILE" ] || return 0
  [ -f "$RAMP_POOL_FILE" ] && [ ! -L "$RAMP_POOL_FILE" ] && [ "$(wc -c < "$RAMP_POOL_FILE")" -le 256 ] || {
    echo 'Ramp-first state file is unsafe; it was not removed.' >&2; return 1;
  }
  IFS=$'\t' read -r version ownership basis fingerprint extra < "$RAMP_POOL_FILE" || return 1
  [[ "$basis" = manual_unverified || "$basis" = proof_verified ]] || { echo 'Ramp-first state is invalid; config was left unchanged.' >&2; return 1; }
  if [ "$ownership" = managed ]; then
    if [ "$basis" = proof_verified ]; then
      IFS=$'\t' read -r version ownership basis fingerprint extra proof < "$RAMP_POOL_FILE" || return 1
      [[ "$version" = 1 && "$ownership" = managed && "$basis" = proof_verified && "$fingerprint" =~ ^[a-f0-9]{64}$ && "$extra" =~ ^[a-f0-9]{64}$ && -z "$proof" ]] || { echo 'Ramp-first state is invalid.' >&2; return 1; }
    else [[ "$version" = 1 && "$fingerprint" =~ ^[a-f0-9]{64}$ && -z "$extra" ]] || { echo 'Ramp-first state is invalid.' >&2; return 1; }
    fi
    current="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')"
    if [ "$current" = 1 ]; then
      current_fingerprint="$(adaptive_ramp_pool_fingerprint 2>/dev/null || true)"
      if [ "$current_fingerprint" = "$fingerprint" ]; then
        adaptive_ramp_pool_set_config 0 || { echo 'Could not restore the pre-Beta Ramp setting.' >&2; return 1; }
        echo 'Ramp-first changes were rolled back to the pre-Beta disabled state.'
      else
        echo 'Ramp settings changed after Beta enabled them; preserving the current manual config.'
      fi
    fi
elif [[ "$version" = 1 && "$ownership" = preexisting && "$basis" = manual_unverified && -z "$fingerprint" && -z "$extra" ]]; then
    echo 'The Ramp setting predated Beta; preserving the manual config.'
  else
    echo 'Ramp-first state is invalid; config was left unchanged.' >&2; return 1
  fi
  rm -f "$RAMP_POOL_FILE" || { echo 'Could not clear Ramp-first ownership state.' >&2; return 1; }
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
  [ ! -L "$BASE" ] && [ ! -L "$EVENTS_FILE" ] && [ ! -L "$RAMP_TARGETS_FILE" ] || return 1
  config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  user="$(awk -F= '$1=="WS_USER" {gsub(/["[:space:]]/, "", $2); print $2; exit}' "$config" 2>/dev/null)"
  [ -n "$user" ] || user=nobody
  uid="$(id -u "$user" 2>/dev/null)"; gid="$(id -g "$user" 2>/dev/null)"
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
  mkdir -p "$TOKEN_DIR" "$BASE" && touch "$EVENTS_FILE" "$RAMP_TARGETS_FILE" || return 1
  chown 0:0 "$TOKEN_DIR" && chmod 711 "$TOKEN_DIR" || return 1
  chown "$uid:$gid" "$EVENTS_FILE" "$RAMP_TARGETS_FILE" && chmod 600 "$EVENTS_FILE" "$RAMP_TARGETS_FILE"
}
adaptive_pause_mode() {
  local tmp run run_id
  [ ! -L "$EVENTS_FILE" ] && [ ! -L "$RAMP_TARGETS_FILE" ] || return 1
  adaptive_ramp_pool_restore || return 1
  mkdir -p "$TOKEN_DIR"
  tmp="$(mktemp "$TOKEN_DIR/.mode.XXXXXX")" || return 1
  printf 'OFF\n' > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$MODE_FILE" || { rm -f "$tmp"; return 1; }
  [ ! -e "$EVENTS_FILE" ] || chmod 400 "$EVENTS_FILE"
  [ ! -e "$RAMP_TARGETS_FILE" ] || chmod 400 "$RAMP_TARGETS_FILE"
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
  printf 'Adaptive mode: %s\n' "$(adaptive_mode)"
  if [ "$(adaptive_mode)" = AGENT_BETA ]; then
    if [ "$(cat "$DEFAULT_SCOPE_FILE" 2>/dev/null || true)" = 1 ]; then echo 'Beta application: exact rules including default/LAN scope'
    else echo 'Beta application: exact marked-client scopes only; default/LAN scope disabled'; fi
  else echo 'Automatic strategy application: disabled'; fi
  if adaptive_ramp_pool_enabled; then
    IFS=$'\t' read -r _ramp_version _ramp_owner _ramp_basis _ramp_fingerprint < "$RAMP_POOL_FILE" || :
    printf 'Ramp-first Googlevideo pool: enabled (%s)\n' "$_ramp_basis"
  else
    echo 'Ramp-first Googlevideo pool: disabled'
  fi
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
  [ ! -r "$EVENTS_FILE" ] || event_count="$(awk -F '\t' 'NR<=128 && NF==8 && $1==1 && ($2=="seen" || $2=="needs_verify" || $2=="suspected_failure" || $2=="active_rule_degraded") {n++} END {print n+0}' "$EVENTS_FILE")"
  printf 'Observation events: %s\n' "$event_count"
  ramp_target_count=0
  [ ! -r "$RAMP_TARGETS_FILE" ] || ramp_target_count="$(awk -F '\t' 'NR<=128 && NF==10 && $1==1 && $6=="tls-observed" {n++} END {print n+0}' "$RAMP_TARGETS_FILE")"
  printf 'Observed Googlevideo Ramp targets: %s\n' "$ramp_target_count"
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
  case "$mode" in OBSERVE|TEST_ONLY|AGENT_BETA) doctor_check 'runtime mode' "$mode" 0 ;; *) doctor_check 'runtime mode' OFF 0 ;; esac
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
if [ "$action" = beta ] || [ "$action" = beta-lan ]; then
  adaptive_token_valid || { echo 'Pair the Windows agent first with: adaptive-pair.sh create' >&2; exit 1; }
  adaptive_wait_probe_cleanup || { echo 'Active probe cleanup did not finish; Beta mode was not changed.' >&2; exit 1; }
  adaptive_prepare_events || { echo 'Could not prepare private observation queue.' >&2; exit 1; }
  if [ "$action" = beta-lan ]; then
    adaptive_set_default_scope 1 || { echo 'Could not save the explicit LAN-wide scope consent.' >&2; exit 1; }
  else
    adaptive_ramp_pool_restore || { echo 'Could not restore Ramp before removing LAN-wide consent.' >&2; exit 1; }
    adaptive_set_default_scope 0 || { echo 'Could not clear LAN-wide scope consent.' >&2; exit 1; }
  fi
  adaptive_set_mode AGENT_BETA || { echo 'Could not enable AGENT_BETA.' >&2; exit 1; }
  if [ "$action" = beta-lan ]; then
    echo 'AGENT_BETA enabled. Verified exact rules may apply to the whole LAN (default scope); restart zapret2 to activate.'
  else
    echo 'AGENT_BETA enabled. Verified exact rules may apply only to explicitly marked client scopes; default/LAN scope stays test-only. Restart zapret2 to activate.'
  fi
  exit 0
fi
if [ "$action" = ramp-pool-on ]; then
  adaptive_token_valid || { echo 'Pair the Windows agent first with: adaptive-pair.sh create' >&2; exit 1; }
  adaptive_ramp_pool_enable || exit 1
  exit 0
fi
if [ "$action" = ramp-pool-arm ]; then
  adaptive_token_valid || { echo 'Pair the Windows agent first with: adaptive-pair.sh create' >&2; exit 1; }
  adaptive_ramp_pool_arm || exit 1
  exit 0
fi
if [ "$action" = ramp-pool-proof-on ]; then
  adaptive_token_valid || { echo 'Pair the Windows agent first with: adaptive-pair.sh create' >&2; exit 1; }
  [ "$#" = 5 ] || { echo 'Proof activation is reserved for the authenticated adaptive API.' >&2; exit 2; }
  adaptive_ramp_pool_enable_proven "$2" "$3" "$4" "$5" || exit 1
  exit 0
fi
if [ "$action" = ramp-pool-off ]; then
  adaptive_ramp_pool_restore || exit 1
  echo 'Ramp-first consent disabled. Restart zapret2 to apply any restored Ramp config.'
  exit 0
fi
if [ "$action" = pause ]; then
  adaptive_pause_mode || { echo 'Could not disable observation.' >&2; exit 1; }
  adaptive_set_default_scope 0 || { echo 'Could not clear LAN-wide scope consent.' >&2; exit 1; }
  adaptive_wait_probe_cleanup || { echo 'Active probe cleanup did not finish; adaptive mode is OFF but needs cleanup.' >&2; exit 1; }
  echo 'Observation paused. Restart zapret2 to reload the mode.'
  exit 0
fi
if [ "$action" = events ]; then
  if [ -r "$EVENTS_FILE" ]; then
    awk -F '\t' 'NR<=128 && NF==8 && $1==1 && ($2=="seen" || $2=="needs_verify" || $2=="suspected_failure" || $2=="active_rule_degraded") && $3 ~ /^[a-z0-9][a-z0-9.-]*[a-z0-9]$/ && $4 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && $5 ~ /^[1-4]$/ && $6=="tls" && ($7=="default" || $7 ~ /^mark:[0-9]+$/) && $8 ~ /^[0-9]+$/ {print $2 "\t" $3 "\t" $4 "\tprofile=" $5 "\t" $8}' "$EVENTS_FILE"
  fi
  exit 0
fi
if [ "$action" = clear-events ]; then
  [ ! -L "$EVENTS_FILE" ] && [ ! -L "$RAMP_TARGETS_FILE" ] || { echo 'Refusing a symlinked observation queue.' >&2; exit 1; }
  adaptive_pause_mode || { echo 'Could not pause observation.' >&2; exit 1; }
  adaptive_wait_probe_cleanup || { echo 'Active probe cleanup did not finish; adaptive mode is OFF but events were not cleared.' >&2; exit 1; }
  if type adaptive_queue_clear >/dev/null 2>&1; then adaptive_queue_clear || { echo 'Could not clear queued probe requests.' >&2; exit 1; }; fi
  for clear_file in "$EVENTS_FILE" "$RAMP_TARGETS_FILE"; do
    if [ -e "$clear_file" ]; then
      tmp="$(mktemp "$clear_file.tmp.XXXXXX")" || exit 1
      owner="$(stat -c '%u:%g' "$clear_file" 2>/dev/null)"
      [[ "$owner" =~ ^[0-9]+:[0-9]+$ ]] || { rm -f "$tmp"; exit 1; }
      chown "$owner" "$tmp" && chmod 400 "$tmp" && mv -f "$tmp" "$clear_file" || {
        rm -f "$tmp"; exit 1;
      }
    fi
  done
  echo 'Observation queue cleared and paused; restart zapret2 to reload the mode.'
  exit 0
fi
if [ "$action" = disable ]; then
  adaptive_pause_mode || { echo 'Could not safely disable adaptive mode or restore Ramp.' >&2; exit 1; }
  adaptive_set_default_scope 0 || { echo 'Could not clear LAN-wide scope consent.' >&2; exit 1; }
  adaptive_wait_probe_cleanup || { echo 'Probe cleanup did not finish; check the adaptive probe state before uninstalling.' >&2; exit 1; }
  if type adaptive_queue_clear >/dev/null 2>&1; then adaptive_queue_clear || { echo 'Could not clear queued probe requests.' >&2; exit 1; }; fi
  rm -f "$EVENTS_FILE"
  rm -f "$RAMP_TARGETS_FILE"
  rm -f "$TOKEN_FILE" "$TOKEN_EXPIRY_FILE" "$TOKEN_FILE.tmp."* "$TOKEN_EXPIRY_FILE.tmp."*
  if [ -f "$ROOT/z2r_lib/adaptive_rules.sh" ]; then
    . "$ROOT/z2r_lib/adaptive_rules.sh"
    adaptive_rules_invalidate || { echo 'Could not clear adaptive rules.' >&2; exit 1; }
  fi
  echo 'Adaptive agent disabled; active probes are cancelling through cleanup. Restart zapret2 to apply any restored Ramp config.'
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
