telemetry_notify() {
    type send_stats >/dev/null 2>&1 && send_stats || true
}

orch_max_strategy_for_profile() {
    config_profile_max_strategy "$1"
}

profile_strategy_restart_notice() {
    if [ -n "${ZAPRET2_INIT:-}" ] && [ -x "$ZAPRET2_INIT" ]; then
        z2r_service_action restart
        echo -e "${green}zapret2 перезапущен для применения изменений config.${plain}"
    else
        echo -e "${yellow}Перезапустите zapret2, чтобы изменения config вступили в силу.${plain}"
    fi
}

profile_strategy_restart_if_needed() {
    if profile_config_voice_ports_changed "$1" "$2" "$3"; then
        profile_strategy_restart_notice
    fi
    return 0
}

orch_profile_try() {
    local profile="$1"
    local title="$2"
    local proto_list="$3"
    local test_url="$4"
    local max_strat=""
    local start_strat=""
    local current_strat=""
    local current_state=""
    local answer=""
    local cfg=""
    local old_udp_ports=""
    local first_proto="${proto_list%% *}"
    local -A prev_map

    max_strat="$(orch_max_strategy_for_profile "$profile")"
    if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
        echo "Не удалось определить число стратегий для профиля $profile."
        pause_enter
        return
    fi

    current_state="$(profile_state_display "$profile" "$first_proto")"
    current_strat="$current_state"
    if [ "$current_strat" = "auto" ] || [ "$current_strat" = "0" ] || [ -z "$current_strat" ]; then
        current_strat=1
    fi

    echo "$title"
    echo "Текущее состояние: ${current_state/auto/def}"
    local prompt_text="Введите номер стратегии 1-${max_strat} (0 - отключить профиль"
    if printf '%s' "$test_url" | grep -q '^https://'; then
        prompt_text="${prompt_text}, A - автопрогон"
    fi
    read -re -p "${prompt_text}, Enter - без изменений): " start_strat
    case "$start_strat" in
        a|A|а|А)
            if printf '%s' "$test_url" | grep -q '^https://'; then
                orch_run_auto_sweep "profile" "$profile" "$proto_list" "$test_url" 1 "$max_strat"
            fi
            return
            ;;
    esac
    if [ -z "$start_strat" ]; then
        echo "Без изменений."
        return
    fi
    if [ "$start_strat" = "0" ]; then
        cfg="$(get_config_file)"
        old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
        if profile_state_set_and_apply "$profile" "$proto_list" "0" "$cfg"; then
            echo "Профиль $profile выключен и сохранён как 0."
            profile_strategy_restart_if_needed "$profile" "$cfg" "$old_udp_ports"
        else
            echo -e "${red}Не удалось выключить профиль $profile.${plain}"
        fi
        telemetry_notify
        pause_enter
        return
    fi
    if ! ui_is_number_in_range "$start_strat" 1 "$max_strat"; then
        echo "Неверный номер стратегии или вне диапазона. Начинаем с 1."
        start_strat=1
    fi

    for p in $proto_list; do
        prev_map["$p"]="$(orch_locked_get "$profile" "$p")"
        [ "$current_state" = "0" ] && prev_map["$p"]="0"
    done

    for ((s=start_strat; s<=max_strat; s++)); do
        for p in $proto_list; do
            orch_locked_set "$profile" "$p" "$s"
        done
        echo "Стратегия $s применена."
        if [ "$test_url" = "__RUN_CDN_TEST__" ]; then
            echo "Проверка доступа: CDN test (как в пункте 001)"
            if type run_cdn_test >/dev/null 2>&1; then
                run_cdn_test
            else
                echo "run_cdn_test недоступен, пропускаем проверку."
            fi
        elif printf "%s" "$test_url" | grep -q '^http://'; then
            echo "Проверка HTTP-доступа: $test_url"
            if curl -L -k -A "$Z2R_CURL_UA" --connect-timeout 4 --max-time 8 -s -o /dev/null "$test_url"; then
                echo -e "${green}Есть ответ по HTTP.${plain}"
            else
                echo -e "${yellow}Нет ответа по HTTP. ${red}Проверьте доступность вручную. Возможно ошибка теста.${plain}"
            fi
        elif [ -n "$test_url" ]; then
            echo "Проверка доступа: $test_url"
            check_access "$test_url"
        fi

        read -re -p "1 - сохранить, 0 - отмена, Enter - далее: " answer
        if [ "$answer" = "1" ]; then
            cfg="$(get_config_file)"
            old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
            if profile_state_set_and_apply "$profile" "$proto_list" "$s" "$cfg"; then
                echo "Стратегия $s сохранена для профиля $profile."
                profile_strategy_restart_if_needed "$profile" "$cfg" "$old_udp_ports"
            else
                echo -e "${red}Не удалось сохранить стратегию $s для профиля $profile.${plain}"
            fi
            telemetry_notify
            pause_enter
            return
        elif [ "$answer" = "0" ]; then
            break
        fi
    done

    for p in $proto_list; do
        if [ -n "${prev_map[$p]}" ] && [ "${prev_map[$p]}" -gt 0 ]; then
            orch_locked_set "$profile" "$p" "${prev_map[$p]}"
        elif [ "${prev_map[$p]}" = "0" ]; then
            orch_locked_set "$profile" "$p" 0
        else
            orch_locked_clear "$profile" "$p"
        fi
    done
    echo "Изменения отменены."
    pause_enter
}

# Запрос добавки к паузе между стратегиями автопрогона: базовая пауза нужна,
# чтобы частыми переключениями не словить блок ТСПУ. Enter/неверный ввод = 0,
# 0 = отмена (пустой вывод). Все пояснения — в stderr: stdout функции
# захватывает вызывающий код, там должна быть только цифра.
orch_ask_sweep_extra_delay() {
    local extra
    echo "Пауза между стратегиями снижает риск блока ТСПУ: больше пауза — дольше прогон, но безопаснее." >&2
    read -re -p "Добавить секунд к базовой паузе 3 сек (Enter - без добавки, 0 - отмена): " extra
    if [ "$extra" = "0" ]; then
        return 0
    fi
    if [ -n "$extra" ]; then
        case "$extra" in
            *[!0-9]*)
                echo -e "${yellow}Неверный ввод, будет базовая пауза 3 сек.${plain}" >&2
                extra=0
                ;;
        esac
    fi
    echo "${extra:-0}"
}

# Запрос требуемых версий TLS для автопрогона: 12|13|both (Enter - both).
# 0 = отмена (пустой вывод).
orch_ask_sweep_tls_pref() {
    local pref
    echo "TLS 1.2 важен для ТВ и старых устройств, TLS 1.3 — для современных браузеров." >&2
    read -re -p "Какой TLS должен работать: 1 - TLS 1.2, 2 - TLS 1.3, 3 - обе (Enter - 3, 0 - отмена): " pref
    case "$pref" in
        0) ;;
        1) echo "12" ;;
        2) echo "13" ;;
        ''|3) echo "both" ;;
        *)
            echo -e "${yellow}Неверный ввод, требуются обе версии.${plain}" >&2
            echo "both"
            ;;
    esac
    return 0
}

# Диалог автопрогона (режим → требуемый TLS → добавка к паузе) и запуск.
# 0 на любом вопросе = отмена.
orch_run_auto_sweep() {
    local kind="$1" key="$2" proto_list="$3" test_url="$4" start="$5" max="$6"
    local mode tls_pref extra_pause
    read -re -p "Режим: 1 - до первого успеха, 2 - полный прогон (Enter - 2, 0 - отмена): " mode
    if [ "$mode" = "0" ]; then
        echo "Отмена."
        pause_enter
        return 0
    fi
    local sok=0
    [ "$mode" = "1" ] && sok=1

    tls_pref="$(orch_ask_sweep_tls_pref)"
    if [ -z "$tls_pref" ]; then
        echo "Отмена."
        pause_enter
        return 0
    fi

    extra_pause="$(orch_ask_sweep_extra_delay)"
    if [ -z "$extra_pause" ]; then
        echo "Отмена."
        pause_enter
        return 0
    fi

    orch_auto_sweep "$kind" "$key" "$proto_list" "$test_url" "$start" "$max" "$sok" "$extra_pause" "$tls_pref"
    pause_enter
}

# Автопрогон стратегий: применяет локи по очереди и проверяет каждую одним
# прогоном движка z2r_tls_* (компактная строка на стратегию), затем сводка
# и выбор сохранения. kind=profile|domain; key=профиль или домен.
# $8 (extra_pause) — добавка к базовой паузе между стратегиями
# (база ${Z2R_SWEEP_PAUSE:-3} сек), пауза нужна против срабатывания ТСПУ.
# $9 (tls_pref: any|12|13|both) — какие версии TLS обязаны работать, чтобы
# стратегия считалась зелёной (в диалоге по умолчанию обе).
orch_auto_sweep() {
    local kind="$1" key="$2" proto_list="$3" test_url="$4" start="$5" max="$6" stop_on_ok="$7"
    local s p out v12 v13 dl short token color vcolor
    local ok_list="" warn_list="" n_ok=0 n_warn=0 n_fail=0
    local ok_stats="" best="" best_short=""
    local full_list="" full_stats="" best_full="" best_full_short=""
    local warn_stats="" best_from_warn=0 n_a12=0 n_a13=0
    local prev_str="" interrupted=0 svc_was_running=0
    local -A prev_map
    local code12 code13 q12 q13 badge btxt bst bcol line12 line13

    # case-проверка всей строки: grep -E '^[0-9]+$' построчный и пропускает
    # многострочный мусор, у которого одна из строк — число.
    local extra_pause="${8:-0}"
    case "$extra_pause" in ''|*[!0-9]*) extra_pause=0 ;; esac
    local base_pause="${Z2R_SWEEP_PAUSE:-3}"
    case "$base_pause" in ''|*[!0-9]*) base_pause=3 ;; esac
    local pause_sec=$((base_pause + extra_pause))

    local tls_pref="${9:-any}"
    case "$tls_pref" in
        12|13|both) ;;
        *) tls_pref="any" ;;
    esac
    local goal_txt="" goal_list=""
    case "$tls_pref" in
        12)   goal_txt=", цель TLS 1.2";      goal_list=" (нужен TLS 1.2)" ;;
        13)   goal_txt=", цель TLS 1.3";      goal_list=" (нужен TLS 1.3)" ;;
        both) goal_txt=", цель TLS 1.2+1.3";  goal_list=" (TLS 1.2 и 1.3)" ;;
    esac

    if [ "$kind" = "domain" ]; then
        prev_str="$(orch_locked_get "$key" "tls")"
    else
        for p in $proto_list; do
            prev_map["$p"]="$(orch_locked_get "$key" "$p")"
        done
    fi

    local total=$((max - start + 1))
    echo -e "${cyan}Автопрогон: стратегии ${start}-${max} (${total} шт., примерно $((total * 5 + (total - 1) * pause_sec)) сек, пауза ${pause_sec} сек между стратегиями${goal_txt}). Ctrl+C - прервать.${plain}"
    # Ctrl+C не должен ронять скрипт: под set -e прерванный curl/sleep завершает
    # всю функцию раньше флага. Отключаем -e на время прогона и восстанавливаем.
    local had_e=0
    case "$-" in *e*) had_e=1 ;; esac
    set +e
    trap 'orch_auto_sweep_interrupted=1' INT
    orch_auto_sweep_interrupted=0
    # В каждой строке нужен статус обеих версий TLS — движок не должен
    # добивать медленную пробу (z2r_tls_check_target смотрит эту переменную).
    local wait_both_prev="${Z2R_TLS_WAIT_BOTH:-}"
    Z2R_TLS_WAIT_BOTH=1
    zapret2_running && svc_was_running=1

    for ((s=start; s<=max; s++)); do
        if [ "$kind" = "domain" ]; then
            orch_locked_set "$key" "tls" "$s"
        else
            for p in $proto_list; do
                orch_locked_set "$key" "$p" "$s"
            done
        fi

        out="$(z2r_tls_check_target "$test_url")"
        if [ "$orch_auto_sweep_interrupted" = "1" ]; then
            echo -e "${yellow}Прервано пользователем на стратегии ${s}.${plain}"
            break
        fi
        v12="$(printf '%s\n' "$out" | sed -n 1p)"
        v13="$(printf '%s\n' "$out" | sed -n 2p)"
        dl="$(printf '%s\n' "$out" | sed -n 3p)"
        short="$(z2r_tls_short_result "$v12" "$v13" "$dl" "$tls_pref")"
        token="${short%%|*}"; short="${short#*|}"

        q12=0; q13=0
        if z2r_tls_code_ok "$(z2r_tls_field "$v12" 2)"; then q12=1; fi
        if z2r_tls_code_ok "$(z2r_tls_field "$v13" 2)"; then q13=1; fi
        # Для подсказки «TLS X не прошёл ни одной стратегией» считаем ответившие
        # версии (включая 4xx — googlevideo на корневой путь отвечает 404).
        case "$(z2r_tls_version_state "$(z2r_tls_field "$v12" 1)" "$(z2r_tls_field "$v12" 2)")" in
            ok|http) n_a12=$((n_a12 + 1)) ;;
        esac
        case "$(z2r_tls_version_state "$(z2r_tls_field "$v13" 1)" "$(z2r_tls_field "$v13" 2)")" in
            ok|http) n_a13=$((n_a13 + 1)) ;;
        esac

        case "$token" in
            ok)
                color="$green"; disp="OK  "; n_ok=$((n_ok + 1)); ok_list="${ok_list}${ok_list:+ }${s}"
                dlsize2="$(z2r_tls_field "$dl" 3)"; dltime2="$(z2r_tls_field "$dl" 4)"
                if [ "$q12" = "1" ] && [ "$q13" = "1" ]; then
                    full_list="${full_list}${full_list:+ }${s}"
                fi
                if [ "$dl" != "skip" ] && printf '%s' "$dltime2" | grep -Eq '^[0-9]+\.?[0-9]*$'; then
                    ok_stats="${ok_stats}${s}|${dltime2}|${dlsize2}|${short}"$'\n'
                    if [ "$q12" = "1" ] && [ "$q13" = "1" ]; then
                        full_stats="${full_stats}${s}|${dltime2}|${dlsize2}|${short}"$'\n'
                    fi
                fi
                ;;
            warn)
                color="$yellow"; disp="WARN"; n_warn=$((n_warn + 1)); warn_list="${warn_list}${warn_list:+ }${s}"
                dlsize2="$(z2r_tls_field "$dl" 3)"; dltime2="$(z2r_tls_field "$dl" 4)"
                if [ "$dl" != "skip" ] && printf '%s' "$dltime2" | grep -Eq '^[0-9]+\.?[0-9]*$'; then
                    warn_stats="${warn_stats}${s}|${dltime2}|${dlsize2}|${short}"$'\n'
                fi
                ;;
            *) color="$red"; disp="FAIL"; token="fail"; n_fail=$((n_fail + 1)) ;;
        esac

        badge="$(z2r_tls_version_badge "tls1.2" "$v12")"
        btxt="${badge%%|*}"; bst="${badge#*|}"
        case "$bst" in
            ok) bcol="$green" ;;
            http) bcol="$yellow" ;;
            fail) bcol="$red" ;;
            *) bcol="$plain" ;;
        esac
        line12="$(printf '%b%-17s%b' "$bcol" "$btxt" "$plain")"
        badge="$(z2r_tls_version_badge "tls1.3" "$v13")"
        btxt="${badge%%|*}"; bst="${badge#*|}"
        case "$bst" in
            ok) bcol="$green" ;;
            http) bcol="$yellow" ;;
            fail) bcol="$red" ;;
            *) bcol="$plain" ;;
        esac
        line13="$(printf '%b%-17s%b' "$bcol" "$btxt" "$plain")"
        printf '%s %3d: %b %b %b %b\n' "$(date '+%H:%M:%S')" "$s" \
            "${color}${disp}${plain}" "$line12" "$line13" "${color}${short}${plain}"

        if [ "$stop_on_ok" = "1" ] && [ "$token" = "ok" ]; then
            break
        fi
        # Пауза между стратегиями, чтобы частыми переключениями не словить блок ТСПУ.
        if [ "$s" -lt "$max" ] && [ "$pause_sec" -gt 0 ]; then
            sleep "$pause_sec"
            if [ "$orch_auto_sweep_interrupted" = "1" ]; then
                echo -e "${yellow}Прервано пользователем на стратегии ${s}.${plain}"
                break
            fi
        fi
    done
    trap - INT
    if [ "$had_e" = "1" ]; then set -e; fi
    Z2R_TLS_WAIT_BOTH="$wait_both_prev"

    if [ "$svc_was_running" = "1" ] && ! zapret2_running; then
        echo -e "${red}zapret2 был остановлен: процесс nfqws2 убит (похоже, Ctrl+C). Перезапускаю...${plain}"
        z2r_service_action restart >/dev/null 2>&1 || true
        if zapret2_running; then
            echo -e "${green}zapret2 снова работает.${plain}"
        else
            echo -e "${red}Не удалось перезапустить zapret2. Запустите вручную: пункт 22 главного меню.${plain}"
        fi
    fi

    # Лучшая = самая быстрая зелёная по скорости докачки (байт/с), а не первая
    # попавшаяся; при равной скорости выигрывает меньший номер.
    best=""
    best_short=""
    if [ -n "$ok_stats" ]; then
        win="$(printf '%s' "$ok_stats" | awk -F'|' 'BEGIN{max=-1} {t=$2+0; sz=$3+0; if (t>0 && sz/t>max) {max=sz/t; line=$0}} END{print line}')"
        best="${win%%|*}"
        best_short="$(printf '%s' "$win" | cut -d'|' -f4-)"
    fi
    if [ -z "$best" ] && [ -n "$ok_list" ]; then
        best="${ok_list%% *}"
        best_short="сервер ответил (без докачки)"
    fi
    if [ -z "$best" ] && [ -n "$warn_list" ]; then
        best_from_warn=1
        best="${warn_list%% *}"
        best_short="жёлтая (единственная без красных)"
        if [ -n "$warn_stats" ]; then
            win="$(printf '%s' "$warn_stats" | awk -F'|' 'BEGIN{max=-1} {t=$2+0; sz=$3+0; if (t>0 && sz/t>max) {max=sz/t; line=$0}} END{print line}')"
            best="${win%%|*}"
            best_short="$(printf '%s' "$win" | cut -d'|' -f4-)"
        fi
    fi

    # Самая быстрая из «полных» (обе версии TLS + докачка) — та же метрика
    # скорости, что и у главной лучшей.
    best_full=""
    best_full_short=""
    if [ -n "$full_stats" ]; then
        win="$(printf '%s' "$full_stats" | awk -F'|' 'BEGIN{max=-1} {t=$2+0; sz=$3+0; if (t>0 && sz/t>max) {max=sz/t; line=$0}} END{print line}')"
        best_full="${win%%|*}"
        best_full_short="$(printf '%s' "$win" | cut -d'|' -f4-)"
    fi

    echo ""
    echo "================================================"
    echo -e " Итог автопрогона: ${green}OK ${n_ok}${plain}, ${yellow}жёлтых ${n_warn}${plain}, ${red}красных ${n_fail}${plain}"
    [ -n "$ok_list" ] && echo -e " Зелёные стратегии${goal_list}: ${green}${ok_list}${plain}"
    if [ -n "$full_list" ] && [ "$full_list" != "$ok_list" ]; then
        echo -e " Полные (TLS 1.2 и 1.3): ${green}${full_list}${plain}"
    fi
    [ -n "$warn_list" ] && echo -e " Жёлтые стратегии: ${yellow}${warn_list}${plain}"
    if [ -n "$best" ]; then
        if [ "$best_from_warn" = "1" ]; then
            echo -e " Лучшая из жёлтых (зелёных нет): ${yellow}${best}${plain} (${best_short})"
        else
            echo -e " Лучшая (самая быстрая из зелёных): ${Fgreen}${best}${plain} (${best_short})"
        fi
    else
        echo -e " ${red}Рабочих стратегий не найдено.${plain}"
    fi
    if [ -n "$best_full" ] && [ "$best_full" != "$best" ]; then
        echo -e " Самая быстрая полная (TLS 1.2 и 1.3): ${Fgreen}${best_full}${plain} (${best_full_short})"
    fi
    # Нужная версия TLS не прошла ни одной стратегией — это свойство сайта
    # или блокировки, стратегии тут не помогут; подсказываем, что делать.
    if [ "$n_a12" = "0" ] && { [ "$tls_pref" = "both" ] || [ "$tls_pref" = "12" ]; }; then
        echo -e " ${yellow}TLS 1.2 не прошёл ни одной стратегией: сайт или блокировка его не пускает.${plain}"
        if [ "$tls_pref" = "both" ]; then
            echo -e " ${yellow}Если TLS 1.2 не нужен, перезапустите автопрогон с целью TLS 1.3.${plain}"
        fi
    fi
    if [ "$n_a13" = "0" ] && { [ "$tls_pref" = "both" ] || [ "$tls_pref" = "13" ]; }; then
        echo -e " ${yellow}TLS 1.3 не прошёл ни одной стратегией: сайт или блокировка его не пускает.${plain}"
        if [ "$tls_pref" = "both" ]; then
            echo -e " ${yellow}Если TLS 1.3 не нужен, перезапустите автопрогон с целью TLS 1.2.${plain}"
        fi
    fi
    echo "================================================"

    local answer
    if [ -n "$best" ]; then
        read -re -p "Enter - сохранить ${best}, номер - сохранить другую, 0 - вернуть как было: " answer || answer="0"
    else
        read -re -p "0 или Enter - вернуть как было: " answer || answer="0"
    fi

    if [ "$kind" = "domain" ]; then
        if [ -n "$answer" ] && [ "$answer" != "0" ] && printf '%s' "$answer" | grep -Eq '^[0-9]+$' \
            && [ "$answer" -ge 1 ] && [ "$answer" -le "$max" ]; then
            orch_locked_set "$key" "tls" "$answer"
            echo "Стратегия ${answer} сохранена для домена ${key}."
            telemetry_notify
        elif [ -z "$answer" ] && [ -n "$best" ]; then
            orch_locked_set "$key" "tls" "$best"
            echo "Стратегия ${best} сохранена для домена ${key}."
            telemetry_notify
        else
            if [ -n "$prev_str" ] && [ "$prev_str" != "0" ]; then
                orch_locked_set "$key" "tls" "$prev_str"
            elif [ "$prev_str" = "0" ]; then
                orch_locked_set "$key" "tls" 0
            else
                orch_locked_clear "$key" "tls"
            fi
            echo "Изменения отменены, прежняя стратегия домена возвращена."
        fi
    else
        if [ -n "$answer" ] && [ "$answer" != "0" ] && printf '%s' "$answer" | grep -Eq '^[0-9]+$' \
            && [ "$answer" -ge 1 ] && [ "$answer" -le "$max" ]; then
            :
        elif [ -z "$answer" ] && [ -n "$best" ]; then
            answer="$best"
        else
            answer="0"
        fi
        if [ "$answer" != "0" ]; then
            local cfg old_udp_ports
            cfg="$(get_config_file)"
            old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
            if profile_state_set_and_apply "$key" "$proto_list" "$answer" "$cfg"; then
                echo "Стратегия ${answer} сохранена для профиля ${key}."
                profile_strategy_restart_if_needed "$key" "$cfg" "$old_udp_ports"
            else
                echo -e "${red}Не удалось сохранить стратегию ${answer} для профиля ${key}.${plain}"
            fi
            telemetry_notify
        else
            for p in $proto_list; do
                if [ -n "${prev_map[$p]}" ] && [ "${prev_map[$p]}" -gt 0 ]; then
                    orch_locked_set "$key" "$p" "${prev_map[$p]}"
                elif [ "${prev_map[$p]}" = "0" ]; then
                    orch_locked_set "$key" "$p" 0
                else
                    orch_locked_clear "$key" "$p"
                fi
            done
            echo "Изменения отменены, прежние стратегии профиля возвращены."
        fi
    fi
    return 0
}

get_orchestra_locks_info() {
    local output_var="${1:-}"
    local profile_state_file orch_lock_file
    # fallback для автономного вызова (CGI/WebUI не наследует палитру z2r.sh)
    [ -z "${gray:-}" ] && gray='\033[0;90m'
    profile_state_file="$PROFILE_STATE_FILE"
    orch_lock_file="$ORCH_LOCK_FILE"

    local _pairs="1:tls|2:tls|3:tls|4:tls|5:udp|6:udp|7:udp|8:tls|9:http|10:udp"
    local stored_line orch_line
    if [ "${ORCH_ACTIVE_SCOPE:-default}" = default ]; then
      stored_line="$(_orchestra_multi_state "$profile_state_file" "$_pairs")"
      orch_line="$(_orchestra_multi_state "$orch_lock_file" "$_pairs")"
    else
      # Контекст mark'и (client scopes): показываем локи только этого клиента,
      # глобальный profile state в шапку не примешиваем.
      stored_line=""
      orch_line="$(_orchestra_multi_state "$(_orch_scope_lock_file "$ORCH_ACTIVE_SCOPE" 2>/dev/null || printf '%s\n' "$orch_lock_file")" "$_pairs")"
    fi

    local s_vals o_vals
    IFS=$'\t' read -ra s_vals <<< "$stored_line"
    IFS=$'\t' read -ra o_vals <<< "$orch_line"
    local labels=("YT_TLS" "GV_TLS" "RKN_TLS" "DS_TLS" "YT_QUIC_UDP" "VOICE_UDP" "GAMES_UDP" "FB_TLS" "FB_HTTP" "DNS_UDP")
    local state_vars=("STRATEGY_STATE_YT_TLS" "STRATEGY_STATE_GV_TLS" "STRATEGY_STATE_RKN_TLS" "STRATEGY_STATE_DS_TLS" "STRATEGY_STATE_YT_QUIC_UDP" "STRATEGY_STATE_VOICE_UDP" "STRATEGY_STATE_GAMES_UDP" "STRATEGY_STATE_FB_TLS" "STRATEGY_STATE_FB_HTTP" "STRATEGY_STATE_DNS_UDP")
    local i raw eff colored rendered=""
    for ((i = 0; i < ${#labels[@]}; i++)); do
        raw="${s_vals[i]:-auto}"
        [ "$raw" = "auto" ] && raw="${o_vals[i]:-auto}"
        case "$raw" in
            ""|auto)
                eff="auto"
                printf -v colored "%b" "${gray}def${plain}"
                ;;
            0|skip)
                eff="0"
                printf -v colored "%b" "${red}0${plain}"
                ;;
            *[!0-9]*|0*)
                eff="auto"
                printf -v colored "%b" "${gray}def${plain}"
                ;;
            *)
                eff="$raw"
                printf -v colored "%b" "${Fgreen}${eff}${plain}"
                ;;
        esac
        printf -v "${state_vars[i]}" "%s" "$eff"
        rendered="${rendered}${rendered:+ }${labels[i]}=${colored}"
    done

    if [ -n "$output_var" ]; then
        printf -v "$output_var" "%s" "$rendered"
    else
        printf "%s" "$rendered"
    fi
}

_orchestra_multi_state() {
    local file="$1" pairs="$2"
    if [ -z "$file" ] || [ ! -f "$file" ]; then
        printf 'auto\tauto\tauto\tauto\tauto\tauto\tauto\tauto\tauto\tauto\n'
        return 0
    fi
    awk -v pairs="$pairs" '
        BEGIN {
            FS = "[ \t]+"
            n = split(pairs, P, "|")
            for (i = 1; i <= n; i++) {
                split(P[i], kv, ":")
                PR[i] = kv[1]; PROTO[i] = kv[2]
                R[i] = "auto"
            }
        }
        /^[[:space:]]*#/ || NF == 0 { next }
        {
            for (i = 1; i <= n; i++) {
                if (R[i] != "auto") continue
                if ($1 == PR[i] && $2 == PROTO[i] && NF >= 3) { R[i] = $3 }
                else if ($1 == PR[i] && NF == 2 && PROTO[i] == "tls") { R[i] = $2 }
            }
        }
        END {
            out = ""
            for (i = 1; i <= n; i++) out = out R[i] (i < n ? "\t" : "")
            print out
        }
    ' "$file"
}

# Нормализация введённого значения в чистый домен.
# Убирает пробелы, схему, userinfo, путь, порт и крайние точки.
z2r_normalize_domain() {
    local d="$1"
    d="${d#"${d%%[![:space:]]*}"}"
    d="${d%"${d##*[![:space:]]}"}"
    [ -z "$d" ] && return 1
    d="$(printf '%s' "$d" | sed 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/')"
    d="${d#*://}"
    d="${d##*@}"
    d="${d%%/*}"
    d="${d%%:*}"
    d="${d#.}"
    d="${d%.}"
    [ -z "$d" ] && return 1
    case "$d" in *[!a-z0-9.-]*) return 1 ;; esac
    case "$d" in *[a-z0-9]*) : ;; *) return 1 ;; esac
    printf '%s\n' "$d"
}

# Пути к доменным спискам, общие для CLI и WebUI.
custom_rkn_file() {
    echo "/opt/zator/extra_strats/TCP_Custom.txt"
}

netrogat_file() {
    echo "/opt/zator/lists/netrogat.txt"
}

netrogat_substring_file() {
    echo "/opt/zator/lists/netrogat_substrings.txt"
}

rkn_substring_file() {
    echo "/opt/zator/extra_strats/TCP_RKN_domains_by_substring.txt"
}

domain_list_prepare() {
    local file="$1"
    mkdir -p "$(dirname "$file")"
    touch "$file" 2>/dev/null || true
    sed -i '/^[[:space:]]*$/d' "$file" 2>/dev/null || true
}

domain_list_remove() {
    local file="$1" domain="$2" tmp
    [ -n "$domain" ] || return 1
    [ -f "$file" ] || return 0
    tmp="${file}.tmp.$$"
    grep -Fxv -- "$domain" "$file" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file" 2>/dev/null || true
    sed -i '/^[[:space:]]*$/d' "$file" 2>/dev/null || true
}

domain_list_add() {
    local file="$1" domain="$2" label="$3" item_name="${4:-Домен}"
    local quiet="${5:-0}" result_var="${6:-}" result="added"
    [ -n "$domain" ] || return 1
    domain_list_prepare "$file"
    if grep -Fixq "$domain" "$file" 2>/dev/null; then
        result="duplicate"
        [ -n "$result_var" ] && printf -v "$result_var" '%s' "$result"
        [ "$quiet" = "1" ] || echo -e "$item_name ${yellow}$domain${plain} уже есть в $label."
        return 0
    fi
    printf '%s\n' "$domain" >> "$file"
    [ -n "$result_var" ] && printf -v "$result_var" '%s' "$result"

    [ "$quiet" = "1" ] && return 0

    local action="добавлен"
    [ "$item_name" = "Подстрока" ] && action="добавлена"

    echo -e "$item_name ${yellow}$domain${plain} $action в $label."
}

domain_list_read() {
    local file="$1" line
    domains=()
    while IFS= read -r line; do
        if [ -n "$line" ] && ! printf "%s" "$line" | grep -Eq '^[[:space:]]*#'; then
            domains+=("$line")
        fi
    done < "$file"
}

domain_list_manage() {
    local file="$1" title="$2" empty_text="$3" list_text="$4" remove_message="$5" with_strategy="$6"
    local item_genitive="${7:-домена}"    # для фразы "Введите номер ..."
    local item_accusative="${8:-домен}"   # для фразы "Удалить ..."

    local choice confirm i target strat
    local domains=()

    domain_list_prepare "$file"
    while true; do
        clear -x
        echo -e "${cyan}--- $title ---${plain}"
        echo ""

        domain_list_read "$file"
        if [ "${#domains[@]}" -eq 0 ]; then
            echo -e "${yellow}$empty_text${plain}"
            echo ""
            pause_enter
            return 0
        fi

        echo -e "${yellow}$list_text${plain}"
        echo ""
        i=1
        for d in "${domains[@]}"; do
            if [ "$with_strategy" = "1" ]; then
                strat="$(orch_locked_get "$d" "tls")"
                if printf "%s" "$strat" | grep -Eq '^[0-9]+$' && [ "$strat" -gt 0 ]; then
                    printf "  ${Fcyan}%s.${plain} ${green}%s${plain} [стратегия ${Fcyan}%s${plain}]\n" "$i" "$d" "$strat"
                else
                    printf "  ${Fcyan}%s.${plain} ${green}%s${plain} [${yellow}Стратегии RKN${plain}]\n" "$i" "$d"
                fi
            else
                printf "  ${Fcyan}%s.${plain} ${green}%s${plain}\n" "$i" "$d"
            fi
            i=$((i+1))
        done
        echo ""
        echo -e "Введите номер ${item_genitive} для удаления, ${Fyellow}0${plain} - назад."
        read -re -p "Ваш выбор: " choice

        case "$choice" in
            "0"|"")
                return 0
                ;;
            *[!0-9]*)
                echo -e "${red}Некорректный ввод.${plain}"
                sleep 1
                ;;
            *)
                if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#domains[@]}" ]; then
                    echo -e "${red}Номер вне диапазона.${plain}"
                    sleep 1
                    continue
                fi
                target="${domains[$((choice-1))]}"
                # Используем подставленную форму слова
                echo -e "${yellow}Удалить ${item_accusative} $target?${plain}"
                echo "1 - да, удалить"
                echo "0 - отмена"
                read -re -p "Ваш выбор: " confirm
                if [ "$confirm" = "1" ]; then
                    domain_list_remove "$file" "$target"
                    [ "$with_strategy" = "1" ] && {
                        orch_locked_clear "$target" "tls"
                        orch_locked_clear "$target" "http"
                        orch_locked_clear "$target" "udp"
                    }
                    echo -e "${green}$remove_message${plain}"
                    pause_enter
                else
                    echo "Отменено."
                    sleep 1
                fi
                ;;
        esac
    done
}

custom_rkn_remove_domain() {
    local domain="$1"
    domain_list_remove "$(custom_rkn_file)" "$domain" || return 1
    # Домен мог получить стратегию в любом client-scope — вычищаем отовсюду.
    orch_locked_clear_everywhere "$domain" "tls"
    orch_locked_clear_everywhere "$domain" "http"
    orch_locked_clear_everywhere "$domain" "udp"
}

custom_rkn_add_domain() {
    domain_list_add "$(custom_rkn_file)" "$1" "TCP_Custom"
}

manage_custom_rkn_domain() {
    local user_domain="" test_url="" custom_file="" mode="" strategy_num=""
    local max_strat="" current_strat="" prev_strat="" answer=""
    local only_add=0
    local need_mode_prompt=1
    local existing_strat=""

    user_domain="${1:-}"
    if [ -z "$user_domain" ]; then
        read -re -p "Введите домен для добавления в TCP_Custom (RKN-обработка, например example.com): " user_domain
    fi
    if [ -z "$user_domain" ]; then
        echo "Ввод пустой, ничего не добавлено."
        pause_enter
        return 0
    fi

    # Нормализация: отсекаем схему (http/https), порт, путь, крайние точки и т.п.
    if ! user_domain="$(z2r_normalize_domain "$user_domain")"; then
        echo -e "${red}Не удалось распознать домен из ввода.${plain}"
        echo -e "Укажите домен или ссылку, например: example.com или https://www.youtube.com/watch?v=..."
        pause_enter
        return 0
    fi

    custom_file="$(custom_rkn_file)"
    domain_list_prepare "$custom_file"

    # Проверка: существует ли уже домен и есть ли для него подобранная стратегия.
    if grep -Fxq "$user_domain" "$custom_file" 2>/dev/null; then
        existing_strat="$(orch_locked_get "$user_domain" "tls")"
        if printf "%s" "$existing_strat" | grep -Eq '^[0-9]+$' && [ "$existing_strat" -gt 0 ]; then
            echo -e "${yellow}Домен $user_domain уже есть в TCP_Custom, для него подобрана стратегия ${existing_strat}.${plain}"
            echo "1 - подобрать новую стратегию"
            echo "2 - удалить домен и заново добавить (без подбора стратегии)"
            echo "0 - отменить и оставить всё как есть"
            read -re -p "Ваш выбор: " mode
            case "$mode" in
                "1")
                    echo -e "${green}Домен $user_domain оставлен в TCP_Custom, запускаю подбор новой стратегии.${plain}"
                    only_add=0
                    need_mode_prompt=0
                    ;;
                "2")
                    custom_rkn_remove_domain "$user_domain"
                    echo -e "${green}Домен $user_domain удалён, добавляю заново.${plain}"
                    only_add=1
                    need_mode_prompt=0
                    ;;
                *)
                    echo "Отменено. Всё оставлено как есть."
                    pause_enter
                    return 0
                    ;;
            esac
        else
            echo -e "${yellow}Домен $user_domain уже есть в TCP_Custom, общие стратегии RKN.${plain}"
            # Падаем в обычный выбор режима: добавление будет no-op, но можно подобрать стратегию.
        fi
    fi

    if [ "$need_mode_prompt" -eq 1 ]; then
        echo "1 - только добавить домен в список TCP_Custom"
        echo "2 - добавить и подобрать стратегию для этого домена"
        echo "0 - отмена"
        read -re -p "Ваш выбор: " mode

        case "$mode" in
            "1")
                only_add=1
                ;;
            "2")
                ;;
            "0"|"")
                echo "Отменено."
                pause_enter
                return 0
                ;;
            *)
                echo "Отменено."
                pause_enter
                return 0
                ;;
        esac
    fi

    custom_rkn_add_domain "$user_domain"

    if [ "$only_add" -eq 1 ]; then
        pause_enter
        return 0
    fi

    # Домен попадает в лист глобально (обрабатывается у всех), а подобранная
    # стратегия закрепляется за конкретным клиентом: при включённых Client
    # scopes спрашиваем марку, остальное — как раньше (default).
    # local + динамический скоп bash: все вложенные вызовы (подбор,
    # автопрогон, восстановление) видят этот ORCH_ACTIVE_SCOPE, а после
    # выхода из функции глобальное значение не меняется.
    local ORCH_ACTIVE_SCOPE="default"
    if type client_scope_mode_text >/dev/null 2>&1 \
      && [ "$(client_scope_mode_text)" = "включен" ] \
      && type client_scopes_ask_scope_for_strategies >/dev/null 2>&1; then
        echo "Стратегия закрепляется за клиентом (Client scopes включены)."
        if client_scopes_ask_scope_for_strategies; then
            ORCH_ACTIVE_SCOPE="$CLIENT_SCOPE_ASK_RESULT"
        fi
        if [ "$ORCH_ACTIVE_SCOPE" != default ]; then
            echo -e "${yellow}Подбор и сохранение стратегии — для клиента ${ORCH_ACTIVE_SCOPE}.${plain}"
        fi
    fi

    max_strat="$(orch_max_strategy_for_profile 3)"
    if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
        max_strat=19
    fi

    current_strat="$(orch_locked_get "$user_domain" "tls")"
    if ! printf "%s" "$current_strat" | grep -Eq '^[0-9]+$' || [ "$current_strat" -le 0 ]; then
        current_strat=1
    fi
    # Прежняя стратегия — в контексте выбранного клиента; подмешивать
    # default-значение нельзя (это другой scope).
    prev_strat="$(orch_locked_get "$user_domain" "tls")"
    if ! printf "%s" "$prev_strat" | grep -Eq '^[0-9]+$' || [ "$prev_strat" -le 0 ]; then
        prev_strat=""
    fi

    read -re -p "Введите номер стратегии для старта (Enter - текущая $current_strat, A - автопрогон всех): " strategy_num
    case "$strategy_num" in
        a|A|а|А)
            test_url="$user_domain"
            if ! printf "%s" "$test_url" | grep -Eq '^https?://'; then
                test_url="https://$test_url"
            fi
            orch_run_auto_sweep "domain" "$user_domain" "tls" "$test_url" 1 "$max_strat"
            return 0
            ;;
    esac
    if [ -z "$strategy_num" ]; then
        strategy_num="$current_strat"
    fi
    if ! ui_is_number_in_range "$strategy_num" 1 "$max_strat"; then
        echo "Некорректный номер стратегии или вне диапазона. Начинаем с 1."
        strategy_num=1
    fi

    test_url="$user_domain"
    if ! printf "%s" "$test_url" | grep -Eq '^https?://'; then
        test_url="https://$test_url"
    fi

    for ((s=strategy_num; s<=max_strat; s++)); do
        orch_locked_set "$user_domain" "tls" "$s"

        echo -e "Стратегия $s применена для домена ${cyan}${user_domain}${plain}"
        echo -e "${yellow}Запускается проверка, пожалуйста подождите:${plain}"
        check_access "$test_url"

        read -re -p "1 - сохранить, 0 - отмена, Enter - далее: " answer
        if [ "$answer" = "1" ]; then
            if [ "$ORCH_ACTIVE_SCOPE" != default ]; then
                echo "Стратегия $s сохранена для $user_domain (клиент $ORCH_ACTIVE_SCOPE)."
            else
                echo "Стратегия $s сохранена для $user_domain."
            fi
            telemetry_notify
            pause_enter
            return 0
        elif [ "$answer" = "0" ]; then
            break
        fi
    done

    if printf "%s" "$prev_strat" | grep -Eq '^[0-9]+$' && [ "$prev_strat" -gt 0 ]; then
        orch_locked_set "$user_domain" "tls" "$prev_strat"
    else
        orch_locked_clear "$user_domain" "tls"
    fi
    echo "Изменения по стратегии для домена отменены."
    pause_enter
}

manage_custom_rkn_list() {
    domain_list_manage "$(custom_rkn_file)" \
        "TCP_Custom: домены и стратегии" \
        "Список TCP_Custom пуст. Домены добавляются через пункт 6-3." \
        "Домены в TCP_Custom и подобранные стратегии:" \
        "Домен удалён из TCP_Custom и locked.tsv." \
        1
}

netrogat_remove_domain() {
    domain_list_remove "$(netrogat_file)" "$1"
}

netrogat_add_domain() {
    local user_domain="" clean_domain="" net_file
    net_file="$(netrogat_file)"
    domain_list_prepare "$net_file"

    read -re -p "Введите домен, который добавить в исключения (например, mydomain.com): " user_domain
    if [ -z "$user_domain" ]; then
        echo "Ввод пустой, ничего не добавлено"
        pause_enter
        return 0
    fi

    if clean_domain="$(z2r_normalize_domain "$user_domain")"; then
        domain_list_add "$net_file" "$clean_domain" "исключениях (netrogat.txt)"
    else
        echo -e "${red}Не удалось распознать домен из ввода:${plain} ${yellow}$user_domain${plain}"
        echo -e "Укажите домен или ссылку, например: example.com или https://www.youtube.com/watch?v=..."
    fi
    pause_enter
}

manage_netrogat_list() {
    domain_list_manage "$(netrogat_file)" \
        "netrogat.txt: домены-исключения" \
        "Список netrogat.txt пуст." \
        "Домены в netrogat.txt (лист исключений):" \
        "Домен удалён из netrogat.txt." \
        0
}

netrogat_substring_warn_old_config() {
    local cfg
    cfg="$(get_config_file 2>/dev/null)" || return 0
    [ -n "$cfg" ] || return 0
    grep -q "exclude_substrings=" "$cfg" 2>/dev/null && return 0
    echo -e "${yellow}Внимание: текущий config не содержит exclude_substrings.${plain}"
    echo -e "Подстроки исключений начнут действовать после обновления конфига (пункт 5 главного меню)."
    return 1
}

netrogat_substring_add_line() {
    local file line
    file="$(netrogat_substring_file)"

    clear -x
    netrogat_substring_warn_old_config || true
    echo ""
    echo -e "${cyan}--- Исключения по части имени ---${plain}"
    echo "Добавьте часть имени домена, и все домены с таким текстом будут исключены из обработки."
    echo "Аналог netrogat.txt, но работает по части имени, а не по полному домену."
    echo "Например, если добавить bank, исключены будут: sber-bank.ru, banki.ru"
    echo "и другие домены, в названии которых есть bank."
    echo ""
    read -re -p "Введите подстроку для исключения: " line
    if [ -z "$line" ]; then
        echo "Отменено."
        pause_enter
        return 0
    fi

    domain_list_add "$file" "$line" "список подстрок исключений (netrogat_substrings.txt)" "Подстрока"
    pause_enter
}

netrogat_substring_manage_lines() {
    netrogat_substring_warn_old_config || pause_enter
    domain_list_manage "$(netrogat_substring_file)" \
        "Управление строками netrogat_substrings" \
        "Файл пуст. Добавьте подстроки через соответствующий пункт меню." \
        "Текущие подстроки исключений в файле:" \
        "Подстрока успешно удалена." \
        0 \
        "подстроки" \
        "подстроку"
}

rkn_substring_add_line() {
    local file line
    file="$(rkn_substring_file)"

    if [ ! -f "$file" ]; then
        echo -e "${red}Файл $file не найден.${plain}"
        echo -e "${yellow}Обновите конфиг через пункт 5 главного меню.${plain}"
        pause_enter
        return 1
    fi

    clear -x
    echo -e "${cyan}--- Домены по части имени ---${plain}"
    echo "Добавьте часть имени домена, и все домены с таким текстом будут обрабатываться стратегией РКН."
    echo "Например, если добавить cdn, стратегия РКН будет применяться к:"
    echo "cdn-1.mysite.com, mycdn.com и другим доменам, в названии которых есть cdn."
    echo "Примеры корректного ввода: cdn, media, static, assets"
    echo "Примеры некорректного ввода: rkn.ru, youtube.com и т.д., где содержатся домены"
    echo ""

    read -re -p "Введите подстроку для добавления: " line

    if [ -z "$line" ]; then
        echo "Отменено."
        pause_enter
        return 0
    fi

    domain_list_add "$file" "$line" "список подстрок РКН" "Подстрока"
    pause_enter
}

rkn_substring_manage_lines() {
    local file
    file="$(rkn_substring_file)"

    if [ ! -f "$file" ]; then
        echo -e "${red}Файл $file не найден.${plain}"
        pause_enter
        return 1
    fi

    domain_list_manage "$file" \
        "Управление строками TCP_RKN_domains_by_substring" \
        "Файл пуст. Добавьте подстроки через соответствующий пункт меню." \
        "Текущие подстроки в файле:" \
        "Подстрока успешно удалена." \
        0 \
        "подстроки" \
        "подстроку"
}

Strats_Tryer() {
  local mode_domain="$1"

  case "$mode_domain" in
    "1")
      #вывод подсказки
      show_hint "UDP"
      orch_profile_try "5" "Профиль 5: UDP 443 (QUIC)" "udp" ""
      ;;
    "2")
      #вывод подсказки
      show_hint "TCP"
      orch_profile_try "1" "Профиль 1: TCP 443 (YouTube)" "tls http" "https://www.youtube.com/"
      ;;
    "3")
      #вывод подсказки
      show_hint "GV"
      orch_profile_try "2" "Профиль 2: TCP 443 (Googlevideo)" "tls" "https://$(get_yt_cluster_domain)"
      ;;
    "4")
      #вывод подсказки
      show_hint "RKN"
      orch_profile_try "3" "Профиль 3: TCP 443 (RKN)" "tls" "https://meduza.io"
      ;;
    *)
      manage_custom_rkn_domain "$mode_domain"
      ;;
  esac
}
