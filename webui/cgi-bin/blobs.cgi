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

# SNI-блок вкладки (пул/наборы/пин/политика) — поверх общих хелперов
# lib/orchestra_state.sh; на старом Core деградирует: GET отдаёт "sni":null,
# POST отвечает 503.
_blobs_sni_available() {
  type sni_pool_supported_profiles >/dev/null 2>&1 \
    && type sni_pool_display >/dev/null 2>&1 \
    && type sni_override_set >/dev/null 2>&1
}

_blobs_sni_guard() {
  _blobs_sni_available || send_error "503 Service Unavailable" "Для SNI-настроек обновите Core zator."
}

_blobs_sni_profile_ok() {
  local want="$1" p
  while read -r p; do
    [ "$p" = "$want" ] && return 0
  done < <(sni_pool_supported_profiles)
  return 1
}

# Домены из параметра list (пробелы и переводы строк — разделители).
_blobs_sni_domains() {
  printf '%s' "$1" | tr '\r\n' '  '
}

# Весь sni-блок ОДНИМ awk по пяти файлам: на слабых роутерах каждый $()/
# sed/awk-вызов стоит десятки мс, шелл-сборка json стоила ~3 с. Формат
# полностью повторяет прежний (см. API_CONTRACT.md): профили 1/2/3/4/8 с
# pin/pool/policy/set/effective и наборы с origin. Отсутствующие файлы awk
# просто не получает (их собирает шелл-фильтр ниже).
_blobs_sni_json() {
  local files=""
  local f
  for f in "$ORCH_SNI_FILE" "$ORCH_SNI_POOL_FILE" "$ORCH_SNI_POOL_POLICY_FILE" \
    "$Z2R_SNI_USER_FILE" "$Z2R_SNI_ZATOR_FILE"; do
    [ -f "$f" ] && files="$files $f"
  done
  [ -n "$files" ] || files=" /dev/null"
  # shellcheck disable=SC2086
  awk '
    FNR == 1 {
      mode = ""
      if (FILENAME ~ /sni_user\.txt$/) mode = "uset"
      else if (FILENAME ~ /sni_zator\.txt$/) mode = "zset"
      else if (FILENAME ~ /sni_override\.tsv$/) mode = "pin"
      else if (FILENAME ~ /sni_pool_policy\.tsv$/) mode = "pol"
      else if (FILENAME ~ /sni_pool\.tsv$/) mode = "pool"
    }
    {
      sub(/\r$/, "")
      if (mode == "uset" || mode == "zset") {
        if ($0 ~ /^# set: /) { cur = tolower($3); next }
        if (cur == "") next
        line = $0
        sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
        if (line == "" || line ~ /^#/) next
        line = tolower(line)
        key = mode SUBSEP cur
        if (setdom[key] == "") setnames[mode] = setnames[mode] " " cur
        setdom[key] = setdom[key] "\"" line "\","
        setcnt[key]++
        next
      }
      if (NF < 2) next
      if (mode == "pin") { pins[$1] = tolower($2); next }
      if (mode == "pol") { pol[$1] = $2; next }
      if (mode == "pool") { poolrows[$1] = poolrows[$1] $2 "\n" }
    }
    function set_domains(name,   k, out, w) {
      # пользовательский файл выигрывает целиком
      k = "uset" SUBSEP name
      if (setcnt[k] > 0) return setdom[k]
      k = "zset" SUBSEP name
      return setdom[k]
    }
    function set_origin(name) {
      if (setcnt["uset" SUBSEP name] > 0) return "user"
      if (setcnt["zset" SUBSEP name] > 0) return "zator"
      return ""
    }
    END {
      nprofs = split("1 2 3 4 8", P, " ")
      titles["1"] = "TCP 443 (YouTube)"
      titles["2"] = "TCP 443 (Googlevideo)"
      titles["3"] = "TCP 443 (RKN)"
      titles["4"] = "TCP 443 (Discord)"
      titles["8"] = "Fallback TLS"
      prof_json = ""
      for (i = 1; i <= nprofs; i++) {
        p = P[i]
        pin = (p in pins) ? pins[p] : ""
        rows = (p in poolrows) ? poolrows[p] : ""
        polv = (p in pol && pol[p] == "rand") ? "rand" : "rr"
        pollabel = (polv == "rand") ? "случайно" : "по кругу"
        # разворот строк пула: @имя -> домены набора
        eff = ""; n_eff = 0; n_rows = 0; first = ""; cur_set = ""
        n = split(rows, R, "\n")
        for (j = 1; j <= n; j++) {
          r = R[j]
          if (r == "") continue
          n_rows++
          if (first == "") first = r
          if (r ~ /^@/) {
            nm = tolower(substr(r, 2))
            d = set_domains(nm)
            m = split(d, D, ",")
            for (q = 1; q <= m; q++) if (D[q] != "") { eff = eff D[q] ","; n_eff++ }
          } else {
            eff = eff "\"" tolower(r) "\","; n_eff++
          }
        }
        sub(/,$/, "", eff)
        if (first ~ /^@/) {
          cur_set = tolower(substr(first, 2))
          kind = "набор " cur_set
          if (n_rows > 1) kind = kind " + свои"
        } else if (n_rows > 0) kind = "свой список"
        else kind = ""
        if (kind == "") pool_str = "нет пула (один SNI)"
        else pool_str = kind " (" n_eff " имён, " pollabel ", автосмена)"
        prof_json = prof_json (prof_json ? "," : "") \
          "{\"id\":\"" p "\",\"title\":\"" titles[p] "\",\"pin\":\"" pin "\"," \
          "\"pool\":\"" pool_str "\",\"policy\":\"" polv "\",\"set\":\"" cur_set "\"," \
          "\"effective\":[" eff "]}"
      }
      sets_json = ""
      seen = " "
      # сначала пользовательские, затем проектные (без повторов имён)
      for (s = 1; s <= 2; s++) {
        which = (s == 1) ? "uset" : "zset"
        m = split(setnames[which], N, " ")
        for (j = 1; j <= m; j++) {
          nm = N[j]
          if (nm == "" || index(seen, " " nm " ") > 0) continue
          seen = seen nm " "
          d = set_domains(nm)
          sub(/,$/, "", d)
          sets_json = sets_json (sets_json ? "," : "") \
            "{\"name\":\"" nm "\",\"origin\":\"" set_origin(nm) "\",\"domains\":[" d "]}"
        }
      }
      printf "{\"profiles\":[%s],\"sets\":[%s]}", prof_json, sets_json
    }
  ' $files
}

_blobs_config_path() {
  local cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [ -f "$cfg" ] || cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config.default"
  printf '%s' "$cfg"
}

api_blobs_list() {
  _blobs_lib_guard
  local cfg rows="" row refs files="" f stock="" b name file comment sni
  cfg="$(_blobs_config_path)"
  sni="null"
  _blobs_sni_available && sni="$(_blobs_sni_json)"
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
  # серверный признак «есть неприменённые изменения» (замечание автора PR #82:
  # после удаления последнего блоба и обновления страницы Vue-флаг терялся, а
  # старая декларация оставалась в конфиге): сверяем ожидаемый инжект с секцией
  local expected="" actual dirty=0
  while IFS= read -r row; do
    _custom_blobs_split "$row" || continue
    expected="${expected}--blob=$_CB_NAME:@$(custom_blobs_dir)/$_CB_FILE"$'\n'
  done < <(custom_blobs_list)
  actual="$(awk '/^#Z2R_CUSTOM_BLOBS_BEGIN$/{f=1;next} /^#Z2R_CUSTOM_BLOBS_END$/{f=0} f && /^--blob=/' "$cfg")"
  [ "$actual" != "$expected" ] && dirty=1
  printf 'Cache-Control: no-store\r\n'
  send_json "200 OK" "{\"dir\":\"$(json_escape "$(custom_blobs_dir)")\",\"blobs\":[$rows],\"files\":[$files],\"stock\":[$stock],\"config_dirty\":$dirty,\"sni\":$sni}"
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
  local name="$(_blobs_query_param name)" tmp base auto size rc got=0 chunk_before
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
  # чтение тела: в цикле до нужного объёма (один dd с count может вернуть
  # короткую запись и недобрать байты — замечание автора PR #82)
  tmp="/tmp/z2r-blob-up.$$"
  : > "$tmp"
  got=0
  while [ "$got" -lt "${CONTENT_LENGTH:-0}" ]; do
    chunk_before="$(wc -c < "$tmp" 2>/dev/null | tr -d '[:space:]')"
    dd bs=8192 count=1 2>/dev/null >> "$tmp" || true
    got="$(wc -c < "$tmp" 2>/dev/null | tr -d '[:space:]')"
    # тело кончилось раньше CONTENT_LENGTH (клиент отвалился) — не крутимся
    [ "$got" -gt "$chunk_before" ] || { rm -f "$tmp"; send_error "400 Bad Request" "Загрузка прервана (получено ${got} из ${CONTENT_LENGTH} Б)."; }
  done
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
    sni_pin)
      _blobs_sni_guard
      _blobs_sni_profile_ok "$PARAM_PROFILE" \
        || send_error "400 Bad Request" "Некорректный профиль: $PARAM_PROFILE"
      if [ -z "$PARAM_VALUE" ]; then
        sni_override_clear "$PARAM_PROFILE" \
          || send_error "500 Internal Server Error" "Не удалось сбросить SNI"
      elif sni_override_valid "$PARAM_VALUE"; then
        sni_override_set "$PARAM_PROFILE" "$PARAM_VALUE" \
          || send_error "500 Internal Server Error" "Не удалось сохранить SNI"
      else
        send_error "400 Bad Request" "Некорректный домен: строчные буквы/цифры/точки/дефисы, до 254 символов."
      fi
      telemetry_notify
      send_json "200 OK" "{\"ok\":true,\"restarted\":false,\"restart_required\":false}"
      ;;
    sni_pool_assign)
      _blobs_sni_guard
      _blobs_sni_profile_ok "$PARAM_PROFILE" \
        || send_error "400 Bad Request" "Некорректный профиль: $PARAM_PROFILE"
      sni_pool_assign_set "$PARAM_PROFILE" "$PARAM_VALUE" \
        || send_error "400 Bad Request" "Набор «$PARAM_VALUE» не найден или некорректен."
      telemetry_notify
      send_json "200 OK" "{\"ok\":true,\"restarted\":false,\"restart_required\":false}"
      ;;
    sni_pool_custom)
      _blobs_sni_guard
      _blobs_sni_profile_ok "$PARAM_PROFILE" \
        || send_error "400 Bad Request" "Некорректный профиль: $PARAM_PROFILE"
      local -a sni_items=()
      local sni_d
      for sni_d in $(_blobs_sni_domains "$PARAM_LIST"); do
        [ -n "$sni_d" ] && sni_items+=("$sni_d")
      done
      [ "${#sni_items[@]}" -ge 1 ] || send_error "400 Bad Request" "Список пуст."
      sni_pool_set_list "$PARAM_PROFILE" "${sni_items[@]}" \
        || send_error "400 Bad Request" "Некорректный домен в списке или больше ${Z2R_SNI_POOL_MAX:-32} имён."
      telemetry_notify
      send_json "200 OK" "{\"ok\":true,\"restarted\":false,\"restart_required\":false}"
      ;;
    sni_pool_clear)
      _blobs_sni_guard
      _blobs_sni_profile_ok "$PARAM_PROFILE" \
        || send_error "400 Bad Request" "Некорректный профиль: $PARAM_PROFILE"
      sni_pool_clear "$PARAM_PROFILE" \
        || send_error "500 Internal Server Error" "Не удалось убрать пул"
      telemetry_notify
      send_json "200 OK" "{\"ok\":true,\"restarted\":false,\"restart_required\":false}"
      ;;
    sni_pool_policy)
      _blobs_sni_guard
      _blobs_sni_profile_ok "$PARAM_PROFILE" \
        || send_error "400 Bad Request" "Некорректный профиль: $PARAM_PROFILE"
      sni_pool_policy_set "$PARAM_PROFILE" "$PARAM_VALUE" \
        || send_error "400 Bad Request" "Политика: rr (по кругу) или rand (случайно без повторов)."
      telemetry_notify
      send_json "200 OK" "{\"ok\":true,\"restarted\":false,\"restart_required\":false}"
      ;;
    sni_set_write)
      _blobs_sni_guard
      local -a sni_items=()
      local sni_d
      for sni_d in $(_blobs_sni_domains "$PARAM_LIST"); do
        [ -n "$sni_d" ] && sni_items+=("$sni_d")
      done
      # имя набора — name, домены — list
      [ "${#sni_items[@]}" -ge 1 ] || send_error "400 Bad Request" "Список пуст."
      sni_pool_set_write "$PARAM_NAME" "${sni_items[@]}" \
        || send_error "400 Bad Request" "Некорректное имя набора или домен в списке (до ${Z2R_SNI_POOL_MAX:-32} имён)."
      telemetry_notify
      send_json "200 OK" "{\"ok\":true,\"restarted\":false,\"restart_required\":false}"
      ;;
    sni_set_delete)
      _blobs_sni_guard
      sni_pool_set_delete "$PARAM_NAME" \
        || send_error "400 Bad Request" "Нельзя удалить: набор занят в пулах или не является вашим."
      telemetry_notify
      send_json "200 OK" "{\"ok\":true,\"restarted\":false,\"restart_required\":false}"
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
