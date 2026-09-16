# Развёртывание zator из tar-архивов релизов GitHub или локальных файлов.
# Источник: releases/download/<tag>/zator-<variant>.tar.gz (core|webui|full).
# Архивы собирает webui-src/scripts/pack-zator-tar.mjs; карта файлов и классы
# защиты — в manifest.tsv внутри архива:
#   path|dest|class|sha256|size|exec, class = auto|keep-if-exists|payload.
#
# Модуль самодостаточен: z2r.sh source-ит его для меню, лаунчер z2r вызывает
# standalone: bash /opt/zator/z2r_lib/deploy.sh from-tar <файл|url> [variant] [tag]

ZATOR_ROOT="${ZATOR_ROOT:-/opt/zator}"
ZAPRET2_ROOT="${ZAPRET2_ROOT:-/opt/zapret2}"
DEPLOY_CACHE_DIR="$ZATOR_ROOT/extra_strats/cache/deploy"
DEPLOY_VERSION_FILE="$DEPLOY_CACHE_DIR/version.env"
DEPLOY_LATEST_FILE="$DEPLOY_CACHE_DIR/latest.env"
DEPLOY_PAYLOAD_DIR="$ZATOR_ROOT/.deploy-payload"
DEPLOY_MANIFEST_REL="extra_strats/cache/deploy/manifest.tsv"
DEPLOY_MARGIN_KB="${Z2R_DEPLOY_MARGIN_KB:-8192}"
DEPLOY_SLACK_KB="${Z2R_DEPLOY_SLACK_KB:-1024}"
DEPLOY_RELEASES_LIST="/tmp/z2r_deploy_releases.txt"
Z2R_SCRIPT_DEST="${Z2R_SCRIPT_DEST:-/opt/z2r.sh}"

# Манифест хранит канонические dest (/opt/zator/..., /opt/z2r.sh); при
# переопределённых корнях (тесты, staging) пути перегоняются сюда.
deploy_dest_for() {
  case "$1" in
    /opt/z2r.sh) printf '%s' "$Z2R_SCRIPT_DEST" ;;
    /opt/zator/*) printf '%s/%s' "$ZATOR_ROOT" "${1#/opt/zator/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# цвета и сеть определены в z2r.sh; при standalone-вызове даём минимум
if [ -z "${yellow:-}" ]; then
  plain='' red='' green='' yellow='' Fyellow='' Fcyan='' Bred='' Fplain=''
fi
if ! command -v z2r_fetch_url_to_file >/dev/null 2>&1; then
  z2r_fetch_url_to_file() {
    local dest="$1" url="$2" attempt
    for attempt in 1 2 3; do
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 -o "$dest" "$url" && return 0
      elif command -v wget >/dev/null 2>&1; then
        wget -q -T 10 -O "$dest" "$url" && return 0
      else
        return 127
      fi
      rm -f "$dest"
      [ "$attempt" -lt 3 ] && sleep 2
    done
    return 1
  }
fi

if ! command -v ui_is_number_in_range >/dev/null 2>&1; then
  ui_is_number_in_range() {
    case "$2" in ''|*[!0-9]*) return 1 ;; esac
    case "$3" in ''|*[!0-9]*) return 1 ;; esac
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
  }
fi

deploy_sources_file() {
  printf '%s/extra_strats/cache/deploy/sources.env' "${ZATOR_ROOT:-/opt/zator}"
}

deploy_releases_base() {
  if [ -n "${Z2R_RELEASES_BASE:-}" ]; then
    printf '%s' "$Z2R_RELEASES_BASE"
    return 0
  fi
  local mirror
  mirror="$(deploy_env_get "$(deploy_sources_file)" RELEASES_MIRROR)"
  if [ -n "$mirror" ]; then
    printf '%s' "$mirror"
    return 0
  fi
  local base="${Z2R_PROJECT_RAW_BASE:-}"
  # CGI и прямой запуск z2r.sh не наследуют env лаунчера: репозиторий берём
  # из его же конфига (RAW_URL пишет туда лаунчер с URL-аргументом форка).
  if [ -z "$base" ] && [ -f "${Z2R_CONF:-/opt/z2r.conf}" ]; then
    base="$(deploy_env_get "${Z2R_CONF:-/opt/z2r.conf}" RAW_URL)"
  fi
  [ -n "$base" ] || base="https://raw.githubusercontent.com/AloofLibra/zator/zator"
  local owner repo
  owner="$(printf '%s' "$base" | cut -d/ -f4)"
  repo="$(printf '%s' "$base" | cut -d/ -f5)"
  if [ -n "$owner" ] && [ -n "$repo" ]; then
    printf 'https://github.com/%s/%s/releases/download' "$owner" "$repo"
  else
    printf 'https://github.com/AloofLibra/zator/releases/download'
  fi
}

deploy_env_get() {
  # всегда rc=0, отсутствие файла = пустое значение: присваивания без защиты
  # не должны ронять вызывающий скрипт под set -e
  local file="$1" key="$2" line
  line="$(grep "^${key}=" "$file" 2>/dev/null | head -n 1)"
  line=${line#*=}
  line=${line#\"}
  printf '%s' "${line%\"}"
  return 0
}

deploy_version_field() { deploy_env_get "$DEPLOY_VERSION_FILE" "$1"; }
deploy_latest_field() { deploy_env_get "$DEPLOY_LATEST_FILE" "$1"; }

deploy_json_str() {
  sed -n "s/^.*\"$2\": *\"\([^\"]*\)\".*$/\1/p" "$1" | head -n1
}

deploy_json_num() {
  sed -n "s/^.*\"$2\": *\([0-9][0-9]*\).*$/\1/p" "$1" | head -n1
}

deploy_asset_field() {
  local file="$1" variant="$2" key="$3" section
  section="$(awk -v v="\"${variant}\":" 'index($0, v) > 0 {inb = 1; next} inb && index($0, "}") > 0 {exit} inb {print}' "$file")"
  printf '%s\n' "$section" | sed -n "s/^.*\"${key}\": *\"\([^\"]*\)\".*$/\1/p" | head -n1
  printf '%s\n' "$section" | sed -n "s/^.*\"${key}\": *\([0-9][0-9]*\).*$/\1/p" | head -n1
}

# Забирает latest.json релиза <tag> и заполняет DEPLOY_META_* по сборке и
# DEPLOY_META_ASSET_<VARIANT>_{SIZE,SHA,UNPACKED} по ассетам.
deploy_fetch_release_meta() {
  local tag="$1"
  local tmp="/tmp/z2r_deploy_meta_$$.json"
  rm -f "$tmp"
  if ! z2r_fetch_url_to_file "$tmp" "$(deploy_releases_base)/${tag}/latest.json"; then
    rm -f "$tmp"
    return 1
  fi
  DEPLOY_META_RELEASE="$(deploy_json_str "$tmp" release)"
  DEPLOY_META_BUILD_DATE="$(deploy_json_str "$tmp" buildDate)"
  DEPLOY_META_ZATOR_SHA="$(deploy_json_str "$tmp" zatorSha)"
  DEPLOY_META_WEBUI_SHA="$(deploy_json_str "$tmp" webuiSha)"
  DEPLOY_META_ZATOR_DATE="$(deploy_json_str "$tmp" zatorDate)"
  DEPLOY_META_WEBUI_DATE="$(deploy_json_str "$tmp" webuiDate)"
  local v
  for v in core webui full; do
    eval "DEPLOY_META_ASSET_${v^^}_SIZE=\"\$(deploy_asset_field \"\$tmp\" \"\$v\" size)\""
    eval "DEPLOY_META_ASSET_${v^^}_SHA=\"\$(deploy_asset_field \"\$tmp\" \"\$v\" sha256)\""
    eval "DEPLOY_META_ASSET_${v^^}_UNPACKED=\"\$(deploy_asset_field \"\$tmp\" \"\$v\" unpackedSize)\""
  done
  rm -f "$tmp"
  [ -n "$DEPLOY_META_RELEASE" ]
}

# Пофайловые (raw) установки/обновления живут без version.env: шапка меню и
# панель показывают пустые версии, сравнивать обновления не с чем. Заполняем
# один раз датой коммита ветки (её z2r.sh и так получает для «zeefeer
# обновлен»). Существующий version.env не трогаем; дата неизвестна — пропуск.
deploy_version_bootstrap() {
  local date="${1:-}" vf
  [ -n "$date" ] || return 0
  vf="$DEPLOY_VERSION_FILE"
  if [ -f "$vf" ] && grep -q '^ZATOR_DATE=' "$vf"; then
    return 0
  fi
  mkdir -p "$DEPLOY_CACHE_DIR"
  {
    printf 'ZATOR_VERSION="branch"\nZATOR_DATE="%s"\n' "$date"
    if [ -e "$ZATOR_ROOT/webui/run-webui.sh" ]; then
      printf 'WEBUI_VERSION="branch"\nWEBUI_DATE="%s"\n' "$date"
    fi
    printf 'TRACKING="latest"\n'
  } > "${vf}.tmp.$$" && mv -f "${vf}.tmp.$$" "$vf"
  return 0
}

# Перезапись кэша latest.env из DEPLOY_META_* (заполняются
# deploy_fetch_release_meta или точечным фетчем веб-панели).
deploy_latest_write_cache() {  mkdir -p "$DEPLOY_CACHE_DIR"
  cat > "${DEPLOY_LATEST_FILE}.tmp" <<EOF
LATEST_RELEASE="$DEPLOY_META_RELEASE"
LATEST_BUILD_DATE="$DEPLOY_META_BUILD_DATE"
LATEST_ZATOR_DATE="$DEPLOY_META_ZATOR_DATE"
LATEST_WEBUI_DATE="$DEPLOY_META_WEBUI_DATE"
LATEST_ZATOR_SHA="$DEPLOY_META_ZATOR_SHA"
LATEST_WEBUI_SHA="$DEPLOY_META_WEBUI_SHA"
LATEST_CHECKED_AT="$(date -u '+%Y-%m-%d %H:%M')"
EOF
  mv -f "${DEPLOY_LATEST_FILE}.tmp" "$DEPLOY_LATEST_FILE"
}

deploy_check_latest() {
  DEPLOY_UPDATE_ZATOR=0
  DEPLOY_UPDATE_WEBUI=0
  if ! deploy_fetch_release_meta latest; then
    echo -e "${yellow}Не достучались до сервера обновлений.${plain}"
    if [ -n "$(deploy_env_get "$(deploy_sources_file)" RELEASES_MIRROR)" ]; then
      echo -e "${yellow}Проверьте зеркало или сбросьте источник: п.5 -> п.10.${plain}"
    fi
    return 1
  fi
  deploy_latest_write_cache

  local zator_sha webui_sha
  zator_sha="$(deploy_version_field ZATOR_SHA)"
  webui_sha="$(deploy_version_field WEBUI_SHA)"
  [ -n "$zator_sha" ] && [ "$zator_sha" != "$DEPLOY_META_ZATOR_SHA" ] && DEPLOY_UPDATE_ZATOR=1
  # без установленной панели обновлять нечего: WEBUI_SHA в version.env
  # присутствует даже на core-установках (общая сборка)
  if [ -e "$ZATOR_ROOT/webui/run-webui.sh" ]; then
    [ -n "$webui_sha" ] && [ "$webui_sha" != "$DEPLOY_META_WEBUI_SHA" ] && DEPLOY_UPDATE_WEBUI=1
  fi
  if [ "$DEPLOY_UPDATE_ZATOR" = 1 ] || [ "$DEPLOY_UPDATE_WEBUI" = 1 ]; then
    echo -e "${yellow}Есть обновление:${plain}"
    [ "$DEPLOY_UPDATE_ZATOR" = 1 ] && echo -e "  zator от ${green}$DEPLOY_META_ZATOR_DATE${plain}"
    [ "$DEPLOY_UPDATE_WEBUI" = 1 ] && echo -e "  Web-панель от ${green}$DEPLOY_META_WEBUI_DATE${plain}"
  else
    echo -e "${green}Обновлений нет (релиз $DEPLOY_META_RELEASE).${plain}"
  fi
  return 0
}

free_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Выбор режима staging по свободному месту:
#   A — staging в /tmp (архив + развёрнутое одновременно);
#   B — staging на /opt (архив + развёрнутое на разделе установки);
#   C — без хранения архива: распаковка в новый каталог с послеченной сверкой.
deploy_space_mode_select() {
  local archive_kb="$1" unpacked_kb="$2"
  DEPLOY_MODE=""
  local tmp_free opt_free
  tmp_free="$(free_kb /tmp)"
  opt_free="$(free_kb "$ZATOR_ROOT")"
  if [ -z "$tmp_free" ] || [ -z "$opt_free" ]; then
    echo -e "${yellow}Не удалось определить свободное место (df). Проверки пропущены.${plain}"
    DEPLOY_MODE=A
    return 0
  fi
  local need="$((unpacked_kb + DEPLOY_MARGIN_KB + DEPLOY_SLACK_KB))"
  if [ "$opt_free" -lt "$need" ]; then
    echo -e "${red}Недостаточно места на разделе /opt: свободно $((opt_free / 1024)) МБ, нужно около $((need / 1024)) МБ (zator + zapret2 + рост листов).${plain}"
    return 1
  fi
  if [ "$tmp_free" -ge "$((archive_kb + unpacked_kb + 512))" ]; then
    DEPLOY_MODE=A
  elif [ "$opt_free" -ge "$((archive_kb + unpacked_kb + DEPLOY_MARGIN_KB + DEPLOY_SLACK_KB))" ]; then
    echo -e "${yellow}Мало места в /tmp — staging будет на /opt.${plain}"
    DEPLOY_MODE=B
  else
    echo -e "${yellow}Совсем мало места — установка без хранения архива, с послеченной сверкой.${plain}"
    DEPLOY_MODE=C
  fi
}

deploy_gzip_ok() {
  # od есть не везде (OpenWrt): gzip -t сам ловит и HTML-страницы, и битые архивы
  gzip -t "$1" 2>/dev/null || { echo -e "${red}Файл не является gzip-архивом (возможно, страница ошибки).${plain}"; return 1; }
}

# члены архива не должны выбираться за пределы каталога распаковки
deploy_tar_paths_ok() {
  tar -tzf "$1" 2>/dev/null | while IFS= read -r entry; do
    case "$entry" in
      /*|../*|*/../*|*/..) exit 1 ;;
    esac
  done
}

file_sha256() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

deploy_download_archive() {
  local dest="$1" tag="$2" variant="$3"
  local url="${4:-}" expected
  if [ -z "$url" ]; then
    url="$(deploy_releases_base)/${tag}/zator-${variant}.tar.gz"
  fi
  if ! z2r_fetch_url_to_file "$dest" "$url"; then
    echo -e "${red}Не удалось скачать архив zator-${variant}.tar.gz (релиз $tag).${plain}"
    return 1
  fi
  eval "expected=\"\${DEPLOY_META_ASSET_${variant^^}_SHA:-}\""
  if [ -n "$expected" ] && command -v sha256sum >/dev/null 2>&1; then
    if [ "$(file_sha256 "$dest")" != "$expected" ]; then
      echo -e "${red}Контрольная сумма архива не совпала.${plain}"
      rm -f "$dest"
      return 1
    fi
  fi
}

deploy_unpack() {
  local archive="$1" dir="$2"
  mkdir -p "$dir"
  if tar -xzf "$archive" -C "$dir" 2>/dev/null; then
    return 0
  fi
  (cd "$dir" && tar -xzf "$archive")
}

deploy_stream_unpack() {
  local url="$1" dir="$2"
  mkdir -p "$dir"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 "$url" | tar -xz -C "$dir"
  else
    wget -q -T 10 -O - "$url" | tar -xz -C "$dir"
  fi
}

deploy_verify_staging() {
  local dir="$1" failed=0 checked=0
  local manifest="$dir/$DEPLOY_MANIFEST_REL"
  if [ ! -f "$manifest" ]; then
    echo -e "${red}В архиве нет манифеста — отказ разворачивать.${plain}"
    return 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo -e "${yellow}sha256sum недоступен — сверка пропущена.${plain}"
    return 0
  fi
  local path dest cls sha size exec
  while IFS='|' read -r path dest cls sha size exec; do
    case "$path" in ''|'#'*) continue ;; esac
    checked=$((checked + 1))
    if [ ! -f "$dir/$path" ] || [ "$(file_sha256 "$dir/$path")" != "$sha" ]; then
      echo -e "${red}Повреждён файл в архиве: $path${plain}"
      failed=$((failed + 1))
    fi
  done < "$manifest"
  if [ "$failed" -ne 0 ]; then
    echo -e "${red}Сверка не пройдена: $failed из $checked файлов.${plain}"
    return 1
  fi
  echo -e "${green}Сверка архива пройдена ($checked файлов).${plain}"
}

deploy_install_file() {
  local src="$1" dest="$2" exec="$3" tmp="${dest}.z2rtmp.$$"
  mkdir -p "$(dirname "$dest")"
  rm -f "$tmp"
  cp "$src" "$tmp" || return 1
  mv -f "$tmp" "$dest" || return 1
  if [ "$exec" = "1" ]; then chmod 755 "$dest"; else chmod 644 "$dest"; fi
}

deploy_fix_interpreters() {
  local bash_bin f
  [ -x /opt/bin/bash ] || return 0
  bash_bin=/opt/bin/bash
  for f in "$ZATOR_ROOT/webui/run-webui.sh" "$ZATOR_ROOT"/webui/cgi-bin/*; do
    [ -f "$f" ] || continue
    sed -i "1s|^#!.*bash\$|#!$bash_bin|" "$f"
  done
}

deploy_webui_running() {
  [ -x "$ZATOR_ROOT/webui/run-webui.sh" ] || return 1
  case "$("$ZATOR_ROOT/webui/run-webui.sh" status 2>/dev/null)" in
    running:*) return 0 ;;
    *) return 1 ;;
  esac
}

deploy_write_version() {
  local new_env="$1" has_core="$2" has_webui="$3" tracking="$4"
  mkdir -p "$DEPLOY_CACHE_DIR"
  local zver zdate zcommit zsha wver wdate wsha
  zver="$(deploy_env_get "$new_env" ZATOR_VERSION)"
  zdate="$(deploy_env_get "$new_env" ZATOR_DATE)"
  zcommit="$(deploy_env_get "$new_env" ZATOR_COMMIT)"
  zsha="$(deploy_env_get "$new_env" ZATOR_SHA)"
  wver="$(deploy_env_get "$new_env" WEBUI_VERSION)"
  wdate="$(deploy_env_get "$new_env" WEBUI_DATE)"
  wsha="$(deploy_env_get "$new_env" WEBUI_SHA)"
  if [ "$has_core" != 1 ]; then
    zver="$(deploy_version_field ZATOR_VERSION)"
    zdate="$(deploy_version_field ZATOR_DATE)"
    zcommit="$(deploy_version_field ZATOR_COMMIT)"
    zsha="$(deploy_version_field ZATOR_SHA)"
  fi
  if [ "$has_webui" != 1 ]; then
    wver="$(deploy_version_field WEBUI_VERSION)"
    wdate="$(deploy_version_field WEBUI_DATE)"
    wsha="$(deploy_version_field WEBUI_SHA)"
  fi
  if [ -z "$tracking" ]; then tracking="$(deploy_version_field TRACKING)"; fi
  [ -n "$tracking" ] || tracking="latest"
  cat > "${DEPLOY_VERSION_FILE}.tmp" <<EOF
ZATOR_VERSION="${zver:-unknown}"
ZATOR_DATE="${zdate:-}"
ZATOR_COMMIT="${zcommit:-}"
ZATOR_SHA="${zsha:-}"
WEBUI_VERSION="${wver:-unknown}"
WEBUI_DATE="${wdate:-}"
WEBUI_SHA="${wsha:-}"
TRACKING="${tracking}"
EOF
  mv -f "${DEPLOY_VERSION_FILE}.tmp" "$DEPLOY_VERSION_FILE"
}

# Общие завершающие шаги, когда дерево архива уже на месте:
# сохранение манифеста, слияние version.env, шебанги webui, рестарт webui.
deploy_post_apply() {
  local tree="$1" tracking="$2" z2r_updated="$3" webui_updated="$4"
  local has_core=0 has_webui=0 name
  if [ -e "$tree/_root/z2r.sh" ] || [ -d "$tree/z2r_lib" ]; then has_core=1; fi
  if [ -e "$tree/webui/run-webui.sh" ]; then has_webui=1; fi
  case "$has_core$has_webui" in
    10) name=core ;;
    01) name=webui ;;
    *) name=full ;;
  esac
  mkdir -p "$DEPLOY_CACHE_DIR"
  # раздельные манифесты по компонентам: webui-деплой освежает только свой,
  # целостность проверяет оба без ложных «изменено»
  if [ "$has_core" = 1 ]; then
    awk -F'|' '$1 ~ /^#/ || $1 !~ /^webui\// {print}' "$tree/$DEPLOY_MANIFEST_REL" > "$DEPLOY_CACHE_DIR/manifest.core.tsv"
  fi
  if [ "$has_webui" = 1 ]; then
    awk -F'|' '$1 ~ /^#/ || $1 ~ /^webui\// {print}' "$tree/$DEPLOY_MANIFEST_REL" > "$DEPLOY_CACHE_DIR/manifest.webui.tsv"
  fi
  rm -f "$DEPLOY_CACHE_DIR/manifest.full.tsv" "$DEPLOY_CACHE_DIR/manifest.full.json"
  if [ -f "$tree/extra_strats/cache/deploy/manifest.json" ]; then
    cp -f "$tree/extra_strats/cache/deploy/manifest.json" "$DEPLOY_CACHE_DIR/manifest.${name}.json"
  fi
  deploy_write_version "$tree/extra_strats/cache/deploy/version.env" "$has_core" "$has_webui" "$tracking"

  if [ "$webui_updated" = 1 ]; then
    deploy_fix_interpreters
    if deploy_webui_running; then
      "$ZATOR_ROOT/webui/run-webui.sh" restart >/dev/null 2>&1 || true
      echo -e "${green}Web-панель перезапущена.${plain}"
    fi
  fi
  if [ "$z2r_updated" = 1 ]; then
    echo -e "${yellow}z2r.sh обновлён — перезапустите меню, чтобы изменения вступили в силу.${plain}"
  fi
}

# Режимы A/B: пофайловая установка из staging по классам манифеста.
deploy_apply_staging() {
  local staging="$1" tracking="$2"
  local manifest="$staging/$DEPLOY_MANIFEST_REL"
  local path dest cls sha size exec z2r_updated=0 webui_updated=0 kept=0 installed=0
  while IFS='|' read -r path dest cls sha size exec; do
    case "$path" in ''|'#'*) continue ;; esac
    case "$path" in /*|../*|*/../*|*/..)
      echo -e "${red}Недопустимый путь в манифесте: $path${plain}"
      return 1
      ;;
    esac
    case "$dest" in
      /opt/zator/*|/opt/z2r.sh) ;;
      *)
        echo -e "${red}Недопустимый dest в манифесте: $dest${plain}"
        return 1
        ;;
    esac
    dest="$(deploy_dest_for "$dest")"
    if [ "$cls" = "keep-if-exists" ] && [ -e "$dest" ]; then
      kept=$((kept + 1))
      continue
    fi
    if ! deploy_install_file "$staging/$path" "$dest" "$exec"; then
      echo -e "${red}Не удалось установить $dest${plain}"
      return 1
    fi
    [ "$dest" = "$Z2R_SCRIPT_DEST" ] && z2r_updated=1
    case "$dest" in "$ZATOR_ROOT"/webui/*) webui_updated=1 ;; esac
    installed=$((installed + 1))
  done < "$manifest"
  echo -e "${green}Установлено файлов: $installed, сохранено пользовательских: $kept.${plain}"
  if [ -d "$staging/webui/www" ]; then
    mkdir -p "$ZATOR_ROOT/webui/www"
    if [ ! -L "$ZATOR_ROOT/webui/www/cgi-bin" ]; then
      rm -rf "$ZATOR_ROOT/webui/www/cgi-bin"
      ln -sfn ../cgi-bin "$ZATOR_ROOT/webui/www/cgi-bin" 2>/dev/null || true
    fi
  fi
  deploy_post_apply "$staging" "$tracking" "$z2r_updated" "$webui_updated"
  deploy_apply_config_default || true
}

# Режим C: наполнение нового дерева из старого. Перенос делается hardlink'ами
# (ln -f), а не mv: старое дерево остаётся целым до финального rm, любой сбой
# на этом этапе откатывается простым возвратом rename. Файлы манифеста класса
# auto не переносятся (новая версия уже в дереве), keep-if-exists заменяет
# копию из архива линком на пользовательский файл.
deploy_carry_over_old() {
  local old="$1" new="$2" manifest="$3"
  local rel cls
  (cd "$old" 2>/dev/null && find . \( -type f -o -type l \) 2>/dev/null) | sed 's#^./##' | while read -r rel; do
    [ -n "$rel" ] || continue
    cls="$(awk -F'|' -v p="$rel" '$1 == p {print $3; exit}' "$manifest")"
    if [ -n "$cls" ] && [ "$cls" != "keep-if-exists" ]; then
      continue
    fi
    mkdir -p "$new/$(dirname "$rel")"
    if [ "$cls" = "keep-if-exists" ]; then
      if [ -e "$old/$rel" ] || [ -L "$old/$rel" ]; then
        rm -f "$new/$rel"
        ln -f "$old/$rel" "$new/$rel" 2>/dev/null || cp -af "$old/$rel" "$new/$rel"
      fi
    elif [ -L "$old/$rel" ]; then
      ln -sfn "$(readlink "$old/$rel")" "$new/$rel" 2>/dev/null || true
    else
      ln -f "$old/$rel" "$new/$rel" 2>/dev/null || cp -af "$old/$rel" "$new/$rel"
    fi
  done
}

# Режим C: <newdir> — распакованное дерево рядом с $ZATOR_ROOT.
deploy_apply_newdir() {
  local newdir="$1" tracking="$2" fresh="$3"
  local z2r_updated=0 webui_updated=0 olddir="${ZATOR_ROOT}.old.$$"
  if [ -f "$newdir/_root/z2r.sh" ]; then
    deploy_install_file "$newdir/_root/z2r.sh" "$Z2R_SCRIPT_DEST" 1 || return 1
    rm -rf "$newdir/_root"
    z2r_updated=1
  fi
  if [ -e "$newdir/webui/run-webui.sh" ]; then webui_updated=1; fi

  local had_old=0
  if [ "$fresh" != 1 ] && [ -d "$ZATOR_ROOT" ]; then
    had_old=1
    mv -f "$ZATOR_ROOT" "$olddir" || return 1
  fi
  mkdir -p "$(dirname "$ZATOR_ROOT")"
  if ! mv -f "$newdir" "$ZATOR_ROOT"; then
    [ "$had_old" = 1 ] && mv -f "$olddir" "$ZATOR_ROOT"
    return 1
  fi
  if [ "$had_old" = 1 ]; then
    # старое дерево (уже переименованное) наполняло новое hardlink'ами
    deploy_carry_over_old "$olddir" "$ZATOR_ROOT" "$ZATOR_ROOT/$DEPLOY_MANIFEST_REL"
    rm -rf "$olddir"
  fi
  if [ -d "$ZATOR_ROOT/_payload" ]; then
    rm -rf "$ZATOR_ROOT/.deploy-payload"
    mv -f "$ZATOR_ROOT/_payload" "$ZATOR_ROOT/.deploy-payload"
  fi
  if [ -d "$ZATOR_ROOT/webui/www" ] && [ ! -L "$ZATOR_ROOT/webui/www/cgi-bin" ]; then
    rm -rf "$ZATOR_ROOT/webui/www/cgi-bin"
    ln -sfn ../cgi-bin "$ZATOR_ROOT/webui/www/cgi-bin" 2>/dev/null || true
  fi
  deploy_post_apply "$ZATOR_ROOT" "$tracking" "$z2r_updated" "$webui_updated"
  deploy_apply_config_default || true
}

# Основной вход: deploy_from_tar <файл|url> [variant] [tag]
# Для url: variant обязателен, tag = latest или номер релиза (пишется в TRACKING).
# Применяет config.default из payload релиза: эталон копируется в
# $ZAPRET2_ROOT, затем переносится на живой config (локи, client-scope,
# WAN кинетика) с рестартом zapret2. Пользовательские листы не трогаются.
# Без живого config (свежая установка) — только эталон, установочный
# поток z2r.sh соберёт config сам.
deploy_apply_config_default() {
  [ -f "$DEPLOY_PAYLOAD_DIR/config.default" ] || return 0
  local root="${ZAPRET2_ROOT:-/opt/zapret2}"
  mkdir -p "$root"
  cp -f "$DEPLOY_PAYLOAD_DIR/config.default" "$root/config.default" || return 1
  if [ ! -f "$root/config" ]; then
    echo -e "${yellow}config.default обновлён (эталон); живой config появится при установке zapret2.${plain}"
    return 0
  fi
  deploy_apply_config_to_live
}

# Бэкап-промпт -> stop -> config_apply_from_default -> восстановление/рестарт.
# Рестарт при созданном бэкапе делает backup_update_offer_restore (сценарий А).
deploy_apply_config_to_live() {
  local root="${ZAPRET2_ROOT:-/opt/zapret2}"
  if ! type config_apply_from_default >/dev/null 2>&1; then
    # standalone-запуск лаунчера: применит меню z2r (п.5 -> п.7).
    # Подсказка нужна только когда эталон новее живого конфига, иначе
    # каждый деплой зря кричит о «новом конфиге».
    if ! type config_update_pending >/dev/null 2>&1 && [ -f "$ZATOR_ROOT/z2r_lib/config.sh" ]; then
      . "$ZATOR_ROOT/z2r_lib/config.sh" 2>/dev/null || true
    fi
    if type config_update_pending >/dev/null 2>&1; then
      config_update_pending || return 0
    fi
    echo -e "${yellow}config.default обновлён; примените его к живому конфигу: меню п.5 -> п.7.${plain}"
    return 0
  fi
  if type backup_helper_ask_and_create >/dev/null 2>&1; then
    backup_helper_ask_and_create
  fi
  if type z2r_service_action >/dev/null 2>&1; then
    z2r_service_action stop >/dev/null 2>&1 || true
  fi
  if ! config_apply_from_default; then
    echo -e "${red}Не удалось применить config.default к живому конфигу.${plain}"
    if type z2r_service_action >/dev/null 2>&1; then
      z2r_service_action start >/dev/null 2>&1 || true
    fi
    return 1
  fi
  if [ "${BACKUP_HELPER_CREATED:-0}" = 1 ] && type backup_update_offer_restore >/dev/null 2>&1; then
    backup_update_offer_restore || true
  elif type z2r_service_action >/dev/null 2>&1; then
    z2r_service_action restart >/dev/null 2>&1 || true
    echo -e "${green}Живой config обновлён из config.default, zapret2 перезапущен.${plain}"
  fi
  return 0
}

# Лёгкий путь п.7: применить уже установленный config.default без сети.
# После применения эталон копируется в payload — офлайн-источник на будущее.
deploy_apply_installed_config() {
  local root="${ZAPRET2_ROOT:-/opt/zapret2}"
  local src=""
  if [ -f "$root/config.default" ]; then
    src="$root/config.default"
  elif [ -f "$DEPLOY_PAYLOAD_DIR/config.default" ]; then
    src="$DEPLOY_PAYLOAD_DIR/config.default"
  else
    echo -e "${red}Локальный config.default не найден. Обновитесь из релиза (п.2) или локального архива (п.5).${plain}"
    return 1
  fi
  if [ ! -f "$root/config" ]; then
    echo -e "${yellow}Живой config отсутствует: появится при установке zapret2.${plain}"
    return 0
  fi
  if type config_update_pending >/dev/null 2>&1; then
    config_update_pending
    [ "$?" = 1 ] && {
      echo -e "${green}Живой конфиг уже применён из актуального config.default.${plain}"
      return 0
    }
  fi
  if [ "$src" != "$root/config.default" ]; then
    mkdir -p "$root"
    cp -f "$src" "$root/config.default" || return 1
  fi
  deploy_apply_config_to_live || return 1
  mkdir -p "$DEPLOY_PAYLOAD_DIR"
  cp -f "$root/config.default" "$DEPLOY_PAYLOAD_DIR/config.default" 2>/dev/null || true
}

deploy_from_tar() {
  local source="$1" variant="${2:-}" tag="${3:-latest}" tracking="${3:-}"
  local tmpbase="/tmp/z2r_deploy_$$"
  local staging="$tmpbase/stage" newdir="$ZATOR_ROOT.deploy.new.$$"
  local archive="" archive_kb unpacked_kb unpacked_bytes="" fresh=0 url=""
  trap 'rm -rf "$tmpbase" "$newdir"' RETURN

  case "$source" in
    http://*|https://*)
      url="$source"
      if [ -z "$variant" ]; then
        echo -e "${red}Для URL нужно указать вариант (core|webui|full).${plain}"
        return 1
      fi
      if ! deploy_fetch_release_meta "$tag"; then
        echo -e "${red}Не удалось получить метаданные релиза $tag.${plain}"
        return 1
      fi
      mkdir -p "$tmpbase"
      archive="$tmpbase/zator-$variant.tar.gz"
      deploy_download_archive "$archive" "$tag" "$variant" "$url" || return 1
      ;;
    *)
      archive="$source"
      if [ ! -f "$archive" ]; then
        echo -e "${red}Файл не найден: $archive${plain}"
        return 1
      fi
      ;;
  esac

  deploy_gzip_ok "$archive" || return 1
  if ! deploy_tar_paths_ok "$archive"; then
    echo -e "${red}Архив содержит небезопасные пути (выход за каталог распаковки).${plain}"
    return 1
  fi

  if [ -n "$url" ]; then
    eval "unpacked_bytes=\"\${DEPLOY_META_ASSET_${variant^^}_UNPACKED:-}\""
  fi
  if [ -z "$unpacked_bytes" ]; then
    unpacked_bytes="$(gzip -l "$archive" 2>/dev/null | awk 'NR==2 {print $2}')"
  fi
  archive_kb="$(( ($(wc -c < "$archive") + 1023) / 1024))"
  unpacked_kb="$(( ${unpacked_bytes:-0} / 1024 + 1 ))"

  [ -d "$ZATOR_ROOT/z2r_lib" ] || fresh=1
  deploy_space_mode_select "$archive_kb" "$unpacked_kb" || return 1

  if [ "$DEPLOY_MODE" = "C" ]; then
    if [ -n "$url" ]; then
      deploy_stream_unpack "$url" "$newdir" || { rm -rf "$newdir"; return 1; }
    else
      deploy_unpack "$archive" "$newdir" || { rm -rf "$newdir"; return 1; }
    fi
    deploy_verify_staging "$newdir" || { rm -rf "$newdir"; return 1; }
    deploy_apply_newdir "$newdir" "$tracking" "$fresh" || { rm -rf "$newdir"; return 1; }
    return 0
  fi

  if [ "$DEPLOY_MODE" = "B" ]; then
    staging="$ZATOR_ROOT/.deploy-staging.$$"
    rm -rf "$staging"
  fi
  if ! deploy_unpack "$archive" "$staging"; then
    echo -e "${red}Не удалось распаковать архив.${plain}"
    rm -rf "$staging"
    return 1
  fi
  if ! deploy_verify_staging "$staging"; then
    rm -rf "$staging"
    return 1
  fi
  if [ "$DEPLOY_MODE" = "C" ]; then
    deploy_apply_newdir "$staging" "$tracking" "$fresh" || { rm -rf "$staging"; return 1; }
  else
    deploy_apply_staging "$staging" "$tracking" || { rm -rf "$staging"; return 1; }
  fi
  rm -rf "$staging"
  return 0
}

deploy_integrity_check() {
  local m total=0 ok=0 missing=0 changed=0
  local path dest cls sha size exec
  for m in "$DEPLOY_CACHE_DIR"/manifest.*.tsv; do
    [ -f "$m" ] || continue
    while IFS='|' read -r path dest cls sha size exec; do
      case "$path" in ''|'#'*) continue ;; esac
      case "$dest" in
        /opt/zator/*|/opt/z2r.sh) ;;
        *)
          echo -e "${red}недопустимый dest в манифесте: $dest${plain}"
          missing=$((missing + 1))
          continue
          ;;
      esac
      dest="$(deploy_dest_for "$dest")"
      total=$((total + 1))
      if [ ! -f "$dest" ]; then
        echo -e "${red}отсутствует: $dest${plain}"
        missing=$((missing + 1))
      elif command -v sha256sum >/dev/null 2>&1 && [ "$(file_sha256 "$dest")" != "$sha" ]; then
        echo -e "${yellow}изменён:    $dest${plain}"
        changed=$((changed + 1))
      else
        ok=$((ok + 1))
      fi
    done < "$m"
  done
  if [ "$total" -eq 0 ]; then
    echo -e "${yellow}Сохранённых манифестов нет — целостность не проверить (обновитесь из релиза).${plain}"
    return 1
  fi
  echo -e "Файлов в манифестах: $total, совпадают: $ok, изменены: $changed, отсутствуют: $missing"
  [ "$missing" -eq 0 ]
}

deploy_pick_variant() {
  if [ -e "$ZATOR_ROOT/webui/run-webui.sh" ]; then printf full; else printf core; fi
}

deploy_parse_zapret2_tarball_name() {
  local name="${1##*/}"
  case "$name" in
    zapret2-v*-openwrt-embedded.tar.gz)
      name="${name#zapret2-v}"
      name="${name%-openwrt-embedded.tar.gz}"
      ;;
    zapret2-v*.tar.gz)
      name="${name#zapret2-v}"
      name="${name%.tar.gz}"
      ;;
    *)
      return 1
      ;;
  esac
  [ -n "$name" ] || return 1
  printf '%s' "$name"
}

# Локальный архив zapret2 из /tmp: каноническое имя для ZAPRET2_ARCHIVE_DIR,
# версия из имени файла, суффикс сборки закрепляет флэвор fork.
deploy_local_zapret2_pick() {
  local tar_file ver canon other i=1 found="" pick
  local scan_dir="${Z2R_TMP_DIR:-/tmp}"
  local dir="$scan_dir/z2r_local_zapret2"
  for tar_file in "$scan_dir"/*.tar.gz; do
    [ -f "$tar_file" ] || continue
    deploy_parse_zapret2_tarball_name "$tar_file" >/dev/null 2>&1 || continue
    found="$found
$i. ${tar_file##*/}"
    eval "DEPLOY_LOCAL_Z2_$i=\"\$tar_file\""
    i=$((i + 1))
  done
  if [ -z "$found" ]; then
    echo -e "${yellow}В ${scan_dir} нет архивов zapret2-v<версия>.tar.gz. Положите архив туда и повторите.${plain}"
    return 1
  fi
  echo -e "${yellow}Архивы zapret2:${plain}$found"
  read -re -p "Номер архива (0 - отмена): " pick
  if [ "$pick" = "0" ] || ! ui_is_number_in_range "$pick" 1 $((i - 1)); then
    echo -e "${yellow}Отменено.${plain}"
    return 0
  fi
  eval "tar_file=\"\$DEPLOY_LOCAL_Z2_$pick\""
  ver="$(deploy_parse_zapret2_tarball_name "$tar_file")" || return 1
  printf '%s' "$ver" | grep -Eq '^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9.-]+)?$' || {
    echo -e "${red}Некорректная версия в имени архива: $ver${plain}"
    return 1
  }
  case "$ver" in
    *-*)
      if type zapret2_flavor_save >/dev/null 2>&1; then
        zapret2_flavor_save fork
        echo -e "${yellow}Сборка закреплена: форк (суффикс $ver).${plain}"
      fi
      ;;
  esac
  case "${tar_file##*/}" in
    *-openwrt-embedded.tar.gz) canon="zapret2-v${ver}-openwrt-embedded.tar.gz"; other="$scan_dir/zapret2-v${ver}.tar.gz" ;;
    *) canon="zapret2-v${ver}.tar.gz"; other="$scan_dir/zapret2-v${ver}-openwrt-embedded.tar.gz" ;;
  esac
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -f "$tar_file" "$dir/$canon" || { echo -e "${red}Не удалось подготовить архив.${plain}"; return 1; }
  [ -f "$other" ] && cp -f "$other" "$dir/" 2>/dev/null
  export ZAPRET2_ARCHIVE_DIR="$dir"
  export ZAPRET2_VERSION="$ver"
  echo -e "${green}zapret2 ${ver} будет установлен из локального архива.${plain}"
  echo -e "${yellow}Начинается переустановка zapret2: сначала предложат бэкап.${plain}"
  DEPLOY_WANT_REINSTALL=1
  return 0
}

deploy_releases_list_url() {
  local path
  path="$(deploy_releases_base)"
  case "$path" in
    https://github.com/*/releases/download)
      path="${path#https://github.com/}"
      path="${path%/releases/download}"
      ;;
    *)
      return 1
      ;;
  esac
  printf 'https://api.github.com/repos/%s/releases?per_page=20' "$path"
}

deploy_list_releases() {
  local tmp="/tmp/z2r_deploy_releases_$$.json" i=1 tag date url
  if ! url="$(deploy_releases_list_url)"; then
    echo -e "${yellow}Источник-зеркало не отдаёт список релизов: смените источник (п.10) или обновляйтесь с latest (п.2).${plain}"
    return 1
  fi
  if ! z2r_fetch_url_to_file "$tmp" "$url"; then
    echo -e "${red}Не удалось получить список релизов.${plain}"
    return 1
  fi
  # склейка tag+date чистым awk: paste есть не во всех busybox-сборках
  : > "$DEPLOY_RELEASES_LIST"
  while IFS="$(printf '\t')" read -r tag date; do
    [ -n "$tag" ] || continue
    printf '%s. %s  %s\n' "$i" "$tag" "$date" >> "$DEPLOY_RELEASES_LIST"
    i=$((i + 1))
  done <<EOF
$(awk '
  /"tag_name"/ { tag = $0; sub(/.*"tag_name": *"/, "", tag); sub(/".*/, "", tag) }
  /"published_at"/ { date = $0; sub(/.*"published_at": *"/, "", date); sub(/T.*/, "", date); if (tag != "" && tag != "latest") printf "%s\t%s\n", tag, date; tag = "" }
' "$tmp")
EOF
  rm -f "$tmp"
  cat "$DEPLOY_RELEASES_LIST"
  if [ ! -s "$DEPLOY_RELEASES_LIST" ]; then
    echo -e "${red}Релизы не найдены или ответ источника не распознан.${plain}"
    return 1
  fi
  return 0
}

# Выборочный сброс пользовательских файлов к эталону текущей версии
# (архив релиза, на котором стоит установка; TRACKING из version.env).
deploy_reset_user_files() {
  local source="${1:-}"
  local tmpbase="/tmp/z2r_deploy_reset_$$"
  local staging="$tmpbase/stage"
  trap 'rm -rf "$tmpbase"' RETURN
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo -e "${yellow}sha256sum недоступен — сравнение невозможно.${plain}"
    return 1
  fi
  mkdir -p "$tmpbase"

  if [ -z "$source" ]; then
    local tag variant
    tag="$(deploy_version_field TRACKING)"
    [ -n "$tag" ] || tag="latest"
    variant="$(deploy_pick_variant)"
    if ! deploy_fetch_release_meta "$tag"; then
      echo -e "${red}Не удалось получить метаданные релиза $tag.${plain}"
      return 1
    fi
    source="$tmpbase/zator-$variant.tar.gz"
    deploy_download_archive "$source" "$tag" "$variant" || return 1
  fi
  deploy_gzip_ok "$source" || return 1
  if ! deploy_tar_paths_ok "$source"; then
    echo -e "${red}Архив содержит небезопасные пути.${plain}"
    return 1
  fi
  if ! deploy_unpack "$source" "$staging"; then
    echo -e "${red}Не удалось распаковать архив.${plain}"
    return 1
  fi

  local m="$staging/$DEPLOY_MANIFEST_REL"
  local path dest cls sha size exec idx=0 n answer pick reset_count=0 i
  while IFS='|' read -r path dest cls sha size exec; do
    case "$path" in ''|'#'*) continue ;; esac
    [ "$cls" = "keep-if-exists" ] || continue
    case "$path" in /*|../*|*/../*|*/..)
      echo -e "${red}Недопустимый путь в манифесте: $path${plain}"
      return 1
      ;;
    esac
    case "$dest" in
      /opt/zator/*|/opt/z2r.sh) ;;
      *)
        echo -e "${red}Недопустимый dest в манифесте: $dest${plain}"
        return 1
        ;;
    esac
    dest="$(deploy_dest_for "$dest")"
    if [ -f "$dest" ] && [ "$(file_sha256 "$dest")" != "$sha" ]; then
      idx=$((idx + 1))
      eval "DEPLOY_RESET_${idx}_PATH=\"\$path\""
      eval "DEPLOY_RESET_${idx}_DEST=\"\$dest\""
      echo -e "${yellow}$idx. $path${plain}"
    fi
  done < "$m"

  if [ "$idx" -eq 0 ]; then
    echo -e "${green}Пользовательские файлы не отличаются от эталона.${plain}"
    return 0
  fi
  echo -e "${yellow}Введите номера через пробел (например: 1 3), all — все, 0 — отмена:${plain}"
  read -re -p "" answer
  [ "$answer" = "0" ] && { echo "Отменено."; return 0; }
  pick=""
  for n in $answer; do
    if [ "$n" = "all" ]; then pick="all"; break; fi
    if [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "$idx" ] 2>/dev/null; then
      pick="$pick $n"
    fi
  done
  [ -n "$pick" ] || { echo -e "${yellow}Ничего не выбрано.${plain}"; return 0; }

  if [ "$pick" = "all" ]; then
    i=1
    while [ "$i" -le "$idx" ]; do
      eval "deploy_install_file \"\$staging/\$DEPLOY_RESET_${i}_PATH\" \"\$DEPLOY_RESET_${i}_DEST\" 0" && reset_count=$((reset_count + 1))
      i=$((i + 1))
    done
  else
    for n in $pick; do
      eval "deploy_install_file \"\$staging/\$DEPLOY_RESET_${n}_PATH\" \"\$DEPLOY_RESET_${n}_DEST\" 0" && reset_count=$((reset_count + 1))
    done
  fi
  echo -e "${green}Восстановлено файлов к эталону: $reset_count.${plain}"
  if type z2r_service_action >/dev/null 2>&1; then
    z2r_service_action restart || true
    echo -e "${green}zapret2 перезапущен (листы перечитаются).${plain}"
  else
    echo -e "${yellow}Перезапустите zapret2, чтобы листы перечитались.${plain}"
  fi
}

# Переменные для шапки главного меню: даты zator/webui и уведомление об обновлении.
deploy_menu_header() {
  MENU_ZATOR_DATE="$(deploy_version_field ZATOR_DATE)"
  MENU_WEBUI_DATE="$(deploy_version_field WEBUI_DATE)"
  MENU_ZATOR_VERSION="$(deploy_version_field ZATOR_VERSION)"
  MENU_DEPLOY_TRACKING="$(deploy_version_field TRACKING)"
  [ -n "$MENU_ZATOR_DATE" ] || MENU_ZATOR_DATE="неизвестно"
  [ -n "$MENU_WEBUI_DATE" ] || MENU_WEBUI_DATE="неизвестно"
  [ -n "$MENU_DEPLOY_TRACKING" ] || MENU_DEPLOY_TRACKING="latest"
  # без установленной панели ничего про неё не пишем: поля WEBUI_* в
  # version.env приходят из общей сборки даже для core-варианта
  MENU_WEBUI_PART=""
  local has_webui=0 what=""
  if [ -e "$ZATOR_ROOT/webui/run-webui.sh" ]; then
    has_webui=1
    MENU_WEBUI_PART=", Web-панель от: ${plain}${MENU_WEBUI_DATE}${yellow}"
  fi
  MENU_DEPLOY_NOTICE=""
  MENU_DEPLOY_SOURCE=""
  local mirror
  mirror="$(deploy_env_get "$(deploy_sources_file)" RELEASES_MIRROR)"
  if [ -n "$mirror" ]; then
    MENU_DEPLOY_SOURCE=", источник: ${plain}зеркало $(printf '%s' "$mirror" | sed 's#^[a-z]*://##; s#/.*##')${yellow}"
  fi
  local zsha wsha lz lw
  zsha="$(deploy_version_field ZATOR_SHA)"
  wsha="$(deploy_version_field WEBUI_SHA)"
  lz="$(deploy_latest_field LATEST_ZATOR_SHA)"
  lw="$(deploy_latest_field LATEST_WEBUI_SHA)"
  if [ -n "$lz" ] && [ -n "$zsha" ] && [ "$zsha" != "$lz" ]; then
    what="zator от $(deploy_latest_field LATEST_ZATOR_DATE)"
  fi
  if [ "$has_webui" = 1 ] && [ -n "$lw" ] && [ -n "$wsha" ] && [ "$wsha" != "$lw" ]; then
    [ -n "$what" ] && what="$what, "
    what="${what}Web-панель от $(deploy_latest_field LATEST_WEBUI_DATE)"
  fi
  if [ -n "$what" ]; then
    if [ "$MENU_DEPLOY_TRACKING" != "latest" ]; then
      MENU_DEPLOY_NOTICE="${yellow}Закреплена версия ${plain}${MENU_DEPLOY_TRACKING}${yellow}, доступен latest: ${plain}${what}${yellow} (п.2 снимет закрепление)
"
    else
      MENU_DEPLOY_NOTICE="${red}⬆ Доступно обновление: ${what} — п.5${yellow}
"
    fi
  fi
  if type config_update_pending >/dev/null 2>&1 && config_update_pending; then
    local cfg_date
    cfg_date="$(config_default_last_modified)"
    cfg_date="${cfg_date%% *}"
    MENU_DEPLOY_NOTICE="${MENU_DEPLOY_NOTICE}${Bred}${Fplain}⬆ Есть новый конфиг от ${cfg_date}. Для применения: п.5 -> п.7${plain}
"
  fi
  return 0
}

deploy_update_menu() {
  DEPLOY_WANT_REINSTALL=0
  unset ZAPRET2_ARCHIVE_DIR ZAPRET2_VERSION
  local answer ans tag variant ver tar_file file_num i found rel_num webui_answer pin_answer
  while true; do
    clear -x
    echo -e "${Fcyan}============ Обновление zator и zapret2 ============${plain}"
    deploy_menu_header
    echo -e "zator от: ${green}${MENU_ZATOR_DATE}${yellow}${MENU_WEBUI_PART}, режим: ${plain}${MENU_DEPLOY_TRACKING}${yellow}${MENU_DEPLOY_SOURCE}"
    echo ""
    submenu_item 1 "Проверить обновления (даты zator/webui: локально vs сервер)"
    submenu_item 2 "Обновить zator (код, листы, lua; конфиг применится к живому, рестарт zapret2)"
    submenu_item 3 "Обновить только Web-панель"
    submenu_item 4 "Выбрать номерной релиз (список с датами; установка закрепляет версию)"
    submenu_item 5 "Установить из локального tar.gz (по умолчанию ищется в /tmp)"
    submenu_item 6 "Обновить/переустановить zapret2"
    submenu_item 7 "Обновить конфиг, стратегии, lua и листы"
    submenu_item 8 "Сбросить пользовательские файлы к эталону (netrogat и др.)"
    submenu_item 9 "Проверить целостность установки"
    submenu_item 10 "Источник обновлений (зеркало или стандартный GitHub)"
    submenu_item 0 "Назад в главное меню"
    echo ""
    read -re -p "" answer
    case "$answer" in
      1)
        deploy_check_latest || true
        pause_enter
        ;;
      2)
        if ! deploy_check_latest; then
          pause_enter
          continue
        fi
        variant="$(deploy_pick_variant)"
        if [ "$DEPLOY_UPDATE_ZATOR" = "1" ]; then
          if [ "$(deploy_version_field TRACKING)" != "latest" ]; then
            echo -e "${yellow}Закреплена версия $(deploy_version_field TRACKING); обновление до latest снимет закрепление.${plain}"
            read -re -p "1 - продолжить, 0 - отмена: " pin_answer
            if [ "$pin_answer" != "1" ]; then
              echo -e "${yellow}Отменено.${plain}"
              pause_enter
              continue
            fi
          fi
          deploy_from_tar "$(deploy_releases_base)/latest/zator-${variant}.tar.gz" "$variant" latest || true
        elif [ "$DEPLOY_UPDATE_WEBUI" = "1" ]; then
          echo -e "${green}Ядро zator актуально, есть обновление Web-панели — п.3.${plain}"
        else
          echo -e "${green}Ядро zator актуально.${plain}"
        fi
        pause_enter
        ;;
      3)
        if [ ! -e "$ZATOR_ROOT/webui/run-webui.sh" ]; then
          echo -e "${yellow}Web-панель не установлена (п.14 главного меню).${plain}"
        elif deploy_check_latest && [ "$DEPLOY_UPDATE_WEBUI" = "1" ]; then
          deploy_from_tar "$(deploy_releases_base)/latest/zator-webui.tar.gz" webui latest || true
        else
          echo -e "${green}Web-панель актуальна.${plain}"
        fi
        pause_enter
        ;;
      4)
        echo -e "${yellow}Релизы:${plain}"
        if ! deploy_list_releases; then
          pause_enter
          continue
        fi
        read -re -p "Номер релиза (0 - отмена): " rel_num
        if [ "$rel_num" = "0" ] || ! ui_is_number_in_range "$rel_num" 1 99; then
          echo -e "${yellow}Отменено.${plain}"
          pause_enter
          continue
        fi
        tag="$(sed -n "${rel_num}p" "$DEPLOY_RELEASES_LIST" | awk '{print $2}')"
        if [ -z "$tag" ]; then
          echo -e "${red}Релиз не найден.${plain}"
          pause_enter
          continue
        fi
        variant="$(deploy_pick_variant)"
        if deploy_from_tar "$(deploy_releases_base)/${tag}/zator-${variant}.tar.gz" "$variant" "$tag"; then
          echo -e "${yellow}Версия закреплена ($tag): автообновление лаунчера выключено, обновления вручную (п.2/п.4).${plain}"
        fi
        pause_enter
        ;;
      5)
        i=1
        found=""
        for tar_file in /tmp/*.tar.gz; do
          [ -f "$tar_file" ] || continue
          found="$found
$i. $tar_file"
          eval "DEPLOY_LOCAL_TAR_$i=\"\$tar_file\""
          i=$((i + 1))
        done
        if [ -z "$found" ]; then
          echo -e "${yellow}В /tmp нет tar.gz-файлов. Положите архив туда и повторите.${plain}"
          pause_enter
          continue
        fi
        echo -e "${yellow}Файлы:${plain}$found"
        read -re -p "Номер файла (0 - отмена): " file_num
        if [ "$file_num" != "0" ] && ui_is_number_in_range "$file_num" 1 $((i - 1)); then
          eval "tar_file=\"\$DEPLOY_LOCAL_TAR_$file_num\""
          if deploy_from_tar "$tar_file"; then
            read -re -p $'\033[33mЗакрепить установленную версию (выключить автообновление лаунчера)? 1 - Да, Enter - нет (следить за latest)\033[0m\n' pin_answer
            if [ "$pin_answer" = "1" ]; then
              ver="$(deploy_version_field ZATOR_VERSION)"
              sed -i "s/^TRACKING=.*/TRACKING=\"${ver:-local}\"/" "$DEPLOY_VERSION_FILE"
              echo -e "${yellow}Версия закреплена: автообновление лаунчера выключено.${plain}"
            fi
          fi
        fi
        pause_enter
        ;;
      6)
        echo -e "${yellow}Источник zapret2:${plain}"
        echo -e "  ${Fcyan}1${plain} — скачать с GitHub (выбор версии)"
        echo -e "  ${Fcyan}2${plain} — локальный архив из /tmp"
        echo -e "  ${Fyellow}0${plain} — отмена"
        read -re -p "" ans
        case "$ans" in
          1)
            echo -e "${yellow}Вы уверены, что хотите переустановить/обновить zapret2?${plain}"
            echo -e "${yellow}5 - Да, Enter/0 - Нет (вернуться в меню)${plain}"
            read -re -p "" ans
            if [ "$ans" = "5" ] || [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
              DEPLOY_WANT_REINSTALL=1
              return 0
            fi
            ;;
          2)
            deploy_local_zapret2_pick || true
            if [ "$DEPLOY_WANT_REINSTALL" = 1 ]; then
              return 0
            fi
            ;;
        esac
        ;;
      7)
        deploy_transition_menu
        ;;
      8)
        deploy_reset_user_files || true
        pause_enter
        ;;
      9)
        deploy_integrity_check || true
        pause_enter
        ;;
      10)
        deploy_sources_menu
        ;;
      0|"")
        return 0
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

deploy_sources_menu() {
  local answer url mirror
  while true; do
    clear -x
    echo -e "${Fcyan}===== Источник обновлений =====${plain}"
    mirror="$(deploy_env_get "$(deploy_sources_file)" RELEASES_MIRROR)"
    if [ -n "$mirror" ]; then
      echo -e "Сейчас: ${green}зеркало ${plain}${mirror}${yellow}"
    else
      echo -e "Сейчас: ${green}стандартный (GitHub)${plain}"
    fi
    echo -e "${yellow}Зеркало — ваш сервер с тем же лэйаутом релизов: <base>/latest/latest.json и <base>/<тег>/zator-<вариант>.tar.gz${plain}"
    echo ""
    submenu_item 1 "Указать зеркало (URL)"
    submenu_item 2 "Сбросить на стандартный (GitHub)"
    submenu_item 0 "Назад"
    echo ""
    read -re -p "" answer
    case "$answer" in
      1)
        read -re -p "Базовый URL зеркала (0 - отмена): " url
        case "$url" in
          0|"") ;;
          http://*|https://*)
            if printf '%s' "$url" | grep -q '[^A-Za-z0-9:/.?&=%~_-]'; then
              echo -e "${red}URL содержит недопустимые символы.${plain}"
            else
              url="${url%/}"
              mkdir -p "$DEPLOY_CACHE_DIR"
              printf 'RELEASES_MIRROR="%s"\n' "$url" > "$(deploy_sources_file)"
              echo -e "${green}Зеркало сохранено: $url${plain}"
              deploy_check_latest || true
            fi
            ;;
          *)
            echo -e "${red}URL должен начинаться с http:// или https://${plain}"
            ;;
        esac
        pause_enter
        ;;
      2)
        rm -f "$(deploy_sources_file)"
        echo -e "${green}Сброшено на стандартный источник (GitHub).${plain}"
        pause_enter
        ;;
      0|"")
        return 0
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

# Механизм перехода п.7: как обновлять конфиг/стратегии/lua/листы.
deploy_transition_menu() {
  local answer
  while true; do
    clear -x
    echo -e "${Fcyan}===== Обновление конфига, стратегий, lua и листов =====${plain}"
    echo -e "${yellow}Пользовательские файлы (netrogat.txt, TCP_Custom.txt, substrings-листы, custom_tls.bin) не перезаписываются молча.${plain}"
    echo ""
    submenu_item 1 "Применить установленный config.default (без скачивания)"
    submenu_item 2 "Перекачать релиз и применить (обновит и листы, lua)"
    submenu_item 3 "Полный сброс листов и config до эталона (прежнее поведение п.5)"
    submenu_item 0 "Назад"
    echo ""
    read -re -p "" answer
    case "$answer" in
      1)
        deploy_apply_installed_config || true
        pause_enter
        ;;
      2)
        deploy_from_tar "$(deploy_releases_base)/latest/zator-$(deploy_pick_variant).tar.gz" "$(deploy_pick_variant)" "" || true
        pause_enter
        ;;
      3)
        if type menu_action_update_config_reset >/dev/null 2>&1; then
          backup_helper_ask_and_create
          menu_action_update_config_reset || true
          backup_update_offer_restore || true
        else
          echo -e "${red}Полный сброс доступен только из меню z2r.${plain}"
        fi
        pause_enter
        ;;
      0|"")
        return 0
        ;;
      *)
        ui_invalid_input
        ;;
    esac
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    from-tar)
      shift
      deploy_from_tar "$@"
      ;;
    check)
      deploy_check_latest
      ;;
    *)
      echo "использование: deploy.sh from-tar <файл|url> [variant] [tag] | check" >&2
      exit 2
      ;;
  esac
fi
