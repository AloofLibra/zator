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
  case "$key" in schema_version|action|browser_event_id|trigger|request_class|hostname|method|failure_class|failure_count|observed_at|attempt_id|result) ;;
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

browser_start_trial() {
  local target="$1" trigger="$2" client_id="$3" client_ip="$4" scope="$5"
  local host ip profile proto seen nfqws orch_dir now expires generation raw_id id
  local candidate_dir args_file candidate fingerprint recipe config_value
  IFS=$'\t' read -r host ip profile proto target_scope seen <<< "$target"
  [[ "$target_scope" = "$scope" && "$client_ip" = "$REMOTE_ADDR" ]] || return 2
  [[ ! -d "${Z2R_ADAPTIVE_LOCK_DIR:-/tmp/z2r-supersweep.lock}" ]] || return 4
  [[ "$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" NFQWS2_ENABLE 2>/dev/null | tr -d '"\047')" = 1 ]] || return 5
  case "$proto" in
    tls) recipe=tls-http1-v1 ;;
    googlevideo-tcp) recipe=googlevideo-tcp-media-v1 ;;
    *) return 3 ;;
  esac
  ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
  ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
  adaptive_browser_profile_lock_check "$profile" "$scope" "$ORCH_DIR"
  case $? in 1) ;; *) return 6 ;; esac
  nfqws="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
  [[ -x "$nfqws" ]] || return 3
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
  CONFIG_FILE="${ZAPRET2_ROOT:-/opt/zapret2}/config"
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
  adaptive_browser_attempt_write "$id" "$client_id" "$client_ip" "$scope" "$host" "$ip" "$profile" "$proto" "$trigger" QUEUED "$strategy" "$fingerprint" "$now" "$expires" "$generation" || return 1
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

case "${f[action]:-}" in
  browser_hello|browser_status)
    [[ ${#f[@]} -eq 2 ]] || fail '400 Bad Request' 'browser_hello takes no parameters'
    mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null || printf OFF)"
    case "$mode" in OFF|OBSERVE|TEST_ONLY|AGENT_BETA|PAUSED) ;; *) mode=OFF ;; esac
    send '200 OK' "{\"schema_version\":1,\"client_id\":\"$client_id\",\"scope\":\"$scope\",\"mode\":\"$mode\",\"status\":\"paired\"}"
    ;;
  browser_report_failure)
    [[ ${#f[@]} -eq 10 && "${f[trigger]:-}" =~ ^(main_frame_network_failure|critical_resource_repeated_failure|user_fix)$ &&
       "${f[request_class]:-}" =~ ^(main_frame|script|xmlhttprequest|media)$ && "${f[method]:-}" =~ ^(GET|HEAD|UNSAFE)$ &&
       "${f[failure_class]:-}" =~ ^(network_failure|user_requested|http_(403|451|500|502|503|504))$ &&
       "${f[failure_count]:-}" =~ ^[12]$ &&
       "${f[browser_event_id]:-}" =~ ^[a-f0-9]{32}$ && "${f[observed_at]:-}" =~ ^[0-9]{13}$ ]] || fail '400 Bad Request' 'invalid failure event'
    trigger="${f[trigger]}"; klass="${f[request_class]}"; method="${f[method]}"; failure="${f[failure_class]}"
    mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null || printf OFF)"
    [[ "$mode" = AGENT_BETA ]] || send '200 OK' "{\"schema_version\":1,\"status\":\"OBSERVE_ONLY\",\"state\":\"NOT_TESTED\",\"mode\":\"$mode\"}"
    if [[ "$trigger" = main_frame_network_failure ]]; then
      [[ "$klass" = main_frame && "$method" = GET && "$failure" = network_failure && "${f[failure_count]}" = 1 ]] || fail '400 Bad Request' 'main-frame trigger mismatch'
    elif [[ "$trigger" = critical_resource_repeated_failure ]]; then
      [[ "$klass" =~ ^(script|xmlhttprequest|media)$ && "$method" != UNSAFE && "$failure" = network_failure && "${f[failure_count]}" = 2 ]] || fail '400 Bad Request' 'resource trigger mismatch'
    elif [[ "${f[failure_count]}" != 1 ]]; then fail '400 Bad Request' 'manual trigger count mismatch'
    elif [[ "$failure" = http_* ]]; then :; fi
    host="${f[hostname],,}"
    adaptive_browser_host_valid "$host" || fail '400 Bad Request' 'invalid target hostname'
    host="$ADAPTIVE_BROWSER_HOST"
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
    now="$(date +%s)"; matches="$(adaptive_browser_resolve_observation "$host" "$scope" "$events" "$now" 2>/dev/null)" || send '200 OK' '{"schema_version":1,"status":"TARGET_NOT_MANAGED","state":"TARGET_NOT_MANAGED"}'
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
      5) send '200 OK' '{"schema_version":1,"status":"POLICY_BLOCKED","state":"NOT_TESTED"}' ;;
      6) send '200 OK' '{"schema_version":1,"status":"MANUAL_LOCKED","state":"NOT_TESTED"}' ;;
      7) send '200 OK' '{"schema_version":1,"status":"ACTIVE_ATTEMPT","state":"WAIT_NEW_FLOW"}' ;;
      *) send '200 OK' '{"schema_version":1,"status":"NO_CANDIDATE","state":"NOT_TESTED"}' ;;
    esac
    ;;
  browser_attempt_status|browser_cancel_attempt)
    [[ ${#f[@]} -eq 3 && "${f[attempt_id]:-}" =~ ^[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid attempt id'
    row="$(adaptive_browser_attempt_read "${f[attempt_id]}")" || fail '404 Not Found' 'attempt not found'
    IFS=$'\t' read -r ver attempt_id owner owner_ip attempt_scope host ip profile proto trigger state strategy fingerprint created expires generation extra <<< "$row"
    [[ "$ver" = 1 && "$owner" = "$client_id" && "$owner_ip" = "${REMOTE_ADDR:-}" && "$attempt_scope" = "$scope" && -z "${extra:-}" ]] || fail '404 Not Found' 'attempt not found'
    now="$(date +%s)"
    if (( now > expires )); then
      case "$state" in CONFIRMED_SUCCESS|CONFIRMED_FAILURE|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED|TARGET_NOT_MANAGED) ;;
        *) adaptive_browser_attempt_transition "$attempt_id" "$state" EXPIRED || fail '409 Conflict' 'attempt changed concurrently'; adaptive_browser_trial_remove "$attempt_id" "$generation" || :; state=EXPIRED ;;
      esac
    elif [[ "${f[action]}" = browser_cancel_attempt ]]; then
      adaptive_browser_attempt_transition "$attempt_id" "$state" CANCELLED || fail '409 Conflict' 'attempt is terminal or changed concurrently'
      adaptive_browser_trial_remove "$attempt_id" "$generation" || fail '503 Service Unavailable' 'trial cleanup failed'
      state=CANCELLED
    fi
    send '200 OK' "{\"schema_version\":1,\"attempt_id\":\"$attempt_id\",\"state\":\"$state\",\"expires_at\":$expires}"
    ;;
  browser_report_result)
    [[ ${#f[@]} -eq 7 && "${f[attempt_id]:-}" =~ ^[a-f0-9]{32}$ && "${f[browser_event_id]:-}" =~ ^[a-f0-9]{32}$ &&
       "${f[result]:-}" =~ ^(network_success|network_failure)$ && "${f[request_class]:-}" =~ ^(main_frame|script|xmlhttprequest|media)$ &&
       "${f[observed_at]:-}" =~ ^[0-9]{13}$ ]] || fail '400 Bad Request' 'invalid browser result'
    fail '501 Not Implemented' 'production flow evidence is required before accepting outcomes'
    ;;
  *) fail '400 Bad Request' 'unknown browser action' ;;
esac
