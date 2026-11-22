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

# Resolve a browser hostname only from a fresh exact Lua observation. No DNS or
# synthetic probing is performed here; ambiguous/malformed tuples are refused.
adaptive_browser_resolve_observation() {
  [[ $# = 4 ]] || return 2
  local host="${1,,}" scope="$2" file="$3" now="$4" row ver status old_host ip profile proto old_scope seen extra tuple
  adaptive_browser_host_valid "$host" || return 1
  host="$ADAPTIVE_BROWSER_HOST"
  [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] && [[ "$now" =~ ^[0-9]{1,10}$ ]] || return 2
  [[ -r "$file" && ! -L "$file" && $(wc -c < "$file") -le 32768 ]] || return 1
  local -a rows=()
  while IFS= read -r row || [[ -n "$row" ]]; do
    IFS=$'\t' read -r ver status old_host ip profile proto old_scope seen extra <<< "$row"
    [[ "$ver" = 1 && "$status" = seen && "$old_host" = "$host" && "$old_scope" = "$scope" &&
       "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 && "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ) ) &&
       "$seen" =~ ^[0-9]{1,10}$ && -z "${extra:-}" ]] || continue
    (( seen >= now - 300 && seen <= now + 10 )) || continue
    awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; a=$1+0; b=$2+0; c=$3+0; if(a==0 || a==10 || a==127 || a>=224 || (a==100 && b>=64 && b<=127) || (a==169 && b==254) || (a==172 && b>=16 && b<=31) || (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) || (a==198 && (b==18 || b==19 || (b==51 && c==100))) || (a==203 && b==0 && c==113)) exit 1; exit 0} {exit 1}' <<< "$ip" || continue
    printf -v tuple '%s\t%s\t%s\t%s\t%s\t%s' "$host" "$ip" "$profile" "$proto" "$scope" "$seen"
    rows+=("$tuple")
    (( ${#rows[@]} <= 1 )) || return 1
  done < "$file"
  (( ${#rows[@]} == 1 )) || return 1
  printf '%s\n' "${rows[0]}"
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

# Bounded tmpfs idempotency and per-host retry budget. Output is one of:
# accepted, duplicate, budget; event rows never contain a URL or LAN history.
adaptive_browser_event_claim() {
  [[ $# = 5 && "$1" =~ ^[a-f0-9]{32}$ && "$2" =~ ^[a-f0-9]{32}$ &&
     "$(adaptive_browser_host_valid "$3" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "${3,,}" &&
     "$4" =~ ^(main_frame_network_failure|critical_resource_repeated_failure|user_fix)$ && "$5" =~ ^[0-9]{10}$ ]] || return 2
  local client_id="$1" event_id="$2" host="$3" trigger="$4" now="$5"
  local dir file lock tmp row ver old_id old_host old_trigger old_seen extra count=0 same_host=0 tries=0 outcome=accepted
  dir="$(adaptive_browser_state_dir)/events"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$dir" ]] || return 1
  mkdir -p "$dir" || return 1
  file="$dir/$client_id.tsv"; lock="$file.lock"
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 20 )) || return 1
    sleep 0.05
  done
  tmp="$(mktemp "$dir/.events.XXXXXX")" || { rmdir "$lock"; return 1; }
  if [[ -r "$file" && ! -L "$file" ]]; then
    [[ $(wc -c < "$file") -le 4096 ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    while IFS= read -r row || [[ -n "$row" ]]; do
      IFS=$'\t' read -r ver old_id old_host old_trigger old_seen extra <<< "$row"
      [[ "$ver" = 1 && "$old_id" =~ ^[a-f0-9]{32}$ &&
         "$(adaptive_browser_host_valid "$old_host" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "$old_host" &&
         "$old_trigger" =~ ^(main_frame_network_failure|critical_resource_repeated_failure|user_fix)$ &&
         "$old_seen" =~ ^[0-9]{10}$ && -z "${extra:-}" ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
      (( old_seen >= now - 300 && old_seen <= now + 5 )) || continue
      count=$((count + 1)); (( count <= 127 )) || { rm -f "$tmp"; rmdir "$lock"; return 1; }
      if [[ "$old_id" = "$event_id" ]]; then outcome=duplicate; fi
      if [[ "$old_host" = "$host" ]]; then
        same_host=$((same_host + 1))
        (( same_host < 5 )) || outcome=budget
      fi
      printf '%s\n' "$row" >> "$tmp"
    done < "$file"
  fi
  if [[ "$outcome" = accepted ]]; then
    printf '1\t%s\t%s\t%s\t%s\n' "$event_id" "$host" "$trigger" "$now" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  fi
  chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock" || return 1
  printf '%s\n' "$outcome"
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
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$attempt_id" "$client_id" "$client_ip" "$scope" "$host" "$ip" "$profile" "$proto" "$trigger" "$state" \
    "$strategy" "$fingerprint" "$created" "$expires" "$generation" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$file" || {
      rm -f "$tmp"; return 1;
    }
}

# Compare-and-swap state transition: an older tab cannot overwrite a newer
# terminal outcome after reading a stale attempt snapshot.
adaptive_browser_attempt_transition() {
  [[ $# = 3 && "$1" =~ ^[a-f0-9]{32}$ && "$2" =~ ^(QUEUED|WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS|CONFIRMED_SUCCESS|CONFIRMED_FAILURE|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED|TARGET_NOT_MANAGED)$ &&
     "$3" =~ ^(WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS|CONFIRMED_SUCCESS|CONFIRMED_FAILURE|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED|TARGET_NOT_MANAGED)$ ]] || return 2
  local id="$1" expected="$2" next="$3" file dir lock row ver attempt client ip scope host dst profile proto trigger state strategy fp created expires generation extra tries=0
  file="$(adaptive_browser_attempt_file "$id")"; dir="$(dirname "$file")"; lock="$file.lock"
  [[ -r "$file" && ! -L "$file" && ! -L "$dir" && $(wc -c < "$file") -le 2048 ]] || return 1
  case "$expected:$next" in
    QUEUED:WAIT_NEW_FLOW|QUEUED:TARGET_NOT_MANAGED|QUEUED:CANCELLED|QUEUED:EXPIRED|WAIT_NEW_FLOW:FLOW_CONFIRMED|WAIT_NEW_FLOW:UNKNOWN|WAIT_NEW_FLOW:NOT_TESTED|WAIT_NEW_FLOW:CANCELLED|WAIT_NEW_FLOW:EXPIRED|FLOW_CONFIRMED:WAIT_BROWSER_RESULT|FLOW_CONFIRMED:CONFIRMED_FAILURE|FLOW_CONFIRMED:UNKNOWN|FLOW_CONFIRMED:CANCELLED|FLOW_CONFIRMED:EXPIRED|WAIT_BROWSER_RESULT:PROVISIONAL_SUCCESS|WAIT_BROWSER_RESULT:CONFIRMED_FAILURE|WAIT_BROWSER_RESULT:UNKNOWN|WAIT_BROWSER_RESULT:CANCELLED|WAIT_BROWSER_RESULT:EXPIRED|PROVISIONAL_SUCCESS:CONFIRMED_SUCCESS|PROVISIONAL_SUCCESS:UNKNOWN|PROVISIONAL_SUCCESS:EXPIRED) ;;
    *) return 2 ;;
  esac
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; sleep 0.05; done
  row="$(cat "$file")"
  IFS=$'\t' read -r ver attempt client ip scope host dst profile proto trigger state strategy fp created expires generation extra <<< "$row"
  if [[ "$ver" != 1 || "$attempt" != "$id" || "$state" != "$expected" || -n "${extra:-}" ]]; then rmdir "$lock"; return 3; fi
  adaptive_browser_attempt_write "$attempt" "$client" "$ip" "$scope" "$host" "$dst" "$profile" "$proto" "$trigger" "$next" "$strategy" "$fp" "$created" "$expires" "$generation" || { rmdir "$lock"; return 1; }
  rmdir "$lock" || return 1
}
