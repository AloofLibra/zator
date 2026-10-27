#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/youtube_media.sh
source lib/netcheck.sh
green="<green>"; red="<red>"; yellow="<yellow>"; plain="<reset>"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export Z2R_SUPERSWEEP_DIR="$tmp/old-sweep"
mkdir "$Z2R_SUPERSWEEP_DIR"
touch "$Z2R_SUPERSWEEP_DIR/cancel"
for mode in ok fail partial unknown unavailable; do
    (
        : > "$tmp/probes"; : > "$tmp/legacy"
        z2r_media_install_jq() { echo 'FAIL: installation during a check' >&2; exit 1; }
        z2r_media_resolve() {
            echo "$2" > "$tmp/cache-path"
            echo ready > "$2/status"
            echo '8388608|audio/mp4|audio.googlevideo.com|9999999999' > "$2/audio.params"
            echo '33554432|video/webm|video.googlevideo.com|9999999999' > "$2/video.params"
            if [ "$mode" = unavailable ]; then echo parser_missing > "$2/status"; return 1; fi
        }
        z2r_media_probe() {
            test -z "$Z2R_SUPERSWEEP_DIR"
            test "${5:-0}" = 0
            printf '%s %s %s %s\n' "$Z2R_MEDIA_TLS_VERSION" "$2" "$3" "$4" >> "$tmp/probes"
            case "$mode" in
                ok) echo 'OK|media_range|0|206|1024|.1|.2|.3|.4|2560' ;;
                partial)
                    if [ "$Z2R_MEDIA_TLS_VERSION" = 12 ]; then echo 'FAIL|network_error|28|000|0|0|0|0|5|0'
                    else echo 'OK|media_range|0|206|1024|.1|.2|.3|.4|2560'; fi ;;
                fail) echo 'FAIL|incomplete_transfer|18|206|99|.1|.2|.3|.4|256' ;;
                unknown) echo 'UNKNOWN|cdn_403|0|403|0|.1|.2|.3|.4|0' ;;
            esac
        }
        get_yt_cluster_domain() { echo cdn.example; }
        check_access() { echo "$1" >> "$tmp/legacy"; }
        check_googlevideo_access "$Z2R_MEDIA_DEFAULT_VIDEO_ID" > "$tmp/output" 2>&1
        case "$mode" in
            ok) grep -q '<green>Media OK.*<reset>' "$tmp/output" ;;
            partial) grep -q '<yellow>Media WARN.*<reset>' "$tmp/output" ;;
            fail) grep -q '<red>Media FAIL.*<reset>' "$tmp/output" ;;
            *) grep -q '<yellow>.*Media UNKNOWN.*<reset>' "$tmp/output" ;;
        esac
        test ! -d "$(cat "$tmp/cache-path")"
        if [ "$mode" = unavailable ]; then
            grep -q 'плюшевый' "$tmp/output"
            test "$(cat "$tmp/legacy")" = https://cdn.example
            test ! -s "$tmp/probes"
        else
            test ! -s "$tmp/legacy"
            grep -q '^Googlevideo audio: audio.googlevideo.com$' "$tmp/output"
            grep -q '^Googlevideo video: video.googlevideo.com$' "$tmp/output"
            if [ "$mode" = ok ]; then
                test "$(cat "$tmp/probes")" = $'12 audio 262144 0\n12 video 1048576 0\n12 video 2097152 1\n13 audio 262144 0\n13 video 1048576 0\n13 video 2097152 1'
                grep -q 'Media OK' "$tmp/output"
            elif [ "$mode" = partial ]; then
                test "$(wc -l < "$tmp/probes")" = 4
                grep -q 'TLS 1.2: FAIL' "$tmp/output"
                grep -q 'TLS 1.3: OK' "$tmp/output"
            else
                test "$(wc -l < "$tmp/probes")" = 2
                grep -qi "Media $mode" "$tmp/output"
            fi
        fi
    )
done
(
    z2r_media_check_manual() { return 130; }
    check_access() { touch "$tmp/cancel-fallback"; }
    check_googlevideo_access "$Z2R_MEDIA_DEFAULT_VIDEO_ID" > "$tmp/output"
    test ! -e "$tmp/cancel-fallback"
    grep -q 'прервана' "$tmp/output"
)
(
    z2r_media_check_manual() { printf '%s\n' "$Z2R_MEDIA_VIDEO_ID" > "$tmp/chosen"; }
    check_access() { echo 'FAIL: selection invoked fallback' >&2; exit 1; }
    printf 'https://youtu.be/M7lc1UVf-VE?si=public\n' | check_googlevideo_access > "$tmp/output" 2> "$tmp/prompt"
    test "$(cat "$tmp/chosen")" = M7lc1UVf-VE
    rm "$tmp/chosen"
    printf '0\n' | check_googlevideo_access > "$tmp/output" 2> "$tmp/prompt"
    test ! -e "$tmp/chosen"
)
# Реальный resolver при отсутствии обоих парсеров не должен вызывать установку/диалог.
(
    command() { case "$*" in '-v jq'|'-v jsonfilter') return 1 ;; *) builtin command "$@" ;; esac; }
    z2r_media_install_jq() { touch "$tmp/install-called"; }
    z2r_media_offer_jq() { touch "$tmp/install-called"; }
    mkdir "$tmp/cache"
    ! z2r_media_resolve aqz-KE-bpKQ "$tmp/cache" 2>/dev/null
    test "$(cat "$tmp/cache/status")" = parser_missing
    test ! -e "$tmp/install-called"
)
# Реальный пошаговый путь меню: один resolver и общий план на всю серию.
source lib/config.sh
source lib/supersweep.sh
source lib/strategies.sh
for scenario in cancel save fallback expired signal; do
    (
        export Z2R_SUPERSWEEP_DIR="$tmp/series"
        printf '7\n' > "$tmp/strategy"
        : > "$tmp/resolves"; : > "$tmp/probes"; : > "$tmp/legacy"
        orch_max_strategy_for_profile() { echo 3; }
        profile_state_display() { echo 7; }
        orch_locked_state_get() { cat "$tmp/strategy"; }
        orch_locked_set() { printf '%s\n' "$3" > "$tmp/strategy"; }
        profile_state_set_and_apply() { orch_locked_set "$1" tls "$3"; }
        get_config_file() { echo "$tmp/config"; }
        config_get_var() { :; }
        profile_strategy_restart_if_needed() { :; }
        pause_enter() { :; }
        show_hint() { :; }
        telemetry_notify() { :; }
        _supersweep_settle() { :; }
        get_yt_cluster_domain() { echo cdn.example; }
        check_access() { echo root >> "$tmp/legacy"; }
        z2r_media_resolve() {
            test "$1" = BPk1uJ4txPc
            echo "$2" >> "$tmp/resolves"
            echo ready > "$2/status"
            echo '8388608|audio/mp4|audio.googlevideo.com|9999999999' > "$2/audio.params"
            echo '33554432|video/webm|video.googlevideo.com|9999999999' > "$2/video.params"
            echo '{}' > "$2/meta.json"
            if [ "$scenario" = fallback ]; then echo parser_missing > "$2/status"; return 1; fi
        }
        z2r_media_probe() {
            test "$1" = "$(cat "$tmp/resolves")"
            test -d "$1"
            test "${5:-0}" = 0
            test "$Z2R_SUPERSWEEP_ISOLATED" = 0
            test -z "$Z2R_TLS_LOCAL_PORTS"
            printf '%s %s %s %s\n' "$(cat "$tmp/strategy")" "$2" "$3" "$4" >> "$tmp/probes"
            if [ "$scenario" = signal ]; then
                kill -TERM "$(cat "$tmp/series.lock/pid")"
                echo 'UNKNOWN|cancelled|0|000|0|0|0|0|0|0'
            elif [ "$scenario" = expired ] && [ "$(cat "$tmp/strategy")" = 2 ]; then
                echo 'UNKNOWN|url_expired|0|000|0|0|0|0|0|0'
            else
                echo 'OK|media_range|0|206|1024|.1|.2|.3|.4|2560'
            fi
        }
        if [ "$scenario" = save ]; then answer=1; else answer=0; fi
        printf '1\n\n\n%s\n' "$answer" | orch_profile_try 2 Googlevideo tls https://old.googlevideo.com/ > "$tmp/series.log" 2>&1
        test "$(wc -l < "$tmp/resolves")" = 1
        test ! -d "$(cat "$tmp/resolves")"
        test ! -d "$tmp/series.lock"
        if [ "$scenario" = save ]; then expected=2; else expected=7; fi
        test "$(cat "$tmp/strategy")" = "$expected"
        case "$scenario" in
            fallback) test "$(wc -l < "$tmp/legacy")" = 2; test ! -s "$tmp/probes" ;;
            signal) grep -q 'прерван' "$tmp/series.log" ;;
            expired) test "$(wc -l < "$tmp/probes")" = 8; grep -q 'url_expired' "$tmp/series.log"; test ! -s "$tmp/legacy" ;;
            *) test "$(wc -l < "$tmp/probes")" = 12; test ! -s "$tmp/legacy" ;;
        esac
    )
done
echo 'youtube media manual smoke ok'
