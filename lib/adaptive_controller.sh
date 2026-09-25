# Optional static shadow-controller installer helpers.
# No download, process start, or config change happens when this file is sourced.

adaptive_controller_target() {
  local machine="${Z2R_ADAPTIVE_UNAME_M:-$(uname -m 2>/dev/null)}"
  case "$machine" in
    aarch64|arm64) printf '%s\n' aarch64-unknown-linux-musl ;;
    armv6l|armv7l|armv8l) printf '%s\n' armv6-unknown-linux-musleabi ;;
    i586|i686|i786) printf '%s\n' i586-unknown-linux-musl ;;
    x86_64|amd64) printf '%s\n' x86_64-unknown-linux-musl ;;
    mips) printf '%s\n' mips-unknown-linux-muslsf ;;
    mipsel|mipsle) printf '%s\n' mipsel-unknown-linux-muslsf ;;
    mips64) printf '%s\n' mips64-unknown-linux-musl ;;
    mips64el|mips64le) printf '%s\n' mips64el-unknown-linux-musl ;;
    ppc|powerpc) printf '%s\n' powerpc-unknown-linux-musl ;;
    riscv64) printf '%s\n' riscv64-unknown-linux-musl ;;
    *) return 1 ;;
  esac
}

adaptive_controller_asset_base() {
  local raw="${Z2R_PROJECT_RAW_BASE:-}"
  local asset_base
  asset_base="${Z2R_ADAPTIVE_ASSET_BASE:-}"
  if [ -n "$asset_base" ]; then
    case "$asset_base" in https://* ) printf '%s\n' "${asset_base%/}"; return 0 ;; esac
    return 1
  fi
  case "$raw" in
    https://raw.githubusercontent.com/*/*/*)
      printf '%s/adaptive/assets/linux\n' "${raw%/}"
      ;;
    *) return 1 ;;
  esac
}

# Explicit caller only. Runtime package is target-specific, statically linked,
# bounded to 512 KiB and verified against the checksum in the selected zator branch.
adaptive_controller_install() {
  local target base name root bindir binary tmp sumtmp expected actual size
  target="${1:-$(adaptive_controller_target)}" || {
    echo "Adaptive Controller: неподдерживаемая архитектура $(uname -m 2>/dev/null)." >&2
    return 1
  }
  case "$target" in
    aarch64-unknown-linux-musl|armv6-unknown-linux-musleabi|i586-unknown-linux-musl|x86_64-unknown-linux-musl|mips-unknown-linux-muslsf|mipsel-unknown-linux-muslsf|mips64-unknown-linux-musl|mips64el-unknown-linux-musl|powerpc-unknown-linux-musl|riscv64-unknown-linux-musl) ;;
    *) echo "Adaptive Controller: неизвестный target: $target" >&2; return 2 ;;
  esac
  root="${ZATOR_ROOT:-/opt/zator}"
  bindir="$root/adaptive/bin"
  name="adaptive-controller-$target"
  binary="$bindir/$name"
  [ "${Z2R_OFFLINE:-0}" != 1 ] || {
    if [ -x "$binary" ]; then
      ln -sfn "$name" "$bindir/adaptive-controller" || return 1
      printf '%s\n' "$binary"
      return 0
    fi
    echo "Adaptive Controller отсутствует в offline-пакете." >&2
    return 1
  }
  base="$(adaptive_controller_asset_base)" || {
    echo "Не удалось определить raw asset path для Adaptive Controller." >&2
    return 1
  }
  mkdir -p "$bindir" || return 1
  tmp="$binary.tmp.$$"
  sumtmp="$tmp.sha256"
  rm -f "$tmp" "$sumtmp"
  if ! z2r_fetch_url_to_file "$tmp" "$base/$name" ||
     ! z2r_fetch_url_to_file "$sumtmp" "$base/$name.sha256"; then
    rm -f "$tmp" "$sumtmp"
    echo "Не удалось скачать Adaptive Controller ($target)." >&2
    return 1
  fi
  expected="$(awk 'NR==1 {print $1}' "$sumtmp")"
  case "$expected" in
    *[!0-9a-f]*|'') rm -f "$tmp" "$sumtmp"; echo "Некорректный SHA-256 asset." >&2; return 1 ;;
  esac
  [ "${#expected}" -eq 64 ] || { rm -f "$tmp" "$sumtmp"; echo "Некорректная длина SHA-256." >&2; return 1; }
  actual="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$expected" ] || { rm -f "$tmp" "$sumtmp"; echo "SHA-256 Adaptive Controller не совпадает." >&2; return 1; }
  size="$(wc -c < "$tmp" | awk '{print $1}')"
  case "$size" in ''|*[!0-9]*) rm -f "$tmp" "$sumtmp"; return 1 ;; esac
  [ "$size" -gt 0 ] && [ "$size" -le 524288 ] || {
    rm -f "$tmp" "$sumtmp"
    echo "Размер Adaptive Controller выходит за лимит 512 KiB." >&2
    return 1
  }
  chmod 755 "$tmp" || { rm -f "$tmp" "$sumtmp"; return 1; }
  mv -f "$tmp" "$binary" || { rm -f "$tmp" "$sumtmp"; return 1; }
  ln -sfn "$name" "$bindir/adaptive-controller" || {
    rm -f "$sumtmp"
    return 1
  }
  rm -f "$sumtmp"
  printf '%s\n' "$binary"
}

adaptive_controller_nfqws2_supports_events() {
  local binary
  binary="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
  [ -x "$binary" ] || return 1
  "$binary" --help 2>&1 | grep -q -- '--adaptive-events=<file|unix:path>'
}

adaptive_controller_nfqws2_supports_learning() {
  local binary
  binary="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
  [ -x "$binary" ] || return 1
  "$binary" --help 2>&1 | grep -q -- '--adaptive-strategy=<profile>:<strategy>' &&
    "$binary" --help 2>&1 | grep -q -- '--adaptive-control=<unix_path>'
}

# The interactive menu may inherit NFQWS2_OPT from its caller, but a boot-time
# scheduler has no such environment. Read the quoted multiline option block
# from the active config (or its shipped default) without evaluating config
# contents as shell code.
adaptive_learning_load_options() {
  local cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [ -n "${NFQWS2_OPT:-}" ] && return 0
  if [ ! -f "$cfg" ] || [ -L "$cfg" ]; then cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config.default"; fi
  [ -f "$cfg" ] && [ ! -L "$cfg" ] || return 1
  NFQWS2_OPT="$(awk '
    /^NFQWS2_OPT="[[:space:]]*$/ { inside=1; next }
    inside && /^"[[:space:]]*$/ { exit }
    inside { print }
  ' "$cfg")"
  [ -n "$NFQWS2_OPT" ]
}

# Build a self-contained, one-profile nfqws2 config for an isolated learning
# worker. It intentionally imports only the shared TCP/TLS strategy template
# and blobs from production NFQWS2_OPT; production Lua lock/detector modules
# are never copied into this config.
adaptive_learning_config_write() {
  local strategy="$1" qnum="$2" event_socket="$3"
  local out=/tmp/zator-adaptive-learning/nfqws2.conf
  local tmp
  case "$strategy" in ''|*[!0-9]*) return 2 ;; esac
  case "$qnum" in ''|*[!0-9]*) return 2 ;; esac
  [ "${#qnum}" -le 5 ] || return 2
  [ "$strategy" = 4294967295 ] || [ "${#strategy}" -le 5 ] || return 2
  [ "$event_socket" = /tmp/zator-adaptive/events.sock ] || return 2
  [ "$strategy" -gt 0 ] && [ "${#strategy}" -le 10 ] || return 2
  [ "$qnum" -ge 1 ] && [ "$qnum" -le 65535 ] || return 2
  adaptive_learning_load_options || return 1
  mkdir -p /tmp/zator-adaptive-learning || return 1
  [ ! -L /tmp/zator-adaptive-learning ] || return 1
  chmod 700 /tmp/zator-adaptive-learning || return 1
  tmp="$out.tmp.$$"
  rm -f "$tmp"
  {
    printf '%s\n' \
      "--user=${WS_USER:-nobody}" \
      "--fwmark=${DESYNC_MARK:-0x40000000}" \
      "--qnum=$qnum" \
      "--adaptive-events=unix:$event_socket" \
      "--adaptive-control=/tmp/zator-adaptive-learning/control.sock" \
      "--adaptive-strategy=1:$strategy" \
      "--lua-init=@${ZAPRET2_ROOT:-/opt/zapret2}/lua/zapret-lib.lua" \
      "--lua-init=@${ZAPRET2_ROOT:-/opt/zapret2}/lua/zapret-antidpi.lua" \
      "--lua-init=@${ZATOR_ROOT:-/opt/zator}/lua/adaptive-executor.lua"
    printf '%s\n' "$NFQWS2_OPT" | awk -v wanted="$strategy" '
      /^--blob=/ { print; next }
      $0 == "--template=z2r_tcp_tls_common" { in_template=1; seen_template=1; print; next }
      in_template && /^--new([[:space:]]|$)/ { exit }
      in_template && /^--(out-range|in-range|payload|lua-desync)=/ {
        print
        if ($0 ~ ("strategy=" wanted "([[:space:]]|$)")) seen_strategy=1
      }
      END { if (!seen_template || (wanted != "4294967295" && !seen_strategy)) exit 1 }
    ' || return 1
    cat <<'EOF'
--new
--filter-tcp=443
--filter-l7=tls
--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello
--out-range=-s34228
--in-range=-s32768
--lua-desync=adaptive_execute:scope=learning
--import=z2r_tcp_tls_common
EOF
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}

# Validate a requested id against the exact extracted TLS plan before asking C
# to change the learning worker's default for future flows. Persist only after ACK.
adaptive_learning_runner_lock_check() {
  local lock owner_file owner
  lock=/tmp/zator-adaptive-learning/runner.lock
  [ ! -e "$lock" ] && [ ! -L "$lock" ] && return 0
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  owner_file="$lock/pid"
  [ -f "$owner_file" ] && [ ! -L "$owner_file" ] || return 1
  IFS= read -r owner <"$owner_file" || owner=
  case "$owner" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$owner" = "${Z2R_ADAPTIVE_RUNNER_PID:-}" ] && return 0
  if kill -0 "$owner" 2>/dev/null; then
    echo "Завершите текущий Adaptive learning run перед ручным изменением." >&2
    return 1
  fi
  rm -f "$owner_file" && rmdir "$lock" 2>/dev/null
}

adaptive_learning_runner_lock_acquire() {
  local lock owner_file
  lock=/tmp/zator-adaptive-learning/runner.lock
  [ -d /tmp/zator-adaptive-learning ] && [ ! -L /tmp/zator-adaptive-learning ] || return 1
  if ! mkdir "$lock" 2>/dev/null; then
    adaptive_learning_runner_lock_check || return 1
    mkdir "$lock" 2>/dev/null || {
      echo "Уже выполняется Adaptive learning run." >&2
      return 1
    }
  fi
  chmod 700 "$lock" || { rmdir "$lock" 2>/dev/null || :; return 1; }
  owner_file="$lock/pid"
  (umask 077; printf '%s\n' "$$" >"$owner_file") || {
    rm -f "$owner_file"
    rmdir "$lock" 2>/dev/null || :
    return 1
  }
  chmod 600 "$owner_file" || {
    rm -f "$owner_file"
    rmdir "$lock" 2>/dev/null || :
    return 1
  }
  Z2R_ADAPTIVE_RUNNER_PID="$$"
  export Z2R_ADAPTIVE_RUNNER_PID
}

adaptive_learning_runner_lock_release() {
  local lock owner_file owner
  lock=/tmp/zator-adaptive-learning/runner.lock
  owner_file="$lock/pid"
  [ -d "$lock" ] && [ ! -L "$lock" ] &&
    [ -f "$owner_file" ] && [ ! -L "$owner_file" ] || return 1
  IFS= read -r owner <"$owner_file" || return 1
  [ "$owner" = "$$" ] || return 1
  rm -f "$owner_file" && rmdir "$lock" || return 1
  unset Z2R_ADAPTIVE_RUNNER_PID
}

adaptive_learning_set_candidate() {
  local strategy="$1" strategy_file controller tmp lock
  strategy_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-learning.strategy"
  controller="${ZATOR_ROOT:-/opt/zator}/adaptive/bin/adaptive-controller"
  case "$strategy" in ''|*[!0-9]*) return 2 ;; esac
  [ "$strategy" -gt 0 ] && [ "${#strategy}" -le 10 ] || return 2
  adaptive_learning_enabled || { echo "Adaptive learning is not enabled." >&2; return 1; }
  adaptive_learning_runner_lock_check || return 1
  [ -x "$controller" ] || { echo "adaptive-controller is not installed." >&2; return 1; }
  [ -S /tmp/zator-adaptive-learning/control.sock ] || { echo "Learning worker control socket is unavailable." >&2; return 1; }
  lock=/tmp/zator-adaptive-learning/experiment.lock
  mkdir "$lock" 2>/dev/null || { echo "A learning probe or candidate update is already running." >&2; return 1; }
  if ! adaptive_learning_config_write "$strategy" 65535 /tmp/zator-adaptive/events.sock; then
    rmdir "$lock" 2>/dev/null || :
    if [ "$strategy" = 4294967295 ]; then
      echo "Не удалось подготовить no-strategy контрольный план." >&2
    else
      echo "Strategy $strategy is not present in the TLS learning plan." >&2
    fi
    return 1
  fi
  if ! "$controller" --set-candidate /tmp/zator-adaptive-learning/control.sock 1 "$strategy"; then
    rmdir "$lock" 2>/dev/null || :
    return 1
  fi
  tmp="$strategy_file.tmp.$$"
  if ! printf '%s\n' "$strategy" >"$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$strategy_file"; then
    rm -f "$tmp"
    rmdir "$lock" 2>/dev/null || :
    return 1
  fi
  rmdir "$lock" 2>/dev/null || :
}

# Provider identity is optional context. Never infer it from display text.
adaptive_learning_provider_key() {
  local file key detected_at now
  file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/provider_learning_key.txt"
  [ -f "$file" ] && [ ! -L "$file" ] || { printf '%s\n' unknown; return 0; }
  IFS="$(printf '\t')" read -r key detected_at <"$file" || key=
  case "$key" in
    asn:[1-9][0-9]*)
      case "${key#asn:}:$detected_at" in *[!0-9:]*|'') printf '%s\n' unknown ;;
        *)
          now="$(date +%s 2>/dev/null)"
          case "$now" in ''|*[!0-9]*) printf '%s\n' unknown ;;
            *)
              if [ "${#key}" -le 14 ] && [ "$now" -ge "$detected_at" ] &&
                [ $((now - detected_at)) -le 86400 ]; then
                printf '%s\n' "$key"
              else printf '%s\n' unknown; fi
              ;;
          esac
      esac
      ;;
    *) printf '%s\n' unknown ;;
  esac
}

# Ask the resident C controller whether this host has a due learning task.
# The caller owns traffic generation and must enforce its request budget.
adaptive_learning_schedule_next() {
  local host="$1" allowlist="$2" provider_key controller
  controller="${ZATOR_ROOT:-/opt/zator}/adaptive/bin/adaptive-controller"
  [ -x "$controller" ] || { echo "adaptive-controller is not installed." >&2; return 1; }
  provider_key="$(adaptive_learning_provider_key)" || provider_key=unknown
  "$controller" --next-scheduled /tmp/zator-adaptive/events.sock \
    "$host" 1 "$provider_key" "$allowlist"
}

adaptive_learning_schedule_next_host() {
  local allowlist="$1" provider_key controller
  controller="${ZATOR_ROOT:-/opt/zator}/adaptive/bin/adaptive-controller"
  [ -x "$controller" ] || { echo "adaptive-controller is not installed." >&2; return 1; }
  provider_key="$(adaptive_learning_provider_key)" || provider_key=unknown
  "$controller" --next-background /tmp/zator-adaptive/events.sock \
    "$provider_key" "$allowlist"
}

adaptive_learning_strategy_allowlist() {
  adaptive_learning_load_options || return 1
  printf '%s\n' "${NFQWS2_OPT:-}" | awk '
    /^--template=z2r_tcp_tls_common([[:space:]]|$)/ { inside=1; found=1; next }
    inside && /^--new([[:space:]]|$)/ { exit }
    inside && /^--lua-desync=/ {
      for (i=1; i<=NF; i++) {
        token=$i
        while (match(token, /strategy=[0-9]+/)) {
          id=substr(token, RSTART+9, RLENGTH-9)
          if (!(id in seen)) { seen[id]=1; ids[++n]=id }
          token=substr(token, RSTART+RLENGTH)
        }
      }
    }
    END {
      if (!found || !n || n>64) exit 1
      for (i=1; i<=n; i++) printf "%s%s", (i==1 ? "" : ","), ids[i]
    }
  '
}

# Wait for one exact C-settled lease, without spending candidate-selection
# budget or mistaking another caller's probe for this result.
adaptive_learning_wait_probe_id() {
  local journal="$1" journal_offset="$2" probe_id="$3" timeout="${4:-95}"
  local waited=0 row
  while [ "$waited" -le "$timeout" ]; do
    row="$(awk -F '\t' -v skip="$journal_offset" -v wanted="$probe_id" \
      '{ if (position >= skip && $1 == "PROBE_OUTCOME" && $3 == wanted) { print; exit } \
         position += length($0) + 1 }' "$journal" 2>/dev/null)"
    if [ -n "$row" ]; then printf '%s\n' "$row"; return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "Истёк срок ожидания PROBE_OUTCOME для probe_id=$probe_id." >&2
  return 1
}

# Persistent rolling budget: reserve one scheduler step per 24 hours before
# any control/candidate request. A failed step still consumes its reservation.
adaptive_learning_scheduler_budget_reserve() (
  local root file lock_dir now last tmp
  root="${ZATOR_ROOT:-/opt/zator}"
  file="$root/extra_strats/cache/adaptive-learning-scheduler.last"
  lock_dir=/tmp/zator-adaptive-learning/scheduler-budget.lock
  [ -d /tmp/zator-adaptive-learning ] && [ ! -L /tmp/zator-adaptive-learning ] || exit 1
  mkdir "$lock_dir" 2>/dev/null || {
    echo "Уже выполняется scheduler-запуск или обновление его budget state." >&2
    exit 3
  }
  trap 'rmdir "$lock_dir" 2>/dev/null || :' 0
  trap 'exit 1' HUP INT TERM
  [ -d "${file%/*}" ] && [ ! -L "${file%/*}" ] || exit 1
  [ ! -L "$file" ] || exit 1
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in ''|*[!0-9]*) echo "Системное время не подтверждено; scheduler probe пропущена." >&2; exit 1 ;; esac
  if [ -f "$file" ]; then
    IFS= read -r last <"$file" || last=
    case "$last" in ''|*[!0-9]*) echo "Некорректный scheduler budget state." >&2; exit 1 ;; esac
    [ "$now" -ge "$last" ] || { echo "Системное время откатилось; scheduler probe остановлена." >&2; exit 1; }
    [ $((now - last)) -ge 86400 ] || {
      echo "Суточный лимит scheduler-проб уже использован." >&2
      exit 3
    }
  fi
  umask 077
  tmp="$file.tmp.$$"
  printf '%s\n' "$now" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$file" || {
    rm -f "$tmp"
    exit 1
  }
  exit 0
)

adaptive_learning_wait_probe_settled() {
  local controller="$1" host="$2" budget="$3" provider_key="$4" allowlist="$5"
  local next status waited=0
  while :; do
    if next="$("$controller" --next-candidate /tmp/zator-adaptive/events.sock \
      "$host" 1 "$budget" "$provider_key" "$allowlist")"; then
      printf '%s\n' "$next"
      return 0
    else
      status=$?
    fi
    [ "$status" -eq 3 ] || return "$status"
    [ "$waited" -lt 95 ] || { echo "Истёк лимит ожидания завершения probe." >&2; return 1; }
    sleep 1
    waited=$((waited + 1))
  done
}

# Run a no-desync control and require the exact C-owned outcome before using
# candidate results as a comparison or retry baseline. The active runner owns
# the run-level and experiment locks, so this probe id cannot be interleaved.
adaptive_learning_run_control_probe() {
  local host="$1" controller="$2" budget="$3" provider_key="$4" allowlist="$5"
  local probe_output probe_id journal journal_offset record outcome epoch record_host
  local record_profile record_strategy record_flow_id
  host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
  journal=/tmp/zator-adaptive/shadow.tsv
  [ -f "$journal" ] && [ ! -L "$journal" ] || {
    echo "Журнал Adaptive Controller недоступен." >&2
    return 1
  }
  journal_offset="$(wc -c <"$journal" | awk '{print $1}')"
  case "$journal_offset" in ''|*[!0-9]*) echo "Не удалось определить позицию журнала." >&2; return 1 ;; esac
  adaptive_learning_set_candidate 4294967295 || return 1
  probe_output="$("${ZATOR_ROOT:-/opt/zator}/adaptive/probe-once.sh" "$host" --reported-result)" || return 1
  printf '%s\n' "$probe_output" >&2
  probe_id="$(printf '%s\n' "$probe_output" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^probe_id=[0-9]+$/) { sub(/^probe_id=/, "", $i); print $i; exit } }')"
  case "$probe_id" in ''|*[!0-9]*) echo "No-strategy probe вернул некорректный id." >&2; return 1 ;; esac
  record="$(adaptive_learning_wait_probe_id "$journal" "$journal_offset" "$probe_id")" || return 1
  outcome="$(printf '%s\n' "$record" | awk -F '\t' '{print $4}')"
  epoch="$(printf '%s\n' "$record" | awk -F '\t' '{print $15}')"
  record_profile="$(printf '%s\n' "$record" | awk -F '\t' '{print $6}')"
  record_strategy="$(printf '%s\n' "$record" | awk -F '\t' '{print $7}')"
  record_host="$(printf '%s\n' "$record" | awk -F '\t' '{print $9}')"
  record_flow_id="$(printf '%s\n' "$record" | awk -F '\t' '{print $14}')"
  [ "$outcome" = CONTROL_SUCCESS ] && [ "$record_profile" = 1 ] &&
    [ "$record_strategy" = 4294967295 ] && [ "$record_host" = "$host" ] &&
    case "$record_flow_id" in ''|*[!0-9]*|0) false ;; *) true ;; esac || {
    echo "No-strategy контроль не подтвердил доступность target; candidate probes приостановлены." >&2
    return 1
  }
  case "$epoch" in ''|*[!0-9]*) echo "В журнале отсутствует network epoch контрольной пробы." >&2; return 1 ;; esac
  printf '%s\n' "$epoch"
}

# Run a bounded, operator-started comparison over the strategies actually
# present in the extracted TLS plan. Candidate ranking and attempt accounting
# stay in C; this function only applies the acknowledged choice and runs probes.
adaptive_learning_compare_impl() {
  local host="$1" budget="$2" controller allowlist next status strategy provider_key prior_support
  local completed=0 strategy_file original_strategy last_strategy probe_output probe_id
  local journal journal_offset record record_profile record_strategy record_host record_outcome
  local verified_epoch next_epoch controls_used=0 max_recovery_controls
  controller="${ZATOR_ROOT:-/opt/zator}/adaptive/bin/adaptive-controller"
  case "$host" in ''|.*|*..*|*-.*|*.-*|*-.|*.|*[!A-Za-z0-9.-]*) return 2 ;; esac
  [ "${#host}" -le 253 ] || return 2
  host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
  case "$budget" in ''|*[!0-9]*) return 2 ;; esac
  [ "$budget" -ge 1 ] && [ "$budget" -le 64 ] || return 2
  [ -x "$controller" ] || { echo "adaptive-controller is not installed." >&2; return 1; }
  provider_key="$(adaptive_learning_provider_key)" || provider_key=unknown
  allowlist="$(adaptive_learning_strategy_allowlist)" || {
    echo "Не удалось получить ограниченный список strategy из TLS plan." >&2
    return 1
  }

  strategy_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-learning.strategy"
  IFS= read -r original_strategy <"$strategy_file" || original_strategy=
  case "$original_strategy" in ''|*[!0-9]*) echo "Не задана исходная learning strategy." >&2; return 1 ;; esac
  echo "Контроль без desync для $host..."
  controls_used=1
  verified_epoch="$(adaptive_learning_run_control_probe "$host" "$controller" "$budget" "$provider_key" "$allowlist")" || {
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
    return 1
  }
  max_recovery_controls=$((budget + 1))
  next="$(adaptive_learning_wait_probe_settled "$controller" "$host" "$budget" "$provider_key" "$allowlist")" || {
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
    echo "Не удалось получить candidate после no-strategy контроля." >&2
    return 1
  }
  while :; do
    case "$next" in
      candidate_exhausted*) echo "Лимит candidate probe-попыток исчерпан."; break ;;
    esac
    [ "$completed" -lt "$budget" ] || { echo "Общий лимит $budget candidate probes исчерпан."; break; }
    next_epoch="$(printf '%s\n' "$next" | awk -F '\t' '$1=="candidate_next" && $5 ~ /^epoch=[0-9]+$/ { sub(/^epoch=/,"",$5); print $5 }')"
    case "$next_epoch" in ''|*[!0-9]*)
      [ -n "$last_strategy" ] && adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      [ -n "$last_strategy" ] || adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
      echo "C controller вернул некорректный network epoch." >&2
      return 1
    ;; esac
    if [ "$next_epoch" != "$verified_epoch" ]; then
      [ "$controls_used" -lt "$max_recovery_controls" ] || {
        echo "Слишком много смен network epoch; останавливаю bounded comparison." >&2
        break
      }
      echo "Network epoch сменился ($verified_epoch → $next_epoch); проверяю восстановление без desync..."
      controls_used=$((controls_used + 1))
      verified_epoch="$(adaptive_learning_run_control_probe "$host" "$controller" "$budget" "$provider_key" "$allowlist")" || {
        [ -n "$last_strategy" ] && adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
        return 1
      }
      next="$(adaptive_learning_wait_probe_settled "$controller" "$host" "$budget" "$provider_key" "$allowlist")" || {
        [ -n "$last_strategy" ] && adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
        echo "Не удалось продолжить после проверки нового network epoch." >&2
        return 1
      }
      continue
    fi
    strategy="$(printf '%s\n' "$next" | awk -F '\t' '$1=="candidate_next" && $2 ~ /^strategy=[0-9]+$/ { sub(/^strategy=/,"",$2); print $2 }')"
    prior_support="$(printf '%s\n' "$next" | awk -F '\t' '$1=="candidate_next" && $6 ~ /^prior_support=[0-9]+$/ { sub(/^prior_support=/,"",$6); print $6 }')"
    case "$strategy" in ''|*[!0-9]*)
      [ -n "$last_strategy" ] && adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      [ -n "$last_strategy" ] || adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
      echo "C controller вернул некорректный candidate." >&2
      return 1
    ;; esac
    case "$prior_support" in ''|*[!0-9]*) prior_support=0 ;; esac
    echo "Проба $((completed + 1)): strategy $strategy для $host (prior support: $prior_support)"
    journal=/tmp/zator-adaptive/shadow.tsv
    [ -f "$journal" ] && [ ! -L "$journal" ] || {
      echo "Журнал Adaptive Controller недоступен." >&2
      [ -n "$last_strategy" ] && adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      return 1
    }
    journal_offset="$(wc -c <"$journal" | awk '{print $1}')"
    case "$journal_offset" in ''|*[!0-9]*)
      [ -n "$last_strategy" ] && adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      return 1
    ;; esac
    adaptive_learning_set_candidate "$strategy" || {
      [ -n "$last_strategy" ] && adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      [ -n "$last_strategy" ] || adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
      return 1
    }
    last_strategy="$strategy"
    probe_output="$("${ZATOR_ROOT:-/opt/zator}/adaptive/probe-once.sh" "$host" --reported-result)" || {
      echo "Проба не была принята controller; сравнение остановлено." >&2
      adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      return 1
    }
    probe_id="$(printf '%s\n' "$probe_output" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^probe_id=[0-9]+$/) { sub(/^probe_id=/, "", $i); print $i; exit } }')"
    case "$probe_id" in ''|*[!0-9]*)
      echo "Проба вернула некорректный probe_id." >&2
      adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      return 1
    ;; esac
    record="$(adaptive_learning_wait_probe_id "$journal" "$journal_offset" "$probe_id")" || {
      adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      return 1
    }
    record_profile="$(printf '%s\n' "$record" | awk -F '\t' '{print $6}')"
    record_strategy="$(printf '%s\n' "$record" | awk -F '\t' '{print $7}')"
    record_host="$(printf '%s\n' "$record" | awk -F '\t' '{print $9}')"
    record_outcome="$(printf '%s\n' "$record" | awk -F '\t' '{print $4}')"
    if [ "$record_profile" != 1 ] || [ "$record_strategy" != "$strategy" ] ||
      [ "$record_host" != "$host" ] ||
      { [ "$record_outcome" != STRONG_SUCCESS ] && [ "$record_outcome" != UNKNOWN ]; }; then
      echo "PROBE_OUTCOME не совпадает с выбранными host/profile/strategy; сравнение остановлено." >&2
      adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      return 1
    fi
    completed=$((completed + 1))

    next="$(adaptive_learning_wait_probe_settled "$controller" "$host" "$budget" "$provider_key" "$allowlist")" || {
      echo "Ожидание probe завершилось ошибкой." >&2
      adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
      return 1
    }
  done

  echo "Повторный контроль без desync для $host..."
  if ! adaptive_learning_run_control_probe "$host" "$controller" "$budget" "$provider_key" "$allowlist" >/dev/null; then
    [ -n "$last_strategy" ] && adaptive_learning_set_candidate "$last_strategy" >/dev/null 2>&1 || :
    return 1
  fi
  [ -n "$last_strategy" ] || last_strategy="$original_strategy"
  adaptive_learning_set_candidate "$last_strategy" || return 1
}

adaptive_learning_compare() {
  local run_status
  adaptive_learning_runner_lock_acquire || return 1
  if adaptive_learning_compare_impl "$@"; then run_status=0; else run_status=$?; fi
  adaptive_learning_runner_lock_release || {
    echo "Не удалось освободить Adaptive learning run lock." >&2
    return 1
  }
  return "$run_status"
}

# Consume at most one due scheduler task. Each step uses a successful
# no-desync control before and after one candidate request, for a hard ceiling
# of three HTTPS requests per invocation.
adaptive_learning_scheduled_step_impl() {
  local host="${1:-}" controller allowlist provider_key original_strategy strategy strategy_file
  local task status probe_class journal journal_offset probe_output probe_id record outcome
  local record_profile record_strategy record_host
  adaptive_learning_enabled || { echo "Adaptive learning выключен." >&2; return 1; }
  controller="${ZATOR_ROOT:-/opt/zator}/adaptive/bin/adaptive-controller"
  [ -x "$controller" ] || { echo "adaptive-controller is not installed." >&2; return 1; }
  allowlist="$(adaptive_learning_strategy_allowlist)" || {
    echo "Не удалось получить ограниченный список strategy из TLS plan." >&2
    return 1
  }
  provider_key="$(adaptive_learning_provider_key)" || provider_key=unknown
  strategy_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-learning.strategy"
  IFS= read -r original_strategy <"$strategy_file" || original_strategy=
  case "$original_strategy" in ''|*[!0-9]*|0) echo "Не задана исходная learning strategy." >&2; return 1 ;; esac

  if [ -z "$host" ]; then
    if task="$(adaptive_learning_schedule_next_host "$allowlist")"; then
      host="$(printf '%s\n' "$task" | awk -F '\t' '$1=="background_task" && $2~/^host=/ { sub(/^host=/,"",$2); print $2 }')"
      echo "C scheduler выбрал недавно наблюдавшийся хост: $host"
    else
      status=$?
      [ "$status" -eq 3 ] && { echo "Нет due-задачи для недавно наблюдавшихся хостов."; return 3; }
      return "$status"
    fi
  fi
  case "$host" in ''|.*|*..*|*-.*|*.-*|*-.|*.|*[!A-Za-z0-9.-]*) return 2 ;; esac
  [ "${#host}" -le 253 ] || return 2
  host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"

  if task="$(adaptive_learning_schedule_next "$host" "$allowlist")"; then
    :
  else
    status=$?
    [ "$status" -eq 3 ] && { echo "Для $host пока нет due scheduler-задачи."; return 3; }
    return "$status"
  fi
  journal=/tmp/zator-adaptive/shadow.tsv
  [ -f "$journal" ] && [ ! -L "$journal" ] || {
    echo "Журнал Adaptive Controller недоступен." >&2
    return 1
  }
  if adaptive_learning_scheduler_budget_reserve; then
    :
  else
    status=$?
    [ "$status" -eq 3 ] && return 3
    return "$status"
  fi
  echo "Проверка baseline без desync для $host..."
  if ! adaptive_learning_run_control_probe "$host" "$controller" 64 "$provider_key" "$allowlist" >/dev/null; then
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 ||
      echo "Не удалось восстановить исходную learning strategy." >&2
    return 1
  fi
  # Re-query after the control: an epoch change makes the old task stale.
  if task="$(adaptive_learning_schedule_next "$host" "$allowlist")"; then
    :
  else
    status=$?
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 ||
      echo "Не удалось восстановить исходную learning strategy." >&2
    [ "$status" -eq 3 ] && return 3
    return "$status"
  fi
  strategy="$(printf '%s\n' "$task" | awk -F '\t' '$1=="schedule_task" && $2~/^strategy=[0-9]+$/ { sub(/^strategy=/,"",$2); print $2 }')"
  probe_class="$(printf '%s\n' "$task" | awk -F '\t' '$1=="schedule_task" && $3~/^class=[A-Z_]+$/ { sub(/^class=/,"",$3); print $3 }')"
  case ",$allowlist," in *,$strategy,*) ;; *) strategy= ;; esac
  case "$strategy" in ''|*[!0-9]*|0) strategy= ;; esac
  case "$probe_class" in UNKNOWN_EXPLORATION|PROMISING_RECHECK|UNKNOWN_RECHECK|CHAMPION_REVALIDATION|RUNNERUP_REVALIDATION|QUARANTINE_RETRY) ;; *) strategy= ;; esac
  if [ -z "$strategy" ]; then
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 ||
      echo "Не удалось восстановить исходную learning strategy." >&2
    echo "C scheduler вернул некорректную или отсутствующую due-задачу." >&2
    return 1
  fi

  journal_offset="$(wc -c <"$journal" | awk '{print $1}')"
  case "$journal_offset" in ''|*[!0-9]*)
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
    return 1
  ;; esac
  adaptive_learning_set_candidate "$strategy" || {
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
    return 1
  }
  probe_output="$("${ZATOR_ROOT:-/opt/zator}/adaptive/probe-once.sh" "$host" --reported-result)" || {
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
    echo "Candidate probe не была принята controller." >&2
    return 1
  }
  printf '%s\n' "$probe_output" >&2
  probe_id="$(printf '%s\n' "$probe_output" | awk '{ for (i=1; i<=NF; i++) if ($i~/^probe_id=[0-9]+$/) { sub(/^probe_id=/,"",$i); print $i; exit } }')"
  case "$probe_id" in ''|*[!0-9]*)
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
    echo "Candidate probe вернула некорректный probe_id." >&2
    return 1
  ;; esac
  record="$(adaptive_learning_wait_probe_id "$journal" "$journal_offset" "$probe_id")" || {
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 || :
    return 1
  }
  outcome="$(printf '%s\n' "$record" | awk -F '\t' '{print $4}')"
  record_profile="$(printf '%s\n' "$record" | awk -F '\t' '{print $6}')"
  record_strategy="$(printf '%s\n' "$record" | awk -F '\t' '{print $7}')"
  record_host="$(printf '%s\n' "$record" | awk -F '\t' '{print $9}')"
  if [ "$record_profile" != 1 ] || [ "$record_strategy" != "$strategy" ] ||
    [ "$record_host" != "$host" ]; then
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 ||
      echo "Не удалось восстановить исходную learning strategy." >&2
    echo "PROBE_OUTCOME не совпадает с due host/profile/strategy; scheduler остановлен." >&2
    return 1
  fi
  echo "Scheduler: $probe_class, strategy $strategy, outcome $outcome."
  echo "Проверка baseline без desync после candidate probe..."
  if ! adaptive_learning_run_control_probe "$host" "$controller" 64 "$provider_key" "$allowlist" >/dev/null; then
    adaptive_learning_set_candidate "$original_strategy" >/dev/null 2>&1 ||
      echo "Не удалось восстановить исходную learning strategy." >&2
    echo "Post-control не подтвердился; сравнительная evidence не закрыта." >&2
    return 1
  fi
  adaptive_learning_set_candidate "$original_strategy" || {
    echo "Не удалось восстановить исходную learning strategy." >&2
    return 1
  }
  return 0
}

adaptive_learning_scheduled_step() {
  local run_status
  adaptive_learning_runner_lock_acquire || return 1
  if adaptive_learning_scheduled_step_impl "$@"; then run_status=0; else run_status=$?; fi
  adaptive_learning_runner_lock_release || {
    echo "Не удалось освободить Adaptive learning run lock." >&2
    return 1
  }
  return "$run_status"
}

# zapret2's nfqws2 accepts @config only as argv[1]. The shared do_nfqws hook
# prepends normal NFQWS2 options, so route the learning daemon through this
# exec wrapper; it intentionally ignores those appended arguments.
adaptive_learning_wrapper_install() {
  local wrapper=/tmp/zator-adaptive-learning/nfqws2-wrapper
  local config=/tmp/zator-adaptive-learning/nfqws2.conf
  local binary="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
  local tmp
  case "$binary" in /*) ;; *) return 2 ;; esac
  case "$binary" in *[!A-Za-z0-9_./-]*) return 2 ;; esac
  [ -x "$binary" ] && [ -s "$config" ] || return 1
  [ -d /tmp/zator-adaptive-learning ] && [ ! -L /tmp/zator-adaptive-learning ] || return 1
  tmp="$wrapper.tmp.$$"
  printf '#!/bin/sh\nexec "%s" "@%s"\n' "$binary" "$config" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 700 "$tmp" && mv -f "$tmp" "$wrapper" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$wrapper"
}

adaptive_controller_service_install() {
  local tmp target
  case "${OSystem:-}" in
    WRT)
      target=/etc/init.d/z2r-adaptive-controller
      mkdir -p /etc/init.d || return 1
      tmp="$target.tmp.$$"
      z2r_download_project_file "$tmp" "init.d/openwrt/z2r-adaptive-controller" || return 1
      chmod 755 "$tmp" && mv -f "$tmp" "$target"
      ;;
    *)
      [ "${hardware:-}" = keenetic ] || return 1
      target=/opt/etc/init.d/S89z2r-adaptive-controller
      mkdir -p /opt/etc/init.d || return 1
      tmp="$target.tmp.$$"
      z2r_download_project_file "$tmp" "Entware/z2r-adaptive-controller" || return 1
      chmod 755 "$tmp" && mv -f "$tmp" "$target"
      ;;
  esac
}

adaptive_controller_service_action() {
  local action="$1" service
  case "${OSystem:-}" in
    WRT) service=/etc/init.d/z2r-adaptive-controller ;;
    *)
      [ "${hardware:-}" = keenetic ] || return 1
      service=/opt/etc/init.d/S89z2r-adaptive-controller
      ;;
  esac
  [ -x "$service" ] || return 1
  "$service" "$action"
}

adaptive_controller_nfqws2_supports_canary() {
  local binary
  binary="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
  [ -x "$binary" ] || return 1
  "$binary" --help 2>&1 | grep -q -- '--adaptive-events=<file|unix:path>' &&
    "$binary" --help 2>&1 | grep -q -- '--adaptive-control=<unix_path>' &&
    "$binary" --help 2>&1 | grep -q -- '--adaptive-canary-profile=<profile>'
}

adaptive_canary_enabled() {
  [ -f "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-canary.enabled" ]
}

adaptive_canary_status_text() {
  local hosts_file count
  if ! adaptive_canary_enabled; then
    printf '%s' 'выключен'
    return 0
  fi
  hosts_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-canary.hosts"
  count=0
  [ ! -f "$hosts_file" ] || count="$(awk 'END { print NR + 0 }' "$hosts_file" 2>/dev/null)"
  printf 'включён, allowlist: %s хостов (profile 1)' "$count"
}

adaptive_canary_toggle() {
  local root cache marker hosts_file hosts_tmp marker_tmp controller control_sock host clear_failed wait_count
  adaptive_learning_runner_lock_check || return 1
  root="${ZATOR_ROOT:-/opt/zator}"
  cache="$root/extra_strats/cache"
  marker="$cache/adaptive-canary.enabled"
  hosts_file="$cache/adaptive-canary.hosts"
  controller="$root/adaptive/bin/adaptive-controller"
  control_sock=/tmp/zator-adaptive/production-control.sock

  if adaptive_canary_enabled; then
    clear_failed=0
    if [ -S "$control_sock" ]; then
      if [ -x "$controller" ]; then
        while IFS= read -r host || [ -n "$host" ]; do
          [ -n "$host" ] || continue
          "$controller" --production-clear-host "$control_sock" 1 "$host" >/dev/null || {
            clear_failed=1
            break
          }
        done <"$hosts_file"
      else
        clear_failed=1
      fi
    fi
    if [ "$clear_failed" -eq 1 ]; then
      z2r_service_action restart || {
        echo "Не удалось сбросить C host-map перезапуском; режим оставлен включённым." >&2
        return 1
      }
    fi
    adaptive_controller_service_action stop || {
      echo "Не удалось остановить controller; режим оставлен включённым." >&2
      return 1
    }
    rm -f "$marker" "$hosts_file" /tmp/zator-adaptive/state.tsv.canary.tsv || return 1
    adaptive_controller_service_action start || return 1
    z2r_service_action restart || return 1
    echo "Adaptive canary выключен; C host-map очищен."
    return 0
  fi

  if [ "${OSystem:-}" != WRT ] && [ "${hardware:-}" != keenetic ]; then
    echo "Adaptive canary пока поддерживает OpenWrt и Keenetic Entware." >&2
    return 1
  fi
  adaptive_learning_enabled || {
    echo "Сначала включите Learning worker (пункт 25), чтобы накопить probe evidence." >&2
    return 1
  }
  adaptive_controller_nfqws2_supports_canary || {
    echo "Установленный nfqws2 не поддерживает C canary и telemetry." >&2
    return 1
  }
  if [ ! -x "$controller" ] || ! "$controller" --help 2>&1 | grep -q -- '--canary-hosts'; then
    adaptive_controller_install >/dev/null || return 1
  fi
  "$controller" --help 2>&1 | grep -q -- '--canary-hosts' || {
    echo "Adaptive Controller не содержит canary policy; обновите runtime asset." >&2
    return 1
  }
  read -r -p "Точные hostname через запятую для canary (1–64): " hosts
  mkdir -p "$cache" || return 1
  hosts_tmp="$hosts_file.tmp.$$"
  marker_tmp="$marker.tmp.$$"
  rm -f "$hosts_tmp" "$marker_tmp"
  rm -f /tmp/zator-adaptive/state.tsv.canary.tsv
  if ! printf '%s\n' "$hosts" | tr ',' '\n' | awk '
    {
      h = tolower($0)
      if (length(h) == 0 || length(h) >= 256 || h ~ /[^a-z0-9.-]/ ||
          h ~ /^\./ || h ~ /\.$/ || h ~ /\.\./ || h ~ /(^|\.)-/ || h ~ /-(\.|$)/) exit 1
      if (!seen[h]++) {
        if (++n > 64) exit 1
        print h
      }
    }
    END { if (n < 1) exit 1 }
  ' >"$hosts_tmp"; then
    rm -f "$hosts_tmp"
    echo "Allowlist должен содержать от 1 до 64 корректных hostname без пробелов." >&2
    return 2
  fi
  chmod 600 "$hosts_tmp" || { rm -f "$hosts_tmp"; return 1; }
  mv -f "$hosts_tmp" "$hosts_file" || { rm -f "$hosts_tmp"; return 1; }
  printf 'enabled\n' >"$marker_tmp" && chmod 600 "$marker_tmp" && mv -f "$marker_tmp" "$marker" || {
    rm -f "$marker_tmp" "$hosts_file"
    return 1
  }

  if [ "${OSystem:-}" = WRT ]; then
    wrt_fixes || { rm -f "$marker" "$hosts_file" /tmp/zator-adaptive/state.tsv.canary.tsv; return 1; }
  else
    z2r_download_project_file "$ZAPRET2_ROOT/init.d/sysv/zapret2" "Entware/zapret" || {
      rm -f "$marker" "$hosts_file" /tmp/zator-adaptive/state.tsv.canary.tsv; return 1;
    }
    chmod 755 "$ZAPRET2_ROOT/init.d/sysv/zapret2" || return 1
  fi
  adaptive_controller_service_install || { rm -f "$marker" "$hosts_file" /tmp/zator-adaptive/state.tsv.canary.tsv; return 1; }
  adaptive_controller_service_action restart || {
    rm -f "$marker" "$hosts_file" /tmp/zator-adaptive/state.tsv.canary.tsv
    adaptive_controller_service_action restart >/dev/null 2>&1 || true
    return 1
  }
  wait_count=0
  while [ "$wait_count" -lt 5 ] && [ ! -S /tmp/zator-adaptive/events.sock ]; do
    sleep 1
    wait_count=$((wait_count + 1))
  done
  if [ ! -S /tmp/zator-adaptive/events.sock ]; then
    rm -f "$marker" "$hosts_file" /tmp/zator-adaptive/state.tsv.canary.tsv
    adaptive_controller_service_action restart >/dev/null 2>&1 || true
    echo "Adaptive Controller не создал telemetry socket; canary не включён." >&2
    return 1
  fi
  if ! z2r_service_action restart; then
    rm -f "$marker" "$hosts_file" /tmp/zator-adaptive/state.tsv.canary.tsv
    adaptive_controller_service_action restart >/dev/null 2>&1 || true
    z2r_service_action restart >/dev/null 2>&1 || true
    return 1
  fi
  echo "Adaptive canary включён для $(awk 'END {print NR}' "$hosts_file") hostname; смена стратегии требует подтверждённого champion."
}

adaptive_shadow_enabled() {
  [ -f "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-shadow.enabled" ]
}

adaptive_learning_enabled() {
  [ -f "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-learning.enabled" ]
}

adaptive_learning_mark_available() {
  local mark n desync postnat filter digits
  mark="${Z2R_ADAPTIVE_MARK:-0x08000000}"
  case "$mark" in 0x[0-9A-Fa-f]*|[0-9]*) ;; *) return 1 ;; esac
  case "$mark" in *[!0-9A-Fa-fxX]*) return 1 ;; esac
  case "$mark" in
    0x*)
      digits=${mark#0x}
      [ "${#digits}" -le 8 ] || return 1
      if [ "${#digits}" -eq 8 ]; then
        case "$digits" in [0-7]*) ;; *) return 1 ;; esac
      fi
      ;;
    *) [ "${#mark}" -le 9 ] || return 1 ;;
  esac
  n=$((mark)) 2>/dev/null || return 1
  [ "$n" -gt 0 ] && [ "$((n & (n - 1)))" -eq 0 ] || return 1
  desync=$(( ${DESYNC_MARK:-0x40000000} ))
  postnat=$(( ${DESYNC_MARK_POSTNAT:-0x20000000} ))
  filter=0
  [ -n "${FILTER_MARK:-}" ] && filter=$((FILTER_MARK))
  [ "$((n & desync))" -eq 0 ] && [ "$((n & postnat))" -eq 0 ] && [ "$((n & filter))" -eq 0 ]
}

adaptive_learning_status_text() {
  local strategy_file strategy
  if ! adaptive_learning_enabled; then
    printf '%s' 'выключен'
    return 0
  fi
  strategy_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-learning.strategy"
  IFS= read -r strategy <"$strategy_file" 2>/dev/null || strategy='?'
  printf 'включён, strategy %s, фоновые scheduler-пробы: до 1 шага/24 ч' "$strategy"
}

adaptive_learning_toggle() {
  local root marker strategy_file strategy wait_count action
  root="${ZATOR_ROOT:-/opt/zator}"
  marker="$root/extra_strats/cache/adaptive-learning.enabled"
  strategy_file="$root/extra_strats/cache/adaptive-learning.strategy"

  if adaptive_learning_enabled; then
    read -r -p "Learning активен (фоновые пробы: до 1 шага/24 ч): 1 — сменить strategy, 2 — сравнить candidates, 3 — выполнить due-пробу сейчас, 0 — выключить: " action
    case "$action" in
      1)
        read -r -p "Номер TCP/TLS strategy: " strategy
        if ! adaptive_learning_set_candidate "$strategy"; then
          echo "Strategy не применена; worker продолжает прежний candidate." >&2
          return 1
        fi
        echo "Candidate сменён с ACK от nfqws2; уже открытые flows сохраняют свою strategy."
        echo "Для отдельной пробы: $root/adaptive/probe-once.sh example.com"
        return 0
        ;;
      2)
        local probe_host probe_budget
        read -r -p "Hostname для HTTPS probe: " probe_host
        read -r -p "Общий лимит завершённых probe-попыток (1–64): " probe_budget
        adaptive_learning_compare "$probe_host" "$probe_budget"
        return $?
        ;;
      3)
        local probe_host step_status
        read -r -p "Hostname для scheduler probe (Enter — выбрать из C flow telemetry): " probe_host
        if adaptive_learning_scheduled_step "$probe_host"; then
          return 0
        else
          step_status=$?
        fi
        [ "$step_status" -eq 3 ] && return 0
        return "$step_status"
        ;;
      0)
        adaptive_learning_runner_lock_check || {
          echo "Дождитесь завершения Adaptive learning run." >&2
          return 1
        }
        [ ! -d /tmp/zator-adaptive-learning/experiment.lock ] || {
          echo "Дождитесь завершения learning probe/candidate update." >&2
          return 1
        }
        ;;
      *) echo "Введите 1, 2, 3 или 0." >&2; return 2 ;;
    esac
    rm -f "$marker" "$strategy_file"
    z2r_service_action restart || return 1
    if ! adaptive_shadow_enabled; then
      adaptive_controller_service_action stop >/dev/null 2>&1 || true
      [ "${OSystem:-}" != WRT ] || /etc/init.d/z2r-adaptive-controller disable >/dev/null 2>&1 || true
    fi
    echo "Learning worker выключен. Production strategy не менялась."
    return 0
  fi

  if [ "${OSystem:-}" != WRT ] && [ "${hardware:-}" != keenetic ]; then
    echo "Adaptive learning пока поддерживает OpenWrt и Keenetic Entware." >&2
    return 1
  fi
  if ! adaptive_controller_nfqws2_supports_events || ! adaptive_controller_nfqws2_supports_learning; then
    echo "Установленный nfqws2 не содержит C telemetry и strategy pin; learning не включён." >&2
    return 1
  fi
  if ! adaptive_learning_mark_available; then
    echo "Adaptive mark пересекается с DESYNC/FILTER mark или задан некорректно; learning не включён." >&2
    return 1
  fi
  read -r -p "Номер TCP/TLS strategy для learning worker: " strategy
  case "$strategy" in ''|*[!0-9]*|0) echo "Введите положительный номер стратегии." >&2; return 2 ;; esac
  adaptive_learning_config_write "$strategy" 65535 /tmp/zator-adaptive/events.sock || {
    echo "Strategy $strategy отсутствует в TLS plan или learning config не собран." >&2
    return 1
  }
  rm -f /tmp/zator-adaptive-learning/nfqws2.conf

  if [ "${OSystem:-}" = WRT ]; then
    wrt_fixes || return 1
  else
    z2r_download_project_file "$ZAPRET2_ROOT/init.d/sysv/zapret2" "Entware/zapret" || return 1
    chmod 755 "$ZAPRET2_ROOT/init.d/sysv/zapret2" || return 1
  fi
  mkdir -p "$root/adaptive" "$ZAPRET2_ROOT/init.d/sysv/custom.d" \
    "$ZAPRET2_ROOT/init.d/openwrt/custom.d" || return 1
  z2r_repo_get "$root/adaptive/90-zator-adaptive-learning" \
    "adaptive/90-zator-adaptive-learning" || return 1
  z2r_repo_get "$root/adaptive/probe-once.sh" "adaptive/probe-once.sh" || return 1
  chmod 755 "$root/adaptive/90-zator-adaptive-learning" "$root/adaptive/probe-once.sh" || return 1
  cp -f "$root/adaptive/90-zator-adaptive-learning" \
    "$ZAPRET2_ROOT/init.d/sysv/custom.d/90-zator-adaptive-learning" || return 1
  cp -f "$root/adaptive/90-zator-adaptive-learning" \
    "$ZAPRET2_ROOT/init.d/openwrt/custom.d/90-zator-adaptive-learning" || return 1
  adaptive_controller_service_install || return 1
  adaptive_controller_install >/dev/null || return 1
  mkdir -p "$(dirname "$marker")" || return 1
  printf '%s\n' "$strategy" >"$strategy_file.tmp.$$" && chmod 600 "$strategy_file.tmp.$$" && mv -f "$strategy_file.tmp.$$" "$strategy_file" || return 1
  printf 'enabled\n' >"$marker.tmp.$$" && chmod 600 "$marker.tmp.$$" && mv -f "$marker.tmp.$$" "$marker" || { rm -f "$strategy_file"; return 1; }
  if [ "${OSystem:-}" = WRT ]; then
    /etc/init.d/z2r-adaptive-controller enable || { rm -f "$marker" "$strategy_file"; return 1; }
  fi
  adaptive_controller_service_action start || {
    rm -f "$marker" "$strategy_file"
    adaptive_controller_service_action stop >/dev/null 2>&1 || true
    [ "${OSystem:-}" != WRT ] || /etc/init.d/z2r-adaptive-controller disable >/dev/null 2>&1 || true
    return 1
  }
  wait_count=0
  while [ "$wait_count" -lt 5 ] && [ ! -S /tmp/zator-adaptive/events.sock ]; do
    sleep 1
    wait_count=$((wait_count + 1))
  done
  if [ ! -S /tmp/zator-adaptive/events.sock ]; then
    rm -f "$marker" "$strategy_file"
    adaptive_controller_service_action stop >/dev/null 2>&1 || true
    [ "${OSystem:-}" != WRT ] || /etc/init.d/z2r-adaptive-controller disable >/dev/null 2>&1 || true
    echo "Adaptive Controller не создал Unix-сокет." >&2
    return 1
  fi
  if ! z2r_service_action restart; then
    rm -f "$marker" "$strategy_file"
    adaptive_controller_service_action stop >/dev/null 2>&1 || true
    [ "${OSystem:-}" != WRT ] || /etc/init.d/z2r-adaptive-controller disable >/dev/null 2>&1 || true
    return 1
  fi
  echo "Learning worker запущен для strategy $strategy. Одна HTTPS проба: $root/adaptive/probe-once.sh example.com"
  echo "Фоновый scheduler выполняет не более одного bounded шага за 24 часа; для ручного запуска due-задачи используйте пункт 3."
  echo "Для bounded comparison используйте пункт 2."
}

adaptive_shadow_status_text() {
  adaptive_shadow_enabled && printf '%s' 'включён (shadow)' || printf '%s' 'выключен'
}

adaptive_shadow_toggle() {
  local marker
  marker="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-shadow.enabled"
  adaptive_learning_runner_lock_check || return 1
  if adaptive_shadow_enabled; then
    rm -f "$marker"
    if ! adaptive_learning_enabled; then
      if [ "${OSystem:-}" = WRT ]; then
        /etc/init.d/z2r-adaptive-controller stop >/dev/null 2>&1 || true
        /etc/init.d/z2r-adaptive-controller disable >/dev/null 2>&1 || true
      elif [ "${hardware:-}" = keenetic ]; then
        /opt/etc/init.d/S89z2r-adaptive-controller stop >/dev/null 2>&1 || true
      fi
    fi
    z2r_service_action restart || return 1
    echo "Adaptive shadow выключен; стратегии по-прежнему выбирает legacy fallback."
    return 0
  fi

  if [ "${OSystem:-}" != WRT ] && [ "${hardware:-}" != keenetic ]; then
    echo "Adaptive shadow пока поддерживает OpenWrt и Keenetic Entware." >&2
    return 1
  fi
  if ! adaptive_controller_nfqws2_supports_events; then
    echo "Установленный nfqws2 не содержит C telemetry (--adaptive-events); shadow не включён." >&2
    return 1
  fi
  if [ "${OSystem:-}" = WRT ]; then
    wrt_fixes || return 1
  else
    z2r_download_project_file "$ZAPRET2_ROOT/init.d/sysv/zapret2" "Entware/zapret" || return 1
    chmod 755 "$ZAPRET2_ROOT/init.d/sysv/zapret2" || return 1
  fi
  adaptive_controller_service_install || {
    echo "Adaptive shadow пока поддерживает OpenWrt и Keenetic Entware." >&2
    return 1
  }
  adaptive_controller_install >/dev/null || return 1
  mkdir -p "$(dirname "$marker")" || return 1
  printf 'enabled\n' >"$marker.tmp.$$" && mv -f "$marker.tmp.$$" "$marker" || return 1
  chmod 600 "$marker" 2>/dev/null || :
  if [ "${OSystem:-}" = WRT ]; then
    if ! /etc/init.d/z2r-adaptive-controller enable; then
      rm -f "$marker"
      return 1
    fi
  fi
  adaptive_controller_service_action start || {
    rm -f "$marker"
    if [ "${OSystem:-}" = WRT ]; then /etc/init.d/z2r-adaptive-controller disable >/dev/null 2>&1 || true; fi
    return 1
  }
  local wait_count=0
  while [ "$wait_count" -lt 5 ] && [ ! -S /tmp/zator-adaptive/events.sock ]; do
    sleep 1
    wait_count=$((wait_count + 1))
  done
  if [ ! -S /tmp/zator-adaptive/events.sock ]; then
    rm -f "$marker"
    adaptive_controller_service_action stop >/dev/null 2>&1 || true
    if [ "${OSystem:-}" = WRT ]; then /etc/init.d/z2r-adaptive-controller disable >/dev/null 2>&1 || true; fi
    echo "Adaptive Controller не создал Unix-сокет." >&2
    return 1
  fi
  if ! z2r_service_action restart; then
    rm -f "$marker"
    adaptive_controller_service_action stop >/dev/null 2>&1 || true
    if [ "${OSystem:-}" = WRT ]; then /etc/init.d/z2r-adaptive-controller disable >/dev/null 2>&1 || true; fi
    return 1
  fi
  echo "Adaptive shadow включён. Он только пишет наблюдения и не меняет production strategy."
}
