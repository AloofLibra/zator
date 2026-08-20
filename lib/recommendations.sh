# ---- Recomendations module ----

RECS_URL="https://raw.githubusercontent.com/AloofLibra/zator/zator/recommendations.txt"
RECS_FILE="/opt/zator/extra_strats/cache/recommendations.txt"

# 1. Функция обновления базы
update_recommendations() {
  mkdir -p "$(dirname "$RECS_FILE")"

  # Проверка: если файл существует И он моложе 1 дня (24 часа) - выходим.
  # -mtime -1 означает "изменен менее 1 дня назад"
  if [ -f "$RECS_FILE" ] && [ -n "$(find "$RECS_FILE" -mtime -1 2>/dev/null)" ]; then
    # Файл свежий, обновлять не нужно
    return 0
  fi

  # Скачиваем во временный файл и атомарно заменяем рабочий. При любой ошибке
  # удаляется только .tmp — существующая рабочая база никогда не трогается.
  local tmp
  tmp="$(mktemp "${RECS_FILE}.tmp.XXXXXX" 2>/dev/null)" || tmp="${RECS_FILE}.tmp.$$"

  if command -v z2r_download_project_file >/dev/null 2>&1; then
    if z2r_download_project_file "$tmp" "recommendations.txt" && [ -s "$tmp" ]; then
      mv -f "$tmp" "$RECS_FILE"
    else
      rm -f "$tmp"
    fi
  elif curl -fsSL --max-time 5 "$RECS_URL" -o "$tmp" && [ -s "$tmp" ]; then
    mv -f "$tmp" "$RECS_FILE"
  else
    rm -f "$tmp"
  fi
  return 0
}

# 2. Функция показа подсказки (Logic + UI)
show_hint() {
  local strat_type="$1" # UDP, TCP, GV или RKN
  local my_isp=""

  # А. Узнаем провайдера
  if [ -s "$PROVIDER_CACHE" ]; then
    my_isp="$(head -n1 "$PROVIDER_CACHE")"
  fi

  # Б. Проверяем наличие базы
  if [ -z "$my_isp" ] || [ ! -f "$RECS_FILE" ]; then
    return 0
  fi

  # В. Ищем строку: сначала точное совпадение ключа первого поля, затем по
  # бренду/алиасам из ASN-таблицы (ключи базы бывают "City - Org" и голые
  # "Beeline"). Бренд и алиасы могут содержать пробелы и скобки, поэтому
  # поиск литеральный (awk index), а не регулярным выражением.
  local line brand city alias aliases
  line="$(awk -F'|' -v key="$my_isp" '$1 == key {print; exit}' "$RECS_FILE")"
  if [ -z "$line" ] && type provider_brand_aliases >/dev/null 2>&1; then
    brand="${my_isp%% - *}"
    city="${my_isp#* - }"
    [ "$city" = "$my_isp" ] && city=""
    if [ -n "$city" ]; then
      line="$(awk -F'|' -v b="$brand" -v c="$city" 'index(tolower($1), tolower(b)) && index(tolower($1), tolower(c)) {print; exit}' "$RECS_FILE")"
    fi
    if [ -z "$line" ]; then
      line="$(awk -F'|' -v b="$brand" 'index(tolower($1), tolower(b)) {print; exit}' "$RECS_FILE")"
    fi
    if [ -z "$line" ]; then
      aliases="$(provider_brand_aliases "$brand" 2>/dev/null)"
      while IFS= read -r alias; do
        [ -n "$alias" ] || continue
        line="$(awk -F'|' -v b="$alias" 'index(tolower($1), tolower(b)) {print; exit}' "$RECS_FILE")"
        [ -n "$line" ] && break
      done <<EOF
$aliases
EOF
    fi
  fi
  [ -z "$line" ] && return 0

  # Г. Парсим (актуальный формат у тебя: ISP|UDP:...|TCP:...|GV:...|RKN:...
  local part=""
  case "$strat_type" in
    "UDP") part="$(echo "$line" | cut -d'|' -f2 | cut -d':' -f2)" ;;
    "TCP") part="$(echo "$line" | cut -d'|' -f3 | cut -d':' -f2)" ;;
    "GV")  part="$(echo "$line" | cut -d'|' -f4 | cut -d':' -f2)" ;;
    "RKN") part="$(echo "$line" | cut -d'|' -f5 | cut -d':' -f2)" ;;
    *) return 0 ;;
  esac

  # Д. Выводим
  if [ -n "$part" ] && [ "$part" != "-" ]; then
    echo ""
    echo -e "${cyan}💡 Подсказка:${plain} Пользователи ${green}$my_isp${plain} часто выбирают: ${yellow}$part${plain}"
    echo -e "Попробуйте начать с них."
    echo ""
  fi

  return 0
}

# ---- /Recomendations module ----
