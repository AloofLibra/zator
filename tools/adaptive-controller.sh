#!/usr/bin/env bash
# One TCP/443 probe lease. The caller validates HTTP and LAN authentication;
# this worker owns NFQUEUE 65535, the private nfqws2, and exact-tuple firewall rules.
set -u

ROOT="${ZATOR_ROOT:-/opt/zator}"
ZA_ROOT="${ZAPRET2_ROOT:-/opt/zapret2}"
export ZATOR_ROOT="$ROOT" ZAPRET2_ROOT="$ZA_ROOT"
BASE="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}"
ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
CONFIG_FILE="$ZA_ROOT/config"
LIB="$ROOT/z2r_lib"

id="${1:-}" src_ip="${2:-}" src_port="${3:-}" host="${4:-}"
dst_ip="${5:-}" profile="${6:-}" strategy="${7:-}" expires="${8:-}" scope="${9:-default}"
case "$id" in ''|*[!A-Za-z0-9_-]*) exit 2 ;; esac
[[ -d "$BASE" && ! -L "$BASE" ]] || exit 2
[[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || exit 2
[[ "$host" == *.* && ${#host} -le 253 ]] || exit 2
[[ "$profile" =~ ^[1-4]$ && "$strategy" =~ ^(0|[1-9][0-9]{0,2})$ ]] || exit 2
[[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || exit 2
if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || exit 2; fi
run="$BASE/$id"
[[ -d "$run" && ! -L "$run" ]] || exit 2
umask 077
# nfqws2 drops to UID 65533; keep run data private but let that UID traverse
# the random test-id directory and read only the generated private Lua files.
chmod 711 "$BASE" || { printf 'probe_config_failed\n' > "$run/error"; exit 1; }

. "$LIB/config.sh"
. "$LIB/orchestra_state.sh"
. "$LIB/supersweep_transport.sh"
. "$LIB/supersweep_probe.sh"
. "$LIB/adaptive_lan_transport.sh"
. "$LIB/adaptive_rules.sh"

Z2R_SUPERSWEEP_DIR="$run"
Z2R_ADAPTIVE_LOCK_DIR="${Z2R_ADAPTIVE_LOCK_DIR:-/tmp/z2r-supersweep.lock}"
Z2R_ADAPTIVE_NFQWS2_PID=""
Z2R_ADAPTIVE_TRANSPORT_ACTIVE=0
Z2R_ADAPTIVE_LOCK_HELD=0
Z2R_ADAPTIVE_RESULT_FILE="$run/complete.tsv"
export Z2R_SUPERSWEEP_DIR Z2R_ADAPTIVE_LOCK_DIR

FWTYPE="$(config_get_var "$CONFIG_FILE" FWTYPE 2>/dev/null | tr -d '"\047')"
DESYNC_MARK="$(config_get_var "$CONFIG_FILE" DESYNC_MARK 2>/dev/null | tr -d '"\047')"
DESYNC_MARK_POSTNAT="$(config_get_var "$CONFIG_FILE" DESYNC_MARK_POSTNAT 2>/dev/null | tr -d '"\047')"
POSTNAT="$(config_get_var "$CONFIG_FILE" POSTNAT 2>/dev/null | tr -d '"\047')"
POSTNAT_ALL="$(config_get_var "$CONFIG_FILE" POSTNAT_ALL 2>/dev/null | tr -d '"\047')"
ZAPRET_NFT_TABLE="$(config_get_var "$CONFIG_FILE" ZAPRET_NFT_TABLE 2>/dev/null | tr -d '"\047')"
FILTER_MARK="$(config_get_var "$CONFIG_FILE" FILTER_MARK 2>/dev/null | tr -d '"\047')"
CLIENT_SCOPE_MARK_MASK="$(config_get_var "$CONFIG_FILE" CLIENT_SCOPE_MARK_MASK 2>/dev/null | tr -d '"\047')"
NFQWS2_ENABLE="$(config_get_var "$CONFIG_FILE" NFQWS2_ENABLE 2>/dev/null | tr -d '"\047')"
export FWTYPE DESYNC_MARK DESYNC_MARK_POSTNAT POSTNAT POSTNAT_ALL ZAPRET_NFT_TABLE FILTER_MARK CLIENT_SCOPE_MARK_MASK

nfqws="$ZA_ROOT/nfq2/nfqws2"
cleanup() {
  local rc=$? n=0
  trap - EXIT INT TERM HUP
  if [[ "$Z2R_ADAPTIVE_TRANSPORT_ACTIVE" = 1 ]]; then
    until adaptive_lan_transport_stop; do
      n=$((n + 1))
      if (( n >= 5 )); then
        printf 'cleanup_failed\n' > "$run/state"
        printf 'adaptive controller: firewall cleanup failed; probe PID %s and shared lock retained\n' "$Z2R_ADAPTIVE_NFQWS2_PID" >&2
        exit 1
      fi
      sleep 1
    done
    Z2R_ADAPTIVE_TRANSPORT_ACTIVE=0
  fi
  if [[ -n "$Z2R_ADAPTIVE_NFQWS2_PID" ]]; then
    kill "$Z2R_ADAPTIVE_NFQWS2_PID" 2>/dev/null || true
    wait "$Z2R_ADAPTIVE_NFQWS2_PID" 2>/dev/null || true
    Z2R_ADAPTIVE_NFQWS2_PID=""
  fi
  # Keep the shared Supersweep/probe mutex until this controller's queue owner
  # has exited. Otherwise another probe can acquire the lock while queue 65535
  # is still registered to the old nfqws2 process.
  if [[ "$Z2R_ADAPTIVE_LOCK_HELD" = 1 ]]; then
    adaptive_lan_probe_lock_release || true
    Z2R_ADAPTIVE_LOCK_HELD=0
  fi
  if [[ "$rc" = 0 && -s "$run/result.json.pending" ]]; then
    mv -f "$run/result.json.pending" "$run/result.json" || rc=1
    [[ "$rc" != 0 ]] || printf 'complete\n' > "$run/state"
  fi
  [[ "$rc" = 0 ]] || printf 'failed\n' > "$run/state"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

[[ "$NFQWS2_ENABLE" = 1 && -x "$nfqws" ]] || { printf 'unavailable\n' > "$run/error"; exit 1; }
[[ "$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)" = TEST_ONLY ]] || {
  printf 'probe_mode_off\n' > "$run/error"; exit 1;
}
now="$(date +%s)"
adaptive_lan_lease_valid "$src_ip" "$src_port" "$dst_ip" 443 "$expires" "$now" || {
  printf 'lease_invalid\n' > "$run/error"; exit 1;
}
_adaptive_lan_public_ipv4_valid "$dst_ip" || { printf 'target_not_public_ipv4\n' > "$run/error"; exit 1; }
queue_file="${Z2R_ADAPTIVE_QUEUE_FILE:-/proc/net/netfilter/nfnetlink_queue}"
[[ -r "$queue_file" ]] && ! awk '$1==65535 {found=1} END {exit !found}' "$queue_file" || {
  printf 'queue_busy\n' > "$run/error"; exit 1;
}
max="$(config_profile_max_strategy "$profile" "$CONFIG_FILE")"
[[ "$max" =~ ^[0-9]+$ ]] && { (( strategy == 0 || strategy <= max )); } || { printf 'strategy_unavailable\n' > "$run/error"; exit 1; }
[[ ! -e /etc/passwd ]] || ! awk -F: '$3==65533 {found=1} END {exit !found}' /etc/passwd || {
  printf 'probe_uid_in_use\n' > "$run/error"; exit 1;
}
for status in /proc/[0-9]*/status; do
  [[ -r "$status" ]] || continue
  while read -r key uid rest; do
    [[ "$key" = Uid: ]] || continue
    [[ "$uid" != 65533 ]] || { printf 'probe_uid_in_use\n' > "$run/error"; exit 1; }
    break
  done < "$status" 2>/dev/null || true
done

supersweep_probe_config "$profile" "$CONFIG_FILE" || { printf 'probe_config_failed\n' > "$run/error"; exit 1; }
chmod 755 "$run/probe" || { printf 'probe_config_failed\n' > "$run/error"; exit 1; }
printf '%s\ttls\t%s\n' "${host,,}" "$strategy" > "$run/probe/locked.tsv"
chmod 644 "$run/probe/locked.tsv" || { printf 'probe_config_failed\n' > "$run/error"; exit 1; }
chmod 644 "$run/probe/locked.lua" || { printf 'probe_config_failed\n' > "$run/error"; exit 1; }
chmod 711 "$run" || { printf 'probe_config_failed\n' > "$run/error"; exit 1; }
printf '%s\t%s\n' "$host" "$dst_ip" > "$run/target.tsv"
if [[ "$strategy" = 0 ]]; then
  # DIRECT is a pass-through sentinel, not a numbered strategy in args_file.
  nfqws_version_output="$($nfqws --version 2>&1)" || {
    printf 'fingerprint_failed\n' > "$run/error"; exit 1;
  }
  nfqws_version="${nfqws_version_output%%$'\n'*}"
  fingerprint="sha256:$(printf 'direct\nprofile=%s\nnfqws=%s\n' "$profile" "$nfqws_version" | sha256sum | awk '{print $1}')"
else
  fingerprint="$(adaptive_strategy_fingerprint "$profile" "$strategy" "$run/probe/nfqws2.args" "$nfqws")" || {
    printf 'fingerprint_failed\n' > "$run/error"; exit 1;
  }
fi
catalog_version="sha256:$(sha256sum "$run/probe/nfqws2.args" | awk '{print $1}')"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${host,,}" "$dst_ip" "$profile" "$fingerprint" "$strategy" "$catalog_version" "$scope" > "$run/target.tsv"

# Build argv directly; @file behavior differs between supported nfqws2 builds.
declare -a args=()
while IFS= read -r line; do [[ -z "$line" ]] || args+=("$line"); done < "$run/probe/nfqws2.args"
[[ ${#args[@]} -gt 0 ]] || { printf 'probe_args_empty\n' > "$run/error"; exit 1; }
adaptive_lan_probe_lock_acquire || { printf 'probe_busy\n' > "$run/error"; exit 1; }
Z2R_ADAPTIVE_LOCK_HELD=1
Z2R_ADAPTIVE_ACK_PATH="$run/probe/applied.tsv"
Z2R_ADAPTIVE_ACK_HOST="${host,,}"
Z2R_ADAPTIVE_ACK_PROFILE="$profile"
Z2R_ADAPTIVE_ACK_STRATEGY="$strategy"
Z2R_ADAPTIVE_TEST_ID="$id"
: > "$Z2R_ADAPTIVE_ACK_PATH"
chmod 666 "$Z2R_ADAPTIVE_ACK_PATH"
export Z2R_ADAPTIVE_ACK_PATH Z2R_ADAPTIVE_ACK_HOST Z2R_ADAPTIVE_ACK_PROFILE Z2R_ADAPTIVE_ACK_STRATEGY Z2R_ADAPTIVE_TEST_ID
"$nfqws" "${args[@]}" > "$run/probe/nfqws2.log" 2>&1 </dev/null &
Z2R_ADAPTIVE_NFQWS2_PID=$!
export Z2R_ADAPTIVE_NFQWS2_PID

queue_file="${Z2R_ADAPTIVE_QUEUE_FILE:-/proc/net/netfilter/nfnetlink_queue}"
ready=0
for ((i=0; i<8; i++)); do
  kill -0 "$Z2R_ADAPTIVE_NFQWS2_PID" 2>/dev/null || break
  if awk '$1==65535 {n++} END {exit !(n==1)}' "$queue_file"; then ready=1; break; fi
  sleep 1
done
[[ "$ready" = 1 ]] || { printf 'queue_unavailable\n' > "$run/error"; exit 1; }
Z2R_ADAPTIVE_QUEUE_PID="$(awk '$1==65535 {print $2}' "$queue_file")"
[[ "$Z2R_ADAPTIVE_QUEUE_PID" = "$Z2R_ADAPTIVE_NFQWS2_PID" ]] || { printf 'queue_owner_mismatch\n' > "$run/error"; exit 1; }
now="$(date +%s)"
adaptive_lan_lease_write "$run/leases" "$id" "$src_ip" "$src_port" "$dst_ip" "$expires" "$now" tls-http1-v1 || {
  printf 'lease_invalid\n' > "$run/error"; exit 1;
}
seq_before="$(awk '$1==65535 {if(n++) exit 1; print $8}' "$queue_file")" || { printf 'queue_unavailable\n' > "$run/error"; exit 1; }
[[ "$seq_before" =~ ^[0-9]+$ ]] || { printf 'queue_unavailable\n' > "$run/error"; exit 1; }
if ! adaptive_lan_transport_start "$run/leases" "$id" "$now"; then
  printf 'transport_unavailable\n' > "$run/error"; exit 1
fi
Z2R_ADAPTIVE_TRANSPORT_ACTIVE=1
_adaptive_lan_write_transport_state "$run" "$id" "$_Z2R_ADAPTIVE_LAN_MARK" "$DESYNC_MARK" || {
  printf 'transport_state_failed\n' > "$run/error"
  exit 1
}
printf '{"schema_version":1,"test_id":"%s","hostname":"%s","source_ip":"%s","source_port":%s,"destination_ip":"%s","port":443,"expires":%s,"recipe_id":"tls-http1-v1","profile_id":%s,"scope":"%s","local_strategy_number":%s,"strategy_fingerprint":"%s","catalog_version":"%s"}\n' \
  "$id" "${host,,}" "$src_ip" "$src_port" "$dst_ip" "$expires" "$profile" "$scope" "$strategy" "$fingerprint" "$catalog_version" > "$run/lease.json.tmp"
mv -f "$run/lease.json.tmp" "$run/lease.json"
printf 'leased\n' > "$run/state"

cancelled=0
reconcile_failed=0
for ((i=0; i<35; i++)); do
  if [[ -e "$run/cancel" ]]; then cancelled=1; break; fi
  [[ "$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)" = TEST_ONLY ]] || { cancelled=1; break; }
  [[ -s "$Z2R_ADAPTIVE_RESULT_FILE" ]] && break
  kill -0 "$Z2R_ADAPTIVE_NFQWS2_PID" 2>/dev/null || break
  (( $(date +%s) < expires )) || break
  if ! adaptive_lan_transport_reconcile; then
    sleep 1
    adaptive_lan_transport_reconcile || {
      sleep 1
      adaptive_lan_transport_reconcile || { reconcile_failed=1; break; }
    }
  fi
  sleep 1
done

if [[ "$cancelled" = 1 || ! -s "$Z2R_ADAPTIVE_RESULT_FILE" ]]; then
  timeout_reason=expired
  [[ "$cancelled" = 1 ]] && timeout_reason=cancelled
  printf '{"schema_version":1,"test_id":"%s","route_verified":false,"transport":"UNKNOWN","application":"UNKNOWN","overall":"INCONCLUSIVE","reason":"%s","observed_at":%s,"target":{"hostname":"%s","destination_ip":"%s","ip_family":"ipv4","protocol":"tcp","port":443,"profile_id":%s,"scope":"%s"},"strategy":{"fingerprint":"%s","local_number":%s,"catalog_version":"%s"},"recipe_id":"tls-http1-v1","client_profile":"curl-windows-v1"}\n' \
    "$id" "$timeout_reason" "$(date +%s)" "${host,,}" "$dst_ip" "$profile" "$scope" "$fingerprint" "$strategy" "$catalog_version" > "$run/result.json.tmp"
else
  IFS=$'\t' read -r result_schema result_id observed transport application reason result_host result_dst result_profile result_fingerprint result_strategy result_catalog recipe client_profile result_scope < "$Z2R_ADAPTIVE_RESULT_FILE" || true
  case "$transport" in OK|FAIL|UNKNOWN) ;; *) transport=UNKNOWN; application=UNKNOWN; reason=invalid_result ;; esac
  case "$application" in OK|FAIL|NOT_TESTED|UNKNOWN) ;; *) transport=UNKNOWN; application=UNKNOWN; reason=invalid_result ;; esac
  case "$reason" in probe_ok|http_rejected|rate_limited|server_busy|response_too_large|empty_response|timeout|target_unavailable|route_unverified|probe_error|cancelled|expired) ;; *) reason=invalid_result ;; esac
  if [[ ! "$observed" =~ ^[0-9]{1,10}$ || "$result_schema" != 1 || "$result_id" != "$id" || "$result_host" != "${host,,}" || "$result_dst" != "$dst_ip" || "$result_profile" != "$profile" || "$result_fingerprint" != "$fingerprint" || "$result_strategy" != "$strategy" || "$result_catalog" != "$catalog_version" || "$recipe" != tls-http1-v1 || "$client_profile" != curl-windows-v1 || "$result_scope" != "$scope" ]]; then
    transport=UNKNOWN; application=UNKNOWN; reason=invalid_result
  fi
  seq_after="$(awk '$1==65535 {if(n++) exit 1; print $8}' "$queue_file" 2>/dev/null)"
  ack="$(cat "$Z2R_ADAPTIVE_ACK_PATH" 2>/dev/null)"
  adaptive_lan_transport_reconcile || reconcile_failed=1
  route_verified=false
  final_reason="$reason"
  if [[ "$reconcile_failed" = 1 ]]; then
    final_reason=route_unverified
    transport=UNKNOWN
    application=UNKNOWN
  elif [[ "$seq_after" =~ ^[0-9]+$ ]] && (( seq_after > seq_before )); then
    if [[ "$ack" = "$id"$'\t'"${host,,}"$'\t'"$profile"$'\t'"$strategy" ]]; then
      route_verified=true
    else
      final_reason=strategy_unconfirmed
    fi
  else
    final_reason=route_unverified
  fi
  if [[ "$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)" != TEST_ONLY ]]; then
    route_verified=false
    final_reason=cancelled
    transport=UNKNOWN
    application=UNKNOWN
  fi
  overall=INCONCLUSIVE
  if [[ "$route_verified" = true ]]; then
    if [[ "$transport" = OK && "$application" = OK ]]; then overall=SUCCESS
    elif [[ "$transport" = FAIL || "$application" = FAIL ]]; then overall=FAIL
    fi
  fi
  if [[ "$overall" = SUCCESS && "$strategy" -gt 0 ]]; then
    runtime_stamp="$(adaptive_rules_runtime_stamp "$CONFIG_FILE" "$nfqws" "$ORCH_DIR")"
    adaptive_rule_add "${host,,}" "$dst_ip" "$profile" tls "$scope" "$strategy" \
      "$fingerprint" "$catalog_version" "$runtime_stamp" "$((observed + 900))" \
      || printf 'adaptive controller: verified result could not be stored as a runtime rule\n' >&2
  fi
  printf '{"schema_version":1,"test_id":"%s","route_verified":%s,"transport":"%s","application":"%s","overall":"%s","reason":"%s","observed_at":%s,"target":{"hostname":"%s","destination_ip":"%s","ip_family":"ipv4","protocol":"tcp","port":443,"profile_id":%s,"scope":"%s"},"strategy":{"fingerprint":"%s","local_number":%s,"catalog_version":"%s"},"recipe_id":"tls-http1-v1","client_profile":"curl-windows-v1"}\n' \
    "$id" "$route_verified" "$transport" "$application" "$overall" "$final_reason" "${observed:-0}" "${host,,}" "$dst_ip" "$profile" "$scope" "$fingerprint" "$strategy" "$catalog_version" > "$run/result.json.tmp"
fi
mv -f "$run/result.json.tmp" "$run/result.json"
printf 'complete\n' > "$run/state"
