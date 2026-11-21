#!/usr/bin/env bash
# One TCP/UDP 443 probe lease. The caller validates application behavior;
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
probe_owner="${10:-}"
recipe="${11:-tls-http1-v1}"
treatment="${12:-standard}"
case "$id" in ''|*[!A-Za-z0-9_-]*) exit 2 ;; esac
[[ -d "$BASE" && ! -L "$BASE" ]] || exit 2
[[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || exit 2
[[ "$host" == *.* && ${#host} -le 253 ]] || exit 2
[[ "$profile" =~ ^[1-5]$ && "$strategy" =~ ^(0|[1-9][0-9]{0,2})$ ]] || exit 2
[[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || exit 2
if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || exit 2; fi
[[ -z "$probe_owner" || "$probe_owner" =~ ^[a-f0-9]{32}$ ]] || exit 2
case "$recipe" in
  tls-http1-v1) [[ "$treatment" = standard ]] || exit 2 ;;
  googlevideo-tcp-media-v1)
    [[ "$profile" = 2 && "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+googlevideo\.com$ ]] || exit 2
    case "$treatment" in standard|gv_tcp_plain|gv_tcp_ramp|gv_tcp_ramp_syndata) ;; *) exit 2 ;; esac ;;
  googlevideo-quic-h3-media-v1)
    [[ "$profile" = 5 && "$treatment" = standard && "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+googlevideo\.com$ ]] || exit 2 ;;
  *) exit 2 ;;
esac
client_profile=curl-windows-v1
[[ "$recipe" != googlevideo-tcp-media-v1 ]] || client_profile=curl-windows-media-v1
[[ "$recipe" != googlevideo-quic-h3-media-v1 ]] || client_profile=curl-windows-quic-media-v1
probe_proto=tcp
[[ "$recipe" != googlevideo-quic-h3-media-v1 ]] || probe_proto=udp
expected_recipe="$recipe" expected_client_profile="$client_profile"

adaptive_controller_no_result_reason() {
  local cancelled="$1" reconcile_failed="$2" worker_alive="$3" lease_expired="$4"
  [[ "$cancelled" =~ ^[01]$ && "$reconcile_failed" =~ ^[01]$ &&
     "$worker_alive" =~ ^[01]$ && "$lease_expired" =~ ^[01]$ ]] || return 2
  if [[ "$cancelled" = 1 ]]; then
    printf 'cancelled\n'
  elif [[ "$reconcile_failed" = 1 ]]; then
    printf 'route_unverified\n'
  elif [[ "$worker_alive" != 1 ]]; then
    printf 'probe_error\n'
  elif [[ "$lease_expired" = 1 ]]; then
    printf 'expired\n'
  else
    printf 'transport_timeout\n'
  fi
}

adaptive_controller_save_status() {
  [[ $# = 17 ]] || return 2
  local run="$1" completed="$2" observed="$3" overall="$4" reason="$5" recipe="$6" treatment="$7"
  local profile="$8" scope="$9" strategy="${10}" route="${11}" queue="${12}" ack="${13}"
  local bytes="${14}" speed="${15}" media_ms="${16}" duration="${17}" tmp
  [[ -d "$run" && ! -L "$run" && "$completed" =~ ^[0-9]{1,10}$ && "$observed" =~ ^[0-9]{1,10}$ &&
     "$overall" =~ ^(SUCCESS|FAIL|INCONCLUSIVE)$ && "$reason" =~ ^(probe_ok|http_rejected|rate_limited|server_busy|response_too_large|empty_response|timeout|transport_timeout|origin_unavailable|signed_url_expired|media_insufficient|media_ok|quic_unavailable|target_unavailable|route_unverified|probe_error|cancelled|expired|strategy_unconfirmed|ramp_stage_unconfirmed|invalid_result)$ &&
     "$profile" =~ ^[1-5]$ && ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) &&
     "$strategy" =~ ^(0|[1-9][0-9]{0,2})$ && ( "$route" = true || "$route" = false ) &&
     ( "$queue" = true || "$queue" = false ) && ( "$ack" = true || "$ack" = false ) &&
     "$bytes" =~ ^[0-9]{1,8}$ && "$bytes" -le 16777216 && "$speed" =~ ^[0-9]{1,10}$ && "$speed" -le 1073741824 &&
     "$media_ms" =~ ^[0-9]{1,8}$ && "$media_ms" -le 60000 && "$duration" =~ ^[0-9]{1,6}$ ]] || return 2
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 2; fi
  case "$recipe:$profile:$treatment" in
    tls-http1-v1:[1-4]:standard|googlevideo-tcp-media-v1:2:standard|googlevideo-tcp-media-v1:2:gv_tcp_plain|googlevideo-tcp-media-v1:2:gv_tcp_ramp|googlevideo-tcp-media-v1:2:gv_tcp_ramp_syndata|googlevideo-quic-h3-media-v1:5:standard) ;;
    *) return 2 ;;
  esac
  tmp="$run/status.tsv.tmp.$$"
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$completed" "$observed" "$overall" "$reason" "$recipe" "$treatment" "$profile" "$scope" "$strategy" \
    "$route" "$queue" "$ack" "$bytes" "$speed" "$media_ms" "$duration" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$run/status.tsv" || {
      rm -f "$tmp"
      return 1
    }
}

adaptive_ramp_control_exemptions() {
  [[ "$treatment" = gv_tcp_ramp || "$treatment" = gv_tcp_ramp_syndata ]] || return 0
  local source="${Z2R_ADAPTIVE_RAMP_EXEMPT_FILE:-$BASE/ramp-exempt.tsv}" now tmp matched
  [[ -r "$source" && ! -L "$source" ]] || return 0
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || return 1
  tmp="$run/probe/ramp-exempt-control.tsv"
  matched="$(awk -F '\t' -v host="${host,,}" -v ip="$dst_ip" -v scope="$scope" -v now="$now" \
    '$1==1 && $2==host && $3==ip && $4==scope && $5 ~ /^[0-9]+$/ && ($5+0)>now { found=1 } END { print found+0 }' "$source")" || return 1
  [[ "$matched" = 1 ]] || return 0
  awk -F '\t' -v host="${host,,}" -v ip="$dst_ip" -v scope="$scope" -v now="$now" \
    '!( $1==1 && $2==host && $3==ip && $4==scope && $5 ~ /^[0-9]+$/ && ($5+0)>now )' "$source" > "$tmp" || return 1
  chmod 644 "$tmp" || return 1
  Z2R_ADAPTIVE_RAMP_EXEMPT_FILE="$tmp"
  export Z2R_ADAPTIVE_RAMP_EXEMPT_FILE
}

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
if [[ "$recipe" = googlevideo-tcp-media-v1 || "$recipe" = googlevideo-quic-h3-media-v1 ]]; then
  [[ -r "$LIB/youtube_media.sh" && -r "$LIB/adaptive_media.sh" ]] || { printf 'media_resolver_unavailable\n' > "$run/error"; exit 1; }
  . "$LIB/youtube_media.sh"
  . "$LIB/adaptive_media.sh"
fi

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
  rm -rf "$run/media" 2>/dev/null || :
  rm -f "$run/lease.json" 2>/dev/null || :
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
mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)"
[[ "$mode" = TEST_ONLY || "$mode" = AGENT_BETA ]] || {
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

supersweep_probe_config "$profile" "$CONFIG_FILE" "$treatment" "$dst_ip" "$recipe" || { printf 'probe_config_failed\n' > "$run/error"; exit 1; }
chmod 755 "$run/probe" || { printf 'probe_config_failed\n' > "$run/error"; exit 1; }
locked_proto=tls
[[ "$recipe" != googlevideo-quic-h3-media-v1 ]] || locked_proto=udp
printf '%s\t%s\t%s\n' "${host,,}" "$locked_proto" "$strategy" > "$run/probe/locked.tsv"
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
  if [[ "$treatment" = standard ]]; then
    fingerprint="sha256:$(printf 'direct\nprofile=%s\nnfqws=%s\n' "$profile" "$nfqws_version" | sha256sum | awk '{print $1}')"
  else
    fingerprint="sha256:$(printf 'direct\nprofile=%s\nnfqws=%s\ntreatment=%s\n' "$profile" "$nfqws_version" "$treatment" | sha256sum | awk '{print $1}')"
  fi
else
  fingerprint="$(adaptive_strategy_fingerprint "$profile" "$strategy" "$run/probe/nfqws2.args" "$nfqws" "$treatment" "$recipe")" || {
    printf 'fingerprint_failed\n' > "$run/error"; exit 1;
  }
fi
catalog_version="sha256:$(sha256sum "$run/probe/nfqws2.args" | awk '{print $1}')"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${host,,}" "$dst_ip" "$profile" "$fingerprint" "$strategy" "$catalog_version" "$scope" "$treatment" > "$run/target.tsv"
printf '%s\n' "$treatment" > "$run/treatment"

# Build argv directly; @file behavior differs between supported nfqws2 builds.
declare -a args=()
while IFS= read -r line; do [[ -z "$line" ]] || args+=("$line"); done < "$run/probe/nfqws2.args"
[[ ${#args[@]} -gt 0 ]] || { printf 'probe_args_empty\n' > "$run/error"; exit 1; }
# Acquire the shared probe slot before resolving media so concurrent ramp
# audits cannot race the short-lived, exact-target signed-URL cache.
adaptive_lan_probe_lock_acquire || { printf 'probe_busy\n' > "$run/error"; exit 1; }
Z2R_ADAPTIVE_LOCK_HELD=1
media_url="" media_mime="" media_length=0 media_expires=0 media_url_sha256="" media_json=""
if [[ "$recipe" = googlevideo-tcp-media-v1 || "$recipe" = googlevideo-quic-h3-media-v1 ]]; then
  media_dir="$run/media"
  mkdir -m 700 "$media_dir" || { printf 'media_prepare_failed\n' > "$run/error"; exit 1; }
  video_id="${Z2R_MEDIA_VIDEO_ID:-$Z2R_MEDIA_DEFAULT_VIDEO_ID}"
  if [[ "$recipe" = googlevideo-tcp-media-v1 && ( "$treatment" = gv_tcp_plain || "$treatment" = gv_tcp_ramp || "$treatment" = gv_tcp_ramp_syndata ) ]]; then
    media_url_sha256="$(adaptive_media_prepare_ramp_cache "$BASE/ramp-media-cache" "${host,,}" "$dst_ip" "$video_id" "$media_dir" "$(date +%s)")" || {
      printf 'media_cache_or_origin_unavailable\n' > "$run/error"; exit 1;
    }
    media_url="$(adaptive_media_url_from_cache "$media_dir" video "${host,,}")" || {
      printf 'media_target_mismatch\n' > "$run/error"; exit 1;
    }
  elif ! z2r_media_resolve "$video_id" "$media_dir"; then
    printf 'media_origin_unavailable\n' > "$run/error"; exit 1
  fi
  media_url="$(adaptive_media_url_from_cache "$media_dir" video "${host,,}")" || {
    printf 'media_target_mismatch\n' > "$run/error"; exit 1;
  }
  IFS='|' read -r media_length media_mime media_host media_expires < "$media_dir/video.params" || {
    printf 'media_metadata_invalid\n' > "$run/error"; exit 1;
  }
  [[ "$media_length" =~ ^[1-9][0-9]{0,14}$ && "$media_mime" =~ ^video/(mp4|webm)$ &&
     "$media_host" = "${host,,}" && "$media_expires" =~ ^[1-9][0-9]{0,11}$ ]] || {
    printf 'media_metadata_invalid\n' > "$run/error"; exit 1;
  }
  media_json=",\"media\":{\"url\":\"$media_url\",\"mime_type\":\"$media_mime\",\"content_length\":$media_length,\"expires\":$media_expires}"
  [[ -n "$media_url_sha256" ]] || media_url_sha256="$(printf '%s' "$media_url" | sha256sum | awk '{print $1}')"
  [[ "$media_url_sha256" =~ ^[a-f0-9]{64}$ ]] || { printf 'media_fingerprint_failed\n' > "$run/error"; exit 1; }
fi
Z2R_ADAPTIVE_ACK_PATH="$run/probe/applied.tsv"
Z2R_ADAPTIVE_ACK_HOST="${host,,}"
Z2R_ADAPTIVE_ACK_PROFILE="$profile"
Z2R_ADAPTIVE_ACK_STRATEGY="$strategy"
Z2R_ADAPTIVE_TEST_ID="$id"
: > "$Z2R_ADAPTIVE_ACK_PATH"
chmod 666 "$Z2R_ADAPTIVE_ACK_PATH"
export Z2R_ADAPTIVE_ACK_PATH Z2R_ADAPTIVE_ACK_HOST Z2R_ADAPTIVE_ACK_PROFILE Z2R_ADAPTIVE_ACK_STRATEGY Z2R_ADAPTIVE_TEST_ID
if [[ "$treatment" = gv_tcp_ramp || "$treatment" = gv_tcp_ramp_syndata ]]; then
  Z2R_ADAPTIVE_RAMP_AUDIT_PATH="$run/probe/ramp-audit.tsv"
  printf '1\t0\t0\n' > "$Z2R_ADAPTIVE_RAMP_AUDIT_PATH"
  chmod 666 "$Z2R_ADAPTIVE_RAMP_AUDIT_PATH"
  export Z2R_ADAPTIVE_RAMP_AUDIT_PATH
  adaptive_ramp_control_exemptions || { printf 'ramp_control_policy_failed\n' > "$run/error"; exit 1; }
fi
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
adaptive_lan_lease_write "$run/leases" "$id" "$src_ip" "$src_port" "$dst_ip" "$expires" "$now" "$recipe" "$probe_owner" || {
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
lease_protocol=tcp
[[ "$recipe" != googlevideo-quic-h3-media-v1 ]] || lease_protocol=udp
printf '{"schema_version":1,"test_id":"%s","hostname":"%s","source_ip":"%s","source_port":%s,"destination_ip":"%s","port":443,"protocol":"%s","expires":%s,"recipe_id":"%s","treatment_variant":"%s","profile_id":%s,"scope":"%s","local_strategy_number":%s,"strategy_fingerprint":"%s","catalog_version":"%s"%s}\n' \
  "$id" "${host,,}" "$src_ip" "$src_port" "$dst_ip" "$lease_protocol" "$expires" "$recipe" "$treatment" "$profile" "$scope" "$strategy" "$fingerprint" "$catalog_version" "$media_json" > "$run/lease.json.tmp"
mv -f "$run/lease.json.tmp" "$run/lease.json"
printf 'leased\n' > "$run/state"

cancelled=0
reconcile_failed=0
lease_expired=0
controller_started_at="$(date +%s)"
for ((i=0; i<35; i++)); do
  if [[ -e "$run/cancel" ]]; then cancelled=1; break; fi
  mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)"
  [[ "$mode" = TEST_ONLY || "$mode" = AGENT_BETA ]] || { cancelled=1; break; }
  [[ -s "$Z2R_ADAPTIVE_RESULT_FILE" ]] && break
  kill -0 "$Z2R_ADAPTIVE_NFQWS2_PID" 2>/dev/null || break
  if (( $(date +%s) >= expires )); then lease_expired=1; break; fi
  if ! adaptive_lan_transport_reconcile; then
    sleep 1
    adaptive_lan_transport_reconcile || {
      sleep 1
      adaptive_lan_transport_reconcile || { reconcile_failed=1; break; }
    }
  fi
  sleep 1
done

overall=INCONCLUSIVE final_reason=probe_error route_verified=false queue_seen=false strategy_ack_seen=false
syn_stage_confirmed=false late_ack_stage_confirmed=false media_bytes=0 media_speed_bps=0 media_duration_ms=0
observed="$(date +%s)"
if [[ "$cancelled" = 1 || ! -s "$Z2R_ADAPTIVE_RESULT_FILE" ]]; then
  worker_alive=0
  kill -0 "$Z2R_ADAPTIVE_NFQWS2_PID" 2>/dev/null && worker_alive=1
  timeout_reason="$(adaptive_controller_no_result_reason "$cancelled" "$reconcile_failed" "$worker_alive" "$lease_expired")" || timeout_reason=probe_error
  final_reason="$timeout_reason"
  printf '{"schema_version":1,"test_id":"%s","route_verified":false,"queue_seen":false,"strategy_ack_seen":false,"syn_stage_confirmed":false,"late_ack_stage_confirmed":false,"transport":"UNKNOWN","application":"UNKNOWN","overall":"INCONCLUSIVE","reason":"%s","observed_at":%s,"target":{"hostname":"%s","destination_ip":"%s","ip_family":"ipv4","protocol":"%s","port":443,"profile_id":%s,"scope":"%s"},"strategy":{"fingerprint":"%s","local_number":%s,"catalog_version":"%s"},"recipe_id":"%s","treatment_variant":"%s","client_profile":"%s","media_url_sha256":"","media_bytes":0,"media_speed_bps":0,"media_duration_ms":0}\n' \
    "$id" "$timeout_reason" "$(date +%s)" "${host,,}" "$dst_ip" "$probe_proto" "$profile" "$scope" "$fingerprint" "$strategy" "$catalog_version" "$recipe" "$treatment" "$client_profile" > "$run/result.json.tmp"
else
  media_bytes=0 media_speed_bps=0 media_duration_ms=0
  IFS=$'\t' read -r result_schema result_id observed transport application reason result_host result_dst result_profile result_fingerprint result_strategy result_catalog result_recipe result_treatment result_client_profile result_scope media_bytes media_speed_bps media_duration_ms < "$Z2R_ADAPTIVE_RESULT_FILE" || true
  case "$transport" in OK|FAIL|UNKNOWN) ;; *) transport=UNKNOWN; application=UNKNOWN; reason=invalid_result ;; esac
  case "$application" in OK|FAIL|NOT_TESTED|UNKNOWN) ;; *) transport=UNKNOWN; application=UNKNOWN; reason=invalid_result ;; esac
  case "$reason" in probe_ok|http_rejected|rate_limited|server_busy|response_too_large|empty_response|timeout|transport_timeout|origin_unavailable|signed_url_expired|media_insufficient|media_ok|quic_unavailable|target_unavailable|route_unverified|probe_error|cancelled|expired) ;; *) reason=invalid_result ;; esac
  [[ "$media_bytes" =~ ^[0-9]{1,8}$ && "$media_bytes" -le 16777216 ]] || media_bytes=0
  [[ "$media_speed_bps" =~ ^[0-9]{1,10}$ && "$media_speed_bps" -le 1073741824 ]] || media_speed_bps=0
  [[ "$media_duration_ms" =~ ^[0-9]{1,8}$ && "$media_duration_ms" -le 60000 ]] || media_duration_ms=0
  if [[ ! "$observed" =~ ^[0-9]{1,10}$ || "$result_schema" != 1 || "$result_id" != "$id" || "$result_host" != "${host,,}" || "$result_dst" != "$dst_ip" || "$result_profile" != "$profile" || "$result_fingerprint" != "$fingerprint" || "$result_strategy" != "$strategy" || "$result_catalog" != "$catalog_version" || "$result_recipe" != "$expected_recipe" || "$result_treatment" != "$treatment" || "$result_client_profile" != "$expected_client_profile" || "$result_scope" != "$scope" ]]; then
    transport=UNKNOWN; application=UNKNOWN; reason=invalid_result
  fi
  recipe="$expected_recipe" client_profile="$expected_client_profile"
  seq_after="$(awk '$1==65535 {if(n++) exit 1; print $8}' "$queue_file" 2>/dev/null)"
  ack="$(cat "$Z2R_ADAPTIVE_ACK_PATH" 2>/dev/null)"
  adaptive_lan_transport_reconcile || reconcile_failed=1
  route_verified=false
  queue_seen=false
  strategy_ack_seen=false
  syn_stage_confirmed=false
  late_ack_stage_confirmed=false
  if [[ "$treatment" = gv_tcp_ramp || "$treatment" = gv_tcp_ramp_syndata ]]; then
    ramp_audit_version= ramp_syn= ramp_ack=
    IFS=$'\t' read -r ramp_audit_version ramp_syn ramp_ack < "$run/probe/ramp-audit.tsv" 2>/dev/null || :
    [[ "$ramp_audit_version" = 1 && "$ramp_syn" = 1 ]] && syn_stage_confirmed=true
    [[ "$ramp_audit_version" = 1 && "$ramp_ack" = 1 ]] && late_ack_stage_confirmed=true
  fi
  final_reason="$reason"
  if [[ "$reconcile_failed" = 1 ]]; then
    final_reason=route_unverified
    transport=UNKNOWN
    application=UNKNOWN
  elif [[ "$seq_after" =~ ^[0-9]+$ ]] && (( seq_after > seq_before )); then
    queue_seen=true
    if [[ "$ack" = "$id"$'\t'"${host,,}"$'\t'"$profile"$'\t'"$strategy" ]]; then
      route_verified=true
      strategy_ack_seen=true
    else
      final_reason=strategy_unconfirmed
    fi
  else
    final_reason=route_unverified
  fi
  if [[ "$treatment" = gv_tcp_ramp || "$treatment" = gv_tcp_ramp_syndata ]] &&
     [[ "$syn_stage_confirmed" != true || "$late_ack_stage_confirmed" != true ]]; then
    route_verified=false
    final_reason=ramp_stage_unconfirmed
  fi
  mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)"
  if [[ "$mode" != TEST_ONLY && "$mode" != AGENT_BETA ]]; then
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
if [[ "$treatment" = standard && ( "$recipe" = tls-http1-v1 || "$recipe" = googlevideo-tcp-media-v1 ) &&
      ( "$overall" = SUCCESS || ( "$overall" = FAIL && "$route_verified" = true ) ) ]]; then
    runtime_stamp="$(adaptive_rules_runtime_stamp "$CONFIG_FILE" "$nfqws" "$ORCH_DIR")"
  rule_proto=tls
  [[ "$recipe" != googlevideo-tcp-media-v1 ]] || rule_proto=googlevideo-tcp
  if [[ "$overall" = SUCCESS ]]; then
    adaptive_rule_add "${host,,}" "$dst_ip" "$profile" "$rule_proto" "$scope" "$strategy" \
      "$fingerprint" "$catalog_version" "$runtime_stamp" "$((observed + 900))" || \
      printf 'adaptive controller: verified result could not be stored as a runtime rule\n' >&2
  else
    adaptive_rule_remove_if_matches "${host,,}" "$dst_ip" "$profile" "$rule_proto" "$scope" "$strategy" "$fingerprint" "$runtime_stamp" || :
  fi
fi
  printf '{"schema_version":1,"test_id":"%s","route_verified":%s,"queue_seen":%s,"strategy_ack_seen":%s,"syn_stage_confirmed":%s,"late_ack_stage_confirmed":%s,"transport":"%s","application":"%s","overall":"%s","reason":"%s","observed_at":%s,"target":{"hostname":"%s","destination_ip":"%s","ip_family":"ipv4","protocol":"%s","port":443,"profile_id":%s,"scope":"%s"},"strategy":{"fingerprint":"%s","local_number":%s,"catalog_version":"%s"},"recipe_id":"%s","treatment_variant":"%s","client_profile":"%s","media_url_sha256":"%s","media_bytes":%s,"media_speed_bps":%s,"media_duration_ms":%s}\n' \
    "$id" "$route_verified" "$queue_seen" "$strategy_ack_seen" "$syn_stage_confirmed" "$late_ack_stage_confirmed" "$transport" "$application" "$overall" "$final_reason" "${observed:-0}" "${host,,}" "$dst_ip" "$probe_proto" "$profile" "$scope" "$fingerprint" "$strategy" "$catalog_version" "$recipe" "$treatment" "$client_profile" "$media_url_sha256" "$media_bytes" "$media_speed_bps" "$media_duration_ms" > "$run/result.json.tmp"
fi
mv -f "$run/result.json.tmp" "$run/result.json"
controller_finished_at="$(date +%s)"
controller_duration_seconds=$((controller_finished_at - controller_started_at))
[[ "$controller_duration_seconds" =~ ^[0-9]{1,6}$ ]] || controller_duration_seconds=0
status_tmp="$run/status.tsv.tmp"
if adaptive_controller_save_status "$run" "$controller_finished_at" "$observed" "$overall" "$final_reason" "$recipe" \
  "$treatment" "$profile" "$scope" "$strategy" "$route_verified" "$queue_seen" "$strategy_ack_seen" \
  "$media_bytes" "$media_speed_bps" "$media_duration_ms" "$controller_duration_seconds"; then
  :
else
  rm -f "$status_tmp" "$run/status.tsv.tmp."*
  printf 'adaptive controller: last-result summary could not be saved\n' >&2
fi
printf 'complete\n' > "$run/state"
