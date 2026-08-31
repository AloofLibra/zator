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

    cluster_codename=$(curl -4 -s -k -A "$Z2R_CURL_UA" --max-time 4 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no"| sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')
	#Второй раз для пробития нерелевантного ответа
    cluster_codename=$(curl -4 -s -k -A "$Z2R_CURL_UA" --max-time 4 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no"| sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')
    
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

Z2R_TLS_CONNECT_TIMEOUT=3
Z2R_TLS_MAX_TIME=5
Z2R_TLS_DL_RANGE=65536
Z2R_TLS_DL_MAX_TIME=10
Z2R_TLS_DL_SPEED_LIMIT=2048
Z2R_TLS_DL_SPEED_TIME=1

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
        --speed-limit "$Z2R_TLS_DL_SPEED_LIMIT" --speed-time "$Z2R_TLS_DL_SPEED_TIME" \
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
        X) echo aborted ;;
        6) echo dns ;;
        28) echo timeout ;;
        7) echo conn ;;
        4) echo unsupported ;;
        35|16|53|54|56|60|77) echo tls ;;
        *) echo none ;;
    esac
}

# 206/2xx/3xx + rc=0 и любые байты > 0 — тело дошло целиком (страница может
# быть просто меньше запрошенных 64КБ). Обрыв ("cut") — только когда байты
# пошли, но curl закончился ошибкой.
z2r_tls_download_state() {
    local rc="$1" code="$2" size="$3"
    if [ "$code" = "206" ] || z2r_tls_code_ok "$code"; then
        if [ "$size" -gt 0 ]; then
            if [ "$rc" -eq 0 ]; then echo ok; else echo cut; fi
        else
            echo zero
        fi
    else
        if [ "$rc" -eq 0 ]; then echo zero; else echo fail; fi
    fi
}

z2r_tls_poll_sleep() {
    sleep 0.3 2>/dev/null || sleep 1
}

z2r_tls_check_target() {
    local url="$1" tmp v12 v13 dl dl1 dl2 dstate p12 p13 peek t0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/z2r_tls.XXXXXX")" || return 1
    z2r_tls_probe_version "$url" 12 >"$tmp/v12" 2>/dev/null </dev/null &
    p12=$!
    z2r_tls_probe_version "$url" 13 >"$tmp/v13" 2>/dev/null </dev/null &
    p13=$!

    t0=$SECONDS
    while [ $((SECONDS - t0)) -lt $((Z2R_TLS_MAX_TIME + 2)) ]; do
        z2r_tls_poll_sleep
        if [ -s "$tmp/v12" ] && [ -s "$tmp/v13" ]; then
            break
        fi
        # Z2R_TLS_WAIT_BOTH=1 (автопрогон): не добиваем вторую пробу — нужен
        # честный статус каждой версии TLS, а не только факт прохода.
        if [ -z "${Z2R_TLS_WAIT_BOTH:-}" ]; then
            if [ -s "$tmp/v12" ] && [ ! -s "$tmp/v13" ]; then
                peek="$(cat "$tmp/v12" 2>/dev/null)" || peek=""
                if z2r_tls_code_ok "$(z2r_tls_field "$peek" 2)"; then
                    kill "$p13" 2>/dev/null || true
                    wait "$p13" 2>/dev/null || true
                    break
                fi
            elif [ -s "$tmp/v13" ] && [ ! -s "$tmp/v12" ]; then
                peek="$(cat "$tmp/v13" 2>/dev/null)" || peek=""
                if z2r_tls_code_ok "$(z2r_tls_field "$peek" 2)"; then
                    kill "$p12" 2>/dev/null || true
                    wait "$p12" 2>/dev/null || true
                    break
                fi
            fi
        fi
    done
    wait
    v12="$(cat "$tmp/v12" 2>/dev/null)" || v12=""
    v13="$(cat "$tmp/v13" 2>/dev/null)" || v13=""
    # Пустой файл = проба добита досрочно (вторая версия уже ответила)
    # или упала — помечаем "aborted", а не ложным таймаутом 28.
    [ -n "$v12" ] || v12="X|000|-|-|-"
    [ -n "$v13" ] || v13="X|000|-|-|-"
    dl="skip"
    if z2r_tls_code_ok "$(z2r_tls_field "$v12" 2)" || z2r_tls_code_ok "$(z2r_tls_field "$v13" 2)"; then
        z2r_tls_probe_download "$url" >"$tmp/d1" 2>/dev/null </dev/null &
        z2r_tls_probe_download "$url" >"$tmp/d2" 2>/dev/null </dev/null &
        wait
        dl1="$(cat "$tmp/d1" 2>/dev/null)" || dl1=""
        dl2="$(cat "$tmp/d2" 2>/dev/null)" || dl2=""
        [ -n "$dl1" ] || dl1="28|000|0|-"
        [ -n "$dl2" ] || dl2="28|000|0|-"
        dl="$dl1"
        if [ "$(z2r_tls_download_state "$(z2r_tls_field "$dl1" 1)" "$(z2r_tls_field "$dl1" 2)" "$(z2r_tls_field "$dl1" 3)")" != "ok" ] \
            && [ "$(z2r_tls_download_state "$(z2r_tls_field "$dl2" 1)" "$(z2r_tls_field "$dl2" 2)" "$(z2r_tls_field "$dl2" 3)")" = "ok" ]; then
            dl="$(printf '%s|%s|%s|%s|retry' \
                "$(z2r_tls_field "$dl2" 1)" "$(z2r_tls_field "$dl2" 2)" \
                "$(z2r_tls_field "$dl2" 3)" "$(z2r_tls_field "$dl2" 4)")"
        fi
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
        aborted) fact="Проверка остановлена: сайт уже ответил по другой версии TLS"; hint="" ;;
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
        ok)
            fact="Данные: получено $size байт за $time с (код $code)"
            if [ "$(z2r_tls_field "$raw" 5)" = "retry" ]; then
                fact="Данные: получено $size байт за $time с (код $code) — со второй попытки, первая оборвалась"
            fi
            hint=""
            ;;
        cut) fact="Данные оборвались: получено $size байт и поток остановился." ;;
        zero)
            if [ "$code" != "000" ]; then
                fact="Данные: код $code, 0 байт — сервер не отдал тело ответа."
            else
                fact="Данные: 0 байт — TLS работает, но тело ответа не приходит."
            fi
            ;;
        fail)
            if [ "$rc" = "28" ]; then
                fact="Данные: таймаут — тело ответа не начало приходать за ${Z2R_TLS_DL_MAX_TIME} сек."
            else
                fact="Данные: скачать не удалось (curl rc=$rc)."
            fi
            ;;
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
        if [ "$dstate" = "cut" ]; then
            printf 'fail|TLS работает, но поток данных срезается после %s байт - похоже на блокировку «16кб». Проверьте доступность вручную. Возможно ошибка теста.' "$dlsize"
            return
        fi
        if [ "$dstate" = "zero" ] || [ "$dstate" = "fail" ]; then
            printf 'fail|TLS работает, но данные не приходят — страница не скачивается. Проверьте доступность вручную. Возможно ошибка теста.'
            return
        fi
        if [ "$(z2r_tls_field "$dl" 5)" = "retry" ]; then
            printf 'warn|Поток иногда срезается — повторное соединение прошло, страница может открываться не с первого раза. Проверьте доступность вручную.'
            return
        fi
    fi
    if [ "$t13" -eq 0 ]; then
        printf 'warn|Сайт отвечает только по TLS 1.2 — TLS 1.3 недоступен, современные браузеры могут не открыться. Проверьте вручную.'
        return
    fi
    printf 'ok|Сайт доступен: TLS работает, данные идут.'
}

# Компактный результат одной стратегии для таблицы автопрогона:
# печатает "verdict|короткий текст" (цвета накладывает вызывающий).
# $4 tls_pref (any|12|13|both, по умолчанию any — старое поведение):
# при 12/13/both зелёным считается только прохождение выбранных версий
# TLS (докачка по-прежнему обязательна), иначе жёлтая с пояснением.
z2r_tls_short_result() {
    local v12="$1" v13="$2" dl="$3" pref="${4:-any}"
    local rc12 code12 rc13 code13 s12 s13 t12 t13 q12 q13 best
    local dlrc dlcode dlsize dltime dstate short
    rc12="$(z2r_tls_field "$v12" 1)"; code12="$(z2r_tls_field "$v12" 2)"
    rc13="$(z2r_tls_field "$v13" 1)"; code13="$(z2r_tls_field "$v13" 2)"
    s12="$(z2r_tls_version_state "$rc12" "$code12")"
    s13="$(z2r_tls_version_state "$rc13" "$code13")"
    case "$s12" in ok|http) t12=1 ;; *) t12=0 ;; esac
    case "$s13" in ok|http) t13=1 ;; *) t13=0 ;; esac
    q12=0; q13=0
    if z2r_tls_code_ok "$code12"; then q12=1; fi
    if z2r_tls_code_ok "$code13"; then q13=1; fi
    short=""
    if [ "$t12" -eq 0 ] && [ "$t13" -eq 0 ]; then
        if [ "$s12" = "dns" ] || [ "$s13" = "dns" ]; then
            short="нет ответа (DNS)"
        elif [ "$s12" = "tls" ] || [ "$s13" = "tls" ]; then
            short="TLS-рукопожатие не проходит"
        elif [ "$s12" = "timeout" ] || [ "$s13" = "timeout" ]; then
            short="нет ответа (таймаут)"
        else
            short="нет ответа"
        fi
        printf 'fail|%s\n' "$short"
        return
    fi
    if [ "$q12" -eq 0 ] && [ "$q13" -eq 0 ]; then
        if [ "$t12" -eq 1 ]; then best="$code12"; else best="$code13"; fi
        case "$pref" in
            both)
                if [ "$t12" -eq 1 ] && [ "$t13" -eq 1 ]; then
                    printf 'ok|сервер ответил кодом %s (обе версии)\n' "$best"
                elif [ "$t12" -eq 1 ]; then
                    printf 'warn|работает только TLS 1.2, код %s\n' "$best"
                else
                    printf 'warn|работает только TLS 1.3, код %s\n' "$best"
                fi
                ;;
            12)
                if [ "$t12" -eq 1 ]; then
                    printf 'ok|сервер ответил кодом %s\n' "$best"
                else
                    printf 'warn|работает только TLS 1.3, код %s\n' "$best"
                fi
                ;;
            13)
                if [ "$t13" -eq 1 ]; then
                    printf 'ok|сервер ответил кодом %s\n' "$best"
                else
                    printf 'warn|работает только TLS 1.2, код %s\n' "$best"
                fi
                ;;
            *)
                printf 'ok|сервер ответил кодом %s\n' "$best"
                ;;
        esac
        return
    fi
    if [ "$dl" != "skip" ]; then
        dlrc="$(z2r_tls_field "$dl" 1)"; dlcode="$(z2r_tls_field "$dl" 2)"
        dlsize="$(z2r_tls_field "$dl" 3)"; dltime="$(z2r_tls_field "$dl" 4)"
        dstate="$(z2r_tls_download_state "$dlrc" "$dlcode" "$dlsize")"
        case "$dstate" in
            cut) printf 'fail|срез после %s байт\n' "$dlsize"; return ;;
            zero) printf 'fail|тело не приходит\n'; return ;;
            fail) printf 'fail|докачка не началась\n'; return ;;
            ok)
                if [ "$(z2r_tls_field "$dl" 5)" = "retry" ]; then
                    printf 'warn|срез нестабильный, повтор прошёл\n'
                    return
                fi
                case "$pref" in
                    both)
                        if [ "$q12" -eq 1 ] && [ "$q13" -eq 1 ]; then
                            printf 'ok|данные %s байт за %s с\n' "$dlsize" "$dltime"
                        elif [ "$q12" -eq 1 ]; then
                            printf 'warn|работает только TLS 1.2, данные %s байт за %s с\n' "$dlsize" "$dltime"
                        else
                            printf 'warn|работает только TLS 1.3, данные %s байт за %s с\n' "$dlsize" "$dltime"
                        fi
                        ;;
                    12)
                        if [ "$q12" -eq 1 ]; then
                            printf 'ok|данные %s байт за %s с\n' "$dlsize" "$dltime"
                        else
                            printf 'warn|работает только TLS 1.3, данные %s байт за %s с\n' "$dlsize" "$dltime"
                        fi
                        ;;
                    13)
                        if [ "$q13" -eq 1 ]; then
                            printf 'ok|данные %s байт за %s с\n' "$dlsize" "$dltime"
                        else
                            printf 'warn|работает только TLS 1.2, данные %s байт за %s с\n' "$dlsize" "$dltime"
                        fi
                        ;;
                    *)
                        printf 'ok|данные %s байт за %s с\n' "$dlsize" "$dltime"
                        ;;
                esac
                return
                ;;
        esac
    fi
    if [ "$t13" -eq 0 ]; then
        printf 'warn|только TLS 1.2\n'
        return
    fi
    printf 'ok|данные идут\n'
}

# Статус одной версии TLS для таблицы автопрогона: "текст|состояние"
# (ok|http|fail|aborted — состояние выбирает цвет вызывающий).
# Для ответивших версий добавляем время ответа, как в выводе пункта 01.
z2r_tls_version_badge() {
    local label="$1" raw="$2" rc code state time int frac btime
    rc="$(z2r_tls_field "$raw" 1)"
    code="$(z2r_tls_field "$raw" 2)"
    state="$(z2r_tls_version_state "$rc" "$code")"
    btime=""
    time="$(z2r_tls_field "$raw" 4)"
    case "$time" in
        [0-9]*)
            int="${time%.*}"; frac="${time#*.}"
            [ "$frac" = "$time" ] && frac=""
            btime="${int}.${frac:0:1}с"
            ;;
    esac
    case "$state" in
        ok) printf '%s OK %s|ok\n' "$label" "$btime" ;;
        http) printf '%s %s %s|http\n' "$label" "$code" "$btime" ;;
        aborted) printf '%s -|aborted\n' "$label" ;;
        *) printf '%s FAIL|fail\n' "$label" ;;
    esac
}

# --- DNS-антиспуф (профиль 10): проверка резолва через nslookup/dig ---

# Эталонные адреса deb.torproject.org (CNAME static.torproject.org), сняты
# 2026-08-31 с настоящего ответа Google DNS. Набор у torproject ротируется:
# совпадение хотя бы одного адреса = ответ настоящий (ok); живые A-записи без
# совпадений = жёлтый (сверить вручную); пусто/NXDOMAIN = подмена или обрыв.
Z2R_DNS_KNOWN_ADDRS="204.8.99.144 204.8.99.146 95.216.163.36 116.202.120.165 116.202.120.166 2620:7:6002:0:466:39ff:fe7f:1826 2620:7:6002:0:466:39ff:fe32:e3dd 2a01:4f8:fff0:4f:266:37ff:feae:3bbc 2a01:4f8:fff0:4f:266:37ff:fe2c:5d19 2a01:4f9:c010:19eb::1"

Z2R_DNS_CHECK_DOMAIN="${Z2R_DNS_CHECK_DOMAIN:-deb.torproject.org}"
Z2R_DNS_CHECK_SERVER="${Z2R_DNS_CHECK_SERVER:-8.8.8.8}"
Z2R_DNS_TOOL="${Z2R_DNS_TOOL:-auto}"

z2r_dns_field() {
    printf '%s' "$1" | awk -F '|' -v f="$2" '{print $f}'
}

# Резолв-проба: dig (+short, тип A) при наличии, иначе nslookup (BusyBox).
z2r_dns_probe() {
    local domain="$1" server="$2"
    if [ "$Z2R_DNS_TOOL" = "nslookup" ] \
       || { [ "$Z2R_DNS_TOOL" = "auto" ] && ! command -v dig >/dev/null 2>&1; }; then
        nslookup "$domain" "$server" 2>&1
    else
        dig +short +time=2 +tries=1 "$domain" "@$server" 2>&1
    fi
}

# Адреса из вывода nslookup/dig: "v4 v4|v6 v6". Адрес резолвера исключается:
# первый Address в шапке nslookup — это сам сервер 8.8.8.8. BusyBox-совместимо
# (без grep-альтернаций и grep -o).
z2r_dns_parse_addrs() {
    awk -v srv="$1" '
        {
            gsub(/[,;()]/, " ")
            for (i = 1; i <= NF; i++) {
                t = $i
                sub(/#.*$/, "", t)
                sub(/:$/, "", t)
                if (t == "" || t == srv || seen[t]) continue
                ok4 = (t ~ /^[0-9][0-9.]*[0-9]$/)
                if (ok4) {
                    n = split(t, a, ".")
                    if (n != 4) ok4 = 0
                    for (j = 1; ok4 && j <= 4; j++)
                        if (a[j] !~ /^[0-9]+$/ || a[j] + 0 > 255) ok4 = 0
                }
                if (ok4) { seen[t] = 1; out4 = out4 " " t; continue }
                if (t ~ /:/ && t ~ /^[0-9A-Fa-f:]+$/) { seen[t] = 1; out6 = out6 " " t }
            }
        }
        END { sub(/^ /, "", out4); sub(/^ /, "", out6); printf "%s|%s\n", out4, out6 }
    '
}

# Проверка одной цели: строка "state|reason|v4|v6|hits".
# state: ok|warn|fail; reason: match|rotate|nxdomain|noanswer|empty.
z2r_dns_check_target() {
    local domain="${1:-$Z2R_DNS_CHECK_DOMAIN}" server="${2:-$Z2R_DNS_CHECK_SERVER}"
    local out rc parsed v4 v6 hits a k
    out="$(z2r_dns_probe "$domain" "$server")"; rc=$?
    parsed="$(printf '%s\n' "$out" | z2r_dns_parse_addrs "$server")"
    v4="${parsed%%|*}"
    v6="${parsed#*|}"

    if [ -n "$v4" ]; then
        hits=""
        for a in $v4 $v6; do
            for k in $Z2R_DNS_KNOWN_ADDRS; do
                [ "$a" = "$k" ] && hits="$hits $a"
            done
        done
        if [ -n "$hits" ]; then
            printf 'ok|match|%s|%s|%s\n' "$v4" "$v6" "${hits# }"
        else
            printf 'warn|rotate|%s|%s|\n' "$v4" "$v6"
        fi
        return 0
    fi

    case "$out" in
        *NXDOMAIN*|*"not found"*|*"can't find"*|*"Non-existent"*|*"no answer"*)
            printf 'fail|nxdomain||||\n'
            ;;
        *"timed out"*|*"timeout"*|*"no servers"*|*"refused"*|*"unreachable"*|*"SERVFAIL"*|*"connection"*|*"Failure"*)
            printf 'fail|noanswer||||\n'
            ;;
        *)
            if [ "$rc" -ne 0 ]; then
                printf 'fail|noanswer||||\n'
            else
                printf 'fail|empty||||\n'
            fi
            ;;
    esac
}

z2r_dns_text() {
    local res="$1"
    local state reason v4 v6 hits n4
    state="$(z2r_dns_field "$res" 1)"; reason="$(z2r_dns_field "$res" 2)"
    v4="$(z2r_dns_field "$res" 3)"; v6="$(z2r_dns_field "$res" 4)"
    hits="$(z2r_dns_field "$res" 5)"
    n4="$(printf '%s\n' "$v4" | wc -w)"; n4=$((n4 + 0))
    case "$state" in
        ok)
            printf 'Резолв настоящий: IPv4-адресов %s (%s), совпадение с эталоном torproject:%s\n' \
                "$n4" "$v4" "$hits"
            ;;
        warn)
            printf 'Резолв отвечает адресами (%s), но ни один не из эталонного набора torproject - возможно, набор сменился. Сверьте вручную: dig +tcp %s @%s\n' \
                "$v4" "$Z2R_DNS_CHECK_DOMAIN" "$Z2R_DNS_CHECK_SERVER"
            ;;
        fail)
            case "$reason" in
                nxdomain)
                    printf 'Подмена DNS: %s @ %s отвечает NXDOMAIN/без адресов\n' \
                        "$Z2R_DNS_CHECK_DOMAIN" "$Z2R_DNS_CHECK_SERVER"
                    ;;
                noanswer)
                    printf 'DNS не отвечает (%s @ %s: таймаут/отказ) - вероятно, дропается оригинал запроса\n' \
                        "$Z2R_DNS_CHECK_DOMAIN" "$Z2R_DNS_CHECK_SERVER"
                    ;;
                *)
                    printf 'Ответ DNS пришёл без IPv4-адресов (%s @ %s)\n' \
                        "$Z2R_DNS_CHECK_DOMAIN" "$Z2R_DNS_CHECK_SERVER"
                    ;;
            esac
            ;;
    esac
}

# CLI-вывод для перебора стратегий профиля 10 (цвета как у TLS-проверок).
z2r_dns_check_print() {
    local res state color
    res="$(z2r_dns_check_target "$@")"
    state="$(z2r_dns_field "$res" 1)"
    case "$state" in
        ok) color="$green" ;;
        warn) color="$yellow" ;;
        *) color="$red" ;;
    esac
    echo -e "${color}$(z2r_dns_text "$res")${plain}"
}

check_access() {
    local TestURL="$1" out v12 v13 dl parts fact hint c12 c13 cd verdict vcolor
    out="$(z2r_tls_check_target "$TestURL")"
    v12="$(printf '%s\n' "$out" | sed -n 1p)"
    v13="$(printf '%s\n' "$out" | sed -n 2p)"
    dl="$(printf '%s\n' "$out" | sed -n 3p)"

    case "$(z2r_tls_version_state "$(z2r_tls_field "$v12" 1)" "$(z2r_tls_field "$v12" 2)")" in
        ok|http) c12="$green" ;;
        aborted) c12="${plain}" ;;
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
        aborted) c13="${plain}" ;;
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
