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

adaptive_controller_release_base() {
  local raw="${Z2R_PROJECT_RAW_BASE:-}"
  local path owner repo
  case "$raw" in
    https://raw.githubusercontent.com/*/*/*)
      path="${raw#https://raw.githubusercontent.com/}"
      owner="${path%%/*}"
      path="${path#*/}"
      repo="${path%%/*}"
      case "$owner/$repo" in
        *[!A-Za-z0-9_.-]*|*/) return 1 ;;
      esac
      printf 'https://github.com/%s/%s/releases/download/latest\n' "$owner" "$repo"
      ;;
    *)
      [ -n "${Z2R_ADAPTIVE_RELEASE_BASE:-}" ] || return 1
      printf '%s\n' "${Z2R_ADAPTIVE_RELEASE_BASE%/}"
      ;;
  esac
}

# Explicit caller only. Runtime package is target-specific, statically linked,
# bounded to 144 KiB and verified against the checksum attached to the release.
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
  base="$(adaptive_controller_release_base)" || {
    echo "Не удалось определить GitHub release для Adaptive Controller." >&2
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
  [ "$size" -gt 0 ] && [ "$size" -lt 147456 ] || {
    rm -f "$tmp" "$sumtmp"
    echo "Размер Adaptive Controller выходит за лимит 144 KiB." >&2
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
  [ "${#strategy}" -le 5 ] && [ "${#qnum}" -le 5 ] || return 2
  [ "$event_socket" = /tmp/zator-adaptive/events.sock ] || return 2
  [ "$strategy" -gt 0 ] && [ "${#strategy}" -le 10 ] || return 2
  [ "$qnum" -ge 1 ] && [ "$qnum" -le 65535 ] || return 2
  [ -n "${NFQWS2_OPT:-}" ] || return 1
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
      END { if (!seen_template || !seen_strategy) exit 1 }
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
adaptive_learning_set_candidate() {
  local strategy="$1" strategy_file controller tmp lock
  strategy_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-learning.strategy"
  controller="${ZATOR_ROOT:-/opt/zator}/adaptive/bin/adaptive-controller"
  case "$strategy" in ''|*[!0-9]*) return 2 ;; esac
  [ "$strategy" -gt 0 ] && [ "${#strategy}" -le 10 ] || return 2
  adaptive_learning_enabled || { echo "Adaptive learning is not enabled." >&2; return 1; }
  [ -x "$controller" ] || { echo "adaptive-controller is not installed." >&2; return 1; }
  [ -S /tmp/zator-adaptive-learning/control.sock ] || { echo "Learning worker control socket is unavailable." >&2; return 1; }
  lock=/tmp/zator-adaptive-learning/experiment.lock
  mkdir "$lock" 2>/dev/null || { echo "A learning probe or candidate update is already running." >&2; return 1; }
  if ! adaptive_learning_config_write "$strategy" 65535 /tmp/zator-adaptive/events.sock; then
    rmdir "$lock" 2>/dev/null || :
    echo "Strategy $strategy is not present in the TLS learning plan." >&2
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

adaptive_shadow_enabled() {
  [ -f "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-shadow.enabled" ]
}

adaptive_learning_enabled() {
  [ -f "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-learning.enabled" ]
}

adaptive_learning_mark_available() {
  local mark n desync postnat filter
  mark="${Z2R_ADAPTIVE_MARK:-0x08000000}"
  case "$mark" in 0x[0-9A-Fa-f]*|[0-9]*) ;; *) return 1 ;; esac
  case "$mark" in *[!0-9A-Fa-fxX]*) return 1 ;; esac
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
  printf 'включён, strategy %s' "$strategy"
}

adaptive_learning_toggle() {
  local root marker strategy_file strategy wait_count action
  root="${ZATOR_ROOT:-/opt/zator}"
  marker="$root/extra_strats/cache/adaptive-learning.enabled"
  strategy_file="$root/extra_strats/cache/adaptive-learning.strategy"

  if adaptive_learning_enabled; then
    read -r -p "Learning активен: 1 — сменить strategy для новых flow, 0 — выключить: " action
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
      0)
        [ ! -d /tmp/zator-adaptive-learning/experiment.lock ] || {
          echo "Дождитесь завершения learning probe/candidate update." >&2
          return 1
        }
        ;;
      *) echo "Введите 1 или 0." >&2; return 2 ;;
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
  echo "Результат проверяйте в /tmp/zator-adaptive/shadow.tsv; автоматического сравнения пока нет."
}

adaptive_shadow_status_text() {
  adaptive_shadow_enabled && printf '%s' 'включён (shadow)' || printf '%s' 'выключен'
}

adaptive_shadow_toggle() {
  local marker
  marker="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-shadow.enabled"
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
