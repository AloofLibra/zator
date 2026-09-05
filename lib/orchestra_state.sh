#!/bin/sh

ORCH_DIR="${ORCH_DIR:-/opt/zator/extra_strats/cache/orchestra}"
ORCH_LOCK_FILE="${ORCH_LOCK_FILE:-$ORCH_DIR/locked.tsv}"
PROFILE_STATE_FILE="${PROFILE_STATE_FILE:-${Z2R_PROFILE_STATE_FILE:-/opt/etc/z2r/profile.lock}}"

# Базовое чтение блокировки из locked.tsv. $3 — значение по умолчанию.
# Единый awk для orch_locked_get (default "0") и orch_locked_state_get (default "auto").
_orch_locked_read() {
  local profile="$1"
  local proto="$2"
  local default="${3:-0}"
  [ -f "$ORCH_LOCK_FILE" ] || { echo "$default"; return; }
  awk -v pr="$profile" -v p="$proto" -v d="$default" 'BEGIN{FS="\t"}{
    if ($1==pr && $2==p && NF>=3) {print $3; found=1; exit}
    if ($1==pr && NF==2 && p=="tls") {print $2; found=1; exit}
  } END{if (!found) print d}' "$ORCH_LOCK_FILE"
}

orch_locked_state_get() {
  local scope="${ORCH_ACTIVE_SCOPE:-default}" file v
  if [ "$scope" = default ]; then
    _orch_locked_read "$1" "$2" "auto"
    return 0
  fi
  file="$(_orch_scope_lock_file "$scope")" || { printf 'auto\n'; return 0; }
  if [ ! -f "$file" ]; then
    printf 'auto\n'
    return 0
  fi
  v="$(awk -F '\t' -v pr="$1" -v po="$2" '$1==pr && $2==po {print $3; exit}' "$file")"
  if [ -n "$v" ]; then
    printf '%s\n' "$v"
  else
    printf 'auto\n'
  fi
}

# Scoped locks retain legacy three-column rows for default and use
# scope/profile/proto/strategy rows for mark:<decimal> client scopes.
_orch_scope_basic_validate() {
  local scope="${1:-}"
  case "$scope" in *$'\t'*|*$'\n'*) return 1 ;; esac
  printf '%s' "$scope" | grep -Eq '^(default|mark:[0-9]+)$'
}

# Per-mark lock-файлы: $ORCH_DIR/scopes/mark_N.tsv, строки — profile<TAB>proto<TAB>strategy.
# Один mark — один файл: клиента можно бекапить/удалять целиком, файл читается сам
# по себе. default-локи остаются в locked.tsv (легаси-формат 2/3 колонки).
_orch_scopes_dir() {
  printf '%s\n' "${ORCH_DIR}/scopes"
}

_orch_scope_lock_file() {
  local n="${1#mark:}"
  printf '%s' "$n" | grep -Eq '^[1-9][0-9]*$' || return 1
  printf '%s\n' "$(_orch_scopes_dir)/mark_${n}.tsv"
}

# Разовая миграция старого формата: 4-колоночные mark: строки из locked.tsv
# переезжают в per-mark файлы. Идемпотентна; Lua до сих пор читает и старый
# формат, так что непромигрированные установки продолжают работать.
orch_scoped_locks_migrate() {
  local f="${ORCH_LOCK_FILE}" dir tmp
  [ -f "$f" ] || return 0
  awk -F '\t' 'NF>=4 && $1 ~ /^mark:[1-9][0-9]*$/ {m=1} END {exit !m}' "$f" || return 0
  dir="$(_orch_scopes_dir)"
  mkdir -p "$dir" || return 1
  awk -F '\t' 'NF>=4 && $1 ~ /^mark:[1-9][0-9]*$/ {print substr($1,6) "\t" $2 "\t" $3 "\t" $4}' "$f" \
    | while IFS="$(printf '\t')" read -r n pr po st; do
        [ -n "$n" ] || continue
        printf '%s\t%s\t%s\n' "$pr" "$po" "$st" >> "$dir/mark_${n}.tsv"
      done
  tmp="${f}.migrate.$$"
  awk -F '\t' '!(NF>=4 && $1 ~ /^mark:[1-9][0-9]*$/)' "$f" > "$tmp" \
    && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  return 0
}

orch_scoped_locked_get() {
  local scope="${1:-}" profile="${2:-}" proto="${3:-}" file
  _orch_scope_basic_validate "$scope" || return 2
  [ -n "$profile" ] && [ -n "$proto" ] || return 2
  if [ "$scope" != default ]; then
    orch_scoped_locks_migrate
    file="$(_orch_scope_lock_file "$scope")" || return 2
    if [ -f "$file" ]; then
      awk -F '\t' -v pr="$profile" -v po="$proto" '$1==pr && $2==po {print $3; exit}' "$file"
    else
      printf '0\n'
    fi
    return 0
  fi
  [ -f "$ORCH_LOCK_FILE" ] || { printf '0\n'; return 0; }
  awk -F '\t' -v pr="$profile" -v po="$proto" '
    $1==pr && $2==po && NF==3 {print $3; found=1; exit}
    po=="tls" && $1==pr && NF==2 {print $2; found=1; exit}
    END {if (!found) print "0"}
  ' "$ORCH_LOCK_FILE"
}

orch_scoped_locked_set() {
  local scope="${1:-}" profile="${2:-}" proto="${3:-}" strategy="${4:-}"
  local file tmp matches
  _orch_scope_basic_validate "$scope" || { echo "Invalid lock scope: $scope" >&2; return 2; }
  if type orch_scope_validate >/dev/null 2>&1; then
    orch_scope_validate "$scope" "$profile" "$proto" "$strategy" || return 2
  else
    [ -n "$profile" ] && [ -n "$proto" ] || return 2
    printf '%s' "$strategy" | grep -Eq '^(auto|clear|0|[1-9][0-9]*)$' || return 2
  fi
  case "$strategy" in auto|clear) orch_scoped_locked_clear "$scope" "$profile" "$proto"; return $? ;; esac
  if [ "$scope" != default ]; then
    orch_scoped_locks_migrate
    file="$(_orch_scope_lock_file "$scope")" || return 2
    mkdir -p "$(_orch_scopes_dir)" || return 1
    [ -f "$file" ] || : > "$file" || return 1
    matches="$(awk -F '\t' -v pr="$profile" -v po="$proto" '$1==pr && $2==po {n++} END {print n+0}' "$file")"
    [ "$matches" -le 1 ] || { echo "Conflicting duplicate lock rows for $scope/$profile/$proto" >&2; return 3; }
    tmp="${file}.tmp.$$"
    awk -F '\t' -v OFS='\t' -v pr="$profile" -v po="$proto" -v st="$strategy" '
      {if ($1==pr && $2==po) {if (!seen) {print pr, po, st; seen=1}; next} print}
      END {if (!seen) print pr, po, st}
    ' "$file" > "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; echo "Unable to update lock file" >&2; return 1; }
    return 0
  fi
  mkdir -p "$(dirname "$ORCH_LOCK_FILE")" || return 1
  [ -f "$ORCH_LOCK_FILE" ] || : > "$ORCH_LOCK_FILE" || return 1
  matches="$(awk -F '\t' -v pr="$profile" -v po="$proto" '((NF==3 && $1==pr && $2==po) || (po=="tls" && NF==2 && $1==pr)) {n++} END {print n+0}' "$ORCH_LOCK_FILE")"
  [ "$matches" -le 1 ] || { echo "Conflicting duplicate lock rows for $scope/$profile/$proto" >&2; return 3; }
  tmp="${ORCH_LOCK_FILE}.tmp.$$"
  awk -F '\t' -v OFS='\t' -v pr="$profile" -v po="$proto" -v st="$strategy" '
    function same() { return (NF==3 && $1==pr && $2==po) || (po=="tls" && NF==2 && $1==pr) }
    {if (same()) {if (!seen) {print pr, po, st; seen=1}; next} print}
    END {if (!seen) print pr, po, st}
  ' "$ORCH_LOCK_FILE" > "$tmp" && mv -f "$tmp" "$ORCH_LOCK_FILE" || { rm -f "$tmp"; echo "Unable to update lock file" >&2; return 1; }
}

orch_scoped_locked_clear() {
  local scope="${1:-}" profile="${2:-}" proto="${3:-}" file tmp
  _orch_scope_basic_validate "$scope" || return 2
  if type orch_scope_validate >/dev/null 2>&1; then orch_scope_validate "$scope" "$profile" "$proto" clear || return 2; fi
  if [ "$scope" != default ]; then
    orch_scoped_locks_migrate
    file="$(_orch_scope_lock_file "$scope")" || return 2
    [ -f "$file" ] || return 0
    tmp="${file}.tmp.$$"
    awk -F '\t' -v pr="$profile" -v po="$proto" '!($1==pr && $2==po)' "$file" > "$tmp" \
      && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    # Пустой per-mark файл не оставляем: «клиент целиком» = нет файла.
    [ -s "$file" ] || rm -f "$file"
    return 0
  fi
  [ -f "$ORCH_LOCK_FILE" ] || return 0
  tmp="${ORCH_LOCK_FILE}.tmp.$$"
  awk -F '\t' -v pr="$profile" -v po="$proto" '!((NF==3 && $1==pr && $2==po) || (po=="tls" && $1==pr && NF==2)) {print}' "$ORCH_LOCK_FILE" > "$tmp" && mv -f "$tmp" "$ORCH_LOCK_FILE" || { rm -f "$tmp"; return 1; }
}

# Explain where an effective lock came from for CLI/WebUI diagnostics.
orch_scoped_lock_source() {
  local scope="${1:-default}" profile="${2:-}" proto="${3:-}" file="${ORCH_LOCK_FILE:-}"
  local exact_count default_count
  _orch_scope_basic_validate "$scope" || return 2
  [ -n "$profile" ] && [ -n "$proto" ] || return 2
  if [ "$scope" != default ]; then
    orch_scoped_locks_migrate
    file="$(_orch_scope_lock_file "$scope")" || return 2
    if [ ! -f "$file" ]; then
      exact_count=0
    else
      exact_count="$(awk -F '\t' -v pr="$profile" -v po="$proto" '$1==pr && $2==po {n++} END{print n+0}' "$file")"
    fi
    [ "$exact_count" -gt 1 ] && { printf 'conflict\n'; return 0; }
    [ "$exact_count" -eq 1 ] && { printf 'scoped\n'; return 0; }
    [ -f "$ORCH_LOCK_FILE" ] || { printf 'auto\n'; return 0; }
    default_count="$(awk -F '\t' -v pr="$profile" -v po="$proto" '((NF==3 && $1==pr && $2==po) || (NF==2 && po=="tls" && $1==pr)) {n++} END{print n+0}' "$ORCH_LOCK_FILE")"
    [ "$default_count" -gt 1 ] && printf 'conflict\n' || { [ "$default_count" -eq 1 ] && printf 'default\n' || printf 'auto\n'; }
    return 0
  fi
  [ -f "$file" ] || { printf 'auto\n'; return 0; }
  default_count="$(awk -F '\t' -v pr="$profile" -v po="$proto" '((NF==3 && $1==pr && $2==po) || (NF==2 && po=="tls" && $1==pr)) {n++} END{print n+0}' "$file")"
  [ "$default_count" -gt 1 ] && printf 'conflict\n' || { [ "$default_count" -eq 1 ] && printf 'default\n' || printf 'auto\n'; }
}

orch_scoped_list_scopes() {
  local dir
  printf 'default\n'
  orch_scoped_locks_migrate
  {
    [ -f "$ORCH_LOCK_FILE" ] && awk -F '\t' '$1 ~ /^mark:[1-9][0-9]*$/ {print $1}' "$ORCH_LOCK_FILE"
    dir="$(_orch_scopes_dir)"
    if [ -d "$dir" ]; then
      ls "$dir" 2>/dev/null | sed -n 's/^mark_\([1-9][0-9]*\)\.tsv$/mark:\1/p'
    fi
  } | sort -u
  return 0
}

# CLI-managed client mapping: one canonical row is scope<TAB>IP.
client_scope_map_file() {
  printf '%s\n' "${CLIENT_SCOPE_MAP_FILE:-${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/client_scope.tsv}"
}

client_scope_ip_validate() {
  local ip="$1" part count=0 old_ifs
  if printf '%s\n' "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
    old_ifs="$IFS"; IFS=.
    read -r -a parts <<EOF
$ip
EOF
    IFS="$old_ifs"
    for part in "${parts[@]}"; do
      [ "$part" -le 255 ] 2>/dev/null || return 1
      count=$((count + 1))
    done
    [ "$count" -eq 4 ]
    return
  fi
  printf '%s\n' "$ip" | grep -Eq '^[0-9A-Fa-f:]+$' && printf '%s\n' "$ip" | grep -q ':'
}

client_scope_mark_validate() {
  local scope="${1:-}" id max
  printf '%s\n' "$scope" | grep -Eq '^mark:[1-9][0-9]*$' || return 1
  id="${scope#mark:}"
  max="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" CLIENT_SCOPE_MARK_MAX 2>/dev/null || printf 255)"
  [ "$id" -le "$max" ] 2>/dev/null
}

client_scope_ip_get() {
  local ip="$1" file="$(client_scope_map_file)"
  [ -f "$file" ] || return 0
  awk -F '\t' -v ip="$ip" '$2==ip {print $1; exit}' "$file"
}

client_scope_ip_set() {
  local ip="$1" scope="$2" file tmp
  client_scope_ip_validate "$ip" || return 2
  client_scope_mark_validate "$scope" || return 2
  file="$(client_scope_map_file)"; tmp="${file}.tmp.$$"
  mkdir -p "$(dirname "$file")" || return 1
  [ -f "$file" ] || : > "$file" || return 1
  awk -F '\t' -v OFS='\t' -v ip="$ip" -v sc="$scope" '$2==ip {if (!seen) {print sc,ip; seen=1}; next} {print} END{if (!seen) print sc,ip}' "$file" > "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

client_scope_ip_clear() {
  local ip="$1" file tmp
  client_scope_ip_validate "$ip" || return 2
  file="$(client_scope_map_file)"; tmp="${file}.tmp.$$"
  [ -f "$file" ] || return 0
  awk -F '\t' -v ip="$ip" '$2!=ip' "$file" > "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

client_scope_ip_list() {
  local file="$(client_scope_map_file)"
  [ -f "$file" ] || return 0
  awk -F '\t' 'NF>=2 && $1 ~ /^mark:[1-9][0-9]*$/ {print $2 " -> " $1}' "$file"
}

client_scope_ip_add() {
  local ip="$1" scope="$2" enabled
  client_scope_ip_validate "$ip" || return 2
  client_scope_mark_validate "$scope" || return 2
  case "$(client_scope_firewall_script)" in
    *client-scope-iptables.sh)
      printf '%s\n' "$ip" | grep -Eq ':' && { echo "IPv6 mapping requires nftables" >&2; return 2; }
      ;;
  esac
  client_scope_ip_set "$ip" "$scope" || return $?
  enabled="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" CLIENT_SCOPE_ENABLE 2>/dev/null || printf 0)"
  [ "$enabled" = 1 ] || return 0
  client_scope_firewall_reconcile
}

client_scope_ip_remove() {
  local ip="$1"
  client_scope_ip_clear "$ip" || return $?
  # Режим НЕ выключаем автоматически: удаление последнего клиента часто
  # часть переформирования группы. Вопрос о выключении — в визарде удаления.
  client_scope_firewall_reconcile
}

# Следующий свободный mark (2..CLIENT_SCOPE_MARK_MAX), не занятый в маппинге.
# mark:1 зарезервирован под собственный трафик роутера (тесты/автоподбор),
# mark:0 использовать нельзя (0 = «метки нет»). Печатает "mark:N"; 1 если все заняты.
client_scope_next_mark() {
  local max file used id
  max="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" CLIENT_SCOPE_MARK_MAX 2>/dev/null || printf 255)"
  printf '%s' "$max" | grep -Eq '^[1-9][0-9]*$' || max=255
  file="$(client_scope_map_file)"
  used=""
  [ -f "$file" ] && used="$(awk -F '\t' '$1 ~ /^mark:[1-9][0-9]*$/ {print substr($1,6)}' "$file" | sort -n | tr '\n' ' ')"
  id=2
  while [ "$id" -le "$max" ]; do
    case " $used " in
      *" $id "*) id=$((id + 1)) ;;
      *) printf 'mark:%s\n' "$id"; return 0 ;;
    esac
  done
  return 1
}

# Scoped/default lock-строки для одного scope. Печатает "profile<TAB>proto<TAB>strategy".
# default — legacy 3- и 2-колоночные строки из locked.tsv; mark:N — его per-mark файл.
client_scope_scope_locks() {
  local scope="${1:-default}" file
  _orch_scope_basic_validate "$scope" || return 2
  if [ "$scope" = default ]; then
    [ -f "$ORCH_LOCK_FILE" ] || return 0
    awk -F '\t' 'NF==3 {print $1 "\t" $2 "\t" $3} NF==2 {print $1 "\t" "tls" "\t" $2}' "$ORCH_LOCK_FILE"
  else
    orch_scoped_locks_migrate
    file="$(_orch_scope_lock_file "$scope")" || return 2
    [ -f "$file" ] || return 0
    awk -F '\t' 'NF==3 {print $1 "\t" $2 "\t" $3}' "$file"
  fi
}

# Краткая сводка lock для scope в одну строку: "3/tls=7, 5/udp=2" (пусто если нет).
client_scope_lock_summary() {
  local scope="${1:-default}" out line prof proto strat
  out=""
  while IFS="$(printf '\t')" read -r prof proto strat; do
    [ -n "$prof" ] || continue
    [ -n "$out" ] && out="$out, "
    out="${out}${prof}/${proto}=${strat}"
  done <<< "$(client_scope_scope_locks "$scope" 2>/dev/null)"
  printf '%s\n' "$out"
}

# Машиночитаемая сводка по всем scope: "scope<TAB>ip<TAB>lock_summary".
# default — первая строка (ip пустой), далее mark:N в порядке id.
# Один scope может иметь несколько IP — они склеиваются через запятую.
# Mark'и берутся и из маппинга, и из каталога per-mark локов: локи без
# маппинга (клиент удалён, локи оставлены) видны и доступны для чистки.
# Единый источник данных для CLI-таблицы и будущего WebUI.
client_scope_table() {
  local file dir scope ips locks
  file="$(client_scope_map_file)"
  dir="$(_orch_scopes_dir)"
  orch_scoped_locks_migrate
  printf 'default\t\t%s\n' "$(client_scope_lock_summary default)"
  {
    [ -f "$file" ] && awk -F '\t' '$1 ~ /^mark:[1-9][0-9]*$/ {print $1}' "$file"
    if [ -d "$dir" ]; then
      ls "$dir" 2>/dev/null | sed -n 's/^mark_\([1-9][0-9]*\)\.tsv$/mark:\1/p'
    fi
  } | sort -u | sort -t: -k2,2n | while IFS= read -r scope; do
      [ -n "$scope" ] || continue
      ips=""
      if [ -f "$file" ]; then
        # Склейка IP через запятую на чистом awk: paste есть не во всех busybox-сборках.
        ips="$(awk -F '\t' -v sc="$scope" '$1==sc { printf "%s%s", sep, $2; sep="," }' "$file")"
      fi
      locks="$(client_scope_lock_summary "$scope")"
      printf '%s\t%s\t%s\n' "$scope" "$ips" "$locks"
    done
  return 0
}

# Backward-compatible default-scope wrappers. Дефолтные wrapper'ы уважают
# активный scope меню стратегий: пока меню работает в контексте mark:N
# (client scopes включены), подборы и фиксации пишутся в его per-mark файл.
# Во всех остальных контекстах ORCH_ACTIVE_SCOPE не задан → default.
orch_locked_get() { orch_scoped_locked_get "${ORCH_ACTIVE_SCOPE:-default}" "$1" "$2"; }
orch_locked_set() { orch_scoped_locked_set "${ORCH_ACTIVE_SCOPE:-default}" "$1" "$2" "$3"; }
orch_locked_clear() { orch_scoped_locked_clear "${ORCH_ACTIVE_SCOPE:-default}" "$1" "$2"; }

# Удаление лока из всех scope сразу (default + каждый per-mark файл).
# Нужно при удалении домена из списка: стратегия для него могла быть
# назначена разным клиентам.
orch_locked_clear_everywhere() {
  local profile="$1" proto="$2" scope
  orch_scoped_locked_clear default "$profile" "$proto" || true
  orch_scoped_list_scopes | while IFS= read -r scope; do
    if [ "$scope" != default ] && [ -n "$scope" ]; then
      orch_scoped_locked_clear "$scope" "$profile" "$proto" || true
    fi
  done
  return 0
}

# Переименование профиля/домена в lock-файле одного scope с сохранением
# позиции строки. Меняется только первое поле (2/3-колоночные строки).
orch_scoped_locked_rename() {
  local scope="$1" old="$2" new="$3" file tmp
  _orch_scope_basic_validate "$scope" || return 2
  if [ "$scope" != default ]; then
    orch_scoped_locks_migrate
    file="$(_orch_scope_lock_file "$scope")" || return 2
    [ -f "$file" ] || return 0
    tmp="${file}.rename.$$"
    awk -F '\t' -v OFS='\t' -v old="$old" -v new="$new" '$1==old {$1=new} {print}' "$file" > "$tmp" \
      && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    return 0
  fi
  [ -f "$ORCH_LOCK_FILE" ] || return 0
  tmp="${ORCH_LOCK_FILE}.rename.$$"
  awk -F '\t' -v OFS='\t' -v old="$old" -v new="$new" '$1==old {$1=new} {print}' "$ORCH_LOCK_FILE" > "$tmp" \
    && mv -f "$tmp" "$ORCH_LOCK_FILE" || { rm -f "$tmp"; return 1; }
}

# Переименование во всех scope сразу (симметрично orch_locked_clear_everywhere).
orch_locked_rename_everywhere() {
  local profile="$1" new="$2" scope rc=0
  orch_scoped_locked_rename default "$profile" "$new" || rc=1
  orch_scoped_list_scopes | while IFS= read -r scope; do
    if [ "$scope" != default ] && [ -n "$scope" ]; then
      orch_scoped_locked_rename "$scope" "$profile" "$new" || true
    fi
  done
  return "$rc"
}

zapret2_running() {
  pidof nfqws2 >/dev/null 2>&1
}

profile_state_file() {
  printf '%s\n' "$PROFILE_STATE_FILE"
}

profile_state_normalize() {
  case "$1" in
    ""|"auto")
      echo "auto"
      ;;
    "0"|"skip")
      echo "0"
      ;;
    *)
      if printf '%s' "$1" | grep -Eq '^[1-9][0-9]*$'; then
        echo "$1"
      else
        return 1
      fi
      ;;
  esac
}

profile_state_stored_get() {
  local profile="$1"
  local proto="$2"
  local file
  file="$(profile_state_file)"

  [ -f "$file" ] || { echo "auto"; return 0; }
  awk -v pr="$profile" -v p="$proto" '
    BEGIN { FS="[ \t]+" }
    /^[[:space:]]*#/ || NF == 0 { next }
    $1 == pr && $2 == p && NF >= 3 { print $3; found=1; exit }
    $1 == pr && NF == 2 && p == "tls" { print $2; found=1; exit }
    END { if (!found) print "auto" }
  ' "$file"
}

profile_state_get() {
  local profile="$1"
  local proto="$2"
  local stored

  stored="$(profile_state_stored_get "$profile" "$proto")"
  if [ "$stored" != "auto" ]; then
    profile_state_normalize "$stored" || echo "auto"
    return 0
  fi

  profile_state_normalize "$(orch_locked_state_get "$profile" "$proto")" || echo "auto"
}

profile_state_display() {
  profile_state_get "$1" "$2"
}

profile_state_validate_strategy() {
  local profile="$1"
  local strategy="$2"
  local max

  printf '%s' "$strategy" | grep -Eq '^[0-9]+$' || return 1
  [ "$strategy" = "0" ] && return 0
  if type config_profile_max_strategy >/dev/null 2>&1; then
    max="$(config_profile_max_strategy "$profile" 2>/dev/null || true)"
    if printf '%s' "$max" | grep -Eq '^[1-9][0-9]*$' && [ "$strategy" -gt "$max" ]; then
      return 1
    fi
  fi
  return 0
}

# Атомарная перезапись файла состояния профиля.
# Удаляет запись профиля $2/$3, опционально добавляет новую ($4 — пусто = только удалить).
# Единая awk+tmp+cmp логика для profile_state_set и profile_state_clear.
_profile_state_write() {
  local file="$1" profile="$2" proto="$3" state="$4"
  local tmp="${file}.tmp.$$"

  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ]; then
    awk -v pr="$profile" -v p="$proto" '
      BEGIN { FS=OFS="\t" }
      /^[[:space:]]*#/ || NF == 0 { print; next }
      $1 == pr && (($2 == p) || (NF == 2 && p == "tls")) { next }
      { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    : > "$tmp"
  fi
  [ -n "$state" ] && printf '%s\t%s\t%s\n' "$profile" "$proto" "$state" >> "$tmp"

  if [ -f "$file" ] && cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$file"
  fi
}

profile_state_set() {
  local profile="$1"
  local proto="$2"
  local state

  state="$(profile_state_normalize "$3")" || return 1
  [ "$state" = "auto" ] && { profile_state_clear "$profile" "$proto"; return $?; }
  profile_state_validate_strategy "$profile" "$state" || return 1

  [ "$(profile_state_stored_get "$profile" "$proto")" = "$state" ] && return 0

  _profile_state_write "$(profile_state_file)" "$profile" "$proto" "$state"
}

profile_state_clear() {
  local profile="$1"
  local proto="$2"

  [ "$(profile_state_stored_get "$profile" "$proto")" = "auto" ] && return 0

  _profile_state_write "$(profile_state_file)" "$profile" "$proto" ""
}
