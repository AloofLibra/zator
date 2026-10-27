#!/bin/sh
# Необязательный resolver/probe. URL живут только в приватном tmpfs вне архива sweep.

z2r_media_ua() {
    printf '%s' 'com.google.visionos.youtube/1.04(RealityDevice17,1; U; CPU visionOS 26_6_0 like Mac OS X; US)'
}

z2r_media_status() {
    printf '%s\n' "$1" > "$2/status"
}

z2r_media_install_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    echo 'Media probe: jq отсутствует, пробую установить пакет jq.' >&2
    if command -v opkg >/dev/null 2>&1; then
        opkg install jq >&2 || { opkg update >&2 && opkg install jq >&2; } || :
    elif command -v apk >/dev/null 2>&1; then
        apk add jq >&2 || :
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y jq >&2 || { apt-get update >&2 && apt-get install -y jq >&2; } || :
    fi
    command -v jq >/dev/null 2>&1 && return 0
    echo 'Media probe: установить jq не удалось; медиапроверка недоступна.' >&2
    return 1
}

# Только установщик/обновление вызывают этот диалог с живого терминала.
z2r_media_ask_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    local answer
    printf 'Установить jq для проверки настоящих медиаданных YouTube? 1 — да, Enter — нет: ' >&2
    IFS= read -r answer || answer=""
    if [ "$answer" = 1 ]; then
        z2r_media_install_jq || :
    else
        echo 'Установка jq пропущена. Без него используется плюшевый TLS/CDN-тест.' >&2
    fi
    return 0
}

# Старый deploy.sh уже работает в памяти при обновлении: новый CLI завершает setup.
z2r_media_offer_jq() {
    [ -t 0 ] || return 0
    command -v jq >/dev/null 2>&1 && return 0
    local cache="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache" version answered
    version=$(sed -n 's/^ZATOR_SHA="\([^"]*\)"$/\1/p' "$cache/deploy/version.env" 2>/dev/null) || version=""
    version=${version:-legacy}
    answered=""
    [ ! -f "$cache/jq-offer" ] || IFS= read -r answered < "$cache/jq-offer" || true
    [ "$answered" != "$version" ] || return 0
    z2r_media_ask_jq
    mkdir -p "$cache" && printf '%s\n' "$version" > "$cache/jq-offer" || true
}

z2r_media_url_valid() {
    local url="$1" authority
    case "$url" in https://*.googlevideo.com/videoplayback\?*) ;; *) return 1 ;; esac
    case "$url" in *[![:print:]]*|*\"*|*\\*) return 1 ;; esac
    authority=${url#https://}; authority=${authority%%/*}
    case "$authority" in *[!a-zA-Z0-9.-]*|.*|*..*) return 1 ;; esac
    case "$authority" in *.googlevideo.com) ;; *) return 1 ;; esac
    case "$url" in "https://$authority/videoplayback?"*) ;; *) return 1 ;; esac
    case "&${url#*\?}" in *'&sig='*|*'&signature='*) ;; *) return 1 ;; esac
}

# curl без пользовательского .curlrc, proxy/cookies и повторов. Никаких Player JS.
z2r_media_api() {
    curl -q -4 --noproxy '*' --proto '=https' -s --connect-timeout 5 --max-time 15 \
        --max-filesize 262144 -A "$(z2r_media_ua)" \
        -H 'Content-Type: application/json' -H 'X-Goog-Api-Format-Version: 2' \
        --data-binary "@$2" -o "$3" -w '%{http_code}' "$1" 2>/dev/null
}

# Разбор отдельно от сети позволяет тестировать обезличенные фикстуры.
z2r_media_select() {
    jq -e --arg id "$2" --arg cpn "$3" '
        def direct:
            .url? | strings | startswith("https://");
        def choose($kind):
            [.streamingData.adaptiveFormats[]? |
                select(direct and (.mimeType | startswith($kind + "/"))) |
                select((.drmFamilies // [] | length) == 0) |
                select((.contentLength | tonumber) >= 4096)] |
            sort_by(.bitrate) |
            ([.[] | select(.contentLength|tonumber >= (if $kind=="video" then 8388608 else 1048576 end))] + .) | .[0];
        . as $r | choose("audio") as $a | choose("video") as $v |
        {video_id:$id, playability:($r.playabilityStatus.status // "MISSING"),
         response_video_id:($r.videoDetails.videoId // ""),
         cipher:([$r.streamingData.adaptiveFormats[]? |
                  select(.signatureCipher != null or .cipher != null)] | length > 0),
         audio:$a, video:$v, cpn:$cpn} |
        .audio |= (if . then {url:.url,itag:.itag,mime_type:.mimeType,length:(.contentLength|tonumber)} else null end) |
        .video |= (if . then {url:.url,itag:.itag,mime_type:.mimeType,length:(.contentLength|tonumber)} else null end)
    ' "$1" > "$4/selected.json" 2>/dev/null || { z2r_media_status invalid_json "$4"; return 1; }
    local state actual cipher
    state=$(jq -r '.playability' "$4/selected.json")
    actual=$(jq -r '.response_video_id' "$4/selected.json")
    if [ "$state" != OK ]; then
        if jq -e '(.playabilityStatus.reason // "" | strings | ascii_downcase) | contains("po token") or contains("potoken")' "$1" >/dev/null 2>&1; then
            state=po_token_required
        elif [ "$state" = LOGIN_REQUIRED ]; then state=auth_required
        else state=video_unavailable; fi
        z2r_media_status "$state" "$4"; return 1
    fi
    if [ "$actual" != "$2" ]; then z2r_media_status video_id_mismatch "$4"; return 1; fi
    if ! jq -e '.audio != null and .video != null' "$4/selected.json" >/dev/null; then
        cipher=$(jq -r '.cipher' "$4/selected.json")
        if [ "$cipher" = true ]; then state=signature_cipher; else state=no_format; fi
        z2r_media_status "$state" "$4"; return 1
    fi
    # Проверяем URL как данные; не eval/source и не передаём URL в argv curl.
    jq -r '.audio.url,.video.url' "$4/selected.json" | while IFS= read -r url; do
        z2r_media_url_valid "$url" || exit 1
    done || { z2r_media_status invalid_url "$4"; return 1; }
    if jq -e '[.audio.url,.video.url] | any(.[]; (split("?")[1]|split("&")|any(.[]; startswith("n="))))' \
        "$4/selected.json" >/dev/null; then
        z2r_media_status unsupported_n "$4"; return 1
    fi
    jq --arg cpn "$3" '
        def metadata:
            .cdn_hostname=(.url|split("/")[2]) |
            .expires_at=(.url|split("?")[1]|split("&")|map(select(startswith("expire="))|split("=")[1]|tonumber)|min) |
            .url += ("&cpn="+$cpn);
        .audio |= metadata | .video |= metadata |
        {video_id, audio_url:.audio.url, video_url:.video.url,
         audio_itag:.audio.itag, video_itag:.video.itag,
         mime_type:{audio:.audio.mime_type,video:.video.mime_type},
         cdn_hostname:{audio:.audio.cdn_hostname,video:.video.cdn_hostname},
         audio_length:.audio.length, video_length:.video.length,
         audio_expires_at:.audio.expires_at, video_expires_at:.video.expires_at,
         expires_at:([.audio.expires_at,.video.expires_at]|min), resolver_status:"ready"}
    ' "$4/selected.json" > "$4/media.json" 2>/dev/null || { z2r_media_status invalid_url "$4"; return 1; }
    z2r_media_fresh "$4" || { z2r_media_status expired "$4"; return 1; }
    z2r_media_status ready "$4"
}

z2r_media_fresh() {
    jq -e --argjson now "$(date +%s)" '[.audio_expires_at,.video_expires_at] | all(.[]; type=="number" and . > ($now + 120))' "$1/media.json" >/dev/null 2>&1
}

# dir создаёт вызывающий с umask 077. Только /tmp: никаких записей URL на flash.
z2r_media_resolve() (
    umask 077
    local id="$1" dir="$2" code rc cpn t version major minor
    case "$id" in ''|*[!a-zA-Z0-9_-]*) z2r_media_status invalid_video_id "$dir"; return 1 ;; esac
    [ "${#id}" = 11 ] || { z2r_media_status invalid_video_id "$dir"; return 1; }
    command -v jq >/dev/null 2>&1 || {
        echo 'jq отсутствует: реальная медиапроверка недоступна.' >&2
        z2r_media_status parser_missing "$dir"; return 1
    }
    # До 8.4 --max-filesize не ограничивает ответ без Content-Length.
    version=$(curl -q --version 2>/dev/null) || { z2r_media_status curl_unavailable "$dir"; return 1; }
    version=${version#curl }; version=${version%% *}
    major=${version%%.*}; minor=${version#*.}; minor=${minor%%.*}
    case "$major:$minor" in *[!0-9:]*|:*|*:) z2r_media_status curl_unsupported "$dir"; return 1 ;; esac
    if [ "$major" -lt 8 ] || { [ "$major" = 8 ] && [ "$minor" -lt 4 ]; }; then
        z2r_media_status curl_too_old "$dir"; return 1
    fi
    # 16 URL-safe случайных символов: nonce воспроизведения, не PO-токен.
    cpn=$(cat /proc/sys/kernel/random/uuid | tr -d '\n-')
    cpn=${cpn%????????????????}; t=${cpn%????}
    [ "${#cpn}" = 16 ] || { z2r_media_status random_failed "$dir"; return 1; }
    printf '%s\n' '{"context":{"client":{"clientName":"VISIONOS","clientVersion":"1.04","clientScreen":"WATCH","platform":"MOBILE","deviceMake":"Apple","deviceModel":"RealityDevice17,1","osName":"visionOS","osVersion":"26.6.0.23O770","hl":"en","gl":"US","utcOffsetMinutes":0},"request":{"internalExperimentFlags":[],"useSsl":true},"user":{"lockedSafetyMode":false}}}' > "$dir/request.json"
    code=$(z2r_media_api 'https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false' "$dir/request.json" "$dir/visitor.json"); rc=$?
    if [ "$rc" != 0 ] || [ "$code" != 200 ]; then
        case "$code" in 403) code=innertube_denied ;; 429) code=rate_limited ;; 000) code=network_error ;; *) code=api_error ;; esac
        z2r_media_status "$code" "$dir"; return 1
    fi
    jq -e --slurpfile v "$dir/visitor.json" --arg id "$id" --arg cpn "$cpn" '
        $v[0].responseContext.visitorData as $visitor |
        if ($visitor|type)=="string" and ($visitor|length)>0 then
            .context.client.visitorData=$visitor | .videoId=$id | .cpn=$cpn |
            .contentCheckOk=true | .racyCheckOk=true
        else error("visitor missing") end
    ' "$dir/request.json" > "$dir/player-request.json" 2>/dev/null || { z2r_media_status visitor_missing "$dir"; return 1; }
    code=$(z2r_media_api "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false&t=$t&id=$id&%24fields=playabilityStatus,videoDetails(videoId,lengthSeconds),streamingData" \
        "$dir/player-request.json" "$dir/player.json"); rc=$?
    if [ "$rc" != 0 ] || [ "$code" != 200 ]; then
        case "$code" in 403) code=innertube_denied ;; 429) code=rate_limited ;; 000) code=network_error ;; *) code=api_error ;; esac
        z2r_media_status "$code" "$dir"; return 1
    fi
    z2r_media_select "$dir/player.json" "$id" "$cpn" "$dir" || return 1
    rm -f "$dir/request.json" "$dir/visitor.json" "$dir/player-request.json" "$dir/player.json" "$dir/selected.json"
)

# Подготовка через рабочее соединение ДО установки тестового транспорта.
supersweep_media_prepare() {
    local status row kind
    Z2R_MEDIA_DIR=$(umask 077; mktemp -d /tmp/zator-media.XXXXXX) || return 1
    Z2R_MEDIA_READY=0
    if z2r_media_resolve "${Z2R_MEDIA_VIDEO_ID:-aqz-KE-bpKQ}" "$Z2R_MEDIA_DIR"; then
        Z2R_MEDIA_READY=1
        for kind in audio video; do
            row=$(z2r_media_probe "$Z2R_MEDIA_DIR" "$kind" 16384 0) || row='UNKNOWN|probe_error'
            if [ "${row%%|*}" != OK ]; then
                Z2R_MEDIA_READY=0
                z2r_media_status "baseline_${row#*|}" "$Z2R_MEDIA_DIR"
                break
            fi
        done
    fi
    IFS= read -r status < "$Z2R_MEDIA_DIR/status"
    status=${status%%|*}
    printf '%s\n' "$status" > "$Z2R_SUPERSWEEP_DIR/media-status"
    if [ "$Z2R_MEDIA_READY" = 1 ]; then
        jq 'del(.audio_url,.video_url)' "$Z2R_MEDIA_DIR/media.json" > "$Z2R_SUPERSWEEP_DIR/media-meta.json"
        echo 'Googlevideo: подписанные media URL проверены; аудио + видео + удалённый диапазон, TCP (QUIC не проверяется).' >&2
    else
        echo "Googlevideo: Media UNKNOWN ($status). Плюшевый TLS/CDN-тест; медиазагрузка не подтверждена, победитель профиля 2 автоматически не применяется." >&2
    fi
    return 0
}

# Пункт 1 меню: проверяется рабочее соединение, без подмены стратегий/firewall.
z2r_media_check_manual() (
    umask 077
    local Z2R_SUPERSWEEP_DIR="" Z2R_SUPERSWEEP_ISOLATED=0
    local dir item kind count middle row state reason rc code bytes tcp tls ttfb total speed color
    dir=$(mktemp -d /tmp/zator-media.XXXXXX) || return 1
    trap 'rm -rf "$dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if ! z2r_media_resolve "${Z2R_MEDIA_VIDEO_ID:-aqz-KE-bpKQ}" "$dir"; then
        IFS= read -r reason < "$dir/status" || reason=resolver_error
        printf '%bGooglevideo Media UNKNOWN: %s%b\n' "${yellow:-}" "$reason" "${plain:-}"
        return 1
    fi
    echo 'Googlevideo: реальная загрузка аудио/видео по TCP (QUIC не проверяется).'
    for item in "audio:${Z2R_MEDIA_AUDIO_BYTES:-262144}:0" "video:${Z2R_MEDIA_VIDEO_BYTES:-1048576}:0" "video:${Z2R_MEDIA_VERIFY_BYTES:-2097152}:1"; do
        kind=${item%%:*}; item=${item#*:}; count=${item%%:*}; middle=${item#*:}
        row=$(z2r_media_probe "$dir" "$kind" "$count" "$middle") || row='UNKNOWN|probe_error|0|000|0|0|0|0|0|0'
        IFS='|' read -r state reason rc code bytes tcp tls ttfb total speed <<EOF
$row
EOF
        case "$state" in OK) color=${green:-} ;; FAIL) color=${red:-} ;; *) color=${yellow:-} ;; esac
        printf '%bMedia %s: %s, середина=%s; HTTP %s, %s байт, %s с, %s Б/с (%s)%b\n' "$color" "$state" "$kind" "$middle" "$code" "$bytes" "$total" "$speed" "$reason" "${plain:-}"
        [ "$state" = OK ] || break
    done
    return 0
)

# stdout: итог последней пробы; безопасные подробные метрики отдельно от старого TSV.
supersweep_media_check() {
    local strategy="$1" item kind count middle row state reason
    if [ "${Z2R_MEDIA_READY:-0}" != 1 ]; then
        printf 'UNKNOWN|resolver_unavailable|0|000|0|0|0|0|0|0\n'; return 0
    fi
    for item in "audio:${Z2R_MEDIA_AUDIO_BYTES:-262144}:0" "video:${Z2R_MEDIA_VIDEO_BYTES:-1048576}:0" "video:${Z2R_MEDIA_VERIFY_BYTES:-2097152}:1"; do
        kind=${item%%:*}; item=${item#*:}; count=${item%%:*}; middle=${item#*:}
        row=$(z2r_media_probe "$Z2R_MEDIA_DIR" "$kind" "$count" "$middle" "${Z2R_SUPERSWEEP_ISOLATED:-0}") || row='UNKNOWN|probe_error|0|000|0|0|0|0|0|0'
        printf '%s\t%s\t%s\t%s\t%s\n' "$strategy" "$kind" "$middle" "$row" "${Z2R_MEDIA_TLS_VERSION:-auto}" >> "$Z2R_SUPERSWEEP_DIR/media.tsv"
        state=${row%%|*}; reason=${row#*|}; reason=${reason%%|*}
        [ "$state" = OK ] || break
    done
    printf '%s\n' "$row"
}

# Старый формат TLS-метрик, но каждый успех подтверждён медиаданными, не корнем CDN.
supersweep_media_target() {
    local strategy="$1" pref="${2:-both}" version row state reason rc code bytes tcp tls ttfb total speed
    local v12 v13 r12 r13 s12 s13 selected token label
    for version in 12 13; do
        row=$(Z2R_MEDIA_TLS_VERSION=$version _supersweep_check_target "$strategy" supersweep_media_check) || return 1
        IFS='|' read -r state reason rc code bytes tcp tls ttfb total speed <<EOF
$row
EOF
        # HTTP 206 сам по себе не означает успешную передачу.
        if [ "$state" = OK ]; then selected="0|206|HTTP/1.1|$total|"; else selected="56|000|HTTP/1.1|$total|"; fi
        if [ "$version" = 12 ]; then v12=$selected; r12=$row; s12=$state; else v13=$selected; r13=$row; s13=$state; fi
        [ "$reason" != cancelled ] || break
    done
    r13=${r13:-$r12}; s13=${s13:-UNKNOWN}; v13=${v13:-56|000|HTTP/1.1|0|}
    case "$pref:$s12:$s13" in
        12:OK:*|13:*:OK|any:OK:*|any:*:OK|both:OK:OK) token=ok; label=OK ;;
        12:UNKNOWN:*|13:*:UNKNOWN|*:UNKNOWN:*|*:*:UNKNOWN) token=unknown; label=UNKNOWN ;;
        *:OK:*|*:*:OK) token=warn; label=WARN ;;
        *) token=fail; label=FAIL ;;
    esac
    case "$pref" in 12) selected=$r12 ;; *) selected=$r13 ;; esac
    if [ "$pref" = any ] && [ "$s12" = OK ]; then selected=$r12; fi
    if [ "$pref" = both ] && [ "$s12" != OK ]; then selected=$r12; fi
    if [ "$token" = warn ]; then
        if [ "$s12" = OK ]; then selected=$r12; else selected=$r13; fi
    fi
    IFS='|' read -r state reason rc code bytes tcp tls ttfb total speed <<EOF
$selected
EOF
    printf '%s\n%s\n%s\n%s\n' "$v12" "$v13" "$rc|$code|$bytes|$total" \
        "$token|Media $label: $reason; $bytes байт за $total с"
}

# OK/FAIL/UNKNOWN | reason | curl_rc | HTTP | bytes | TCP | TLS | TTFB | total | B/s.
# Для SuperSweep require_queue=1; standalone PoC проверяет только медиаресурс.
z2r_media_probe() (
    umask 077
    local dir="$1" kind="$2" count="$3" middle="$4" require_queue="${5:-0}"
    local length mime host expire offset end row rc pid before after state reason headers
    local code bytes tcp tls ttfb total speed location url_override="${6:-}" redirects="${7:-2}"
    case "$kind" in audio|video) ;; *) return 1 ;; esac
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    [ "$count" -ge 4096 ] && [ "$count" -le 4194304 ] || return 1
    row=$(jq -r --arg k "$kind" '[.[$k+"_length"],(.mime_type[$k]|split(";")[0]),.cdn_hostname[$k],.[$k+"_expires_at"]] | @tsv' "$dir/media.json") || return 1
    IFS="$(printf '\t')" read -r length mime host expire <<EOF
$row
EOF
    if ! z2r_media_fresh "$dir"; then printf 'UNKNOWN|expired|0|000|0|0|0|0|0|0\n'; return 0; fi
    # Не скачивать целиком даже короткий поток; оба диапазона ограничены четвертью.
    [ "$count" -le $((length / 4)) ] || count=$((length / 4))
    offset=0; [ "$middle" != 1 ] || offset=$((length / 2))
    end=$((offset + count - 1))
    if [ "$require_queue" = 1 ]; then
        if [ "${Z2R_SUPERSWEEP_ISOLATED:-0}" != 1 ] || ! supersweep_probe_healthy; then
            printf 'UNKNOWN|isolation_unavailable|0|000|0|0|0|0|0|0\n'; return 0
        fi
        before=$(supersweep_probe_sequence) || return 1
    fi
    if [ -n "$url_override" ]; then
        z2r_media_url_valid "$url_override" || return 1
        printf 'url = "%s"\n' "$url_override" > "$dir/curl.conf"
    else
        jq -r --arg k "$kind" '"url = " + (.[$k+"_url"]|@json)' "$dir/media.json" > "$dir/curl.conf" || return 1
    fi
    trap 'if [ -n "${pid:-}" ]; then kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi; rm -f "$dir/curl.conf" "$dir/headers" "$dir/metrics"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    set --
    if [ "$require_queue" = 1 ]; then set -- --local-port 62000-62999; fi
    case "${Z2R_MEDIA_TLS_VERSION:-}" in
        12) set -- "$@" --tlsv1.2 --tls-max 1.2 ;;
        13) set -- "$@" --tlsv1.3 --tls-max 1.3 ;;
    esac
    # Один curl = новое TCP/TLS-соединение. stderr не должен раскрывать URL.
    curl -q -4 --noproxy '*' --proto '=https' --http1.1 -s \
        --config "$dir/curl.conf" -A "$(z2r_media_ua)" "$@" \
        --range "$offset-$end" --max-filesize "$count" --limit-rate 2M \
        --connect-timeout 5 --max-time 15 --speed-limit 1024 --speed-time 5 \
        -D "$dir/headers" -o /dev/null \
        -w '%{http_code}|%{size_download}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{speed_download}' \
        > "$dir/metrics" 2>/dev/null </dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ -n "${Z2R_SUPERSWEEP_DIR:-}" ] && [ -e "$Z2R_SUPERSWEEP_DIR/cancel" ]; then
            kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; pid=
            printf 'UNKNOWN|cancelled|0|000|0|0|0|0|0|0\n'; return 0
        fi
        sleep 1
    done
    rc=0; wait "$pid" || rc=$?; pid=
    IFS='|' read -r code bytes tcp tls ttfb total speed < "$dir/metrics" || :
    state=UNKNOWN; reason=invalid_response
    if [ "$require_queue" = 1 ]; then
        after=$(supersweep_probe_sequence) || after=$before
        if ! supersweep_probe_healthy || [ "$after" = "$before" ]; then
            printf 'UNKNOWN|noqueue|%s|%s|%s|%s|%s|%s|%s|%s\n' "$rc" "${code:-000}" "${bytes:-0}" "${tcp:-0}" "${tls:-0}" "${ttfb:-0}" "${total:-0}" "${speed:-0}"; return 0
        fi
    fi
    case "$code" in
        301|302|307|308)
            location=$(awk 'tolower($1)=="location:" {sub(/^[^:]*:[ ]*/, "");sub(/\r$/, "");print;exit}' "$dir/headers")
            if [ "$rc" = 0 ] && [ "$redirects" -gt 0 ] && z2r_media_url_valid "$location"; then
                # Только подписанный redirect CDN; каждое соединение проверяется отдельно.
                z2r_media_probe "$dir" "$kind" "$count" "$middle" "$require_queue" "$location" $((redirects - 1))
                return $?
            fi
            ;;
    esac
    headers=$(awk -v expected="bytes $offset-$end/$length" -v mime="$mime" '
        /^HTTP\// {range="";type=""}
        {sub(/\r$/, ""); key=tolower($1); if(key=="content-range:") {sub(/^[^:]*:[ ]*/, "");range=$0}
         if(key=="content-type:") {sub(/^[^:]*:[ ]*/, "");split($0,a,";");type=a[1]}}
        END {print (range==expected && type==mime)?"valid":"invalid"}' "$dir/headers")
    case "$code" in
        403) reason=cdn_403 ;;
        429) reason=rate_limited ;;
        206)
            if [ "$rc" = 0 ] && [ "$headers" = valid ] && [ "$bytes" = "$count" ]; then
                state=OK; reason=media_range
            elif [ "$headers" = valid ]; then
                case "$rc" in 0|18|28|56) state=FAIL; reason=incomplete_transfer ;; esac
            fi ;;
        000)
            reason=network_error
            # Передача может сломаться до HTTP; DNS/возможности curl не оценивают стратегию.
            case "$rc" in 7|18|28|35|52|55|56) state=FAIL ;; esac ;;
    esac
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$state" "$reason" "$rc" "${code:-000}" "${bytes:-0}" "${tcp:-0}" "${tls:-0}" "${ttfb:-0}" "${total:-0}" "${speed:-0}"
)
