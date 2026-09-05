#!/usr/bin/env bash

set -u

PATH="/opt/bin:/opt/sbin:$PATH"
export PATH

WEBUI_ROOT="/opt/zator/webui"
ZAPRET_ROOT="/opt/zapret2"
ZATOR_ROOT="/opt/zator"
CONFIG_FILE="$ZAPRET_ROOT/config"
ORCH_DIR="$ZATOR_ROOT/extra_strats/cache/orchestra"
LIB_DIR=""

find_runtime_libs() {
  local here dir
  here="$(cd -- "$(dirname -- "$0")" && pwd)"
  for dir in \
    "$ZATOR_ROOT/z2r_lib" \
    "$ZAPRET_ROOT/z2r_lib" \
    "$here/../../z2r_lib" \
    "$here/../../lib" \
    "$here/../lib"; do
    if [ -f "$dir/orchestra_state.sh" ] && [ -f "$dir/config.sh" ] && [ -f "$dir/strategies.sh" ] && [ -f "$dir/netcheck.sh" ]; then
      LIB_DIR="$dir"
      return 0
    fi
  done
  return 1
}

find_runtime_libs || { echo 'Status: 500 Internal Server Error\r'; echo; echo '{"error":"missing z2r runtime libs"}'; exit 0; }
. "$LIB_DIR/config.sh"
. "$LIB_DIR/orchestra_state.sh"
. "$LIB_DIR/strategies.sh"
. "$LIB_DIR/netcheck.sh"
[ -f "$LIB_DIR/actions.sh" ] && . "$LIB_DIR/actions.sh"
[ -f "$LIB_DIR/provider.sh" ] && . "$LIB_DIR/provider.sh"
[ -f "$LIB_DIR/telemetry.sh" ] && . "$LIB_DIR/telemetry.sh"

telemetry_notify() {
  type send_stats >/dev/null 2>&1 && send_stats || true
}

json_escape() {
  printf '%s' "$1" | awk 'BEGIN{ORS=""}
  {
    gsub(/\\/, "\\\\")
    gsub(/"/, "\\\"")
    gsub(/\r/, "")
    if (NR>1) printf "\\n"
    printf "%s", $0
  }'
}

send_json() {
  local status="$1"
  local body="$2"
  printf 'Status: %s\r\n' "$status"
  printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'
  printf '%s\n' "$body"
}

send_error() {
  local status="$1"
  local message="$2"
  send_json "$status" "{\"error\":\"$(json_escape "$message")\"}"
  exit 0
}

parse_params() {
  local raw="${QUERY_STRING:-}"
  if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
    raw="$(dd bs=1 count="${CONTENT_LENGTH:-0}" 2>/dev/null || true)"
  fi
  local part key value
  # Инициализация под set -u: все возможные PARAM_* всегда определены.
  PARAM_PROFILE=""
  PARAM_STRATEGY=""
  PARAM_ACTION=""
  PARAM_SETTING=""
  PARAM_VALUE=""
  PARAM_LIST=""
  PARAM_DOMAIN=""
  PARAM_NEW_DOMAIN=""
  PARAM_NAME=""
  PARAM_CITY=""
  PARAM_PROTO=""
  PARAM_SCOPE="default"
  IFS='&' read -r -a parts <<< "$raw"
  for part in "${parts[@]}"; do
    key="${part%%=*}"
    value="${part#*=}"
    value="${value//+/ }"
    printf -v value '%b' "${value//%/\\x}"
    case "$key" in
      profile) PARAM_PROFILE="$value" ;;
      strategy) PARAM_STRATEGY="$value" ;;
      action) PARAM_ACTION="$value" ;;
      setting) PARAM_SETTING="$value" ;;
      value) PARAM_VALUE="$value" ;;
      list) PARAM_LIST="$value" ;;
      domain) PARAM_DOMAIN="$value" ;;
      new_domain) PARAM_NEW_DOMAIN="$value" ;;
      name) PARAM_NAME="$value" ;;
      city) PARAM_CITY="$value" ;;
      proto) PARAM_PROTO="$value" ;;
      scope) PARAM_SCOPE="${value:-default}" ;;
    esac
  done
}

get_config_file() {
  config_get_file "$CONFIG_FILE"
}

set_zapret2_init() {
  if [ -f "$ZAPRET_ROOT/init.d/openwrt/zapret2" ]; then
    ZAPRET2_INIT="$ZAPRET_ROOT/init.d/openwrt/zapret2"
  else
    ZAPRET2_INIT="$ZAPRET_ROOT/init.d/sysv/zapret2"
  fi
}

# Единый скан конфига из lib/config.sh (им же пользуется шапка CLI-меню):
# один awk-проход отдаёт все режимы, порты, WG/DNS/QUIC и max-стратегии
# профилей — веб-панель читает конфиг ровно так же, «в лёт».
_snapshot_once() {
  [ -n "${MENU_SNAPSHOT_DONE:-}" ] && return 0
  menu_config_snapshot "$CONFIG_FILE"
  MENU_SNAPSHOT_DONE=1
}

orch_max_strategy_for_profile() {
  config_profile_max_strategy "$1" "$CONFIG_FILE"
}

# JSON-escape без форка (awk json_escape стоит процесс на каждое поле);
# для значений без управляющих символов: lock-значения, режимы, имена файлов.
_json_esc() {
  REPLY="${1//\\/\\\\}"
  REPLY="${REPLY//\"/\\\"}"
}

# Пакетное чтение lock-состояний профилей: один проход по файлам
# (locked.tsv, locked.manual.tsv, profile.lock) вместо ~4 внешних процессов
# на каждый профиль. Семантика orch_scoped_lock_source / orch_locked_state_get /
# profile_state_stored_get / profile_state_normalize сохранена; L — locked.tsv,
# M — locked.manual.tsv (fallback-профили 8/9).
_profile_states_scan() {
  local line pr rest po val cur var file tag
  _PS_LOADED=1
  for tag in L M; do
    if [ "$tag" = "L" ]; then file="$ORCH_LOCK_FILE"; else file="$ORCH_DIR/locked.manual.tsv"; fi
    [ -f "$file" ] || continue
    while IFS= read -r line; do
      case "$line" in ""|"#"*) continue ;; esac
      pr="${line%%	*}"
      rest="${line#*	}"
      [ "$rest" = "$line" ] && continue
      po="${rest%%	*}"
      if [ "$po" = "$rest" ]; then val="$po"; po="tls"; else val="${rest#*	}"; fi
      case "$pr" in ""|*[!0-9]*) continue ;; esac
      var="_${tag}CNT_${pr}_${po}"
      cur="${!var:-0}"
      printf -v "$var" '%s' "$((cur + 1))"
      if [ "$cur" = "0" ]; then
        printf -v "_${tag}VAL_${pr}_${po}" '%s' "$val"
      fi
    done < "$file"
  done
  # profile.lock: profile proto state (или старый profile state = tls)
  file="${PROFILE_STATE_FILE:-/etc/z2r/profile.lock}"
  [ -f "$file" ] || return 0
  local first second
  while read -r pr first second _; do
    case "$pr" in ""|"#"*|*[!0-9]*) continue ;; esac
    if [ -n "$second" ]; then
      printf -v "_STORE_${pr}_${first}" '%s' "$second"
    elif [ -n "$first" ]; then
      printf -v "_STORE_${pr}_tls" '%s' "$first"
    fi
  done < "$file"
}

_profile_cur_cached() {  # $1=profile $2=proto $3=L|M -> REPLY
  local var stored
  var="_STORE_$1_$2"
  stored="${!var:-auto}"
  if [ "$stored" = "auto" ]; then
    var="_$3VAL_$1_$2"
    stored="${!var:-auto}"
  fi
  case "$stored" in
    ""|auto) REPLY="auto" ;;
    0|skip) REPLY="0" ;;
    *[!0-9]*) REPLY="auto" ;;
    *) REPLY="$stored" ;;
  esac
}

_profile_src_cached() {  # $1=profile $2=proto $3=L|M -> REPLY
  local var cnt
  var="_$3CNT_$1_$2"
  cnt="${!var:-0}"
  if [ "$cnt" -gt 1 ]; then REPLY="conflict"
  elif [ "$cnt" = "1" ]; then REPLY="default"
  else REPLY="auto"
  fi
}

profile_proto() {
  local list
  list="$(config_profile_proto_list "$1")"
  echo "${list%% *}"
}

# Resolve the selected client scope, falling back to the legacy default state.
profile_scoped_state_display() {
  local scope="$1" profile="$2" proto="$3" source scoped
  if [ "${scope:-default}" = default ]; then
    profile_state_display "$profile" "$proto"
    return
  fi
  source="$(orch_scoped_lock_source "$scope" "$profile" "$proto" 2>/dev/null || printf auto)"
  case "$source" in
    scoped)
      scoped="$(orch_scoped_locked_get "$scope" "$profile" "$proto" 2>/dev/null || printf 0)"
      profile_state_normalize "$scoped" 2>/dev/null || printf auto
      ;;
    conflict) printf 'conflict\n' ;;
    *) profile_state_display "$profile" "$proto" ;;
  esac
}

profile_json() {
  local id="$1" label="$2" desc="$3" proto current max scope source mvar
  scope="${PARAM_SCOPE:-default}"
  proto="$(profile_proto "$id")"
  if [ "$scope" = "default" ]; then
    [ -n "${_PS_LOADED:-}" ] || _profile_states_scan
    _profile_cur_cached "$id" "$proto" L; current="$REPLY"
    _profile_src_cached "$id" "$proto" L; source="$REPLY"
  else
    current="$(profile_scoped_state_display "$scope" "$id" "$proto")"
    source="$(orch_scoped_lock_source "$scope" "$id" "$proto" 2>/dev/null || printf auto)"
  fi
  mvar="MENU_PROFILE_MAX_$id"; max="${!mvar:-0}"
  _json_esc "$label"; local jlabel="$REPLY"
  _json_esc "$desc"; local jdesc="$REPLY"
  _json_esc "$current"; local jcurrent="$REPLY"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s,"scope":"%s","lock_source":"%s"}' \
    "$id" "$jlabel" "$jdesc" "$jcurrent" "${max:-0}" "$scope" "$source"
}

all_profiles_json() {
  _snapshot_once
  printf '['
  profile_json 1 "YouTube TCP" "Основной TCP профиль для YouTube"
  printf ','
  profile_json 2 "Googlevideo" "Видео-домены YouTube"
  printf ','
  profile_json 3 "RKN Лист" "Основные блокировки сайтов"
  printf ','
  profile_json 4 "Discord TCP" "TCP профиль Discord"
  printf ','
  profile_json 5 "YouTube QUIC" "UDP 443 для YouTube"
  printf ','
  profile_json 6 "Voice UDP" "Discord/STUN и голосовые сервисы"
  printf ','
  profile_json_udp_games 7 "UDP Games" "Игровой UDP (порты 1026-65531)"
  printf ','
  profile_json_fallback 8 "Fallback TLS" "Безразборный режим TLS (profile 8)"
  printf ','
  profile_json_fallback 9 "Fallback HTTP" "Безразборный режим HTTP (profile 9)"
  printf ','
  profile_json_dns 10 "DNS Антиспуф" "Защита UDP:53 от подмены DNS-ответов (клон с малым TTL)"
  printf ']'
}

# Профиль 10 (антиспуф DNS): гейтинг по состоянию тумблера (п.8 главного меню),
# как у UDP Games по config_mode_text udp_games.
profile_json_dns() {
  local id="$1" label="$2" desc="$3" proto current max dns_state scope source mvar
  scope="${PARAM_SCOPE:-default}"
  proto="$(profile_proto "$id")"
  if [ "$scope" = "default" ]; then
    [ -n "${_PS_LOADED:-}" ] || _profile_states_scan
    _profile_cur_cached "$id" "$proto" L; current="$REPLY"
    _profile_src_cached "$id" "$proto" L; source="$REPLY"
  else
    current="$(profile_scoped_state_display "$scope" "$id" "$proto")"
    source="$(orch_scoped_lock_source "$scope" "$id" "$proto" 2>/dev/null || printf auto)"
  fi
  mvar="MENU_PROFILE_MAX_$id"; max="${!mvar:-0}"
  dns_state="$MENU_DNS_DESINC"
  _json_esc "$label"; local jlabel="$REPLY"
  _json_esc "$desc"; local jdesc="$REPLY"
  _json_esc "$current"; local jcurrent="$REPLY"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s,"scope":"%s","lock_source":"%s","is_dns_desync":true,"dns_desync_enabled":%s}' \
    "$id" "$jlabel" "$jdesc" "$jcurrent" "${max:-0}" \
    "$scope" "$source" "$([ "$dns_state" = "Включен" ] && echo true || echo false)"
}

profile_json_udp_games() {
  local id="$1" label="$2" desc="$3" proto current max games_state scope source mvar
  scope="${PARAM_SCOPE:-default}"
  proto="$(profile_proto "$id")"
  if [ "$scope" = "default" ]; then
    [ -n "${_PS_LOADED:-}" ] || _profile_states_scan
    _profile_cur_cached "$id" "$proto" L; current="$REPLY"
    _profile_src_cached "$id" "$proto" L; source="$REPLY"
  else
    current="$(profile_scoped_state_display "$scope" "$id" "$proto")"
    source="$(orch_scoped_lock_source "$scope" "$id" "$proto" 2>/dev/null || printf auto)"
  fi
  mvar="MENU_PROFILE_MAX_$id"; max="${!mvar:-0}"
  games_state="$MENU_UDP_GAMES"
  _json_esc "$label"; local jlabel="$REPLY"
  _json_esc "$desc"; local jdesc="$REPLY"
  _json_esc "$current"; local jcurrent="$REPLY"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s,"scope":"%s","lock_source":"%s","is_udp_games":true,"udp_games_enabled":%s}' \
    "$id" "$jlabel" "$jdesc" "$jcurrent" "${max:-0}" \
    "$scope" "$source" "$([ "$games_state" = "Включен" ] && echo true || echo false)"
}

profile_json_fallback() {
  local id="$1" label="$2" desc="$3" proto current max fallback_state scope source mvar
  scope="${PARAM_SCOPE:-default}"
  proto="$(profile_proto "$id")"
  # Для профилей 8/9 состояние стратегии хранится в locked.manual.tsv.
  if [ "$scope" = "default" ]; then
    [ -n "${_PS_LOADED:-}" ] || _profile_states_scan
    _profile_cur_cached "$id" "$proto" M; current="$REPLY"
    _profile_src_cached "$id" "$proto" M; source="$REPLY"
  else
    local saved_lock_file="$ORCH_LOCK_FILE"
    ORCH_LOCK_FILE="$ORCH_DIR/locked.manual.tsv"
    current="$(profile_scoped_state_display "$scope" "$id" "$proto")"
    source="$(orch_scoped_lock_source "$scope" "$id" "$proto" 2>/dev/null || printf auto)"
    ORCH_LOCK_FILE="$saved_lock_file"
  fi
  mvar="MENU_PROFILE_MAX_$id"; max="${!mvar:-0}"
  fallback_state="$MENU_FALLBACK"
  _json_esc "$label"; local jlabel="$REPLY"
  _json_esc "$desc"; local jdesc="$REPLY"
  _json_esc "$current"; local jcurrent="$REPLY"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s,"scope":"%s","lock_source":"%s","is_fallback":true,"fallback_enabled":%s}' \
    "$id" "$jlabel" "$jdesc" "$jcurrent" "${max:-0}" \
    "$scope" "$source" "$([ "$fallback_state" = "включен" ] && echo true || echo false)"
}

service_zapret2() {
  local action="$1"
  set_zapret2_init
  [ -f "$ZAPRET2_INIT" ] || return 1
  case "$action" in
    start|stop|restart)
      z2r_service_action "$action" >/dev/null 2>&1
      ;;
    *)
      return 2
      ;;
  esac
}

# Автоперезапуск после изменения настройки: только когда zapret2 запущен.
# PARAM_RESTART=0 — отложить рестарт (WireGuard-форма меняет до трёх настроек
# одним сабмитом). Результат — в _SERVICE_RESTARTED (true/false) для JSON.
_service_apply_restart() {
  _SERVICE_RESTARTED=false
  [ "${PARAM_RESTART:-1}" = "0" ] && return 0
  zapret2_running || return 0
  service_zapret2 restart && _SERVICE_RESTARTED=true
  return 0
}

strategy_locks_status_text() {
  if [ -s "$ORCH_DIR/locked.tsv" ] || [ -s "$ORCH_DIR/locked.manual.tsv" ] || [ -s "$(profile_state_file)" ]; then
    echo "Есть"
  else
    echo "Нет"
  fi
}

_tls_detail_json() {
  local raw="$1" ver="$2"
  local code
  code="$(z2r_tls_field "$raw" 2)"
  case "$code" in ''|*[!0-9]*) code=0 ;; *) code=$((10#$code)) ;; esac
  printf '{"code":%s,"proto":"%s","time":"%s","ip":"%s","state":"%s","text":"%s"}' \
    "$code" \
    "$(json_escape "$(z2r_tls_field "$raw" 3)")" \
    "$(json_escape "$(z2r_tls_field "$raw" 4)")" \
    "$(json_escape "$(z2r_tls_field "$raw" 5)")" \
    "$(z2r_tls_version_state "$(z2r_tls_field "$raw" 1)" "$(z2r_tls_field "$raw" 2)")" \
    "$(json_escape "$(z2r_tls_version_text "$ver" "$raw")")"
}

check_one_target_json() {
  local label="$1" target="$2"
  local out v12 v13 dl s12 s13 b12 b13 verdict dlcode dlsize dltime dljson
  out="$(z2r_tls_check_target "$target")"
  v12="$(printf '%s\n' "$out" | sed -n 1p)"
  v13="$(printf '%s\n' "$out" | sed -n 2p)"
  dl="$(printf '%s\n' "$out" | sed -n 3p)"
  s12="$(z2r_tls_version_state "$(z2r_tls_field "$v12" 1)" "$(z2r_tls_field "$v12" 2)")"
  s13="$(z2r_tls_version_state "$(z2r_tls_field "$v13" 1)" "$(z2r_tls_field "$v13" 2)")"
  case "$s12" in ok|http) b12=1 ;; *) b12=0 ;; esac
  case "$s13" in ok|http) b13=1 ;; *) b13=0 ;; esac
  verdict="$(z2r_tls_target_verdict "$v12" "$v13" "$dl")"
  dljson="null"
  if [ "$dl" != "skip" ]; then
    dlcode="$(z2r_tls_field "$dl" 2)"
    dlsize="$(z2r_tls_field "$dl" 3)"
    dltime="$(z2r_tls_field "$dl" 4)"
    case "$dlcode" in ''|*[!0-9]*) dlcode=0 ;; *) dlcode=$((10#$dlcode)) ;; esac
    case "$dlsize" in ''|*[!0-9]*) dlsize=0 ;; *) dlsize=$((10#$dlsize)) ;; esac
    dljson="$(printf '{"code":%s,"size":%s,"time":"%s","state":"%s","text":"%s"}' \
      "$dlcode" "$dlsize" "$(json_escape "$dltime")" \
      "$(z2r_tls_download_state "$(z2r_tls_field "$dl" 1)" "$dlcode" "$dlsize")" \
      "$(json_escape "$(z2r_tls_download_text "$dl")")")"
  fi
  printf '{"label":"%s","target":"%s","tls12":%s,"tls13":%s,"verdict":"%s","text":"%s","tls12_detail":%s,"tls13_detail":%s,"download":%s}' \
    "$(json_escape "$label")" "$(json_escape "$target")" "$b12" "$b13" \
    "${verdict%%|*}" "$(json_escape "${verdict#*|}")" \
    "$(_tls_detail_json "$v12" 1.2)" "$(_tls_detail_json "$v13" 1.3)" "$dljson"
}

check_one_dns_json() {
  local res state text
  res="$(z2r_dns_check_series | sed -n 1p)"
  state="$(z2r_dns_field "$res" 1)"
  text="$(z2r_dns_series_text "$res")"
  printf '{"label":"DNS антиспуф","target":"%s","verdict":"%s","text":"%s"}' \
    "$(json_escape "nslookup ${Z2R_DNS_CHECK_DOMAIN} @ ${Z2R_DNS_CHECK_SERVER}")" \
    "$state" "$(json_escape "$text")"
}

profile_check_json() {
  local profile="$1" gv
  case "$profile" in
    1)
      printf '{"results":[%s]}' "$(check_one_target_json "YouTube" "https://www.youtube.com/")"
      ;;
    2)
      gv="$(get_yt_cluster_domain)"
      printf '{"results":[%s]}' "$(check_one_target_json "Googlevideo" "https://${gv}")"
      ;;
    3)
      printf '{"results":[%s]}' "$(check_one_target_json "Blocked Sites" "https://meduza.io")"
      ;;
    4)
      printf '{"results":[%s]}' "$(check_one_target_json "Discord" "https://discord.com/")"
      ;;
    5|6)
      printf '{"results":[],"message":"%s"}' "$(json_escape "Для UDP-профиля быстрая TLS-проверка неприменима. Проверьте работу в браузере или приложении.")"
      ;;
    10)
      printf '{"results":[%s]}' "$(check_one_dns_json)"
      ;;
    *)
      printf '{"results":[]}'
      ;;
  esac
}

_quic443_state_text() {
  local state
  state="$(backup_smart_quic443_state "$1" 2>/dev/null)"
  case "$state" in
    1) echo "включены" ;;
    0) echo "выключены" ;;
    *) echo "неизвестно" ;;
  esac
}

_provider_cache_text() {
  local cache="/opt/zator/extra_strats/cache/provider.txt"
  if [ -s "$cache" ]; then
    cat "$cache"
  else
    echo "Не определён"
  fi
}

_client_scope_diagnostics_state() {
  local enabled mask shift max desync postnat mask_n shift_n max_n desync_n postnat_n mode reason
  local mask_json shift_json max_json scoped_count conflicts file manual_file
  enabled="$(config_get_var "$CONFIG_FILE" CLIENT_SCOPE_ENABLE 2>/dev/null || printf 0)"
  mask="$(config_get_var "$CONFIG_FILE" CLIENT_SCOPE_MARK_MASK 2>/dev/null || true)"
  shift="$(config_get_var "$CONFIG_FILE" CLIENT_SCOPE_MARK_SHIFT 2>/dev/null || printf 0)"
  max="$(config_get_var "$CONFIG_FILE" CLIENT_SCOPE_MARK_MAX 2>/dev/null || printf 255)"
  desync="$(config_get_var "$CONFIG_FILE" DESYNC_MARK 2>/dev/null || printf 0x40000000)"
  postnat="$(config_get_var "$CONFIG_FILE" DESYNC_MARK_POSTNAT 2>/dev/null || printf 0x20000000)"
  mask_json=0; shift_json=0; max_json=0
  mode=disabled; reason=disabled
  if [ "$enabled" = 1 ]; then
    if [ -z "$mask" ]; then
      reason=missing-mask
    elif mask_n="$(config_client_scope_num "$mask" 2>/dev/null)"; then
      mask_json="$mask_n"
      shift_n="$(config_client_scope_num "$shift" 2>/dev/null || true)"
      max_n="$(config_client_scope_num "$max" 2>/dev/null || true)"
      [ -n "$shift_n" ] && shift_json="$shift_n"
      [ -n "$max_n" ] && max_json="$max_n"
      if [ -n "$shift_n" ] && [ -n "$max_n" ] &&
         desync_n="$(config_client_scope_num "$desync" 2>/dev/null)" &&
         postnat_n="$(config_client_scope_num "$postnat" 2>/dev/null)" &&
         [ "$mask_n" -gt 0 ] && [ "$shift_n" -le 31 ] && [ "$max_n" -gt 0 ] &&
         [ "$max_n" -le 255 ] && [ $((mask_n % (2 ** shift_n))) -eq 0 ]; then
        if [ $((mask_n & desync_n)) -ne 0 ] || [ $((mask_n & postnat_n)) -ne 0 ]; then
          reason=mask-conflict
        else
          mode=mark; reason=no-scoped-lock
        fi
      else
        reason=invalid-mask
      fi
    else
      reason=invalid-mask
    fi
  elif mask_n="$(config_client_scope_num "$mask" 2>/dev/null)" &&
       shift_n="$(config_client_scope_num "$shift" 2>/dev/null)" &&
       max_n="$(config_client_scope_num "$max" 2>/dev/null)"; then
    mask_json="$mask_n"; shift_json="$shift_n"; max_json="$max_n"
  fi
  file="$ORCH_DIR/locked.tsv"; manual_file="$ORCH_DIR/locked.manual.tsv"
  scoped_count="$(awk -F '\t' '$1 ~ /^mark:[0-9]+$/ && NF >= 4 {n++} END {print n+0}' "$file" "$manual_file" 2>/dev/null)"
  conflicts="$(awk -F '\t' '$1 ~ /^mark:[0-9]+$/ && NF >= 4 {key=$1 SUBSEP $2 SUBSEP $3; seen[key SUBSEP $4]=1} END {for (item in seen) {split(item, fields, SUBSEP); keys[fields[1] SUBSEP fields[2] SUBSEP fields[3]]++} for (key in keys) if (keys[key] > 1) n++} END {print n+0}' "$file" "$manual_file" 2>/dev/null)"
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$mode" "$mask_json" "$shift_json" "$max_json" "${scoped_count:-0}" "${conflicts:-0}" "$reason"
}

_client_scope_diagnostics_json_from_state() {
  local state="$1" mode mask_json shift_json max_json scoped_count conflicts reason
  IFS='|' read -r mode mask_json shift_json max_json scoped_count conflicts reason <<< "$state"
  printf '{"mode":"%s","mask":%s,"shift":%s,"max_scope":%s,"scoped_lock_count":%s,"conflicts":%s,"last_seen_scope":"unavailable","fallback_reason":"%s"}' \
    "$mode" "$mask_json" "$shift_json" "$max_json" "$scoped_count" "$conflicts" "$reason"
}

client_scope_diagnostics_json() {
  local state
  state="$(_client_scope_diagnostics_state)"
  _client_scope_diagnostics_json_from_state "$state"
}

client_scopes_json() {
  local scopes scope first=1 enabled warning diagnostics diagnostic_state
  local mode mask_json shift_json max_json scoped_count conflicts reason
  scopes="$(orch_scoped_list_scopes 2>/dev/null | sort -u)"
  diagnostic_state="$(_client_scope_diagnostics_state)"
  IFS='|' read -r mode mask_json shift_json max_json scoped_count conflicts reason <<< "$diagnostic_state"
  diagnostics="$(_client_scope_diagnostics_json_from_state "$diagnostic_state")"
  enabled=false; warning=""
  [ "$mode" = mark ] && enabled=true
  case "$reason" in
    missing-mask) warning="Client scope включён, но firewall mapping не задан." ;;
    mask-conflict) warning="Маска client scope пересекается со служебной mark-маской; включён безопасный fallback." ;;
    invalid-mask) warning="Маска client scope некорректна; включён безопасный fallback." ;;
  esac
  printf '{"enabled":%s,"warning":"%s","scopes":[' "$enabled" "$(json_escape "$warning")"
  while IFS= read -r scope; do
    [ -n "$scope" ] || continue
    [ "$first" = 1 ] || printf ','
    printf '"%s"' "$(json_escape "$scope")"
    first=0
  done <<< "$scopes"
  printf '],"diagnostics":%s}' "$diagnostics"
}

scope_param_valid() {
  case "${1:-default}" in
    default) return 0 ;;
    mark:*) [[ "${1#mark:}" =~ ^[0-9]+$ ]] && return 0 ;;
  esac
  return 1
}

api_scopes() {
  parse_params
  scope_param_valid "${PARAM_SCOPE:-default}" || send_error "400 Bad Request" "Некорректный scope"
  send_json "200 OK" "$(client_scopes_json)"
}

status_json() {
  local running locks_text provider_text
  _snapshot_once
  if zapret2_running; then running=true; else running=false; fi
  locks_text="$(strategy_locks_status_text)"
  provider_text="$(_provider_cache_text)"
  _json_esc "$locks_text"; locks_text="$REPLY"
  _json_esc "$provider_text"; provider_text="$REPLY"
  _json_esc "$MENU_HOSTLIST"; local hostlist_text="$REPLY"
  _json_esc "$MENU_FWTYPE"; local fw_text="$REPLY"
  _json_esc "$MENU_FLOWOFFLOAD"; local offload_text="$REPLY"
  _json_esc "$MENU_TLS_BLOB"; local tls_text="$REPLY"
  _json_esc "$MENU_WG_STATE"; local wg_text="$REPLY"
  _json_esc "$MENU_AUTO_MODE"; local auto_text="$REPLY"
  _json_esc "$MENU_RST_GUARD"; local rst_text="$REPLY"
  _json_esc "$MENU_REASM"; local reasm_text="$REPLY"
  _json_esc "$MENU_QUIC443"; local quic_text="$REPLY"
  cat <<EOF
{"zapret2_running":$running,"strategy_locks_status":"$locks_text","hostlist_mode":"$hostlist_text","fwtype":"$fw_text","flowoffload":"$offload_text","tls_blob_mode":"$tls_text","wireguard":"$wg_text","auto_mode":"$auto_text","rst_guard":"$rst_text","reasm":"$reasm_text","quic443":"$quic_text","provider":"$provider_text","client_scope":$(client_scope_diagnostics_json),"profiles":$(all_profiles_json)}
EOF
}

api_status() {
  parse_params
  scope_param_valid "${PARAM_SCOPE:-default}" || send_error "400 Bad Request" "Некорректный scope"
  send_json "200 OK" "$(status_json)"
}

# Выполняет api_*_get в под-оболочке с подменённым выводом и отдаёт чистый JSON.
# Для начальной инициализации webui: один state.cgi вместо ~15 отдельных CGI.
_state_capture() {
  (
    send_json() { printf '%s' "$2"; }
    send_error() { printf '{"_error":"%s"}' "$(json_escape "$2")"; exit 0; }
    "$1"
  )
}

# Токены CSV-портов в JSON-массив без внешних процессов (значения —
# только цифры и дефисы, escape не нужен).
_csv_tokens_json() {
  local out="" t first=1 old_ifs="$IFS"
  IFS=','
  for t in $1; do
    [ -n "$t" ] || continue
    if [ "$first" = "1" ]; then first=0; else out="${out},"; fi
    out="${out}\"${t}\""
  done
  IFS="$old_ifs"
  printf '%s' "$out"
}

api_state() {
  parse_params
  scope_param_valid "${PARAM_SCOPE:-default}" || send_error "400 Bad Request" "Некорректный scope"
  _snapshot_once
  local fake_dir="/opt/zator/files/fake" f b blobs_tls="" blobs_wg=""
  for f in "$fake_dir"/*.bin; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    case "$b" in tls_*.bin|custom_tls.bin)
      blobs_tls="${blobs_tls}${blobs_tls:+,}\"${b}\"" ;;
    esac
  done
  for f in "$fake_dir"/wg_initial_fake_*; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    blobs_wg="${blobs_wg}${blobs_wg:+,}\"${b}\""
  done
  ports_split "$MENU_PORTS_TCP_FULL" "80"
  local tcp_full="$MENU_PORTS_TCP_FULL" tcp_user="$_PORTS_USER" tcp_base="$_PORTS_BASE"
  ports_split "$MENU_PORTS_UDP_FULL" "443"
  local udp_full="$MENU_PORTS_UDP_FULL" udp_user="$_PORTS_USER" udp_base="$_PORTS_BASE"
  local quic_json dns_json
  if [ "$MENU_QUIC443" = "неизвестно" ]; then
    quic_json='{"_error":"Блок QUIC (UDP443) не найден в конфиге. Обновите конфиг через CLI (пункт 5 главного меню)."}'
  else
    quic_json="{\"state\":\"$MENU_QUIC443\",\"enabled\":$([ "$MENU_QUIC443" = "включены" ] && echo true || echo false)}"
  fi
  if [ "$MENU_DNS_DESINC" = "Неизвестно" ]; then
    dns_json='{"_error":"Блок DNS (UDP:53) не найден в конфиге. Обновите конфиг через CLI (пункт 5 главного меню)."}'
  else
    dns_json="{\"state\":\"$MENU_DNS_DESINC\",\"enabled\":$([ "$MENU_DNS_DESINC" = "Включен" ] && echo true || echo false)}"
  fi
  send_json "200 OK" "$(cat <<EOF
{"status":$(status_json),"scopes":$(client_scopes_json),"tls_blob":{"current_mode":"$MENU_TLS_BLOB_MODE","current_blob":"$MENU_BLOB_FILE","available_blobs":[$blobs_tls]},"wg_blob":{"current_blob":"$MENU_WG_BLOB","current_repeats":"$MENU_WG_REPEATS","available_blobs":[$blobs_wg]},"wg_state":{"state":"$MENU_WG_STATE_RAW","enabled":$([ "$MENU_WG_STATE_RAW" = "1" ] && echo true || echo false)},"fallback":{"state":"$MENU_FALLBACK","enabled":$([ "$MENU_FALLBACK" = "включен" ] && echo true || echo false)},"udp_games":{"state":"$MENU_UDP_GAMES","enabled":$([ "$MENU_UDP_GAMES" = "Включен" ] && echo true || echo false),"ports":"$udp_full"},"auto_mode":{"state":"$MENU_AUTO_MODE","enabled":$([ "$MENU_AUTO_MODE" = "включен" ] && echo true || echo false)},"hostlist":{"state":"$MENU_HOSTLIST","auto":$([ "$MENU_HOSTLIST" = "авто" ] && echo true || echo false)},"rst_guard":{"state":"$MENU_RST_GUARD","enabled":$([ "$MENU_RST_GUARD" = "включен" ] && echo true || echo false),"lua_available":$([ -s "$ZATOR_ROOT/lua/rst-guard.lua" ] && echo true || echo false)},"reasm":{"state":"$MENU_REASM","enabled":$([ "$MENU_REASM" = "включено" ] && echo true || echo false)},"quic443":$quic_json,"dns_desync":$dns_json,"ports":{"tcp":{"full":"$tcp_full","user":[$(_csv_tokens_json "$tcp_user")],"base":"$tcp_base"},"udp":{"full":"$udp_full","user":[$(_csv_tokens_json "$udp_user")],"base":"$udp_base"}},"provider":$(_state_capture api_provider_get),"backups":$(_state_capture api_backups_list)}
EOF
)"
}

api_set_lock() {
  parse_params
  [[ "${PARAM_PROFILE:-}" =~ ^[1-9][0-9]*$ ]] || send_error "400 Bad Request" "Некорректный профиль"
  [[ "${PARAM_STRATEGY:-}" =~ ^[0-9]+$ ]] || send_error "400 Bad Request" "Некорректная стратегия"
  local requested_scope="${PARAM_SCOPE:-default}"
  orch_scope_validate "$requested_scope" "$PARAM_PROFILE" "$(profile_proto "$PARAM_PROFILE")" "$PARAM_STRATEGY" || send_error "400 Bad Request" "Некорректный scope или lock"
  case "$PARAM_PROFILE" in
    1|2|3|4)
      [ "$(config_mode_text auto_mode "$CONFIG_FILE")" = "включен" ] && \
        send_error "409 Conflict" "Профиль $PARAM_PROFILE управляется авторотацией TCP/HTTP. Сначала выключите авторотацию."
      ;;
  esac
  local max proto_list check_json old_udp_ports
  max="$(orch_max_strategy_for_profile "$PARAM_PROFILE")"
  if [ "${PARAM_STRATEGY}" -ne 0 ]; then
    [ "${PARAM_STRATEGY}" -ge 1 ] && [ "${PARAM_STRATEGY}" -le "${max:-0}" ] || send_error "400 Bad Request" "Стратегия вне диапазона"
  fi
  proto_list="$(config_profile_proto_list "$PARAM_PROFILE")"
  [ -n "$proto_list" ] || send_error "400 Bad Request" "Не удалось определить протокол профиля"
  old_udp_ports="$(config_get_var "$CONFIG_FILE" NFQWS2_PORTS_UDP)"
  if [ "$requested_scope" = default ]; then
    profile_state_set_and_apply "$PARAM_PROFILE" "$proto_list" "$PARAM_STRATEGY" "$CONFIG_FILE" || send_error "500 Internal Server Error" "Не удалось сохранить состояние профиля"
  else
    orch_scoped_locked_set "$requested_scope" "$PARAM_PROFILE" "${proto_list%% *}" "$PARAM_STRATEGY" || send_error "500 Internal Server Error" "Не удалось сохранить scoped lock"
  fi
  profile_config_voice_ports_changed "$PARAM_PROFILE" "$CONFIG_FILE" "$old_udp_ports" && service_zapret2 restart >/dev/null 2>&1 || true
  telemetry_notify
  send_json "200 OK" "{\"ok\":true}"
}

api_clear_lock() {
  parse_params
  [[ "${PARAM_PROFILE:-}" =~ ^[1-9][0-9]*$ ]] || send_error "400 Bad Request" "Некорректный профиль"
  case "$PARAM_PROFILE" in
    1|2|3|4)
      [ "$(config_mode_text auto_mode "$CONFIG_FILE")" = "включен" ] && \
        send_error "409 Conflict" "Профиль $PARAM_PROFILE управляется авторотацией TCP/HTTP. Сначала выключите авторотацию."
      ;;
  esac
  local requested_scope="${PARAM_SCOPE:-default}" proto_list old_udp_ports
  orch_scope_validate "$requested_scope" "$PARAM_PROFILE" "$(profile_proto "$PARAM_PROFILE")" clear || send_error "400 Bad Request" "Некорректный scope"
  proto_list="$(config_profile_proto_list "$PARAM_PROFILE")"
  [ -n "$proto_list" ] || send_error "400 Bad Request" "Не удалось определить протокол профиля"
  old_udp_ports="$(config_get_var "$CONFIG_FILE" NFQWS2_PORTS_UDP)"
  if [ "$requested_scope" = default ]; then
    profile_state_set_and_apply "$PARAM_PROFILE" "$proto_list" "auto" "$CONFIG_FILE" || send_error "500 Internal Server Error" "Не удалось сбросить состояние профиля"
  else
    orch_scoped_locked_clear "$requested_scope" "$PARAM_PROFILE" "${proto_list%% *}" || send_error "500 Internal Server Error" "Не удалось сбросить scoped lock"
  fi
  profile_config_voice_ports_changed "$PARAM_PROFILE" "$CONFIG_FILE" "$old_udp_ports" && service_zapret2 restart >/dev/null 2>&1 || true
  telemetry_notify
  send_json "200 OK" "{\"ok\":true}"
}

api_service() {
  parse_params
  case "${PARAM_ACTION:-}" in
    start|stop|restart) ;;
    *) send_error "400 Bad Request" "Некорректное действие" ;;
  esac
  service_zapret2 "$PARAM_ACTION" || send_error "500 Internal Server Error" "Не удалось выполнить команду zapret2"
  send_json "200 OK" "{\"ok\":true}"
}

api_check() {
  parse_params
  if [[ "${PARAM_PROFILE:-}" =~ ^[1-9][0-9]*$ ]]; then
    send_json "200 OK" "$(profile_check_json "$PARAM_PROFILE")"
    return
  fi
  local gv results
  gv="$(get_yt_cluster_domain)"
  results="$(check_one_target_json "YouTube" "https://www.youtube.com/")"
  results="${results},$(check_one_target_json "Googlevideo" "https://${gv}")"
  results="${results},$(check_one_target_json "Blocked Sites" "https://meduza.io")"
  results="${results},$(check_one_target_json "Instagram" "https://www.instagram.com/")"
  send_json "200 OK" "{\"results\":[${results}]}"
}

api_tls_blob_get() {
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zator/files/fake"
  local current_blob current_mode available_blobs

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"
  [ -d "$fake_dir" ] || send_error "500 Internal Server Error" "Директория fake не найдена"

  current_blob="$(sed -n -E 's#.*--blob=maxru:@/opt/(zapret2|zator)/files/fake/([^[:space:]]+).*#\2#p' "$cfg" | head -n1)"
  [ -z "$current_blob" ] && current_blob=""
  current_mode="$(config_tls_blob_mode_value "$cfg")"

  available_blobs=""
  if sort -z </dev/null >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      f="$(basename "$f")"
      case "$f" in
        tls_*.bin|custom_tls.bin)
          available_blobs="${available_blobs}${available_blobs:+,}\"$(json_escape "$f")\""
          ;;
      esac
    done < <(find "$fake_dir" -maxdepth 1 -type f -name '*.bin' -print0 | sort -z)
  else
    while IFS= read -r f; do
      f="$(basename "$f")"
      case "$f" in
        tls_*.bin|custom_tls.bin)
          available_blobs="${available_blobs}${available_blobs:+,}\"$(json_escape "$f")\""
          ;;
      esac
    done < <(find "$fake_dir" -maxdepth 1 -type f -name '*.bin' | sort)
  fi

  send_json "200 OK" "{
    \"current_mode\":\"$(json_escape "$current_mode")\",
    \"current_blob\":\"$(json_escape "$current_blob")\",
    \"available_blobs\":[$available_blobs]
  }"
}

api_tls_blob_set() {
  local blob="$PARAM_VALUE"
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zator/files/fake"
  local sed_ereg prefix

  case "$blob" in
    fake_default_tls)
      ;;
    tls_*.bin|custom_tls.bin)
      [ -f "$fake_dir/$blob" ] || send_error "400 Bad Request" "Файл блоба не существует: $blob"
      ;;
    *)
      send_error "400 Bad Request" "Некорректное значение блоба: $blob"
      ;;
  esac

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  sed_ereg="$(config_sed_ereg)"

  if [ "$blob" = "fake_default_tls" ]; then
    sed -i $sed_ereg '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)maxru#\1fake_default_tls#g; }' "$cfg"
  else
    prefix="--blob=maxru:@/opt/zator/files/fake/"

    if ! grep -qE -- "--blob=maxru:@/opt/(zapret2|zator)/files/fake/" "$cfg"; then
      send_error "500 Internal Server Error" "Строка --blob=maxru не найдена в конфиге"
    fi

    sed -i $sed_ereg '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)fake_default_tls#\1maxru#g; }' "$cfg"
    sed -i $sed_ereg "s#--blob=maxru:@/opt/(zapret2|zator)/files/fake/[^[:space:]]+#${prefix}${blob}#g" "$cfg"
  fi

  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED}"
}

api_wg_blob_get() {
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zator/files/fake"
  local current_blob current_repeats available_blobs

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"
  [ -d "$fake_dir" ] || send_error "500 Internal Server Error" "Директория fake не найдена"

  current_blob="$(sed -n -E 's#.*--blob=fakewgblob:@/opt/(zapret2|zator)/files/fake/([^[:space:]]+).*#\2#p' "$cfg" | head -n1)"
  [ -z "$current_blob" ] && current_blob=""
  current_repeats="$(sed -n -E 's#.*blob=fakewgblob:repeats=([0-9]+).*#\1#p' "$cfg" | head -n1)"
  [ -z "$current_repeats" ] && current_repeats=""

  # Только файлы вида wg_initial_fake_* (как в menu_action_set_wg_blob)
  available_blobs=""
  if sort -z </dev/null >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      f="$(basename "$f")"
      available_blobs="${available_blobs}${available_blobs:+,}\"$(json_escape "$f")\""
    done < <(find "$fake_dir" -maxdepth 1 -type f -name 'wg_initial_fake_*' -print0 | sort -z)
  else
    while IFS= read -r f; do
      f="$(basename "$f")"
      available_blobs="${available_blobs}${available_blobs:+,}\"$(json_escape "$f")\""
    done < <(find "$fake_dir" -maxdepth 1 -type f -name 'wg_initial_fake_*' | sort)
  fi

  send_json "200 OK" "{
    \"current_blob\":\"$(json_escape "$current_blob")\",
    \"current_repeats\":\"$(json_escape "$current_repeats")\",
    \"available_blobs\":[$available_blobs]
  }"
}

api_wg_blob_set() {
  local blob="$PARAM_VALUE"
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zator/files/fake"
  local sed_ereg prefix

  # Валидация имени файла: только wg_initial_fake_* (как в CLI)
  case "$blob" in
    wg_initial_fake_*)
      [ -f "$fake_dir/$blob" ] || send_error "400 Bad Request" "Файл блоба не существует: $blob"
      ;;
    *)
      send_error "400 Bad Request" "Некорректное значение блоба: $blob"
      ;;
  esac

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  sed_ereg="$(config_sed_ereg)"
  prefix="--blob=fakewgblob:@/opt/zator/files/fake/"

  if ! grep -qE -- "--blob=fakewgblob:@/opt/(zapret2|zator)/files/fake/" "$cfg"; then
    send_error "500 Internal Server Error" "Стратегия WireGuard не найдена в конфиге (нет --blob=fakewgblob:@...)"
  fi

  sed -i $sed_ereg "s#--blob=fakewgblob:@/opt/(zapret2|zator)/files/fake/[^[:space:]]+#${prefix}${blob}#g" "$cfg"

  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED}"
}

_fallback_state() {
  config_mode_text fallback "$1"
}

_fallback_set_state() {
  local cfg="$1"
  local want_on="$2"
  if [ "$want_on" = "1" ]; then
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^[[:space:]]*--skip[[:space:]]\+//' "$cfg"
    sed -i '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/ s/^[[:space:]]*--skip[[:space:]]\+//' "$cfg"
  else
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^[[:space:]]*--filter-tcp=443 --filter-l7=tls/--skip --filter-tcp=443 --filter-l7=tls/' "$cfg"
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^[[:space:]]*--filter-tcp=443$/--skip --filter-tcp=443/' "$cfg"
    sed -i '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/ s/^[[:space:]]*--filter-tcp=80 --filter-l7=http/--skip --filter-tcp=80 --filter-l7=http/' "$cfg"
  fi
}

api_fallback_get() {
  local cfg="/opt/zapret2/config"
  local state

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  state="$(_fallback_state "$cfg")"

  send_json "200 OK" "{\"state\":\"$(json_escape "$state")\",\"enabled\":$([ "$state" = "включен" ] && echo true || echo false)}"
}

api_fallback_state_set() {
  local value="$PARAM_VALUE"
  local cfg="/opt/zapret2/config"

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac

  if [ "$(_fallback_state "$cfg")" = "недоступен" ]; then
    send_error "409 Conflict" "Безразборный режим недоступен при включённой авторотации TCP/HTTP. Сначала выключите авторотацию."
  fi

  if type backup_smart_set_fallback >/dev/null 2>&1; then
    for cfg in /opt/zapret2/config /opt/zapret2/config.default; do
      [ -f "$cfg" ] || continue
      backup_smart_set_fallback "$cfg" "$value"
    done
  else
    _fallback_set_state "$cfg" "$value"
  fi
  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED}"
}

api_wg_repeats_set() {
  local repeats="$PARAM_VALUE"
  local cfg="/opt/zapret2/config"
  local sed_ereg

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  case "$repeats" in
    ''|*[!0-9]*)
      send_error "400 Bad Request" "Некорректное значение repeats: $repeats"
      ;;
  esac
  [ "$repeats" -ge 2 ] 2>/dev/null && [ "$repeats" -le 99 ] 2>/dev/null ||
    send_error "400 Bad Request" "Значение repeats должно быть от 2 до 99"

  if ! grep -q 'blob=fakewgblob:repeats=' "$cfg"; then
    send_error "500 Internal Server Error" "Стратегия WireGuard не найдена в конфиге (нет blob=fakewgblob:repeats=)"
  fi

  sed_ereg="$(config_sed_ereg)"
  sed -i $sed_ereg "s#(blob=fakewgblob:repeats=)[0-9]+#\\1${repeats}#g" "$cfg"

  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED}"
}

_wg_state_get() {
  local cfg="$1" blk
  blk="$(sed -n '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/p' "$cfg" 2>/dev/null)"
  if printf "%s\n" "$blk" | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-l7=wireguard[[:space:]]*$'; then
    printf '0'
  elif printf "%s\n" "$blk" | grep -q -- '--filter-l7=wireguard'; then
    printf '1'
  fi
}

_wg_state_set() {
  local cfg="$1" want_on="$2"
  if [ "$want_on" = "1" ]; then
    sed -i '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/ s/^[[:space:]]*--skip[[:space:]]\+--filter-l7=wireguard/--filter-l7=wireguard/' "$cfg"
  else
    sed -i '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/ s/^[[:space:]]*--filter-l7=wireguard/--skip --filter-l7=wireguard/' "$cfg"
  fi
}

api_wg_state_get() {
  local cfg="/opt/zapret2/config"
  local state

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  state="$(_wg_state_get "$cfg")"

  send_json "200 OK" "{
    \"state\":\"$(json_escape "$state")\",
    \"enabled\":$([ "$state" = "1" ] && echo true || echo false)
  }"
}

api_wg_state_set() {
  local cfg="/opt/zapret2/config"
  local value="$PARAM_VALUE"

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac

  if [ -z "$(_wg_state_get "$cfg")" ]; then
    send_error "500 Internal Server Error" "Стратегия WireGuard не найдена в конфиге (нет блока #Z2R_WG_*)"
  fi

  _wg_state_set "$cfg" "$value"

  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED}"
}

_udp_games_set_skip() {
  local cfg="$1" want_on="$2"
  if [ "$want_on" = "1" ]; then
    sed -i '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/ s/^--skip[[:space:]]\+--filter-udp=1026/--filter-udp=1026/' "$cfg"
  else
    sed -i '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/ s/^--filter-udp=1026/--skip --filter-udp=1026/' "$cfg"
  fi
}

api_udp_games_get() {
  local cfg="/opt/zapret2/config"
  local state ports

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  state="$(config_mode_text udp_games "$cfg")"
  ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"

  send_json "200 OK" "{
    \"state\":\"$(json_escape "$state")\",
    \"enabled\":$([ "$state" = "Включен" ] && echo true || echo false),
    \"ports\":\"$(json_escape "$ports")\"
  }"
}

api_udp_games_set() {
  local cfg="/opt/zapret2/config"
  local value="$PARAM_VALUE"
  local current_ports new_ports

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac

  current_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"

  if [ "$value" = "1" ]; then
    new_ports="$(csv_add_tokens "${current_ports:-443}" "1026-65531")"
    config_set_var "$cfg" NFQWS2_PORTS_UDP "$new_ports"
    _udp_games_set_skip "$cfg" 1
  else
    new_ports="$(csv_remove_tokens "$current_ports" "1026-65531")"
    [ -n "$new_ports" ] || new_ports="443"
    config_set_var "$cfg" NFQWS2_PORTS_UDP "$new_ports"
    _udp_games_set_skip "$cfg" 0
  fi

  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED}"
}

_require_config() {
  [ -f "$CONFIG_FILE" ] || send_error "500 Internal Server Error" "Config не найден"
}

api_auto_mode_get() {
  local state
  _require_config
  state="$(config_mode_text auto_mode "$CONFIG_FILE")"
  send_json "200 OK" "{\"state\":\"$(json_escape "$state")\",\"enabled\":$([ "$state" = "включен" ] && echo true || echo false)}"
}

api_auto_mode_set() {
  local value="$PARAM_VALUE" cfg
  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac
  _require_config
  if [ "$value" = "1" ] && [ "$(config_mode_text fallback "$CONFIG_FILE")" = "включен" ]; then
    send_error "409 Conflict" "Авторотация недоступна при включённом безразборном режиме. Сначала выключите безразборный режим."
  fi
  for cfg in /opt/zapret2/config /opt/zapret2/config.default; do
    [ -f "$cfg" ] || continue
    config_auto_layout_valid "$cfg" || send_error "500 Internal Server Error" "В $cfg не найдены маркеры авторежима. Обновите конфиг через CLI (пункт 5 главного меню)."
  done
  for cfg in /opt/zapret2/config /opt/zapret2/config.default; do
    [ -f "$cfg" ] || continue
    config_set_auto_mode "$cfg" "$value" || send_error "500 Internal Server Error" "Не удалось переключить авторотацию в $cfg"
  done
  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED,\"state\":\"$(json_escape "$(config_mode_text auto_mode "$CONFIG_FILE")")\"}"
}

api_hostlist_get() {
  local state
  _require_config
  state="$(config_mode_text hostlist "$CONFIG_FILE")"
  send_json "200 OK" "{\"state\":\"$(json_escape "$state")\",\"auto\":$([ "$state" = "авто" ] && echo true || echo false)}"
}

api_hostlist_set() {
  local value="$PARAM_VALUE" cfg
  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac
  _require_config
  for cfg in /opt/zapret2/config /opt/zapret2/config.default; do
    [ -f "$cfg" ] || continue
    backup_smart_set_hostlist "$cfg" "$value"
  done
  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED,\"state\":\"$(json_escape "$(config_mode_text hostlist "$CONFIG_FILE")")\"}"
}

api_rst_guard_get() {
  local state
  _require_config
  state="$(config_mode_text rst_guard "$CONFIG_FILE")"
  send_json "200 OK" "{\"state\":\"$(json_escape "$state")\",\"enabled\":$([ "$state" = "включен" ] && echo true || echo false),\"lua_available\":$([ -s "$ZATOR_ROOT/lua/rst-guard.lua" ] && echo true || echo false)}"
}

api_rst_guard_set() {
  local value="$PARAM_VALUE"
  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac
  _require_config
  if [ "$value" = "1" ] && [ ! -s "$ZATOR_ROOT/lua/rst-guard.lua" ]; then
    send_error "500 Internal Server Error" "Файл rst-guard.lua отсутствует на устройстве. Включите защиту один раз через CLI (пункт 18) — при включении файл скачивается автоматически."
  fi
  backup_smart_set_rst_guard "$CONFIG_FILE" "$value"
  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED,\"state\":\"$(json_escape "$(config_mode_text rst_guard "$CONFIG_FILE")")\"}"
}

api_reasm_get() {
  local state
  _require_config
  state="$(config_mode_text reasm_disable "$CONFIG_FILE")"
  send_json "200 OK" "{\"state\":\"$(json_escape "$state")\",\"enabled\":$([ "$state" = "включено" ] && echo true || echo false)}"
}

api_reasm_set() {
  local value="$PARAM_VALUE"
  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac
  _require_config
  grep -q '^NFQWS2_OPT="' "$CONFIG_FILE" || send_error "500 Internal Server Error" "Не найден блок NFQWS2_OPT в конфиге. Обновите конфиг через CLI (пункт 5 главного меню)."
  backup_smart_set_reasm "$CONFIG_FILE" "$value"
  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED,\"state\":\"$(json_escape "$(config_mode_text reasm_disable "$CONFIG_FILE")")\"}"
}

api_quic443_get() {
  _require_config
  [ -n "$(backup_smart_quic443_state "$CONFIG_FILE")" ] || \
    send_error "500 Internal Server Error" "Блок QUIC (UDP443) не найден в конфиге. Обновите конфиг через CLI (пункт 5 главного меню)."
  send_json "200 OK" "{\"state\":\"$(json_escape "$(_quic443_state_text "$CONFIG_FILE")")\",\"enabled\":$([ "$(backup_smart_quic443_state "$CONFIG_FILE")" = "1" ] && echo true || echo false)}"
}

api_quic443_set() {
  local value="$PARAM_VALUE"
  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac
  _require_config
  [ -n "$(backup_smart_quic443_state "$CONFIG_FILE")" ] || \
    send_error "500 Internal Server Error" "Блок QUIC (UDP443) не найден в конфиге. Обновите конфиг через CLI (пункт 5 главного меню)."
  backup_smart_set_quic443 "$CONFIG_FILE" "$value"
  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED,\"state\":\"$(json_escape "$(_quic443_state_text "$CONFIG_FILE")")\"}"
}

# Антиспуф DNS (профиль 10, UDP:53). Ядро — те же сеттеры, что и в пункте 8
# главного меню (menu_action_toggle_dns_desync): блок #Z2R_DNS_* + порт 53
# в NFQWS2_PORTS_UDP. Состояние — config_mode_text dns_desync.
api_dns_desync_get() {
  local state
  _require_config
  state="$(config_mode_text dns_desync "$CONFIG_FILE")"
  [ "$state" != "Неизвестно" ] || \
    send_error "500 Internal Server Error" "Блок DNS (UDP:53) не найден в конфиге. Обновите конфиг через CLI (пункт 5 главного меню)."
  send_json "200 OK" "{\"state\":\"$(json_escape "$state")\",\"enabled\":$([ "$state" = "Включен" ] && echo true || echo false)}"
}

api_dns_desync_set() {
  local value="$PARAM_VALUE"
  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac
  _require_config
  [ "$(config_mode_text dns_desync "$CONFIG_FILE")" != "Неизвестно" ] || \
    send_error "500 Internal Server Error" "Блок DNS (UDP:53) не найден в конфиге. Обновите конфиг через CLI (пункт 5 главного меню)."
  type backup_smart_set_dns_desync >/dev/null 2>&1 || \
    send_error "500 Internal Server Error" "Сеттеры lib/actions.sh недоступны. Обновите z2r."
  backup_smart_set_dns_desync "$CONFIG_FILE" "$value"
  config_profile_dns_ports_apply "$CONFIG_FILE" "$value"
  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED,\"state\":\"$(json_escape "$(config_mode_text dns_desync "$CONFIG_FILE")")\"}"
}

_ports_tokens_json() {
  local csv="$1" out="" first=1 t old_ifs="$IFS"
  [ -n "$csv" ] || { printf '%s' "$out"; return; }
  IFS=','
  for t in $csv; do
    [ -n "$t" ] || continue
    if [ "$first" = "1" ]; then first=0; else out="${out},"; fi
    out="${out}\"$(json_escape "$t")\""
  done
  IFS="$old_ifs"
  printf '%s' "$out"
}

api_ports_get() {
  local tcp udp tcp_user tcp_base udp_user udp_base
  _require_config
  tcp="$(config_get_var "$CONFIG_FILE" NFQWS2_PORTS_TCP)"
  udp="$(config_get_var "$CONFIG_FILE" NFQWS2_PORTS_UDP)"
  ports_split "$tcp" "80"
  tcp_user="$_PORTS_USER"
  tcp_base="$_PORTS_BASE"
  ports_split "$udp" "443"
  udp_user="$_PORTS_USER"
  udp_base="$_PORTS_BASE"
  send_json "200 OK" "{
    \"tcp\":{\"full\":\"$(json_escape "$tcp")\",\"user\":[$(_ports_tokens_json "$tcp_user")],\"base\":\"$(json_escape "$tcp_base")\"},
    \"udp\":{\"full\":\"$(json_escape "$udp")\",\"user\":[$(_ports_tokens_json "$udp_user")],\"base\":\"$(json_escape "$udp_base")\"}
  }"
}

_validate_proto_param() {
  case "${PARAM_PROTO:-}" in
    tcp|udp) ;;
    *) send_error "400 Bad Request" "Некорректный протокол: ${PARAM_PROTO:-}" ;;
  esac
}

api_ports_add() {
  _validate_proto_param
  [ -n "${PARAM_VALUE:-}" ] || send_error "400 Bad Request" "Не указаны порты"
  _require_config
  if ! ports_apply_add "$PARAM_PROTO" "$PARAM_VALUE" "$CONFIG_FILE"; then
    send_error "400 Bad Request" "Ничего не добавлено (некорректные значения или дубликаты): ${PORTS_APPLY_SKIPPED:-}"
  fi
  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"added\":\"$(json_escape "$PORTS_APPLY_ADDED")\",\"skipped\":\"$(json_escape "$PORTS_APPLY_SKIPPED")\",\"restarted\":$_SERVICE_RESTARTED}"
}

api_ports_remove() {
  _validate_proto_param
  [ -n "${PARAM_VALUE:-}" ] || send_error "400 Bad Request" "Не указан порт"
  if [ "$PARAM_PROTO" = "udp" ] && [ "$PARAM_VALUE" = "1026-65531" ]; then
    send_error "400 Bad Request" "Диапазон 1026-65531 управляется переключателем игрового UDP на вкладке Настройки"
  fi
  _require_config
  ports_apply_remove "$PARAM_PROTO" "$PARAM_VALUE" "$CONFIG_FILE" || \
    send_error "400 Bad Request" "Порт не найден среди добавленных: $PARAM_VALUE"
  _service_apply_restart
  send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED}"
}

api_provider_get() {
  send_json "200 OK" "{\"provider\":\"$(json_escape "$(_provider_cache_text)")\"}"
}

api_provider_set() {
  local name="${PARAM_NAME:-}" city="${PARAM_CITY:-}"
  name="${name//$'\n'/}"
  name="${name//|/}"
  city="${city//$'\n'/}"
  city="${city//|/}"
  [ -n "$(printf '%s' "$name" | tr -d '[:space:]')" ] || send_error "400 Bad Request" "Укажите название провайдера"
  if ! type provider_set_manual >/dev/null 2>&1; then
    send_error "500 Internal Server Error" "Модуль провайдера недоступен"
  fi
  provider_set_manual "$name" "$city" || send_error "400 Bad Request" "Укажите название провайдера"
  send_json "200 OK" "{\"ok\":true,\"provider\":\"$(json_escape "$PROVIDER_MENU")\"}"
}

api_provider_redetect() {
  if ! type provider_force_redetect >/dev/null 2>&1; then
    send_error "500 Internal Server Error" "Модуль провайдера недоступен"
  fi
  provider_force_redetect >/dev/null 2>&1
  send_json "200 OK" "{\"ok\":true,\"provider\":\"$(json_escape "$PROVIDER_MENU")\"}"
}

_backup_date_from_name() {
  local name="$1" d
  case "$name" in
    z2r_backup_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar)
      d="${name#z2r_backup_}"
      d="${d%.tar}"
      printf '%s-%s-%s %s:%s:%s' "${d:0:4}" "${d:4:2}" "${d:6:2}" "${d:9:2}" "${d:11:2}" "${d:13:2}"
      ;;
  esac
}

api_backups_list() {
  local list_file f items="" first=1 name size date_str d
  if ! type backup_build_list_file >/dev/null 2>&1; then
    send_error "500 Internal Server Error" "Модуль бэкапов недоступен"
  fi
  list_file="/tmp/z2r_webui_backups_$$"
  backup_build_list_file "$list_file"
  # Размеры одним wc на все файлы: форк на каждый бэкап слишком дорог на
  # слабых роутерах; дата парсится из имени средствами самого bash.
  while read -r size f; do
    [ -n "$f" ] || continue
    [ "$f" = "total" ] && continue
    name="${f##*/}"
    case "$name" in
      z2r_backup_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar)
        d="${name#z2r_backup_}"; d="${d%.tar}"
        date_str="${d:0:4}-${d:4:2}-${d:6:2} ${d:9:2}:${d:11:2}:${d:13:2}"
        ;;
      *) date_str="" ;;
    esac
    if [ "$first" = "1" ]; then first=0; else items="${items},"; fi
    items="${items}{\"name\":\"${name}\",\"size\":${size:-0},\"date\":\"${date_str}\"}"
  done < <(wc -c $(cat "$list_file") 2>/dev/null)
  rm -f "$list_file"
  send_json "200 OK" "{\"items\":[${items}]}"
}

api_backups_create() {
  local archive
  if ! type backup_create_core >/dev/null 2>&1; then
    send_error "500 Internal Server Error" "Модуль бэкапов недоступен"
  fi
  archive="$(backup_create_core 2>/dev/null)" || send_error "500 Internal Server Error" "Не удалось создать бэкап"
  send_json "200 OK" "{\"ok\":true,\"name\":\"$(json_escape "$(basename "$archive")")\"}"
}

send_tar_file() {
  local path="$1" name="$2" size
  size="$(wc -c < "$path" | tr -d '[:space:]')"
  printf 'Status: 200 OK\r\n'
  printf 'Content-Type: application/x-tar\r\n'
  printf 'Content-Disposition: attachment; filename="%s"\r\n' "$name"
  printf 'Content-Length: %s\r\n' "${size:-0}"
  printf 'Cache-Control: no-store\r\n\r\n'
  cat "$path"
  exit 0
}

query_param() {
  local key="$1" part k v _qp_parts
  [ -n "${QUERY_STRING:-}" ] || return 1
  IFS='&' read -r -a _qp_parts <<< "${QUERY_STRING}"
  for part in "${_qp_parts[@]}"; do
    k="${part%%=*}"
    [ "$k" = "$key" ] || continue
    v="${part#*=}"
    v="${v//+/ }"
    printf -v v '%b' "${v//%/\\x}"
    printf '%s' "$v"
    return 0
  done
  return 1
}

api_backups_delete() {
  local name="${PARAM_NAME:-}"
  if ! type backup_delete_core >/dev/null 2>&1; then
    send_error "500 Internal Server Error" "Модуль бэкапов недоступен"
  fi
  [ -n "$name" ] || send_error "400 Bad Request" "Не указано имя файла"
  backup_delete_core "$name" >/dev/null 2>&1 || send_error "404 Not Found" "Бэкап не найден"
  send_json "200 OK" "{\"ok\":true,\"name\":\"$(json_escape "$name")\"}"
}

api_backups_download() {
  local name="${PARAM_NAME:-}" path
  if ! type backup_resolve_archive >/dev/null 2>&1; then
    send_error "500 Internal Server Error" "Модуль бэкапов недоступен"
  fi
  [ -n "$name" ] || send_error "400 Bad Request" "Не указано имя файла"
  path="$(backup_resolve_archive "$name")" || send_error "404 Not Found" "Бэкап не найден"
  send_tar_file "$path" "$name"
}

api_backups_upload() {
  local len orig tmp got name
  if ! type backup_import_core >/dev/null 2>&1; then
    send_error "500 Internal Server Error" "Модуль бэкапов недоступен"
  fi
  len="${CONTENT_LENGTH:-0}"
  case "$len" in
    ''|*[!0-9]*) len=0 ;;
  esac
  [ "$len" -gt 0 ] || send_error "400 Bad Request" "Пустой файл"
  [ "$len" -le 33554432 ] || send_error "413 Payload Too Large" "Файл слишком большой (максимум 32 МБ)"
  tmp="/tmp/z2r_webui_upload_$$"
  head -c "$len" > "$tmp" 2>/dev/null || { rm -f "$tmp"; send_error "500 Internal Server Error" "Не удалось принять файл"; }
  got="$(wc -c < "$tmp" | tr -d '[:space:]')"
  if [ "${got:-0}" -ne "$len" ]; then
    rm -f "$tmp"
    send_error "400 Bad Request" "Файл получен не полностью"
  fi
  orig="$(query_param name || true)"
  name="$(backup_import_core "$tmp" "$orig")" || { rm -f "$tmp"; send_error "400 Bad Request" "Файл не является архивом бэкапа"; }
  send_json "200 OK" "{\"ok\":true,\"name\":\"$(json_escape "$name")\"}"
}

# Управление доменами переиспользует нормализацию, пути и операции со списками
# из lib/strategies.sh; здесь остаётся только CGI-представление.

# Маппинг имени списка (URL-параметр list) на путь файла и метаданные.
# Аргументы: $1=list_name. Печатает "file|kind|title|desc" или возвращает 1.
_domains_resolve_list() {
  case "$1" in
    netrogat)
      printf '%s|%s|%s|%s' "$(netrogat_file)" "domain" "Исключения (netrogat.txt)" \
        "Домены, исключаемые из обработки zapret2 (--hostlist-exclude)."
      ;;
    custom_rkn)
      printf '%s|%s|%s|%s' "$(custom_rkn_file)" "domain" "TCP_Custom (RKN-домены)" \
        "Кастомные домены под RKN-стратегию. Для каждого можно зафиксировать номер стратегии."
      ;;
    substring)
      # Длинное описание собираем отдельно через %b (интерпретирует \n), чтобы
      # в редакторе строка была читаемой, а в WebUI отображалась с переносами.
      # Контракт полей: file|kind|title|desc — desc не должен содержать '|'.
      local desc
      desc="$(printf '%b' \
        "Подстроки имени домена для RKN. Без нормализации — как есть.\n" \
        "Добавьте часть имени домена, и все домены с таким текстом будут обрабатываться стратегией РКН.\n" \
        "Например, если добавить cdn, стратегия РКН будет применяться к:\n" \
        "cdn-1.mysite.com, mycdn.com и другим доменам, в названии которых есть cdn.\n" \
        "Примеры корректного ввода: cdn, media, static, assets")"
      printf '%s|%s|%s|%s' "$(rkn_substring_file)" "substring" \
        "Подстроки (TCP_RKN_domains_by_substring)" "$desc"
      ;;
    netrogat_substring)
      local desc
      desc="$(printf '%b' \
        "Подстроки-исключения (netrogat_substrings.txt). Без нормализации — как есть.\n" \
        "Добавьте часть имени домена, и все домены с таким текстом будут исключены из обработки —\n" \
        "аналог netrogat.txt, но по части имени.\n" \
        "Например, если добавить bank, исключены будут sber-bank.ru, banki.ru\n" \
        "и другие домены, в названии которых есть bank.")"
      printf '%s|%s|%s|%s' "$(netrogat_substring_file)" "substring" \
        "Подстроки исключений (netrogat_substrings)" "$desc"
      ;;
    *)
      return 1
      ;;
  esac
}

# Чтение одного списка и выдача JSON.
# Для custom_rkn каждому домену сопоставляется текущая стратегия из locked.tsv
# (0 = авто/общие RKN), плюс max_strategy = orch_max_strategy_for_profile 3.
api_domains_list() {
  parse_params
  local meta file kind title desc
  meta="$(_domains_resolve_list "${PARAM_LIST:-}")" || send_error "400 Bad Request" "Неизвестный список"
  file="${meta%%|*}"
  meta="${meta#*|}"
  kind="${meta%%|*}"
  meta="${meta#*|}"
  title="${meta%%|*}"
  desc="${meta#*|}"

  [ -n "$file" ] || send_error "500 Internal Server Error" "Не определён путь списка"

  local items="" line first=1 strat max_strat
  # Самолечение: домены из locked.tsv, пропавшие из TCP_Custom.txt (старые
  # обновления затирали список), возвращаются перед чтением — иначе веб-панель
  # и CLI видят пустой список при живых локах.
  [ "$PARAM_LIST" = "custom_rkn" ] && custom_rkn_restore_from_locks >/dev/null
  domain_list_prepare "$file"
  if [ "$PARAM_LIST" = "custom_rkn" ]; then
    max_strat="$(orch_max_strategy_for_profile 3)"
    if ! printf '%s' "$max_strat" | grep -Eq '^[0-9]+$' || [ "$max_strat" -le 0 ]; then
      max_strat=19
    fi
  else
    max_strat=0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | grep -Eq '^[[:space:]]*#' && continue
    if [ "$first" = "1" ]; then first=0; else items="${items},"; fi
    if [ "$PARAM_LIST" = "custom_rkn" ]; then
      strat="$(orch_locked_get "$line" "tls")"
      printf '%s' "$strat" | grep -Eq '^[0-9]+$' || strat=0
      items="${items}{\"value\":\"$(json_escape "$line")\",\"strategy\":${strat}}"
    else
      items="${items}{\"value\":\"$(json_escape "$line")\"}"
    fi
  done < "$file"

  send_json "200 OK" "{
    \"list\":\"$(json_escape "$PARAM_LIST")\",
    \"title\":\"$(json_escape "$title")\",
    \"description\":\"$(json_escape "$desc")\",
    \"kind\":\"$(json_escape "$kind")\",
    \"is_custom_rkn\":$([ "$PARAM_LIST" = "custom_rkn" ] && echo true || echo false),
    \"max_strategy\":${max_strat},
    \"items\":[${items}]
  }"
}

# Быстрая проверка домена общим движком z2r_tls_* (как в CLI при подборе стратегии).
_domains_check_json() {
  local domain="$1"
  printf '{"results":[%s]}' "$(check_one_target_json "$domain" "https://$domain/")"
}

# Действия над списком: add/remove/import/clear/set_strategy/clear_strategy/check.
api_domains_action() {
  parse_params
  local meta file kind
  meta="$(_domains_resolve_list "${PARAM_LIST:-}")" || send_error "400 Bad Request" "Неизвестный список"
  file="${meta%%|*}"
  meta="${meta#*|}"
  kind="${meta%%|*}"
  [ -n "$file" ] || send_error "500 Internal Server Error" "Не определён путь списка"

  local action="${PARAM_ACTION:-}"
  local domain normalized added=0 duplicates=0 skipped=0 count=0

  case "${PARAM_LIST:-}:$action" in
    custom_rkn:add|custom_rkn:import|substring:add|substring:import)
      if [ "$(config_mode_text hostlist "$CONFIG_FILE")" = "авто" ]; then
        send_error "409 Conflict" "Автосбор списков включён: домены RKN zapret2 определяет автоматически. Выключите автосбор в настройках, чтобы пополнять список вручную."
      fi
      ;;
  esac

  case "$action" in
    add)
      domain="${PARAM_DOMAIN:-}"
      [ -n "$domain" ] || send_error "400 Bad Request" "Не указан домен"
      if [ "$kind" = "domain" ]; then
        normalized="$(z2r_normalize_domain "$domain")" || \
          send_error "400 Bad Request" "Некорректный домен: $domain"
      else
        # Подстрока: только обрезка пробелов и непустота.
        normalized="${domain#"${domain%%[![:space:]]*}"}"
        normalized="${normalized%"${normalized##*[![:space:]]}"}"
        [ -n "$normalized" ] || send_error "400 Bad Request" "Пустая подстрока"
      fi
      local add_result=""
      domain_list_add "$file" "$normalized" "" "Домен" 1 add_result || \
        send_error "500 Internal Server Error" "Не удалось обновить список"
      local check_json=""
      if [ "$PARAM_LIST" = "custom_rkn" ]; then
        check_json=",\"check\":$(_domains_check_json "$normalized")"
      fi
      send_json "200 OK" "{\"ok\":true,\"duplicate\":$([ "$add_result" = "duplicate" ] && echo true || echo false)${check_json}}"
      ;;
    remove)
      domain="${PARAM_DOMAIN:-}"
      [ -n "$domain" ] || send_error "400 Bad Request" "Не указан домен"
      if [ "$PARAM_LIST" = "custom_rkn" ]; then
        custom_rkn_remove_domain "$domain"
      else
        domain_list_remove "$file" "$domain"
      fi
      send_json "200 OK" "{\"ok\":true}"
      ;;
    rename)
      [ "$PARAM_LIST" = "custom_rkn" ] || send_error "400 Bad Request" "Переименование применяется только к TCP_Custom"
      domain="${PARAM_DOMAIN:-}"
      [ -n "$domain" ] || send_error "400 Bad Request" "Не указан домен"
      normalized="$(z2r_normalize_domain "${PARAM_NEW_DOMAIN:-}")" || \
        send_error "400 Bad Request" "Некорректный домен: ${PARAM_NEW_DOMAIN:-}"
      # Совпадение с самим собой — no-op, ошибки не будет.
      if [ "$normalized" = "$domain" ]; then
        send_json "200 OK" "{\"ok\":true,\"domain\":\"$(json_escape "$normalized")\"}"
        exit 0
      fi
      grep -Fxq -- "$normalized" "$file" 2>/dev/null && \
        send_error "409 Conflict" "Домен ${normalized} уже есть в списке"
      local rename_rc=0
      custom_rkn_rename_domain "$domain" "$normalized" || rename_rc=$?
      [ "$rename_rc" = "2" ] && send_error "400 Bad Request" "Домена нет в списке"
      [ "$rename_rc" = "0" ] || send_error "500 Internal Server Error" "Не удалось переименовать домен"
      send_json "200 OK" "{\"ok\":true,\"domain\":\"$(json_escape "$normalized")\"}"
      ;;
    import)
      # PARAM_DOMAIN — многострочный текст (после URL-decode \n сохранены).
      local IFS=$'\n'
      local raw="${PARAM_DOMAIN:-}"
      [ -n "$raw" ] || send_error "400 Bad Request" "Пустой импорт"
      domain_list_prepare "$file"
      # shellcheck disable=SC2086
      set -f
      for line in $raw; do
        set +f
        # обрезка пробелов
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || { skipped=$((skipped+1)); continue; }
        printf '%s' "$line" | grep -Eq '^[[:space:]]*#' && { skipped=$((skipped+1)); continue; }
        if [ "$kind" = "domain" ]; then
          normalized="$(z2r_normalize_domain "$line")" || { skipped=$((skipped+1)); continue; }
        else
          normalized="$line"
        fi
        local add_result=""
        domain_list_add "$file" "$normalized" "" "Домен" 1 add_result || { skipped=$((skipped+1)); continue; }
        if [ "$add_result" = "duplicate" ]; then
          duplicates=$((duplicates+1))
          continue
        fi
        added=$((added+1))
      done
      set +f
      send_json "200 OK" "{\"ok\":true,\"added\":${added},\"duplicates\":${duplicates},\"skipped\":${skipped}}"
      ;;
    clear)
      if [ "$PARAM_LIST" = "custom_rkn" ]; then
        # Сначала собираем домены, потом чистим их локи.
        domain_list_prepare "$file"
        while IFS= read -r domain; do
          [ -n "$domain" ] || continue
          printf '%s' "$domain" | grep -Eq '^[[:space:]]*#' && continue
          orch_locked_clear "$domain" "tls"
          orch_locked_clear "$domain" "http"
          orch_locked_clear "$domain" "udp"
          count=$((count+1))
        done < "$file"
      fi
      : > "$file"
      send_json "200 OK" "{\"ok\":true,\"cleared\":${count}}"
      ;;
    set_strategy)
      [ "$PARAM_LIST" = "custom_rkn" ] || send_error "400 Bad Request" "Стратегия применяется только к TCP_Custom"
      domain="${PARAM_DOMAIN:-}"
      [ -n "$domain" ] || send_error "400 Bad Request" "Не указан домен"
      # Домен должен присутствовать в списке.
      grep -Fxq -- "$domain" "$file" 2>/dev/null || send_error "400 Bad Request" "Домена нет в списке"
      local strat="${PARAM_STRATEGY:-}"
      printf '%s' "$strat" | grep -Eq '^[0-9]+$' || send_error "400 Bad Request" "Некорректная стратегия"
      local max_strat
      max_strat="$(orch_max_strategy_for_profile 3)"
      if ! printf '%s' "$max_strat" | grep -Eq '^[0-9]+$' || [ "$max_strat" -le 0 ]; then
        max_strat=19
      fi
      [ "$strat" -ge 1 ] && [ "$strat" -le "$max_strat" ] || \
        send_error "400 Bad Request" "Стратегия вне диапазона (1..${max_strat})"
      orch_locked_set "$domain" "tls" "$strat"
      send_json "200 OK" "{\"ok\":true,\"strategy\":${strat},\"check\":$(_domains_check_json "$domain")}"
      ;;
    clear_strategy)
      [ "$PARAM_LIST" = "custom_rkn" ] || send_error "400 Bad Request" "Стратегия применяется только к TCP_Custom"
      domain="${PARAM_DOMAIN:-}"
      [ -n "$domain" ] || send_error "400 Bad Request" "Не указан домен"
      orch_locked_clear "$domain" "tls"
      send_json "200 OK" "{\"ok\":true}"
      ;;
    check)
      [ "$PARAM_LIST" = "custom_rkn" ] || send_error "400 Bad Request" "Проверка применяется только к TCP_Custom"
      domain="${PARAM_DOMAIN:-}"
      [ -n "$domain" ] || send_error "400 Bad Request" "Не указан домен"
      send_json "200 OK" "{\"ok\":true,\"check\":$(_domains_check_json "$domain")}"
      ;;
    *)
      send_error "400 Bad Request" "Неизвестное действие: $action"
      ;;
  esac
}
