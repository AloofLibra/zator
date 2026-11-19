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
  _custom_blobs_write "$content" || return 1
  # имя сменилось — правим ссылки в пользовательских стратегиях
  if [ "$name" != "$oldname" ]; then
    custom_strategies_rename_blob "$oldname" "$name"
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
  [ -n "$file" ] && rm -f "$(custom_blobs_dir)/$file" 2>/dev/null
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
