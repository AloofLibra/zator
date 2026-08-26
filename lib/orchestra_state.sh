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
  _orch_locked_read "$1" "$2" "auto"
}

# Scoped locks retain legacy three-column rows for default and use
# scope/profile/proto/strategy rows for mark:<decimal> client scopes.
_orch_scope_basic_validate() {
  local scope="${1:-}"
  case "$scope" in *$'\t'*|*$'\n'*) return 1 ;; esac
  printf '%s' "$scope" | grep -Eq '^(default|mark:[0-9]+)$'
}

orch_scoped_locked_get() {
  local scope="${1:-}" profile="${2:-}" proto="${3:-}"
  _orch_scope_basic_validate "$scope" || return 2
  [ -n "$profile" ] && [ -n "$proto" ] || return 2
  [ -f "$ORCH_LOCK_FILE" ] || { printf '0\n'; return 0; }
  awk -F '\t' -v sc="$scope" -v pr="$profile" -v po="$proto" '
    $1==sc && $2==pr && $3==po && NF>=4 {print $4; found=1; exit}
    sc=="default" && $1==pr && $2==po && NF==3 {print $3; found=1; exit}
    sc=="default" && po=="tls" && $1==pr && NF==2 {print $2; found=1; exit}
    END {if (!found) print "0"}
  ' "$ORCH_LOCK_FILE"
}

orch_scoped_locked_set() {
  local scope="${1:-}" profile="${2:-}" proto="${3:-}" strategy="${4:-}" tmp="${ORCH_LOCK_FILE}.tmp.$$" matches
  _orch_scope_basic_validate "$scope" || { echo "Invalid lock scope: $scope" >&2; return 2; }
  if type orch_scope_validate >/dev/null 2>&1; then
    orch_scope_validate "$scope" "$profile" "$proto" "$strategy" || return 2
  else
    [ -n "$profile" ] && [ -n "$proto" ] || return 2
    printf '%s' "$strategy" | grep -Eq '^(auto|clear|0|[1-9][0-9]*)$' || return 2
  fi
  case "$strategy" in auto|clear) orch_scoped_locked_clear "$scope" "$profile" "$proto"; return $? ;; esac
  mkdir -p "$(dirname "$ORCH_LOCK_FILE")" || return 1
  [ -f "$ORCH_LOCK_FILE" ] || : > "$ORCH_LOCK_FILE" || return 1
  matches="$(awk -F '\t' -v sc="$scope" -v pr="$profile" -v po="$proto" '((NF>=4 && $1==sc && $2==pr && $3==po) || (sc=="default" && NF==3 && $1==pr && $2==po) || (sc=="default" && po=="tls" && NF==2 && $1==pr)) {n++} END {print n+0}' "$ORCH_LOCK_FILE")"
  [ "$matches" -le 1 ] || { echo "Conflicting duplicate lock rows for $scope/$profile/$proto" >&2; return 3; }
  awk -F '\t' -v OFS='\t' -v sc="$scope" -v pr="$profile" -v po="$proto" -v st="$strategy" '
    function same() { return (NF>=4 && $1==sc && $2==pr && $3==po) || (sc=="default" && NF==3 && $1==pr && $2==po) || (sc=="default" && po=="tls" && NF==2 && $1==pr) }
    {if (same()) {if (!seen) {print (sc=="default" ? pr OFS po OFS st : sc OFS pr OFS po OFS st); seen=1}; next} print}
    END {if (!seen) print (sc=="default" ? pr OFS po OFS st : sc OFS pr OFS po OFS st)}
  ' "$ORCH_LOCK_FILE" > "$tmp" && mv -f "$tmp" "$ORCH_LOCK_FILE" || { rm -f "$tmp"; echo "Unable to update lock file" >&2; return 1; }
}

orch_scoped_locked_clear() {
  local scope="${1:-}" profile="${2:-}" proto="${3:-}" tmp="${ORCH_LOCK_FILE}.tmp.$$"
  _orch_scope_basic_validate "$scope" || return 2
  if type orch_scope_validate >/dev/null 2>&1; then orch_scope_validate "$scope" "$profile" "$proto" clear || return 2; fi
  [ -f "$ORCH_LOCK_FILE" ] || return 0
  awk -F '\t' -v sc="$scope" -v pr="$profile" -v po="$proto" '!((NF>=4 && $1==sc && $2==pr && $3==po) || (sc=="default" && NF==3 && $1==pr && $2==po) || (sc=="default" && po=="tls" && $1==pr && NF==2)) {print}' "$ORCH_LOCK_FILE" > "$tmp" && mv -f "$tmp" "$ORCH_LOCK_FILE" || { rm -f "$tmp"; return 1; }
}

# Explain where an effective lock came from for CLI/WebUI diagnostics.
orch_scoped_lock_source() {
  local scope="${1:-default}" profile="${2:-}" proto="${3:-}" file="${ORCH_LOCK_FILE:-}"
  local exact_count default_count
  _orch_scope_basic_validate "$scope" || return 2
  [ -n "$profile" ] && [ -n "$proto" ] || return 2
  [ -f "$file" ] || { printf 'auto\n'; return 0; }
  exact_count="$(awk -F '\t' -v sc="$scope" -v pr="$profile" -v po="$proto" 'NF>=4 && $1==sc && $2==pr && $3==po {n++} END{print n+0}' "$file")"
  [ "$exact_count" -gt 1 ] && { printf 'conflict\n'; return 0; }
  [ "$exact_count" -eq 1 ] && { printf 'scoped\n'; return 0; }
  default_count="$(awk -F '\t' -v pr="$profile" -v po="$proto" '((NF==3 && $1==pr && $2==po) || (NF==2 && po=="tls" && $1==pr)) {n++} END{print n+0}' "$file")"
  [ "$default_count" -gt 1 ] && printf 'conflict\n' || { [ "$default_count" -eq 1 ] && printf 'default\n' || printf 'auto\n'; }
}

orch_scoped_list_scopes() {
  printf 'default\n'
  [ -f "$ORCH_LOCK_FILE" ] || return 0
  awk -F '\t' '$1 ~ /^mark:[0-9]+$/ {print $1}' "$ORCH_LOCK_FILE"
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
  if [ -z "$(client_scope_ip_list)" ]; then
    config_set_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" CLIENT_SCOPE_ENABLE 0 || return 1
  fi
  client_scope_firewall_reconcile
}

# Следующий свободный mark (1..CLIENT_SCOPE_MARK_MAX), не занятый в маппинге.
# Печатает "mark:N"; 1 если все заняты.
client_scope_next_mark() {
  local max file used id
  max="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" CLIENT_SCOPE_MARK_MAX 2>/dev/null || printf 255)"
  printf '%s' "$max" | grep -Eq '^[1-9][0-9]*$' || max=255
  file="$(client_scope_map_file)"
  used=""
  [ -f "$file" ] && used="$(awk -F '\t' '$1 ~ /^mark:[1-9][0-9]*$/ {print substr($1,6)}' "$file" | sort -n | tr '\n' ' ')"
  id=1
  while [ "$id" -le "$max" ]; do
    case " $used " in
      *" $id "*) id=$((id + 1)) ;;
      *) printf 'mark:%s\n' "$id"; return 0 ;;
    esac
  done
  return 1
}

# Scoped/default lock-строки для одного scope. Печатает "profile<TAB>proto<TAB>strategy".
# default — legacy 3- и 2-колоночные строки; mark:N — 4-колоночные.
client_scope_scope_locks() {
  local scope="${1:-default}"
  _orch_scope_basic_validate "$scope" || return 2
  [ -f "$ORCH_LOCK_FILE" ] || return 0
  if [ "$scope" = default ]; then
    awk -F '\t' 'NF==3 {print $1 "\t" $2 "\t" $3} NF==2 {print $1 "\t" "tls" "\t" $2}' "$ORCH_LOCK_FILE"
  else
    awk -F '\t' -v sc="$scope" '$1==sc && NF>=4 {print $2 "\t" $3 "\t" $4}' "$ORCH_LOCK_FILE"
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
# Единый источник данных для CLI-таблицы и будущего WebUI.
client_scope_table() {
  local file scope ips locks
  file="$(client_scope_map_file)"
  printf 'default\t\t%s\n' "$(client_scope_lock_summary default)"
  [ -f "$file" ] || return 0
  for scope in $(awk -F '\t' '$1 ~ /^mark:[1-9][0-9]*$/ {print $1}' "$file" | sort -u -t: -k2,2n); do
    ips="$(awk -F '\t' -v sc="$scope" '$1==sc {print $2}' "$file" | paste -sd, -)"
    locks="$(client_scope_lock_summary "$scope")"
    printf '%s\t%s\t%s\n' "$scope" "$ips" "$locks"
  done
}

# Backward-compatible default-scope wrappers.
orch_locked_get() { orch_scoped_locked_get default "$1" "$2"; }
orch_locked_set() { orch_scoped_locked_set default "$1" "$2" "$3"; }
orch_locked_clear() { orch_scoped_locked_clear default "$1" "$2"; }

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
