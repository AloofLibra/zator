# submenus.sh
# Единый стиль: loop + return на 0/Enter

#функция меню "1. Сменить стратегии"
strategies_submenu() {
  while true; do
    clear -x
    local strategies_status cfg
    get_orchestra_locks_info strategies_status
    cfg="$(config_get_file 2>/dev/null)" || cfg=""
    menu_config_snapshot "$cfg"
    # Состояние безразборного режима (fallback): если выключен,
    # пункты 8/9 (Fallback TLS/HTTP) становятся недоступными.
    local fb_state fb_disabled auto_state auto_enabled
    fb_state="$MENU_FALLBACK"
    [ "$fb_state" = "выключен" ] && fb_disabled=1 || fb_disabled=0
    auto_state="$MENU_AUTO_MODE"
    [ "$auto_state" = "включен" ] && auto_enabled=1 || auto_enabled=0
    # Состояние обхода UDP на 1026-65531 (пункт 10): если выключен,
    # пункт 7 (UDP Games) становится недоступным.
    local games_state games_disabled
    games_state="$MENU_UDP_GAMES"
    [ "$games_state" = "Выключен" ] && games_disabled=1 || games_disabled=0

    echo -e "${cyan}--- Управление стратегиями ---${plain}"
    echo -e "${yellow}Выбор стратегии профиля (0 или Enter для выхода)${plain}"
    echo -e "  Текущие стратегии [${strategies_status}]"
    echo -e 

    if [ "$auto_enabled" = "1" ]; then
      echo -e "${Fcyan}	1-4.${plain} ${red}Ручной выбор TCP-стратегий недоступен при авторотации${plain}"
    else
      submenu_item "	1" "Профиль 1: TCP 443 (YouTube) [${MENU_PROFILE_MAX_1:-0}]" "tls" "$STRATEGY_STATE_YT_TLS"
      submenu_item "	2" "Профиль 2: TCP 443 (Googlevideo) [${MENU_PROFILE_MAX_2:-0}]" "tls" "$STRATEGY_STATE_GV_TLS"
      submenu_item "	3" "Профиль 3: TCP 443 (RKN) [${MENU_PROFILE_MAX_3:-0}]" "tls" "$STRATEGY_STATE_RKN_TLS"
      submenu_item "	4" "Профиль 4: TCP 443 (Discord) [${MENU_PROFILE_MAX_4:-0}]" "tls" "$STRATEGY_STATE_DS_TLS"
    fi
    submenu_item "	5" "Профиль 5: UDP 443 (QUIC) [${MENU_PROFILE_MAX_5:-0}]" "udp" "$STRATEGY_STATE_YT_QUIC_UDP"
    submenu_item "	6" "Профиль 6: UDP Voice (Discord/STUN) [${MENU_PROFILE_MAX_6:-0}]" "udp" "$STRATEGY_STATE_VOICE_UDP"
    if [ "$games_disabled" = "1" ]; then
      echo -e "${Fcyan}	7.${plain} ${red}Профиль 7: UDP Games (1026-65531) [${MENU_PROFILE_MAX_7:-0}]${plain} ${red}[выключен — включите обход UDP, п.10]${plain}"
    else
      submenu_item "	7" "Профиль 7: UDP Games (1026-65531) [${MENU_PROFILE_MAX_7:-0}]" "udp" "$STRATEGY_STATE_GAMES_UDP"
    fi
    if [ "$auto_enabled" = "1" ]; then
      echo -e "${Fcyan}	8-9.${plain} ${red}Ручной выбор fallback недоступен при авторотации${plain}"
    elif [ "$fb_disabled" = "1" ]; then
      echo -e "${Fcyan}	8.${plain} ${red}Fallback TLS (безразборный блок)${plain} ${red}[выключен — включите безразборный режим, п.13]${plain}"
      echo -e "${Fcyan}	9.${plain} ${red}Fallback HTTP (безразборный блок) [${MENU_PROFILE_MAX_9:-0}]${plain} ${red}[выключен — включите безразборный режим, п.13]${plain}"
    else
      submenu_item "	8" "Fallback TLS (безразборный блок)" "" "$STRATEGY_STATE_FB_TLS"
      submenu_item "	9" "Fallback HTTP (безразборный блок) [${MENU_PROFILE_MAX_9:-0}]" "" "$STRATEGY_STATE_FB_HTTP"
    fi
    submenu_item "	10" "Авторотация TCP/HTTP [${auto_state}]"
    submenu_item "	0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans

    if [ "$auto_enabled" = "1" ]; then
      case "$ans" in
        1|2|3|4|8|9)
          echo -e "${yellow}Ручной выбор TCP-стратегий недоступен при авторотации.${plain}"
          pause_enter
          continue
          ;;
      esac
    fi

    case "$ans" in
      "1")
        orch_profile_try "1" "Профиль 1: TCP 443 (YouTube)" "tls http" "https://www.youtube.com/"
        ;;
      "2")
        orch_profile_try "2" "Профиль 2: TCP 443 (Googlevideo)" "tls" "https://$(get_yt_cluster_domain)"
        ;;
      "3")
        orch_profile_try "3" "Профиль 3: TCP 443 (RKN)" "tls" "https://meduza.io"
        ;;
      "4")
        orch_profile_try "4" "Профиль 4: TCP 443 (Discord)" "tls" "https://discord.com/"
        ;;
      "5")
        echo -e "${yellow}Проверьте работоспособность в браузере.${plain}"
        orch_profile_try "5" "Профиль 5: UDP 443 (QUIC)" "udp" ""
        ;;
      "6")
        echo -e "${yellow}Проверьте работоспособность в приложении.${plain}"
        orch_profile_try "6" "Профиль 6: UDP Voice (Discord/STUN)" "udp" ""
        ;;
      "7")
        if [ "$games_disabled" = "1" ]; then
          echo -e "${red}Обход UDP на 1026-65531 выключен.${plain}"
          echo -e "${yellow}Сначала включите обход UDP на 1026-65531 портах в главном меню, пункт 10.${plain}"
          pause_enter
        else
          echo -e "${yellow}Проверьте работоспособность в игре.${plain}"
          orch_profile_try "7" "Профиль 7: UDP Games (1026-65531)" "udp" ""
        fi
        ;;
      "8")
        if [ "$fb_disabled" = "1" ]; then
          echo -e "${red}Безразборный режим выключен.${plain}"
          echo -e "${yellow}Сначала включите безразборный режим (fallback) в главном меню, пункт 13.${plain}"
          pause_enter
        else
          fallback_profile_try
        fi
        ;;
      "9")
        if [ "$fb_disabled" = "1" ]; then
          echo -e "${red}Безразборный режим выключен.${plain}"
          echo -e "${yellow}Сначала включите безразборный режим (fallback) в главном меню, пункт 13.${plain}"
          pause_enter
        else
          fallback_http_profile_try
        fi
        ;;
      "10")
        toggle_auto_mode
        pause_enter
        ;;
      "0"|"")
        return
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

# Подменю управления доменами (пункт 6 главного меню).
# Объединяет работу с листом исключений netrogat.txt и кастомными доменами TCP_Custom.
domains_submenu() {
  while true; do
    clear -x
    echo -e "${cyan}--- Управление доменами ---${plain}"
    echo ""
    echo -e "${yellow}Исключения (netrogat.txt):${plain}"
    submenu_item "1" "Добавить домен в исключения"
    submenu_item "2" "Просмотр/удаление доменов"
    echo ""
    echo -e "${yellow}TCP_Custom (RKN-обработка):${plain}"
    submenu_item "3" "Добавить домен в TCP_Custom (с/без подбора стратегии)"
    submenu_item "4" "Просмотр/удаление доменов TCP_Custom (с номерами стратегий)"
    echo ""
    echo -e "${yellow}TCP_RKN_domains_by_substring (строки):${plain}"
    submenu_item "5" "Добавить строку в TCP_RKN_domains_by_substring"
    submenu_item "6" "Просмотр/удаление строк TCP_RKN_domains_by_substring"
    echo ""
    echo -e "${yellow}Исключения по подстрокам (netrogat_substrings.txt):${plain}"
    submenu_item "7" "Добавить подстроку в netrogat_substrings"
    submenu_item "8" "Просмотр/удаление подстрок netrogat_substrings"
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans

    case "$ans" in
      "1")
        netrogat_add_domain
        ;;
      "2")
        manage_netrogat_list
        ;;
      "3")
        manage_custom_rkn_domain
        ;;
      "4")
        manage_custom_rkn_list
        ;;
      "5")
        rkn_substring_add_line
        ;;
      "6")
        rkn_substring_manage_lines
        ;;
      "7")
        netrogat_substring_add_line
        ;;
      "8")
        netrogat_substring_manage_lines
        ;;
      "0"|"")
        return
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

# Подменю управления портами (пункт 20 главного меню).
# Пользовательские порты добавляются в начало NFQWS2_PORTS_TCP/UDP.
# TCP-порты дополнительно попадают в стратегию RKN; UDP-стратегии не меняются.
ports_submenu() {
  local cfg="/opt/zapret2/config"
  while true; do
    clear -x
    echo -e "${cyan}--- Управление портами ---${plain}"
    echo ""
    echo -e "${yellow}TCP:${plain} ${green}$(config_get_var "$cfg" NFQWS2_PORTS_TCP)${plain}"
    echo -e "${yellow}UDP:${plain} ${green}$(config_get_var "$cfg" NFQWS2_PORTS_UDP)${plain}"
    echo ""
    echo -e "${yellow}TCP (добавляются в NFQWS2_PORTS_TCP и в стратегию RKN):${plain}"
    submenu_item "1" "Добавить TCP порт(ы)"
    submenu_item "2" "Просмотр/удаление TCP портов"
    echo ""
    echo -e "${yellow}UDP (добавляются только в NFQWS2_PORTS_UDP):${plain}"
    submenu_item "3" "Добавить UDP порт(ы)"
    submenu_item "4" "Просмотр/удаление UDP портов"
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans

    case "$ans" in
      "1")
        ports_add tcp
        ;;
      "2")
        ports_manage tcp
        ;;
      "3")
        ports_add udp
        ;;
      "4")
        ports_manage udp
        ;;
      "0"|"")
        return
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

flowoffload_submenu() {
  while true; do
    clear -x
    echo -e "${cyan}--- FLOWOFFLOAD ---${plain}"
    echo "Текущее состояние: $(config_get_var /opt/zapret2/config FLOWOFFLOAD 2>/dev/null)"
    echo ""

    submenu_item "1" "software (программное ускорение)"
    submenu_item "2" "hardware (аппаратное NAT)"
    submenu_item "3" "none (отключено)"
    submenu_item "4" "donttouch (дефолт)"
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans

    case "$ans" in
      "1"|"2"|"3"|"4")
        case "$ans" in
          1) val="software" ;;
          2) val="hardware" ;;
          3) val="none" ;;
          4) val="donttouch" ;;
        esac
        config_set_var /opt/zapret2/config FLOWOFFLOAD "$val"
        /opt/zapret2/install_prereq.sh
        z2r_service_action restart
        echo -e "${green}FLOWOFFLOAD=$val применён.${plain}"
        pause_enter
        ;;
      "0"|"")
        return
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

fwtype_submenu() {
  local cfg cur target nft_state ipt_state
  cfg="$(get_config_file)"

  while true; do
    clear -x
    echo -e "${cyan}--- Firewall (nftables/iptables) ---${plain}"
    cur="$(config_get_var "$cfg" FWTYPE)"
    echo "Текущий режим: $cur"
    echo ""

    if fwtype_nft_available; then
      nft_state="${green}доступен${plain}"
    else
      nft_state="${yellow}недоступен ($(fwtype_unavailable_reason nftables))${plain}"
    fi
    if fwtype_iptables_available; then
      ipt_state="${green}доступен${plain}"
    else
      ipt_state="${yellow}недоступен ($(fwtype_unavailable_reason iptables))${plain}"
    fi
    echo -e "nftables: $nft_state"
    echo -e "iptables: $ipt_state"
    echo ""

    target=""
    if [ "$cur" != "nftables" ] && fwtype_nft_available; then
      target="nftables"
    elif [ "$cur" != "iptables" ] && fwtype_iptables_available; then
      target="iptables"
    fi

    if [ -n "$target" ]; then
      submenu_item "1" "Переключить на $target"
    fi
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans

    case "$ans" in
      "1")
        if [ -n "$target" ]; then
          fwtype_apply "$target"
          pause_enter
        else
          ui_invalid_input
        fi
        ;;
      "0"|"")
        return
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

tcp443_submenu() {
  local cfg selected_count
  cfg="/opt/zapret2/config"

  while true; do
  clear -x
  selected_count="$(config_tcp443_current_strategy "$cfg")"
  echo -e "${yellow}Безразборный режим по стратегии: ${plain}$selected_count"
  echo -e "\033[33mС каким номером применить стратегию? (1-19, 0 - отключение безразборного режима, Enter - выход):${plain}"
  read -re -p " " answer_bezr
  
  case "$answer_bezr" in
    "" )
      return
      ;;
    *)
      if echo "$answer_bezr" | grep -Eq '^[0-9]+$' && [ "$answer_bezr" -ge 0 ] && [ "$answer_bezr" -le 19 ]; then
        if [ "$answer_bezr" -ge 1 ] && [ "$answer_bezr" -le 19 ]; then
          if ! config_tcp443_set_strategy "$answer_bezr" "$cfg"; then
            rm -f "${cfg}.tmp"
            echo -e "${yellow}Не удалось найти TCP443-блок с маркерами #Z2R_TCP443_BEGIN/#Z2R_TCP443_END.${plain}"
            pause_enter
            continue
          fi
          z2r_service_action restart
          echo -e "${green}Выполнена команда перезапуска zapret. ${yellow}Безразборный режим активирован на $answer_bezr стратегии для TCP-443. Проверка доступа к meduza.io${plain}"
          check_access_list
        else
          config_tcp443_set_strategy 0 "$cfg"
          z2r_service_action restart
          echo -e "${green}Выполнена команда перезапуска zapret${plain}"
          echo "Безразборный режим отключен"
        fi
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
      else
        ui_invalid_input
        pause_enter
      fi
      ;;
  esac
done
}

provider_submenu() {
  provider_init_once

  while true; do
    clear -x
    echo -e "${cyan}--- Провайдер / подсказки ---${plain}"
    echo -e "Текущий провайдер: ${green}${PROVIDER_MENU}${plain}"
    echo ""

    submenu_item "1" "Указать провайдера вручную"
    submenu_item "2" "Определить провайдера заново (сбросить кэш)"
    submenu_item "3" "Обновить базу рекомендаций (подсказки)"
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans

    case "$ans" in
      "1")
        provider_set_manual_menu
        sleep 1
        pause_enter
        ;;
      "2")
        provider_force_redetect
        sleep 1
        pause_enter
        ;;
      "3")
        echo "Обновляем базу рекомендаций..."
        rm -f "$RECS_FILE"
        update_recommendations
        if [ -s "$RECS_FILE" ]; then
          echo -e "${green}База успешно обновлена!${plain}"
        else
          echo -e "${red}Ошибка обновления базы.${plain}"
        fi
        sleep 1
        pause_enter
        ;;
      "0"|"")
        return
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

# Подменю настроек WireGuard (вызывается из пункта 19 "Дополнительные настройки").
# Проверяет наличие блока стратегий WireGuard и объявления blob fakewgblob в конфиге.
# Если их нет — предлагает обновить конфиг через пункт 5 главного меню.
wireguard_submenu() {
  while true; do
    local cfg="/opt/zapret2/config"
    local has_wg_block=0
    local current_repeats=""
    local current_blob=""
    local wg_block=""

    clear -x
    [ ! -f "$cfg" ] && cfg="/opt/zapret2/config.default"

    if [ -f "$cfg" ]; then
      wg_block="$(sed -n '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/p' "$cfg")"
      if printf "%s\n" "$wg_block" | grep -q -- '--filter-l7=wireguard' &&
         printf "%s\n" "$wg_block" | grep -q 'blob=fakewgblob:repeats=' &&
         grep -qE -- '--blob=fakewgblob:@/opt/(zapret2|zator)/files/fake/wg_initial_fake_' "$cfg"; then
        has_wg_block=1
      fi
      current_repeats="$(sed -n -E 's#.*blob=fakewgblob:repeats=([0-9]+).*#\1#p' "$cfg" | head -n1)"
      current_blob="$(sed -n -E 's#.*--blob=fakewgblob:@/opt/(zapret2|zator)/files/fake/([^[:space:]]+).*#\2#p' "$cfg" | head -n1)"
    fi

    echo -e "${cyan}--- Настройки WireGuard ---${plain}"
    echo ""

    if [ "$has_wg_block" -eq 0 ]; then
      echo -e "${red}В конфиге не найден блок стратегий WireGuard или объявление blob fakewgblob.${plain}"
      echo -e "${yellow}Обновите конфиг через пункт 5 главного меню, чтобы появились настройки WireGuard.${plain}"
      echo ""
      submenu_item "0" "Назад"
      echo ""
      read -re -p "Ваш выбор: " ans
      case "$ans" in
        "0"|"")
          return
          ;;
        *)
          ui_invalid_input
          ;;
      esac
      continue
    fi

    [ -z "$current_repeats" ] && current_repeats="не определено"
    [ -z "$current_blob" ] && current_blob="не найден"

    echo -e "${yellow}Стратегия WireGuard обнаружена в конфиге.${plain}"
    echo -e "${yellow}Количество повторов (repeats): ${plain}${current_repeats}"
    echo -e "${yellow}Файл blob: ${plain}${current_blob}"
    echo ""
    submenu_item "1" "Изменить количество повторов (repeats)"
    submenu_item "2" "Сменить blob для WireGuard"
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans
    case "$ans" in
      "1")
        menu_action_wg_repeats || true
        ;;
      "2")
        menu_action_set_wg_blob || true
        ;;
      "0"|"")
        return
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

advanced_settings_submenu() {
  while true; do
    local current_state current_value current_color
    local wg_block wg_value wg_color
    local quic_block quic_value quic_color
    local keenetic_status keenetic_color
    clear -x
    current_state="$(config_mode_text reasm_disable /opt/zapret2/config)"
    if [ "$current_state" = "включено" ]; then
      current_value="активирован"; current_color="red"
    elif [ "$current_state" = "выключено" ]; then
      current_value="отсутствует"; current_color="green"
    else
      current_value="недоступно"; current_color="yellow"
    fi

    wg_block="$(sed -n '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/p' /opt/zapret2/config 2>/dev/null)"
    if printf "%s\n" "$wg_block" | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-l7=wireguard[[:space:]]*$'; then
      wg_value="выключено"; wg_color="red"
    elif printf "%s\n" "$wg_block" | grep -q -- '--filter-l7=wireguard'; then
      wg_value="включено"; wg_color="green"
    else
      wg_value="недоступно"; wg_color="yellow"
    fi

    quic_block="$(sed -n '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/p' /opt/zapret2/config 2>/dev/null)"
    if printf "%s\n" "$quic_block" | grep -Eq '^[[:space:]]*--filter-udp=443[[:space:]]*$'; then
      quic_value="включено"; quic_color="green"
    elif printf "%s\n" "$quic_block" | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-udp=443[[:space:]]*$'; then
      quic_value="выключено"; quic_color="red"
    else
      quic_value="недоступно"; quic_color="yellow"
    fi

    echo -e "${cyan}--- Дополнительные настройки ---${plain}"
    echo ""
    echo "Параметр --reasm-disable отключает склейку больших пакетов для анализа средствами NFQWS2."
    echo "Он нужен только если на роутере не удается отключить аппаратное ускорение: NFQWS2 задерживает первый пакет, роутер отправляет второй напрямую, и соединение ломается."
    echo -e "Проверка: откройте в новом инкогнито-окне ${cyan}https://img.reg.ru/news/showcase-main-page__hero-slider_image_domains.webp${plain}"
    echo "Если картинка открывается, параметр обычно не нужен. Проблема чаще актуальна на Keenetic/Netcraze."
    echo ""

    submenu_status_item "1" "Параметр --reasm-disable." "$current_value" "$current_color"
    submenu_status_item "2" "Включить/выключить стратегию WireGuard." "$wg_value" "$wg_color"
    submenu_status_item "3" "Настройки WireGuard (повторы и blob)"
    submenu_status_item "4" "Фейки для всех QUIC-initial на 443 порту." "$quic_value" "$quic_color"
    if keenetic_policy_ndmc_is_supported; then
      keenetic_status="$(get_keenetic_policy_status)"
      case "$keenetic_status" in
        "Не задана"|"") keenetic_color="yellow" ;;
        *) keenetic_color="green" ;;
      esac
      submenu_status_item "5" "Настройка Keenetic-политики для nfqws2." "$keenetic_status" "$keenetic_color"
    fi
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans
    case "$ans" in
      "1")
        if menu_action_toggle_reasm_disable; then
          if pidof nfqws2 >/dev/null; then
            z2r_service_action restart
            echo -e "${green}zapret2 перезапущен для применения изменений.${plain}"
          fi
        fi
        pause_enter
        ;;
      "2")
        menu_action_toggle_wireguard_fake || true
        ;;
      "3")
        wireguard_submenu || true
        ;;
      "4")
        menu_action_toggle_quic443_fake || true
        ;;
      "5")
        if keenetic_policy_ndmc_is_supported; then
          keenetic_policy_submenu
        fi
        ;;
      "0"|"")
        return
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

keenetic_policy_submenu() {
  while true; do
    clear -x
    echo -e "${cyan}--- Keenetic Policy ---${plain}"
    echo -e "Текущее состояние: ${green}$(get_keenetic_policy_status)${plain}"
    echo ""
    submenu_item "1" "Задать или очистить имя политики"
    submenu_item "2" "$( [ "$(get_keenetic_policy_mode_label)" = "Все, кроме устройств из политики" ] && echo 'Переключить режим на "Только устройства из политики"' || echo 'Переключить режим на "Все, кроме устройств из политики"' )"
    submenu_item "0" "Назад"
    echo ""
    read -re -p "Ваш выбор: " ans
    case "$ans" in
      "1") menu_action_set_keenetic_policy_name; pause_enter ;;
      "2") menu_action_toggle_keenetic_policy_mode; pause_enter ;;
      "0"|"") return ;;
      *) ui_invalid_input ;;
    esac
  done
}

backup_submenu() {
  # $1 (block_full) — 1 = контекст обновления: в восстановлении скрывается режим
  # «Полное» (защита обновлённого config). По умолчанию 0 (все режимы доступны).
  local block_full="${1:-0}"
  local count
  while true; do
    clear -x
    count="$(backup_count_archives)"
    echo -e "${cyan}--- Управление бэкапами ---${plain}"
    echo -e "${yellow}Каталог: ${plain}${green}/opt/zator_backup${plain}"
    echo -e "${yellow}Архивов: ${plain}${green}${count}${plain}"
    if [ "$block_full" = "1" ]; then
      echo -e "${yellow}Режим: контекст обновления (полное восстановление заблокировано).${plain}"
    fi
    echo ""
    submenu_item "1" "Создать новый бэкап"
    submenu_item "2" "Восстановить из бэкапа"
    submenu_item "3" "Удалить старые бэкапы"
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans

    case "$ans" in
      "1")
        menu_action_backup_create || true
        ;;
      "2")
        menu_action_backup_restore "" "$block_full" || true
        pause_enter
        ;;
      "3")
        menu_action_backup_delete || true
        ;;
      "0"|"")
        return
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

beginner_guide_menu() {
  clear -x
  echo -e "${Bblue}${Fplain} Не знаешь, с чего начать? Есть проблемы? ${plain}"
  echo ""
  echo -e "${Fcyan}Что делает проект${plain}"
  echo -e "z2r устанавливает и настраивает zapret2 в ${yellow}/opt/zapret2${plain} (бинарники и ${yellow}config${plain}),"
  echo -e "а весь zator-контент (списки, fake payload'ы, стратегии, lua, webui) держит отдельно в ${yellow}/opt/zator${plain},"
  echo -e "чтобы обновление zapret2 не затрагивало настройки. Дальше меню помогает"
  echo -e "перезапускать zapret2, переключать режимы и подбирать рабочие стратегии под"
  echo -e "конкретного провайдера и устройство."
  echo ""

  echo -e "${Fcyan}Обязательные шаги перед подбором${plain}"
  echo -e "${Fyellow}1.${plain} Настрой DoH/DoT на роутере или устройствах."
  echo -e "   РКН подменяет адреса при использовании незащищённых DNS. После смены DNS перезапусти"
  echo -e "   браузер или устройство, чтобы старый DNS-кэш не мешал проверкам."
  echo -e "${Fyellow}2.${plain} На Windows включи TCP timestamps в командной строке (CMD) от имени администратора:"
  echo -e "   ${green}netsh interface tcp set global timestamps=enabled${plain}"
  echo -e "   После команды лучше перезагрузиться."
  echo -e "${Fyellow}3.${plain} Проверь, что время и дата на роутере и клиенте выставлены правильно."
  echo -e "   Неверное время ломает TLS и делает диагностику бессмысленной."
  echo -e "${Fyellow}4.${plain} Не смешивай много изменений сразу: поменял стратегию - проверь сервис вручную."
  echo ""

  echo -e "${Fcyan}Где подбирать стратегии${plain}"
  echo -e "Подбор спрятан в ${Fyellow}пункте 1${plain} главного меню:"
  echo -e "${green}Фиксация стратегии профиля/безразборного блока${plain}."
  echo -e "Внутри профили уже разделены по сервисам и протоколам."
  echo -e "Выбери тот который нужно настроить и запустится перебор стратегий."
  echo ""

  echo -e "${Fcyan}Порядок для YouTube${plain}"
  echo -e "${Fyellow}1.${plain} Сначала подбери профиль 1: ${green}TCP 80/443 (YouTube)${plain}."
  echo -e "Он отвечает за загрузку самого сайта Youtube.com."
  echo -e "${Fyellow}2.${plain} Потом профиль 2: ${green}TCP 80/443 (Googlevideo)${plain}."
  echo -e "Он отвечает за загрузку видео на большинстве устройств"
  echo -e "${Fyellow}3.${plain} Потом опционально профиль 5: ${green}UDP 443 (YouTube QUIC)${plain}."
  echo -e "   QUIC обычно нужен для мобильных устройств, но и браузер также будет его использовать, если он работает"
  echo -e "   Но если YouTube уже стабильно работает, то QUIC можно не трогать."
  echo ""

  echo -e "${Fcyan}Порядок для Discord${plain}"
  echo -e "${Fyellow}1.${plain} Сначала настрой профиль 4: ${green}TCP 80/443 (Discord)${plain}."
  echo -e "   Добейся, чтобы сайт или приложение открывались и логинились."
  echo -e "Как правило, этого достаточно для полноценной работоспособности Discord"
  echo -e "${Fyellow}2.${plain} Если не работает голосовая связь, то тебе поможет профиль 6: ${green}UDP Voice (Discord/STUN)${plain}."
  echo -e "   Это отдельная настройка для голосовой связи."
  echo ""

  echo -e "${Fcyan}Управление доменами (Пункт 6 главного меню)${plain}"
  echo -e "Раздел позволяет гибко настраивать обход или исключение для конкретных сайтов:"
  echo -e "${Fyellow}1.${plain} Исключения (${green}netrogat.txt${plain}) — белый список. Внеси сюда домены (например, Госуслуги, банки),"
  echo -e "   которые должны идти напрямую, мимо всех механизмов обхода zapret2."
  echo -e "${Fyellow}2.${plain} Обработка RKN (${green}TCP_Custom${plain}) — кастомный список сайтов. Нужен, если сайта нет в стандартных"
  echo -e "   списках, но доступ к нему заблокирован провайдером."
  echo -e "   При добавлении домена доступны два режима:"
  echo -e "   - ${yellow}Только добавить:${plain} сайт будет обрабатываться общей для RKN-профиля стратегией (Профиль 3)."
  echo -e "   - ${yellow}Добавить и подобрать стратегию:${plain} запустить индивидуальный перебор. Для этого конкретного"
  echo -e "     домена зафиксируется личная рабочая стратегия, даже если общая стратегия RKN для него не подходит."
  echo ""

  echo -e "${Fcyan}Полезные ориентиры${plain}"
  echo -e "- Пункт 16 меняет TLS blob; пробуй его, если TLS-профили работают нестабильно или не работают вовсе."
  echo -e "- Fallback/безразборный режим помогает в случаях когда нужно получить доступ ко множеству сайтов которых нет в списке RKN"
  echo -e "  Начни с 26 стратегии для безразборного режима. Она самая универсальная."
  echo -e "${Fcyan}Пункт 19 — Дополнительные настройки${plain}"
  echo -e "- ${green}--reasm-disable${plain}: отключает склейку больших пакетов для анализа. Нужен только на роутерах"
  echo -e "  (Keenetic/Netcraze), где не удаётся выключить аппаратное ускорение и из-за этого ломаются соединения."
  echo -e "- ${green}WireGuard${plain}: ТСПУ/DPI умеют распознавать и блокировать рукопожатие WireGuard по характерной сигнатуре."
  echo -e "  Стратегия отправляет ДО настоящего начального пакета несколько фейковых (repeats = их количество),"
  echo -e "  чтобы сбить с толку ТСПУ и пропустить реальное рукопожатие. Здесь можно включить/выключить стратегию,"
  echo -e "  поменять количество фейков (repeats, 2-99) и выбрать другой blob-файл (wg_initial_fake_*)."
  echo -e "  ${Fyellow}Важно:${plain} UDP-порт WireGuard должен перехватываться nfqws2 — если его нет в диапазоне"
  echo -e "  NFQWS2_PORTS_UDP, добавь порт через пункт 20 (Управление портами NFQWS2)."
  echo -e "- ${green}Фейки для QUIC-initial на 443${plain}: подмена начальных QUIC-пакетов на 443 порту."
  echo -e "${Fyellow}Важно:${plain} после любых изменений конфигурации не забывай перезапускать zapret2"
  echo -e "  (пункт 22 главного меню), иначе правки не вступят в силу."
  echo -e "- После обновления стратегий пунктом 5 старые списки подбора могут сброситься;"
  echo -e "  если есть рабочая схема, перед обновлением соглашайся на бэкап."
  echo ""
  pause_enter
}
