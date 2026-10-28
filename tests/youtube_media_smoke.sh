#!/usr/bin/env bash
# Без YouTube, сервисов и firewall. Нужен jq только на машине тестирования.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v jq >/dev/null || { echo 'FAIL: test prerequisite jq missing'; exit 1; }
source lib/youtube_media.sh
test "$Z2R_MEDIA_DEFAULT_VIDEO_ID" = BPk1uJ4txPc
for value in BPk1uJ4txPc 'https://www.youtube.com/watch?v=BPk1uJ4txPc' 'https://m.youtube.com/watch?si=public&v=BPk1uJ4txPc&t=5#part' 'https://youtu.be/BPk1uJ4txPc?si=public' 'https://youtube.com/shorts/BPk1uJ4txPc' 'https://youtube.com/live/BPk1uJ4txPc'; do
    test "$(z2r_media_video_id "$value")" = BPk1uJ4txPc
done
for value in bad 'https://evil.example/watch?v=BPk1uJ4txPc' 'https://youtube.com.evil.example/watch?v=BPk1uJ4txPc' 'https://youtube.com@evil.example/watch?v=BPk1uJ4txPc' 'https://youtube.com/watch?v=bad' 'BPk1uJ4txPc;id'; do
    ! z2r_media_video_id "$value"
done
test "$(printf '\n' | z2r_media_ask_video 2>/dev/null)" = BPk1uJ4txPc
test "$(printf 'bad\nhttps://youtu.be/M7lc1UVf-VE\n' | z2r_media_ask_video 2>/dev/null)" = M7lc1UVf-VE
! printf '0\n' | z2r_media_ask_video >/dev/null 2>&1
! z2r_media_ask_video </dev/null >/dev/null 2>&1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cache" "$tmp/bin" "$tmp/run"
export Z2R_SUPERSWEEP_DIR="$tmp/run"
real_media_check=$(declare -f z2r_media_check)
fixture=tests/fixtures/youtube-media/player.json
select_fixture() { z2r_media_select "$1" aqz-KE-bpKQ 0123456789abcdef "$tmp/cache"; }
expect_status() { test "$(cat "$tmp/cache/status")" = "$1"; }
select_fixture "$fixture"
expect_status ready
# Подготовка не проверяет текущую стратегию: CDN может быть заблокирован до перебора.
(
    Z2R_MEDIA_DIR=""
    trap '[ -z "$Z2R_MEDIA_DIR" ] || rm -rf "$Z2R_MEDIA_DIR"' EXIT
    z2r_media_resolve() { z2r_media_select "$fixture" aqz-KE-bpKQ 0123456789abcdef "$2"; }
    z2r_media_probe() { touch "$tmp/premature-probe"; return 1; }
    z2r_media_prepare > "$tmp/prepare-log" 2>&1
    test "$Z2R_MEDIA_READY" = 1
    test "$(cat "$Z2R_MEDIA_DIR/status")" = ready
    test "$(cat "$Z2R_SUPERSWEEP_DIR/media-status")" = ready
    test ! -e "$tmp/premature-probe"
    grep -q '^Googlevideo audio: rr1---sn-example.googlevideo.com$' "$tmp/prepare-log"
    ! grep -q 'Плюшевый' "$tmp/prepare-log"
)
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
printf '{' > "$tmp/broken.json"
! select_fixture "$tmp/broken.json"; expect_status invalid_json
test ! -e "$tmp/cache/video.curl"
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
for selection in tiny_preferred low_bitrate drm duplicate_itag null_drm; do
    case "$selection" in
        tiny_preferred) filter='.streamingData.adaptiveFormats += [(.streamingData.adaptiveFormats[0] | .itag=140 | .contentLength="8192" | .bitrate=1)]'; expected_itag=139 ;;
        low_bitrate) filter='.streamingData.adaptiveFormats += [(.streamingData.adaptiveFormats[0] | .itag=140 | .bitrate=1 | .drmFamilies=[])]'; expected_itag=140 ;;
        drm) filter='.streamingData.adaptiveFormats += [(.streamingData.adaptiveFormats[0] | .itag=140 | .bitrate=1 | .drmFamilies=["widevine"])]'; expected_itag=139 ;;
        null_drm) filter='.streamingData.adaptiveFormats[].drmFamilies=null'; expected_itag=139 ;;
        duplicate_itag) filter='.streamingData.adaptiveFormats += [(.streamingData.adaptiveFormats[0] | .bitrate=1 | .contentLength="5000000")]'; expected_itag=139 ;;
    esac
    jq "$filter" "$fixture" > "$tmp/ranked.json"
    for backend in jq jsonfilter; do
        command -v "$backend" >/dev/null 2>&1 || continue
        z2r_media_select "$tmp/ranked.json" aqz-KE-bpKQ 0123456789abcdef "$tmp/cache" "$backend"
        jq -e --argjson itag "$expected_itag" '.audio_itag==$itag' "$tmp/cache/media.json" >/dev/null
        jq -S . "$tmp/cache/media.json" > "$tmp/ranked-$backend.json"
    done
    if command -v jsonfilter >/dev/null 2>&1; then cmp "$tmp/ranked-jq.json" "$tmp/ranked-jsonfilter.json"; fi
done
select_fixture "$fixture"
for scenario in missing visitor_number visitor_quote visitor_newline 403 429 valid; do
    (
        : > "$tmp/cold-parser.calls"
        jq() { echo jq >> "$tmp/cold-parser.calls"; command jq "$@"; }
        z2r_media_api() {
            case "$1" in https://www.youtube.com/youtubei/v1/*) ;; *) return 1 ;; esac
            case "$scenario" in
                403|429) printf '%s' "$scenario" ;;
                missing) echo '{}' > "$3"; printf 200 ;;
                valid|visitor_number|visitor_quote|visitor_newline)
                    case "$1" in
                        *visitor_id*)
                            case "$scenario" in
                                visitor_newline) printf '%s\n' '{"responseContext":{"visitorData":"REDACTED\nEXTRA"}}' > "$3" ;;
                                visitor_number) echo '{"responseContext":{"visitorData":123}}' > "$3" ;;
                                visitor_quote) echo '{"responseContext":{"visitorData":"bad\\\"visitor"}}' > "$3" ;;
                                *) echo '{"responseContext":{"visitorData":"REDACTED"}}' > "$3" ;;
                            esac ;;
                        *player*)
                            command jq -e '.context.client.visitorData=="REDACTED" and .context.client.clientName=="VISIONOS" and .videoId=="aqz-KE-bpKQ" and .contentCheckOk==true and .racyCheckOk==true' "$2" >/dev/null || return 1
                            cp "$fixture" "$3" ;;
                    esac
                    printf 200 ;;
            esac
        }
        case "$scenario" in
            valid)
                z2r_media_resolve aqz-KE-bpKQ "$tmp/cache"; expect_status ready
                if [ "$(z2r_media_parser)" = jq ]; then test "$(wc -l < "$tmp/cold-parser.calls")" = 2
                else test ! -s "$tmp/cold-parser.calls"; fi ;;
            *)
                ! z2r_media_resolve aqz-KE-bpKQ "$tmp/cache"
                case "$scenario" in missing|visitor_number|visitor_quote|visitor_newline) expect_status visitor_missing ;; 403) expect_status innertube_denied ;; 429) expect_status rate_limited ;; esac ;;
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
    earlytimeout|connectfail|tlsfail|emptyreply|earlyreset|dnsfail|unsupported)
        : > "$headers"
        printf '000|0|0|0|0|5.002153|0'
        case "$MOCK" in
            earlytimeout) exit 28 ;; connectfail) exit 7 ;; tlsfail) exit 35 ;;
            emptyreply) exit 52 ;; earlyreset) exit 56 ;; dnsfail) exit 6 ;; unsupported) exit 4 ;;
        esac ;;
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
for scenario in ok 200 403 429 partial reset timeout text wrongrange redirect badredirect earlytimeout connectfail tlsfail emptyreply earlyreset dnsfail unsupported; do
    export MOCK="$scenario"
    result=$(z2r_media_probe "$tmp/cache" video 1048576 1)
    case "$scenario" in
        ok|redirect) [[ "$result" == OK\|media_range\|* ]] ;;
        partial|reset|timeout) [[ "$result" == FAIL\|incomplete_transfer\|* ]] ;;
        earlytimeout|connectfail|tlsfail|emptyreply|earlyreset) [[ "$result" == FAIL\|network_error\|* ]] ;;
        *) [[ "$result" == UNKNOWN\|* ]] ;;
    esac
done
MOCK=ok
for version in 12 13; do
    result=$(Z2R_MEDIA_TLS_VERSION=$version z2r_media_probe "$tmp/cache" video 1048576 0)
    [[ "$result" == OK\|media_range\|* ]]
done
# Прогретая проба и redirect не должны запускать НИ ОДНОГО JSON-парсера.
(
    jq() { echo 'FAIL: jq in media probe' >&2; exit 99; }
    jsonfilter() { echo 'FAIL: jsonfilter in media probe' >&2; exit 99; }
    for spec in audio:262144:0 video:1048576:0 video:2097152:1; do
        kind=${spec%%:*}; rest=${spec#*:}; count=${rest%%:*}; middle=${rest#*:}
        result=$(z2r_media_probe "$tmp/cache" "$kind" "$count" "$middle")
        [[ "$result" == OK\|media_range\|* ]]
    done
    MOCK=redirect
    result=$(z2r_media_probe "$tmp/cache" video 1048576 1)
    [[ "$result" == OK\|media_range\|* ]]
    date() { echo 4102444800; }
    result=$(z2r_media_probe "$tmp/cache" video 1048576 0)
    [[ "$result" == UNKNOWN\|expired\|* ]]
)
export MOCK Z2R_SUPERSWEEP_ISOLATED=1
supersweep_probe_healthy() { return 0; }
supersweep_probe_sequence() { echo 100; }
MOCK=earlytimeout
result=$(z2r_media_probe "$tmp/cache" video 1048576 0 1)
[[ "$result" == UNKNOWN\|noqueue\|* ]]
MOCK=ok
result=$(z2r_media_probe "$tmp/cache" video 1048576 0 1)
[[ "$result" == UNKNOWN\|noqueue\|* ]]
supersweep_probe_sequence() { if [ -f "$tmp/seq" ]; then echo 101; else touch "$tmp/seq"; echo 100; fi; }
result=$(z2r_media_probe "$tmp/cache" video 1048576 0 1)
[[ "$result" == OK\|* ]]
rm "$tmp/seq"
MOCK=earlytimeout
result=$(z2r_media_probe "$tmp/cache" video 1048576 0 1)
[[ "$result" == FAIL\|network_error\|28\|000\|0\|* ]]
export MOCK=wait
z2r_media_probe "$tmp/cache" video 1048576 0 > "$tmp/cancel-result" &
pid=$!
sleep 1
touch "$Z2R_SUPERSWEEP_DIR/cancel"
wait "$pid"
grep -q '^UNKNOWN|cancelled|' "$tmp/cancel-result"
rm "$Z2R_SUPERSWEEP_DIR/cancel"
(
    command() { case "$*" in '-v jq'|'-v jsonfilter'|'-v opkg'|'-v apk'|'-v apt-get') return 1 ;; *) builtin command "$@" ;; esac; }
    ! z2r_media_resolve aqz-KE-bpKQ "$tmp/cache"
    expect_status parser_missing
)
# Старые отчёты сохраняют число/порядок столбцов. UNKNOWN не считается fail.
source lib/supersweep.sh
media_check_wrapper=$(declare -f _supersweep_check_target)
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
z2r_media_check() {
    case "$1" in
        1) echo 'UNKNOWN|cdn_403|0|403|0|0|0|0|0|0' ;;
        2) echo 'FAIL|incomplete_transfer|18|206|99|.1|.2|.3|.4|200' ;;
        3) echo 'OK|media_range|0|206|2097152|.1|.2|.3|1|2097152' ;;
    esac
}
eval "$media_check_wrapper"
supersweep_probe_sequence() {
    local n=0
    [ ! -f "$tmp/worker-seq" ] || read -r n < "$tmp/worker-seq"
    echo $((n + 1)) > "$tmp/worker-seq"; cat "$tmp/worker-seq"
}
Z2R_MEDIA_READY=1 Z2R_SUPERSWEEP_MEDIA=1 Z2R_SUPERSWEEP_SETTLE=0 \
    _supersweep_worker_profile gv gv 2 tls https://example.org/ 3 any 0 > "$tmp/worker.log"
grep -q '^best=3$' "$tmp/run/best.gv"
grep -q '^greens=3$' "$tmp/run/best.gv"
grep -q '^warns=$' "$tmp/run/best.gv"
grep -q '^n_unknown=1$' "$tmp/run/best.gv"
grep -q '^n_fail=1$' "$tmp/run/best.gv"
awk -F '\t' '$3==2 && $4=="fail" && $7==99 {found=1} END {exit !found}' "$tmp/run/progress.gv.tsv"
# Восстановление транспорта относится к изолированному SuperSweep, не к обычному A.
for health_case in recovered dead; do
    (
        rm -f "$tmp/health-ready" "$Z2R_SUPERSWEEP_DIR/cancel"
        sleep() { :; }
        supersweep_probe_healthy() { test -e "$tmp/health-ready"; }
        supersweep_transport_reinstall() {
            [ "$health_case" = recovered ] || return 1
            touch "$tmp/health-ready"
        }
        z2r_media_check() { echo 'OK|media_range|0|206|2097152|.1|.2|.3|1|2097152'; }
        Z2R_SUPERSWEEP_ISOLATED=1 Z2R_MEDIA_READY=1 Z2R_SUPERSWEEP_MEDIA=1 Z2R_SUPERSWEEP_SETTLE=0 \
            _supersweep_worker_profile gv gv 2 tls https://example.org/ 1 both 0 > "$tmp/health.log" 2>&1
        if [ "$health_case" = recovered ]; then
            grep -q '^best=1$' "$tmp/run/best.gv"
            test ! -e "$Z2R_SUPERSWEEP_DIR/cancel"
        else
            grep -q '^interrupted=1$' "$tmp/run/best.gv"
            grep -q '^reason=transport_unavailable$' "$Z2R_SUPERSWEEP_DIR/probe/isolation-error"
            grep -q '^n_ok=0$' "$tmp/run/best.gv"
        fi
    )
done
rm -f "$Z2R_SUPERSWEEP_DIR/cancel"
for isolated in 0 1; do
    (
        eval "$real_media_check"
        z2r_media_probe() { test "$5" = "$isolated"; echo 'OK|media_range|0|206|1024|.1|.2|.3|1|1024'; }
        Z2R_MEDIA_READY=1 Z2R_MEDIA_DIR="$tmp/cache" Z2R_SUPERSWEEP_ISOLATED=$isolated z2r_media_check 1 > /dev/null
    )
done
(
    z2r_media_target() { return 1; }
    Z2R_MEDIA_READY=1 Z2R_SUPERSWEEP_MEDIA=1 _supersweep_worker_profile gv gv 2 tls https://example.org/ 1 both 0 > "$tmp/callback-error.log"
    grep -q '^interrupted=1$' "$tmp/run/best.gv"
    grep -q '^n_fail=0$' "$tmp/run/best.gv"
)
z2r_media_check() { touch "$Z2R_SUPERSWEEP_DIR/cancel"; echo 'UNKNOWN|cancelled|0|000|0|0|0|0|0|0'; }
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
