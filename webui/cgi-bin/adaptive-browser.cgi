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
    printf 'Access-Control-Allow-Origin: %s\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Max-Age: 300\r\n' "$origin"
    [[ "${HTTP_ACCESS_CONTROL_REQUEST_PRIVATE_NETWORK:-}" != true ]] || printf 'Access-Control-Allow-Private-Network: true\r\n'
  fi
}
send() { local status="$1" body="$2"; printf 'Status: %s\r\n' "$status"; headers; printf '\r\n%s\n' "$body"; exit 0; }
fail() { send "$1" "{\"schema_version\":1,\"error\":\"$2\"}"; }

if [[ "${REQUEST_METHOD:-}" = OPTIONS ]]; then
  origin_ok "$origin" || fail '403 Forbidden' 'extension origin required'
  [[ "${HTTP_ACCESS_CONTROL_REQUEST_METHOD:-}" = POST ]] || fail '405 Method Not Allowed' 'POST preflight required'
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
  case "$key" in schema_version|action|browser_event_id|trigger|request_class|hostname|method|failure_class|failure_transport|failure_count|observed_at|attempt_id|result|browser_ip|browser_protocol) ;;
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
  local host ip profile proto seen nfqws orch_dir now expires generation raw_id id
  local candidate_dir args_file candidate fingerprint recipe config_value flow_dir flow_user flow_uid flow_gid flow_owner
  IFS=$'\t' read -r host ip profile proto target_scope seen <<< "$target"
  [[ "$target_scope" = "$scope" && "$client_ip" = "$REMOTE_ADDR" ]] || return 2
  [[ "$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)" = AGENT_BETA ]] || return 5
  [[ ! -d "${Z2R_ADAPTIVE_LOCK_DIR:-/tmp/z2r-supersweep.lock}" ]] || return 4
  [[ "$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" NFQWS2_ENABLE 2>/dev/null | tr -d '"\047')" = 1 ]] || return 5
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
  raw_id="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ "$raw_id" =~ ^[a-f0-9]{32}$ ]] || return 1
  id="$raw_id"; now="$(date +%s)"; expires=$((now + 45))
  raw_id="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ "$raw_id" =~ ^[0-9]{1,10}$ ]] || return 1
  generation=$((raw_id % 999999999 + 1))
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
  candidate="$(adaptive_browser_candidate_select "$host" "$ip" "$profile" "$proto" "$scope" "$args_file" "$nfqws" "$ORCH_DIR" "$client_id")"
  if [[ $? -ne 0 || -z "$candidate" ]]; then rm -rf "$candidate_dir"; return 3; fi
  IFS=$'\t' read -r strategy fingerprint <<< "$candidate"
  rm -rf "$candidate_dir" || return 1
  adaptive_browser_attempt_gc "$now" "$id"
  case $? in 0) ;; 3) return 4 ;; *) return 1 ;; esac
  if ! adaptive_browser_attempt_write "$id" "$client_id" "$client_ip" "$scope" "$host" "$ip" "$profile" "$proto" "$trigger" QUEUED "$strategy" "$fingerprint" "$now" "$expires" "$generation"; then
    adaptive_browser_attempt_reservation_release "$id" >/dev/null 2>&1 || :
    return 1
  fi
  adaptive_browser_attempt_reservation_release "$id" >/dev/null 2>&1 || :
  if ! adaptive_browser_trial_add "$id" "$generation" "$client_id" "$client_ip" "$scope" "$host" "$ip" "$profile" "$proto" "$strategy" "$fingerprint" "$now" "$expires"; then
    adaptive_browser_attempt_transition "$id" QUEUED TARGET_NOT_MANAGED >/dev/null 2>&1 || :
    return 7
  fi
  adaptive_browser_attempt_transition "$id" QUEUED WAIT_NEW_FLOW || {
    adaptive_browser_trial_remove "$id" "$generation" || :
    return 1
  }
  printf '{"schema_version":1,"status":"WAIT_NEW_FLOW","state":"WAIT_NEW_FLOW","attempt_id":"%s","candidate":{"profile_id":%s,"strategy":%s,"protocol":"%s","treatment_variant":"standard"},"scope":"%s","expires_at":%s,"retry_hint":"reload_if_safe"}' \
    "$id" "$profile" "$strategy" "$proto" "$scope" "$expires"
}

browser_confirm_flow() {
  local row ver flow_id flow_generation flow_client flow_scope flow_host flow_ip flow_profile flow_proto flow_strategy fingerprint syn_at selected_at ramp_treatment ramp_ack_evidence extra now
  row="$(adaptive_browser_flow_read "$attempt_id" "$generation" 2>/dev/null)" || return 1
  IFS=$'\t' read -r ver flow_id flow_generation flow_client flow_scope flow_host flow_ip flow_profile flow_proto flow_strategy fingerprint syn_at selected_at ramp_treatment ramp_ack_evidence extra <<< "$row"
  now="$(date +%s)"
  [[ "$ver" = 1 && "$flow_id" = "$attempt_id" && "$flow_generation" = "$generation" && "$flow_client" = "$client_id" && "$flow_scope" = "$attempt_scope" &&
     "$flow_host" = "$host" && "$flow_ip" = "$ip" && "$flow_profile" = "$profile" && "$flow_proto" = "$proto" &&
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

browser_promote_attempt() {
  local dir args_file recipe config_value config nfqws max stamp current_fp catalog_rows catalog_version catalog_fp now expires
  [[ "$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)" = AGENT_BETA ]] || return 1
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
  # Keep the confirmed rule for the browser's client scope, and publish the
  # same result as a default-scope baseline for clients without a configured
  # scope. Marked clients never inherit the shared row.
  if [[ "$attempt_scope" != default ]]; then
    adaptive_rule_add "$host" "$ip" "$profile" "$proto" "$attempt_scope" "$strategy" "$attempt_fingerprint" \
      "$catalog_version" "$stamp" "$expires" browser-confirmed || { local rc=$?; rm -rf "$dir"; return "$rc"; }
  fi
  adaptive_rule_add "$host" "$ip" "$profile" "$proto" shared "$strategy" "$attempt_fingerprint" \
    "$catalog_version" "$stamp" "$expires" browser-confirmed
  local rc=$?
  rm -rf "$dir"
  return "$rc"
}

case "${f[action]:-}" in
  browser_hello|browser_status)
    [[ ${#f[@]} -eq 2 ]] || fail '400 Bad Request' 'browser_hello takes no parameters'
    mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null || printf OFF)"
    case "$mode" in OFF|OBSERVE|TEST_ONLY|AGENT_BETA|PAUSED) ;; *) mode=OFF ;; esac
    ranking_opt_in=false
    [[ ! -f "$ROOT/extra_strats/cache/adaptive/browser-rankings-opt-in" || -L "$ROOT/extra_strats/cache/adaptive/browser-rankings-opt-in" ]] ||
      [[ "$(cat "$ROOT/extra_strats/cache/adaptive/browser-rankings-opt-in" 2>/dev/null)" != 1 ]] || ranking_opt_in=true
    send '200 OK' "{\"schema_version\":1,\"client_id\":\"$client_id\",\"scope\":\"$scope\",\"mode\":\"$mode\",\"ranking_opt_in\":$ranking_opt_in,\"status\":\"paired\"}"
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
    [[ "$mode" = AGENT_BETA ]] || send '200 OK' "{\"schema_version\":1,\"status\":\"MODE_DISABLED\",\"state\":\"NOT_TESTED\",\"mode\":\"$mode\"}"
    if [[ "$trigger" = main_frame_network_failure ]]; then
      [[ "$klass" = main_frame && "$method" = GET && "$failure" = network_failure && "${f[failure_count]}" = 1 ]] || fail '400 Bad Request' 'main-frame trigger mismatch'
    elif [[ "$trigger" = critical_resource_repeated_failure ]]; then
      [[ "$klass" =~ ^(script|xmlhttprequest|media)$ && "$method" != UNSAFE && "$failure" = network_failure && "${f[failure_count]}" = 2 ]] || fail '400 Bad Request' 'resource trigger mismatch'
    elif [[ "${f[failure_count]}" != 1 ]]; then fail '400 Bad Request' 'manual trigger count mismatch'
    elif [[ "$failure" = http_* ]]; then :; fi
    host="${f[hostname],,}"
    adaptive_browser_host_valid "$host" || fail '400 Bad Request' 'invalid target hostname'
    host="$ADAPTIVE_BROWSER_HOST"
    [[ "$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)" = AGENT_BETA ]] || send '200 OK' '{"schema_version":1,"status":"MODE_DISABLED","state":"NOT_TESTED"}'
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
    IFS=$'\t' read -r obs_host obs_ip obs_profile obs_proto obs_scope obs_seen <<< "$matches"
    if [[ "$obs_host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ && "$obs_profile" = 2 ]]; then
      obs_proto=googlevideo-tcp
      matches="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$obs_host" "$obs_ip" "$obs_profile" "$obs_proto" "$obs_scope" "$obs_seen")"
    fi
    trial_json="$(browser_start_trial "$matches" "$trigger" "$client_id" "${REMOTE_ADDR:-}" "$scope")"
    trial_rc=$?
    case "$trial_rc" in
      0) send '200 OK' "$trial_json" ;;
      4) send '200 OK' '{"schema_version":1,"status":"ROUTER_BUSY","state":"NOT_TESTED"}' ;;
      5) send '200 OK' '{"schema_version":1,"status":"MODE_DISABLED","state":"NOT_TESTED"}' ;;
      6) send '200 OK' '{"schema_version":1,"status":"MANUAL_LOCKED","state":"NOT_TESTED"}' ;;
      7) send '200 OK' '{"schema_version":1,"status":"ACTIVE_ATTEMPT","state":"WAIT_NEW_FLOW"}' ;;
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
    if [[ "$state" =~ ^(WAIT_NEW_FLOW|FLOW_CONFIRMED|WAIT_BROWSER_RESULT|PROVISIONAL_SUCCESS)$ ]]; then
      if browser_confirm_flow; then :
      else
        flow_rc=$?
        if [[ "$flow_rc" = 1 && "$state" = WAIT_NEW_FLOW ]]; then :
        else adaptive_browser_attempt_transition "$attempt_id" "$state" UNKNOWN || :; state=UNKNOWN; adaptive_browser_trial_remove "$attempt_id" "$generation" || :
        fi
      fi
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
    [[ ( ${#f[@]} -eq 8 || ${#f[@]} -eq 9 ) && "${f[attempt_id]:-}" =~ ^[a-f0-9]{32}$ && "${f[browser_event_id]:-}" =~ ^[a-f0-9]{32}$ &&
       "${f[result]:-}" =~ ^(network_success|network_failure)$ && "${f[request_class]:-}" =~ ^(main_frame|script|xmlhttprequest|media)$ &&
       "${f[browser_ip]:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "${f[observed_at]:-}" =~ ^[0-9]{13}$ &&
       ( -z "${f[browser_protocol]:-}" || "${f[browser_protocol]}" =~ ^(h3|tcp)$ ) ]] || fail '400 Bad Request' 'invalid browser result'
    awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]{0,2})$/ || $i>255) exit 1; exit 0} {exit 1}' <<< "${f[browser_ip]}" || fail '400 Bad Request' 'invalid browser IP'
    row="$(adaptive_browser_attempt_read "${f[attempt_id]}")" || fail '404 Not Found' 'attempt not found'
    IFS=$'\t' read -r ver attempt_id owner owner_ip attempt_scope host ip profile proto trigger state strategy attempt_fingerprint created expires generation extra <<< "$row"
    [[ "$ver" = 1 && "$owner" = "$client_id" && "$owner_ip" = "${REMOTE_ADDR:-}" && "$attempt_scope" = "$scope" && -z "${extra:-}" ]] || fail '404 Not Found' 'attempt not found'
    if [[ "${f[request_class]}" != main_frame ]]; then
      [[ "$trigger" = critical_resource_repeated_failure && "${f[request_class]}" =~ ^(script|xmlhttprequest|media)$ ]] || fail '400 Bad Request' 'critical-resource result does not match this attempt'
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
    if [[ "$state" = WAIT_NEW_FLOW ]]; then browser_confirm_flow || fail '409 Conflict' 'new production flow with selected strategy is not confirmed'; state=FLOW_CONFIRMED; fi
    if [[ "$state" = FLOW_CONFIRMED ]]; then
      adaptive_browser_attempt_transition "$attempt_id" FLOW_CONFIRMED WAIT_BROWSER_RESULT || fail '409 Conflict' 'attempt changed concurrently'
      state=WAIT_BROWSER_RESULT
    fi
    flow_row="$(adaptive_browser_flow_read "$attempt_id" "$generation" 2>/dev/null)" || fail '409 Conflict' 'production flow evidence is unavailable'
    IFS=$'\t' read -r flow_ver flow_id flow_generation flow_client flow_scope flow_host flow_ip flow_profile flow_proto flow_strategy flow_fingerprint syn_at selected_at flow_extra <<< "$flow_row"
    [[ "$flow_client" = "$client_id" && "$flow_scope" = "$attempt_scope" && "$flow_host" = "$host" && "$flow_ip" = "$ip" && "${f[browser_ip]}" = "$flow_ip" &&
       "$flow_profile" = "$profile" && "$flow_proto" = "$proto" && "$flow_strategy" = "$strategy" && "$flow_fingerprint" = "$attempt_fingerprint" ]] || fail '409 Conflict' 'production flow does not match this attempt'
    (( f[observed_at] >= selected_at * 1000 && f[observed_at] <= now_ms + 5000 && f[observed_at] <= expires * 1000 )) || fail '400 Bad Request' 'result is outside the confirmed flow window'
    [[ "$state" = WAIT_BROWSER_RESULT || "$state" = PROVISIONAL_SUCCESS ]] || fail '409 Conflict' 'attempt is not waiting for a browser result'
    if [[ "$proto" = quic && "${f[browser_protocol]:-}" != h3 ]]; then
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
    if [[ "$state" = CONFIRMED_FAILURE ]]; then
      next_claim="$(adaptive_browser_event_claim "$client_id" "${f[browser_event_id]}" "$host" "$trigger" "$(date +%s)")" || next_claim=unavailable
      if [[ "$next_claim" = accepted ]]; then
        next_target="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$host" "$ip" "$profile" "$proto" "$attempt_scope" "$(date +%s)")"
        next_trial_json="$(browser_start_trial "$next_target" "$trigger" "$client_id" "${REMOTE_ADDR:-}" "$attempt_scope")"
        next_trial_rc=$?
        if [[ "$next_trial_rc" = 0 ]]; then
          send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"NEXT_CANDIDATE\",\"next_attempt\":$next_trial_json}"
        fi
      fi
    fi
    send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"$state\"}"
    ;;
  *) fail '400 Bad Request' 'unknown browser action' ;;
esac
