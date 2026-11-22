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
adaptive_browser_client_auth "$provided" "${REMOTE_ADDR:-}" "$origin" || fail '401 Unauthorized' 'invalid, expired, or out-of-scope browser token'
client_id="$ADAPTIVE_BROWSER_CLIENT_ID"; scope="$ADAPTIVE_BROWSER_CLIENT_SCOPE"

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
    # Until production-flow trial selection is installed, do not claim that a
    # strategy was applied. This explicit state is replaced by the session engine.
    send '503 Service Unavailable' '{"schema_version":1,"status":"TRIAL_ENGINE_UNAVAILABLE","state":"NOT_TESTED"}'
    ;;
  browser_attempt_status|browser_cancel_attempt)
    [[ ${#f[@]} -eq 3 && "${f[attempt_id]:-}" =~ ^[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid attempt id'
    row="$(adaptive_browser_attempt_read "${f[attempt_id]}")" || fail '404 Not Found' 'attempt not found'
    IFS=$'\t' read -r ver attempt_id owner owner_ip attempt_scope host ip profile proto trigger state strategy fingerprint created expires generation extra <<< "$row"
    [[ "$ver" = 1 && "$owner" = "$client_id" && "$owner_ip" = "${REMOTE_ADDR:-}" && "$attempt_scope" = "$scope" && -z "${extra:-}" ]] || fail '404 Not Found' 'attempt not found'
    now="$(date +%s)"
    if (( now > expires )); then
      case "$state" in CONFIRMED_SUCCESS|CONFIRMED_FAILURE|UNKNOWN|NOT_TESTED|CANCELLED|EXPIRED|TARGET_NOT_MANAGED) ;;
        *) adaptive_browser_attempt_transition "$attempt_id" "$state" EXPIRED || fail '409 Conflict' 'attempt changed concurrently'; state=EXPIRED ;;
      esac
    elif [[ "${f[action]}" = browser_cancel_attempt ]]; then
      adaptive_browser_attempt_transition "$attempt_id" "$state" CANCELLED || fail '409 Conflict' 'attempt is terminal or changed concurrently'
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
