# This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
#!/bin/bash
# QUIC-медиапроверка профиля 5: перебор UDP-стратегий с проверкой googlevideo
# по HTTP/3 с самого роутера. Транспортных правил, выделенных портов и
# изолированных probe-инстансов не нужно: прод-NFQUEUE-правило (mangle
# POSTROUTING, connbytes 1:5) покрывает роутер-исходящий трафик — обычный
# curl --http3-only с роутера обрабатывается прод-nfqws2 с реально залоченной
# стратегией (лок читает Lua из locked.tsv, TTL ~2с + устаканивание ~3с).
#
# Вердикты учитывают поведение TSPU (измерено 15.11): QUIC к googlevideo
# держится вероятностно и окнами, поэтому ОДНА проба одного места — не
# вердикт. На стратегию 5 проб: три куска ПОДРЯД от начала ролика (симуляция
# прогрессивной загрузки плеером) + случайная середина + случайный кусок у
# конца. Случайные позиции общие на весь прогон: между прогонами разные
# места, внутри прогона честное сравнение стратегий. Видно и «начало не
# идёт, дальше стабильно», и «работает, потом деградирует».
# green (все куски), warn/нестабильно (прошла часть — с указанием, какой
# именно), unknown (CDN ответил отказом — транспорт жив, медиа нет),
# held (все попытки без ответа). Z2R_QUIC_ROUNDS (1..5, спрашивается в
# диалоге) добавляет повторы полного круга проб по той же стратегии подряд
# — больше статистики и лучше видно окна TSPU; зелёный только если все
# повторы зелёные. Если всё красное — возможен холд окна, а не вина
# стратегий: итог печатает оговорку, как z2r_youtube_reboot_advice для TCP.
#
# Модуль необязательный (как youtube_media.sh): старый bootstrap может его
# не доставить — без него пункт A подбора профиля 5 просто не предлагается.

Z2R_QUIC_PROBE_BYTES_DEFAULT=1048576
Z2R_QUIC_CURL_SIZE_LIMIT=10485760

if ! type z2r_media_prepare >/dev/null 2>&1 \
    && [ -f "${LIB_DIR:-${BASH_SOURCE[0]%/*}}/youtube_media.sh" ]; then
    source "${LIB_DIR:-${BASH_SOURCE[0]%/*}}/youtube_media.sh"
fi

# Цвета для standalone-запуска; в меню их задаёт z2r.sh.
[ -z "${plain:-}" ] && plain='\033[0m'
[ -z "${red:-}" ] && red='\033[0;31m'
[ -z "${green:-}" ] && green='\033[0;32m'
[ -z "${yellow:-}" ] && yellow='\033[0;33m'
[ -z "${cyan:-}" ] && cyan='\033[0;36m'
[ -z "${Fgreen:-}" ] && Fgreen='\033[1;32m'

# --- h3-curl: детект и установка ---------------------------------------------

# Byte 6 ELF-заголовка: 1 = little-endian, 2 = big-endian (как у сниффера).
z2r_quic_elf_endian() {
    local elf value
    elf="${Z2R_QUIC_ELF_FILE:-}"
    [ -n "$elf" ] || elf=/proc/self/exe
    [ -r "$elf" ] || return 1
    # od -b — единственная форма байт-дампа и в GNU od, и в busybox od Entware.
    value="$(dd if="$elf" bs=1 skip=5 count=1 2>/dev/null | od -b 2>/dev/null | awk 'NR==1 {print $2; exit}')"
    case "$value" in
        001|1) echo little; return 0 ;;
        002|2) echo big; return 0 ;;
        *) return 1 ;;
    esac
}

# Имя артефакта z2r-curl-h3-linux-<arch>.gz. MIPS-эндзианесс по ELF-байту
# (uname на MIPS не различает), little-endian — доминирующий случай роутеров.
z2r_quic_curl_arch() {
    local machine endian platform_arch
    machine="$(uname -m 2>/dev/null)"
    case "$machine" in
        x86_64|amd64) echo x86_64 ;;
        i386|i486|i586|i686) echo i686 ;;
        aarch64|arm64) echo aarch64 ;;
        arm|armv6l|armv7l|armv8l) echo arm ;;
        mipsel*|mipsle*) echo mipsel ;;
        mips*)
            endian="$(z2r_quic_elf_endian 2>/dev/null)" || endian=""
            if [ -z "$endian" ] && [ -r "${Z2R_QUIC_OPENWRT_RELEASE:-/etc/openwrt_release}" ]; then
                platform_arch="$(sed -n 's/^DISTRIB_ARCH=//p' "${Z2R_QUIC_OPENWRT_RELEASE:-/etc/openwrt_release}" | head -n1 | tr -d "'\"")"
                case "$platform_arch" in
                    mipsel*|mipsle*) endian=little ;;
                    mips*) endian=big ;;
                esac
            fi
            if [ -z "$endian" ] && command -v opkg >/dev/null 2>&1; then
                platform_arch="$(opkg print-architecture 2>/dev/null | awk '$2 != "all" && $2 != "noarch" {print $2; exit}')"
                case "$platform_arch" in
                    mipsel*|mipsle*) endian=little ;;
                    mips*) endian=big ;;
                esac
            fi
            case "$endian" in
                big) echo mipssf ;;
                *) echo mipsel ;;
            esac ;;
        riscv64) echo riscv64 ;;
        *) return 1 ;;
    esac
}

# Рабочий h3-curl: $Z2R_QUIC_CURL env → /opt/bin/curl (Entware-сборка с
# OpenSSL QUIC) → $ZATOR_ROOT/tools/bin/curl-h3-<arch> (наш установленный) →
# curl из PATH. Печатает путь; rc=1 если HTTP3 нигде не найден.
z2r_quic_curl_detect() {
    local bin arch=""
    arch="$(z2r_quic_curl_arch 2>/dev/null)" || arch=""
    while IFS= read -r bin; do
        [ -n "$bin" ] || continue
        { [ -x "$bin" ] || command -v "$bin" >/dev/null 2>&1; } || continue
        "$bin" --version 2>/dev/null | grep -qiE 'HTTP3|nghttp3' || continue
        printf '%s\n' "$bin"
        return 0
    done <<EOF
${Z2R_QUIC_CURL:-}
/opt/bin/curl
${arch:+${ZATOR_ROOT:-/opt/zator}/tools/bin/curl-h3-$arch}
curl
EOF
    return 1
}

# CA-бандл обязателен: компилированный путь curl на Entware не существует,
# а вызовы с -q (весь наш код) игнорируют curlrc — спасает только env.
z2r_quic_ca_bundle() {
    local p="${Z2R_QUIC_CA_BUNDLE:-}"
    if [ -n "$p" ]; then
        [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
        return 1
    fi
    for p in /opt/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt; do
        [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# Установка бинарника по образцу googlevideo_sniffer_install: релизы zator
# (TRACKING → latest, base-override Z2R_CURL_H3_RELEASE_BASE), gzip -t,
# потолок размера. Не удалось — rc=1 (вызывающий предлагает режим без проверки).
z2r_quic_curl_install() {
    local arch base fallback tracking tmp compressed size release reason dest
    [ "${Z2R_OFFLINE:-0}" != 1 ] || return 1
    arch="$(z2r_quic_curl_arch)" || {
        echo "h3-curl: не удалось определить архитектуру платформы ($(uname -m 2>/dev/null)), установка отменена." >&2
        return 1
    }
    dest="${ZATOR_ROOT:-/opt/zator}/tools/bin/curl-h3-$arch"
    if [ -x "$dest" ]; then
        echo "h3-curl: уже установлен ($dest)." >&2
        return 0
    fi
    # Бинарники живут отдельным репозиторием (MarkinAlexander/z2r-curl-h3):
    # rolling-релиз latest + версионные теги, override для зеркал/тестов.
    base="${Z2R_CURL_H3_RELEASE_BASE:-https://github.com/MarkinAlexander/z2r-curl-h3/releases/download/latest}"
    fallback="${Z2R_CURL_H3_RELEASE_FALLBACK:-}"
    mkdir -p "${ZATOR_ROOT:-/opt/zator}/tools/bin" || {
        echo "h3-curl: не удалось создать каталог ${ZATOR_ROOT:-/opt/zator}/tools/bin." >&2
        return 1
    }
    tmp="$dest.tmp.$$"
    compressed="$tmp.gz"
    reason="не удалось скачать z2r-curl-h3-linux-$arch.gz (нет curl/wget или источник недоступен)"
    for release in "$base" "$fallback"; do
        [ -n "$release" ] || continue
        reason="не удалось скачать z2r-curl-h3-linux-$arch.gz с $release"
        if { if command -v curl >/dev/null 2>&1; then
               curl -fLsS --connect-timeout 8 --max-time 120 --max-filesize 20971520 \
                   "$release/z2r-curl-h3-linux-$arch.gz" -o "$compressed" 2>/dev/null
             elif command -v wget >/dev/null 2>&1; then
               wget -q -T 120 -O "$compressed" "$release/z2r-curl-h3-linux-$arch.gz" 2>/dev/null
             else
               false
             fi
           } && gzip -t "$compressed" 2>/dev/null; then
            # Распаковка ограничена сверху: битый архив не должен съесть flash.
            gzip -dc "$compressed" 2>/dev/null | head -c $((Z2R_QUIC_CURL_SIZE_LIMIT + 1)) > "$tmp" 2>/dev/null
            size="$(wc -c < "$tmp" | tr -d ' ')"
            case "$size" in ''|*[!0-9]*) reason="нечитаемый размер артефакта с $release"; continue ;; esac
            if [ "$size" -le "$Z2R_QUIC_CURL_SIZE_LIMIT" ] && [ "$size" -ge 1048576 ] && [ -s "$tmp" ]; then
                # set -e: сбой chmod/mv не должен убить вызывающее меню — уйти в следующий source.
                if chmod 755 "$tmp" && mv -f "$tmp" "$dest"; then
                    reason=""
                    break
                fi
                reason="не удалось установить артефакт с $release (chmod/mv)"
                continue
            fi
            reason="артефакт с $release отброшен: ${size:-?} байт при лимите $Z2R_QUIC_CURL_SIZE_LIMIT"
        fi
    done
    if [ -z "$reason" ]; then
        echo "h3-curl: установлен $dest." >&2
        rm -f "$tmp" "$compressed"
        return 0
    fi
    echo "h3-curl: бинарник не установлен ($reason)." >&2
    rm -f "$tmp" "$compressed"
    return 1
}

# Детект + предложение установки (диалог). rc=0 — h3-curl есть.
z2r_quic_offer_install() {
    z2r_quic_curl_detect >/dev/null 2>&1 && return 0
    echo -e "${yellow}h3-curl не найден: проверка видео по HTTP/3 недоступна.${plain}" >&2
    local ans
    read -re -p "Скачать и установить h3-curl (репозиторий z2r-curl-h3)? 1 - да, Enter - нет: " ans || ans=""
    [ "$ans" = "1" ] || return 1
    z2r_quic_curl_install || return 1
    z2r_quic_curl_detect >/dev/null 2>&1
}

# --- Пробы --------------------------------------------------------------------

_z2r_quic_settle() {
    local s="${1:-${Z2R_QUIC_SETTLE:-3}}"
    case "$s" in ''|*[!0-9]*) s=3 ;; esac
    [ "$s" -gt 0 ] && sleep "$s"
    return 0   # set -e: s=0 даёт rc 1 у [ — не должен убивать вызывающего
}

_z2r_quic_attempt_pause() {
    local s="${Z2R_QUIC_ATTEMPT_PAUSE:-3}"
    case "$s" in ''|*[!0-9]*) s=3 ;; esac
    [ "$s" -gt 0 ] && sleep "$s"
    return 0
}

# Один h3-GET с роутера по подписанной ссылке из кеша медиа ($dir/$kind.curl —
# URL никогда не в argv и не в логах). count — размер фрагмента, offset —
# смещение в потоке в байтах (0 — начало ролика). Формат колонок
# z2r_media_probe + ver:
#   state|reason|rc|ver|code|bytes|tcp|tls|ttfb|total|speed
# ver — %{http_version}: зелёный только при ver=3 (проверяется именно h3).
z2r_quic_probe() (
    trap - EXIT
    umask 077
    local dir="$1" kind="$2" count="$3" offset="$4"
    local length mime host expire end rc pid curl_bin ca
    local code ver bytes tcp tls ttfb total speed state reason range_valid
    local url_override="${5:-}" redirects="${6:-2}" config
    local headers="$dir/quic-headers" metrics="$dir/quic-metrics"
    case "$kind" in audio|video) ;; *) return 1 ;; esac
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    [ "$count" -ge 4096 ] && [ "$count" -le 2097152 ] || return 1
    case "$offset" in ''|*[!0-9]*) return 1 ;; esac
    IFS='|' read -r length mime host expire 2>/dev/null < "$dir/$kind.params" || return 1
    # Не скачивать целиком даже короткий поток; диапазон ограничен четвертью.
    [ "$count" -le $((length / 4)) ] || count=$((length / 4))
    [ "$offset" -le $((length - count)) ] || offset=$((length - count))
    end=$((offset + count - 1))
    config="$dir/$kind.curl"
    curl_bin="${Z2R_QUIC_CURL:-}"
    [ -n "$curl_bin" ] || curl_bin=curl
    # CA-бандл обязателен на Entware (-q игнорирует curlrc): экспорт в этот
    # subshell, обычным переменным окружения ничего не достаётся.
    if ca="$(z2r_quic_ca_bundle)"; then export CURL_CA_BUNDLE="$ca"; fi
    # Один владелец EXIT cleanup на всю цепочку перенаправлений.
    trap '{ [ -z "${pid:-}" ] || { kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; }
        rm -f "$dir/quic-curl.conf" "$headers" "$metrics"; } 2>/dev/null' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    while :; do
        if ! z2r_media_fresh "$dir"; then
            printf 'UNKNOWN|expired|0|0|000|0|0|0|0|0|0\n'; return 0
        fi
        if [ -n "$url_override" ]; then
            # Только подписанный redirect CDN; URL по-прежнему не в argv.
            z2r_media_url_valid "$url_override" || return 1
            config="$dir/quic-curl.conf"
            printf 'url = "%s"\n' "$url_override" > "$config" || return 1
        fi
        # Один curl = новое QUIC-соединение. stderr не должен раскрывать URL.
        "$curl_bin" -q -4 --noproxy '*' --http3-only -s \
            --config "$config" -A "$(z2r_media_ua)" \
            --range "$offset-$end" --max-filesize "$count" --limit-rate 2M \
            --connect-timeout 5 --max-time 15 --speed-limit 1024 --speed-time 10 \
            -D "$headers" -o /dev/null \
            -w '%{http_code}|%{size_download}|%{http_version}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{speed_download}' \
            > "$metrics" 2>/dev/null </dev/null &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            if [ -n "${Z2R_QUIC_SWEEP_DIR:-}" ] && [ -e "$Z2R_QUIC_SWEEP_DIR/cancel" ]; then
                kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; pid=
                printf 'UNKNOWN|cancelled|0|0|000|0|0|0|0|0|0\n'; return 0
            fi
            sleep 1
        done
        rc=0; wait "$pid" || rc=$?; pid=
        # curl без единого байта ответа не создаёт -D файл — awk ниже сыпал
        # «No such file or directory» в весь HELD-путь (каждая из 5 позиций).
        [ -f "$headers" ] || : > "$headers"
        # -w: code|bytes|ver|tcp|tls|ttfb|total|speed
        IFS='|' read -r code bytes ver tcp tls ttfb total speed < "$metrics" || :
        case "$code" in
            301|302|307|308)
                location=$(awk 'tolower($1)=="location:" {sub(/^[^:]*:[ ]*/, "");sub(/\r$/, "");print;exit}' "$headers")
                if [ "$rc" = 0 ] && [ "$redirects" -gt 0 ] && z2r_media_url_valid "$location"; then
                    url_override=$location
                    redirects=$((redirects - 1))
                    continue
                fi
                ;;
        esac
        range_valid=$(awk -v expected="bytes $offset-$end/$length" -v mime="$mime" '
            /^HTTP\// {range="";type=""}
            {sub(/\r$/, ""); key=tolower($1); if(key=="content-range:") {sub(/^[^:]*:[ ]*/, "");range=$0}
             if(key=="content-type:") {sub(/^[^:]*:[ ]*/, "");split($0,a,";");type=a[1]}}
            END {print (range==expected && type==mime)?"valid":"invalid"}' "$headers")
        state=UNKNOWN; reason=invalid_response
        case "$code" in
            403) reason=cdn_403 ;;
            429) reason=rate_limited ;;
            503) reason=cdn_503 ;;
            206)
                if [ "$rc" = 0 ] && [ "$ver" = 3 ] && [ "$range_valid" = valid ] && [ "$bytes" = "$count" ]; then
                    state=OK; reason=media_h3
                elif [ "$ver" != "3" ]; then
                    reason=not_h3
                elif [ "$range_valid" = valid ]; then
                    case "$rc" in 0|18|28|56) state=FAIL; reason=incomplete_transfer ;; esac
                fi ;;
            000)
                reason=network_error
                [ "$rc" != 6 ] || reason=dns_error
                case "$rc" in 7|18|28|35|52|55|56) state=FAIL ;; esac ;;
        esac
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$state" "$reason" "$rc" "${ver:-0}" "${code:-000}" "${bytes:-0}" \
            "${tcp:-0}" "${tls:-0}" "${ttfb:-0}" "${total:-0}" "${speed:-0}"
        return 0
    done
)

# Одна проверка медиа для ТЕКУЩЕГО лока (стратегию ставит вызывающий):
# видео с позиции pct (по умолчанию середина), размер Z2R_QUIC_PROBE_BYTES
# (по доке ≤2МиБ на GET).
# Одна проверка медиа для ТЕКУЩЕГО лока (стратегию ставит вызывающий).
# key: 1|2|3 — куски подряд от начала ролика (0, count, 2*count);
# mid — случайная середина; end — случайный кусок ближе к концу.
# Для честного сравнения стратегий позиции mid/end фиксируются на ВЕСЬ прогон
# (Z2R_QUIC_MID_PCT / Z2R_QUIC_END_PCT задаёт перебор; без них — своя
# случайная на каждый вызов). Размер куска = Z2R_QUIC_PROBE_BYTES (по доке
# ≤2МиБ, не более четверти потока). Z2R_QUIC_JITTER — случайное смещение
# ±N% от куска на каждую пробу (0 — детерминированно).
z2r_quic_check() {
    local key="${1:-1}" count="${Z2R_QUIC_PROBE_BYTES:-$Z2R_QUIC_PROBE_BYTES_DEFAULT}" row
    local length mime host expire jitter span offset max_off pct
    case "$key" in 1|2|3|mid|end) ;; *) key=1 ;; esac
    case "$count" in ''|*[!0-9]*) count="$Z2R_QUIC_PROBE_BYTES_DEFAULT" ;; esac
    [ "$count" -ge 4096 ] && [ "$count" -le 2097152 ] || count="$Z2R_QUIC_PROBE_BYTES_DEFAULT"
    if [ "${Z2R_MEDIA_READY:-0}" != 1 ] || [ -z "${Z2R_MEDIA_DIR:-}" ]; then
        printf 'UNKNOWN|resolver_unavailable|0|0|000|0|0|0|0|0|0\n'; return 0
    fi
    if [ ! -s "$Z2R_MEDIA_DIR/video.params" ]; then
        printf 'UNKNOWN|invalid_params|0|0|000|0|0|0|0|0|0\n'; return 0
    fi
    IFS='|' read -r length mime host expire < "$Z2R_MEDIA_DIR/video.params" || length=0
    case "$length" in ''|*[!0-9]*) length=0 ;; esac
    [ "$length" -gt 0 ] || { printf 'UNKNOWN|invalid_params|0|0|000|0|0|0|0|0|0\n'; return 0; }
    [ "$count" -le $((length / 4)) ] || count=$((length / 4))
    case "$key" in
        1) offset=0 ;;
        2) offset="$count" ;;
        3) offset=$((count * 2)) ;;
        mid)
            pct="${Z2R_QUIC_MID_PCT:-$((25 + (RANDOM % 51)))}"
            case "$pct" in ''|*[!0-9]*) pct=50 ;; esac
            [ "$pct" -lt 25 ] && pct=25
            [ "$pct" -gt 75 ] && pct=75
            offset=$((length * pct / 100)) ;;
        end)
            pct="${Z2R_QUIC_END_PCT:-$((87 + (RANDOM % 14)))}"
            case "$pct" in ''|*[!0-9]*) pct=93 ;; esac
            [ "$pct" -lt 87 ] && pct=87
            [ "$pct" -gt 100 ] && pct=100
            offset=$((length * pct / 100)) ;;
    esac
    jitter="${Z2R_QUIC_JITTER:-0}"
    case "$jitter" in ''|*[!0-9]*) jitter=0 ;; esac
    [ "$jitter" -le 90 ] || jitter=90
    if [ "$jitter" -gt 0 ]; then
        span=$((count * jitter / 100))
        offset=$((offset + (RANDOM % (2 * span + 1)) - span))
    fi
    [ "$offset" -lt 0 ] && offset=0
    max_off=$((length - count))
    [ "$offset" -gt "$max_off" ] && offset=$max_off
    row=$(z2r_quic_probe "$Z2R_MEDIA_DIR" video "$count" "$offset") \
        || row='UNKNOWN|probe_error|0|0|000|0|0|0|0|0|0'
    printf '%s\n' "$row"
}

_z2r_quic_speed_mbps() {
    awk -v s="${1:-0}" 'BEGIN{printf "%.1f", (s + 0) / 1048576}'
}

# План проб стратегии (фиксированный): три куска ПОДРЯД от начала ролика
# (симуляция прогрессивной загрузки плеером, детерминированно — сравнимо
# между стратегиями), затем случайная середина и случайный кусок у конца.
# Случайные позиции общие для всего прогона (задаёт z2r_quic_sweep_run) —
# между прогонами разные, внутри прогона честное сравнение стратегий.
_z2r_quic_plan() {
    printf '1 2 3 mid end'
}

_z2r_quic_pos_label() {
    case "$1" in
        1) echo "кусок 1" ;;
        2) echo "кусок 2" ;;
        3) echo "кусок 3" ;;
        mid) echo "середина" ;;
        *) echo "конец" ;;
    esac
}

# Короткая метка причины падения для списка «падали: ...».
_z2r_quic_fail_mark() {
    case "$1" in
        cdn_403) echo "CDN 403" ;;
        rate_limited) echo "429" ;;
        cdn_503) echo "503" ;;
        not_h3) echo "не h3" ;;
        incomplete_transfer) echo "срез" ;;
        dns_error) echo "DNS" ;;
        ca_error) echo "CA" ;;
        expired) echo "истекло" ;;
        *) echo "нет ответа" ;;
    esac
}

# Short-текст вердикта, когда медиа так и не пошло. unknown важнее held:
# CDN-отказ значит, что транспорт жив (хотя бы раз ответил).
_z2r_quic_fail_short() {
    local r1="$1" r2="$2"
    case "$r1 $r2" in
        *cdn_403*) printf 'unknown|медиа нет: CDN отказал (403)\n' ;;
        *rate_limited*) printf 'unknown|медиа нет: лимит CDN (429)\n' ;;
        *cdn_503*) printf 'unknown|медиа нет: CDN 503\n' ;;
        *not_h3*) printf 'unknown|транспорт ответил не по HTTP/3\n' ;;
        *ca_error*) printf 'unknown|curl не проверил сертификат (CA-бандл)\n' ;;
        *dns_error*) printf 'unknown|DNS не ответил — ошибка теста, не стратегии\n' ;;
        *expired*) printf 'unknown|подписанные ссылки истекли\n' ;;
        *) printf 'held|все попытки без ответа — возможно окно холда\n' ;;
    esac
}

# Один полный круг проб (план из 5 позиций) для ТЕКУЩЕГО лока.
# stdout: verdict|speed|short, verdict = green|warn|unknown|held|cancelled;
# speed — сумма скоростей прошедших проб (сравнима между стратегиями).
# Ход проб показывается строкой-анимацией в stderr (только на tty),
# чтобы между баннером и первым вердиктом не было ощущения «висит».
# Анимация: «стереть-потом-писать» (\r\033[K перед текстом) и тексты
# КОРОЧЕ 40 символов — длинные строки переносятся на узких терминалах,
# и \r чистит только первую строку экрана (хвосты вида «…т ответа»).
z2r_quic_single_round() {
    local s="$1"
    local key label row st re bt tt sp out mark
    local ok_n=0 speed_sum=0 ok_positions="" fail_details=""
    local re_first="" re_last="" i=0 total
    for key in $(_z2r_quic_plan); do
        label="$(_z2r_quic_pos_label "$key")"
        [ "$i" = 0 ] || _z2r_quic_attempt_pause
        i=$((i + 1))
        if [ -t 2 ]; then
            printf '\r\033[K[%s] проба %d/5 (%s)...' "$s" "$i" "$label" >&2
        fi
        row="$(z2r_quic_check "$key")" || row=""
        case "$row" in
            ''|*cancelled*)
                [ -t 2 ] && printf '\r\033[K' >&2
                printf 'cancelled|0|\n'; return 0 ;;
        esac
        IFS='|' read -r st re _ _ _ bt _ _ _ tt sp <<EOF
$row
EOF
        if [ "$st" = "OK" ]; then
            ok_n=$((ok_n + 1))
            speed_sum="$(awk -v a="$speed_sum" -v b="$sp" 'BEGIN{printf "%.0f", a + b}')"
            ok_positions="${ok_positions}${ok_positions:+, }${label}"
            if [ -t 2 ]; then
                printf '\r\033[K[%s] проба %d/5 (%s): OK, %s МБ/с' \
                    "$s" "$i" "$label" "$(_z2r_quic_speed_mbps "$sp")" >&2
            fi
        else
            mark="$(_z2r_quic_fail_mark "$re")"
            fail_details="${fail_details}${fail_details:+, }${label} — ${mark}"
            [ -n "$re_first" ] || re_first="$re"
            re_last="$re"
            if [ -t 2 ]; then
                printf '\r\033[K[%s] проба %d/5 (%s): %s' "$s" "$i" "$label" "$mark" >&2
            fi
        fi
    done
    total="$i"
    if [ "$ok_n" -eq "$total" ]; then
        out="$(printf 'green|%s|h3 %s/%s (%s): %s МБ/с' \
            "$speed_sum" "$ok_n" "$total" "$ok_positions" \
            "$(_z2r_quic_speed_mbps "$(awk -v s="$speed_sum" -v n="$total" 'BEGIN{printf "%.0f", s / n}')")")"
    elif [ "$ok_n" -eq 0 ]; then
        out="$(_z2r_quic_fail_short "$re_first" "$re_last")"
    else
        out="$(printf 'warn|%s|нестабильно: %s/%s прошло (OK: %s; %s), %s МБ/с' \
            "$speed_sum" "$ok_n" "$total" "$ok_positions" "$fail_details" \
            "$(_z2r_quic_speed_mbps "$(awk -v s="$speed_sum" -v n="$ok_n" 'BEGIN{printf "%.0f", s / n}')")")"
    fi
    [ -t 2 ] && printf '\r\033[K' >&2
    printf '%s\n' "$out"
    return 0
}

# Вердикт одной стратегии: Z2R_QUIC_ROUNDS повторов полного круга проб
# (1..5, по умолчанию 1), один за другим по той же стратегии — больше
# статистики и лучше видно окна TSPU. Позиции середины/конца общие на весь
# прогон, поэтому повторы меряют одни и те же места.
# Агрегация: green — все повторы зелёные; warn — часть повторов зелёная или
# нестабильные повторы; unknown/held — все повторы одного типа. Итог каждого
# повтора печатается в stderr (кроме одиночного — он и есть итог).
# stdout: verdict|speed|short.
z2r_quic_strategy_verdict() {
    local s="$1"
    local rounds="${Z2R_QUIC_ROUNDS:-1}"
    case "$rounds" in ''|*[!0-9]*) rounds=1 ;; esac
    [ "$rounds" -ge 1 ] || rounds=1
    [ "$rounds" -le 5 ] || rounds=5
    local r out token rest speed short
    local n_g=0 n_w=0 n_u=0 n_h=0 sum_speed=0
    local last_token="" last_short="" disp
    for ((r = 1; r <= rounds; r++)); do
        out="$(z2r_quic_single_round "$s")" || out=""
        token="${out%%|*}"; rest="${out#*|}"; speed="${rest%%|*}"; short="${rest#*|}"
        if [ "$token" = "cancelled" ] || [ -z "$out" ]; then
            printf 'cancelled|0|\n'; return 0
        fi
        case "$token" in
            green)   n_g=$((n_g + 1)) ;;
            warn)    n_w=$((n_w + 1)) ;;
            unknown) n_u=$((n_u + 1)) ;;
            *)       token="held"; n_h=$((n_h + 1)) ;;
        esac
        sum_speed="$(awk -v a="$sum_speed" -v b="$speed" 'BEGIN{printf "%.0f", a + b}')"
        last_token="$token"; last_short="$short"
        if [ "$rounds" -gt 1 ]; then
            case "$token" in
                green)   disp="${green}OK${plain}" ;;
                warn)    disp="${yellow}WARN${plain}" ;;
                unknown) disp="${yellow}UNKNOWN${plain}" ;;
                held)    disp="${red}HELD${plain}" ;;
            esac
            printf '  повтор %d/%d: %b %b\n' "$r" "$rounds" "$disp" "${short}${plain}" >&2
        fi
    done
    if [ "$n_g" -eq "$rounds" ]; then
        if [ "$rounds" = 1 ]; then
            printf 'green|%s|%s\n' "$sum_speed" "$last_short"
        else
            printf 'green|%s|все %d повтора зелёные, в среднем %s МБ/с\n' \
                "$sum_speed" "$rounds" \
                "$(_z2r_quic_speed_mbps "$(awk -v s="$sum_speed" -v n="$((rounds * 5))" 'BEGIN{printf "%.0f", s / n}')")"
        fi
    elif [ "$n_g" -gt 0 ]; then
        printf 'warn|%s|зелёных повторов %d/%d (смотри детали выше)\n' "$sum_speed" "$n_g" "$rounds"
    elif [ "$n_u" -eq "$rounds" ] || [ "$n_h" -eq "$rounds" ] || [ "$n_w" -eq "$rounds" ]; then
        printf '%s|%s|%s\n' "$last_token" "$sum_speed" "$last_short"
    else
        printf 'warn|%s|повторы нестабильны (зелёных %d, warn %d, unknown %d, held %d)\n' \
            "$sum_speed" "$n_g" "$n_w" "$n_u" "$n_h"
    fi
    return 0
}

# --- Режим «без проверки» -----------------------------------------------------

_z2r_quic_blind_sleep() {
    local secs="$1" i=0
    case "$secs" in ''|*[!0-9]*) return 0 ;; esac
    while [ "$i" -lt "$secs" ]; do
        [ "${z2r_quic_blind_interrupted:-0}" != 1 ] || return 1
        [ -z "${Z2R_QUIC_SWEEP_DIR:-}" ] || [ ! -e "$Z2R_QUIC_SWEEP_DIR/cancel" ] || return 1
        sleep 1
        i=$((i + 1))
    done
    return 0
}

# Циклическая смена QUIC-стратегий с паузой: пользователь проверяет видео
# в браузере. Ctrl+C (или cancel-файл) — остановка на текущей стратегии,
# затем вопрос сохранить/вернуть.
z2r_quic_sweep_blind() {
    local max="${1:-}" s=0
    if [ -z "$max" ]; then
        if type orch_max_strategy_for_profile >/dev/null 2>&1; then
            max="$(orch_max_strategy_for_profile 5)"
        elif type config_profile_max_strategy >/dev/null 2>&1; then
            max="$(config_profile_max_strategy 5)"
        fi
    fi
    case "$max" in ''|*[!0-9]*|0)
        echo -e "${red}Не удалось определить число стратегий профиля 5.${plain}" >&2
        return 1 ;;
    esac
    local pause="${Z2R_QUIC_BLIND_PAUSE:-10}"
    case "$pause" in ''|*[!0-9]*) pause=10 ;; esac
    local prev had_e=0 answer stopped
    prev="$(orch_locked_state_get 5 udp)"
    echo -e "${cyan}Режим без проверки: стратегии 1-${max} сменяются по кругу каждые ${pause} сек.${plain}"
    echo -e "${cyan}Проверяйте видео в браузере; Ctrl+C - остановить на текущей стратегии.${plain}"
    case "$-" in *e*) had_e=1 ;; esac
    set +e
    trap 'z2r_quic_blind_interrupted=1' INT
    z2r_quic_blind_interrupted=0
    touched=1
    while [ "${z2r_quic_blind_interrupted:-0}" != 1 ]; do
        for ((s = 1; s <= max; s++)); do
            [ "${z2r_quic_blind_interrupted:-0}" != 1 ] || break
            orch_locked_set 5 udp "$s" || true
            echo -e "$(date '+%H:%M:%S') Стратегия ${s} применена — проверьте видео в браузере."
            _z2r_quic_blind_sleep "$pause" || break
        done
        [ "${z2r_quic_blind_interrupted:-0}" != 1 ] || break
    done
    trap ':' INT
    if [ "$had_e" = "1" ]; then set -e; fi
    echo ""
    stopped=0
    [ "${z2r_quic_blind_interrupted:-0}" = 1 ] && stopped=1
    [ -n "${Z2R_QUIC_SWEEP_DIR:-}" ] && [ -e "$Z2R_QUIC_SWEEP_DIR/cancel" ] && stopped=1
    case "${s:-0}" in ''|0|*[!0-9]*)
        # Ни одна стратегия не успела примениться — просто вернуть как было.
        case "$prev" in
            ''|auto) orch_locked_clear 5 udp || true ;;
            *) orch_locked_set 5 udp "$prev" || true ;;
        esac
        echo "Ни одна стратегия не применялась, состояние профиля не менялось."
        return 0
        ;;
    esac
    if [ "$stopped" = 1 ]; then
        echo -e "${yellow}Перебор остановлен на стратегии ${s}.${plain}"
    fi
    read -re -p "Enter - сохранить ${s}, 0 - вернуть как было: " answer || answer="0"
    if [ "$answer" = "0" ]; then
        case "$prev" in
            ''|auto) orch_locked_clear 5 udp || true ;;
            *) orch_locked_set 5 udp "$prev" || true ;;
        esac
        echo "Изменения отменены, прежняя стратегия профиля возвращена."
    else
        if type profile_state_set_and_apply >/dev/null 2>&1; then
            profile_state_set_and_apply 5 udp "$s" "" \
                && echo "Стратегия ${s} сохранена для профиля 5." \
                || echo -e "${red}Не удалось сохранить стратегию ${s} для профиля 5.${plain}"
        else
            # set -e: неудача записи не должна убивать меню.
            orch_locked_set 5 udp "$s" \
                && echo "Стратегия ${s} сохранена для профиля 5." \
                || echo -e "${red}Не удалось сохранить стратегию ${s} для профиля 5.${plain}"
        fi
        type telemetry_notify >/dev/null 2>&1 && telemetry_notify
    fi
    return 0
}

z2r_quic_offer_blind() {
    local ans
    read -re -p "Перебор без проверки: стратегии сменяются по кругу, проверяйте видео в браузере. Запустить? 1 - да, Enter - отмена: " ans || ans=""
    [ "$ans" = "1" ] || return 1
    z2r_quic_sweep_blind
}

# Диалог числа повторов полного круга проб на стратегию (1-5; 0 — отмена).
# Больше повторов — больше статистики по окнам TSPU, дольше прогон.
_z2r_quic_ask_rounds() {
    local ans
    while :; do
        read -re -p "Повторов пробы на стратегию (1-5, Enter - 1, 0 - отмена): " ans || ans=""
        case "$ans" in
            0) return 1 ;;
            ''|1) printf '1\n'; return 0 ;;
            *[!0-9]*)
                echo -e "${yellow}Нужно число 1-5.${plain}" >&2 ;;
            *)
                if [ "$ans" -ge 2 ] && [ "$ans" -le 5 ]; then
                    printf '%s\n' "$ans"; return 0
                fi
                echo -e "${yellow}Нужно число 1-5.${plain}" >&2 ;;
        esac
    done
}

# --- Перебор с проверкой ------------------------------------------------------

# Перебор QUIC-стратегий профиля 5 с проверкой видео по HTTP/3.
# Предусловия (проверяет _z2r_quic_trial): Z2R_MEDIA_READY=1, h3-curl в
# Z2R_QUIC_CURL, приватный Z2R_QUIC_SWEEP_DIR. Локи временные: победителя
# применяет финальный вопрос, при прерывании лок возвращает _z2r_quic_trial.
# Настройки (env-override для тестов, как Z2R_SWEEP_PAUSE у TCP-перебора):
#   Z2R_QUIC_SETTLE       — пауза после лока (3);
#   Z2R_QUIC_ATTEMPT_PAUSE— пауза между пробами (3);
#   Z2R_QUIC_SWEEP_PAUSE  — пауза между стратегиями (3);
#   Z2R_QUIC_JITTER       — случайное смещение ±N% от куска на пробу (0).
z2r_quic_sweep_run() {
    local max="${1:-}" s
    if [ -z "$max" ]; then
        if type orch_max_strategy_for_profile >/dev/null 2>&1; then
            max="$(orch_max_strategy_for_profile 5)"
        elif type config_profile_max_strategy >/dev/null 2>&1; then
            max="$(config_profile_max_strategy 5)"
        fi
    fi
    case "$max" in ''|*[!0-9]*|0)
        echo -e "${red}Не удалось определить число стратегий профиля 5.${plain}" >&2
        return 1 ;;
    esac

    local pause_sec="${Z2R_QUIC_SWEEP_PAUSE:-3}"
    case "$pause_sec" in ''|*[!0-9]*) pause_sec=3 ;; esac
    # Интервал по умолчанию не бывает < 3; технический override может быть любым.
    if [ -z "${Z2R_QUIC_SWEEP_PAUSE:-}" ] && [ "$pause_sec" -lt 3 ]; then
        pause_sec=3
    fi
    local settle_sec="${Z2R_QUIC_SETTLE:-3}"
    case "$settle_sec" in ''|*[!0-9]*) settle_sec=3 ;; esac
    local attempt_pause="${Z2R_QUIC_ATTEMPT_PAUSE:-3}"
    case "$attempt_pause" in ''|*[!0-9]*) attempt_pause=3 ;; esac
    local rounds="${Z2R_QUIC_ROUNDS:-1}"
    case "$rounds" in ''|*[!0-9]*) rounds=1 ;; esac
    [ "$rounds" -ge 1 ] || rounds=1
    [ "$rounds" -le 5 ] || rounds=5
    local rounds_txt=""
    [ "$rounds" -gt 1 ] && rounds_txt=", повторов на стратегию ${rounds}"

    # Случайные позиции середины/конца — ОДНИ на весь прогон: между прогонами
    # разные места, внутри прогона честное сравнение стратегий (и повторов).
    local mid_pct=$((25 + (RANDOM % 51))) end_pct=$((87 + (RANDOM % 14)))
    Z2R_QUIC_MID_PCT="$mid_pct" Z2R_QUIC_END_PCT="$end_pct"

    local green_list="" warn_list="" green_stats="" warn_stats=""
    local n_green=0 n_warn=0 n_unknown=0 n_held=0
    local verdict token rest speed short win best="" best_short="" best_from_warn=0
    local interrupted_flag=0 svc_was_running=0 prev
    prev="$(orch_locked_state_get 5 udp)"

    echo -e "${cyan}QUIC-перебор: стратегии 1-${max} (${max} шт., примерно $((max * (settle_sec + rounds * 5 * (5 + attempt_pause) + pause_sec))) сек, 5 проб на стратегию: 3 куска от начала + случайная середина (${mid_pct}%) + случайный конец (${end_pct}%)${rounds_txt}, паузы ${settle_sec}/${pause_sec} сек). Ctrl+C - прервать.${plain}"
    local had_e=0
    case "$-" in *e*) had_e=1 ;; esac
    set +e
    trap 'z2r_quic_sweep_interrupted=1; [ -z "${Z2R_QUIC_SWEEP_DIR:-}" ] || { : > "$Z2R_QUIC_SWEEP_DIR/cancel" 2>/dev/null || :; }' INT
    z2r_quic_sweep_interrupted=0
    zapret2_running && svc_was_running=1
    touched=1

    for ((s = 1; s <= max; s++)); do
        orch_locked_set 5 udp "$s" || true
        if [ "${z2r_quic_sweep_interrupted:-0}" = 1 ]; then
            echo -e "${yellow}Проверка прервана пользователем на стратегии ${s}.${plain}"
            break
        fi
        _z2r_quic_settle "$settle_sec"
        verdict="$(z2r_quic_strategy_verdict "$s")" || verdict=""
        token="${verdict%%|*}"; rest="${verdict#*|}"; speed="${rest%%|*}"; short="${rest#*|}"
        if [ "${z2r_quic_sweep_interrupted:-0}" = 1 ] || [ -z "$verdict" ] || [ "$token" = "cancelled" ]; then
            echo -e "${yellow}Проверка прервана пользователем на стратегии ${s}.${plain}"
            break
        fi
        case "$token" in
            green)
                n_green=$((n_green + 1)); green_list="${green_list}${green_list:+ }${s}"
                green_stats="${green_stats}${s}|${speed}|${short}"$'\n' ;;
            warn)
                n_warn=$((n_warn + 1)); warn_list="${warn_list}${warn_list:+ }${s}"
                warn_stats="${warn_stats}${s}|${speed}|${short}"$'\n' ;;
            unknown) n_unknown=$((n_unknown + 1)) ;;
            *) token="held"; n_held=$((n_held + 1)) ;;
        esac
        case "$token" in
            green)   printf '%s %3d: %b %b\n' "$(date '+%H:%M:%S')" "$s" "${green}OK${plain}" "${green}${short}${plain}" ;;
            warn)    printf '%s %3d: %b %b\n' "$(date '+%H:%M:%S')" "$s" "${yellow}WARN${plain}" "${yellow}${short}${plain}" ;;
            unknown) printf '%s %3d: %b %b\n' "$(date '+%H:%M:%S')" "$s" "${yellow}UNKNOWN${plain}" "${yellow}${short}${plain}" ;;
            held)    printf '%s %3d: %b %b\n' "$(date '+%H:%M:%S')" "$s" "${red}HELD${plain}" "${red}${short}${plain}" ;;
        esac
        if [ "$s" -lt "$max" ] && [ "$pause_sec" -gt 0 ]; then
            sleep "$pause_sec"
            if [ "${z2r_quic_sweep_interrupted:-0}" = 1 ]; then
                echo -e "${yellow}Прервано пользователем на стратегии ${s}.${plain}"
                break
            fi
        fi
    done
    if [ "${_Z2R_QUIC_TRIAL:-0}" = 1 ]; then trap ':' INT; else trap - INT; fi
    if [ "$had_e" = "1" ]; then set -e; fi

    if [ "$svc_was_running" = "1" ] && ! zapret2_running; then
        echo -e "${red}zapret2 был остановлен: процесс nfqws2 убит (похоже, Ctrl+C). Перезапускаю...${plain}"
        z2r_service_action restart >/dev/null 2>&1 || true
        if zapret2_running; then
            echo -e "${green}zapret2 снова работает.${plain}"
        else
            echo -e "${red}Не удалось перезапустить zapret2. Запустите вручную: пункт 22 главного меню.${plain}"
        fi
    fi

    # Лучшая = самая быстрая из ЗЕЛЁНЫХ (все фрагменты прошли) по суммарной
    # скорости; при равной скорости выигрывает меньший номер (тот же awk, что
    # и у TCP-перебора). Жёлтые (нестабильные) — только если зелёных нет:
    # стратегия, режущая часть фрагментов, не должна выигрывать у целых.
    if [ -n "$green_stats" ]; then
        win="$(printf '%s' "$green_stats" | awk -F'|' 'BEGIN{max=-1} {sp=$2+0; if (sp>max) {max=sp; line=$0}} END{print line}')"
        best="${win%%|*}"
        best_short="$(printf '%s' "$win" | cut -d'|' -f3-)"
    elif [ -n "$warn_stats" ]; then
        best_from_warn=1
        win="$(printf '%s' "$warn_stats" | awk -F'|' 'BEGIN{max=-1} {sp=$2+0; if (sp>max) {max=sp; line=$0}} END{print line}')"
        best="${win%%|*}"
        best_short="$(printf '%s' "$win" | cut -d'|' -f3-)"
    fi

    echo ""
    echo "================================================"
    echo -e " Итог QUIC-перебора: ${green}зелёных ${n_green}${plain}, ${yellow}нестабильных ${n_warn}${plain}, ${yellow}unknown ${n_unknown}${plain}, ${red}held ${n_held}${plain}"
    [ -n "$green_list" ] && echo -e " Зелёные стратегии: ${green}${green_list}${plain}"
    [ -n "$warn_list" ] && echo -e " Нестабильные (прошли не все фрагменты): ${yellow}${warn_list}${plain}"
    if [ -n "$best" ] && [ "$best_from_warn" != "1" ]; then
        echo -e " Лучшая (самая быстрая из зелёных): ${Fgreen}${best}${plain} (${best_short})"
    elif [ -n "$best" ]; then
        echo -e " Лучшая из нестабильных (зелёных нет): ${yellow}${best}${plain} (${best_short})"
    else
        echo -e " ${red}Зелёных стратегий не найдено.${plain}"
        if [ "$n_held" -gt 0 ]; then
            echo -e " ${yellow}Если всё красное — возможно, окно холда TSPU: повторите перебор позже.${plain}"
        fi
        echo -e " ${yellow}Текущее поведение QUIC лучше перепроверить в браузере.${plain}"
    fi
    echo "================================================"

    local answer
    if [ -n "$best" ]; then
        read -re -p "Enter - сохранить ${best}, номер - сохранить другую, 0 - вернуть как было: " answer || answer="0"
    else
        read -re -p "0 или Enter - вернуть как было: " answer || answer="0"
    fi
    if [ -n "$answer" ] && [ "$answer" != "0" ] && printf '%s' "$answer" | grep -Eq '^[0-9]+$' \
        && [ "$answer" -ge 1 ] && [ "$answer" -le "$max" ]; then
        :
    elif [ -z "$answer" ] && [ -n "$best" ]; then
        answer="$best"
    else
        answer="0"
    fi
    if [ "$answer" != "0" ]; then
        if type profile_state_set_and_apply >/dev/null 2>&1; then
            if profile_state_set_and_apply 5 udp "$answer" ""; then
                echo "Стратегия ${answer} сохранена для профиля 5."
                type telemetry_notify >/dev/null 2>&1 && telemetry_notify
            else
                echo -e "${red}Не удалось сохранить стратегию ${answer} для профиля 5.${plain}"
            fi
        else
            # set -e: неудача записи не должна убивать меню.
            orch_locked_set 5 udp "$answer" \
                && echo "Стратегия ${answer} сохранена для профиля 5." \
                || echo -e "${red}Не удалось сохранить стратегию ${answer} для профиля 5.${plain}"
        fi
    else
        case "$prev" in
            ''|auto) orch_locked_clear 5 udp || true ;;
            *) orch_locked_set 5 udp "$prev" || true ;;
        esac
        echo "Изменения отменены, прежняя стратегия профиля возвращена."
    fi
    return 0
}

# Цветная строка вердикта для ручного подбора (тот же формат, что в переборе).
# Пустой/отменённый вердикт — проверка прервана.
z2r_quic_print_verdict() {
    local s="$1" verdict="$2"
    local token rest speed short color disp
    token="${verdict%%|*}"
    rest="${verdict#*|}"; speed="${rest%%|*}"; short="${rest#*|}"
    if [ -z "$verdict" ] || [ "$token" = "cancelled" ]; then
        echo -e "${yellow}  QUIC: проверка прервана.${plain}"
        return 0
    fi
    case "$token" in
        green)   color="$green";   disp="OK" ;;
        warn)    color="$yellow";  disp="WARN" ;;
        unknown) color="$yellow";  disp="UNKNOWN" ;;
        *)       color="$red";     disp="HELD" ;;
    esac
    printf '%b  QUIC: %b%s%b %b%s%b\n' "${plain}" "$color" "$disp" "$plain" "$color" "$short" "$plain"
    return 0
}

# Быстрая QUIC-проверка для меню 01: один круг проб ТЕКУЩЕЙ стратегии
# профиля 5, локи не трогаем. Сабшелл — глушим supersweep-mirror и чистим
# медиа-кеш за собой (как z2r_media_check_manual). Модуль опциональный:
# нет h3-curl — одна подсказка; мусорный DNS — предупреждение гейта и выход.
z2r_quic_access_check() (
    type z2r_quic_curl_detect >/dev/null 2>&1 || return 0
    type z2r_quic_single_round >/dev/null 2>&1 || return 0
    type z2r_media_prepare >/dev/null 2>&1 || return 0
    local verdict gh
    if ! z2r_quic_curl_detect >/dev/null 2>&1; then
        echo -e "${plain}QUIC-проверка недоступна: h3-curl не установлен (меню 5 предложит установку).${plain}"
        return 0
    fi
    # Проба берёт бинарь из Z2R_QUIC_CURL: пустое значение = curl из PATH
    # (на OpenWRT без HTTP3) — все пробы молча падают и вердикт врёт «HELD».
    # Тот же контракт, что у _z2r_quic_trial.
    Z2R_QUIC_CURL="$(z2r_quic_curl_detect 2>/dev/null)" || Z2R_QUIC_CURL=""
    echo "Проверка видео по QUIC (профиль 5, текущая стратегия)"
    # Свой медиа-кеш: после check_googlevideo_access наружу не достать
    # (media-check живёт в сабшелле и чистит свой кеш), готовим заново —
    # это один Innertube-запрос. Если кеш уже готов, переиспользуем.
    if [ "${Z2R_MEDIA_READY:-0}" != 1 ] || [ -z "${Z2R_MEDIA_DIR:-}" ] || [ ! -s "${Z2R_MEDIA_DIR}/video.params" ]; then
        Z2R_SUPERSWEEP_DIR=""
        Z2R_MEDIA_DIR=""
        Z2R_MEDIA_READY=0
        _Z2R_MEDIA_FOR_QUIC=1
        trap '[ -z "${Z2R_MEDIA_DIR:-}" ] || rm -rf "$Z2R_MEDIA_DIR"' EXIT
        z2r_media_prepare || { echo -e "${yellow}QUIC: медиа-ссылки не получены, проверка пропущена.${plain}"; return 0; }
    fi
    if [ "${Z2R_MEDIA_READY:-0}" != 1 ] || [ ! -s "${Z2R_MEDIA_DIR}/video.params" ]; then
        echo -e "${yellow}QUIC: медиа UNKNOWN, проверка пропущена.${plain}"
        return 0
    fi
    gh=""
    IFS='|' read -r _ _ gh _ < "${Z2R_MEDIA_DIR}/video.params" || gh=""
    if type z2r_gv_dns_gate >/dev/null 2>&1 && [ -n "$gh" ]; then
        if ! z2r_gv_dns_gate "$gh"; then
            echo -e "${yellow}QUIC-проверка пропущена: сначала почините DNS (см. предупреждение выше).${plain}"
            return 0
        fi
    fi
    # Лок не меняем: проба идёт текущей стратегией профиля 5 (то, что юзер
    # реально живёт с прямо сейчас). «01» — только метка в stderr-анимации.
    verdict="$(z2r_quic_single_round "01")" || verdict=""
    z2r_quic_print_verdict "01" "$verdict"
    return 0
)

# --- Обёртка прогона и точка входа --------------------------------------------

# Обёртка перебора: mutex прогона, единственный кеш ссылок, восстановление
# лока профиля 5 при прерывании. Как orch_gv_trial, но для профиля 5/udp.
_z2r_quic_trial() (
    local run="$1"
    shift
    local shared_lock="${Z2R_QUIC_LOCK_DIR:-/tmp/z2r-quic-sweep}.lock"
    local Z2R_SUPERSWEEP_DIR="" Z2R_QUIC_SWEEP_DIR="" Z2R_MEDIA_DIR="" Z2R_MEDIA_READY=0
    local Z2R_MEDIA_VIDEO_ID="${Z2R_QUIC_MEDIA_VIDEO_ID:-}"
    local _Z2R_QUIC_TRIAL=1 completed=0 touched=0 prior reason gh
    prior="$(orch_locked_state_get 5 udp)"
    (umask 077; mkdir "$shared_lock") 2>/dev/null || {
        echo 'Другой прогон уже выполняется: QUIC-подбор не запущен.' >&2
        return 0
    }
    printf '%s\n' "$BASHPID" > "$shared_lock/pid"
    trap 'trap "" INT TERM HUP
        if [ "$completed" = 0 ] && [ "$touched" = 1 ]; then
            case "$prior" in
                ""|auto) orch_locked_clear 5 udp || true ;;
                *) orch_locked_set 5 udp "$prior" || true ;;
            esac
        fi
        [ -z "$Z2R_MEDIA_DIR" ] || rm -rf "$Z2R_MEDIA_DIR"
        [ -z "$Z2R_QUIC_SWEEP_DIR" ] || rm -rf "$Z2R_QUIC_SWEEP_DIR"
        rm -f "$shared_lock/pid"; rmdir "$shared_lock" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    Z2R_QUIC_SWEEP_DIR=$(umask 077; mktemp -d /tmp/z2r-quic-sweep.XXXXXX) || return 1
    Z2R_QUIC_CURL="$(z2r_quic_curl_detect 2>/dev/null)" || true
    if [ -z "$Z2R_QUIC_CURL" ]; then
        # Ручной подбор на живом терминале: предложить установить h3-curl,
        # если его ещё не спрашивали при входе в профиль (Z2R_QUIC_OFFER_DONE).
        if [ "${Z2R_QUIC_TRIAL_SOFT:-0}" = 1 ] \
            && [ "${Z2R_QUIC_OFFER_DONE:-0}" != 1 ] \
            && { [ -t 0 ] || [ "${Z2R_QUIC_ASSUME_TTY:-0}" = 1 ]; }; then
            if z2r_quic_offer_install; then
                Z2R_QUIC_CURL="$(z2r_quic_curl_detect 2>/dev/null)" || true
            fi
        fi
        if [ -z "$Z2R_QUIC_CURL" ]; then
            if [ "${Z2R_QUIC_TRIAL_SOFT:-0}" = 1 ]; then
                # Ручной подбор: без проверки, но подбор сам продолжается.
                echo -e "${yellow}h3-curl не найден: подбор без QUIC-проверки.${plain}" >&2
                "$run" "$@" || return 1
                completed=1
                return 0
            fi
            echo -e "${yellow}h3-curl не найден: проверка видео недоступна.${plain}" >&2
            z2r_quic_offer_blind || :
            return 0
        fi
    fi
    # Резолвер VISIONOS тоже зовёт curl с -q: на Entware компилированный
    # CA-путь curl не существует — дать бандл всему прогону (проба ставит
    # его и сама; отсутствует — ничего не экспортируем).
    if ca="$(z2r_quic_ca_bundle 2>/dev/null)"; then export CURL_CA_BUNDLE="$ca"; fi
    if type z2r_media_prepare >/dev/null 2>&1; then
        # Хвост «TCP (QUIC не проверяется)» в сообщениях prepare здесь лжёт —
        # дальше пойдёт именно QUIC-проверка (см. youtube_media.sh).
        _Z2R_MEDIA_FOR_QUIC=1
        z2r_media_prepare || return 1
    else
        echo 'Медиамодуль недоступен: проверка видео по QUIC невозможна.' >&2
    fi
    if [ "$Z2R_MEDIA_READY" != 1 ]; then
        if [ "${Z2R_QUIC_TRIAL_SOFT:-0}" = 1 ]; then
            echo -e "${yellow}Медиа UNKNOWN: подбор без QUIC-проверки.${plain}" >&2
            "$run" "$@" || return 1
            completed=1
            return 0
        fi
        reason="$(cat "$Z2R_MEDIA_DIR/status" 2>/dev/null)" || reason=resolver_error
        reason="${reason%%|*}"; reason="${reason:-resolver_error}"
        echo -e "${yellow}Медиа UNKNOWN (${reason}): проверка видео недоступна.${plain}" >&2
        z2r_quic_offer_blind || :
        return 0
    fi
    # DNS-гейт googlevideo: мусорный резолв — громкое предупреждение перед
    # прогоном (проба и так честно отчитается DNS-ошибкой, предупреждение
    # объясняет почему). Прогон НЕ останавливаем: пусть стратегии покажут
    # свои результаты, а виновник виден сразу.
    if type z2r_gv_dns_gate >/dev/null 2>&1; then
        gh=""
        IFS='|' read -r _ _ gh _ < "${Z2R_MEDIA_DIR}/video.params" 2>/dev/null || gh=""
        if [ -n "$gh" ]; then
            z2r_gv_dns_gate "$gh" >&2 || :
        fi
    fi
    "$run" "$@" || return 1
    completed=1
)

# Точка входа «Проверка медиа по QUIC» (A в подборе профиля 5):
# h3-curl (детект → установка) → видео → число повторов → подготовка ссылок →
# перебор с проверкой → сводка → применение лучшей. Деградация без h3-curl
# или без медиа — режим «без проверки» (z2r_quic_sweep_blind).
z2r_quic_media_run() {
    local video="${Z2R_QUIC_MEDIA_VIDEO_ID:-}" rounds
    if ! z2r_quic_offer_install; then
        echo -e "${yellow}Проверка видео по QUIC недоступна.${plain}" >&2
        z2r_quic_offer_blind || :
        return 0
    fi
    if [ -z "$video" ] && type z2r_media_ask_video >/dev/null 2>&1; then
        video=$(z2r_media_ask_video) || { echo 'Отмена.'; return 0; }
    fi
    [ -n "$video" ] || video="${Z2R_MEDIA_DEFAULT_VIDEO_ID:-BPk1uJ4txPc}"
    rounds="$(_z2r_quic_ask_rounds)" || { echo 'Отмена.'; return 0; }
    Z2R_QUIC_MEDIA_VIDEO_ID="$video" Z2R_QUIC_ROUNDS="$rounds" _z2r_quic_trial z2r_quic_sweep_run
    return 0
}
