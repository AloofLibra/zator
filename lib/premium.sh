# ---- ZEFEER PREMIUM (777/999) ----
# Сделано исключительно ради мемов. Практического смысла не несёт. 
PREMIUM_FLAG="$CACHE_DIR/premium.enabled"
PREMIUM_TITLE_FILE="$CACHE_DIR/premium.title"

rand_from_list() {
  (( $# > 0 )) || return 1
  local idx=$((RANDOM % $#))
  shift "$idx"
  printf '%s\n' "$1"
}

spinner_for_seconds() {
  local seconds="${1:-2}"
  local msg="${2:-Работаем}"
  local frames="|/-\\"
  local i=0
  local end=$((SECONDS + seconds))

  local _had_tput=0
  if command -v tput >/dev/null 2>&1; then
    _had_tput=1
    tput civis
    trap 'tput cnorm; trap - EXIT INT TERM' EXIT INT TERM
  fi

  while (( SECONDS < end )); do
    i=$(( (i + 1) % 4 ))
    # \r + \033[2K: в начало строки и стереть строку
    printf "\r\033[2K%s... [%c]" "$msg" "${frames:$i:1}"
    sleep 1
  done
  printf "\r\033[2K%s... [OK]\n" "$msg"

  if (( _had_tput )); then
    tput cnorm
    trap - EXIT INT TERM
  fi
}

premium_get_or_set_title() {
  mkdir -p "$CACHE_DIR"
  if [[ -s "$PREMIUM_TITLE_FILE" ]]; then
    cat "$PREMIUM_TITLE_FILE"
    return 0
  fi

  local title
  title="$(rand_from_list \
    "Граф Дезинхрона" \
    "Барон QUIC'а" \
    "Хранитель Hostlist'ов" \
    "Лорд --new" \
    "Грандмастер FakeTLS" \
    "Архитектор Сплитов" \
    "Повелитель RST (легальный)" \
    "Смотрящий за ipset'ом" \
    "Владыка TTL (ненадолго)" \
    "Амбассадор «Тест не точен»" \
  )"
  echo "$title" > "$PREMIUM_TITLE_FILE"
  echo "$title"
}

zefeer_premium_777() {
  mkdir -p "$CACHE_DIR"

  if [[ -f "$PREMIUM_FLAG" ]]; then
    local title
    title="$(premium_get_or_set_title)"
    echo -e "${yellow}ZEFEER PREMIUM уже активирован.${plain}"
    echo -e "Ваш титул: ${green}${title}${plain}"
    return 0
  fi

  echo -e "${yellow}Подключаемся к платёжному шлюзу...${plain}"
  spinner_for_seconds 2 "Проверяем поддержку проекта"

  # Фальш-результат
  local verdict
  verdict="$(rand_from_list \
    "Транзакция не найдена, но найден хороший человек." \
    "Оплата не прошла, зато прошли вы. В сердечко." \
    "Биллинг лежит. Premium — стоит." \
    "Счёт не выставлялся. Списали уважение." \
    "Донат не обнаружен. Обнаружена смелость нажать 777." \
  )"

  echo -e "${green}${verdict}${plain}"

  local title
  title="$(premium_get_or_set_title)"
  echo -e "Premium активирован ${green}ヽ(o^ ^o)ﾉ ${plain}"
  echo -e "Присвоен титул: ${pink}${title}${plain}"

  : > "$PREMIUM_FLAG"
}

zefeer_space_999() {
  local chars=(
    ｱ ｲ ｳ ｴ ｵ ｶ ｷ ｸ ｹ ｺ ｻ ｼ ｽ ｾ ｿ ﾀ ﾁ ﾂ ﾃ ﾄ ﾅ ﾆ ﾇ ﾈ ﾉ
    ﾊ ﾋ ﾌ ﾍ ﾎ ﾏ ﾐ ﾑ ﾒ ﾓ ﾔ ﾕ ﾖ ﾗ ﾘ ﾙ ﾚ ﾛ ﾜ ｦ ﾝ
    0 1 2 3 4 5 6 7 8 9
  )
  local cols rows frames frame x y row tail ch key buf seq
  local -a drops speeds

  cols="$(tput cols 2>/dev/null || echo 80)"
  rows="$(tput lines 2>/dev/null || echo 24)"

  if (( cols < 20 || rows < 8 )); then
    echo -e "${green}Wake up, zefeer...${plain}"
    return 0
  fi

  matrix_999_cleanup() {
    printf '\033[0m'
    tput cnorm 2>/dev/null || true
    clear
  }

  matrix_999_sleep() {
    if command -v usleep >/dev/null 2>&1; then
      usleep 30000
    else
      read -rsn1 -t 0.03 key 2>/dev/null || true
    fi
  }

  trap 'matrix_999_cleanup; trap - INT TERM; return 0' INT TERM

  clear
  tput civis 2>/dev/null || true
  printf '\033[1;2H\033[38;5;46mWake up, zefeer...\033[0m'

  for (( x = 1; x <= cols; x += 2 )); do
    drops[$x]=$((RANDOM % rows - 8))
    speeds[$x]=$((RANDOM % 3 + 1))
  done

  frames=360
  for (( frame = 0; frame < frames; frame++ )); do
    buf=""
    for (( x = 1; x <= cols; x += 2 )); do
      (( frame % speeds[$x] == 0 )) || continue

      y=${drops[$x]}

      if (( y >= 2 && y <= rows )); then
        ch="${chars[$((RANDOM % ${#chars[@]}))]}"
        printf -v seq '\033[%s;%sH\033[97m%s' "$y" "$x" "$ch"
        buf="${buf}${seq}"
      fi

      row=$((y - 1))
      if (( row >= 2 && row <= rows )); then
        ch="${chars[$((RANDOM % ${#chars[@]}))]}"
        printf -v seq '\033[%s;%sH\033[38;5;118m%s' "$row" "$x" "$ch"
        buf="${buf}${seq}"
      fi

      row=$((y - 3))
      if (( row >= 2 && row <= rows )); then
        ch="${chars[$((RANDOM % ${#chars[@]}))]}"
        printf -v seq '\033[%s;%sH\033[38;5;34m%s' "$row" "$x" "$ch"
        buf="${buf}${seq}"
      fi

      tail=$((y - 8))
      if (( tail >= 2 && tail <= rows )); then
        printf -v seq '\033[%s;%sH ' "$tail" "$x"
        buf="${buf}${seq}"
      fi

      y=$((y + 1))
      if (( y > rows + 8 )); then
        y=$((0 - RANDOM % rows))
      fi
      drops[$x]=$y
    done
    printf '%b' "$buf"
    matrix_999_sleep
  done

  matrix_999_cleanup
  trap - INT TERM
  unset -f matrix_999_sleep
  unset -f matrix_999_cleanup
  echo -e "${green}Матрица обновлена. Следуй за белым маршрутом.${plain}"
}
# ---- /ZEFEER PREMIUM ----
