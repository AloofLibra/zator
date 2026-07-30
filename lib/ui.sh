# UI helpers

pause_enter() {
  read -re -p "Enter для продолжения" _
}

submenu_item() {
  local key="$1"
  local state="${4:-auto}"
  if [ "$key" = "0" ]; then
    echo -e "${Fyellow}${key}.${plain} ${Fyellow}$2${plain} $3"
  elif [ "$state" = "0" ]; then
    echo -e "${Fcyan}${key}.${plain} ${red}$2${plain} ${red}$3${plain}"
  else
    echo -e "${Fcyan}${key}.${plain} ${green}$2${plain} $3"
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
