# submenus.sh
# Единый стиль: loop + return на 0/Enter

# Путь к живому config (для чтения max-стратегий профилей).
client_scopes_cfg() {
  printf '%s\n' "${ZAPRET2_ROOT:-/opt/zapret2}/config"
}

# --- Client scopes: вывод состояния (общий для меню и будущих вызовов) ---

client_scopes_print_header() {
  local mode
  echo -e "${cyan}--- Client scopes ---${plain}"
  mode="$(client_scope_mode_text)"
  if [ "$mode" = "включен" ]; then
    echo -e "Режим: ${green}включен${plain}"
  else
    echo -e "Режим: ${red}выключен${plain}"
  fi
}

# Ширина строки при выводе локов (перенос длинных списков; ориентир — 80-колоночный терминал).
CLIENT_SCOPES_WRAP_WIDTH=76

# Короткие имена профилей для компактного вывода локов (полные — config_profile_title).
_client_scopes_profile_label() {
  case "$1" in
    1) echo "YouTube" ;;
    2) echo "Googlevideo" ;;
    3) echo "RKN" ;;
    4) echo "Discord" ;;
    5) echo "QUIC" ;;
    6) echo "UDP Voice" ;;
    7) echo "UDP Games" ;;
    8) echo "Fallback TLS" ;;
    9) echo "Fallback HTTP" ;;
    *) echo "профиль $1" ;;
  esac
}

# Одна запись лока в человекочитаемом виде: "YouTube/tls=28", "домен/tls=выкл".
# 0 — не номер стратегии, а «выключено»: диссинк для цели не применяется (VERDICT_PASS).
_client_scopes_lock_entry() {
  local target="$1" proto="$2" strat="$3" label
  case "$target" in
    [1-9]) label="$(_client_scopes_profile_label "$target")" ;;
    *) label="$target" ;;
  esac
  if [ "$strat" = 0 ]; then
    strat="выкл"
  fi
  printf '%s/%s=%s\n' "$label" "$proto" "$strat"
}

# Перенос записей (по одной в строке на входе) в строки не шире $1.
# $2 — префикс первой строки (например, "домены (23): ").
_client_scopes_wrap_entries() {
  local width="${1:-76}" prefix="${2:-}" line="" entry first=1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "$first" = 1 ]; then
      entry="${prefix}${entry}"
      first=0
    fi
    if [ -z "$line" ]; then
      line="$entry"
    elif [ "$(( ${#line} + ${#entry} + 2 ))" -le "$width" ]; then
      line="$line, $entry"
    else
      printf '%s\n' "$line"
      line="$entry"
    fi
  done
  if [ -n "$line" ]; then
    printf '%s\n' "$line"
  fi
  return 0
}

# Однострочная сводка локов scope с именами профилей и «выкл» вместо 0.
_client_scopes_lock_line() {
  local scope="$1" tab target proto strat out=""
  tab="$(printf '\t')"
  while IFS="$tab" read -r target proto strat; do
    if [ -n "$target" ]; then
      if [ -n "$out" ]; then
        out="$out, "
      fi
      out="$out$(_client_scopes_lock_entry "$target" "$proto" "$strat")"
    fi
  done <<< "$(client_scope_scope_locks "$scope" 2>/dev/null)"
  printf '%s\n' "$out"
}

# Блок локов одного scope: сперва профили (по номеру), затем домены (по алфавиту).
# У default доменных локов может быть много — список переносится по ширине.
_client_scopes_print_locks() {
  local scope="$1" tab target proto strat proles="" domains="" dcount
  tab="$(printf '\t')"
  while IFS="$tab" read -r target proto strat; do
    [ -n "$target" ] || continue
    case "$target" in
      [1-9]) proles="${proles}${target}${tab}${proto}${tab}${strat}
" ;;
      *) domains="${domains}${target}${tab}${proto}${tab}${strat}
" ;;
    esac
  done <<< "$(client_scope_scope_locks "$scope" 2>/dev/null)"
  [ -n "${proles}${domains}" ] || return 0
  echo ""
  echo -e "  ${cyan}Локи (${scope}):${plain}"
  if [ -n "$proles" ]; then
    printf '%s' "$proles" | LC_ALL=C sort | while IFS="$tab" read -r target proto strat; do
      if [ -n "$target" ]; then
        _client_scopes_lock_entry "$target" "$proto" "$strat"
      fi
    done | _client_scopes_wrap_entries "$CLIENT_SCOPES_WRAP_WIDTH" | sed 's/^/    /'
  fi
  if [ -n "$domains" ]; then
    dcount="$(printf '%s' "$domains" | grep -c .)"
    printf '%s' "$domains" | LC_ALL=C sort | while IFS="$tab" read -r target proto strat; do
      if [ -n "$target" ]; then
        _client_scopes_lock_entry "$target" "$proto" "$strat"
      fi
    done | _client_scopes_wrap_entries "$CLIENT_SCOPES_WRAP_WIDTH" "домены ($dcount): " | sed 's/^/    /'
  fi
  return 0
}

# Таблица: scope / IP. Локи — блоками под таблицей: у default это все локи
# оркестра (профили + домены), в одну строку они не помещаются.
# Данные — из client_scope_table / client_scope_scope_locks (orchestra_state.sh).
client_scopes_print_table() {
  local scope ips
  echo ""
  printf '  %-10s %s\n' "Scope" "IP"
  # Нормализация в ровно 2 колонки: read с IFS=таб схлопывает пустое поле,
  # и при IP="" локи попадали бы в колонку IP.
  while IFS="$(printf '\t')" read -r scope ips; do
    [ -n "$scope" ] || continue
    if [ "$scope" = default ]; then
      ips="все клиенты"
    elif [ -z "$ips" ]; then
      ips="—"
    fi
    printf '  %-10s %s\n' "$scope" "$ips"
  done <<< "$(client_scope_table | awk -F '\t' '{ print $1 "\t" $2 }')"
  while read -r scope; do
    if [ -n "$scope" ]; then
      _client_scopes_print_locks "$scope"
    fi
  done <<< "$(client_scope_table | cut -f1)"
  return 0
}

# Значение scoped-лока или пусто, если записи нет. В отличие от
# orch_scoped_locked_get, не подменяет «нет записи» на 0 — для сброса
# нужен именно факт отсутствия записи.
_client_scopes_scoped_value() {
  local scope="$1" profile="$2" proto="$3" file
  if [ "$scope" != default ]; then
    file="$(_orch_scope_lock_file "$scope")" || return 0
    [ -f "$file" ] || return 0
    awk -F '\t' -v pr="$profile" -v po="$proto" '$1==pr && $2==po {print $3; exit}' "$file"
  else
    [ -f "$ORCH_LOCK_FILE" ] || return 0
    awk -F '\t' -v pr="$profile" -v po="$proto" '
      $1==pr && $2==po && NF==3 {print $3; exit}
      $1==pr && po=="tls" && NF==2 {print $2; exit}
    ' "$ORCH_LOCK_FILE"
  fi
}

# Краткая подсказка «tls=28», «http=выкл», «udp=2 от default» (наследованный
# лок показывается со source-пометкой, 0 — как «выкл»).
_client_scopes_lock_hint() {
  local scope="$1" profile="$2" proto="$3" v src=""
  v="$(_client_scopes_scoped_value "$scope" "$profile" "$proto")"
  if [ -z "$v" ] && [ "$scope" != default ]; then
    v="$(_client_scopes_scoped_value default "$profile" "$proto")"
    src=" от default"
  fi
  if [ -z "$v" ]; then
    printf '%s=—' "$proto"
  else
    if [ "$v" = 0 ]; then
      v="выкл"
    fi
    printf '%s=%s%s' "$proto" "$v" "$src"
  fi
}

# Выбор scope из таблицы. Результат — $CLIENT_SCOPE_ASK_RESULT.
# $1 — опциональный preset (вопрос пропускается). 1 — отмена.
client_scopes_ask_scope() {
  local preset="${1:-}" ans list count scope
  if [ -n "$preset" ]; then
    CLIENT_SCOPE_ASK_RESULT="$preset"
    return 0
  fi
  list="$(client_scope_table | cut -f1)"
  count=0
  while IFS= read -r scope; do
    [ -n "$scope" ] || continue
    count=$((count + 1))
    if [ "$scope" = "default" ]; then
      submenu_item "$count" "default — все клиенты"
    else
      submenu_item "$count" "$scope"
    fi
  done <<< "$list"
  while true; do
    read -re -p "Выберите scope (1..$count, или mark:N, 0 — назад): " ans || return 1
    case "$ans" in
      0) return 1 ;;
      default) CLIENT_SCOPE_ASK_RESULT="default"; return 0 ;;
      mark:*)
        if client_scope_mark_validate "$ans" && printf '%s\n' "$list" | grep -Fqx "$ans"; then
          CLIENT_SCOPE_ASK_RESULT="$ans"
          return 0
        fi
        echo -e "${red}Такой клиент не найден.${plain}" ;;
      *)
        if ui_is_number_in_range "$ans" 1 "$count"; then
          CLIENT_SCOPE_ASK_RESULT="$(sed -n "${ans}p" <<< "$list")"
          return 0
        fi
        echo -e "${red}Неверный ввод.${plain}" ;;
    esac
  done
}

# LAN-мосты, из ARP-таблицы которых берём список устройств:
# Keenetic — br0 (и дополнительные brN), OpenWRT — br-lan.
client_scopes_lan_ifaces() {
  local b
  for b in br0 br-lan br1 br2; do
    if [ -d "/sys/class/net/$b" ]; then
      printf '%s\n' "$b"
    fi
  done
}

# IP устройств из ARP-таблицы LAN-мостов. Неполные записи (нулевой MAC)
# и уже привязанные к mark IP пропускаются.
client_scopes_lan_ip_list() {
  local iface ip
  for iface in $(client_scopes_lan_ifaces); do
    awk -v dev="$iface" '$6 == dev && $4 != "00:00:00:00:00:00" {print $1}' /proc/net/arp 2>/dev/null
  done | sort -u | while IFS= read -r ip; do
      if [ -n "$ip" ] && [ -z "$(client_scope_ip_get "$ip" 2>/dev/null)" ]; then
        printf '%s\n' "$ip"
      fi
    done
  return 0
}

# Ввод IP клиента: вручную или выбором из найденных устройств (ARP).
# Результат — $CLIENT_SCOPE_ASK_IP. 1 — отмена.
client_scopes_ask_ip() {
  local ip ans list count
  while true; do
    read -re -p "IP клиента (Enter — выбрать из найденных устройств, 0 — отмена): " ip || return 1
    case "$ip" in
      0) return 1 ;;
      "")
        list="$(client_scopes_lan_ip_list)"
        count=0
        if [ -n "$list" ]; then
          echo "Найденные устройства (ARP):"
          while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            count=$((count + 1))
            submenu_item "$count" "$ip"
          done <<< "$list"
        fi
        if [ "$count" -eq 0 ]; then
          echo -e "${yellow}В ARP-таблице подходящих устройств не найдено — введите IP вручную.${plain}"
          continue
        fi
        read -re -p "Выберите устройство (1..$count, 0 — ввести вручную): " ans || return 1
        case "$ans" in
          0) continue ;;
          *)
            if ui_is_number_in_range "$ans" 1 "$count"; then
              CLIENT_SCOPE_ASK_IP="$(sed -n "${ans}p" <<< "$list")"
              return 0
            fi
            echo -e "${red}Неверный ввод.${plain}" ;;
        esac
        continue
        ;;
      *)
        if client_scope_ip_validate "$ip"; then
          CLIENT_SCOPE_ASK_IP="$ip"
          return 0
        fi
        echo -e "${red}Некорректный IP-адрес.${plain}" ;;
    esac
  done
}

# Выбор mark: нумерованный список существующих групп (с их IP), «Новая группа»
# (авто — следующий свободный со 2-го: mark:1 зарезервирован под роутер)
# или ручной номер. Результат — $CLIENT_SCOPE_ASK_MARK. 1 — отмена.
client_scopes_ask_mark() {
  local next list count extra ans n ips scope
  if ! next="$(client_scope_next_mark)"; then
    next=""
    echo -e "${yellow}Свободных mark нет — можно добавить только в существующую группу.${plain}"
  fi
  while true; do
    list="$(client_scope_table | awk -F '\t' '$1 ~ /^mark:/ {print $1}')"
    count=0
    echo "Группы клиентов:"
    while IFS= read -r scope; do
      [ -n "$scope" ] || continue
      count=$((count + 1))
      ips="$(awk -F '\t' -v sc="$scope" '$1==sc { printf "%s%s", sep, $2; sep="," }' "$(client_scope_map_file)" 2>/dev/null)"
      if [ -n "$ips" ]; then
        submenu_item "$count" "$scope ($ips)"
      else
        submenu_item "$count" "$scope"
      fi
    done <<< "$list"
    if [ -n "$next" ]; then
      extra=$((count + 1))
      submenu_item "$extra" "Новая группа ($next)"
      read -re -p "Выберите группу (1..$count, Enter - новая $next, mark:N - вручную, 0 — отмена): " ans || return 1
      [ -n "$ans" ] || ans="$extra"
    else
      extra=0
      read -re -p "Выберите группу (1..$count, mark:N - вручную, 0 — отмена): " ans || return 1
      if [ -z "$ans" ]; then
        echo -e "${yellow}Свободных mark нет — выберите существующую группу или введите mark:N вручную.${plain}"
        continue
      fi
    fi
    case "$ans" in
      0) return 1 ;;
    esac
    if [ "$extra" != 0 ] && [ "$ans" = "$extra" ]; then
      CLIENT_SCOPE_ASK_MARK="$next"
      return 0
    fi
    if ui_is_number_in_range "$ans" 1 "$count"; then
      CLIENT_SCOPE_ASK_MARK="$(sed -n "${ans}p" <<< "$list")"
      return 0
    fi
    # Ручной ввод: mark:N или число — существующая группа или новая с номером.
    case "$ans" in
      mark:*) ;;
      [0-9]*) ans="mark:$ans" ;;
      *)
        echo -e "${red}Неверный ввод.${plain}"
        continue
        ;;
    esac
    n="${ans#mark:}"
    if [ "$n" = "1" ]; then
      echo -e "${yellow}mark:1 зарезервирован для собственного трафика роутера — выберите другой номер.${plain}"
      continue
    fi
    if ! client_scope_mark_validate "$ans"; then
      echo -e "${red}Некорректный mark (ожидается mark:N).${plain}"
      continue
    fi
    CLIENT_SCOPE_ASK_MARK="$ans"
    return 0
  done
}

# Выбор scope для меню стратегий: существующий (default/mark:N) или создание
# нового клиента IP → mark. Результат — $CLIENT_SCOPE_ASK_RESULT. 1 — отмена.
client_scopes_ask_scope_for_strategies() {
  local list count extra del ans scope ip
  while true; do
    clear -x
    client_scopes_print_header
    echo ""
    list="$(client_scope_table | cut -f1)"
    count=0
    while IFS= read -r scope; do
      [ -n "$scope" ] || continue
      count=$((count + 1))
      if [ "$scope" = "default" ]; then
        submenu_item "$count" "default — все клиенты"
      else
        submenu_item "$count" "$scope"
      fi
    done <<< "$list"
    extra=$((count + 1))
    del=$((count + 2))
    submenu_item "$extra" "Новый клиент (IP → mark)"
    submenu_item "$del" "Удалить клиента"
    read -re -p "Стратегии для клиента (1..$del, 0 — назад): " ans || return 1
    case "$ans" in
      0) return 1 ;;
      "$del")
        client_scopes_wizard_remove
        continue
        ;;
      "$extra")
        if ! client_scopes_ask_ip; then
          continue
        fi
        ip="$CLIENT_SCOPE_ASK_IP"
        if ! client_scopes_ask_mark; then
          continue
        fi
        if client_scope_ip_add "$ip" "$CLIENT_SCOPE_ASK_MARK"; then
          echo -e "${green}Сохранено: $ip → $CLIENT_SCOPE_ASK_MARK.${plain}"
          CLIENT_SCOPE_ASK_RESULT="$CLIENT_SCOPE_ASK_MARK"
          return 0
        fi
        echo -e "${red}Не удалось сохранить маппинг (проверьте IP и firewall backend).${plain}"
        continue
        ;;
      *)
        if ui_is_number_in_range "$ans" 1 "$count"; then
          CLIENT_SCOPE_ASK_RESULT="$(sed -n "${ans}p" <<< "$list")"
          return 0
        fi
        echo -e "${red}Неверный ввод.${plain}" ;;
    esac
  done
}

# Короткая строка «mark:82 (192.168.0.82)» для заголовка меню стратегий.
client_scopes_scope_label() {
  local scope="${1:-default}" ips
  if [ "$scope" = default ]; then
    printf '%s\n' "default (все клиенты)"
    return 0
  fi
  ips="$(client_scope_table | awk -F '\t' -v sc="$scope" '$1==sc {print $2; exit}')"
  if [ -n "$ips" ]; then
    printf '%s (%s)\n' "$scope" "$ips"
  else
    printf '%s\n' "$scope"
  fi
}

# Выбор профиля (1..7 — основные профили со стратегиями), с текущими локами.
# $1 — scope, для которого показываем локи. Результат — $CLIENT_SCOPE_ASK_PROFILE.
# 1 — отмена.
client_scopes_ask_profile() {
  local p max ans cfg hint
  cfg="$(client_scopes_cfg)"
  for p in 1 2 3 4 5 6 7; do
    max="$(config_profile_max_strategy "$p" "$cfg" 2>/dev/null || echo 0)"
    hint="$(_client_scopes_locks_hint "${1:-default}" "$p")"
    if [ -n "$hint" ]; then
      submenu_item "$p" "$(config_profile_title "$p") [$max] — $hint"
    else
      submenu_item "$p" "$(config_profile_title "$p") [$max]"
    fi
  done
  while true; do
    read -re -p "Выберите профиль (1..7, 0 — назад): " ans || return 1
    if ui_is_number_in_range "$ans" 1 7; then
      CLIENT_SCOPE_ASK_PROFILE="$ans"
      return 0
    fi
    case "$ans" in 0) return 1 ;; esac
    echo -e "${red}Неверный ввод.${plain}"
  done
}

# Текущие локи профиля одной строкой: "tls=выкл, http=28 от default".
_client_scopes_locks_hint() {
  local scope="$1" profile="$2" proto hint=""
  for proto in $(config_profile_proto_list "$profile"); do
    if [ -n "$hint" ]; then
      hint="$hint, "
    fi
    hint="$hint$(_client_scopes_lock_hint "$scope" "$profile" "$proto")"
  done
  printf '%s\n' "$hint"
}

# Выбор протокола. Если у профиля их несколько — можно оба сразу.
# Результат — $CLIENT_SCOPE_ASK_PROTO (один протокол или список через пробел).
# 1 — отмена.
client_scopes_ask_proto() {
  local list="$1" proto ans n=0 i=1
  for proto in $list; do n=$((n + 1)); done
  if [ "$n" -eq 1 ]; then
    CLIENT_SCOPE_ASK_PROTO="$list"
    return 0
  fi
  i=1
  for proto in $list; do
    submenu_item "$i" "$proto"
    i=$((i + 1))
  done
  submenu_item "$((n + 1))" "оба протокола"
  while true; do
    read -re -p "Протокол (1..$((n + 1)), Enter - оба, 0 — назад): " ans || return 1
    if [ -z "$ans" ] || [ "$ans" = "$((n + 1))" ]; then
      CLIENT_SCOPE_ASK_PROTO="$list"
      return 0
    fi
    if ui_is_number_in_range "$ans" 1 "$n"; then
      i=1
      for proto in $list; do
        if [ "$i" -eq "$ans" ]; then
          CLIENT_SCOPE_ASK_PROTO="$proto"
          return 0
        fi
        i=$((i + 1))
      done
    fi
    case "$ans" in 0) return 1 ;; esac
    echo -e "${red}Неверный ввод.${plain}"
  done
}

# Выбор стратегии по конвенции проекта: 0 - выкл диссинка, Enter - без
# изменений. C — сброс лока (удалить запись, наследовать default).
# $1 — профиль, $2 — список протоколов, $3 — scope.
# Результат — $CLIENT_SCOPE_ASK_STRATEGY (число 1..max, 0 или "clear").
# 1 — отмена (ничего не сохраняется).
client_scopes_ask_strategy() {
  local profile="$1" proto_list="$2" scope="$3"
  local max ans cfg proto hint_line
  cfg="$(client_scopes_cfg)"
  max="$(config_profile_max_strategy "$profile" "$cfg" 2>/dev/null || echo 0)"
  hint_line=""
  for proto in $proto_list; do
    if [ -n "$hint_line" ]; then
      hint_line="$hint_line, "
    fi
    hint_line="$hint_line$(_client_scopes_lock_hint "$scope" "$profile" "$proto")"
  done
  echo "Сейчас: $hint_line"
  while true; do
    read -re -p "Номер стратегии 1..$max (0 - выкл диссинка, C - сброс, Enter - без изменений): " ans || return 1
    [ -n "$ans" ] || return 1
    case "$ans" in
      0)
        CLIENT_SCOPE_ASK_STRATEGY="0"
        return 0 ;;
      c|C|с|С)
        CLIENT_SCOPE_ASK_STRATEGY="clear"
        return 0 ;;
    esac
    if ui_is_number_in_range "$ans" 1 "$max"; then
      CLIENT_SCOPE_ASK_STRATEGY="$ans"
      return 0
    fi
    echo -e "${red}Неверный ввод.${plain}"
  done
}

# Мастер: добавить клиента (IP → mark) с автоназначением mark.
client_scopes_wizard_add() {
  local ip scope ans
  if ! client_scopes_ask_ip; then
    return 1
  fi
  ip="$CLIENT_SCOPE_ASK_IP"
  scope="$(client_scope_ip_get "$ip")"
  if [ -n "$scope" ]; then
    echo "У IP уже есть scope $scope."
    read -re -p "Изменить? (y/N): " ans || return 0
    case "$ans" in
      y|Y|да|Д|д) ;;
      *) return 0 ;;
    esac
  fi
  if ! client_scopes_ask_mark; then
    return 1
  fi
  scope="$CLIENT_SCOPE_ASK_MARK"
  if ! client_scope_ip_add "$ip" "$scope"; then
    echo -e "${red}Не удалось сохранить маппинг (проверьте IP, scope и firewall backend).${plain}"
    return 1
  fi
  echo -e "${green}Сохранено: $ip → $scope.${plain}"
  if [ "$(client_scope_mode_text)" != "включен" ]; then
    read -re -p "Включить Client scopes? (y/N): " ans || return 0
    case "$ans" in
      y|Y|да|Д|д)
        if client_scope_mode_set 1; then
          echo -e "${green}Client scopes включены.${plain}"
        else
          echo -e "${red}Не удалось включить режим.${plain}"
        fi
        ;;
    esac
  fi
  read -re -p "Настроить lock для этого клиента? (y/N): " ans || return 0
  case "$ans" in
    y|Y|да|Д|д) client_scopes_wizard_lock "$scope" ;;
  esac
}

# Мастер: настроить lock (scope → профиль → протокол(ы) → стратегия).
# $1 — опциональный preset scope (таблица не печатается, scope не спрашивается).
client_scopes_wizard_lock() {
  local scope profile proto_list proto strategy saved
  if [ -z "${1:-}" ]; then
    client_scopes_print_table
    if ! client_scopes_ask_scope; then
      return 0
    fi
  else
    client_scopes_ask_scope "$1" || return 0
  fi
  scope="$CLIENT_SCOPE_ASK_RESULT"
  if ! client_scopes_ask_profile "$scope"; then
    return 0
  fi
  profile="$CLIENT_SCOPE_ASK_PROFILE"
  if ! client_scopes_ask_proto "$(config_profile_proto_list "$profile")"; then
    echo -e "${red}Не удалось определить протоколы профиля $profile.${plain}"
    return 1
  fi
  proto_list="$CLIENT_SCOPE_ASK_PROTO"
  if ! client_scopes_ask_strategy "$profile" "$proto_list" "$scope"; then
    return 0
  fi
  strategy="$CLIENT_SCOPE_ASK_STRATEGY"
  for proto in $proto_list; do
    if [ "$strategy" = clear ]; then
      if ! orch_scoped_locked_clear "$scope" "$profile" "$proto"; then
        echo -e "${red}Не удалось сбросить lock ($proto).${plain}"
        return 1
      fi
    elif ! orch_scoped_locked_set "$scope" "$profile" "$proto" "$strategy"; then
      echo -e "${red}Не удалось сохранить lock ($proto): некорректные параметры или конфликт.${plain}"
      return 1
    fi
  done
  if [ "$strategy" = clear ]; then
    if [ "$scope" = default ]; then
      echo -e "${green}Lock сброшен: профиль $profile ($(config_profile_title "$profile")) вернётся к авторотации оркестра.${plain}"
    else
      echo -e "${green}Lock сброшен: $scope / профиль $profile ($(config_profile_title "$profile")) наследует default.${plain}"
    fi
  else
    saved="$strategy"
    if [ "$strategy" = 0 ]; then
      saved="выкл (диссинк не применяется)"
    fi
    echo -e "${green}Lock сохранён: $scope / профиль $profile ($(config_profile_title "$profile")) / $proto_list → $saved.${plain}"
  fi
  echo "Lock'и scope: $(_client_scopes_lock_line "$scope")"
}

# Мастер: удалить клиента (все IP scope + опционально его lock'и).
# Удалить все локи scope (per-mark файл целиком / default-строки не трогаем).
client_scopes_clear_scope_locks() {
  local scope="$1" prof pproto rc=0
  while IFS="$(printf '\t')" read -r prof pproto _; do
    [ -n "$prof" ] || continue
    orch_scoped_locked_clear "$scope" "$prof" "$pproto" || rc=1
  done <<< "$(client_scope_scope_locks "$scope")"
  return "$rc"
}

client_scopes_wizard_remove() {
  local scope ans ip was_enabled was_running=0 rc ips count choice rest
  client_scopes_print_table
  if [ -z "$(client_scope_table | cut -f1 | grep '^mark:')" ]; then
    echo -e "${yellow}Нет клиентов для удаления.${plain}"
    return 0
  fi
  if ! client_scopes_ask_scope; then
    return 0
  fi
  scope="$CLIENT_SCOPE_ASK_RESULT"
  case "$scope" in
    default)
      echo -e "${yellow}default — это все клиенты, удалять нечего. Выберите mark:N.${plain}"
      return 0 ;;
  esac
  # В группе несколько IP — можно удалить один, не трогая остальных.
  ips="$(awk -F '\t' -v sc="$scope" '$1==sc {print $2}' "$(client_scope_map_file)" 2>/dev/null)"
  count=0
  for ip in $ips; do
    count=$((count + 1))
  done
  if [ "$count" -gt 1 ]; then
    echo "В группе $scope несколько IP:"
    count=0
    for ip in $ips; do
      count=$((count + 1))
      submenu_item "$count" "$ip"
    done
    submenu_item "$((count + 1))" "Удалить всю группу (все IP и локи)"
    submenu_item "$((count + 2))" "Сбросить локи группы (IP останутся)"
    read -re -p "Выберите действие (1..$((count + 2)), 0 — отмена): " choice || return 0
    case "$choice" in
      0) return 0 ;;
      "$((count + 2))")
        # Отдельный сброс локов: клиент остаётся, стратегии возвращаются
        # к default (наследованию).
        if [ -z "$(client_scope_scope_locks "$scope")" ]; then
          echo -e "${yellow}У группы $scope нет локов.${plain}"
          return 0
        fi
        read -re -p "Сбросить все локи $scope (стратегии вернутся к default)? (y/N): " ans || return 0
        case "$ans" in
          y|Y|да|Д|д)
            client_scopes_clear_scope_locks "$scope"
            echo -e "${green}Локи группы $scope сброшены — стратегии наследуются от default.${plain}"
            ;;
        esac
        return 0
        ;;
      "$((count + 1))") ;;   # вся группа — обычный путь ниже
      *)
        if ui_is_number_in_range "$choice" 1 "$count"; then
          ip="$(printf '%s\n' "$ips" | sed -n "${choice}p")"
          if client_scope_ip_remove "$ip"; then
            rest="$(awk -F '\t' -v sc="$scope" '$1==sc { printf "%s%s", sep, $2; sep="," }' "$(client_scope_map_file)" 2>/dev/null)"
            echo -e "${green}IP $ip удалён из группы $scope. Осталось: $rest${plain}"
          else
            echo -e "${red}Не удалось удалить $ip.${plain}"
            return 1
          fi
          return 0
        fi
        echo -e "${red}Неверный ввод.${plain}"
        return 0
        ;;
    esac
  fi
  # Очистка — самостоятельное действие: подтверждённое «да» применяется сразу,
  # даже если следующим вопросом отменить удаление IP/группы.
  if [ -n "$(client_scope_scope_locks "$scope")" ]; then
    read -re -p "Удалить lock'и этого клиента? (y/N): " ans || return 0
    case "$ans" in
      y|Y|да|Д|д)
        if client_scopes_clear_scope_locks "$scope"; then
          echo -e "${green}Lock'и клиента удалены — стратегии наследуются от default.${plain}"
        else
          echo -e "${red}Не удалось полностью удалить lock'и клиента.${plain}"
          return 1
        fi
        ;;
    esac
  fi
  read -re -p "Удалить $scope и все его IP? (y/N): " ans || return 0
  case "$ans" in
    y|Y|да|Д|д) ;;
    *) return 0 ;;
  esac
  was_enabled="$(client_scope_mode_text)"
  if [ -n "${ZAPRET2_INIT:-}" ] && zapret2_running; then
    was_running=1
  fi
  for ip in $(awk -F '\t' -v sc="$scope" '$1==sc {print $2}' "$(client_scope_map_file)"); do
    if ! client_scope_ip_remove "$ip"; then
      echo -e "${red}Не удалось удалить $ip.${plain}"
      return 1
    fi
  done
  echo -e "${green}Клиент $scope удалён.${plain}"
  # Последний клиент — не повод молча гасить режим: часто это часть
  # переформирования группы. Спрашиваем, дефолт — оставить включённым
  # (новый клиент подхватит правила автоматически).
  if [ "$was_enabled" = "включен" ] && [ -z "$(client_scope_ip_list)" ]; then
    read -re -p "Это был последний клиент — выключить режим Client scopes? (y/N): " ans || return 0
    case "$ans" in
      y|Y|да|Д|д)
        if client_scope_mode_set 0; then
          echo -e "${yellow}Режим Client scopes выключен.${plain}"
        else
          rc=$?
          [ "$was_running" = 1 ] && client_scope_daemon_reload 1 || true
          echo -e "${red}Не удалось выключить режим (сбой перезапуска nfqws2).${plain}"
          return "$rc"
        fi
        ;;
      *)
        echo -e "${yellow}Режим оставлен включённым: добавьте нового клиента — правила появятся автоматически.${plain}"
        ;;
    esac
  fi
}

# Пункт 11: сводка состояния + мастера.
client_scopes_submenu() {
  while true; do
    clear -x
    client_scopes_print_header
    client_scopes_print_table
    submenu_item "1" "Добавить клиента (IP → mark)" ""
    submenu_item "2" "Настроить клиента (lock)" ""
    submenu_item "3" "Удалить клиента" ""
    submenu_item "4" "Включить/выключить режим" ""
    submenu_item "0" "Назад" ""
    read -re -p "Ваш выбор: " ans || return
    case "$ans" in
      1) client_scopes_wizard_add || true; pause_enter ;;
      2) client_scopes_wizard_lock || true; pause_enter ;;
      3) client_scopes_wizard_remove || true; pause_enter ;;
      4) client_scopes_toggle_mode || true; pause_enter ;;
      0|"") return ;;
      *) ui_invalid_input ;;
    esac
  done
}

client_scope_mode_text() {
  local cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [ "$(config_get_var "$cfg" CLIENT_SCOPE_ENABLE 2>/dev/null || printf 0)" = 1 ] && printf 'включен' || printf 'выключен'
}

# Пункт 22: тонкая обёртка над централизованным setter'ом (config.sh).
toggle_client_scope_mode() {
  if [ "$(client_scope_mode_text)" = "включен" ]; then
    client_scope_mode_set 0 || return 1
    echo -e "${yellow}Client scopes (Beta) выключены.${plain}"
  else
    # Онбординг: включать нечего — добавляем первого клиента здесь же.
    # Иначе тупик: меню 1 показывает выбор клиента только при включённом
    # режиме, а включение требует хотя бы одного маппинга.
    if [ -z "$(client_scope_ip_list)" ]; then
      local ans
      echo -e "${yellow}Клиентов ещё нет — сначала добавим первого, затем включим режим.${plain}"
      read -re -p "Добавить клиента сейчас? (Y/n): " ans || return 1
      case "$ans" in
        n|N|нет|Н|н)
          echo "Включение отменено: добавьте IP-маппинг (пункт 23 или меню 1 после включения)."
          return 1
          ;;
      esac
      if ! client_scopes_ask_ip; then
        echo "Включение отменено."
        return 1
      fi
      if ! client_scopes_ask_mark; then
        echo "Включение отменено."
        return 1
      fi
      if ! client_scope_ip_add "$CLIENT_SCOPE_ASK_IP" "$CLIENT_SCOPE_ASK_MARK"; then
        echo -e "${red}Не удалось сохранить маппинг (проверьте IP и firewall backend).${plain}"
        return 1
      fi
      echo -e "${green}Сохранено: $CLIENT_SCOPE_ASK_IP → $CLIENT_SCOPE_ASK_MARK.${plain}"
    fi
    client_scope_mode_set 1 || { echo -e "${red}Не удалось включить Client scopes (Beta).${plain}"; return 1; }
    echo -e "${green}Client scopes (Beta) включены. Настройка стратегий — меню 1.${plain}"
  fi
}

# Пункт 4 внутри 11: переключение режима с подтверждением.
client_scopes_toggle_mode() {
  local current
  current="$(client_scope_mode_text)"
  if [ "$current" = "включен" ]; then
    read -re -p "Выключить Client scopes? (y/N): " ans || return 0
    case "$ans" in
      y|Y|да|Д|д)
        if client_scope_mode_set 0; then
          echo -e "${yellow}Client scopes выключены.${plain}"
        else
          echo -e "${red}Не удалось выключить режим.${plain}"
        fi
        ;;
    esac
  else
    read -re -p "Включить Client scopes? (y/N): " ans || return 0
    case "$ans" in
      y|Y|да|Д|д)
        if client_scope_mode_set 1; then
          echo -e "${green}Client scopes включены.${plain}"
        else
          echo -e "${red}Не удалось включить режим (нужен хотя бы один IP-маппинг).${plain}"
        fi
        ;;
    esac
  fi
}

#функция меню "1. Сменить стратегии"
strategies_submenu() {
  local SUBMENU_ITEM_INDENT=1
  # Client scopes (Beta): при включённом режиме сначала выбираем/создаём
  # клиента (mark), под которого настраиваем стратегии, и проваливаемся
  # в привычное меню уже в его контексте. При выключенном режиме меню
  # открывается сразу, как раньше, без вопросов. Сменить клиента внутри —
  # пункт 12.
  ORCH_ACTIVE_SCOPE="default"
  if [ "$(client_scope_mode_text)" = "включен" ]; then
    if client_scopes_ask_scope_for_strategies; then
      ORCH_ACTIVE_SCOPE="$CLIENT_SCOPE_ASK_RESULT"
    else
      return 0
    fi
  fi
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
    if [ "$(client_scope_mode_text)" = "включен" ]; then
      echo -e "${yellow}Клиент: $(client_scopes_scope_label "$ORCH_ACTIVE_SCOPE")${plain}"
    fi
    echo -e "${yellow}Выбор стратегии профиля (0 или Enter для выхода)${plain}"
    echo -e "  Текущие стратегии [${strategies_status}]"
    echo -e 

    if [ "$auto_enabled" = "1" ]; then
      echo -e "${Fcyan}	1-4.${plain} ${red}Ручной выбор TCP-стратегий недоступен при авторотации${plain}"
    else
      submenu_item "1" "Профиль 1: TCP 443 (YouTube) [${MENU_PROFILE_MAX_1:-0}]" "tls" "$STRATEGY_STATE_YT_TLS"
      submenu_item "2" "Профиль 2: TCP 443 (Googlevideo) [${MENU_PROFILE_MAX_2:-0}]" "tls" "$STRATEGY_STATE_GV_TLS"
      submenu_item "3" "Профиль 3: TCP 443 (RKN) [${MENU_PROFILE_MAX_3:-0}]" "tls" "$STRATEGY_STATE_RKN_TLS"
      submenu_item "4" "Профиль 4: TCP 443 (Discord) [${MENU_PROFILE_MAX_4:-0}]" "tls" "$STRATEGY_STATE_DS_TLS"
    fi
    submenu_item "5" "Профиль 5: UDP 443 (QUIC) [${MENU_PROFILE_MAX_5:-0}]" "udp" "$STRATEGY_STATE_YT_QUIC_UDP"
    submenu_item "6" "Профиль 6: UDP Voice (Discord/STUN) [${MENU_PROFILE_MAX_6:-0}]" "udp" "$STRATEGY_STATE_VOICE_UDP"
    if [ "$games_disabled" = "1" ]; then
      echo -e "${Fcyan}	7.${plain} ${red}Профиль 7: UDP Games (1026-65531) [${MENU_PROFILE_MAX_7:-0}]${plain} ${red}[выключен — включите обход UDP, п.10]${plain}"
    else
      submenu_item "7" "Профиль 7: UDP Games (1026-65531) [${MENU_PROFILE_MAX_7:-0}]" "udp" "$STRATEGY_STATE_GAMES_UDP"
    fi
    if [ "$auto_enabled" = "1" ]; then
      echo -e "${Fcyan}	8-9.${plain} ${red}Ручной выбор fallback недоступен при авторотации${plain}"
    elif [ "$fb_disabled" = "1" ]; then
      echo -e "${Fcyan}	8.${plain} ${red}Fallback TLS (безразборный блок)${plain} ${red}[выключен — включите безразборный режим, п.13]${plain}"
      echo -e "${Fcyan}	9.${plain} ${red}Fallback HTTP (безразборный блок) [${MENU_PROFILE_MAX_9:-0}]${plain} ${red}[выключен — включите безразборный режим, п.13]${plain}"
    else
      submenu_item "8" "Fallback TLS (безразборный блок)" "" "$STRATEGY_STATE_FB_TLS"
      submenu_item "9" "Fallback HTTP (безразборный блок) [${MENU_PROFILE_MAX_9:-0}]" "" "$STRATEGY_STATE_FB_HTTP"
    fi
    submenu_item "10" "Авторотация TCP/HTTP [${auto_state}]"
    submenu_item "0" "Назад"
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
        ORCH_ACTIVE_SCOPE="default"
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

# --- Watchdog zapret2: включение/выключение (пункт 19-6) ---
# Файлы докачиваются с репозитория при отсутствии (z2r_download_project_file),
# поэтому в ветке они живут как исходники, а на роутере появляются по требованию.

watchdog_entware_script() { printf '%s\n' "${ZATOR_ROOT:-/opt/zator}/z2r_lib/zapret2-watchdog"; }
# Пути автозапуска переопределяются через env (тесты подставляют временные файлы).
watchdog_entware_init() { printf '%s\n' "${Z2R_ENTWARE_INIT:-/opt/etc/init.d/S91zapret2-watchdog}"; }
watchdog_wrt_init() { printf '%s\n' "${Z2R_WRT_INIT:-/etc/init.d/zapret2-watchdog}"; }

watchdog_supported() { [ "${OSystem:-}" = "entware" ] || [ "${OSystem:-}" = "WRT" ]; }

# Проверка, что pid действительно принадлежит нашему демону watchdog: pid мог
# переиспользоваться посторонним процессом после смерти демона — такому
# сигналить (TERM/KILL) нельзя. Сверяются строго ПЕРВЫЕ аргументы cmdline с
# каноническим путём нашего скрипта: либо сам скрипт как argv[0] (прямой
# запуск), либо «sh наш-скрипт …» — при shebang-запуске ядро подставляет
# интерпретатор первым аргументом. Упоминание пути в дальних аргументах
# чужого процесса и тот же basename из другого каталога «нашими» не
# считаются — fail-closed безопаснее ложного kill. /proc/pid/exe здесь не
# помощник: для скриптов он указывает на busybox, как и у любого процесса.
wd_pid_is_ours() {
  local script cmdl line1 line2
  script="$(watchdog_entware_script)"
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "/proc/$1/cmdline" ] || return 1
  cmdl="$(tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null)"
  line1="$(printf '%s\n' "$cmdl" | sed -n 1p)"
  line2="$(printf '%s\n' "$cmdl" | sed -n 2p)"
  [ -n "$line1" ] || return 1
  if [ "$line1" = "$script" ]; then
    return 0
  fi
  case "$line1" in
    sh | */sh) [ "$line2" = "$script" ] && return 0 ;;
  esac
  return 1
}

# Статус для меню: работает / выключен / не установлен / недоступно.
watchdog_status_text() {
  local target
  if ! watchdog_supported; then
    printf '%s\n' "недоступно"
    return 0
  fi
  if [ "${OSystem:-}" = "WRT" ]; then
    target="$(watchdog_wrt_init)"
  else
    target="$(watchdog_entware_script)"
  fi
  if [ ! -x "$target" ]; then
    printf '%s\n' "не установлен"
  elif "$target" status >/dev/null 2>&1; then
    printf '%s\n' "работает"
  else
    printf '%s\n' "выключен"
  fi
}

# Переключатель: не установлен/выключен → скачать (если нужно) + включить
# в автозагрузку + запустить; работает → остановить и убрать из автозагрузки.
# Каждый небыстрый шаг печатается ДО его выполнения: остановка идёт до ~35
# секунд (демон выходит только после текущего цикла проверки), молчание в
# это время выглядит как зависание меню.
# Все шаги проверяются на ошибку: частично применённое состояние — это
# ненулевой код возврата и откат там, где возможно; вызывающий код использует
# «watchdog_toggle || true», поэтому рассчитывать на set -e нельзя.
watchdog_toggle() {
  local script init
  if ! watchdog_supported; then
    echo -e "${yellow}Watchdog доступен на Keenetic/Entware и OpenWRT.${plain}"
    return 1
  fi
  if [ "${OSystem:-}" = "WRT" ]; then
    init="$(watchdog_wrt_init)"
    if [ -x "$init" ] && "$init" status >/dev/null 2>&1; then
      echo -e "${cyan}Останавливаю watchdog и убираю из автозагрузки (procd)...${plain}"
      echo -e "${yellow}Подождите: остановка занимает до ~35 секунд (демон завершается после текущего цикла проверки) — это не зависание.${plain}"
      if ! "$init" stop >/dev/null 2>&1; then
        echo -e "${red}Не удалось остановить watchdog.${plain}"
        return 1
      fi
      if ! "$init" disable >/dev/null 2>&1; then
        echo -e "${red}Watchdog остановлен, но убрать его из автозагрузки не удалось.${plain}"
        return 1
      fi
      echo -e "${yellow}Watchdog остановлен и убран из автозагрузки.${plain}"
      return 0
    fi
    if [ ! -x "$init" ]; then
      echo -e "${cyan}Скачиваю watchdog с репозитория (init.d/openwrt/zapret2-watchdog)...${plain}"
      if ! z2r_download_project_file "$init" "init.d/openwrt/zapret2-watchdog"; then
        echo -e "${red}Не удалось скачать watchdog с репозитория.${plain}"
        return 1
      fi
      if ! chmod +x "$init"; then
        echo -e "${red}Не удалось сделать init-скрипт watchdog исполняемым.${plain}"
        return 1
      fi
    fi
    echo -e "${cyan}Включаю автозапуск и запускаю watchdog (procd)...${plain}"
    if ! "$init" enable >/dev/null 2>&1; then
      echo -e "${red}Не удалось включить автозапуск watchdog.${plain}"
      return 1
    fi
    if ! "$init" start; then
      echo -e "${red}Watchdog не удалось запустить — посмотрите лог: /opt/zator/z2r_lib/zapret2-watchdog.log${plain}"
      # откат: не оставляем в автозагрузке то, что не запустилось
      "$init" disable >/dev/null 2>&1
      return 1
    fi
    echo -e "${green}Watchdog установлен и включён (автозапуск).${plain}"
    return 0
  fi
  script="$(watchdog_entware_script)"
  init="$(watchdog_entware_init)"
  if [ -x "$script" ] && "$script" status >/dev/null 2>&1; then
    echo -e "${cyan}Останавливаю watchdog и убираю из автозагрузки...${plain}"
    echo -e "${yellow}Подождите: остановка занимает до ~35 секунд (демон доигрывает текущий 30-секундный цикл проверки и выходит) — это не зависание.${plain}"
    if ! "$script" stop; then
      echo -e "${red}Не удалось остановить watchdog.${plain}"
      return 1
    fi
    if ! rm -f "$init" || [ -e "$init" ]; then
      echo -e "${red}Watchdog остановлен, но убрать обёртку автозапуска ($init) не удалось.${plain}"
      return 1
    fi
    echo -e "${yellow}Watchdog остановлен и убран из автозагрузки.${plain}"
    return 0
  fi
  if [ ! -x "$script" ]; then
    echo -e "${cyan}Скачиваю watchdog с репозитория (Entware/zapret2-watchdog)...${plain}"
    if ! z2r_download_project_file "$script" "Entware/zapret2-watchdog"; then
      echo -e "${red}Не удалось скачать watchdog с репозитория.${plain}"
      return 1
    fi
    if ! chmod +x "$script"; then
      echo -e "${red}Не удалось сделать скрипт watchdog исполняемым.${plain}"
      return 1
    fi
  fi
  echo -e "${cyan}Настраиваю автозапуск и запускаю watchdog...${plain}"
  if ! mkdir -p "$(dirname "$init")"; then
    echo -e "${red}Не удалось создать каталог автозапуска ($(dirname "$init")).${plain}"
    return 1
  fi
  cat > "$init" <<WRAPPER || { echo -e "${red}Не удалось создать обёртку автозапуска ($init).${plain}"; rm -f "$init"; return 1; }
#!/bin/sh
# Автозапуск watchdog zapret2 (создан z2r, пункт 19-6). Сам watchdog: $script
case "\$1" in
  start|stop|restart|status) exec "$script" "\$1" ;;
  *) echo "usage: \$0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
WRAPPER
  if ! chmod +x "$init"; then
    echo -e "${red}Не удалось сделать обёртку автозапуска исполняемой ($init).${plain}"
    rm -f "$init"
    return 1
  fi
  if "$script" start; then
    echo -e "${green}Watchdog установлен и включён (автозапуск $init).${plain}"
  else
    echo -e "${red}Watchdog не удалось запустить — посмотрите лог: /opt/zator/z2r_lib/zapret2-watchdog.log${plain}"
    # откат: не оставляем автозапуск того, что не запустилось
    rm -f "$init"
    return 1
  fi
}

# Полное снятие watchdog при удалении zapret2/zator (пункты меню 4 и 44):
# остановить демона и убрать его файлы (скрипт, конфиг, обёртку автозапуска,
# лог). При обновлении/переустановке zapret2 НЕ вызывается — там watchdog
# сознательно переживает обновление: init-скрипт zapret2 вернётся на место.
# Каждый шаг проверяется по факту: неполная зачистка — это ненулевой код
# возврата и явное предупреждение (вызывающий код печатает свою ошибку через
# «|| echo», и он должен реально срабатывать).
watchdog_uninstall() {
  local script init conf pidfile pid i killed=0 removed=0 errors=0
  conf="${ZATOR_ROOT:-/opt/zator}/z2r_lib/zapret2-watchdog.conf"
  if ! watchdog_supported; then
    return 0
  fi
  if [ "${OSystem:-}" = "WRT" ]; then
    init="$(watchdog_wrt_init)"
    if [ -e "$init" ]; then
      removed=1
      if [ -x "$init" ]; then
        if ! "$init" stop >/dev/null 2>&1; then
          errors=$((errors + 1))
        fi
        if ! "$init" disable >/dev/null 2>&1; then
          errors=$((errors + 1))
        fi
      fi
      rm -f "$init"
      if [ -e "$init" ]; then
        errors=$((errors + 1))
      fi
    fi
  else
    script="$(watchdog_entware_script)"
    init="$(watchdog_entware_init)"
    pidfile="${Z2R_WATCHDOG_PIDFILE:-/opt/var/run/zapret2-watchdog.pid}"
    # pidfile и живого демона зачищаем ВСЕГДА, даже если файлы установки уже
    # частично удалены: иначе демон останется висеть сиротой без файлов.
    pid=""
    [ -r "$pidfile" ] && pid=$(cat "$pidfile" 2>/dev/null)
    if wd_pid_is_ours "$pid"; then
      killed=1
      # Быстрая остановка: TERM, 3 секунды, KILL. Штатный stop ждёт до ~35
      # секунд (демон выходит после текущего sleep) — для удаления долго, а
      # оставлять живым процесс, файл скрипта которого сейчас снесём, нельзя.
      kill "$pid" 2>/dev/null
      i=0
      while [ "$i" -lt 3 ] && wd_pid_is_ours "$pid"; do
        sleep 1
        i=$((i + 1))
      done
      # повторная сверка перед KILL: pid мог переиспользоваться посторонним
      if wd_pid_is_ours "$pid"; then
        kill -9 "$pid" 2>/dev/null
        sleep 1
        if wd_pid_is_ours "$pid"; then
          errors=$((errors + 1))
        fi
      fi
    fi
    rm -f "$pidfile"
    if [ -e "$pidfile" ]; then
      errors=$((errors + 1))
    fi
    if [ -e "$script" ] || [ -e "$init" ]; then
      removed=1
    fi
    rm -f "$init" "$script"
    if [ -e "$init" ] || [ -e "$script" ]; then
      errors=$((errors + 1))
    fi
  fi
  # Конфиг общий для WRT и Entware и мог осиротеть раньше скрипта —
  # чистим его вне платформенных веток
  if [ -e "$conf" ]; then
    removed=1
  fi
  rm -f "$conf"
  if [ -e "$conf" ]; then
    errors=$((errors + 1))
  fi
  # лог: новая локация в root-owned /opt/zator/z2r_lib + старая в /tmp
  # (осталась от прежних версий watchdog); зачистка лога best-effort
  rm -f /tmp/zapret2-watchdog.log 2>/dev/null || :
  rm -f "${ZATOR_ROOT:-/opt/zator}/z2r_lib/zapret2-watchdog.log" 2>/dev/null || :
  if [ "$errors" -gt 0 ]; then
    echo -e "${red}Watchdog удалён не полностью: часть шагов завершилась с ошибкой — процесс или файлы могли остаться.${plain}"
    return 1
  fi
  if [ "$removed" = 1 ] || [ "$killed" = 1 ]; then
    echo -e "${yellow}Watchdog остановлен и удалён (демон, автозапуск, файлы).${plain}"
  fi
  return 0
}

# После обновления/переустановки zapret2: демон мог самоостановиться, пока
# init-скрипт zapret2 отсутствовал (удаление и новая установка идут минуты).
# Если watchdog был включён — поднимаем его обратно. Неудачный запуск — это
# предупреждение и ненулевой код возврата: установщик продолжит работу через
# «|| true», но пользователь увидит, что watchdog остался выключен.
watchdog_ensure_running() {
  local target init
  watchdog_supported || return 0
  if [ "${OSystem:-}" = "WRT" ]; then
    target="$(watchdog_wrt_init)"
    [ -x "$target" ] && "$target" enabled >/dev/null 2>&1 || return 0
  else
    target="$(watchdog_entware_script)"
    init="$(watchdog_entware_init)"
    # Обёртка автозапуска = признак «был включён»: нет её — не поднимаем.
    [ -x "$target" ] && [ -x "$init" ] || return 0
  fi
  "$target" status >/dev/null 2>&1 && return 0
  if ! "$target" start >/dev/null 2>&1; then
    echo -e "${red}Watchdog zapret2 НЕ смог запуститься после обновления — включите его вручную (пункт 19-6), лог: /opt/zator/z2r_lib/zapret2-watchdog.log${plain}"
    return 1
  fi
  echo -e "${green}Watchdog zapret2 снова запущен (пережил обновление).${plain}"
}

advanced_settings_submenu() {
  while true; do
    local current_state current_value current_color
    local wg_block wg_value wg_color
    local quic_block quic_value quic_color
    local keenetic_status keenetic_color
    local wd_status wd_color
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
    wd_status="$(watchdog_status_text)"
    case "$wd_status" in
      работает) wd_color="green" ;;
      выключен) wd_color="red" ;;
      *) wd_color="yellow" ;;
    esac
    submenu_status_item "6" "Watchdog zapret2: перезапуск при падении/OOM." "$wd_status" "$wd_color"
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
      "6")
        watchdog_toggle || true
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
