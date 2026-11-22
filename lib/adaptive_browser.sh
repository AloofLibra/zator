#!/usr/bin/env bash
# Browser-only pairing and bounded runtime state. Never shares the agent token.

adaptive_browser_clients_file() {
  printf '%s\n' "${Z2R_ADAPTIVE_BROWSER_CLIENTS_FILE:-${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/browser-clients.tsv}"
}

adaptive_browser_state_dir() {
  printf '%s\n' "${Z2R_ADAPTIVE_BROWSER_DIR:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/browser}"
}

adaptive_browser_public_origin_valid() {
  [[ "${1:-}" =~ ^chrome-extension://[a-p]{32}$ ]]
}

adaptive_browser_host_valid() {
  local host="${1,,}" label
  host="${host%.}"
  [[ ${#host} -le 253 && "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || return 1
  case "$host" in *.localhost|*.local|*.lan|*.internal|*.home.arpa|localhost|local|lan|internal) return 1 ;; esac
  ADAPTIVE_BROWSER_HOST="$host"
}

adaptive_browser_context_valid() {
  local client_id="$1" client_ip="$2" scope="$3" now="${4:-$(date +%s)}"
  local map_file="${CLIENT_SCOPE_MAP_FILE:-${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/client_scope.tsv}"
  [[ "$client_id" =~ ^[a-f0-9]{32}$ && "$client_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$now" =~ ^[0-9]{1,10}$ ]] || return 1
  awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; a=$1+0; b=$2+0; if(a==10 || (a==192 && b==168) || (a==172 && b>=16 && b<=31)) exit 0; exit 1} {exit 1}' <<< "$client_ip" || return 1
  if [[ "$scope" = default ]]; then
    [[ "$(cat "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/mode" 2>/dev/null)" = AGENT_BETA &&
       -f "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/apply-default-scope" &&
       ! -L "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/apply-default-scope" &&
       "$(cat "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/apply-default-scope" 2>/dev/null)" = 1 ]]
    return
  fi
  [[ "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] && (( ${scope#mark:} <= 65535 )) || return 1
  [[ "$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" CLIENT_SCOPE_ENABLE 2>/dev/null | tr -d '"\047')" = 1 &&
     -r "$map_file" && ! -L "$map_file" ]] || return 1
  awk -F '\t' -v ip="$client_ip" -v sc="$scope" '
    $1 ~ /^mark:[1-9][0-9]*$/ && $2 ~ /^[0-9.]+$/ { if ($2==ip) {ip_count++; ip_scope=$1}; if ($1==sc) {scope_count++; scope_ip=$2} }
    END {exit !(ip_count==1 && ip_scope==sc && scope_count==1 && scope_ip==ip)}
  ' "$map_file"
}

# Validates the browser-specific credential and returns its router-bound identity
# in ADAPTIVE_BROWSER_CLIENT_ID / ADAPTIVE_BROWSER_CLIENT_SCOPE.
adaptive_browser_client_auth() {
  [[ $# = 3 ]] || return 2
  local token="$1" remote_ip="$2" origin="$3" file now hash row
  local ver id token_hash client_ip scope expires extra count=0 found=0
  [[ "$token" =~ ^[a-f0-9]{64}$ && "$remote_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  adaptive_browser_public_origin_valid "$origin" || return 1
  file="$(adaptive_browser_clients_file)"
  [[ -f "$file" && ! -L "$file" && -r "$file" && $(wc -c < "$file") -le 8192 ]] || return 1
  now="$(date +%s)" || return 1
  hash="$(printf '%s' "$token" | sha256sum | awk '{print $1}')" || return 1
  while IFS= read -r row || [[ -n "$row" ]]; do
    count=$((count + 1)); (( count <= 8 )) || return 1
    IFS=$'\t' read -r ver id token_hash client_ip scope expires extra <<< "$row"
    [[ "$ver" = 1 && "$id" =~ ^[a-f0-9]{32}$ && "$token_hash" =~ ^[a-f0-9]{64}$ &&
       "$client_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
       "$expires" =~ ^[0-9]{1,10}$ && -z "${extra:-}" ]] || return 1
    if [[ "$hash" = "$token_hash" ]]; then
      (( expires > now )) && [[ "$client_ip" = "$remote_ip" ]] && adaptive_browser_context_valid "$id" "$client_ip" "$scope" "$now" || return 1
      ADAPTIVE_BROWSER_CLIENT_ID="$id"
      ADAPTIVE_BROWSER_CLIENT_SCOPE="$scope"
      ADAPTIVE_BROWSER_CLIENT_EXPIRES="$expires"
      found=1
    fi
  done < "$file"
  (( found == 1 ))
}

adaptive_browser_attempt_file() {
  printf '%s/%s.tsv\n' "$(adaptive_browser_state_dir)/attempts" "$1"
}

adaptive_browser_attempt_read() {
  [[ $# = 1 && "$1" =~ ^[a-f0-9]{32}$ ]] || return 2
  local file
  file="$(adaptive_browser_attempt_file "$1")"
  [[ -f "$file" && ! -L "$file" && -r "$file" && $(wc -c < "$file") -le 2048 ]] || return 1
  cat "$file"
}

adaptive_browser_attempt_write() {
  [[ $# = 15 ]] || return 2
  local attempt_id="$1" client_id="$2" client_ip="$3" scope="$4" host="$5" ip="$6" profile="$7" proto="$8"
  local trigger="$9" state="${10}" strategy="${11}" fingerprint="${12}" created="${13}" expires="${14}" generation="${15}"
  local dir file tmp
  [[ "$attempt_id" =~ ^[a-f0-9]{32}$ && "$client_id" =~ ^[a-f0-9]{32}$ &&
     "$client_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
     ( "$host" = - || "$(adaptive_browser_host_valid "$host" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "${host,,}" ) &&
     ( "$ip" = - || "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ) &&
     "$profile" =~ ^[0-5]$ && ( "$proto" = tls || "$proto" = googlevideo-tcp || "$proto" = quic || "$proto" = unknown ) &&
     "$trigger" =~ ^(main_frame_network_failure|critical_resource_repeated_failure|user_fix)$ &&
     "$state" =~ ^(QUEUED|TEST_ONLY|TARGET_NOT_MANAGED|WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS|CONFIRMED_SUCCESS|CONFIRMED_FAILURE|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED)$ &&
     "$strategy" =~ ^(-|0|[1-9][0-9]{0,2})$ &&
     ( "$fingerprint" = - || "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ ) &&
     "$created" =~ ^[0-9]{1,10}$ && "$expires" =~ ^[0-9]{1,10}$ && "$generation" =~ ^[1-9][0-9]{0,8}$ ]] || return 2
  dir="$(dirname "$(adaptive_browser_attempt_file "$attempt_id")")"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$dir" ]] || return 1
  mkdir -p "$dir" || return 1
  file="$(adaptive_browser_attempt_file "$attempt_id")"
  [[ ! -L "$file" ]] || return 1
  tmp="$(mktemp "$dir/.attempt.XXXXXX")" || return 1
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$attempt_id" "$client_id" "$client_ip" "$scope" "$host" "$ip" "$profile" "$proto" "$trigger" "$state" \
    "$strategy" "$fingerprint" "$created" "$expires" "$generation" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$file" || {
      rm -f "$tmp"; return 1;
    }
}
