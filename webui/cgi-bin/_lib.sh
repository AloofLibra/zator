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

orch_max_strategy_for_profile() {
  config_profile_max_strategy "$1" "$CONFIG_FILE"
}

profile_proto() {
  local list
  list="$(config_profile_proto_list "$1")"
  echo "${list%% *}"
}

profile_json() {
  local id="$1" label="$2" desc="$3" proto current max scope source
  scope="${PARAM_SCOPE:-default}"
  proto="$(profile_proto "$id")"
  current="$(profile_state_display "$id" "$proto")"
  source="$(orch_scoped_lock_source "$scope" "$id" "$proto" 2>/dev/null || printf auto)"
  max="$(orch_max_strategy_for_profile "$id")"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s,"scope":"%s","lock_source":"%s"}' \
    "$id" "$(json_escape "$label")" "$(json_escape "$desc")" "$(json_escape "$current")" "${max:-0}" "$(json_escape "$scope")" "$(json_escape "$source")"
}

all_profiles_json() {
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
  printf ']'
}

profile_json_udp_games() {
  local id="$1" label="$2" desc="$3" proto current max games_state
  proto="$(profile_proto "$id")"
  current="$(profile_state_display "$id" "$proto")"
  max="$(orch_max_strategy_for_profile "$id")"
  games_state="$(config_mode_text udp_games "$CONFIG_FILE")"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s,"is_udp_games":true,"udp_games_enabled":%s}' \
    "$id" "$(json_escape "$label")" "$(json_escape "$desc")" "$(json_escape "$current")" "${max:-0}" \
    "$([ "$games_state" = "Включен" ] && echo true || echo false)"
}

profile_json_fallback() {
  local id="$1" label="$2" desc="$3" proto current max fallback_state
  local saved_lock_file
  proto="$(profile_proto "$id")"
  # Для профилей 8/9 (fallback) состояние стратегии хранится в locked.manual.tsv,
  # а не в locked.tsv. Временно переключаем ORCH_LOCK_FILE для чтения.
  saved_lock_file="$ORCH_LOCK_FILE"
  ORCH_LOCK_FILE="$ORCH_DIR/locked.manual.tsv"
  current="$(profile_state_display "$id" "$proto")"
  ORCH_LOCK_FILE="$saved_lock_file"
  max="$(orch_max_strategy_for_profile "$id")"
  fallback_state="$(_fallback_state "$CONFIG_FILE")"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s,"is_fallback":true,"fallback_enabled":%s}' \
    "$id" "$(json_escape "$label")" "$(json_escape "$desc")" "$(json_escape "$current")" "${max:-0}" \
    "$([ "$fallback_state" = "включен" ] && echo true || echo false)"
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

client_scopes_json() {
  local scopes scope first=1 enabled warning
  scopes="$(orch_scoped_list_scopes 2>/dev/null | sort -u)"
  enabled=false; warning=""
  [ "${CLIENT_SCOPE_ENABLE:-0}" = 1 ] && enabled=true
  if [ "$enabled" = true ] && [ -z "${CLIENT_SCOPE_MARK_MASK:-}" ]; then
    warning="Client scope включён, но firewall mapping не задан."
  fi
  printf '{"enabled":%s,"warning":"%s","scopes":[' "$enabled" "$(json_escape "$warning")"
  while IFS= read -r scope; do
    [ -n "$scope" ] || continue
    [ "$first" = 1 ] || printf ','
    printf '"%s"' "$(json_escape "$scope")"
    first=0
  done <<< "$scopes"
  printf ']}'
}

api_scopes() {
  parse_params
  case "${PARAM_SCOPE:-default}" in
    default|mark:[0-9]*) ;;
    *) send_error "400 Bad Request" "Некорректный scope" ;;
  esac
  send_json "200 OK" "$(client_scopes_json)"
}

api_status() {
  parse_params
  local running wg_raw wg_state
  if zapret2_running; then running=true; else running=false; fi
  wg_raw="$(_wg_state_get "$CONFIG_FILE")"
  case "$wg_raw" in
    1) wg_state="включено" ;;
    0) wg_state="выключено" ;;
    *) wg_state="недоступно" ;;
  esac
  send_json "200 OK" "$(cat <<EOF
{"zapret2_running":$running,"strategy_locks_status":"$(json_escape "$(strategy_locks_status_text)")","hostlist_mode":"$(json_escape "$(config_mode_text hostlist "$CONFIG_FILE")")","fwtype":"$(json_escape "$(config_mode_text fwtype "$CONFIG_FILE")")","flowoffload":"$(json_escape "$(config_mode_text flowoffload "$CONFIG_FILE")")","tls_blob_mode":"$(json_escape "$(config_mode_text tls_blob_menu "$CONFIG_FILE")")","wireguard":"$(json_escape "$wg_state")","auto_mode":"$(json_escape "$(config_mode_text auto_mode "$CONFIG_FILE")")","rst_guard":"$(json_escape "$(config_mode_text rst_guard "$CONFIG_FILE")")","reasm":"$(json_escape "$(config_mode_text reasm_disable "$CONFIG_FILE")")","quic443":"$(json_escape "$(_quic443_state_text "$CONFIG_FILE")")","provider":"$(json_escape "$(_provider_cache_text)")","profiles":$(all_profiles_json)}
EOF
)"
}

api_set_lock() {
  parse_params
  [[ "${PARAM_PROFILE:-}" =~ ^[1-9]$ ]] || send_error "400 Bad Request" "Некорректный профиль"
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
  [[ "${PARAM_PROFILE:-}" =~ ^[1-9]$ ]] || send_error "400 Bad Request" "Некорректный профиль"
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
  if [[ "${PARAM_PROFILE:-}" =~ ^[1-9]$ ]]; then
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

  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
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

  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
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
  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
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

  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
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

  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
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

  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
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
  local value="$PARAM_VALUE" cfg restarted=false
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
  if zapret2_running; then
    service_zapret2 restart && restarted=true
  fi
  send_json "200 OK" "{\"ok\":true,\"restarted\":$restarted,\"state\":\"$(json_escape "$(config_mode_text auto_mode "$CONFIG_FILE")")\"}"
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
  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true,\"state\":\"$(json_escape "$(config_mode_text hostlist "$CONFIG_FILE")")\"}"
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
  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true,\"state\":\"$(json_escape "$(config_mode_text rst_guard "$CONFIG_FILE")")\"}"
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
  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true,\"state\":\"$(json_escape "$(config_mode_text reasm_disable "$CONFIG_FILE")")\"}"
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
  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true,\"state\":\"$(json_escape "$(_quic443_state_text "$CONFIG_FILE")")\"}"
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
  send_json "200 OK" "{\"ok\":true,\"added\":\"$(json_escape "$PORTS_APPLY_ADDED")\",\"skipped\":\"$(json_escape "$PORTS_APPLY_SKIPPED")\",\"reboot_required\":true}"
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
  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
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
  local list_file f items="" first=1 name size date_str
  if ! type backup_build_list_file >/dev/null 2>&1; then
    send_error "500 Internal Server Error" "Модуль бэкапов недоступен"
  fi
  list_file="/tmp/z2r_webui_backups_$$"
  backup_build_list_file "$list_file"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if [ "$first" = "1" ]; then first=0; else items="${items},"; fi
    name="$(basename "$f")"
    size="$(wc -c < "$f" | tr -d '[:space:]')"
    date_str="$(_backup_date_from_name "$name")"
    items="${items}{\"name\":\"$(json_escape "$name")\",\"size\":${size:-0},\"date\":\"$(json_escape "$date_str")\"}"
  done < "$list_file"
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
