#!/usr/bin/env bash

set -u

PATH="/opt/bin:/opt/sbin:$PATH"
export PATH

WEBUI_ROOT="/opt/zapret2/webui"
ZAPRET_ROOT="/opt/zapret2"
CONFIG_FILE="$ZAPRET_ROOT/config"
ORCH_DIR="$ZAPRET_ROOT/extra_strats/cache/orchestra"
LIB_DIR=""

find_runtime_libs() {
  local here dir
  here="$(cd -- "$(dirname -- "$0")" && pwd)"
  for dir in \
    "$ZAPRET_ROOT/z2r_lib" \
    "$here/../../z2r_lib" \
    "$here/../../lib" \
    "$here/../lib"; do
    if [ -f "$dir/orchestra_state.sh" ] && [ -f "$dir/config.sh" ]; then
      LIB_DIR="$dir"
      return 0
    fi
  done
  return 1
}

find_runtime_libs || { echo 'Status: 500 Internal Server Error\r'; echo; echo '{"error":"missing z2r runtime libs"}'; exit 0; }
. "$LIB_DIR/config.sh"
. "$LIB_DIR/orchestra_state.sh"
[ -f "$LIB_DIR/telemetry.sh" ] && . "$LIB_DIR/telemetry.sh"

telemetry_notify() {
  type send_stats >/dev/null 2>&1 && send_stats || true
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\n/\\n/g'
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

orch_max_strategy_for_profile() {
  config_profile_max_strategy "$1" "$CONFIG_FILE"
}

profile_proto() {
  local list
  list="$(config_profile_proto_list "$1")"
  echo "${list%% *}"
}

profile_json() {
  local id="$1" label="$2" desc="$3" proto current max
  proto="$(profile_proto "$id")"
  current="$(profile_state_display "$id" "$proto")"
  max="$(orch_max_strategy_for_profile "$id")"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s}' \
    "$id" "$(json_escape "$label")" "$(json_escape "$desc")" "$(json_escape "$current")" "${max:-0}"
}

all_profiles_json() {
  printf '['
  profile_json 1 "YouTube TCP" "Основной TCP профиль для YouTube"
  printf ','
  profile_json 2 "Googlevideo" "Видео-домены YouTube"
  printf ','
  profile_json 3 "Blocked Sites" "Основные блокировки сайтов"
  printf ','
  profile_json 4 "Discord TCP" "TCP профиль Discord"
  printf ','
  profile_json 5 "YouTube QUIC" "UDP 443 для YouTube"
  printf ','
  profile_json 6 "Voice UDP" "Discord/STUN и голосовые сервисы"
  printf ']'
}

service_zapret2() {
  local action="$1"
  set_zapret2_init
  [ -f "$ZAPRET2_INIT" ] || return 1
  case "$action" in
    start|stop|restart)
      "$ZAPRET2_INIT" "$action" >/dev/null 2>&1
      ;;
    *)
      return 2
      ;;
  esac
}

strategy_locks_status_text() {
  if [ -s "$ORCH_DIR/locked.tsv" ] || [ -s "$ORCH_DIR/locked.manual.tsv" ] || [ -s "$(profile_state_file)" ]; then
    echo "Есть"
  else
    echo "Нет"
  fi
}

get_yt_cluster_domain() {
  local cluster_codename converted_name="" i=0 char idx b
  local letters_map_a="u z p k f a 5 0 v q l g b 6 1 w r m h c 7 2 x s n i d 8 3 y t o j e 9 4 -"
  local letters_map_b="0 1 2 3 4 5 6 7 8 9 a b c d e f g h i j k l m n o p q r s t u v w x y z -"

  cluster_codename="$(curl -s --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no" | sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')"
  cluster_codename="$(curl -s --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no" | sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')"
  [ -n "$cluster_codename" ] || { echo "rr1---sn-5goeenes.googlevideo.com"; return; }

  while [ $i -lt ${#cluster_codename} ]; do
    char="$(echo "$cluster_codename" | cut -c$((i+1)))"
    idx=1
    for a in $letters_map_a; do
      [ "$a" = "$char" ] && break
      idx=$((idx+1))
    done
    b="$(echo "$letters_map_b" | cut -d' ' -f "$idx")"
    converted_name="${converted_name}${b}"
    i=$((i+1))
  done
  echo "rr1---sn-${converted_name}.googlevideo.com"
}

check_one_target_json() {
  local label="$1"
  local target="$2"
  local tls12=0 tls13=0
  curl --tls-max 1.2 --max-time 1 -s -o /dev/null "$target" && tls12=1 || true
  curl --tlsv1.3 --max-time 1 -s -o /dev/null "$target" && tls13=1 || true
  printf '{"label":"%s","target":"%s","tls12":%s,"tls13":%s}' \
    "$(json_escape "$label")" "$(json_escape "$target")" "$tls12" "$tls13"
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
    *)
      printf '{"results":[]}'
      ;;
  esac
}

api_status() {
  local running
  if zapret2_running; then running=true; else running=false; fi
  send_json "200 OK" "$(cat <<EOF
{"zapret2_running":$running,"strategy_locks_status":"$(json_escape "$(strategy_locks_status_text)")","hostlist_mode":"$(json_escape "$(config_mode_text hostlist "$CONFIG_FILE")")","fwtype":"$(json_escape "$(config_mode_text fwtype "$CONFIG_FILE")")","flowoffload":"$(json_escape "$(config_mode_text flowoffload "$CONFIG_FILE")")","tls_blob_mode":"$(json_escape "$(config_mode_text tls_blob_menu "$CONFIG_FILE")")","profiles":$(all_profiles_json)}
EOF
)"
}

api_set_lock() {
  parse_params
  [[ "${PARAM_PROFILE:-}" =~ ^[1-7]$ ]] || send_error "400 Bad Request" "Некорректный профиль"
  [[ "${PARAM_STRATEGY:-}" =~ ^[0-9]+$ ]] || send_error "400 Bad Request" "Некорректная стратегия"
  local max proto_list check_json
  max="$(orch_max_strategy_for_profile "$PARAM_PROFILE")"
  if [ "${PARAM_STRATEGY}" -ne 0 ]; then
    [ "${PARAM_STRATEGY}" -ge 1 ] && [ "${PARAM_STRATEGY}" -le "${max:-0}" ] || send_error "400 Bad Request" "Стратегия вне диапазона"
  fi
  proto_list="$(config_profile_proto_list "$PARAM_PROFILE")"
  [ -n "$proto_list" ] || send_error "400 Bad Request" "Не удалось определить протокол профиля"
  profile_state_set_and_apply "$PARAM_PROFILE" "$proto_list" "$PARAM_STRATEGY" "$CONFIG_FILE" || send_error "500 Internal Server Error" "Не удалось сохранить состояние профиля"
  [ "$PARAM_PROFILE" = "6" ] && service_zapret2 restart >/dev/null 2>&1 || true
  telemetry_notify
  check_json="$(profile_check_json "$PARAM_PROFILE")"
  send_json "200 OK" "{\"ok\":true,\"check\":$check_json}"
}

api_clear_lock() {
  parse_params
  [[ "${PARAM_PROFILE:-}" =~ ^[1-7]$ ]] || send_error "400 Bad Request" "Некорректный профиль"
  local proto_list
  proto_list="$(config_profile_proto_list "$PARAM_PROFILE")"
  [ -n "$proto_list" ] || send_error "400 Bad Request" "Не удалось определить протокол профиля"
  profile_state_set_and_apply "$PARAM_PROFILE" "$proto_list" "auto" "$CONFIG_FILE" || send_error "500 Internal Server Error" "Не удалось сбросить состояние профиля"
  [ "$PARAM_PROFILE" = "6" ] && service_zapret2 restart >/dev/null 2>&1 || true
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
  local gv
  gv="$(get_yt_cluster_domain)"
  send_json "200 OK" "{\"results\":[
$(check_one_target_json "YouTube" "https://www.youtube.com/")
,$(check_one_target_json "Googlevideo" "https://${gv}")
,$(check_one_target_json "Blocked Sites" "https://meduza.io")
,$(check_one_target_json "Instagram" "https://www.instagram.com/")
]}"
}
