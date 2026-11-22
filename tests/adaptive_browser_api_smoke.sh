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
grep -q '"ranking_opt_in":false' <<< "$response"
[[ "$(cat "$Z2R_ADAPTIVE_BROWSER_DIR/presence/$client_id")" =~ ^[0-9]{10}$ ]] || { echo 'browser API did not record tmpfs presence' >&2; exit 1; }
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
if adaptive_browser_resolve_observation example.org mark:7 "$events" "$now"; then exit 1; else [[ "$?" = 3 ]]; fi
printf '1\tseen\twww.youtube.com\t8.8.8.8\t1\ttls\tmark:7\t%s\n' "$now" > "$events"
printf '1\tseen\twww.youtube.com\t1.1.1.1\t5\tquic\tmark:7\t%s\n' "$now" >> "$events"
if adaptive_browser_resolve_observation www.youtube.com mark:7 "$events" "$now"; then exit 1; fi
resolved="$(adaptive_browser_resolve_observation www.youtube.com mark:7 "$events" "$now" quic)"
[[ "$resolved" = $'www.youtube.com\t1.1.1.1\t5\tquic\tmark:7\t'"$now" ]]
resolved="$(adaptive_browser_resolve_observation www.youtube.com mark:7 "$events" "$now" tls)"
[[ "$resolved" = $'www.youtube.com\t8.8.8.8\t1\ttls\tmark:7\t'"$now" ]]

attempt=abcdefabcdefabcdefabcdefabcdefab
adaptive_browser_attempt_write "$attempt" "$client_id" 192.168.1.42 mark:7 example.org 203.0.113.10 1 tls main_frame_network_failure WAIT_NEW_FLOW 2 - "$(date +%s)" "$(( $(date +%s) + 30 ))" 1
line="$(adaptive_browser_attempt_read "$attempt")"
[[ "$line" = $'1\t'"$attempt"$'\t'"$client_id"*WAIT_NEW_FLOW* ]]
adaptive_browser_attempt_transition "$attempt" WAIT_NEW_FLOW FLOW_CONFIRMED
adaptive_browser_attempt_transition "$attempt" FLOW_CONFIRMED WAIT_BROWSER_RESULT
if adaptive_browser_attempt_transition "$attempt" WAIT_NEW_FLOW CANCELLED; then exit 1; fi
if adaptive_browser_attempt_transition "$attempt" WAIT_BROWSER_RESULT WAIT_NEW_FLOW; then exit 1; fi
if adaptive_browser_attempt_write ../bad "$client_id" 192.168.1.42 mark:7 example.org - 1 tls main_frame_network_failure WAIT_NEW_FLOW 2 - 1 2 1; then exit 1; fi

gc_now="$(date +%s)"
gc_make_attempt() {
  local gc_id="$1" created="$2" expires="$3" state="$4"
  printf '1\t%s\t%s\t192.168.1.42\tmark:7\texample.org\t8.8.8.8\t1\ttls\tmain_frame_network_failure\t%s\t2\t-\t%s\t%s\t1\n' \
    "$gc_id" "$client_id" "$state" "$created" "$expires" > "$(adaptive_browser_attempt_file "$gc_id")"
}
gc_old=11111111111111111111111111111111
gc_make_attempt "$gc_old" "$((gc_now - 301))" "$((gc_now - 256))" CONFIRMED_FAILURE
mkdir -p "$(adaptive_browser_flow_dir)"
printf 'stale\n' > "$(adaptive_browser_flow_dir)/$gc_old.1.tsv"
adaptive_browser_attempt_gc "$gc_now"
[[ ! -e "$(adaptive_browser_attempt_file "$gc_old")" && ! -e "$(adaptive_browser_flow_dir)/$gc_old.1.tsv" ]] || {
  echo 'stale browser attempt or flow evidence survived GC' >&2; exit 1;
}
gc_reserve_a=22222222222222222222222222222222
gc_reserve_b=33333333333333333333333333333333
adaptive_browser_attempt_gc "$gc_now" "$gc_reserve_a"
adaptive_browser_attempt_gc "$gc_now" "$gc_reserve_b"
[[ -d "$Z2R_ADAPTIVE_BROWSER_DIR/attempts/.reserve.$gc_reserve_a" && -d "$Z2R_ADAPTIVE_BROWSER_DIR/attempts/.reserve.$gc_reserve_b" ]] || {
  echo 'concurrent browser attempt capacity was not reserved' >&2; exit 1;
}
adaptive_browser_attempt_reservation_release "$gc_reserve_a"
adaptive_browser_attempt_reservation_release "$gc_reserve_b"
for i in $(seq 1000 1060); do
  gc_id="$(printf '%032x' "$i")"
  gc_make_attempt "$gc_id" "$gc_now" "$((gc_now + 45))" WAIT_NEW_FLOW
done
gc_reserve_c=44444444444444444444444444444444
gc_reserve_d=55555555555555555555555555555555
adaptive_browser_attempt_gc "$gc_now" "$gc_reserve_c"
adaptive_browser_attempt_gc "$gc_now" "$gc_reserve_d"
if adaptive_browser_attempt_gc "$gc_now" 66666666666666666666666666666666; then
  echo 'capacity reservation allowed more than 64 browser attempts' >&2; exit 1
else [[ "$?" = 3 ]]; fi
adaptive_browser_attempt_reservation_release "$gc_reserve_c"
adaptive_browser_attempt_reservation_release "$gc_reserve_d"
for i in $(seq 1000 1060); do rm -f -- "$(adaptive_browser_attempt_file "$(printf '%032x' "$i")")"; done
for i in $(seq 1 63); do
  gc_id="$(printf '%032x' "$i")"
  gc_make_attempt "$gc_id" "$gc_now" "$((gc_now + 45))" WAIT_NEW_FLOW
done
if adaptive_browser_attempt_gc "$gc_now"; then echo '64 fresh attempts exceeded the journal cap' >&2; exit 1
else [[ "$?" = 3 ]]; fi
for i in $(seq 1 63); do rm -f -- "$(adaptive_browser_attempt_file "$(printf '%032x' "$i")")"; done
adaptive_browser_attempt_gc "$gc_now"

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

ws_user="$(id -un)"
cat > "$ZAPRET2_ROOT/config" <<EOF
CLIENT_SCOPE_ENABLE=1
NFQWS2_ENABLE=1
WS_USER=$ws_user
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
# One eligible managed main-frame failure starts a scoped trial immediately;
# the first attempt must not perform a curl/DNS diagnosis.
mkdir -p "$ZATOR_ROOT/extra_strats/cache/orchestra"
trial_host=immediate.example.org
trial_now="$(date +%s)"
printf '1\tseen\t%s\t8.8.8.8\t1\ttls\tmark:7\t%s\n' "$trial_host" "$trial_now" > "$Z2R_ADAPTIVE_DIR/events.tsv"
mkdir -p "$tmp/mock-diagnostics"
for diagnostic in curl nslookup; do
  cat > "$tmp/mock-diagnostics/$diagnostic" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$0" >> "$Z2R_TEST_DIAGNOSTICS"
exit 99
EOF
  chmod +x "$tmp/mock-diagnostics/$diagnostic"
done
main_event=12121212121212121212121212121212
main_body="schema_version=1&action=browser_report_failure&browser_event_id=$main_event&trigger=main_frame_network_failure&request_class=main_frame&hostname=$trial_host&method=GET&failure_class=network_failure&failure_count=1&observed_at=$((trial_now * 1000))"
main_response="$(printf '%s' "$main_body" | env PATH="$tmp/mock-diagnostics:$PATH" Z2R_TEST_DIAGNOSTICS="$tmp/diagnostics-called" REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#main_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"state":"WAIT_NEW_FLOW"' <<< "$main_response"
[[ ! -e "$tmp/diagnostics-called" ]]
shopt -s nullglob
reservations=("$Z2R_ADAPTIVE_BROWSER_DIR/attempts"/.reserve.*)
[[ ${#reservations[@]} -eq 0 ]] || { echo 'successful trial left a capacity reservation behind' >&2; exit 1; }
shopt -u nullglob
# Multiple eligible production observations are ambiguous, not unmanaged, and
# must not create a trial.
ambiguous_now="$(date +%s)"
ambiguous_host=r1---sn.googlevideo.com
printf '1\tseen\t%s\t8.8.8.8\t2\tgooglevideo-tcp\tmark:7\t%s\n1\tseen\t%s\t1.1.1.1\t5\tquic\tmark:7\t%s\n' \
  "$ambiguous_host" "$ambiguous_now" "$ambiguous_host" "$ambiguous_now" > "$Z2R_ADAPTIVE_DIR/events.tsv"
ambiguous_event=13131313131313131313131313131313
ambiguous_body="schema_version=1&action=browser_report_failure&browser_event_id=$ambiguous_event&trigger=main_frame_network_failure&request_class=main_frame&hostname=$ambiguous_host&method=GET&failure_class=network_failure&failure_count=1&observed_at=$((ambiguous_now * 1000))"
ambiguous_response="$(printf '%s' "$ambiguous_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#ambiguous_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"status":"UNKNOWN"' <<< "$ambiguous_response"
grep -q '"reason":"ambiguous_recent_flows"' <<< "$ambiguous_response"
! grep -q '"attempt_id"' <<< "$ambiguous_response"
printf 'Example ISP - Test City\n' > "$ZATOR_ROOT/extra_strats/cache/provider.txt"
printf '1\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-rankings-opt-in"
adaptive_browser_rankings_opted_in
ranking_status_body='schema_version=1&action=browser_status'
ranking_status="$(printf '%s' "$ranking_status_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#ranking_status_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"ranking_opt_in":true' <<< "$ranking_status"
printf '%s\n' '--lua-desync=split:strategy=3' >> "$tmp/args/strategies"
sed -i '/--lua-desync=multisplit:strategy=2/a --lua-desync=split:strategy=3' "$ZAPRET2_ROOT/config"
rank_fp="$(adaptive_strategy_fingerprint 1 3 "$tmp/args/strategies" "$ZAPRET2_ROOT/nfq2/nfqws2" standard tls-http1-v1)"
ranking_file="$tmp/rankings.tsv"
printf 'schema_version=2\nstatus=fresh\ngenerated_at=%s\nprofile_id=1\nprotocol=tls\nstrategy\t%s\t0.900000\t10\t9\t1\n' "$(date +%s)" "$rank_fp" > "$ranking_file"
mkdir -p "$tmp/mockbin"
cat > "$tmp/mockbin/curl" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$Z2R_TEST_CURL_ARGS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$Z2R_TEST_RANKING_FILE" "$2"; exit $?; fi
  shift
done
exit 2
EOF
chmod +x "$tmp/mockbin/curl"
old_path="$PATH"
PATH="$tmp/mockbin:$PATH"
export Z2R_TEST_RANKING_FILE="$ranking_file" Z2R_TEST_CURL_ARGS="$tmp/curl-args"
selected="$(adaptive_browser_candidate_select example.org 8.8.8.8 1 tls default "$tmp/args/strategies" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ORCH_DIR" "$client_id")"
PATH="$old_path"
[[ "${selected%%$'\t'*}" = 3 ]]
! grep -q 'example.org\|8\.8\.8\.8' "$tmp/curl-args"
sed -i 's#sha256:.*#sha256:0000000000000000000000000000000000000000000000000000000000000000#' "$ranking_file"
PATH="$tmp/mockbin:$PATH"
selected="$(adaptive_browser_candidate_select example.org 8.8.8.8 1 tls default "$tmp/args/strategies" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ORCH_DIR" "$client_id")"
PATH="$old_path"
[[ "${selected%%$'\t'*}" = 2 ]]
rm -f "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-rankings-opt-in"
sed -i '/--lua-desync=split:strategy=3/d' "$ZAPRET2_ROOT/config"
printf '%s\n' '--lua-desync=fake:strategy=1' '--lua-desync=multisplit:strategy=2' > "$tmp/args/strategies"
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
mode_file="$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
mode_index=0
for inactive_mode in OFF OBSERVE TEST_ONLY; do
  printf '%s\n' "$inactive_mode" > "$mode_file"
  mode_index=$((mode_index + 1))
  mode_event="$(printf '%032x' "$mode_index")"
  mode_body="schema_version=1&action=browser_report_failure&browser_event_id=$mode_event&trigger=main_frame_network_failure&request_class=main_frame&method=GET&failure_class=network_failure&failure_count=1&hostname=mode-$inactive_mode.example.org&observed_at=$(date +%s%3N)"
  mode_response="$(printf '%s' "$mode_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#mode_body}" \
    HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
  grep -q '"status":"MODE_DISABLED"' <<< "$mode_response" || { echo "browser API applied a trial while mode=$inactive_mode" >&2; exit 1; }
done
printf 'AGENT_BETA\n' > "$mode_file"
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

video_attempt=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
video_host=rr1---sn-a5mekn6e.googlevideo.com
video_now="$(date +%s)"
video_expires=$((video_now + 30))
video_fingerprint="sha256:$(printf '%064d' 0 | tr 0 c)"
adaptive_browser_attempt_write "$video_attempt" "$client_id" 192.168.1.42 mark:7 "$video_host" 8.8.8.8 2 googlevideo-tcp main_frame_network_failure WAIT_NEW_FLOW 4 "$video_fingerprint" "$video_now" "$video_expires" 11
printf '1\t%s\t11\t%s\tmark:7\t%s\t8.8.8.8\t2\tgooglevideo-tcp\t4\t%s\t%s\t%s\tapplied\tconfirmed\n' \
  "$video_attempt" "$client_id" "$video_host" "$video_fingerprint" "$video_now" "$video_now" > "$flow_dir/$video_attempt.11.tsv"
video_flow_row="$(adaptive_browser_flow_read "$video_attempt" 11)" || { echo 'Googlevideo flow evidence was rejected by parser' >&2; exit 1; }
[[ "$video_flow_row" = *$'\tapplied\tconfirmed' ]] || { echo "unexpected flow evidence: $video_flow_row" >&2; exit 1; }
video_status_body="schema_version=1&action=browser_attempt_status&attempt_id=$video_attempt"
video_status_response="$(printf '%s' "$video_status_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#video_status_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"state":"FLOW_CONFIRMED"' <<< "$video_status_response"
grep -q '"ramp_treatment":"applied"' <<< "$video_status_response"
grep -q '"ramp_ack_evidence":"confirmed"' <<< "$video_status_response"
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

critical_attempt=efefefefefefefefefefefefefefefef
critical_generation=8
critical_now="$(date +%s)"
critical_expires=$((critical_now + 30))
adaptive_browser_attempt_write "$critical_attempt" "$client_id" 192.168.1.42 mark:7 media.example.test 8.8.8.8 1 tls critical_resource_repeated_failure WAIT_BROWSER_RESULT "$selected_strategy" "$selected_fingerprint" "$critical_now" "$critical_expires" "$critical_generation"
printf '1\t%s\t%s\t%s\tmark:7\tmedia.example.test\t8.8.8.8\t1\ttls\t%s\t%s\t%s\t%s\n' \
  "$critical_attempt" "$critical_generation" "$client_id" "$selected_strategy" "$selected_fingerprint" "$critical_now" "$critical_now" > "$flow_dir/$critical_attempt.$critical_generation.tsv"
critical_success_body="schema_version=1&action=browser_report_result&attempt_id=$critical_attempt&browser_event_id=12121212121212121212121212121212&result=network_success&request_class=xmlhttprequest&browser_ip=8.8.8.8&observed_at=$((critical_now * 1000))"
critical_success_response="$(printf '%s' "$critical_success_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#critical_success_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"state":"PROVISIONAL_SUCCESS"' <<< "$critical_success_response"
wrong_class_body="schema_version=1&action=browser_report_result&attempt_id=$attempt_flow&browser_event_id=13131313131313131313131313131313&result=network_success&request_class=xmlhttprequest&browser_ip=8.8.8.8&observed_at=$((critical_now * 1000))"
wrong_class_response="$(printf '%s' "$wrong_class_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#wrong_class_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q 'critical-resource result does not match this attempt' <<< "$wrong_class_response"
wrong_class_failure_body="schema_version=1&action=browser_report_result&attempt_id=$attempt_flow&browser_event_id=14141414141414141414141414141414&result=network_failure&request_class=script&browser_ip=8.8.8.8&observed_at=$((critical_now * 1000))"
wrong_class_failure_response="$(printf '%s' "$wrong_class_failure_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#wrong_class_failure_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q 'critical-resource result does not match this attempt' <<< "$wrong_class_failure_response"

# A failed post-trial main-frame request chooses exactly the next candidate,
# bounded by the same per-host event budget and a fresh production flow.
attempt_failed=ffffffffffffffffffffffffffffffff
failed_generation=9
failed_now="$(date +%s)"
failed_expires=$((failed_now + 30))
adaptive_browser_attempt_write "$attempt_failed" "$client_id" 192.168.1.42 mark:7 example.org 8.8.8.8 1 tls main_frame_network_failure WAIT_NEW_FLOW "$selected_strategy" "$selected_fingerprint" "$failed_now" "$failed_expires" "$failed_generation"
adaptive_browser_trial_add "$attempt_failed" "$failed_generation" "$client_id" 192.168.1.42 mark:7 example.org 8.8.8.8 1 tls "$selected_strategy" "$selected_fingerprint" "$failed_now" "$failed_expires"
printf '1\t%s\t%s\t%s\tmark:7\texample.org\t8.8.8.8\t1\ttls\t%s\t%s\t%s\t%s\n' \
  "$attempt_failed" "$failed_generation" "$client_id" "$selected_strategy" "$selected_fingerprint" "$failed_now" "$failed_now" > "$flow_dir/$attempt_failed.$failed_generation.tsv"
rm -f "$tmp/runtime/browser/events/$client_id.tsv"
failed_result_ms="$(( $(date +%s) * 1000 ))"
failed_body="schema_version=1&action=browser_report_result&attempt_id=$attempt_failed&browser_event_id=99999999999999999999999999999999&result=network_failure&request_class=main_frame&browser_ip=8.8.8.8&observed_at=$failed_result_ms"
failed_response="$(printf '%s' "$failed_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#failed_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"state":"NEXT_CANDIDATE"' <<< "$failed_response"
grep -q '"attempt_id":"[a-f0-9]\{32\}"' <<< "$failed_response"
grep -q '"strategy":1' <<< "$failed_response"

# A browser success after a confirmed profile-5 flow is not QUIC success unless
# Chromium provides reliable H3 protocol evidence (the current extension does not).
quic_attempt=abababababababababababababababab
quic_generation=10
quic_host=rr1---sn-a5mekn6e.googlevideo.com
quic_now="$(date +%s)"
quic_expires=$((quic_now + 30))
quic_fingerprint="sha256:$(printf '%064d' 0 | tr 0 c)"
quic_strategy=2
adaptive_browser_attempt_write "$quic_attempt" "$client_id" 192.168.1.42 mark:7 "$quic_host" 8.8.8.8 5 quic main_frame_network_failure WAIT_BROWSER_RESULT "$quic_strategy" "$quic_fingerprint" "$quic_now" "$quic_expires" "$quic_generation"
printf '1\t%s\t%s\t%s\tmark:7\t%s\t8.8.8.8\t5\tquic\t%s\t%s\t%s\t%s\n' \
  "$quic_attempt" "$quic_generation" "$client_id" "$quic_host" "$quic_strategy" "$quic_fingerprint" "$quic_now" "$quic_now" > "$flow_dir/$quic_attempt.$quic_generation.tsv"
quic_result_body="schema_version=1&action=browser_report_result&attempt_id=$quic_attempt&browser_event_id=abababababababababababababababab&result=network_success&request_class=main_frame&browser_ip=8.8.8.8&observed_at=$((quic_now * 1000))"
quic_result_response="$(printf '%s' "$quic_result_body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#quic_result_body}" \
  HTTP_ORIGIN="$origin" HTTP_AUTHORIZATION="Bearer $token" REMOTE_ADDR=192.168.1.42 bash "$ROOT/webui/cgi-bin/adaptive-browser.cgi")"
grep -q '"state":"UNKNOWN"' <<< "$quic_result_response"
grep -q '"status":"PROTOCOL_UNKNOWN"' <<< "$quic_result_response"
grep -q '"reason":"h3_protocol_evidence_unavailable"' <<< "$quic_result_response"
if grep -q '"state":"CONFIRMED_SUCCESS"' <<< "$quic_result_response"; then
  echo 'browser success on a QUIC trial was incorrectly counted as H3 success' >&2; exit 1;
fi
echo 'adaptive browser API smoke: OK'
