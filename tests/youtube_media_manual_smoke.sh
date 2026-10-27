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
for mode in ok fail unknown unavailable; do
    (
        : > "$tmp/probes"; : > "$tmp/legacy"
        z2r_media_install_jq() { echo 'FAIL: installation during a check' >&2; exit 1; }
        z2r_media_resolve() {
            echo "$2" > "$tmp/cache-path"
            if [ "$mode" = unavailable ]; then echo parser_missing > "$2/status"; return 1; fi
        }
        z2r_media_probe() {
            test -z "$Z2R_SUPERSWEEP_DIR"
            test "${5:-0}" = 0
            printf '%s %s %s\n' "$2" "$3" "$4" >> "$tmp/probes"
            case "$mode" in
                ok) echo 'OK|media_range|0|206|1024|.1|.2|.3|.4|2560' ;;
                fail) echo 'FAIL|incomplete_transfer|18|206|99|.1|.2|.3|.4|256' ;;
                unknown) echo 'UNKNOWN|cdn_403|0|403|0|.1|.2|.3|.4|0' ;;
            esac
        }
        get_yt_cluster_domain() { echo cdn.example; }
        check_access() { echo "$1" >> "$tmp/legacy"; }
        check_googlevideo_access "$Z2R_MEDIA_DEFAULT_VIDEO_ID" > "$tmp/output"
        case "$mode" in
            ok) grep -q '<green>Media OK.*<reset>' "$tmp/output" ;;
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
            if [ "$mode" = ok ]; then
                test "$(cat "$tmp/probes")" = $'audio 262144 0\nvideo 1048576 0\nvideo 2097152 1'
                grep -q 'Media OK' "$tmp/output"
            else
                test "$(wc -l < "$tmp/probes")" = 1
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
# Реальный resolver при отсутствии jq не должен вызывать установку/диалог.
(
    command() { case "$*" in '-v jq') return 1 ;; *) builtin command "$@" ;; esac; }
    z2r_media_install_jq() { touch "$tmp/install-called"; }
    z2r_media_offer_jq() { touch "$tmp/install-called"; }
    mkdir "$tmp/cache"
    ! z2r_media_resolve aqz-KE-bpKQ "$tmp/cache" 2>/dev/null
    test "$(cat "$tmp/cache/status")" = parser_missing
    test ! -e "$tmp/install-called"
)
echo 'youtube media manual smoke ok'
