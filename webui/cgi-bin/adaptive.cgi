#!/usr/bin/env bash
# Authenticated single-probe API; it never writes production strategy locks.
set -u

ROOT="${ZATOR_ROOT:-/opt/zator}"
BASE="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}"
TOKEN_FILE="$ROOT/extra_strats/cache/adaptive/token"
TOKEN_EXPIRY_FILE="$ROOT/extra_strats/cache/adaptive/token.expires"
CONTROLLER="$ROOT/tools/adaptive-controller.sh"
MAX_BODY=4096

send_json() {
  local status="$1" body="$2"
  printf 'Status: %s\r\nCache-Control: no-store\r\nContent-Type: application/json; charset=utf-8\r\n\r\n%s\n' "$status" "$body"
  exit 0
}

fail() { send_json "$1" "{\"error\":\"$2\"}"; }

json_escape() {
  printf '%s' "$1" | awk 'BEGIN{ORS=""} {gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\r/, ""); if (NR>1) printf "\\n"; printf "%s", $0}'
}

adaptive_gc_runs() {
  local now dir state expiry count=0
  [[ -d "$BASE" && ! -L "$BASE" ]] || return 1
  now="$(date +%s)" || return 1
  for dir in "$BASE"/*; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    [[ "$(basename "$dir")" =~ ^[a-f0-9]{32}$ ]] || continue
    state="$(cat "$dir/state" 2>/dev/null)"
    case "$state" in complete|failed)
      expiry="$(awk -F '\t' 'NR==1 {print $6}' "$dir/leases/$(basename "$dir").tsv" 2>/dev/null)"
      if [[ "$expiry" =~ ^[0-9]{1,10}$ ]] && (( now > expiry + 600 )); then
        rm -rf "$dir" || return 1
        continue
      fi
      ;;
    esac
    count=$((count + 1))
  done
  (( count < 128 ))
}

if [[ "${REQUEST_METHOD:-}" != POST || "${CONTENT_TYPE%%;*}" != application/x-www-form-urlencoded ]]; then
  fail '405 Method Not Allowed' 'POST form data required'
fi
length="${CONTENT_LENGTH:-}"
[[ "$length" =~ ^[0-9]{1,4}$ ]] && (( length > 0 && length <= MAX_BODY )) || fail '413 Payload Too Large' 'invalid request size'
length=$((10#$length))
[[ -r "$TOKEN_FILE" && ! -L "$TOKEN_FILE" ]] || fail '503 Service Unavailable' 'adaptive pairing is not configured'
[[ -r "$TOKEN_EXPIRY_FILE" && ! -L "$TOKEN_EXPIRY_FILE" ]] || fail '401 Unauthorized' 'adaptive pairing token expired; rotate it'
token="$(cat "$TOKEN_FILE" 2>/dev/null)"
token_expiry="$(cat "$TOKEN_EXPIRY_FILE" 2>/dev/null)"
now="$(date +%s)"
[[ "$token_expiry" =~ ^[0-9]{1,10}$ && "$now" =~ ^[0-9]{1,10}$ ]] && (( token_expiry > now )) \
  || fail '401 Unauthorized' 'adaptive pairing token expired; rotate it'
provided="${HTTP_AUTHORIZATION:-}"
case "$provided" in 'Bearer '*) provided="${provided#Bearer }" ;; *) fail '401 Unauthorized' 'missing bearer token' ;; esac
[[ "$token" =~ ^[a-f0-9]{64}$ && "$provided" =~ ^[a-f0-9]{64}$ ]] || fail '401 Unauthorized' 'invalid bearer token'
token_hash="$(printf '%s' "$token" | sha256sum | awk '{print $1}')"
provided_hash="$(printf '%s' "$provided" | sha256sum | awk '{print $1}')"
[[ "$token_hash" = "$provided_hash" ]] || fail '401 Unauthorized' 'invalid bearer token'

client_ip="${REMOTE_ADDR:-}"
. "${ROOT}/z2r_lib/adaptive_lan_transport.sh" 2>/dev/null || fail '503 Service Unavailable' 'adaptive runtime unavailable'
. "${ROOT}/z2r_lib/adaptive_queue.sh" 2>/dev/null || fail '503 Service Unavailable' 'adaptive queue unavailable'
_adaptive_lan_ipv4_valid "$client_ip" || fail '403 Forbidden' 'LAN IPv4 client required'
awk -v ip="$client_ip" 'BEGIN {
  split(ip,o,".")
  if (!(o[1]==10 || (o[1]==172 && o[2]>=16 && o[2]<=31) || (o[1]==192 && o[2]==168) || ip=="127.0.0.1")) exit 1
}' || fail '403 Forbidden' 'LAN client required'
json_events() {
  local file="${Z2R_ADAPTIVE_EVENTS_FILE:-$BASE/events.tsv}" requests_file="${Z2R_ADAPTIVE_REQUESTS_FILE:-$BASE/requests.tsv}" processed_file="$(adaptive_queue_processed_file)" now line ver status host ip profile proto scope seen first=1 count=0 event_limit=128 mode req_ver req_id req_host req_ip req_profile req_scope req_created pver phost pip pprofile pscope pcompleted key
  local -A processed=()
  mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null || printf OFF)"
  case "$mode" in OBSERVE|TEST_ONLY) ;; *) mode=OFF ;; esac
  if [[ "$mode" = TEST_ONLY && -s "$requests_file" && ! -L "$requests_file" ]]; then event_limit=96; fi
  [[ ( -r "$file" && ! -L "$file" ) || ( -r "$requests_file" && ! -L "$requests_file" ) ]] || { printf '{"schema_version":1,"mode":"%s","events":[]}' "$mode"; return; }
  now="$(date +%s)" || { printf '{"schema_version":1,"mode":"%s","events":[]}' "$mode"; return; }
  if [[ -r "$processed_file" && ! -L "$processed_file" ]]; then
    while IFS=$'\t' read -r pver phost pip pprofile pscope pcompleted || [[ -n "$pver$phost" ]]; do
      [[ "$pver" = 1 && "$phost" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ &&
         "$pprofile" =~ ^[1-4]$ && ( "$pscope" = default || "$pscope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$pcompleted" =~ ^[0-9]{1,10}$ ]] || continue
      (( pcompleted > now - 3600 && pcompleted <= now + 60 )) || continue
      processed["$phost|$pip|$pprofile|$pscope"]=1
    done < "$processed_file"
  fi
  printf '{"schema_version":1,"mode":"%s","events":[' "$mode"
  if [[ -r "$file" && ! -L "$file" ]]; then
  while IFS=$'\t' read -r ver status host ip profile proto scope seen || [[ -n "$ver$status$host$ip$profile$proto$scope$seen" ]]; do
    (( count < event_limit )) || break
    [[ "$ver" = 1 && ( "$status" = seen || "$status" = needs_verify || "$status" = suspected_failure ) &&
       "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#host} -le 253 &&
       "$profile" =~ ^[1-4]$ && "$proto" = tls &&
       ( "$scope" = default || "$scope" =~ ^mark:[0-9]{1,10}$ ) && "$seen" =~ ^[0-9]{1,10}$ ]] || continue
    _adaptive_lan_public_ipv4_valid "$ip" || continue
    (( seen <= now + 60 && seen >= now - 604800 )) || continue
      key="$host|$ip|$profile|$scope"
      [[ ( "$status" != seen && "$status" != suspected_failure ) || ! ${processed[$key]+present} ]] || continue
    (( first )) || printf ','
    first=0
    printf '{"status":"%s","hostname":"%s","destination_ip":"%s","profile_id":%s,"protocol":"%s","scope":"%s","observed_at":%s}' \
      "$status" "$host" "$ip" "$profile" "$proto" "$scope" "$seen"
    count=$((count + 1))
  done < "$file"
  fi
  if [[ "$mode" = TEST_ONLY && -r "$requests_file" && ! -L "$requests_file" ]]; then
    while IFS=$'\t' read -r req_ver req_id req_host req_ip req_profile req_scope req_created || [[ -n "$req_ver$req_id" ]]; do
      (( count < 128 )) || break
      [[ "$req_ver" = 1 && "$req_id" =~ ^[a-f0-9]{32}$ && "$req_host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ &&
         "$req_profile" =~ ^[1-4]$ && ( "$req_scope" = default || "$req_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$req_created" =~ ^[0-9]{1,10}$ ]] || continue
      _adaptive_lan_public_ipv4_valid "$req_ip" || continue
      (( req_created <= now + 60 && req_created >= now - 1800 )) || continue
      (( first )) || printf ','
      first=0
      printf '{"status":"needs_verify","request_id":"%s","hostname":"%s","destination_ip":"%s","profile_id":%s,"protocol":"tls","scope":"%s","observed_at":%s}' \
        "$req_id" "$req_host" "$req_ip" "$req_profile" "$req_scope" "$req_created"
      count=$((count + 1))
    done < "$requests_file"
  fi
  printf ']}'
}
json_candidates() {
  local host="${1,,}" ip="$2" profile="$3" scope="$4" offset="${5:-0}" limit="${6:-10}" order="${7:-ranked}" requested_set="${8:-}" ranked_fingerprints="${9:-}" za_root="${10:-${ZAPRET2_ROOT:-/opt/zapret2}}"
  local config="$za_root/config" nfqws="$za_root/nfq2/nfqws2"
  local max total_max candidate_count locked number count=0 first=1 stamp known known_strategy known_fp known_catalog known_expiry ranked source=local-profile-order catalog_dir args_file fingerprint candidate_set_version candidate_set_material remote_matched=0
  local -a ordered=() preferred=() remote_order=()
  local -A added=() seen_semantics=() strategy_fingerprints=() first_strategy_for_fingerprint=()
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#host} -le 253 ]] || return 2
  _adaptive_lan_public_ipv4_valid "$ip" || return 2
  [[ "$profile" =~ ^[1-4]$ ]] || return 2
  [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || return 2
  [[ "$order" = ranked || "$order" = exploration ]] || return 2
  if [[ -n "$ranked_fingerprints" ]]; then
    [[ "$order" = ranked && ${#ranked_fingerprints} -le 729 ]] || return 2
    IFS=',' read -r -a remote_order <<< "$ranked_fingerprints"
    (( ${#remote_order[@]} <= 10 )) || return 2
    local remote_fp
    local -A remote_seen=()
    for remote_fp in "${remote_order[@]}"; do
      [[ "$remote_fp" =~ ^sha256:[a-f0-9]{64}$ && ! ${remote_seen[$remote_fp]+yes} ]] || return 2
      remote_seen[$remote_fp]=1
    done
  fi
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 2; fi
  [[ -r "$config" && ! -L "$config" ]] || return 3
  [[ -r "$ROOT/z2r_lib/config.sh" && -r "$ROOT/z2r_lib/orchestra_state.sh" && -r "$ROOT/z2r_lib/adaptive_rules.sh" &&
     -r "$ROOT/z2r_lib/supersweep_probe.sh" && -r "$ROOT/lua/locked.lua" && -r "$ROOT/lua/fake-adapt.lua" && -x "$nfqws" ]] || return 3
  ZATOR_ROOT="$ROOT" ZAPRET2_ROOT="$za_root"
  ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
  ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
  . "$ROOT/z2r_lib/config.sh"
  . "$ROOT/z2r_lib/orchestra_state.sh"
  . "$ROOT/z2r_lib/adaptive_rules.sh"
  . "$ROOT/z2r_lib/supersweep_probe.sh"
  locked="$(ORCH_ACTIVE_SCOPE="$scope" profile_state_get "$profile" tls 2>/dev/null || printf auto)"
  [[ "$locked" = auto ]] || return 4
  stamp="$(adaptive_rules_runtime_stamp "$config" "$nfqws" "$ORCH_DIR")" || return 3
  if known="$(adaptive_rule_lookup_local "$host" "$ip" "$profile" tls "$scope" "$stamp")"; then
    IFS=$'\t' read -r known_strategy known_fp known_catalog known_expiry <<< "$known"
    printf '{"schema_version":1,"status":"already_confirmed","profile_id":%s,"scope":"%s","strategy_number":%s,"strategy_fingerprint":"%s","catalog_version":"%s","expires":%s}' \
      "$profile" "$scope" "$known_strategy" "$known_fp" "$known_catalog" "$known_expiry"
    return 0
  fi
  max="$(config_profile_max_strategy "$profile" "$config" 2>/dev/null)"
  [[ "$max" =~ ^[1-9][0-9]{0,2}$ ]] || return 5
  total_max="$max"
  if [[ "$order" = ranked ]]; then
    ranked="$(adaptive_rules_ranked_candidates "$profile" tls "$scope" "$stamp" "$total_max" 2>/dev/null || true)"
    while IFS= read -r number; do
      [[ "$number" =~ ^[1-9][0-9]{0,2}$ ]] && (( number <= total_max )) && [[ ! ${added[$number]+yes} ]] || continue
      preferred+=("$number"); added[$number]=1
    done <<< "$ranked"
  fi
  if (( ${#preferred[@]} > 0 )); then source=local-confirmations-first; fi
  if [[ "$order" = exploration ]]; then
    for ((number=1; number<=total_max; number++)); do ordered+=("$number"); done
  else
    [[ ! -L "$BASE" ]] || return 3
    mkdir -p "$BASE" || return 3
    catalog_dir="$(mktemp -d "$BASE/catalog.XXXXXX")" || return 3
    Z2R_SUPERSWEEP_DIR="$catalog_dir"
    DESYNC_MARK="$(config_get_var "$config" DESYNC_MARK 2>/dev/null | tr -d '"\047')"
    export Z2R_SUPERSWEEP_DIR DESYNC_MARK
    if ! supersweep_probe_config "$profile" "$config"; then rm -rf "$catalog_dir"; return 3; fi
    args_file="$catalog_dir/probe/nfqws2.args"
    for ((number=1; number<=total_max; number++)); do
      fingerprint="$(adaptive_strategy_fingerprint "$profile" "$number" "$args_file" "$nfqws")" || {
        rm -rf "$catalog_dir"; return 3;
      }
      strategy_fingerprints[$number]="$fingerprint"
      [[ ${first_strategy_for_fingerprint[$fingerprint]+yes} ]] || first_strategy_for_fingerprint[$fingerprint]="$number"
    done
    for number in "${preferred[@]}"; do
      fingerprint="${strategy_fingerprints[$number]}"
      [[ ${seen_semantics[$fingerprint]+yes} ]] && continue
      ordered+=("$number"); seen_semantics[$fingerprint]=1
    done
    for remote_fp in "${remote_order[@]}"; do
      number="${first_strategy_for_fingerprint[$remote_fp]:-}"
      [[ "$number" =~ ^[1-9][0-9]{0,2}$ && ! ${seen_semantics[$remote_fp]+yes} ]] || continue
      ordered+=("$number"); seen_semantics[$remote_fp]=1; remote_matched=1
    done
    for ((number=1; number<=total_max; number++)); do
      fingerprint="${strategy_fingerprints[$number]}"
      [[ ${seen_semantics[$fingerprint]+yes} ]] && continue
      ordered+=("$number"); seen_semantics[$fingerprint]=1
    done
    rm -rf "$catalog_dir"
  fi
  candidate_count="${#ordered[@]}"
  [[ "$offset" =~ ^[0-9]{1,3}$ && "$limit" =~ ^[1-9][0-9]?$ ]] || return 2
  (( offset <= candidate_count && limit <= 10 )) || return 2
  [[ "$order" != ranked || "$remote_matched" -eq 0 || "$source" = local-confirmations-first ]] || source=remote-rankings-first
  candidate_set_material="order=$order|profile=$profile|scope=$scope|profile_count=$total_max|candidate_count=$candidate_count|source=$source|stamp=$stamp|remote=$ranked_fingerprints|candidates=$(printf '%s,' "${ordered[@]}")"
  candidate_set_version="sha256:$(printf '%s\n' "$candidate_set_material" | sha256sum | awk '{print $1}')" || return 3
  [[ "$candidate_set_version" =~ ^sha256:[a-f0-9]{64}$ ]] || return 3
  if [[ "$order" = ranked ]]; then
    if (( offset > 0 )); then
      [[ "$requested_set" =~ ^sha256:[a-f0-9]{64}$ ]] || return 5
      [[ "$requested_set" = "$candidate_set_version" ]] || return 6
    elif [[ -n "$requested_set" && "$requested_set" != "$candidate_set_version" ]]; then
      return 6
    fi
  elif [[ -n "$requested_set" ]]; then return 2; fi
  max=$((candidate_count - offset))
  (( max > limit )) && max="$limit"
  printf '{"schema_version":1,"status":"%s","profile_id":%s,"scope":"%s","profile_strategy_count":%s,"candidate_count":%s,"candidate_set_version":"%s","candidate_offset":%s,"candidate_numbers":[' \
    "$([[ "$max" -gt 0 ]] && printf ready || printf complete)" "$profile" "$scope" "$total_max" "$candidate_count" "$candidate_set_version" "$offset"
  for ((count=offset; count<offset + max; count++)); do
    (( first )) || printf ','
    first=0
    printf '%s' "${ordered[$count]}"
  done
  printf '],"source":"%s"}' "$source"
}

body="$(dd bs=1 count="$length" 2>/dev/null)"
[[ ${#body} -eq $length ]] || fail '400 Bad Request' 'truncated request'
decode() {
  local input="$1" output='' i=0 char hex byte
  while (( i < ${#input} )); do
    char="${input:i:1}"
    case "$char" in
      +) output+=' ' ;;
      %)
        (( i + 2 < ${#input} )) || return 1
        hex="${input:i+1:2}"
        [[ "$hex" =~ ^[A-Fa-f0-9]{2}$ ]] || return 1
        printf -v byte '%b' "\\x$hex"
        [[ "$byte" != $'\0' ]] || return 1
        output+="$byte"
        i=$((i + 2)) ;;
      *) output+="$char" ;;
    esac
    i=$((i + 1))
  done
  REPLY="$output"
}

declare -A fields=()
IFS='&' read -r -a pairs <<< "$body"
for pair in "${pairs[@]}"; do
  key="${pair%%=*}"; value="${pair#*=}"
  [[ "$pair" == *=* ]] || fail '400 Bad Request' 'invalid form field'
  decode "$key" || fail '400 Bad Request' 'invalid form encoding'; key="$REPLY"
  decode "$value" || fail '400 Bad Request' 'invalid form encoding'; value="$REPLY"
  case "$key" in
    action|hostname|destination_ip|profile_id|local_strategy_number|source_port|scope|offset|limit|order|candidate_set_version|ranked_fingerprints|schema_version|test_id|route_verified|overall|observed_at|transport|application|reason|ip_family|protocol|port|strategy_fingerprint|catalog_version|recipe_id|client_profile|request_id) ;;
    *) fail '400 Bad Request' 'unknown form field' ;;
  esac
  [[ -n "$key" && ! ${fields[$key]+present} ]] || fail '400 Bad Request' 'duplicate form field'
  fields["$key"]="$value"
done
action="${fields[action]:-}"

case "$action" in
  stats_identity)
    provider_file="$ROOT/extra_strats/cache/provider.txt"
    provider="$(head -n1 "$provider_file" 2>/dev/null)"
    [[ -n "$provider" && ${#provider} -le 120 && "$provider" != 'Не определён' && "$provider" != 'Не удалось определить' ]] || \
      fail '503 Service Unavailable' 'provider identity is unavailable'
    provider="${provider%% - *}"
    send_json '200 OK' "{\"schema_version\":1,\"provider\":\"$(json_escape "$provider")\"}"
    ;;
  events)
    adaptive_queue_agent_heartbeat >/dev/null 2>&1 || :
    send_json '200 OK' "$(json_events)"
    ;;
  resources)
    [[ "${#fields[@]}" -eq 1 ]] || fail '400 Bad Request' 'resources accepts no parameters'
    resource_json="$(adaptive_queue_resources_json)" || fail '503 Service Unavailable' 'router resource counters are unavailable'
    send_json '200 OK' "$resource_json"
    ;;
  ack_request)
    request_id="${fields[request_id]:-}"
    [[ "$request_id" =~ ^[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid request id'
    adaptive_queue_ack "$request_id" || fail '500 Internal Server Error' 'could not acknowledge request'
    send_json '200 OK' '{"schema_version":1,"ok":true}'
    ;;
  cancel_probes)
    [[ "${#fields[@]}" -eq 1 ]] || fail '400 Bad Request' 'cancel_probes accepts no parameters'
    cancelled=0
    if [[ -d "$BASE" && ! -L "$BASE" ]]; then
      for dir in "$BASE"/*; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        id="$(basename "$dir")"
        [[ "$id" =~ ^[a-f0-9]{32}$ ]] || continue
        state="$(cat "$dir/state" 2>/dev/null)"
        case "$state" in complete|failed|cleanup_failed) continue ;; esac
        lease_file="$dir/leases/$id.tsv"
        [[ -f "$lease_file" && ! -L "$lease_file" ]] || continue
        lease_record="$(awk -F '\t' -v id="$id" -v ip="$client_ip" 'NF==7 && $1==id && $2==ip {n++; row=$0} END {if(n==1) print row; else exit 1}' "$lease_file" 2>/dev/null)" || continue
        IFS=$'\t' read -r lease_id lease_ip lease_port lease_dst lease_dport lease_expiry lease_recipe <<< "$lease_record"
        [[ "$lease_id" = "$id" && "$lease_ip" = "$client_ip" && "$lease_expiry" =~ ^[0-9]{1,10}$ &&
           "$lease_recipe" = tls-http1-v1 ]] || continue
        (( lease_expiry > $(date +%s) )) || continue
        [[ ! -e "$dir/cancel" && ! -L "$dir/cancel" ]] || continue
        cancel_tmp="$(mktemp "$dir/.cancel.XXXXXX")" || fail '500 Internal Server Error' 'could not create probe cancellation'
        printf 'urgent_request\n' > "$cancel_tmp" && chmod 600 "$cancel_tmp" && mv -f "$cancel_tmp" "$dir/cancel" || {
          rm -f "$cancel_tmp"; fail '500 Internal Server Error' 'could not cancel probe'
        }
        cancelled=$((cancelled + 1))
      done
    fi
    send_json '200 OK' "{\"schema_version\":1,\"cancelled\":$cancelled}"
    ;;
  ack_event)
    host="${fields[hostname]:-}"; dst_ip="${fields[destination_ip]:-}"; profile="${fields[profile_id]:-}"; scope="${fields[scope]:-default}"
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ && "$dst_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$profile" =~ ^[1-4]$ ]] || fail '400 Bad Request' 'invalid event acknowledgment'
    _adaptive_lan_public_ipv4_valid "$dst_ip" && [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || fail '400 Bad Request' 'invalid event acknowledgment'
    if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || fail '400 Bad Request' 'invalid event acknowledgment'; fi
    adaptive_queue_event_ack "$host" "$dst_ip" "$profile" "$scope" || fail '400 Bad Request' 'invalid event acknowledgment'
    send_json '200 OK' '{"schema_version":1,"ok":true}'
    ;;
  candidates)
    [[ "$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)" = TEST_ONLY ]] || \
      fail '403 Forbidden' 'adaptive probe mode is not TEST_ONLY'
    if candidate_json="$(json_candidates "${fields[hostname]:-}" "${fields[destination_ip]:-}" "${fields[profile_id]:-}" "${fields[scope]:-default}" "${fields[offset]:-0}" "${fields[limit]:-10}" "${fields[order]:-ranked}" "${fields[candidate_set_version]:-}" "${fields[ranked_fingerprints]:-}")"; then
      send_json '200 OK' "$candidate_json"
    else
      case "$?" in
        2) fail '400 Bad Request' 'invalid hostname, destination, profile, or client scope' ;;
        3) fail '503 Service Unavailable' 'strategy catalog is unavailable' ;;
        4) fail '409 Conflict' 'profile has an explicit lock or disable' ;;
        5) fail '400 Bad Request' 'ranked candidate page requires its initial catalog version' ;;
        6) fail '409 Conflict' 'ranked candidate catalog changed; restart candidate search' ;;
        *) fail '409 Conflict' 'profile has no local strategies' ;;
      esac
    fi
    ;;
  lease)
    [[ -x "$CONTROLLER" ]] || fail '503 Service Unavailable' 'adaptive controller is not installed'
    [[ "$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)" = TEST_ONLY ]] || \
      fail '403 Forbidden' 'adaptive probe mode is not TEST_ONLY'
    host="${fields[hostname]:-}"
    dst_ip="${fields[destination_ip]:-}"
    profile="${fields[profile_id]:-}"
    strategy="${fields[local_strategy_number]:-}"
    scope="${fields[scope]:-default}"
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ && "$host" == *.* && ${#host} -le 253 ]] || fail '400 Bad Request' 'invalid hostname'
    host="${host,,}"
    _adaptive_lan_public_ipv4_valid "$dst_ip" || fail '400 Bad Request' 'public IPv4 destination required'
    [[ "$profile" =~ ^[1-4]$ && "$strategy" =~ ^(0|[1-9][0-9]{0,2})$ ]] || fail '400 Bad Request' 'invalid profile or strategy'
    [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || fail '400 Bad Request' 'invalid client scope'
    if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || fail '400 Bad Request' 'invalid client scope'; fi
    now="$(date +%s)"; expires=$((now + 90)); port=""
    if [[ ${fields[source_port]+present} ]]; then
      candidate_port="${fields[source_port]}"
      [[ "$candidate_port" =~ ^[1-9][0-9]{0,4}$ ]] && \
        adaptive_lan_lease_valid "$client_ip" "$candidate_port" "$dst_ip" 443 "$expires" "$now" || \
        fail '400 Bad Request' 'invalid source port'
      port="$candidate_port"
    else
      for ((attempt=0; attempt<16; attempt++)); do
        candidate_port=$((62000 + RANDOM % 1000))
        if adaptive_lan_lease_valid "$client_ip" "$candidate_port" "$dst_ip" 443 "$expires" "$now"; then port="$candidate_port"; break; fi
      done
    fi
    [[ -n "$port" ]] || fail '503 Service Unavailable' 'cannot allocate source port'
    # BusyBox builds on supported routers may omit the `od` applet. The Linux
    # kernel UUID source provides the same 128-bit random ID without an extra
    # userspace dependency.
    id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
    id="${id//-/}"
    [[ "$id" =~ ^[a-f0-9]{32}$ ]] || fail '503 Service Unavailable' 'cannot create test id'
    (umask 077; mkdir -p "$BASE") || fail '500 Internal Server Error' 'cannot create adaptive runtime'
    [[ ! -L "$BASE" ]] || fail '503 Service Unavailable' 'unsafe adaptive runtime path'
    chmod 711 "$BASE" || fail '500 Internal Server Error' 'cannot protect adaptive runtime'
    adaptive_gc_runs || fail '503 Service Unavailable' 'adaptive probe capacity reached'
    run="$BASE/$id"
    (umask 077; mkdir "$run") 2>/dev/null || fail '409 Conflict' 'test id collision'
    chmod 711 "$run" || fail '500 Internal Server Error' 'cannot protect test state'
    nohup bash "$CONTROLLER" "$id" "$client_ip" "$port" "$host" "$dst_ip" "$profile" "$strategy" "$expires" "$scope" \
      > "$run/controller.log" 2>&1 </dev/null &
    for ((waited=0; waited<9; waited++)); do
      [[ -s "$run/lease.json" ]] && send_json '200 OK' "$(cat "$run/lease.json")"
      [[ -s "$run/error" ]] && fail '503 Service Unavailable' 'probe could not be started'
      sleep 1
    done
    fail '503 Service Unavailable' 'probe startup timed out'
    ;;
  complete)
    id="${fields[test_id]:-}"
    [[ "$id" =~ ^[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid test id'
    run="$BASE/$id"
    [[ -d "$run" && ! -L "$run" && -r "$run/leases/$id.tsv" ]] || fail '404 Not Found' 'unknown or expired test'
    IFS=$'\t' read -r lease_id lease_ip lease_port lease_dst lease_dport lease_expiry lease_recipe < "$run/leases/$id.tsv" || fail '404 Not Found' 'unknown lease'
    [[ "$lease_id" = "$id" && "$lease_ip" = "$client_ip" && "$lease_recipe" = tls-http1-v1 ]] || fail '403 Forbidden' 'lease owner mismatch'
    [[ "${fields[schema_version]:-}" = 1 && "${fields[test_id]:-}" = "$id" ]] || fail '400 Bad Request' 'result schema mismatch'
    [[ "${fields[route_verified]:-}" = false && "${fields[overall]:-}" = INCONCLUSIVE &&
       "${fields[ip_family]:-}" = ipv4 && "${fields[protocol]:-}" = tcp && "${fields[port]:-}" = 443 ]] \
      || fail '400 Bad Request' 'client result must use the unverified IPv4 TCP/443 recipe'
    observed="${fields[observed_at]:-}"; transport="${fields[transport]:-}"; application="${fields[application]:-}"
    reason="${fields[reason]:-}"; host="${fields[hostname]:-}"; dst_ip="${fields[destination_ip]:-}"
    profile="${fields[profile_id]:-}"; fingerprint="${fields[strategy_fingerprint]:-}"
    strategy="${fields[local_strategy_number]:-}"; catalog="${fields[catalog_version]:-}"
    recipe="${fields[recipe_id]:-}"; client_profile="${fields[client_profile]:-}"
    scope="${fields[scope]:-default}"
    [[ "$observed" =~ ^[0-9]{1,10}$ ]] || fail '400 Bad Request' 'invalid timestamp'
    case "$transport" in OK|FAIL|UNKNOWN) ;; *) fail '400 Bad Request' 'invalid transport verdict' ;; esac
    case "$application" in OK|FAIL|NOT_TESTED|UNKNOWN) ;; *) fail '400 Bad Request' 'invalid application verdict' ;; esac
    case "$reason" in probe_ok|http_rejected|rate_limited|server_busy|response_too_large|empty_response|timeout|target_unavailable|route_unverified|probe_error|cancelled|expired) ;; *) fail '400 Bad Request' 'invalid reason' ;; esac
    [[ "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" =~ ^sha256:[a-f0-9]{64}$ ]] || fail '400 Bad Request' 'invalid strategy identity'
    [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || fail '400 Bad Request' 'invalid client scope'
    if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || fail '400 Bad Request' 'invalid client scope'; fi
    IFS=$'\t' read -r expected_host expected_dst expected_profile expected_fingerprint expected_strategy expected_catalog expected_scope < "$run/target.tsv" || fail '409 Conflict' 'probe context missing'
    (( lease_expiry > $(date +%s) )) || fail '410 Gone' 'lease expired'
    [[ "$host" = "$expected_host" && "$dst_ip" = "$expected_dst" && "$profile" = "$expected_profile" && "$fingerprint" = "$expected_fingerprint" && "$strategy" = "$expected_strategy" && "$catalog" = "$expected_catalog" && "$scope" = "$expected_scope" && "$lease_dport" = 443 && "$recipe" = tls-http1-v1 && "$client_profile" = curl-windows-v1 ]] || fail '409 Conflict' 'result does not match lease'
    printf -v record '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$id" "$observed" "$transport" "$application" "$reason" "$host" "$dst_ip" "$profile" "$fingerprint" "$strategy" "$catalog" "$recipe" "$client_profile" "$scope"
    result_file="$run/complete.tsv"
    if [[ -e "$result_file" ]]; then
      [[ "$(cat "$result_file")" = "$record" ]] || fail '409 Conflict' 'test result already submitted'
    else
      (umask 077; mkdir "$run/complete.lock") 2>/dev/null || fail '409 Conflict' 'result submission already in progress'
      tmp="$run/.complete.$$.tmp"
      (umask 077; printf '%s\n' "$record" > "$tmp") && mv "$tmp" "$result_file" || {
        rm -f "$tmp"; rmdir "$run/complete.lock" 2>/dev/null || :
        fail '500 Internal Server Error' 'cannot save test result'
      }
      rmdir "$run/complete.lock" 2>/dev/null || :
    fi
    for ((waited=0; waited<10; waited++)); do
      [[ -s "$run/result.json" ]] && send_json '200 OK' "$(cat "$run/result.json")"
      [[ "$(cat "$run/state" 2>/dev/null)" = cleanup_failed ]] && fail '503 Service Unavailable' 'probe cleanup failed'
      sleep 1
    done
    fail '503 Service Unavailable' 'probe completion timed out'
    ;;
  *) fail '400 Bad Request' 'unknown adaptive action' ;;
esac
