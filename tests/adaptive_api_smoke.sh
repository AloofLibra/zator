#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -q 'cgi-bin/adaptive.cgi' "$ROOT/z2r.sh" || { echo 'adaptive API is not deployed with WebUI' >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs" Z2R_ADAPTIVE_NDM_ROOT="$tmp/no-ndm"
mkdir -p "$ZATOR_ROOT/extra_strats/cache/adaptive" "$ZATOR_ROOT/extra_strats/cache/orchestra" "$ZATOR_ROOT/z2r_lib" "$ZATOR_ROOT/tools" "$ZATOR_ROOT/lua" "$tmp/zapret2/nfq2" "$Z2R_ADAPTIVE_DIR"
mkdir -p "$ZATOR_ROOT/files/fake"
printf 'blob-A' > "$ZATOR_ROOT/files/fake/tls_clienthello_max_ru.bin"
printf 'Example ISP - Test City\n' > "$ZATOR_ROOT/extra_strats/cache/provider.txt"
cp "$ROOT/lib/adaptive_lan_transport.sh" "$ZATOR_ROOT/z2r_lib/"
cp "$ROOT/lib/config.sh" "$ROOT/lib/orchestra_state.sh" "$ROOT/lib/adaptive_rules.sh" "$ROOT/lib/supersweep_probe.sh" "$ZATOR_ROOT/z2r_lib/"
cp "$ROOT/lib/adaptive_queue.sh" "$ZATOR_ROOT/z2r_lib/"
cat >> "$ZATOR_ROOT/z2r_lib/adaptive_lan_transport.sh" <<'RECOVERY_MOCK'
adaptive_lan_transport_recover_stale() {
  printf '%s\n' "$1" >> "$Z2R_RECOVERY_TEST_LOG"
  [[ "${Z2R_RECOVERY_TEST_FAIL:-0}" != 1 ]] || return 1
  return 0
}
_adaptive_lan_controller_alive() { [[ "${Z2R_RECOVERY_TEST_LIVE_PID:-}" = "$1" ]]; }
RECOVERY_MOCK
cp "$ROOT/orchestra/locked.lua" "$ZATOR_ROOT/lua/locked.lua"
cp "$ROOT/lua/fake-adapt.lua" "$ZATOR_ROOT/lua/"
cp "$ROOT/config.default" "$tmp/zapret2/config"
mkdir -p "$tmp/zapret2/lua"
printf 'module-A' > "$tmp/zapret2/lua/zapret-antidpi.lua"
printf 'module-L' > "$tmp/zapret2/lua/zapret-lib.lua"
printf 'module-A' > "$tmp/zapret2/lua/zapret-auto.lua"
# Strategy 45 intentionally duplicates strategy 1 after normalizing its index.
sed -i '/#Z2R_AUTO_STANDARD_1_END/i --lua-desync=fake:blob=fake_default_tls:tcp_seq=-3000:repeats=2:strategy=45 --lua-desync=multidisorder:pos=sniext+1,midsld:strategy=45' "$tmp/zapret2/config"
cat > "$tmp/zapret2/nfq2/nfqws2" <<'NFQWS'
#!/bin/sh
case "$1" in
  --version) echo 'nfqws2 smoke version' ;;
  --help) echo 'nfqws2 smoke help' ;;
esac
NFQWS
chmod +x "$tmp/zapret2/nfq2/nfqws2"
export ZAPRET2_ROOT="$tmp/zapret2"
export Z2R_ADAPTIVE_LOCK_DIR="$tmp/adaptive-lock" Z2R_RECOVERY_TEST_LOG="$tmp/recovery-calls.log"
mkdir -p "$Z2R_ADAPTIVE_LOCK_DIR"
printf '%064d' 7 > "$ZATOR_ROOT/extra_strats/cache/adaptive/token"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$ZATOR_ROOT/extra_strats/cache/adaptive/token.expires"
printf 'OFF\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
cat > "$ZATOR_ROOT/tools/adaptive-controller.sh" <<'CONTROLLER'
#!/usr/bin/env bash
set -eu
id="$1" ip="$2" port="$3" host="$4" dst="$5" profile="$6" strategy="$7" expiry="$8" scope="$9" owner="${10:-}" recipe="${11:-tls-http1-v1}" treatment="${12:-standard}"
run="$Z2R_ADAPTIVE_DIR/$id"
mkdir -p "$run/leases"
fingerprint=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
catalog=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$dst" "$profile" "$fingerprint" "$strategy" "$catalog" "$scope" "$treatment" > "$run/target.tsv"
if [[ -n "$owner" ]]; then printf '%s\t%s\t%s\t%s\t443\t%s\t%s\t%s\n' "$id" "$ip" "$port" "$dst" "$expiry" "$recipe" "$owner" > "$run/leases/$id.tsv"; else printf '%s\t%s\t%s\t%s\t443\t%s\t%s\n' "$id" "$ip" "$port" "$dst" "$expiry" "$recipe" > "$run/leases/$id.tsv"; fi
media_json=''
if [[ "$recipe" = googlevideo-tcp-media-v1 || "$recipe" = googlevideo-quic-h3-media-v1 ]]; then media_json=",\"media\":{\"url\":\"https://rr1---sn-a5mekn6e.googlevideo.com/videoplayback?expire=$(( $(date +%s) + 600 ))&sig=smoke\",\"mime_type\":\"video/mp4\",\"content_length\":8388608}"; fi
protocol=tcp
[[ "$recipe" != googlevideo-quic-h3-media-v1 ]] || protocol=udp
printf '{"schema_version":1,"test_id":"%s","source_ip":"%s","source_port":%s,"destination_ip":"%s","port":443,"protocol":"%s","expires":%s,"recipe_id":"%s","treatment_variant":"%s","profile_id":%s,"scope":"%s","local_strategy_number":%s,"strategy_fingerprint":"%s","catalog_version":"%s"%s}\n' "$id" "$ip" "$port" "$dst" "$protocol" "$expiry" "$recipe" "$treatment" "$profile" "$scope" "$strategy" "$fingerprint" "$catalog" "$media_json" > "$run/lease.json"
(
  while [[ ! -s "$run/complete.tsv" ]]; do sleep .05; done
  IFS=$'\t' read -r schema test_id observed transport application reason host dst profile fp strategy catalog recipe treatment client result_scope < "$run/complete.tsv"
  printf '{"schema_version":1,"test_id":"%s","route_verified":true,"transport":"%s","application":"%s","overall":"SUCCESS","reason":"%s","treatment_variant":"%s"}\n' "$test_id" "$transport" "$application" "$reason" "$treatment" > "$run/result.json"
  printf 'complete\n' > "$run/state"
) >/dev/null 2>&1 &
CONTROLLER
chmod 700 "$ZATOR_ROOT/tools/adaptive-controller.sh"

call_api() {
  local body="$1" auth="${2:-Bearer $(cat "$ZATOR_ROOT/extra_strats/cache/adaptive/token")}"; shift 2 2>/dev/null || :
  REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#body}" \
  REMOTE_ADDR=192.168.1.44 HTTP_AUTHORIZATION="$auth" \
  printf '%s' "$body" | env REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH="${#body}" \
    REMOTE_ADDR=192.168.1.44 HTTP_AUTHORIZATION="$auth" bash "$ROOT/webui/cgi-bin/adaptive.cgi"
}

unauthorized="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1' 'Bearer wrong')"
[[ "$unauthorized" == *'401 Unauthorized'* ]] || { echo 'unauthorized request accepted' >&2; exit 1; }
[[ ! -e "$Z2R_ADAPTIVE_DIR/agent.last" ]] || { echo 'unauthorized request updated the agent heartbeat' >&2; exit 1; }
printf '1\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/token.expires"
expired_token="$(call_api 'action=stats_identity')"
[[ "$expired_token" == *'401 Unauthorized'* && "$expired_token" == *'token expired'* ]] || {
  echo "expired pairing token was accepted: $expired_token" >&2; exit 1;
}
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$ZATOR_ROOT/extra_strats/cache/adaptive/token.expires"
stats_identity="$(call_api 'action=stats_identity')"
[[ "$stats_identity" == *'"provider":"Example ISP"'* ]] || { echo "provider identity missing: $stats_identity" >&2; exit 1; }
[[ "$stats_identity" != *'Test City'* ]] || { echo "provider city leaked into adaptive identity: $stats_identity" >&2; exit 1; }
cleanup_run=11111111111111111111111111111111
mkdir -p "$Z2R_ADAPTIVE_DIR/$cleanup_run"
printf 'cleanup_failed\n' > "$Z2R_ADAPTIVE_DIR/$cleanup_run/state"
resources="$(call_api 'action=resources')"
resources_json="${resources#*$'\r\n\r\n'}"
[[ "$resources" == *'Status: 200 OK'* ]] && python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["schema_version"] == 1
assert isinstance(r["load1_per_core"], (int, float)) and r["load1_per_core"] >= 0
assert isinstance(r["cores"], int) and r["cores"] > 0
assert isinstance(r["mem_available_kib"], int) and r["mem_available_kib"] >= 0
assert isinstance(r["active_probes"], int) and r["active_probes"] >= 1
' <<< "$resources_json" || {
  echo "read-only router capacity response is incomplete: $resources" >&2; exit 1;
}
invalid_resources="$(call_api 'action=resources&hostname=example.org')"
[[ "$invalid_resources" == *'400 Bad Request'* ]] || { echo 'resources accepted unexpected caller-supplied fields' >&2; exit 1; }
off_lease="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1')"
[[ "$off_lease" == *'403 Forbidden'* ]] || { echo "probe lease was issued while OFF: $off_lease" >&2; exit 1; }
printf 'OBSERVE\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
observe_lease="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1')"
[[ "$observe_lease" == *'403 Forbidden'* ]] || { echo "probe lease was issued while OBSERVE: $observe_lease" >&2; exit 1; }
printf 'TEST_ONLY\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
mkdir -p "$tmp/no-od"
cat > "$tmp/no-od/od" <<'NO_OD'
#!/bin/sh
exit 127
NO_OD
chmod +x "$tmp/no-od/od"
direct_lease_response="$(PATH="$tmp/no-od:$PATH" call_api 'action=lease&hostname=direct.example.org&destination_ip=93.184.216.33&profile_id=1&local_strategy_number=0')"
direct_lease_json="${direct_lease_response#*$'\r\n\r\n'}"
direct_id="$(printf '%s' "$direct_lease_json" | sed -n 's/.*"test_id":"\([a-f0-9]*\)".*/\1/p')"
[[ "$direct_id" =~ ^[a-f0-9]{32}$ && "$direct_lease_json" == *'"local_strategy_number":0'* ]] || { echo "DIRECT lease was rejected: $direct_lease_response" >&2; exit 1; }
direct_body="action=complete&test_id=$direct_id&schema_version=1&route_verified=false&overall=INCONCLUSIVE&ip_family=ipv4&protocol=tcp&port=443&observed_at=$(date +%s)&transport=OK&application=OK&reason=probe_ok&hostname=direct.example.org&destination_ip=93.184.216.33&profile_id=1&scope=default&strategy_fingerprint=sha256%3Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&local_strategy_number=0&catalog_version=sha256%3Abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&recipe_id=tls-http1-v1&client_profile=curl-windows-v1"
direct_complete="$(call_api "$direct_body")"
[[ "$direct_complete" == *'"overall":"SUCCESS"'* ]] || { echo "DIRECT completion rejected: $direct_complete" >&2; exit 1; }
candidate_list="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=mark%3A4')"
[[ "$candidate_list" == *'"candidate_numbers":[1,2,3,4,5,6,7,8,9,10]'* && "$candidate_list" == *'"scope":"mark:4"'* ]] || {
  echo "local candidate ordering is invalid: $candidate_list" >&2; exit 1;
}
printf 'AGENT_BETA\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
beta_candidates="$(call_api 'action=candidates&hostname=beta.example.org&destination_ip=93.184.216.34&profile_id=1&scope=mark%3A4')"
[[ "$beta_candidates" == *'Status: 200 OK'* && "$beta_candidates" == *'"candidate_numbers":[1,2,3,4,5,6,7,8,9,10]'* ]] || {
  echo "AGENT_BETA did not keep local verification available: $beta_candidates" >&2; exit 1;
}
beta_lease="$(call_api 'action=lease&hostname=beta.example.org&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&source_port=62030')"
[[ "$beta_lease" == *'Status: 200 OK'* && "$beta_lease" == *'"recipe_id":"tls-http1-v1"'* ]] || {
  echo "AGENT_BETA did not allow an isolated probe lease: $beta_lease" >&2; exit 1;
}
beta_lease_id="$(printf '%s' "$beta_lease" | sed -n 's/.*"test_id":"\([a-f0-9]*\)".*/\1/p')"
[[ "$beta_lease_id" =~ ^[a-f0-9]{32}$ ]] || { echo 'AGENT_BETA lease has no valid test id' >&2; exit 1; }
printf '1\t%s\t%s\tOK\tOK\tprobe_ok\tbeta.example.org\t93.184.216.34\t1\tsha256:%064d\t1\tsha256:%064d\ttls-http1-v1\tstandard\tcurl-windows-v1\tmark:4\n' \
  "$beta_lease_id" "$(date +%s)" 0 0 > "$Z2R_ADAPTIVE_DIR/$beta_lease_id/complete.tsv"
for _ in $(seq 1 30); do [[ "$(cat "$Z2R_ADAPTIVE_DIR/$beta_lease_id/state" 2>/dev/null)" = complete ]] && break; sleep 0.05; done
[[ "$(cat "$Z2R_ADAPTIVE_DIR/$beta_lease_id/state" 2>/dev/null)" = complete ]] || {
  echo 'AGENT_BETA fixture controller did not finish its lease' >&2; exit 1;
}
invalid_media_scope="$(call_api 'action=lease&hostname=beta.example.org&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&recipe_id=googlevideo-tcp-media-v1')"
[[ "$invalid_media_scope" == *'400 Bad Request'* ]] || { echo 'media recipe was accepted outside profile-2 Googlevideo' >&2; exit 1; }
invalid_tls_treatment="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&treatment_variant=gv_tcp_ramp')"
[[ "$invalid_tls_treatment" == *'400 Bad Request'* ]] || { echo 'TLS recipe accepted a Googlevideo treatment' >&2; exit 1; }
media_lease="$(call_api 'action=lease&hostname=rr1---sn-a5mekn6e.googlevideo.com&destination_ip=93.184.216.34&profile_id=2&local_strategy_number=1&scope=mark%3A4&source_port=62031&recipe_id=googlevideo-tcp-media-v1&treatment_variant=gv_tcp_ramp')"
media_lease_json="${media_lease#*$'\r\n\r\n'}"
media_lease_id="$(printf '%s' "$media_lease_json" | sed -n 's/.*"test_id":"\([a-f0-9]*\)".*/\1/p')"
[[ "$media_lease" == *'Cache-Control: no-store'* && "$media_lease" == *'"recipe_id":"googlevideo-tcp-media-v1"'* && "$media_lease" == *'"treatment_variant":"gv_tcp_ramp"'* &&
   "$media_lease" == *'"mime_type":"video/mp4"'* && "$media_lease" == *'/videoplayback?expire='* && "$media_lease_id" =~ ^[a-f0-9]{32}$ ]] || {
  echo "profile-2 Googlevideo media lease missing its private recipe contract: $media_lease" >&2; exit 1;
}
bad_media_treatment="action=complete&test_id=$media_lease_id&schema_version=1&route_verified=false&overall=INCONCLUSIVE&ip_family=ipv4&protocol=tcp&port=443&observed_at=$(date +%s)&transport=OK&application=OK&reason=media_ok&hostname=rr1---sn-a5mekn6e.googlevideo.com&destination_ip=93.184.216.34&profile_id=2&scope=mark%3A4&strategy_fingerprint=sha256%3Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&local_strategy_number=1&catalog_version=sha256%3Abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&recipe_id=googlevideo-tcp-media-v1&treatment_variant=gv_tcp_ramp_syndata&client_profile=curl-windows-media-v1&media_bytes=1048576&media_speed_bps=524288&media_duration_ms=2000"
[[ "$(call_api "$bad_media_treatment")" == *'409 Conflict'* ]] || { echo 'API accepted completion for a different treatment variant' >&2; exit 1; }
media_body="action=complete&test_id=$media_lease_id&schema_version=1&route_verified=false&overall=INCONCLUSIVE&ip_family=ipv4&protocol=tcp&port=443&observed_at=$(date +%s)&transport=OK&application=OK&reason=media_ok&hostname=rr1---sn-a5mekn6e.googlevideo.com&destination_ip=93.184.216.34&profile_id=2&scope=mark%3A4&strategy_fingerprint=sha256%3Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&local_strategy_number=1&catalog_version=sha256%3Abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&recipe_id=googlevideo-tcp-media-v1&treatment_variant=gv_tcp_ramp&client_profile=curl-windows-media-v1&media_bytes=1048576&media_speed_bps=524288&media_duration_ms=2000"
media_complete="$(call_api "$media_body")"
[[ "$media_complete" == *'Status: 200 OK'* ]] || { echo "media completion metrics rejected: $media_complete" >&2; exit 1; }
for _ in $(seq 1 30); do [[ "$(cat "$Z2R_ADAPTIVE_DIR/$media_lease_id/state" 2>/dev/null)" = complete ]] && break; sleep 0.05; done
[[ "$(cat "$Z2R_ADAPTIVE_DIR/$media_lease_id/state" 2>/dev/null)" = complete ]] || { echo 'media lease did not complete in the fixture controller' >&2; exit 1; }
printf 'TEST_ONLY\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
candidate_total="$(printf '%s' "$candidate_list" | sed -n 's/.*"profile_strategy_count":\([0-9][0-9]*\).*/\1/p')"
candidate_unique="$(printf '%s' "$candidate_list" | sed -n 's/.*"candidate_count":\([0-9][0-9]*\).*/\1/p')"
candidate_set_version="$(printf '%s' "$candidate_list" | sed -n 's/.*"candidate_set_version":"\([^"]*\)".*/\1/p')"
candidate_numbers_json="$(printf '%s' "$candidate_list" | sed -n 's/.*"candidate_numbers":\[\([^]]*\)\].*/\1/p')"
[[ "$candidate_unique" =~ ^[0-9]+$ && "$candidate_unique" -lt "$candidate_total" && "$candidate_set_version" =~ ^sha256:[a-f0-9]{64}$ && ",${candidate_numbers_json}," != *,45,* ]] || {
  echo "ranked candidates did not remove the duplicate semantic strategy: $candidate_list" >&2; exit 1;
}
exploration_candidates="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=mark%3A4&order=exploration&offset=0&limit=3')"
[[ "$exploration_candidates" == *'"candidate_count":45'* && "$exploration_candidates" == *'"candidate_set_version":"sha256:'* && "$exploration_candidates" == *'"candidate_numbers":[31,11,2]'* && "$exploration_candidates" == *'"source":"family-diverse-local-order"'* ]] || {
  echo "exploration order is not family-diverse: $exploration_candidates" >&2; exit 1;
}
invalid_order="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&order=remote')"
[[ "$invalid_order" == *'400 Bad Request'* ]] || { echo "unknown candidate order accepted: $invalid_order" >&2; exit 1; }
candidate_offset=10
if (( candidate_unique <= 10 )); then candidate_offset="$candidate_unique"; fi
candidate_page="$(call_api "action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=mark%3A4&offset=$candidate_offset&limit=1&candidate_set_version=$candidate_set_version")"
if (( candidate_unique > 10 )); then
  [[ "$candidate_page" == *'"candidate_offset":10,"candidate_numbers":[11]'* ]] || {
    echo "candidate paging skipped or reordered a strategy: $candidate_page" >&2; exit 1;
  }
else
  [[ "$candidate_page" == *'"status":"complete"'* && "$candidate_page" == *'"candidate_numbers":[]'* ]] || {
    echo "candidate paging did not report completion: $candidate_page" >&2; exit 1;
  }
fi
stale_candidate_page="$(call_api "action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=mark%3A4&offset=10&limit=1&candidate_set_version=sha256:$(printf '%064d' 0)")"
[[ "$stale_candidate_page" == *'409 Conflict'* ]] || { echo "stale ranked candidate snapshot was accepted: $stale_candidate_page" >&2; exit 1; }
invalid_page="$(call_api "action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&offset=$((candidate_unique + 1))&limit=1")"
[[ "$invalid_page" == *'400 Bad Request'* ]] || { echo "out-of-range candidate page accepted: $invalid_page" >&2; exit 1; }
source "$ROOT/lib/adaptive_rules.sh"
source "$ROOT/lib/config.sh"
stamp="$(adaptive_rules_runtime_stamp "$ZAPRET2_ROOT/config" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ZATOR_ROOT/extra_strats/cache/orchestra")"
mkdir -p "$tmp/other"
printf 'same-data' > "$tmp/blob-a.bin"
cp "$tmp/blob-a.bin" "$tmp/other/blob-b.bin"
printf '%s\n' "--blob=sample:@$tmp/blob-a.bin" '--lua-desync=plain:strategy=1' > "$tmp/plan-a.args"
printf '%s\n' "--blob=sample:@$tmp/other/blob-b.bin" '--lua-desync=plain:strategy=1' > "$tmp/plan-b.args"
fp_path_a="$(adaptive_strategy_fingerprint 1 1 "$tmp/plan-a.args" "$ZAPRET2_ROOT/nfq2/nfqws2")"
fp_path_b="$(adaptive_strategy_fingerprint 1 1 "$tmp/plan-b.args" "$ZAPRET2_ROOT/nfq2/nfqws2")"
[[ "$fp_path_a" = "$fp_path_b" ]] || { echo 'blob fingerprint depends on an absolute file path' >&2; exit 1; }
source "$ROOT/lib/supersweep_probe.sh"
ranking_catalog="$(mktemp -d "$ZATOR_ROOT/extra_strats/cache/adaptive/rank-catalog.XXXXXX")"
ORCH_DIR="$ZATOR_ROOT/extra_strats/cache/orchestra"
Z2R_SUPERSWEEP_DIR="$ranking_catalog"
DESYNC_MARK="$(config_get_var "$ZAPRET2_ROOT/config" DESYNC_MARK 2>/dev/null | tr -d '"\047')"
export Z2R_SUPERSWEEP_DIR DESYNC_MARK
supersweep_probe_config 1 "$ZAPRET2_ROOT/config"
ranked_fp="$(adaptive_strategy_fingerprint 1 12 "$ranking_catalog/probe/nfqws2.args" "$ZAPRET2_ROOT/nfq2/nfqws2")"
rm -rf "$ranking_catalog"
ranking_treatment="$(mktemp -d "$ZATOR_ROOT/extra_strats/cache/adaptive/ramp-catalog.XXXXXX")"
Z2R_SUPERSWEEP_DIR="$ranking_treatment"
export Z2R_SUPERSWEEP_DIR
supersweep_probe_config 2 "$ZAPRET2_ROOT/config" gv_tcp_plain
plain_treatment_fp="$(adaptive_strategy_fingerprint 2 1 "$ranking_treatment/probe/nfqws2.args" "$ZAPRET2_ROOT/nfq2/nfqws2" gv_tcp_plain)"
! grep -Fq -- "--lua-init=@$ZATOR_ROOT/lua/wssize-ramp.lua" "$ranking_treatment/probe/nfqws2.args" || {
  echo 'Plain media probe unexpectedly loaded the Ramp Lua implementation' >&2; exit 1;
}
supersweep_probe_config 2 "$ZAPRET2_ROOT/config" gv_tcp_ramp 93.184.216.34
grep -Fxq -- "--lua-init=@$ZATOR_ROOT/lua/wssize-ramp.lua" "$ranking_treatment/probe/nfqws2.args" || {
  echo 'Ramp probe did not load its Lua implementation' >&2; exit 1;
}
grep -Fxq -- "--ipset=$ranking_treatment/probe/googlevideo-ipv4.txt" "$ranking_treatment/probe/nfqws2.args" &&
  [[ "$(cat "$ranking_treatment/probe/googlevideo-ipv4.txt")" = 93.184.216.34 ]] || {
  echo 'Ramp probe did not constrain the isolated early-stage handler to the exact destination IP' >&2; exit 1;
}
ramp_treatment_fp="$(adaptive_strategy_fingerprint 2 1 "$ranking_treatment/probe/nfqws2.args" "$ZAPRET2_ROOT/nfq2/nfqws2" gv_tcp_ramp)"
[[ "$plain_treatment_fp" != "$ramp_treatment_fp" ]] || { echo 'Ramp treatment did not change adaptive strategy identity' >&2; exit 1; }
rm -rf "$ranking_treatment"
remote_ranked_candidates="$(call_api "action=candidates&hostname=ranked.example.org&destination_ip=93.184.216.36&profile_id=1&scope=mark%3A4&ranked_fingerprints=$ranked_fp")"
[[ "$remote_ranked_candidates" == *'"source":"remote-rankings-first"'* && "$remote_ranked_candidates" == *'"candidate_numbers":[12,'* ]] || {
  echo "remote fingerprint ranking did not reorder the local catalog: $remote_ranked_candidates" >&2; exit 1;
}
old_lua_fp="$ranked_fp"
old_lua_stamp="$stamp"
sleep 1
printf 'module-B' > "$tmp/zapret2/lua/zapret-antidpi.lua"
changed_lua_stamp="$(adaptive_rules_runtime_stamp "$ZAPRET2_ROOT/config" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ZATOR_ROOT/extra_strats/cache/orchestra")"
ranking_catalog_lua="$(mktemp -d "$ZATOR_ROOT/extra_strats/cache/adaptive/rank-catalog.XXXXXX")"
Z2R_SUPERSWEEP_DIR="$ranking_catalog_lua"
export Z2R_SUPERSWEEP_DIR
supersweep_probe_config 1 "$ZAPRET2_ROOT/config"
changed_lua_fp="$(adaptive_strategy_fingerprint 1 12 "$ranking_catalog_lua/probe/nfqws2.args" "$ZAPRET2_ROOT/nfq2/nfqws2")"
rm -rf "$ranking_catalog_lua"
[[ "$changed_lua_fp" != "$old_lua_fp" && "$changed_lua_stamp" != "$old_lua_stamp" ]] || {
  echo 'Lua implementation change did not invalidate strategy identity and runtime rules' >&2; exit 1;
}
stamp="$changed_lua_stamp"
old_blob_fp="$ranked_fp"
old_blob_stamp="$stamp"
sleep 1
printf 'blob-B' > "$ZATOR_ROOT/files/fake/tls_clienthello_max_ru.bin"
changed_blob_stamp="$(adaptive_rules_runtime_stamp "$ZAPRET2_ROOT/config" "$ZAPRET2_ROOT/nfq2/nfqws2" "$ZATOR_ROOT/extra_strats/cache/orchestra")"
ranking_catalog_changed="$(mktemp -d "$ZATOR_ROOT/extra_strats/cache/adaptive/rank-catalog.XXXXXX")"
Z2R_SUPERSWEEP_DIR="$ranking_catalog_changed"
export Z2R_SUPERSWEEP_DIR
supersweep_probe_config 1 "$ZAPRET2_ROOT/config"
changed_blob_fp="$(adaptive_strategy_fingerprint 1 12 "$ranking_catalog_changed/probe/nfqws2.args" "$ZAPRET2_ROOT/nfq2/nfqws2")"
rm -rf "$ranking_catalog_changed"
[[ "$changed_blob_fp" != "$old_blob_fp" && "$changed_blob_stamp" != "$old_blob_stamp" ]] || {
  echo 'blob-content change did not invalidate strategy identity and runtime rules' >&2; exit 1;
}
stamp="$changed_blob_stamp"
invalid_remote_ranking="$(call_api 'action=candidates&hostname=ranked.example.org&destination_ip=93.184.216.36&profile_id=1&ranked_fingerprints=12')"
[[ "$invalid_remote_ranking" == *'400 Bad Request'* ]] || { echo "malformed remote ranking was accepted: $invalid_remote_ranking" >&2; exit 1; }
printf '1\tcdn.example.org\t93.184.216.34\t1\ttls\tmark:4\t7\tsha256:%064d\tsha256:%064d\t%s\t%s\n' \
  0 1 "$stamp" "$(( $(date +%s) + 3600 ))" > "$Z2R_ADAPTIVE_DIR/rules.tsv"
ranked_candidates="$(call_api 'action=candidates&hostname=other.example.org&destination_ip=93.184.216.35&profile_id=1&scope=mark%3A4')"
[[ "$ranked_candidates" == *'"source":"local-confirmations-first"}'* && "$ranked_candidates" == *'"candidate_numbers":[7,1,2,3,4,5,6,8,9,10]'* ]] || {
  echo "local confirmations were not prioritized: $ranked_candidates" >&2; exit 1;
}
known_candidates="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=mark%3A4')"
[[ "$known_candidates" == *'"status":"already_confirmed"'* && "$known_candidates" == *'"strategy_number":7'* ]] || {
  echo "fresh exact rule was not reused: $known_candidates" >&2; exit 1;
}
revalidate_candidates="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=mark%3A4&force_revalidate=1')"
[[ "$revalidate_candidates" == *'"source":"active-rule-revalidation"'* && "$revalidate_candidates" == *'"candidate_numbers":[7,'* ]] || {
  echo "suspected failure did not put the active strategy first for revalidation: $revalidate_candidates" >&2; exit 1;
}
invalid_revalidate="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=mark%3A4&force_revalidate=2')"
[[ "$invalid_revalidate" == *'400 Bad Request'* ]] || { echo 'candidate API accepted an invalid revalidation flag' >&2; exit 1; }
printf '1\tdirect.example.org\t93.184.216.35\t1\ttls\tmark:4\t0\tsha256:%064d\tsha256:%064d\t%s\t%s\n' \
  0 1 "$stamp" "$(( $(date +%s) + 3600 ))" >> "$Z2R_ADAPTIVE_DIR/rules.tsv"
direct_candidates="$(call_api 'action=candidates&hostname=direct.example.org&destination_ip=93.184.216.35&profile_id=1&scope=mark%3A4')"
[[ "$direct_candidates" == *'"status":"already_confirmed"'* && "$direct_candidates" == *'"strategy_number":0'* && "$direct_candidates" == *'"winner_kind":"DIRECT"'* ]] || {
  echo "verified DIRECT rule was not represented as a separate winner: $direct_candidates" >&2; exit 1;
}
other_scope_candidates="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=default')"
[[ "$other_scope_candidates" == *'"status":"ready"'* ]] || { echo "confirmed rule leaked across client scope: $other_scope_candidates" >&2; exit 1; }
printf '1\trr1-index.googlevideo.com\t93.184.216.41\t2\tgooglevideo-tcp\tmark:4\t7\tsha256:%064d\tsha256:%064d\t%s\t%s\n' \
  2 3 "$stamp" "$(( $(date +%s) + 3600 ))" > "$Z2R_ADAPTIVE_DIR/rules.tsv"
rr_group_candidates="$(call_api 'action=candidates&hostname=rr2-index.googlevideo.com&destination_ip=93.184.216.42&profile_id=2&scope=mark%3A4')"
[[ "$rr_group_candidates" == *'"source":"local-confirmations-first"'* && "$rr_group_candidates" == *'"candidate_numbers":[7,'* && "$rr_group_candidates" != *'group_id'* ]] || {
  echo "rrN group confirmation was not used as a local candidate hint: $rr_group_candidates" >&2; exit 1;
}
printf '1\trr3-index.googlevideo.com\t93.184.216.46\t2\tgooglevideo-tcp\tmark:4\t9\tsha256:%064d\tsha256:%064d\t%s\t%s\n' \
  6 7 "$stamp" "$(( $(date +%s) + 3600 ))" >> "$Z2R_ADAPTIVE_DIR/rules.tsv"
rr_conflict_candidates="$(call_api 'action=candidates&hostname=rr4-index.googlevideo.com&destination_ip=93.184.216.47&profile_id=2&scope=mark%3A4')"
[[ "$rr_conflict_candidates" == *'"source":"local-profile-order"'* && "$rr_conflict_candidates" == *'"candidate_numbers":[1,'* ]] || {
  echo "conflicting rrN group confirmations did not fall back to catalog order: $rr_conflict_candidates" >&2; exit 1;
}
rr_index2_candidates="$(call_api 'action=candidates&hostname=rr2-index2.googlevideo.com&destination_ip=93.184.216.42&profile_id=2&scope=mark%3A4')"
[[ "$rr_index2_candidates" == *'"source":"local-profile-order"'* && "$rr_index2_candidates" == *'"candidate_numbers":[1,'* ]] || {
  echo "rrN-index2 incorrectly inherited the rrN-index group: $rr_index2_candidates" >&2; exit 1;
}
printf '1\tr1---sn-abcd.googlevideo.com\t93.184.216.43\t2\tgooglevideo-tcp\tmark:4\t5\tsha256:%064d\tsha256:%064d\t%s\t%s\n' \
  4 5 "$stamp" "$(( $(date +%s) + 3600 ))" >> "$Z2R_ADAPTIVE_DIR/rules.tsv"
r_group_candidates="$(call_api 'action=candidates&hostname=r2---sn-abcd.googlevideo.com&destination_ip=93.184.216.44&profile_id=2&scope=mark%3A4')"
[[ "$r_group_candidates" == *'"candidate_numbers":[5,'* ]] || {
  echo "rN CDN suffix group did not prioritize its local confirmation: $r_group_candidates" >&2; exit 1;
}
quic_candidates="$(call_api 'action=candidates&hostname=rr1-index.googlevideo.com&destination_ip=93.184.216.45&profile_id=5&scope=mark%3A4')"
[[ "$quic_candidates" == *'"protocol":"udp"'* && "$quic_candidates" == *'"recipe_id":"googlevideo-quic-h3-media-v1"'* && "$quic_candidates" == *'"candidate_numbers":[1,'* ]] || {
  echo "profile-5 candidates were not isolated to the Googlevideo HTTP/3 recipe: $quic_candidates" >&2; exit 1;
}
quic_probe_catalog="$tmp/quic-probe-catalog"
mkdir -p "$quic_probe_catalog"
Z2R_SUPERSWEEP_DIR="$quic_probe_catalog"
export Z2R_SUPERSWEEP_DIR
supersweep_probe_config 5 "$ZAPRET2_ROOT/config" standard 93.184.216.45 googlevideo-quic-h3-media-v1
for lua_init in zapret-lib zapret-antidpi zapret-auto; do
  grep -Fxq -- "--lua-init=@$ZAPRET2_ROOT/lua/$lua_init.lua" "$quic_probe_catalog/probe/nfqws2.args" || {
    echo "profile-5 probe omitted upstream Lua init $lua_init" >&2; exit 1;
  }
done
quic_owner=33333333333333333333333333333333
quic_lease="$(call_api "action=lease&hostname=rr1-index.googlevideo.com&destination_ip=93.184.216.45&profile_id=5&local_strategy_number=1&scope=mark%3A4&source_port=62032&probe_owner=$quic_owner&recipe_id=googlevideo-quic-h3-media-v1")"
quic_lease_json="${quic_lease#*$'\r\n\r\n'}"
quic_lease_id="$(printf '%s' "$quic_lease_json" | sed -n 's/.*"test_id":"\([a-f0-9]*\)".*/\1/p')"
[[ "$quic_lease" == *'Status: 200 OK'* && "$quic_lease" == *'"protocol":"udp"'* &&
   "$quic_lease" == *'"recipe_id":"googlevideo-quic-h3-media-v1"'* &&
   "$quic_lease" == *'"media":{"url":"https://rr1---sn-a5mekn6e.googlevideo.com/videoplayback?'* &&
   "$quic_lease_id" =~ ^[a-f0-9]{32}$ ]] || {
  echo "profile-5 lease did not return a private HTTP/3 media target: $quic_lease" >&2; exit 1;
}
quic_complete="action=complete&test_id=$quic_lease_id&probe_owner=$quic_owner&schema_version=1&route_verified=false&overall=INCONCLUSIVE&ip_family=ipv4&protocol=tcp&port=443&observed_at=$(date +%s)&transport=OK&application=OK&reason=media_ok&hostname=rr1-index.googlevideo.com&destination_ip=93.184.216.45&profile_id=5&scope=mark%3A4&strategy_fingerprint=sha256%3Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&local_strategy_number=1&catalog_version=sha256%3Abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&recipe_id=googlevideo-quic-h3-media-v1&client_profile=curl-windows-quic-media-v1&media_bytes=1048576&media_speed_bps=524288&media_duration_ms=2000"
wrong_quic_protocol="$(call_api "$quic_complete")"
[[ "$wrong_quic_protocol" == *'400 Bad Request'* ]] || { echo "QUIC lease accepted a TCP completion: $wrong_quic_protocol" >&2; exit 1; }
quic_complete="${quic_complete/protocol=tcp/protocol=udp}"
quic_complete_response="$(call_api "$quic_complete")"
[[ "$quic_complete_response" == *'"overall":"SUCCESS"'* ]] || {
  echo "profile-5 HTTP/3 completion was rejected: $quic_complete_response" >&2; exit 1;
}
r_other_suffix_candidates="$(call_api 'action=candidates&hostname=r2---sn-efgh.googlevideo.com&destination_ip=93.184.216.44&profile_id=2&scope=mark%3A4')"
[[ "$r_other_suffix_candidates" == *'"source":"local-profile-order"'* ]] || {
  echo "different rN CDN suffix inherited another group's confirmation: $r_other_suffix_candidates" >&2; exit 1;
}
rm -f "$Z2R_ADAPTIVE_DIR/rules.tsv"
printf '1\ttls\t3\n' > "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv"
locked_candidates="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=default')"
[[ "$locked_candidates" == *'409 Conflict'* ]] || { echo "candidate scheduler ignored a profile lock: $locked_candidates" >&2; exit 1; }
rm -f "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv"
expired_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$Z2R_ADAPTIVE_DIR/$expired_id/leases" "$Z2R_ADAPTIVE_DIR/legacy"
printf 'complete\n' > "$Z2R_ADAPTIVE_DIR/$expired_id/state"
printf '%s\t192.168.1.44\t62000\t93.184.216.34\t443\t%s\ttls-http1-v1\n' "$expired_id" "$(( $(date +%s) - 700 ))" > "$Z2R_ADAPTIVE_DIR/$expired_id/leases/$expired_id.tsv"
lease_owner=11111111111111111111111111111111
lease_response="$(call_api "action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&source_port=62017&probe_owner=$lease_owner")"
[[ "$lease_response" == *'Content-Type: application/json'* && "$lease_response" == *'Status: 200 OK'* ]] || {
  echo "lease response is missing CGI headers: $lease_response" >&2; exit 1;
}
lease_json="${lease_response#*$'\r\n\r\n'}"
id="$(printf '%s' "$lease_json" | sed -n 's/.*"test_id":"\([a-f0-9]*\)".*/\1/p')"
[[ "$id" =~ ^[a-f0-9]{32}$ && "$lease_json" == *'"source_port":62017'* ]] || { echo "lease failed to honor the available client port: $lease_response" >&2; exit 1; }
bad_source_port="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&source_port=63000')"
[[ "$bad_source_port" == *'400 Bad Request'* ]] || { echo 'lease accepted an out-of-range client source port' >&2; exit 1; }
[[ ! -e "$Z2R_ADAPTIVE_DIR/$expired_id" && -d "$Z2R_ADAPTIVE_DIR/legacy" ]] || { echo 'GC removed the wrong run directory' >&2; exit 1; }
body="action=complete&test_id=$id&probe_owner=$lease_owner&schema_version=1&route_verified=false&overall=INCONCLUSIVE&ip_family=ipv4&protocol=tcp&port=443&observed_at=$(date +%s)&transport=OK&application=OK&reason=probe_ok&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&scope=default&strategy_fingerprint=sha256%3Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&local_strategy_number=1&catalog_version=sha256%3Abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&recipe_id=tls-http1-v1&client_profile=curl-windows-v1"
wrong_owner_complete="$(call_api "${body/probe_owner=$lease_owner/probe_owner=22222222222222222222222222222222}")"
[[ "$wrong_owner_complete" == *'403 Forbidden'* ]] || { echo 'completion accepted a mismatched probe owner' >&2; exit 1; }
complete="$(call_api "$body")"
[[ "$complete" == *'"overall":"SUCCESS"'* ]] || { echo "completion failed: $complete" >&2; exit 1; }
scoped_owner=44444444444444444444444444444444
scoped_lease_response="$(call_api "action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&scope=mark%3A4&probe_owner=$scoped_owner")"
scoped_lease_json="${scoped_lease_response#*$'\r\n\r\n'}"
scoped_id="$(printf '%s' "$scoped_lease_json" | sed -n 's/.*"test_id":"\([a-f0-9]*\)".*/\1/p')"
[[ "$scoped_id" =~ ^[a-f0-9]{32}$ && "$scoped_lease_json" == *'"scope":"mark:4"'* ]] || {
  echo "scoped lease lost the client scope: $scoped_lease_response" >&2; exit 1;
}
scoped_body="${body/test_id=$id/test_id=$scoped_id}"
scoped_body="${scoped_body/scope=default/scope=mark%3A4}"
scoped_body="${scoped_body/probe_owner=$lease_owner/probe_owner=$scoped_owner}"
scoped_complete="$(call_api "$scoped_body")"
[[ "$scoped_complete" == *'"overall":"SUCCESS"'* ]] || { echo "scoped completion failed: $scoped_complete" >&2; exit 1; }
own_probe=cccccccccccccccccccccccccccccccc
other_probe=dddddddddddddddddddddddddddddddd
expired_probe=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
done_probe=ffffffffffffffffffffffffffffffff
mkdir -p "$Z2R_ADAPTIVE_DIR/$own_probe/leases" "$Z2R_ADAPTIVE_DIR/$other_probe/leases" \
  "$Z2R_ADAPTIVE_DIR/$expired_probe/leases" "$Z2R_ADAPTIVE_DIR/$done_probe/leases"
printf 'leased\n' > "$Z2R_ADAPTIVE_DIR/$own_probe/state"
printf 'leased\n' > "$Z2R_ADAPTIVE_DIR/$other_probe/state"
printf 'leased\n' > "$Z2R_ADAPTIVE_DIR/$expired_probe/state"
printf 'complete\n' > "$Z2R_ADAPTIVE_DIR/$done_probe/state"
printf '%s\t192.168.1.44\t62010\t93.184.216.34\t443\t%s\ttls-http1-v1\n' "$own_probe" "$(( $(date +%s) + 60 ))" > "$Z2R_ADAPTIVE_DIR/$own_probe/leases/$own_probe.tsv"
printf '%s\t192.168.1.45\t62011\t93.184.216.35\t443\t%s\ttls-http1-v1\n' "$other_probe" "$(( $(date +%s) + 60 ))" > "$Z2R_ADAPTIVE_DIR/$other_probe/leases/$other_probe.tsv"
printf '%s\t192.168.1.44\t62012\t93.184.216.36\t443\t%s\ttls-http1-v1\n' "$expired_probe" "$(( $(date +%s) - 1 ))" > "$Z2R_ADAPTIVE_DIR/$expired_probe/leases/$expired_probe.tsv"
printf '%s\t192.168.1.44\t62013\t93.184.216.37\t443\t%s\ttls-http1-v1\n' "$done_probe" "$(( $(date +%s) + 60 ))" > "$Z2R_ADAPTIVE_DIR/$done_probe/leases/$done_probe.tsv"
cancel_response="$(call_api 'action=cancel_probes')"
[[ "$cancel_response" == *'"cancelled":1'* && "$(cat "$Z2R_ADAPTIVE_DIR/$own_probe/cancel")" == urgent_request &&
   ! -e "$Z2R_ADAPTIVE_DIR/$other_probe/cancel" && ! -e "$Z2R_ADAPTIVE_DIR/$expired_probe/cancel" &&
   ! -e "$Z2R_ADAPTIVE_DIR/$done_probe/cancel" ]] || {
  echo "urgent preemption did not cancel only the requesting LAN client's probe: $cancel_response" >&2; exit 1;
}
invalid_cancel="$(call_api 'action=cancel_probes&test_id=anything')"
[[ "$invalid_cancel" == *'400 Bad Request'* ]] || { echo 'cancel_probes accepted caller-supplied selectors' >&2; exit 1; }
exact_probe=abababababababababababababababab
same_ip_probe=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
same_port_other_owner=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
owner_a=22222222222222222222222222222222
owner_b=33333333333333333333333333333333
mkdir -p "$Z2R_ADAPTIVE_DIR/$exact_probe/leases" "$Z2R_ADAPTIVE_DIR/$same_ip_probe/leases" "$Z2R_ADAPTIVE_DIR/$same_port_other_owner/leases"
printf 'leased\n' > "$Z2R_ADAPTIVE_DIR/$exact_probe/state"
printf 'leased\n' > "$Z2R_ADAPTIVE_DIR/$same_ip_probe/state"
printf '%s\t192.168.1.44\t62020\t93.184.216.40\t443\t%s\ttls-http1-v1\n' "$exact_probe" "$(( $(date +%s) + 60 ))" > "$Z2R_ADAPTIVE_DIR/$exact_probe/leases/$exact_probe.tsv"
printf '%s\t192.168.1.44\t62021\t93.184.216.41\t443\t%s\ttls-http1-v1\n' "$same_ip_probe" "$(( $(date +%s) + 60 ))" > "$Z2R_ADAPTIVE_DIR/$same_ip_probe/leases/$same_ip_probe.tsv"
printf '%s\t192.168.1.44\t62020\t93.184.216.42\t443\t%s\ttls-http1-v1\t%s\n' "$same_port_other_owner" "$(( $(date +%s) + 60 ))" "$owner_b" > "$Z2R_ADAPTIVE_DIR/$same_port_other_owner/leases/$same_port_other_owner.tsv"
printf '%s\t192.168.1.44\t62020\t93.184.216.40\t443\t%s\ttls-http1-v1\t%s\n' "$exact_probe" "$(( $(date +%s) + 60 ))" "$owner_a" > "$Z2R_ADAPTIVE_DIR/$exact_probe/leases/$exact_probe.tsv"
wrong_owner_cancel="$(call_api "action=cancel_probes&source_port=62020&probe_owner=99999999999999999999999999999999")"
[[ "$wrong_owner_cancel" == *'"cancelled":0'* && ! -e "$Z2R_ADAPTIVE_DIR/$exact_probe/cancel" && ! -e "$Z2R_ADAPTIVE_DIR/$same_port_other_owner/cancel" ]] || {
  echo "cancellation accepted a non-matching probe owner: $wrong_owner_cancel" >&2; exit 1;
}
exact_cancel="$(call_api "action=cancel_probes&source_port=62020&probe_owner=$owner_a")"
[[ "$exact_cancel" == *'"cancelled":1'* && "$(cat "$Z2R_ADAPTIVE_DIR/$exact_probe/cancel")" = urgent_request &&
   ! -e "$Z2R_ADAPTIVE_DIR/$same_ip_probe/cancel" && ! -e "$Z2R_ADAPTIVE_DIR/$same_port_other_owner/cancel" ]] || {
  echo "source-port cancellation affected another lease owned by the same LAN IP: $exact_cancel" >&2; exit 1;
}
bad_source_port_cancel="$(call_api 'action=cancel_probes&source_port=6200&probe_owner=22222222222222222222222222222222')"
[[ "$bad_source_port_cancel" == *'400 Bad Request'* ]] || { echo 'cancel_probes accepted an invalid source port' >&2; exit 1; }
for pair in 'route_verified=false:route_verified=true' 'overall=INCONCLUSIVE:overall=SUCCESS' 'ip_family=ipv4:ip_family=ipv6' 'protocol=tcp:protocol=udp' 'port=443:port=8443'; do
  original="${pair%%:*}"; replacement="${pair#*:}"
  rejected="$(call_api "${body/$original/$replacement}")"
  [[ "$rejected" == *'400 Bad Request'* ]] || { echo "invalid recipe accepted ($replacement): $rejected" >&2; exit 1; }
done
duplicate="$(call_api "$body")"
[[ "$duplicate" == *'"overall":"SUCCESS"'* ]] || { echo 'idempotent completion failed' >&2; exit 1; }
conflict="$(call_api "${body/transport=OK/transport=FAIL}")"
[[ "$conflict" == *'409 Conflict'* ]] || { echo "conflicting completion accepted: $conflict" >&2; exit 1; }
scope_conflict="$(call_api "${body/scope=default/scope=mark%3A4}")"
[[ "$scope_conflict" == *'409 Conflict'* ]] || { echo "completion changed client scope: $scope_conflict" >&2; exit 1; }
now="$(date +%s)"
printf '1\tsuspected_failure\tcdn.example.org\t93.184.216.34\t2\ttls\tmark:4\t%s\n1\tactive_rule_degraded\tcdn2.example.org\t93.184.216.35\t2\ttls\tmark:4\t%s\n1\tseen\tbad host\t192.168.1.1\t1\ttls\tdefault\t%s\n' "$now" "$now" "$now" > "$Z2R_ADAPTIVE_DIR/events.tsv"
events="$(call_api 'action=events')"
[[ "$events" == *'Content-Type: application/json'* && "$events" == *'"status":"suspected_failure"'* && "$events" == *'"status":"active_rule_degraded"'* && "$events" == *'"hostname":"cdn.example.org"'* && "$events" == *'"profile_id":2'* && "$events" == *'"scope":"mark:4"'* && "$events" != *'bad host'* ]] || {
  echo "events API returned invalid observation data: $events" >&2; exit 1;
}
printf 'AGENT_BETA\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
printf '1\trr2-index.googlevideo.com\t142.250.72.14\tmark:4\t%s\ttls-observed\tgv1:rr:index\tpending\t0\tunknown\n1\tbad.googlevideo.com.evil.org\t142.250.72.15\tdefault\t%s\ttls-observed\tgv1:exact:bad.googlevideo.com.evil.org\tpending\t0\tunknown\n1\tprivate.googlevideo.com\t192.168.1.1\tdefault\t%s\ttls-observed\tgv1:exact:private.googlevideo.com\tpending\t0\tunknown\n1\tstale.googlevideo.com\t142.250.72.16\tdefault\t%s\ttls-observed\tgv1:exact:stale.googlevideo.com\tpending\t0\tunknown\n' \
  "$now" "$now" "$now" "$(( now - 604801 ))" > "$Z2R_ADAPTIVE_DIR/ramp-targets.tsv"
mkdir -p "$ZATOR_ROOT/lists"
printf '142.250.72.14\n' > "$ZATOR_ROOT/lists/googlevideo-ipv4.txt"
sed -i 's/^Z2R_WSSIZE_RAMP_ENABLE=0$/Z2R_WSSIZE_RAMP_ENABLE=1/' "$ZAPRET2_ROOT/config"
ramp_targets="$(call_api 'action=ramp_targets')"
[[ "$ramp_targets" == *'Status: 200 OK'* && "$ramp_targets" == *'"hostname":"rr2-index.googlevideo.com"'* &&
   "$ramp_targets" == *'"group_id":"gv1:rr:index"'* && "$ramp_targets" == *'"provenance":"tls-observed"'* &&
   "$ramp_targets" == *'"ramp_state":"ramp_default"'* &&
   "$ramp_targets" == *'"dns_expires_at":null'* && "$ramp_targets" != *'bad.googlevideo.com.evil.org'* &&
   "$ramp_targets" != *'192.168.1.1'* && "$ramp_targets" != *'stale.googlevideo.com'* ]] || {
  echo "ramp target API failed filtering or safe serialization: $ramp_targets" >&2; exit 1;
}
printf '1\trr3-index.googlevideo.com\t142.250.72.14\tmark:4\t%s\ttls-observed\tgv1:rr:index\tconflict\t0\tunknown\n' "$now" >> "$Z2R_ADAPTIVE_DIR/ramp-targets.tsv"
ramp_conflict_targets="$(call_api 'action=ramp_targets')"
[[ "$ramp_conflict_targets" == *'"hostname":"rr3-index.googlevideo.com"'* && "$ramp_conflict_targets" == *'"ramp_state":"conflict"'* ]] || {
  echo "Ramp IP conflict was overwritten by the pool default: $ramp_conflict_targets" >&2; exit 1;
}
proof_host=rr4-index.googlevideo.com proof_ip=142.250.72.17 proof_scope=mark:4
printf '1\t%s\t%s\t%s\t%s\ttls-observed\tgv1:rr:index\tpending\t0\tunknown\n' "$proof_host" "$proof_ip" "$proof_scope" "$now" >> "$Z2R_ADAPTIVE_DIR/ramp-targets.tsv"
printf '%s\n%s\n' 142.250.72.14 "$proof_ip" > "$ZATOR_ROOT/lists/googlevideo-ipv4.txt"
proof_ids=(00000000000000000000000000000001 00000000000000000000000000000002 00000000000000000000000000000003 00000000000000000000000000000004)
proof_treatments=(gv_tcp_ramp gv_tcp_plain gv_tcp_plain gv_tcp_ramp)
for i in 0 1 2 3; do
  proof_id="${proof_ids[$i]}" treatment="${proof_treatments[$i]}" observed="$((now - 100 + i * 10))"
  mkdir -p "$Z2R_ADAPTIVE_DIR/$proof_id"
  ramp_stage=false
  [[ "$treatment" != gv_tcp_ramp ]] || ramp_stage=true
  printf '{"schema_version":1,"test_id":"%s","route_verified":true,"queue_seen":true,"strategy_ack_seen":true,"syn_stage_confirmed":%s,"late_ack_stage_confirmed":%s,"transport":"OK","application":"OK","overall":"SUCCESS","reason":"media_ok","observed_at":%s,"target":{"hostname":"%s","destination_ip":"%s","ip_family":"ipv4","protocol":"tcp","port":443,"profile_id":2,"scope":"%s"},"strategy":{"fingerprint":"sha256:%064d","local_number":7,"catalog_version":"sha256:%064d"},"recipe_id":"googlevideo-tcp-media-v1","treatment_variant":"%s","client_profile":"curl-windows-media-v1","media_url_sha256":"%064d","media_bytes":1048576,"media_speed_bps":524288,"media_duration_ms":2000}\n' \
    "$proof_id" "$ramp_stage" "$ramp_stage" "$observed" "$proof_host" "$proof_ip" "$proof_scope" 1 2 "$treatment" 3 > "$Z2R_ADAPTIVE_DIR/$proof_id/result.json"
done
proof_id_csv="$(IFS=,; printf '%s' "${proof_ids[*]}")"
proof_body="action=ramp_exempt_apply&hostname=$proof_host&destination_ip=$proof_ip&scope=mark%3A4&test_ids=$proof_id_csv"
no_lan_consent="$(call_api "$proof_body")"
[[ "$no_lan_consent" == *'403 Forbidden'* ]] || { echo "Ramp exemption applied without explicit LAN consent: $no_lan_consent" >&2; exit 1; }
printf '1\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/apply-default-scope"
proof_applied="$(call_api "$proof_body")"
[[ "$proof_applied" == *'"status":"ramp_exempt"'* && "$proof_applied" == *"$proof_ip"* ]] || {
  echo "verified Ramp proof did not apply an exact exemption: $proof_applied" >&2; exit 1;
}
[[ "$(wc -l < "$Z2R_ADAPTIVE_DIR/ramp-exempt.tsv")" = 1 && "$(cat "$Z2R_ADAPTIVE_DIR/ramp-exempt.tsv")" != *'videoplayback'* ]] || {
  echo 'Ramp exemption store was unbounded or persisted the signed URL' >&2; exit 1;
}
[[ "$(stat -c '%a' "$Z2R_ADAPTIVE_DIR/ramp-exempt.tsv")" = 644 ]] || {
  echo 'Ramp exemption is not readable by the dropped-privilege nfqws2 worker' >&2; exit 1;
}
ramp_targets_exempt="$(call_api 'action=ramp_targets')"
[[ "$ramp_targets_exempt" == *'"hostname":"rr4-index.googlevideo.com"'* && "$ramp_targets_exempt" == *'"ramp_state":"ramp_exempt"'* ]] || {
  echo "Ramp target API did not expose the exact active exemption: $ramp_targets_exempt" >&2; exit 1;
}
revoke_ids=(00000000000000000000000000000005 00000000000000000000000000000006 00000000000000000000000000000007)
revoke_treatments=(gv_tcp_ramp gv_tcp_plain gv_tcp_ramp)
for i in 0 1 2; do
  revoke_id="${revoke_ids[$i]}" treatment="${revoke_treatments[$i]}" observed="$((now - 30 + i * 10))"
  ramp_stage=false overall=INCONCLUSIVE transport=UNKNOWN application=UNKNOWN reason=media_insufficient
  if [[ "$treatment" = gv_tcp_ramp ]]; then ramp_stage=true overall=SUCCESS transport=OK application=OK reason=media_ok; fi
  if [[ "$treatment" = gv_tcp_plain ]]; then transport=OK; fi
  mkdir -p "$Z2R_ADAPTIVE_DIR/$revoke_id"
  printf '{"schema_version":1,"test_id":"%s","route_verified":true,"queue_seen":true,"strategy_ack_seen":true,"syn_stage_confirmed":%s,"late_ack_stage_confirmed":%s,"transport":"%s","application":"%s","overall":"%s","reason":"%s","observed_at":%s,"target":{"hostname":"%s","destination_ip":"%s","ip_family":"ipv4","protocol":"tcp","port":443,"profile_id":2,"scope":"%s"},"strategy":{"fingerprint":"sha256:%064d","local_number":7,"catalog_version":"sha256:%064d"},"recipe_id":"googlevideo-tcp-media-v1","treatment_variant":"%s","client_profile":"curl-windows-media-v1","media_url_sha256":"%064d","media_bytes":0,"media_speed_bps":0,"media_duration_ms":2000}\n' \
    "$revoke_id" "$ramp_stage" "$ramp_stage" "$transport" "$application" "$overall" "$reason" "$observed" \
    "$proof_host" "$proof_ip" "$proof_scope" 1 2 "$treatment" 3 > "$Z2R_ADAPTIVE_DIR/$revoke_id/result.json"
  if [[ "$treatment" = gv_tcp_ramp ]]; then sed -i 's/"media_bytes":0/"media_bytes":1048576/; s/"media_speed_bps":0/"media_speed_bps":524288/' "$Z2R_ADAPTIVE_DIR/$revoke_id/result.json"; fi
done
revoke_id_csv="$(IFS=,; printf '%s' "${revoke_ids[*]}")"
revoke_body="action=ramp_exempt_revoke&hostname=$proof_host&destination_ip=$proof_ip&scope=mark%3A4&test_ids=$revoke_id_csv"
revoke_control="$Z2R_ADAPTIVE_DIR/${revoke_ids[2]}/result.json"
cp "$revoke_control" "$revoke_control.good"
sed -i 's/"media_bytes":1048576/"media_bytes":1/' "$revoke_control"
bad_revoke="$(call_api "$revoke_body")"
[[ "$bad_revoke" == *'409 Conflict'* && "$(cat "$Z2R_ADAPTIVE_DIR/ramp-exempt.tsv")" == *"$proof_ip"* ]] || {
  echo 'Ramp exemption was revoked without a successful return Ramp control' >&2; exit 1;
}
mv -f "$revoke_control.good" "$revoke_control"
revoked="$(call_api "$revoke_body")"
[[ "$revoked" == *'"status":"ramp_default"'* && "$(cat "$Z2R_ADAPTIVE_DIR/ramp-exempt.tsv")" != *"$proof_ip"* ]] || {
  echo "verified Ramp/plain/Ramp degradation did not revoke the exact exception: $revoked" >&2; exit 1;
}
bad_revoke="$(call_api "$revoke_body")"
[[ "$bad_revoke" == *'409 Conflict'* ]] || { echo 'Ramp exemption revocation accepted a second request after exact removal' >&2; exit 1; }
printf '1\trr5-index.googlevideo.com\t%s\tdefault\t%s\ttls-observed\tgv1:rr:index\tpending\t0\tunknown\n' "$proof_ip" "$now" >> "$Z2R_ADAPTIVE_DIR/ramp-targets.tsv"
ramp_conflict_after_apply="$(call_api 'action=ramp_targets')"
[[ "$ramp_conflict_after_apply" == *'"hostname":"rr4-index.googlevideo.com"'* && "$ramp_conflict_after_apply" == *'"ramp_state":"conflict"'* ]] || {
  echo "new shared-IP observation did not override the active Ramp exception: $ramp_conflict_after_apply" >&2; exit 1;
}
conflict_apply="$(call_api "$proof_body")"
[[ "$conflict_apply" == *'409 Conflict'* ]] || { echo 'Ramp exception was renewed despite a shared-IP conflict' >&2; exit 1; }
sed -i 's/^Z2R_WSSIZE_RAMP_ENABLE=1$/Z2R_WSSIZE_RAMP_ENABLE=0/' "$ZAPRET2_ROOT/config"
ramp_disabled_targets="$(call_api 'action=ramp_targets')"
[[ "$ramp_disabled_targets" != *'"ramp_state":"ramp_default"'* && "$ramp_disabled_targets" != *'"ramp_state":"ramp_exempt"'* ]] || {
  echo 'disabled Ramp config was advertised as Ramp default or exemption' >&2; exit 1;
}
printf 'TEST_ONLY\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
ramp_targets_test_only="$(call_api 'action=ramp_targets')"
[[ "$ramp_targets_test_only" == *'403 Forbidden'* ]] || { echo 'Ramp target API was available outside AGENT_BETA' >&2; exit 1; }
mkdir -p "$Z2R_ADAPTIVE_NDM_ROOT"
printf 'AGENT_BETA\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
ramp_targets_unsupported="$(call_api 'action=ramp_targets')"
[[ "$ramp_targets_unsupported" == *'"supported":false'* && "$ramp_targets_unsupported" == *'keenetic_late_ack_gate_unverified'* && "$ramp_targets_unsupported" == *'"targets":[]'* ]] || {
  echo "Keenetic Ramp audit was not reported unsupported: $ramp_targets_unsupported" >&2; exit 1;
}
ramp_lease_unsupported="$(call_api 'action=lease&hostname=rr4-index.googlevideo.com&destination_ip=142.250.72.17&profile_id=2&local_strategy_number=7&recipe_id=googlevideo-tcp-media-v1&treatment_variant=gv_tcp_ramp')"
[[ "$ramp_lease_unsupported" == *'403 Forbidden'* && "$ramp_lease_unsupported" == *'late-ACK gate'* ]] || {
  echo "Keenetic AGENT_BETA accepted a Ramp lease: $ramp_lease_unsupported" >&2; exit 1;
}
ramp_apply_unsupported="$(call_api "$proof_body")"
[[ "$ramp_apply_unsupported" == *'403 Forbidden'* && "$ramp_apply_unsupported" == *'late-ACK gate'* ]] || {
  echo "Keenetic Ramp exemption apply was not blocked: $ramp_apply_unsupported" >&2; exit 1;
}
ramp_revoke_unsupported="$(call_api "$revoke_body")"
[[ "$ramp_revoke_unsupported" == *'403 Forbidden'* && "$ramp_revoke_unsupported" == *'late-ACK gate'* ]] || {
  echo "Keenetic Ramp exemption revoke was not blocked: $ramp_revoke_unsupported" >&2; exit 1;
}
agent_status="$(call_api 'action=agent_status&stage=deep_search&statistics_enabled=true&rankings_enabled=false&search_outcome=deep_scheduled&candidates_checked=12&fast_candidates=10&deep_candidates=2&search_duration_ms=123456&time_to_first_success_ms=0&pc_cpu_percent=23&pc_free_memory_bytes=8589934592&pc_network_bytes_per_second=4096&router_load_milli=320&router_memory_available_kib=65536&router_active_probes=0&revalidation_recoveries=4&revalidation_failures=1&cooldown_targets=2')"
[[ "$agent_status" == *'"ok":true'* && "$(cat "$Z2R_ADAPTIVE_DIR/agent.status.tsv")" == *$'\tdeep_search\ttrue\tfalse\tdeep_scheduled\t12\t10\t2\t123456\t0\t23\t8589934592\t4096\t320\t65536\t0\t4\t1\t2'* &&
   "$(stat -c '%a' "$Z2R_ADAPTIVE_DIR/agent.status.tsv")" = 600 ]] || {
  echo 'authenticated bounded search status was not persisted privately' >&2; exit 1;
}
legacy_agent_status="$(call_api 'action=agent_status&stage=cooldown&statistics_enabled=true&rankings_enabled=false&search_outcome=deep_scheduled&candidates_checked=12&fast_candidates=10&deep_candidates=2&search_duration_ms=123456&time_to_first_success_ms=0&pc_cpu_percent=23&pc_free_memory_bytes=8589934592&pc_network_bytes_per_second=4096&router_load_milli=320&router_memory_available_kib=65536&router_active_probes=0&revalidation_recoveries=4&revalidation_failures=1')"
[[ "$legacy_agent_status" == *'"ok":true'* && "$(cat "$Z2R_ADAPTIVE_DIR/agent.status.tsv")" == *$'\tcooldown\ttrue\tfalse'* && "$(tail -n 1 "$Z2R_ADAPTIVE_DIR/agent.status.tsv")" == *$'\t4\t1\t0' ]] || {
  echo 'legacy watcher status without cooldown count was not accepted' >&2; exit 1;
}
status_before_bad_update="$(cat "$Z2R_ADAPTIVE_DIR/agent.status.tsv")"
bad_agent_status="$(call_api 'action=agent_status&stage=deep_search&statistics_enabled=true&rankings_enabled=false&search_outcome=deep_scheduled&candidates_checked=12&fast_candidates=10&deep_candidates=2&search_duration_ms=123456&time_to_first_success_ms=0&pc_cpu_percent=101&pc_free_memory_bytes=8589934592&pc_network_bytes_per_second=4096&router_load_milli=320&router_memory_available_kib=65536&router_active_probes=0&revalidation_recoveries=4&revalidation_failures=1&cooldown_targets=2')"
[[ "$bad_agent_status" == *'400 Bad Request'* && "$(cat "$Z2R_ADAPTIVE_DIR/agent.status.tsv")" = "$status_before_bad_update" ]] || {
  echo 'out-of-range runtime metric replaced the last valid watcher snapshot' >&2; exit 1;
}
heartbeat="$(cat "$Z2R_ADAPTIVE_DIR/agent.last")"
[[ "$heartbeat" =~ ^[0-9]{10}$ && "$(stat -c '%a' "$Z2R_ADAPTIVE_DIR/agent.last")" = 600 && "$heartbeat" -ge "$(( $(date +%s) - 10 ))" ]] || {
  echo 'authenticated watcher heartbeat was not written privately' >&2; exit 1;
}
request_id="$(ZATOR_ROOT="$ZATOR_ROOT" Z2R_ADAPTIVE_DIR="$Z2R_ADAPTIVE_DIR" bash -c '. "$1"; adaptive_queue_request cdn.example.org 93.184.216.34 2 mark:4' _ "$ROOT/lib/adaptive_queue.sh")"
[[ "$request_id" =~ ^[a-f0-9]{32}$ ]] || { echo 'manual probe request was not queued' >&2; exit 1; }
duplicate_request="$(ZATOR_ROOT="$ZATOR_ROOT" Z2R_ADAPTIVE_DIR="$Z2R_ADAPTIVE_DIR" bash -c '. "$1"; adaptive_queue_request cdn.example.org 93.184.216.34 2 mark:4' _ "$ROOT/lib/adaptive_queue.sh" 2>/dev/null || true)"
[[ -z "$duplicate_request" ]] || { echo 'manual request cooldown did not suppress duplicate' >&2; exit 1; }
events="$(call_api 'action=events')"
[[ "$events" == *"\"request_id\":\"$request_id\""* && "$events" == *'"status":"needs_verify"'* ]] || { echo 'queued manual request did not reach the paired agent' >&2; exit 1; }
[[ "$(wc -l < "$Z2R_RECOVERY_TEST_LOG")" -ge 1 ]] || { echo 'Watch event polling did not invoke stale-probe recovery' >&2; exit 1; }
recovery_calls_before_live="$(wc -l < "$Z2R_RECOVERY_TEST_LOG")"
printf 'adaptive-lan\t424242\t%s\n' "$(cat /proc/sys/kernel/random/boot_id)" > "$Z2R_ADAPTIVE_LOCK_DIR/owner"
live_recovery="$(Z2R_RECOVERY_TEST_LIVE_PID=424242 call_api 'action=events')"
rm -f "$Z2R_ADAPTIVE_LOCK_DIR/owner"
[[ "$live_recovery" == *'Status: 200 OK'* && "$(wc -l < "$Z2R_RECOVERY_TEST_LOG")" = "$recovery_calls_before_live" ]] || {
  echo 'event polling disrupted or attempted recovery of a live adaptive controller' >&2; exit 1;
}
failed_recovery="$(Z2R_RECOVERY_TEST_FAIL=1 call_api 'action=events')"
[[ "$failed_recovery" == *'503 Service Unavailable'* && "$failed_recovery" == *'could not verify its queue owner or clean its rules'* ]] || {
  echo 'Watch event API continued after stale-probe recovery failed closed' >&2; exit 1;
}
recovery_calls_before_lease="$(wc -l < "$Z2R_RECOVERY_TEST_LOG")"
recovery_lease="$(call_api 'action=lease&hostname=lease-recovery.example.org&destination_ip=93.184.216.32&profile_id=1&local_strategy_number=1')"
[[ "$recovery_lease" == *'Status: 200 OK'* && "$(wc -l < "$Z2R_RECOVERY_TEST_LOG")" -gt "$recovery_calls_before_lease" ]] || {
  echo 'new lease did not run stale-probe recovery before queue ownership' >&2; exit 1;
}
ack="$(call_api "action=ack_request&request_id=$request_id")"
[[ "$ack" == *'"ok":true'* ]] || { echo 'agent could not acknowledge its manual request' >&2; exit 1; }
event_ack="$(call_api 'action=ack_event&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=2&scope=mark%3A4')"
[[ "$event_ack" == *'"ok":true'* ]] || { echo 'agent could not persist event cooldown' >&2; exit 1; }
events="$(call_api 'action=events')"
[[ "$events" != *"\"request_id\":\"$request_id\""* && "$events" != *'"hostname":"cdn.example.org"'* ]] || { echo 'acknowledged work remained visible after event cooldown' >&2; exit 1; }
: > "$Z2R_ADAPTIVE_DIR/events.tsv"
for n in $(seq 1 128); do
  printf '1\tseen\th%s.example.org\t93.184.216.%s\t1\ttls\tdefault\t%s\n' "$n" "$n" "$now" >> "$Z2R_ADAPTIVE_DIR/events.tsv"
done
full_queue_request="$(ZATOR_ROOT="$ZATOR_ROOT" Z2R_ADAPTIVE_DIR="$Z2R_ADAPTIVE_DIR" bash -c '. "$1"; adaptive_queue_request h128.example.org 93.184.216.128 1 default' _ "$ROOT/lib/adaptive_queue.sh")"
full_queue_events="$(call_api 'action=events')"
[[ "$full_queue_events" == *"\"request_id\":\"$full_queue_request\""* ]] || { echo 'full passive ring hid the explicit verification request' >&2; exit 1; }
call_api "action=ack_request&request_id=$full_queue_request" >/dev/null
bad_target="$(call_api 'action=lease&hostname=example.com&destination_ip=192.168.1.1&profile_id=1&local_strategy_number=1')"
[[ "$bad_target" == *'400 Bad Request'* ]] || { echo "private target accepted: $bad_target" >&2; exit 1; }
bad_scope="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&scope=mark%3A65536')"
[[ "$bad_scope" == *'400 Bad Request'* ]] || { echo "out-of-range client scope accepted: $bad_scope" >&2; exit 1; }
printf 'OFF\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
paused_lease="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1')"
[[ "$paused_lease" == *'403 Forbidden'* ]] || { echo "probe lease was issued after OFF: $paused_lease" >&2; exit 1; }
echo 'adaptive API smoke: ok'
