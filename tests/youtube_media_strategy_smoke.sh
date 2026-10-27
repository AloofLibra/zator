#!/usr/bin/env bash
# Реальный путь меню: профиль 2 -> A -> полный/первый, транспорт/сеть замоканы.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v jq >/dev/null
source lib/config.sh
source lib/netcheck.sh
source lib/supersweep.sh
source lib/strategies.sh
tmp=$(mktemp -d)
trap 'rc=$?; if [ "$rc" != 0 ]; then cat "$tmp/log" >&2; fi; rm -rf "$tmp"' EXIT
export Z2R_SUPERSWEEP_DIR="$tmp/run" Z2R_SWEEP_PAUSE=0 Z2R_SUPERSWEEP_SETTLE=0
export ORCH_LOCK_FILE="$tmp/locked.tsv"
touch "$tmp/config"
for scenario in full first fallback cancel startfail busy manual; do
    (
        printf '2\ttls\t7\n' > "$ORCH_LOCK_FILE"
        : > "$tmp/trace"; : > "$tmp/saved"
        get_config_file() { echo "$tmp/config"; }
        config_get_var() { echo 0; }
        orch_max_strategy_for_profile() { if [ "$scenario" = first ]; then echo 4; else echo 3; fi; }
        profile_state_display() { echo 7; }
        orch_locked_state_get() { awk '$1==2 {print $3}' "$ORCH_LOCK_FILE"; }
        orch_locked_set() {
            echo "set|$ORCH_LOCK_FILE|$3" >> "$tmp/trace"
            printf '2\ttls\t%s\n' "$3" > "$ORCH_LOCK_FILE"
        }
        orch_locked_clear() { : > "$ORCH_LOCK_FILE"; }
        profile_state_set_and_apply() { echo "$3" > "$tmp/saved"; orch_locked_set "$1" tls "$3"; }
        profile_strategy_restart_if_needed() { :; }
        pause_enter() { :; }
        show_hint() { :; }
        telemetry_notify() { :; }
        zapret2_running() { return 0; }
        sleep() { :; }
        _supersweep_settle() { :; }
        check_googlevideo_access() { echo manual_media >> "$tmp/trace"; }
        check_access() { echo 'FAIL: old root check' >&2; exit 1; }
        supersweep_media_prepare() {
            echo prepare >> "$tmp/trace"
            Z2R_MEDIA_DIR=$(mktemp -d /tmp/zator-media.XXXXXX)
            echo "cache|$Z2R_MEDIA_DIR" >> "$tmp/trace"
            echo '{"cdn_hostname":{"video":"media.googlevideo.com"}}' > "$Z2R_MEDIA_DIR/media.json"
            Z2R_MEDIA_READY=1
            if [ "$scenario" = fallback ]; then
                Z2R_MEDIA_READY=0
                echo 'jq отсутствует: плюшевый TLS/CDN-тест.' >&2
            fi
        }
        supersweep_transport_start() { :; }
        supersweep_probe_start() {
            [ "$scenario" != startfail ] || return 1
            test "$1" = 2
            echo start >> "$tmp/trace"
            mkdir -p "$Z2R_SUPERSWEEP_DIR/probe"
            : > "$Z2R_SUPERSWEEP_DIR/probe/locked.tsv"
            export Z2R_TLS_LOCAL_PORTS=62000-62999
        }
        supersweep_probe_stop() { echo stop >> "$tmp/trace"; unset Z2R_TLS_LOCAL_PORTS; }
        z2r_tls_check_target() { echo root >> "$tmp/trace"; printf '0|404|HTTP/1.1|.1|192.0.2.1\n0|404|HTTP/1.1|.1|192.0.2.1\nskip\n'; }
        _supersweep_check_target() { echo 'FAIL: root during media' >&2; exit 1; }
        supersweep_media_check() {
            test "$Z2R_TLS_LOCAL_PORTS" = 62000-62999
            test "$(cat "$ORCH_LOCK_FILE")" = $'2\ttls\t7'
            test "$Z2R_MEDIA_TLS_VERSION" = 12 || test "$Z2R_MEDIA_TLS_VERSION" = 13
            echo "media|$1" >> "$tmp/trace"
            if [ "$scenario" = first ]; then echo 'OK|media_range|0|206|2097152|.1|.2|.3|1|2097152'; return; fi
            if [ "$scenario" = fallback ]; then echo 'UNKNOWN|parser_missing|0|000|0|0|0|0|0|0'; return; fi
            if [ "$scenario" = cancel ]; then touch "$Z2R_SUPERSWEEP_DIR/cancel"; echo 'UNKNOWN|cancelled|0|000|0|0|0|0|0|0'; return; fi
            case "$1" in
                1) echo 'UNKNOWN|noqueue|0|206|0|.1|.2|.3|1|0' ;;
                2) echo 'FAIL|incomplete_transfer|18|206|99|.1|.2|.3|1|99' ;;
                3) echo 'OK|media_range|0|206|2097152|.1|.2|.3|1|2097152' ;;
            esac
        }
        if [ "$scenario" = busy ]; then mkdir "$Z2R_SUPERSWEEP_DIR.lock"; fi
        if [ "$scenario" = manual ]; then
            printf '1\n0\n' | orch_profile_try 2 'Профиль 2: TCP 443 (Googlevideo)' tls https://old.googlevideo.com/ > "$tmp/log" 2>&1
        elif [ "$scenario" = first ]; then
            printf 'A\n1\n\n\n\n' | orch_profile_try 2 'Профиль 2: TCP 443 (Googlevideo)' tls https://old.googlevideo.com/ > "$tmp/log" 2>&1
        else
            printf 'A\n2\n\n\n0\n' | orch_profile_try 2 'Профиль 2: TCP 443 (Googlevideo)' tls https://old.googlevideo.com/ > "$tmp/log" 2>&1
        fi
        if [ "$scenario" = fallback ]; then
            test "$(grep -c '^root$' "$tmp/trace")" = 3
            grep -Fq "$(printf '%b' "$green")tls1.2 404" "$tmp/log"
        else
            ! grep -q '^root$' "$tmp/trace"
        fi
        case "$scenario" in
            full)
                grep -q 'Media UNKNOWN: noqueue' "$tmp/log"
                grep -q 'Media FAIL: incomplete_transfer' "$tmp/log"
                grep -q 'Media OK: media_range' "$tmp/log"
                grep -Fq "$(printf '%b' "$green")Media OK" "$tmp/log"
                grep -Fq "$(printf '%b' "$red")Media FAIL" "$tmp/log"
                grep -Fq "$(printf '%b' "$yellow")Media UNKNOWN" "$tmp/log"
                grep -q 'Лучшая .*: .*3' "$tmp/log"
                test ! -s "$tmp/saved" ;;
            first)
                test "$(cat "$tmp/saved")" = 1
                test "$(grep -c '^media|' "$tmp/trace")" = 2 ;;
            fallback)
                grep -q 'плюшевый' "$tmp/log"
                ! grep -q 'Лучшая ' "$tmp/log"
                test ! -s "$tmp/saved" ;;
            cancel) grep -qi 'прерван' "$tmp/log"; test ! -s "$tmp/saved" ;;
            startfail) test ! -s "$tmp/saved"; ! grep -q '^media|' "$tmp/trace" ;;
            busy) test -d "$Z2R_SUPERSWEEP_DIR.lock"; test ! -s "$tmp/trace"; rmdir "$Z2R_SUPERSWEEP_DIR.lock" ;;
            manual) grep -q '^manual_media$' "$tmp/trace"; test ! -s "$tmp/saved" ;;
        esac
        if [ "$scenario" != first ]; then test "$(cat "$ORCH_LOCK_FILE")" = $'2\ttls\t7'; fi
        if [ "$scenario" != fallback ] && [ "$scenario" != first ] && [ "$scenario" != manual ]; then
            ! grep -Fq "set|$ORCH_LOCK_FILE|" "$tmp/trace"
        fi
        test ! -d "$Z2R_SUPERSWEEP_DIR.lock"
        if [ "$scenario" != manual ] && [ "$scenario" != busy ]; then test "$(grep -c '^prepare$' "$tmp/trace")" = 1; fi
        while IFS='|' read -r event path rest; do
            [ "$event" != cache ] || test ! -d "$path"
        done < "$tmp/trace"
    )
done
# TLS-цель использует только подтверждённые media-ответы соответствующей версии.
supersweep_media_check() {
    local state=$first_state
    [ "$Z2R_MEDIA_TLS_VERSION" = 12 ] || state=$second_state
    if [ "$state" = OK ]; then
        echo 'OK|media_range|0|206|2097152|.1|.2|.3|.9|2330168'
    else
        echo "$state|network_error|28|000|0|0|0|0|5.002153|0"
    fi
}
for spec in both:FAIL:FAIL:fail both:FAIL:OK:warn both:OK:FAIL:warn 12:OK:FAIL:ok 13:OK:FAIL:warn any:OK:FAIL:ok both:OK:UNKNOWN:unknown 12:OK:UNKNOWN:ok both:UNKNOWN:UNKNOWN:unknown; do
    IFS=: read -r pref first_state second_state expected <<< "$spec"
    out=$(supersweep_media_target 1 "$pref")
    test "$(printf '%s\n' "$out" | sed -n '4s/|.*//p')" = "$expected"
    if [ "$expected" = warn ]; then
        test "$(printf '%s\n' "$out" | sed -n 3p)" = '0|206|2097152|.9'
    fi
done
echo 'youtube media strategy smoke ok'
