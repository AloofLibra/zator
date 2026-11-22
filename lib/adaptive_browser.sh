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

adaptive_browser_quic_host_valid() {
  [[ $# = 1 && "${1,,}" =~ (^|\.)(googlevideo\.com|youtube\.com|youtubei\.googleapis\.com)$ ]]
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
       ( ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 && "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ) ) ) || ( "$profile" = 5 && "$proto" = quic ) ) &&
       "$seen" =~ ^[0-9]{1,10}$ && -z "${extra:-}" ]] || continue
    [[ "$proto" != quic ]] || adaptive_browser_quic_host_valid "$old_host" || continue
    (( seen >= now - 300 && seen <= now + 10 )) || continue
    awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; a=$1+0; b=$2+0; c=$3+0; if(a==0 || a==10 || a==127 || a>=224 || (a==100 && b>=64 && b<=127) || (a==169 && b==254) || (a==172 && b>=16 && b<=31) || (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) || (a==198 && (b==18 || b==19 || (b==51 && c==100))) || (a==203 && b==0 && c==113)) exit 1; exit 0} {exit 1}' <<< "$ip" || continue
    printf -v tuple '%s\t%s\t%s\t%s\t%s\t%s' "$host" "$ip" "$profile" "$proto" "$scope" "$seen"
    rows+=("$tuple")
    (( ${#rows[@]} <= 1 )) || return 1
  done < "$file"
  (( ${#rows[@]} == 1 )) || return 1
  printf '%s\n' "${rows[0]}"
}

# Choose one numbered strategy without running curl, DNS, or an isolated probe.
# Existing verified local rankings only sort candidates; a browser failure does
# not itself create a verified rule or lower another strategy's rating.
adaptive_browser_profile_lock_check() {
  [[ $# = 3 && "$1" =~ ^[1-5]$ && ( "$2" = default || "$2" =~ ^mark:[1-9][0-9]{0,4}$ ) ]] || return 2
  local profile="$1" scope="$2" orch_dir="$3" lock_file scoped_lock proto=udp
  [[ "$profile" != 5 ]] && proto=tls
  scoped_lock=""
  if [[ "$scope" != default ]]; then scoped_lock="$orch_dir/scopes/${scope/:/_}.tsv"; fi
  # Match Lua's scoped-first, default-fallback lock resolution.
  for lock_file in "$scoped_lock" "$orch_dir/locked.tsv"; do
    [[ -n "$lock_file" && -e "$lock_file" ]] || continue
    [[ -f "$lock_file" && ! -L "$lock_file" && -r "$lock_file" ]] || return 2
    if awk -F '\t' -v pr="$profile" -v proto="$proto" '$1==pr && (($2==proto && NF>=3) || NF==2) {found=1} END{exit !found}' "$lock_file"; then
      return 0
    fi
  done
  return 1
}

adaptive_browser_candidate_select() {
  [[ $# = 9 ]] || return 2
  local host="$1" ip="$2" profile="$3" proto="$4" scope="$5" args_file="$6" nfqws="$7" orch_dir="$8" client_id="$9"
  local config="${ZAPRET2_ROOT:-/opt/zapret2}/config" max current state stamp exact ranked family identity strategy fingerprint now
  local -A seen=()
  local -a candidates=()
  [[ ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 ) ) || ( "$profile" = 5 && "$proto" = quic ) ) &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && -r "$args_file" && -x "$nfqws" ]] || return 2
  adaptive_browser_profile_lock_check "$profile" "$scope" "$orch_dir"
  case $? in 1) ;; *) return 4 ;; esac
  current=1
  stamp="$(adaptive_rules_runtime_stamp "$config" "$nfqws" "$orch_dir")" || return 1
  exact="$(adaptive_rule_lookup_local "$host" "$ip" "$profile" "$proto" "$scope" "$stamp" 2>/dev/null || true)"
  if [[ -n "$exact" ]]; then IFS=$'\t' read -r current _ <<< "$exact"; fi
  max="$(config_profile_max_strategy "$profile" "$config")"
  [[ "$max" =~ ^[1-9][0-9]{0,2}$ ]] || return 3
  if [[ "$proto" = googlevideo-tcp ]]; then identity="$(adaptive_rules_googlevideo_group_id "$host")"; else identity=""; fi
  ranked="$(adaptive_rules_ranked_candidates "$profile" "$proto" "$scope" "$stamp" "$max" "$identity" 2>/dev/null || true)"
  while IFS= read -r strategy; do [[ "$strategy" =~ ^[1-9][0-9]{0,2}$ ]] && candidates+=("$strategy"); done <<< "$(printf '%s\n' "$ranked" | head -n 5)"
  family="$(adaptive_exploration_strategy_order "$args_file" "$max" 2>/dev/null || true)"
  while IFS= read -r strategy; do [[ "$strategy" =~ ^[1-9][0-9]{0,2}$ ]] && candidates+=("$strategy"); done <<< "$family"
  now="$(date +%s)" || return 1
  for strategy in "${candidates[@]}"; do
    [[ "$strategy" != "$current" && ! ${seen[$strategy]+yes} ]] || continue
    seen[$strategy]=1
    if adaptive_browser_candidate_confirmed_failed "$client_id" "$host" "$ip" "$profile" "$proto" "$scope" "$strategy" "$now"; then continue; fi
    case "$proto" in googlevideo-tcp) recipe=googlevideo-tcp-media-v1 ;; quic) recipe=googlevideo-quic-h3-media-v1 ;; *) recipe=tls-http1-v1 ;; esac
    fingerprint="$(adaptive_strategy_fingerprint "$profile" "$strategy" "$args_file" "$nfqws" standard "$recipe" 2>/dev/null)" || continue
    [[ "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ ]] || continue
    printf '%s\t%s\n' "$strategy" "$fingerprint"
    return 0
  done
  return 3
}

adaptive_browser_candidate_confirmed_failed() {
  [[ $# = 8 && "$1" =~ ^[a-f0-9]{32}$ ]] || return 1
  local wanted_client="$1" host="$2" ip="$3" profile="$4" proto="$5" scope="$6" strategy="$7" now="$8"
  local dir="$(adaptive_browser_state_dir)/attempts" file row ver id client client_ip old_scope old_host old_ip old_profile old_proto trigger state old_strategy fp created expires generation extra count=0
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  for file in "$dir"/*.tsv; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    count=$((count + 1)); (( count <= 64 )) || return 1
    [[ $(wc -c < "$file") -le 2048 ]] || continue
    IFS= read -r row < "$file" || continue
    IFS=$'\t' read -r ver id client client_ip old_scope old_host old_ip old_profile old_proto trigger state old_strategy fp created expires generation extra <<< "$row"
    [[ "$ver" = 1 && "$client" = "$wanted_client" && "$old_host" = "$host" && "$old_ip" = "$ip" &&
       "$old_profile" = "$profile" && "$old_proto" = "$proto" && "$old_scope" = "$scope" && "$old_strategy" = "$strategy" &&
       "$state" = CONFIRMED_FAILURE && "$created" =~ ^[0-9]{1,10}$ ]] || continue
    (( created >= now - 300 && created <= now + 5 )) && return 0
  done
  return 1
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

adaptive_browser_trials_file() { printf '%s/trials.tsv\n' "$(adaptive_browser_state_dir)"; }
adaptive_browser_flow_dir() { printf '%s/flows\n' "$(adaptive_browser_state_dir)"; }

adaptive_browser_flow_read() {
  [[ $# = 2 && "$1" =~ ^[a-f0-9]{32}$ && "$2" =~ ^[1-9][0-9]{0,8}$ ]] || return 2
  local dir file row lines
  dir="$(adaptive_browser_flow_dir)"; file="$dir/$1.$2.tsv"
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  [[ -e "$file" ]] || return 1
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 2
  [[ $(wc -c < "$file") -le 512 ]] || return 2
  lines="$(awk 'END {print NR+0}' "$file")"
  [[ "$lines" = 1 ]] || return 2
  IFS= read -r row < "$file" || return 2
  local ver id generation client_id scope host ip profile proto strategy fingerprint syn_at selected_at extra
  IFS=$'\t' read -r ver id generation client_id scope host ip profile proto strategy fingerprint syn_at selected_at extra <<< "$row"
  [[ "$ver" = 1 && "$id" = "$1" && "$generation" = "$2" && "$client_id" =~ ^[a-f0-9]{32}$ &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$host" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( "$profile" =~ ^[1-4]$ || "$profile" = 5 ) &&
     ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 && "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ) || ( "$proto" = quic && "$profile" = 5 ) ) &&
     "$strategy" =~ ^[1-9][0-9]{0,2}$ && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ &&
     "$syn_at" =~ ^[0-9]{1,10}$ && "$selected_at" =~ ^[0-9]{1,10}$ && -z "${extra:-}" ]] || return 2
  [[ "$proto" != quic ]] || adaptive_browser_quic_host_valid "$host" || return 2
  printf '%s\n' "$row"
}

adaptive_browser_result_claim() {
  [[ $# = 5 && "$1" =~ ^[a-f0-9]{32}$ && "$2" =~ ^[a-f0-9]{32}$ && "$3" =~ ^[a-f0-9]{32}$ &&
     "$4" =~ ^(network_success|network_failure)$ && "$5" =~ ^[0-9]{10}$ ]] || return 2
  local client_id="$1" attempt_id="$2" event_id="$3" result="$4" now="$5"
  local dir="$(adaptive_browser_state_dir)/results" file lock tmp row ver old_client old_id old_result old_seen extra count=0 tries=0
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$dir" ]] || return 1
  mkdir -p "$dir" || return 1
  file="$dir/$attempt_id.tsv"; lock="$file.lock"
  [[ ! -L "$file" && ! -L "$lock" ]] || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; sleep 0.05; done
  tmp="$(mktemp "$dir/.result.XXXXXX")" || { rmdir "$lock"; return 1; }
  if [[ -r "$file" ]]; then
    [[ $(wc -c < "$file") -le 2048 ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    while IFS= read -r row || [[ -n "$row" ]]; do
      IFS=$'\t' read -r ver old_client old_id old_result old_seen extra <<< "$row"
      [[ "$ver" = 1 && "$old_client" = "$client_id" && "$old_id" =~ ^[a-f0-9]{32}$ && "$old_result" =~ ^(network_success|network_failure)$ &&
         "$old_seen" =~ ^[0-9]{10}$ && -z "${extra:-}" ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
      (( old_seen >= now - 300 && old_seen <= now + 5 )) || continue
      count=$((count + 1)); (( count <= 7 )) || { rm -f "$tmp"; rmdir "$lock"; return 1; }
      if [[ "$old_id" = "$event_id" ]]; then
        rm -f "$tmp"; rmdir "$lock"; return 3
      fi
      printf '%s\n' "$row" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    done < "$file"
  fi
  printf '1\t%s\t%s\t%s\t%s\n' "$client_id" "$event_id" "$result" "$now" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock"
}

adaptive_browser_trial_add() {
  [[ $# = 13 ]] || return 2
  local id="$1" generation="$2" client_id="$3" client_ip="$4" scope="$5" host="$6" ip="$7"
  local profile="$8" proto="$9" strategy="${10}" fingerprint="${11}" created="${12}" expires="${13}"
  local file lock dir tmp row ver old_id old_gen old_client old_client_ip old_scope old_host old_ip old_profile old_proto old_strategy old_fp old_created old_expires extra now count=0 tries=0
  [[ "$id" =~ ^[a-f0-9]{32}$ && "$generation" =~ ^[1-9][0-9]{0,8}$ && "$client_id" =~ ^[a-f0-9]{32}$ &&
     "$client_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
     "$(adaptive_browser_host_valid "$host" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "${host,,}" &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 ) ) ) || ( "$profile" = 5 && "$proto" = quic ) ) &&
     "$strategy" =~ ^[1-9][0-9]{0,2}$ && ( "$fingerprint" = - || "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ ) &&
     "$created" =~ ^[0-9]{1,10}$ && "$expires" =~ ^[0-9]{1,10}$ ]] || return 2
  [[ "$proto" != quic ]] || adaptive_browser_quic_host_valid "$host" || return 2
  now="$(date +%s)"; (( expires > now && expires <= now + 90 && created <= now + 5 )) || return 2
  file="$(adaptive_browser_trials_file)"; dir="$(dirname "$file")"; lock="$file.lock"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$file" && ! -L "$lock" ]] || return 1
  mkdir -p "$dir" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; sleep 0.05; done
  tmp="$(mktemp "$dir/.trials.XXXXXX")" || { rmdir "$lock"; return 1; }
  if [[ -r "$file" ]]; then
    [[ $(wc -c < "$file") -le 16384 ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    while IFS= read -r row || [[ -n "$row" ]]; do
      IFS=$'\t' read -r ver old_id old_gen old_client old_client_ip old_scope old_host old_ip old_profile old_proto old_strategy old_fp old_created old_expires extra <<< "$row"
      [[ "$ver" = 1 && "$old_id" =~ ^[a-f0-9]{32}$ && "$old_gen" =~ ^[1-9][0-9]{0,8}$ &&
         "$old_client" =~ ^[a-f0-9]{32}$ && "$old_scope" =~ ^(default|mark:[1-9][0-9]{0,4})$ &&
         "$old_host" =~ ^[a-z0-9.-]+$ && "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
         ( ( "$old_profile" =~ ^[1-4]$ && ( "$old_proto" = tls || ( "$old_proto" = googlevideo-tcp && "$old_profile" = 2 ) ) ) || ( "$old_profile" = 5 && "$old_proto" = quic ) ) && "$old_strategy" =~ ^[1-9][0-9]{0,2}$ &&
         ( "$old_fp" = - || "$old_fp" =~ ^sha256:[a-f0-9]{64}$ ) && "$old_created" =~ ^[0-9]{1,10}$ && "$old_expires" =~ ^[0-9]{1,10}$ && -z "${extra:-}" ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
      (( old_expires > now )) || continue
      count=$((count + 1)); (( count <= 63 )) || { rm -f "$tmp"; rmdir "$lock"; return 1; }
      if [[ "$old_client" = "$client_id" && "$old_scope" = "$scope" && "$old_host" = "$host" ]]; then
        rm -f "$tmp"; rmdir "$lock"; return 3
      fi
      printf '%s\n' "$row" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    done < "$file"
  fi
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$generation" "$client_id" "$client_ip" "$scope" "$host" "$ip" "$profile" "$proto" "$strategy" "$fingerprint" "$created" "$expires" >> "$tmp" || {
      rm -f "$tmp"; rmdir "$lock"; return 1;
    }
  chmod 644 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock"
}

adaptive_browser_trial_remove() {
  [[ $# = 2 && "$1" =~ ^[a-f0-9]{32}$ && "$2" =~ ^[1-9][0-9]{0,8}$ ]] || return 2
  local wanted="$1" generation="$2" file lock dir tmp row ver id gen rest removed=0 tries=0
  file="$(adaptive_browser_trials_file)"; dir="$(dirname "$file")"; lock="$file.lock"
  local flow_file="$(adaptive_browser_flow_dir)/$wanted.$generation.tsv"
  [[ ! -L "$flow_file" ]] || return 1
  [[ ! -f "$flow_file" ]] || rm -f "$flow_file" || return 1
  [[ -f "$file" && ! -L "$file" && ! -L "$lock" ]] || return 0
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; sleep 0.05; done
  tmp="$(mktemp "$dir/.trials.XXXXXX")" || { rmdir "$lock"; return 1; }
  while IFS= read -r row || [[ -n "$row" ]]; do
    IFS=$'\t' read -r ver id gen rest <<< "$row"
    if [[ "$ver" = 1 && "$id" = "$wanted" && "$gen" = "$generation" ]]; then removed=1; continue; fi
    printf '%s\n' "$row" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  done < "$file"
  if (( removed )); then chmod 644 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  else rm -f "$tmp"; fi
  rmdir "$lock" || return 1
  return 0
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
  if [[ "$proto" = quic ]]; then [[ "$profile" = 5 ]] && adaptive_browser_quic_host_valid "$host" || return 2; fi
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
    QUEUED:WAIT_NEW_FLOW|QUEUED:TARGET_NOT_MANAGED|QUEUED:CANCELLED|QUEUED:EXPIRED|WAIT_NEW_FLOW:FLOW_CONFIRMED|WAIT_NEW_FLOW:UNKNOWN|WAIT_NEW_FLOW:NOT_TESTED|WAIT_NEW_FLOW:CANCELLED|WAIT_NEW_FLOW:EXPIRED|FLOW_CONFIRMED:WAIT_BROWSER_RESULT|FLOW_CONFIRMED:CONFIRMED_FAILURE|FLOW_CONFIRMED:UNKNOWN|FLOW_CONFIRMED:CANCELLED|FLOW_CONFIRMED:EXPIRED|WAIT_BROWSER_RESULT:PROVISIONAL_SUCCESS|WAIT_BROWSER_RESULT:CONFIRMED_FAILURE|WAIT_BROWSER_RESULT:UNKNOWN|WAIT_BROWSER_RESULT:CANCELLED|WAIT_BROWSER_RESULT:EXPIRED|PROVISIONAL_SUCCESS:CONFIRMED_SUCCESS|PROVISIONAL_SUCCESS:CONFIRMED_FAILURE|PROVISIONAL_SUCCESS:UNKNOWN|PROVISIONAL_SUCCESS:EXPIRED) ;;
    *) return 2 ;;
  esac
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; sleep 0.05; done
  row="$(cat "$file")"
  IFS=$'\t' read -r ver attempt client ip scope host dst profile proto trigger state strategy fp created expires generation extra <<< "$row"
  if [[ "$ver" != 1 || "$attempt" != "$id" || "$state" != "$expected" || -n "${extra:-}" ]]; then rmdir "$lock"; return 3; fi
  adaptive_browser_attempt_write "$attempt" "$client" "$ip" "$scope" "$host" "$dst" "$profile" "$proto" "$trigger" "$next" "$strategy" "$fp" "$created" "$expires" "$generation" || { rmdir "$lock"; return 1; }
  rmdir "$lock" || return 1
}
