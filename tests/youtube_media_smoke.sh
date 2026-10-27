#!/usr/bin/env bash
# Без YouTube, сервисов и firewall. Нужен jq только на машине тестирования.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v jq >/dev/null || { echo 'FAIL: test prerequisite jq missing'; exit 1; }
source lib/youtube_media.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cache" "$tmp/bin" "$tmp/run"
export Z2R_SUPERSWEEP_DIR="$tmp/run"
fixture=tests/fixtures/youtube-media/player.json
select_fixture() { z2r_media_select "$1" aqz-KE-bpKQ 0123456789abcdef "$tmp/cache"; }
expect_status() { test "$(cat "$tmp/cache/status")" = "$1"; }
select_fixture "$fixture"
expect_status ready
bootstrap_loop=$(awk '/^for lib in \$Z2R_LIB_FILES; do$/ {inside=1} inside {print} inside && /^done$/ {exit}' z2r.sh)
(
    mkdir "$tmp/bootstrap"
    touch "$tmp/bootstrap/config.sh"
    LIB_DIR="$tmp/bootstrap" Z2R_LIB_FILES='config.sh youtube_media.sh' missing_libs=0
    eval "$bootstrap_loop"
    test "$missing_libs" = 0
    rm "$tmp/bootstrap/config.sh"
    missing_libs=0
    eval "$bootstrap_loop"
    test "$missing_libs" = 1
)
! z2r_media_url_valid 'https://evil.example/foo.googlevideo.com/videoplayback?sig=REDACTED'
! z2r_media_url_valid 'https://rr1---sn-example.googlevideo.com/foo.googlevideo.com/videoplayback?sig=REDACTED'
jq -e '.audio_itag==139 and .video_itag==160 and .cdn_hostname.audio=="rr1---sn-example.googlevideo.com"' "$tmp/cache/media.json" >/dev/null
for scenario in absent unavailable cipher n expired badhost wrongid potoken; do
    case "$scenario" in
        absent) filter='del(.streamingData)'; expected=no_format ;;
        unavailable) filter='.playabilityStatus.status="ERROR"'; expected=video_unavailable ;;
        cipher) filter='.streamingData.adaptiveFormats |= map(.signatureCipher="redacted" | del(.url))'; expected=signature_cipher ;;
        n) filter='.streamingData.adaptiveFormats[].url += "&n=redacted"'; expected=unsupported_n ;;
        expired) filter='.streamingData.adaptiveFormats[].url |= (split("4102444800")|join("1"))'; expected=expired ;;
        badhost) filter='.streamingData.adaptiveFormats[].url |= (split("rr1---sn-example.googlevideo.com")|join("evil.example"))'; expected=invalid_url ;;
        wrongid) filter='.videoDetails.videoId="jNQXAC9IVRw"'; expected=video_id_mismatch ;;
        potoken) filter='.playabilityStatus={status:"ERROR",reason:"PO token required"}'; expected=po_token_required ;;
    esac
    jq "$filter" "$fixture" > "$tmp/changed.json"
    if select_fixture "$tmp/changed.json"; then echo "FAIL: accepted $scenario"; exit 1; fi
    expect_status "$expected"
done
jq '.streamingData.adaptiveFormats[].mimeType="application/octet-stream"' "$fixture" > "$tmp/changed.json"
! select_fixture "$tmp/changed.json"; expect_status no_format
select_fixture "$fixture"
for scenario in missing 403 429 valid; do
    (
        z2r_media_api() {
            case "$scenario" in
                403|429) printf '%s' "$scenario" ;;
                missing) echo '{}' > "$3"; printf 200 ;;
                valid)
                    case "$1" in
                        *visitor_id*) echo '{"responseContext":{"visitorData":"REDACTED"}}' > "$3" ;;
                        *player*) cp "$fixture" "$3" ;;
                    esac
                    printf 200 ;;
            esac
        }
        case "$scenario" in
            valid) z2r_media_resolve aqz-KE-bpKQ "$tmp/cache"; expect_status ready ;;
            *)
                ! z2r_media_resolve aqz-KE-bpKQ "$tmp/cache"
                case "$scenario" in missing) expect_status visitor_missing ;; 403) expect_status innertube_denied ;; 429) expect_status rate_limited ;; esac ;;
        esac
    )
done
(
    curl() { echo 'curl 7.88.1 fake'; }
    ! z2r_media_resolve aqz-KE-bpKQ "$tmp/cache"
    expect_status curl_too_old
)
cat > "$tmp/bin/curl" <<'MOCK'
#!/bin/sh
set -eu
headers= range= config= tls_min= tls_max=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -D) headers="$2"; shift ;;
        --range) range="$2"; shift ;;
        --config) config="$2"; shift ;;
        --tlsv1.2) tls_min=12 ;;
        --tlsv1.3) tls_min=13 ;;
        --tls-max) tls_max="$2"; shift ;;
    esac
    shift
done
case "${Z2R_MEDIA_TLS_VERSION:-}" in
    12) test "$tls_min:$tls_max" = 12:1.2 ;;
    13) test "$tls_min:$tls_max" = 13:1.3 ;;
esac
test -n "$config" # URL не должен быть в argv.
case "${MOCK:-ok}" in
    wait) sleep 10; exit 0 ;;
    403|429) printf 'HTTP/1.1 %s\r\n\r\n' "$MOCK" > "$headers"; printf '%s|0|.1|.2|.3|.4|0' "$MOCK"; exit 0 ;;
    200) printf 'HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\n\r\n' > "$headers"; printf '200|1048576|.1|.2|.3|.4|12345'; exit 0 ;;
    redirect|badredirect)
        if ! grep -q redirected "$config"; then
            host=rr1---sn-example.googlevideo.com; [ "$MOCK" != badredirect ] || host=evil.example
            printf 'HTTP/1.1 302 Found\r\nLocation: https://%s/videoplayback?expire=4102444800&sig=REDACTED&redirected=1\r\n\r\n' "$host" > "$headers"
            printf '302|0|.1|.2|.3|.4|0'; exit 0
        fi ;;
esac
start=${range%-*}; end=${range#*-}; bytes=$((end-start+1)); rc=0
total=12000000; mime=video/mp4
grep -q 'itag=139' "$config" && { total=4000000; mime=audio/mp4; }
case "${MOCK:-ok}" in
    partial) bytes=99; rc=18 ;;
    reset) bytes=99; rc=56 ;;
    timeout) bytes=99; rc=28 ;;
    text) mime=text/html ;;
    wrongrange) end=$((end+1)) ;;
esac
printf 'HTTP/1.1 206 Partial Content\r\nContent-Type: %s\r\nContent-Range: bytes %s-%s/%s\r\n\r\n' "$mime" "$start" "$end" "$total" > "$headers"
printf '206|%s|.1|.2|.3|.4|12345' "$bytes"
exit "$rc"
MOCK
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
for scenario in ok 200 403 429 partial reset timeout text wrongrange redirect badredirect; do
    export MOCK="$scenario"
    result=$(z2r_media_probe "$tmp/cache" video 1048576 1)
    case "$scenario" in
        ok|redirect) [[ "$result" == OK\|media_range\|* ]] ;;
        partial|reset|timeout) [[ "$result" == FAIL\|incomplete_transfer\|* ]] ;;
        *) [[ "$result" == UNKNOWN\|* ]] ;;
    esac
done
MOCK=ok
for version in 12 13; do
    result=$(Z2R_MEDIA_TLS_VERSION=$version z2r_media_probe "$tmp/cache" video 1048576 0)
    [[ "$result" == OK\|media_range\|* ]]
done
export MOCK Z2R_SUPERSWEEP_ISOLATED=1
supersweep_probe_healthy() { return 0; }
supersweep_probe_sequence() { echo 100; }
result=$(z2r_media_probe "$tmp/cache" video 1048576 0 1)
[[ "$result" == UNKNOWN\|noqueue\|* ]]
supersweep_probe_sequence() { if [ -f "$tmp/seq" ]; then echo 101; else touch "$tmp/seq"; echo 100; fi; }
result=$(z2r_media_probe "$tmp/cache" video 1048576 0 1)
[[ "$result" == OK\|* ]]
export MOCK=wait
z2r_media_probe "$tmp/cache" video 1048576 0 > "$tmp/cancel-result" &
pid=$!
sleep 1
touch "$Z2R_SUPERSWEEP_DIR/cancel"
wait "$pid"
grep -q '^UNKNOWN|cancelled|' "$tmp/cancel-result"
rm "$Z2R_SUPERSWEEP_DIR/cancel"
(
    command() { case "$*" in '-v jq'|'-v opkg'|'-v apk'|'-v apt-get') return 1 ;; *) builtin command "$@" ;; esac; }
    ! z2r_media_resolve aqz-KE-bpKQ "$tmp/cache"
    expect_status parser_missing
)
# Старые отчёты сохраняют число/порядок столбцов. UNKNOWN не считается fail.
source lib/supersweep.sh
printf 'state=done\nstarted=1\nupdated=2\n' > "$tmp/run/status"
printf 'gv\tgv\tprofile\t2\thttps://example.org/\t1\n' > "$tmp/run/workers.tsv"
printf '1\t2\t1\tunknown\tfail\tfail\t0\t0\tMedia UNKNOWN\n' > "$tmp/run/progress.gv.tsv"
echo parser_missing > "$tmp/run/media-status"
supersweep_report_tsv | awk -F '\t' '$1=="W" {if(NF!=14 || $6!=1 || $7!=0 || $8!=1 || $9!=0) exit 1; found=1} END {if(!found)exit 1}'
# UNKNOWN не входит ни в greens/warns, ни в кандидаты победителя.
_supersweep_request_lock() { return 0; }
_supersweep_settle() { :; }
_supersweep_check_target() { printf '0|200|HTTP/1.1|.1|192.0.2.1\n0|200|HTTP/1.1|.1|192.0.2.1\n0|206|65536|.1\n'; }
source lib/netcheck.sh
Z2R_SUPERSWEEP_MEDIA=1 Z2R_MEDIA_READY=0 Z2R_SUPERSWEEP_SETTLE=0 \
    _supersweep_worker_profile gv gv 2 tls https://example.org/ 1 any 0 > "$tmp/worker.log"
grep -q '^best=$' "$tmp/run/best.gv"
grep -q '^n_unknown=1$' "$tmp/run/best.gv"
! grep -q '^n_fail=1$' "$tmp/run/best.gv"
supersweep_media_check() {
    case "$1" in
        1) echo 'UNKNOWN|cdn_403|0|403|0|0|0|0|0|0' ;;
        2) echo 'FAIL|incomplete_transfer|18|206|99|.1|.2|.3|.4|200' ;;
        3) echo 'OK|media_range|0|206|2097152|.1|.2|.3|1|2097152' ;;
    esac
}
_supersweep_check_target() { echo 'FAIL: root during media' >&2; exit 1; }
Z2R_MEDIA_READY=1 Z2R_SUPERSWEEP_MEDIA=1 Z2R_SUPERSWEEP_SETTLE=0 \
    _supersweep_worker_profile gv gv 2 tls https://example.org/ 3 any 0 > "$tmp/worker.log"
grep -q '^best=3$' "$tmp/run/best.gv"
grep -q '^greens=3$' "$tmp/run/best.gv"
grep -q '^warns=$' "$tmp/run/best.gv"
grep -q '^n_unknown=1$' "$tmp/run/best.gv"
grep -q '^n_fail=1$' "$tmp/run/best.gv"
awk -F '\t' '$3==2 && $4=="fail" && $7==99 {found=1} END {exit !found}' "$tmp/run/progress.gv.tsv"
supersweep_media_check() { touch "$Z2R_SUPERSWEEP_DIR/cancel"; echo 'UNKNOWN|cancelled|0|000|0|0|0|0|0|0'; }
Z2R_MEDIA_READY=1 Z2R_SUPERSWEEP_MEDIA=1 _supersweep_worker_profile gv gv 2 tls https://example.org/ 1 any 0 > "$tmp/worker.log"
grep -q '^interrupted=1$' "$tmp/run/best.gv"
grep -q '^best=$' "$tmp/run/best.gv"
supersweep_report_save() { :; }
Z2R_MEDIA_DIR="$tmp/must-keep"
mkdir "$Z2R_MEDIA_DIR"
_supersweep_cleanup
test -d "$tmp/must-keep"
owned=$(mktemp -d /tmp/zator-media.XXXXXX)
Z2R_MEDIA_DIR="$owned"
_supersweep_cleanup
test ! -d "$owned"
echo 'youtube media smoke ok'
