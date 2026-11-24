#!/usr/bin/env bash
# Browser-only pairing and bounded runtime state. Never shares the agent token.

adaptive_browser_random_hex() {
  local bytes="${1:-}" hex format
  [[ "$bytes" =~ ^([1-9]|[1-5][0-9]|6[0-4])$ ]] || return 2
  format="${bytes}/1 \"%02x\""
  hex="$(dd if=/dev/urandom bs="$bytes" count=1 2>/dev/null | hexdump -v -e "$format" 2>/dev/null)" || return 1
  [[ ${#hex} -eq $((bytes * 2)) && "$hex" =~ ^[a-f0-9]+$ ]] || return 1
  printf '%s\n' "$hex"
}

adaptive_browser_clients_file() {
  printf '%s\n' "${Z2R_ADAPTIVE_BROWSER_CLIENTS_FILE:-${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/browser-clients.tsv}"
}

adaptive_browser_state_dir() {
  printf '%s\n' "${Z2R_ADAPTIVE_BROWSER_DIR:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/browser}"
}

# AUTO is the unified router mode. AGENT_BETA remains a compatibility alias
# while existing installs and browser pairings migrate their mode file.
adaptive_browser_rotation_enabled() {
  case "$(cat "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/mode" 2>/dev/null)" in
    AUTO|AGENT_BETA) return 0 ;;
    *) return 1 ;;
  esac
}

adaptive_browser_sleep_short() {
  if command -v usleep >/dev/null 2>&1; then usleep 50000; else sleep 1; fi
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
    adaptive_browser_rotation_enabled &&
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
  [[ $# = 4 || $# = 5 ]] || return 2
  local host="${1,,}" scope="$2" file="$3" now="$4" transport="${5:-unknown}" row ver status old_host ip profile proto old_scope seen selected_strategy strategy_count extra tuple
  adaptive_browser_host_valid "$host" || return 1
  host="$ADAPTIVE_BROWSER_HOST"
  [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] && [[ "$now" =~ ^[0-9]{1,10}$ ]] && [[ "$transport" =~ ^(unknown|tls|quic)$ ]] || return 2
  [[ -r "$file" && ! -L "$file" && $(wc -c < "$file") -le 32768 ]] || return 1
  local -a rows=() family_rows=()
  while IFS= read -r row || [[ -n "$row" ]]; do
    IFS=$'\t' read -r ver status old_host ip profile proto old_scope seen selected_strategy strategy_count extra <<< "$row"
    case "$transport" in
      tls) [[ "$proto" = tls || "$proto" = googlevideo-tcp ]] || continue ;;
      quic) [[ "$proto" = quic ]] || continue ;;
    esac
    [[ "$ver" = 1 && ( "$status" = seen || "$status" =~ ^router_trial_[1-9][0-9]*$ ) && "$old_scope" = "$scope" &&
       ( ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 && "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ) ) ) || ( "$profile" = 5 && "$proto" = quic ) ) &&
       "$seen" =~ ^[0-9]{1,10}$ && "${selected_strategy:-}" =~ ^(0|[1-9][0-9]{0,2})$ &&
       "${strategy_count:-0}" =~ ^[1-9][0-9]{0,2}$ && -z "${extra:-}" ]] || continue
    [[ "$proto" != quic ]] || adaptive_browser_quic_host_valid "$old_host" || continue
    if [[ "$old_host" != "$host" ]]; then
      [[ "$transport" != quic && "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ && "$old_host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ &&
         "$profile" = 2 && ( "$proto" = tls || "$proto" = googlevideo-tcp ) ]] || continue
    else
      [[ ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 ) ) ) || ( "$profile" = 5 && "$proto" = quic ) ]] || continue
    fi
    (( seen >= now - 300 && seen <= now + 10 )) || continue
    awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; a=$1+0; b=$2+0; c=$3+0; if(a==0 || a==10 || a==127 || a>=224 || (a==100 && b>=64 && b<=127) || (a==169 && b==254) || (a==172 && b>=16 && b<=31) || (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) || (a==198 && (b==18 || b==19 || (b==51 && c==100))) || (a==203 && b==0 && c==113)) exit 1; exit 0} {exit 1}' <<< "$ip" || continue
    if [[ "$old_host" = "$host" ]]; then
      printf -v tuple '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$host" "$ip" "$profile" "$proto" "$scope" "$seen" "${selected_strategy:-0}"
      rows+=("$tuple")
      (( ${#rows[@]} <= 1 )) || return 3
    else
      printf -v tuple '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$old_host" "$ip" "$profile" googlevideo-tcp "$scope" "$seen" "${selected_strategy:-0}"
      family_rows+=("$tuple")
    fi
  done < "$file"
  if (( ${#rows[@]} == 1 )); then printf '%s\n' "${rows[0]}"; return 0; fi
  (( ${#family_rows[@]} )) || return 1
  local newest=0 selected='' selected_tuple
  for tuple in "${family_rows[@]}"; do
    IFS=$'\t' read -r old_host ip profile proto old_scope seen selected_strategy <<< "$tuple"
    if (( seen > newest )); then newest=$seen; selected="$tuple"; selected_tuple="$old_host\t$ip\t$profile\t$proto\t$old_scope\t$selected_strategy"; continue; fi
    if (( seen == newest )); then
      local current_tuple
      current_tuple="$old_host\t$ip\t$profile\t$proto\t$old_scope\t$selected_strategy"
      [[ "$current_tuple" = "$selected_tuple" ]] || return 3
    fi
  done
  printf '%s\n' "$selected"
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
  # Match Lua's scoped-first, default-fallback lock resolution, including manual locks.
  for lock_file in "$scoped_lock" "$orch_dir/locked.tsv" "$orch_dir/locked.manual.tsv"; do
    [[ -n "$lock_file" && -e "$lock_file" ]] || continue
    [[ -f "$lock_file" && ! -L "$lock_file" && -r "$lock_file" ]] || return 2
    if awk -F '\t' -v pr="$profile" -v proto="$proto" '$1==pr && (($2==proto && NF>=3) || NF==2) {found=1} END{exit !found}' "$lock_file"; then
      return 0
    fi
  done
  return 1
}

adaptive_browser_rankings_opted_in() {
  local file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/browser-rankings-opt-in"
  [[ -f "$file" && ! -L "$file" && "$(cat "$file" 2>/dev/null)" = 1 ]]
}

# Redis may only reorder fingerprints already present in this exact local catalog.
adaptive_browser_redis_ranked_candidates() {
  [[ $# = 8 ]] || return 2
  adaptive_browser_rankings_opted_in || return 0
  adaptive_browser_rotation_enabled || return 0
  local profile="$1" proto="$2" recipe="$3" stamp="$4" max="$5" args_file="$6" nfqws="$7" cache_dir="$8"
  local provider_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/provider.txt" provider url protocol now raw fingerprints catalog ordered
  local raw_file catalog_file fingerprint_file
  [[ -f "$provider_file" && ! -L "$provider_file" && -r "$provider_file" && $(wc -c < "$provider_file") -le 256 ]] || return 0
  provider="$(head -n1 "$provider_file" | tr -d '\r')"
  provider="${provider%% - *}"
  case "$provider" in ''|'Не определён'|'Не удалось определить'|Unknown) return 0 ;; esac
  [[ -n "$provider" && ${#provider} -le 120 && ! "$provider" =~ [$'\t\r\n'] &&
     ! -L "$cache_dir" && ! -L "$(dirname "$cache_dir")" ]] || return 0
  case "$proto" in
    tls) protocol=tls ;;
    googlevideo-tcp) protocol=tcp-media ;;
    quic) protocol=quic ;;
    *) return 0 ;;
  esac
  url="${Z2R_ADAPTIVE_RANKINGS_URL:-https://alooflibra.fun/z4r/adaptive-v2/browser-rankings.tsv}"
  [[ "$url" = https://* && "$url" != *[[:space:]]* ]] || return 0
  raw_file="$(mktemp /tmp/z2r-browser-ranking.XXXXXX)" || return 0
  catalog_file="${cache_dir%/}/rankings-catalog-${profile}-${recipe}.tsv"
  fingerprint_file="${raw_file}.fingerprints"
  if ! curl -4 -fsS --connect-timeout 1 --max-time 2 --max-filesize 8192 --get \
      --data-urlencode "provider=$provider" --data-urlencode "profile=$profile" \
      --data-urlencode "protocol=$protocol" --data-urlencode "recipe=$recipe" \
      --data-urlencode "treatment=standard" "$url" -o "$raw_file" 2>/dev/null; then
    rm -f "$raw_file" "$fingerprint_file"
    return 0
  fi
  now="$(date +%s)" || { rm -f "$raw_file" "$fingerprint_file"; return 0; }
  raw="$(awk -F '\t' -v now="$now" -v profile="$profile" -v protocol="$protocol" -v recipe="$recipe" '
    function uint(x) { return x ~ /^(0|[1-9][0-9]{0,9})$/ }
    function val(line, key, p) { p=index(line,"="); return p && substr(line,1,p-1)==key ? substr(line,p+1) : "" }
    NR==1 { if ($0!="schema_version=2") bad=1; next }
    /^source=/ { v=val($0,"source"); if (got_source || v!="browser_feedback") bad=1; got_source=1; next }
    /^status=/ { v=val($0,"status"); if (status!="" || (v!="fresh" && v!="stale" && v!="not_ready")) bad=1; status=v; next }
    /^generated_at=/ { v=val($0,"generated_at"); if (generated!="" || !uint(v)) bad=1; generated=v+0; next }
    /^profile_id=/ { v=val($0,"profile_id"); if (got_profile || !uint(v)) bad=1; got_profile=1; got_profile_value=v; next }
    /^protocol=/ { v=val($0,"protocol"); if (got_protocol || v !~ /^(tls|tcp-media|quic)$/) bad=1; got_protocol=1; got_protocol_value=v; next }
    /^recipe_id=/ { v=val($0,"recipe_id"); if (got_recipe || v !~ /^(tls-http1-v1|googlevideo-tcp-media-v1|googlevideo-quic-h3-media-v1)$/) bad=1; got_recipe=1; got_recipe_value=v; next }
    /^treatment_variant=/ { v=val($0,"treatment_variant"); if (got_treatment || v!="standard") bad=1; got_treatment=1; next }
    $1=="strategy" {
      if (NF!=6 || $2 !~ /^sha256:[a-f0-9]{64}$/ || $3 !~ /^(0(\.[0-9]+)?|1(\.0+)?)$/ || $3+0>1 || !uint($4) || !uint($5) || !uint($6) || seen[$2]++ || ++rows>20) bad=1
      else fingerprints[rows]=$2
      next
    }
    { bad=1 }
    END {
      if (status!="fresh" || !uint(generated) || generated>now+5 || generated<now-900 ||
          got_source!=1 || got_profile!=1 || got_profile_value!=profile || got_protocol!=1 || got_protocol_value!=protocol ||
          (got_recipe && got_recipe_value!=recipe) || (!got_recipe && recipe!="tls-http1-v1") ||
          (recipe!="tls-http1-v1" && !got_treatment) || rows<1 || bad) exit 1
      for (i=1;i<=rows;i++) print fingerprints[i]
    }
  ' "$raw_file" 2>/dev/null)" || { rm -f "$raw_file" "$fingerprint_file"; return 0; }
  printf '%s\n' "$raw" > "$fingerprint_file" || { rm -f "$raw_file" "$fingerprint_file"; return 0; }
  catalog="$(adaptive_strategy_fingerprint_catalog "$profile" "$max" "$args_file" "$nfqws" standard "$recipe" "$stamp" "$cache_dir" 2>/dev/null)" || {
    rm -f "$raw_file" "$fingerprint_file"; return 0;
  }
  printf '%s\n' "$catalog" > "$catalog_file" || { rm -f "$raw_file" "$fingerprint_file" "$catalog_file"; return 0; }
  ordered="$(awk -F '\t' 'FNR==NR { rank[++n]=$1; next } NF==2 { number[$2]=$1 } END { for(i=1;i<=n;i++) if(rank[i] in number) print number[rank[i]] }' \
    "$fingerprint_file" "$catalog_file")"
  rm -f "$raw_file" "$fingerprint_file" "$catalog_file"
  [[ -z "$ordered" ]] || printf '%s\n' "$ordered"
}

adaptive_browser_candidate_select() {
  [[ $# = 9 || $# = 10 ]] || return 2
  local host="$1" ip="$2" profile="$3" proto="$4" scope="$5" args_file="$6" nfqws="$7" orch_dir="$8" client_id="$9" exclude_strategy="${10:-}"
  local config="${ZAPRET2_ROOT:-/opt/zapret2}/config" max current state stamp exact family_exact ranked group_ranked remote family identity strategy fingerprint recipe now
  local -A seen=()
  local -a candidates=()
  [[ ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 ) ) || ( "$profile" = 5 && "$proto" = quic ) ) &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && -r "$args_file" && -x "$nfqws" ]] || return 2
  adaptive_browser_profile_lock_check "$profile" "$scope" "$orch_dir"
  case $? in 1) ;; *) return 4 ;; esac
  current="$exclude_strategy"
  [[ -z "$current" || "$current" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 2
  stamp="$(adaptive_rules_runtime_stamp "$config" "$nfqws" "$orch_dir")" || return 1
  exact="$(adaptive_rule_lookup_local "$host" "$ip" "$profile" "$proto" "$scope" "$stamp" 2>/dev/null || true)"
  family_exact=""
  if [[ "$proto" = googlevideo-tcp ]]; then
    family_exact="$(adaptive_rule_lookup_local googlevideo.com "$ip" "$profile" "$proto" "$scope" "$stamp" 2>/dev/null || true)"
  fi
  if [[ -z "$current" ]]; then
    if [[ -n "$exact" ]]; then IFS=$'\t' read -r current _ <<< "$exact"
    elif [[ -n "$family_exact" ]]; then IFS=$'\t' read -r current _ <<< "$family_exact"
    else return 3; fi
  fi
  max="$(config_profile_max_strategy "$profile" "$config")"
  [[ "$max" =~ ^[1-9][0-9]{0,2}$ ]] || return 3
  identity="exactip:$host:$ip"
  ranked="$(adaptive_rules_ranked_candidates "$profile" "$proto" "$scope" "$stamp" "$max" "$identity" 2>/dev/null || true)"
  while IFS= read -r strategy; do [[ "$strategy" =~ ^[1-9][0-9]{0,2}$ ]] && candidates+=("$strategy"); done <<< "$(printf '%s\n' "$ranked" | head -n 5)"
  if [[ "$proto" = googlevideo-tcp ]]; then
    identity="$(adaptive_rules_googlevideo_group_id "$host")" || identity=""
    if [[ -n "$identity" ]]; then
      group_ranked="$(adaptive_rules_ranked_candidates "$profile" "$proto" "$scope" "$stamp" "$max" "$identity" 2>/dev/null || true)"
      while IFS= read -r strategy; do [[ "$strategy" =~ ^[1-9][0-9]{0,2}$ ]] && candidates+=("$strategy"); done <<< "$(printf '%s\n' "$group_ranked" | head -n 5)"
    fi
  fi
  case "$proto" in googlevideo-tcp) recipe=googlevideo-tcp-media-v1 ;; quic) recipe=googlevideo-quic-h3-media-v1 ;; *) recipe=tls-http1-v1 ;; esac
  remote="$(adaptive_browser_redis_ranked_candidates "$profile" "$proto" "$recipe" "$stamp" "$max" "$args_file" "$nfqws" "$(adaptive_browser_state_dir)/catalog-cache" || true)"
  while IFS= read -r strategy; do [[ "$strategy" =~ ^[1-9][0-9]{0,2}$ ]] && candidates+=("$strategy"); done <<< "$remote"
  # Prefer the numeric successor of the strategy actually used before the
  # broader family-diverse exploration order (which can start at #31).
  if [[ "$current" =~ ^[1-9][0-9]{0,2}$ ]]; then
    for ((strategy=current + 1; strategy<=max; strategy++)); do candidates+=("$strategy"); done
    for ((strategy=1; strategy<current; strategy++)); do candidates+=("$strategy"); done
  fi
  family="$(adaptive_exploration_strategy_order "$args_file" "$max" 2>/dev/null || true)"
  while IFS= read -r strategy; do [[ "$strategy" =~ ^[1-9][0-9]{0,2}$ ]] && candidates+=("$strategy"); done <<< "$family"
  now="$(date +%s)" || return 1
  for strategy in "${candidates[@]}"; do
    [[ "$strategy" != "$current" && ! ${seen[$strategy]+yes} ]] || continue
    seen[$strategy]=1
    if adaptive_browser_candidate_confirmed_failed "$client_id" "$host" "$ip" "$profile" "$proto" "$scope" "$strategy" "$now"; then continue; fi
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
    [[ "$ver" = 1 &&
       ( "$old_host" = "$host" || ( "$profile" = 2 && "$proto" = googlevideo-tcp &&
         "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ && "$old_host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ) ) &&
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

# Keep a short browser presence heartbeat on tmpfs for the WebUI. A write is
# rate-limited per client and never contains the browser token or LAN address.
adaptive_browser_presence_touch() {
  [[ $# = 1 && "$1" =~ ^[a-f0-9]{32}$ ]] || return 2
  local id="$1" now dir file tmp entry count=0 stamp
  now="$(date +%s)" || return 1
  dir="$(adaptive_browser_state_dir)/presence"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$dir" ]] || return 1
  mkdir -p "$dir" || return 1
  file="$dir/$id"
  [[ ! -L "$file" ]] || return 1
  if [[ -f "$file" ]]; then
    stamp="$(cat "$file" 2>/dev/null)"
    [[ "$stamp" =~ ^[0-9]{10}$ ]] && (( stamp >= now - 60 && stamp <= now + 5 )) && return 0
  fi
  for entry in "$dir"/*; do
    [[ -f "$entry" && ! -L "$entry" ]] || continue
    count=$((count + 1))
    (( count <= 64 )) || return 1
    stamp="$(cat "$entry" 2>/dev/null)"
    if [[ "$stamp" =~ ^[0-9]{10}$ ]] && (( stamp < now - 600 )); then rm -f "$entry"; count=$((count - 1)); fi
  done
  (( count < 64 )) || [[ -f "$file" ]] || return 1
  tmp="$(mktemp "$dir/.presence.XXXXXX")" || return 1
  (umask 077; printf '%s\n' "$now" > "$tmp") && chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

adaptive_browser_stats_opted_in() {
  local root="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive"
  [[ -f "$root/browser-flow-upload-opt-in" && ! -L "$root/browser-flow-upload-opt-in" &&
     "$(cat "$root/browser-flow-upload-opt-in" 2>/dev/null)" = 1 ]]
}

adaptive_browser_stats_queue_attempt() {
  [[ $# = 1 && "$1" =~ ^[a-f0-9]{32}$ ]] || return 2
  adaptive_browser_stats_opted_in || return 0
  local row ver id client client_ip scope host ip profile proto trigger state strategy fingerprint created expires generation extra
  local protocol treatment=standard proven=false confidence=low queue_dir queue lock tmp oldrow oldver oldid observed oldprofile oldproto oldfp oldstate oldtreatment oldproven oldconfidence count=0
  local -a rows=()
  row="$(adaptive_browser_attempt_read "$1")" || return 1
  IFS=$'\t' read -r ver id client client_ip scope host ip profile proto trigger state strategy fingerprint created expires generation extra <<< "$row"
  [[ "$ver" = 1 && "$id" = "$1" && "$state" =~ ^(CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED)$ &&
     "$created" =~ ^[0-9]{10}$ && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ && -z "${extra:-}" ]] || return 0
  case "$proto:$profile" in tls:[1-4]) protocol=tls ;; googlevideo-tcp:2) protocol=googlevideo-tcp ;; quic:5) protocol=quic ;; *) return 0 ;; esac
  case "$state:$protocol" in
    CONFIRMED_SUCCESS:tls|CONFIRMED_SUCCESS:googlevideo-tcp) proven=true; confidence=high ;;
    CONFIRMED_SUCCESS:quic) proven=true; confidence=high ;;
    CONFIRMED_FAILURE:tls|CONFIRMED_FAILURE:googlevideo-tcp) proven=true; confidence=medium ;;
    TCP_FALLBACK:quic) confidence=high ;;
  esac
  queue_dir="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive"
  queue="$queue_dir/browser-flow-queue.tsv"
  lock="$(adaptive_browser_state_dir)/stats-queue.lock"
  [[ ! -L "$queue_dir" && ! -L "$queue" && ! -L "$(adaptive_browser_state_dir)" && ! -L "$lock" ]] || return 1
  mkdir -p "$queue_dir" "$(adaptive_browser_state_dir)" || return 1
  local tries=0
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 20 )) || return 1
    adaptive_browser_sleep_short
  done
  if [[ -f "$queue" ]]; then
    [[ -r "$queue" && $(wc -c < "$queue") -le 65536 ]] || { rmdir "$lock"; return 1; }
    while IFS= read -r oldrow || [[ -n "$oldrow" ]]; do
      IFS=$'\t' read -r oldver oldid observed oldprofile oldproto oldfp oldstate oldtreatment oldproven oldconfidence extra <<< "$oldrow"
      [[ "$oldver" = 1 && "$oldid" =~ ^[a-f0-9]{32}$ && "$observed" =~ ^[0-9]{10}$ && "$oldprofile" =~ ^[1-5]$ &&
         "$oldproto" =~ ^(tls|googlevideo-tcp|quic)$ && "$oldfp" =~ ^sha256:[a-f0-9]{64}$ &&
         "$oldstate" =~ ^(CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED)$ &&
         "$oldtreatment" = standard && "$oldproven" =~ ^(true|false)$ && "$oldconfidence" =~ ^(low|medium|high)$ && -z "${extra:-}" ]] || continue
      [[ "$oldid" != "$id" ]] || continue
      rows+=("$oldrow")
    done < "$queue"
  fi
  printf -v row '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$id" "$created" "$profile" "$protocol" "$fingerprint" "$state" "$treatment" "$proven" "$confidence"
  rows+=("$row")
  if (( ${#rows[@]} > 256 )); then rows=("${rows[@]: -256}"); fi
  tmp="$(mktemp "$queue_dir/.browser-flow-queue.XXXXXX")" || { rmdir "$lock"; return 1; }
  printf '%s\n' "${rows[@]}" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$queue" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock"
}

adaptive_browser_stats_flush() {
  adaptive_browser_stats_opted_in || return 0
  local root="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive"
  local token_file="$root/browser-flow-upload-token" queue="$root/browser-flow-queue.tsv"
  local provider_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/provider.txt"
  local upload_lock="$(adaptive_browser_state_dir)/stats-upload.lock" queue_lock="$(adaptive_browser_state_dir)/stats-queue.lock"
  local token provider now row ver id observed profile protocol fingerprint state treatment proven confidence extra key comma='' results='' count=0
  local snapshot payload response curl_cfg sent_id
  local -a selected_ids=()
  local -A seen_dimensions=()
  [[ -e "$queue" ]] || return 0
  [[ -f "$queue" && ! -L "$queue" ]] || return 1
  [[ -f "$token_file" && ! -L "$token_file" && -r "$token_file" && $(wc -c < "$token_file") -le 64 &&
     -r "$queue" && $(wc -c < "$queue") -le 65536 &&
     -f "$provider_file" && ! -L "$provider_file" && -r "$provider_file" && $(wc -c < "$provider_file") -le 256 &&
     ! -L "$(adaptive_browser_state_dir)" && ! -L "$upload_lock" && ! -L "$queue_lock" ]] || return 1
  token="$(cat "$token_file")"
  [[ "$token" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || return 1
  provider="$(head -n1 "$provider_file" | tr -d '\r')"; provider="${provider%% - *}"
  [[ -n "$provider" && ${#provider} -le 120 && "$provider" != 'Не определён' && "$provider" != 'Не удалось определить' &&
     "$provider" != *'"'* && "$provider" != *'\'* && "$provider" != *[[:cntrl:]]* ]] || return 1
  mkdir -p "$(adaptive_browser_state_dir)" || return 1
  (umask 077; mkdir "$upload_lock") 2>/dev/null || return 0
  printf '%s\n' "$$" > "$upload_lock/pid"
  local tries=0
  while ! (umask 077; mkdir "$queue_lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 20 )) || { rm -f "$upload_lock/pid"; rmdir "$upload_lock"; return 0; }
    adaptive_browser_sleep_short
  done
  snapshot="$(mktemp /tmp/z2r-browser-flow-snapshot.XXXXXX)" || { rmdir "$queue_lock"; rm -f "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
  cp "$queue" "$snapshot" && chmod 600 "$snapshot" || { rm -f "$snapshot"; rmdir "$queue_lock"; rm -f "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
  rmdir "$queue_lock"
  now="$(date +%s)" || { rm -f "$snapshot" "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
  while IFS=$'\t' read -r ver id observed profile protocol fingerprint state treatment proven confidence extra; do
    [[ "$ver" = 1 && "$id" =~ ^[a-f0-9]{32}$ && "$observed" =~ ^[0-9]{10}$ && "$profile" =~ ^[1-5]$ &&
       "$protocol" =~ ^(tls|googlevideo-tcp|quic)$ && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ &&
       "$state" =~ ^(CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED)$ &&
       "$treatment" = standard && "$proven" =~ ^(true|false)$ && "$confidence" =~ ^(low|medium|high)$ && -z "${extra:-}" ]] || continue
    (( observed >= now - 604800 && observed <= now + 300 )) || continue
    key="$profile|$protocol|$fingerprint|$state|$treatment|$proven|$confidence"
    if [[ ${seen_dimensions[$key]+yes} ]]; then
      selected_ids+=("$id")
      continue
    fi
    seen_dimensions["$key"]=1
    [[ -z "$results" ]] || comma=','
    results+="$comma{\"profile_id\":$profile,\"protocol\":\"$protocol\",\"fingerprint\":\"$fingerprint\",\"state\":\"$state\",\"treatment_variant\":\"$treatment\",\"protocol_proven\":$proven,\"confidence\":\"$confidence\"}"
    selected_ids+=("$id")
    count=$((count + 1))
    (( count < 24 )) || break
  done < "$snapshot"
  rm -f "$snapshot"
  if (( count == 0 )); then rm -f "$upload_lock/pid"; rmdir "$upload_lock"; return 0; fi
  local request_id
  request_id="$(adaptive_browser_random_hex 16)"
  [[ "$request_id" =~ ^[a-f0-9]{32}$ ]] || { rm -f "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
  payload="$(mktemp /tmp/z2r-browser-flow-payload.XXXXXX)" || { rm -f "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
  response="$(mktemp /tmp/z2r-browser-flow-response.XXXXXX)" || { rm -f "$payload" "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
  curl_cfg="$(mktemp /tmp/z2r-browser-flow-curl.XXXXXX)" || { rm -f "$payload" "$response" "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
  (umask 077; printf '{"schema_version":1,"source":"browser_flow","client_profile":"chromium-v1","request_id":"%s","provider":"%s","observed_at":%s,"results":[%s]}\n' \
    "$request_id" "$provider" "$now" "$results" > "$payload" &&
    printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$token" > "$curl_cfg") || {
      rm -f "$payload" "$response" "$curl_cfg" "$upload_lock/pid"; rmdir "$upload_lock"; return 1;
    }
  chmod 600 "$payload" "$curl_cfg" || { rm -f "$payload" "$response" "$curl_cfg" "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
  if ! curl -4 -fsS --connect-timeout 2 --max-time 4 --max-filesize 32768 --config "$curl_cfg" \
      --data-binary "@$payload" -o "$response" 'https://alooflibra.fun/z4r/adaptive-v2/browser-flow' 2>/dev/null ||
      ! grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$response" || ! grep -Eq '"source"[[:space:]]*:[[:space:]]*"browser_flow"' "$response"; then
    rm -f "$payload" "$response" "$curl_cfg" "$upload_lock/pid"; rmdir "$upload_lock"; return 1
  fi
  tries=0
  while ! (umask 077; mkdir "$queue_lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 20 )) || { rm -f "$payload" "$response" "$curl_cfg" "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
    adaptive_browser_sleep_short
  done
  snapshot="$(mktemp "$root/.browser-flow-queue.XXXXXX")" || { rmdir "$queue_lock"; rm -f "$payload" "$response" "$curl_cfg" "$upload_lock/pid"; rmdir "$upload_lock"; return 1; }
  while IFS=$'\t' read -r ver id observed profile protocol fingerprint state treatment proven confidence extra; do
    [[ "$ver" = 1 && "$id" =~ ^[a-f0-9]{32}$ && "$observed" =~ ^[0-9]{10}$ && "$profile" =~ ^[1-5]$ &&
       "$protocol" =~ ^(tls|googlevideo-tcp|quic)$ && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ &&
       "$state" =~ ^(CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED)$ &&
       "$treatment" = standard && "$proven" =~ ^(true|false)$ && "$confidence" =~ ^(low|medium|high)$ && -z "${extra:-}" ]] || continue
    sent_id=0
    for request_id in "${selected_ids[@]}"; do [[ "$request_id" = "$id" ]] && { sent_id=1; break; }; done
    (( sent_id )) || printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ver" "$id" "$observed" "$profile" "$protocol" "$fingerprint" "$state" "$treatment" "$proven" "$confidence" >> "$snapshot"
  done < "$queue"
  if [[ -s "$snapshot" ]]; then chmod 600 "$snapshot" && mv -f "$snapshot" "$queue" || { rm -f "$snapshot" "$payload" "$response" "$curl_cfg" "$upload_lock/pid"; rmdir "$queue_lock"; rmdir "$upload_lock"; return 1; }
  else rm -f "$snapshot" "$queue"; fi
  rmdir "$queue_lock"
  rm -f "$payload" "$response" "$curl_cfg" "$upload_lock/pid"
  rmdir "$upload_lock"
  return 0
}

adaptive_browser_stats_schedule_flush() {
  adaptive_browser_stats_opted_in || return 0
  (adaptive_browser_stats_flush) </dev/null >/dev/null 2>&1 &
}

adaptive_browser_attempt_file() {
  printf '%s/%s.tsv\n' "$(adaptive_browser_state_dir)/attempts" "$1"
}

adaptive_browser_attempt_reservation_release() {
  [[ $# = 1 && "$1" =~ ^[a-f0-9]{32}$ ]] || return 2
  local path="$(adaptive_browser_state_dir)/attempts/.reserve.$1" owner
  [[ -d "$path" && ! -L "$path" && -f "$path/pid" && ! -L "$path/pid" ]] || return 1
  owner="$(cat "$path/pid" 2>/dev/null)"
  [[ "$owner" = "$$" ]] || return 1
  rm -f "$path/pid" && rmdir "$path"
}

# Keep the tmpfs attempt journal bounded across long-running routers. Terminal
# rows are retained for five minutes for the WebUI and candidate-failure budget.
adaptive_browser_attempt_gc() {
  [[ ( $# = 1 || $# = 2 ) && "$1" =~ ^[0-9]{10}$ && ( $# = 1 || "$2" =~ ^[a-f0-9]{32}$ ) ]] || return 2
  local now="$1" reserve_id="${2:-}" dir="$(adaptive_browser_state_dir)/attempts" gc_lock file name row reservation
  local ver id client client_ip scope host ip profile proto trigger state strategy fingerprint created expires generation extra
  local count=0 scanned=0 tries=0 owner attempt_lock lock_stamp reserve_name
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$dir" ]] || return 1
  mkdir -p "$dir" || return 1
  gc_lock="$dir/.gc.lock"
  [[ ! -L "$gc_lock" ]] || return 1
  while ! (umask 077; mkdir "$gc_lock") 2>/dev/null; do
    tries=$((tries + 1))
    owner="$(cat "$gc_lock/pid" 2>/dev/null)"
    if [[ "$owner" =~ ^[1-9][0-9]{0,9}$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$gc_lock/pid" 2>/dev/null || :
      rmdir "$gc_lock" 2>/dev/null || :
      continue
    fi
    if [[ ! "$owner" =~ ^[1-9][0-9]{0,9}$ ]]; then
      lock_stamp="$(stat -c %Y "$gc_lock" 2>/dev/null)"
      if [[ "$lock_stamp" =~ ^[0-9]{10}$ ]] && (( now - lock_stamp > 2 )); then
        rmdir "$gc_lock" 2>/dev/null || :
        continue
      fi
    fi
    (( tries < 40 )) || return 1
    adaptive_browser_sleep_short
  done
  printf '%s\n' "$$" > "$gc_lock/pid" || { rm -f "$gc_lock/pid"; rmdir "$gc_lock"; return 1; }
  for file in "$dir"/*.tsv; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    scanned=$((scanned + 1))
    if (( scanned > 512 )); then rm -f "$gc_lock/pid"; rmdir "$gc_lock"; return 1; fi
    name="${file##*/}"; id="${name%.tsv}"
    [[ "$id" =~ ^[a-f0-9]{32}$ && $(wc -c < "$file") -le 2048 ]] || { count=$((count + 1)); continue; }
    row="$(adaptive_browser_attempt_read "$id" 2>/dev/null)" || { count=$((count + 1)); continue; }
    IFS=$'\t' read -r ver id client client_ip scope host ip profile proto trigger state strategy fingerprint created expires generation extra <<< "$row"
    [[ "$ver" = 1 && "$id" = "${name%.tsv}" && "$created" =~ ^[0-9]{10}$ && "$expires" =~ ^[0-9]{10}$ &&
       "$generation" =~ ^[1-9][0-9]{0,8}$ && -z "${extra:-}" ]] || { count=$((count + 1)); continue; }
    if (( created < now - 300 )); then
      attempt_lock="$file.lock"
      [[ ! -L "$attempt_lock" ]] || { count=$((count + 1)); continue; }
      if (umask 077; mkdir "$attempt_lock") 2>/dev/null; then
        row="$(adaptive_browser_attempt_read "$id" 2>/dev/null)" || row=""
        IFS=$'\t' read -r ver id client client_ip scope host ip profile proto trigger state strategy fingerprint created expires generation extra <<< "$row"
        if [[ "$ver" = 1 && "$id" = "${name%.tsv}" && "$created" =~ ^[0-9]{10}$ && "$generation" =~ ^[1-9][0-9]{0,8}$ && -z "${extra:-}" ]] && (( created < now - 300 )); then
          if adaptive_browser_trial_remove "$id" "$generation" && rm -f -- "$file"; then :; else
            rmdir "$attempt_lock" 2>/dev/null || :; rm -f "$gc_lock/pid"; rmdir "$gc_lock"; return 1
          fi
        else
          count=$((count + 1))
        fi
        rmdir "$attempt_lock" 2>/dev/null || :
      else
        count=$((count + 1))
      fi
    else
      count=$((count + 1))
    fi
  done
  for reservation in "$dir"/.reserve.*; do
    [[ -d "$reservation" && ! -L "$reservation" ]] || continue
    scanned=$((scanned + 1))
    if (( scanned > 512 )); then rm -f "$gc_lock/pid"; rmdir "$gc_lock"; return 1; fi
    reserve_name="${reservation##*/}"
    owner="$(cat "$reservation/pid" 2>/dev/null)"
    if [[ "$reserve_name" =~ ^\.reserve\.[a-f0-9]{32}$ && "$owner" =~ ^[1-9][0-9]{0,9}$ ]] && kill -0 "$owner" 2>/dev/null; then
      count=$((count + 1))
    elif [[ ! "$owner" =~ ^[1-9][0-9]{0,9}$ ]]; then
      lock_stamp="$(stat -c %Y "$reservation" 2>/dev/null)"
      if [[ "$lock_stamp" =~ ^[0-9]{10}$ ]] && (( now - lock_stamp > 2 )) && [[ -f "$reservation/pid" || -z "$owner" ]]; then
        rm -f "$reservation/pid" 2>/dev/null || :
        rmdir "$reservation" 2>/dev/null || count=$((count + 1))
      else count=$((count + 1)); fi
    else
      rm -f "$reservation/pid" 2>/dev/null || :
      rmdir "$reservation" 2>/dev/null || count=$((count + 1))
    fi
  done
  if [[ -n "$reserve_id" ]]; then
    (( count < 64 )) || { rm -f "$gc_lock/pid"; rmdir "$gc_lock"; return 3; }
    reservation="$dir/.reserve.$reserve_id"
    [[ ! -e "$reservation" && ! -L "$reservation" ]] || { rm -f "$gc_lock/pid"; rmdir "$gc_lock"; return 1; }
    if ! (umask 077; mkdir "$reservation") || ! printf '%s\n' "$$" > "$reservation/pid"; then
      rm -f "$reservation/pid" 2>/dev/null || :
      rmdir "$reservation" 2>/dev/null || :
      rm -f "$gc_lock/pid"; rmdir "$gc_lock"; return 1
    fi
    count=$((count + 1))
  fi
  rm -f "$gc_lock/pid"
  rmdir "$gc_lock" || return 1
  if [[ -n "$reserve_id" ]]; then (( count <= 64 )) || return 3
  else (( count < 64 )) || return 3; fi
  return 0
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
  local ver id generation client_id scope host ip profile proto strategy fingerprint syn_at selected_at ramp_treatment ramp_ack_evidence extra
  IFS=$'\t' read -r ver id generation client_id scope host ip profile proto strategy fingerprint syn_at selected_at ramp_treatment ramp_ack_evidence extra <<< "$row"
  # Rows written before Ramp treatment evidence was added remain readable.
  [[ -n "${ramp_treatment:-}" ]] || ramp_treatment=unknown
  [[ -n "${ramp_ack_evidence:-}" ]] || ramp_ack_evidence=unknown
  [[ "$ver" = 1 && "$id" = "$1" && "$generation" = "$2" && "$client_id" =~ ^[a-f0-9]{32}$ &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$host" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( "$profile" =~ ^[1-4]$ || "$profile" = 5 ) &&
     ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 && "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ) || ( "$proto" = quic && "$profile" = 5 ) ) &&
     "$strategy" =~ ^[1-9][0-9]{0,2}$ && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ &&
     "$syn_at" =~ ^[0-9]{1,10}$ && "$selected_at" =~ ^[0-9]{1,10}$ &&
     "$ramp_treatment" =~ ^(not_applicable|unknown|applied|bypassed|unchanged|no_window_scale)$ &&
     "$ramp_ack_evidence" =~ ^(not_applicable|unknown|confirmed|pending)$ && -z "${extra:-}" ]] || return 2
  [[ "$proto" != googlevideo-tcp || "$ramp_treatment" != not_applicable ]] || return 2
  [[ "$proto" = googlevideo-tcp || "$ramp_treatment" = not_applicable || "$ramp_treatment" = unknown ]] || return 2
  [[ "$proto" != googlevideo-tcp || "$ramp_ack_evidence" != not_applicable || "$ramp_treatment" != applied ]] || return 2
  [[ "$proto" = googlevideo-tcp || "$ramp_ack_evidence" = not_applicable || "$ramp_ack_evidence" = unknown ]] || return 2
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
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; adaptive_browser_sleep_short; done
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
  [[ $# = 13 || $# = 14 ]] || return 2
  local id="$1" generation="$2" client_id="$3" client_ip="$4" scope="$5" host="$6" ip="$7"
  local profile="$8" proto="$9" strategy="${10}" fingerprint="${11}" created="${12}" expires="${13}"
  local trigger="${14:-standard}" max_ttl=180
  local file lock dir tmp row ver old_id old_gen old_client old_client_ip old_scope old_host old_ip old_profile old_proto old_strategy old_fp old_created old_expires extra now count=0 tries=0
  [[ "$id" =~ ^[a-f0-9]{32}$ && "$generation" =~ ^[1-9][0-9]{0,8}$ && "$client_id" =~ ^[a-f0-9]{32}$ &&
     "$client_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
     "$(adaptive_browser_host_valid "$host" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "${host,,}" &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 ) ) ) || ( "$profile" = 5 && "$proto" = quic ) ) &&
     "$strategy" =~ ^[1-9][0-9]{0,2}$ && ( "$fingerprint" = - || "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ ) &&
     "$created" =~ ^[0-9]{1,10}$ && "$expires" =~ ^[0-9]{1,10}$ ]] || return 2
  [[ "$proto" != quic ]] || adaptive_browser_quic_host_valid "$host" || return 2
  now="$(date +%s)"
  [[ "$trigger" = standard || "$trigger" = ramp_canary ]] || return 2
  if [[ "$trigger" = ramp_canary ]]; then
    (( expires > now && expires <= now + 300 && created <= now + 5 )) || return 2
  else
    [[ "$profile" = 2 && "$proto" = googlevideo-tcp ]] && max_ttl=600
    (( expires > now && expires <= now + max_ttl && created <= now + 5 )) || return 2
  fi
  file="$(adaptive_browser_trials_file)"; dir="$(dirname "$file")"; lock="$file.lock"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$file" && ! -L "$lock" ]] || return 1
  mkdir -p "$dir" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; adaptive_browser_sleep_short; done
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
       if [[ "$old_scope" = "$scope" &&
            ( "$old_host" = "$host" ||
              ( "$profile" = 2 && "$proto" = googlevideo-tcp && "$old_profile" = 2 && "$old_proto" = googlevideo-tcp &&
                "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ && "$old_host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ) ) ]]; then
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
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; adaptive_browser_sleep_short; done
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
     "$4" =~ ^(main_frame_network_failure|critical_resource_repeated_failure|user_fix|ramp_canary)$ && "$5" =~ ^[0-9]{10}$ ]] || return 2
  local client_id="$1" event_id="$2" host="$3" trigger="$4" now="$5"
  local dir file lock tmp row ver old_id old_host old_trigger old_seen extra count=0 same_host=0 tries=0 outcome=accepted
  dir="$(adaptive_browser_state_dir)/events"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$dir" ]] || return 1
  mkdir -p "$dir" || return 1
  file="$dir/$client_id.tsv"; lock="$file.lock"
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 20 )) || return 1
    adaptive_browser_sleep_short
  done
  tmp="$(mktemp "$dir/.events.XXXXXX")" || { rmdir "$lock"; return 1; }
  if [[ -r "$file" && ! -L "$file" ]]; then
    [[ $(wc -c < "$file") -le 4096 ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    while IFS= read -r row || [[ -n "$row" ]]; do
      IFS=$'\t' read -r ver old_id old_host old_trigger old_seen extra <<< "$row"
      [[ "$ver" = 1 && "$old_id" =~ ^[a-f0-9]{32}$ &&
         "$(adaptive_browser_host_valid "$old_host" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "$old_host" &&
         "$old_trigger" =~ ^(main_frame_network_failure|critical_resource_repeated_failure|user_fix|ramp_canary)$ &&
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
     "$trigger" =~ ^(main_frame_network_failure|critical_resource_repeated_failure|user_fix|ramp_canary)$ &&
     "$state" =~ ^(QUEUED|TEST_ONLY|TARGET_NOT_MANAGED|WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS|CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED)$ &&
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
  [[ $# = 3 && "$1" =~ ^[a-f0-9]{32}$ && "$2" =~ ^(QUEUED|WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS|CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED|TARGET_NOT_MANAGED)$ &&
     "$3" =~ ^(WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS|CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED|TARGET_NOT_MANAGED)$ ]] || return 2
  local id="$1" expected="$2" next="$3" file dir lock row ver attempt client ip scope host dst profile proto trigger state strategy fp created expires generation extra tries=0
  file="$(adaptive_browser_attempt_file "$id")"; dir="$(dirname "$file")"; lock="$file.lock"
  [[ -r "$file" && ! -L "$file" && ! -L "$dir" && $(wc -c < "$file") -le 2048 ]] || return 1
  case "$expected:$next" in
    QUEUED:WAIT_NEW_FLOW|QUEUED:TARGET_NOT_MANAGED|QUEUED:CANCELLED|QUEUED:EXPIRED|WAIT_NEW_FLOW:FLOW_CONFIRMED|WAIT_NEW_FLOW:TCP_FALLBACK|WAIT_NEW_FLOW:UNKNOWN|WAIT_NEW_FLOW:NOT_TESTED|WAIT_NEW_FLOW:CANCELLED|WAIT_NEW_FLOW:EXPIRED|FLOW_CONFIRMED:WAIT_BROWSER_RESULT|FLOW_CONFIRMED:TCP_FALLBACK|FLOW_CONFIRMED:CONFIRMED_FAILURE|FLOW_CONFIRMED:UNKNOWN|FLOW_CONFIRMED:CANCELLED|FLOW_CONFIRMED:EXPIRED|WAIT_BROWSER_RESULT:PROVISIONAL_SUCCESS|WAIT_BROWSER_RESULT:TCP_FALLBACK|WAIT_BROWSER_RESULT:CONFIRMED_FAILURE|WAIT_BROWSER_RESULT:UNKNOWN|WAIT_BROWSER_RESULT:CANCELLED|WAIT_BROWSER_RESULT:EXPIRED|PROVISIONAL_SUCCESS:CONFIRMED_SUCCESS|PROVISIONAL_SUCCESS:TCP_FALLBACK|PROVISIONAL_SUCCESS:CONFIRMED_FAILURE|PROVISIONAL_SUCCESS:UNKNOWN|PROVISIONAL_SUCCESS:EXPIRED) ;;
    *) return 2 ;;
  esac
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; adaptive_browser_sleep_short; done
  row="$(cat "$file")"
  IFS=$'\t' read -r ver attempt client ip scope host dst profile proto trigger state strategy fp created expires generation extra <<< "$row"
  if [[ "$ver" != 1 || "$attempt" != "$id" || "$state" != "$expected" || -n "${extra:-}" ]]; then rmdir "$lock"; return 3; fi
  adaptive_browser_attempt_write "$attempt" "$client" "$ip" "$scope" "$host" "$dst" "$profile" "$proto" "$trigger" "$next" "$strategy" "$fp" "$created" "$expires" "$generation" || { rmdir "$lock"; return 1; }
  rmdir "$lock" || return 1
}

# Store only coarse, opt-in Googlevideo playback evidence. It is short-lived,
# bounded, local to the router, and never sufficient by itself to create a Ramp
# exemption. Row: attempt/generation/client/scope/host/IP/profile/transport/
# strategy/fingerprint/Ramp treatment+ACK/quality/playback metrics/timestamp.
adaptive_browser_media_quality_write() {
  [[ $# = 19 ]] || return 2
  local attempt_id="$1" generation="$2" client_id="$3" scope="$4" host="$5" ip="$6"
  local profile="$7" proto="$8" strategy="$9" fingerprint="${10}" treatment="${11}" ack="${12}"
  local quality="${13}" sample_ms="${14}" progress_ms="${15}" stall_ms="${16}"
  local dropped="${17}" total="${18}" observed_at="${19}"
  local dir file lock tmp row ver old_attempt old_generation old_client old_scope old_host old_ip old_profile old_proto
  local old_strategy old_fingerprint old_treatment old_ack old_quality old_sample old_progress old_stall old_dropped old_total old_at extra
  local now tries=0 count=0

  [[ "$attempt_id" =~ ^[a-f0-9]{32}$ && "$generation" =~ ^[1-9][0-9]{0,8}$ && "$client_id" =~ ^[a-f0-9]{32}$ &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
     "$(adaptive_browser_host_valid "$host" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "$host" &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$profile" = 2 && "$proto" = googlevideo-tcp &&
     "$strategy" =~ ^[1-9][0-9]{0,2}$ && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ &&
     "$treatment" =~ ^(applied|bypassed)$ && "$ack" =~ ^(unknown|confirmed|pending)$ &&
     "$quality" =~ ^(healthy|degraded|unknown)$ && "$sample_ms" =~ ^[0-9]{1,5}$ &&
     "$progress_ms" =~ ^[0-9]{1,5}$ && "$stall_ms" =~ ^[0-9]{1,5}$ &&
     "$dropped" =~ ^[0-9]{1,6}$ && "$total" =~ ^[0-9]{1,6}$ && "$observed_at" =~ ^[0-9]{10}$ ]] || return 2
  (( sample_ms <= 12000 && progress_ms <= 12000 && stall_ms <= 12000 && dropped <= 999999 && total <= 999999 )) || return 2
  if [[ "$quality" = healthy ]]; then (( sample_ms >= 7500 && progress_ms >= 5000 && stall_ms < 1000 )) || return 2; fi
  if [[ "$quality" = degraded ]]; then (( sample_ms >= 5000 )) || return 2; fi

  now="$(date +%s)"
  (( observed_at >= now - 60 && observed_at <= now + 5 )) || return 2
  dir="$(adaptive_browser_state_dir)/media-quality"
  file="$dir/evidence.tsv"; lock="$file.lock"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$dir" && ! -L "$file" && ! -L "$lock" ]] || return 1
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries + 1)); (( tries < 20 )) || return 1; adaptive_browser_sleep_short; done
  tmp="$(mktemp "$dir/.evidence.XXXXXX")" || { rmdir "$lock"; return 1; }
  if [[ -r "$file" ]]; then
    [[ $(wc -c < "$file") -le 32768 ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    while IFS= read -r row || [[ -n "$row" ]]; do
      IFS=$'\t' read -r ver old_attempt old_generation old_client old_scope old_host old_ip old_profile old_proto \
        old_strategy old_fingerprint old_treatment old_ack old_quality old_sample old_progress old_stall old_dropped old_total old_at extra <<< "$row"
      [[ "$ver" = 1 && "$old_attempt" =~ ^[a-f0-9]{32}$ && "$old_generation" =~ ^[1-9][0-9]{0,8}$ &&
         "$old_client" =~ ^[a-f0-9]{32}$ && ( "$old_scope" = default || "$old_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
         "$old_host" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ && "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
         "$old_profile" = 2 && "$old_proto" = googlevideo-tcp && "$old_strategy" =~ ^[1-9][0-9]{0,2}$ &&
         "$old_fingerprint" =~ ^sha256:[a-f0-9]{64}$ && "$old_treatment" =~ ^(applied|bypassed)$ &&
         "$old_ack" =~ ^(unknown|confirmed|pending)$ && "$old_quality" =~ ^(healthy|degraded|unknown)$ &&
         "$old_sample" =~ ^[0-9]{1,5}$ && "$old_progress" =~ ^[0-9]{1,5}$ && "$old_stall" =~ ^[0-9]{1,5}$ &&
         "$old_dropped" =~ ^[0-9]{1,6}$ && "$old_total" =~ ^[0-9]{1,6}$ && "$old_at" =~ ^[0-9]{10}$ && -z "${extra:-}" ]] || {
           rm -f "$tmp"; rmdir "$lock"; return 1;
         }
      (( old_at >= now - 86400 )) || continue
      if [[ "$old_attempt" = "$attempt_id" && "$old_generation" = "$generation" ]]; then
        rm -f "$tmp"; rmdir "$lock"; return 3
      fi
      count=$((count + 1)); (( count < 64 )) || { rm -f "$tmp"; rmdir "$lock"; return 1; }
      printf '%s\n' "$row" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    done < "$file"
  fi
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$attempt_id" "$generation" "$client_id" "$scope" "$host" "$ip" "$profile" "$proto" "$strategy" \
    "$fingerprint" "$treatment" "$ack" "$quality" "$sample_ms" "$progress_ms" "$stall_ms" "$dropped" "$total" "$observed_at" >> "$tmp" || {
      rm -f "$tmp"; rmdir "$lock"; return 1;
    }
  chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock" || return 1
}

# Accept only a natural Ramp -> Plain -> Plain -> Ramp browser sequence for
# one exact target. Applying the short exception remains a separate operation.
adaptive_browser_ramp_canary_validate() {
  [[ $# = 6 ]] || return 2
  local host="$1" ip="$2" scope="$3" ids="$4" now="$5" wanted_client="$6"
  local file row ver id generation client old_scope old_host old_ip profile proto strategy fp treatment ack
  local quality sample progress stall dropped total observed extra count=0 i current_id expected_treatment
  local first_client="" first_strategy="" first_fp="" first_at=0 last_at=0
  local -a wanted=() expected=(applied bypassed bypassed applied)
  local -A rows=()
  [[ "$(adaptive_browser_host_valid "$host" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "$host" &&
     "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
     "$ids" =~ ^[a-f0-9]{32},[a-f0-9]{32},[a-f0-9]{32},[a-f0-9]{32}$ &&
     "$now" =~ ^[0-9]{10}$ && "$wanted_client" =~ ^[a-f0-9]{32}$ ]] || return 2
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 2; fi
  awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; a=$1+0; b=$2+0; c=$3+0; if(a==0 || a==10 || a==127 || a>=224 || (a==100 && b>=64 && b<=127) || (a==169 && b==254) || (a==172 && b>=16 && b<=31) || (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) || (a==198 && (b==18 || b==19 || (b==51 && c==100))) || (a==203 && b==0 && c==113)) exit 1; exit 0} {exit 1}' <<< "$ip" || return 2
  IFS=, read -r -a wanted <<< "$ids"
  for ((i=0; i<4; i++)); do
    for ((count=0; count<i; count++)); do [[ "${wanted[i]}" != "${wanted[count]}" ]] || return 2; done
  done
  file="$(adaptive_browser_state_dir)/media-quality/evidence.tsv"
  [[ -f "$file" && ! -L "$file" && -r "$file" && $(wc -c < "$file") -le 32768 ]] || return 1
  count=0
  while IFS= read -r row || [[ -n "$row" ]]; do
    count=$((count + 1)); (( count <= 64 )) || return 1
    IFS=$'\t' read -r ver id generation client old_scope old_host old_ip profile proto strategy fp treatment ack \
      quality sample progress stall dropped total observed extra <<< "$row"
    [[ "$ver" = 1 && "$id" =~ ^[a-f0-9]{32}$ && "$generation" =~ ^[1-9][0-9]{0,8}$ &&
       "$client" =~ ^[a-f0-9]{32}$ && ( "$old_scope" = default || "$old_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
       "$old_host" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ && "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
       "$profile" = 2 && "$proto" = googlevideo-tcp && "$strategy" =~ ^[1-9][0-9]{0,2}$ &&
       "$fp" =~ ^sha256:[a-f0-9]{64}$ && "$treatment" =~ ^(applied|bypassed)$ &&
       "$ack" =~ ^(unknown|confirmed|pending)$ && "$quality" =~ ^(healthy|degraded|unknown)$ &&
       "$sample" =~ ^[0-9]{1,5}$ && "$progress" =~ ^[0-9]{1,5}$ && "$stall" =~ ^[0-9]{1,5}$ &&
       "$dropped" =~ ^[0-9]{1,6}$ && "$total" =~ ^[0-9]{1,6}$ && "$observed" =~ ^[0-9]{10}$ &&
       -z "${extra:-}" ]] || return 1
    for current_id in "${wanted[@]}"; do
      if [[ "$id" = "$current_id" ]]; then
        [[ ! ${rows[$id]+yes} ]] || return 1
        rows[$id]="$row"
      fi
    done
  done < "$file"
  for ((i=0; i<4; i++)); do
    current_id="${wanted[i]}"; row="${rows[$current_id]:-}"
    [[ -n "$row" ]] || return 1
    IFS=$'\t' read -r ver id generation client old_scope old_host old_ip profile proto strategy fp treatment ack \
      quality sample progress stall dropped total observed extra <<< "$row"
    expected_treatment="${expected[i]}"
    [[ "$client" = "$wanted_client" && "$old_host" = "$host" && "$old_ip" = "$ip" && "$old_scope" = "$scope" &&
       "$treatment" = "$expected_treatment" && "$quality" = healthy &&
       "$sample" -ge 7500 && "$progress" -ge 5000 && "$stall" -lt 1000 ]] || return 1
    if [[ "$treatment" = applied ]]; then [[ "$ack" = confirmed ]] || return 1; fi
    if (( i == 0 )); then
      first_client="$client"; first_strategy="$strategy"; first_fp="$fp"; first_at="$observed"
    else
      [[ "$client" = "$first_client" && "$strategy" = "$first_strategy" && "$fp" = "$first_fp" ]] || return 1
      (( observed > last_at )) || return 1
    fi
    last_at="$observed"
  done
  (( first_at >= now - 1200 && last_at <= now + 5 && last_at - first_at <= 1200 )) || return 1
  printf '%s' "$ids|$host|$ip|$scope|$first_strategy|$first_fp" | sha256sum | awk '{print $1}'
}

# Keep one router-wide canary in flight so overlapping trials cannot race an
# exact Ramp exemption. Progress is compare-and-swap on the current attempt ID.
adaptive_browser_ramp_canary_session_file() {
  printf '%s/ramp-canary/session.tsv' "$(adaptive_browser_state_dir)"
}

adaptive_browser_ramp_canary_session_begin() {
  [[ $# = 13 ]] || return 2
  local session="$1" client="$2" client_ip="$3" scope="$4" host="$5" ip="$6"
  local strategy="$7" fp="$8" stage="$9" attempt="${10}" ids="${11}" lease="${12}" now="${13}"
  local dir file lock tmp row v old_session old_client old_ip old_scope old_host old_dst old_strategy old_fp old_stage old_attempt old_ids old_lease created expires extra
  [[ "$session" =~ ^[a-f0-9]{32}$ && "$client" =~ ^[a-f0-9]{32}$ &&
     "$client_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
     "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$strategy" =~ ^[1-9][0-9]{0,2}$ &&
     "$fp" =~ ^sha256:[a-f0-9]{64}$ && "$stage" = plain1 && "$attempt" =~ ^[a-f0-9]{32}$ &&
     "$ids" =~ ^[a-f0-9]{32}$ && "$lease" =~ ^[a-f0-9]{64}$ && "$now" =~ ^[0-9]{10}$ ]] || return 2
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 2; fi
  [[ "$(adaptive_browser_host_valid "$host" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "$host" ]] || return 2
  awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; a=$1+0; b=$2+0; c=$3+0; if(a==0 || a==10 || a==127 || a>=224 || (a==100 && b>=64 && b<=127) || (a==169 && b==254) || (a==172 && b>=16 && b<=31) || (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) || (a==198 && (b==18 || b==19 || (b==51 && c==100))) || (a==203 && b==0 && c==113)) exit 1; exit 0} {exit 1}' <<< "$ip" || return 2
  dir="$(adaptive_browser_state_dir)/ramp-canary"; file="$dir/session.tsv"; lock="$file.lock"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$dir" && ! -L "$file" && ! -L "$lock" ]] || return 1
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  (umask 077; mkdir "$lock") 2>/dev/null || return 4
  if [[ -r "$file" ]]; then
    IFS=$'\t' read -r v old_session old_client old_ip old_scope old_host old_dst old_strategy old_fp old_stage old_attempt old_ids old_lease created expires extra < "$file"
    [[ "$v" = 1 && "$old_session" =~ ^[a-f0-9]{32}$ && "$old_client" =~ ^[a-f0-9]{32}$ &&
       "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$old_scope" =~ ^(default|mark:[1-9][0-9]{0,4})$ &&
       "$old_host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ &&
       "$old_dst" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$old_strategy" =~ ^[1-9][0-9]{0,2}$ &&
       "$old_fp" =~ ^sha256:[a-f0-9]{64}$ && "$old_stage" =~ ^(plain1|plain2|ramp2|complete)$ &&
       ( "$old_attempt" = - || "$old_attempt" =~ ^[a-f0-9]{32}$ ) && "$old_ids" =~ ^[a-f0-9]{32}(,[a-f0-9]{32}){0,3}$ &&
       "$old_lease" =~ ^[a-f0-9]{64}$ && "$created" =~ ^[0-9]{10}$ && "$expires" =~ ^[0-9]{10}$ && -z "${extra:-}" ]] || {
         rmdir "$lock"; return 1;
       }
    if (( expires > now )); then rmdir "$lock"; return 4; fi
  fi
  tmp="$(mktemp "$dir/.session.XXXXXX")" || { rmdir "$lock"; return 1; }
  expires=$((now + 1200))
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session" "$client" "$client_ip" "$scope" "$host" "$ip" "$strategy" "$fp" "$stage" "$attempt" "$ids" "$lease" "$now" "$expires" > "$tmp" &&
    chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock"
}

adaptive_browser_ramp_canary_session_advance() {
  [[ $# = 6 ]] || return 2
  local session="$1" expected_attempt="$2" next_attempt="$3" treatment="$4" ack="$5" quality="$6"
  local dir file lock tmp row v id client client_ip scope host ip strategy fp stage attempt ids lease created expires extra next_stage now
  file="$(adaptive_browser_ramp_canary_session_file)"; dir="$(dirname "$file")"; lock="$file.lock"
  [[ "$session" =~ ^[a-f0-9]{32}$ && "$expected_attempt" =~ ^[a-f0-9]{32}$ &&
     ( "$next_attempt" = - || "$next_attempt" =~ ^[a-f0-9]{32}$ ) && "$treatment" =~ ^(applied|bypassed)$ &&
     "$ack" =~ ^(unknown|confirmed|pending)$ && "$quality" = healthy &&
     -f "$file" && ! -L "$file" && ! -L "$lock" && $(wc -c < "$file") -le 2048 ]] || return 2
  (umask 077; mkdir "$lock") 2>/dev/null || return 4
  row="$(cat "$file")"
  IFS=$'\t' read -r v id client client_ip scope host ip strategy fp stage attempt ids lease created expires extra <<< "$row"
  now="$(date +%s)"
  [[ "$v" = 1 && "$id" = "$session" && "$attempt" = "$expected_attempt" && -z "${extra:-}" &&
     "$expires" =~ ^[0-9]{10}$ ]] && (( now <= expires )) || { rmdir "$lock"; return 3; }
  case "$stage:$treatment:$ack" in
    plain1:bypassed:unknown|plain1:bypassed:pending) next_stage=plain2 ;;
    plain2:bypassed:unknown|plain2:bypassed:pending) next_stage=ramp2 ;;
    ramp2:applied:confirmed) next_stage=complete ;;
    *) rmdir "$lock"; return 2 ;;
  esac
  [[ ",${ids}," != *",${expected_attempt},"* &&
     ( "$next_attempt" = - || ",${ids}," != *",${next_attempt},"* ) &&
     ( "$next_stage" = complete && "$next_attempt" = - || "$next_stage" != complete && "$next_attempt" != - ) ]] || { rmdir "$lock"; return 2; }
  tmp="$(mktemp "$dir/.session.XXXXXX")" || { rmdir "$lock"; return 1; }
  ids="$ids,$expected_attempt"
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$client" "$client_ip" "$scope" "$host" "$ip" "$strategy" "$fp" "$next_stage" "$next_attempt" "$ids" "$lease" "$created" "$expires" > "$tmp" &&
    chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock"
  printf '%s' "$next_stage"
}

adaptive_browser_ramp_canary_session_clear() {
  [[ $# = 1 && "$1" =~ ^[a-f0-9]{32}$ ]] || return 2
  local file="$(adaptive_browser_ramp_canary_session_file)" lock row v id rest
  lock="$file.lock"
  [[ -f "$file" && ! -L "$file" && ! -L "$lock" ]] || return 1
  (umask 077; mkdir "$lock") 2>/dev/null || return 4
  IFS=$'\t' read -r v id rest < "$file"
  [[ "$v" = 1 && "$id" = "$1" ]] || { rmdir "$lock"; return 3; }
  rm -f "$file" && rmdir "$lock"
}

adaptive_browser_ramp_canary_cooldown_active() {
  [[ $# = 1 && "$1" =~ ^[0-9]{10}$ ]] || return 2
  local file="$(adaptive_browser_state_dir)/ramp-canary/cooldown.tsv" ver until extra
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$(dirname "$file")" && ! -L "$file" ]] || return 3
  [[ -f "$file" ]] || return 1
  (( $(wc -c < "$file") <= 64 )) || return 3
  IFS=$'\t' read -r ver until extra < "$file"
  [[ "$ver" = 1 && "$until" =~ ^[0-9]{10}$ && -z "${extra:-}" ]] || return 3
  (( until > $1 ))
}

adaptive_browser_ramp_canary_cooldown_set() {
  [[ $# = 2 && "$1" =~ ^[0-9]{10}$ && "$2" =~ ^[1-9][0-9]{1,4}$ ]] || return 2
  local now="$1" ttl="$2" dir="$(adaptive_browser_state_dir)/ramp-canary"
  local file="$dir/cooldown.tsv" lock="$dir/cooldown.lock" tmp until
  (( ttl <= 86400 )) || return 2
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$dir" && ! -L "$file" && ! -L "$lock" ]] || return 1
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  (umask 077; mkdir "$lock") 2>/dev/null || return 4
  local cooldown_rc=0
  adaptive_browser_ramp_canary_cooldown_active "$now" || cooldown_rc=$?
  case "$cooldown_rc" in 0) rmdir "$lock"; return 4 ;; 1) ;; *) rmdir "$lock"; return 1 ;; esac
  until=$((now + ttl))
  tmp="$(mktemp "$dir/.cooldown.XXXXXX")" || { rmdir "$lock"; return 1; }
  printf '1\t%s\n' "$until" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$file" || {
    rm -f "$tmp"; rmdir "$lock"; return 1;
  }
  rmdir "$lock"
}

adaptive_browser_ramp_canary_lease_apply() {
  [[ $# = 5 ]] || return 2
  local host="$1" ip="$2" scope="$3" proof="$4" expires="$5"
  local root="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}" file="${Z2R_ADAPTIVE_RAMP_EXEMPT_FILE:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/ramp-exempt.tsv}"
  local lock="${file}.lock" now tmp row ver old_host old_ip old_scope old_expires old_proof extra count=0
  [[ "$(adaptive_browser_host_valid "$host" && printf '%s' "$ADAPTIVE_BROWSER_HOST")" = "$host" &&
     "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
     "$proof" =~ ^[a-f0-9]{64}$ && "$expires" =~ ^[1-9][0-9]{9}$ ]] || return 2
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 2; fi
  awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; a=$1+0; b=$2+0; c=$3+0; if(a==0 || a==10 || a==127 || a>=224 || (a==100 && b>=64 && b<=127) || (a==169 && b==254) || (a==172 && b>=16 && b<=31) || (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) || (a==198 && (b==18 || b==19 || (b==51 && c==100))) || (a==203 && b==0 && c==113)) exit 1; exit 0} {exit 1}' <<< "$ip" || return 2
  now="$(date +%s)" || return 1
  (( expires > now && expires <= now + 900 )) || return 2
  [[ ! -L "$root" && ! -L "$file" && ! -L "$lock" ]] || return 1
  mkdir -p "$root" || return 1
  (umask 077; mkdir "$lock") 2>/dev/null || return 4
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || { rmdir "$lock"; return 1; }
  if [[ -r "$file" ]]; then
    [[ $(wc -c < "$file") -le 16384 ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    while IFS= read -r row || [[ -n "$row" ]]; do
      IFS=$'\t' read -r ver old_host old_ip old_scope old_expires old_proof extra <<< "$row"
      [[ "$ver" = 1 && "$old_host" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ &&
         "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
         ( "$old_scope" = default || "$old_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
         "$old_expires" =~ ^[1-9][0-9]{9}$ && "$old_proof" =~ ^[a-f0-9]{64}$ && -z "${extra:-}" ]] || {
           rm -f "$tmp"; rmdir "$lock"; return 1;
         }
      (( old_expires > now )) || continue
      if [[ "$old_host" = "$host" && "$old_ip" = "$ip" && "$old_scope" = "$scope" ]]; then
        rm -f "$tmp"; rmdir "$lock"
        [[ "$old_proof" = "$proof" ]] && return 3 || return 4
      fi
      count=$((count + 1)); (( count < 128 )) || { rm -f "$tmp"; rmdir "$lock"; return 1; }
      printf '%s\n' "$row" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    done < "$file"
  fi
  printf '1\t%s\t%s\t%s\t%s\t%s\n' "$host" "$ip" "$scope" "$expires" "$proof" >> "$tmp" || {
    rm -f "$tmp"; rmdir "$lock"; return 1;
  }
  chmod 644 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock" || return 1
}

adaptive_browser_ramp_canary_lease_revoke() {
  [[ $# = 4 ]] || return 2
  local host="$1" ip="$2" scope="$3" proof="$4"
  local root="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}" file="${Z2R_ADAPTIVE_RAMP_EXEMPT_FILE:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/ramp-exempt.tsv}"
  local lock="${file}.lock" now tmp row ver old_host old_ip old_scope old_expires old_proof extra count=0 found=0
  [[ "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
     "$proof" =~ ^[a-f0-9]{64}$ ]] || return 2
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 2; fi
  awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; a=$1+0; b=$2+0; c=$3+0; if(a==0 || a==10 || a==127 || a>=224 || (a==100 && b>=64 && b<=127) || (a==169 && b==254) || (a==172 && b>=16 && b<=31) || (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) || (a==198 && (b==18 || b==19 || (b==51 && c==100))) || (a==203 && b==0 && c==113)) exit 1; exit 0} {exit 1}' <<< "$ip" || return 2
  [[ ! -L "$root" && ! -L "$file" && ! -L "$lock" && -f "$file" && -r "$file" ]] || return 1
  now="$(date +%s)" || return 1
  (umask 077; mkdir "$lock") 2>/dev/null || return 4
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || { rmdir "$lock"; return 1; }
  [[ $(wc -c < "$file") -le 16384 ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  while IFS= read -r row || [[ -n "$row" ]]; do
    IFS=$'\t' read -r ver old_host old_ip old_scope old_expires old_proof extra <<< "$row"
    [[ "$ver" = 1 && "$old_host" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ &&
       "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
       ( "$old_scope" = default || "$old_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
       "$old_expires" =~ ^[1-9][0-9]{9}$ && "$old_proof" =~ ^[a-f0-9]{64}$ && -z "${extra:-}" ]] || {
         rm -f "$tmp"; rmdir "$lock"; return 1;
       }
    if [[ "$old_host" = "$host" && "$old_ip" = "$ip" && "$old_scope" = "$scope" ]]; then
      [[ "$old_proof" = "$proof" ]] || { rm -f "$tmp"; rmdir "$lock"; return 4; }
      found=1
      continue
    fi
    (( old_expires > now )) || continue
    count=$((count + 1)); (( count < 128 )) || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    printf '%s\n' "$row" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  done < "$file"
  (( found )) || { rm -f "$tmp"; rmdir "$lock"; return 3; }
  chmod 644 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock" || return 1
}
