# Функция для генерации строки статуса стратегий
get_current_strategies_info() {
    local s_udp s_tcp s_gv s_rkn
    s_udp="$(profile_state_display 5 udp)"
    s_tcp="$(profile_state_display 1 tls)"
    s_gv="$(profile_state_display 2 tls)"
    s_rkn="$(profile_state_display 3 tls)"

    colorize_num() {
        if [ "$1" = "auto" ]; then
            echo "${gray}auto${plain}"
        elif [ "$1" = "0" ]; then
            echo "${Fyellow}0${plain}"
        elif printf "%s" "$1" | grep -Eq '^[0-9]+$'; then
            echo "${green}$1${plain}"
        else
            echo "${gray}auto${plain}"
        fi
    }

    echo -e "YT_UDP:$(colorize_num "$s_udp") YT_TCP:$(colorize_num "$s_tcp") YT_GV:$(colorize_num "$s_gv") RKN:$(colorize_num "$s_rkn")"
}

telemetry_notify() {
    type send_stats >/dev/null 2>&1 && send_stats || true
}

orch_max_strategy_for_profile() {
    config_profile_max_strategy "$1"
}

profile_strategy_restart_notice() {
    if [ -n "${ZAPRET2_INIT:-}" ] && [ -x "$ZAPRET2_INIT" ]; then
        "$ZAPRET2_INIT" restart
        echo -e "${green}zapret2 перезапущен для применения изменений config.${plain}"
    else
        echo -e "${yellow}Перезапустите zapret2, чтобы изменения config вступили в силу.${plain}"
    fi
}

profile_strategy_restart_if_needed() {
    if [ "$1" = "6" ]; then
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
    echo "Текущее состояние: $current_state"
    read -re -p "Введите номер стратегии (0 - отключить профиль, Enter - без изменений): " start_strat
    if [ -z "$start_strat" ]; then
        echo "Без изменений."
        return
    fi
    if [ "$start_strat" = "0" ]; then
        if profile_state_set_and_apply "$profile" "$proto_list" "0" "$(get_config_file)"; then
            echo "Профиль $profile выключен и сохранён как 0."
            profile_strategy_restart_if_needed "$profile"
        else
            echo -e "${red}Не удалось выключить профиль $profile.${plain}"
        fi
        telemetry_notify
        pause_enter
        return
    fi
    if ! printf "%s" "$start_strat" | grep -Eq '^[0-9]+$'; then
        echo "Неверный номер стратегии. Начинаем с 1."
        start_strat=1
    elif [ "$start_strat" -lt 1 ] || [ "$start_strat" -gt "$max_strat" ]; then
        echo "Номер стратегии вне диапазона. Начинаем с 1."
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
            if curl --max-time 2 -s -o /dev/null "$test_url"; then
                echo -e "${green}Есть ответ по HTTP.${plain}"
            else
                echo -e "${yellow}Нет ответа по HTTP. Проверьте доступность вручную.${plain}"
            fi
        elif [ -n "$test_url" ]; then
            echo "Проверка доступа: $test_url"
            check_access "$test_url"
        fi

        read -re -p "1 - сохранить, 0 - отмена, Enter - далее: " answer
        if [ "$answer" = "1" ]; then
            if profile_state_set_and_apply "$profile" "$proto_list" "$s" "$(get_config_file)"; then
                echo "Стратегия $s сохранена для профиля $profile."
                profile_strategy_restart_if_needed "$profile"
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

get_orchestra_locks_info() {
    local yt_tls="" gv_tls="" rkn_tls="" ds_tls="" yt_quic_udp="" voice_udp="" games_udp="" fb_tls="" fb_http=""
    local v=""
    yt_tls="$(profile_state_display 1 tls)"
    gv_tls="$(profile_state_display 2 tls)"
    rkn_tls="$(profile_state_display 3 tls)"
    ds_tls="$(profile_state_display 4 tls)"
    yt_quic_udp="$(profile_state_display 5 udp)"
    voice_udp="$(profile_state_display 6 udp)"
    games_udp="$(profile_state_display 7 udp)"
    fb_tls="$(profile_state_display 8 tls)"
    fb_http="$(profile_state_display 9 http)"

    fmt_status_num() {
        v="${1:-auto}"
        if [ "$v" = "auto" ]; then
            printf "%b" "${gray}auto${plain}"
        elif [ "$v" = "0" ]; then
            printf "%b" "${Fyellow}0${plain}"
        else
            printf "%b" "${Fcyan}${v}${plain}"
        fi
    }

    printf "YT_TLS=%s GV_TLS=%s RKN_TLS=%s DS_TLS=%s YT_QUIC_UDP=%s VOICE_UDP=%s GAMES_UDP=%s FB_TLS=%s FB_HTTP=%s" \
        "$(fmt_status_num "$yt_tls")" \
        "$(fmt_status_num "$gv_tls")" \
        "$(fmt_status_num "$rkn_tls")" \
        "$(fmt_status_num "$ds_tls")" \
        "$(fmt_status_num "$yt_quic_udp")" \
        "$(fmt_status_num "$voice_udp")" \
        "$(fmt_status_num "$games_udp")" \
        "$(fmt_status_num "$fb_tls")" \
        "$(fmt_status_num "$fb_http")"
}

# Путь к файлу списка кастомных доменов TCP_Custom (RKN-обработка).
custom_rkn_file() {
    echo "/opt/zapret2/extra_strats/TCP_Custom.txt"
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
    local file="$1" domain="$2" label="$3"
    [ -n "$domain" ] || return 1
    domain_list_prepare "$file"
    if grep -Fixq "$domain" "$file" 2>/dev/null; then
        echo -e "Домен ${yellow}$domain${plain} уже есть в $label."
        return 0
    fi
    echo "$domain" >> "$file"
    echo -e "Домен ${yellow}$domain${plain} добавлен в $label."
}

domain_list_read() {
    local file="$1" line
    domains=()
    while IFS= read -r line; do
        [ -n "$line" ] && domains+=("$line")
    done < "$file"
}

domain_list_manage() {
    local file="$1" title="$2" empty_text="$3" list_text="$4" remove_message="$5" with_strategy="$6"
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
        echo -e "Введите номер домена для удаления, ${Fyellow}0${plain} - назад."
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
                echo -e "${yellow}Удалить домен $target?${plain}"
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
    orch_locked_clear "$domain" "tls"
    orch_locked_clear "$domain" "http"
    orch_locked_clear "$domain" "udp"
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
    # Функция z2r_normalize_domain() определена глобально в z2r.sh до подключения lib.
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

    max_strat="$(orch_max_strategy_for_profile 3)"
    if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
        max_strat=19
    fi

    current_strat="$(orch_locked_get "$user_domain" "tls")"
    if ! printf "%s" "$current_strat" | grep -Eq '^[0-9]+$' || [ "$current_strat" -le 0 ]; then
        current_strat=1
    fi
    prev_strat="$(orch_locked_get "$user_domain" "tls")"
    if ! printf "%s" "$prev_strat" | grep -Eq '^[0-9]+$' || [ "$prev_strat" -le 0 ]; then
        prev_strat="$existing_strat"
    fi

    read -re -p "Введите номер стратегии для старта (Enter - текущая $current_strat): " strategy_num
    if [ -z "$strategy_num" ]; then
        strategy_num="$current_strat"
    fi
    if ! printf "%s" "$strategy_num" | grep -Eq '^[0-9]+$'; then
        echo "Некорректный номер стратегии. Начинаем с 1."
        strategy_num=1
    elif [ "$strategy_num" -lt 1 ] || [ "$strategy_num" -gt "$max_strat" ]; then
        echo "Номер вне диапазона. Начинаем с 1."
        strategy_num=1
    fi

    test_url="$user_domain"
    if ! printf "%s" "$test_url" | grep -Eq '^https?://'; then
        test_url="https://$test_url"
    fi

    for ((s=strategy_num; s<=max_strat; s++)); do
        orch_locked_set "$user_domain" "tls" "$s"

        echo "Стратегия $s применена для домена $user_domain"
        check_access "$test_url"

        read -re -p "1 - сохранить, 0 - отмена, Enter - далее: " answer
        if [ "$answer" = "1" ]; then
            echo "Стратегия $s сохранена для $user_domain."
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

# Путь к файлу листа исключений netrogat.txt.
netrogat_file() {
    echo "/opt/zapret2/lists/netrogat.txt"
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

Strats_Tryer() {
  local mode_domain="$1"

  case "$mode_domain" in
    "1")
      #вывод подсказки
      show_hint "UDP"
      orch_profile_try "5" "Профиль 5: UDP 443 (YouTube QUIC)" "udp" ""
      ;;
    "2")
      #вывод подсказки
      show_hint "TCP"
      orch_profile_try "1" "Профиль 1: TCP 80/443 (YouTube)" "tls http" "https://www.youtube.com/"
      ;;
    "3")
      #вывод подсказки
      show_hint "GV"
      orch_profile_try "2" "Профиль 2: TCP 80/443 (Googlevideo)" "tls" "https://$(get_yt_cluster_domain)"
      ;;
    "4")
      #вывод подсказки
      show_hint "RKN"
      orch_profile_try "3" "Профиль 3: TCP 80/443 (RKN)" "tls" "https://meduza.io"
      ;;
    *)
      manage_custom_rkn_domain "$mode_domain"
      ;;
  esac
}
