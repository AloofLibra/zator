#!/bin/sh

ORCH_DIR="${ORCH_DIR:-/opt/zapret2/extra_strats/cache/orchestra}"
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

orch_locked_get() {
  _orch_locked_read "$1" "$2" "0"
}

orch_locked_state_get() {
  _orch_locked_read "$1" "$2" "auto"
}

orch_locked_set() {
  local profile="$1"
  local proto="$2"
  local strategy="$3"
  local tmp="${ORCH_LOCK_FILE}.tmp"
  mkdir -p "$(dirname "$ORCH_LOCK_FILE")" || return 1
  touch "$ORCH_LOCK_FILE" || return 1
  awk -v pr="$profile" -v p="$proto" -v s="$strategy" 'BEGIN{FS=OFS="\t"}{
    if ($1==pr && (($2==p) || (NF==2 && p=="tls"))) {print pr,p,s; found=1; next}
    print
  } END{
    if (!found) print pr,p,s
  }' "$ORCH_LOCK_FILE" > "$tmp" && mv "$tmp" "$ORCH_LOCK_FILE"
}

orch_locked_clear() {
  local profile="$1"
  local proto="$2"
  local tmp="${ORCH_LOCK_FILE}.tmp"
  [ -f "$ORCH_LOCK_FILE" ] || return 0
  awk -v pr="$profile" -v p="$proto" 'BEGIN{FS=OFS="\t"}{
    if ($1==pr && (($2==p) || (NF==2 && p=="tls"))) next
    print
  }' "$ORCH_LOCK_FILE" > "$tmp" && mv "$tmp" "$ORCH_LOCK_FILE"
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
