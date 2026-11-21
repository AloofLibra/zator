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
  [[ $# = 4 && "$1" =~ ^[1-4]$ && "$2" =~ ^[1-9][0-9]{0,2}$ && -r "$3" && -x "$4" ]] || return 2
  local profile="$1" strategy="$2" args_file="$3" nfqws="$4" material fingerprint line spec blob_name blob_value blob_path blob_hash lua_path lua_name
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
    "$zator_root/z2r_lib/adaptive_rules.sh" "$zator_root/z2r_lib/supersweep_probe.sh" \
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

adaptive_rule_add() {
  [[ $# = 10 ]] || return 2
  local host="${1,,}" ip="$2" profile="$3" proto="$4" scope="$5"
  local strategy="$6" fingerprint="$7" catalog="$8" runtime_stamp="$9" expires="${10}"
  local now file dir lock tmp row count=0 lock_tries=0 snapshot source_file owner
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#host} -le 253 ]] || return 2
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
  [[ "$profile" =~ ^[1-4]$ && "$proto" = tls && ( "$scope" = default || "$scope" =~ ^mark:[0-9]{1,5}$ ) ]] || return 2
  [[ "$strategy" =~ ^[1-9][0-9]{0,2}$ && "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" =~ ^sha256:[a-f0-9]{64}$ ]] || return 2
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
      if [[ "$old_host" = "$host" && "$old_ip" = "$ip" && "$old_profile" = "$profile" && "$old_proto" = "$proto" && "$old_scope" = "$scope" ]]; then
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
  rmdir "$lock" || return 1
  adaptive_rules_schedule_snapshot || :
}

# Remove one exact adaptive tuple from the runtime store (and its snapshot).
adaptive_rule_remove() {
  [[ $# = 4 ]] || return 2
  local host="${1,,}" ip="$2" profile="$3" scope="$4"
  local file dir lock snapshot source tmp row ver old_host old_ip old_profile old_proto old_scope old_strategy old_fp old_catalog old_stamp old_expiry extra tries=0 owner removed=0 count=0
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#host} -le 253 ]] || return 2
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$profile" =~ ^[1-4]$ && ( "$scope" = default || "$scope" =~ ^mark:[1-9][0-9]{0,4}$ ) ]] || return 2
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
      if [[ "$ver" = 1 && "$old_host" = "$host" && "$old_ip" = "$ip" && "$old_profile" = "$profile" && "$old_proto" = tls && "$old_scope" = "$scope" && -z "${extra:-}" ]]; then
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
  local file snapshot row ver old_host old_ip old_profile old_proto old_scope strategy fp catalog old_stamp expiry extra now
  local found='' matches=0 count=0
  file="$(adaptive_rules_file)"; snapshot="$(adaptive_rules_snapshot_file)"
  [[ -f "$file" && ! -L "$file" ]] || file="$snapshot"
  [[ -r "$file" && ! -L "$file" ]] || return 1
  now="$(date +%s)" || return 1
  while IFS= read -r row; do
    count=$((count + 1)); (( count <= 256 )) || return 1
    IFS=$'\t' read -r ver old_host old_ip old_profile old_proto old_scope strategy fp catalog old_stamp expiry extra <<< "$row"
    [[ "$ver" = 1 && -z "${extra:-}" && "$old_host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ &&
       "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$old_profile" =~ ^[1-4]$ && "$old_proto" = tls &&
       ( "$old_scope" = default || "$old_scope" =~ ^mark:[1-9][0-9]{0,4}$ ) && "$strategy" =~ ^[1-9][0-9]{0,2}$ &&
       "$fp" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" =~ ^sha256:[a-f0-9]{64}$ && "$expiry" =~ ^[1-9][0-9]{0,9}$ ]] || continue
    [[ "$old_host" = "$host" && "$old_ip" = "$ip" && "$old_profile" = "$profile" && "$old_proto" = "$proto" &&
       "$old_scope" = "$scope" && "$old_stamp" = "$stamp" ]] || continue
    (( expiry > now )) || continue
    matches=$((matches + 1))
    found="${strategy}\t${fp}\t${catalog}\t${expiry}"
  done < "$file"
  (( matches == 1 )) || return 1
  printf '%b\n' "$found"
}

# List locally confirmed strategies for a profile/scope, most frequent first.
# Only rows from the current runtime stamp and a single matching catalog are
# eligible. This is a bounded local ranking hint, never an apply decision.
adaptive_rules_ranked_candidates() {
  [[ $# = 5 ]] || return 2
  local profile="$1" proto="$2" scope="$3" stamp="$4" max="$5"
  local file snapshot row ver host ip old_profile old_proto old_scope strategy fp catalog old_stamp expiry extra now catalog_seen
  local -A counts=() seen_catalog=()
  [[ "$profile" =~ ^[1-4]$ && "$proto" = tls && ( "$scope" = default || "$scope" =~ ^mark:[0-9]{1,5}$ ) && "$stamp" =~ ^[0-9:|]{1,2048}$ && "$max" =~ ^[1-9][0-9]{0,2}$ ]] || return 2
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
    [[ "$ver" = 1 && -z "${extra:-}" && "$old_profile" = "$profile" && "$old_proto" = "$proto" && "$old_scope" = "$scope" &&
       "$strategy" =~ ^[1-9][0-9]{0,2}$ && "$fp" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" =~ ^sha256:[a-f0-9]{64}$ &&
       "$old_stamp" = "$stamp" && "$expiry" =~ ^[1-9][0-9]{0,9}$ ]] || continue
    (( expiry > now )) || continue
    seen_catalog["$catalog"]=1
  done
  (( ${#seen_catalog[@]} == 1 )) || return 0
  catalog_seen="${!seen_catalog[@]}"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r ver host ip old_profile old_proto old_scope strategy fp catalog old_stamp expiry extra <<< "$row"
    [[ "$ver" = 1 && -z "${extra:-}" && "$old_profile" = "$profile" && "$old_proto" = "$proto" && "$old_scope" = "$scope" &&
       "$strategy" =~ ^[1-9][0-9]{0,2}$ && "$fp" =~ ^sha256:[a-f0-9]{64}$ && "$catalog" = "$catalog_seen" &&
       "$old_stamp" = "$stamp" && "$expiry" =~ ^[1-9][0-9]{0,9}$ ]] || continue
    (( expiry > now )) || continue
    counts["$strategy"]=$(( ${counts[$strategy]:-0} + 1 ))
  done
  for strategy in "${!counts[@]}"; do printf '%s\t%s\n' "${counts[$strategy]}" "$strategy"; done | sort -rn -k1,1 -k2,2n | awk -F '\t' -v m="$max" 'NR<=m {print $2}'
}
