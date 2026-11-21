#!/usr/bin/env bash
# Persistent, bounded handoff queue for explicit adaptive verification requests.
set -u

adaptive_queue_file() { printf '%s\n' "${Z2R_ADAPTIVE_REQUESTS_FILE:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/requests.tsv}"; }
adaptive_queue_processed_file() { printf '%s\n' "${Z2R_ADAPTIVE_PROCESSED_FILE:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/processed.tsv}"; }

adaptive_queue_agent_heartbeat() {
  local base="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}" file tmp now
  [[ ! -L "$base" ]] || return 1
  mkdir -p "$base" || return 1
  [[ -d "$base" && ! -L "$base" ]] || return 1
  file="$base/agent.last"
  [[ ! -L "$file" ]] || return 1
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || return 1
  tmp="$(mktemp "$base/.agent-last.XXXXXX")" || return 1
  (umask 077; printf '%s\n' "$now" > "$tmp") && chmod 600 "$tmp" && mv -f "$tmp" "$file" || {
    rm -f "$tmp"
    return 1
  }
}

adaptive_queue_agent_status() {
  [[ $# = 17 ]] || return 2
  local stage="$1" stats="$2" rankings="$3" outcome="$4" checked="$5" fast="$6" deep="$7" duration="$8" first="$9"
  local cpu="${10}" pc_mem="${11}" pc_net="${12}" router_load="${13}" router_mem="${14}" router_active="${15}"
  local revalidation_recoveries="${16}" revalidation_failures="${17}" now
  local base="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}" file tmp
  [[ "$stage" =~ ^(idle|fast_search|deep_search|explore|ramp_audit)$ &&
     "$stats" =~ ^(true|false)$ && "$rankings" =~ ^(true|false)$ &&
     "$outcome" =~ ^(none|found|direct|deep_scheduled|all_exhausted|limit_reached|inconclusive|stopped_rate_limit|stopped_infra|cancelled)$ &&
     "$checked" =~ ^[0-9]{1,3}$ && "$checked" -le 999 &&
     "$fast" =~ ^[0-9]{1,3}$ && "$fast" -le 999 &&
     "$deep" =~ ^[0-9]{1,3}$ && "$deep" -le 999 &&
     "$duration" =~ ^[0-9]{1,8}$ && "$duration" -le 86400000 &&
     "$first" =~ ^[0-9]{1,8}$ && "$first" -le 86400000 &&
     "$cpu" =~ ^(-1|[0-9]{1,3})$ &&
     "$pc_mem" =~ ^(-1|[0-9]{1,13})$ && "$pc_mem" -le 8796093022208 &&
     "$pc_net" =~ ^(-1|[0-9]{1,13})$ && "$pc_net" -le 1099511627776 &&
     "$router_load" =~ ^(-1|[0-9]{1,7})$ && "$router_load" -le 1024000 &&
     "$router_mem" =~ ^(-1|[0-9]{1,13})$ && "$router_mem" -le 8796093022208 &&
     "$router_active" =~ ^(-1|[0-9]{1,3})$ && "$router_active" -le 999 &&
     "$revalidation_recoveries" =~ ^(0|[1-9][0-9]{0,5})$ && "$revalidation_recoveries" -le 999999 &&
     "$revalidation_failures" =~ ^(0|[1-9][0-9]{0,5})$ && "$revalidation_failures" -le 999999 ]] || return 2
  [[ "$cpu" = -1 ]] || (( cpu <= 100 )) || return 2
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || return 1
  [[ ! -L "$base" ]] || return 1
  mkdir -p "$base" || return 1
  [[ -d "$base" && ! -L "$base" ]] || return 1
  file="$base/agent.status.tsv"
  [[ ! -L "$file" ]] || return 1
  tmp="$(mktemp "$base/.agent-status.XXXXXX")" || return 1
  (umask 077; printf '3\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$stage" "$stats" "$rankings" "$outcome" "$checked" "$fast" "$deep" "$duration" "$first" \
    "$cpu" "$pc_mem" "$pc_net" "$router_load" "$router_mem" "$router_active" "$revalidation_recoveries" "$revalidation_failures" > "$tmp") &&
    chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

adaptive_queue_resources_json() {
  local base="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}" load1 cores mem_available load_per_core active=0 dir id state
  load1="$(awk 'NR==1 {print $1; exit}' /proc/loadavg 2>/dev/null)"
  cores="$(awk '/^processor[[:space:]]*:/ {n++} END {print n+0}' /proc/cpuinfo 2>/dev/null)"
  mem_available="$(awk '
    $1=="MemAvailable:" {available=$2; found=1}
    $1=="MemFree:" {free=$2}
    $1=="Buffers:" {buffers=$2}
    $1=="Cached:" {cached=$2}
    END {if (found) print available; else if (free!="" && buffers!="" && cached!="") print free+buffers+cached; else print 0}
  ' /proc/meminfo 2>/dev/null)"
  [[ "$load1" =~ ^[0-9]+([.][0-9]+)?$ && "$cores" =~ ^[1-9][0-9]{0,2}$ &&
     "$mem_available" =~ ^[0-9]{1,10}$ ]] || return 1
  load_per_core="$(awk -v lavg="$load1" -v cores="$cores" 'BEGIN {printf "%.3f", lavg/cores}')"
  [[ "$load_per_core" =~ ^[0-9]+[.][0-9]{3}$ ]] || return 1
  if [[ -d "$base" && ! -L "$base" ]]; then
    for dir in "$base"/*; do
      [[ -d "$dir" && ! -L "$dir" ]] || continue
      id="${dir##*/}"
      [[ "$id" =~ ^[a-f0-9]{32}$ ]] || continue
      state="$(cat "$dir/state" 2>/dev/null)"
      case "$state" in complete|failed) ;; *) active=$((active + 1)) ;; esac
    done
  fi
  printf '{"schema_version":1,"load1_per_core":%s,"cores":%s,"mem_available_kib":%s,"active_probes":%s}\n' \
    "$load_per_core" "$cores" "$mem_available" "$active"
}

adaptive_queue_request() {
  [[ $# = 4 ]] || return 2
  local host="${1,,}" ip="$2" profile="$3" scope="$4" base="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}"
  local file lock tmp now id row ver old_id old_host old_ip old_profile old_scope created count=0 cooldown=0 tries=0 owner events
  mode="$(cat "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/mode" 2>/dev/null)"
  [[ "$mode" = TEST_ONLY || "$mode" = AGENT_BETA ]] || return 3
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#host} -le 253 ]] || return 2
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$profile" =~ ^[1-4]$ && ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) ]] || return 2
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 2; fi
  local -a octets; IFS=. read -r -a octets <<< "$ip"
  (( ${#octets[@]} == 4 )) || return 2
  for id in "${octets[@]}"; do [[ "$id" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( id <= 255 )) || return 2; done
  (( octets[0] != 0 && octets[0] != 10 && octets[0] != 127 && octets[0] < 224 &&
     !(octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127) &&
     !(octets[0] == 169 && octets[1] == 254) &&
     !(octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) &&
     !(octets[0] == 192 && (octets[1] == 168 || (octets[1] == 0 && (octets[2] == 0 || octets[2] == 2)) || (octets[1] == 88 && octets[2] == 99))) &&
     !(octets[0] == 198 && (octets[1] == 18 || octets[1] == 19 || (octets[1] == 51 && octets[2] == 100))) &&
     !(octets[0] == 203 && octets[1] == 0 && octets[2] == 113) )) || return 2
  events="${Z2R_ADAPTIVE_EVENTS_FILE:-$base/events.tsv}"
  awk -F '\t' -v h="$host" -v ip="$ip" -v p="$profile" -v s="$scope" -v now="$(date +%s)" \
    '$1==1 && ($2=="seen" || $2=="needs_verify" || $2=="suspected_failure" || $2=="active_rule_degraded") && $3==h && $4==ip && $5==p && $7==s && $8 ~ /^[0-9]+$/ && $8<=now+60 && $8>=now-86400 {found=1} END {exit !found}' "$events" 2>/dev/null || return 4
  file="$(adaptive_queue_file)"; lock="$file.lock"; now="$(date +%s)"
  mkdir -p "$(dirname "$file")" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries+1)); ((tries<30)) || return 1; sleep 0.1; done
  tmp="$file.tmp.$$.$RANDOM"; : > "$tmp" || { rmdir "$lock"; return 1; }
  if [[ -r "$file" && ! -L "$file" ]]; then
  while IFS=$'\t' read -r ver old_id old_host old_ip old_profile old_scope created || [[ -n "${ver:-}${old_id:-}" ]]; do
    [[ "$ver" = 1 && "$old_id" =~ ^[a-f0-9]{32}$ && "$old_host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$old_profile" =~ ^[1-4]$ && ( "$old_scope" = default || "$old_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$created" =~ ^[0-9]{1,10}$ ]] || continue
    (( created > now - 1800 )) || continue
    count=$((count+1))
    if [[ "$old_host" = "$host" && "$old_ip" = "$ip" && "$old_profile" = "$profile" && "$old_scope" = "$scope" ]]; then
      (( now - created >= 300 )) || cooldown=1
    fi
    (( count <= 32 )) || { rm -f "$tmp"; rmdir "$lock"; return 5; }
    printf '1\t%s\t%s\t%s\t%s\t%s\n' "$old_id" "$old_host" "$old_ip" "$old_profile" "$old_scope" "$created" >> "$tmp"
  done < "$file" 2>/dev/null
  fi
  if (( cooldown )); then rm -f "$tmp"; rmdir "$lock"; return 6; fi
  (( count < 32 )) || { rm -f "$tmp"; rmdir "$lock"; return 5; }
  id="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ "$id" =~ ^[a-f0-9]{32}$ ]] || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$host" "$ip" "$profile" "$scope" "$now" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  owner="$(stat -c '%u:%g' "$file" 2>/dev/null || true)"
  if [[ "$owner" =~ ^[0-9]+:[0-9]+$ ]]; then chown "$owner" "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }; fi
  chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock" || return 1
  printf '%s\n' "$id"
}

adaptive_queue_ack() {
  [[ $# = 1 && "$1" =~ ^[a-f0-9]{32}$ ]] || return 2
  local wanted="$1" file lock tmp row ver id host ip profile scope created tries=0 owner found=0
  file="$(adaptive_queue_file)"; lock="$file.lock"
  [[ -f "$file" && ! -L "$file" ]] || return 0
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries+1)); ((tries<30)) || return 1; sleep 0.1; done
  tmp="$file.tmp.$$.$RANDOM"; : > "$tmp" || { rmdir "$lock"; return 1; }
  while IFS= read -r row; do
    IFS=$'\t' read -r ver id host ip profile scope created <<< "$row"
    if [[ "$ver" = 1 && "$id" = "$wanted" ]]; then found=1; continue; fi
    printf '%s\n' "$row" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  done < "$file"
  if (( found )); then
    owner="$(stat -c '%u:%g' "$file" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+:[0-9]+$ ]]; then chown "$owner" "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }; fi
    chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  else rm -f "$tmp"; fi
  rmdir "$lock"
}

# Persist passive-event completion on tmpfs so restarting the Windows watcher
# does not immediately replay the same ring-buffer observations.
adaptive_queue_event_ack() {
  [[ $# = 4 ]] || return 2
  local host="${1,,}" ip="$2" profile="$3" scope="$4" file lock tmp row ver old_host old_ip old_profile old_scope completed now tries=0 count=0 owner
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#host} -le 253 &&
     "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$profile" =~ ^[1-4]$ &&
     ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) ]] || return 2
  if [[ "$scope" = mark:* ]]; then (( ${scope#mark:} <= 65535 )) || return 2; fi
  file="$(adaptive_queue_processed_file)"; lock="$file.lock"; now="$(date +%s)"
  mkdir -p "$(dirname "$file")" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries+1)); ((tries<30)) || return 1; sleep 0.1; done
  tmp="$file.tmp.$$.$RANDOM"; : > "$tmp" || { rmdir "$lock"; return 1; }
  if [[ -r "$file" && ! -L "$file" ]]; then
    while IFS=$'\t' read -r ver old_host old_ip old_profile old_scope completed || [[ -n "${ver:-}${old_host:-}" ]]; do
      [[ "$ver" = 1 && "$old_host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$old_profile" =~ ^[1-4]$ && ( "$old_scope" = default || "$old_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$completed" =~ ^[0-9]{1,10}$ ]] || continue
      (( completed > now - 3600 && completed <= now + 60 )) || continue
      if [[ "$old_host" = "$host" && "$old_ip" = "$ip" && "$old_profile" = "$profile" && "$old_scope" = "$scope" ]]; then
        continue
      fi
      count=$((count+1)); (( count <= 127 )) || continue
      printf '1\t%s\t%s\t%s\t%s\t%s\n' "$old_host" "$old_ip" "$old_profile" "$old_scope" "$completed" >> "$tmp"
    done < "$file"
  fi
  printf '1\t%s\t%s\t%s\t%s\t%s\n' "$host" "$ip" "$profile" "$scope" "$now" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  owner="$(stat -c '%u:%g' "$file" 2>/dev/null || true)"
  if [[ "$owner" =~ ^[0-9]+:[0-9]+$ ]]; then chown "$owner" "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }; fi
  chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  rmdir "$lock"
}

adaptive_queue_clear() {
  local file lock tries=0
  file="$(adaptive_queue_file)"; lock="$file.lock"
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do tries=$((tries+1)); ((tries<30)) || return 1; sleep 0.1; done
  rm -f "$file" "$(adaptive_queue_processed_file)" || { rmdir "$lock"; return 1; }
  rmdir "$lock"
}
