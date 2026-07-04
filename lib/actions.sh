backup_strats() {
  # Бэкап папки стратегий
  if [ -d /opt/zapret2/extra_strats ]; then
    echo -e "${yellow}Сделать бэкап /opt/zapret2/extra_strats ?${plain}"
    echo -e "${yellow}5 - Да, Enter - Нет, 0 - отмена${plain}"
    read -r ans
    if [ "$ans" = "0" ]; then
        get_menu # сигнал “отмена/в меню”
    fi
    if [ "$ans" = "5" ] || [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
      touch /opt/zapret2/extra_strats/TCP_Custom.txt 2>/dev/null || true
      rm -rf /opt/extra_strats 2>/dev/null || true
      cp -rf /opt/zapret2/extra_strats /opt/ || true
      if [ -f /opt/zapret2/extra_strats/TCP_Custom.txt ] && [ ! -f /opt/extra_strats/TCP_Custom.txt ]; then
        cp -f /opt/zapret2/extra_strats/TCP_Custom.txt /opt/extra_strats/TCP_Custom.txt 2>/dev/null || true
      fi
      echo -e "${green}Бэкап extra_strats сохранён в /opt/extra_strats${plain}"
    fi
  fi

  # Бэкап листа исключений
  if [ -f /opt/zapret2/lists/netrogat.txt ]; then
    echo -e "${yellow}Сделать бэкап /opt/zapret2/lists/netrogat.txt ?${plain}"
    echo -e "${yellow}5 - Да, Enter - Нет, 0 - отмена и выход в меню${plain}"
    read -r ans2
    if [ "$ans2" = "0" ]; then
      get_menu
    fi
    if [ "$ans2" = "5" ] || [ "$ans2" = "y" ] || [ "$ans2" = "Y" ]; then
      cp -f /opt/zapret2/lists/netrogat.txt /opt/netrogat.txt || true
      echo -e "${green}Бэкап netrogat.txt сохранён в /opt/netrogat.txt${plain}"
    fi
  fi

  return 0
}


menu_action_update_config_reset() {
  echo -e "${yellow}Конфиг обновлен (UTC +0): $(curl -s "https://api.github.com/repos/AloofLibra/zator/commits?path=config.default&per_page=1" | grep '"date"' | head -n1 | cut -d'"' -f4) ${plain}"

  backup_strats

  "$ZAPRET2_INIT" stop

  rm -rf /opt/zapret2/lists /opt/zapret2/extra_strats

  rm -f /opt/zapret2/files/fake/http_fake_MS.bin \
        /opt/zapret2/files/fake/quic_{1..7}.bin \
        /opt/zapret2/files/fake/syn_packet.bin \
        /opt/zapret2/files/fake/tls_clienthello_{1..18}.bin \
        /opt/zapret2/files/fake/tls_clienthello_2n.bin \
        /opt/zapret2/files/fake/tls_clienthello_6a.bin \
        /opt/zapret2/files/fake/tls_clienthello_4pda_to.bin

  get_repo

  if [ ! -f /opt/zapret2/files/fake/custom_tls.bin ]; then
    mkdir -p /opt/zapret2/files/fake
    if ! z2r_download_project_file /opt/zapret2/files/fake/custom_tls.bin "fake/custom_tls.bin"; then
      echo -e "${yellow}Не удалось скачать custom_tls.bin: нет curl/wget.${plain}"
    fi
  fi

  # Раскомменчивание юзера под keenetic или merlin
  change_user
  # На Keenetic автоматически подставляем WAN интерфейс в свежий шаблон конфига.
  if [ "$hardware" = "keenetic" ]; then
    config_keenetic_set_wan_iface /opt/zapret2/config.default
  fi

  cp -f /opt/zapret2/config.default /opt/zapret2/config
  # После копирования синхронизируем рабочий конфиг, чтобы reset не терял IFACE_WAN.
  if [ "$hardware" = "keenetic" ]; then
    config_keenetic_set_wan_iface /opt/zapret2/config
  fi

  "$ZAPRET2_INIT" start

  # ВАЖНО: check_access_list — это по сути интерактивный тест (он сам печатает и может ждать Enter),
  # поэтому лучше вызывать его из get_menu отдельным пунктом ("01"), а не тут.
  # check_access_list

  echo -e "${green}Config файл обновлён. Листы подбора стратегий и исключений сброшены в дефолт, если не просили сохранить. Фейк файлы обновлены.${plain}"
  return 0
}

menu_action_toggle_bolvan_ports() {
  local cfg="/opt/zapret2/config"
  local voice_ports_csv="50000-50099,1400,3478-3481,5349,19294-19344"
  local current_ports new_ports
  local init_dir custom_dir

  if [ ! -f "$cfg" ]; then
    echo -e "${red}Не найден $cfg.${plain}"
    return 1
  fi

  init_dir="$(dirname "$ZAPRET2_INIT")"
  custom_dir="$init_dir/custom.d"
  current_ports="$(sed -n 's/^NFQWS2_PORTS_UDP=//p' "$cfg" | head -n1)"

  if ! printf "%s" "$current_ports" | grep -Eq '(^|,)50000-50099(,|$)'; then
    new_ports="$(csv_add_tokens "${current_ports:-443}" "$voice_ports_csv")"
    sed -i "s/^NFQWS2_PORTS_UDP=.*/NFQWS2_PORTS_UDP=$new_ports/" "$cfg"
    sed -i '/#Стратегии для голосовой связи/,/^[[:space:]]*--new[[:space:]]*$/ s/^--skip[[:space:]]\+--filter-udp=/--filter-udp=/' "$cfg"

    rm -f "$custom_dir/50-discord-media" \
          "$custom_dir/50-stun4all"

    echo -e "${green}Включён 6 блок конфига для голосовой связи. Скрипты bol-van отключены.${plain}"

  elif printf "%s" "$current_ports" | grep -Eq '(^|,)50000-50099(,|$)'; then
    new_ports="$(csv_remove_tokens "$current_ports" "$voice_ports_csv")"
    [ -n "$new_ports" ] || new_ports="443"
    sed -i "s/^NFQWS2_PORTS_UDP=.*/NFQWS2_PORTS_UDP=$new_ports/" "$cfg"
    sed -i '/#Стратегии для голосовой связи/,/^[[:space:]]*--new[[:space:]]*$/ s/^--filter-udp=/--skip --filter-udp=/' "$cfg"

    z2r_install_bolvan_voice_scripts "$custom_dir" || return 1

    echo -e "${green}Включены скрипты bol-van 50-discord-media/50-stun4all. 6 блок конфига отключён через --skip.${plain}"
  else
    echo -e "${yellow}Неизвестное состояние строки NFQWS2_PORTS_UDP. Проверь конфиг вручную.${plain}"
    return 0
  fi

  "$ZAPRET2_INIT" restart
  echo -e "${green}Выполнение переключений завершено.${plain}"
  return 0
}

menu_action_toggle_fwtype() {
  local cfg
  cfg="$(get_config_file)"
  if [ "$(config_get_var "$cfg" FWTYPE)" = "iptables" ]; then
    config_set_var "$cfg" FWTYPE nftables
    /opt/zapret2/install_prereq.sh
    "$ZAPRET2_INIT" restart
    echo -e "${green}Zapret moode: nftables.${plain}"

  elif [ "$(config_get_var "$cfg" FWTYPE)" = "nftables" ]; then
    config_set_var "$cfg" FWTYPE iptables
    /opt/zapret2/install_prereq.sh
    "$ZAPRET2_INIT" restart
    echo -e "${green}Zapret moode: iptables.${plain}"

  else
    echo -e "${yellow}Неизвестное состояние строки FWTYPE. Проверь конфиг вручную.${plain}"
  fi

  return 0
}

menu_action_toggle_udp_range() {
  local cfg current_ports new_ports
  cfg="$(get_config_file)"
  current_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"

  if ! printf "%s" "$current_ports" | grep -Eq '(^|,)1026-65531(,|$)'; then
    new_ports="$(csv_add_tokens "" "1026-65531,${current_ports:-443}")"
    config_set_var "$cfg" NFQWS2_PORTS_UDP "$new_ports"
    sed -i '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/ s/^--skip[[:space:]]\+--filter-udp=1026/--filter-udp=1026/' "$cfg"
    echo -e "${green}Стратегия UDP обхода активирована. Выделены порты 1026-65531${plain}"

  elif printf "%s" "$current_ports" | grep -Eq '(^|,)1026-65531(,|$)'; then
    new_ports="$(csv_remove_token "$current_ports" "1026-65531")"
    [ -n "$new_ports" ] || new_ports="443"
    config_set_var "$cfg" NFQWS2_PORTS_UDP "$new_ports"
    sed -i '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/ s/^--filter-udp=1026/--skip --filter-udp=1026/' "$cfg"
    echo -e "${green}Стратегия UDP обхода ДЕактивирована. Выделенные порты 1026-65531 убраны${plain}"

  else
    echo -e "${yellow}Неизвестное состояние строки NFQWS2_PORTS_UDP. Проверь конфиг вручную.${plain}"
    return 0
  fi

  "$ZAPRET2_INIT" restart
  echo -e "${green}Выполнение переключений завершено.${plain}"
  return 0
}

menu_action_toggle_reasm_disable() {
  local cfg="/opt/zapret2/config"
  local state

  if [ ! -f "$cfg" ]; then
    echo -e "${red}Файл конфигурации не найден: $cfg${plain}"
    echo -e "${yellow}Пожалуйста, убедитесь, что zapret2 установлен и настроен.${plain}"
    return 1
  fi

  state="$(config_mode_text reasm_disable "$cfg")"

  if [ "$state" = "включено" ]; then
    sed -i '/^[[:space:]]*--reasm-disable[[:space:]]*$/d' "$cfg" || return 1
    echo -e "Параметр --reasm-disable: ${green}деактивирован${plain}."
  else
    if ! grep -q '^NFQWS2_OPT="' "$cfg"; then
      echo -e "${red}Не найден блок NFQWS2_OPT в $cfg.${plain}"
      return 1
    fi
    sed -i '/^NFQWS2_OPT="/a --reasm-disable' "$cfg" || return 1
    echo -e "Параметр --reasm-disable: ${red}активирован${plain}."
  fi

  return 0
}

menu_action_set_tls_blob() {
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zapret2/files/fake"
  local prefix="--blob=maxru:@/opt/zapret2/files/fake/"
  local sed_ereg="-E"
  local current_blob=""
  local current_mode=""
  local has_tls_maxru=0
  local has_tls_default=0
  local blobs=()
  local i=0
  local choice=""
  local selected_blob=""

  if [ ! -f "$cfg" ]; then
    cfg="/opt/zapret2/config.default"
  fi
  if [ ! -f "$cfg" ]; then
    echo -e "${red}Не найден config/config.default.${plain}"
    pause_enter
    return 1
  fi

  if [ ! -d "$fake_dir" ]; then
    echo -e "${red}Каталог $fake_dir не найден.${plain}"
    pause_enter
    return 1
  fi

  if ! printf "x" | sed -E 's/x/x/' >/dev/null 2>&1; then
    sed_ereg="-r"
  fi

  if sort -z </dev/null >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      blobs+=("$(basename "$f")")
    done < <(find "$fake_dir" -maxdepth 1 -type f -name '*.bin' -print0 | sort -z)
  else
    while IFS= read -r f; do
      blobs+=("$(basename "$f")")
    done < <(find "$fake_dir" -maxdepth 1 -type f -name '*.bin' | sort)
  fi

  if [ "${#blobs[@]}" -eq 0 ]; then
    echo -e "${red}В $fake_dir нет .bin файлов.${plain}"
    pause_enter
    return 1
  fi

  current_blob="$(sed -n -E 's#.*--blob=maxru:@/opt/zapret2/files/fake/([^[:space:]]+).*#\1#p' "$cfg" | head -n1)"
  [ -z "$current_blob" ] && current_blob="не найден в конфиге"
  if awk '
      /--lua-desync=/ && /blob=maxru/ && $0 !~ /strategy=26/ {found=1}
      END {exit(found?0:1)}
    ' "$cfg"; then
    has_tls_maxru=1
  fi
  if awk '
      /--lua-desync=/ && /blob=fake_default_tls/ && $0 !~ /strategy=26/ {found=1}
      END {exit(found?0:1)}
    ' "$cfg"; then
    has_tls_default=1
  fi

  if [ "$has_tls_maxru" -eq 1 ] && [ "$has_tls_default" -eq 0 ]; then
    current_mode="maxru (внешний файл)"
  elif [ "$has_tls_default" -eq 1 ] && [ "$has_tls_maxru" -eq 0 ]; then
    current_mode="fake_default_tls (встроенный)"
  elif [ "$has_tls_default" -eq 1 ] && [ "$has_tls_maxru" -eq 1 ]; then
    current_mode="mixed"
  else
    current_mode="не определён"
  fi

  echo -e "${yellow}Текущий режим blob: ${plain}${current_mode}"
  echo -e "${yellow}Текущий файл для maxru: ${plain}${current_blob}"
  echo -e "${yellow}Выберите blob для TLS-стратегий:${plain}"
  echo "1. fake_default_tls (встроенный)"
  i=1
  for b in "${blobs[@]}"; do
    i=$((i+1))
    echo "$i. $b"
  done
  echo "0. Отмена"
  read -re -p "Ваш выбор: " choice

  if [ "$choice" = "0" ] || [ -z "$choice" ]; then
    echo "Отменено."
    pause_enter
    return 0
  fi
  if ! printf "%s" "$choice" | grep -Eq '^[0-9]+$'; then
    echo -e "${red}Некорректный выбор.${plain}"
    pause_enter
    return 1
  fi
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "$(( ${#blobs[@]} + 1 ))" ]; then
    echo -e "${red}Номер вне диапазона.${plain}"
    pause_enter
    return 1
  fi

  if [ "$choice" -eq 1 ]; then
    if [ "$sed_ereg" = "-E" ]; then
      sed -i -E '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)maxru#\1fake_default_tls#g; }' "$cfg"
    else
      sed -i -r '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)maxru#\1fake_default_tls#g; }' "$cfg"
    fi
    echo -e "${green}В TLS-стратегиях выбран встроенный blob: fake_default_tls${plain}"
    echo -e "${yellow}Строка --blob=maxru:@... сохранена без изменений для обратного переключения.${plain}"
    pause_enter
    return 0
  fi

  selected_blob="${blobs[$((choice-2))]}"

  if ! grep -q -- "--blob=maxru:@/opt/zapret2/files/fake/" "$cfg"; then
    echo -e "${red}Строка --blob=maxru:@/opt/zapret2/files/fake/... не найдена в $cfg${plain}"
    pause_enter
    return 1
  fi

  if [ "$sed_ereg" = "-E" ]; then
    sed -i -E '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)fake_default_tls#\1maxru#g; }' "$cfg"
    sed -i -E "s#(${prefix})[^[:space:]]+#\\1${selected_blob}#g" "$cfg"
  else
    sed -i -r '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)fake_default_tls#\1maxru#g; }' "$cfg"
    sed -i -r "s#(${prefix})[^[:space:]]+#\\1${selected_blob}#g" "$cfg"
  fi
  echo -e "${green}Обновлено: --blob=maxru -> ${selected_blob}${plain}"
  echo -e "${yellow}Перезапустите zapret2 (пункт 2 меню), чтобы применить изменения.${plain}"
  pause_enter
  return 0
}

# Переключатель стратегии WireGuard. По умолчанию блок выключен через --skip.
menu_action_toggle_wireguard_fake() {
  local cfg
  local wg_block

  if ! cfg="$(get_config_file)"; then
    echo -e "${red}Не найден config/config.default.${plain}"
    pause_enter
    return 1
  fi

  wg_block="$(sed -n '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/p' "$cfg")"
  if ! printf "%s\n" "$wg_block" | grep -q -- '--filter-l7=wireguard'; then
    echo -e "${red}В конфиге не найден блок WireGuard.${plain}"
    echo -e "${yellow}Обновите конфиг через пункт 5 главного меню.${plain}"
    pause_enter
    return 1
  fi

  if printf "%s\n" "$wg_block" | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-l7=wireguard[[:space:]]*$'; then
    sed -i '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/ s/^[[:space:]]*--skip[[:space:]]\+--filter-l7=wireguard/--filter-l7=wireguard/' "$cfg"
    echo -e "${green}Стратегия WireGuard ВКЛЮЧЕНА (--skip удалён).${plain}"
  else
    sed -i '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/ s/^[[:space:]]*--filter-l7=wireguard/--skip --filter-l7=wireguard/' "$cfg"
    echo -e "${green}Стратегия WireGuard ВЫКЛЮЧЕНА (--skip добавлен).${plain}"
  fi
  echo -e "${yellow}Для применения изменений перезапустите zapret2: пункт 22 главного меню.${plain}"
  pause_enter
  return 0
}

# Изменение количества повторов (repeats) для стратегии WireGuard.
# Диапазон: 2..99. Меняет только строку blob=fakewgblob:repeats=N.
menu_action_wg_repeats() {
  local cfg
  local sed_ereg="-E"
  local current_repeats=""
  local new_repeats=""

  if ! cfg="$(get_config_file)"; then
    echo -e "${red}Не найден config/config.default.${plain}"
    pause_enter
    return 1
  fi

  if ! printf "x" | sed -E 's/x/x/' >/dev/null 2>&1; then
    sed_ereg="-r"
  fi

  if ! grep -q 'blob=fakewgblob:repeats=' "$cfg"; then
    echo -e "${red}В конфиге не найдена строка стратегии WireGuard (blob=fakewgblob:repeats=).${plain}"
    echo -e "${yellow}Обновите конфиг через пункт 5 главного меню, чтобы появились настройки WireGuard.${plain}"
    pause_enter
    return 1
  fi

  current_repeats="$(sed -n -E 's#.*blob=fakewgblob:repeats=([0-9]+).*#\1#p' "$cfg" | head -n1)"
  [ -z "$current_repeats" ] && current_repeats="не определено"

  echo -e "${yellow}Текущее количество повторов WireGuard (repeats): ${plain}${current_repeats}"
  echo -e "${yellow}Введите новое количество повторов (от 2 до 99):${plain}"
  read -re new_repeats

  if [ -z "$new_repeats" ]; then
    echo "Отменено."
    pause_enter
    return 0
  fi
  if ! printf "%s" "$new_repeats" | grep -Eq '^[0-9]+$'; then
    echo -e "${red}Некорректное значение: нужно целое число.${plain}"
    pause_enter
    return 1
  fi
  if [ "$new_repeats" -lt 2 ] || [ "$new_repeats" -gt 99 ]; then
    echo -e "${red}Значение должно быть в диапазоне от 2 до 99.${plain}"
    pause_enter
    return 1
  fi

  if [ "$sed_ereg" = "-E" ]; then
    sed -i -E "s#(blob=fakewgblob:repeats=)[0-9]+#\\1${new_repeats}#g" "$cfg"
  else
    sed -i -r "s#(blob=fakewgblob:repeats=)[0-9]+#\\1${new_repeats}#g" "$cfg"
  fi
  echo -e "${green}Количество повторов WireGuard изменено на ${new_repeats}.${plain}"
  echo -e "${yellow}Для применения изменений перезапустите zapret2: пункт 22 главного меню.${plain}"
  pause_enter
  return 0
}

# Смена blob-файла для стратегии WireGuard.
# Показывает только файлы вида wg_initial_fake_* и позволяет выбрать по номеру.
menu_action_set_wg_blob() {
  local cfg
  local fake_dir="/opt/zapret2/files/fake"
  local prefix="--blob=fakewgblob:@/opt/zapret2/files/fake/"
  local sed_ereg="-E"
  local current_blob=""
  local blobs=()
  local i=0
  local choice=""
  local selected_blob=""

  if ! cfg="$(get_config_file)"; then
    echo -e "${red}Не найден config/config.default.${plain}"
    pause_enter
    return 1
  fi

  if [ ! -d "$fake_dir" ]; then
    echo -e "${red}Каталог $fake_dir не найден.${plain}"
    pause_enter
    return 1
  fi

  if ! printf "x" | sed -E 's/x/x/' >/dev/null 2>&1; then
    sed_ereg="-r"
  fi

  if ! grep -q -- "--blob=fakewgblob:@/opt/zapret2/files/fake/" "$cfg"; then
    echo -e "${red}В конфиге не найдено объявление --blob=fakewgblob:@...${plain}"
    echo -e "${yellow}Обновите конфиг через пункт 5 главного меню, чтобы появились настройки WireGuard.${plain}"
    pause_enter
    return 1
  fi

  # Только файлы, начинающиеся с wg_initial_fake_
  if sort -z </dev/null >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      blobs+=("$(basename "$f")")
    done < <(find "$fake_dir" -maxdepth 1 -type f -name 'wg_initial_fake_*' -print0 | sort -z)
  else
    while IFS= read -r f; do
      blobs+=("$(basename "$f")")
    done < <(find "$fake_dir" -maxdepth 1 -type f -name 'wg_initial_fake_*' | sort)
  fi

  if [ "${#blobs[@]}" -eq 0 ]; then
    echo -e "${red}В $fake_dir нет файлов wg_initial_fake_*.${plain}"
    pause_enter
    return 1
  fi

  current_blob="$(sed -n -E 's#.*--blob=fakewgblob:@/opt/zapret2/files/fake/([^[:space:]]+).*#\1#p' "$cfg" | head -n1)"
  [ -z "$current_blob" ] && current_blob="не найден в конфиге"

  echo -e "${yellow}Текущий blob для WireGuard: ${plain}${current_blob}"
  echo -e "${yellow}Выберите файл blob для WireGuard:${plain}"
  i=0
  for b in "${blobs[@]}"; do
    i=$((i+1))
    echo "$i. $b"
  done
  echo "0. Отмена"
  read -re -p "Ваш выбор: " choice

  if [ "$choice" = "0" ] || [ -z "$choice" ]; then
    echo "Отменено."
    pause_enter
    return 0
  fi
  if ! printf "%s" "$choice" | grep -Eq '^[0-9]+$'; then
    echo -e "${red}Некорректный выбор.${plain}"
    pause_enter
    return 1
  fi
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#blobs[@]}" ]; then
    echo -e "${red}Номер вне диапазона.${plain}"
    pause_enter
    return 1
  fi

  selected_blob="${blobs[$((choice-1))]}"

  if [ "$sed_ereg" = "-E" ]; then
    sed -i -E "s#(${prefix})[^[:space:]]+#\\1${selected_blob}#g" "$cfg"
  else
    sed -i -r "s#(${prefix})[^[:space:]]+#\\1${selected_blob}#g" "$cfg"
  fi
  echo -e "${green}Обновлено: --blob=fakewgblob -> ${selected_blob}${plain}"
  echo -e "${yellow}Для применения изменений перезапустите zapret2: пункт 22 главного меню.${plain}"
  pause_enter
  return 0
}

# Переключатель фейков для всех QUIC-инициализаций на UDP 443 (последний блок конфига).
# Включено/выключено определяется наличием --skip перед --filter-udp=443.
menu_action_toggle_quic443_fake() {
  local cfg
  local quic_block

  if ! cfg="$(get_config_file)"; then
    echo -e "${red}Не найден config/config.default.${plain}"
    pause_enter
    return 1
  fi

  quic_block="$(sed -n '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/p' "$cfg")"
  if ! printf "%s\n" "$quic_block" | grep -Eq '^[[:space:]]*(--skip[[:space:]]+)?--filter-udp=443[[:space:]]*$'; then
    echo -e "${red}В конфиге не найден блок QUIC (UDP443, quic_initial).${plain}"
    echo -e "${yellow}Обновите конфиг через пункт 5 главного меню.${plain}"
    pause_enter
    return 1
  fi

  if printf "%s\n" "$quic_block" | grep -Eq '^[[:space:]]*--filter-udp=443[[:space:]]*$'; then
    # Выключаем: добавляем --skip перед --filter-udp=443
    sed -i '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/ s/^[[:space:]]*--filter-udp=443[[:space:]]*$/--skip --filter-udp=443/' "$cfg"
    echo -e "${green}Фейки для QUIC (UDP443) ВЫКЛЮЧЕНЫ (--skip добавлен).${plain}"
  else
    # Включаем: убираем --skip перед --filter-udp=443
    sed -i '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/ s/^[[:space:]]*--skip[[:space:]]\+--filter-udp=443[[:space:]]*$/--filter-udp=443/' "$cfg"
    echo -e "${green}Фейки для QUIC (UDP443) ВКЛЮЧЕНЫ (--skip удалён).${plain}"
  fi
  echo -e "${yellow}Для применения изменений перезапустите zapret2: пункт 22 главного меню.${plain}"
  pause_enter
  return 0
}

toggle_hostlist_mode() {
  for cfg in /opt/zapret2/config /opt/zapret2/config.default; do
    [ -f "$cfg" ] || continue
    if grep -q '^MODE_FILTER=autohostlist' "$cfg"; then
      sed -i 's/^MODE_FILTER=autohostlist/MODE_FILTER=hostlist/' "$cfg"
      # Disable <HOSTLIST> placeholder for RKN strategy only
      sed -i 's#\(--hostlist=/opt/zapret2/extra_strats/TCP_RKN_list\.txt\) <HOSTLIST>#\1#g' "$cfg"
    elif grep -q '^MODE_FILTER=hostlist' "$cfg"; then
      sed -i 's/^MODE_FILTER=hostlist/MODE_FILTER=autohostlist/' "$cfg"
      # Enable <HOSTLIST> placeholder for RKN strategy only
      sed -i 's#\(--hostlist=/opt/zapret2/extra_strats/TCP_RKN_list\.txt\)#\1 <HOSTLIST>#g' "$cfg"
    fi
  done
}

toggle_fallback_mode() {
  for cfg in /opt/zapret2/config /opt/zapret2/config.default; do
    [ -f "$cfg" ] || continue
    if { sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$cfg"; sed -n '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/p' "$cfg"; } | grep -q '^[[:space:]]*--skip[[:space:]]'; then
      sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^[[:space:]]*--skip[[:space:]]\+//' "$cfg"
      sed -i '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/ s/^[[:space:]]*--skip[[:space:]]\+//' "$cfg"
    else
      sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^[[:space:]]*--filter-tcp=443 --filter-l7=tls/--skip --filter-tcp=443 --filter-l7=tls/' "$cfg"
      sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^[[:space:]]*--filter-tcp=443$/--skip --filter-tcp=443/' "$cfg"
      sed -i '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/ s/^[[:space:]]*--filter-tcp=80 --filter-l7=http/--skip --filter-tcp=80 --filter-l7=http/' "$cfg"
    fi
  done
}

toggle_rst_guard_mode() {
  local cfg="/opt/zapret2/config"
  local enable=1
  local key

  if type rst_guard_lua_update_from_repo >/dev/null 2>&1 && [ ! -s /opt/zapret2/lua/rst-guard.lua ]; then
    rst_guard_lua_update_from_repo || true
  fi

  if [ ! -f "$cfg" ]; then
    echo -e "${red}Не найден $cfg.${plain}"
    return 1
  fi

  if grep -q -- '--lua-desync=rst_guard_locked:key=' "$cfg"; then
    enable=0
  fi

  if [ "$enable" -eq 1 ]; then
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^--filter-tcp=443 --filter-l7=tls$/--filter-tcp=443/' "$cfg"
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^--skip --filter-tcp=443 --filter-l7=tls$/--skip --filter-tcp=443/' "$cfg"
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello$/--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello,empty/' "$cfg"
    for key in 1 2 3 4 8 9; do
      sed -i "s/--lua-desync=circular_locked:key=$key/--lua-desync=rst_guard_locked:key=$key/g" "$cfg"
    done
  else
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^--filter-tcp=443$/--filter-tcp=443 --filter-l7=tls/' "$cfg"
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^--skip --filter-tcp=443$/--skip --filter-tcp=443 --filter-l7=tls/' "$cfg"
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello,empty$/--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello/' "$cfg"
    for key in 1 2 3 4 8 9; do
      sed -i "s/--lua-desync=rst_guard_locked:key=$key/--lua-desync=circular_locked:key=$key/g" "$cfg"
    done
  fi
}

# =============================================================================
# Управление портами NFQWS2_PORTS_TCP / NFQWS2_PORTS_UDP
# =============================================================================
# Пользовательские порты добавляются В НАЧАЛО строк (до дефолтных 80/443),
# через запятую без пробелов.
#
# Пользовательскими считаются ВСЕ порты, стоящие в строке слева от якоря:
#   TCP — слева до порта 80,
#   UDP — слева до порта 443.
# Эти порты читаются прямо из config, их же показываем и удаляем.
# Для TCP дополнительно те же порты добавляются в --filter-tcp блока RKN.
# Для UDP --filter-udp не трогаем.
# После изменений просим пользователя перезапустить zapret2 (пункт 22).

# Человекочитаемая метка протокола.
ports_proto_label() {
  case "$1" in
    tcp) printf 'TCP' ;;
    udp) printf 'UDP' ;;
    *)   printf '%s' "$1" ;;
  esac
}

# Имя переменной в конфиге для протокола.
ports_var() {
  case "$1" in
    tcp) printf 'NFQWS2_PORTS_TCP' ;;
    udp) printf 'NFQWS2_PORTS_UDP' ;;
    *) return 1 ;;
  esac
}

# Якорь разделения: всё слева от него — пользовательские порты.
ports_anchor() {
  case "$1" in
    tcp) printf '80' ;;
    udp) printf '443' ;;
    *) return 1 ;;
  esac
}

# Разбить строку портов по якорю. Результат — в глобальных _PORTS_USER/_PORTS_BASE:
#  _PORTS_USER — всё до якоря (пользовательские порты);
#  _PORTS_BASE — от якоря до конца (дефолтные/системные).
# Если якорь не найден — пользовательская часть пуста, база = вся строка.
ports_split() {
  local line="$1" anchor="$2"
  local arr=() t started=0
  _PORTS_USER=""
  _PORTS_BASE=""
  [ -n "$line" ] && IFS=',' read -ra arr <<< "$line"
  for t in "${arr[@]}"; do
    [ "$started" -eq 0 ] && [ "$t" = "$anchor" ] && started=1
    if [ "$started" -eq 0 ]; then
      [ -n "$t" ] && _PORTS_USER="${_PORTS_USER:+$_PORTS_USER,}$t"
    else
      [ -n "$t" ] && _PORTS_BASE="${_PORTS_BASE:+$_PORTS_BASE,}$t"
    fi
  done
  if [ "$started" -eq 0 ]; then
    _PORTS_BASE="$line"
    _PORTS_USER=""
  fi
}

# Склеить две CSV-части через запятую (пустые опускаются).
ports_join() {
  local a="$1" b="$2"
  if [ -n "$a" ] && [ -n "$b" ]; then printf '%s,%s' "$a" "$b"
  elif [ -n "$a" ]; then printf '%s' "$a"
  else printf '%s' "$b"
  fi
}

# Проверка корректности порта или диапазона (1-65535). 0 - ок, 1 - мусор.
ports_validate() {
  local token="$1" start end
  case "$token" in
    ""|*[!0-9-]*) return 1 ;;  # пусто или недопустимые символы
  esac
  if printf '%s' "$token" | grep -q -- '-'; then
    # диапазон START-END
    start="${token%%-*}"
    end="${token#*-}"
    case "$end" in *-*) return 1 ;; esac  # второй дефис недопустим
    [ -n "$start" ] && [ -n "$end" ] || return 1
    [ "$start" -ge 1 ] 2>/dev/null && [ "$start" -le 65535 ] 2>/dev/null || return 1
    [ "$end"   -ge 1 ] 2>/dev/null && [ "$end"   -le 65535 ] 2>/dev/null || return 1
    [ "$start" -le "$end" ] || return 1
  else
    [ "$token" -ge 1 ] 2>/dev/null && [ "$token" -le 65535 ] 2>/dev/null || return 1
  fi
  return 0
}

# Есть ли точное совпадение токена в CSV-строке? (0 - есть, 1 - нет)
csv_contains_token() {
  local csv="$1" token="$2"
  local arr=() t
  [ -n "$csv" ] || return 1
  IFS=',' read -ra arr <<< "$csv"
  for t in "${arr[@]}"; do
    [ "$t" = "$token" ] && return 0
  done
  return 1
}

# Удалить точное совпадение токена из CSV (печатает результат).
csv_remove_token() {
  local csv="$1" token="$2"
  local arr=() t out=""
  [ -n "$csv" ] || return 0
  IFS=',' read -ra arr <<< "$csv"
  for t in "${arr[@]}"; do
    [ -n "$t" ] || continue
    [ "$t" = "$token" ] && continue
    if [ -z "$out" ]; then out="$t"; else out="$out,$t"; fi
  done
  printf '%s' "$out"
}

csv_add_tokens() {
  local csv="$1" tokens="$2" arr=() tok out="$csv"
  [ -n "$tokens" ] && IFS=',' read -ra arr <<< "$tokens"
  for tok in "${arr[@]}"; do
    [ -n "$tok" ] || continue
    csv_contains_token "$out" "$tok" || out="$(ports_join "$out" "$tok")"
  done
  printf '%s' "$out"
}

csv_remove_tokens() {
  local csv="$1" tokens="$2" arr=() tok out="$csv"
  [ -n "$tokens" ] && IFS=',' read -ra arr <<< "$tokens"
  for tok in "${arr[@]}"; do
    [ -n "$tok" ] && out="$(csv_remove_token "$out" "$tok")"
  done
  printf '%s' "$out"
}

# Записать строку --filter-tcp блока RKN = пользовательские TCP-порты + база из конфига.
# Базовые порты (от якоря 80 и правее) берутся прямо из NFQWS2_PORTS_TCP — без констант.
ports_set_rkn_filter() {
  local cfg="$1" user="$2"
  local tcp_line rkn_ports
  tcp_line="$(config_get_var "$cfg" NFQWS2_PORTS_TCP)"
  ports_split "$tcp_line" "80"
  rkn_ports="$(ports_join "$user" "$_PORTS_BASE")"
  # Диапазон от комментария RKN до ближайшего --new; внутри него меняем
  # единственную строку --filter-tcp=... --filter-l7=tls.
  sed -i "/#Стратегии для RKN/,/^[[:space:]]*--new[[:space:]]*\$/ s/^--filter-tcp=.*--filter-l7=tls[[:space:]]*\$/--filter-tcp=${rkn_ports} --filter-l7=tls/" "$cfg"
}

# Добавление пользовательских портов (tcp|udp).
# Порты добавляются в начало строки (до якоря 80/443) и читаются прямо из config.
ports_add() {
  local proto="$1" cfg="/opt/zapret2/config"
  local var anchor label line input tok added="" skipped=""
  local arr=() new_user

  var="$(ports_var "$proto")" || return 1
  anchor="$(ports_anchor "$proto")"
  label="$(ports_proto_label "$proto")"
  line="$(config_get_var "$cfg" "$var")"
  ports_split "$line" "$anchor"
  new_user="$_PORTS_USER"

  clear -x
  echo -e "${cyan}--- Добавление ${label} портов ---${plain}"
  echo "Порты добавляются В НАЧАЛО строки $var (до дефолтных)."
  if [ "$proto" = "tcp" ]; then
    echo "TCP-порты также попадают в стратегию RKN (--filter-tcp)."
  else
    echo "UDP-порты добавляются только в $var (стратегии не меняются)."
  fi
  echo "Формат: один порт (8080) или диапазон (9000-9100)."
  echo "Несколько значений — через запятую без пробелов: 8080,9090,9000-9100"
  echo ""
  read -re -p "Введите порты: " input
  if [ -n "$input" ]; then
    # убираем любые пробелы
    input="$(printf '%s' "$input" | tr -d '[:space:]')"
    [ -n "$input" ] && IFS=',' read -ra arr <<< "$input"
  fi

  for tok in "${arr[@]}"; do
    [ -n "$tok" ] || continue
    if ! ports_validate "$tok"; then
      skipped="${skipped}${tok},"
      continue
    fi
    # дубликат: уже есть в строке конфига
    if csv_contains_token "$line" "$tok"; then
      skipped="${skipped}${tok},"
      continue
    fi
    new_user="$(ports_join "$new_user" "$tok")"
    added="${added}${tok},"
  done

  if [ -z "$added" ]; then
    echo -e "${yellow}Ничего не добавлено.${plain}"
    [ -n "$skipped" ] && echo -e "${yellow}Пропущено (некорректно/дубликаты): ${skipped%,}${plain}"
    pause_enter
    return 0
  fi

  config_set_var "$cfg" "$var" "$(ports_join "$new_user" "$_PORTS_BASE")"
  [ "$proto" = "tcp" ] && ports_set_rkn_filter "$cfg" "$new_user"

  echo -e "${green}Добавлено ${label}: ${added%,}${plain}"
  [ -n "$skipped" ] && echo -e "${yellow}Пропущено: ${skipped%,}${plain}"
  echo -e "${green}Строка $var: $(config_get_var "$cfg" "$var")${plain}"
  echo -e "${yellow}Для применения изменений перезапустите zapret2: пункт 22 главного меню.${plain}"
  pause_enter
  return 0
}

# Просмотр и удаление пользовательских портов (tcp|udp).
# Показываются только порты слева от якоря (80/443) — их и можно удалить.
ports_manage() {
  local proto="$1" cfg="/opt/zapret2/config"
  local var anchor label line choice confirm i target
  local ports=()

  var="$(ports_var "$proto")" || return 1
  anchor="$(ports_anchor "$proto")"
  label="$(ports_proto_label "$proto")"

  while true; do
    clear -x
    line="$(config_get_var "$cfg" "$var")"
    ports_split "$line" "$anchor"
    ports=()
    [ -n "$_PORTS_USER" ] && IFS=',' read -ra ports <<< "$_PORTS_USER"

    echo -e "${cyan}--- Пользовательские ${label} порты ---${plain}"
    echo -e "Полная строка $var: ${green}$line${plain}"
    echo ""

    if [ "${#ports[@]}" -eq 0 ]; then
      echo -e "${yellow}Нет добавленных ${label} портов.${plain}"
      echo ""
      pause_enter
      return 0
    fi

    echo -e "${yellow}Добавленные порты (можно удалить только эти):${plain}"
    echo ""
    i=1
    for p in "${ports[@]}"; do
      printf "  ${Fcyan}%s.${plain} ${green}%s${plain}\n" "$i" "$p"
      i=$((i+1))
    done
    echo ""
    echo -e "Введите номер порта для удаления, ${Fyellow}0${plain} - назад."
    read -re -p "Ваш выбор: " choice

    case "$choice" in
      "0"|"")
        return 0
        ;;
      *)
        if ! printf '%s' "$choice" | grep -Eq '^[0-9]+$'; then
          echo -e "${red}Некорректный ввод.${plain}"
          sleep 1
          continue
        fi
        if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ports[@]}" ]; then
          echo -e "${red}Номер вне диапазона.${plain}"
          sleep 1
          continue
        fi
        target="${ports[$((choice-1))]}"
        echo ""
        echo -e "${yellow}Удалить порт ${green}${target}${yellow} из строки $var?"
        [ "$proto" = "tcp" ] && echo "(также убирается из стратегии RKN)"
        echo "1 - да, удалить"
        echo "0 - отмена"
        read -re -p "Ваш выбор: " confirm
        case "$confirm" in
          "1")
            local new_user
            new_user="$(csv_remove_token "$_PORTS_USER" "$target")"
            config_set_var "$cfg" "$var" "$(ports_join "$new_user" "$_PORTS_BASE")"
            [ "$proto" = "tcp" ] && ports_set_rkn_filter "$cfg" "$new_user"
            echo -e "${green}Порт ${target} удалён.${plain}"
            echo -e "${green}Строка $var: $(config_get_var "$cfg" "$var")${plain}"
            echo -e "${yellow}Для применения изменений перезапустите zapret2: пункт 22 главного меню.${plain}"
            pause_enter
            ;;
          *)
            echo "Отменено."
            sleep 1
            ;;
        esac
        ;;
    esac
  done
}

# Краткий статус для строки главного меню: сколько портов слева от якорей.
# Необязательный аргумент — путь к конфигу (по умолчанию /opt/zapret2/config).
ports_menu_status() {
  local cfg="${1:-/opt/zapret2/config}"
  local tcp udp n=0 arr=()
  [ -f "$cfg" ] || { printf 'дефолт'; return 0; }
  tcp="$(config_get_var "$cfg" NFQWS2_PORTS_TCP)"
  udp="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
  ports_split "$tcp" "80"
  [ -n "$_PORTS_USER" ] && { IFS=',' read -ra arr <<< "$_PORTS_USER"; n=$((n + ${#arr[@]})); }
  ports_split "$udp" "443"
  [ -n "$_PORTS_USER" ] && { IFS=',' read -ra arr <<< "$_PORTS_USER"; n=$((n + ${#arr[@]})); }
  if [ "$n" -gt 0 ]; then
    printf 'добавлено портов: %s' "$n"
  else
    printf 'дефолт'
  fi
}
