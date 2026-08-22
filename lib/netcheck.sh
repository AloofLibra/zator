# Network / access checks

# Цвета (определяются глобально в z2r.sh; fallback для автономного запуска)
[ -z "${plain:-}" ] && plain='\033[0m'
[ -z "${red:-}" ] && red='\033[0;31m'
[ -z "${green:-}" ] && green='\033[0;32m'
[ -z "${yellow:-}" ] && yellow='\033[0;33m'
[ -z "${Z2R_CURL_UA:-}" ] && Z2R_CURL_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'

get_yt_cluster_domain() {
    local letters_map_a="u z p k f a 5 0 v q l g b 6 1 w r m h c 7 2 x s n i d 8 3 y t o j e 9 4 -"
    local letters_map_b="0 1 2 3 4 5 6 7 8 9 a b c d e f g h i j k l m n o p q r s t u v w x y z -"
    
    cluster_codename=$(curl -s -A "$Z2R_CURL_UA" --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no"| sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')
	#Второй раз для пробития нерелевантного ответа
    cluster_codename=$(curl -s -A "$Z2R_CURL_UA" --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no"| sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')
    
    [ -z "$cluster_codename" ] && {
        echo "Не удалось получить cluster_codename. Используем тогда rr1---sn-5goeenes.googlevideo.com" >&2
        echo "rr1---sn-5goeenes.googlevideo.com"
        return
    }
    
    local converted_name=""
    local i=0
    while [ $i -lt ${#cluster_codename} ]; do
        char=$(echo "$cluster_codename" | cut -c$((i+1)))
        idx=1
        for a in $letters_map_a; do
            [ "$a" = "$char" ] && break
            idx=$((idx+1))
        done
        b=$(echo "$letters_map_b" | cut -d' ' -f $idx)
        converted_name="${converted_name}${b}"
        i=$((i+1))
    done
    
    echo "rr1---sn-${converted_name}.googlevideo.com"
}

Z2R_TLS_CONNECT_TIMEOUT=4
Z2R_TLS_MAX_TIME=8
Z2R_TLS_DL_RANGE=65536
Z2R_TLS_DL_MIN_OK=32768
Z2R_TLS_DL_MAX_TIME=12

# Функции движка всегда возвращают 0 (вызовы под set -e в z2r.sh):
# код возврата curl передаётся внутри данных, а не статусом функции.

z2r_tls_head_once() {
    local url="$1" hdr="$2"; shift 2
    local out rc
    rc=0
    out="$(curl -4 -s -L -k -I -o /dev/null -A "$Z2R_CURL_UA" \
        --connect-timeout "$Z2R_TLS_CONNECT_TIMEOUT" --max-time "$Z2R_TLS_MAX_TIME" \
        -D "$hdr" -w '%{time_total} %{remote_ip}' \
        "$@" "$url" 2>/dev/null)" || rc=$?
    printf '%s|%s\n' "$rc" "${out:-- -}"
}

z2r_tls_probe_version() {
    local url="$1" ver="$2" flags hdr raw rc rest time ip first proto code
    case "$ver" in
        12) flags="--tlsv1.2 --tls-max 1.2" ;;
        13) flags="--tlsv1.3" ;;
        *) return 1 ;;
    esac
    hdr="$(mktemp "${TMPDIR:-/tmp}/z2r_tls.XXXXXX")" || return 1
    : >"$hdr"
    raw="$(z2r_tls_head_once "$url" "$hdr" $flags)"
    rc="${raw%%|*}"; rest="${raw#*|}"
    case "$rest" in
        *' '*) time="${rest%% *}"; ip="${rest##* }" ;;
        *) time="-"; ip="-" ;;
    esac
    first="$(grep '^HTTP/' "$hdr" 2>/dev/null | tail -n 1 | tr -d '\r')"
    proto="${first%% *}"; code="${first#* }"; code="${code%% *}"
    [ -n "$proto" ] || proto="-"
    case "$code" in ''|*[!0-9]*) code=000 ;; esac
    rm -f "$hdr"
    printf '%s|%s|%s|%s|%s\n' "$rc" "$code" "$proto" "$time" "$ip"
}

z2r_tls_probe_download() {
    local url="$1" out rc code rest size time
    rc=0
    out="$(curl -4 -s -L -k -o /dev/null -A "$Z2R_CURL_UA" \
        --connect-timeout "$Z2R_TLS_CONNECT_TIMEOUT" --max-time "$Z2R_TLS_DL_MAX_TIME" \
        -H "Range: bytes=0-$((Z2R_TLS_DL_RANGE - 1))" \
        -w '%{http_code} %{size_download} %{time_total}' \
        "$url" 2>/dev/null)" || rc=$?
    code="${out%% *}"; rest="${out#* }"; size="${rest%% *}"; time="${rest##* }"
    case "$out" in *' '*) ;; *) size=""; time="" ;; esac
    case "$code" in ''|*[!0-9]*) code=000 ;; esac
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    [ -n "$time" ] || time="-"
    printf '%s|%s|%s|%s\n' "$rc" "$code" "$size" "$time"
}

z2r_tls_field() {
    printf '%s\n' "$1" | cut -d'|' -f"$2"
}

z2r_tls_code_ok() {
    case "$1" in
        2??|3??) return 0 ;;
        *) return 1 ;;
    esac
}

z2r_tls_version_state() {
    local rc="$1" code="$2"
    if [ "$code" != "000" ]; then
        if z2r_tls_code_ok "$code"; then echo ok; else echo http; fi
        return
    fi
    case "$rc" in
        6) echo dns ;;
        28) echo timeout ;;
        7) echo conn ;;
        4) echo unsupported ;;
        35|16|53|54|56|60|77) echo tls ;;
        *) echo none ;;
    esac
}

z2r_tls_download_state() {
    local rc="$1" code="$2" size="$3"
    if [ "$rc" -eq 0 ]; then
        if [ "$code" = "206" ]; then
            if [ "$size" -ge "$Z2R_TLS_DL_MIN_OK" ]; then echo ok; else echo partial; fi
        elif z2r_tls_code_ok "$code"; then
            if [ "$size" -gt 0 ]; then echo ok; else echo zero; fi
        else
            echo zero
        fi
    else
        echo fail
    fi
}

z2r_tls_check_target() {
    local url="$1" tmp v12 v13 dl
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/z2r_tls.XXXXXX")" || return 1
    z2r_tls_probe_version "$url" 12 >"$tmp/v12" &
    z2r_tls_probe_version "$url" 13 >"$tmp/v13" &
    wait
    v12="$(cat "$tmp/v12" 2>/dev/null)" || v12=""
    v13="$(cat "$tmp/v13" 2>/dev/null)" || v13=""
    [ -n "$v12" ] || v12="1|000|-|-|-"
    [ -n "$v13" ] || v13="1|000|-|-|-"
    dl="skip"
    if z2r_tls_code_ok "$(z2r_tls_field "$v12" 2)" || z2r_tls_code_ok "$(z2r_tls_field "$v13" 2)"; then
        dl="$(z2r_tls_probe_download "$url")"
    fi
    rm -rf "$tmp"
    printf '%s\n%s\n%s\n' "$v12" "$v13" "$dl"
}

# Версия строки проверки: "факт|подсказка". Подсказка пустая только при успехе;
# в CLI факт красится жёлтым/зелёным, подсказка — красным (как в эталонном выводе).
z2r_tls_version_parts() {
    local ver="$1" raw="$2"
    local rc code proto time state why fact hint
    rc="$(z2r_tls_field "$raw" 1)"; code="$(z2r_tls_field "$raw" 2)"
    proto="$(z2r_tls_field "$raw" 3)"; time="$(z2r_tls_field "$raw" 4)"
    state="$(z2r_tls_version_state "$rc" "$code")"
    if [ "$ver" = "1.2" ]; then
        why="важно для ТВ и т.п."
    else
        why="важно в основном для всего современного"
    fi
    hint="Проверьте доступность вручную. Возможно ошибка теста."
    case "$state" in
        ok|http) fact="Есть ответ по TLS $ver ($why): $proto $code за $time с"; hint="" ;;
        dns) fact="Нет ответа по TLS $ver ($why) Домен не разрешается (DNS)." ;;
        timeout) fact="Нет ответа по TLS $ver ($why) Таймаут ${Z2R_TLS_MAX_TIME}сек." ;;
        tls) fact="Нет ответа по TLS $ver ($why) Ошибка TLS-рукопожатия." ;;
        conn) fact="Нет ответа по TLS $ver ($why) Соединение не устанавливается." ;;
        unsupported) fact="Нет ответа по TLS $ver ($why) Локальный curl не поддерживает эту версию TLS." ;;
        *) fact="Нет ответа по TLS $ver ($why) curl rc=$rc." ;;
    esac
    printf '%s|%s\n' "$fact" "$hint"
}

z2r_tls_version_text() {
    local parts fact hint
    parts="$(z2r_tls_version_parts "$1" "$2")"
    fact="${parts%%|*}"; hint="${parts#*|}"
    if [ -n "$hint" ]; then
        printf '%s %s\n' "$fact" "$hint"
    else
        printf '%s\n' "$fact"
    fi
}

z2r_tls_download_parts() {
    local raw="$1" rc code size time state fact hint
    if [ "$raw" = "skip" ]; then
        printf '|\n'
        return
    fi
    rc="$(z2r_tls_field "$raw" 1)"; code="$(z2r_tls_field "$raw" 2)"
    size="$(z2r_tls_field "$raw" 3)"; time="$(z2r_tls_field "$raw" 4)"
    state="$(z2r_tls_download_state "$rc" "$code" "$size")"
    hint="Проверьте доступность вручную. Возможно ошибка теста."
    case "$state" in
        ok) fact="Данные: получено $size байт за $time с (код $code)"; hint="" ;;
        partial) fact="Данные: получено только $size байт из $((Z2R_TLS_DL_RANGE / 1024))КБ — данных меньше ожидаемого." ;;
        zero)
            if [ "$code" != "000" ]; then
                fact="Данные: код $code, 0 байт — сервер не отдал тело ответа."
            else
                fact="Данные: 0 байт — TLS работает, но тело ответа не приходит."
            fi
            ;;
        fail) fact="Данные: скачать не удалось (curl rc=$rc)." ;;
    esac
    printf '%s|%s\n' "$fact" "$hint"
}

z2r_tls_download_text() {
    local parts fact hint
    parts="$(z2r_tls_download_parts "$1")"
    fact="${parts%%|*}"; hint="${parts#*|}"
    if [ -n "$hint" ]; then
        printf '%s %s\n' "$fact" "$hint"
    else
        printf '%s\n' "$fact"
    fi
}

z2r_tls_target_verdict() {
    local v12="$1" v13="$2" dl="$3"
    local rc12 code12 rc13 code13 s12 s13 t12 t13 best dlrc dlcode dlsize dstate reason
    rc12="$(z2r_tls_field "$v12" 1)"; code12="$(z2r_tls_field "$v12" 2)"
    rc13="$(z2r_tls_field "$v13" 1)"; code13="$(z2r_tls_field "$v13" 2)"
    s12="$(z2r_tls_version_state "$rc12" "$code12")"
    s13="$(z2r_tls_version_state "$rc13" "$code13")"
    case "$s12" in ok|http) t12=1 ;; *) t12=0 ;; esac
    case "$s13" in ok|http) t13=1 ;; *) t13=0 ;; esac
    if [ "$t12" -eq 0 ] && [ "$t13" -eq 0 ]; then
        if [ "$s12" = "dns" ] || [ "$s13" = "dns" ]; then
            reason="домен не разрешается системным DNS; браузер может работать через свой DoH"
        elif [ "$s12" = "tls" ] || [ "$s13" = "tls" ]; then
            reason="TLS-рукопожатие не проходит"
        elif [ "$s12" = "timeout" ] || [ "$s13" = "timeout" ]; then
            reason="нет ответа от сервера (таймаут)"
        else
            reason="соединение не устанавливается"
        fi
        printf 'fail|Нет ответа: %s. Стратегия, скорее всего, не работает. Проверьте доступность вручную. Возможно ошибка теста.' "$reason"
        return
    fi
    if ! z2r_tls_code_ok "$code12" && ! z2r_tls_code_ok "$code13"; then
        if [ "$t12" -eq 1 ]; then best="$code12"; else best="$code13"; fi
        printf 'ok|Доступ есть: TLS работает, сервер ответил кодом %s.' "$best"
        return
    fi
    if [ "$dl" != "skip" ]; then
        dlrc="$(z2r_tls_field "$dl" 1)"; dlcode="$(z2r_tls_field "$dl" 2)"; dlsize="$(z2r_tls_field "$dl" 3)"
        dstate="$(z2r_tls_download_state "$dlrc" "$dlcode" "$dlsize")"
        if [ "$dstate" = "zero" ] || [ "$dstate" = "fail" ]; then
            printf 'fail|TLS работает, но данные не приходят — страница не скачивается. Проверьте доступность вручную. Возможно ошибка теста.'
            return
        fi
        if [ "$dstate" = "partial" ]; then
            printf 'warn|Данные идут не полностью. Проверьте доступность вручную. Возможно ошибка теста.'
            return
        fi
    fi
    if [ "$t13" -eq 0 ]; then
        printf 'warn|Сайт отвечает только по TLS 1.2 — TLS 1.3 недоступен, современные браузеры могут не открыться. Проверьте вручную.'
        return
    fi
    printf 'ok|Сайт доступен: TLS работает, данные идут.'
}

check_access() {
    local TestURL="$1" out v12 v13 dl parts fact hint c12 c13 cd verdict vcolor
    out="$(z2r_tls_check_target "$TestURL")"
    v12="$(printf '%s\n' "$out" | sed -n 1p)"
    v13="$(printf '%s\n' "$out" | sed -n 2p)"
    dl="$(printf '%s\n' "$out" | sed -n 3p)"

    case "$(z2r_tls_version_state "$(z2r_tls_field "$v12" 1)" "$(z2r_tls_field "$v12" 2)")" in
        ok|http) c12="$green" ;;
        *) c12="$yellow" ;;
    esac
    parts="$(z2r_tls_version_parts 1.2 "$v12")"
    fact="${parts%%|*}"; hint="${parts#*|}"
    if [ -n "$hint" ]; then
        echo -e "${c12}${fact} ${red}${hint}${plain}"
    else
        echo -e "${c12}${fact}${plain}"
    fi

    case "$(z2r_tls_version_state "$(z2r_tls_field "$v13" 1)" "$(z2r_tls_field "$v13" 2)")" in
        ok|http) c13="$green" ;;
        *) c13="$yellow" ;;
    esac
    parts="$(z2r_tls_version_parts 1.3 "$v13")"
    fact="${parts%%|*}"; hint="${parts#*|}"
    if [ -n "$hint" ]; then
        echo -e "${c13}${fact} ${red}${hint}${plain}"
    else
        echo -e "${c13}${fact}${plain}"
    fi

    if [ "$dl" != "skip" ]; then
        case "$(z2r_tls_download_state "$(z2r_tls_field "$dl" 1)" "$(z2r_tls_field "$dl" 2)" "$(z2r_tls_field "$dl" 3)")" in
            ok) cd="$green" ;;
            *) cd="$yellow" ;;
        esac
        parts="$(z2r_tls_download_parts "$dl")"
        fact="${parts%%|*}"; hint="${parts#*|}"
        if [ -n "$hint" ]; then
            echo -e "${cd}${fact} ${red}${hint}${plain}"
        else
            echo -e "${cd}${fact}${plain}"
        fi
    fi

    verdict="$(z2r_tls_target_verdict "$v12" "$v13" "$dl")"
    case "${verdict%%|*}" in
        ok) vcolor="$green" ;;
        warn) vcolor="$yellow" ;;
        *) vcolor="$red" ;;
    esac
    echo -e "${vcolor}Итог: ${verdict#*|}${plain}"
}


check_dns() {
    local DOMAIN="${1:-rutracker.org}"
    local DOH_RAW DOH_IPS NS_RAW NS_IPS MATCH_IPS MATCH_COUNT DOH_COUNT NS_COUNT ip


    echo "================================================"
    echo " Анализ DNS для домена: $DOMAIN"
    echo "================================================"

    DOH_RAW=$(curl -s -A "$Z2R_CURL_UA" --max-time 5 "https://dns.google/resolve?name=${DOMAIN}&type=A")

    if [ -z "$DOH_RAW" ]; then
        echo -e "${red}[-] Ошибка: Google DoH недоступен${plain}"
        return 1
    fi

    DOH_IPS=$(
        echo "$DOH_RAW" \
        | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | sort -u
    )

    if [ -z "$DOH_IPS" ]; then
        echo -e "${red}[-] Ошибка: Google DoH не вернул IPv4 адреса${plain}"
        return 1
    fi

    echo -e "${yellow}-> Эталонные IP от DoH:${plain}"
    for ip in $DOH_IPS; do
        echo "  $ip"
    done

    echo "----------------------------------------"

    NS_RAW=$(nslookup "$DOMAIN" 2>/dev/null)

    if [ -z "$NS_RAW" ]; then
        echo -e "${red}[-] Ошибка: nslookup не смог разрешить домен${plain}"
        return 1
    fi

    NS_IPS=$(
        echo "$NS_RAW" \
        | awk '
            /^Name:[[:space:]]/ { in_answer=1; next }
            in_answer && /^Address([[:space:]][0-9]+)?:/ { print }
        ' \
        | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | sort -u
    )

    echo -e "${yellow}-> Полученные IP от nslookup:${plain}"

    if [ -z "$NS_IPS" ]; then
        echo "  Пустой ответ"
    else
        for ip in $NS_IPS; do
            echo "  $ip"
        done
    fi

    echo "================================================"

    if [ -z "$NS_IPS" ]; then
        echo -e "${red} ВНИМАНИЕ: DNS не вернул ни одного IPv4 адреса${plain}"
        echo "================================================"
        return 2
    fi

    if echo "$NS_IPS" | grep -Eq '^(127\.0\.0\.1|0\.0\.0\.0)$'; then
        echo -e "${red} ВНИМАНИЕ: ОБНАРУЖЕНА ЯВНАЯ DNS-ПОДМЕНА${plain}"
        echo " DNS вернул адрес блокировки: $NS_IPS"
        echo "================================================"
        return 2
    fi

    MATCH_IPS=""
    MATCH_COUNT=0

    for ip in $NS_IPS; do
        if echo "$DOH_IPS" | grep -Fxq "$ip"; then
            MATCH_IPS="$MATCH_IPS $ip"
            MATCH_COUNT=$((MATCH_COUNT + 1))
        fi
    done

    DOH_COUNT=$(echo "$DOH_IPS" | wc -w | tr -d ' ')
    NS_COUNT=$(echo "$NS_IPS" | wc -w | tr -d ' ')

    if [ "$MATCH_COUNT" -eq "$DOH_COUNT" ] && [ "$DOH_COUNT" -eq "$NS_COUNT" ]; then

        echo -e "${green} ВЕРДИКТ: ВСЁ ЧИСТО${plain}"
        echo " IP из локального DNS полностью совпадают с DoH."
        echo " Явной подмены DNS не обнаружено."
        echo "================================================"
        return 0

    fi

    if [ "$MATCH_COUNT" -gt 0 ]; then

        echo -e "${green} ВЕРДИКТ: DNS РАБОТАЕТ КОРРЕКТНО${plain}"
        echo " Найдены совпадающие IP:"
        echo "$MATCH_IPS" | tr ' ' '\n' | grep -v "^$" | sed 's/^/  /'
        echo ""
        echo " Ответы отличаются частично."
        echo " Для Cloudflare/CDN это является нормальным поведением."
        echo " Признаков DNS-подмены не обнаружено."
        echo "================================================"
        return 0

    fi

    echo -e "${red} ВНИМАНИЕ: ВОЗМОЖНА DNS-ПОДМЕНА${plain}"
    echo " Совпадающих IP между DoH и локальным DNS не найдено."
    echo ""
    echo " Возможные причины:"
    echo " - DNS фильтрация провайдера"
    echo " - Подмена DNS"
    echo " - Некорректная работа DNS сервера"
    echo "================================================"

    return 2
}

check_access_list() {
   if ! check_dns "rutracker.org"; then
      echo -e "${yellow}DNS-проверка завершилась предупреждением, продолжаю остальные тесты.${plain}"
   fi

   echo "Проверка доступности youtube.com (YT TCP)"
   check_access "https://www.youtube.com/"
   echo "Проверка доступности $(get_yt_cluster_domain) (YT TCP)"
   check_access "https://$(get_yt_cluster_domain)"
   echo "Проверка доступности meduza.io (RKN list)"
   check_access "https://meduza.io"
   echo "Проверка доступности www.instagram.com (RKN list + нужен рабочий DNS)"
   check_access "https://www.instagram.com/"

}
