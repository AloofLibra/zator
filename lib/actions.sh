keenetic_policy_get_mark() {
  local name="$1"
  ndmc -c "show ip policy" 2>/dev/null | awk -v policy="$name" '
    index($0, "name = " policy ",") || index($0, "description = " policy ":") { found=1; next }
    found && /mark[[:space:]]*[:=][[:space:]]*/ {
      sub(/^.*mark[[:space:]]*[:=][[:space:]]*/, "", $0)
      print ($0 ~ /^0x/ ? $0 : "0x" $0)
      exit
    }
  '
}

ensure_keenetic_policy_config() {
  local cfg="${1:-/opt/zapret2/config}"
  [ -f "$cfg" ] || return 1
  grep -q '^POLICY_NAME=' "$cfg" || echo 'POLICY_NAME=' >> "$cfg"
  grep -q '^POLICY_MARK=' "$cfg" || echo 'POLICY_MARK=' >> "$cfg"
  grep -q '^POLICY_EXCLUDE=' "$cfg" || echo 'POLICY_EXCLUDE=0' >> "$cfg"
  sed -i 's|^#\?INIT_FW_POST_UP_HOOK=.*|INIT_FW_POST_UP_HOOK="/opt/zapret2/init.d/sysv/keenetic-policy.sh up"|' "$cfg"
  sed -i 's|^#\?INIT_FW_PRE_DOWN_HOOK=.*|INIT_FW_PRE_DOWN_HOOK="/opt/zapret2/init.d/sysv/keenetic-policy.sh down"|' "$cfg"
}

get_keenetic_policy_name() {
  sed -n 's/^POLICY_NAME=//p' /opt/zapret2/config 2>/dev/null | tail -n1
}

get_keenetic_policy_mode_label() {
  [ "$(sed -n 's/^POLICY_EXCLUDE=//p' /opt/zapret2/config 2>/dev/null | tail -n1)" = "1" ] &&
    echo "Все, кроме устройств из политики" || echo "Только устройства из политики"
}

get_keenetic_policy_status() {
  local name
  name="$(get_keenetic_policy_name)"
  [ -n "$name" ] && echo "$name | $(get_keenetic_policy_mode_label)" || echo "Не задана"
}

menu_action_set_keenetic_policy_name() {
  local name mark=""
  ensure_keenetic_policy_config || return 1
  read -re -p "Введите имя Keenetic-политики. Enter очистит настройку, 0 - отмена: " name
  [ "$name" = "0" ] && { echo "Изменение отменено."; return; }
  case "$name" in *$'\n'*|*'|'*) echo -e "${red}Недопустимое имя политики.${plain}"; return 1;; esac
  if [ -n "$name" ]; then
    mark="$(keenetic_policy_get_mark "$name")"
    [ -n "$mark" ] || { echo -e "${red}Политика '$name' не найдена.${plain}"; return 1; }
  fi
  config_set_var /opt/zapret2/config POLICY_NAME "$name"
  config_set_var /opt/zapret2/config POLICY_MARK "$mark"
  z2r_service_action restart
  [ -n "$name" ] && echo -e "${green}Установлена Keenetic-политика:${plain} $name" || echo -e "${yellow}Ограничение по Keenetic-политике отключено.${plain}"
}

menu_action_toggle_keenetic_policy_mode() {
  local next value
  ensure_keenetic_policy_config || return 1
  value="$(sed -n 's/^POLICY_EXCLUDE=//p' /opt/zapret2/config | tail -n1)"
  [ "$value" = "1" ] && { next=0; value="Только устройства из политики"; } || { next=1; value="Все, кроме устройств из политики"; }
  sed -i "s/^POLICY_EXCLUDE=.*/POLICY_EXCLUDE=$next/" /opt/zapret2/config
  z2r_service_action restart
  echo -e "${green}Режим Keenetic-политики изменён:${plain} $value"
}

menu_action_update_config_reset() {
  echo -e "${yellow}Конфиг обновлен (UTC +0): $(z2r_github_commit_date config.default) ${plain}"

  z2r_service_action stop

  rm -f /opt/zapret2/init.d/{sysv,openwrt}/custom.d/{50-discord-media,50-stun4all}
  rm -rf /opt/zator/lists /opt/zator/extra_strats

  rm -f /opt/zator/files/fake/http_fake_MS.bin \
        /opt/zator/files/fake/quic_{1..7}.bin \
        /opt/zator/files/fake/syn_packet.bin \
        /opt/zator/files/fake/tls_clienthello_{1..18}.bin \
        /opt/zator/files/fake/tls_clienthello_2n.bin \
        /opt/zator/files/fake/tls_clienthello_6a.bin \
        /opt/zator/files/fake/tls_clienthello_4pda_to.bin

  # При сетевом сбое get_repo вернёт 1: отменяем сброс конфига и возвращаем
  # сервис обратно, иначе zapret2 останется остановленным на полуобновлённом состоянии.
  if ! get_repo; then
    echo -e "${red}Не удалось обновить компоненты (сеть). Операция отменена.${plain}"
    z2r_service_action start >/dev/null 2>&1 || true
    return 1
  fi

  if [ ! -f /opt/zator/files/fake/custom_tls.bin ]; then
    mkdir -p /opt/zator/files/fake
    if ! z2r_download_project_file /opt/zator/files/fake/custom_tls.bin "fake/custom_tls.bin"; then
      echo -e "${yellow}Не удалось скачать custom_tls.bin: нет curl/wget.${plain}"
    fi
  fi

  # Раскомменчивание юзера под keenetic или merlin
  change_user
  # На Keenetic автоматически подставляем WAN интерфейс в свежий шаблон конфига.
  if [ "$hardware" = "keenetic" ]; then
    config_keenetic_set_wan_iface /opt/zapret2/config.default
  fi

  profile_apply_all /opt/zapret2/config.default

  cp -f /opt/zapret2/config.default /opt/zapret2/config
  config_client_scope_ensure /opt/zapret2/config || true
  [ "$hardware" = "keenetic" ] && ensure_keenetic_policy_config /opt/zapret2/config
  # После копирования синхронизируем рабочий конфиг, чтобы reset не терял IFACE_WAN.
  if [ "$hardware" = "keenetic" ]; then
    config_keenetic_set_wan_iface /opt/zapret2/config
  fi

  if [ "$BACKUP_HELPER_CREATED" != "1" ] || [ ! -f "$BACKUP_LAST_ARCHIVE" ]; then
    z2r_service_action start
  fi

  echo -e "${green}Config файл обновлён. Листы подбора стратегий и исключений сброшены в дефолт, если не просили сохранить. Фейк файлы обновлены.${plain}"
  return 0
}

fwtype_apply() {
  local target="$1" cfg cur
  cfg="$(get_config_file)"
  cur="$(config_get_var "$cfg" FWTYPE)"

  if [ "$cur" = "$target" ]; then
    echo -e "${yellow}Режим $target уже активен.${plain}"
    return 0
  fi

  if [ "$target" = "nftables" ] && ! fwtype_nft_available; then
    echo -e "${yellow}Переход на nftables невозможен: $(fwtype_unavailable_reason nftables).${plain}"
    return 0
  fi

  if [ "$target" = "iptables" ] && ! fwtype_iptables_available; then
    echo -e "${yellow}Переход на iptables невозможен: $(fwtype_unavailable_reason iptables).${plain}"
    return 0
  fi

  config_set_var "$cfg" FWTYPE "$target"
  /opt/zapret2/install_prereq.sh
  z2r_service_action restart
  echo -e "${green}Zapret mode: $target.${plain}"
  return 0
}

menu_action_toggle_udp_range() {
  local cfg current_ports new_ports state
  cfg="$(get_config_file)"
  current_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
  state="$(config_mode_text udp_games "$cfg")"

  if [ "$state" = "Включен" ]; then
    new_ports="$(csv_remove_tokens "$current_ports" "1026-65531")"
    [ -n "$new_ports" ] || new_ports="443"
    config_set_var "$cfg" NFQWS2_PORTS_UDP "$new_ports"
    backup_smart_set_udp_games "$cfg" 0
    echo -e "${green}Стратегия UDP обхода ДЕактивирована. Выделенные порты 1026-65531 убраны${plain}"

  elif [ "$state" = "Выключен" ]; then
    new_ports="$(csv_add_tokens "" "1026-65531,${current_ports:-443}")"
    config_set_var "$cfg" NFQWS2_PORTS_UDP "$new_ports"
    backup_smart_set_udp_games "$cfg" 1
    echo -e "${green}Стратегия UDP обхода активирована. Выделены порты 1026-65531${plain}"

  else
    echo -e "${yellow}Неизвестное состояние строки NFQWS2_PORTS_UDP. Проверь конфиг вручную.${plain}"
    return 0
  fi

  z2r_service_action restart
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
    backup_smart_set_reasm "$cfg" 0
    echo -e "Параметр --reasm-disable: ${green}деактивирован${plain}."
  else
    if ! grep -q '^NFQWS2_OPT="' "$cfg"; then
      echo -e "${red}Не найден блок NFQWS2_OPT в $cfg.${plain}"
      return 1
    fi
    backup_smart_set_reasm "$cfg" 1
    echo -e "Параметр --reasm-disable: ${red}активирован${plain}."
  fi

  return 0
}

menu_action_set_tls_blob() {
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zator/files/fake"
  local prefix="--blob=maxru:@/opt/zator/files/fake/"
  local sed_ereg="-E"
  local current_blob=""
  local current_mode=""
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

  sed_ereg="$(config_sed_ereg)"

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

  current_blob="$(sed -n -E 's#.*--blob=maxru:@/opt/(zapret2|zator)/files/fake/([^[:space:]]+).*#\2#p' "$cfg" | head -n1)"
  [ -z "$current_blob" ] && current_blob="не найден в конфиге"
  current_mode="$(config_tls_blob_mode_value "$cfg")"
  case "$current_mode" in
    maxru)            current_mode="maxru (внешний файл)" ;;
    fake_default_tls) current_mode="fake_default_tls (встроенный)" ;;
  esac

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
  if ! ui_is_number_in_range "$choice" 1 "$(( ${#blobs[@]} + 1 ))"; then
    echo -e "${red}Некорректный выбор или номер вне диапазона.${plain}"
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

  if ! grep -qE -- "--blob=maxru:@/opt/(zapret2|zator)/files/fake/" "$cfg"; then
    echo -e "${red}Строка --blob=maxru:@.../files/fake/... не найдена в $cfg${plain}"
    pause_enter
    return 1
  fi

  if [ "$sed_ereg" = "-E" ]; then
    sed -i -E '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)fake_default_tls#\1maxru#g; }' "$cfg"
    sed -i -E "s#--blob=maxru:@/opt/(zapret2|zator)/files/fake/[^[:space:]]+#${prefix}${selected_blob}#g" "$cfg"
  else
    sed -i -r '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)fake_default_tls#\1maxru#g; }' "$cfg"
    sed -i -r "s#--blob=maxru:@/opt/(zapret2|zator)/files/fake/[^[:space:]]+#${prefix}${selected_blob}#g" "$cfg"
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
    backup_smart_set_wireguard "$cfg" 1
    echo -e "${green}Стратегия WireGuard ВКЛЮЧЕНА (--skip удалён).${plain}"
  else
    backup_smart_set_wireguard "$cfg" 0
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

  sed_ereg="$(config_sed_ereg)"

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
  if ! ui_is_number_in_range "$new_repeats" 2 99; then
    echo -e "${red}Значение должно быть целым числом от 2 до 99.${plain}"
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
  local fake_dir="/opt/zator/files/fake"
  local prefix="--blob=fakewgblob:@/opt/zator/files/fake/"
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

  sed_ereg="$(config_sed_ereg)"

  if ! grep -qE -- "--blob=fakewgblob:@/opt/(zapret2|zator)/files/fake/" "$cfg"; then
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

  current_blob="$(sed -n -E 's#.*--blob=fakewgblob:@/opt/(zapret2|zator)/files/fake/([^[:space:]]+).*#\2#p' "$cfg" | head -n1)"
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
  if ! ui_is_number_in_range "$choice" 1 "${#blobs[@]}"; then
    echo -e "${red}Некорректный выбор или номер вне диапазона.${plain}"
    pause_enter
    return 1
  fi

  selected_blob="${blobs[$((choice-1))]}"

  if [ "$sed_ereg" = "-E" ]; then
    sed -i -E "s#--blob=fakewgblob:@/opt/(zapret2|zator)/files/fake/[^[:space:]]+#${prefix}${selected_blob}#g" "$cfg"
  else
    sed -i -r "s#--blob=fakewgblob:@/opt/(zapret2|zator)/files/fake/[^[:space:]]+#${prefix}${selected_blob}#g" "$cfg"
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
    backup_smart_set_quic443 "$cfg" 0
    echo -e "${green}Фейки для QUIC (UDP443) ВЫКЛЮЧЕНЫ (--skip добавлен).${plain}"
  else
    # Включаем: убираем --skip перед --filter-udp=443
    backup_smart_set_quic443 "$cfg" 1
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
      backup_smart_set_hostlist "$cfg" 0
    elif grep -q '^MODE_FILTER=hostlist' "$cfg"; then
      backup_smart_set_hostlist "$cfg" 1
    fi
  done
}

toggle_fallback_mode() {
  if [ "$(config_mode_text auto_mode)" = "включен" ]; then
    echo -e "${yellow}Безразборный режим недоступен при авторотации TCP/HTTP.${plain}"
    return 0
  fi
  for cfg in /opt/zapret2/config /opt/zapret2/config.default; do
    [ -f "$cfg" ] || continue
    if [ "$(config_mode_text fallback "$cfg")" = "выключен" ]; then
      backup_smart_set_fallback "$cfg" 1
    else
      backup_smart_set_fallback "$cfg" 0
    fi
  done
}

# Взаимно исключающие TCP/HTTP-блоки: ручной circular_locked и авто circular_quality.
config_set_auto_mode() {
  local cfg="$1"
  local enable="$2"
  local id standard_ids auto_ids fallback_on

  [ -f "$cfg" ] || return 1
  [ "$enable" = "0" ] || [ "$enable" = "1" ] || return 1
  config_auto_layout_valid "$cfg" || return 1
  standard_ids="$(config_auto_pair_ids "$cfg" standard)" || return 1
  auto_ids="$(config_auto_pair_ids "$cfg")" || return 1
  [ "$enable" = "1" ] && grep -q '^#Z2R_AUTO_MODE=1$' "$cfg" && return 0
  [ "$enable" = "0" ] && grep -q '^#Z2R_AUTO_MODE=0$' "$cfg" && return 0

  if [ "$enable" = "1" ]; then
    fallback_on=0
    [ "$(config_mode_text fallback "$cfg")" = "включен" ] && fallback_on=1
    sed -i "s/^#Z2R_AUTO_FALLBACK_WAS=[01]$/#Z2R_AUTO_FALLBACK_WAS=$fallback_on/" "$cfg"
    for id in $auto_ids; do
      sed -i "/^#Z2R_AUTO_${id}_BEGIN$/,/^#Z2R_AUTO_${id}_END$/ s/^--skip[[:space:]]\+//" "$cfg"
    done
    for id in $standard_ids; do
      sed -i "/^#Z2R_AUTO_STANDARD_${id}_BEGIN$/,/^#Z2R_AUTO_STANDARD_${id}_END$/ s/^--skip[[:space:]]\+//" "$cfg"
      sed -i "/^#Z2R_AUTO_STANDARD_${id}_BEGIN$/,/^#Z2R_AUTO_STANDARD_${id}_END$/ { /^--.*filter-tcp=/ s/^/--skip /; }" "$cfg"
    done
    sed -i 's/^#Z2R_AUTO_MODE=0$/#Z2R_AUTO_MODE=1/' "$cfg"
  else
    fallback_on="$(sed -n 's/^#Z2R_AUTO_FALLBACK_WAS=\([01]\)$/\1/p' "$cfg")"
    for id in $auto_ids; do
      sed -i "/^#Z2R_AUTO_${id}_BEGIN$/,/^#Z2R_AUTO_${id}_END$/ s/^--skip[[:space:]]\+//" "$cfg"
      sed -i "/^#Z2R_AUTO_${id}_BEGIN$/,/^#Z2R_AUTO_${id}_END$/ { /^--.*filter-tcp=/ s/^/--skip /; }" "$cfg"
    done
    for id in $standard_ids; do
      sed -i "/^#Z2R_AUTO_STANDARD_${id}_BEGIN$/,/^#Z2R_AUTO_STANDARD_${id}_END$/ s/^--skip[[:space:]]\+//" "$cfg"
      if { [ "$id" = "8" ] || [ "$id" = "9" ]; } && [ "$fallback_on" = "0" ]; then
        sed -i "/^#Z2R_AUTO_STANDARD_${id}_BEGIN$/,/^#Z2R_AUTO_STANDARD_${id}_END$/ { /^--.*filter-tcp=/ s/^/--skip /; }" "$cfg"
      fi
    done
    sed -i 's/^#Z2R_AUTO_MODE=1$/#Z2R_AUTO_MODE=0/' "$cfg"
  fi
}

toggle_auto_mode() {
  local cfg state enable
  cfg="$(config_get_file /opt/zapret2/config)" || {
    echo -e "${red}Не найден /opt/zapret2/config.${plain}"
    return 1
  }
  state="$(config_mode_text auto_mode "$cfg")"
  case "$state" in
    включен) enable=0 ;;
    выключен) enable=1 ;;
    *)
      echo -e "${red}Блоки авторежима в $cfg находятся в несогласованном состоянии.${plain}"
      return 1
      ;;
  esac

  # Сначала проверяем оба конфига, чтобы не оставить их в разных режимах.
  for cfg in /opt/zapret2/config /opt/zapret2/config.default; do
    [ -f "$cfg" ] || continue
    config_auto_layout_valid "$cfg" || {
      echo -e "${red}В $cfg не найдены маркеры авторежима.${plain}"
      return 1
    }
  done
  for cfg in /opt/zapret2/config /opt/zapret2/config.default; do
    [ -f "$cfg" ] || continue
    if ! config_set_auto_mode "$cfg" "$enable"; then
      echo -e "${red}В $cfg не найдены маркеры авторежима.${plain}"
      return 1
    fi
  done

  echo -e "${green}Авторежим: $(config_mode_text auto_mode /opt/zapret2/config).${plain}"
  if pidof nfqws2 >/dev/null 2>&1; then
    if z2r_service_action restart; then
      echo -e "${green}zapret2 перезапущен для применения авторежима.${plain}"
    else
      echo -e "${red}Не удалось перезапустить zapret2.${plain}"
      return 1
    fi
  else
    echo -e "${yellow}Авторежим будет применён при следующем запуске zapret2.${plain}"
  fi
}

toggle_rst_guard_mode() {
  local cfg="/opt/zapret2/config"
  local enable=1

  if type rst_guard_lua_update_from_repo >/dev/null 2>&1 && [ ! -s /opt/zator/lua/rst-guard.lua ]; then
    rst_guard_lua_update_from_repo || true
  fi

  if [ ! -f "$cfg" ]; then
    echo -e "${red}Не найден $cfg.${plain}"
    return 1
  fi

  if grep -q -- '--lua-desync=rst_guard_locked:key=' "$cfg"; then
    enable=0
  fi

  backup_smart_set_rst_guard "$cfg" "$enable"
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

ports_apply_add() {
  local proto="$1" input="$2" cfg="${3:-/opt/zapret2/config}"
  local var anchor line tok added="" skipped="" arr=() new_user
  var="$(ports_var "$proto")" || return 1
  anchor="$(ports_anchor "$proto")"
  line="$(config_get_var "$cfg" "$var")"
  ports_split "$line" "$anchor"
  new_user="$_PORTS_USER"

  input="$(printf '%s' "$input" | tr -d '[:space:]')"
  [ -n "$input" ] && IFS=',' read -ra arr <<< "$input"

  for tok in "${arr[@]}"; do
    [ -n "$tok" ] || continue
    if ! ports_validate "$tok"; then
      skipped="${skipped}${tok},"
      continue
    fi
    if csv_contains_token "$line" "$tok" || csv_contains_token "$new_user" "$tok"; then
      skipped="${skipped}${tok},"
      continue
    fi
    new_user="$(ports_join "$new_user" "$tok")"
    added="${added}${tok},"
  done

  PORTS_APPLY_ADDED="${added%,}"
  PORTS_APPLY_SKIPPED="${skipped%,}"
  [ -z "$added" ] && return 1

  config_set_var "$cfg" "$var" "$(ports_join "$new_user" "$_PORTS_BASE")"
  [ "$proto" = "tcp" ] && ports_set_rkn_filter "$cfg" "$new_user"
  return 0
}

ports_apply_remove() {
  local proto="$1" token="$2" cfg="${3:-/opt/zapret2/config}"
  local var anchor line new_user
  var="$(ports_var "$proto")" || return 1
  anchor="$(ports_anchor "$proto")"
  line="$(config_get_var "$cfg" "$var")"
  ports_split "$line" "$anchor"
  csv_contains_token "$_PORTS_USER" "$token" || return 1
  new_user="$(csv_remove_tokens "$_PORTS_USER" "$token")"
  config_set_var "$cfg" "$var" "$(ports_join "$new_user" "$_PORTS_BASE")"
  [ "$proto" = "tcp" ] && ports_set_rkn_filter "$cfg" "$new_user"
  return 0
}

# Записать строку --filter-tcp блока RKN = пользовательские TCP-порты + база из конфига.
# Базовые порты (от якоря 80 и правее) берутся прямо из NFQWS2_PORTS_TCP — без констант.
ports_set_rkn_filter() {
  local cfg="$1" user="$2"
  local tcp_line rkn_ports marker
  tcp_line="$(config_get_var "$cfg" NFQWS2_PORTS_TCP)"
  ports_split "$tcp_line" "80"
  rkn_ports="$(ports_join "$user" "$_PORTS_BASE")"
  for marker in Z2R_AUTO_STANDARD_3 Z2R_AUTO_3; do
    sed -i "/^#${marker}_BEGIN$/,/^#${marker}_END$/ s/^--filter-tcp=.*--filter-l7=tls[[:space:]]*\$/--filter-tcp=${rkn_ports} --filter-l7=tls/" "$cfg"
    sed -i "/^#${marker}_BEGIN$/,/^#${marker}_END$/ s/^--skip --filter-tcp=.*--filter-l7=tls[[:space:]]*\$/--skip --filter-tcp=${rkn_ports} --filter-l7=tls/" "$cfg"
  done
}

# Добавление пользовательских портов (tcp|udp).
# Порты добавляются в начало строки (до якоря 80/443) и читаются прямо из config.
ports_add() {
  local proto="$1"
  local var label input
  var="$(ports_var "$proto")" || return 1
  label="$(ports_proto_label "$proto")"

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

  if ! ports_apply_add "$proto" "$input"; then
    echo -e "${yellow}Ничего не добавлено.${plain}"
    [ -n "$PORTS_APPLY_SKIPPED" ] && echo -e "${yellow}Пропущено (некорректно/дубликаты): ${PORTS_APPLY_SKIPPED}${plain}"
    pause_enter
    return 0
  fi

  echo -e "${green}Добавлено ${label}: ${PORTS_APPLY_ADDED}${plain}"
  [ -n "$PORTS_APPLY_SKIPPED" ] && echo -e "${yellow}Пропущено: ${PORTS_APPLY_SKIPPED}${plain}"
  echo -e "${green}Строка $var: $(config_get_var /opt/zapret2/config "$var")${plain}"
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
        if ! ui_is_number_in_range "$choice" 1 "${#ports[@]}"; then
          echo -e "${red}Некорректный ввод или номер вне диапазона.${plain}"
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
            if ports_apply_remove "$proto" "$target"; then
              echo -e "${green}Порт ${target} удалён.${plain}"
            else
              echo -e "${red}Не удалось удалить порт ${target}.${plain}"
            fi
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

Z2R_BACKUP_DIR="/opt/zator_backup"

z2r_backup_state_files() {
  cat <<'EOF'
lists/netrogat.txt
lists/netrogat_substrings.txt
extra_strats/TCP_Custom.txt
extra_strats/TCP_RKN_domains_by_substring.txt
extra_strats/cache/orchestra/locked.tsv
extra_strats/cache/orchestra/locked.manual.tsv
extra_strats/cache/orchestra/auto_locked.tsv
EOF
}

backup_build_list_file() {
  local out="$1"
  : > "$out"
  if [ -d "$Z2R_BACKUP_DIR" ]; then
    find "$Z2R_BACKUP_DIR" -maxdepth 1 -type f -name 'z2r_backup_*.tar' 2>/dev/null | sort > "$out"
  fi
  return 0
}

backup_count_archives() {
  local list_file n
  list_file="/tmp/z2r_backup_cnt_$$"
  backup_build_list_file "$list_file"
  n="$(wc -l < "$list_file" | tr -d '[:space:]')"
  rm -f "$list_file"
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

backup_pick_archive() {
  local prompt="$1"
  local list_file count choice i selected
  BACKUP_PICKED=""
  list_file="/tmp/z2r_backup_pick_$$"
  backup_build_list_file "$list_file"
  count="$(wc -l < "$list_file" | tr -d '[:space:]')"
  [ -n "$count" ] || count=0

  if [ "$count" -eq 0 ]; then
    echo -e "${yellow}Архивы бэкапов не найдены в $Z2R_BACKUP_DIR${plain}"
    rm -f "$list_file"
    pause_enter
    return 1
  fi

  echo -e "${yellow}Доступные архивы бэкапов:${plain}"
  i=0
  while IFS= read -r f; do
    i=$((i+1))
    printf "  ${Fcyan}%s.${plain} ${green}%s${plain}\n" "$i" "$(basename "$f")"
  done < "$list_file"
  echo -e "  ${Fyellow}0.${plain} ${Fyellow}Отмена${plain}"
  echo ""
  read -re -p "$prompt" choice

  if [ "$choice" = "0" ] || [ -z "$choice" ]; then
    rm -f "$list_file"
    return 1
  fi
  if ! ui_is_number_in_range "$choice" 1 "$count"; then
    echo -e "${red}Некорректный ввод или номер вне диапазона.${plain}"
    rm -f "$list_file"
    pause_enter
    return 1
  fi

  selected="$(sed -n "${choice}p" "$list_file")"
  rm -f "$list_file"
  BACKUP_PICKED="$selected"
  return 0
}

backup_create_core() {
  local ts archive stage rel src tmp_list
  BACKUP_LAST_ARCHIVE=""
  ts="$(date +%Y%m%d_%H%M%S)"
  archive="$Z2R_BACKUP_DIR/z2r_backup_${ts}.tar"
  stage="/tmp/z2r_backup_stage_$$"
  tmp_list="/tmp/z2r_backup_state_$$"

  rm -rf "$stage"
  mkdir -p "$stage" || return 1

  if [ -f /opt/zapret2/config ]; then
    cp -f /opt/zapret2/config "$stage/config" || { rm -rf "$stage" "$tmp_list"; return 1; }
  fi

  z2r_backup_state_files > "$tmp_list"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    src="/opt/zator/$rel"
    [ -f "$src" ] || continue
    mkdir -p "$stage/$(dirname "$rel")"
    cp -f "$src" "$stage/$rel" || { rm -rf "$stage" "$tmp_list"; return 1; }
  done < "$tmp_list"
  rm -f "$tmp_list"

  mkdir -p "$Z2R_BACKUP_DIR" || { rm -rf "$stage"; return 1; }

  tar -cf "$archive" -C "$stage" . 2>/dev/null || { rm -rf "$stage" "$archive"; return 1; }
  rm -rf "$stage"

  BACKUP_LAST_ARCHIVE="$archive"
  printf '%s\n' "$archive"
}

backup_resolve_archive() {
  local name="$1" list_file path rc
  case "$name" in
    z2r_backup_*.tar) ;;
    *) return 1 ;;
  esac
  case "$name" in
    */*|..*) return 1 ;;
  esac
  path="$Z2R_BACKUP_DIR/$name"
  [ -f "$path" ] || return 1
  list_file="/tmp/z2r_backup_resolve_$$"
  backup_build_list_file "$list_file"
  grep -qxF "$path" "$list_file"
  rc=$?
  rm -f "$list_file"
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$path"
}

backup_delete_core() {
  local name="$1" path
  path="$(backup_resolve_archive "$name")" || return 1
  rm -f "$path" || return 1
  printf '%s\n' "$path"
}

backup_import_core() {
  local src="$1" orig="${2:-}" listing name="" ts n
  [ -f "$src" ] || return 1
  [ -s "$src" ] || return 1
  listing="/tmp/z2r_backup_import_$$"
  tar -tf "$src" > "$listing" 2>/dev/null || { rm -f "$listing"; return 1; }
  grep -qE '(^|/)config$|/(lists|extra_strats)/' "$listing" || { rm -f "$listing"; return 1; }
  rm -f "$listing"
  case "$orig" in
    z2r_backup_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar)
      [ -e "$Z2R_BACKUP_DIR/$orig" ] || name="$orig"
      ;;
  esac
  if [ -z "$name" ]; then
    ts="$(date +%Y%m%d_%H%M%S)"
    name="z2r_backup_${ts}.tar"
    n=0
    while [ -e "$Z2R_BACKUP_DIR/$name" ]; do
      n=$((n+1))
      name="z2r_backup_${ts}_${n}.tar"
    done
  fi
  mkdir -p "$Z2R_BACKUP_DIR" || return 1
  mv -f "$src" "$Z2R_BACKUP_DIR/$name" || return 1
  printf '%s\n' "$name"
}

menu_action_backup_create() {
  local archive
  if ! archive="$(backup_create_core 2>/dev/null)"; then
    echo -e "${red}Не удалось создать бэкап.${plain}"
    return 1
  fi
  # backup_create_core ставит BACKUP_LAST_ARCHIVE внутри command substitution
  # (subshell), до вызывающего shell значение не доходит — восстанавливаем.
  BACKUP_LAST_ARCHIVE="$archive"
  echo -e "${green}Бэкап создан: $(basename "$archive")${plain}"
  echo -e "${yellow}Путь: $archive${plain}"
  pause_enter
  return 0
}


backup_helper_ask_and_create() {
  local ans
  BACKUP_HELPER_CONSENT=0
  BACKUP_HELPER_CREATED=0
  BACKUP_LAST_ARCHIVE=""

  echo -e "${yellow}Создать резервную копию (бэкап) перед операцией?${plain}"
  echo -e "  ${Fcyan}1${plain} — да, создать бэкап"
  echo -e "  ${Fyellow}0${plain} — нет, продолжить без бэкапа"
  read -re -p "Ваш выбор: " ans

  case "$ans" in
    1|5|y|Y|д|Д)
      BACKUP_HELPER_CONSENT=1
      if menu_action_backup_create; then
        BACKUP_HELPER_CREATED=1
      else
        echo -e "${red}Не удалось создать бэкап. Продолжаем без него.${plain}"
      fi
      ;;
    *)
      echo -e "${yellow}Продолжаем без создания бэкапа.${plain}"
      ;;
  esac
  return 0
}

backup_update_offer_restore() {
  local ans

  # Сценарий А: только что создан архив.
  if [ "$BACKUP_HELPER_CREATED" = "1" ] && [ -n "$BACKUP_LAST_ARCHIVE" ] && [ -f "$BACKUP_LAST_ARCHIVE" ]; then
    echo ""
    echo -e "${yellow}Обновление завершено. Хотите восстановить ваши настройки из только что созданного бэкапа?${plain}"
    echo -e "${yellow}(Доступны только безопасные режимы: умный перенос / списки. Полное восстановление заблокировано, чтобы не затереть обновлённый config.)${plain}"
    echo -e "  ${Fcyan}1${plain} — да, восстановить из свежего бэкапа"
    echo -e "  ${Fyellow}0${plain} — нет, оставить обновлённый config как есть"
    read -re -p "Ваш выбор: " ans
    case "$ans" in
      1|5|y|Y|д|Д)
        # block_full=1: режим «Полное» (a) недоступен — только списки (2) и умный перенос (3).
        menu_action_backup_restore "$BACKUP_LAST_ARCHIVE" 1 || true
        ;;
      *)
        echo -e "${green}Обновлённый config оставлен без изменений.${plain}"
        ;;
    esac
    if ! pidof nfqws2 >/dev/null 2>&1; then
      z2r_service_action start >/dev/null 2>&1 || true
      echo -e "${green}zapret2 запущен.${plain}"
    fi
    return 0
  fi

  # Сценарий Б: отказ от бэкапа. Ищем ранее созданные архивы.
  if [ "$(backup_count_archives)" -gt 0 ]; then
    echo ""
    echo -e "${yellow}Найдены ранее созданные архивы бэкапов в /opt/zator_backup/.${plain}"
    echo -e "${yellow}Перейти в меню бэкапов для восстановления прошлых настроек?${plain}"
    echo -e "${yellow}(Полное восстановление будет заблокировано в контексте обновления.)${plain}"
    echo -e "  ${Fcyan}1${plain} — да, перейти в меню бэкапов"
    echo -e "  ${Fyellow}0${plain} — нет, выйти"
    read -re -p "Ваш выбор: " ans
    case "$ans" in
      1|5|y|Y|д|Д)
        # block_full=1 пробрасывается в подменю: полное восстановление скрыто.
        backup_submenu 1 || true
        ;;
      *)
        echo -e "${green}Выход без восстановления.${plain}"
        ;;
    esac
  fi
  return 0
}

# Проверка наличия всех blob-файлов, на которые ссылается config.
# Если хотя бы один файл отсутствует — печатает его и возвращает 1 (импорт недопустим).
# Если все на месте — возвращает 0.
backup_check_blobs() {
  local cfg="$1"
  local tmp_pairs name file missing
  [ -f "$cfg" ] || return 0

  tmp_pairs="/tmp/z4r_blob_pairs_$$"
  missing=0
  # Извлекаем пары "ИМЯ ФАЙЛ" из строк --blob=NAME:@/opt/.../files/fake/FILE
  # (path-agnostic: zapret2|zator — старый/новый корень).
  sed -n 's#.*--blob=\([a-zA-Z0-9_]*\):@/opt/[^/][^/]*/files/fake/\([^[:space:]]*\).*#\1 \2#p' "$cfg" \
    | sort -u > "$tmp_pairs"

  while read -r name file; do
    [ -n "$name" ] || continue
    [ -n "$file" ] || continue
    if [ ! -f "/opt/zator/files/fake/$file" ]; then
      echo -e "${red}Blob ${name}: файл ${file} отсутствует на устройстве.${plain}"
      missing=1
    fi
  done < "$tmp_pairs"
  rm -f "$tmp_pairs"
  return "$missing"
}

# =============================================================================
# Умный перенос настроек (режим 3 восстановления).
# Неразрушающий перенос: живой /opt/zapret2/config НЕ заменяется.
# Старый config из бэкапа — только источник данных для чтения.
# Переносятся: порты NFQWS2_PORTS_*, blob-файлы (по совпадению имён),
# флаги пунктов 13/18/19/20. Применяются штатные sed-паттерны проекта
# (логическое ядро toggle_* / menu_action_toggle_*), но параметризованно:
# каждый «сеттер» принимает конкретный cfg и желаемое состояние.
# =============================================================================

# Точечный перенос портов NFQWS2_PORTS_TCP / NFQWS2_PORTS_UDP.
# Значения целиком берутся из старого конфига и записываются в новый через
# штатный config_set_var. Для TCP дополнительно синхронизируется --filter-tcp
# блока RKN через ports_set_rkn_filter() — как при ручном добавлении портов.
backup_smart_apply_ports() {
  local old_cfg="$1" new_cfg="$2"
  local old_tcp old_udp new_tcp_user

  [ -f "$old_cfg" ] && [ -f "$new_cfg" ] || return 0

  old_tcp="$(config_get_var "$old_cfg" NFQWS2_PORTS_TCP)"
  old_udp="$(config_get_var "$old_cfg" NFQWS2_PORTS_UDP)"

  if [ -n "$old_tcp" ]; then
    config_set_var "$new_cfg" NFQWS2_PORTS_TCP "$old_tcp"
    # Синхронизация --filter-tcp блока RKN = пользовательские порты + база.
    ports_split "$old_tcp" "80"
    new_tcp_user="$_PORTS_USER"
    ports_set_rkn_filter "$new_cfg" "$new_tcp_user"
  fi
  if [ -n "$old_udp" ]; then
    config_set_var "$new_cfg" NFQWS2_PORTS_UDP "$old_udp"
  fi
  return 0
}

# Синхронизация blob-файлов по совпадению имён + синхронизация режима maxru.
# Блоб прописывается в конфиге в ДВУХ местах (см. menu_action_set_tls_blob):
#   1. Декларация: --blob=maxru:@/opt/zator/files/fake/ФАЙЛ
#   2. Ссылки в стратегиях: blob=fake_default_tls ↔ blob=maxru в --lua-desync=
# Шаг 1: переносятся декларации для имён, есть и в старом, и в новом (файл
#   должен физически существовать на устройстве). Новые блобы не затрагиваются.
# Шаг 2: если режим maxru в старом конфиге отличается от нового — переключаем
#   теми же sed, что и menu_action_set_tls_blob() (кроме strategy=26).
backup_smart_apply_blobs() {
  local old_cfg="$1" new_cfg="$2"
  local tmp_old tmp_new name oldfile newfile ereg
  local old_mode new_mode

  [ -f "$old_cfg" ] && [ -f "$new_cfg" ] || return 0
  ereg="$(config_sed_ereg)"
  tmp_old="/tmp/z4r_smart_old_$$"
  tmp_new="/tmp/z4r_smart_new_$$"

  # --- Шаг 1: перенос деклараций --blob=NAME:@.../FILE по совпадению имён ---
  # path-agnostic (zapret2|zator): старый бэкап может содержать старый корень,
  # новый живой конфиг — новый. Совпадение по [^/][^/]* портабельно в BRE/ERE.
  sed -n 's#.*--blob=\([a-zA-Z0-9_]*\):@/opt/[^/][^/]*/files/fake/\([^[:space:]]*\).*#\1 \2#p' "$old_cfg" | sort -u > "$tmp_old"
  sed -n 's#.*--blob=\([a-zA-Z0-9_]*\):@/opt/[^/][^/]*/files/fake/\([^[:space:]]*\).*#\1 \2#p' "$new_cfg" | sort -u > "$tmp_new"

  while read -r name oldfile; do
    [ -n "$name" ] || continue
    [ -n "$oldfile" ] || continue
    # Только имена, присутствующие в новом конфиге.
    grep -q "^${name} " "$tmp_new" || continue
    # Не ломаем конфиг: переносим только существующие на устройстве файлы.
    [ -f "/opt/zator/files/fake/$oldfile" ] || continue
    # Текущий файл этого блоба в новом конфиге.
    newfile="$(sed -n "s#.*--blob=${name}:@/opt/[^/][^/]*/files/fake/\([^[:space:]]*\).*#\1#p" "$new_cfg" | head -n1)"
    [ "$newfile" = "$oldfile" ] && continue
    # Замена пути файла для данного имени блоба (строка объявления).
    # \1 сохраняет канонический префикс нового конфига (/@/opt/zator/files/fake/).
    sed -i $ereg "s#(--blob=${name}:@/opt/[^/][^/]*/files/fake/)[^[:space:]]+#\\1${oldfile}#g" "$new_cfg"
  done < "$tmp_old"

  rm -f "$tmp_old" "$tmp_new"

  # --- Шаг 2: синхронизация режима maxru (ссылки в --lua-desync= строках) ---
  # config_tls_blob_mode_value() определяет: maxru / fake_default_tls / mixed.
  old_mode="$(config_tls_blob_mode_value "$old_cfg")"
  new_mode="$(config_tls_blob_mode_value "$new_cfg")"

  # Режимы совпадают или старый неоднозначен — ничего делать не нужно.
  [ "$old_mode" = "$new_mode" ] && return 0
  [ "$old_mode" = "mixed" ] && return 0
  [ "$old_mode" = "не определён" ] && return 0

  # Переключаем режим в новом конфиге теми же sed, что и menu_action_set_tls_blob().
  if [ "$old_mode" = "maxru" ]; then
    # Включаем maxru: fake_default_tls → maxru в lua-desync (кроме strategy=26).
    sed -i $ereg '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)fake_default_tls#\1maxru#g; }' "$new_cfg"
  elif [ "$old_mode" = "fake_default_tls" ]; then
    # Возвращаем default: maxru → fake_default_tls в lua-desync (кроме strategy=26).
    sed -i $ereg '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)maxru#\1fake_default_tls#g; }' "$new_cfg"
  fi

  return 0
}

# --- Программные «сеттеры» состояний (логическое ядро тумблеров) ---
# Каждый принимает cfg и желаемое состояние (1=вкл, 0=выкл) и применяет
# точечные sed-замены только к указанному файлу (без интерактивного read).

# Пункт 13: безразборный режим (fallback). --skip в блоках #Z2R_FALLBACK*.
# Повторяет логическое ядро toggle_fallback_mode(), но для одного cfg.
backup_smart_set_fallback() {
  local cfg="$1" want_on="$2"
  local tls_begin="" tls_end="" http_begin http_end
  if grep -q '^#Z2R_AUTO_MODE=1$' "$cfg"; then
    return 0
  else
    tls_begin="#Z2R_FALLBACK_BEGIN"
    tls_end="#Z2R_FALLBACK_END"
    http_begin="#Z2R_FALLBACK_HTTP_BEGIN"
    http_end="#Z2R_FALLBACK_HTTP_END"
  fi
  if [ "$want_on" = "1" ]; then
    [ -z "$tls_begin" ] || sed -i "/$tls_begin/,/$tls_end/ s/^[[:space:]]*--skip[[:space:]]\+//" "$cfg"
    sed -i "/$http_begin/,/$http_end/ s/^[[:space:]]*--skip[[:space:]]\+//" "$cfg"
  else
    [ -z "$tls_begin" ] || sed -i "/$tls_begin/,/$tls_end/ s/^[[:space:]]*--skip[[:space:]]\+//" "$cfg"
    sed -i "/$http_begin/,/$http_end/ s/^[[:space:]]*--skip[[:space:]]\+//" "$cfg"
    [ -z "$tls_begin" ] || sed -i "/$tls_begin/,/$tls_end/ { /^--.*filter-tcp=/ s/^/--skip /; }" "$cfg"
    sed -i "/$http_begin/,/$http_end/ { /^--.*filter-tcp=/ s/^/--skip /; }" "$cfg"
  fi
}

# Пункт 18: защита от RST-инъекций. circular_locked <-> rst_guard_locked (key 1,2,3,4,8,9).
# Повторяет логическое ядро toggle_rst_guard_mode(), но для одного cfg.
backup_smart_set_rst_guard() {
  local cfg="$1" want_on="$2"
  local key
  if [ "$want_on" = "1" ]; then
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

# Пункт 19: --reasm-disable (вставка/удаление строки после NFQWS2_OPT=").
# Повторяет логическое ядро menu_action_toggle_reasm_disable().
backup_smart_set_reasm() {
  local cfg="$1" want_on="$2"
  if [ "$want_on" = "1" ]; then
    grep -q '^[[:space:]]*--reasm-disable[[:space:]]*$' "$cfg" || \
      sed -i '/^NFQWS2_OPT="/a --reasm-disable' "$cfg"
  else
    sed -i '/^[[:space:]]*--reasm-disable[[:space:]]*$/d' "$cfg"
  fi
}

# Пункт 19: стратегия WireGuard (--skip перед --filter-l7=wireguard).
# Повторяет логическое ядро menu_action_toggle_wireguard_fake().
backup_smart_set_wireguard() {
  local cfg="$1" want_on="$2"
  if [ "$want_on" = "1" ]; then
    sed -i '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/ s/^[[:space:]]*--skip[[:space:]]\+--filter-l7=wireguard/--filter-l7=wireguard/' "$cfg"
  else
    sed -i '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/ s/^[[:space:]]*--filter-l7=wireguard/--skip --filter-l7=wireguard/' "$cfg"
  fi
}

# Пункт 19: фейки QUIC-initial на 443 (--skip перед --filter-udp=443).
# Повторяет логическое ядро menu_action_toggle_quic443_fake().
backup_smart_set_quic443() {
  local cfg="$1" want_on="$2"
  if [ "$want_on" = "1" ]; then
    sed -i '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/ s/^[[:space:]]*--skip[[:space:]]\+--filter-udp=443[[:space:]]*$/--filter-udp=443/' "$cfg"
  else
    sed -i '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/ s/^[[:space:]]*--filter-udp=443[[:space:]]*$/--skip --filter-udp=443/' "$cfg"
  fi
}

# Пункт 19: игровой UDP (--skip перед --filter-udp=1026 в блоке игрового UDP).
# Повторяет логическое ядро menu_action_toggle_udp_range() (config-часть).
backup_smart_set_udp_games() {
  local cfg="$1" want_on="$2"
  if [ "$want_on" = "1" ]; then
    sed -i '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/ s/^--skip[[:space:]]\+--filter-udp=1026/--filter-udp=1026/' "$cfg"
  else
    sed -i '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/ s/^--filter-udp=1026/--skip --filter-udp=1026/' "$cfg"
  fi
}

# Пункт 19: MODE_FILTER (hostlist/autohostlist) + плейсхолдер <HOSTLIST> для RKN.
# Повторяет логическое ядро toggle_hostlist_mode(), но для одного указанного cfg.
backup_smart_set_hostlist() {
  local cfg="$1" want_auto="$2"
  if [ "$want_auto" = "1" ]; then
    sed -i 's/^MODE_FILTER=hostlist/MODE_FILTER=autohostlist/' "$cfg"
    sed -i -E 's#(--hostlist=/opt/(zapret2|zator)/extra_strats/TCP_RKN_list\.txt)#\1 <HOSTLIST>#g' "$cfg"
  else
    sed -i 's/^MODE_FILTER=autohostlist/MODE_FILTER=hostlist/' "$cfg"
    sed -i -E 's#(--hostlist=/opt/(zapret2|zator)/extra_strats/TCP_RKN_list\.txt) <HOSTLIST>#\1#g' "$cfg"
  fi
}

# Детектор состояния WireGuard в указанном cfg: 1=вкл, 0=выкл, пусто=блока нет.
backup_smart_wg_state() {
  local cfg="$1" blk
  blk="$(sed -n '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/p' "$cfg" 2>/dev/null)"
  if printf "%s\n" "$blk" | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-l7=wireguard[[:space:]]*$'; then
    printf '0'
  elif printf "%s\n" "$blk" | grep -q -- '--filter-l7=wireguard'; then
    printf '1'
  fi
}

# Детектор состояния QUIC443 в указанном cfg: 1=вкл, 0=выкл, пусто=блока нет.
backup_smart_quic443_state() {
  local cfg="$1" blk
  blk="$(sed -n '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/p' "$cfg" 2>/dev/null)"
  if printf "%s\n" "$blk" | grep -Eq '^[[:space:]]*--filter-udp=443[[:space:]]*$'; then
    printf '1'
  elif printf "%s\n" "$blk" | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-udp=443[[:space:]]*$'; then
    printf '0'
  fi
}

# Оркестратор флагов: читает состояния из старого конфига и применяет к новому.
# Порядок важен: RST-защита меняет формат --filter-tcp в блоке fallback,
# поэтому применяется раньше безразборного режима (fallback-сеттер умеет оба формата).
backup_smart_apply_flags() {
  local old_cfg="$1" new_cfg="$2"
  local s_old s_new v_old v_new

  [ -f "$old_cfg" ] && [ -f "$new_cfg" ] || return 0

  # Client mark scope is configuration state too. Legacy backups simply have
  # no variables and therefore leave the new defaults untouched.
  config_client_scope_apply "$old_cfg" "$new_cfg"

  # --- Авторотация TCP/HTTP ---
  s_old="$(config_mode_text auto_mode "$old_cfg")"
  s_new="$(config_mode_text auto_mode "$new_cfg")"
  if [ "$s_old" != "неизвестно" ] && [ "$s_old" != "$s_new" ]; then
    if [ "$s_old" = "включен" ]; then
      config_set_auto_mode "$new_cfg" 1
      v_old="$(sed -n 's/^#Z2R_AUTO_FALLBACK_WAS=\([01]\)$/\1/p' "$old_cfg")"
      [ -z "$v_old" ] || sed -i "s/^#Z2R_AUTO_FALLBACK_WAS=[01]$/#Z2R_AUTO_FALLBACK_WAS=$v_old/" "$new_cfg"
    else config_set_auto_mode "$new_cfg" 0; fi
  fi

  # --- Пункт 18: RST-защита (первой — меняет формат filter-tcp) ---
  s_old="$(config_mode_text rst_guard "$old_cfg")"
  s_new="$(config_mode_text rst_guard "$new_cfg")"
  if [ "$s_old" != "$s_new" ]; then
    if [ "$s_old" = "включен" ]; then backup_smart_set_rst_guard "$new_cfg" 1
    else backup_smart_set_rst_guard "$new_cfg" 0; fi
  fi

  # --- Пункт 13: безразборный режим (fallback) ---
  s_old="$(config_mode_text fallback "$old_cfg")"
  s_new="$(config_mode_text fallback "$new_cfg")"
  if [ "$s_old" != "$s_new" ]; then
    if [ "$s_old" = "включен" ]; then backup_smart_set_fallback "$new_cfg" 1
    else backup_smart_set_fallback "$new_cfg" 0; fi
  fi

  # --- Пункт 19: --reasm-disable ---
  s_old="$(config_mode_text reasm_disable "$old_cfg")"
  s_new="$(config_mode_text reasm_disable "$new_cfg")"
  if [ "$s_old" != "$s_new" ]; then
    if [ "$s_old" = "включено" ]; then backup_smart_set_reasm "$new_cfg" 1
    else backup_smart_set_reasm "$new_cfg" 0; fi
  fi

  # --- Пункт 19: игровой UDP ---
  s_old="$(config_mode_text udp_games "$old_cfg")"
  s_new="$(config_mode_text udp_games "$new_cfg")"
  if [ "$s_old" != "$s_new" ]; then
    if [ "$s_old" = "Включен" ]; then backup_smart_set_udp_games "$new_cfg" 1
    else backup_smart_set_udp_games "$new_cfg" 0; fi
  fi

  # --- Пункт 19: WireGuard ---
  v_old="$(backup_smart_wg_state "$old_cfg")"
  v_new="$(backup_smart_wg_state "$new_cfg")"
  if [ -n "$v_old" ] && [ -n "$v_new" ] && [ "$v_old" != "$v_new" ]; then
    backup_smart_set_wireguard "$new_cfg" "$v_old"
  fi

  # --- Пункт 19: QUIC443 ---
  v_old="$(backup_smart_quic443_state "$old_cfg")"
  v_new="$(backup_smart_quic443_state "$new_cfg")"
  if [ -n "$v_old" ] && [ -n "$v_new" ] && [ "$v_old" != "$v_new" ]; then
    backup_smart_set_quic443 "$new_cfg" "$v_old"
  fi

  # --- Пункт 19: FWTYPE ---
  v_old="$(config_get_var "$old_cfg" FWTYPE)"
  v_new="$(config_get_var "$new_cfg" FWTYPE)"
  if [ -n "$v_old" ] && [ "$v_old" != "$v_new" ]; then
    config_set_var "$new_cfg" FWTYPE "$v_old"
  fi

  # --- Пункт 19/20: FLOWOFFLOAD ---
  v_old="$(config_get_var "$old_cfg" FLOWOFFLOAD)"
  v_new="$(config_get_var "$new_cfg" FLOWOFFLOAD)"
  if [ -n "$v_old" ] && [ "$v_old" != "$v_new" ]; then
    config_set_var "$new_cfg" FLOWOFFLOAD "$v_old"
  fi

  # --- Пункт 19: MODE_FILTER (hostlist/autohostlist) ---
  s_old="$(config_mode_text hostlist "$old_cfg")"
  s_new="$(config_mode_text hostlist "$new_cfg")"
  if [ "$s_old" != "$s_new" ]; then
    if [ "$s_old" = "авто" ]; then backup_smart_set_hostlist "$new_cfg" 1
    else backup_smart_set_hostlist "$new_cfg" 0; fi
  fi

  return 0
}

# Полный умный перенос: порты + blob'ы + флаги. Живой config не заменяется.
# Аргументы: old_cfg (из бэкапа), new_cfg (живой /opt/zapret2/config).
menu_action_backup_restore_smart() {
  local old_cfg="$1" new_cfg="$2"

  [ -f "$old_cfg" ] || { echo -e "${red}В архиве нет config — умный перенос невозможен.${plain}"; return 1; }
  [ -f "$new_cfg" ] || { echo -e "${red}Живой config не найден: $new_cfg${plain}"; return 1; }

  echo -e "${cyan}Умный перенос настроек (живой config не заменяется)...${plain}"
  backup_smart_apply_ports "$old_cfg" "$new_cfg"
  echo -e "${green}  • Порты NFQWS2_PORTS_TCP/UDP перенесены.${plain}"
  backup_smart_apply_blobs "$old_cfg" "$new_cfg"
  echo -e "${green}  • Blob-файлы синхронизированы по совпадению имён.${plain}"
  backup_smart_apply_flags "$old_cfg" "$new_cfg"
  echo -e "${green}  • Флаги (п.13/18/19/20) применены к живому config.${plain}"
  return 0
}

# Восстановление из выбранного архива.
# Режим 1 — полное: config + списки доменов + номера стратегий (с проверкой blob).
# Режим 2 — только пользовательские списки доменов и выбранные номера стратегий.
# Режим 3 — умный перенос: живой config НЕ заменяется; из бэкапа точечно
#   переносятся порты NFQWS2_PORTS_*, blob-файлы (по совпадению имён) и флаги
#   пунктов 13/18/19/20 через штатные sed-паттерны проекта.
menu_action_backup_restore() {
  # $1 (preset_archive) — необязательный путь к архиву; если задан, выбор из
  #   списка пропускается (используется при восстановлении из только что
  #   созданного бэкапа после обновления, пункт 5).
  # $2 (block_full) — 1 = запретить режим «Полное» (mode 1). Применяется в
  #   контексте обновления, чтобы архив не затёр только что обновлённый config.
  local preset_archive="${1:-}"
  local block_full="${2:-0}"
  local archive restore_dir mode rel src dst tmp_list was_running

  if [ -n "$preset_archive" ]; then
    archive="$preset_archive"
    if [ ! -f "$archive" ]; then
      echo -e "${red}Архив не найден: $archive${plain}"
      return 1
    fi
    echo -e "${yellow}Восстановление из архива: $(basename "$archive")${plain}"
  else
    if ! backup_pick_archive "Выберите номер архива для восстановления: "; then
      return 0
    fi
    archive="$BACKUP_PICKED"
  fi
  echo ""

  # Выбор режима восстановления. В контексте обновления (block_full=1) режим
  # «Полное» (1) недоступен иначе маразм, не надо заменять обновленынй конфиг на старый
  while true; do
    echo -e "${yellow}Режим восстановления:${plain}"
    if [ "$block_full" = "1" ]; then
      # Контекст обновления: полное восстановление заблокировано.
      echo -e "  ${Fcyan}2${plain} — ${green}Только списки доменов и номера стратегий${plain} (config не затрагивается)"
      echo -e "  ${Fcyan}3${plain} — ${green}Умный перенос настроек${plain} (config не заменяется; переносятся порты, blob'ы, флаги п.13/18/19/20)"
      echo -e "  ${Fyellow}0${plain} — ${Fyellow}Отмена${plain}"
      echo -e "${yellow}(Полное восстановление заблокировано: обновлённый config защищён от перезаписи старым файлом из архива.)${plain}"
    else
      echo -e "  ${Fcyan}1${plain} — ${green}Полное${plain} (config + списки доменов + номера стратегий)"
      echo -e "  ${Fcyan}2${plain} — ${green}Только списки доменов и номера стратегий${plain} (config не затрагивается)"
      echo -e "  ${Fcyan}3${plain} — ${green}Умный перенос настроек${plain} (config не заменяется; переносятся порты, blob'ы, флаги п.13/18/19/20)"
      echo -e "  ${Fyellow}0${plain} — ${Fyellow}Отмена${plain}"
    fi
    read -re -p "Ваш выбор: " mode
    case "$mode" in
      2|3) break ;;
      1)
        if [ "$block_full" = "1" ]; then
          echo -e "${red}Полное восстановление заблокировано в контексте обновления (защита обновлённого config). Доступно: 2, 3 или 0.${plain}"
          sleep 1
          continue
        fi
        break
        ;;
      0|"")
        echo -e "${yellow}Восстановление отменено.${plain}"
        return 0
        ;;
      *)
        echo -e "${red}Некорректный ввод. Выберите доступный режим (2, 3 или 0).${plain}"
        sleep 1
        continue
        ;;
    esac
  done

  restore_dir="/tmp/z4r_restore_$$"
  rm -rf "$restore_dir"
  if ! mkdir -p "$restore_dir"; then
    echo -e "${red}Не удалось создать временную директорию.${plain}"
    return 1
  fi

  if ! tar -xf "$archive" -C "$restore_dir" 2>/dev/null; then
    rm -rf "$restore_dir"
    echo -e "${red}Не удалось распаковать архив: $(basename "$archive")${plain}"
    return 1
  fi

  # Режим 1: предварительная проверка blob-файлов. Если config из архива
  # ссылается на отсутствующий blob — прерываем импорт, ничего не меняем.
  if [ "$mode" = "1" ] && [ -f "$restore_dir/config" ]; then
    if ! backup_check_blobs "$restore_dir/config"; then
      rm -rf "$restore_dir"
      echo ""
      echo -e "${red}Восстановление прервано: отсутствуют blob-файлы.${plain}"
      echo -e "${yellow}Установите недостающие blob-файлы или обновите проект перед восстановлением.${plain}"
      return 1
    fi
  fi

  # Останавливаем zapret2 перед накатом файлов.
  was_running=0
  if pidof nfqws2 >/dev/null 2>&1; then
    was_running=1
  fi
  z2r_service_action stop 2>/dev/null || true

  # Режим 1: config — все переключения пользователя физически живут внутри config.
  if [ "$mode" = "1" ]; then
    if [ -f "$restore_dir/config" ]; then
      if cp -f "$restore_dir/config" /opt/zapret2/config; then
        echo -e "${green}config восстановлен.${plain}"
      else
        rm -rf "$restore_dir"
        echo -e "${red}Ошибка восстановления config.${plain}"
        return 1
      fi
    else
      echo -e "${yellow}В архиве нет config — текущий config не изменён.${plain}"
    fi
  elif [ "$mode" = "3" ]; then
    # Умный перенос: живой /opt/zapret2/config не заменяется. Старый config из
    # архива — только источник данных. Проверка blob не нужна: синхронизация
    # идёт по совпадению имён и переносит только существующие на устройстве файлы.
    if ! menu_action_backup_restore_smart "$restore_dir/config" /opt/zapret2/config; then
      rm -rf "$restore_dir"
      return 1
    fi
  else
    echo -e "${yellow}Config не затронут (режим 2 — списки доменов и номера стратегий).${plain}"
  fi

  # Пользовательские списки/состояния/блокировки (оба режима).
  tmp_list="/tmp/z2r_state_list_$$"
  z2r_backup_state_files > "$tmp_list"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    src="$restore_dir/$rel"
    [ -f "$src" ] || continue
    dst="/opt/zator/$rel"
    mkdir -p "$(dirname "$dst")"
    if ! cp -f "$src" "$dst"; then
      rm -rf "$restore_dir" "$tmp_list"
      echo -e "${red}Ошибка восстановления $rel.${plain}"
      return 1
    fi
  done < "$tmp_list"
  rm -f "$tmp_list"
  echo -e "${green}Списки доменов и номера стратегий восстановлены.${plain}"

  rm -rf "$restore_dir"

  # Перезапуск, если zapret2 был активен.
  if [ "$was_running" = "1" ]; then
    z2r_service_action start 2>/dev/null || true
    echo -e "${green}zapret2 перезапущен для применения восстановленных настроек.${plain}"
  fi

  echo -e "${green}Восстановление завершено.${plain}"
  return 0
}

menu_action_backup_delete() {
  local archive confirm

  if ! backup_pick_archive "Выберите номер архива для удаления: "; then
    return 0
  fi
  archive="$BACKUP_PICKED"
  echo ""
  echo -e "${yellow}Удалить архив ${green}$(basename "$archive")${yellow} безвозвратно?${plain}"
  echo -e "  ${Fcyan}1${plain} — да, удалить"
  echo -e "  ${Fyellow}0${plain} — отмена"
  read -re -p "Ваш выбор: " confirm

  if [ "$confirm" = "1" ]; then
    rm -f "$archive"
    echo -e "${green}Архив удалён: $(basename "$archive")${plain}"
  else
    echo -e "${yellow}Удаление отменено.${plain}"
  fi
  pause_enter
  return 0
}
