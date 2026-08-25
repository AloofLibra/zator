# UI helpers

pause_enter() {
  read -re -p "Enter для продолжения" _
}

submenu_item() {
  local key="$1"
  local state="${4:-auto}"
  local indent=""
  local clean_key="${key//$'\t'/}"
  clean_key="${clean_key//\\t/}"
  [ "${SUBMENU_ITEM_INDENT:-0}" = 1 ] && indent=$'\t'
  local key_display="${indent}${clean_key}."
  if [ "$clean_key" = "0" ]; then
    echo -e "${Fyellow}${key_display}${plain} ${Fyellow}$2${plain} $3"
  elif [ "$state" = "0" ]; then
    echo -e "${Fcyan}${key_display}${plain} ${red}$2${plain} ${red}$3${plain}"
  else
    echo -e "${Fcyan}${key_display}${plain} ${green}$2${plain} $3"
  fi
}

# Пункт подменю с нейтральным текстом и значением «Сейчас:» цветом статуса:
# $1=ключ, $2=текст пункта, $3=значение (пусто — пункт без статуса), $4=статус
# (green|red|yellow).
submenu_status_item() {
  local key="$1" text="$2" value="$3" status="${4:-yellow}"
  local color="$yellow"
  case "$status" in
    green) color="$green" ;;
    red) color="$red" ;;
  esac
  if [ "$key" = "0" ]; then
    echo -e "${Fyellow}${key}.${plain} ${Fyellow}${text}${plain} ${value}"
  elif [ -z "$value" ]; then
    echo -e "${Fcyan}${key}.${plain} ${text}"
  else
    echo -e "${Fcyan}${key}.${plain} ${text} ${yellow}Сейчас: ${color}${value}${plain}"
  fi
}

# Совместимость со старым кодом меню
exit_to_menu() {
  pause_enter
}

# Печать стандартного сообщения о неверном вводе меню + короткая пауза.
ui_invalid_input() {
  echo -e "${yellow}Неверный ввод.${plain}"
  sleep 1
}

# Проверка: $1 — целое число в диапазоне [$2..$3]. Возвращает 0 (да) / 1 (нет).
# Заменяет связку «grep -Eq '^[0-9]+$' + сравнение -ge/-le» во всех меню.
ui_is_number_in_range() {
  printf '%s' "$1" | grep -Eq '^[0-9]+$' || return 1
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}
