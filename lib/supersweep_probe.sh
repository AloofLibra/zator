#!/usr/bin/env bash
# Из develop: отдельная NFQUEUE, зарезервированные curl-порты и минимальный
# план nfqws2. Без adaptive-controller, телеметрийных патчей и фонового обучения.

supersweep_probe_config() {
    local profile="$1" cfg="$2" dir="${Z2R_SUPERSWEEP_DIR}/probe" f
    case "$profile" in 1|2|3|4) ;; *) return 1 ;; esac
    # Пути попадут в Lua-строку и @config: не интерпретируем shell/Lua-код.
    case "$dir" in /*) ;; *) return 1 ;; esac
    case "$dir" in *[!a-zA-Z0-9_./-]*) return 1 ;; esac
    mkdir -p "$dir" || return 1
    # Lua после drop privileges читает только приватные локи/копии настроек.
    chmod 755 "$Z2R_SUPERSWEEP_DIR" "$dir" || return 1
    sed -e "s#^local LOCKED_PATH = .*#local LOCKED_PATH = \"$dir/locked.tsv\"#" \
        -e "s#^local LOCKED_MANUAL_PATH = .*#local LOCKED_MANUAL_PATH = \"$dir/locked.manual.tsv\"#" \
        "${ZATOR_ROOT:-/opt/zator}/lua/locked.lua" > "$dir/locked.lua" || return 1
    : > "$dir/locked.tsv"
    : > "$dir/locked.manual.tsv"
    for f in blob_override.tsv mode_override.tsv sni_override.tsv clonesize.tsv; do
        [ ! -f "$ORCH_DIR/$f" ] || cp "$ORCH_DIR/$f" "$dir/$f" || return 1
    done
    # --autoexclude есть не во всех сборках: неизвестная опция валит бинарник,
    # поэтому поддержка проверяется по --help и кешируется на процесс.
    local binary="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
    case "${Z2R_SUPERSWEEP_AUTOEXCLUDE:-}" in
        0|1) ;;
        *)
            if [ -x "$binary" ] && "$binary" --help 2>&1 | grep -q -- '--autoexclude'; then
                Z2R_SUPERSWEEP_AUTOEXCLUDE=1
            else
                Z2R_SUPERSWEEP_AUTOEXCLUDE=0
            fi
            ;;
    esac
    {
        printf '%s\n' "--qnum=${Z2R_SUPERSWEEP_QNUM:-65535}" \
            "--fwmark=${DESYNC_MARK:-0x40000000}" \
            '--uid=65533:65533'
        if [ "$Z2R_SUPERSWEEP_AUTOEXCLUDE" = 1 ]; then
            printf '%s\n' '--autoexclude=0'
        fi
        printf '%s\n' \
            "--lua-init=@${ZAPRET2_ROOT:-/opt/zapret2}/lua/zapret-lib.lua" \
            "--lua-init=@${ZAPRET2_ROOT:-/opt/zapret2}/lua/zapret-antidpi.lua" \
            "--lua-init=@${ZAPRET2_ROOT:-/opt/zapret2}/lua/zapret-auto.lua" \
            "--lua-init=@$dir/locked.lua" \
            "--lua-init=@${ZATOR_ROOT:-/opt/zator}/lua/fake-adapt.lua"
        awk '
            /^NFQWS2_OPT="[[:space:]]*$/ { opts=1; next }
            opts && /^"[[:space:]]*$/ { opts=0 }
            !opts { next }
            /^--blob=/ { print; next }
            /^--template=z2r_tcp_tls_common$/ { common=1; found=1; print; next }
            common && /^--new/ { common=0; new_seen=1; print; next }
            common && /^--/ {
                if (/^--lua-desync=/) {
                    n = split($0, piece, / --lua-desync=/)
                    for (i = 1; i <= n; i++) print (i > 1 ? "--lua-desync=" : "") piece[i]
                } else print
            }
            END { if (!found || !new_seen) exit 1 }
        ' "$cfg" || return 1
    } > "$dir/nfqws2.args" || return 1
    # Только НУМЕРОВАННЫЕ стратегии нужного стандартного профиля. Исключения/
    # hostlists и детекторы не нужны: весь трафик очереди — явно выбранная проба.
    # Дописываем план после --new шаблона; каждый аргумент — отдельной строкой.
    awk -v p="$profile" '
        /^NFQWS2_OPT="[[:space:]]*$/ { opts=1; next }
        opts && /^"[[:space:]]*$/ { opts=0 }
        !opts { next }
        /^--template=z2r_tcp_tls_common$/ { common=1; found=1; next }
        common && /^--new/ { common=0; next }
        $0 == "#Z2R_AUTO_STANDARD_" p "_BEGIN" { block=1; seen=1; next }
        $0 == "#Z2R_AUTO_STANDARD_" p "_END" { block=0 }
        block {
            if (!header++) {
                print "--filter-tcp=443\n--filter-l7=tls"
                print "--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello"
                print "--out-range=-s34228"
                print "--in-range=-s32768"
                print "--lua-desync=circular_locked:key=" p
            }
            if (/^--import=/) { print; plan=1 }
            if (/^--lua-desync=/ && /:strategy=[0-9]+/) {
                n = split($0, piece, / --lua-desync=/)
                for (i = 1; i <= n; i++) print (i > 1 ? "--lua-desync=" : "") piece[i]
                plan=1
            }
            if (/^--in-range=x$/ || /^--payload=tls_client_hello,discord_ip_discovery$/) print
        }
        END { if (!found || !seen || !plan) exit 1 }
    ' "$cfg" >> "$dir/nfqws2.args" || return 1
    chmod 644 "$dir"/*.lua "$dir"/*.tsv "$dir/nfqws2.args"
}

supersweep_probe_stop() {
    # Сначала убрать маршрутизацию; затем остановить ТОЛЬКО своего ребёнка.
    if [ "${Z2R_SUPERSWEEP_TRANSPORT_ACTIVE:-0}" = 1 ]; then
        # Старый iptables без -w может упереться в чужой xtables lock — это
        # транзиент, ретраим, иначе очистка бросит живой пробник и lock.
        local t=0
        until supersweep_transport_stop; do
            t=$((t + 1))
            [ "$t" -lt 3 ] || return 1
            sleep 1
        done
        Z2R_SUPERSWEEP_TRANSPORT_ACTIVE=0
    fi
    if [ -n "${Z2R_SUPERSWEEP_NFQ_PID:-}" ]; then
        kill "$Z2R_SUPERSWEEP_NFQ_PID" 2>/dev/null || true
        wait "$Z2R_SUPERSWEEP_NFQ_PID" 2>/dev/null || true
        Z2R_SUPERSWEEP_NFQ_PID=""
    fi
    rm -f "${Z2R_SUPERSWEEP_DIR:-/tmp/z2r-supersweep}/probe/transport.env" 2>/dev/null
    unset Z2R_TLS_LOCAL_PORTS
}

supersweep_probe_healthy() {
    kill -0 "$Z2R_SUPERSWEEP_NFQ_PID" 2>/dev/null && supersweep_transport_check || return 1
    if grep -Eq 'LUA ERROR|desync ERROR' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.log"; then
        echo 'Ошибка Lua тестового nfqws2: прогон остановлен (см. probe/nfqws2.log).' >&2
        return 1
    fi
}

supersweep_probe_sequence() {
    local seq
    seq="$(awk '$1==65535 {print $8; exit}' "${Z2R_SUPERSWEEP_QUEUE_FILE:-/proc/net/netfilter/nfnetlink_queue}")" || return 1
    case "$seq" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$seq"
}

supersweep_probe_start() {
    local profile="$1" cfg="$2" dir="${Z2R_SUPERSWEEP_DIR}/probe" i=0 line
    local binary="${ZAPRET2_ROOT:-/opt/zapret2}/nfq2/nfqws2"
    local queue_file="${Z2R_SUPERSWEEP_QUEUE_FILE:-/proc/net/netfilter/nfnetlink_queue}" status key uid rest
    [ -x "$binary" ] || { echo 'nfqws2 не найден или не исполняем: фоновый прогон не запущен.' >&2; return 1; }
    [ -r "$queue_file" ] || { echo 'Ядро не экспортирует nfnetlink_queue: фоновый прогон не запущен.' >&2; return 1; }
    # Никогда не отбирать очередь у другого nfqws2.
    ! awk '$1==65535 {found=1} END {exit !found}' "$queue_file" \
        || { echo 'Очередь 65535 занята другим процессом: остановите его или подождите.' >&2; return 1; }
    # Свой UID отличает raw-сегменты от основного nfqws2 даже когда
    # сторонний OUTPUT переписал их DESYNC_MARK.
    if awk -F: '$3==65533 {found=1} END {exit !found}' /etc/passwd; then
        echo 'UID 65533 уже занят: фоновый прогон не запущен.' >&2; return 1
    fi
    for status in /proc/[0-9]*/status; do
        [ -r "$status" ] || continue
        while read -r key uid rest; do
            [ "$key" = Uid: ] || continue
            [ "$uid" != 65533 ] || { echo 'UID 65533 уже используется процессом.' >&2; return 1; }
            break
        done < "$status" 2>/dev/null || true
    done
    supersweep_probe_config "$profile" "$cfg" || return 1
    local args=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        args+=("$line")
    done < "$dir/nfqws2.args"
    [ "${#args[@]}" -gt 0 ] || return 1
    # Передаём argv напрямую: разбор @-файлов различается между сборками nfqws2.
    "$binary" "${args[@]}" > "$dir/nfqws2.log" 2>&1 </dev/null &
    Z2R_SUPERSWEEP_NFQ_PID=$!
    i=0
    while [ "$i" -lt 5 ]; do
        kill -0 "$Z2R_SUPERSWEEP_NFQ_PID" 2>/dev/null || { supersweep_probe_stop; return 1; }
        awk '$1==65535 {found=1} END {exit !found}' "$queue_file" && break
        sleep 1
        i=$((i + 1))
    done
    if [ "$i" = 5 ]; then supersweep_probe_stop; return 1; fi
    Z2R_SUPERSWEEP_TRANSPORT_ACTIVE=1
    if ! supersweep_transport_start; then
        supersweep_transport_stop 2>/dev/null || :
        sleep 2
        if ! supersweep_transport_start; then
            supersweep_probe_stop
            echo 'Не удалось установить правила транспорта: фоновый прогон не запущен.' >&2
            return 1
        fi
    fi
    {
        printf 'FWTYPE=%s\n' "$FWTYPE"
        printf 'DESYNC_MARK=%s\n' "$DESYNC_MARK"
        printf 'DESYNC_MARK_POSTNAT=%s\n' "${DESYNC_MARK_POSTNAT:-0x20000000}"
        printf 'POSTNAT=%s\n' "${POSTNAT:-1}"
        printf 'POSTNAT_ALL=%s\n' "${POSTNAT_ALL:-0}"
        printf 'ZAPRET_NFT_TABLE=%s\n' "${ZAPRET_NFT_TABLE:-zapret2}"
        printf 'FILTER_MARK=%s\n' "${FILTER_MARK:-0}"
        printf 'CLIENT_SCOPE_MARK_MASK=%s\n' "${CLIENT_SCOPE_MARK_MASK:-0}"
    } > "$dir/transport.env" 2>/dev/null || : && chmod 644 "$dir/transport.env" 2>/dev/null
    export Z2R_TLS_LOCAL_PORTS=62000-62999
}

supersweep_background_start() {
    local cfg="$1" lib="${LIB_DIR:-${BASH_SOURCE[0]%/*}}" dir="$Z2R_SUPERSWEEP_DIR"
    local job_control=0
    shift
    [ -r "$lib/supersweep_probe.sh" ] && [ -r "$lib/supersweep_transport.sh" ] || return 1
    (umask 077; mkdir "${dir}.lock") 2>/dev/null || {
        echo 'Суперавтопрогон уже запущен.' >&2; return 1;
    }
    # Живой процесс прошлого прогона при удалённом lock (прерванный cleanup)
    # топтал бы файлы и cancel нового: без него нельзя стартовать.
    local proc_cmdline arg previous runner_found
    for proc_cmdline in /proc/[0-9]*/cmdline; do
        previous=""
        runner_found=0
        while IFS= read -r -d '' arg; do
            case "$previous" in
                supersweep_probe.sh|*/supersweep_probe.sh)
                    if [ "$arg" = --run ]; then
                        runner_found=1
                        break
                    fi
                    ;;
            esac
            previous="$arg"
        done 2>/dev/null < "$proc_cmdline" || true
        if [ "$runner_found" = 1 ]; then
            rmdir "${dir}.lock" 2>/dev/null || true
            echo 'Обнаружен живой процесс прошлого фонового прогона: дождитесь его завершения или остановите (меню 12).' >&2
            return 1
        fi
    done
    # Старые Entware без setsid: отдельная группа фоновой job, только при
    # живом tty (set -m на закрытой CGI-pty может зависнуть).
    if ! command -v setsid >/dev/null 2>&1 && [ -t 0 ]; then
        case "$-" in *m*) ;; *) set -m; job_control=1 ;; esac
    fi
    (
        # OpenWrt без nohup: игнор HUP наследуется после exec, потоки уже перенаправлены.
        trap '' HUP INT QUIT
        export Z2R_SUPERSWEEP_LOCK_HELD=1 Z2R_SUPERSWEEP_ISOLATED=1
        export Z2R_SUPERSWEEP_DIR ZATOR_ROOT ZAPRET2_ROOT ORCH_DIR ORCH_LOCK_FILE
        export Z2R_MEDIA_VIDEO_ID
        export ORCH_ACTIVE_SCOPE="${ORCH_ACTIVE_SCOPE:-default}"
        export Z2R_SUPERSWEEP_ARCHIVE_DIR Z2R_SUPERSWEEP_STATS_URL TELEMETRY_CFG
        export CONFIG_FILE="$cfg"
        if command -v setsid >/dev/null 2>&1; then
            exec setsid bash "$lib/supersweep_probe.sh" --run "$@"
        fi
        exec bash "$lib/supersweep_probe.sh" --run "$@"
    ) > "${dir}.log" 2>&1 </dev/null &
    local pid=$!
    [ "$job_control" != 1 ] || set +m
    printf '%s\n' "$pid" > "${dir}.lock/pid"
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "${dir}.lock/pid"
        rmdir "${dir}.lock" 2>/dev/null || true
        echo "Фоновый запуск не удался: ${dir}.log" >&2
        return 1
    fi
    echo "Суперавтопрогон запущен в фоне. Лог: ${dir}.log"
}

if [ "${1:-}" = --run ]; then
    shift
    LIB_DIR="${BASH_SOURCE[0]%/*}"
    telemetry_cfg="${TELEMETRY_CFG:-${ZATOR_ROOT:-/opt/zator}/z2r_lib/telemetry.config}"
    for lib in config orchestra_state ui netcheck strategies telemetry supersweep supersweep_transport; do
        source "$LIB_DIR/$lib.sh" || exit 1
    done
    CACHE_DIR="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache"
    TELEMETRY_CFG="$telemetry_cfg"
    PROVIDER_TXT="$CACHE_DIR/provider.txt"
    get_config_file() { printf '%s\n' "$CONFIG_FILE"; }
    # Настройки firewall читаем как данные, не source-им пользовательский config.
    FWTYPE="$(config_get_var "$CONFIG_FILE" FWTYPE | tr -d '\"\047')"
    DESYNC_MARK="$(config_get_var "$CONFIG_FILE" DESYNC_MARK | tr -d '\"\047')"
    DESYNC_MARK_POSTNAT="$(config_get_var "$CONFIG_FILE" DESYNC_MARK_POSTNAT | tr -d '\"\047')"
    POSTNAT="$(config_get_var "$CONFIG_FILE" POSTNAT | tr -d '\"\047')"
    POSTNAT_ALL="$(config_get_var "$CONFIG_FILE" POSTNAT_ALL | tr -d '\"\047')"
    ZAPRET_NFT_TABLE="$(config_get_var "$CONFIG_FILE" ZAPRET_NFT_TABLE | tr -d '\"\047')"
    FILTER_MARK="$(config_get_var "$CONFIG_FILE" FILTER_MARK | tr -d '\"\047')"
    CLIENT_SCOPE_MARK_MASK="$(config_get_var "$CONFIG_FILE" CLIENT_SCOPE_MARK_MASK | tr -d '\"\047')"
    export FWTYPE DESYNC_MARK DESYNC_MARK_POSTNAT
    # This advertised PID owns the probe/worker and waits for their cleanup.
    # Keep the inherited ignored HUP/INT for detached operation.
    trap '_supersweep_cleanup' EXIT
    trap 'exit 143' TERM
    _supersweep_run "$@"
    exit $?
fi
