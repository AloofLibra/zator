#!/bin/sh
# Необязательный resolver/probe. URL живут только в приватном tmpfs вне архива sweep.
Z2R_MEDIA_DEFAULT_VIDEO_ID=BPk1uJ4txPc

# Только известные YouTube URL; никакие страницы по пользовательскому адресу не загружаются.
z2r_media_video_id() {
    local value="$1" host path query part id=""
    case "$value" in
        https://*|http://*)
            path=${value#*://}; host=${path%%/*}; path=${path#*/}
            case "$host" in
                youtu.be|www.youtu.be) id=${path%%[/?#]*} ;;
                youtube.com|www.youtube.com|m.youtube.com|music.youtube.com)
                    case "$path" in
                        shorts/*|embed/*|live/*) id=${path#*/}; id=${id%%[/?#]*} ;;
                        watch\?*)
                            query=${path#*\?}; query=${query%%#*}
                            while [ -n "$query" ]; do
                                part=${query%%&*}
                                case "$query" in *'&'*) query=${query#*&} ;; *) query="" ;; esac
                                case "$part" in v=*) [ -z "$id" ] || return 1; id=${part#v=} ;; esac
                            done ;;
                    esac ;;
                *) return 1 ;;
            esac ;;
        *) id=$value ;;
    esac
    case "$id" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    [ "${#id}" = 11 ] || return 1
    printf '%s\n' "$id"
}

# Как остальные диалоги меню: stdout — только ответ, сообщения — stderr.
z2r_media_ask_video() {
    local answer id default="${Z2R_MEDIA_VIDEO_ID:-$Z2R_MEDIA_DEFAULT_VIDEO_ID}"
    while :; do
        printf 'Видео для Googlevideo: URL или ID (Enter — %s, 0 — отмена): ' "$default" >&2
        IFS= read -r answer || return 1
        case "$answer" in 0) return 1 ;; '') answer=$default ;; esac
        if id=$(z2r_media_video_id "$answer"); then printf '%s\n' "$id"; return 0; fi
        echo 'Неверный YouTube URL или video ID (нужно 11 символов). Повторите ввод.' >&2
    done
}

z2r_media_ua() {
    printf '%s' 'com.google.visionos.youtube/1.04(RealityDevice17,1; U; CPU visionOS 26_6_0 like Mac OS X; US)'
}

z2r_media_status() {
    printf '%s\n' "$1" > "$2/status"
}

# jsonfilter штатно доступен в OpenWrt; jq нужен только при его отсутствии.
z2r_media_parser() {
    if command -v jsonfilter >/dev/null 2>&1; then printf 'jsonfilter\n'
    elif command -v jq >/dev/null 2>&1; then printf 'jq\n'
    else return 1; fi
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
    z2r_media_parser >/dev/null 2>&1 && return 0
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
    z2r_media_parser >/dev/null 2>&1 && return 0
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

# Один jq разбирает player; после выбора парсер больше не нужен для media GET.
_z2r_media_select_jq() {
    jq -r '
        def choose($kind):
            [.streamingData.adaptiveFormats[]? |
                select(.url? | strings | startswith("https://")) |
                select(.mimeType? | strings | startswith($kind + "/")) |
                select((.drmFamilies // [] | length) == 0) |
                select((try (.contentLength | tonumber) catch 0) >= 4096)] |
            sort_by(.bitrate) |
            ([.[] | select(.contentLength|tonumber >= (if $kind=="video" then 8388608 else 1048576 end))] + .) | .[0];
        . as $r | choose("audio") as $a | choose("video") as $v |
        (if $r.playabilityStatus.status=="OK" then "OK"
         elif ($r.playabilityStatus.reason // "" | ascii_downcase | contains("po token") or contains("potoken")) then "po_token_required"
         elif $r.playabilityStatus.status=="LOGIN_REQUIRED" then "auth_required" else "video_unavailable" end),
        ($r.videoDetails.videoId // ""),
        ([$r.streamingData.adaptiveFormats[]? | select(.signatureCipher != null or .cipher != null)] | length > 0),
        ($a.url // ""), ($a.itag // ""), ($a.mimeType // "" | split(";")[0]), ($a.contentLength // ""),
        ($v.url // ""), ($v.itag // ""), ($v.mimeType // "" | split(";")[0]), ($v.contentLength // "")
    ' "$1" 2>/dev/null
}

_z2r_media_select_jsonfilter() {
    local file="$1" dir="$2" state actual="" reason cipher=false indices index base
    local url itag mime length rate drm_type drm extra has_extra kind large
    local au="" ai="" am="" al="" ar=0 ap=0 vu="" vi="" vm="" vl="" vr=0 vp=0
    state=$(jsonfilter -q -i "$file" -e '@.playabilityStatus.status') || {
        jsonfilter -q -l 0 -i "$file" -e '@' >/dev/null || return 1
        state=MISSING
    }
    if [ "$state" != OK ]; then
        reason=$(jsonfilter -q -i "$file" -e '@.playabilityStatus.reason' 2>/dev/null | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
        case "$reason" in *'po token'*|*potoken*) state=po_token_required ;;
            *) if [ "$state" = LOGIN_REQUIRED ]; then state=auth_required; else state=video_unavailable; fi ;;
        esac
    else
        actual=$(jsonfilter -q -i "$file" -e '@.videoDetails.videoId') || actual=""
        # Служебный вывод содержит только индексы массива, не значения. Никакого eval.
        indices=$(jsonfilter -q -i "$file" -F , -e 'indices=@.streamingData.adaptiveFormats') || indices=""
        indices=${indices#export indices=}; indices=${indices%'; '}
        while [ -n "$indices" ]; do
            index=${indices%%,*}
            case "$indices" in *,*) indices=${indices#*,} ;; *) indices="" ;; esac
            case "$index" in ''|*[!0-9]*) continue ;; esac
            base="@.streamingData.adaptiveFormats[$index]"
            jsonfilter -q -i "$file" -e "$base.url" -e "$base.itag" -e "$base.mimeType" \
                -e "$base.contentLength" -e "$base.bitrate" -t "$base.drmFamilies" -e "$base.drmFamilies" \
                > "$dir/format.fields" 2>/dev/null || :
            url=""; itag=""; mime=""; length=""; rate=""; drm_type=""; drm=""; has_extra=0
            { IFS= read -r url; IFS= read -r itag; IFS= read -r mime; IFS= read -r length
              IFS= read -r rate; IFS= read -r drm_type; IFS= read -r drm
              if IFS= read -r extra; then has_extra=1; fi
            } < "$dir/format.fields" || :
            [ "$has_extra" = 0 ] || continue
            case "$drm_type:$drm" in :|null:|'array:[]'|'array:[ ]') ;; *) continue ;; esac
            case "$url" in https://*) ;; *) continue ;; esac
            case "$itag" in ''|*[!0-9]*) continue ;; esac
            case "$length" in ''|*[!0-9]*) continue ;; esac
            case "$rate" in ''|*[!0-9]*) continue ;; esac
            case "$itag:$length" in 0?*:*|*:0?*) return 1 ;; esac
    [ "${#itag}" -le 6 ] && [ "${#length}" -le 15 ] && [ "${#rate}" -le 15 ] || continue
            [ "$length" -ge 4096 ] || continue
            mime=${mime%%;*}; large=0
            case "$mime" in
                audio/mp4|audio/webm) kind=audio; [ "$length" -lt 1048576 ] || large=1 ;;
                video/mp4|video/webm) kind=video; [ "$length" -lt 8388608 ] || large=1 ;;
                *) continue ;;
            esac
            if [ "$kind" = audio ]; then
                if [ -z "$au" ] || [ "$large" -gt "$ap" ] || { [ "$large" = "$ap" ] && [ "$rate" -lt "$ar" ]; }; then
                    au=$url; ai=$itag; am=$mime; al=$length; ar=$rate; ap=$large
                fi
            elif [ -z "$vu" ] || [ "$large" -gt "$vp" ] || { [ "$large" = "$vp" ] && [ "$rate" -lt "$vr" ]; }; then
                vu=$url; vi=$itag; vm=$mime; vl=$length; vr=$rate; vp=$large
            fi
        done
        if [ -z "$au" ] || [ -z "$vu" ]; then
            reason=$(jsonfilter -q -i "$file" -t '@.streamingData.adaptiveFormats[*].signatureCipher' -t '@.streamingData.adaptiveFormats[*].cipher') || :
            case "$reason" in *string*|*int*|*double*|*array*|*object*|*boolean*) cipher=true ;; esac
        fi
    fi
    printf '%s\n' "$state" "$actual" "$cipher" "$au" "$ai" "$am" "$al" "$vu" "$vi" "$vm" "$vl"
}

# Проверенные скаляры, не shell-код: params читаются через read, URL — только curl -K.
_z2r_media_cache_stream() {
    local dir="$1" kind="$2" url="$3" itag="$4" mime="$5" length="$6" cpn="$7" host query part expire="" value
    z2r_media_url_valid "$url" || return 1
    case "$itag:$length" in *[!0-9:]*|:*|*:) return 1 ;; esac
    [ "${#itag}" -le 6 ] && [ "${#length}" -le 15 ] && [ "$length" -ge 4096 ] || return 1
    case "$kind:$mime" in audio:audio/mp4|audio:audio/webm|video:video/mp4|video:video/webm) ;; *) return 1 ;; esac
    host=${url#https://}; host=${host%%/*}; query=${url#*\?}
    while [ -n "$query" ]; do
        part=${query%%&*}
        case "$query" in *'&'*) query=${query#*&} ;; *) query="" ;; esac
        case "$part" in
            n=*) z2r_media_status unsupported_n "$dir"; return 2 ;;
            expire=*)
                value=${part#expire=}
                case "$value" in ''|*[!0-9]*|0?*) return 1 ;; esac
                [ "${#value}" -le 12 ] || return 1
                if [ -z "$expire" ] || [ "$value" -lt "$expire" ]; then expire=$value; fi ;;
        esac
    done
    [ -n "$expire" ] || return 1
    printf '%s|%s|%s|%s\n' "$length" "$mime" "$host" "$expire" > "$dir/$kind.params" || return 1
    printf 'url = "%s&cpn=%s"\n' "$url" "$cpn" > "$dir/$kind.curl"
}

# Разбор отдельно от сети позволяет прогнать обе реализации на одних фикстурах.
z2r_media_select() {
    local file="$1" id="$2" cpn="$3" dir="$4" parser="${5:-}" state actual cipher au ai am al vu vi vm vl ah ae vh ve expires metadata rc
    rm -f "$dir/audio.params" "$dir/video.params" "$dir/audio.curl" "$dir/video.curl" "$dir/expires" "$dir/media.json" "$dir/meta.json"
    [ -n "$parser" ] || parser=$(z2r_media_parser) || { z2r_media_status parser_missing "$dir"; return 1; }
    case "$id$cpn" in *[!a-zA-Z0-9_-]*) z2r_media_status invalid_video_id "$dir"; return 1 ;; esac
    [ "${#id}" = 11 ] && [ "${#cpn}" = 16 ] || { z2r_media_status invalid_video_id "$dir"; return 1; }
    case "$parser" in
        jq) _z2r_media_select_jq "$file" > "$dir/selection" ;;
        jsonfilter) _z2r_media_select_jsonfilter "$file" "$dir" > "$dir/selection" ;;
        *) z2r_media_status parser_missing "$dir"; return 1 ;;
    esac || { z2r_media_status invalid_json "$dir"; return 1; }
    { IFS= read -r state; IFS= read -r actual; IFS= read -r cipher
      IFS= read -r au; IFS= read -r ai; IFS= read -r am; IFS= read -r al
      IFS= read -r vu; IFS= read -r vi; IFS= read -r vm; IFS= read -r vl
    } < "$dir/selection" || { z2r_media_status invalid_json "$dir"; return 1; }
    [ "$state" = OK ] || { z2r_media_status "$state" "$dir"; return 1; }
    [ "$actual" = "$id" ] || { z2r_media_status video_id_mismatch "$dir"; return 1; }
    if [ -z "$au" ] || [ -z "$vu" ]; then
        state=no_format; [ "$cipher" != true ] || state=signature_cipher
        z2r_media_status "$state" "$dir"; return 1
    fi
    for state in audio video; do
        rc=0
        if [ "$state" = audio ]; then _z2r_media_cache_stream "$dir" audio "$au" "$ai" "$am" "$al" "$cpn" || rc=$?
        else _z2r_media_cache_stream "$dir" video "$vu" "$vi" "$vm" "$vl" "$cpn" || rc=$?; fi
        [ "$rc" != 2 ] || return 1
        [ "$rc" = 0 ] || { z2r_media_status invalid_url "$dir"; return 1; }
    done
    IFS='|' read -r al am ah ae < "$dir/audio.params"
    IFS='|' read -r vl vm vh ve < "$dir/video.params"
    expires=$ae; [ "$ve" -ge "$expires" ] || expires=$ve
    printf '%s\n' "$expires" > "$dir/expires"
    z2r_media_fresh "$dir" || { z2r_media_status expired "$dir"; return 1; }
    printf '{"video_id":"%s","audio_itag":%s,"video_itag":%s,"mime_type":{"audio":"%s","video":"%s"},"cdn_hostname":{"audio":"%s","video":"%s"},"audio_length":%s,"video_length":%s,"audio_expires_at":%s,"video_expires_at":%s,"expires_at":%s,"resolver_status":"ready"}\n' \
        "$id" "$ai" "$vi" "$am" "$vm" "$ah" "$vh" "$al" "$vl" "$ae" "$ve" "$expires" > "$dir/meta.json" || return 1
    IFS= read -r metadata < "$dir/meta.json"
    printf '{"audio_url":"%s&cpn=%s","video_url":"%s&cpn=%s",%s\n' "$au" "$cpn" "$vu" "$cpn" "${metadata#\{}" > "$dir/media.json" || return 1
    rm -f "$dir/selection" "$dir/format.fields"
    z2r_media_status ready "$dir"
}

z2r_media_fresh() {
    local expires now
    IFS= read -r expires < "$1/expires" || return 1
    case "$expires" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#expires}" -le 12 ] || return 1
    now=$(date +%s) || return 1
    [ "$expires" -gt "$((now + 120))" ]
}

z2r_media_request() {
    printf '%s' '{"context":{"client":{"clientName":"VISIONOS","clientVersion":"1.04","clientScreen":"WATCH","platform":"MOBILE","deviceMake":"Apple","deviceModel":"RealityDevice17,1","osName":"visionOS","osVersion":"26.6.0.23O770","hl":"en","gl":"US","utcOffsetMinutes":0'
    [ -z "${3:-}" ] || printf ',"visitorData":"%s"' "$3"
    printf '%s' '},"request":{"internalExperimentFlags":[],"useSsl":true},"user":{"lockedSafetyMode":false}}'
    [ -z "${1:-}" ] || printf ',"videoId":"%s","cpn":"%s","contentCheckOk":true,"racyCheckOk":true' "$1" "$2"
    printf '}\n'
}

# dir создаёт вызывающий с umask 077. Только /tmp: никаких записей URL на flash.
z2r_media_resolve() (
    umask 077
    local id="$1" dir="$2" code rc cpn t version major minor parser visitor visitor_type visitor_extra
    case "$id" in ''|*[!a-zA-Z0-9_-]*) z2r_media_status invalid_video_id "$dir"; return 1 ;; esac
    [ "${#id}" = 11 ] || { z2r_media_status invalid_video_id "$dir"; return 1; }
    parser=$(z2r_media_parser) || {
        echo 'Нет jsonfilter или jq: реальная медиапроверка недоступна.' >&2
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
    z2r_media_request > "$dir/request.json"
    code=$(z2r_media_api 'https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false' "$dir/request.json" "$dir/visitor.json"); rc=$?
    if [ "$rc" != 0 ] || [ "$code" != 200 ]; then
        case "$code" in 403) code=innertube_denied ;; 429) code=rate_limited ;; 000) code=network_error ;; *) code=api_error ;; esac
        z2r_media_status "$code" "$dir"; return 1
    fi
    case "$parser" in
        jsonfilter)
            jsonfilter -q -i "$dir/visitor.json" -t '@.responseContext.visitorData' -e '@.responseContext.visitorData' > "$dir/visitor.fields" || :
            visitor_type=""; visitor=""
            { IFS= read -r visitor_type; IFS= read -r visitor; if IFS= read -r visitor_extra; then visitor_type=invalid; fi; } < "$dir/visitor.fields" || :
            [ "$visitor_type" = string ] || visitor="" ;;
        jq) visitor=$(jq -er '.responseContext.visitorData | select(type=="string" and length>0)' "$dir/visitor.json" 2>/dev/null) || visitor="" ;;
    esac
    case "$visitor" in ''|*[!a-zA-Z0-9_%=+/.-]*) z2r_media_status visitor_missing "$dir"; return 1 ;; esac
    [ "${#visitor}" -le 4096 ] || { z2r_media_status visitor_missing "$dir"; return 1; }
    z2r_media_request "$id" "$cpn" "$visitor" > "$dir/player-request.json"
    code=$(z2r_media_api "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false&t=$t&id=$id&%24fields=playabilityStatus,videoDetails(videoId,lengthSeconds),streamingData" \
        "$dir/player-request.json" "$dir/player.json"); rc=$?
    if [ "$rc" != 0 ] || [ "$code" != 200 ]; then
        case "$code" in 403) code=innertube_denied ;; 429) code=rate_limited ;; 000) code=network_error ;; *) code=api_error ;; esac
        z2r_media_status "$code" "$dir"; return 1
    fi
    z2r_media_select "$dir/player.json" "$id" "$cpn" "$dir" "$parser" || return 1
    rm -f "$dir/request.json" "$dir/visitor.json" "$dir/player-request.json" "$dir/player.json" "$dir/visitor.fields"
)

# Подготовка через рабочее соединение ДО установки тестового транспорта.
z2r_media_prepare() {
    local status kind length mime host expire
    Z2R_MEDIA_DIR=$(umask 077; mktemp -d /tmp/zator-media.XXXXXX) || return 1
    Z2R_MEDIA_READY=0
    if z2r_media_resolve "${Z2R_MEDIA_VIDEO_ID:-$Z2R_MEDIA_DEFAULT_VIDEO_ID}" "$Z2R_MEDIA_DIR"; then
        Z2R_MEDIA_READY=1
    fi
    IFS= read -r status < "$Z2R_MEDIA_DIR/status"
    status=${status%%|*}
    if [ -n "${Z2R_SUPERSWEEP_DIR:-}" ]; then
        printf '%s\n' "$status" > "$Z2R_SUPERSWEEP_DIR/media-status"
    fi
    if [ "$Z2R_MEDIA_READY" = 1 ]; then
        if [ -n "${Z2R_SUPERSWEEP_DIR:-}" ]; then cp "$Z2R_MEDIA_DIR/meta.json" "$Z2R_SUPERSWEEP_DIR/media-meta.json"; fi
        echo 'Googlevideo: подписанные media URL подготовлены; аудио + видео + удалённый диапазон, TCP (QUIC не проверяется).' >&2
        for kind in audio video; do
            IFS='|' read -r length mime host expire < "$Z2R_MEDIA_DIR/$kind.params" || return 1
            printf 'Googlevideo %s: %s\n' "$kind" "$host" >&2
        done
    else
        echo "Googlevideo: Media UNKNOWN ($status). Плюшевый TLS/CDN-тест; медиазагрузка не подтверждена, победитель профиля 2 автоматически не применяется." >&2
    fi
    return 0
}

# Пункт 1 меню: проверяется рабочее соединение, без подмены стратегий/firewall.
z2r_media_check_manual() (
    umask 077
    trap - EXIT
    local Z2R_MEDIA_DIR="${Z2R_MEDIA_DIR:-}" Z2R_MEDIA_READY="${Z2R_MEDIA_READY:-0}"
    local Z2R_SUPERSWEEP_DIR="${Z2R_SUPERSWEEP_DIR:-}" Z2R_SUPERSWEEP_ISOLATED=0 reason
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [ -z "$Z2R_MEDIA_DIR" ]; then
        # Отдельная проверка владеет кешем; в ручной серии им владеет orch_gv_trial.
        Z2R_SUPERSWEEP_DIR=""
        trap '[ -z "$Z2R_MEDIA_DIR" ] || rm -rf "$Z2R_MEDIA_DIR"' EXIT
        z2r_media_prepare || return 1
    fi
    if [ "$Z2R_MEDIA_READY" != 1 ]; then
        IFS= read -r reason < "$Z2R_MEDIA_DIR/status" || reason=resolver_error
        printf '%bGooglevideo Media UNKNOWN: %s%b\n' "${yellow:-}" "$reason" "${plain:-}"
        return 1
    fi
    echo 'Googlevideo: реальная загрузка аудио/видео по TCP (QUIC не проверяется).'
    z2r_media_target '' both print
)

# Один план audio/video/middle для всех режимов.
z2r_media_check() {
    local strategy="${1:-}" item kind count middle row state reason
    local rc code bytes tcp tls ttfb total speed
    if [ "${Z2R_MEDIA_READY:-0}" != 1 ]; then
        printf 'UNKNOWN|resolver_unavailable|0|000|0|0|0|0|0|0\n'; return 0
    fi
    for item in "audio:${Z2R_MEDIA_AUDIO_BYTES:-262144}:0" "video:${Z2R_MEDIA_VIDEO_BYTES:-1048576}:0" "video:${Z2R_MEDIA_VERIFY_BYTES:-2097152}:1"; do
        kind=${item%%:*}; item=${item#*:}; count=${item%%:*}; middle=${item#*:}
        row=$(z2r_media_probe "$Z2R_MEDIA_DIR" "$kind" "$count" "$middle" "${Z2R_SUPERSWEEP_ISOLATED:-0}") || row='UNKNOWN|probe_error|0|000|0|0|0|0|0|0'
        if [ -n "${Z2R_SUPERSWEEP_DIR:-}" ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$strategy" "$kind" "$middle" "$row" "${Z2R_MEDIA_TLS_VERSION:-auto}" >> "$Z2R_SUPERSWEEP_DIR/media.tsv"
        fi
        IFS='|' read -r state reason rc code bytes tcp tls ttfb total speed <<EOF
$row
EOF
        [ "$state" = OK ] || break
    done
    printf '%s\n' "$row"
}

# Старый формат TLS-метрик, но каждый успех подтверждён медиаданными, не корнем CDN.
z2r_media_target() {
    local strategy="$1" pref="${2:-both}" output_mode="${3:-}" version row state reason rc code bytes tcp tls ttfb total speed color
    local v12 v13 r12 r13 s12 s13 selected token label
    for version in 12 13; do
        if [ "${Z2R_SUPERSWEEP_ISOLATED:-0}" = 1 ]; then
            row=$(Z2R_MEDIA_TLS_VERSION=$version _supersweep_check_target "$strategy" z2r_media_check) || return 1
        else
            row=$(Z2R_MEDIA_TLS_VERSION=$version z2r_media_check "$strategy") || return 1
        fi
        IFS='|' read -r state reason rc code bytes tcp tls ttfb total speed <<EOF
$row
EOF
        if [ "$output_mode" = print ]; then
            case "$state" in OK) color=${green:-} ;; FAIL) color=${red:-} ;; *) color=${yellow:-} ;; esac
            printf '%bTLS 1.%s: %s; HTTP %s, %s байт, %s с (%s)%b\n' "$color" "${version#1}" "$state" "$code" "$bytes" "$total" "$reason" "${plain:-}"
        fi
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
    if [ "$output_mode" = print ]; then
        case "$token" in ok) color=${green:-} ;; fail) color=${red:-} ;; *) color=${yellow:-} ;; esac
        printf '%bMedia %s: %s; %s байт за %s с%b\n' "$color" "$label" "$reason" "$bytes" "$total" "${plain:-}"
    else
        printf '%s\n%s\n%s\n%s\n' "$v12" "$v13" "$rc|$code|$bytes|$total" \
            "$token|Media $label: $reason; $bytes байт за $total с"
    fi
}

# OK/FAIL/UNKNOWN | reason | curl_rc | HTTP | bytes | TCP | TLS | TTFB | total | B/s.
# Для SuperSweep require_queue=1; standalone PoC проверяет только медиаресурс.
z2r_media_probe() (
    trap - EXIT
    umask 077
    local dir="$1" kind="$2" count="$3" middle="$4" require_queue="${5:-0}"
    local length mime host expire offset end row rc pid before after state reason headers
    local code bytes tcp tls ttfb total speed location url_override="${6:-}" redirects="${7:-2}" config="$dir/$kind.curl"
    case "$kind" in audio|video) ;; *) return 1 ;; esac
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    [ "$count" -ge 4096 ] && [ "$count" -le 4194304 ] || return 1
    IFS='|' read -r length mime host expire < "$dir/$kind.params" || return 1
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
        config="$dir/curl.conf"
        printf 'url = "%s"\n' "$url_override" > "$config" || return 1
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
        --config "$config" -A "$(z2r_media_ua)" "$@" \
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
