#!/usr/bin/env bash
# QUIC-медиапроверка профиля 5 (lib/quic_media.sh): мок h3-curl, мок локов.
# Без сети, без youtube, без рестартов сервиса. Только временные каталоги.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*" >&2; exit 1; }
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source lib/youtube_media.sh
source lib/ui.sh
source lib/quic_media.sh
source lib/strategies.sh

# == 0. статическая проводка: z2r.sh, strategies.sh, submenus.sh ==============
grep -q 'youtube_media.sh quic_media.sh premium.sh' z2r.sh \
  || fail "проводка: quic_media.sh нет в Z2R_LIB_FILES"
grep -q 'youtube_media.sh|quic_media.sh) continue' z2r.sh \
  || fail "проводка: необязательный модуль quic_media.sh не исключён из missing-libs"
grep -q 'source "$LIB_DIR/quic_media.sh"' z2r.sh \
  || fail "проводка: нет source quic_media.sh в z2r.sh"
bootstrap_loop=$(awk '/^for lib in \$Z2R_LIB_FILES; do$/ {inside=1} inside {print} inside && /^done$/ {exit}' z2r.sh)
(
    mkdir "$TMP_DIR/bootstrap"
    touch "$TMP_DIR/bootstrap/config.sh"
    LIB_DIR="$TMP_DIR/bootstrap" Z2R_LIB_FILES='config.sh quic_media.sh' missing_libs=0
    eval "$bootstrap_loop"
    test "$missing_libs" = 0
    rm "$TMP_DIR/bootstrap/config.sh"
    missing_libs=0
    eval "$bootstrap_loop"
    test "$missing_libs" = 1
) || fail "проводка: bootstrap-цикл не допускает отсутствующий quic_media.sh"
grep -q 'A - автопрогон с проверкой видео (QUIC)' lib/strategies.sh \
  || fail "проводка: в orch_profile_try нет A-опции QUIC для профиля 5"
grep -q 'github.com/MarkinAlexander/z2r-curl-h3/releases/download/latest' lib/quic_media.sh \
  || fail "проводка: дефолтный base установки h3-curl не указывает на z2r-curl-h3"
grep -q 'z2r_quic_media_run' lib/strategies.sh \
  || fail "проводка: A профиля 5 не вызывает z2r_quic_media_run"
grep -q 'проверяется и ручной выбор стратегии' lib/submenus.sh \
  || fail "проводка: в подменю стратегий нет подсказки про QUIC-проверку"
grep -q 'z2r_quic_single_round' lib/strategies.sh \
  || fail "проводка: ручной подбор профиля 5 не вызывает QUIC-проверку"
grep -q '_z2r_quic_trial _orch_profile_manual_sweep' lib/strategies.sh \
  || fail "проводка: ручной подбор профиля 5 не обёрнут в QUIC-trial"

# == 1. архитектура артефакта =========*
printf '\177ELF\001\001' > "$TMP_DIR/elf-little"   # EI_DATA=1
printf '\177ELF\001\002' > "$TMP_DIR/elf-big"      # EI_DATA=2
uname() { case "$1" in -m) echo "${MOCK_UNAME:-}" ;; *) command uname "$@" ;; esac; }
export MOCK_UNAME
test "$(MOCK_UNAME=x86_64 z2r_quic_curl_arch)" = x86_64
test "$(MOCK_UNAME=i686 z2r_quic_curl_arch)" = i686
test "$(MOCK_UNAME=aarch64 z2r_quic_curl_arch)" = aarch64
test "$(MOCK_UNAME=mipsel z2r_quic_curl_arch)" = mipsel
test "$(MOCK_UNAME=mips Z2R_QUIC_ELF_FILE="$TMP_DIR/elf-little" z2r_quic_curl_arch)" = mipsel \
  || fail "архитектура: mips+little должен дать mipsel"
test "$(MOCK_UNAME=mips Z2R_QUIC_ELF_FILE="$TMP_DIR/elf-big" z2r_quic_curl_arch)" = mipssf \
  || fail "архитектура: mips+big должен дать mipssf"
! MOCK_UNAME=sparc z2r_quic_curl_arch 2>/dev/null || true

# == 2. CA-бандл ==============================================================
Z2R_QUIC_CA_BUNDLE="$TMP_DIR/ca.crt"
: > "$Z2R_QUIC_CA_BUNDLE"
export Z2R_QUIC_CA_BUNDLE
test "$(z2r_quic_ca_bundle)" = "$TMP_DIR/ca.crt"
Z2R_QUIC_CA_BUNDLE="$TMP_DIR/missing-ca.crt" z2r_quic_ca_bundle 2>/dev/null \
  && fail "CA: отсутствующий бандл не должен находиться"

# == 3. детект h3-curl ========================================================
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/curl-h3-mock" <<'MOCK'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        --version)
            printf 'curl 8.16.0 (x86_64-pc-linux-musl) libcurl/8.16.0 OpenSSL/3.5.4 nghttp3/1.12\nFeatures: HTTP3 HTTPS-proxy\n'
            exit 0 ;;
    esac
done
exit 86
MOCK
chmod +x "$TMP_DIR/bin/curl-h3-mock"
printf '#!/bin/sh\necho "curl 8.9.0 no-h3 here"\n' > "$TMP_DIR/bin/plain-curl"
chmod +x "$TMP_DIR/bin/plain-curl"
mkdir -p "$TMP_DIR/tools/bin"
cp "$TMP_DIR/bin/curl-h3-mock" "$TMP_DIR/tools/bin/curl-h3-i686"
test "$(Z2R_QUIC_CURL="$TMP_DIR/bin/curl-h3-mock" z2r_quic_curl_detect)" = "$TMP_DIR/bin/curl-h3-mock" \
  || fail "детект: env-override не сработал"
! Z2R_QUIC_CURL="$TMP_DIR/bin/plain-curl" z2r_quic_curl_detect 2>/dev/null \
  || fail "детект: curl без HTTP3 не должен находиться"
! Z2R_QUIC_CURL="$TMP_DIR/bin/absent-curl" z2r_quic_curl_detect 2>/dev/null \
  || fail "детект: отсутствующий путь не должен находиться"
Z2R_QUIC_CURL=""
MOCK_UNAME=i686
test "$(ZATOR_ROOT="$TMP_DIR" z2r_quic_curl_detect)" = "$TMP_DIR/tools/bin/curl-h3-i686" \
  || fail "детект: tools/bin/curl-h3-<arch> не найден"
! ZATOR_ROOT="$TMP_DIR/empty-root" Z2R_QUIC_CURL="" z2r_quic_curl_detect >/dev/null 2>&1 \
  || fail "детект: пустой ZATOR_ROOT не должен давать h3-curl"

# == 4. установка h3-curl (паттерн сниффера) ==================================
mkdir -p "$TMP_DIR/dlbin" "$TMP_DIR/dl"
export MOCK_DL_CALLS="$TMP_DIR/dl-calls"
: > "$MOCK_DL_CALLS"
cat > "$TMP_DIR/dlbin/curl" <<'MOCK'
#!/bin/sh
echo "$*" >> "${MOCK_DL_CALLS:-/dev/null}"
out=""; prev=""
for a in "$@"; do
    case "$prev" in -o) out="$a" ;; esac
    prev="$a"
done
[ -n "$out" ] || exit 93
case "${MOCK_DL:-}" in
    fail) exit 7 ;;
    garbage) printf 'not a gzip stream at all\n' > "$out"; exit 0 ;;
esac
cat "${MOCK_DL_SRC:?}" > "$out" || exit 1
MOCK
chmod +x "$TMP_DIR/dlbin/curl"
head -c 1100000 /dev/zero > "$TMP_DIR/dl/body-1m"
gzip -c "$TMP_DIR/dl/body-1m" > "$TMP_DIR/dl/good.gz"
head -c 10486000 /dev/zero > "$TMP_DIR/dl/body-big"
gzip -c "$TMP_DIR/dl/body-big" > "$TMP_DIR/dl/big.gz"
printf 'tiny' | gzip -c > "$TMP_DIR/dl/tiny.gz"

# На Windows/MSYS chmod не даёт бита исполнения: POSIX-проверки гейтятся.
can_x() { : > "$TMP_DIR/xprobe"; chmod +x "$TMP_DIR/xprobe" 2>/dev/null || return 1; [ -x "$TMP_DIR/xprobe" ]; }

INSTALL_ROOT=""
install_seq=0
run_install() { # $1=фикстура, $2=режим мока, $3=явный источник (для пропуска скачивания)
    install_seq=$((install_seq + 1))
    INSTALL_ROOT="$TMP_DIR/inst-$install_seq"
    mkdir -p "$INSTALL_ROOT/tools/bin"
    ZATOR_ROOT="$INSTALL_ROOT" MOCK_UNAME=i686 Z2R_CURL_H3_RELEASE_BASE="https://mock.invalid/rel" \
        MOCK_DL_SRC="${3:-$TMP_DIR/dl/$1}" MOCK_DL="${2:-}" PATH="$TMP_DIR/dlbin:$PATH" \
        z2r_quic_curl_install
}
run_install good.gz 2>/dev/null || fail "установка: годный артефакт не установлен"
test -s "$INSTALL_ROOT/tools/bin/curl-h3-i686" || fail "установка: бинарник не записан"
if can_x; then
    test -x "$INSTALL_ROOT/tools/bin/curl-h3-i686" || fail "установка: бинарник не исполняемый"
fi
: > "$MOCK_DL_CALLS"
if can_x; then
    run_install good.gz "" "$TMP_DIR/dl/absent.gz" 2>/dev/null \
      || fail "установка: существующий бинарник должен вернуть 0 без скачивания"
    test ! -s "$MOCK_DL_CALLS" || fail "установка: существующий бинарник должен пропускать скачивание"
fi
run_install garbage >/dev/null 2>&1 && fail "установка: битый gzip не должен ставиться"
run_install good.gz garbage >/dev/null 2>&1 && fail "установка: битая закачка не должна ставиться"
run_install big.gz >/dev/null 2>&1 && fail "установка: артефакт больше лимита не должен ставиться"
run_install tiny.gz >/dev/null 2>&1 && fail "установка: артефакт меньше минимума не должен ставиться"
run_install good.gz fail >/dev/null 2>&1 && fail "установка: сбой закачки не должен ставиться"
# Нет ни curl, ни wget: мок command прячет оба, утилиты остаются настоящими.
mkdir -p "$TMP_DIR/inst-empty/tools/bin"
(
    command() { case "$*" in '-v curl'|'-v wget') return 1 ;; *) builtin command "$@" ;; esac; }
    ZATOR_ROOT="$TMP_DIR/inst-empty" MOCK_UNAME=i686 Z2R_CURL_H3_RELEASE_BASE="https://mock.invalid/rel" \
        PATH="$TMP_DIR/dlbin:$PATH" z2r_quic_curl_install 2>/dev/null && exit 1
    exit 0
) || fail "установка: без curl/wget должна быть ошибка, а не успех"
# Fallback на wget: curl спрятан моком command, wget-мок лежит рядом с curl-моком.
cp "$TMP_DIR/dlbin/curl" "$TMP_DIR/dlbin/wget"
cat > "$TMP_DIR/dlbin/wget" <<'MOCK'
#!/bin/sh
echo "$*" >> "${MOCK_DL_CALLS:-/dev/null}"
out=""; prev=""
for a in "$@"; do
    case "$prev" in -O) out="$a" ;; esac
    prev="$a"
done
[ -n "$out" ] || exit 93
cat "${MOCK_DL_SRC:?}" > "$out" || exit 1
MOCK
chmod +x "$TMP_DIR/dlbin/wget"
install_seq=$((install_seq + 1))
WGET_ROOT="$TMP_DIR/inst-wget"
mkdir -p "$WGET_ROOT/tools/bin"
(
    command() { case "$*" in '-v curl') return 1 ;; *) builtin command "$@" ;; esac; }
    ZATOR_ROOT="$WGET_ROOT" MOCK_UNAME=i686 Z2R_CURL_H3_RELEASE_BASE="https://mock.invalid/rel" \
        MOCK_DL_SRC="$TMP_DIR/dl/good.gz" PATH="$TMP_DIR/dlbin:$PATH" \
        z2r_quic_curl_install 2>/dev/null || exit 1
    exit 0
) || fail "установка: fallback на wget не сработал"
test -s "$WGET_ROOT/tools/bin/curl-h3-i686" || fail "установка: wget-бинарник не установлен"

# == 5. проба: один h3-GET по подписанной ссылке ==============================
media="$TMP_DIR/media"
mkdir -p "$media"
umask 077
printf '12000000|video/mp4|rr1---sn-example.googlevideo.com|4102444800\n' > "$media/video.params"
printf 'url = "https://rr1---sn-example.googlevideo.com/videoplayback?expire=4102444800&sig=REDACTED"\n' > "$media/video.curl"
printf '4102444800\n' > "$media/expires"

cat > "$TMP_DIR/bin/curl-h3-mock" <<'MOCK'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        --version)
            printf 'curl 8.16.0 libcurl/8.16.0 OpenSSL/3.5.4 nghttp3/1.12\nFeatures: HTTP3\n'
            exit 0 ;;
    esac
done
headers=""; config=""; range=""
prev=""
for a in "$@"; do
    case "$prev" in
        -D) headers="$a" ;;
        --config) config="$a" ;;
        --range) range="$a" ;;
    esac
    case "$a" in *videoplayback*) [ -z "${MOCK_LEAK_CHECK:-}" ] || touch "$MOCK_LEAK_CHECK" ;; esac
    prev="$a"
done
[ -n "$config" ] || { echo 'mock: no --config' >&2; exit 90; }
case "$*" in *--http3-only*) ;; *) echo 'mock: no --http3-only' >&2; exit 91 ;; esac
[ -n "${CURL_CA_BUNDLE:-}" ] || { echo 'mock: no CURL_CA_BUNDLE' >&2; exit 92; }
case "$*" in *--range*) ;; *) echo 'mock: no --range' >&2; exit 94 ;; esac
case "$*" in *'--noproxy *'*) ;; *) echo 'mock: no --noproxy' >&2; exit 95 ;; esac
start=${range%-*}; end=${range#*-}; bytes=$((end - start + 1)); rc=0
ver=3; code=206; mime=video/mp4
grep -q 'itag=139' "$config" 2>/dev/null && mime=audio/mp4
case "${MOCK:-ok}" in
    slowcancel) sleep 2 ;;
    ver2) ver=2 ;;
    403|429|503)
        code="$MOCK"; bytes=0
        printf 'HTTP/3 200\r\nContent-Type: %s\r\n\r\n' "$mime" > "$headers"
        printf '%s|0|3|0.01|0.30|0.40|0.50|0' "$code"; exit 0 ;;
    timeout) code=000; bytes=0; rc=28; : > "$headers"
        printf '000|0|0|0|0|0|15.0|0'; exit 28 ;;
    dnsfail) code=000; bytes=0; rc=6; : > "$headers"
        printf '000|0|0|0|0|0|0.1|0'; exit 6 ;;
    partial) bytes=99; rc=18 ;;
    wrongrange) end=$((end + 1)) ;;
    redirect|badredirect)
        if ! grep -q redirected "$config" 2>/dev/null; then
            host=rr1---sn-example.googlevideo.com
            [ "$MOCK" != badredirect ] || host=evil.example
            printf 'HTTP/3 302 Found\r\nLocation: https://%s/videoplayback?expire=4102444800&sig=REDACTED&redirected=1\r\n\r\n' "$host" > "$headers"
            printf '302|0|3|0.01|0.30|0.40|0.50|0'; exit 0
        fi ;;
esac
printf 'HTTP/3 206 Partial Content\r\nContent-Type: %s\r\nContent-Range: bytes %s-%s/12000000\r\n\r\n' "$mime" "$start" "$end" > "$headers"
printf '206|%s|%s|0.01|0.30|0.45|1.20|%s' "$bytes" "$ver" "$((bytes * 2))"
exit "$rc"
MOCK
chmod +x "$TMP_DIR/bin/curl-h3-mock"
export Z2R_QUIC_CURL="$TMP_DIR/bin/curl-h3-mock"
export Z2R_QUIC_SWEEP_DIR="$TMP_DIR/sweeps"
mkdir -p "$Z2R_QUIC_SWEEP_DIR"
export MOCK_LEAK_CHECK="$TMP_DIR/url-leak"

probe_row() { MOCK="${1:-ok}" z2r_quic_probe "$media" video 1048576 6000000; }
row="$(probe_row ok)"
[[ "$row" == OK\|media_h3\|0\|3\|206\|1048576\|* ]] || fail "проба ok: $row"
test ! -e "$TMP_DIR/url-leak" || fail "проба: URL попал в argv"
row="$(probe_row ver2)"
[[ "$row" == UNKNOWN\|not_h3\|* ]] || fail "проба ver=2 должен быть not_h3: $row"
row="$(probe_row 403)"
[[ "$row" == UNKNOWN\|cdn_403\|* ]] || fail "проба 403: $row"
row="$(probe_row 429)"
[[ "$row" == UNKNOWN\|rate_limited\|* ]] || fail "проба 429: $row"
row="$(probe_row 503)"
[[ "$row" == UNKNOWN\|cdn_503\|* ]] || fail "проба 503: $row"
row="$(probe_row timeout)"
[[ "$row" == FAIL\|network_error\|28\|0\|000\|* ]] || fail "проба timeout: $row"
row="$(probe_row dnsfail)"
[[ "$row" == UNKNOWN\|dns_error\|* ]] || fail "проба dns должен быть UNKNOWN (не вина стратегии): $row"
row="$(probe_row partial)"
[[ "$row" == FAIL\|incomplete_transfer\|* ]] || fail "проба partial: $row"
row="$(probe_row wrongrange)"
[[ "$row" == UNKNOWN\|invalid_response\|* ]] || fail "проба wrongrange: $row"
row="$(probe_row redirect)"
[[ "$row" == OK\|media_h3\|* ]] || fail "проба redirect должен довести до OK: $row"
row="$(probe_row badredirect)"
[[ "$row" == UNKNOWN\|invalid_response\|* ]] || fail "проба badredirect: $row"
touch "$Z2R_QUIC_SWEEP_DIR/cancel"
row="$(probe_row slowcancel)"
[[ "$row" == UNKNOWN\|cancelled\|* ]] || fail "проба cancel: $row"
rm "$Z2R_QUIC_SWEEP_DIR/cancel"
row="$( { date() { echo 4102444800; }; probe_row ok; } )"
[[ "$row" == UNKNOWN\|expired\|* ]] || fail "проба expired: $row"

# == 5b. check: план позиций (3 от начала + случайные середина/конец) =========
(
    z2r_quic_probe() { printf '%s|%s|%s' "$2" "$3" "$4" > "$TMP_DIR/captured"; echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|500000'; }
    # Куски 1..3 от начала: offsets 0, 1МиБ, 2МиБ (count=1МиБ, длина 12МиБ).
    Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$media" z2r_quic_check 1 >/dev/null
    [[ "$(cat "$TMP_DIR/captured")" == video\|1048576\|0 ]] \
      || fail "check: кусок 1 должен дать offset 0: $(cat "$TMP_DIR/captured")"
    Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$media" z2r_quic_check 2 >/dev/null
    [[ "$(cat "$TMP_DIR/captured")" == video\|1048576\|1048576 ]] \
      || fail "check: кусок 2 должен дать offset 1МиБ: $(cat "$TMP_DIR/captured")"
    Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$media" z2r_quic_check 3 >/dev/null
    [[ "$(cat "$TMP_DIR/captured")" == video\|1048576\|2097152 ]] \
      || fail "check: кусок 3 должен дать offset 2МиБ: $(cat "$TMP_DIR/captured")"
    # Середина/конец с пинамированными процентами (как на прогоне).
    Z2R_QUIC_MID_PCT=50 Z2R_QUIC_END_PCT=100 Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$media" z2r_quic_check mid >/dev/null
    [[ "$(cat "$TMP_DIR/captured")" == video\|1048576\|6000000 ]] \
      || fail "check: середина (50%) должна дать offset 6МиБ: $(cat "$TMP_DIR/captured")"
    Z2R_QUIC_MID_PCT=50 Z2R_QUIC_END_PCT=100 Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$media" z2r_quic_check end >/dev/null
    [[ "$(cat "$TMP_DIR/captured")" == video\|1048576\|10951424 ]] \
      || fail "check: конец (100%) должен клампиться в хвост: $(cat "$TMP_DIR/captured")"
    # Случайные середина/конец без пина: границы середина [25%,75%], конец [87%,100%].
    for _ in 1 2 3 4 5 6; do
        Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$media" z2r_quic_check mid >/dev/null
        off="$(cat "$TMP_DIR/captured")"; off="${off##*|}"
        [ "$off" -ge 3000000 ] && [ "$off" -le 9000000 ] \
          || fail "check: случайная середина вне [25%,75%]: $off"
        Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$media" z2r_quic_check end >/dev/null
        off="$(cat "$TMP_DIR/captured")"; off="${off##*|}"
        [ "$off" -ge 10440000 ] && [ "$off" -le 10951424 ] \
          || fail "check: случайный конец вне [87%,100%]: $off"
    done
    # Джиттер 50% на куске 2: offset в границах base ± 0.5МиБ.
    for _ in 1 2 3 4; do
        Z2R_QUIC_JITTER=50 Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$media" z2r_quic_check 2 >/dev/null
        off="$(cat "$TMP_DIR/captured")"; off="${off##*|}"
        case "$off" in ''|*[!0-9]*) fail "check: джиттер дал нечисловой offset: $off" ;; esac
        [ "$off" -ge 524288 ] && [ "$off" -le 1572864 ] \
          || fail "check: джиттер вне ±50% куска: $off"
    done
    # Неизвестный ключ трактуется как кусок 1.
    Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$media" z2r_quic_check 99 >/dev/null
    [[ "$(cat "$TMP_DIR/captured")" == video\|1048576\|0 ]] \
      || fail "check: неизвестный ключ должен дать кусок 1: $(cat "$TMP_DIR/captured")"
    # Нет параметров потока — честный UNKNOWN, не падение.
    mkdir -p "$TMP_DIR/empty-media"
    out="$(Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$TMP_DIR/empty-media" z2r_quic_check 1)"
    [[ "$out" == UNKNOWN\|invalid_params\|* ]] || fail "check: без params должен быть invalid_params: $out"
)

# == 6. вердикты стратегий: план 5 проб (3 от начала + середина + конец) ======
CNT="$TMP_DIR/cnt"; mkdir -p "$CNT"
check_mock_reset() { rm -rf "$CNT"; mkdir -p "$CNT"; }
export Z2R_QUIC_ATTEMPT_PAUSE=0
verdict_of() { MOCKV="$1" z2r_quic_strategy_verdict "$2"; }
z2r_quic_check() {
    # $1 — ключ позиции плана; счётчик глобальный на сценарий.
    local n
    n="$(cat "$CNT/all" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$CNT/all"
    case "${MOCKV:-}" in
        allgreen) echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|500000' ;;
        flap)
            if [ "$n" = 1 ]; then echo 'FAIL|network_error|28|0|000|0|0|0|0|15.0|0'
            else echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|400000'; fi ;;
        degrade)
            if [ "$n" -le 2 ]; then echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|600000'
            else echo 'FAIL|network_error|28|0|000|0|0|0|0|15.0|0'; fi ;;
        cdndeny) echo 'UNKNOWN|cdn_403|0|3|403|0|0|0|0|0.5|0' ;;
        held) echo 'FAIL|network_error|28|0|000|0|0|0|0|15.0|0' ;;
        cancel) echo 'UNKNOWN|cancelled|0|0|000|0|0|0|0|0|0' ;;
    esac
}
check_mock_reset
row="$(verdict_of allgreen 1)"
[[ "$row" == green\|2500000\|* ]] || fail "вердикт: green (сумма 5 проб) ожидаем, получено: $row"
printf '%s' "$row" | grep -Fq 'h3 5/5 (кусок 1, кусок 2, кусок 3, середина, конец)' \
  || fail "вердикт: green без перечня кусков: $row"
check_mock_reset
row="$(verdict_of flap 2)"
printf '%s' "$row" | grep -Fq 'warn|1600000|нестабильно: 4/5 прошло (OK: кусок 2, кусок 3, середина, конец; кусок 1 — нет ответа)' \
  || fail "вердикт: warn (флап на старте) ожидаем: $row"
check_mock_reset
row="$(verdict_of degrade 2)"
printf '%s' "$row" | grep -Fq 'нестабильно: 2/5 прошло (OK: кусок 1, кусок 2; кусок 3 — нет ответа, середина — нет ответа, конец — нет ответа)' \
  || fail "вердикт: warn (деградация по ходу) ожидаем: $row"
check_mock_reset
row="$(verdict_of cdndeny 3)"
printf '%s' "$row" | grep -Fq 'unknown|0|медиа нет: CDN отказал (403)' \
  || fail "вердикт: unknown (403) ожидаем: $row"
check_mock_reset
row="$(verdict_of held 4)"
printf '%s' "$row" | grep -Fq 'held|0|все попытки без ответа' \
  || fail "вердикт: held ожидаем: $row"
check_mock_reset
row="$(verdict_of cancel 5)"
[[ "$row" == cancelled* ]] || fail "вердикт: cancelled ожидаем: $row"

# == 6b. повторы круга на стратегию (Z2R_QUIC_ROUNDS) ========================
# mixedrounds: повтор 1 — green (5 проб), повтор 2 — warn (первая проба
# сорвалась), повтор 3 — green. Итог: зелёных повторов 2/3.
check_mock_reset
z2r_quic_check() {
    local n
    n="$(cat "$CNT/all" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$CNT/all"
    case "${MOCKV:-}" in
        allgreen) echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|500000' ;;
        mixedrounds)
            if [ "$n" -le 5 ]; then echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|500000'
            elif [ "$n" = 6 ]; then echo 'FAIL|network_error|28|0|000|0|0|0|0|15.0|0'
            elif [ "$n" -le 10 ]; then echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|400000'
            else echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|500000'; fi ;;
    esac
}
out="$(Z2R_QUIC_ROUNDS=3 MOCKV=mixedrounds z2r_quic_strategy_verdict 1 2>"$TMP_DIR/rounds-err")"
printf '%s' "$out" | grep -Fq 'warn|6600000|зелёных повторов 2/3' \
  || fail "повторы: агрегация зелёных повторов 2/3 ожидаема: $out"
grep -q 'повтор 1/3' "$TMP_DIR/rounds-err" || fail "повторы: нет строки повтора 1/3"
grep -q 'повтор 2/3' "$TMP_DIR/rounds-err" || fail "повторы: нет строки повтора 2/3"
grep -q 'повтор 3/3' "$TMP_DIR/rounds-err" || fail "повторы: нет строки повтора 3/3"
# Все повторы зелёные: green с агрегированной средней.
check_mock_reset
out="$(Z2R_QUIC_ROUNDS=2 MOCKV=allgreen z2r_quic_strategy_verdict 1 2>/dev/null)"
printf '%s' "$out" | grep -Fq 'green|5000000|все 2 повтора зелёные, в среднем 0.5 МБ/с' \
  || fail "повторы: все зелёные должны дать агрегат: $out"
# Один повтор — прежний формат без агрегатной обёртки.
check_mock_reset
out="$(Z2R_QUIC_ROUNDS=1 MOCKV=allgreen z2r_quic_strategy_verdict 1 2>/dev/null)"
printf '%s' "$out" | grep -Fq 'green|2500000|h3 5/5' \
  || fail "повторы: один повтор должен сохранить прежний формат: $out"

# == 6c. диалог числа повторов ===============================================
cap="$(printf '\n' | _z2r_quic_ask_rounds 2>/dev/null)"
[ "$cap" = "1" ] || fail "диалог повторов: Enter должен давать 1: $cap"
cap="$(printf '3\n' | _z2r_quic_ask_rounds 2>/dev/null)"
[ "$cap" = "3" ] || fail "диалог повторов: 3 должен возвращать 3: $cap"
printf '0\n' | _z2r_quic_ask_rounds >/dev/null 2>&1 \
  && fail "диалог повторов: 0 должен отменять"
cap="$(printf 'abc\n7\n2\n' | _z2r_quic_ask_rounds 2>/dev/null)"
[ "$cap" = "2" ] || fail "диалог повторов: мусор должен переспрашивать: $cap"
grep -q '_z2r_quic_ask_rounds' lib/quic_media.sh \
  || fail "проводка: диалог повторов не вызывается из media_run"

# == 7. перебор с проверкой: локи, сводка, применение =========================
export ORCH_DIR="$TMP_DIR/orch"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
mkdir -p "$ORCH_DIR"
: > "$ORCH_LOCK_FILE"
source lib/orchestra_state.sh
source lib/config.sh
export Z2R_QUIC_SETTLE=0 Z2R_QUIC_SWEEP_PAUSE=0 Z2R_QUIC_ATTEMPT_PAUSE=0
config_profile_max_strategy() { case "$1" in 5) echo 5 ;; *) echo 0 ;; esac; }
zapret2_running() { return 1; }

sweep_run() { printf '%s' "$1" | z2r_quic_sweep_run; }
ansi_clean() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

# 7a. зелёные есть: Enter сохраняет самую быструю (2: 1400000 > 1000000).
# Мок читает ТЕКУЩИЙ лок 5/udp — как реальная проверка.
check_mock_reset
z2r_quic_check() {
    local cur
    cur="$(orch_locked_get 5 udp)"
    case "$cur" in
        1) echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|500000' ;;
        2) echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.10|700000' ;;
        3|4) echo 'UNKNOWN|cdn_403|0|3|403|0|0|0|0|0.5|0' ;;
        5) echo 'FAIL|network_error|28|0|000|0|0|0|0|15.0|0' ;;
        *) echo 'UNKNOWN|resolver_unavailable|0|0|000|0|0|0|0|0|0' ;;
    esac
}
out_c="$(ansi_clean "$(sweep_run $'\n')")"
printf '%s' "$out_c" | grep -q "Итог QUIC-перебора" || fail "перебор: нет сводки: $out_c"
printf '%s' "$out_c" | grep -q "Зелёные стратегии: 1 2" || fail "перебор: нет списка зелёных: $out_c"
printf '%s' "$out_c" | grep -q "Лучшая (самая быстрая из зелёных): 2" || fail "перебор: лучшей должна быть 2 (быстрее): $out_c"
printf '%s' "$out_c" | grep -q "Стратегия 2 сохранена для профиля 5." || fail "перебор: лучшая не сохранена"
test "$(orch_locked_get 5 udp)" = 2 || fail "перебор: лок 5/udp = $(orch_locked_get 5 udp), ожидался 2"

# 7b. ответ 0 возвращает прежний лок (в т.ч. «auto» = отсутствие строки).
orch_locked_set 5 udp 5
out_c="$(ansi_clean "$(sweep_run '0')")"
test "$(orch_locked_get 5 udp)" = 5 || fail "перебор: ответ 0 должен вернуть лок 5"
printf '%s' "$out_c" | grep -q "прежняя стратегия профиля возвращена" || fail "перебор: нет сообщения возврата"
orch_locked_clear 5 udp
out="$(sweep_run '0')"
! grep -Eq '^5\tudp' "$ORCH_LOCK_FILE" || fail "перебор: прежний auto должен остаться auto (без строки)"

# 7c. всё красное: подсказка про окно холда, лок не меняется.
check_mock_reset
z2r_quic_check() { echo 'FAIL|network_error|28|0|000|0|0|0|0|15.0|0'; }
out_c="$(ansi_clean "$(sweep_run $'\n')")"
printf '%s' "$out_c" | grep -q "окно холда" || fail "перебор: нет оговорки про окно холда: $out_c"
printf '%s' "$out_c" | grep -q "Зелёных стратегий не найдено" || fail "перебор: нет сообщения об отсутствии зелёных"
! grep -Eq '^5\tudp' "$ORCH_LOCK_FILE" || fail "перебор: без зелёных лок меняться не должен"

# 7d. отмена на стратегии: перебор останавливается, прежний лок возвращён.
check_mock_reset
z2r_quic_check() {
    local cur
    cur="$(orch_locked_get 5 udp)"
    case "$cur" in
        1) echo 'OK|media_h3|0|3|206|1048576|0.01|0.30|0.45|1.20|500000' ;;
        *) echo 'UNKNOWN|cancelled|0|0|000|0|0|0|0|0|0' ;;
    esac
}
orch_locked_set 5 udp 4
out_c="$(ansi_clean "$(sweep_run '0')")"
printf '%s' "$out_c" | grep -q "прервана пользователем на стратегии 2" || fail "перебор: нет сообщения об отмене: $out_c"
test "$(orch_locked_get 5 udp)" = 4 || fail "перебор: после отмены должен остаться прежний лок 4"
orch_locked_clear 5 udp

# 7e. set -e-гигиена: сбой пробы не роняет вызывающий код (меню z2r.sh).
(
    set -e
    z2r_quic_check() { echo 'FAIL|network_error|28|0|000|0|0|0|0|15.0|0'; }
    printf '0\n' | z2r_quic_sweep_run >/dev/null
    echo survived
) | grep -q survived || fail "перебор: set -e роняет вызывающий код"

# 7f. восстановление лока обёрткой при сбое прогона (EXIT-trap trial).
z2r_media_prepare() { Z2R_MEDIA_DIR="$media"; Z2R_MEDIA_READY=1; return 0; }
# CURL_CA_BUNDLE должен попадать в окружение прогона (резолвер VISIONOS
# зовёт curl с -q; на Entware компилированный CA-путь не существует).
ca_probe_run() { touched=1; printf 'CA=%s' "${CURL_CA_BUNDLE:-none}" > "$TMP_DIR/trial-ca"; return 0; }
Z2R_QUIC_LOCK_DIR="$TMP_DIR/quiclock6" Z2R_QUIC_MEDIA_VIDEO_ID="BPk1uJ4txPc" \
    _z2r_quic_trial ca_probe_run >/dev/null 2>&1 || true
grep -q "CA=$TMP_DIR/ca.crt" "$TMP_DIR/trial-ca" \
  || fail "trial: CURL_CA_BUNDLE не экспортирован резолверу: $(cat "$TMP_DIR/trial-ca" 2>/dev/null)"
orch_locked_set 5 udp 4
broken_run() { touched=1; orch_locked_set 5 udp 3; return 1; }
Z2R_QUIC_LOCK_DIR="$TMP_DIR/quiclock2" Z2R_QUIC_MEDIA_VIDEO_ID="BPk1uJ4txPc" \
    _z2r_quic_trial broken_run >/dev/null 2>&1 || true
test "$(orch_locked_get 5 udp)" = 4 \
  || fail "trial: после сбоя прогона лок должен вернуться к 4, а не $(orch_locked_get 5 udp)"
test ! -d "$TMP_DIR/quiclock2" || fail "trial: mutex-каталог не убран после прогона"
# Успешный прогон: локи не трогаются повторно.
ok_run() { touched=1; orch_locked_set 5 udp 3; return 0; }
Z2R_QUIC_LOCK_DIR="$TMP_DIR/quiclock3" Z2R_QUIC_MEDIA_VIDEO_ID="BPk1uJ4txPc" \
    _z2r_quic_trial ok_run >/dev/null 2>&1 || true
test "$(orch_locked_get 5 udp)" = 3 || fail "trial: после успешного прогона лок должен остаться 3"
# Mutex: второй прогон не должен начаться (shared_lock = <dir>.lock).
mkdir -p "$TMP_DIR/quiclock4.lock"
out="$(Z2R_QUIC_LOCK_DIR="$TMP_DIR/quiclock4" Z2R_QUIC_MEDIA_VIDEO_ID="BPk1uJ4txPc" _z2r_quic_trial ok_run 2>&1)"
printf '%s' "$out" | grep -q "Другой прогон уже выполняется" || fail "trial: нет сообщения о втором прогоне"
orch_locked_clear 5 udp

# == 7g. ручной подбор профиля 5 с QUIC-проверкой каждой стратегии ============
(
    : > "$TMP_DIR/mock-config"
    get_config_file() { echo "$TMP_DIR/mock-config"; }
    config_profile_max_strategy() { case "$1" in 5) echo 32 ;; *) echo 0 ;; esac; }
    Z2R_QUIC_LOCK_DIR="$TMP_DIR/quiclock-manual"
    Z2R_QUIC_CURL="$TMP_DIR/bin/curl-h3-mock"
    z2r_media_prepare() { Z2R_MEDIA_DIR="$media"; Z2R_MEDIA_READY=1; return 0; }
    z2r_quic_single_round() { echo 'green|2500000|h3 5/5 (кусок 1, кусок 2, кусок 3, середина, конец): 0.5 МБ/с'; }
    orch_locked_clear 5 udp
    out_c="$(ansi_clean "$(printf '23\nM7lc1UVf-VE\n1\n\n' | orch_profile_try 5 "Профиль 5" "udp" "" 2>&1)")"
    printf '%s' "$out_c" | grep -q "QUIC: OK" || fail "ручной подбор: нет QUIC-вердикта: $out_c"
    printf '%s' "$out_c" | grep -q "h3 5/5" || fail "ручной подбор: вердикт без деталей круга: $out_c"
    printf '%s' "$out_c" | grep -q "Стратегия 23 сохранена для профиля 5." \
      || fail "ручной подбор: стратегия 23 не сохранена: $out_c"
    test "$(orch_locked_get 5 udp)" = 23 \
      || fail "ручной подбор: лок = $(orch_locked_get 5 udp), ожидался 23"
    printf '%s' "$out_c" | grep -q "прерван" \
      && fail "ручной подбор: успешное сохранение не должно помечаться прерванным"
    # Ответ 0 на финальный вопрос — отмена: прежний лок возвращён, проверка тоже была.
    orch_locked_set 5 udp 22
    out_c="$(ansi_clean "$(printf '23\nM7lc1UVf-VE\n0\n\n' | orch_profile_try 5 "Профиль 5" "udp" "" 2>&1)")"
    printf '%s' "$out_c" | grep -q "QUIC: OK" || fail "ручной подбор (отмена): нет QUIC-вердикта: $out_c"
    test "$(orch_locked_get 5 udp)" = 22 \
      || fail "ручной подбор (отмена): прежний лок 22 потерян"
    orch_locked_clear 5 udp
)

# == 7h. ручной подбор БЕЗ h3-curl: оффер установки ДО промпта стратегии ======
(
        unset Z2R_QUIC_CURL   # секция 5 экспортировала мок — здесь нужен честный детект
        : > "$TMP_DIR/mock-config"
        get_config_file() { echo "$TMP_DIR/mock-config"; }
        config_profile_max_strategy() { case "$1" in 5) echo 32 ;; *) echo 0 ;; esac; }
        ZATOR_ROOT="$TMP_DIR/zator-t"
        mkdir -p "$ZATOR_ROOT/tools/bin"
        z2r_media_prepare() { Z2R_MEDIA_DIR="$media"; Z2R_MEDIA_READY=1; return 0; }
        z2r_quic_curl_install() {
            cp "$TMP_DIR/bin/curl-h3-mock" "$ZATOR_ROOT/tools/bin/curl-h3-i686"
            chmod 755 "$ZATOR_ROOT/tools/bin/curl-h3-i686"
            echo "h3-curl: установлен (мок)" >&2
            return 0
        }
        z2r_quic_single_round() { echo 'green|2500000|h3 5/5 (кусок 1, кусок 2, кусок 3, середина, конец): 0.5 МБ/с'; }
        orch_locked_clear 5 udp
        # Оффер теперь ПЕРВЫЙ (до промпта стратегии): вход 1, стратегия, видео, сохранить.
        out_c="$(ansi_clean "$(printf '1\n23\nM7lc1UVf-VE\n1\n\n' | Z2R_QUIC_ASSUME_TTY=1 orch_profile_try 5 "Профиль 5" "udp" "" 2>&1)")"
        # read -p не печатает промпт при пайпе — assert'им вход оффера и факт установки.
        printf '%s' "$out_c" | grep -q "h3-curl не найден: проверка видео" \
          || fail "ручной без curl: нет входа в предложение установки: $out_c"
        printf '%s' "$out_c" | grep -q "h3-curl: установлен (мок)" \
          || fail "ручной без curl: установка не вызвалась: $out_c"
        test -s "$ZATOR_ROOT/tools/bin/curl-h3-i686" \
          || fail "ручной без curl: мок-установка не сработала"
        printf '%s' "$out_c" | grep -q "QUIC: OK" \
          || fail "ручной без curl: после установки нет QUIC-вердикта: $out_c"
        test "$(orch_locked_get 5 udp)" = 23 \
          || fail "ручной без curl: лок = $(orch_locked_get 5 udp), ожидался 23"
        # Оффер идёт ДО старта подбора (фидбэк «слишком поздно»).
        # (read -p промпт не печатается при пайпе, а grep-пайплайны под
        # pipefail без guard'а молча убивают скрипт — потому || true.)
        line_offer="$(printf '%s\n' "$out_c" | grep -n "h3-curl не найден: проверка видео" | head -1 | cut -d: -f1 || true)"
        line_applied="$(printf '%s\n' "$out_c" | grep -n "применена" | head -1 | cut -d: -f1 || true)"
        [ -n "$line_offer" ] && [ -n "$line_applied" ] && [ "$line_offer" -lt "$line_applied" ] \
          || fail "оффер должен идти до старта подбора: $out_c"
        # Не-tty: предложение установки НЕ появляется, деградация без проверки.
        rm -f "$ZATOR_ROOT/tools/bin/curl-h3-i686"
        orch_locked_clear 5 udp
        out_c="$(ansi_clean "$(printf '7\nM7lc1UVf-VE\n0\n\n' | orch_profile_try 5 "Профиль 5" "udp" "" 2>&1)")"
        printf '%s' "$out_c" | grep -q "подбор без QUIC-проверки" \
          || fail "ручной без curl (не-tty): нет сообщения деградации: $out_c"
        printf '%s' "$out_c" | grep -q "h3-curl: установлен (мок)" \
          && fail "ручной без curl (не-tty): не должен предлагать установку"
        orch_locked_clear 5 udp
    )

    # == 7i. set -e-гигиена QUIC-путей: ничего не убивает меню ===================
    (
        set -e
        export Z2R_QUIC_SETTLE=0 Z2R_QUIC_ATTEMPT_PAUSE=0
        # 7i-1: пауза/устаканивание с нулём (rc 1 у [) не убивают под set -e.
        _z2r_quic_settle
        _z2r_quic_settle 0
        _z2r_quic_attempt_pause
        # 7i-2: ручной путь целиком под set -e с нулевыми паузами.
        config_profile_max_strategy() { case "$1" in 5) echo 32 ;; *) echo 0 ;; esac; }
        z2r_quic_single_round() { echo 'green|2500000|h3 5/5 (кусок 1, кусок 2, кусок 3, середина, конец): 0.5 МБ/с'; }
        orch_locked_clear 5 udp
        out_c="$(ansi_clean "$(printf '12\nM7lc1UVf-VE\n1\n\n' | orch_profile_try 5 "Профиль 5" "udp" "" 2>&1)")"
        printf '%s' "$out_c" | grep -q "Стратегия 12 сохранена для профиля 5." \
          || fail "set -e: ручной путь с SETTLE=0 упал: $out_c"
        # 7i-3: сбой записи лока на восстановлении — вызывающий жив.
        orch_locked_set() { return 1; }
        orch_locked_clear() { return 1; }
        z2r_quic_check() { echo 'FAIL|network_error|28|0|000|0|0|0|0|15.0|0'; }
        printf '0\n' | z2r_quic_sweep_run >/dev/null
        # 7i-4: сбой записи в EXIT-trap trial — mutex убран, вызывающий жив.
        z2r_media_prepare() { Z2R_MEDIA_DIR="$media"; Z2R_MEDIA_READY=1; return 0; }
        fail_run() { touched=1; return 1; }
        Z2R_QUIC_LOCK_DIR="$TMP_DIR/quiclock-torture" _z2r_quic_trial fail_run >/dev/null 2>&1 || true
        test ! -d "$TMP_DIR/quiclock-torture.lock" || fail "set -e: trap не убрал mutex после сбоя"
        echo survived
    ) | grep -q survived || fail "set -e: QUIC-путь роняет вызывающего"

# == 8. режим «без проверки» ==================================================
export Z2R_QUIC_BLIND_PAUSE=0
blind_sleep_mock() { z2r_quic_blind_interrupted=1; return 1; }
_z2r_quic_blind_sleep() { blind_sleep_mock; }
# Enter — сохранить текущую (1).
orch_locked_clear 5 udp
out="$(printf '\n' | z2r_quic_sweep_blind)"
printf '%s' "$out" | grep -q "Режим без проверки" || fail "blind: нет заголовка режима: $out"
printf '%s' "$out" | grep -q "Стратегия 1 сохранена для профиля 5." || fail "blind: стратегия 1 не сохранена: $out"
test "$(orch_locked_get 5 udp)" = 1 || fail "blind: лок = $(orch_locked_get 5 udp), ожидался 1"
# 0 — вернуть прежнее.
orch_locked_set 5 udp 3
out="$(printf '0\n' | z2r_quic_sweep_blind)"
printf '%s' "$out" | grep -q "прежняя стратегия профиля возвращена" || fail "blind: 0 не вернул прежний лок"
test "$(orch_locked_get 5 udp)" = 3 || fail "blind: прежний лок 3 потерян"
orch_locked_clear 5 udp
# Нет числа стратегий — отказ.
config_profile_max_strategy() { echo 0; }
printf '\n' | z2r_quic_sweep_blind >/dev/null 2>&1 \
  && fail "blind: без числа стратегий должна быть ошибка"
config_profile_max_strategy() { case "$1" in 5) echo 5 ;; *) echo 0 ;; esac; }

# == 9. деградация: нет h3-curl ==============================================
z2r_quic_curl_detect() { return 1; }
z2r_quic_curl_install() { echo "mock install" >&2; return 1; }
out="$(printf '\n\n' | z2r_quic_media_run 2>&1)"
printf '%s' "$out" | grep -q "Проверка видео по QUIC недоступна" \
  || fail "деградация: нет сообщения о недоступности: $out"
# Установка declined + слепой режим принят: слепой перебор запускается.
orch_locked_clear 5 udp
out="$(printf '\n1\n\n' | z2r_quic_media_run 2>&1)"
printf '%s' "$out" | grep -q "Режим без проверки" || fail "деградация: слепой режим не запущен: $out"
orch_locked_clear 5 udp
unset -f z2r_quic_curl_detect z2r_quic_curl_install
source lib/quic_media.sh   # восстановить настоящие функции после unset

# == 10. media_run: видео спрашивается, trial готовит медиа ===================
z2r_quic_curl_detect() { echo "$TMP_DIR/bin/curl-h3-mock"; return 0; }
z2r_media_prepare() { Z2R_MEDIA_DIR="$media"; Z2R_MEDIA_READY=1; return 0; }
z2r_quic_sweep_run() { echo "sweep-ok media_id=$Z2R_QUIC_MEDIA_VIDEO_ID"; return 0; }
out="$(printf 'https://youtu.be/M7lc1UVf-VE\n' | Z2R_QUIC_LOCK_DIR="$TMP_DIR/quiclock5" z2r_quic_media_run 2>&1)"
printf '%s' "$out" | grep -q "sweep-ok media_id=M7lc1UVf-VE" \
  || fail "media_run: video id не дошёл до перебора: $out"

echo 'quic media smoke ok'
