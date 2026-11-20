# --- Пользовательские блобы (custom_blobs.tsv) --------------------------------
# Пользователь загружает файлы блобов через панель в
# $ZATOR_ROOT/files/fake/custom_blob/ и создаёт декларации --blob=ИМЯ:@файл,
# которые инжектятся в config между маркерной парой #Z2R_CUSTOM_BLOBS_BEGIN/END
# (в config.default — сразу после штатных деклараций блобов). Как и кастомные
# стратегии: номера/имена принадлежат инжектору, маркеры досоздаются на старых
# конфигах, инжект идемпотентен и применяется во все пути перезаписи конфига.
# Переименование блоба правит ссылки на него в пользовательских стратегиях
# (custom_strategies.tsv, только пользовательские записи).
#
# Формат TSV: id <TAB> name <TAB> file <TAB> comment
#   id       — стабильный порядковый номер без дыр;
#   name     — имя блоба для --blob=ИМЯ:@… (буква/подчёркивание + буквы/цифры/_);
#   file     — имя файла внутри custom_blob/ (без путей);
#   comment  — произвольная пометка.

CUSTOM_BLOBS_FILE="${CUSTOM_BLOBS_FILE:-${ORCH_DIR:-/opt/zator/extra_strats/cache/orchestra}/custom_blobs.tsv}"

custom_blobs_dir() {
  printf '%s\n' "${ZATOR_ROOT:-/opt/zator}/files/fake/custom_blob"
}

# --- чтение TSV ---------------------------------------------------------------

custom_blobs_list() {
  [ -f "$CUSTOM_BLOBS_FILE" ] || return 0
  awk -F '\t' '
    /^[[:space:]]*#/ || NF < 3 { next }
    { print $1 "\t" $2 "\t" $3 "\t" $4 }
  ' "$CUSTOM_BLOBS_FILE"
}

custom_blobs_count() {
  custom_blobs_list | wc -l | tr -d '[:space:]'
}

custom_blobs_row() {
  local id="$1"
  custom_blobs_list | awk -F '\t' -v want="$id" '$1 == want { print; exit }'
}

# Разбор строки TSV (та же техника, что в custom_strategies: пустые поля
# сохраняются). Поля — в _CB_ID/_CB_NAME/_CB_FILE/_CB_COMMENT.
_custom_blobs_split() {
  local line="${1%$'\n'}"
  case "$line" in ''|'#'*) return 1 ;; esac
  IFS=$_CS_SOH read -r _CB_ID _CB_NAME _CB_FILE _CB_COMMENT <<<"$(printf '%s' "$line" | tr '\t' "$_CS_SOH")"
  case "$_CB_ID" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# --- имена --------------------------------------------------------------------

# Имя валидно по форме: буква/подчёркивание, дальше буквы/цифры/подчёркивание,
# до 32 символов (0x-литералы и чистые числа исключены по определению).
custom_blobs_name_wellformed() {
  case "$1" in
    *[!A-Za-z0-9_]*) return 1 ;;
  esac
  case "$1" in
    [0-9]*|0x*|"") return 1 ;;
  esac
  [ "${#1}" -le 32 ] || return 1
  printf '%s' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'
}

# Занятое имя: штатные декларации конфига (custom_strategies_blob_names —
# включает builtin clone-блобы) или другое пользовательское имя.
custom_blobs_name_taken() {
  local name="$1" cfg="${2:-${ZAPRET2_ROOT:-/opt/zapret2}/config}" known
  [ -f "$cfg" ] || cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config.default"
  while IFS= read -r known; do
    [ -z "$known" ] && continue
    [ "$known" = "$name" ] && return 0
  done < <(custom_strategies_blob_names "$cfg")
  while IFS= read -r known; do
    [ -z "$known" ] && continue
    [ "$known" = "$name" ] && return 0
  done < <(custom_blobs_list | awk -F '\t' '{print $2}')
  return 1
}

custom_blobs_validate_name() {
  local name="$1" cfg="${2:-${ZAPRET2_ROOT:-/opt/zapret2}/config}"
  custom_blobs_name_wellformed "$name" || {
    echo "Имя блоба: буква/подчёркивание, дальше буквы/цифры/подчёркивание (до 32 символов)." >&2
    return 2
  }
  if custom_blobs_name_taken "$name" "$cfg"; then
    echo "Имя «$name» уже занято (штатный или другой пользовательский блоб)." >&2
    return 2
  fi
  return 0
}

# Имя файла: без путей, «..», спецсимволов; расширение (.bin) допустимо.
custom_blobs_file_wellformed() {
  case "$1" in
    ""|*/*|*".."*) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$1" in
    [A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- записи -------------------------------------------------------------------

_custom_blobs_write() {
  local tmp content="$1"
  while :; do
    case "$content" in *$'\n') content="${content%$'\n'}" ;; *) break ;; esac
  done
  mkdir -p "$ORCH_DIR" || return 1
  tmp="${CUSTOM_BLOBS_FILE}.tmp.$$"
  printf '%s\n' "$content" > "$tmp" && mv -f "$tmp" "$CUSTOM_BLOBS_FILE" || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

_custom_blobs_header() {
  printf '# zator custom blobs: id, name, file (в custom_blob/), comment\n'
}

custom_blobs_next_id() {
  local max=0 id
  while IFS="$(printf '\t')" read -r id _rest; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ "$id" -gt "$max" ] && max="$id"
  done < <(custom_blobs_list)
  echo $((max + 1))
}

# Добавляет декларацию. rc: 0 ок (stdout — id), 2 — ошибка валидации, 1 — I/O.
custom_blobs_add() {
  local name="$1" file="$2" comment="${3:-}" cfg="${4:-}" id
  custom_blobs_validate_name "$name" "$cfg" || return 2
  custom_blobs_file_wellformed "$file" || { echo "Некорректное имя файла блоба." >&2; return 2; }
  [ -f "$(custom_blobs_dir)/$file" ] || { echo "Файла $file нет в $(custom_blobs_dir)." >&2; return 2; }
  comment="${comment//$'\t'/ }"
  [ "${#comment}" -le 64 ] || comment="${comment:0:64}"
  id="$(custom_blobs_next_id)"
  local content rows
  rows="$(custom_blobs_list)"
  [ -n "$rows" ] && rows="$rows
"
  content="$(_custom_blobs_header)
$rows$(printf '%s\t%s\t%s\t%s' "$id" "$name" "$file" "$comment")"
  _custom_blobs_write "$content" || return 1
  echo "$id"
}

custom_blobs_replace() {
  local id="$1" name="$2" file="$3" comment="${4:-}" cfg="${5:-}" content row oldname
  custom_blobs_row "$id" >/dev/null || return 2
  oldname="$(custom_blobs_row "$id" | awk -F '\t' '{print $2}')"
  if [ "$name" != "$oldname" ]; then
    custom_blobs_validate_name "$name" "$cfg" || return 2
  fi
  custom_blobs_file_wellformed "$file" || { echo "Некорректное имя файла блоба." >&2; return 2; }
  [ -f "$(custom_blobs_dir)/$file" ] || { echo "Файла $file нет в $(custom_blobs_dir)." >&2; return 2; }
  comment="${comment//$'\t'/ }"
  [ "${#comment}" -le 64 ] || comment="${comment:0:64}"
  content="$(_custom_blobs_header)"$'\n'
  while IFS= read -r row; do
    _custom_blobs_split "$row" || continue
    if [ "$_CB_ID" = "$id" ]; then
      row="$(printf '%s\t%s\t%s\t%s' "$_CB_ID" "$name" "$file" "$comment")"
    fi
    content="$content$row
"
  done < <(custom_blobs_list)
  # атомарность (замечание автора PR #82): сначала правим ссылки в стратегиях,
  # затем TSV блобов; ошибка любого шага откатывает предыдущий
  if [ "$name" != "$oldname" ]; then
    if ! custom_strategies_rename_blob "$oldname" "$name"; then
      echo "Не удалось обновить ссылки в «Своих стратегиях» — переименование откачено." >&2
      return 1
    fi
  fi
  if ! _custom_blobs_write "$content"; then
    if [ "$name" != "$oldname" ]; then
      custom_strategies_rename_blob "$name" "$oldname" 2>/dev/null || true
    fi
    echo "Не удалось записать TSV блобов — переименование откачено." >&2
    return 1
  fi
  return 0
}

# Удаление: блоб, на который ссылаются пользовательские стратегии, не удаляется.
custom_blobs_delete() {
  local id="$1" name file
  custom_blobs_row "$id" >/dev/null || return 2
  name="$(custom_blobs_row "$id" | awk -F '\t' '{print $2}')"
  if [ "$(custom_strategies_blob_ref_rows "$name")" != "0" ]; then
    echo "Блоб «$name» используется в пользовательских стратегиях ($(custom_strategies_blob_ref_rows "$name") шт.) — сначала уберите ссылки." >&2
    return 2
  fi
  local content row
  content="$(_custom_blobs_header)"$'\n'
  while IFS= read -r row; do
    _custom_blobs_split "$row" || continue
    [ "$_CB_ID" = "$id" ] && { file="$_CB_FILE"; continue; }
    content="$content$row
"
  done < <(custom_blobs_list)
  _custom_blobs_write "$content" || return 1
  # физический файл сносит только если на него больше не ссылается другая
  # декларация (два имени могут указывать на один файл — замечание автора PR #82)
  local still_used=0
  if [ -n "$file" ]; then
    if custom_blobs_list | awk -F '\t' -v f="$file" '$3 == f {found=1} END {exit !found}'; then
      still_used=1
    fi
  fi
  if [ -n "$file" ] && [ "$still_used" = "0" ]; then
    rm -f "$(custom_blobs_dir)/$file" 2>/dev/null
  fi
  return 0
}

# Файлы, лежащие в custom_blob/ (для привязки/загрузки).
custom_blobs_files_list() {
  local dir
  dir="$(custom_blobs_dir)"
  [ -d "$dir" ] || return 0
  ( cd "$dir" 2>/dev/null && ls -1 2>/dev/null | sort ) || return 0
}

# Сохраняет загруженный файл (путь $1) под санитизированным именем $2.
# rc: 0 ок, 2 — кривое имя/размер.
custom_blobs_upload_file() {
  local src="$1" name="$2" dir
  case "$name" in
    ""|*/*|*".."*) echo "Некорректное имя файла." >&2; return 2 ;;
  esac
  case "$name" in
    [A-Za-z0-9]*) : ;;
    *) echo "Имя файла должно начинаться с буквы или цифры." >&2; return 2 ;;
  esac
  case "$name" in
    *[!A-Za-z0-9._-]*) echo "Имя файла: буквы, цифры, . _ - (без пробелов)." >&2; return 2 ;;
  esac
  [ "${#name}" -le 64 ] || { echo "Имя файла длиннее 64 символов." >&2; return 2; }
  [ -f "$src" ] || { echo "Нет данных загрузки." >&2; return 2; }
  local size
  size="$(wc -c < "$src" 2>/dev/null | tr -d '[:space:]')"
  case "$size" in ''|*[!0-9]*) echo "Не удалось определить размер файла." >&2; return 2 ;; esac
  [ "$size" -ge 1 ] && [ "$size" -le 262144 ] || { echo "Размер файла 1 Б…256 КиБ." >&2; return 2; }
  dir="$(custom_blobs_dir)"
  mkdir -p "$dir" || return 1
  cp -f "$src" "$dir/$name" || return 1
  return 0
}

# --- инжект в конфиг ----------------------------------------------------------

custom_blobs_region() {
  case "$1" in
    begin) echo '^#Z2R_CUSTOM_BLOBS_BEGIN' ;;
    end)   echo '^#Z2R_CUSTOM_BLOBS_END' ;;
    *) return 1 ;;
  esac
}

# Досоздаёт маркерную пару в конфигах без неё (старые установки): перед строкой
# --template=z2r_tcp_tls_common (штатные декларации блобов всегда выше неё).
custom_blobs_ensure_markers() {
  local cfg="$1" mb me tmp
  [ -f "$cfg" ] || return 1
  mb="#Z2R_CUSTOM_BLOBS_BEGIN"
  me="#Z2R_CUSTOM_BLOBS_END"
  if grep -qxF "$mb" "$cfg" && grep -qxF "$me" "$cfg"; then
    return 0
  fi
  tmp="${cfg}.cusb.$$"
  awk -v mb="$mb" -v me="$me" '
    !done && $0 ~ /^--template=z2r_tcp_tls_common[[:space:]]*$/ {
      print mb
      print me
      done = 1
    }
    { print }
  ' "$cfg" > "$tmp" && mv -f "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
  return 0
}

# Применяет TSV к конфигу $1: маркеры, декларации --blob=ИМЯ:@custom_blob/файл
# между ними. Молчаливая (для хуков перезаписи конфига); rc!=0 только при I/O.
custom_blobs_apply_file() {
  local cfg="${1:-${ZAPRET2_ROOT:-/opt/zapret2}/config}"
  [ -f "$cfg" ] || { echo "custom blobs: нет конфига $cfg" >&2; return 1; }
  custom_blobs_ensure_markers "$cfg" || return 1

  local work="/tmp/z2r-custom-blobs-$$"
  mkdir -p "$work" || return 1
  local ins="$work/ins"
  : > "$ins"
  local row name file line
  while IFS= read -r row; do
    _custom_blobs_split "$row" || continue
    name="$_CB_NAME" file="$_CB_FILE"
    custom_blobs_file_wellformed "$file" || continue
    case "$name" in
      *[!A-Za-z0-9_]*|[0-9]*|"") continue ;;
    esac
    line="$(printf -- '--blob=%s:@%s/%s' "$name" "$(custom_blobs_dir)" "$file")"
    printf '%s\n' "$line" >> "$ins"
  done < <(custom_blobs_list)

  local mb me tmp
  mb="#Z2R_CUSTOM_BLOBS_BEGIN"
  me="#Z2R_CUSTOM_BLOBS_END"
  tmp="${cfg}.cusbfill.$$"
  awk -v mb="$mb" -v me="$me" -v insf="$ins" '
    $0 == mb {
      print
      if (insf != "") {
        while ((getline line < insf) > 0) print line
        close(insf)
      }
      wiping = 1
      next
    }
    $0 == me { wiping = 0; print; next }
    !wiping { print }
  ' "$cfg" > "$tmp" && mv -f "$tmp" "$cfg" || { rm -rf "$work" "$tmp" 2>/dev/null; return 1; }
  rm -rf "$work"
  return 0
}

# --- подменю CLI (п.16 -> «Свои блобы»; панель дублирует через blobs.cgi) ------
# Загрузка файлов через CLI не делается: кладите файлы в custom_blob/
# (scp/веб-панелью — там кнопка загрузки) — каталог и TSV едут в бэкапах.

# Имя блоба по умолчанию из имени файла: база без расширения, мусор в _,
# цифра в начале -> префикс blob_.
_custom_blobs_name_from_file() {
  local base="${1%.*}" auto
  auto="$(printf '%s' "$base" | tr -c 'A-Za-z0-9_' '_')"
  case "$auto" in
    [0-9]*) auto="blob_$auto" ;;
    ""|_*) auto="blob_1" ;;
  esac
  printf '%s' "$auto"
}

# Выбор файла из custom_blob/. stdout — ТОЛЬКО имя файла (рендер в stderr);
# 0/Enter/EOF — отмена (rc 0, пустой stdout).
_custom_blobs_pick_file() {
  local files=() f i choice n
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(custom_blobs_files_list)
  if [ "${#files[@]}" = "0" ]; then
    echo -e "${yellow}Каталог $(custom_blobs_dir) пуст.${plain}" >&2
    echo -e "${yellow}Положите файл блоба туда (scp) или загрузите через веб-панель —${plain}" >&2
    echo -e "${yellow}«Свои блобы» -> «Загрузка блоба». Каталог едет в бэкапах.${plain}" >&2
    return 0
  fi
  while true; do
    i=1
    echo -e "${cyan}--- Файлы в $(custom_blobs_dir) ---${plain}" >&2
    echo "" >&2
    for f in "${files[@]}"; do
      submenu_item "$i" "$f" >&2
      i=$((i + 1))
    done
    submenu_item "0" "Отмена" >&2
    echo "" >&2
    read -re -p "Ваш выбор: " choice || choice=""
    case "$choice" in ""|0) return 0 ;; esac
    case "$choice" in *[!0-9]*) ui_invalid_input >&2; continue ;; esac
    n="${#files[@]}"
    if [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
      printf '%s\n' "${files[$((choice - 1))]}"
      return 0
    fi
    ui_invalid_input >&2
  done
}

# Ввод имени блоба. $1 — значение по умолчанию (Enter принимает его).
# stdout — ТОЛЬКО имя; пустой ввод при пустом default — отмена (пустой stdout).
_custom_blobs_ask_name() {
  local def="${1:-}" input
  while true; do
    if [ -n "$def" ]; then
      read -re -p "Имя блоба (Enter = $def): " input || input="$def"
      [ -z "$input" ] && input="$def"
    else
      read -re -p "Имя блоба (Enter - отмена): " input || input=""
      [ -z "$input" ] && return 0
    fi
    if custom_blobs_name_wellformed "$input"; then
      printf '%s\n' "$input"
      return 0
    fi
    echo -e "${red}Имя блоба: буква/подчёркивание, дальше буквы/цифры/подчёркивание (до 32).${plain}" >&2
  done
}

# Выбор существующей записи. stdout — ТОЛЬКО id; 0/Enter/EOF — отмена.
_custom_blobs_pick_row() {
  local row choice n=0
  while true; do
    n=0
    echo -e "${cyan}--- Свои блобы ---${plain}" >&2
    echo "" >&2
    while IFS= read -r row; do
      _custom_blobs_split "$row" || continue
      n=$((n + 1))
      submenu_item "$_CB_ID" "$_CB_NAME — $_CB_FILE" >&2
    done < <(custom_blobs_list)
    submenu_item "0" "Отмена" >&2
    echo "" >&2
    read -re -p "Ваш выбор: " choice || choice=""
    case "$choice" in ""|0) return 0 ;; esac
    case "$choice" in *[!0-9]*) ui_invalid_input >&2; continue ;; esac
    if custom_blobs_row "$choice" >/dev/null 2>&1; then
      printf '%s\n' "$choice"
      return 0
    fi
    ui_invalid_input >&2
  done
}

custom_blobs_submenu() {
  local cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [ -f "$cfg" ] || cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config.default"
  local ans id name file comment row refs

  while true; do
    clear -x
    echo -e "${cyan}--- Свои блобы (custom_blob) ---${plain}"
    echo ""
    echo -e "${yellow}Декларации --blob=ИМЯ:@файл дописываются в конфиг после штатных блобов${plain}"
    echo -e "${yellow}(секция #Z2R_CUSTOM_BLOBS). Файлы кладите в:${plain}"
    echo -e "${cyan}$(custom_blobs_dir)${plain}"
    echo -e "${yellow}(scp или загрузка через веб-панель; каталог и список едут в бэкапах).${plain}"
    echo -e "${yellow}Имя не должно совпадать со штатным. Смена имени правит ссылки${plain}"
    echo -e "${yellow}в «Своих стратегиях». Вступает в силу после «Применить» (пункт 4).${plain}"
    echo ""
    if [ "$(custom_blobs_count)" = "0" ]; then
      echo -e "${yellow}Деклараций нет.${plain}"
    else
      printf "${yellow}%-3s %-16s %-24s %-6s %s${plain}\n" "ID" "Имя" "Файл" "Ссыл." "Комментарий"
      local row
      while IFS= read -r row; do
        _custom_blobs_split "$row" || continue
        refs="$(custom_strategies_blob_ref_rows "$_CB_NAME")"
        printf "%-3s %-16s %-24s %-6s %s\n" "$_CB_ID" "$_CB_NAME" "$_CB_FILE" "$refs" "$_CB_COMMENT"
      done < <(custom_blobs_list)
    fi
    echo ""
    submenu_item "1" "Добавить блоб (из файла каталога)"
    submenu_item "2" "Изменить / переименовать"
    submenu_item "3" "Удалить"
    submenu_item "4" "Применить к конфигу"
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans || ans=""
    case "$ans" in
      "0"|"")
        return
        ;;
      "1")
        file="$(_custom_blobs_pick_file)" || file=""
        if [ -n "$file" ]; then
          name="$(_custom_blobs_ask_name "$(_custom_blobs_name_from_file "$file")")" || name=""
        fi
        [ -n "${file:-}" ] && [ -n "${name:-}" ] || { echo "Отменено."; pause_enter; continue; }
        read -re -p "Комментарий (Enter - пусто): " comment || comment=""
        if id="$(custom_blobs_add "$name" "$file" "$comment")"; then
          echo -e "${green}Добавлено: ID $id, блоб «$name».${plain}"
          echo -e "${yellow}Примените к конфигу (п.4) и перезапустите zapret2.${plain}"
        else
          echo -e "${red}Не добавлено (имя занято/кривое или файл пропал).${plain}"
        fi
        pause_enter
        ;;
      "2")
        id="$(_custom_blobs_pick_row)" || id=""
        [ -n "$id" ] || { echo "Отменено."; pause_enter; continue; }
        row="$(custom_blobs_row "$id")"
        _custom_blobs_split "$row" || { pause_enter; continue; }
        echo -e "${yellow}Текущее: имя «$_CB_NAME», файл «$_CB_FILE», комментарий «$_CB_COMMENT»${plain}"
        name="$(_custom_blobs_ask_name "$_CB_NAME")" || name="$_CB_NAME"
        file="$(_custom_blobs_pick_file)" || file="$_CB_FILE"
        [ -z "$file" ] && file="$_CB_FILE"
        read -re -p "Комментарий (Enter - прежний): " comment || comment="$_CB_COMMENT"
        [ -z "$comment" ] && comment="$_CB_COMMENT"
        if custom_blobs_replace "$id" "$name" "$file" "$comment" "$cfg"; then
          if [ "$name" != "$_CB_NAME" ]; then
            echo -e "${green}Переименовано: «$_CB_NAME» -> «$name». Ссылки в «Своих стратегиях» обновлены.${plain}"
          else
            echo -e "${green}Обновлено.${plain}"
          fi
          echo -e "${yellow}Примените к конфигу (п.4).${plain}"
        else
          echo -e "${red}Не обновлено (имя занято/кривое или файл пропал).${plain}"
        fi
        pause_enter
        ;;
      "3")
        id="$(_custom_blobs_pick_row)" || id=""
        [ -n "$id" ] || { echo "Отменено."; pause_enter; continue; }
        row="$(custom_blobs_row "$id")"
        _custom_blobs_split "$row" || { pause_enter; continue; }
        refs="$(custom_strategies_blob_ref_rows "$_CB_NAME")"
        if [ "$refs" != "0" ]; then
          echo -e "${red}Блоб «$_CB_NAME» используется в $refs стратеги(ях) — сначала уберите ссылки (п.1 -> 14).${plain}"
          pause_enter
          continue
        fi
        if custom_blobs_delete "$id"; then
          echo -e "${green}Удалено (запись и файл).${plain}"
        else
          echo -e "${red}Не удалено.${plain}"
        fi
        pause_enter
        ;;
      "4")
        local strat_ok=1
        if type custom_strategies_apply_file >/dev/null 2>&1; then
          custom_strategies_apply_file "$cfg" || strat_ok=0
        fi
        if custom_blobs_apply_file "$cfg" && [ "$strat_ok" = "1" ]; then
          echo -e "${green}Пользовательские блобы применены к $cfg.${plain}"
          read -re -p "Перезапустить zapret2 сейчас? 1 - да, Enter - нет: " ans || ans=""
          if [ "$ans" = "1" ]; then
            z2r_service_action restart || echo -e "${red}Не удалось перезапустить zapret2 — смотрите /tmp/nfqws2_1.err (п.666).${plain}"
          fi
        else
          echo -e "${red}Не удалось применить блобы к $cfg.${plain}"
        fi
        pause_enter
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}
