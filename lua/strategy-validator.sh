#!/bin/sh
# Async worker for circular_quality; hostname is read only from a validated TSV.

QUEUE_DIR=/tmp/z2r-strategy-validation
CURL_BIN="$(command -v curl 2>/dev/null)" || CURL_BIN=

if [ -z "$CURL_BIN" ]; then
    echo "strategy-validator: curl is required" >&2
    exit 127
fi

process_request() {
    req=$1
    case "$req" in "$QUEUE_DIR"/request.[0-9]*) ;; *) return 1 ;; esac
    id=${req##*.}
    case "$id" in ''|*[!0-9]*) return 1 ;; esac
    work=$req.work
    mv "$req" "$work" 2>/dev/null || return 0

    IFS='	' read -r rid askey hostkey strategy host extra < "$work"
    if [ -n "$extra" ] || [ "$rid" != "$id" ]; then rm -f "$work"; return 1; fi
    case "$askey" in ''|*[!A-Za-z0-9_.-]*) rm -f "$work"; return 1 ;; esac
    case "$hostkey" in ''|*[!A-Za-z0-9_.-]*) rm -f "$work"; return 1 ;; esac
    case "$strategy" in ''|*[!0-9]*) rm -f "$work"; return 1 ;; esac
    case "$host" in ''|.*|*.|*..*|*[!A-Za-z0-9.-]*) rm -f "$work"; return 1 ;; esac

    result=$QUEUE_DIR/result.$id
    tmp=$result.tmp.$$
    status=ERROR
    "$CURL_BIN" -sS --http1.1 --connect-timeout 5 --max-time 15 "https://$host/" -o /dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then status=OK
    elif [ "$rc" -ne 5 ] && [ "$rc" -ne 6 ]; then status=FAIL
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$status" "$askey" "$hostkey" "$strategy" > "$tmp" && mv -f "$tmp" "$result"
    logger -t strategy-validator "id=$id host=$hostkey strategy=$strategy status=$status"
    rm -f "$work"
}

if [ "$1" = "--daemon" ]; then
    mkdir -p "$QUEUE_DIR" || exit 1
    while :; do
        for req in "$QUEUE_DIR"/request.[0-9]*; do
            [ -f "$req" ] && process_request "$req"
        done
        sleep 1
    done
fi

process_request "$1"
