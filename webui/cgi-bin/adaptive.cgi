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

adaptive_ramp_exemptions_supported() {
  local ndm_root="${Z2R_ADAPTIVE_NDM_ROOT:-/opt/etc/ndm}"
  [[ ! -d "$ndm_root" ]]
}

adaptive_ramp_pool_consent_active() {
  local mode="$ROOT/extra_strats/cache/adaptive/mode"
  local lan="$ROOT/extra_strats/cache/adaptive/apply-default-scope"
  local state="$ROOT/extra_strats/cache/adaptive/ramp-pool"
  [[ "$(cat "$mode" 2>/dev/null)" = AGENT_BETA && "$(cat "$lan" 2>/dev/null)" = 1 &&
     -f "$state" && ! -L "$state" && $(wc -c < "$state") -le 256 ]] || return 1
  awk -F '\t' 'NR==1 && (($1==1 && $2=="preexisting" && $3=="manual_unverified" && NF==3) || ($1==1 && $2=="managed" && $3=="manual_unverified" && $4 ~ /^[a-f0-9]{64}$/ && NF==4) || ($1==1 && $2=="managed" && $3=="proof_verified" && $4 ~ /^[a-f0-9]{64}$/ && $5 ~ /^[a-f0-9]{64}$/ && NF==5)) {ok=1} END {exit !ok}' "$state"
}

adaptive_ramp_pool_armed() {
  local mode="$ROOT/extra_strats/cache/adaptive/mode" lan="$ROOT/extra_strats/cache/adaptive/apply-default-scope"
  local state="$ROOT/extra_strats/cache/adaptive/ramp-pool-armed" config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  local version status fingerprint extra key value current
  [[ "$(cat "$mode" 2>/dev/null)" = AGENT_BETA && "$(cat "$lan" 2>/dev/null)" = 1 &&
     -f "$state" && ! -L "$state" && $(wc -c < "$state") -le 256 && -r "$config" && ! -L "$config" ]] || return 1
  IFS=$'\t' read -r version status fingerprint extra < "$state" || return 1
  [[ "$version" = 1 && "$status" = armed && "$fingerprint" =~ ^[a-f0-9]{64}$ && -z "$extra" &&
     "$(config_get_var "$config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')" = 0 ]] || return 1
  current="$(for key in NFQWS2_ENABLE Z2R_WSSIZE_RAMP_MODE Z2R_WSSIZE_RAMP_WSIZE Z2R_WSSIZE_RAMP_SCALE \
    Z2R_WSSIZE_RAMP_OPEN Z2R_WSSIZE_RAMP_SYNDATA Z2R_WSSIZE_RAMP_SYN_BLOB Z2R_WSSIZE_RAMP_IPSET Z2R_WSSIZE_MARK; do
      value="$(config_get_var "$config" "$key" 2>/dev/null | tr -d '"\047')" || return 1
      printf '%s=%s\n' "$key" "$value"
    done | sha256sum | awk '{print $1}')" || return 1
  [[ "$current" = "$fingerprint" ]]
}

adaptive_ramp_pool_probe_authorized() {
  adaptive_ramp_pool_consent_active || adaptive_ramp_pool_armed
}

json_escape() {
  printf '%s' "$1" | awk 'BEGIN{ORS=""} {gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\r/, ""); if (NR>1) printf "\\n"; printf "%s", $0}'
}

adaptive_gc_runs() {
  local now dir state expiry retention count=0 treatment
  [[ -d "$BASE" && ! -L "$BASE" ]] || return 1
  now="$(date +%s)" || return 1
  for dir in "$BASE"/*; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    [[ "$(basename "$dir")" =~ ^[a-f0-9]{32}$ ]] || continue
    state="$(cat "$dir/state" 2>/dev/null)"
    case "$state" in complete|failed)
      expiry="$(awk -F '\t' 'NR==1 {print $6}' "$dir/leases/$(basename "$dir").tsv" 2>/dev/null)"
      retention=600
      treatment="$(cat "$dir/treatment" 2>/dev/null)"
      case "$treatment" in gv_tcp_plain|gv_tcp_ramp|gv_tcp_ramp_syndata) retention=1800 ;; esac
      if [[ "$expiry" =~ ^[0-9]{1,10}$ ]] && (( now > expiry + retention )); then
        rm -rf "$dir" || return 1
        continue
      fi
      ;;
    esac
    count=$((count + 1))
  done
  (( count < 128 ))
}

# Recover only a stale adaptive-lan owner whose lease, process, private Lua,
# queue PID, and temporary firewall state all match. This runs on Watch polls
# and before issuing a new lease so controller SIGKILL does not strand q65535.
adaptive_recover_abandoned_probe() {
  local config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  local lock_dir="${Z2R_ADAPTIVE_LOCK_DIR:-/tmp/z2r-supersweep.lock}"
  local owner controller owner_boot boot_id
  [[ -d "$BASE" && ! -L "$BASE" && -d "$lock_dir" && ! -L "$lock_dir" ]] || return 0
  if [[ -f "$lock_dir/owner" && ! -L "$lock_dir/owner" ]]; then
    IFS=$'\t' read -r owner controller owner_boot < "$lock_dir/owner" || return 1
    boot_id="$(cat "${Z2R_ADAPTIVE_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)"
    [[ -n "$boot_id" ]] || boot_id=-
    if [[ "$owner" = adaptive-lan && "$controller" =~ ^[0-9]+$ && "$owner_boot" = "$boot_id" ]] &&
       _adaptive_lan_controller_alive "$controller"; then return 0; fi
  fi
  [[ -r "$config" && ! -L "$config" ]] || return 1
  FWTYPE="$(config_get_var "$config" FWTYPE 2>/dev/null | tr -d '"\047')"
  DESYNC_MARK="$(config_get_var "$config" DESYNC_MARK 2>/dev/null | tr -d '"\047')"
  DESYNC_MARK_POSTNAT="$(config_get_var "$config" DESYNC_MARK_POSTNAT 2>/dev/null | tr -d '"\047')"
  FILTER_MARK="$(config_get_var "$config" FILTER_MARK 2>/dev/null | tr -d '"\047')"
  CLIENT_SCOPE_MARK_MASK="$(config_get_var "$config" CLIENT_SCOPE_MARK_MASK 2>/dev/null | tr -d '"\047')"
  POSTNAT="$(config_get_var "$config" POSTNAT 2>/dev/null | tr -d '"\047')"
  POSTNAT_ALL="$(config_get_var "$config" POSTNAT_ALL 2>/dev/null | tr -d '"\047')"
  ZAPRET_NFT_TABLE="$(config_get_var "$config" ZAPRET_NFT_TABLE 2>/dev/null | tr -d '"\047')"
  export FWTYPE DESYNC_MARK DESYNC_MARK_POSTNAT FILTER_MARK CLIENT_SCOPE_MARK_MASK POSTNAT POSTNAT_ALL ZAPRET_NFT_TABLE
  adaptive_lan_transport_recover_stale "$BASE"
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
. "${ROOT}/z2r_lib/config.sh" 2>/dev/null || fail '503 Service Unavailable' 'adaptive config helpers are unavailable'
. "$ROOT/tools/adaptive-ramp-proof.sh" 2>/dev/null || fail '503 Service Unavailable' 'adaptive Ramp proof validator is unavailable'
_adaptive_lan_ipv4_valid "$client_ip" || fail '403 Forbidden' 'LAN IPv4 client required'
awk -v ip="$client_ip" 'BEGIN {
  split(ip,o,".")
  if (!(o[1]==10 || (o[1]==172 && o[2]>=16 && o[2]<=31) || (o[1]==192 && o[2]==168) || ip=="127.0.0.1")) exit 1
}' || fail '403 Forbidden' 'LAN client required'
json_events() {
  local file="${Z2R_ADAPTIVE_EVENTS_FILE:-$BASE/events.tsv}" requests_file="${Z2R_ADAPTIVE_REQUESTS_FILE:-$BASE/requests.tsv}" processed_file="$(adaptive_queue_processed_file)" now line ver status host ip profile proto scope seen first=1 count=0 event_limit=128 mode req_ver req_id req_host req_ip req_profile req_scope req_created pver phost pip pprofile pscope pcompleted key
  local -A processed=()
  mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null || printf OFF)"
  case "$mode" in OBSERVE|TEST_ONLY|AGENT_BETA) ;; *) mode=OFF ;; esac
  if [[ "$mode" = TEST_ONLY || "$mode" = AGENT_BETA ]] && [[ -s "$requests_file" && ! -L "$requests_file" ]]; then event_limit=96; fi
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
    [[ "$ver" = 1 && ( "$status" = seen || "$status" = needs_verify || "$status" = suspected_failure || "$status" = active_rule_degraded || "$status" =~ ^router_trial_[1-9][0-9]?[0-9]?$ || "$status" = router_exhausted ) &&
       "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#host} -le 253 &&
       "$profile" =~ ^[1-4]$ && "$proto" = tls &&
       ( "$scope" = default || "$scope" =~ ^mark:[0-9]{1,10}$ ) && "$seen" =~ ^[0-9]{1,10}$ ]] || continue
    _adaptive_lan_public_ipv4_valid "$ip" || continue
    (( seen <= now + 60 && seen >= now - 604800 )) || continue
      key="$host|$ip|$profile|$scope"
      [[ ( "$status" != seen && "$status" != suspected_failure && "$status" != active_rule_degraded && "$status" != router_exhausted && ! "$status" =~ ^router_trial_ ) || ! ${processed[$key]+present} ]] || continue
    (( first )) || printf ','
    first=0
    printf '{"status":"%s","hostname":"%s","destination_ip":"%s","profile_id":%s,"protocol":"%s","scope":"%s","observed_at":%s}' \
      "$status" "$host" "$ip" "$profile" "$proto" "$scope" "$seen"
    count=$((count + 1))
  done < "$file"
  fi
  if [[ ( "$mode" = TEST_ONLY || "$mode" = AGENT_BETA ) && -r "$requests_file" && ! -L "$requests_file" ]]; then
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
json_ramp_targets() {
  local file="${Z2R_ADAPTIVE_RAMP_TARGETS_FILE:-$BASE/ramp-targets.tsv}" exempt_file="${Z2R_ADAPTIVE_RAMP_EXEMPT_FILE:-$BASE/ramp-exempt.tsv}"
  local now ver host ip scope seen provenance group state dns_expiry media dns_json exempt_json first=1 count=0 in_pool armed
  local e_ver e_host e_ip e_scope e_expires e_hash
  local config="${ZAPRET2_ROOT:-/opt/zapret2}/config" ramp_enable ramp_ipset
  local -A hosts_by_ip=() ips_by_host=() ramp_conflicts=()
  armed=0
  adaptive_ramp_pool_armed && armed=1
  adaptive_ramp_pool_consent_active || (( armed )) || {
    printf '{"schema_version":1,"supported":false,"reason":"ramp_pool_consent_required","targets":[]}'
    return 0
  }
  [[ ! -L "$file" && -r "$file" ]] || { printf '{"schema_version":1,"targets":[]}'; return 0; }
  [[ -r "$config" && ! -L "$config" ]] || config=""
  if [[ -n "$config" ]]; then
    ramp_enable="$(awk -F= '$1=="Z2R_WSSIZE_RAMP_ENABLE" {gsub(/["[:space:]]/, "", $2); print $2; exit}' "$config")"
    ramp_ipset="$(awk -F= '$1=="Z2R_WSSIZE_RAMP_IPSET" {sub(/^[^=]*=/, ""); gsub(/^[[:space:]"]+|[[:space:]"]+$/, ""); print; exit}' "$config")"
    case "$ramp_ipset" in
      /opt/zator/*) ramp_ipset="$ROOT/${ramp_ipset#/opt/zator/}" ;;
      /opt/zapret2/*) ramp_ipset="${ZAPRET2_ROOT:-/opt/zapret2}/${ramp_ipset#/opt/zapret2/}" ;;
    esac
    [[ ( "$ramp_enable" = 1 || "$armed" = 1 ) && -r "$ramp_ipset" && ! -L "$ramp_ipset" ]] || ramp_ipset=""
  else
    ramp_ipset=""
  fi
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || return 1
  while IFS=$'\t' read -r ver host ip scope seen provenance group state dns_expiry media || [[ -n "$ver$host$ip" ]]; do
    [[ "$ver" = 1 && "$provenance" = tls-observed && "$seen" =~ ^[0-9]{1,10}$ ]] || continue
    (( seen <= now + 60 && seen >= now - 604800 )) || continue
    [[ -z "${hosts_by_ip[$ip]:-}" || "${hosts_by_ip[$ip]}" = "$host" ]] || ramp_conflicts["ip:$ip"]=1
    [[ -z "${ips_by_host[$host]:-}" || "${ips_by_host[$host]}" = "$ip" ]] || ramp_conflicts["host:$host"]=1
    hosts_by_ip["$ip"]="$host"; ips_by_host["$host"]="$ip"
  done < "$file"
  printf '{"schema_version":1,"supported":true,"targets":['
  while IFS=$'\t' read -r ver host ip scope seen provenance group state dns_expiry media || [[ -n "$ver$host$ip" ]]; do
    (( count < 128 )) || break
    [[ "$ver" = 1 && "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ && ${#host} -le 253 &&
       ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) ]] || continue
    _adaptive_lan_public_ipv4_valid "$ip" || continue
    [[ "$seen" =~ ^[0-9]{1,10}$ && "$provenance" = tls-observed &&
       "$group" =~ ^gv1:(rr|r|exact):[a-z0-9.-]+$ &&
       "$state" =~ ^(pending|ramp_default|ramp_exempt|conflict|uncertain)$ &&
       "$dns_expiry" =~ ^[0-9]{1,10}$ && "$media" = unknown ]] || continue
    (( seen <= now + 60 && seen >= now - 604800 )) || continue
    if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || continue; fi
    if [[ ${ramp_conflicts[ip:$ip]+yes} || ${ramp_conflicts[host:$host]+yes} ]]; then state=conflict; fi
    # A target is eligible for an isolated Ramp audit only when the installed
    # config explicitly enables Ramp and this exact destination belongs to
    # its configured pool. A stale/absent pool or disabled setting stays pending.
    in_pool=0
    [[ -n "$ramp_ipset" ]] && grep -Fqx -- "$ip" "$ramp_ipset" && in_pool=1
    if [[ "$state" != conflict ]]; then
      if (( in_pool )); then
        if (( armed )) && [[ "$ramp_enable" != 1 ]]; then state=pending; else state=ramp_default; fi
      else state=uncertain
      fi
    fi
    exempt_json=null
    if [[ "$state" != conflict && "$state" = ramp_default && -r "$exempt_file" && ! -L "$exempt_file" ]]; then
      while IFS=$'\t' read -r e_ver e_host e_ip e_scope e_expires e_hash || [[ -n "$e_ver$e_ip" ]]; do
        if [[ "$e_ver" = 1 && "$e_host" = "$host" && "$e_ip" = "$ip" && "$e_scope" = "$scope" &&
              "$e_expires" =~ ^[1-9][0-9]{0,9}$ && "$e_hash" =~ ^[a-f0-9]{64}$ ]] && (( e_expires > now )); then
          state=ramp_exempt
          exempt_json="$e_expires"
          break
        fi
      done < "$exempt_file"
    fi
    (( first )) || printf ','
    first=0
    if (( dns_expiry == 0 )); then dns_json=null; else dns_json="$dns_expiry"; fi
    printf '{"hostname":"%s","destination_ip":"%s","scope":"%s","group_id":"%s","observed_at":%s,"provenance":"%s","ramp_state":"%s","dns_expires_at":%s,"ramp_expires_at":%s,"media_recipe_available":"%s"}' \
      "$(json_escape "$host")" "$ip" "$scope" "$(json_escape "$group")" "$seen" "$provenance" "$state" "$dns_json" "$exempt_json" "$media"
    count=$((count + 1))
  done < "$file"
  printf ']}'
}

adaptive_ramp_pool_apply_proof() {
  local host="${fields[hostname]:-}" ip="${fields[destination_ip]:-}" scope="${fields[scope]:-}" ids="${fields[test_ids]:-}"
  local now id json stage observed hash strategy bytes reason exact=0 conflict=0
  local first_hash="" first_strategy="" first_seen=0 last_seen=0 output target_file config ramp_ipset
  local -a test_ids
  [[ "${#fields[@]}" -eq 5 && "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ && ${#host} -le 253 ]] ||
    fail '400 Bad Request' 'invalid Ramp-first proof target'
  _adaptive_lan_public_ipv4_valid "$ip" && [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || fail '400 Bad Request' 'invalid Ramp-first proof tuple'
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || fail '400 Bad Request' 'invalid Ramp-first proof scope'; fi
  [[ "$ids" =~ ^[a-f0-9]{32},[a-f0-9]{32},[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid Ramp-first proof IDs'
  IFS=, read -r -a test_ids <<< "$ids"
  [[ "${test_ids[0]}" != "${test_ids[1]}" && "${test_ids[0]}" != "${test_ids[2]}" && "${test_ids[1]}" != "${test_ids[2]}" ]] ||
    fail '400 Bad Request' 'Ramp-first proof IDs must be unique'
  adaptive_ramp_pool_armed || fail '403 Forbidden' 'Ramp-first proof arm is missing, stale, or its consent/config changed'
  now="$(date +%s)" || fail '500 Internal Server Error' 'clock unavailable'
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || fail '500 Internal Server Error' 'clock unavailable'
  target_file="${Z2R_ADAPTIVE_RAMP_TARGETS_FILE:-$BASE/ramp-targets.tsv}"
  [[ -r "$target_file" && ! -L "$target_file" ]] || fail '409 Conflict' 'observed Ramp target is unavailable'
  while IFS=$'\t' read -r ver row_host row_ip row_scope seen provenance group state dns_expiry media extra || [[ -n "$ver$row_host$row_ip" ]]; do
    [[ "$ver" = 1 && "$provenance" = tls-observed && "$seen" =~ ^[0-9]{1,10}$ ]] || continue
    (( seen >= now - 86400 && seen <= now + 60 )) || continue
    [[ "$dns_expiry" =~ ^[0-9]{1,10}$ ]] && (( dns_expiry == 0 || dns_expiry > now )) || continue
    if [[ "$row_ip" = "$ip" && "$row_host" != "$host" ]] || [[ "$row_host" = "$host" && "$row_ip" != "$ip" ]] ||
       [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" != "$scope" ]] || [[ "$row_ip" = "$ip" && "$state" = conflict ]]; then conflict=1; fi
    [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" = "$scope" ]] && exact=1
  done < "$target_file"
  (( exact && ! conflict )) || fail '409 Conflict' 'Ramp-first target is no longer exact or has a hostname, IP, DNS, or scope conflict'
  config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  ramp_ipset="$(config_get_var "$config" Z2R_WSSIZE_RAMP_IPSET 2>/dev/null | tr -d '"\047')"
  case "$ramp_ipset" in /opt/zator/*) ramp_ipset="$ROOT/${ramp_ipset#/opt/zator/}" ;; /opt/zapret2/*) ramp_ipset="${ZAPRET2_ROOT:-/opt/zapret2}/${ramp_ipset#/opt/zapret2/}" ;; esac
  [[ "$(config_get_var "$config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')" = 0 &&
     -r "$ramp_ipset" && ! -L "$ramp_ipset" ]] && grep -Fqx -- "$ip" "$ramp_ipset" || fail '409 Conflict' 'Ramp target is not in the current configured pool'
  for i in 0 1 2; do
    id="${test_ids[$i]}"; stage=gv_tcp_ramp; (( i != 1 )) || stage=gv_tcp_plain
    [[ -d "$BASE/$id" && ! -L "$BASE/$id" && -f "$BASE/$id/result.json" && ! -L "$BASE/$id/result.json" ]] || fail '409 Conflict' 'Ramp-first proof result is unavailable'
    (( $(wc -c < "$BASE/$id/result.json") <= 8192 )) || fail '409 Conflict' 'Ramp-first proof result is oversized'
    IFS= read -r json < "$BASE/$id/result.json" || fail '409 Conflict' 'Ramp-first proof result is unreadable'
    [[ "$json" = *"\"test_id\":\"$id\""* && "$json" = *'"route_verified":true'* && "$json" = *'"queue_seen":true'* &&
       "$json" = *'"strategy_ack_seen":true'* && "$json" = *"\"hostname\":\"$host\""* &&
       "$json" = *"\"destination_ip\":\"$ip\""* && "$json" = *'"profile_id":2'* && "$json" = *"\"scope\":\"$scope\""* &&
       "$json" = *'"protocol":"tcp"'* && "$json" = *'"recipe_id":"googlevideo-tcp-media-v1"'* &&
       "$json" = *"\"treatment_variant\":\"$stage\""* ]] || fail '409 Conflict' 'Ramp-first result does not match its exact media probe'
    [[ "$json" =~ \"media_url_sha256\":\"([a-f0-9]{64})\" ]] || fail '409 Conflict' 'Ramp-first proof lacks the media URL fingerprint'
    hash="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"observed_at\":([0-9]{1,10}) ]] || fail '409 Conflict' 'Ramp-first proof timestamp is invalid'
    observed="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"local_number\":([1-9][0-9]{0,2}) ]] || fail '409 Conflict' 'Ramp-first proof strategy is invalid'
    strategy="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"media_bytes\":([0-9]{1,8}) ]] || fail '409 Conflict' 'Ramp-first proof media size is invalid'
    bytes="${BASH_REMATCH[1]}"
    (( observed >= now - 1200 && observed <= now + 60 )) || fail '409 Conflict' 'Ramp-first proof is stale'
    if (( i == 1 )); then
      [[ "$json" = *'"overall":"INCONCLUSIVE"'* && "$json" = *'"application":"UNKNOWN"'* &&
         "$json" != *'"syn_stage_confirmed":true'* && "$json" != *'"late_ack_stage_confirmed":true'* &&
         "$json" =~ \"reason\":\"(media_insufficient|transport_timeout|target_unavailable)\" ]] ||
        fail '409 Conflict' 'plain result does not prove a route-verified media degradation'
      reason="${BASH_REMATCH[1]}"
      [[ "$reason" != media_insufficient || "$bytes" -lt 1048576 ]] || fail '409 Conflict' 'plain media result did not fall below the required range'
      [[ "$json" = *'"transport":"OK"'* || "$json" = *'"transport":"UNKNOWN"'* ]] || fail '409 Conflict' 'plain result has an inconsistent transport verdict'
    else
      [[ "$json" = *'"overall":"SUCCESS"'* && "$json" = *'"transport":"OK"'* && "$json" = *'"application":"OK"'* &&
         "$json" = *'"syn_stage_confirmed":true'* && "$json" = *'"late_ack_stage_confirmed":true'* && "$bytes" -ge 1048576 ]] ||
        fail '409 Conflict' 'Ramp controls must confirm late ACK and at least 1 MiB of media'
    fi
    if (( i == 0 )); then first_hash="$hash"; first_strategy="$strategy"; first_seen="$observed"
    else [[ "$hash" = "$first_hash" && "$strategy" = "$first_strategy" ]] || fail '409 Conflict' 'Ramp-first proof changed media URL or TLS strategy'
      (( observed > last_seen )) || fail '409 Conflict' 'Ramp-first proof timestamps are not ordered'
    fi
    last_seen="$observed"
  done
  (( last_seen - first_seen <= 1200 )) || fail '409 Conflict' 'Ramp-first proof exceeded its bounded comparison window'
  output="$(ZATOR_ROOT="$ROOT" ZAPRET2_ROOT="${ZAPRET2_ROOT:-/opt/zapret2}" Z2R_ADAPTIVE_DIR="$BASE" bash "$ROOT/tools/adaptive-pair.sh" ramp-pool-proof-on "$host" "$ip" "$scope" "$ids" 2>&1)" || {
    fail '409 Conflict' 'Ramp-first could not be enabled after proof; inspect adaptive-pair status'
  }
  send_json '200 OK' '{"schema_version":1,"status":"ramp_default","basis":"proof_verified","restart_required":true}'
}

adaptive_ramp_exemption_apply() {
  local host="${fields[hostname]:-}" ip="${fields[destination_ip]:-}" scope="${fields[scope]:-}"
  local ids="${fields[test_ids]:-}" now expires config ramp_enable ramp_ipset mode marker target_file exempt_file
  local row ver row_host row_ip row_scope seen provenance group state dns_expiry media extra exact=0
  local id expected_treatment json url_hash observed strategy bytes min_bytes=1048576 first_hash="" first_strategy="" first_seen=0 last_seen=0
  local lock tmp count=0
  adaptive_ramp_exemptions_supported || fail '403 Forbidden' 'Automatic Ramp exemptions remain disabled until the late-ACK evidence gate passes on this hardware'
  [[ "${#fields[@]}" -eq 5 && "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ &&
     ${#host} -le 253 ]] || fail '400 Bad Request' 'invalid Ramp exemption target'
  _adaptive_lan_public_ipv4_valid "$ip" || fail '400 Bad Request' 'invalid Ramp exemption IP'
  [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || fail '400 Bad Request' 'invalid Ramp exemption scope'
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || fail '400 Bad Request' 'invalid Ramp exemption scope'; fi
  [[ "$ids" =~ ^[a-f0-9]{32},[a-f0-9]{32},[a-f0-9]{32},[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid Ramp proof IDs'
  IFS=, read -r -a test_ids <<< "$ids"
  [[ "${test_ids[0]}" != "${test_ids[1]}" && "${test_ids[0]}" != "${test_ids[2]}" && "${test_ids[0]}" != "${test_ids[3]}" &&
     "${test_ids[1]}" != "${test_ids[2]}" && "${test_ids[1]}" != "${test_ids[3]}" && "${test_ids[2]}" != "${test_ids[3]}" ]] || fail '400 Bad Request' 'Ramp proof IDs must be unique'
  mode="$ROOT/extra_strats/cache/adaptive/mode"; marker="$ROOT/extra_strats/cache/adaptive/apply-default-scope"
  [[ "$(cat "$mode" 2>/dev/null)" = AGENT_BETA && "$(cat "$marker" 2>/dev/null)" = 1 ]] || fail '403 Forbidden' 'Ramp exemptions require AGENT_BETA LAN consent'
  adaptive_ramp_pool_consent_active || fail '403 Forbidden' 'Ramp exemptions require explicit Ramp-first pool consent'
  config="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  ramp_enable="$(config_get_var "$config" Z2R_WSSIZE_RAMP_ENABLE 2>/dev/null | tr -d '"\047')"
  ramp_ipset="$(config_get_var "$config" Z2R_WSSIZE_RAMP_IPSET 2>/dev/null | tr -d '"\047')"
  case "$ramp_ipset" in
    /opt/zator/*) ramp_ipset="$ROOT/${ramp_ipset#/opt/zator/}" ;;
    /opt/zapret2/*) ramp_ipset="${ZAPRET2_ROOT:-/opt/zapret2}/${ramp_ipset#/opt/zapret2/}" ;;
  esac
  [[ "$ramp_enable" = 1 && -r "$ramp_ipset" && ! -L "$ramp_ipset" ]] && grep -Fqx -- "$ip" "$ramp_ipset" || fail '409 Conflict' 'Ramp must be enabled and the exact IP must remain in the configured pool'
  now="$(date +%s)" || fail '500 Internal Server Error' 'clock unavailable'
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || fail '500 Internal Server Error' 'clock unavailable'
  target_file="${Z2R_ADAPTIVE_RAMP_TARGETS_FILE:-$BASE/ramp-targets.tsv}"
  [[ -r "$target_file" && ! -L "$target_file" ]] || fail '409 Conflict' 'observed Ramp target is unavailable'
  while IFS=$'\t' read -r ver row_host row_ip row_scope seen provenance group state dns_expiry media extra || [[ -n "$ver$row_host$row_ip" ]]; do
    [[ "$ver" = 1 && "$provenance" = tls-observed && "$seen" =~ ^[0-9]{1,10}$ ]] || continue
    (( seen >= now - 86400 && seen <= now + 60 )) || continue
    [[ "$dns_expiry" =~ ^[0-9]{1,10}$ ]] && (( dns_expiry == 0 || dns_expiry > now )) || continue
    if [[ "$row_ip" = "$ip" && "$row_host" != "$host" ]] || [[ "$row_host" = "$host" && "$row_ip" != "$ip" ]] ||
       [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" = "$scope" && "$state" = conflict ]]; then
      fail '409 Conflict' 'Ramp target has a shared-IP, DNS, or scope conflict'
    fi
    [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" = "$scope" ]] && exact=1
  done < "$target_file"
  (( exact )) || fail '409 Conflict' 'Ramp target is no longer exactly observed'
  expected_treatments=(gv_tcp_ramp gv_tcp_plain gv_tcp_plain gv_tcp_ramp)
  for i in 0 1 2 3; do
    id="${test_ids[$i]}"; expected_treatment="${expected_treatments[$i]}"
    [[ -d "$BASE/$id" && ! -L "$BASE/$id" && -f "$BASE/$id/result.json" && ! -L "$BASE/$id/result.json" ]] || fail '409 Conflict' 'Ramp proof result is unavailable'
    (( $(wc -c < "$BASE/$id/result.json") <= 8192 )) || fail '409 Conflict' 'Ramp proof result is oversized'
    IFS= read -r json < "$BASE/$id/result.json" || fail '409 Conflict' 'Ramp proof result is unavailable'
    [[ "$json" = *"\"test_id\":\"$id\""* && "$json" = *"\"route_verified\":true"* &&
       "$json" = *"\"queue_seen\":true"* && "$json" = *"\"strategy_ack_seen\":true"* &&
       "$json" = *"\"overall\":\"SUCCESS\""* && "$json" = *"\"transport\":\"OK\""* &&
       "$json" = *"\"application\":\"OK\""* && "$json" = *"\"hostname\":\"$host\""* &&
       "$json" = *"\"destination_ip\":\"$ip\""* && "$json" = *"\"profile_id\":2"* &&
       "$json" = *"\"scope\":\"$scope\""* && "$json" = *"\"local_number\":"* &&
       "$json" = *"\"recipe_id\":\"googlevideo-tcp-media-v1\""* &&
       "$json" = *"\"treatment_variant\":\"$expected_treatment\""* ]] || fail '409 Conflict' 'Ramp proof does not match the completed media probe'
    [[ "$json" =~ \"media_url_sha256\":\"([a-f0-9]{64})\" ]] || fail '409 Conflict' 'Ramp proof lacks a signed media URL fingerprint'
    url_hash="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"observed_at\":([0-9]{1,10}) ]] || fail '409 Conflict' 'Ramp proof timestamp is invalid'
    observed="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"local_number\":([1-9][0-9]{0,2}) ]] || fail '409 Conflict' 'Ramp proof strategy is invalid'
    strategy="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"media_bytes\":([0-9]{1,8}) ]] || fail '409 Conflict' 'Ramp proof media byte count is invalid'
    bytes="${BASH_REMATCH[1]}"
    (( bytes >= min_bytes && observed >= now - 1200 && observed <= now + 60 )) || fail '409 Conflict' 'Ramp proof is stale or has insufficient media'
    if [[ "$expected_treatment" = gv_tcp_ramp ]]; then
      [[ "$json" = *"\"syn_stage_confirmed\":true"* && "$json" = *"\"late_ack_stage_confirmed\":true"* ]] || fail '409 Conflict' 'Ramp proof did not confirm SYN and late ACK stages'
    else
      [[ "$json" = *"\"syn_stage_confirmed\":false"* && "$json" = *"\"late_ack_stage_confirmed\":false"* ]] || fail '409 Conflict' 'plain proof unexpectedly applied Ramp'
    fi
    if (( i == 0 )); then first_hash="$url_hash"; first_strategy="$strategy"; first_seen="$observed"
    else
      [[ "$url_hash" = "$first_hash" && "$strategy" = "$first_strategy" ]] || fail '409 Conflict' 'Ramp comparison changed its media URL or strategy'
      (( observed > last_seen )) || fail '409 Conflict' 'Ramp proof timestamps are not ordered'
    fi
    last_seen="$observed"
  done
  (( last_seen - first_seen <= 1200 )) || fail '409 Conflict' 'Ramp comparison exceeded the signed URL window'
  expires=$((now + 21600))
  exempt_file="${Z2R_ADAPTIVE_RAMP_EXEMPT_FILE:-$BASE/ramp-exempt.tsv}"
  [[ ! -L "$exempt_file" ]] || fail '409 Conflict' 'Ramp exemption store is unsafe'
  mkdir -p "$(dirname "$exempt_file")" || fail '500 Internal Server Error' 'cannot prepare Ramp exemption store'
  lock="$exempt_file.lock"
  (umask 077; mkdir "$lock") 2>/dev/null || fail '409 Conflict' 'Ramp exemption store is busy'
  tmp="$exempt_file.tmp.$$"
  : > "$tmp" || { rmdir "$lock"; fail '500 Internal Server Error' 'cannot update Ramp exemption store'; }
  if [[ -r "$exempt_file" ]]; then
    while IFS=$'\t' read -r ver row_host row_ip row_scope seen provenance group state dns_expiry media extra; do
      [[ "$ver" = 1 && "$row_host" =~ ^[a-z0-9.-]+$ && "$row_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
         ( "$row_scope" = default || "$row_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$seen" =~ ^[1-9][0-9]{0,9}$ &&
         "$provenance" =~ ^[a-f0-9]{64}$ && -z "$group" && -z "$state" && -z "$dns_expiry" && -z "$media" && -z "$extra" ]] || continue
      (( seen > now )) || continue
      [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" = "$scope" ]] && continue
      count=$((count + 1)); (( count < 128 )) || { rm -f "$tmp"; rmdir "$lock"; fail '507 Insufficient Storage' 'Ramp exemption limit reached'; }
      printf '1\t%s\t%s\t%s\t%s\t%s\n' "$row_host" "$row_ip" "$row_scope" "$seen" "$provenance" >> "$tmp" || {
        rm -f "$tmp"; rmdir "$lock"; fail '500 Internal Server Error' 'cannot update Ramp exemption store';
      }
    done < "$exempt_file"
  fi
  printf '1\t%s\t%s\t%s\t%s\t%s\n' "$host" "$ip" "$scope" "$expires" "$first_hash" >> "$tmp" &&
    # nfqws2 drops privileges; its Lua callback must read the tmpfs policy.
    chmod 644 "$tmp" && mv -f "$tmp" "$exempt_file" || {
      rm -f "$tmp"; rmdir "$lock"; fail '500 Internal Server Error' 'cannot activate Ramp exemption';
    }
  rmdir "$lock" || fail '500 Internal Server Error' 'cannot release Ramp exemption lock'
  send_json '200 OK' "{\"schema_version\":1,\"status\":\"ramp_exempt\",\"hostname\":\"$host\",\"destination_ip\":\"$ip\",\"scope\":\"$scope\",\"expires\":$expires}"
}
adaptive_ramp_exemption_revoke() {
  local host="${fields[hostname]:-}" ip="${fields[destination_ip]:-}" scope="${fields[scope]:-}" ids="${fields[test_ids]:-}"
  local exempt_file="${Z2R_ADAPTIVE_RAMP_EXEMPT_FILE:-$BASE/ramp-exempt.tsv}" now id json stage hash observed strategy bytes speed reason
  local lock tmp ver row_host row_ip row_scope expires row_hash extra found=0 count=0 first_hash="" first_strategy="" first_seen=0 last_seen=0
  adaptive_ramp_exemptions_supported || fail '403 Forbidden' 'Automatic Ramp exemption changes remain disabled until the late-ACK evidence gate passes on this hardware'
  adaptive_ramp_pool_consent_active || fail '403 Forbidden' 'Ramp revocation requires explicit Ramp-first pool consent'
  [[ "${#fields[@]}" -eq 5 && "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ && ${#host} -le 253 ]] ||
    fail '400 Bad Request' 'invalid Ramp revocation target'
  _adaptive_lan_public_ipv4_valid "$ip" || fail '400 Bad Request' 'invalid Ramp revocation IP'
  [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || fail '400 Bad Request' 'invalid Ramp revocation scope'
  [[ "$ids" =~ ^[a-f0-9]{32},[a-f0-9]{32},[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid Ramp revocation proof IDs'
  IFS=, read -r -a test_ids <<< "$ids"
  [[ "${test_ids[0]}" != "${test_ids[1]}" && "${test_ids[0]}" != "${test_ids[2]}" && "${test_ids[1]}" != "${test_ids[2]}" ]] ||
    fail '400 Bad Request' 'Ramp revocation proof IDs must be unique'
  now="$(date +%s)" || fail '500 Internal Server Error' 'clock unavailable'
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || fail '500 Internal Server Error' 'clock unavailable'
  for i in 0 1 2; do
    id="${test_ids[$i]}"; stage="gv_tcp_ramp"; [[ "$i" != 1 ]] || stage=gv_tcp_plain
    [[ -d "$BASE/$id" && ! -L "$BASE/$id" && -f "$BASE/$id/result.json" && ! -L "$BASE/$id/result.json" ]] || fail '409 Conflict' 'Ramp revocation result is unavailable'
    (( $(wc -c < "$BASE/$id/result.json") <= 8192 )) || fail '409 Conflict' 'Ramp revocation result is oversized'
    IFS= read -r json < "$BASE/$id/result.json" || fail '409 Conflict' 'Ramp revocation result is unavailable'
    [[ "$json" = *"\"test_id\":\"$id\""* && "$json" = *'"route_verified":true'* &&
       "$json" = *'"queue_seen":true'* && "$json" = *'"strategy_ack_seen":true'* &&
       "$json" = *"\"hostname\":\"$host\""* && "$json" = *"\"destination_ip\":\"$ip\""* &&
       "$json" = *'"profile_id":2'* && "$json" = *"\"scope\":\"$scope\""* &&
       "$json" = *'"protocol":"tcp"'* && "$json" = *'"recipe_id":"googlevideo-tcp-media-v1"'* &&
       "$json" = *"\"treatment_variant\":\"$stage\""* ]] || fail '409 Conflict' 'Ramp revocation result does not match its treatment'
    [[ "$json" =~ \"media_url_sha256\":\"([a-f0-9]{64})\" ]] || fail '409 Conflict' 'Ramp revocation result lacks a URL fingerprint'
    hash="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"observed_at\":([0-9]{1,10}) ]] || fail '409 Conflict' 'Ramp revocation timestamp is invalid'
    observed="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"local_number\":([1-9][0-9]{0,2}) ]] || fail '409 Conflict' 'Ramp revocation strategy is invalid'
    strategy="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"media_bytes\":([0-9]{1,8}) ]] || fail '409 Conflict' 'Ramp revocation media count is invalid'
    bytes="${BASH_REMATCH[1]}"
    [[ "$json" =~ \"media_speed_bps\":([0-9]{1,10}) ]] || fail '409 Conflict' 'Ramp revocation media speed is invalid'
    speed="${BASH_REMATCH[1]}"
    if (( i == 0 )); then first_hash="$hash"; first_strategy="$strategy"; first_seen="$observed"
    else
      [[ "$hash" = "$first_hash" && "$strategy" = "$first_strategy" ]] || fail '409 Conflict' 'Ramp revocation changed URL or strategy'
      (( observed > last_seen )) || fail '409 Conflict' 'Ramp revocation results are not ordered'
    fi
    if (( i == 1 )); then
      [[ "$json" != *'"syn_stage_confirmed":true'* && "$json" != *'"late_ack_stage_confirmed":true'* &&
         "$json" = *'"overall":"INCONCLUSIVE"'* && "$json" =~ \"reason\":\"(media_insufficient|transport_timeout|target_unavailable)\" ]] ||
        fail '409 Conflict' 'plain media result does not prove a bounded degradation'
      reason="${BASH_REMATCH[1]}"
      if [[ "$reason" = media_insufficient ]]; then
        [[ "$json" = *'"transport":"OK"'* && "$json" = *'"application":"UNKNOWN"'* ]] || fail '409 Conflict' 'plain media result has inconsistent verdict fields'
      else
        [[ "$json" = *'"transport":"UNKNOWN"'* && "$json" = *'"application":"UNKNOWN"'* ]] || fail '409 Conflict' 'plain transport result has inconsistent verdict fields'
      fi
    else
      [[ "$json" = *'"syn_stage_confirmed":true'* && "$json" = *'"late_ack_stage_confirmed":true'* &&
         "$json" = *'"overall":"SUCCESS"'* && "$json" = *'"transport":"OK"'* && "$json" = *'"application":"OK"'* ]] &&
        (( bytes >= 1048576 && speed > 0 )) ||
        fail '409 Conflict' 'Ramp control did not succeed'
    fi
    (( observed >= now - 1200 && observed <= now + 60 )) || fail '409 Conflict' 'Ramp revocation result is stale'
    last_seen="$observed"
  done
  (( last_seen - first_seen <= 1200 )) || fail '409 Conflict' 'Ramp revocation comparison exceeded its URL window'
  [[ -r "$exempt_file" && ! -L "$exempt_file" ]] || fail '409 Conflict' 'Ramp exemption store is unavailable'
  lock="$exempt_file.lock"
  (umask 077; mkdir "$lock") 2>/dev/null || fail '409 Conflict' 'Ramp exemption store is busy'
  tmp="$exempt_file.tmp.$$"
  : > "$tmp" || { rmdir "$lock"; fail '500 Internal Server Error' 'cannot update Ramp exemption store'; }
  while IFS=$'\t' read -r ver row_host row_ip row_scope expires row_hash extra; do
    [[ "$ver" = 1 && "$expires" =~ ^[1-9][0-9]{0,9}$ && "$row_hash" =~ ^[a-f0-9]{64}$ && -z "$extra" ]] || continue
    (( expires > now )) || continue
    if [[ "$row_host" = "$host" && "$row_ip" = "$ip" && "$row_scope" = "$scope" ]]; then found=1; continue; fi
    count=$((count + 1)); (( count <= 128 )) || { rm -f "$tmp"; rmdir "$lock"; fail '507 Insufficient Storage' 'Ramp exemption store is oversized'; }
    printf '1\t%s\t%s\t%s\t%s\t%s\n' "$row_host" "$row_ip" "$row_scope" "$expires" "$row_hash" >> "$tmp" || {
      rm -f "$tmp"; rmdir "$lock"; fail '500 Internal Server Error' 'cannot update Ramp exemption store';
    }
  done < "$exempt_file"
  (( found )) || { rm -f "$tmp"; rmdir "$lock"; fail '409 Conflict' 'exact Ramp exemption is no longer active'; }
  # Keep the revoke output readable by the unprivileged nfqws2 worker too.
  chmod 644 "$tmp" && mv -f "$tmp" "$exempt_file" || {
    rm -f "$tmp"; rmdir "$lock"; fail '500 Internal Server Error' 'cannot revoke Ramp exemption';
  }
  rmdir "$lock" || fail '500 Internal Server Error' 'cannot release Ramp exemption lock'
  send_json '200 OK' "{\"schema_version\":1,\"status\":\"ramp_default\",\"hostname\":\"$host\",\"destination_ip\":\"$ip\",\"scope\":\"$scope\"}"
}
json_candidates() {
  local host="${1,,}" ip="$2" profile="$3" scope="$4" offset="${5:-0}" limit="${6:-10}" order="${7:-ranked}" requested_set="${8:-}" ranked_fingerprints="${9:-}" za_root="${10:-${ZAPRET2_ROOT:-/opt/zapret2}}" force_revalidate="${11:-0}"
  local config="$za_root/config" nfqws="$za_root/nfq2/nfqws2"
  local max total_max candidate_count locked number count=0 first=1 stamp known known_strategy="" known_fp known_catalog known_expiry ranked source=local-profile-order catalog_dir args_file fingerprint fingerprint_catalog candidate_set_version candidate_set_material remote_matched=0 active_proto=tls group_id="" recipe=tls-http1-v1
  local -a ordered=() preferred=() remote_order=()
  local -A added=() seen_semantics=() strategy_fingerprints=() first_strategy_for_fingerprint=()
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#host} -le 253 ]] || return 2
  _adaptive_lan_public_ipv4_valid "$ip" || return 2
  [[ "$profile" =~ ^[1-5]$ ]] || return 2
  [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || return 2
  [[ "$order" = ranked || "$order" = exploration ]] || return 2
  [[ "$force_revalidate" = 0 || "$force_revalidate" = 1 ]] || return 2
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
  if [[ "$profile" = 2 && "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ]]; then
    active_proto=googlevideo-tcp
    recipe=googlevideo-tcp-media-v1
    group_id="$(adaptive_rules_googlevideo_group_id "$host")" || return 2
  elif [[ "$profile" = 5 ]]; then
    [[ "$host" =~ ^([a-z0-9-]+\.)+googlevideo\.com$ ]] || return 2
    active_proto=udp
    recipe=googlevideo-quic-h3-media-v1
  fi
  locked="$(ORCH_ACTIVE_SCOPE="$scope" profile_state_get "$profile" "$active_proto" 2>/dev/null || printf auto)"
  [[ "$locked" = auto ]] || return 4
  stamp="$(adaptive_rules_runtime_stamp "$config" "$nfqws" "$ORCH_DIR")" || return 3
  if [[ "$active_proto" != udp ]] && known="$(adaptive_rule_lookup_local "$host" "$ip" "$profile" "$active_proto" "$scope" "$stamp")"; then
    IFS=$'\t' read -r known_strategy known_fp known_catalog known_expiry <<< "$known"
    if [[ "$force_revalidate" = 0 ]]; then
      printf '{"schema_version":1,"status":"already_confirmed","profile_id":%s,"scope":"%s","strategy_number":%s,"winner_kind":"%s","strategy_fingerprint":"%s","catalog_version":"%s","expires":%s}' \
        "$profile" "$scope" "$known_strategy" "$( [ "$known_strategy" = 0 ] && printf DIRECT || printf STRATEGY )" "$known_fp" "$known_catalog" "$known_expiry"
      return 0
    fi
  fi
  max="$(config_profile_max_strategy "$profile" "$config" 2>/dev/null)"
  [[ "$max" =~ ^[1-9][0-9]{0,2}$ ]] || return 5
  total_max="$max"
  if [[ "$order" = ranked ]]; then
    if [[ "$force_revalidate" = 1 && "$known_strategy" =~ ^[1-9][0-9]{0,2}$ && "$known_strategy" -le "$total_max" ]]; then
      preferred+=("$known_strategy"); added[$known_strategy]=1
    fi
    if [[ "$active_proto" = udp ]]; then
      ranked=""
    elif [[ -n "$group_id" ]]; then
      ranked="$(adaptive_rules_ranked_candidates "$profile" "$active_proto" "$scope" "$stamp" "$total_max" "$group_id" 2>/dev/null || true)"
    else
      ranked="$(adaptive_rules_ranked_candidates "$profile" "$active_proto" "$scope" "$stamp" "$total_max" 2>/dev/null || true)"
    fi
    while IFS= read -r number; do
      [[ "$number" =~ ^[1-9][0-9]{0,2}$ ]] && (( number <= total_max )) && [[ ! ${added[$number]+yes} ]] || continue
      preferred+=("$number"); added[$number]=1
    done <<< "$ranked"
  fi
  if (( ${#preferred[@]} > 0 )); then source=local-confirmations-first; fi
  if [[ "$order" = exploration ]]; then
    [[ ! -L "$BASE" ]] || return 3
    mkdir -p "$BASE" || return 3
    catalog_dir="$(mktemp -d "$BASE/catalog.XXXXXX")" || return 3
    Z2R_SUPERSWEEP_DIR="$catalog_dir"
    DESYNC_MARK="$(config_get_var "$config" DESYNC_MARK 2>/dev/null | tr -d '"\047')"
    export Z2R_SUPERSWEEP_DIR DESYNC_MARK
    if ! supersweep_probe_config "$profile" "$config" standard "$ip" "$recipe"; then rm -rf "$catalog_dir"; return 3; fi
    args_file="$catalog_dir/probe/nfqws2.args"
    source=family-diverse-local-order
    while IFS= read -r number; do
      [[ "$number" =~ ^[1-9][0-9]{0,2}$ && "$number" -le "$total_max" ]] || { rm -rf "$catalog_dir"; return 3; }
      ordered+=("$number")
    done < <(adaptive_exploration_strategy_order "$args_file" "$total_max")
    rm -rf "$catalog_dir"
    (( ${#ordered[@]} == total_max )) || return 3
  else
    [[ ! -L "$BASE" ]] || return 3
    mkdir -p "$BASE" || return 3
    catalog_dir="$(mktemp -d "$BASE/catalog.XXXXXX")" || return 3
    Z2R_SUPERSWEEP_DIR="$catalog_dir"
    DESYNC_MARK="$(config_get_var "$config" DESYNC_MARK 2>/dev/null | tr -d '"\047')"
    export Z2R_SUPERSWEEP_DIR DESYNC_MARK
    if ! supersweep_probe_config "$profile" "$config" standard "$ip" "$recipe"; then rm -rf "$catalog_dir"; return 3; fi
    args_file="$catalog_dir/probe/nfqws2.args"
    fingerprint_catalog="$(adaptive_strategy_fingerprint_catalog "$profile" "$total_max" "$args_file" "$nfqws" standard "$recipe" "$stamp" "$BASE/catalog-cache")" || {
      rm -rf "$catalog_dir"; return 3;
    }
    while IFS=$'\t' read -r number fingerprint; do
      [[ "$number" =~ ^[1-9][0-9]{0,2}$ && "$number" -le "$total_max" && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ ]] || {
        rm -rf "$catalog_dir"; return 3;
      }
      strategy_fingerprints[$number]="$fingerprint"
      [[ ${first_strategy_for_fingerprint[$fingerprint]+yes} ]] || first_strategy_for_fingerprint[$fingerprint]="$number"
    done <<< "$fingerprint_catalog"
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
  [[ "$force_revalidate" != 1 ]] || source=active-rule-revalidation
  candidate_set_material="order=$order|profile=$profile|protocol=$active_proto|recipe=$recipe|scope=$scope|profile_count=$total_max|candidate_count=$candidate_count|source=$source|force=$force_revalidate|known=${known_strategy:-none}|stamp=$stamp|identity=$group_id|remote=$ranked_fingerprints|candidates=$(printf '%s,' "${ordered[@]}")"
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
  printf '{"schema_version":1,"status":"%s","profile_id":%s,"scope":"%s","protocol":"%s","recipe_id":"%s","profile_strategy_count":%s,"candidate_count":%s,"candidate_set_version":"%s","candidate_offset":%s,"active_rule_strategy":%s,"active_rule_fingerprint":"%s","candidate_numbers":[' \
    "$([[ "$max" -gt 0 ]] && printf ready || printf complete)" "$profile" "$scope" "$active_proto" "$recipe" "$total_max" "$candidate_count" "$candidate_set_version" "$offset" \
    "$( [[ "$known_strategy" =~ ^(0|[1-9][0-9]{0,2})$ ]] && printf '%s' "$known_strategy" || printf null )" "${known_fp:-}"
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
    action|hostname|destination_ip|profile_id|local_strategy_number|source_port|probe_owner|scope|offset|limit|order|candidate_set_version|ranked_fingerprints|force_revalidate|schema_version|test_id|route_verified|overall|observed_at|transport|application|reason|ip_family|protocol|port|strategy_fingerprint|catalog_version|recipe_id|treatment_variant|client_profile|media_bytes|media_speed_bps|media_duration_ms|request_id|test_ids|stage|statistics_enabled|rankings_enabled|search_outcome|candidates_checked|fast_candidates|deep_candidates|search_duration_ms|time_to_first_success_ms|pc_cpu_percent|pc_free_memory_bytes|pc_network_bytes_per_second|router_load_milli|router_memory_available_kib|router_active_probes|revalidation_recoveries|revalidation_failures|success_after_apply|cooldown_targets) ;;
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
    adaptive_recover_abandoned_probe || fail '503 Service Unavailable' 'adaptive probe recovery could not verify its queue owner or clean its rules'
    adaptive_queue_agent_heartbeat >/dev/null 2>&1 || :
    send_json '200 OK' "$(json_events)"
    ;;
  agent_status)
    [[ "${#fields[@]}" -ge 18 && "${#fields[@]}" -le 20 ]] || fail '400 Bad Request' 'agent_status requires a bounded status snapshot'
    status_args=("${fields[stage]:-}" "${fields[statistics_enabled]:-}" "${fields[rankings_enabled]:-}" \
      "${fields[search_outcome]:-}" "${fields[candidates_checked]:-}" "${fields[fast_candidates]:-}" \
      "${fields[deep_candidates]:-}" "${fields[search_duration_ms]:-}" "${fields[time_to_first_success_ms]:-}" \
      "${fields[pc_cpu_percent]:-}" "${fields[pc_free_memory_bytes]:-}" "${fields[pc_network_bytes_per_second]:-}" \
      "${fields[router_load_milli]:-}" "${fields[router_memory_available_kib]:-}" "${fields[router_active_probes]:-}" \
      "${fields[revalidation_recoveries]:-}" "${fields[revalidation_failures]:-}" "${fields[success_after_apply]:-0}")
    [[ ${fields[cooldown_targets]+present} ]] && status_args+=("${fields[cooldown_targets]}")
    adaptive_queue_agent_status "${status_args[@]}" || fail '400 Bad Request' 'invalid agent status snapshot'
    adaptive_queue_agent_heartbeat >/dev/null 2>&1 || :
    send_json '200 OK' '{"schema_version":1,"ok":true}'
    ;;
  ramp_targets)
    [[ "${#fields[@]}" -eq 1 ]] || fail '400 Bad Request' 'ramp_targets accepts no parameters'
    [[ "$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)" = AGENT_BETA ]] || \
      fail '403 Forbidden' 'Ramp audit targets are available only in AGENT_BETA'
    if ! adaptive_ramp_pool_probe_authorized; then
      send_json '200 OK' '{"schema_version":1,"supported":false,"reason":"ramp_pool_consent_required","targets":[]}'
    fi
    target_json="$(json_ramp_targets)" || fail '503 Service Unavailable' 'Ramp observation catalog is unavailable'
    send_json '200 OK' "$target_json"
    ;;
  ramp_exempt_apply)
    adaptive_ramp_exemption_apply
    ;;
  ramp_pool_apply)
    adaptive_ramp_pool_apply_proof
    ;;
  ramp_exempt_revoke)
    adaptive_ramp_exemption_revoke
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
    [[ "${#fields[@]}" -eq 1 || ( "${#fields[@]}" -eq 3 && ${fields[source_port]+present} && ${fields[probe_owner]+present} ) ]] || \
      fail '400 Bad Request' 'invalid probe cancellation parameters'
    source_port="${fields[source_port]:-}"
    probe_owner="${fields[probe_owner]:-}"
    if [[ -n "$source_port" || -n "$probe_owner" ]]; then
      [[ "$source_port" =~ ^[1-9][0-9]{4}$ ]] && (( source_port >= 62000 && source_port <= 62999 )) || \
        fail '400 Bad Request' 'invalid probe source port'
      [[ "$probe_owner" =~ ^[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid probe owner'
    fi
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
        lease_record="$(awk -F '\t' -v id="$id" -v ip="$client_ip" -v port="$source_port" -v owner="$probe_owner" '((NF==7) || (NF==8 && length($8)==32 && $8 !~ /[^a-f0-9]/)) && $1==id && $2==ip && (port=="" || $3==port) && (owner=="" || (NF==8 && $8==owner)) {n++; row=$0} END {if(n==1) print row; else exit 1}' "$lease_file" 2>/dev/null)" || continue
        IFS=$'\t' read -r lease_id lease_ip lease_port lease_dst lease_dport lease_expiry lease_recipe lease_owner <<< "$lease_record"
        [[ "$lease_id" = "$id" && "$lease_ip" = "$client_ip" && "$lease_expiry" =~ ^[0-9]{1,10}$ &&
           ( "$lease_recipe" = tls-http1-v1 || "$lease_recipe" = googlevideo-tcp-media-v1 ) ]] || continue
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
    mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)"
    [[ "$mode" = TEST_ONLY || "$mode" = AGENT_BETA ]] || fail '403 Forbidden' 'adaptive probe mode does not allow candidates'
    if candidate_json="$(json_candidates "${fields[hostname]:-}" "${fields[destination_ip]:-}" "${fields[profile_id]:-}" "${fields[scope]:-default}" "${fields[offset]:-0}" "${fields[limit]:-10}" "${fields[order]:-ranked}" "${fields[candidate_set_version]:-}" "${fields[ranked_fingerprints]:-}" "${ZAPRET2_ROOT:-/opt/zapret2}" "${fields[force_revalidate]:-0}")"; then
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
    adaptive_recover_abandoned_probe || fail '503 Service Unavailable' 'adaptive probe recovery could not verify its queue owner or clean its rules'
    [[ -x "$CONTROLLER" ]] || fail '503 Service Unavailable' 'adaptive controller is not installed'
    mode="$(cat "$ROOT/extra_strats/cache/adaptive/mode" 2>/dev/null)"
    [[ "$mode" = TEST_ONLY || "$mode" = AGENT_BETA ]] || fail '403 Forbidden' 'adaptive probe mode does not allow probes'
    host="${fields[hostname]:-}"
    dst_ip="${fields[destination_ip]:-}"
    profile="${fields[profile_id]:-}"
    strategy="${fields[local_strategy_number]:-}"
    scope="${fields[scope]:-default}"
    probe_owner="${fields[probe_owner]:-}"
    recipe="${fields[recipe_id]:-tls-http1-v1}"
    treatment="${fields[treatment_variant]:-standard}"
    [[ -z "$probe_owner" || "$probe_owner" =~ ^[a-f0-9]{32}$ ]] || fail '400 Bad Request' 'invalid probe owner'
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ && "$host" == *.* && ${#host} -le 253 ]] || fail '400 Bad Request' 'invalid hostname'
    host="${host,,}"
    _adaptive_lan_public_ipv4_valid "$dst_ip" || fail '400 Bad Request' 'public IPv4 destination required'
    [[ "$profile" =~ ^[1-5]$ && "$strategy" =~ ^(0|[1-9][0-9]{0,2})$ ]] || fail '400 Bad Request' 'invalid profile or strategy'
    case "$recipe" in
      tls-http1-v1) [[ "$treatment" = standard ]] || fail '400 Bad Request' 'TLS recipe does not accept a Googlevideo treatment' ;;
      googlevideo-tcp-media-v1)
        [[ "$profile" = 2 && "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ ]] || \
          fail '400 Bad Request' 'Googlevideo media recipe requires a profile-2 Googlevideo hostname'
        case "$treatment" in standard|gv_tcp_plain|gv_tcp_ramp|gv_tcp_ramp_syndata) ;; *) fail '400 Bad Request' 'invalid Googlevideo treatment' ;; esac
        if [[ "$mode" = AGENT_BETA && "$treatment" =~ ^gv_tcp_ramp ]]; then
          adaptive_ramp_pool_probe_authorized || fail '403 Forbidden' 'Ramp probes require explicit Ramp-first pool consent'
        fi ;;
      googlevideo-quic-h3-media-v1)
        [[ "$profile" = 5 && "$treatment" = standard && "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ ]] || \
          fail '400 Bad Request' 'Googlevideo QUIC recipe requires profile 5 and a Googlevideo hostname' ;;
      *) fail '400 Bad Request' 'unsupported adaptive recipe' ;;
    esac
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
    nohup bash "$CONTROLLER" "$id" "$client_ip" "$port" "$host" "$dst_ip" "$profile" "$strategy" "$expires" "$scope" "$probe_owner" "$recipe" "$treatment" \
      > "$run/controller.log" 2>&1 </dev/null &
    wait_limit=9
    [[ "$recipe" != googlevideo-tcp-media-v1 ]] || wait_limit=45
    for ((waited=0; waited<wait_limit; waited++)); do
      if [[ -s "$run/lease.json" ]]; then
        lease_body="$(cat "$run/lease.json")"
        if [[ "$recipe" = googlevideo-tcp-media-v1 || "$recipe" = googlevideo-quic-h3-media-v1 ]]; then rm -f "$run/lease.json"; fi
        printf 'Cache-Control: no-store\r\n'
        send_json '200 OK' "$lease_body"
      fi
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
    IFS=$'\t' read -r lease_id lease_ip lease_port lease_dst lease_dport lease_expiry lease_recipe lease_owner < "$run/leases/$id.tsv" || fail '404 Not Found' 'unknown lease'
    [[ "$lease_id" = "$id" && "$lease_ip" = "$client_ip" && ( "$lease_recipe" = tls-http1-v1 || "$lease_recipe" = googlevideo-tcp-media-v1 || "$lease_recipe" = googlevideo-quic-h3-media-v1 ) ]] || fail '403 Forbidden' 'lease owner mismatch'
    expected_protocol=tcp
    [[ "$lease_recipe" != googlevideo-quic-h3-media-v1 ]] || expected_protocol=udp
    if [[ -n "$lease_owner" ]]; then
      [[ "$lease_owner" =~ ^[a-f0-9]{32}$ && "${fields[probe_owner]:-}" = "$lease_owner" ]] || fail '403 Forbidden' 'probe owner mismatch'
    elif [[ ${fields[probe_owner]+present} ]]; then
      fail '403 Forbidden' 'probe owner mismatch'
    fi
    [[ "${fields[schema_version]:-}" = 1 && "${fields[test_id]:-}" = "$id" ]] || fail '400 Bad Request' 'result schema mismatch'
    [[ "${fields[route_verified]:-}" = false && "${fields[overall]:-}" = INCONCLUSIVE &&
       "${fields[ip_family]:-}" = ipv4 && "${fields[protocol]:-}" = "$expected_protocol" && "${fields[port]:-}" = 443 ]] || \
      fail '400 Bad Request' 'client result must use the unverified IPv4/443 recipe'
    observed="${fields[observed_at]:-}"; transport="${fields[transport]:-}"; application="${fields[application]:-}"
    reason="${fields[reason]:-}"; host="${fields[hostname]:-}"; dst_ip="${fields[destination_ip]:-}"
    profile="${fields[profile_id]:-}"; fingerprint="${fields[strategy_fingerprint]:-}"
    strategy="${fields[local_strategy_number]:-}"; catalog="${fields[catalog_version]:-}"
    recipe="${fields[recipe_id]:-}"; client_profile="${fields[client_profile]:-}"
    scope="${fields[scope]:-default}"
    [[ "$observed" =~ ^[0-9]{1,10}$ ]] || fail '400 Bad Request' 'invalid timestamp'
    case "$transport" in OK|FAIL|UNKNOWN) ;; *) fail '400 Bad Request' 'invalid transport verdict' ;; esac
    case "$application" in OK|FAIL|NOT_TESTED|UNKNOWN) ;; *) fail '400 Bad Request' 'invalid application verdict' ;; esac
    case "$reason" in probe_ok|http_rejected|rate_limited|server_busy|response_too_large|empty_response|timeout|transport_timeout|origin_unavailable|signed_url_expired|media_insufficient|media_ok|quic_unavailable|target_unavailable|route_unverified|probe_error|cancelled|expired) ;; *) fail '400 Bad Request' 'invalid reason' ;; esac
    media_bytes="${fields[media_bytes]:-0}"; media_speed_bps="${fields[media_speed_bps]:-0}"; media_duration_ms="${fields[media_duration_ms]:-0}"
    [[ "$media_bytes" =~ ^[0-9]{1,8}$ && "$media_bytes" -le 16777216 &&
       "$media_speed_bps" =~ ^[0-9]{1,10}$ && "$media_speed_bps" -le 1073741824 &&
       "$media_duration_ms" =~ ^[0-9]{1,8}$ && "$media_duration_ms" -le 60000 ]] || fail '400 Bad Request' 'invalid media metrics'
    [[ "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" =~ ^sha256:[a-f0-9]{64}$ ]] || fail '400 Bad Request' 'invalid strategy identity'
    [[ "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ]] || fail '400 Bad Request' 'invalid client scope'
    if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || fail '400 Bad Request' 'invalid client scope'; fi
    treatment="${fields[treatment_variant]:-standard}"
    IFS=$'\t' read -r expected_host expected_dst expected_profile expected_fingerprint expected_strategy expected_catalog expected_scope expected_treatment < "$run/target.tsv" || fail '409 Conflict' 'probe context missing'
    expected_treatment="${expected_treatment:-standard}"
    (( lease_expiry > $(date +%s) )) || fail '410 Gone' 'lease expired'
    expected_client=curl-windows-v1; expected_protocol=tcp
    [[ "$lease_recipe" != googlevideo-tcp-media-v1 ]] || expected_client=curl-windows-media-v1
    if [[ "$lease_recipe" = googlevideo-quic-h3-media-v1 ]]; then expected_client=curl-windows-quic-media-v1; expected_protocol=udp; fi
    [[ "${fields[protocol]:-}" = "$expected_protocol" && "$host" = "$expected_host" && "$dst_ip" = "$expected_dst" && "$profile" = "$expected_profile" && "$fingerprint" = "$expected_fingerprint" && "$strategy" = "$expected_strategy" && "$catalog" = "$expected_catalog" && "$scope" = "$expected_scope" && "$treatment" = "$expected_treatment" && "$lease_dport" = 443 && "$recipe" = "$lease_recipe" && "$client_profile" = "$expected_client" ]] || fail '409 Conflict' 'result does not match lease'
    if [[ "$recipe" = tls-http1-v1 ]]; then [[ "$media_bytes:$media_speed_bps:$media_duration_ms" = 0:0:0 ]] || fail '400 Bad Request' 'TLS recipe cannot submit media metrics'; fi
    printf -v record '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$id" "$observed" "$transport" "$application" "$reason" "$host" "$dst_ip" "$profile" "$fingerprint" "$strategy" "$catalog" "$recipe" "$treatment" "$client_profile" "$scope" "$media_bytes" "$media_speed_bps" "$media_duration_ms"
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
