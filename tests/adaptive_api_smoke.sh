#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -q 'cgi-bin/adaptive.cgi' "$ROOT/z2r.sh" || { echo 'adaptive API is not deployed with WebUI' >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs"
mkdir -p "$ZATOR_ROOT/extra_strats/cache/adaptive" "$ZATOR_ROOT/extra_strats/cache/orchestra" "$ZATOR_ROOT/z2r_lib" "$ZATOR_ROOT/tools" "$ZATOR_ROOT/lua" "$tmp/zapret2/nfq2" "$Z2R_ADAPTIVE_DIR"
mkdir -p "$ZATOR_ROOT/files/fake"
printf 'blob-A' > "$ZATOR_ROOT/files/fake/tls_clienthello_max_ru.bin"
printf 'Example ISP - Test City\n' > "$ZATOR_ROOT/extra_strats/cache/provider.txt"
cp "$ROOT/lib/adaptive_lan_transport.sh" "$ZATOR_ROOT/z2r_lib/"
cp "$ROOT/lib/config.sh" "$ROOT/lib/orchestra_state.sh" "$ROOT/lib/adaptive_rules.sh" "$ROOT/lib/supersweep_probe.sh" "$ZATOR_ROOT/z2r_lib/"
cp "$ROOT/lib/adaptive_queue.sh" "$ZATOR_ROOT/z2r_lib/"
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
printf '%064d' 7 > "$ZATOR_ROOT/extra_strats/cache/adaptive/token"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$ZATOR_ROOT/extra_strats/cache/adaptive/token.expires"
printf 'OFF\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
cat > "$ZATOR_ROOT/tools/adaptive-controller.sh" <<'CONTROLLER'
#!/usr/bin/env bash
set -eu
id="$1" ip="$2" port="$3" host="$4" dst="$5" profile="$6" strategy="$7" expiry="$8" scope="$9"
run="$Z2R_ADAPTIVE_DIR/$id"
mkdir -p "$run/leases"
fingerprint=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
catalog=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$dst" "$profile" "$fingerprint" "$strategy" "$catalog" "$scope" > "$run/target.tsv"
printf '%s\t%s\t%s\t%s\t443\t%s\ttls-http1-v1\n' "$id" "$ip" "$port" "$dst" "$expiry" > "$run/leases/$id.tsv"
printf '{"schema_version":1,"test_id":"%s","source_ip":"%s","source_port":%s,"destination_ip":"%s","port":443,"expires":%s,"recipe_id":"tls-http1-v1","profile_id":%s,"scope":"%s","local_strategy_number":%s,"strategy_fingerprint":"%s","catalog_version":"%s"}\n' "$id" "$ip" "$port" "$dst" "$expiry" "$profile" "$scope" "$strategy" "$fingerprint" "$catalog" > "$run/lease.json"
(
  while [[ ! -s "$run/complete.tsv" ]]; do sleep .05; done
  IFS=$'\t' read -r schema test_id observed transport application reason host dst profile fp strategy catalog recipe client result_scope < "$run/complete.tsv"
  printf '{"schema_version":1,"test_id":"%s","route_verified":true,"transport":"%s","application":"%s","overall":"SUCCESS","reason":"%s"}\n' "$test_id" "$transport" "$application" "$reason" > "$run/result.json"
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
candidate_total="$(printf '%s' "$candidate_list" | sed -n 's/.*"profile_strategy_count":\([0-9][0-9]*\).*/\1/p')"
candidate_unique="$(printf '%s' "$candidate_list" | sed -n 's/.*"candidate_count":\([0-9][0-9]*\).*/\1/p')"
candidate_set_version="$(printf '%s' "$candidate_list" | sed -n 's/.*"candidate_set_version":"\([^"]*\)".*/\1/p')"
candidate_numbers_json="$(printf '%s' "$candidate_list" | sed -n 's/.*"candidate_numbers":\[\([^]]*\)\].*/\1/p')"
[[ "$candidate_unique" =~ ^[0-9]+$ && "$candidate_unique" -lt "$candidate_total" && "$candidate_set_version" =~ ^sha256:[a-f0-9]{64}$ && ",${candidate_numbers_json}," != *,45,* ]] || {
  echo "ranked candidates did not remove the duplicate semantic strategy: $candidate_list" >&2; exit 1;
}
exploration_candidates="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=mark%3A4&order=exploration&offset=0&limit=3')"
[[ "$exploration_candidates" == *'"candidate_count":45'* && "$exploration_candidates" == *'"candidate_set_version":"sha256:'* && "$exploration_candidates" == *'"candidate_numbers":[1,2,3]'* && "$exploration_candidates" == *'"source":"local-profile-order"'* ]] || {
  echo "exploration order is not stable numeric order: $exploration_candidates" >&2; exit 1;
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
other_scope_candidates="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=default')"
[[ "$other_scope_candidates" == *'"status":"ready"'* ]] || { echo "confirmed rule leaked across client scope: $other_scope_candidates" >&2; exit 1; }
rm -f "$Z2R_ADAPTIVE_DIR/rules.tsv"
printf '1\ttls\t3\n' > "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv"
locked_candidates="$(call_api 'action=candidates&hostname=cdn.example.org&destination_ip=93.184.216.34&profile_id=1&scope=default')"
[[ "$locked_candidates" == *'409 Conflict'* ]] || { echo "candidate scheduler ignored a profile lock: $locked_candidates" >&2; exit 1; }
rm -f "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv"
expired_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$Z2R_ADAPTIVE_DIR/$expired_id/leases" "$Z2R_ADAPTIVE_DIR/legacy"
printf 'complete\n' > "$Z2R_ADAPTIVE_DIR/$expired_id/state"
printf '%s\t192.168.1.44\t62000\t93.184.216.34\t443\t%s\ttls-http1-v1\n' "$expired_id" "$(( $(date +%s) - 700 ))" > "$Z2R_ADAPTIVE_DIR/$expired_id/leases/$expired_id.tsv"
lease_response="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&source_port=62017')"
[[ "$lease_response" == *'Content-Type: application/json'* && "$lease_response" == *'Status: 200 OK'* ]] || {
  echo "lease response is missing CGI headers: $lease_response" >&2; exit 1;
}
lease_json="${lease_response#*$'\r\n\r\n'}"
id="$(printf '%s' "$lease_json" | sed -n 's/.*"test_id":"\([a-f0-9]*\)".*/\1/p')"
[[ "$id" =~ ^[a-f0-9]{32}$ && "$lease_json" == *'"source_port":62017'* ]] || { echo "lease failed to honor the available client port: $lease_response" >&2; exit 1; }
bad_source_port="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&source_port=63000')"
[[ "$bad_source_port" == *'400 Bad Request'* ]] || { echo 'lease accepted an out-of-range client source port' >&2; exit 1; }
[[ ! -e "$Z2R_ADAPTIVE_DIR/$expired_id" && -d "$Z2R_ADAPTIVE_DIR/legacy" ]] || { echo 'GC removed the wrong run directory' >&2; exit 1; }
body="action=complete&test_id=$id&schema_version=1&route_verified=false&overall=INCONCLUSIVE&ip_family=ipv4&protocol=tcp&port=443&observed_at=$(date +%s)&transport=OK&application=OK&reason=probe_ok&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&scope=default&strategy_fingerprint=sha256%3Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&local_strategy_number=1&catalog_version=sha256%3Abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&recipe_id=tls-http1-v1&client_profile=curl-windows-v1"
complete="$(call_api "$body")"
[[ "$complete" == *'"overall":"SUCCESS"'* ]] || { echo "completion failed: $complete" >&2; exit 1; }
scoped_lease_response="$(call_api 'action=lease&hostname=example.com&destination_ip=93.184.216.34&profile_id=1&local_strategy_number=1&scope=mark%3A4')"
scoped_lease_json="${scoped_lease_response#*$'\r\n\r\n'}"
scoped_id="$(printf '%s' "$scoped_lease_json" | sed -n 's/.*"test_id":"\([a-f0-9]*\)".*/\1/p')"
[[ "$scoped_id" =~ ^[a-f0-9]{32}$ && "$scoped_lease_json" == *'"scope":"mark:4"'* ]] || {
  echo "scoped lease lost the client scope: $scoped_lease_response" >&2; exit 1;
}
scoped_body="${body/test_id=$id/test_id=$scoped_id}"
scoped_body="${scoped_body/scope=default/scope=mark%3A4}"
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
printf '1\tsuspected_failure\tcdn.example.org\t93.184.216.34\t2\ttls\tmark:4\t%s\n1\tseen\tbad host\t192.168.1.1\t1\ttls\tdefault\t%s\n' "$now" "$now" > "$Z2R_ADAPTIVE_DIR/events.tsv"
events="$(call_api 'action=events')"
[[ "$events" == *'Content-Type: application/json'* && "$events" == *'"status":"suspected_failure"'* && "$events" == *'"hostname":"cdn.example.org"'* && "$events" == *'"profile_id":2'* && "$events" == *'"scope":"mark:4"'* && "$events" != *'bad host'* ]] || {
  echo "events API returned invalid observation data: $events" >&2; exit 1;
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
