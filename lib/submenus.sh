# submenus.sh
# Единый стиль: loop + return на 0/Enter

#функция меню "1. Сменить стратегии"
strategies_submenu() {
  while true; do
    local strategies_status
    strategies_status=$(get_orchestra_locks_info)
    local p1_max p2_max p3_max p4_max p5_max p6_max p7_max p9_max
    p1_max="$(orch_max_strategy_for_profile 1)"
    p2_max="$(orch_max_strategy_for_profile 2)"
    p3_max="$(orch_max_strategy_for_profile 3)"
    p4_max="$(orch_max_strategy_for_profile 4)"
    p5_max="$(orch_max_strategy_for_profile 5)"
    p6_max="$(orch_max_strategy_for_profile 6)"
    p7_max="$(orch_max_strategy_for_profile 7)"
    p9_max="$(orch_max_strategy_for_profile 9)"
    clear -x

    echo -e "${cyan}--- Управление стратегиями ---${plain}"
    echo -e "${yellow}Выбор стратегии профиля (0 или Enter для выхода)${plain}"
    echo -e "  Текущие стратегии [${strategies_status}]"
    echo -e 

    submenu_item "	1" "Профиль 1: TCP 80/443 (YouTube) [${p1_max:-0}]" "tls"
    submenu_item "	2" "Профиль 2: TCP 80/443 (Googlevideo) [${p2_max:-0}]" "tls"
    submenu_item "	3" "Профиль 3: TCP 80/443 (RKN) [${p3_max:-0}]" "tls"
    submenu_item "	4" "Профиль 4: TCP 80/443 (Discord) [${p4_max:-0}]" "tls"
    submenu_item "	5" "Профиль 5: UDP 443 (YouTube QUIC) [${p5_max:-0}]" "udp"
    submenu_item "	6" "Профиль 6: UDP Voice (Discord/STUN) [${p6_max:-0}]" "udp"
    submenu_item "	7" "Профиль 7: UDP Games (1026-65531) [${p7_max:-0}]" "udp"
    submenu_item "	8" "Fallback TLS (безразборный блок)"
    submenu_item "	9" "Fallback HTTP (безразборный блок) [${p9_max:-0}]"
    submenu_item "	0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans

    case "$ans" in
      "1")
        orch_profile_try "1" "Профиль 1: TCP 80/443 (YouTube)" "tls http" "https://www.youtube.com/"
        ;;
      "2")
        orch_profile_try "2" "Профиль 2: TCP 80/443 (Googlevideo)" "tls" "https://$(get_yt_cluster_domain)"
        ;;
      "3")
        orch_profile_try "3" "Профиль 3: TCP 80/443 (RKN)" "tls" "https://meduza.io"
        ;;
      "4")
        orch_profile_try "4" "Профиль 4: TCP 80/443 (Discord)" "tls" "https://discord.com/"
        ;;
      "5")
        echo -e "${yellow}Проверьте работоспособность в браузере.${plain}"
        orch_profile_try "5" "Профиль 5: UDP 443 (YouTube QUIC)" "udp" ""
        ;;
      "6")
        echo -e "${yellow}Проверьте работоспособность в приложении.${plain}"
        orch_profile_try "6" "Профиль 6: UDP Voice (Discord/STUN)" "udp" ""
        ;;
      "7")
        echo -e "${yellow}Проверьте работоспособность в игре.${plain}"
        orch_profile_try "7" "Профиль 7: UDP Games (1026-65531)" "udp" ""
        ;;
      "8")
        fallback_profile_try
        ;;
      "9")
        fallback_http_profile_try
        ;;
      "0"|"")
        return
        ;;
      *)
        echo -e "${yellow}Неверный ввод.${plain}"
        sleep 1
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
      "0"|"")
        return
        ;;
      *)
        echo -e "${yellow}Неверный ввод.${plain}"
        sleep 1
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
        echo -e "${yellow}Неверный ввод.${plain}"
        sleep 1
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
      "1")
        config_set_var /opt/zapret2/config FLOWOFFLOAD software
        /opt/zapret2/install_prereq.sh
        "$ZAPRET2_INIT" restart
        echo -e "${green}FLOWOFFLOAD=software применён.${plain}"
        pause_enter
        ;;
      "2")
        config_set_var /opt/zapret2/config FLOWOFFLOAD hardware
        /opt/zapret2/install_prereq.sh
        "$ZAPRET2_INIT" restart
        echo -e "${green}FLOWOFFLOAD=hardware применён.${plain}"
        pause_enter
        ;;
      "3")
        config_set_var /opt/zapret2/config FLOWOFFLOAD none
        /opt/zapret2/install_prereq.sh
        "$ZAPRET2_INIT" restart
        echo -e "${green}FLOWOFFLOAD=none применён.${plain}"
        pause_enter
        ;;
      "4")
        config_set_var /opt/zapret2/config FLOWOFFLOAD donttouch
        /opt/zapret2/install_prereq.sh
        "$ZAPRET2_INIT" restart
        echo -e "${green}FLOWOFFLOAD=donttouch применён.${plain}"
        pause_enter
        ;;
      "0"|"")
        return
        ;;
      *)
        echo -e "${yellow}Неверный ввод.${plain}"
        sleep 1
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
  echo -e "\033[33mС каким номером применить стратегию? (1-19, 0 - отключение безразборного режима, Enter - выход) \033[31mПри активации кастомно подобранные домены будут очищены:${plain}"
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
          for f_clear in $(seq 1 19); do
            echo -n > "/opt/zapret2/extra_strats/TCP/User/$f_clear.txt"
            echo -n > "/opt/zapret2/extra_strats/TCP/temp/$f_clear.txt"
          done
          "$ZAPRET2_INIT" restart
          echo -e "${green}Выполнена команда перезапуска zapret. ${yellow}Безразборный режим активирован на $answer_bezr стратегии для TCP-443. Проверка доступа к meduza.io${plain}"
          check_access_list
        else
          config_tcp443_set_strategy 0 "$cfg"
          "$ZAPRET2_INIT" restart
          echo -e "${green}Выполнена команда перезапуска zapret${plain}"
          echo "Безразборный режим отключен"
        fi
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
      else
        echo -e "${yellow}Неверный ввод.${plain}"
        sleep 1
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
        echo -e "${yellow}Неверный ввод.${plain}"
        sleep 1
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

    clear -x
    [ ! -f "$cfg" ] && cfg="/opt/zapret2/config.default"

    if [ -f "$cfg" ]; then
      if wg_config_has_block "$cfg"; then
        has_wg_block=1
      fi
      current_repeats="$(sed -n -E 's#.*blob=fakewgblob:repeats=([0-9]+).*#\1#p' "$cfg" | head -n1)"
      current_blob="$(sed -n -E 's#.*--blob=fakewgblob:@/opt/zapret2/files/fake/([^[:space:]]+).*#\1#p' "$cfg" | head -n1)"
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
          echo -e "${yellow}Неверный ввод.${plain}"
          sleep 1
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
        menu_action_wg_repeats
        ;;
      "2")
        menu_action_set_wg_blob
        ;;
      "0"|"")
        return
        ;;
      *)
        echo -e "${yellow}Неверный ввод.${plain}"
        sleep 1
        ;;
    esac
  done
}

advanced_settings_submenu() {
  while true; do
    local current_state current_label
    local quic_state quic_label
    clear -x
    current_state="$(config_mode_text reasm_disable /opt/zapret2/config)"
    if [ "$current_state" = "включено" ]; then
      current_label="${red}активирован${plain}"
    elif [ "$current_state" = "выключено" ]; then
      current_label="${cyan}отсутствует${plain}"
    else
      current_label="${yellow}недоступно${plain}"
    fi

    quic_state="$(quic443_fake_state /opt/zapret2/config)"
    case "$quic_state" in
      enabled)  quic_label="${green}включено${plain}" ;;
      disabled) quic_label="${red}выключено${plain}" ;;
      *)        quic_label="${yellow}недоступно${plain}" ;;
    esac

    echo -e "${cyan}--- Дополнительные настройки ---${plain}"
    echo ""
    echo "Параметр --reasm-disable отключает склейку больших пакетов для анализа средствами NFQWS2."
    echo "Он нужен только если на роутере не удается отключить аппаратное ускорение: NFQWS2 задерживает первый пакет, роутер отправляет второй напрямую, и соединение ломается."
    echo -e "Проверка: откройте в новом инкогнито-окне ${cyan}https://img.reg.ru/news/showcase-main-page__hero-slider_image_domains.webp${plain}"
    echo "Если картинка открывается, параметр обычно не нужен. Проблема чаще актуальна на Keenetic/Netcraze."
    echo ""

    submenu_item "1" "Параметр --reasm-disable. Сейчас: ${current_label}"
    submenu_item "2" "Настройки WireGuard (повторы и blob)"
    submenu_item "3" "Фейки для всех QUIC-initial на 443 порту. Сейчас: ${quic_label}"
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans
    case "$ans" in
      "1")
        if menu_action_toggle_reasm_disable; then
          if pidof nfqws2 >/dev/null; then
            "$ZAPRET2_INIT" restart
            echo -e "${green}zapret2 перезапущен для применения изменений.${plain}"
          fi
        fi
        pause_enter
        ;;
      "2")
        wireguard_submenu
        ;;
      "3")
        menu_action_toggle_quic443_fake
        ;;
      "0"|"")
        return
        ;;
      *)
        echo -e "${yellow}Неверный ввод.${plain}"
        sleep 1
        ;;
    esac
  done
}

beginner_guide_menu() {
  clear -x
  echo -e "${Bblue}${Fplain} Не знаешь, с чего начать? Есть проблемы? ${plain}"
  echo ""
  echo -e "${Fcyan}Что делает проект${plain}"
  echo -e "z2r устанавливает и настраивает zapret2 в ${yellow}/opt/zapret2${plain}, кладет туда конфиг,"
  echo -e "списки доменов, fake payload'ы и набор стратегий обхода. Дальше меню помогает"
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
  echo -e "   Важно: Для кастомных UDP-стратегий Discord сначала переключи пункт 8 главного меню"
  echo -e "   со стандартных скриптов bol-van на кастомные стратегии для голосовой связи."
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
  echo -e "- Пункт 16 меняет TLS blob; пробуй поиграться с ними, если TLS-профили работают нестабильно или не работают вовсе."
  echo -e "- Fallback/безразборный режим помогает в случаях когда нужно получить доступ ко множеству сайтов которых нет в списке RKN"
  echo -e "  Начни с 26 стратегии для безразборного режима. Она самая универсальная."
  echo -e "- После обновления стратегий пунктом 5 старые списки подбора могут сброситься;"
  echo -e "  если есть рабочая схема, перед обновлением соглашайся на бэкап."
  echo ""
  pause_enter
}
