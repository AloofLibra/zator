#!/usr/bin/env bash
# Narrow browser-feedback API. This credential is independent of adaptive.cgi.
set -u
ROOT="${ZATOR_ROOT:-/opt/zator}"
MAX_BODY=2048
STATE_DIR="${Z2R_ADAPTIVE_BROWSER_DIR:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/browser}"

origin="${HTTP_ORIGIN:-}"
origin_ok() { [[ "$1" =~ ^chrome-extension://[a-p]{32}$ ]]; }
headers() {
  printf 'Cache-Control: no-store\r\nVary: Origin\r\nContent-Type: application/json; charset=utf-8\r\n'
  if origin_ok "$origin"; then
    # OpenWrt uhttpd only exports a fixed allowlist of request headers to CGI;
    # Chromium's preflight headers are dropped. Answer PNA preflight for the
    # exact extension origin without depending on those unavailable variables.
    printf 'Access-Control-Allow-Origin: %s\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Max-Age: 300\r\nAccess-Control-Allow-Private-Network: true\r\n' "$origin"
  fi
}
send() { local status="$1" body="$2"; printf 'Status: %s\r\n' "$status"; headers; printf '\r\n%s\n' "$body"; exit 0; }
fail() { send "$1" "{\"schema_version\":1,\"error\":\"$2\"}"; }

if [[ "${REQUEST_METHOD:-}" = OPTIONS ]]; then
  origin_ok "$origin" || fail '403 Forbidden' 'extension origin required'
  send '204 No Content' ''
fi
[[ "${REQUEST_METHOD:-}" = POST && "${CONTENT_TYPE%%;*}" = application/x-www-form-urlencoded ]] || fail '405 Method Not Allowed' 'POST form data required'
origin_ok "$origin" || fail '403 Forbidden' 'extension origin required'
length="${CONTENT_LENGTH:-}"
[[ "$length" =~ ^[0-9]{1,4}$ ]] && (( 10#$length > 0 && 10#$length <= MAX_BODY )) || fail '413 Payload Too Large' 'invalid request size'
body="$(head -c "$((10#$length))")"
[[ ${#body} -le MAX_BODY && "${#body}" -eq "$((10#$length))" ]] || fail '400 Bad Request' 'truncated request body'

# Extension messages use only this ASCII field alphabet. Reject escapes instead
# of invoking an unsafe shell decoder; all accepted values are plain identifiers.
declare -A f=()
IFS='&' read -r -a pairs <<< "$body"
for pair in "${pairs[@]}"; do
  [[ "$pair" = *=* && "$pair" != *%* && "$pair" != *+* ]] || fail '400 Bad Request' 'invalid form encoding'
  key="${pair%%=*}"; value="${pair#*=}"
  [[ "$key" =~ ^[a-z_]+$ && "$value" =~ ^[a-zA-Z0-9_.:-]*$ ]] || fail '400 Bad Request' 'invalid form field'
  case "$key" in schema_version|action|browser_event_id|trigger|request_class|hostname|method|failure_class|failure_transport|failure_count|observed_at|attempt_id|result|browser_ip|browser_protocol|media_quality|media_sample_ms|media_progress_ms|media_stall_ms|media_dropped_frames|media_total_frames|ramp_canary_opt_in) ;;
    *) fail '400 Bad Request' 'unknown form field' ;; esac
  [[ -n "$key" && ! ${f[$key]+present} ]] || fail '400 Bad Request' 'duplicate form field'
  f[$key]="$value"
done
[[ "${f[schema_version]:-}" = 1 && ${#f[@]} -ge 2 ]] || fail '400 Bad Request' 'unsupported schema'

provided="${HTTP_AUTHORIZATION:-}"
[[ "$provided" = 'Bearer '* ]] || fail '401 Unauthorized' 'browser token required'
provided="${provided#Bearer }"
. "$ROOT/z2r_lib/config.sh" 2>/dev/null || fail '503 Service Unavailable' 'configuration helpers unavailable'
. "$ROOT/z2r_lib/orchestra_state.sh" 2>/dev/null || fail '503 Service Unavailable' 'scope helpers unavailable'
. "$ROOT/z2r_lib/adaptive_browser.sh" 2>/dev/null || fail '503 Service Unavailable' 'browser runtime unavailable'
. "$ROOT/z2r_lib/adaptive_rules.sh" 2>/dev/null || fail '503 Service Unavailable' 'adaptive strategy catalogue unavailable'
. "$ROOT/z2r_lib/supersweep_probe.sh" 2>/dev/null || fail '503 Service Unavailable' 'strategy plan builder unavailable'
adaptive_browser_client_auth "$provided" "${REMOTE_ADDR:-}" "$origin" || fail '401 Unauthorized' 'invalid, expired, or out-of-scope browser token'
client_id="$ADAPTIVE_BROWSER_CLIENT_ID"; scope="$ADAPTIVE_BROWSER_CLIENT_SCOPE"
adaptive_browser_presence_touch "$client_id" >/dev/null 2>&1 || :

browser_start_trial() {
  local target="$1" trigger="$2" client_id="$3" client_ip="$4" scope="$5"
  local fixed_strategy="${6:-}" fixed_fingerprint="${7:-}" exclude_strategy="${8:-}"
  local host ip profile proto seen nfqws orch_dir now expires generation raw_id id
  local candidate_dir args_file candidate fingerprint recipe config_value flow_dir flow_user flow_uid flow_gid flow_owner trial_kind=standard
  IFS=$'\t' read -r host ip profile proto target_scope seen <<< "$target"
  [[ "$target_scope" = "$scope" && "$client_ip" = "$REMOTE_ADDR" ]] || return 2
  adaptive_browser_rotation_enabled || return 5
  [[ ! -d "${Z2R_ADAPTIVE_LOCK_DIR:-/tmp/z2r-supersweep.lock}" ]] || return 4
  [[ "$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" NFQWS2_ENABLE 2>/dev/null | tr -d '"\047')" = 1 ]] || return 5
  grep -q '^#Z2R_AUTO_MODE=1$' "${ZAPRET2_ROOT:-/opt/zapret2}/config" 2>/dev/null || return 8
  case "$proto" in
    tls) recipe=tls-http1-v1 ;;
    googlevideo-tcp) recipe=googlevideo-tcp-media-v1 ;;
    quic) recipe=googlevideo-quic-h3-media-v1 ;;
    *) return 3 ;;
  esac
  ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
  ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
  adaptive_browser_profile_lock_check "$profile" "$scope" "$ORCH_DIR"
  case $? in 1) ;; *) return 6 ;; esac
  nfqws="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
  [[ -x "$nfqws" ]] || return 3
  CONFIG_FILE="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  flow_user="$(config_get_var "$CONFIG_FILE" WS_USER 2>/dev/null | tr -d '"\047')"
  [[ -n "$flow_user" ]] || flow_user=nobody
  [[ "$flow_user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || return 3
  flow_uid="$(id -u "$flow_user" 2>/dev/null)"; flow_gid="$(id -g "$flow_user" 2>/dev/null)"
  [[ "$flow_uid" =~ ^[0-9]+$ && "$flow_gid" =~ ^[0-9]+$ ]] || return 3
  flow_dir="$(adaptive_browser_flow_dir)"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$flow_dir" ]] || return 1
  mkdir -p "$flow_dir" || return 1
  flow_owner="$(stat -c %u "$flow_dir" 2>/dev/null)"
  if [[ "$flow_owner" != "$flow_uid" ]]; then
    chown "$flow_uid:$flow_gid" "$flow_dir" && chmod 700 "$flow_dir" || return 1
  elif [[ "$(id -u)" = 0 ]]; then
    chmod 700 "$flow_dir" || return 1
  fi
  raw_id="$(adaptive_browser_random_hex 16)"
  [[ "$raw_id" =~ ^[a-f0-9]{32}$ ]] || return 1
  id="$raw_id"; now="$(date +%s)"; expires=$((now + 180))
  if [[ "$trigger" = ramp_canary ]]; then expires=$((now + 300)); trial_kind=ramp_canary; fi
  raw_id="$(adaptive_browser_random_hex 4)"
  [[ "$raw_id" =~ ^[a-f0-9]{8}$ ]] || return 1
  generation=$((16#$raw_id % 999999999 + 1))
  candidate_dir="$(adaptive_browser_state_dir)/candidates/$id"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$(dirname "$candidate_dir")" && ! -e "$candidate_dir" ]] || return 1
  mkdir -p "$candidate_dir" || return 1
  Z2R_SUPERSWEEP_DIR="$candidate_dir"; export Z2R_SUPERSWEEP_DIR
  for config_value in FWTYPE DESYNC_MARK DESYNC_MARK_POSTNAT FILTER_MARK CLIENT_SCOPE_MARK_MASK POSTNAT POSTNAT_ALL ZAPRET_NFT_TABLE; do
    value="$(config_get_var "$CONFIG_FILE" "$config_value" 2>/dev/null | tr -d '"\047')" || { rm -rf "$candidate_dir"; return 3; }
    printf -v "$config_value" '%s' "$value"
  done
  export FWTYPE DESYNC_MARK DESYNC_MARK_POSTNAT FILTER_MARK CLIENT_SCOPE_MARK_MASK POSTNAT POSTNAT_ALL ZAPRET_NFT_TABLE
  if ! supersweep_probe_config "$profile" "$CONFIG_FILE" standard "$ip" "$recipe"; then
    rm -rf "$candidate_dir"; return 3
  fi
  args_file="$candidate_dir/probe/nfqws2.args"
  if [[ -n "$fixed_strategy" || -n "$fixed_fingerprint" ]]; then
    [[ "$trigger" = ramp_canary && "$fixed_strategy" =~ ^[1-9][0-9]{0,2}$ && "$fixed_fingerprint" =~ ^sha256:[a-f0-9]{64}$ ]] || {
      rm -rf "$candidate_dir"; return 3;
    }
    candidate_fingerprint="$(adaptive_strategy_fingerprint "$profile" "$fixed_strategy" "$args_file" "$nfqws" standard "$recipe")" || {
      rm -rf "$candidate_dir"; return 3;
    }
    [[ "$candidate_fingerprint" = "$fixed_fingerprint" ]] || { rm -rf "$candidate_dir"; return 3; }
    candidate="$fixed_strategy"$'\t'"$fixed_fingerprint"
  else
    candidate="$(adaptive_browser_candidate_select "$host" "$ip" "$profile" "$proto" "$scope" "$args_file" "$nfqws" "$ORCH_DIR" "$client_id" "$exclude_strategy")"
    if [[ $? -ne 0 || -z "$candidate" ]]; then rm -rf "$candidate_dir"; return 3; fi
  fi
  IFS=$'\t' read -r strategy fingerprint <<< "$candidate"
  rm -rf "$candidate_dir" || return 1
  adaptive_browser_attempt_gc "$now" "$id"
  case $? in 0) ;; 3) return 4 ;; *) return 1 ;; esac
  if ! adaptive_browser_attempt_write "$id" "$client_id" "$client_ip" "$scope" "$host" "$ip" "$profile" "$proto" "$trigger" QUEUED "$strategy" "$fingerprint" "$now" "$expires" "$generation"; then
    adaptive_browser_attempt_reservation_release "$id" >/dev/null 2>&1 || :
    return 1
  fi
  adaptive_browser_attempt_reservation_release "$id" >/dev/null 2>&1 || :
  if ! adaptive_browser_trial_add "$id" "$generation" "$client_id" "$client_ip" "$scope" "$host" "$ip" "$profile" "$proto" "$strategy" "$fingerprint" "$now" "$expires" "$trial_kind"; then
    adaptive_browser_attempt_transition "$id" QUEUED TARGET_NOT_MANAGED >/dev/null 2>&1 || :
    return 7
  fi
  adaptive_browser_attempt_transition "$id" QUEUED WAIT_NEW_FLOW || {
    adaptive_browser_trial_remove "$id" "$generation" || :
    return 1
  }
  local retry_hint=reload_if_safe
  [[ "$trigger" != ramp_canary ]] || retry_hint=observe_natural_flow
  printf '{"schema_version":1,"status":"WAIT_NEW_FLOW","state":"WAIT_NEW_FLOW","attempt_id":"%s","candidate":{"profile_id":%s,"strategy":%s,"protocol":"%s","treatment_variant":"standard"},"scope":"%s","expires_at":%s,"retry_hint":"%s"}' \
    "$id" "$profile" "$strategy" "$proto" "$scope" "$expires" "$retry_hint"
}

browser_learning_status() {
  local events now rows row ver status host ip profile proto row_scope seen selected_strategy extra host_key strategy strategy_source strategy_json lock lock_proto stamp nfqws
  local targets='[' first=1 count=0 ranking=false stats=false ramp=false quic=false autorotation=false
  events="${Z2R_ADAPTIVE_EVENTS_FILE:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/events.tsv}"
  now="$(date +%s)" || now=0
  ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
  ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
  nfqws="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
  grep -q '^#Z2R_AUTO_MODE=1$' "${ZAPRET2_ROOT:-/opt/zapret2}/config" 2>/dev/null && autorotation=true
  stamp=''
  if [[ -x "$nfqws" && -r "${ZAPRET2_ROOT:-/opt/zapret2}/config" ]]; then
    stamp="$(adaptive_rules_runtime_stamp "${ZAPRET2_ROOT:-/opt/zapret2}/config" "$nfqws" "$ORCH_DIR" 2>/dev/null || true)"
  fi
  adaptive_browser_rankings_opted_in && ranking=true
  adaptive_browser_stats_opted_in && stats=true
  [[ "$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')" = 1 ]] && ramp=true
  [[ "$(config_profile_max_strategy 5 "${ZAPRET2_ROOT:-/opt/zapret2}/config" 2>/dev/null)" =~ ^[1-9][0-9]{0,2}$ ]] && quic=true
  if [[ -r "$events" && ! -L "$events" && $(wc -c < "$events") -le 32768 ]]; then
    rows="$(awk -F '\t' -v now="$now" -v scope="$scope" '
      function ipok(ip, a,n) { if (split(ip,a,".")!=4) return 0; for(n=1;n<=4;n++) if(a[n]!~/^(0|[1-9][0-9]{0,2})$/ || a[n]>255) return 0; return 1 }
       (NF==8 || NF==9 || NF==10) && $1==1 && $7==scope && $8~/^[0-9]{10}$/ && $8>=now-300 && $8<=now+10 &&
        $3~/^([a-z0-9][a-z0-9-]*\.)+[a-z0-9][a-z0-9-]*$/ && length($3)<=253 && ipok($4) &&
        (($6=="tls" && $5~/^[1-4]$/) || ($6=="googlevideo-tcp" && $5==2 && $3~/\.googlevideo\.com$/) || ($6=="quic" && $5==5)) &&
        ($2=="seen" || $2=="needs_verify" || $2=="suspected_failure" || $2=="active_rule_degraded" || $2~/^router_trial_[1-9][0-9]*$/ || $2=="router_exhausted") {
          key=$3 SUBSEP $5 SUBSEP $6
          if (!(key in newest) || $8>newest[key]) { newest[key]=$8; value[key]=$0 }
        }
      END { for (key in value) print value[key] }
    ' "$events" | sort -t "$(printf '\t')" -k8,8nr | head -n 24)"
    while IFS=$'\t' read -r ver status host ip profile proto row_scope seen selected_strategy strategy_count extra; do
      [[ "$ver" = 1 && "$row_scope" = "$scope" && "$host" =~ ^([a-z0-9][a-z0-9-]*\.)+[a-z0-9][a-z0-9-]*$ && "$profile" =~ ^[1-5]$ ]] || continue
      if [[ "$profile" = 2 && "$host" =~ \.googlevideo\.com$ && "$proto" = tls ]]; then proto=googlevideo-tcp; fi
      (( count < 24 )) || break
      count=$((count + 1)); host_key="$host"
      case "$proto" in googlevideo-tcp) lock_proto=tls ;; quic) lock_proto=udp ;; *) lock_proto=tls ;; esac
      ORCH_ACTIVE_SCOPE="$scope"
      lock="$(profile_state_get "$profile" "$lock_proto" 2>/dev/null || printf auto)"
      if [[ "$lock" = auto && "$scope" != default ]]; then
        ORCH_ACTIVE_SCOPE=default
        lock="$(profile_state_get "$profile" "$lock_proto" 2>/dev/null || printf auto)"
      fi
      if [[ "$lock" =~ ^[0-9]{1,3}$ ]]; then
        strategy="$lock"; strategy_source=profile_lock
      else
        strategy=''; strategy_source=profile_auto
        if [[ -r "$(adaptive_browser_state_dir)/trials.tsv" && ! -L "$(adaptive_browser_state_dir)/trials.tsv" ]]; then
          strategy="$(awk -F '\t' -v now="$now" -v scope="$scope" -v host="$host" -v profile="$profile" -v proto="$proto" '
            NF==14 && $1==1 && $6==scope && $9==profile && $10==proto && $11~/^[1-9][0-9]{0,2}$/ && $14~/^[0-9]{10}$/ && $14>now &&
              ($7==host || (profile==2 && proto=="googlevideo-tcp" && $7~/\.googlevideo\.com$/ && host~/\.googlevideo\.com$/) || (profile==5 && proto=="quic" && $7==host)) { if ($13>created) {created=$13; strategy=$11} }
            END {print strategy}
          ' "$(adaptive_browser_state_dir)/trials.tsv")"
          [[ -z "$strategy" ]] || strategy_source=active_trial
        fi
        if [[ -z "$strategy" && -n "$stamp" ]]; then
          local rule
          rule="$(adaptive_rule_lookup_local "$host" "$ip" "$profile" "$proto" "$scope" "$stamp" 2>/dev/null || true)"
          if [[ -n "$rule" ]]; then IFS=$'\t' read -r strategy _ _ _ _ <<< "$rule"; strategy_source=verified_rule; fi
          if [[ -z "$strategy" && "$proto" = googlevideo-tcp ]]; then
            rule="$(adaptive_rule_lookup_local googlevideo.com "$ip" "$profile" "$proto" "$scope" "$stamp" 2>/dev/null || true)"
            if [[ -n "$rule" ]]; then IFS=$'\t' read -r strategy _ _ _ _ <<< "$rule"; strategy_source=googlevideo_family_baseline; fi
          fi
        fi
        if [[ -z "$strategy" && "$status" =~ ^router_trial_([1-9][0-9]{0,2})$ ]]; then
          strategy="${BASH_REMATCH[1]}"; strategy_source=router_auto_trial
        fi
        [[ -n "$strategy" ]] || strategy="${selected_strategy:-}"
      fi
      strategy_json=null
      [[ "$strategy" =~ ^[0-9]{1,3}$ ]] && strategy_json="$strategy"
      [[ "$first" = 1 ]] || targets+=','
      first=0
      targets+="{\"hostname\":\"$host_key\",\"profile_id\":$profile,\"protocol\":\"$proto\",\"observed_at\":$seen,\"strategy_number\":$strategy_json,\"strategy_source\":\"$strategy_source\",\"learning_state\":\"$status\"}"
    done <<< "$rows"
  fi
  targets+=']'
  send '200 OK' "{\"schema_version\":1,\"status\":\"paired\",\"mode\":\"$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null | tr -cd 'A-Z_')\",\"scope\":\"$scope\",\"autorotation_enabled\":$autorotation,\"ranking_opt_in\":$ranking,\"stats_opt_in\":$stats,\"ramp_configured\":$ramp,\"quic_profile_available\":$quic,\"targets\":$targets}"
}

browser_confirm_flow() {
  local row ver flow_id flow_generation flow_client flow_scope flow_host flow_ip flow_profile flow_proto flow_strategy fingerprint syn_at selected_at ramp_treatment ramp_ack_evidence extra now
  row="$(adaptive_browser_flow_read "$attempt_id" "$generation" 2>/dev/null)" || return 1
  IFS=$'\t' read -r ver flow_id flow_generation flow_client flow_scope flow_host flow_ip flow_profile flow_proto flow_strategy fingerprint syn_at selected_at ramp_treatment ramp_ack_evidence extra <<< "$row"
  now="$(date +%s)"
  [[ "$ver" = 1 && "$flow_id" = "$attempt_id" && "$flow_generation" = "$generation" && "$flow_client" = "$client_id" && "$flow_scope" = "$attempt_scope" &&
     ( ( "$flow_host" = "$host" && "$flow_ip" = "$ip" ) ||
       ( "$proto" = googlevideo-tcp && "$profile" = 2 && "$flow_proto" = googlevideo-tcp && "$flow_profile" = 2 &&
         "$flow_host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ && "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ) ) &&
     "$flow_profile" = "$profile" && "$flow_proto" = "$proto" &&
     "$flow_strategy" = "$strategy" && "$fingerprint" = "$attempt_fingerprint" &&
     "$syn_at" -ge "$created" && "$selected_at" -ge "$syn_at" && "$selected_at" -le "$expires" && "$now" -le "$expires" && -z "${extra:-}" ]] || return 2
  BROWSER_FLOW_RAMP_TREATMENT="${ramp_treatment:-unknown}"
  if [[ "$state" = WAIT_NEW_FLOW ]]; then
    adaptive_browser_attempt_transition "$attempt_id" WAIT_NEW_FLOW FLOW_CONFIRMED || return 3
    state=FLOW_CONFIRMED
  elif [[ "$state" != FLOW_CONFIRMED && "$state" != WAIT_BROWSER_RESULT && "$state" != PROVISIONAL_SUCCESS ]]; then
    return 3
  fi
}

browser_ramp_canary_target_allowed() {
  local host="$1" ip="$2" target_scope="$3" now mode marker ramp_state config ramp_enable ramp_ipset target_file
  local row ver row_host row_ip row_scope seen provenance group state dns_expiry media extra exact=0
  [[ "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
     ( "$target_scope" = default || "$target_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) ]] || return 1
  if [[ "$target_scope" = mark:* ]]; then (( ${target_scope#mark:} <= 65535 )) || return 1; fi
  awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; a=$1+0; b=$2+0; c=$3+0; if(a==0 || a==10 || a==127 || a>=224 || (a==100 && b>=64 && b<=127) || (a==169 && b==254) || (a==172 && b>=16 && b<=31) || (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) || (a==198 && (b==18 || b==19 || (b==51 && c==100))) || (a==203 && b==0 && c==113)) exit 1; exit 0} {exit 1}' <<< "$ip" || return 1
  mode="$ROOT/extra_strats/cache/adaptive/mode"
  marker="$ROOT/extra_strats/cache/adaptive/apply-default-scope"
  ramp_state="$ROOT/extra_strats/cache/adaptive/ramp-pool"
  adaptive_browser_rotation_enabled && [[ "$(cat "$marker" 2>/dev/null)" = 1 &&
     -f "$ramp_state" && ! -L "$ramp_state" && $(wc -c < "$ramp_state") -le 256 ]] || return 1
  awk -F '\t' 'NR==1 && ((($1==1 && $2=="preexisting" && $3=="manual_unverified" && NF==3) || ($1==1 && $2=="managed" && $3=="manual_unverified" && $4~/^[a-f0-9]{64}$/ && NF==4) || ($1==1 && $2=="managed" && $3=="proof_verified" && $4~/^[a-f0-9]{64}$/ && $5~/^[a-f0-9]{64}$/ && NF==5))) {ok=1} END {exit !ok}' "$ramp_state" || return 1
  [[ ! -d "${Z2R_ADAPTIVE_NDM_ROOT:-/opt/etc/ndm}" ]] || return 1
  config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  ramp_enable="$(config_get_var "$config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')"
  ramp_ipset="$(config_get_var "$config" Z2R_WSSIZE_RAMP_IPSET 2>/dev/null | tr -d '"\047')"
  case "$ramp_ipset" in
    /opt/zator/*) ramp_ipset="$ROOT/${ramp_ipset#/opt/zator/}" ;;
    /opt/zapret2/*) ramp_ipset="${ZAPRET2_ROOT:-/opt/zapret2}/${ramp_ipset#/opt/zapret2/}" ;;
  esac
  [[ "$ramp_enable" = 1 && -r "$ramp_ipset" && ! -L "$ramp_ipset" ]] && grep -Fqx -- "$ip" "$ramp_ipset" || return 1
  now="$(date +%s)" || return 1
  target_file="${Z2R_ADAPTIVE_RAMP_TARGETS_FILE:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/ramp-targets.tsv}"
  [[ -r "$target_file" && ! -L "$target_file" ]] || return 1
  while IFS=$'\t' read -r ver row_host row_ip row_scope seen provenance group state dns_expiry media extra || [[ -n "$ver$row_host$row_ip" ]]; do
    [[ "$ver" = 1 && "$provenance" = tls-observed && "$seen" =~ ^[0-9]{1,10}$ ]] || continue
    (( seen >= now - 86400 && seen <= now + 60 )) || continue
    [[ "$dns_expiry" =~ ^[0-9]{1,10}$ ]] && (( dns_expiry == 0 || dns_expiry > now )) || continue
    if [[ "$row_ip" = "$ip" && "$row_host" != "$host" ]] || [[ "$row_host" = "$host" && "$row_ip" != "$ip" ]] ||
       [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" = "$target_scope" && "$state" = conflict ]]; then return 1; fi
    [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" = "$target_scope" ]] && exact=1
  done < "$target_file"
  (( exact ))
}

browser_ramp_canary_abort() {
  local attempt="$1" file row ver session owner client_ip attempt_scope host ip strategy fp stage current ids lease created expires extra
  file="$(adaptive_browser_ramp_canary_session_file)"
  [[ -r "$file" && ! -L "$file" ]] || return 1
  IFS=$'\t' read -r ver session owner client_ip attempt_scope host ip strategy fp stage current ids lease created expires extra < "$file"
  [[ "$ver" = 1 && "$owner" = "$client_id" && "$attempt_scope" = "$scope" &&
     ( "$attempt" = - || "$current" = "$attempt" ) && -z "${extra:-}" ]] || return 1
  adaptive_browser_ramp_canary_lease_revoke "$host" "$ip" "$attempt_scope" "$lease" >/dev/null 2>&1 || :
  adaptive_browser_ramp_canary_session_clear "$session"
}

browser_ramp_canary_start_next() {
  local host="$1" ip="$2" strategy="$3" fp="$4" target
  target="$(printf '%s\t%s\t2\tgooglevideo-tcp\t%s\t%s' "$host" "$ip" "$scope" "$(date +%s)")"
  browser_start_trial "$target" ramp_canary "$client_id" "${REMOTE_ADDR:-}" "$scope" "$strategy" "$fp"
}

browser_ramp_canary_start() {
  local attempt="$1" host="$2" ip="$3" strategy="$4" fp="$5" now session lease expires next_json next_attempt attempt_row generation
  browser_ramp_canary_target_allowed "$host" "$ip" "$scope" || return 1
  now="$(date +%s)"
  cooldown_rc=0
  adaptive_browser_ramp_canary_cooldown_active "$now" || cooldown_rc=$?
  [[ "$cooldown_rc" = 1 ]] || return 1
  session="$(adaptive_browser_random_hex 16)"
  [[ "$session" =~ ^[a-f0-9]{32}$ ]] || return 1
  lease="$(printf '%s|%s|%s|%s|%s' "$session" "$client_id" "$host" "$ip" "$scope" | sha256sum | awk '{print $1}')"
  [[ "$lease" =~ ^[a-f0-9]{64}$ ]] || return 1
  expires=$((now + 900))
  adaptive_browser_ramp_canary_lease_apply "$host" "$ip" "$scope" "$lease" "$expires" || return 1
  next_json="$(browser_ramp_canary_start_next "$host" "$ip" "$strategy" "$fp")" || {
    adaptive_browser_ramp_canary_lease_revoke "$host" "$ip" "$scope" "$lease" >/dev/null 2>&1 || :
    return 1
  }
  next_attempt="$(printf '%s' "$next_json" | sed -n 's/.*"attempt_id":"\([a-f0-9]\{32\}\)".*/\1/p')"
  [[ "$next_attempt" =~ ^[a-f0-9]{32}$ ]] || {
    adaptive_browser_ramp_canary_lease_revoke "$host" "$ip" "$scope" "$lease" >/dev/null 2>&1 || :
    return 1
  }
  if ! adaptive_browser_ramp_canary_session_begin "$session" "$client_id" "${REMOTE_ADDR:-}" "$scope" "$host" "$ip" \
      "$strategy" "$fp" plain1 "$next_attempt" "$attempt" "$lease" "$now"; then
    attempt_row="$(adaptive_browser_attempt_read "$next_attempt" 2>/dev/null)" || attempt_row=""
    [[ -z "$attempt_row" ]] || {
      adaptive_browser_attempt_transition "$next_attempt" WAIT_NEW_FLOW CANCELLED >/dev/null 2>&1 || :
      IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ generation _ <<< "$attempt_row"
      [[ "$generation" =~ ^[1-9][0-9]{0,8}$ ]] && adaptive_browser_trial_remove "$next_attempt" "$generation" >/dev/null 2>&1 || :
    }
    adaptive_browser_ramp_canary_lease_revoke "$host" "$ip" "$scope" "$lease" >/dev/null 2>&1 || :
    return 1
  fi
  if ! adaptive_browser_ramp_canary_cooldown_set "$now" 3600; then
    browser_ramp_canary_abort "$next_attempt" >/dev/null 2>&1 || :
    adaptive_browser_attempt_transition "$next_attempt" WAIT_NEW_FLOW CANCELLED >/dev/null 2>&1 || :
    attempt_row="$(adaptive_browser_attempt_read "$next_attempt" 2>/dev/null)" || attempt_row=""
    if [[ -n "$attempt_row" ]]; then
      IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ generation <<< "$attempt_row"
      [[ "$generation" =~ ^[1-9][0-9]{0,8}$ ]] && adaptive_browser_trial_remove "$next_attempt" "$generation" >/dev/null 2>&1 || :
    fi
    return 1
  fi
  BROWSER_RAMP_CANARY_RESPONSE="{\"ramp_canary\":\"plain1_armed\",\"next_attempt\":$next_json}"
}

browser_ramp_canary_handle_result() {
  local attempt="$1" state="$2" opted_in="$3" trigger="$4" flow_treatment="$5" flow_ack="$6" attempt_generation="$7"
  local evidence row ver id generation owner attempt_scope e_host e_ip e_profile e_proto e_strategy e_fp e_treatment e_ack quality sample progress stall dropped total observed extra
  local session_file session_owner session_ip session_scope session_host session_dst session_strategy session_fp stage current ids lease created expires
  local now next_json next_attempt next_stage proof final_expires lease_removed=0 session_row next_generation
  BROWSER_RAMP_CANARY_RESPONSE=""
  session_file="$(adaptive_browser_ramp_canary_session_file)"
  if [[ "$trigger" = ramp_canary ]]; then
    [[ "$state" != PROVISIONAL_SUCCESS ]] || return 0
    [[ "$opted_in" = 1 && "$state" = CONFIRMED_SUCCESS ]] || {
      browser_ramp_canary_abort "$attempt" || :
      BROWSER_RAMP_CANARY_RESPONSE='{"ramp_canary":"aborted"}'
      return 0
    }
    [[ -r "$session_file" && ! -L "$session_file" ]] || return 1
    IFS=$'\t' read -r ver session session_owner session_ip session_scope session_host session_dst session_strategy session_fp stage current ids lease created expires extra < "$session_file"
    [[ "$ver" = 1 && "$session_owner" = "$client_id" && "$session_ip" = "${REMOTE_ADDR:-}" &&
       "$session_scope" = "$scope" && "$current" = "$attempt" && "$session_host" = "$host" && "$session_dst" = "$ip" &&
       "$session_strategy" = "$strategy" && "$session_fp" = "$attempt_fingerprint" && -z "${extra:-}" ]] || {
      browser_ramp_canary_abort "$attempt" || :
      return 1
    }
  else
    [[ "$trigger" =~ ^(main_frame_network_failure|critical_resource_repeated_failure|user_fix)$ &&
       "$state" = CONFIRMED_SUCCESS && "$opted_in" = 1 && "$proto" = googlevideo-tcp && "$profile" = 2 &&
       "$flow_treatment" = applied && "$flow_ack" = confirmed ]] || return 1
    if [[ -r "$session_file" ]]; then
      IFS=$'\t' read -r ver session session_owner session_ip session_scope session_host session_dst session_strategy session_fp stage current ids lease created expires extra < "$session_file"
      [[ "$expires" =~ ^[0-9]{10}$ ]] || return 1
      now="$(date +%s)"
      (( expires <= now )) || return 1
      adaptive_browser_ramp_canary_lease_revoke "$session_host" "$session_dst" "$session_scope" "$lease" >/dev/null 2>&1 || :
      adaptive_browser_ramp_canary_session_clear "$session" || return 1
    fi
  fi
  evidence="$(adaptive_browser_state_dir)/media-quality/evidence.tsv"
  [[ -r "$evidence" && ! -L "$evidence" && $(wc -c < "$evidence") -le 32768 ]] || {
    [[ "$trigger" != ramp_canary ]] || browser_ramp_canary_abort "$attempt" || :
    return 1
  }
  row="$(awk -F '\t' -v id="$attempt" -v gen="$attempt_generation" '$2==id && $3==gen {row=$0; n++} END {if(n==1) print row}' "$evidence")"
  [[ -n "$row" ]] || { [[ "$trigger" != ramp_canary ]] || browser_ramp_canary_abort "$attempt" || :; return 1; }
  IFS=$'\t' read -r ver id generation owner attempt_scope e_host e_ip e_profile e_proto e_strategy e_fp e_treatment e_ack quality sample progress stall dropped total observed extra <<< "$row"
  [[ "$ver" = 1 && "$owner" = "$client_id" && "$attempt_scope" = "$scope" && "$e_host" = "$host" &&
     "$e_ip" = "$ip" && "$e_profile" = 2 && "$e_proto" = googlevideo-tcp &&
     "$e_strategy" = "$strategy" && "$e_fp" = "$attempt_fingerprint" &&
     "$e_treatment" = "$flow_treatment" && "$e_ack" = "$flow_ack" ]] || {
    [[ "$trigger" != ramp_canary ]] || browser_ramp_canary_abort "$attempt" || :
    return 1
  }
  [[ "$quality" = healthy && "$sample" -ge 7500 && "$progress" -ge 5000 && "$stall" -lt 1000 && -z "${extra:-}" ]] || {
    [[ "$trigger" != ramp_canary ]] || browser_ramp_canary_abort "$attempt" || :
    return 1
  }
  if [[ "$trigger" != ramp_canary ]]; then
    browser_ramp_canary_target_allowed "$e_host" "$e_ip" "$scope" || return 1
    browser_ramp_canary_start "$attempt" "$e_host" "$e_ip" "$e_strategy" "$e_fp" || return 1
    return 0
  fi
  treatment="$e_treatment"; ack="$e_ack"
  browser_ramp_canary_target_allowed "$e_host" "$e_ip" "$scope" || { browser_ramp_canary_abort "$attempt" || :; return 1; }
  now="$(date +%s)"
  case "$stage" in
    plain1) next_stage=plain2 ;;
    plain2) next_stage=ramp2 ;;
    ramp2)
      [[ "$(adaptive_browser_ramp_canary_session_advance "$session" "$attempt" - "$treatment" "$ack" healthy)" = complete ]] || {
        browser_ramp_canary_abort "$attempt" || :; return 1;
      }
      session_row="$(cat "$session_file" 2>/dev/null)" || session_row=""
      IFS=$'\t' read -r ver session session_owner session_ip session_scope session_host session_dst session_strategy session_fp stage current ids lease created expires extra <<< "$session_row"
      adaptive_browser_ramp_canary_lease_revoke "$e_host" "$e_ip" "$scope" "$lease" >/dev/null 2>&1 || :
      browser_ramp_canary_target_allowed "$e_host" "$e_ip" "$scope" || { adaptive_browser_ramp_canary_session_clear "$session" || :; return 1; }
      proof="$(adaptive_browser_ramp_canary_validate "$e_host" "$e_ip" "$scope" "$ids" "$now" "$client_id")" || {
        adaptive_browser_ramp_canary_session_clear "$session" || :; return 1;
      }
      final_expires=$((now + 900))
      if adaptive_browser_ramp_canary_lease_apply "$e_host" "$e_ip" "$scope" "$proof" "$final_expires"; then
        BROWSER_RAMP_CANARY_RESPONSE="{\"ramp_canary\":\"short_lease_applied\",\"expires_at\":$final_expires}"
      else
        BROWSER_RAMP_CANARY_RESPONSE='{"ramp_canary":"evidence_accepted_no_lease"}'
      fi
      adaptive_browser_ramp_canary_session_clear "$session" || :
      return 0
      ;;
    *) browser_ramp_canary_abort "$attempt" || :; return 1 ;;
  esac
  [[ "$stage" != plain2 ]] || {
    adaptive_browser_ramp_canary_lease_revoke "$e_host" "$e_ip" "$scope" "$lease" >/dev/null 2>&1 || :
    lease_removed=1
  }
  next_json="$(browser_ramp_canary_start_next "$e_host" "$e_ip" "$e_strategy" "$e_fp")" || {
    [[ "$lease_removed" = 1 ]] || adaptive_browser_ramp_canary_lease_revoke "$e_host" "$e_ip" "$scope" "$lease" >/dev/null 2>&1 || :
    adaptive_browser_ramp_canary_session_clear "$session" || :
    return 1
  }
  next_attempt="$(printf '%s' "$next_json" | sed -n 's/.*"attempt_id":"\([a-f0-9]\{32\}\)".*/\1/p')"
  [[ "$next_attempt" =~ ^[a-f0-9]{32}$ ]] || {
    [[ "$lease_removed" = 1 ]] || adaptive_browser_ramp_canary_lease_revoke "$e_host" "$e_ip" "$scope" "$lease" >/dev/null 2>&1 || :
    adaptive_browser_ramp_canary_session_clear "$session" || :; return 1;
  }
  if ! adaptive_browser_ramp_canary_session_advance "$session" "$attempt" "$next_attempt" "$treatment" "$ack" healthy >/dev/null; then
    adaptive_browser_attempt_transition "$next_attempt" WAIT_NEW_FLOW CANCELLED >/dev/null 2>&1 || :
    attempt_row="$(adaptive_browser_attempt_read "$next_attempt" 2>/dev/null)" || attempt_row=""
    if [[ -n "$attempt_row" ]]; then
      IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ next_generation <<< "$attempt_row"
      [[ "$next_generation" =~ ^[1-9][0-9]{0,8}$ ]] && adaptive_browser_trial_remove "$next_attempt" "$next_generation" >/dev/null 2>&1 || :
    fi
    adaptive_browser_ramp_canary_session_clear "$session" || :
    [[ "$lease_removed" = 1 ]] || adaptive_browser_ramp_canary_lease_revoke "$e_host" "$e_ip" "$scope" "$lease" >/dev/null 2>&1 || :
    return 1
  fi
  BROWSER_RAMP_CANARY_RESPONSE="{\"ramp_canary\":\"${next_stage}_armed\",\"next_attempt\":$next_json}"
}

browser_promote_attempt() {
  local dir args_file recipe config_value config nfqws max stamp current_fp catalog_rows catalog_version catalog_fp now expires
  adaptive_browser_rotation_enabled || return 1
  adaptive_browser_profile_lock_check "$profile" "$attempt_scope" "$ROOT/extra_strats/cache/orchestra"
  [[ "$?" = 1 ]] || return 1
  case "$proto" in tls) recipe=tls-http1-v1 ;; googlevideo-tcp) recipe=googlevideo-tcp-media-v1 ;; quic) recipe=googlevideo-quic-h3-media-v1 ;; *) return 1 ;; esac
  nfqws="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
  config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [[ -x "$nfqws" && -r "$config" && ! -L "$config" ]] || return 1
  dir="$(adaptive_browser_state_dir)/candidates/$attempt_id.verify"
  [[ ! -L "$(adaptive_browser_state_dir)" && ! -L "$(dirname "$dir")" && ! -e "$dir" ]] || return 1
  mkdir -p "$dir" || return 1
  Z2R_SUPERSWEEP_DIR="$dir"; export Z2R_SUPERSWEEP_DIR
  CONFIG_FILE="$config"
  for config_value in FWTYPE DESYNC_MARK DESYNC_MARK_POSTNAT FILTER_MARK CLIENT_SCOPE_MARK_MASK POSTNAT POSTNAT_ALL ZAPRET_NFT_TABLE; do
    value="$(config_get_var "$CONFIG_FILE" "$config_value" 2>/dev/null | tr -d '"\047')" || { rm -rf "$dir"; return 1; }
    printf -v "$config_value" '%s' "$value"
  done
  export FWTYPE DESYNC_MARK DESYNC_MARK_POSTNAT FILTER_MARK CLIENT_SCOPE_MARK_MASK POSTNAT POSTNAT_ALL ZAPRET_NFT_TABLE
  if ! supersweep_probe_config "$profile" "$CONFIG_FILE" standard "$ip" "$recipe"; then rm -rf "$dir"; return 1; fi
  args_file="$dir/probe/nfqws2.args"
  max="$(config_profile_max_strategy "$profile" "$CONFIG_FILE")"
  [[ "$max" =~ ^[1-9][0-9]{0,2}$ ]] || { rm -rf "$dir"; return 1; }
  stamp="$(adaptive_rules_runtime_stamp "$CONFIG_FILE" "$nfqws" "$ROOT/extra_strats/cache/orchestra")" || { rm -rf "$dir"; return 1; }
  current_fp="$(adaptive_strategy_fingerprint "$profile" "$strategy" "$args_file" "$nfqws" standard "$recipe")" || { rm -rf "$dir"; return 1; }
  [[ "$current_fp" = "$attempt_fingerprint" ]] || { rm -rf "$dir"; return 1; }
  catalog_rows="$(adaptive_strategy_fingerprint_catalog "$profile" "$max" "$args_file" "$nfqws" standard "$recipe" "$stamp" "$(adaptive_browser_state_dir)/catalog-cache")" || { rm -rf "$dir"; return 1; }
  catalog_fp="$(awk -F '\t' -v n="$strategy" '$1==n {print $2; exit}' <<< "$catalog_rows")"
  [[ "$catalog_fp" = "$attempt_fingerprint" ]] || { rm -rf "$dir"; return 1; }
  catalog_version="sha256:$(printf '%s\n' "$catalog_rows" | sha256sum | awk '{print $1}')"
  [[ "$catalog_version" =~ ^sha256:[a-f0-9]{64}$ ]] || { rm -rf "$dir"; return 1; }
  now="$(date +%s)"; expires=$((now + 900))
  # A strategy belongs to the configured mark (or to the unmarked shared
  # population). A marked result must never leak into the default scope.
  if [[ "$attempt_scope" != default ]]; then
    adaptive_rule_add "$host" "$ip" "$profile" "$proto" "$attempt_scope" "$strategy" "$attempt_fingerprint" \
      "$catalog_version" "$stamp" "$expires" browser-confirmed || { local rc=$?; rm -rf "$dir"; return "$rc"; }
    if [[ "$proto" = googlevideo-tcp ]]; then
      adaptive_rule_add googlevideo.com "$ip" "$profile" "$proto" "$attempt_scope" "$strategy" "$attempt_fingerprint" \
        "$catalog_version" "$stamp" "$expires" browser-confirmed || { local rc=$?; rm -rf "$dir"; return "$rc"; }
    fi
    rm -rf "$dir"
    return 0
  fi
  adaptive_rule_add "$host" "$ip" "$profile" "$proto" shared "$strategy" "$attempt_fingerprint" \
    "$catalog_version" "$stamp" "$expires" browser-confirmed || { local rc=$?; rm -rf "$dir"; return "$rc"; }
  if [[ "$proto" = googlevideo-tcp ]]; then
    adaptive_rule_add googlevideo.com "$ip" "$profile" "$proto" shared "$strategy" "$attempt_fingerprint" \
      "$catalog_version" "$stamp" "$expires" browser-confirmed || { local rc=$?; rm -rf "$dir"; return "$rc"; }
  fi
  local rc=$?
  rm -rf "$dir"
  return "$rc"
}

case "${f[action]:-}" in
  browser_hello|browser_status)
    [[ ${#f[@]} -eq 2 ]] || fail '400 Bad Request' 'browser_hello takes no parameters'
    mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null || printf OFF)"
    case "$mode" in OFF|OBSERVE|TEST_ONLY|AUTO|AGENT_BETA|PAUSED) ;; *) mode=OFF ;; esac
    ranking_opt_in=false
    [[ ! -f "$ROOT/extra_strats/cache/adaptive/browser-rankings-opt-in" || -L "$ROOT/extra_strats/cache/adaptive/browser-rankings-opt-in" ]] ||
      [[ "$(cat "$ROOT/extra_strats/cache/adaptive/browser-rankings-opt-in" 2>/dev/null)" != 1 ]] || ranking_opt_in=true
    send '200 OK' "{\"schema_version\":1,\"client_id\":\"$client_id\",\"scope\":\"$scope\",\"mode\":\"$mode\",\"ranking_opt_in\":$ranking_opt_in,\"status\":\"paired\"}"
    ;;
  browser_learning_status)
    [[ ${#f[@]} -eq 2 ]] || fail '400 Bad Request' 'browser_learning_status takes no parameters'
    browser_learning_status
    ;;
  browser_report_failure)
    [[ ( ${#f[@]} -eq 10 || ${#f[@]} -eq 11 ) && "${f[trigger]:-}" =~ ^(main_frame_network_failure|critical_resource_repeated_failure|user_fix)$ &&
       "${f[request_class]:-}" =~ ^(main_frame|script|xmlhttprequest|media)$ && "${f[method]:-}" =~ ^(GET|HEAD|UNSAFE)$ &&
       "${f[failure_class]:-}" =~ ^(network_failure|user_requested|http_(403|451|500|502|503|504))$ &&
       "${f[failure_transport]:-unknown}" =~ ^(unknown|tls|quic)$ &&
       "${f[failure_count]:-}" =~ ^[12]$ &&
       "${f[browser_event_id]:-}" =~ ^[a-f0-9]{32}$ && "${f[observed_at]:-}" =~ ^[0-9]{13}$ ]] || fail '400 Bad Request' 'invalid failure event'
    trigger="${f[trigger]}"; klass="${f[request_class]}"; method="${f[method]}"; failure="${f[failure_class]}"
    mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null || printf OFF)"
    adaptive_browser_rotation_enabled || send '200 OK' "{\"schema_version\":1,\"status\":\"MODE_DISABLED\",\"state\":\"NOT_TESTED\",\"mode\":\"$mode\"}"
    if [[ "$trigger" = main_frame_network_failure ]]; then
      [[ "$klass" = main_frame && "$method" = GET && "$failure" = network_failure && "${f[failure_count]}" = 1 ]] || fail '400 Bad Request' 'main-frame trigger mismatch'
    elif [[ "$trigger" = critical_resource_repeated_failure ]]; then
      [[ "$klass" =~ ^(script|xmlhttprequest|media)$ && "$method" != UNSAFE && "$failure" = network_failure && "${f[failure_count]}" = 2 ]] || fail '400 Bad Request' 'resource trigger mismatch'
    elif [[ "${f[failure_count]}" != 1 ]]; then fail '400 Bad Request' 'manual trigger count mismatch'
    elif [[ "$failure" = http_* ]]; then :; fi
    host="${f[hostname],,}"
    adaptive_browser_host_valid "$host" || fail '400 Bad Request' 'invalid target hostname'
    host="$ADAPTIVE_BROWSER_HOST"
    adaptive_browser_rotation_enabled || send '200 OK' '{"schema_version":1,"status":"MODE_DISABLED","state":"NOT_TESTED"}'
    now_ms="$(( $(date +%s) * 1000 ))"; observed="${f[observed_at]}"
    (( observed <= now_ms + 5000 && observed >= now_ms - 60000 )) || fail '400 Bad Request' 'stale failure event'
    [[ "$trigger" = user_fix || "$failure" = network_failure ]] || send '200 OK' '{"schema_version":1,"status":"MANUAL_ONLY","state":"NOT_TESTED"}'
    [[ "$trigger" = main_frame_network_failure || "$trigger" = critical_resource_repeated_failure || "$trigger" = user_fix ]] || fail '400 Bad Request' 'invalid trigger'
    claim="$(adaptive_browser_event_claim "$client_id" "${f[browser_event_id]}" "$host" "$trigger" "$(date +%s)")" || fail '503 Service Unavailable' 'browser event journal unavailable'
    [[ "$claim" != duplicate ]] || send '200 OK' '{"schema_version":1,"status":"DUPLICATE","state":"NOT_TESTED"}'
    [[ "$claim" != budget ]] || send '200 OK' '{"schema_version":1,"status":"COOLDOWN","state":"NOT_TESTED"}'
    # Resolve only from recent production observations already written by Lua.
    # No DNS lookup or synthetic request is performed before the first trial.
    events="${Z2R_ADAPTIVE_EVENTS_FILE:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/events.tsv}"
    [[ -r "$events" && ! -L "$events" ]] || send '200 OK' '{"schema_version":1,"status":"TARGET_NOT_MANAGED","state":"TARGET_NOT_MANAGED"}'
    now="$(date +%s)"; matches="$(adaptive_browser_resolve_observation "$host" "$scope" "$events" "$now" "${f[failure_transport]:-unknown}" 2>/dev/null)"; resolve_rc=$?
    case "$resolve_rc" in
      0) ;;
      3) send '200 OK' '{"schema_version":1,"status":"UNKNOWN","state":"UNKNOWN","reason":"ambiguous_recent_flows"}' ;;
      *) send '200 OK' '{"schema_version":1,"status":"TARGET_NOT_MANAGED","state":"TARGET_NOT_MANAGED"}' ;;
    esac
    IFS=$'\t' read -r obs_host obs_ip obs_profile obs_proto obs_scope obs_seen exclude_strategy <<< "$matches"
    if [[ "$obs_host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ && "$obs_profile" = 2 ]]; then
      obs_proto=googlevideo-tcp
      matches="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$obs_host" "$obs_ip" "$obs_profile" "$obs_proto" "$obs_scope" "$obs_seen" "$exclude_strategy")"
    fi
    [[ "$exclude_strategy" =~ ^(0|[1-9][0-9]{0,2})$ ]] || send '200 OK' '{"schema_version":1,"status":"NOT_TESTED","state":"NOT_TESTED","reason":"router_strategy_unknown"}'
    trial_json="$(browser_start_trial "$matches" "$trigger" "$client_id" "${REMOTE_ADDR:-}" "$scope" "" "" "$exclude_strategy")"
    trial_rc=$?
    case "$trial_rc" in
      0) send '200 OK' "$trial_json" ;;
      4) send '200 OK' '{"schema_version":1,"status":"ROUTER_BUSY","state":"NOT_TESTED"}' ;;
      5) send '200 OK' '{"schema_version":1,"status":"MODE_DISABLED","state":"NOT_TESTED"}' ;;
      6) send '200 OK' '{"schema_version":1,"status":"MANUAL_LOCKED","state":"NOT_TESTED"}' ;;
      7) send '200 OK' '{"schema_version":1,"status":"ACTIVE_ATTEMPT","state":"ACTIVE_ATTEMPT"}' ;;
      8) send '200 OK' '{"schema_version":1,"status":"AUTOROTATION_DISABLED","state":"NOT_TESTED"}' ;;
      *) send '200 OK' '{"schema_version":1,"status":"NO_CANDIDATE","state":"NOT_TESTED"}' ;;
    esac
    ;;
  browser_attempt_status|browser_cancel_attempt)
    [[ ${#f[@]} -eq 3 && "${f[attempt_id]:-}" =~ ^[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid attempt id'
    row="$(adaptive_browser_attempt_read "${f[attempt_id]}")" || fail '404 Not Found' 'attempt not found'
    IFS=$'\t' read -r ver attempt_id owner owner_ip attempt_scope host ip profile proto trigger state strategy attempt_fingerprint created expires generation extra <<< "$row"
    [[ "$ver" = 1 && "$owner" = "$client_id" && "$owner_ip" = "${REMOTE_ADDR:-}" && "$attempt_scope" = "$scope" && -z "${extra:-}" ]] || fail '404 Not Found' 'attempt not found'
    now="$(date +%s)"
    if (( now > expires )); then
      case "$state" in CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED|TARGET_NOT_MANAGED) ;;
        *) adaptive_browser_attempt_transition "$attempt_id" "$state" EXPIRED || fail '409 Conflict' 'attempt changed concurrently'; adaptive_browser_trial_remove "$attempt_id" "$generation" || :; state=EXPIRED ;;
      esac
    elif [[ "${f[action]}" = browser_cancel_attempt ]]; then
      adaptive_browser_attempt_transition "$attempt_id" "$state" CANCELLED || fail '409 Conflict' 'attempt is terminal or changed concurrently'
      adaptive_browser_trial_remove "$attempt_id" "$generation" || fail '503 Service Unavailable' 'trial cleanup failed'
      state=CANCELLED
    fi
    if [[ "$trigger" = ramp_canary ]] && ! adaptive_browser_rotation_enabled && [[
          "$state" =~ ^(WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS)$ ]]; then
      adaptive_browser_attempt_transition "$attempt_id" "$state" UNKNOWN || :
      adaptive_browser_trial_remove "$attempt_id" "$generation" || :
      state=UNKNOWN
    fi
    if [[ "$state" =~ ^(WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS)$ ]]; then
      if browser_confirm_flow; then :
      else
        flow_rc=$?
        if [[ "$flow_rc" = 1 && "$state" = WAIT_NEW_FLOW ]]; then :
        else adaptive_browser_attempt_transition "$attempt_id" "$state" UNKNOWN || :; state=UNKNOWN; adaptive_browser_trial_remove "$attempt_id" "$generation" || :
        fi
      fi
    fi
    if [[ "$trigger" = ramp_canary && "$state" =~ ^(UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED)$ ]]; then
      browser_ramp_canary_abort "$attempt_id" || :
    fi
    case "$state" in CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED)
      adaptive_browser_stats_queue_attempt "$attempt_id" >/dev/null 2>&1 && adaptive_browser_stats_schedule_flush >/dev/null 2>&1 || : ;;
    esac
    if [[ "$proto" = googlevideo-tcp ]]; then
      BROWSER_FLOW_RAMP_TREATMENT=unknown
      BROWSER_FLOW_RAMP_ACK_EVIDENCE=unknown
      if flow_row="$(adaptive_browser_flow_read "$attempt_id" "$generation" 2>/dev/null)"; then
        IFS=$'\t' read -r flow_ver flow_id flow_generation flow_client flow_scope flow_host flow_ip flow_profile flow_proto flow_strategy flow_fingerprint syn_at selected_at flow_ramp_treatment flow_ramp_ack_evidence flow_extra <<< "$flow_row"
        [[ "${flow_ramp_treatment:-}" =~ ^(unknown|applied|bypassed|unchanged|no_window_scale)$ ]] && BROWSER_FLOW_RAMP_TREATMENT="$flow_ramp_treatment"
        [[ "${flow_ramp_ack_evidence:-}" =~ ^(unknown|confirmed|pending)$ ]] && BROWSER_FLOW_RAMP_ACK_EVIDENCE="$flow_ramp_ack_evidence"
      fi
      send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"$state\",\"expires_at\":$expires,\"ramp_treatment\":\"$BROWSER_FLOW_RAMP_TREATMENT\",\"ramp_ack_evidence\":\"$BROWSER_FLOW_RAMP_ACK_EVIDENCE\"}"
    fi
    send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"$state\",\"expires_at\":$expires}"
    ;;
  browser_report_result)
    [[ ${#f[@]} -ge 8 && ${#f[@]} -le 16 && "${f[attempt_id]:-}" =~ ^[a-f0-9]{32}$ && "${f[browser_event_id]:-}" =~ ^[a-f0-9]{32}$ &&
       "${f[result]:-}" =~ ^(network_success|network_failure)$ && "${f[request_class]:-}" =~ ^(main_frame|script|xmlhttprequest|media)$ &&
       ( -z "${f[browser_ip]:-}" || "${f[browser_ip]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ) && "${f[observed_at]:-}" =~ ^[0-9]{13}$ &&
       ( -z "${f[browser_protocol]:-}" || "${f[browser_protocol]}" =~ ^(h3|tcp)$ ) &&
       ( -z "${f[ramp_canary_opt_in]:-}" || "${f[ramp_canary_opt_in]}" =~ ^[01]$ ) ]] || fail '400 Bad Request' 'invalid browser result'
    media_fields=0
    for media_key in media_quality media_sample_ms media_progress_ms media_stall_ms media_dropped_frames media_total_frames; do
      [[ ${f[$media_key]+present} ]] && media_fields=$((media_fields + 1))
    done
    [[ "$media_fields" = 0 || "$media_fields" = 6 ]] || fail '400 Bad Request' 'incomplete media quality evidence'
    if [[ "$media_fields" = 6 ]]; then
      [[ "${f[media_quality]}" =~ ^(healthy|degraded|unknown)$ &&
         "${f[media_sample_ms]}" =~ ^[0-9]{1,5}$ && "${f[media_progress_ms]}" =~ ^[0-9]{1,5}$ &&
         "${f[media_stall_ms]}" =~ ^[0-9]{1,5}$ && "${f[media_dropped_frames]}" =~ ^[0-9]{1,6}$ &&
         "${f[media_total_frames]}" =~ ^[0-9]{1,6}$ ]] || fail '400 Bad Request' 'invalid media quality evidence'
      (( f[media_sample_ms] <= 12000 && f[media_progress_ms] <= 12000 && f[media_stall_ms] <= 12000 &&
         f[media_dropped_frames] <= 999999 && f[media_total_frames] <= 999999 )) || fail '400 Bad Request' 'media quality evidence out of range'
      if [[ "${f[media_quality]}" = healthy ]]; then
        (( f[media_sample_ms] >= 7500 && f[media_progress_ms] >= 5000 && f[media_stall_ms] < 1000 )) || fail '400 Bad Request' 'healthy media evidence is too weak'
      elif [[ "${f[media_quality]}" = degraded ]]; then
        (( f[media_sample_ms] >= 5000 )) || fail '400 Bad Request' 'degraded media evidence is too short'
      fi
      [[ "${f[result]}" = network_success ]] || fail '400 Bad Request' 'media evidence requires a successful resource'
    fi
    if [[ -n "${f[browser_ip]}" ]]; then
      awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; exit 0} {exit 1}' <<< "${f[browser_ip]}" || fail '400 Bad Request' 'invalid browser IP'
    elif [[ "${f[result]}" != network_failure ]]; then
      fail '400 Bad Request' 'browser IP is required for successful outcomes'
    fi
    row="$(adaptive_browser_attempt_read "${f[attempt_id]}")" || fail '404 Not Found' 'attempt not found'
    IFS=$'\t' read -r ver attempt_id owner owner_ip attempt_scope host ip profile proto trigger state strategy attempt_fingerprint created expires generation extra <<< "$row"
    [[ "$ver" = 1 && "$owner" = "$client_id" && "$owner_ip" = "${REMOTE_ADDR:-}" && "$attempt_scope" = "$scope" && -z "${extra:-}" ]] || fail '404 Not Found' 'attempt not found'
    if [[ "${f[request_class]}" != main_frame ]]; then
      [[ ( "$trigger" = critical_resource_repeated_failure && "${f[request_class]}" =~ ^(script|xmlhttprequest|media)$ ) ||
         ( "$trigger" = ramp_canary && "${f[request_class]}" = media ) ]] || fail '400 Bad Request' 'critical-resource result does not match this attempt'
    fi
    [[ "${f[observed_at]}" =~ ^[0-9]{13}$ ]] || fail '400 Bad Request' 'invalid result time'
    now_ms="$(( $(date +%s) * 1000 ))"
    if [[ "$proto" = quic && "${f[browser_protocol]:-}" = tcp ]]; then
      [[ "${f[result]}" = network_success && "${f[browser_ip]}" = "$ip" &&
         "${f[observed_at]}" -ge "$((created * 1000))" && "${f[observed_at]}" -le "$((expires * 1000))" &&
         "${f[observed_at]}" -le "$((now_ms + 5000))" &&
         "$state" =~ ^(WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS)$ ]] || fail '400 Bad Request' 'invalid TCP fallback evidence'
      result_claim="$(adaptive_browser_result_claim "$client_id" "$attempt_id" "${f[browser_event_id]}" "${f[result]}" "$(date +%s)")" || {
        result_rc=$?
        if [[ "$result_rc" = 3 ]]; then
          duplicate_state="$(adaptive_browser_attempt_read "$attempt_id" | cut -f11)"
          send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"$duplicate_state\",\"status\":\"DUPLICATE\"}"
        fi
        fail '503 Service Unavailable' 'browser result journal unavailable'
      }
      adaptive_browser_attempt_transition "$attempt_id" "$state" TCP_FALLBACK || fail '409 Conflict' 'attempt changed concurrently'
      adaptive_browser_trial_remove "$attempt_id" "$generation" || fail '503 Service Unavailable' 'trial cleanup failed'
      adaptive_browser_stats_queue_attempt "$attempt_id" >/dev/null 2>&1 && adaptive_browser_stats_schedule_flush >/dev/null 2>&1 || :
      send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"TCP_FALLBACK\",\"status\":\"TCP_FALLBACK\",\"reason\":\"browser_negotiated_tcp\"}"
    fi
    if [[ "$state" = WAIT_NEW_FLOW ]]; then
      if browser_confirm_flow; then state=FLOW_CONFIRMED
      else
        if [[ "$trigger" = ramp_canary ]]; then
          adaptive_browser_attempt_transition "$attempt_id" WAIT_NEW_FLOW UNKNOWN >/dev/null 2>&1 || :
          adaptive_browser_trial_remove "$attempt_id" "$generation" >/dev/null 2>&1 || :
          browser_ramp_canary_abort "$attempt_id" >/dev/null 2>&1 || :
        fi
        fail '409 Conflict' 'new production flow with selected strategy is not confirmed'
      fi
    fi
    if [[ "$state" = FLOW_CONFIRMED ]]; then
      adaptive_browser_attempt_transition "$attempt_id" FLOW_CONFIRMED WAIT_BROWSER_RESULT || fail '409 Conflict' 'attempt changed concurrently'
      state=WAIT_BROWSER_RESULT
    fi
    flow_row="$(adaptive_browser_flow_read "$attempt_id" "$generation" 2>/dev/null)" || fail '409 Conflict' 'production flow evidence is unavailable'
    IFS=$'\t' read -r flow_ver flow_id flow_generation flow_client flow_scope flow_host flow_ip flow_profile flow_proto flow_strategy flow_fingerprint syn_at selected_at flow_ramp_treatment flow_ramp_ack_evidence flow_extra <<< "$flow_row"
    [[ "$flow_client" = "$client_id" && "$flow_scope" = "$attempt_scope" &&
        ( ( "$flow_host" = "$host" && "$flow_ip" = "$ip" ) ||
          ( "$proto" = googlevideo-tcp && "$profile" = 2 && "$flow_proto" = googlevideo-tcp && "$flow_profile" = 2 &&
            "$flow_host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ && "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ) ) &&
        ( ( -z "${f[browser_ip]}" && "${f[result]}" = network_failure ) || "${f[browser_ip]}" = "$flow_ip" ) &&
       "$flow_profile" = "$profile" && "$flow_proto" = "$proto" && "$flow_strategy" = "$strategy" && "$flow_fingerprint" = "$attempt_fingerprint" ]] || fail '409 Conflict' 'production flow does not match this attempt'
    (( f[observed_at] >= selected_at * 1000 && f[observed_at] <= now_ms + 5000 && f[observed_at] <= expires * 1000 )) || fail '400 Bad Request' 'result is outside the confirmed flow window'
    [[ "$state" = WAIT_BROWSER_RESULT || "$state" = PROVISIONAL_SUCCESS ]] || fail '409 Conflict' 'attempt is not waiting for a browser result'
    if [[ "$proto" = quic && "${f[result]}" != network_failure && "${f[browser_protocol]:-}" != h3 ]]; then
      adaptive_browser_attempt_transition "$attempt_id" "$state" UNKNOWN || fail '409 Conflict' 'attempt changed concurrently'
      adaptive_browser_trial_remove "$attempt_id" "$generation" || fail '503 Service Unavailable' 'trial cleanup failed'
      adaptive_browser_stats_queue_attempt "$attempt_id" >/dev/null 2>&1 && adaptive_browser_stats_schedule_flush >/dev/null 2>&1 || :
      send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"UNKNOWN\",\"status\":\"PROTOCOL_UNKNOWN\",\"reason\":\"h3_protocol_evidence_unavailable\"}"
    fi
    result_claim="$(adaptive_browser_result_claim "$client_id" "$attempt_id" "${f[browser_event_id]}" "${f[result]}" "$(date +%s)")" || {
      result_rc=$?
      [[ "$result_rc" = 3 ]] && send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"$state\",\"status\":\"DUPLICATE\"}"
      fail '503 Service Unavailable' 'browser result journal unavailable'
    }
    media_quality_json=""
    if [[ "$media_fields" = 6 ]]; then
      [[ "$proto" = googlevideo-tcp && "$profile" = 2 && "$flow_ramp_treatment" =~ ^(applied|bypassed)$ &&
         "$flow_ramp_ack_evidence" =~ ^(unknown|confirmed|pending)$ ]] || fail '400 Bad Request' 'media quality requires a proven Googlevideo Ramp flow'
      media_store_rc=0
      adaptive_browser_media_quality_write "$attempt_id" "$generation" "$client_id" "$attempt_scope" "$host" "$ip" \
        "$profile" "$proto" "$strategy" "$attempt_fingerprint" "$flow_ramp_treatment" "$flow_ramp_ack_evidence" \
        "${f[media_quality]}" "${f[media_sample_ms]}" "${f[media_progress_ms]}" "${f[media_stall_ms]}" \
        "${f[media_dropped_frames]}" "${f[media_total_frames]}" "$(date +%s)" || media_store_rc=$?
      if [[ "$media_store_rc" = 0 ]]; then
        media_quality_json=",\"media_quality\":\"${f[media_quality]}\""
      else
        media_quality_json=',"media_quality":"unknown"'
      fi
      if [[ "${f[media_quality]}" != healthy ]]; then
        adaptive_browser_attempt_transition "$attempt_id" "$state" UNKNOWN || fail '409 Conflict' 'attempt changed concurrently'
        adaptive_browser_trial_remove "$attempt_id" "$generation" || fail '503 Service Unavailable' 'trial cleanup failed'
        [[ "$trigger" != ramp_canary ]] || browser_ramp_canary_abort "$attempt_id" >/dev/null 2>&1 || :
        adaptive_browser_stats_queue_attempt "$attempt_id" >/dev/null 2>&1 && adaptive_browser_stats_schedule_flush >/dev/null 2>&1 || :
        send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"UNKNOWN\",\"reason\":\"media_quality_inconclusive\",\"media_quality\":\"${f[media_quality]}\"}"
      fi
    fi
    case "$state:${f[result]}" in
      WAIT_BROWSER_RESULT:network_failure)
        adaptive_browser_attempt_transition "$attempt_id" WAIT_BROWSER_RESULT CONFIRMED_FAILURE || fail '409 Conflict' 'attempt changed concurrently'
        adaptive_browser_trial_remove "$attempt_id" "$generation" || fail '503 Service Unavailable' 'trial cleanup failed'
        state=CONFIRMED_FAILURE
        ;;
      WAIT_BROWSER_RESULT:network_success)
        adaptive_browser_attempt_transition "$attempt_id" WAIT_BROWSER_RESULT PROVISIONAL_SUCCESS || fail '409 Conflict' 'attempt changed concurrently'
        state=PROVISIONAL_SUCCESS
        ;;
      PROVISIONAL_SUCCESS:network_success)
        browser_promote_attempt || {
          adaptive_browser_attempt_transition "$attempt_id" PROVISIONAL_SUCCESS UNKNOWN || :
          adaptive_browser_trial_remove "$attempt_id" "$generation" || :
          send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"UNKNOWN\",\"reason\":\"strategy_fingerprint_changed_or_promotion_failed\"}"
        }
        adaptive_browser_attempt_transition "$attempt_id" PROVISIONAL_SUCCESS CONFIRMED_SUCCESS || fail '409 Conflict' 'attempt changed concurrently'
        adaptive_browser_trial_remove "$attempt_id" "$generation" || fail '503 Service Unavailable' 'trial cleanup failed'
        state=CONFIRMED_SUCCESS
        ;;
      PROVISIONAL_SUCCESS:network_failure)
        adaptive_browser_attempt_transition "$attempt_id" PROVISIONAL_SUCCESS CONFIRMED_FAILURE || fail '409 Conflict' 'attempt changed concurrently'
        adaptive_browser_trial_remove "$attempt_id" "$generation" || fail '503 Service Unavailable' 'trial cleanup failed'
        state=CONFIRMED_FAILURE
        ;;
      *) fail '409 Conflict' 'attempt is not waiting for this result' ;;
    esac
    case "$state" in CONFIRMED_SUCCESS|CONFIRMED_FAILURE|TCP_FALLBACK|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED)
      adaptive_browser_stats_queue_attempt "$attempt_id" >/dev/null 2>&1 && adaptive_browser_stats_schedule_flush >/dev/null 2>&1 || : ;;
    esac
    ramp_canary_json=""
    if [[ "$proto" = googlevideo-tcp && ( "$trigger" = ramp_canary || "${f[ramp_canary_opt_in]:-0}" = 1 ) ]]; then
      browser_ramp_canary_handle_result "$attempt_id" "$state" "${f[ramp_canary_opt_in]:-0}" "$trigger" \
        "$flow_ramp_treatment" "$flow_ramp_ack_evidence" "$generation" || :
      if [[ "$BROWSER_RAMP_CANARY_RESPONSE" = \{*\} ]]; then
        ramp_canary_json="${BROWSER_RAMP_CANARY_RESPONSE:1:${#BROWSER_RAMP_CANARY_RESPONSE}-2}"
        [[ -z "$ramp_canary_json" ]] || ramp_canary_json=",$ramp_canary_json"
      fi
    fi
    if [[ "$state" = CONFIRMED_FAILURE && "$trigger" != ramp_canary ]]; then
      next_claim="$(adaptive_browser_event_claim "$client_id" "${f[browser_event_id]}" "$host" "$trigger" "$(date +%s)")" || next_claim=unavailable
      if [[ "$next_claim" = accepted ]]; then
        next_target="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$host" "$ip" "$profile" "$proto" "$attempt_scope" "$(date +%s)" "$strategy")"
        next_trial_json="$(browser_start_trial "$next_target" "$trigger" "$client_id" "${REMOTE_ADDR:-}" "$attempt_scope" "" "" "$strategy")"
        next_trial_rc=$?
        if [[ "$next_trial_rc" = 0 ]]; then
          send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"NEXT_CANDIDATE\",\"next_attempt\":$next_trial_json}"
        fi
      fi
    fi
    send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"$state\"$media_quality_json$ramp_canary_json}"
    ;;
  *) fail '400 Bad Request' 'unknown browser action' ;;
esac
