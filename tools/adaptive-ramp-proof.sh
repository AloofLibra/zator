#!/usr/bin/env bash
# Shared validation for proof-triggered Googlevideo Ramp-first activation.
adaptive_ramp_proof_validate() {
  local ids="$1" host="$2" ip="$3" scope="$4" now id json stage observed hash strategy bytes reason
  local first_hash="" first_strategy="" first_seen=0 last_seen=0 i
  local -a test_ids
  [[ "$ids" =~ ^[a-f0-9]{32},[a-f0-9]{32},[a-f0-9]{32}$ &&
     "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ && ${#host} -le 253 &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) ]] || return 1
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 1; fi
  IFS=, read -r -a test_ids <<< "$ids"
  [[ "${test_ids[0]}" != "${test_ids[1]}" && "${test_ids[0]}" != "${test_ids[2]}" && "${test_ids[1]}" != "${test_ids[2]}" ]] || return 1
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || return 1
  for i in 0 1 2; do
    id="${test_ids[$i]}"; stage=gv_tcp_ramp; (( i != 1 )) || stage=gv_tcp_plain
    [[ -d "$BASE/$id" && ! -L "$BASE/$id" && -f "$BASE/$id/result.json" && ! -L "$BASE/$id/result.json" &&
       $(wc -c < "$BASE/$id/result.json") -le 8192 ]] || return 1
    IFS= read -r json < "$BASE/$id/result.json" || return 1
    [[ "$json" = *"\"test_id\":\"$id\""* && "$json" = *'"route_verified":true'* && "$json" = *'"queue_seen":true'* &&
       "$json" = *'"strategy_ack_seen":true'* && "$json" = *"\"hostname\":\"$host\""* &&
       "$json" = *"\"destination_ip\":\"$ip\""* && "$json" = *'"profile_id":2'* && "$json" = *"\"scope\":\"$scope\""* &&
       "$json" = *'"protocol":"tcp"'* && "$json" = *'"recipe_id":"googlevideo-tcp-media-v1"'* &&
       "$json" = *"\"treatment_variant\":\"$stage\""* ]] || return 1
    [[ "$json" =~ \"media_url_sha256\":\"([a-f0-9]{64})\" ]] || return 1
    hash="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"observed_at\":([0-9]{1,10}) ]] || return 1
    observed="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"local_number\":([1-9][0-9]{0,2}) ]] || return 1
    strategy="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"media_bytes\":([0-9]{1,8}) ]] || return 1
    bytes="${BASH_REMATCH[1]}"
    (( observed >= now - 1200 && observed <= now + 60 )) || return 1
    if (( i == 1 )); then
      [[ "$json" = *'"overall":"INCONCLUSIVE"'* && "$json" = *'"application":"UNKNOWN"'* &&
         "$json" != *'"syn_stage_confirmed":true'* && "$json" != *'"late_ack_stage_confirmed":true'* &&
         "$json" =~ \"reason\":\"(media_insufficient|transport_timeout|target_unavailable)\" ]] || return 1
      reason="${BASH_REMATCH[1]}"
      [[ "$reason" != media_insufficient || "$bytes" -lt 1048576 ]] || return 1
      [[ "$json" = *'"transport":"OK"'* || "$json" = *'"transport":"UNKNOWN"'* ]] || return 1
    else
      [[ "$json" = *'"overall":"SUCCESS"'* && "$json" = *'"transport":"OK"'* && "$json" = *'"application":"OK"'* &&
         "$json" = *'"syn_stage_confirmed":true'* && "$json" = *'"late_ack_stage_confirmed":true'* && "$bytes" -ge 1048576 ]] || return 1
    fi
    if (( i == 0 )); then first_hash="$hash"; first_strategy="$strategy"; first_seen="$observed"
    else [[ "$hash" = "$first_hash" && "$strategy" = "$first_strategy" ]] || return 1
      (( observed > last_seen )) || return 1
    fi
    last_seen="$observed"
  done
  (( last_seen - first_seen <= 1200 )) || return 1
  printf '%s' "$ids" | sha256sum | awk '{print $1}'
}
