#!/usr/bin/env bash
. /opt/zator/webui/cgi-bin/_lib.sh

# Пользовательские блобы (панель: «Свои блобы»): CRUD деклараций
# --blob=ИМЯ:@custom_blob/файл + загрузка файлов через браузер.
# Загрузка: POST /cgi-bin/blobs.cgi?action=upload&name=файл.bin — тело запроса
# бинарное (application/octet-stream), параметры в QUERY_STRING, чтобы не
# городить multipart-парсер в CGI.

_blobs_lib_guard() {
  type custom_blobs_apply_file >/dev/null 2>&1 \
    && type custom_strategies_blob_ref_rows >/dev/null 2>&1 \
    || send_error "503 Service Unavailable" "Для «Своих блобов» обновите Core zator."
}

_blobs_config_path() {
  local cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [ -f "$cfg" ] || cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config.default"
  printf '%s' "$cfg"
}

api_blobs_list() {
  _blobs_lib_guard
  local cfg rows="" row refs files="" f stock="" b name file comment
  cfg="$(_blobs_config_path)"
  while IFS= read -r row; do
    _custom_blobs_split "$row" || continue
    refs="$(custom_strategies_blob_ref_rows "$_CB_NAME")"
    rows="${rows}${rows:+,}{\"id\":$_CB_ID,\"name\":\"$(json_escape "$_CB_NAME")\",\"file\":\"$(json_escape "$_CB_FILE")\",\"comment\":\"$(json_escape "${_CB_COMMENT:-}")\",\"refs\":${refs:-0}}"
  done < <(custom_blobs_list)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    files="${files}${files:+,}\"$(json_escape "$f")\""
  done < <(custom_blobs_files_list)
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    stock="${stock}${stock:+,}\"$(json_escape "$b")\""
  done < <(custom_strategies_blob_names "$cfg")
  printf 'Cache-Control: no-store\r\n'
  send_json "200 OK" "{\"dir\":\"$(json_escape "$(custom_blobs_dir)")\",\"blobs\":[$rows],\"files\":[$files],\"stock\":[$stock]}"
}

# Параметр ТОЛЬКО из QUERY_STRING (parse_params при POST читает тело — для
# бинарной загрузки оно не текст). Имя файла — [A-Za-z0-9._-], процент-энкод
# минимальный, как в parse_params.
_blobs_query_param() {
  local want="$1" q="${QUERY_STRING:-}" pair val=""
  local wasf=$-
  case "$wasf" in *f*) ;; *) set -f ;; esac
  local IFS='&'
  for pair in $q; do
    case "$pair" in
      "$want="*) val="${pair#*=}" ;;
    esac
  done
  case "$wasf" in *f*) ;; *) set +f ;; esac
  case "${val:-}" in "") return 0 ;; esac
  val="${val//+/ }"
  local hex='\x'
  printf -v val '%b' "${val//%/$hex}"
  printf '%s' "$val"
}

# POST action=upload&name=файл.bin — бинарное тело запроса.
api_blobs_upload() {
  _blobs_lib_guard
  local name="$(_blobs_query_param name)" tmp base auto size rc
  case "$name" in
    ""|*/*|*".."*) send_error "400 Bad Request" "Некорректное имя файла." ;;
  esac
  case "$name" in
    *[!A-Za-z0-9._-]*) send_error "400 Bad Request" "Имя файла: буквы, цифры, . _ - (без пробелов)." ;;
  esac
  [ "${#name}" -le 64 ] || send_error "400 Bad Request" "Имя файла длиннее 64 символов."
  case "${CONTENT_LENGTH:-0}" in
    ''|*[!0-9]*) send_error "400 Bad Request" "Некорректный размер загрузки." ;;
  esac
  [ "${CONTENT_LENGTH:-0}" -ge 1 ] && [ "${CONTENT_LENGTH:-0}" -le 262144 ] \
    || send_error "413 Payload Too Large" "Размер файла 1 Б…256 КиБ."
  tmp="/tmp/z2r-blob-up.$$"
  dd bs=8192 count=$(( (CONTENT_LENGTH + 8191) / 8192 )) of="$tmp" 2>/dev/null || true
  size="$(wc -c < "$tmp" 2>/dev/null | tr -d '[:space:]')"
  [ "${size:-0}" = "${CONTENT_LENGTH:-0}" ] || { rm -f "$tmp"; send_error "400 Bad Request" "Тело загрузки пришло не целиком."; }
  _custom_capture_err custom_blobs_upload_file "$tmp" "$name"
  rc="$REPLY_RC"
  rm -f "$tmp"
  [ "$rc" = "0" ] || send_error "400 Bad Request" "$(printf '%s' "${REPLY_ERR:-загрузка не удалась}" | head -n1)"

  # авто-декларация: имя = имя файла без расширения, приведённое к форме блоба
  base="${name%.*}"
  auto="$(printf '%s' "$base" | tr -c 'A-Za-z0-9_' '_')"
  case "$auto" in
    [0-9]*) auto="blob_$auto" ;;
    ""|_*) auto="blob_1" ;;
  esac
  local created="" bound=0
  if custom_blobs_list | awk -F '\t' -v f="$name" '$3 == f { found=1 } END { exit !found }'; then
    bound=1
  fi
  if [ "$bound" = "0" ] && ! custom_blobs_name_taken "$auto"; then
    _custom_capture_err custom_blobs_add "$auto" "$name" "загружен из панели"
    if [ "$REPLY_RC" = "0" ]; then
      created="$REPLY_OUT"
    fi
  fi
  send_json "200 OK" "{\"ok\":true,\"file\":\"$(json_escape "$name")\",\"created\":${created:-null},\"apply_required\":true}"
}

api_blobs_action() {
  _blobs_lib_guard
  parse_params
  local action="${PARAM_ACTION:-}" id="${PARAM_ID:-}" name="${PARAM_VALUE:-}"
  local file="${PARAM_FILE:-}" comment="${PARAM_COMMENT:-}" cfg err
  cfg="$(_blobs_config_path)"

  case "$action" in
    add)
      _custom_capture_err custom_blobs_add "$name" "$file" "$comment" "$cfg"
      [ "$REPLY_RC" = "0" ] || send_error "400 Bad Request" "$(printf '%s' "${REPLY_ERR:-не добавлено}" | head -n1)"
      send_json "200 OK" "{\"ok\":true,\"id\":$REPLY_OUT,\"apply_required\":true}"
      ;;
    edit)
      case "$id" in ''|*[!0-9]*) send_error "400 Bad Request" "Некорректный ID" ;; esac
      custom_blobs_row "$id" >/dev/null || send_error "400 Bad Request" "Нет записи $id"
      comment="${comment:-$(custom_blobs_row "$id" | awk -F '\t' '{print $4}')}"
      _custom_capture_err custom_blobs_replace "$id" "$name" "$file" "$comment" "$cfg"
      [ "$REPLY_RC" = "0" ] || send_error "400 Bad Request" "$(printf '%s' "${REPLY_ERR:-не обновлено}" | head -n1)"
      send_json "200 OK" "{\"ok\":true,\"renamed\":true,\"apply_required\":true}"
      ;;
    delete)
      case "$id" in ''|*[!0-9]*) send_error "400 Bad Request" "Некорректный ID" ;; esac
      _custom_capture_err custom_blobs_delete "$id"
      [ "$REPLY_RC" = "0" ] || send_error "400 Bad Request" "$(printf '%s' "${REPLY_ERR:-не удалено}" | head -n1)"
      send_json "200 OK" "{\"ok\":true,\"apply_required\":true}"
      ;;
    apply)
      _custom_capture_err custom_blobs_apply_file "$cfg"
      [ "$REPLY_RC" = "0" ] || send_error "500 Internal Server Error" "Не удалось применить блобы к конфигу"
      # переименования правили spec'и пользовательских стратегий —
      # переинжектим и их (идемпотентно)
      type custom_strategies_apply_file >/dev/null 2>&1 \
        && _custom_capture_err custom_strategies_apply_file "$cfg"
      PARAM_RESTART="${PARAM_RESTART:-1}" _service_apply_restart
      telemetry_notify
      send_json "200 OK" "{\"ok\":true,\"restarted\":$_SERVICE_RESTARTED,\"restart_required\":true}"
      ;;
    *)
      send_error "400 Bad Request" "Неизвестное действие: $action"
      ;;
  esac
}

case "${REQUEST_METHOD:-GET}" in
  GET)
    api_blobs_list
    ;;
  POST)
    case "${QUERY_STRING:-}" in
      *action=upload*)
        # параметры загрузки — только из QUERY_STRING (тело бинарное)
        api_blobs_upload
        ;;
      *)
        api_blobs_action
        ;;
    esac
    ;;
  *)
    send_error "405 Method Not Allowed" "Метод не поддерживается"
    ;;
esac
