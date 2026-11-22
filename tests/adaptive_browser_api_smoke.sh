#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2"
export Z2R_ADAPTIVE_BROWSER_CLIENTS_FILE="$tmp/zator/extra_strats/cache/adaptive/browser-clients.tsv"
export Z2R_ADAPTIVE_BROWSER_DIR="$tmp/runtime/browser" Z2R_ADAPTIVE_DIR="$tmp/runtime"
export CLIENT_SCOPE_MAP_FILE="$tmp/zator/extra_strats/cache/client_scope.tsv"
mkdir -p "$tmp/zator/extra_strats/cache/adaptive" "$tmp/zapret2" "$tmp/runtime"
mkdir -p "$tmp/zator/z2r_lib"
cp "$ROOT/lib/config.sh" "$ROOT/lib/orchestra_state.sh" "$ROOT/lib/adaptive_browser.sh" "$ROOT/lib/adaptive_rules.sh" "$ROOT/lib/supersweep_probe.sh" "$tmp/zator/z2r_lib/"
mkdir -p "$tmp/zator/lua"
cp "$ROOT/orchestra/locked.lua" "$tmp/zator/lua/locked.lua"
printf 'AGENT_BETA\n' > "$tmp/zator/extra_strats/cache/adaptive/mode"
printf 'CLIENT_SCOPE_ENABLE=1\n' > "$tmp/zapret2/config"
printf 'mark:7\t192.168.1.42\n' > "$CLIENT_SCOPE_MAP_FILE"
config_get_var() { awk -F= -v k="$2" '$1==k {print $2; exit}' "$1"; }
. "$ROOT/lib/adaptive_browser.sh"

token="$(printf '%064d' 0 | tr 0 a)"
hash="$(printf '%s' "$token" | sha256sum | awk '{print $1}')"
client_id=0123456789abcdef0123456789abcdef
printf '1\t%s\t%s\t192.168.1.42\tmark:7\t%s\n' "$client_id" "$hash" "$(( $(date +%s) + 3600 ))" > "$Z2R_ADAPTIVE_BROWSER_CLIENTS_FILE"
chmod 600 "$Z2R_ADAPTIVE_BROWSER_CLIENTS_FILE"

origin=chrome-extension://abcdefghijklmnopabcdefghijklmnop
body='schema_version=1&action=browser_hello'
response="$(printf '%s' "$body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 \
  bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"status":"paired"' <<< "$response"
grep -q "Access-Control-Allow-Origin: $origin" <<< "$response"
preflight="$(env REQUEST_METHOD=OPTIONS HTTP_ORIGIN="$origin" HTTP_ACCESS_CONTROL_REQUEST_METHOD=POST \
  HTTP_ACCESS_CONTROL_REQUEST_PRIVATE_NETWORK=true bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi" </dev/null)"
grep -q 'Status: 204 No Content' <<< "$preflight"
grep -q 'Access-Control-Allow-Private-Network: true' <<< "$preflight"
wrong_origin="$(printf '%s' "$body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#body}" \
  HTTP_ORIGIN=https://example.org HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 \
  bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q 'Status: 403 Forbidden' <<< "$wrong_origin"
observed_ms="$(( $(date +%s) * 1000 ))"
critical_body="schema_version=1&action=browser_report_failure&browser_event_id=11111111111111111111111111111111&trigger=critical_resource_repeated_failure&request_class=script&hostname=unseen.example.org&method=GET&failure_class=network_failure&failure_count=2&observed_at=$observed_ms"
critical="$(printf '%s' "$critical_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#critical_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"status":"TARGET_NOT_MANAGED"' <<< "$critical"

adaptive_browser_client_auth "$token" 192.168.1.42 chrome-extension://abcdefghijklmnopabcdefghijklmnop
[[ "$ADAPTIVE_BROWSER_CLIENT_ID" = "$client_id" && "$ADAPTIVE_BROWSER_CLIENT_SCOPE" = mark:7 ]]
if adaptive_browser_client_auth "$token" 192.168.1.43 chrome-extension://abcdefghijklmnopabcdefghijklmnop; then exit 1; fi
if adaptive_browser_client_auth "$token" 192.168.1.42 https://example.org; then exit 1; fi

now="$(date +%s)"
[[ "$(adaptive_browser_event_claim "$client_id" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa example.org main_frame_network_failure "$now")" = accepted ]]
[[ "$(adaptive_browser_event_claim "$client_id" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa example.org main_frame_network_failure "$now")" = duplicate ]]
[[ "$(adaptive_browser_event_claim "$client_id" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb example.org main_frame_network_failure "$now")" = accepted ]]
[[ "$(adaptive_browser_event_claim "$client_id" cccccccccccccccccccccccccccccccc example.org main_frame_network_failure "$now")" = accepted ]]
[[ "$(adaptive_browser_event_claim "$client_id" dddddddddddddddddddddddddddddddd example.org main_frame_network_failure "$now")" = accepted ]]
[[ "$(adaptive_browser_event_claim "$client_id" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee example.org main_frame_network_failure "$now")" = accepted ]]
[[ "$(adaptive_browser_event_claim "$client_id" ffffffffffffffffffffffffffffffff example.org main_frame_network_failure "$now")" = budget ]]

now="$(date +%s)"
events="$tmp/runtime/events.tsv"
printf '1\tseen\texample.org\t8.8.8.8\t1\ttls\tmark:7\t%s\n' "$now" > "$events"
resolved="$(adaptive_browser_resolve_observation example.org mark:7 "$events" "$now")"
[[ "$resolved" = $'example.org\t8.8.8.8\t1\ttls\tmark:7\t'"$now" ]]
printf '1\tseen\texample.org\t1.1.1.1\t1\ttls\tmark:7\t%s\n' "$now" >> "$events"
if adaptive_browser_resolve_observation example.org mark:7 "$events" "$now"; then exit 1; fi

attempt=abcdefabcdefabcdefabcdefabcdefab
adaptive_browser_attempt_write "$attempt" "$client_id" 192.168.1.42 mark:7 example.org 203.0.113.10 1 tls main_frame_network_failure WAIT_NEW_FLOW 2 - "$(date +%s)" "$(( $(date +%s) + 30 ))" 1
line="$(adaptive_browser_attempt_read "$attempt")"
[[ "$line" = $'1\t'"$attempt"$'\t'"$client_id"*WAIT_NEW_FLOW* ]]
adaptive_browser_attempt_transition "$attempt" WAIT_NEW_FLOW FLOW_CONFIRMED
adaptive_browser_attempt_transition "$attempt" FLOW_CONFIRMED WAIT_BROWSER_RESULT
if adaptive_browser_attempt_transition "$attempt" WAIT_NEW_FLOW CANCELLED; then exit 1; fi
if adaptive_browser_attempt_transition "$attempt" WAIT_BROWSER_RESULT WAIT_NEW_FLOW; then exit 1; fi
if adaptive_browser_attempt_write ../bad "$client_id" 192.168.1.42 mark:7 example.org - 1 tls main_frame_network_failure WAIT_NEW_FLOW 2 - 1 2 1; then exit 1; fi

trial_id=99999999999999999999999999999999
trial_now="$(date +%s)"
adaptive_browser_trial_add "$trial_id" 1 "$client_id" 192.168.1.42 mark:7 example.org 8.8.8.8 1 tls 2 - "$trial_now" "$((trial_now + 45))"
[[ "$(awk -F '\t' 'END {print NF}' "$(adaptive_browser_trials_file)")" = 14 ]]
if adaptive_browser_trial_add 88888888888888888888888888888888 1 "$client_id" 192.168.1.42 mark:7 example.org 8.8.8.8 1 tls 3 - "$trial_now" "$((trial_now + 45))"; then exit 1; else [[ "$?" = 3 ]]; fi
adaptive_browser_trial_remove "$trial_id" 1
if grep -q "$trial_id" "$(adaptive_browser_trials_file)"; then exit 1; fi

bash -n "$ROOT/webui/cgi-bin/adaptive-browser.cgi" "$ROOT/lib/adaptive_browser.sh" "$ROOT/tools/adaptive-browser-pair.sh"
grep -q 'browser_hello' "$ROOT/webui/cgi-bin/adaptive-browser.cgi"
grep -q 'browser_cancel_attempt' "$ROOT/webui/cgi-bin/adaptive-browser.cgi"
! grep -q 'TOKEN_FILE=.*adaptive/token$' "$ROOT/webui/cgi-bin/adaptive-browser.cgi"

cat > "$ZAPRET2_ROOT/config" <<'EOF'
CLIENT_SCOPE_ENABLE=1
NFQWS2_ENABLE=1
FWTYPE=nft
DESYNC_MARK=0x40000000
NFQWS2_OPT="
--template=z2r_tcp_tls_common
--lua-desync=fake:strategy=1
--new
#Z2R_AUTO_STANDARD_1_BEGIN
--lua-desync=fake:strategy=1
--lua-desync=multisplit:strategy=2
#Z2R_AUTO_STANDARD_1_END
--new
"
EOF
mkdir -p "$ZAPRET2_ROOT/nfq2" "$tmp/orchestra" "$tmp/args"
cat > "$ZAPRET2_ROOT/nfq2/nfqws2" <<'EOF'
#!/usr/bin/env sh
if [ "${1:-}" = --version ]; then echo 'nfqws2 test 1'; exit 0; fi
exit 1
EOF
chmod +x "$ZAPRET2_ROOT/nfq2/nfqws2"
printf '%s\n' '--lua-desync=fake:strategy=1' '--lua-desync=multisplit:strategy=2' > "$tmp/args/strategies"
ORCH_DIR="$tmp/orchestra"
. "$ROOT/lib/config.sh"
. "$ROOT/lib/adaptive_rules.sh"
. "$ROOT/lib/supersweep_probe.sh"
selected="$(adaptive_browser_candidate_select example.org 8.8.8.8 1 tls default "$tmp/args/strategies" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ORCH_DIR" "$client_id")"
[[ "${selected%%$'\t'*}" = 2 ]]
printf '1\ttls\t6\n' > "$ORCH_DIR/locked.tsv"
if adaptive_browser_candidate_select example.org 8.8.8.8 1 tls default "$tmp/args/strategies" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ORCH_DIR" "$client_id"; then exit 1; else [[ "$?" = 4 ]]; fi
rm -f "$ORCH_DIR/locked.tsv"
mkdir -p "$ORCH_DIR/scopes"
printf '1\ttls\t5\n' > "$ORCH_DIR/scopes/mark_7.tsv"
if adaptive_browser_candidate_select example.org 8.8.8.8 1 tls mark:7 "$tmp/args/strategies" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ORCH_DIR" "$client_id"; then exit 1; else [[ "$?" = 4 ]]; fi
rm -f "$ORCH_DIR/scopes/mark_7.tsv"
printf '1\ttls\t6\n' > "$ORCH_DIR/locked.tsv"
if adaptive_browser_candidate_select example.org 8.8.8.8 1 tls mark:7 "$tmp/args/strategies" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ORCH_DIR" "$client_id"; then exit 1; else [[ "$?" = 4 ]]; fi
rm -f "$ORCH_DIR/locked.tsv"
now="$(date +%s)"
adaptive_browser_attempt_write aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$client_id" 192.168.1.42 default example.org 8.8.8.8 1 tls main_frame_network_failure CONFIRMED_FAILURE 2 - "$now" "$((now + 45))" 1
adaptive_browser_candidate_confirmed_failed "$client_id" example.org 8.8.8.8 1 tls default 2 "$now"
if adaptive_browser_candidate_select example.org 8.8.8.8 1 tls default "$tmp/args/strategies" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ORCH_DIR" "$client_id"; then exit 1; else [[ "$?" = 3 ]]; fi

attempt_flow=cccccccccccccccccccccccccccccccc
flow_now="$(date +%s)"
flow_expires=$((flow_now + 30))
selected_strategy="${selected%%$'\t'*}"
Z2R_SUPERSWEEP_DIR="$tmp/promotion-plan"; export Z2R_SUPERSWEEP_DIR
FWTYPE=nft DESYNC_MARK=0x40000000; export FWTYPE DESYNC_MARK
supersweep_probe_config 1 "$ZAPRET2_ROOT/config" standard 8.8.8.8 tls-http1-v1
selected_fingerprint="$(adaptive_strategy_fingerprint 1 "$selected_strategy" "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args" "$ZAPRET2_ROOT/nfq2/nfqws2" standard tls-http1-v1)"
adaptive_browser_attempt_write "$attempt_flow" "$client_id" 192.168.1.42 mark:7 example.org 8.8.8.8 1 tls main_frame_network_failure WAIT_NEW_FLOW "$selected_strategy" "$selected_fingerprint" "$flow_now" "$flow_expires" 3
flow_dir="$(adaptive_browser_flow_dir)"
mkdir -p "$flow_dir"
printf '1\t%s\t3\t%s\tmark:7\texample.org\t8.8.8.8\t1\ttls\t%s\t%s\t%s\t%s\n' \
  "$attempt_flow" "$client_id" "$selected_strategy" "$selected_fingerprint" "$flow_now" "$flow_now" > "$flow_dir/$attempt_flow.3.tsv"
status_body="schema_version=1&action=browser_attempt_status&attempt_id=$attempt_flow"
status_response="$(printf '%s' "$status_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#status_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"state":"FLOW_CONFIRMED"' <<< "$status_response"
observed_result_ms="$(( $(date +%s) * 1000 ))"
wrong_ip_body="schema_version=1&action=browser_report_result&attempt_id=$attempt_flow&browser_event_id=dddddddddddddddddddddddddddddddd&result=network_success&request_class=main_frame&browser_ip=1.1.1.1&observed_at=$observed_result_ms"
wrong_ip_response="$(printf '%s' "$wrong_ip_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#wrong_ip_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q 'production flow does not match' <<< "$wrong_ip_response"
result_body="schema_version=1&action=browser_report_result&attempt_id=$attempt_flow&browser_event_id=dddddddddddddddddddddddddddddddd&result=network_success&request_class=main_frame&browser_ip=8.8.8.8&observed_at=$observed_result_ms"
result_response="$(printf '%s' "$result_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#result_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"state":"PROVISIONAL_SUCCESS"' <<< "$result_response"
duplicate_result="$(printf '%s' "$result_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#result_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"status":"DUPLICATE"' <<< "$duplicate_result"
result_body="schema_version=1&action=browser_report_result&attempt_id=$attempt_flow&browser_event_id=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee&result=network_success&request_class=main_frame&browser_ip=8.8.8.8&observed_at=$observed_result_ms"
result_response="$(printf '%s' "$result_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#result_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"state":"CONFIRMED_SUCCESS"' <<< "$result_response"
echo 'adaptive browser API smoke: OK'
