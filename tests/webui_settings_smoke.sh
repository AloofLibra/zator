#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local pattern="$2"
  local message="$3"

  grep -Eq -- "$pattern" <<<"$text" || fail "$message"
}

assert_not_contains() {
  local text="$1"
  local pattern="$2"
  local message="$3"

  ! grep -Eq -- "$pattern" <<<"$text" || fail "$message"
}

TMP_DIR="$(mktemp -d /tmp/zator-webui-settings.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
export Z2R_ADAPTIVE_NDM_ROOT="$TMP_DIR/no-ndm"

ROOT="$TMP_DIR/zapret2"
CFG="$ROOT/config"
export ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export PROFILE_STATE_FILE="$TMP_DIR/profile.lock"
export ZAPRET2_INIT="$ROOT/init.d/sysv/zapret2"

mkdir -p "$ORCH_DIR" "$ROOT/init.d/sysv" "$TMP_DIR/backups"
tr -d '\r' < "$REPO_DIR/config.default" > "$CFG"
printf '#!/bin/sh\nexit 0\n' > "$ZAPRET2_INIT"
chmod +x "$ZAPRET2_INIT"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/actions.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/provider.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/ui.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/strategies.sh"

PROVIDER_CACHE="$TMP_DIR/provider.txt"
Z2R_BACKUP_DIR="$TMP_DIR/backups"

# == 0. Синтаксис изменённых файлов ==

for file in \
  "$REPO_DIR/lib/actions.sh" \
  "$REPO_DIR/lib/provider.sh" \
  "$REPO_DIR/webui/cgi-bin/_lib.sh" \
  "$REPO_DIR/webui/cgi-bin/settings.cgi" \
  "$REPO_DIR/webui/cgi-bin/backups.cgi"; do
  bash -n <(tr -d '\r' < "$file")
done
command -v node >/dev/null 2>&1 && node --check "$REPO_DIR/webui/app.js"
command -v python >/dev/null 2>&1 && python -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$REPO_DIR/webui/dev/fake_router_server.py"

# The report uses shared HTTP helpers without loading the heavy runtime libs.
mkdir -p "$TMP_DIR/panel/cgi-bin" "$TMP_DIR/runtime/z2r_lib"
sed "s#/opt/zator#$TMP_DIR/runtime#g; s#/opt/zapret2#$TMP_DIR/zapret2#g" \
  "$REPO_DIR/webui/cgi-bin/_lib.sh" > "$TMP_DIR/panel/cgi-bin/_lib.sh"
cat >> "$TMP_DIR/panel/cgi-bin/_lib.sh" <<'ADAPTIVE_RESTART_MOCK'
zapret2_running() { return 0; }
service_zapret2() { printf '%s\n' "$1" >> "$ADAPTIVE_RESTART_LOG"; }
ADAPTIVE_RESTART_MOCK
sed "s#/opt/zator/webui/cgi-bin/_lib.sh#$TMP_DIR/panel/cgi-bin/_lib.sh#" \
  "$REPO_DIR/webui/cgi-bin/settings.cgi" > "$TMP_DIR/panel/cgi-bin/settings.cgi"
printf 'exit 97\n' > "$TMP_DIR/runtime/z2r_lib/config.sh"
for file in orchestra_state strategies netcheck; do
  printf ':\n' > "$TMP_DIR/runtime/z2r_lib/$file.sh"
done
cat > "$TMP_DIR/runtime/z2r_lib/supersweep.sh" <<'REPORT'
supersweep_report_json() { printf '{"state":"idle"}\n'; }
REPORT
report="$(REQUEST_METHOD=GET QUERY_STRING=setting=supersweep bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -q 'Status: 200 OK' <<< "$report" || fail 'report fast path failed'
grep -q 'Cache-Control: no-store' <<< "$report" || fail 'report may be cached'
grep -Fq '{"state":"idle"}' <<< "$report" || fail 'report body changed'
[ "$(grep -c 'Content-Type:' <<< "$report")" = 1 ] || fail 'duplicate report headers'
printf 'supersweep_report_json() { return 1; }\n' > "$TMP_DIR/runtime/z2r_lib/supersweep.sh"
report="$(REQUEST_METHOD=GET QUERY_STRING=setting=supersweep bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -q 'Status: 500 Internal Server Error' <<< "$report" || fail 'report failure status changed'
printf ':\n' > "$TMP_DIR/runtime/z2r_lib/supersweep.sh"
report="$(REQUEST_METHOD=GET QUERY_STRING=setting=supersweep bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -q 'Status: 503 Service Unavailable' <<< "$report" || fail 'old core status changed'
# Статус h3-curl: тот же лёгкий fast-path (quic_media.sh сам тянет youtube_media.sh).
cat > "$TMP_DIR/runtime/z2r_lib/quic_media.sh" <<'H3CURL'
z2r_quic_curl_arch() { printf 'i686\n'; }
z2r_quic_curl_detect() { printf '/opt/zator/tools/bin/curl-h3-i686\n'; }
H3CURL
report="$(REQUEST_METHOD=GET QUERY_STRING=setting=h3_curl bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -q 'Status: 200 OK' <<< "$report" || fail 'h3_curl fast path failed'
grep -q 'Cache-Control: no-store' <<< "$report" || fail 'h3_curl may be cached'
grep -Fq '"found":true' <<< "$report" || fail 'h3_curl body changed'
grep -Fq '"arch":"i686"' <<< "$report" || fail 'h3_curl arch missing'
printf ':\n' > "$TMP_DIR/runtime/z2r_lib/quic_media.sh"
report="$(REQUEST_METHOD=GET QUERY_STRING=setting=h3_curl bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -q 'Status: 503 Service Unavailable' <<< "$report" || fail 'h3_curl old core status changed'
normal_rc=0
REQUEST_METHOD=GET QUERY_STRING=setting=ports bash "$TMP_DIR/panel/cgi-bin/settings.cgi" || normal_rc=$?
[ "$normal_rc" = 97 ] || fail 'ordinary settings skipped the runtime loader'

# Adaptive panel status and same-origin/LAN-only controls.
printf ':\n' > "$TMP_DIR/runtime/z2r_lib/config.sh"
mkdir -p "$TMP_DIR/runtime/extra_strats/cache/adaptive" "$TMP_DIR/runtime/tools" "$TMP_DIR/adaptive"
printf 'TEST_ONLY\n' > "$TMP_DIR/runtime/extra_strats/cache/adaptive/mode"
printf 'paired-token\n' > "$TMP_DIR/runtime/extra_strats/cache/adaptive/token"
pairing_expiry=$(( $(date +%s) + 3600 ))
printf '%s\n' "$pairing_expiry" > "$TMP_DIR/runtime/extra_strats/cache/adaptive/token.expires"
printf '4\t%s\tdeep_search\ttrue\tfalse\tdeep_scheduled\t12\t10\t2\t123456\t0\t23\t8589934592\t4096\t320\t65536\t0\t4\t1\t2\n' "$(date +%s)" > "$TMP_DIR/adaptive/agent.status.tsv"
renewal_status="$(Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq "\"pairing_expires_at\":$pairing_expiry" <<< "$renewal_status" || fail 'adaptive status omitted pairing expiry for renewal warning'
grep -Fq '"stage":"deep_search"' <<< "$renewal_status" || fail 'adaptive status omitted current DeepSearch phase'
grep -Fq '"fast_candidates":10,"deep_candidates":2' <<< "$renewal_status" || fail 'adaptive status omitted FastSearch/DeepSearch progress metrics'
grep -Fq '"statistics_enabled":true,"rankings_enabled":false' <<< "$renewal_status" || fail 'adaptive status omitted explicit statistics/rankings opt-in state'
grep -Fq '"pc_cpu_percent":23,"pc_free_memory_bytes":8589934592,"pc_network_bytes_per_second":4096' <<< "$renewal_status" || fail 'adaptive status omitted Windows runtime metrics'
grep -Fq '"router_load1_per_core":0.320,"router_memory_available_kib":65536,"router_active_probes":0' <<< "$renewal_status" || fail 'adaptive status omitted router runtime metrics'
grep -Fq '"revalidation_recoveries":4,"revalidation_failures":1,"success_after_apply":0' <<< "$renewal_status" || fail 'adaptive status omitted aggregate revalidation results'
grep -Fq '"cooldown_targets":2' <<< "$renewal_status" || fail 'adaptive status omitted target-free cooldown count'
printf '3\t%s\tcooldown\ttrue\tfalse\tdeep_scheduled\t12\t10\t2\t123456\t0\t23\t8589934592\t4096\t320\t65536\t0\t4\t1\n' "$(date +%s)" > "$TMP_DIR/adaptive/agent.status.tsv"
legacy_adaptive_status="$(Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"cooldown_targets":0' <<< "$legacy_adaptive_status" || fail 'legacy adaptive status did not default cooldown count to zero'
grep -Fq '"stage":"cooldown"' <<< "$legacy_adaptive_status" || fail 'adaptive panel API rejected the cooldown Watch stage'
printf '5\t%s\tdeep_search\ttrue\tfalse\tdeep_scheduled\t12\t10\t2\t123456\t0\t23\t8589934592\t4096\t320\t65536\t0\t4\t1\t3\t2\n' "$(date +%s)" > "$TMP_DIR/adaptive/agent.status.tsv"
v5_adaptive_status="$(Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"success_after_apply":3,"cooldown_targets":2' <<< "$v5_adaptive_status" || fail 'adaptive status omitted success-after-apply count'
printf '1\tseen\tcdn.example.org\t93.184.216.34\t1\ttls\tdefault\t%s\n1\tactive_rule_degraded\tcdn2.example.org\t93.184.216.35\t1\ttls\tdefault\t%s\n' "$(date +%s)" "$(date +%s)" > "$TMP_DIR/adaptive/events.tsv"
printf '1\tcdn.example.org\t93.184.216.34\t1\ttls\tdefault\t7\tsha256:%064d\tsha256:%064d\t1:2\t%s\n' 0 0 "$(( $(date +%s) + 3600 ))" > "$TMP_DIR/runtime/extra_strats/cache/adaptive/rules.tsv"
mkdir -p "$TMP_DIR/adaptive/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
printf '1\t%s\t%s\tSUCCESS\tmedia_ok\tgooglevideo-tcp-media-v1\tstandard\t2\tmark:4\t9\ttrue\ttrue\ttrue\t1048576\t2000000\t524\t12\n' "$(date +%s)" "$(date +%s)" > "$TMP_DIR/adaptive/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/status.tsv"
printf '{"probe_network_bytes":1234567}\n' > "$TMP_DIR/adaptive/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/result.json"
printf '%s\n' "$(date +%s)" > "$TMP_DIR/adaptive/agent.last"
printf '%s\n' 'adaptive_rule_remove() { printf "%s|%s|%s|%s\\n" "$@" >> "$ADAPTIVE_RULE_RESET_LOG"; }' > "$TMP_DIR/runtime/z2r_lib/adaptive_rules.sh"
cp "$REPO_DIR/lib/adaptive_queue.sh" "$TMP_DIR/runtime/z2r_lib/adaptive_queue.base.sh"
cat > "$TMP_DIR/runtime/z2r_lib/adaptive_queue.sh" <<'ADAPTIVE_QUEUE'
. "$LIB_DIR/adaptive_queue.base.sh"
adaptive_queue_request() { printf '%s|%s|%s|%s\n' "$@" >> "$ADAPTIVE_REQUEST_LOG"; printf '%032d\n' 1; }
ADAPTIVE_QUEUE
cat > "$TMP_DIR/runtime/tools/adaptive-pair.sh" <<'ADAPTIVE_CLI'
#!/bin/sh
printf '%s\n' "$1" >> "$ADAPTIVE_ACTION_LOG"
ADAPTIVE_CLI
chmod +x "$TMP_DIR/runtime/tools/adaptive-pair.sh"
adaptive_status="$(Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"paired":true' <<< "$adaptive_status" || fail 'adaptive pairing status missing'
grep -Fq '"mode":"TEST_ONLY"' <<< "$adaptive_status" || fail 'adaptive mode missing'
grep -Fq '"adaptive_rule_flipflops":0' <<< "$adaptive_status" || fail 'adaptive panel omitted the semantic flip-flop count'
grep -Fq '"event_count":2' <<< "$adaptive_status" || fail 'adaptive event count missing'
grep -Fq '"pending_requests":0' <<< "$adaptive_status" || fail 'adaptive request count missing'
grep -Fq '"hostname":"cdn.example.org"' <<< "$adaptive_status" || fail 'adaptive queue details missing'
grep -Fq '"strategy_number":7' <<< "$adaptive_status" || fail 'adaptive exact rule details missing'
grep -Fq '"last_probe":{"observed_at":' <<< "$adaptive_status" || fail 'adaptive status omitted the last probe summary'
grep -Fq '"reason":"media_ok"' <<< "$adaptive_status" || fail 'adaptive status omitted the last probe reason'
grep -Fq '"status":"active_rule_degraded"' <<< "$adaptive_status" || fail 'adaptive status omitted the degraded active-rule event'
grep -Fq '"media_bytes":1048576' <<< "$adaptive_status" || fail 'adaptive status omitted media transfer metrics'
grep -Fq '"probe_network_bytes":1234567' <<< "$adaptive_status" || fail 'adaptive status omitted test-queue IP byte metrics'
assert_not_contains "$adaptive_status" 'media_url_sha256' 'adaptive status exposed media URL hashes'
printf '1\tdirect.example.org\t93.184.216.35\t1\ttls\tmark:4\t0\tsha256:%064d\tsha256:%064d\t1:2\t%s\n' 0 0 "$(( $(date +%s) + 3600 ))" >> "$TMP_DIR/runtime/extra_strats/cache/adaptive/rules.tsv"
adaptive_direct_status="$(Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"hostname":"direct.example.org"' <<< "$adaptive_direct_status" || fail 'adaptive panel omitted the verified DIRECT rule'
grep -Fq '"strategy_number":0' <<< "$adaptive_direct_status" || fail 'adaptive panel did not preserve the DIRECT sentinel'
grep -Fq '"resources":{' <<< "$adaptive_status" || fail 'adaptive router capacity metrics missing'
grep -Fq '"agent_online":true' <<< "$adaptive_status" || fail 'adaptive status did not report a recent Windows agent heartbeat'
assert_not_contains "$adaptive_status" 'sha256:' 'adaptive GET exposed internal fingerprints'
assert_not_contains "$adaptive_status" paired-token 'adaptive GET exposed bearer token'
linux_adaptive_status="$(Z2R_ADAPTIVE_NDM_ROOT="$TMP_DIR/no-ndm" Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"ramp_audit_supported":true' <<< "$linux_adaptive_status" || fail 'adaptive panel disabled Ramp auditing on Linux/VPS'
grep -Fq '"ramp_exemptions_supported":true' <<< "$linux_adaptive_status" || fail 'adaptive panel disabled automatic Ramp exemptions outside the Keenetic-specific gate'
mkdir -p "$TMP_DIR/ndm"
keenetic_adaptive_status="$(Z2R_ADAPTIVE_NDM_ROOT="$TMP_DIR/ndm" Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"ramp_audit_supported":true' <<< "$keenetic_adaptive_status" || fail 'adaptive panel disabled Ramp auditing on Keenetic'
grep -Fq '"ramp_exemptions_supported":false' <<< "$keenetic_adaptive_status" || fail 'adaptive panel did not mark automatic Ramp exemptions unsupported on Keenetic'
grep -Fq 'keenetic_late_ack_gate_unverified' <<< "$keenetic_adaptive_status" || fail 'adaptive panel omitted the reason for the Keenetic exemption gate'
printf 'AGENT_BETA\n' > "$TMP_DIR/runtime/extra_strats/cache/adaptive/mode"
beta_status="$(Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"automatic_apply":true' <<< "$beta_status" || fail 'adaptive Beta status omitted enabled exact-rule application'
grep -Fq '"default_scope_apply":false' <<< "$beta_status" || fail 'adaptive Beta status overstated LAN-scope consent'
printf '1\n' > "$TMP_DIR/runtime/extra_strats/cache/adaptive/apply-default-scope"
beta_lan_status="$(Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"default_scope_apply":true' <<< "$beta_lan_status" || fail 'adaptive Beta status omitted explicit LAN-scope consent'
rm -f "$TMP_DIR/runtime/extra_strats/cache/adaptive/apply-default-scope"
printf 'TEST_ONLY\n' > "$TMP_DIR/runtime/extra_strats/cache/adaptive/mode"
printf '1\n' > "$TMP_DIR/adaptive/agent.last"
offline_agent_status="$(Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"agent_online":false' <<< "$offline_agent_status" || fail 'adaptive status reported a stale Windows agent heartbeat as online'
printf '%s\n' "$(date +%s)" > "$TMP_DIR/adaptive/agent.last"
printf '1\n' > "$TMP_DIR/runtime/extra_strats/cache/adaptive/token.expires"
expired_adaptive_status="$(Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=GET QUERY_STRING=setting=adaptive bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"paired":false' <<< "$expired_adaptive_status" || fail 'adaptive panel reported an expired token as paired'
grep -Fq '"pairing_expired":true' <<< "$expired_adaptive_status" || fail 'adaptive panel did not distinguish an expired pairing token'
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$TMP_DIR/runtime/extra_strats/cache/adaptive/token.expires"
export ADAPTIVE_ACTION_LOG="$TMP_DIR/adaptive-actions.log"
export ADAPTIVE_RESTART_LOG="$TMP_DIR/adaptive-restarts.log"
body='setting=adaptive_action&action=test-only'
adaptive_action="$(printf '%s' "$body" | Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#body}" HTTP_HOST=router.lan HTTP_ORIGIN=http://router.lan REMOTE_ADDR=192.168.1.7 bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq 'Status: 200 OK' <<< "$adaptive_action" || fail 'same-origin adaptive control failed'
grep -Fq '"action":"test-only"' <<< "$adaptive_action" || fail 'adaptive control response missing action'
grep -Fq '"restarted":true' <<< "$adaptive_action" || fail 'adaptive control did not reload the mode'
grep -Fxq 'test-only' "$ADAPTIVE_ACTION_LOG" || fail 'adaptive control did not delegate to CLI'
grep -Fxq 'restart' "$ADAPTIVE_RESTART_LOG" || fail 'adaptive mode change did not restart zapret2'
export ADAPTIVE_RULE_RESET_LOG="$TMP_DIR/adaptive-rule-reset.log"
reset_body='setting=adaptive_action&action=reset-rule&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=default'
reset_result="$(printf '%s' "$reset_body" | Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#reset_body}" HTTP_HOST=router.lan HTTP_ORIGIN=http://router.lan REMOTE_ADDR=192.168.1.7 bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"action":"reset-rule"' <<< "$reset_result" || fail 'exact adaptive rule reset failed'
grep -Fxq 'cdn.example.org|93.184.216.34|1|default' "$ADAPTIVE_RULE_RESET_LOG" || fail 'adaptive rule reset tuple changed'
export ADAPTIVE_REQUEST_LOG="$TMP_DIR/adaptive-request.log"
request_body='setting=adaptive_action&action=request-probe&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=default'
request_result="$(printf '%s' "$request_body" | Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#request_body}" HTTP_HOST=router.lan HTTP_ORIGIN=http://router.lan REMOTE_ADDR=192.168.1.7 bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq '"action":"request-probe"' <<< "$request_result" || fail 'manual adaptive probe request failed'
grep -Fq '"request_id":"00000000000000000000000000000001"' <<< "$request_result" || fail 'manual request id missing'
grep -Fxq 'cdn.example.org|93.184.216.34|1|default' "$ADAPTIVE_REQUEST_LOG" || fail 'manual request tuple changed'
cross_origin="$(printf '%s' "$body" | Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#body}" HTTP_HOST=router.lan HTTP_ORIGIN=http://evil.example REMOTE_ADDR=192.168.1.7 bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq 'Status: 403 Forbidden' <<< "$cross_origin" || fail 'cross-origin adaptive control accepted'
non_lan="$(printf '%s' "$body" | Z2R_ADAPTIVE_DIR="$TMP_DIR/adaptive" REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#body}" HTTP_HOST=router.lan HTTP_ORIGIN=http://router.lan REMOTE_ADDR=8.8.8.8 bash "$TMP_DIR/panel/cgi-bin/settings.cgi")"
grep -Fq 'Status: 403 Forbidden' <<< "$non_lan" || fail 'non-LAN adaptive control accepted'

# == 0b. custom.cgi: кастомные стратегии (CRUD поверх lib/custom_strategies.sh) ==
CUSTOM_DIR="$TMP_DIR/custom"
mkdir -p "$CUSTOM_DIR/panel/cgi-bin" "$CUSTOM_DIR/runtime/z2r_lib" \
  "$CUSTOM_DIR/runtime/extra_strats/cache/orchestra" "$CUSTOM_DIR/runtime/zapret2/files/fake"
sed "s#/opt/zator#$CUSTOM_DIR/runtime#g; s#/opt/zapret2#$CUSTOM_DIR/runtime/zapret2#g" \
  "$REPO_DIR/webui/cgi-bin/_lib.sh" > "$CUSTOM_DIR/panel/cgi-bin/_lib.sh"
sed "s#/opt/zator/webui/cgi-bin/_lib.sh#$CUSTOM_DIR/panel/cgi-bin/_lib.sh#" \
  "$REPO_DIR/webui/cgi-bin/custom.cgi" > "$CUSTOM_DIR/panel/cgi-bin/custom.cgi"
printf ':\n' > "$CUSTOM_DIR/runtime/z2r_lib/config.sh"
printf 'zapret2_running() { return 1; }\n' > "$CUSTOM_DIR/runtime/z2r_lib/orchestra_state.sh"
for file in strategies netcheck; do
  printf ':\n' > "$CUSTOM_DIR/runtime/z2r_lib/$file.sh"
done
cp "$REPO_DIR/lib/custom_strategies.sh" "$CUSTOM_DIR/runtime/z2r_lib/"
# Мок-конфиг: маркерные регионы (tpl/p5) и объявления блобов для валидации имён.
cat > "$CUSTOM_DIR/runtime/zapret2/config" <<CFG
--template=z2r_tcp_tls_common
--lua-desync=fake:blob=maxru:repeats=2:strategy=2
--new
--lua-desync=circular_locked:key=5:why=quic
--new
--blob=maxru:@/opt/zator/files/fake/tls_clienthello_max_ru.bin
--blob=fakewgblob:@/opt/zator/files/fake/wg_initial_fake_1.bin
CFG
custom_post() {
  local body="$1"
  printf '%s' "$body" | ZAPRET2_ROOT="$CUSTOM_DIR/runtime/zapret2" \
    ORCH_LOCK_FILE="$CUSTOM_DIR/runtime/extra_strats/cache/orchestra/locked.tsv" \
    REQUEST_METHOD=POST CONTENT_LENGTH="${#body}" \
    bash "$CUSTOM_DIR/panel/cgi-bin/custom.cgi"
}
custom_get() {
  ZAPRET2_ROOT="$CUSTOM_DIR/runtime/zapret2" \
    ORCH_LOCK_FILE="$CUSTOM_DIR/runtime/extra_strats/cache/orchestra/locked.tsv" \
    REQUEST_METHOD=GET QUERY_STRING="${1:-}" \
    bash "$CUSTOM_DIR/panel/cgi-bin/custom.cgi"
}
custom_config="$CUSTOM_DIR/runtime/zapret2/config"

report="$(custom_get)"
grep -Fq '"strategies":[]' <<<"$report" || fail "custom: свежий список не пуст"
report="$(custom_post 'action=add&block=p5&value=fake%3Ablob%3Dfakewgblob%3Arepeats%3D3&comment=test')"
grep -Fq '"ok":true,"id":1' <<<"$report" || fail "custom: валидная QUIC-стратегия не добавлена: $report"
report="$(custom_post 'action=add&block=p5&value=evil%3Acurl%3Ax')"
grep -q 'Неизвестный примитив' <<<"$report" || fail "custom: мусорный примитив прошёл валидацию: $report"
report="$(custom_post 'action=add&block=p5&value=fake%3Ablob%3Dfakewgblob%3Astrategy%3D2%3Arepeats%3D3')"
grep -q 'разобрать строку' <<<"$report" || fail "custom: strategy= в середине группы должен ронять разбор: $report"
report="$(custom_post 'action=add&block=tpl&value=--lua-desync%3Dmultidisorder%3Apos%3Dmidsld%3Astrategy%3D12&comment=auto')"
grep -Fq '"ok":true,"id":2' <<<"$report" || fail "custom: готовая строка конфига не нормализована: $report"
report="$(custom_get)"
grep -Fq '"spec":"multidisorder:pos=midsld"' <<<"$report" || fail "custom: normalize не срезал префикс/strategy=: $report"
grep -Fq '"assigned":""' <<<"$report" || fail "custom: assigned должен быть пуст до apply"
report="$(custom_post 'action=enable&id=1&value=0')"
grep -Fq '"ok":true' <<<"$report" || fail "custom: выключение не сработало"
report="$(custom_get)"
grep -Fq '"enabled":false' <<<"$report" || fail "custom: enabled не отразился в списке"
# Включённая tpl-стратегия при apply получает номер после максимума блока (2).
report="$(custom_post 'action=enable&id=2&value=1')"
report="$(custom_post 'action=apply')"
grep -Fq '"ok":true' <<<"$report" || fail "custom: apply упал: $report"
grep -qF 'strategy=' "$custom_config" || fail "custom: apply не дописал стратегии в конфиг"
grep -qF -- '--lua-desync=multidisorder:pos=midsld:strategy=3' "$custom_config" \
  || fail "custom: tpl-стратегия не получила номер после максимума блока (2)"
report="$(custom_get)"
grep -Fq '"assigned":"3"' <<<"$report" || fail "custom: assigned не обновился при apply: $report"
report="$(custom_post 'action=delete&id=2')"
grep -Fq '"ok":true' <<<"$report" || fail "custom: удаление не сработало"
report="$(custom_get)"
grep -Fq '"id":1,' <<<"$report" && grep -Fq '"id":2,' <<<"$report" \
  && fail "custom: удалённая запись осталась в списке"
report="$(custom_post 'action=enable&id=9&value=1')"
grep -q 'Нет записи 9' <<<"$report" || fail "custom: отсутствующий ID должен давать 400"
# Запись без комментария: два таба подряд в TSV — assigned не должен
# «уезжать» в комментарий (bash-read с табами сжимал пустые поля).
report="$(custom_post 'action=add&block=p5&value=fake%3Ablob%3Dfakewgblob%3Arepeats%3D6')"
grep -Fq '"ok":true,"id":2' <<<"$report" || fail "custom: запись без комментария не добавлена: $report"
report="$(custom_post 'action=apply')"
grep -Fq '"ok":true' <<<"$report" || fail "custom: повторный apply упал"
report="$(custom_get)"
grep -Fq '"id":2,"block":"p5","spec":"fake:blob=fakewgblob:repeats=6","enabled":true,"comment":"","assigned":"1"' \
  <<<"$report" || fail "custom: у записи без комментария assigned не дошёл до JSON: $report"

# == 1. Статические инварианты wiring'а ==

assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" '\$LIB_DIR/actions\.sh' "_lib.sh не подключает lib/actions.sh"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" '\$LIB_DIR/provider\.sh' "_lib.sh не подключает lib/provider.sh"

for fn in api_auto_mode_get api_hostlist_get api_rst_guard_get api_reasm_get api_quic443_get api_dns_desync_get api_wssize_ramp_get api_ports_get api_provider_get; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/settings.cgi")" "$fn" "settings.cgi GET не вызывает $fn"
done
for fn in api_auto_mode_set api_hostlist_set api_rst_guard_set api_reasm_set api_quic443_set api_dns_desync_set api_wssize_ramp_set api_ports_add api_ports_remove api_provider_set api_provider_redetect; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/settings.cgi")" "$fn" "settings.cgi POST не вызывает $fn"
done
# per-profile TLS блоб: POST-ветка + общий сеттер из orchestra_state.sh
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/settings.cgi")" 'tls_blob_profile' "settings.cgi POST не вызывает tls_blob_profile"
for fn in api_tls_blob_profile_set api_tls_blob_profile_blobs_json; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" "$fn" "_lib.sh нет $fn"
done
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'blob_override_file_valid' "api_tls_blob_profile_set без валидации файла"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" '"profile_blobs"' "GET/state не отдаёт profile_blobs"
# Профиль 5 (QUIC): валидация профиль-aware (иначе UDP-блобы отсеются TLS-фильтром),
# fake_default_tls для QUIC запрещён, кандидаты — свой список quic_blobs.
_lib_raw_check="$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")"
fake_py_check="$(cat "$REPO_DIR/webui/dev/fake_router_server.py")"
app_js_check="$(find "$REPO_DIR/webui-src/src" -type f \( -name '*.vue' -o -name '*.ts' \) -exec cat {} +)"
assert_contains "$_lib_raw_check" 'blob_override_file_valid "\$value" "\$profile"' "api_tls_blob_profile_set: валидация не профиль-aware"
assert_contains "$_lib_raw_check" 'fake_default_tls неприменим к QUIC-профилю' "api_tls_blob_profile_set: профиль 5 принимает fake_default_tls"
assert_contains "$_lib_raw_check" 'api_quic_blobs_json' "_lib.sh: нет списка QUIC-кандидатов"
assert_contains "$_lib_raw_check" '"quic_blobs"' "GET/state не отдаёт quic_blobs"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/settings.cgi")" 'h3_curl' "settings.cgi GET не знает h3_curl"
assert_contains "$_lib_raw_check" 'api_h3_curl_get' "_lib.sh: нет api_h3_curl_get"
assert_contains "$_lib_raw_check" 'z2r_quic_curl_detect' "api_h3_curl_get не использует детект quic_media"
for id in quic-blob-form 'tls-blob-quic-5' fetchH3Curl H3CurlStatus; do
  grep -rq "$id" "$REPO_DIR/webui-src/src" || fail "webui-src не содержит $id"
done
assert_contains "$app_js_check" "tls_blob_profile\('5'" "webui-src: QUIC-блоб не шлёт профиль 5"
assert_contains "$app_js_check" 'fetchH3Curl' "webui-src не загружает статус h3-curl"
assert_contains "$fake_py_check" '_scan_quic_blobs' "fake_router_server.py не отдаёт quic_blobs"
assert_contains "$fake_py_check" 'h3_curl' "fake_router_server.py без статуса h3-curl"
assert_contains "$fake_py_check" 'BLOB_OVERRIDE_PROFILE_IDS' "fake_router_server.py: профиль 5 не в переопределениях блобов"
assert_contains "$(cat "$REPO_DIR/webui/dev/API_CONTRACT.md")" 'h3_curl' "API_CONTRACT.md без h3_curl"
assert_contains "$(cat "$REPO_DIR/webui/dev/API_CONTRACT.md")" 'quic_blobs' "API_CONTRACT.md без quic_blobs"
# Кастомные стратегии в вебе: CGI-эндпоинт, либа-инжектор, фронт, мок, контракт.
[ -f "$REPO_DIR/webui/cgi-bin/custom.cgi" ] || fail "custom.cgi отсутствует"
grep -q 'api_custom_list' "$REPO_DIR/webui/cgi-bin/custom.cgi" || fail "custom.cgi GET без api_custom_list"
grep -q 'api_custom_action' "$REPO_DIR/webui/cgi-bin/custom.cgi" || fail "custom.cgi POST без api_custom_action"
# raw-установки качают cgi пофайлово (webui_install_files) — новый файл обязан
# быть в списке, иначе pack-zator-tar.mjs падает на кросс-проверке
grep -q 'cgi-bin/custom.cgi' "$REPO_DIR/z2r.sh" \
  || fail "webui_install_files: custom.cgi не качается при raw-установке"
assert_contains "$_lib_raw_check" 'custom_strategies_validate' "_lib.sh: кастомные стратегии без валидатора lib"
assert_contains "$_lib_raw_check" 'custom_strategies_apply_file' "_lib.sh: apply не использует инжектор lib"
assert_contains "$_lib_raw_check" 'custom_strategies.sh' "_lib.sh не source-ит lib/custom_strategies.sh"
grep -q 'custom-strats' "$REPO_DIR/webui-src/src/router/index.ts" || fail "роутер без /custom-strats"
grep -rq 'custom-strats' "$REPO_DIR/webui-src/src/App.vue" || fail "App.vue без вкладки кастомных стратегий"
for id in custom-strat-form custom-strat-spec custom-import-text custom-apply-btn custom-strats-filter; do
  grep -rq "$id" "$REPO_DIR/webui-src/src" || fail "webui-src не содержит #$id"
done
assert_contains "$app_js_check" 'fetchCustomStrats' "webui-src: нет загрузки custom.cgi"
assert_contains "$app_js_check" 'customStrats.apply' "webui-src: нет применения кастомных стратегий"
assert_contains "$fake_py_check" '_handle_custom' "fake_router_server.py без custom.cgi"
assert_contains "$fake_py_check" 'CUSTOM_BLOCKS' "fake_router_server.py без таблицы блоков"
assert_contains "$(cat "$REPO_DIR/webui/dev/API_CONTRACT.md")" 'custom.cgi' "API_CONTRACT.md без custom.cgi"

[ -f "$REPO_DIR/webui/cgi-bin/backups.cgi" ] || fail "backups.cgi отсутствует"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/backups.cgi")" '405 Method Not Allowed' "backups.cgi не отдаёт 405"
for fn in api_backups_list api_backups_create api_backups_delete api_backups_download api_backups_upload; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/backups.cgi")" "$fn" "backups.cgi не вызывает $fn"
done
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'send_tar_file' "_lib.sh не отдаёт tar-файлы"

# Агрегирующий state.cgi: одна загрузка вместо ~15 CGI при старте webui
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'api_state\(\)' "_lib.sh: нет агрегирующего api_state"
[ -f "$REPO_DIR/webui/cgi-bin/state.cgi" ] || fail "state.cgi отсутствует"
grep -q 'api_state' "$REPO_DIR/webui/cgi-bin/state.cgi" || fail "state.cgi не вызывает api_state"
grep -q 'cgi-bin/state.cgi' "$REPO_DIR/z2r.sh" || fail "z2r.sh не устанавливает state.cgi"
grep -rq 'state\.cgi' "$REPO_DIR/webui-src/src" || fail "webui-src не использует state.cgi"
grep -q '"state"' "$REPO_DIR/webui/dev/fake_router_server.py" || fail "fake_router_server.py без эндпоинта state"
grep -q 'state\.cgi' "$REPO_DIR/webui/dev/API_CONTRACT.md" || fail "API_CONTRACT.md без state.cgi"

for key in auto_mode rst_guard reasm quic443 provider; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" "\\\"$key\\\"" "api_status не отдаёт поле $key"
done
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'rst-guard\.lua' "rst_guard set без guard на lua-файл"

for id in auto-mode-form hostlist-form rst-guard-form reasm-form quic443-form dns-desync-form wssize-ramp-form wssize-ramp-toggle wssize-ramp-mode wssize-ramp-scale ports-tcp-form ports-udp-form provider-form tls-blob-profile-form backup-create-btn backup-import-btn backup-import-file; do
  grep -rq "$id" "$REPO_DIR/webui-src/src" || fail "webui-src не содержит #$id"
done

app_js="$(find "$REPO_DIR/webui-src/src" -type f \( -name '*.vue' -o -name '*.ts' \) -exec cat {} +)"
for needle in 'auto_mode_state' 'hostlist_state' 'rst_guard_state' 'reasm_state' 'quic443_state' 'dns_desync_state' 'ports_add' 'ports_remove' 'provider_set' 'provider_redetect' 'tls_blob_profile' '/cgi-bin/backups.cgi' "action: 'create'" "action: 'delete'" 'action=download' 'action=upload' 'download-btn' 'backups-toggle' 'confirmDialog'; do
  assert_contains "$app_js" "$needle" "webui-src не использует $needle"
done

# Проверка обновлений из панели: кнопка в карточке версии (видна только без
# обновлений), CGI-эндпоинт с коротким fetch, мок и контракт на месте.
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/settings.cgi")" 'update_check' "settings.cgi GET не знает update_check"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'api_update_check' "_lib.sh без api_update_check"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'deploy_latest_write_cache' "api_update_check не пишет кэш latest.env"
assert_contains "$(cat "$REPO_DIR/lib/deploy.sh")" 'z2r.conf' "deploy_releases_base не учитывает RAW_URL из z2r.conf (CGI без env лаунчера)"

# raw-установки без version.env: бутстрап датой коммита ветки + «неизвестно»
# в панели вместо пустых полей.
assert_contains "$(cat "$REPO_DIR/lib/deploy.sh")" 'deploy_version_bootstrap' "deploy.sh без бутстрапа version.env"
grep -q 'deploy_version_bootstrap "\$commit_date"' "$REPO_DIR/z2r.sh" || fail "z2r.sh не вызывает бутстрап version.env"
assert_contains "$(cat "$REPO_DIR/lib/deploy.sh")" "grep -q .\\^ZATOR_DATE=" "бутстрап не защищён существующий version.env"
_lib_raw="$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")"
assert_contains "$_lib_raw" 'v_zator_date="неизвестно"' "state.cgi без fallback для пустой версии zator"
assert_contains "$app_js" 'update_check' "webui-src не вызывает update_check"
assert_contains "$app_js" 'update-check-btn' "webui-src без кнопки проверки обновлений"
assert_contains "$app_js" 'runUpdateCheck' "webui-src без обработчика проверки обновлений"
assert_contains "$(cat "$REPO_DIR/webui-src/src/components/status/StatusCards.vue")" "verClass === ''" "кнопка обновлений не спрятана при видимых обновлениях"
assert_contains "$(cat "$REPO_DIR/webui/dev/fake_router_server.py")" 'update_check' "fake_router_server.py без update_check"
assert_contains "$(cat "$REPO_DIR/webui/dev/fake_router_server.py")" 'apply_wssize_ramp' "fake_router_server.py не сохраняет wssize_ramp"
assert_contains "$(cat "$REPO_DIR/webui/dev/fake_router_server.py")" 'build_wssize_ramp_settings' "fake_router_server.py не отдаёт wssize_ramp"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'PARAM_SYNDATA' "settings.cgi не читает поле SYN-data"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'Z2R_WSSIZE_RAMP_SYNDATA' "settings.cgi не сохраняет поле SYN-data"
assert_contains "$(cat "$REPO_DIR/webui-src/src/components/settings/WssizeRampPanel.vue")" 'wssize-ramp-syndata' "WebUI без переключателя SYN-data"
assert_contains "$(cat "$REPO_DIR/webui-src/src/components/settings/WssizeRampPanel.vue")" '!enabled' "WebUI не блокирует SYN-data при выключенном Ramp"
assert_contains "$(cat "$REPO_DIR/webui/dev/API_CONTRACT.md")" 'update_check' "API_CONTRACT.md без update_check"
assert_contains "$app_js" 'AUTO_MODE_GATED_PROFILES' "webui-src не гейтит профили 1-4 при авторотации"
assert_contains "$app_js" 'fallback-hint' "webui-src без подсказки гейтинга профиля"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'управляется авторотацией' "_lib.sh: set-lock/clear-lock без guard'а авторотации"

# Автоперезапуск после изменения настройки: общий хелпер в CGI, тосты в JS,
# симуляция в fake-сервере; ручных «Перезапустите zapret2» больше нет.
_lib_sh="$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")"
assert_contains "$_lib_sh" '_service_apply_restart\(\)' "_lib.sh: нет общего хелпера автоперезапуска"
assert_not_contains "$_lib_sh" 'reboot_required' "_lib.sh: остался старый флаг reboot_required"
# init-скрипт: CGI выбирает openwrt-инит только на настоящем OpenWRT (procd);
# tarball кладёт оба инита на все платформы, без пробы Keenetic/Merlin/VPS
# получают procd-скрипт и кнопки старт/стоп падают «Не удалось выполнить команду zapret2»
assert_contains "$_lib_sh" '/sbin/procd' "set_zapret2_init берёт openwrt-инит без проверки procd (падение кнопок старт/стоп на не-OpenWRT)"
assert_contains "$app_js" 'announceRestart' "webui-src: нет тоста о перезапуске"
assert_contains "$app_js" 'restartSuffix' "webui-src: нет суффикса про перезапуск"
assert_not_contains "$app_js" 'Перезапустите zapret2' "webui-src: остался ручной призыв перезапустить"
assert_contains "$(cat "$REPO_DIR/webui/dev/fake_router_server.py")" '_apply_restart' "fake_router_server.py: нет симуляции автоперезапуска"

assert_contains "$(cat "$REPO_DIR/lib/actions.sh")" 'ports_apply_add "\$proto" "\$input"' "CLI ports_add не использует ядро ports_apply_add"
assert_contains "$(cat "$REPO_DIR/lib/actions.sh")" 'ports_apply_remove "\$proto" "\$target"' "CLI ports_manage не использует ядро ports_apply_remove"
assert_contains "$(cat "$REPO_DIR/lib/actions.sh")" 'backup_create_core 2>/dev/null' "CLI menu_action_backup_create не использует ядро backup_create_core"

fake_py="$(cat "$REPO_DIR/webui/dev/fake_router_server.py")"
for needle in 'auto_mode_state' 'hostlist_state' 'rst_guard_state' 'reasm_state' 'quic443_state' 'dns_desync_state' 'ports_add' 'provider_set' 'provider_redetect' 'apply_backup_create' 'apply_backup_delete' 'apply_backup_import' 'ConflictError'; do
  assert_contains "$fake_py" "$needle" "fake_router_server.py не реализует $needle"
done
assert_contains "$fake_py" 'apply_tls_blob_profile' "fake_router_server.py не реализует apply_tls_blob_profile"
assert_contains "$fake_py" '"profile_blobs"' "fake_router_server.py не отдаёт profile_blobs"
assert_contains "$fake_py" 'z2r_prof_' "fake_router_server.py не моделирует слоты z2r_prof_N"
assert_contains "$fake_py" 'netrogat_substring' "fake_router_server.py не поддерживает список netrogat_substring"
assert_contains "$fake_py" 'AUTO_MODE_GATED_PROFILES' "fake_router_server.py не гейтит профили 1-4 при авторотации"

# Панель авторотации обязана жить в реестре панелей настроек (роут /settings/auto-mode)
grep -q "'auto-mode'" "$REPO_DIR/webui-src/src/components/settings/panels.ts" \
  || fail "панель авторотации отсутствует в реестре настроек"

# == 2. Hostlist: autohostlist и плейсхолдер <HOSTLIST> ==

[ "$(config_mode_text hostlist "$CFG")" != "неизвестно" ] || fail "config.default: hostlist режим не определён"
backup_smart_set_hostlist "$CFG" 1
grep -q '^MODE_FILTER=autohostlist' "$CFG" || fail "hostlist set 1 не переключил MODE_FILTER"
grep -q 'TCP_RKN_list\.txt <HOSTLIST>' "$CFG" || fail "hostlist set 1 не добавил плейсхолдер <HOSTLIST>"
[ "$(config_mode_text hostlist "$CFG")" = "авто" ] || fail "config_mode_text hostlist не видит авто"
backup_smart_set_hostlist "$CFG" 0
grep -q '^MODE_FILTER=hostlist' "$CFG" || fail "hostlist set 0 не вернул MODE_FILTER"
grep -q 'TCP_RKN_list\.txt <HOSTLIST>' "$CFG" && fail "hostlist set 0 не убрал плейсхолдер <HOSTLIST>"

# == 3. reasm-disable ==

backup_smart_set_reasm "$CFG" 1
[ "$(config_mode_text reasm_disable "$CFG")" = "включено" ] || fail "reasm set 1 не виден в config_mode_text"
awk '/^NFQWS2_OPT="/ {found=1; next} found && /^--reasm-disable$/ {ok=1} found && /^"$/ {exit} END {exit !ok}' "$CFG" \
  || fail "--reasm-disable не внутри блока NFQWS2_OPT"
backup_smart_set_reasm "$CFG" 1
[ "$(grep -c '^--reasm-disable$' "$CFG")" -eq 1 ] || fail "reasm set 1 не идемпотентен"
backup_smart_set_reasm "$CFG" 0
[ "$(config_mode_text reasm_disable "$CFG")" = "выключено" ] || fail "reasm set 0 не удалил параметр"

# == 4. QUIC443 ==

backup_smart_set_quic443 "$CFG" 0
[ "$(backup_smart_quic443_state "$CFG")" = "0" ] || fail "quic443 set 0 не определился"
backup_smart_set_quic443 "$CFG" 1
[ "$(backup_smart_quic443_state "$CFG")" = "1" ] || fail "quic443 set 1 не определился"
sed -n '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/p' "$CFG" | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-udp=443' \
  && fail "quic443 включен, но --skip остался"

# == 4a. Антиспуф DNS (профиль 10): ядро тумблера WebUI/CLI ==
# Дефолт апстрима: блок активен (без --skip) И порт 53 в NFQWS2_PORTS_UDP —
# config_mode_text dns_desync = Включен. Тумблер меняет блок + порт.

[ "$(config_mode_text dns_desync "$CFG")" = "Включен" ] \
  || fail "свежий config.default: антиспуф DNS должен быть Включен (блок + порт 53)"
sed -n '/#Z2R_DNS_BEGIN/,/#Z2R_DNS_END/p' "$CFG" | grep -q '^--filter-udp=53$' \
  || fail "блок #Z2R_DNS_* должен быть активен по умолчанию (без --skip)"
assert_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53(,|$)' \
  "порт 53 должен быть в NFQWS2_PORTS_UDP по умолчанию"

# повторное включение не дублирует порт
backup_smart_set_dns_desync "$CFG" 1
config_profile_dns_ports_apply "$CFG" 1
assert_not_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53,53(,|$)' "dns_desync set 1 задублировал порт 53"

backup_smart_set_dns_desync "$CFG" 0
config_profile_dns_ports_apply "$CFG" 0
[ "$(config_mode_text dns_desync "$CFG")" = "Выключен" ] || fail "dns_desync set 0 не выключился"
assert_not_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53(,|$)' "dns_desync set 0 не убрал порт 53"
sed -n '/#Z2R_DNS_BEGIN/,/#Z2R_DNS_END/p' "$CFG" | grep -q '^--skip --filter-udp=53$' \
  || fail "dns_desync set 0 не вернул --skip в блок #Z2R_DNS_*"
# возврат в дефолтное состояние (блок активен, порт на месте)
backup_smart_set_dns_desync "$CFG" 1
config_profile_dns_ports_apply "$CFG" 1
[ "$(config_mode_text dns_desync "$CFG")" = "Включен" ] || fail "dns_desync set 1 не включился обратно"

# == 5. RST guard ==

backup_smart_set_rst_guard "$CFG" 1
[ "$(config_mode_text rst_guard "$CFG")" = "включен" ] || fail "rst_guard set 1 не виден"
grep -q -- '--lua-desync=rst_guard_locked:key=1' "$CFG" || fail "rst_guard set 1 не заменил circular_locked:key=1"
sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$CFG" | grep -q '^--skip --filter-tcp=443 --filter-l7=tls$' \
  && fail "rst_guard set 1 не упростил filter-tcp в fallback-блоке"
backup_smart_set_rst_guard "$CFG" 0
[ "$(config_mode_text rst_guard "$CFG")" = "выключен" ] || fail "rst_guard set 0 не вернул circular_locked"
sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$CFG" | grep -q '^--skip --filter-tcp=443 --filter-l7=tls$' \
  || fail "rst_guard set 0 не вернул filter-l7=tls в fallback-блоке"

# == 6. Fallback: guard авторотации и восстановление состояния ==

backup_smart_set_fallback "$CFG" 1
[ "$(config_mode_text fallback "$CFG")" = "включен" ] || fail "fallback set 1 не включился"
backup_smart_set_fallback "$CFG" 0
[ "$(config_mode_text fallback "$CFG")" = "выключен" ] || fail "fallback set 0 не выключился"
backup_smart_set_fallback "$CFG" 1
[ "$(config_mode_text fallback "$CFG")" = "включен" ] || fail "подготовка fallback к тесту авторотации не удалась"

config_auto_layout_valid "$CFG" || fail "config.default не проходит config_auto_layout_valid"
config_set_auto_mode "$CFG" 1
[ "$(config_mode_text auto_mode "$CFG")" = "включен" ] || fail "config_set_auto_mode 1 не сработал"
[ "$(config_mode_text fallback "$CFG")" = "недоступен" ] || fail "fallback не 'недоступен' при авторотации"
backup_smart_set_fallback "$CFG" 0
[ "$(config_mode_text fallback "$CFG")" = "недоступен" ] || fail "fallback сеттер не no-op при авторотации"
config_set_auto_mode "$CFG" 0
[ "$(config_mode_text auto_mode "$CFG")" = "выключен" ] || fail "config_set_auto_mode 0 не сработал"
[ "$(config_mode_text fallback "$CFG")" = "включен" ] || fail "после выключения авторотации fallback не восстановлен (AUTO_FALLBACK_WAS)"

# == 7. Порты NFQWS2: add/remove + синхронизация RKN --filter-tcp ==

ports_apply_add tcp "8080,9000-9100,abc,8080" "$CFG" \
  || fail "ports_apply_add отклонил валидные порты"
[ "$PORTS_APPLY_ADDED" = "8080,9000-9100" ] || fail "PORTS_APPLY_ADDED неверен: $PORTS_APPLY_ADDED"
[ "$PORTS_APPLY_SKIPPED" = "abc,8080" ] || fail "PORTS_APPLY_SKIPPED неверен: $PORTS_APPLY_SKIPPED"
tcp_line="$(config_get_var "$CFG" NFQWS2_PORTS_TCP)"
printf '%s\n' "$tcp_line" | grep -q '^8080,9000-9100,' || fail "порты не встали в начало NFQWS2_PORTS_TCP: $tcp_line"
sed -n '/#Z2R_AUTO_STANDARD_3_BEGIN/,/#Z2R_AUTO_STANDARD_3_END/p' "$CFG" | grep -q -- '--filter-tcp=8080,9000-9100,' \
  || fail "RKN --filter-tcp не синхронизировался с пользовательскими TCP-портами"

if ports_apply_add tcp "8080" "$CFG"; then
  fail "ports_apply_add должен отклонять дубликат"
fi

ports_apply_remove tcp "8080" "$CFG" || fail "ports_apply_remove не удалил порт"
tcp_line="$(config_get_var "$CFG" NFQWS2_PORTS_TCP)"
case ",$tcp_line," in
  *",8080,"*) fail "порт 8080 не удалён из NFQWS2_PORTS_TCP: $tcp_line" ;;
esac
sed -n '/#Z2R_AUTO_STANDARD_3_BEGIN/,/#Z2R_AUTO_STANDARD_3_END/p' "$CFG" | grep -q -- '--filter-tcp=8080' \
  && fail "порт 8080 не убран из RKN --filter-tcp"
if ports_apply_remove tcp "8080" "$CFG"; then
  fail "ports_apply_remove должен отклонять отсутствующий порт"
fi

ports_apply_add udp "12345" "$CFG" || fail "ports_apply_add udp не работает"
udp_line="$(config_get_var "$CFG" NFQWS2_PORTS_UDP)"
printf '%s\n' "$udp_line" | grep -q '^12345,' || fail "UDP-порт не в начале NFQWS2_PORTS_UDP: $udp_line"
ports_apply_remove udp "12345" "$CFG" || fail "ports_apply_remove udp не работает"

# == 8. Бэкапы: ядро создания ==

backup_out="$TMP_DIR/backup_out"
if ! backup_create_core >"$backup_out" 2>/dev/null; then
  fail "backup_create_core упал"
fi
backup_tar="$(cat "$backup_out")"
[ -f "$backup_tar" ] || fail "архив бэкапа не создан: $backup_tar"
[ "$backup_tar" = "$BACKUP_LAST_ARCHIVE" ] || fail "BACKUP_LAST_ARCHIVE не совпадает с путём архива"
basename "$backup_tar" | grep -Eq '^z2r_backup_[0-9]{8}_[0-9]{6}\.tar$' || fail "имя архива не по шаблону: $backup_tar"
[ -s "$backup_tar" ] || fail "архив бэкапа пуст"

# == 8a. Бэкапы: ядра resolve/delete/import ==

backup_name="$(basename "$backup_tar")"
resolved="$(backup_resolve_archive "$backup_name")" || fail "backup_resolve_archive не нашёл свежий архив"
[ "$resolved" = "$backup_tar" ] || fail "backup_resolve_archive вернул не тот путь: $resolved"
if backup_resolve_archive "../$backup_name" >/dev/null 2>&1; then
  fail "backup_resolve_archive должен отклонять path traversal"
fi
if backup_resolve_archive "z2r_backup_20990101_000000.tar" >/dev/null 2>&1; then
  fail "backup_resolve_archive должен отклонять отсутствующий архив"
fi
if backup_resolve_archive "evil.tar" >/dev/null 2>&1; then
  fail "backup_resolve_archive должен отклонять имя мимо шаблона"
fi

deleted="$(backup_delete_core "$backup_name")" || fail "backup_delete_core упал"
[ ! -f "$deleted" ] || fail "backup_delete_core не удалил архив"
if backup_delete_core "$backup_name" >/dev/null 2>&1; then
  fail "backup_delete_core должен отклонять отсутствующий архив"
fi

import_stage="$TMP_DIR/import_stage"
mkdir -p "$import_stage"
printf 'MODE_FILTER=hostlist\n' > "$import_stage/config"
import_src="$TMP_DIR/upload.tar"
tar -cf "$import_src" -C "$import_stage" .
imported="$(backup_import_core "$import_src" "z2r_backup_20990101_000000.tar")" \
  || fail "backup_import_core упал на валидном tar"
[ "$imported" = "z2r_backup_20990101_000000.tar" ] || fail "backup_import_core не сохранил оригинальное имя: $imported"
[ -f "$Z2R_BACKUP_DIR/$imported" ] || fail "импортированный архив не в каталоге бэкапов"
[ ! -f "$import_src" ] || fail "backup_import_core не перенёс файл"

tar -cf "$import_src" -C "$import_stage" .
imported2="$(backup_import_core "$import_src" "my_router.tar")" \
  || fail "backup_import_core упал на валидном tar без шаблонного имени"
printf '%s\n' "$imported2" | grep -Eq '^z2r_backup_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.tar$' \
  || fail "сгенерированное имя не по шаблону: $imported2"

bad_stage="$TMP_DIR/bad_stage"
mkdir -p "$bad_stage"
printf 'junk\n' > "$bad_stage/readme.txt"
bad_src="$TMP_DIR/bad.tar"
tar -cf "$bad_src" -C "$bad_stage" .
if backup_import_core "$bad_src" >/dev/null 2>&1; then
  fail "backup_import_core должен отклонять tar без config/lists/extra_strats"
fi
[ -f "$bad_src" ] || fail "при отказе backup_import_core не должен удалять исходный файл"

garbage="$TMP_DIR/garbage.bin"
printf 'not a tar\n' > "$garbage"
if backup_import_core "$garbage" >/dev/null 2>&1; then
  fail "backup_import_core должен отклонять не-tar файл"
fi

# == 9. Провайдер ==

provider_asn_lookup 47119
[ "$PROVIDER_BRAND" = "Ufanet" ] || fail "ASN 47119 должен давать бренд Ufanet, получен: $PROVIDER_BRAND"
provider_asn_lookup 20485
[ "$PROVIDER_BRAND" = "Rostelecom" ] || fail "ASN 20485 должен давать бренд Rostelecom"
[ "$(provider_brand_aliases Rostelecom | tr '\n' ',')" = "TTK," ] || fail "алиасы Rostelecom должны быть TTK"
provider_asn_lookup 8369
[ "$PROVIDER_BRAND" = "Dom.ru" ] || fail "ASN 8369 должен давать бренд Dom.ru"
[ "$(provider_brand_aliases 'Dom.ru' | tr '\n' ',')" = "ER-Telecom," ] || fail "алиасы Dom.ru должны быть ER-Telecom"
if provider_asn_lookup 99999; then
  fail "неизвестный ASN должен возвращать 1"
fi

[ "$(_provider_json_num '{"connection":{"asn":47119,"org":"JSC Ufanet"}}' asn)" = "47119" ] \
  || fail "_provider_json_num не извлекает asn"
[ "$(_provider_json_str '{"as":"AS47119 JSC Ufanet","isp":"JSC Ufanet"}' isp)" = "JSC Ufanet" ] \
  || fail "_provider_json_str не извлекает isp"
[ "$(_provider_json_str '{"as":"AS47119 JSC Ufanet"}' as)" = "AS47119 JSC Ufanet" ] \
  || fail "_provider_json_str не извлекает as"

provider_sh="$(cat "$REPO_DIR/lib/provider.sh")"
who_line="$(printf '%s\n' "$provider_sh" | grep -n 'curl.*ipwho\.is' | head -1 | cut -d: -f1)"
info_line="$(printf '%s\n' "$provider_sh" | grep -n 'curl.*ipinfo\.io' | head -1 | cut -d: -f1)"
apiline="$(printf '%s\n' "$provider_sh" | grep -n 'curl.*ip-api\.com' | head -1 | cut -d: -f1)"
[ -n "$who_line" ] && [ -n "$info_line" ] && [ -n "$apiline" ] && [ "$who_line" -lt "$info_line" ] && [ "$info_line" -lt "$apiline" ] \
  || fail "каскад детекта должен быть ipwho.is -> ipinfo.io -> ip-api.com"
grep -q 'tr -cd' "$REPO_DIR/lib/provider.sh" && fail "provider.sh не должен калечить строки через tr -cd"
grep -q 'recommendations_json' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail "WebUI не использует общий движок подсказок"
grep -q '_detect_api_simple' "$REPO_DIR/lib/telemetry.sh" || fail "фоллбек телеметрии не использует общий детектор"

provider_set_manual "MTS" "Moscow" || fail "provider_set_manual упал"
[ "$(cat "$PROVIDER_CACHE")" = "MTS - Moscow" ] || fail "provider_set_manual не записал кэш"
provider_set_manual "Beeline" "" || fail "provider_set_manual без города упал"
[ "$(cat "$PROVIDER_CACHE")" = "Beeline" ] || fail "provider_set_manual без города записал лишнее"
if provider_set_manual "" "City"; then
  fail "provider_set_manual должен отклонять пустое имя"
fi

# == 10. Кастомные домены: самолечение из locked.tsv и переименование ==
# Старые обновления затирали TCP_Custom.txt пустым Custom.txt из репозитория,
# при этом локи доменов в locked.tsv переживали: список пуст, локи живы.

export ZATOR_ROOT="$TMP_DIR/zator"
CUSTOM_FILE="$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
mkdir -p "$ZATOR_ROOT/extra_strats"

# locked.tsv: числовые профили, mark-строки, IP и домены. В список переезжают
# только домены, отсутствующие в нём, в порядке lock-файла.
cat > "$ORCH_LOCK_FILE" <<'EOF'
1	tls	28
3	tls	26
mark:2	tls	7
10.0.0.1	tls	5
rustorka.com	tls	20
amnezia.org	tls	27
EOF
printf 'amnezia.org\n' > "$CUSTOM_FILE"

restored="$(custom_rkn_restore_from_locks)"
[ "$restored" = "1" ] || fail "custom_rkn_restore_from_locks должен добавить 1 домен, добавлено: $restored"
[ "$(cat "$CUSTOM_FILE")" = "amnezia.org
rustorka.com" ] || fail "восстановление вставило домен не туда/не то: $(cat "$CUSTOM_FILE" | tr '\n' ',')"
restored="$(custom_rkn_restore_from_locks)"
[ "$restored" = "0" ] || fail "повторное восстановление должно быть no-op, добавлено: $restored"

# Переименование: позиция строки в списке и в lock-файле сохраняется.
printf 'rustorka.com\namnezia.org\n' > "$CUSTOM_FILE"
custom_rkn_rename_domain "amnezia.org" "nova.example.org" || fail "custom_rkn_rename_domain упал"
[ "$(cat "$CUSTOM_FILE")" = "rustorka.com
nova.example.org" ] || fail "переименование не сохранило позицию строки в списке"
awk -F '\t' '$1=="nova.example.org" && $2=="tls" && $3=="27" {ok=1} END{exit !ok}' "$ORCH_LOCK_FILE" \
  || fail "лок домена не переименован"
awk -F '\t' '$1=="rustorka.com" && $2=="tls" && $3=="20" {ok=1} END{exit !ok}' "$ORCH_LOCK_FILE" \
  || fail "чужие локи повреждены при переименовании"
rm_rc=0
custom_rkn_rename_domain "absent.example" "x.example.org" 2>/dev/null || rm_rc=$?
[ "$rm_rc" = "2" ] || fail "переименование отсутствующего домена должно давать 2, получено: $rm_rc"

# Общий случай: любой список (исключения, подстроки) — без локов, позиция строки
# сохраняется; код 2 для отсутствующей записи.
RENAME_LIST="$TMP_DIR/rename_list.txt"
printf 'first.com\nsecond.com\n' > "$RENAME_LIST"
domain_list_rename "$RENAME_LIST" "first.com" "renamed.com" || fail "domain_list_rename упал"
[ "$(cat "$RENAME_LIST")" = "renamed.com
second.com" ] || fail "domain_list_rename не сохранил позицию строки: $(cat "$RENAME_LIST" | tr '\n' ',')"
rm_rc=0
domain_list_rename "$RENAME_LIST" "absent.com" "x.com" 2>/dev/null || rm_rc=$?
[ "$rm_rc" = "2" ] || fail "domain_list_rename отсутствующей записи должен давать 2, получено: $rm_rc"

# Статика: деплой TCP_Custom в z2r.sh не безусловный, самолечение подключено
# на старте z2r и в CGI чтения списка, rename присутствует во всех слоях.
tcp_custom_downloads="$(grep -c 'z2r_download_project_file "\$ZATOR_ROOT/extra_strats/TCP_Custom\.txt"' "$REPO_DIR/z2r.sh")"
tcp_custom_guards="$(grep -c 'if \[ ! -f "\$ZATOR_ROOT/extra_strats/TCP_Custom\.txt" \]; then' "$REPO_DIR/z2r.sh")"
[ "$tcp_custom_downloads" -ge 1 ] && [ "$tcp_custom_downloads" = "$tcp_custom_guards" ] \
  || fail "z2r.sh: есть скачивание TCP_Custom.txt без guard'а [ ! -f ] (затирает список)"
grep -q 'custom_rkn_restore_from_locks' "$REPO_DIR/z2r.sh" || fail "z2r.sh не вызывает custom_rkn_restore_from_locks на старте"
assert_contains "$_lib_sh" 'custom_rkn_restore_from_locks' "_lib.sh: чтение custom_rkn не лечит список"
assert_contains "$_lib_sh" 'rename)' "_lib.sh: нет действия rename в api_domains_action"
assert_contains "$_lib_sh" 'PARAM_NEW_DOMAIN' "_lib.sh: нет параметра new_domain"
assert_contains "$(cat "$REPO_DIR/lib/strategies.sh")" 'custom_rkn_rename_domain\(\)' "lib/strategies.sh: нет custom_rkn_rename_domain"
assert_contains "$(cat "$REPO_DIR/lib/orchestra_state.sh")" 'orch_locked_rename_everywhere\(\)' "lib/orchestra_state.sh: нет orch_locked_rename_everywhere"
for needle in 'orch_locked_rename' 'orch_locked_domain_names' '"rename"'; do
  assert_contains "$fake_py" "$needle" "fake_router_server.py не реализует $needle"
done
src_all="$(find "$REPO_DIR/webui-src/src" -type f \( -name '*.vue' -o -name '*.ts' \) -exec cat {} +)"
for needle in "action: 'rename'" 'new_domain' 'domain-rename-input' 'rename-btn'; do
  assert_contains "$src_all" "$needle" "webui-src не использует $needle"
done

echo "webui settings smoke ok"
