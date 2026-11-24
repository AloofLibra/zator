# This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
#!/usr/bin/env bash
# Bounded runtime store and delayed cache snapshot for locally verified adaptive rules.
# Never writes manual locks or per-probe flash data.

adaptive_rules_file() {
  printf '%s\n' "${Z2R_ADAPTIVE_RULES_FILE:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/rules.tsv}"
}

adaptive_rules_snapshot_file() {
  printf '%s\n' "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/rules.tsv"
}

adaptive_rules_quic_host_valid() {
  [[ $# = 1 && "${1,,}" =~ (^|\.)(googlevideo\.com|youtube\.com|youtubei\.googleapis\.com)$ ]]
}

adaptive_rules_googlevideo_host_valid() {
  [[ $# = 1 && "${1,,}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*googlevideo\.com$ ]]
}

adaptive_rules_kind_valid() {
  [[ $# = 3 ]] || return 1
  local profile="$1" proto="$2" host="${3,,}"
  case "$proto" in
    tls) [[ "$profile" =~ ^[1-4]$ ]] ;;
    googlevideo-tcp) [[ "$profile" = 2 ]] && adaptive_rules_googlevideo_host_valid "$host" ;;
    quic) [[ "$profile" = 5 ]] && adaptive_rules_quic_host_valid "$host" ;;
    *) return 1 ;;
  esac
}

adaptive_rules_resolve_runtime_path() {
  local path="$1" zator_root="${ZATOR_ROOT:-/opt/zator}" zapret_root="${ZAPRET2_ROOT:-/opt/zapret2}"
  case "$path" in
    /opt/zator/*) path="$zator_root/${path#/opt/zator/}" ;;
    /opt/zapret2/*) path="$zapret_root/${path#/opt/zapret2/}" ;;
  esac
  printf '%s\n' "$path"
}

adaptive_rules_runtime_dependency_paths() {
  local config="$1"
  [[ -r "$config" && ! -L "$config" ]] || return 0
  awk '
    /^NFQWS2_OPT="[[:space:]]*$/ { inside=1; next }
    inside && /^"[[:space:]]*$/ { inside=0; next }
    !inside { next }
    {
      line=$0
      while (match(line, /--blob=[^[:space:]]+|--lua-init=[^[:space:]]+/)) {
        token=substr(line, RSTART, RLENGTH)
        value=token
        if (token ~ /^--blob=/) sub(/^--blob=[^:]*:@/, "", value)
        else sub(/^--lua-init=@/, "", value)
        if (value != token && value ~ /^\// && !seen[value]++) print value
        line=substr(line, RSTART + RLENGTH)
      }
    }
  ' "$config"
}

# Fingerprint the exact numbered plan from the isolated nfqws2 argv file.
adaptive_strategy_fingerprint() {
  [[ $# -ge 4 && $# -le 6 && "$1" =~ ^[1-5]$ && "$2" =~ ^[1-9][0-9]{0,2}$ && -r "$3" && -x "$4" ]] || return 2
  local profile="$1" strategy="$2" args_file="$3" nfqws="$4" treatment="${5:-standard}" recipe="${6:-tls-http1-v1}"
  local material fingerprint line spec blob_name blob_value blob_path blob_hash lua_path lua_name
  if [[ "$profile" = 2 && "$treatment" != standard && "$recipe" = tls-http1-v1 ]]; then recipe=googlevideo-tcp-media-v1; fi
  case "$recipe:$profile:$treatment" in
    tls-http1-v1:1:standard|tls-http1-v1:2:standard|tls-http1-v1:3:standard|tls-http1-v1:4:standard) ;;
    googlevideo-tcp-media-v1:2:standard|googlevideo-tcp-media-v1:2:gv_tcp_plain|googlevideo-tcp-media-v1:2:gv_tcp_ramp|googlevideo-tcp-media-v1:2:gv_tcp_ramp_syndata) ;;
    googlevideo-quic-h3-media-v1:5:standard) ;;
    *) return 2 ;;
  esac
  material="$(
    printf 'profile=%s\n' "$profile"
    awk -v n="$strategy" '
      /^--lua-desync=/ && $0 ~ ("(^|:)strategy=" n "(:|$)") {
        line=$0
        gsub(/:strategy=[0-9]+/, "", line)
        print line
        found=1
      }
      /^--blob=/ {
        line=$0
        sub(/:@[^[:space:]]+$/, ":@<file>", line)
        print line
      }
      END { if (!found) exit 1 }
    ' "$args_file"
  )" || return 1
  if [[ "${ADAPTIVE_NFQWS_VERSION_BINARY:-}" != "$nfqws" ]]; then
    ADAPTIVE_NFQWS_VERSION="$($nfqws --version 2>&1 | head -n 1)" || return 1
    ADAPTIVE_NFQWS_VERSION_BINARY="$nfqws"
  fi
  material="profile=$profile\nnfqws=${ADAPTIVE_NFQWS_VERSION:-unknown}\n${material#*$'\n'}"
  # Keep legacy TLS fingerprints stable; Googlevideo treatment is part of the
  # tested semantics even when the numbered TLS plan itself is unchanged.
  [[ "$treatment" = standard ]] || material+="\ntreatment=$treatment"
  [[ "$recipe" = tls-http1-v1 ]] || material+="\nrecipe=$recipe"
  if [[ "${ADAPTIVE_FINGERPRINT_DEPENDENCY_ARGS_FILE:-}" != "$args_file" ]]; then
    ADAPTIVE_FINGERPRINT_DEPENDENCY_MATERIAL=''
    while IFS= read -r line; do
      case "$line" in
        --blob=*:*)
          spec="${line#--blob=}"; blob_name="${spec%%:*}"; blob_value="${spec#*:}"
          [[ "$blob_value" = @/* ]] || continue
          blob_path="$(adaptive_rules_resolve_runtime_path "${blob_value#@}")"
          if [[ -f "$blob_path" ]]; then
            blob_hash="$(sha256sum "$blob_path" | awk '{print $1}')" || return 1
          else blob_hash=missing; fi
          ADAPTIVE_FINGERPRINT_DEPENDENCY_MATERIAL+=$'\nblob-content='"$blob_name:$blob_hash"
          ;;
        --lua-init=@/*)
          lua_path="${line#--lua-init=@}"
          lua_name="${lua_path##*/}"
          case "$lua_path" in */probe/locked.lua) lua_path="${ZATOR_ROOT:-/opt/zator}/lua/locked.lua" ;; esac
          lua_path="$(adaptive_rules_resolve_runtime_path "$lua_path")"
          if [[ -f "$lua_path" ]]; then
            blob_hash="$(sha256sum "$lua_path" | awk '{print $1}')" || return 1
          else blob_hash=missing; fi
          ADAPTIVE_FINGERPRINT_DEPENDENCY_MATERIAL+=$'\nlua-content='"$lua_name:$blob_hash"
          ;;
      esac
    done < "$args_file"
    ADAPTIVE_FINGERPRINT_DEPENDENCY_ARGS_FILE="$args_file"
  fi
  material+="${ADAPTIVE_FINGERPRINT_DEPENDENCY_MATERIAL:-}"
  fingerprint="$(printf '%s\n' "$material" | sed -e 's#/opt/zator/#<zator>/#g' -e 's#/opt/zapret2/#<zapret2>/#g' | sha256sum | awk '{print $1}')" || return 1
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  printf 'sha256:%s\n' "$fingerprint"
}

# Reuse numbered fingerprints while their existing runtime stamp is current;
# candidate ordering and local confirmations are still recomputed per request.
adaptive_strategy_fingerprint_catalog() {
  [[ $# = 8 && "$1" =~ ^[1-5]$ && "$2" =~ ^[1-9][0-9]{0,2}$ && -r "$3" && -x "$4" && "$8" = /* ]] || return 2
  local profile="$1" max="$2" args_file="$3" nfqws="$4" treatment="$5" recipe="$6" stamp="$7" cache_dir="$8"
  local version key_material key cache_file tmp number fingerprint
  version="$("$nfqws" --version 2>&1 | head -n 1)" || return 1
  [[ -n "$version" && ${#version} -le 256 ]] || return 1
  key_material="profile=$profile|max=$max|treatment=$treatment|recipe=$recipe|stamp=$stamp|nfqws=$version"
  key="$(printf '%s\n' "$key_material" | sha256sum | awk '{print $1}')" || return 1
  [[ "$key" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ ! -L "$cache_dir" ]] || return 1
  mkdir -p "$cache_dir" || return 1
  chmod 700 "$cache_dir" || return 1
  cache_file="$cache_dir/p${profile}-${recipe}.tsv"
  if [[ -f "$cache_file" && ! -L "$cache_file" ]]; then
    if awk -F '\t' -v key="$key" -v max="$max" '
      NR==1 { if ($0 != key) bad=1; next }
      NF!=2 || $1 != NR-1 || $2 !~ /^sha256:[a-f0-9]{64}$/ { bad=1 }
      END { if (NR != max+1 || bad) exit 1 }
    ' "$cache_file"; then
      tail -n +2 "$cache_file"
      return 0
    fi
  fi
  tmp="$(mktemp "$cache_dir/.catalog.XXXXXX")" || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$key" > "$tmp" || { rm -f "$tmp"; return 1; }
  for ((number=1; number<=max; number++)); do
    fingerprint="$(adaptive_strategy_fingerprint "$profile" "$number" "$args_file" "$nfqws" "$treatment" "$recipe")" || {
      rm -f "$tmp"; return 1;
    }
    printf '%s\t%s\n' "$number" "$fingerprint" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done
  mv -f "$tmp" "$cache_file" || { rm -f "$tmp"; return 1; }
  tail -n +2 "$cache_file"
}

# Produce a stable round-robin order across broad desync families for low-
# priority Explore. Numbered FastSearch keeps its own ranked/local ordering.
adaptive_exploration_strategy_order() {
  [[ $# = 2 && -r "$1" && "$2" =~ ^[1-9][0-9]{0,2}$ ]] || return 2
  awk -v max="$2" '
    /^--lua-desync=/ {
      line=$0
      while (match(line, /--lua-desync=[^[:space:]]+/)) {
        start=RSTART; token_length=RLENGTH
        token=substr(line, start, token_length)
        sub(/^--lua-desync=/, "", token)
        spec=token
        sub(/:strategy=[0-9]+.*/, "", spec)
        method=spec
        sub(/:.*/, "", method)
        strategy=""
        if (match(token, /:strategy=[0-9]+/)) {
          strategy=substr(token, RSTART+10, RLENGTH-10)+0
        }
        if (strategy>0 && strategy<=max && !(strategy in family)) {
          if (method ~ /clone/) name="clone"
          else if (method ~ /^hostfakesplit/) name="hostfakesplit"
          else if (method ~ /multi(split|disorder)/) name="multi"
          else if (method ~ /^fake/) name="fake"
          else if (method ~ /split|disorder/) name="split"
          else name="other"
          family[strategy]=name
        }
        line=substr(line, start+token_length)
      }
    }
    END {
      names[1]="clone"; names[2]="hostfakesplit"; names[3]="multi"
      names[4]="fake"; names[5]="split"; names[6]="other"
      for (i=1;i<=max;i++) {
        name=family[i]
        if (name=="") name="other"
        count[name]++
        item[name, count[name]]=i
      }
      emitted=0
      while (emitted<max) {
        progress=0
        for (f=1;f<=6;f++) {
          name=names[f]
          if (cursor[name]<count[name]) {
            cursor[name]++
            print item[name, cursor[name]]
            emitted++; progress=1
          }
        }
        if (!progress) exit 1
      }
    }
  ' "$1"
}

adaptive_rules_daemon_owner() {
  local config="${ZAPRET2_ROOT:-/opt/zapret2}/config" user uid gid
  user="$(awk -F= '$1=="WS_USER" {gsub(/["[:space:]]/, "", $2); print $2; exit}' "$config" 2>/dev/null)"
  [[ -n "$user" ]] || return 1
  uid="$(id -u "$user" 2>/dev/null)"; gid="$(id -g "$user" 2>/dev/null)"
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
  printf '%s:%s\n' "$uid" "$gid"
}

adaptive_rules_runtime_stamp() {
  local config="$1" binary="$2" orch_dir="$3" zator_root="${ZATOR_ROOT:-/opt/zator}" path value first=1 dependency_path
  local -A runtime_seen=()
  for path in \
    "$config" "$binary" "${ZAPRET2_ROOT:-/opt/zapret2}/lua/zapret-lib.lua" \
    "${ZAPRET2_ROOT:-/opt/zapret2}/lua/zapret-antidpi.lua" "${ZAPRET2_ROOT:-/opt/zapret2}/lua/zapret-auto.lua" \
    "$orch_dir/blob_override.tsv" "$orch_dir/sni_override.tsv" \
    "$orch_dir/mode_override.tsv" "$orch_dir/clonesize.tsv" "$orch_dir/custom_strategies.tsv" \
    "$zator_root/lua/client-scope-config.lua" "$zator_root/lua/locked.lua" \
    "$zator_root/lua/rst-guard.lua" "$zator_root/lua/strategy-lock-manager.lua" \
    "$zator_root/lua/combined-detector.lua" "$zator_root/lua/silent-drop-detector.lua" \
    "$zator_root/lua/dns-clone.lua" "$zator_root/lua/fake-adapt.lua" "$zator_root/lua/wssize-ramp.lua" \
    "$zator_root/z2r_lib/adaptive_rules.sh" "$zator_root/z2r_lib/adaptive_media.sh" \
    "$zator_root/z2r_lib/youtube_media.sh" "$zator_root/z2r_lib/supersweep_probe.sh" \
    "$zator_root/tools/adaptive-controller.sh"; do
    runtime_seen["$path"]=1
    value="$(stat -c '%Y:%s' "$path" 2>/dev/null)" || value=0:0
    [[ "$value" =~ ^[0-9]+:[0-9]+$ ]] || value=0:0
    if (( first )); then printf '%s' "$value"; first=0; else printf '|%s' "$value"; fi
  done
  while IFS= read -r dependency_path; do
    path="$(adaptive_rules_resolve_runtime_path "$dependency_path")"
    [[ ! ${runtime_seen[$path]+yes} ]] || continue
    runtime_seen["$path"]=1
    value="$(stat -c '%Y:%s' "$path" 2>/dev/null)" || value=0:0
    [[ "$value" =~ ^[0-9]+:[0-9]+$ ]] || value=0:0
    if (( first )); then printf '%s' "$value"; first=0; else printf '|%s' "$value"; fi
  done < <(adaptive_rules_runtime_dependency_paths "$config")
  printf '\n'
}

adaptive_rules_invalidate() {
  local file dir lock tmp snapshot generation tries=0
  file="$(adaptive_rules_file)"; dir="$(dirname "$file")"; lock="$file.lock"
  snapshot="$(adaptive_rules_snapshot_file)"
  mkdir -p "$dir" "$(dirname "$snapshot")" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 20 )) || return 1
    sleep 0.1
  done
  generation="$dir/generation"
  tmp="$generation.tmp.$$.$RANDOM"
  printf '%s-%s-%s\n' "$(date +%s)" "$$" "$RANDOM" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$generation" || {
    rm -f "$tmp"; rmdir "$lock" 2>/dev/null || :; return 1;
  }
  rm -f "$file" "$snapshot" "$snapshot.tmp."* "$dir/snapshot-at" 2>/dev/null || {
    rmdir "$lock" 2>/dev/null || :; return 1;
  }
  rmdir "$lock" || return 1
  adaptive_router_trials_reset || return 1
}

adaptive_router_trials_reset() {
  local events="${Z2R_ADAPTIVE_EVENTS_FILE:-${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}/events.tsv}"
  local dir tmp owner mode
  [ -e "$events" ] || return 0
  [ -f "$events" ] && [ ! -L "$events" ] && [ -r "$events" ] || return 1
  (( $(wc -c < "$events") <= 65536 )) || return 1
  dir="$(dirname "$events")"
  owner="$(stat -c '%u:%g' "$events" 2>/dev/null)"
  mode="$(stat -c '%a' "$events" 2>/dev/null)"
  [[ "$owner" =~ ^[0-9]+:[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  tmp="$(mktemp "$dir/.events-reset.XXXXXX")" || return 1
  awk -F '\t' 'BEGIN { OFS="\t" }
    NR<=128 && (NF==8 || NF==9 || NF==10 || NF==11) && $1==1 && ($2 ~ /^router_trial_[1-9][0-9]?[0-9]?$/ || $2=="router_exhausted") { $2="seen"; if (NF>=9) $9=0 }
    { print }
  ' "$events" > "$tmp" || { rm -f "$tmp"; return 1; }
  chown "$owner" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$events" || {
    rm -f "$tmp"; return 1;
  }
}

adaptive_rules_runtime_reset() {
  local file lock tries=0
  file="$(adaptive_rules_file)"; lock="$file.lock"
  mkdir -p "$(dirname "$file")" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 20 )) || return 1
    sleep 0.1
  done
  rm -f "$file" || { rmdir "$lock" 2>/dev/null || :; return 1; }
  rmdir "$lock" || return 1
  adaptive_router_trials_reset || return 1
}

adaptive_rules_snapshot() {
  local file snapshot lock tmp row count=0 tries=0 dir timestamp owner
  file="$(adaptive_rules_file)"; snapshot="$(adaptive_rules_snapshot_file)"
  dir="$(dirname "$file")"; lock="$file.lock"
  [[ -f "$file" && ! -L "$file" ]] || return 0
  mkdir -p "$(dirname "$snapshot")" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 50 )) || return 1
    sleep 0.1
  done
  tmp="$(mktemp "$snapshot.tmp.XXXXXX")" || { rmdir "$lock"; return 1; }
  : > "$tmp" || { rmdir "$lock"; return 1; }
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    count=$((count + 1)); (( count <= 256 )) || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    printf '%s\n' "$row" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  done < "$file"
  owner="$(adaptive_rules_daemon_owner 2>/dev/null || true)"
  if [[ -n "$owner" ]]; then
    chown "$owner" "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    if [[ "$(id -u)" = 0 ]]; then
      chown 0:0 "$(dirname "$snapshot")" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    fi
    chmod 711 "$(dirname "$snapshot")" || {
      rm -f "$tmp"; rmdir "$lock"; return 1;
    }
  else
    chmod 711 "$(dirname "$snapshot")" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  fi
  chmod 600 "$tmp" && mv -f "$tmp" "$snapshot" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  timestamp="$dir/snapshot-at.tmp.$$.$RANDOM"
  date +%s > "$timestamp" && chmod 600 "$timestamp" && mv -f "$timestamp" "$dir/snapshot-at" || {
    rm -f "$timestamp"; rmdir "$lock"; return 1;
  }
  rmdir "$lock" || return 1
}

adaptive_rules_schedule_snapshot() {
  local file dir pending generation delay interval last now remaining
  file="$(adaptive_rules_file)"; dir="$(dirname "$file")"
  mkdir -p "$dir" || return 1
  generation="$(cat "$dir/generation" 2>/dev/null || printf '0')"
  pending="$dir/snapshot-pending.$generation"
  (umask 077; mkdir "$pending") 2>/dev/null || return 0
  delay="${Z2R_ADAPTIVE_SNAPSHOT_DELAY:-60}"
  [[ "$delay" =~ ^[0-9]{1,3}$ ]] || delay=60
  interval="${Z2R_ADAPTIVE_SNAPSHOT_INTERVAL:-300}"
  [[ "$interval" =~ ^[0-9]{1,5}$ ]] || interval=300
  last="$(cat "$dir/snapshot-at" 2>/dev/null)"
  now="$(date +%s)"
  if [[ "$last" =~ ^[0-9]{1,10}$ ]] && (( now >= last && now - last < interval )); then
    remaining=$((interval - (now - last)))
    (( remaining > delay )) && delay="$remaining"
  fi
  (
    trap 'rmdir "$pending" 2>/dev/null || :' EXIT HUP INT TERM
    sleep "$delay"
    [[ "$(cat "$dir/generation" 2>/dev/null || printf '0')" = "$generation" ]] || exit 0
    adaptive_rules_snapshot
  ) </dev/null >/dev/null 2>&1 &
}

# Count semantic A-B-A runtime-rule reversals without retaining raw targets.
# adaptive_rule_add holds the rule-store lock while calling this writer.
adaptive_rules_flipflop_file() {
  printf '%s\n' "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/flipflops.tsv"
}

adaptive_rules_flipflop_record() {
  [[ $# = 7 ]] || return 2
  local host="${1,,}" ip="$2" profile="$3" proto="$4" scope="$5" previous="$6" current="$7"
  local key now file dir tmp
  [[ "$previous" =~ ^sha256:[a-f0-9]{64}$ && "$current" =~ ^sha256:[a-f0-9]{64}$ && "$previous" != "$current" ]] || return 0
  key="$(printf '%s\n' "$host|$ip|$profile|$proto|$scope" | sha256sum | awk '{print $1}')" || return 1
  [[ "$key" =~ ^[a-f0-9]{64}$ ]] || return 1
  now="$(date +%s)" || return 1
  file="$(adaptive_rules_flipflop_file)"; dir="$(dirname "$file")"
  [[ ! -L "$dir" ]] || return 1
  mkdir -p "$dir" || return 1
  [[ -d "$dir" && ! -L "$dir" && ! -L "$file" ]] || return 1
  if [[ ! -e "$file" ]]; then (umask 077; : > "$file") || return 1; chmod 600 "$file" || return 1; fi
  tmp="$(mktemp "$dir/.flipflops.XXXXXX")" || return 1
  awk -F '\t' -v OFS='\t' -v key="$key" -v old="$previous" -v new="$current" -v now="$now" \
    -v total_key="0000000000000000000000000000000000000000000000000000000000000000" \
    -v zero_fp="sha256:0000000000000000000000000000000000000000000000000000000000000000" '
    BEGIN { found=0; total_found=0; total=0; added=0 }
    NF==6 && $1==1 && $2 ~ /^[a-f0-9]{64}$/ && $3 ~ /^sha256:[a-f0-9]{64}$/ &&
      $4 ~ /^sha256:[a-f0-9]{64}$/ && $5 ~ /^(0|[1-9][0-9]{0,5})$/ && $6 ~ /^[0-9]{1,10}$/ {
      if ($2==total_key) {
        total_found=1
        total=$5+0
        next
      }
      if (!total_found) total += $5+0
      if ($2==key) {
        found=1
        flips=$5+0
        prior=$3; latest=$4
        if ($6+0>=now-7776000 && $6+0<=now+60 && latest==old) {
          if (prior==new && latest!=new) {
            if (flips<999999) flips++
            added=1
          }
        } else {
          prior=old
        }
        replacement="1" OFS key OFS prior OFS new OFS flips OFS now
        next
      }
      rows[++n]=$0
    }
    END {
      if (!found) replacement="1" OFS key OFS old OFS new OFS "0" OFS now
      for (i=1; i<=n; i++) if (i>n-254) print rows[i]
      print replacement
      if (total>999999999) total=999999999
      if (added && total<999999999) total++
      print "1" OFS total_key OFS zero_fp OFS zero_fp OFS total OFS now
    }
  ' "$file" 2>/dev/null > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

adaptive_rules_flipflop_total() {
  local file size
  file="$(adaptive_rules_flipflop_file)"
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || { printf '0\n'; return 0; }
  size="$(wc -c < "$file" 2>/dev/null)"
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 65536 ]] || { printf '0\n'; return 0; }
  awk -F '\t' '
    NF==6 && $1==1 && $2 ~ /^[a-f0-9]{64}$/ && $3 ~ /^sha256:[a-f0-9]{64}$/ && $4 ~ /^sha256:[a-f0-9]{64}$/ && $5 ~ /^(0|[1-9][0-9]{0,9})$/ {
      if ($2=="0000000000000000000000000000000000000000000000000000000000000000") {global=$5+0; found=1}
      else legacy += $5+0
    }
    END {total=found ? global : legacy; if (total>999999999) total=999999999; printf "%.0f\n", total+0}
  ' "$file"
}

adaptive_rule_add() {
  [[ $# = 10 || $# = 11 ]] || return 2
  local host="${1,,}" ip="$2" profile="$3" proto="$4" scope="$5"
  local strategy="$6" fingerprint="$7" catalog="$8" runtime_stamp="$9" expires="${10}"
  local rule_origin="${11:-}"
  local now file dir lock tmp row count=0 lock_tries=0 snapshot source_file owner previous_fingerprint=""
  [[ ( "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ || ( "$proto" = googlevideo-tcp && "$host" = googlevideo.com ) ) && ${#host} -le 253 ]] || return 2
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 2
  awk -F. 'NF==4 {
    for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || $i>255 || ($i ~ /^0[0-9]+$/)) exit 1
    a=$1+0; b=$2+0; c=$3+0
    if(a==0 || a==10 || a==127 || a>=224 || (a==100 && b>=64 && b<=127) ||
       (a==169 && b==254) || (a==172 && b>=16 && b<=31) ||
       (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) ||
       (a==198 && (b==18 || b==19 || (b==51 && c==100))) || (a==203 && b==0 && c==113)) exit 1
    exit 0
  } {exit 1}' <<< "$ip" || return 2
  [[ ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 && "$(adaptive_rules_googlevideo_host_valid "$host" && printf yes)" = yes ) ) || ( "$profile" = 5 && "$proto" = quic ) ) && ( "$scope" = default || "$scope" =~ ^mark:[0-9]{1,5}$ || ( "$scope" = shared && "$rule_origin" = browser-confirmed ) ) ]] || return 2
  [[ "$proto" != quic ]] || adaptive_rules_quic_host_valid "$host" || return 2
  [[ "$strategy" =~ ^(0|[1-9][0-9]{0,2})$ && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" =~ ^sha256:[a-f0-9]{64}$ ]] || return 2
  [[ "$runtime_stamp" =~ ^[0-9:|]{1,2048}$ ]] || return 2
  [[ "$expires" =~ ^[1-9][0-9]{0,9}$ ]] || return 2
  now="$(date +%s)" || return 1
  (( expires > now && expires <= now + 604800 )) || return 2
  file="$(adaptive_rules_file)"; dir="$(dirname "$file")"; lock="$file.lock"
  snapshot="$(adaptive_rules_snapshot_file)"
  mkdir -p "$dir" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do
    lock_tries=$((lock_tries + 1)); (( lock_tries < 20 )) || return 1
    sleep 0.1
  done
  tmp="$file.tmp.$$.$RANDOM"
  : > "$tmp" || { rmdir "$lock"; return 1; }
  source_file="$file"
  [[ -e "$source_file" ]] || source_file="$snapshot"
  if [[ -r "$source_file" ]]; then
    while IFS= read -r row; do
      IFS=$'\t' read -r ver old_host old_ip old_profile old_proto old_scope old_strategy old_fp old_catalog old_stamp old_expiry extra <<< "$row"
      [[ "$ver" = 1 && -z "${extra:-}" && "$old_expiry" =~ ^[0-9]{1,10}$ ]] || continue
      (( old_expiry > now )) || continue
      if [[ "$old_host" = "$host" && "$old_profile" = "$profile" && "$old_proto" = "$proto" && "$old_scope" = "$scope" ]]; then
        [[ "$old_fp" =~ ^sha256:[a-f0-9]{64}$ ]] && previous_fingerprint="$old_fp"
        continue
      fi
      count=$((count + 1))
      printf '%s\n' "$row" >> "$tmp"
    done < "$source_file"
  fi
  if (( count >= 256 )); then rm -f "$tmp"; rmdir "$lock"; return 1; fi
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$host" "$ip" "$profile" "$proto" "$scope" "$strategy" "$fingerprint" "$catalog" "$runtime_stamp" "$expires" >> "$tmp" || {
      rm -f "$tmp"; rmdir "$lock"; return 1;
    }
  owner="$(adaptive_rules_daemon_owner 2>/dev/null || true)"
  if [[ -n "$owner" ]]; then chown "$owner" "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }; fi
  chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  if [[ -n "$previous_fingerprint" && "$previous_fingerprint" != "$fingerprint" ]]; then
    adaptive_rules_flipflop_record "$host" "$ip" "$profile" "$proto" "$scope" "$previous_fingerprint" "$fingerprint" || :
  fi
  rmdir "$lock" || return 1
  adaptive_rules_schedule_snapshot || :
}

# Remove one exact adaptive tuple from the runtime store (and its snapshot).
adaptive_rule_remove() {
  [[ $# = 4 || $# = 5 ]] || return 2
  local host="${1,,}" ip="$2" profile="$3" scope="$4" proto="${5:-tls}"
  local file dir lock snapshot source tmp row ver old_host old_ip old_profile old_proto old_scope old_strategy old_fp old_catalog old_stamp old_expiry extra tries=0 owner removed=0 count=0
  [[ ( "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ || ( "$proto" = googlevideo-tcp && "$host" = googlevideo.com ) ) && ${#host} -le 253 ]] || return 2
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 && "$(adaptive_rules_googlevideo_host_valid "$host" && printf yes)" = yes ) ) ) || ( "$profile" = 5 && "$proto" = quic ) ) && ( "$scope" = default || "$scope" = shared || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) ]] || return 2
  [[ "$proto" != quic ]] || adaptive_rules_quic_host_valid "$host" || return 2
  file="$(adaptive_rules_file)"; dir="$(dirname "$file")"; lock="$file.lock"; snapshot="$(adaptive_rules_snapshot_file)"
  mkdir -p "$dir" "$(dirname "$snapshot")" || return 1
  while ! (umask 077; mkdir "$lock") 2>/dev/null; do
    tries=$((tries + 1)); (( tries < 20 )) || return 1
    sleep 0.1
  done
  source="$file"; [[ -r "$source" ]] || source="$snapshot"
  tmp="$file.tmp.$$.$RANDOM"
  : > "$tmp" || { rmdir "$lock"; return 1; }
  if [[ -r "$source" && ! -L "$source" ]]; then
    while IFS= read -r row; do
      count=$((count + 1)); (( count <= 256 )) || { rm -f "$tmp"; rmdir "$lock"; return 1; }
      IFS=$'\t' read -r ver old_host old_ip old_profile old_proto old_scope old_strategy old_fp old_catalog old_stamp old_expiry extra <<< "$row"
      if [[ "$ver" = 1 && "$old_host" = "$host" && "$old_profile" = "$profile" && "$old_proto" = "$proto" && "$old_scope" = "$scope" && -z "${extra:-}" ]]; then
        removed=1; continue
      fi
      printf '%s\n' "$row" >> "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    done < "$source"
  fi
  if (( removed )); then
    owner="$(adaptive_rules_daemon_owner 2>/dev/null || true)"
    [[ -z "$owner" ]] || chown "$owner" "$tmp" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
    chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; rmdir "$lock"; return 1; }
  else
    rm -f "$tmp"
  fi
  rmdir "$lock" || return 1
  (( removed )) && adaptive_rules_schedule_snapshot || :
  return $((1 - removed))
}

# Return a still-valid exact local result as TSV only when its runtime stamp
# matches the installed config/binary/Lua set. Conflicting matches are ignored.
adaptive_rule_lookup_local() {
  [[ $# = 6 ]] || return 2
  local host="${1,,}" ip="$2" profile="$3" proto="$4" scope="$5" stamp="$6"
  local file snapshot row ver old_host old_ip old_profile old_proto old_scope strategy fp catalog old_stamp expiry extra now found_value current_value conflict=0
  local found='' found_scope='' matches=0 shared_found='' shared_found_value='' shared_matches=0 count=0
  [[ "$proto" != quic ]] || adaptive_rules_quic_host_valid "$host" || return 2
  file="$(adaptive_rules_file)"; snapshot="$(adaptive_rules_snapshot_file)"
  [[ -f "$file" && ! -L "$file" ]] || file="$snapshot"
  [[ -r "$file" && ! -L "$file" ]] || return 1
  now="$(date +%s)" || return 1
  while IFS= read -r row; do
    count=$((count + 1)); (( count <= 256 )) || return 1
    IFS=$'\t' read -r ver old_host old_ip old_profile old_proto old_scope strategy fp catalog old_stamp expiry extra <<< "$row"
    [[ "$ver" = 1 && -z "${extra:-}" && ( "$old_host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ || ( "$old_proto" = googlevideo-tcp && "$old_host" = googlevideo.com ) ) &&
       "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( ( "$old_profile" =~ ^[1-4]$ && ( "$old_proto" = tls || ( "$old_proto" = googlevideo-tcp && "$old_profile" = 2 && "$(adaptive_rules_googlevideo_host_valid "$old_host" && printf yes)" = yes ) ) ) || ( "$old_profile" = 5 && "$old_proto" = quic ) ) &&
       ( "$old_scope" = default || "$old_scope" = shared || "$old_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$strategy" =~ ^(0|[1-9][0-9]{0,2})$ &&
       "$fp" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" =~ ^sha256:[a-f0-9]{64}$ && "$expiry" =~ ^[1-9][0-9]{0,9}$ ]] || continue
    [[ "$old_host" = "$host" && "$old_profile" = "$profile" && "$old_proto" = "$proto" &&
       ( "$old_scope" = "$scope" || ( "$scope" = default && "$old_scope" = shared ) ) && "$old_stamp" = "$stamp" ]] || continue
    (( expiry > now )) || continue
    if [[ "$old_scope" = "$scope" ]]; then
      current_value="${strategy}\t${fp}\t${catalog}\t${old_stamp}"
      if (( matches )); then [[ "$current_value" = "$found_value" ]] || conflict=1
      else found_value="$current_value"; found="${strategy}\t${fp}\t${catalog}\t${expiry}"; fi
      matches=$((matches + 1))
      found_scope="$old_scope"
    else
      current_value="${strategy}\t${fp}\t${catalog}\t${old_stamp}"
      if (( shared_matches )); then [[ "$current_value" = "$shared_found_value" ]] || conflict=1
      else shared_found_value="$current_value"; shared_found="${strategy}\t${fp}\t${catalog}\t${expiry}"; fi
      shared_matches=$((shared_matches + 1))
    fi
  done < "$file"
  (( conflict == 0 )) || return 1
  if (( matches > 0 )); then printf '%b\t%s\n' "$found" "$found_scope"; return 0; fi
  (( shared_matches > 0 )) || return 1
  printf '%b\tshared\n' "$shared_found"
}

# Remove an adaptive rule only when a route-verified failure reproduces the
# currently stored strategy identity. A failed search candidate cannot evict a
# different active strategy for the same tuple.
adaptive_rule_remove_if_matches() {
  [[ $# = 8 ]] || return 2
  local host="$1" ip="$2" profile="$3" proto="$4" scope="$5" strategy="$6" fingerprint="$7" stamp="$8"
  local current current_strategy current_fingerprint current_catalog current_expiry current_scope
  adaptive_rules_kind_valid "$profile" "$proto" "$host" || return 2
  [[ "$strategy" =~ ^(0|[1-9][0-9]{0,2})$ && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ ]] || return 2
  current="$(adaptive_rule_lookup_local "$host" "$ip" "$profile" "$proto" "$scope" "$stamp")" || return 1
  IFS=$'\t' read -r current_strategy current_fingerprint current_catalog current_expiry current_scope <<< "$current"
  [[ "$current_strategy" = "$strategy" && "$current_fingerprint" = "$fingerprint" ]] || return 1
  adaptive_rule_remove "$host" "$ip" "$profile" "$current_scope" "$proto"
}

# List locally confirmed strategies for a profile/scope, most frequent first.
# Only rows from the current runtime stamp and a single matching catalog are
# eligible. This is a bounded local ranking hint, never an apply decision.
adaptive_rules_googlevideo_group_id() {
  [[ $# = 1 ]] || return 2
  local host="${1,,}"
  host="${host%.}"
  adaptive_rules_googlevideo_host_valid "$host" && [[ ${#host} -le 253 ]] || return 2
  if [[ ! "$host" =~ (^|\.)googlevideo\.com$ ]]; then printf 'exact:%s\n' "$host"; return; fi
  if [[ "$host" =~ ^rr[0-9]+-(.+)\.googlevideo\.com$ ]]; then printf 'gv1:rr:%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$host" =~ ^r[0-9]+(---sn-[a-z0-9-]+)\.googlevideo\.com$ ]]; then printf 'gv1:r:%s\n' "${BASH_REMATCH[1]}"
  else printf 'exact:%s\n' "$host"; fi
}

adaptive_rules_ranked_candidates() {
  [[ $# = 5 || $# = 6 ]] || return 2
  local profile="$1" proto="$2" scope="$3" stamp="$4" max="$5" identity="${6:-}"
  local file snapshot row ver host ip old_profile old_proto old_scope strategy fp catalog old_stamp expiry extra now catalog_seen row_identity pair remaining exact_host exact_ip
  local -A scores=() seen_catalog=() seen_pairs=()
  local best_score=0 best_ties=0
  [[ ( "$profile" =~ ^[1-4]$ && ( "$proto" = tls || ( "$proto" = googlevideo-tcp && "$profile" = 2 ) ) || ( "$profile" = 5 && "$proto" = quic ) ) && ( "$scope" = default || "$scope" =~ ^mark:[0-9]{1,5}$ ) && "$stamp" =~ ^[0-9:|]{1,2048}$ && "$max" =~ ^[1-9][0-9]{0,2}$ ]] || return 2
  [[ -z "$identity" || "$identity" =~ ^(gv1:(rr|r):[a-z0-9.-]+|exact:[a-z0-9.-]+|exactip:[a-z0-9.-]+:[0-9.]+)$ ]] || return 2
  if [[ "$identity" = exactip:* ]]; then
    exact_host="${identity#exactip:}"; exact_ip="${exact_host##*:}"; exact_host="${exact_host%:*}"
    [[ "$exact_host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ &&
       "$exact_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 2
  fi
  file="$(adaptive_rules_file)"; snapshot="$(adaptive_rules_snapshot_file)"
  [[ -f "$file" && ! -L "$file" ]] || file="$snapshot"
  [[ -r "$file" && ! -L "$file" ]] || return 0
  now="$(date +%s)" || return 1
  local -a rows=()
  while IFS= read -r row; do
    rows+=("$row"); (( ${#rows[@]} <= 256 )) || return 1
  done < "$file"
  # Avoid combining catalogs when a remap/update was observed during writes.
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r ver host ip old_profile old_proto old_scope strategy fp catalog old_stamp expiry extra <<< "$row"
    [[ "$ver" = 1 && -z "${extra:-}" && "$old_profile" = "$profile" && "$old_proto" = "$proto" &&
       ( "$old_scope" = "$scope" || ( "$scope" = default && "$old_scope" = shared ) ) &&
       "$(adaptive_rules_kind_valid "$old_profile" "$old_proto" "$host" && printf valid)" = valid &&
       "$strategy" =~ ^[1-9][0-9]{0,2}$ && "$fp" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" =~ ^sha256:[a-f0-9]{64}$ &&
       "$old_stamp" = "$stamp" && "$expiry" =~ ^[1-9][0-9]{0,9}$ ]] || continue
    if [[ "$identity" = exactip:* ]]; then [[ "$host" = "$exact_host" && "$ip" = "$exact_ip" ]] || continue
    elif [[ -n "$identity" ]]; then row_identity="$(adaptive_rules_googlevideo_group_id "$host" 2>/dev/null)" || continue; [[ "$row_identity" = "$identity" ]] || continue; fi
    (( expiry > now )) || continue
    seen_catalog["$catalog"]=1
  done
  (( ${#seen_catalog[@]} == 1 )) || return 0
  catalog_seen="${!seen_catalog[@]}"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r ver host ip old_profile old_proto old_scope strategy fp catalog old_stamp expiry extra <<< "$row"
    [[ "$ver" = 1 && -z "${extra:-}" && "$old_profile" = "$profile" && "$old_proto" = "$proto" &&
       ( "$old_scope" = "$scope" || ( "$scope" = default && "$old_scope" = shared ) ) &&
       "$(adaptive_rules_kind_valid "$old_profile" "$old_proto" "$host" && printf valid)" = valid &&
       "$strategy" =~ ^[1-9][0-9]{0,2}$ && "$fp" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" = "$catalog_seen" &&
       "$old_stamp" = "$stamp" && "$expiry" =~ ^[1-9][0-9]{0,9}$ ]] || continue
    if [[ "$identity" = exactip:* ]]; then [[ "$host" = "$exact_host" && "$ip" = "$exact_ip" ]] || continue
    elif [[ -n "$identity" ]]; then row_identity="$(adaptive_rules_googlevideo_group_id "$host" 2>/dev/null)" || continue; [[ "$row_identity" = "$identity" ]] || continue; fi
    (( expiry > now )) || continue
    pair="$host|$ip"
    [[ ! ${seen_pairs[$pair]+yes} ]] || continue
    seen_pairs[$pair]=1
    remaining=$((expiry - now))
    # Rule TTL is currently fifteen minutes; remaining lifetime is a bounded proxy
    # for confirmation recency and keeps old snapshots from dominating groups.
    (( remaining > 900 )) && remaining=900
    scores["$strategy"]=$(( ${scores[$strategy]:-0} + remaining ))
  done
  # A tied group result is conflicting evidence, not a reason to prefer the
  # numerically smaller strategy. Leave the normal catalog order intact until
  # a distinct fresh host/IP confirmation breaks the tie.
  if [[ -n "$identity" ]]; then
    for strategy in "${!scores[@]}"; do
      if (( scores[$strategy] > best_score )); then best_score=${scores[$strategy]}; best_ties=1
      elif (( scores[$strategy] == best_score )); then best_ties=$((best_ties + 1)); fi
    done
    (( best_ties <= 1 )) || return 0
  fi
  for strategy in "${!scores[@]}"; do printf '%s\t%s\n' "${scores[$strategy]}" "$strategy"; done | sort -rn -k1,1 -k2,2n | awk -F '\t' -v m="$max" 'NR<=m {print $2}'
}
