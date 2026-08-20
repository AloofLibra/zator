# ---- Provider detector integration ----
# Провайдер определяется по номеру автономной системы (ASN): он стабилен и одинаков
# у всех гео-сервисов, в отличие от поля isp (юридические лица и локальные бренды).
# Каскад: ipwho.is (HTTPS, без ключа) -> ipinfo.io -> ip-api.com (HTTP, последний).
PROVIDER_CACHE="/opt/zator/extra_strats/cache/provider.txt"
PROVIDER_MENU="Не определён"
PROVIDER_INIT_DONE=0
PROVIDER_ASN=""

PROVIDER_ASN_DB_FILE="/opt/zator/data/providers/asn.txt"
PROVIDER_ASN_CACHE="/opt/zator/extra_strats/cache/provider_asn.txt"
PROVIDER_ASN_REMOTE="https://raw.githubusercontent.com/AloofLibra/zator/zator/data/providers/asn.txt"
PROVIDER_ASN_TTL_DAYS=7

# Встроенная минимальная база (fallback при отсутствии cache и data/providers/asn.txt).
# Формат строки: ASN:Бренд:алиасы(через запятую, без пробелов). Обновляемая база
# живёт в data/providers/asn.txt; при загрузке таблицы мержится с этой (remote приоритет).
PROVIDER_ASN_BUILTIN="8359:MTS:
31133:MTS:MGTS
12389:Rostelecom:
42610:Rostelecom:
20485:Rostelecom:TTK
3216:Beeline:VimpelCom
8369:Dom.ru:ER-Telecom
9049:Dom.ru:ER-Telecom
47119:Ufanet:
25159:MegaFon:
12958:T2:
9002:RETN:
8492:OBIT:
9198:Kazakhtelecom:
15895:Kyivstar:
6697:Beltelecom:"
PROVIDER_ASN_TABLE="$PROVIDER_ASN_BUILTIN"
PROVIDER_ASN_TABLE_SRC="builtin"

_provider_asn_file_valid() {
  local f="$1" bad rows
  [ -s "$f" ] || return 1
  bad="$(grep -vE '^[[:space:]]*(#|$)' "$f" | grep -cvE '^[0-9]+:[^:]+(:[^:]*)?[[:space:]]*$' || true)"
  [ "${bad:-1}" -eq 0 ] || return 1
  rows="$(grep -cE '^[0-9]+:' "$f" || true)"
  [ "${rows:-0}" -ge 5 ] || return 1
  return 0
}

provider_load_database() {
  local src=""
  if [ -f "$PROVIDER_ASN_CACHE" ] && _provider_asn_file_valid "$PROVIDER_ASN_CACHE"; then
    src="$PROVIDER_ASN_CACHE"
    PROVIDER_ASN_TABLE_SRC="cache"
  elif [ -f "$PROVIDER_ASN_DB_FILE" ] && _provider_asn_file_valid "$PROVIDER_ASN_DB_FILE"; then
    src="$PROVIDER_ASN_DB_FILE"
    PROVIDER_ASN_TABLE_SRC="file"
  else
    PROVIDER_ASN_TABLE="$PROVIDER_ASN_BUILTIN"
    PROVIDER_ASN_TABLE_SRC="builtin"
    return 0
  fi
  PROVIDER_ASN_TABLE="$(
    { grep -vE '^[[:space:]]*(#|$)' "$src"; printf '%s\n' "$PROVIDER_ASN_BUILTIN"; } |
    awk -F: '$1 ~ /^[0-9]+$/ && NF >= 2 { if (!($1 in seen)) { seen[$1] = 1; print } }'
  )"
  return 0
}

provider_update_database() {
  if [ -f "$PROVIDER_ASN_CACHE" ] && [ -z "$(find "$PROVIDER_ASN_CACHE" -mtime +"$(( PROVIDER_ASN_TTL_DAYS - 1 ))" 2>/dev/null)" ]; then
    return 0
  fi
  local tmp
  tmp="$(mktemp /tmp/z2r_asn_db.XXXXXX 2>/dev/null)" || tmp="/tmp/z2r_asn_db.$$"
  if ! curl -s --max-time 10 "$PROVIDER_ASN_REMOTE" -o "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! _provider_asn_file_valid "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mkdir -p "$(dirname "$PROVIDER_ASN_CACHE")"
  mv "$tmp" "$PROVIDER_ASN_CACHE" || { rm -f "$tmp"; return 1; }
  return 0
}

provider_db_version() {
  local src_file=""
  case "$PROVIDER_ASN_TABLE_SRC" in
    cache) src_file="$PROVIDER_ASN_CACHE" ;;
    file) src_file="$PROVIDER_ASN_DB_FILE" ;;
  esac
  if [ -n "$src_file" ] && [ -f "$src_file" ]; then
    sed -n 's/^# ZATOR_PROVIDER_DB_VERSION=//p' "$src_file" | head -n1
  else
    echo "builtin"
  fi
}

provider_asn_lookup() {
  local row
  PROVIDER_BRAND=""
  PROVIDER_ALIASES=""
  row="$(printf '%s\n' "$PROVIDER_ASN_TABLE" | grep -m1 "^$1:")"
  [ -n "$row" ] || return 1
  PROVIDER_BRAND="${row#*:}"
  PROVIDER_BRAND="${PROVIDER_BRAND%%:*}"
  PROVIDER_ALIASES="${row#*:*:}"
  return 0
}

provider_brand_aliases() {
  printf '%s\n' "$PROVIDER_ASN_TABLE" | grep -F ":$1:" | sed 's/^.*://' | sed '/^$/d' | sort -u
}

_provider_json_str() {
  printf '%s' "$1" | tr -d '\r\n' | LC_ALL=C sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

_provider_json_num() {
  printf '%s' "$1" | LC_ALL=C grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" | head -n1 | LC_ALL=C grep -o '[0-9][0-9]*$'
}

_provider_clean() {
  printf '%s' "$1" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-60
}

_detect_api_simple() {
  local resp asn="" isp="" city="" brand res

  provider_load_database

  resp="$(curl -s --max-time 6 'https://ipwho.is/' 2>/dev/null)"
  if printf '%s' "$resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    asn="$(_provider_json_num "$resp" asn)"
    isp="$(_provider_clean "$(_provider_json_str "$resp" isp)")"
    city="$(_provider_clean "$(_provider_json_str "$resp" city)")"
  fi

  if [ -z "$asn" ]; then
    resp="$(curl -s --max-time 6 'https://ipinfo.io/json' 2>/dev/null)"
    local org
    org="$(_provider_json_str "$resp" org)"
    if printf '%s' "$org" | grep -q '^AS[0-9][0-9]*'; then
      asn="$(printf '%s' "$org" | grep -o '^AS[0-9][0-9]*' | tr -d 'AS')"
      isp="$(_provider_clean "${org#AS[0-9]* }")"
    fi
    [ -z "$city" ] && city="$(_provider_clean "$(_provider_json_str "$resp" city)")"
  fi

  if [ -z "$asn" ]; then
    resp="$(curl -s --max-time 6 'http://ip-api.com/json/?fields=isp,city,as' 2>/dev/null)"
    local as_field
    as_field="$(_provider_json_str "$resp" as)"
    if printf '%s' "$as_field" | grep -q '^AS[0-9][0-9]*'; then
      asn="$(printf '%s' "$as_field" | grep -o '^AS[0-9][0-9]*' | tr -d 'AS')"
    fi
    [ -z "$isp" ] && isp="$(_provider_clean "$(_provider_json_str "$resp" isp)")"
    [ -z "$city" ] && city="$(_provider_clean "$(_provider_json_str "$resp" city)")"
  fi

  PROVIDER_ASN="$asn"
  if provider_asn_lookup "$asn"; then
    brand="$PROVIDER_BRAND"
  elif [ -n "$isp" ]; then
    brand="$isp"
    [ -n "$asn" ] && brand="$brand (AS$asn)"
  elif [ -n "$asn" ]; then
    brand="AS$asn"
  else
    return 1
  fi

  res="$brand"
  if [ -n "$city" ] && [ "$city" != "$brand" ]; then
    res="$brand - $city"
  fi

  mkdir -p "$(dirname "$PROVIDER_CACHE")"
  echo "$res" > "$PROVIDER_CACHE"
  return 0
}

provider_init_once() {
  [ "$PROVIDER_INIT_DONE" = "1" ] && return 0
  PROVIDER_INIT_DONE=1

  provider_load_database

  if [ ! -s "$PROVIDER_CACHE" ]; then
    echo "Определяем провайдера..."
    _detect_api_simple || true
  fi

  if [ -s "$PROVIDER_CACHE" ]; then
      PROVIDER_MENU="$(head -n1 "$PROVIDER_CACHE")"
  else
      PROVIDER_MENU="Не определён"
  fi
}

provider_force_redetect() {
  echo "Обновляем данные о провайдере..."
  provider_update_database || true
  rm -f "$PROVIDER_CACHE"
  _detect_api_simple || true

  if [ -s "$PROVIDER_CACHE" ]; then
      PROVIDER_MENU="$(head -n1 "$PROVIDER_CACHE")"
  else
      PROVIDER_MENU="Не удалось определить"
  fi
}

provider_set_manual() {
  local p="$1" c="${2:-}" res="$1"
  [ -n "$p" ] || return 1
  [ -n "$c" ] && res="$p - $c"
  mkdir -p "$(dirname "$PROVIDER_CACHE")"
  echo "$res" > "$PROVIDER_CACHE"
  PROVIDER_MENU="$res"
  return 0
}

provider_set_manual_menu() {
  local p c
  read -re -p "Провайдер (например MTS/Beeline): " p
  read -re -p "Город (можно пусто): " c
  provider_set_manual "$p" "$c" || echo -e "${red}Провайдер не задан.${plain}"
}
# ---- /Provider detector integration ----
