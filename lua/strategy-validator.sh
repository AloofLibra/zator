#!/bin/sh
# Async worker for circular_quality; hostname is read only from a validated TSV.

QUEUE_DIR="${Z2R_VALIDATION_QUEUE:-/tmp/z2r-strategy-validation}"
Z2R_CURL_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'
CURL_BIN="$(command -v curl 2>/dev/null)" || CURL_BIN=

mkdir -p "$QUEUE_DIR" 2>/dev/null || true

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
    "$CURL_BIN" -sS --http1.1 -A "$Z2R_CURL_UA" --connect-timeout 5 --max-time 15 "https://$host/" -o /dev/null
    rc=$?
    tostate=$QUEUE_DIR/to.${hostkey}.${strategy}
    if [ "$rc" -eq 0 ]; then
        status=OK
        rm -f "$tostate" 2>/dev/null
    elif [ "$rc" -eq 5 ] || [ "$rc" -eq 6 ]; then
        status=ERROR
    elif [ "$rc" -eq 28 ]; then
        # Одиночный таймаут может быть случайным сбоем — ERROR (разрешён повтор).
        # Подряд идущие таймауты — типичный признак нерабочей стратегии: FAIL,
        # чтобы авторотация переключилась. Счётчик живёт 10 минут.
        tn=0
        if [ -f "$tostate" ] && [ -z "$(find "$tostate" -mmin +10 2>/dev/null)" ]; then
            tn="$(cat "$tostate" 2>/dev/null)"
        fi
        case "$tn" in ''|*[!0-9]*) tn=0 ;; esac
        tn=$((tn + 1))
        if [ "$tn" -ge 2 ]; then
            rm -f "$tostate" 2>/dev/null
            status=FAIL
        else
            printf '%s\n' "$tn" >"$tostate" 2>/dev/null || true
            status=ERROR
        fi
    else
        status=FAIL
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
