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

_orch_legacy_locked_get() {
  _orch_locked_read "$1" "$2" "0"
}

orch_locked_state_get() {
  _orch_locked_read "$1" "$2" "auto"
}

_orch_legacy_locked_set() {
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

_orch_legacy_locked_clear() {
  local profile="$1"
  local proto="$2"
  local tmp="${ORCH_LOCK_FILE}.tmp"
  [ -f "$ORCH_LOCK_FILE" ] || return 0
  awk -v pr="$profile" -v p="$proto" 'BEGIN{FS=OFS="\t"}{
    if ($1==pr && (($2==p) || (NF==2 && p=="tls"))) next
    print
  }' "$ORCH_LOCK_FILE" > "$tmp" && mv "$tmp" "$ORCH_LOCK_FILE"
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
  awk -F '\t' -v sc="$scope" -v pr="$profile" -v po="$proto" '!((NF>=4 && $1==sc && $2==pr && $3==po) || (sc=="default" && NF==3 && $1==pr && $2==po)) {print}' "$ORCH_LOCK_FILE" > "$tmp" && mv -f "$tmp" "$ORCH_LOCK_FILE" || { rm -f "$tmp"; return 1; }
}

orch_scoped_locked_list() {
  local scope="${1:-}"
  [ -f "$ORCH_LOCK_FILE" ] || return 0
  [ -z "$scope" ] && { awk 'NF>=3 && $0 !~ /^[[:space:]]*#/ {print}' "$ORCH_LOCK_FILE"; return; }
  _orch_scope_basic_validate "$scope" || return 2
  awk -F '\t' -v sc="$scope" '$1==sc || (sc=="default" && NF==3) {print}' "$ORCH_LOCK_FILE"
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
