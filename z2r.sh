#!/bin/bash

set -e

#Переменная содержащая версию на случай невозможности получить информацию о lastest с github
DEFAULT_VER="0.8.2"

#Чтобы удобнее красить текст
plain='\033[0m'
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
pink='\033[0;35m'
cyan='\033[0;36m'
gray='\033[0;90m'
Fplain='\033[1;37m'
Fred='\033[1;31m'
Fgreen='\033[1;32m'
Fyellow='\033[1;33m'
Fblue='\033[1;34m'
Fpink='\033[1;35m'
Fcyan='\033[1;36m'
Fblack='\033[1;30m'
Bplain='\033[47m'
Bred='\033[41m'
Bgreen='\033[42m'
Byellow='\033[43m'
Bblue='\033[44m'
Bpink='\033[45m'
Bcyan='\033[46m'


z2r_github_commit_date() {
  local path="$1" timeout="${2:-10}"
  [ "${Z2R_OFFLINE:-0}" != "1" ] || return 0
  curl -s --max-time "$timeout" "https://api.github.com/repos/AloofLibra/zator/commits?path=${path}&per_page=1" \
    | grep '"date"' | head -n1 | cut -d'"' -f4
}

Z2R_BRANCH="${Z2R_BRANCH:-zator}"
Z2R_PROJECT_RAW_BASE="${Z2R_PROJECT_RAW_BASE:-https://raw.githubusercontent.com/AloofLibra/zator/${Z2R_BRANCH}}"
Z2R_PROJECT_MIRROR_BASE="${Z2R_PROJECT_MIRROR_BASE:-https://git.px.rkn.quest/AloofLibra/plain}"
Z2R_INSTALLER_URL="${Z2R_INSTALLER_URL:-${Z2R_PROJECT_RAW_BASE}/z2r.sh}"
ZAPRET2_UPSTREAM_RAW_BASE="${ZAPRET2_UPSTREAM_RAW_BASE:-https://raw.githubusercontent.com/bol-van/zapret2/master}"
ZAPRET2_UPSTREAM_MIRROR_BASE="${ZAPRET2_UPSTREAM_MIRROR_BASE:-https://git.px.rkn.quest/zapret2/plain}"
ZAPRET2_RELEASE_BASE="${ZAPRET2_RELEASE_BASE:-https://github.com/bol-van/zapret2/releases/download}"
ZAPRET2_RELEASE_MIRROR_BASE="${ZAPRET2_RELEASE_MIRROR_BASE:-}"
ZAPRET2_YANDEX_0952="${ZAPRET2_YANDEX_0952:-https://disk.yandex.ru/d/M26CLc7XCEV_og}"
ZAPRET2_YANDEX_0952_OPENWRT="${ZAPRET2_YANDEX_0952_OPENWRT:-https://disk.yandex.ru/d/ER1R2TNw8f7KYA}"
Z2R_LIB_FILES="ui.sh provider.sh telemetry.sh recommendations.sh netcheck.sh premium.sh strategies.sh submenus.sh actions.sh config.sh orchestra_state.sh"

# Два корня установки:
#   ZAPRET2_ROOT — zapret2-native (бинарники, init.d, install_*.sh, config, config.default),
#                  пересоздаётся при обновлении zapret2.
#   ZATOR_ROOT   — zator-контент (z2r_lib, lua, webui, extra_strats, lists, files/fake),
#                  НЕ затрагивается обновлением zapret2.
# Оба переопределяемы через env (как URL-переменные выше).
ZAPRET2_ROOT="${ZAPRET2_ROOT:-/opt/zapret2}"
ZATOR_ROOT="${ZATOR_ROOT:-/opt/zator}"

z2r_mirror_url() {
  printf '%s/%s?h=%s' "$Z2R_PROJECT_MIRROR_BASE" "$1" "$Z2R_BRANCH"
}

z2r_fetch_url_to_file() {
  local dest="$1"
  local url="$2"
  local attempt

  # До 3 попыток с таймаутом на соединение
  for attempt in 1 2 3; do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL --connect-timeout 10 -o "$dest" "$url"; then
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -q -T 10 -O "$dest" "$url"; then
        return 0
      fi
    else
      return 127
    fi
    rm -f "$dest"
    if [ "$attempt" -lt 3 ]; then
      sleep 2
    fi
  done
  return 1
}

z2r_download_project_file() {
  local dest="$1"
  local rel="$2"
  local tmp="${dest}.tmp.$$"
  local primary="${Z2R_PROJECT_RAW_BASE}/${rel}"

  if [ -n "${Z2R_PROJECT_DIR:-}" ]; then
    case "$rel" in
      /*|../*|*/../*|*/..) return 1 ;;
    esac
    if [ -f "$Z2R_PROJECT_DIR/$rel" ]; then
      mkdir -p "$(dirname "$dest")"
      cp -f "$Z2R_PROJECT_DIR/$rel" "$tmp" || return 1
      mv -f "$tmp" "$dest"
      return 0
    fi
    if [ "${Z2R_OFFLINE:-0}" = "1" ]; then
      echo -e "${red}В архиве отсутствует файл проекта: $rel${plain}" >&2
      return 1
    fi
  fi

  mirror="$(z2r_mirror_url "$rel")"
  mkdir -p "$(dirname "$dest")"
  rm -f "$tmp"
  if z2r_fetch_url_to_file "$tmp" "$primary"; then
    mv -f "$tmp" "$dest"
    return 0
  fi
  if [ -n "${Z2R_PROJECT_MIRROR_BASE:-}" ]; then
    echo -e "${yellow}GitHub недоступен для $rel. Пробую зеркало.${plain}" >&2
    rm -f "$tmp"
    if z2r_fetch_url_to_file "$tmp" "$mirror"; then
      mv -f "$tmp" "$dest"
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

z2r_download_project_stdout() {
  local rel="$1"
  local tmp="/tmp/z2r_download_$$"

  if z2r_download_project_file "$tmp" "$rel"; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

z2r_upstream_mirror_url() {
  printf '%s/%s?h=master' "$ZAPRET2_UPSTREAM_MIRROR_BASE" "$1"
}

z2r_download_upstream_file() {
  local dest="$1"
  local rel="$2"
  local tmp="${dest}.tmp.$$"
  local primary="${ZAPRET2_UPSTREAM_RAW_BASE}/${rel}"
  local mirror

  if [ "${Z2R_OFFLINE:-0}" = "1" ]; then
    echo -e "${red}В установленном zapret2 отсутствует upstream-файл: $rel${plain}" >&2
    return 1
  fi

  mirror="$(z2r_upstream_mirror_url "$rel")"
  mkdir -p "$(dirname "$dest")"
  rm -f "$tmp"
  if z2r_fetch_url_to_file "$tmp" "$primary"; then
    mv -f "$tmp" "$dest"
    return 0
  fi
  echo -e "${yellow}GitHub недоступен для zapret2/$rel. Пробую зеркало.${plain}" >&2
  rm -f "$tmp"
  if z2r_fetch_url_to_file "$tmp" "$mirror"; then
    mv -f "$tmp" "$dest"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

z2r_yandex_public_for_release() {
  local tarfile="$2"

  case "$tarfile" in
    *-openwrt-embedded.tar.gz)
      printf '%s' "$ZAPRET2_YANDEX_0952_OPENWRT"
      ;;
    *.tar.gz)
      printf '%s' "$ZAPRET2_YANDEX_0952"
      ;;
  esac
}

z2r_download_yandex_public_file() {
  local dest="$1"
  local public_url="$2"
  local api_tmp="/tmp/z2r_yadisk_$$.json"
  local href

  rm -f "$api_tmp" "$dest"
  if ! z2r_fetch_url_to_file "$api_tmp" "https://cloud-api.yandex.net/v1/disk/public/resources/download?public_key=$public_url"; then
    rm -f "$api_tmp"
    return 1
  fi
  href="$(sed -n 's/.*"href":"\([^"]*\)".*/\1/p' "$api_tmp" | sed 's/\\u0026/\&/g; s#\\/#/#g' | head -n1)"
  rm -f "$api_tmp"
  [ -n "$href" ] || return 1

  z2r_fetch_url_to_file "$dest" "$href"
}

z2r_download_zapret2_release() {
  local dest="$1"
  local ver="$2"
  local tarfile="$3"
  local primary="${ZAPRET2_RELEASE_BASE}/v${ver}/${tarfile}"
  local mirror=""
  local yadisk=""

  rm -f "$dest"
  if z2r_fetch_url_to_file "$dest" "$primary"; then
    return 0
  fi
  rm -f "$dest"

  if [ -n "$ZAPRET2_RELEASE_MIRROR_BASE" ]; then
    mirror="${ZAPRET2_RELEASE_MIRROR_BASE%/}/v${ver}/${tarfile}"
    echo -e "${yellow}GitHub недоступен для $tarfile. Пробую зеркало zapret2 release.${plain}" >&2
    if z2r_fetch_url_to_file "$dest" "$mirror"; then
      return 0
    fi
    rm -f "$dest"
  fi

  yadisk="$(z2r_yandex_public_for_release "$ver" "$tarfile")"
  if [ -n "$yadisk" ]; then
    echo -e "${yellow}Пробую Яндекс.Диск для $tarfile.${plain}" >&2
    if z2r_download_yandex_public_file "$dest" "$yadisk"; then
      return 0
    fi
    rm -f "$dest"
  fi

  return 1
}

z2r_exec_external_installer() {
  local mirror
  local tmp="/tmp/z2r_installer_$$"

  if [ "${Z2R_OFFLINE:-0}" = "1" ]; then
    echo "Ошибка: в архиве отсутствуют дочерние библиотеки z2r."
    exit 1
  fi

  mirror="$(z2r_mirror_url "z2r")"
  if z2r_fetch_url_to_file "$tmp" "$Z2R_INSTALLER_URL" || z2r_fetch_url_to_file "$tmp" "$mirror"; then
    exec sh "$tmp" "$@"
  fi
  rm -f "$tmp"
  echo "Ошибка: не удалось загрузить внешний z2r."
  exit 1
}

#___Проверка на наличие необходимых библиотек___#

#Определяем путь скрипта, подгружаем функции
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

# --- Миграция zator-контента из $ZAPRET2_ROOT в $ZATOR_ROOT ---
# Исторически весь zator-контент (z2r_lib, lua, webui, extra_strats, lists, files/fake)
# жил внутри /opt/zapret2 и уничтожался при каждом обновлении zapret2 (rm -rf).
# Теперь он переносится в отдельный каталог $ZATOR_ROOT и более не трогается
# при обновлении zapret2. Функция не имеет зависимостей от lib/ и безопасна
# при set -e. Идемпотентна: при повторном запуске no-op.
z2r_migrate_to_zator() {
  mkdir -p "$ZATOR_ROOT" 2>/dev/null || return 0
  local sub src dst f

  for sub in z2r_lib webui; do
    src="$ZAPRET2_ROOT/$sub"
    dst="$ZATOR_ROOT/$sub"
    [ -e "$src" ] || continue
    if [ ! -e "$dst" ]; then
      mv "$src" "$dst" 2>/dev/null || true
    else
      rm -rf "$src" 2>/dev/null || true
    fi
  done

  # Данные пользователя: если новый каталог уже создан (лаунчером/обновлением),
  # содержимое старого переносим поверх (кэш оркестра с локами), затем удаляем.
  for sub in extra_strats lists; do
    src="$ZAPRET2_ROOT/$sub"
    dst="$ZATOR_ROOT/$sub"
    [ -e "$src" ] || continue
    if [ ! -e "$dst" ]; then
      mv "$src" "$dst" 2>/dev/null || true
    else
      cp -a "$src/." "$dst/" 2>/dev/null || true
      rm -rf "$src" 2>/dev/null || true
    fi
  done

  # /opt/zapret2/lua — СМЕШАННЫЙ каталог: вместе с нашими модулями там лежат
  # lua-библиотеки самого zapret2 (zapret-lib.lua, zapret-antidpi.lua,
  # zapret-auto.lua), на которые ссылается конфиг. Переносим только наши файлы,
  # каталог и чужие файлы не трогаем.
  for f in locked.lua rst-guard.lua strategy-lock-manager.lua combined-detector.lua silent-drop-detector.lua strategy-validator.sh; do
    src="$ZAPRET2_ROOT/lua/$f"
    [ -f "$src" ] || continue
    if [ ! -e "$ZATOR_ROOT/lua/$f" ]; then
      mkdir -p "$ZATOR_ROOT/lua" 2>/dev/null
      mv "$src" "$ZATOR_ROOT/lua/$f" 2>/dev/null || true
    else
      rm -f "$src" 2>/dev/null || true
    fi
  done

  # Fake-файлы: переносим только files/fake, остальное в files/ — zapret2.
  src="$ZAPRET2_ROOT/files/fake"
  if [ -e "$src" ] && [ ! -e "$ZATOR_ROOT/files/fake" ]; then
    mkdir -p "$ZATOR_ROOT/files" 2>/dev/null
    mv "$src" "$ZATOR_ROOT/files/fake" 2>/dev/null || true
  fi

  # Пути в живом config/config.default: заменяем ТОЛЬКО ссылки на наши файлы
  # и поддеревья. Ссылки вида /opt/zapret2/lua/zapret-*.lua (файлы самого
  # zapret2) не трогаем. Без grep-предфильтра: BRE-альтернация "\|" не
  # поддерживается BusyBox grep; sed с отсутствующими совпадениями безопасен.
  local cfg
  for cfg in "$ZAPRET2_ROOT/config" "$ZAPRET2_ROOT/config.default"; do
    [ -f "$cfg" ] || continue
    sed -i \
      -e 's#/opt/zapret2/lua/locked.lua#/opt/zator/lua/locked.lua#g' \
      -e 's#/opt/zapret2/lua/rst-guard.lua#/opt/zator/lua/rst-guard.lua#g' \
      -e 's#/opt/zapret2/lua/strategy-lock-manager.lua#/opt/zator/lua/strategy-lock-manager.lua#g' \
      -e 's#/opt/zapret2/lua/combined-detector.lua#/opt/zator/lua/combined-detector.lua#g' \
      -e 's#/opt/zapret2/lua/silent-drop-detector.lua#/opt/zator/lua/silent-drop-detector.lua#g' \
      -e 's#/opt/zapret2/lua/strategy-validator.sh#/opt/zator/lua/strategy-validator.sh#g' \
      -e 's#/opt/zapret2/files/fake#/opt/zator/files/fake#g' \
      -e 's#/opt/zapret2/extra_strats#/opt/zator/extra_strats#g' \
      -e 's#/opt/zapret2/lists#/opt/zator/lists#g' \
      "$cfg" 2>/dev/null || true
  done
  return 0
}

z2r_migrate_to_zator

# Проверяем наличие всех нужных lib-файлов, иначе запускаем внешний скрипт
missing_libs=0
# Предпочитаем $ZATOR_ROOT/z2r_lib (новое расположение), fallback на
# $ZAPRET2_ROOT/z2r_lib (legacy/сразу после первой установки внешним лаунчером).
if [ -f "$ZATOR_ROOT/z2r_lib/orchestra_state.sh" ]; then
  LIB_DIR="$ZATOR_ROOT/z2r_lib"
else
  LIB_DIR="$ZAPRET2_ROOT/z2r_lib"
fi
for lib in $Z2R_LIB_FILES; do
  if [ ! -f "$LIB_DIR/$lib" ]; then
    missing_libs=1
    break
  fi
done

if [ "$missing_libs" -ne 0 ]; then
  echo "Не найдены нужные файлы в $LIB_DIR. Запускаю внешний z2r..."
  z2r_exec_external_installer "$@"
fi

#___Сначала идут анонсы функций____

# UI helpers (пауза/печать пунктов меню/совместимость старого кода)
# Функции: pause_enter, submenu_item, exit_to_menu
source "$LIB_DIR/ui.sh"

# Определение провайдера/города + ручная установка/сброс кэша
# Функции: provider_init_once, provider_force_redetect, provider_set_manual_menu
# (внутр.: _detect_api_simple)
source "$LIB_DIR/provider.sh"

# Телеметрия (вкл/выкл один раз + отправка статистики в Google Forms)
# Функции: init_telemetry, send_stats
source "$LIB_DIR/telemetry.sh"

# Общий API для чтения и правки $ZAPRET2_ROOT/config
source "$LIB_DIR/config.sh"

# Общий API ручных локов стратегий
source "$LIB_DIR/orchestra_state.sh"

# База подсказок по стратегиям (скачивание + вывод подсказки по провайдеру)
# Функции: update_recommendations, show_hint
source "$LIB_DIR/recommendations.sh"

# Проверка доступности ресурсов/сети (TLS 1.2/1.3) + получение домена кластера youtube (googlevideo)
# Функции: get_yt_cluster_domain, check_access, check_access_list
source "$LIB_DIR/netcheck.sh"

# “Premium” пункты 777/999 и их вспомогательные эффекты (рандом, спиннер, титулы)
# Функции: rand_from_list, spinner_for_seconds, premium_get_or_set_title, zefeer_premium_777, zefeer_space_999
source "$LIB_DIR/premium.sh"

# Логика стратегий: статус, lock-файлы, быстрый подбор
# Функции: get_current_strategies_info, orch_profile_try, Strats_Tryer
source "$LIB_DIR/strategies.sh"

# Подменю (UI-обвязка стратегий + доп. меню управления: FLOWOFFLOAD, TCP443, провайдер)
# Функции: strategies_submenu, flowoffload_submenu, fwtype_submenu, tcp443_submenu, provider_submenu, beginner_guide_menu
source "$LIB_DIR/submenus.sh"

# Действия меню (бэкапы/сбросы/переключатели)
# Функции: backup_strats, menu_action_update_config_reset,
#          fwtype_apply, menu_action_toggle_udp_range, menu_action_set_tls_blob
source "$LIB_DIR/actions.sh"

keenetic_policy_ndmc_is_supported() {
  local output
  [ "$hardware" = "keenetic" ] || return 1
  command -v ndmc >/dev/null 2>&1 || return 1
  output="$(ndmc -c "show ip policy" 2>/dev/null)" || return 1
  [ -n "$output" ] || return 1
  case "$output" in
    *"ndmc: system failed ["*|*"Cli::Main: failed to initialize."*) return 1 ;;
  esac
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
  elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
  elif [[ -f /opt/etc/entware_release ]]; then
    release="entware"
  elif [[ -f /etc/entware_release ]]; then
    release="entware"
  else
    echo "Не удалось определить ОС. Прекращение работы скрипта." >&2
    exit 1
  fi

  if [[ "$release" == "entware" ]]; then
    if [ -d /jffs ] || uname -a | grep -qi "Merlin"; then
      hardware="merlin"
    elif grep -Eqi "netcraze|keenetic" /proc/version; then
      hardware="keenetic"
    else
      echo -e "${yellow}Железо не определено. Будем считать что это Keenetic. Если будут проблемы - пишите в саппорт.${plain}"
      hardware="keenetic"
    fi
  fi

  #По просьбе наших слушателей) Теперь netcraze официально детектится скриптом не как keenetic, а отдельно)
  if grep -q "netcraze" "/bin/ndmc" 2>/dev/null; then
    echo "OS: $release Netcraze"
  else
    echo "OS: $release $hardware"
  fi

  if [[ "$release" == "ubuntu" || "$release" == "debian" || "$release" == "endeavouros" || "$release" == "arch" ]]; then
    OSystem="VPS"
  elif [[ "$release" == "openwrt" || "$release" == "immortalwrt" || "$release" == "asuswrt" || "$release" == "x-wrt" || "$release" == "kwrt" || "$release" == "istoreos" ]]; then
    OSystem="WRT"
  elif [[ "$release" == "entware" || "$hardware" = "keenetic" ]]; then
    OSystem="entware"
  else
    read -re -p $'\033[31mДля этой ОС нет подходящей функции. Или ОС определение выполнено некорректно.\033[33m Рекомендуется обратиться в чат поддержки
Enter - выход
1 - Плюнуть и продолжить как OpenWRT
2 - Плюнуть и продолжить как entware
3 - Плюнуть и продолжить как VPS\033[0m\n' os_answer
    case "$os_answer" in
    "1")
      OSystem="WRT"
    ;;
    "2")
      OSystem="entware"
    ;;
    "3")
      OSystem="VPS"
    ;;
    *)
      echo "Выбран выход"
      exit 0
    ;;
    esac
  fi
}


set_zapret2_init() {
  if [ "$OSystem" = "WRT" ] && [ -f "$ZAPRET2_ROOT/init.d/openwrt/zapret2" ]; then
    ZAPRET2_INIT="$ZAPRET2_ROOT/init.d/openwrt/zapret2"
  else
    ZAPRET2_INIT="$ZAPRET2_ROOT/init.d/sysv/zapret2"
  fi
  export ZAPRET2_INIT
}

z2r_archive_preflight() {
  local required_archive

  [ "${Z2R_OFFLINE:-0}" = "1" ] || return 0
  [ -n "${Z2R_PROJECT_DIR:-}" ] && [ -d "$Z2R_PROJECT_DIR" ] || {
    echo -e "${red}Не найден payload проекта из установочного архива.${plain}"
    return 1
  }
  [ -n "${ZAPRET2_ARCHIVE_DIR:-}" ] && [ -d "$ZAPRET2_ARCHIVE_DIR" ] || {
    echo -e "${red}Не найден каталог vendor из установочного архива.${plain}"
    return 1
  }
  if [ "$OSystem" = "WRT" ]; then
    required_archive="$ZAPRET2_ARCHIVE_DIR/zapret2-v$ZAPRET2_VERSION-openwrt-embedded.tar.gz"
  else
    required_archive="$ZAPRET2_ARCHIVE_DIR/zapret2-v$ZAPRET2_VERSION.tar.gz"
  fi
  [ -f "$required_archive" ] || {
    echo -e "${red}Для этой платформы в bundle отсутствует $(basename "$required_archive").${plain}"
    return 1
  }
  if ! z2r_validate_tar_archive "$required_archive"; then
    echo -e "${red}Архив $(basename "$required_archive") повреждён или содержит небезопасные пути.${plain}"
    return 1
  fi
  grep -Fx "zapret2-v$ZAPRET2_VERSION/install_bin.sh" < <(tar -tzf "$required_archive") >/dev/null || {
    echo -e "${red}В $(basename "$required_archive") отсутствует install_bin.sh.${plain}"
    return 1
  }
  grep -Fx "zapret2-v$ZAPRET2_VERSION/install_easy.sh" < <(tar -tzf "$required_archive") >/dev/null || {
    echo -e "${red}В $(basename "$required_archive") отсутствует install_easy.sh.${plain}"
    return 1
  }
}

cleanup_zapret2_init_dirs() {
  local init_dir="$ZAPRET2_ROOT/init.d"

  [ -d "$init_dir" ] || return 0

  if [ "$OSystem" = "WRT" ]; then
    rm -rf "$init_dir/sysv"
  else
    rm -rf "$init_dir/openwrt"
  fi
}

ORCH_DIR="$ZATOR_ROOT/extra_strats/cache/orchestra"
ORCH_LUA_LOCKED="$ZATOR_ROOT/lua/locked.lua"
RST_GUARD_LUA="$ZATOR_ROOT/lua/rst-guard.lua"
CIRCULAR_DETECTOR_LUA="$ZATOR_ROOT/lua/combined-detector.lua"
SILENT_DROP_DETECTOR_LUA="$ZATOR_ROOT/lua/silent-drop-detector.lua"
STRATEGY_LOCK_MANAGER_LUA="$ZATOR_ROOT/lua/strategy-lock-manager.lua"
STRATEGY_VALIDATOR_WORKER="$ZATOR_ROOT/lua/strategy-validator.sh"
STRATEGY_VALIDATOR_OPENWRT_INIT="/etc/init.d/z2r-strategy-validator"
STRATEGY_VALIDATOR_ENTWARE_INIT="/opt/etc/init.d/S93z2r-strategy-validator"
STRATEGY_VALIDATOR_SYSTEMD_UNIT="/etc/systemd/system/z2r-strategy-validator.service"

locked_lua_update_from_repo() {
  local tmp="${ORCH_LUA_LOCKED}.tmp"

  mkdir -p "$ORCH_DIR" "$(dirname "$ORCH_LUA_LOCKED")"
  if ! z2r_download_project_file "$tmp" "orchestra/locked.lua"; then
    echo -e "${red}Не удалось скачать locked.lua.${plain}"
    return 1
  fi

  mv "$tmp" "$ORCH_LUA_LOCKED"
  echo -e "${green}locked.lua обновлен из репозитория.${plain}"
}

rst_guard_lua_update_from_repo() {
  local tmp="${RST_GUARD_LUA}.tmp"

  mkdir -p "$(dirname "$RST_GUARD_LUA")"
  if ! z2r_download_project_file "$tmp" "lua/rst-guard.lua"; then
    echo -e "${red}Не удалось скачать rst-guard.lua.${plain}"
    return 1
  fi

  mv "$tmp" "$RST_GUARD_LUA"
  echo -e "${green}rst-guard.lua обновлен из репозитория.${plain}"
}

circular_runtime_update_from_repo() {
  mkdir -p "$ZATOR_ROOT/lua"
  z2r_download_project_file "$CIRCULAR_DETECTOR_LUA" "lua/combined-detector.lua" || return 1
  z2r_download_project_file "$SILENT_DROP_DETECTOR_LUA" "lua/silent-drop-detector.lua" || return 1
  z2r_download_project_file "$STRATEGY_LOCK_MANAGER_LUA" "lua/strategy-lock-manager.lua" || return 1
  z2r_download_project_file "$STRATEGY_VALIDATOR_WORKER" "lua/strategy-validator.sh" || return 1
  chmod +x "$STRATEGY_VALIDATOR_WORKER"
}

# Deploy the optional client-scope helper without applying firewall changes.
client_scope_firewall_update_from_repo() {
  local dest="$ZATOR_ROOT/firewall/client-scope-iptables.sh"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$SCRIPT_DIR/firewall/client-scope-iptables.sh" ]; then
    cp -f "$SCRIPT_DIR/firewall/client-scope-iptables.sh" "$dest" || return 1
  else
    z2r_download_project_file "$dest" "firewall/client-scope-iptables.sh" || return 1
  fi
  chmod +x "$dest"
}

strategy_validator_install_service() {
  local validator_path="/opt/bin:/opt/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if ! PATH="$validator_path" command -v curl >/dev/null 2>&1; then
    echo -e "${red}Для strategy-validator нужен curl.${plain}"
    return 1
  fi

  case "$OSystem" in
    WRT)
      z2r_download_project_file "$STRATEGY_VALIDATOR_OPENWRT_INIT" "init.d/openwrt/z2r-strategy-validator" || return 1
      chmod +x "$STRATEGY_VALIDATOR_OPENWRT_INIT"
      "$STRATEGY_VALIDATOR_OPENWRT_INIT" enable 2>/dev/null || true
      "$STRATEGY_VALIDATOR_OPENWRT_INIT" restart 2>/dev/null || "$STRATEGY_VALIDATOR_OPENWRT_INIT" start 2>/dev/null || return 1
      ;;
    entware)
      z2r_download_project_file "$STRATEGY_VALIDATOR_ENTWARE_INIT" "Entware/z2r-strategy-validator" || return 1
      chmod +x "$STRATEGY_VALIDATOR_ENTWARE_INIT"
      "$STRATEGY_VALIDATOR_ENTWARE_INIT" restart 2>/dev/null || "$STRATEGY_VALIDATOR_ENTWARE_INIT" start 2>/dev/null || return 1
      ;;
    VPS)
      if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /etc/systemd/system ]; then
        echo -e "${red}Для strategy-validator на этой VPS нужен systemd.${plain}"
        return 1
      fi
      cat > "$STRATEGY_VALIDATOR_SYSTEMD_UNIT" <<'EOF'
[Unit]
Description=z2r strategy validation worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'mkdir -p /tmp/z2r-strategy-validation && user=$(/bin/sed -n "s/^WS_USER=//p" @ZAPRET2_ROOT@/config | /usr/bin/head -n1); [ -n "$user" ] || user=nobody; /bin/chown "$user" /tmp/z2r-strategy-validation && /bin/chmod 700 /tmp/z2r-strategy-validation'
ExecStart=@ZATOR_ROOT@/lua/strategy-validator.sh --daemon
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
      sed -i \
        -e "s#@ZAPRET2_ROOT@#$ZAPRET2_ROOT#g" \
        -e "s#@ZATOR_ROOT@#$ZATOR_ROOT#g" \
        "$STRATEGY_VALIDATOR_SYSTEMD_UNIT"
      systemctl daemon-reload
      systemctl enable z2r-strategy-validator.service
      systemctl restart z2r-strategy-validator.service
      ;;
  esac
}

strategy_validator_remove_service() {
  case "$OSystem" in
    WRT)
      [ -f "$STRATEGY_VALIDATOR_OPENWRT_INIT" ] || return 0
      "$STRATEGY_VALIDATOR_OPENWRT_INIT" stop 2>/dev/null || true
      "$STRATEGY_VALIDATOR_OPENWRT_INIT" disable 2>/dev/null || true
      rm -f "$STRATEGY_VALIDATOR_OPENWRT_INIT"
      ;;
    entware)
      [ -f "$STRATEGY_VALIDATOR_ENTWARE_INIT" ] || return 0
      "$STRATEGY_VALIDATOR_ENTWARE_INIT" stop 2>/dev/null || true
      rm -f "$STRATEGY_VALIDATOR_ENTWARE_INIT"
      ;;
    VPS)
      if command -v systemctl >/dev/null 2>&1 && [ -f "$STRATEGY_VALIDATOR_SYSTEMD_UNIT" ]; then
        systemctl disable --now z2r-strategy-validator.service >/dev/null 2>&1 || true
        rm -f "$STRATEGY_VALIDATOR_SYSTEMD_UNIT"
        systemctl daemon-reload >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

# Проверяем locked.lua, при отсутствии пробуем скачать из репозитория
if [ -f "$ZAPRET2_ROOT/config" ]; then
  if [ ! -s "$ORCH_LUA_LOCKED" ]; then
    echo "Не найден locked.lua. Пытаюсь скачать из репозитория..."
    locked_lua_update_from_repo || true
  fi
  if [ ! -s "$RST_GUARD_LUA" ]; then
    echo "Не найден rst-guard.lua. Пытаюсь скачать из репозитория..."
    rst_guard_lua_update_from_repo || true
  fi
  if [ ! -s "$CIRCULAR_DETECTOR_LUA" ] || [ ! -s "$SILENT_DROP_DETECTOR_LUA" ] || \
     [ ! -s "$STRATEGY_LOCK_MANAGER_LUA" ] || [ ! -s "$STRATEGY_VALIDATOR_WORKER" ]; then
    echo "Не найдены Lua-модули circular. Пытаюсь скачать из репозитория..."
    circular_runtime_update_from_repo || true
  fi
fi

_fallback_strategy_text() {
  local profile="$1" proto="$2"
  local file="$ORCH_DIR/locked.manual.tsv"
  if [ -f "$file" ]; then
    local val
    val="$(awk -F '\t' -v p="$profile" -v pr="$proto" '$1==p && $2==pr && $3 ~ /^[0-9]+$/ {print $3; exit}' "$file")"
    if [ -n "$val" ]; then
      echo "$val"
      return
    fi
  fi
  echo "не задана"
}

fallback_strategy_text() {
  _fallback_strategy_text "8" "tls"
}

fallback_http_strategy_text() {
  _fallback_strategy_text "9" "http"
}

_fallback_profile_try() {
  local profile="$1" title="$2" proto="$3" test_url="$4"
  local prev_lock_file="${ORCH_LOCK_FILE:-$ORCH_DIR/locked.tsv}"
  ORCH_LOCK_FILE="$ORCH_DIR/locked.manual.tsv"
  orch_profile_try "$profile" "$title" "$proto" "$test_url"
  ORCH_LOCK_FILE="$prev_lock_file"
}

fallback_profile_try() {
  _fallback_profile_try "8" "Профиль 8: fallback (безразборный блок)" "tls" "__RUN_CDN_TEST__"
}

fallback_http_profile_try() {
  _fallback_profile_try "9" "Профиль 9: fallback HTTP (безразборный блок)" "http" "http://deb.torproject.org/torproject.org"
}

change_user() {
   if "$ZAPRET2_ROOT/nfq2/nfqws2" --dry-run --user="nobody" 2>&1 | grep -q "queue"; then
    echo "WS_USER=nobody"
	sed -i 's/^#\(WS_USER=nobody\)/\1/' "$ZAPRET2_ROOT/config.default"
   elif "$ZAPRET2_ROOT/nfq2/nfqws2" --dry-run --user="$(head -n1 /etc/passwd | cut -d: -f1)" 2>&1 | grep -q "queue"; then
    echo "WS_USER=$(head -n1 /etc/passwd | cut -d: -f1)"
    sed -i "s/^#WS_USER=nobody$/WS_USER=$(head -n1 /etc/passwd | cut -d: -f1)/" "$ZAPRET2_ROOT/config.default"
   else
    echo -e "${yellow}WS_USER не подошёл. Скорее всего будут проблемы. Если что - пишите в саппорт${plain}"
   fi
}

ensure_nfqws2_stopped() {
  z2r_service_action stop
  sleep 1
  if pidof nfqws2 >/dev/null; then
    if command -v killall >/dev/null 2>&1; then
      killall -9 nfqws2
    else
      pkill -9 nfqws2
    fi
    sleep 1
  fi
}

blockcheck2_run_summary() {
  local blockcheck_path="$ZAPRET2_ROOT/blockcheck2.sh"
  local test_name="z4r"
  local default_target="static.rutracker.cc/templates/v1/min/4e695e8ea9cf5a1dcc7aed231b887c51.lib.min.js"
  local test_target="${Z2R_BLOCKCHECK2_DOMAINS:-$default_target}"
  local log_dir="/tmp/zapret2/cache/blockcheck2"
  local provider_file="$ZATOR_ROOT/extra_strats/cache/provider.txt"
  local provider_label="" provider_sanitized="" ts=""
  local log_file="" summary_file="" summary_public=""
  local uuid_suffix=""
  local was_running=0 rc=0
  local pid=0 start_ts=0
  local progress_file="/tmp/blockcheck2_progress_$$"

  if [ ! -x "$blockcheck_path" ]; then
    echo -e "${red}blockcheck2.sh не найден или не исполняемый: $blockcheck_path${plain}"
    return 1
  fi

  blockcheck2_prepare_z4r_test || return 1

  if pidof nfqws2 >/dev/null; then
    was_running=1
    ensure_nfqws2_stopped
    echo -e "${green}Выполнена команда остановки zapret2${plain}"
  fi

  mkdir -p "$log_dir"
  ts="$(date +%Y%m%d_%H%M%S)"
  if [ -s "$provider_file" ]; then
    provider_label="$(cat "$provider_file")"
  else
    provider_label="Unknown"
  fi
  provider_sanitized="$(echo "$provider_label" | tr -cd 'a-zA-Z0-9 ._-' | tr ' ' '_' | cut -c1-60)"
  [ -z "$provider_sanitized" ] && provider_sanitized="Unknown"

  uuid_suffix="$(blockcheck2_get_uuid)"
  log_file="$log_dir/blockcheck2_${provider_sanitized}_${ts}_${uuid_suffix}.log"
  summary_file="$log_dir/blockcheck2_${provider_sanitized}_${ts}_${uuid_suffix}.summary"
  summary_public="$ZAPRET2_ROOT/blockcheck2_summary.txt"

  echo -e "${yellow}Запускаю blockcheck2 TEST=$test_name для $test_target...${plain}"
  start_ts="$(date +%s)"
  CURL_HTTPS_GET=1 BATCH=1 TEST="$test_name" DOMAINS="$test_target" ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=1 ENABLE_HTTPS_TLS13=1 ENABLE_HTTP3=0 BC2_PROGRESS_FILE="$progress_file" ZAPRET_BASE="$ZAPRET2_ROOT" "$blockcheck_path" >"$log_file" 2>&1 &
  pid=$!
  if [ "$pid" -gt 0 ]; then
    local spin='|/-\' idx=0 pct=0 elapsed=0 elapsed_fmt="" overrun_notice=0
    local done=0 total=0 eta=0 eta_fmt=""
    while kill -0 "$pid" >/dev/null 2>&1; do
      elapsed=$(( $(date +%s) - start_ts ))
      if [ -s "$progress_file" ]; then
        read -r done total <"$progress_file"
        if [ -n "$total" ] && [ "$total" -gt 0 ]; then
          pct=$(( (done * 100) / total ))
          if [ "$done" -gt 0 ]; then
            eta=$(( (elapsed * (total - done)) / done ))
            eta_fmt="$(blockcheck2_format_elapsed "$eta")"
          else
            eta_fmt="?"
          fi
        else
          pct="$(blockcheck2_progress_percent "$elapsed")"
          eta_fmt="?"
        fi
      else
        pct="$(blockcheck2_progress_percent "$elapsed")"
        eta_fmt="?"
      fi
      elapsed_fmt="$(blockcheck2_format_elapsed "$elapsed")"
      printf "\r${yellow}blockcheck2: %3s%% %s elapsed %s ETA %s${plain}" "$pct" "${spin:$idx:1}" "$elapsed_fmt" "$eta_fmt"
      if [ "$pct" -ge 100 ] && [ "$overrun_notice" -eq 0 ]; then
        echo -e "\n${yellow}Скрипт выполняется дольше обычного. Это ожидаемо. Дождитесь завершения работы скрипта.${plain}"
        echo -e "\n${yellow}И вообще 146% - не предел${plain}"
        overrun_notice=1
      fi
      idx=$(( (idx + 1) % 4 ))
      sleep 1
    done
    wait "$pid" || rc=$?
    rm -f "$progress_file" 2>/dev/null || true
    elapsed_fmt="$(blockcheck2_format_elapsed "$(( $(date +%s) - start_ts ))")"
    printf "\r${yellow}blockcheck2: 100%% done (elapsed %s)${plain}\n" "$elapsed_fmt"
  else
    echo -e "${red}Не удалось запустить blockcheck2.${plain}"
    rc=1
  fi

  # Extract SUMMARY block only
  awk '
    /^\* SUMMARY/ {in_summary=1}
    in_summary {
      if (/^\* COMMON/ || /^Please note this SUMMARY/ || /^Understanding how strategies work/) exit
      print
    }
  ' "$log_file" > "$summary_file"

  if [ ! -s "$summary_file" ]; then
    echo -e "${red}SUMMARY не найден. Лог сохранен: $log_file${plain}"
  else
    cp "$summary_file" "$summary_public"
    echo -e "${green}SUMMARY сохранен для просмотра: $summary_public${plain}"
    echo -e "${yellow}Пожалуйста, отправьте этот файл в чат z4r: $summary_public${plain}"
    echo -e "${yellow}Нажмите Enter чтобы продолжить${plain}"
    read -r
  fi

  if [ "$was_running" -eq 1 ]; then
    z2r_service_action restart
    echo -e "${green}zapret2 восстановлен (restart)${plain}"
  fi

  return $rc
}

blockcheck2_prepare_z4r_test() {
  local test_dir="$ZAPRET2_ROOT/blockcheck2.d/z4r"
  local src_dir="$SCRIPT_DIR/blockcheck2.d/z4r"
  local file dest

  mkdir -p "$test_dir" || return 1
  for file in 10-list.sh list_https_tls12.txt list_https_tls13.txt; do
    dest="$test_dir/$file"
    if [ -f "$src_dir/$file" ]; then
      cp -f "$src_dir/$file" "$dest" || return 1
    elif ! z2r_download_project_file "$dest" "blockcheck2.d/z4r/$file" && [ ! -s "$dest" ]; then
      echo -e "${red}Не удалось установить blockcheck2.d/z4r/$file${plain}"
      return 1
    fi
  done
  chmod +x "$test_dir/10-list.sh" 2>/dev/null || true
  return 0
}

blockcheck2_progress_percent() {
  local elapsed="$1"
  local total=$((2 * 60 * 60))
  if [ "$elapsed" -le 0 ]; then
    echo 0
    return
  fi
  echo $(( (elapsed * 100) / total ))
}

blockcheck2_format_elapsed() {
  local total="$1" hours=0 mins=0 secs=0
  if [ "$total" -ge 3600 ]; then
    hours=$(( total / 3600 ))
    mins=$(( (total % 3600) / 60 ))
    secs=$(( total % 60 ))
    printf "%dh%02dm%02ds" "$hours" "$mins" "$secs"
  elif [ "$total" -ge 60 ]; then
    mins=$(( total / 60 ))
    secs=$(( total % 60 ))
    printf "%dm%02ds" "$mins" "$secs"
  else
    printf "%ss" "$total"
  fi
}

blockcheck2_get_uuid() {
  local tel_uuid=""
  if [ -n "$TELEMETRY_CFG" ] && [ -f "$TELEMETRY_CFG" ]; then
    source "$TELEMETRY_CFG"
  fi
  if [ -z "$tel_uuid" ]; then
    if [ -f /proc/sys/kernel/random/uuid ]; then
      tel_uuid="$(cut -c1-8 /proc/sys/kernel/random/uuid)"
    else
      tel_uuid="$(date +%s%N | md5sum | head -c 8)"
    fi
    if [ -n "$TELEMETRY_CFG" ]; then
      mkdir -p "$(dirname "$TELEMETRY_CFG")"
      echo "tel_enabled=${tel_enabled:-0}" > "$TELEMETRY_CFG"
      echo "tel_uuid=$tel_uuid" >> "$TELEMETRY_CFG"
    fi
  fi
  echo "$tel_uuid"
}

run_cdn_test() {
  BIN_THR_BYTES=$((24*1024))
  PARALLEL=6

  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  NC='\033[0m'

  TESTS=(
  "US.CF-01|🇺🇸 Cloudflare|$BIN_THR_BYTES|1|https://img.wzstats.gg/cleaver/gunFullDisplay"
  "US.CF-02|🇺🇸 Cloudflare|104319|1|https://genshin.jmp.blue/characters/all#"
  "US.CF-03|🇺🇸 Cloudflare|109863|1|https://api.frankfurter.dev/v1/2000-01-01..2002-12-31"
  "US.CF-04|🇨🇦 Cloudflare|79655|1|https://www.bigcartel.com/"
  "US.DO-01|🇺🇸 DigitalOcean|195612|2|https://genderize.io/"
  "DE.HE-01|🇩🇪 Hetzner|$BIN_THR_BYTES|1|https://j.dejure.org/jcg/doctrine/doctrine_banner.webp"
  "DE.HE-02|🇩🇪 Hetzner|162646|1|https://accesorioscelular.com/tienda/css/plugins.css"
  "FI.HE-01|🇫🇮 Hetzner|$BIN_THR_BYTES|1|https://251b5cd9.nip.io/1MB.bin"
  "FI.HE-02|🇫🇮 Hetzner|$BIN_THR_BYTES|1|https://nioges.com/libs/fontawesome/webfonts/fa-solid-900.woff2"
  "FI.HE-03|🇫🇮 Hetzner|$BIN_THR_BYTES|1|https://5fd8bdae.nip.io/1MB.bin"
  "FI.HE-04|🇫🇮 Hetzner|$BIN_THR_BYTES|1|https://5fd8bca5.nip.io/1MB.bin"
  "FR.OVH-01|🇫🇷 OVH|75872|1|https://eu.api.ovh.com/console/rapidoc-min.js"
  "FR.OVH-02|🇫🇷 OVH|$BIN_THR_BYTES|1|https://ovh.sfx.ovh/10M.bin"
  "SE.OR-01|🇸🇪 Oracle|$BIN_THR_BYTES|1|https://oracle.sfx.ovh/10M.bin"
  "DE.AWS-01|🇩🇪 AWS|$BIN_THR_BYTES|1|https://www.getscope.com/assets/fonts/fa-solid-900.woff2"
  "US.AWS-01|🇺🇸 AWS|215419|1|https://corp.kaltura.com/wp-content/cache/min/1/wp-content/themes/airfleet/dist/styles/theme.css"
  "US.GC-01|🇺🇸 Google Cloud|176277|1|https://api.usercentrics.eu/gvl/v3/en.json"
  "US.FST-01|🇺🇸 Fastly|77597|1|https://www.jetblue.com/footer/footer-element-es2015.js"
  "CA.FST-01|🇨🇦 Fastly|84086|1|https://ssl.p.jwpcdn.com/player/v/8.40.5/bidding.js"
  "US.AKM-01|🇺🇸 Akamai|$BIN_THR_BYTES|1|https://www.roxio.com/static/roxio/images/products/creator/nxt9/call-action-footer-bg.jpg"
  "PL.AKM-01|🇵🇱 Akamai|$BIN_THR_BYTES|1|https://media-assets.stryker.com/is/image/stryker/gateway_1?\$max_width_1410\$"
  "US.CDN77-01|🇺🇸 CDN77|$BIN_THR_BYTES|1|https://cdn.eso.org/images/banner1920/eso2520a.jpg"
  "FR.CNTB-01|🇫🇷 Contabo|$BIN_THR_BYTES|1|https://xdmarineshop.gr/index.php?route=index"
  "NL.SW-01|🇳🇱 Scaleway|$BIN_THR_BYTES|1|https://www.velivole.fr/img/header.jpg"
  "US.CNST-01|🇺🇸 Constant|$BIN_THR_BYTES|1|https://cdn.xuansiwei.com/common/lib/font-awesome/4.7.0/fontawesome-webfont.woff2?v=4.7.0"
  )

  check_one() {
      IFS='|' read -r id provider thr times url <<< "$1"

      total=0
      code=0

      for ((i=1;i<=times;i++)); do
          read bytes code <<< $(curl -L -s \
              -A "$Z2R_CURL_UA" \
              -H "Range: bytes=0-${thr}" \
              --connect-timeout 5 \
              --max-time 5 \
              -o /dev/null \
              -w '%{size_download} %{http_code}' \
              "$url")

          total=$((total+bytes))
      done

      avg=$((total/times))

      if (( avg >= thr )) && [[ "$code" =~ ^[23] ]]; then
          echo -e "${GREEN}$id OK${NC} ${avg}b [$provider]"
          echo OK >> /tmp/cdn_ok
      else
          echo -e "${RED}$id FAIL${NC} ${avg}b code=$code [$provider]"
          echo FAIL >> /tmp/cdn_fail
      fi
  }

  export -f check_one
  export BIN_THR_BYTES PARALLEL GREEN RED YELLOW NC Z2R_CURL_UA

  rm -f /tmp/cdn_ok /tmp/cdn_fail

  pids_parallels=()
  for test_parallel in "${TESTS[@]}"; do
    check_one "$test_parallel" &
    pids_parallels+=($!)

    # ограничение параллельных задач
    if [ "${#pids_parallels[@]}" -ge "$PARALLEL" ]; then
      wait "${pids_parallels[0]}"
      pids_parallels=("${pids_parallels[@]:1}")
    fi
  done

  # ждём оставшиеся
  for pid_parallel in "${pids_parallels[@]}"; do
    wait "$pid_parallel"
  done

  [ -f /tmp/cdn_ok ] && OK_COUNT=$(wc -l < /tmp/cdn_ok) || OK_COUNT=0
  [ -f /tmp/cdn_fail ] && FAIL_COUNT=$(wc -l < /tmp/cdn_fail) || FAIL_COUNT=0

  echo
  echo -e "${YELLOW}=== SUMMARY ===${NC}"
  echo -e "${GREEN}OK:${NC} ${OK_COUNT:-0}"
  echo -e "${RED}FAIL:${NC} ${FAIL_COUNT:-0}"
}

#Создаём папки и забираем файлы папок lists, fake, extra_strats, копируем конфиг
z2r_install_runtime_libs_from_archive() {
  local lib

  [ "${Z2R_OFFLINE:-0}" = "1" ] || return 0
  mkdir -p "$ZATOR_ROOT/z2r_lib"
  for lib in $Z2R_LIB_FILES; do
    z2r_download_project_file "$ZATOR_ROOT/z2r_lib/$lib" "lib/$lib" || return 1
  done
}

get_repo() {
  local fake_archive="/tmp/z2r_fake_files_$$.tar.gz"

  # zator-контент разворачивается в $ZATOR_ROOT (не затрагивается обновлением zapret2).
  mkdir -p "$ZATOR_ROOT/lists" "$ZATOR_ROOT/extra_strats" "$ZATOR_ROOT/extra_strats/cache" "$ZATOR_ROOT/files/fake"
  mkdir -p "$ORCH_DIR"
  z2r_install_runtime_libs_from_archive || return 1
  client_scope_firewall_update_from_repo || return 1
  chmod 777 "$ORCH_DIR" 2>/dev/null || true
  locked_lua_update_from_repo || true
  rst_guard_lua_update_from_repo || true
  circular_runtime_update_from_repo || return 1
  strategy_validator_install_service || return 1
  for listfile in cloudflare-ipset.txt cloudflare-ipset_v6.txt netrogat.txt russia-discord.txt russia-youtube-rtmps.txt russia-youtube.txt russia-youtubeQ.txt tg_cidr.txt; do
    z2r_download_project_file "$ZATOR_ROOT/lists/$listfile" "lists/$listfile" || return 1
  done
  z2r_download_project_file "$fake_archive" "fake_files.tar.gz" || return 1
  tar -xzf "$fake_archive" -C "$ZATOR_ROOT/files/fake" || {
    rm -f "$fake_archive"
    return 1
  }
  rm -f "$fake_archive"
  z2r_download_project_file "$ZATOR_ROOT/extra_strats/UDP_YT_list.txt" "extra_strats/UDP/YT/List.txt" || return 1
  z2r_download_project_file "$ZATOR_ROOT/extra_strats/TCP_RKN_list.txt" "extra_strats/TCP/RKN/List.txt" || return 1
  z2r_download_project_file "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" "extra_strats/TCP/RKN/Custom.txt" || return 1
  z2r_download_project_file "$ZATOR_ROOT/extra_strats/TCP_YT_list.txt" "extra_strats/TCP/YT/List.txt" || return 1
  z2r_download_project_file "$ZATOR_ROOT/extra_strats/TCP_Discord.txt" "extra_strats/TCP/RKN/Discord.txt" || return 1
  blockcheck2_prepare_z4r_test || return 1
  if [ ! -f "$ZATOR_ROOT/files/fake/custom_tls.bin" ]; then
    mkdir -p "$ZATOR_ROOT/files/fake"
    if ! z2r_download_project_file "$ZATOR_ROOT/files/fake/custom_tls.bin" "fake/custom_tls.bin"; then
      echo -e "${yellow}Не удалось скачать custom_tls.bin: нет curl/wget.${plain}"
    fi
  fi
  touch "$ZATOR_ROOT/lists/autohostlist.txt"
  if [ -d /opt/extra_strats ]; then
    rm -rf "$ZATOR_ROOT/extra_strats"
    mv /opt/extra_strats "$ZATOR_ROOT/"
    echo "Востановление настроек подбора из резерва выполнено."
  fi
  if [ ! -f "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" ]; then
    mkdir -p "$ZATOR_ROOT/extra_strats"
    z2r_download_project_file "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" "extra_strats/TCP/RKN/Custom.txt" || touch "$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
  fi
  if [ ! -f "$ZATOR_ROOT/extra_strats/TCP_RKN_domains_by_substring.txt" ]; then
    mkdir -p "$ZATOR_ROOT/extra_strats"
    z2r_download_project_file "$ZATOR_ROOT/extra_strats/TCP_RKN_domains_by_substring.txt" "extra_strats/TCP/RKN/Domains_By_Substring.txt" || touch "$ZATOR_ROOT/extra_strats/TCP_RKN_domains_by_substring.txt"
  fi
  if [ ! -f "$ZATOR_ROOT/lists/netrogat_substrings.txt" ]; then
    z2r_download_project_file "$ZATOR_ROOT/lists/netrogat_substrings.txt" "lists/netrogat_substrings.txt" || touch "$ZATOR_ROOT/lists/netrogat_substrings.txt"
  fi
  mkdir -p "$ZATOR_ROOT/data/providers"
  if z2r_download_project_file "$ZATOR_ROOT/data/providers/asn.txt" "data/providers/asn.txt"; then
    grep -qE '^[0-9]+:' "$ZATOR_ROOT/data/providers/asn.txt" 2>/dev/null || rm -f "$ZATOR_ROOT/data/providers/asn.txt"
  fi
  if [ -f "/opt/netrogat.txt" ]; then
    mv -f /opt/netrogat.txt "$ZATOR_ROOT/lists/netrogat.txt"
    echo "Востановление листа исключений выполнено."
  fi
  # config.default и keenetic-policy.sh — zapret2-native, остаются в $ZAPRET2_ROOT.
 z2r_download_project_file "$ZAPRET2_ROOT/config.default" "config.default" || return 1
  # Add new optional settings without breaking an older deployed template.
  config_client_scope_ensure "$ZAPRET2_ROOT/config.default" || return 1
  if [ "$hardware" = "keenetic" ]; then
    z2r_download_project_file "$ZAPRET2_ROOT/init.d/sysv/keenetic-policy.sh" "Entware/keenetic-policy.sh" || return 1
    chmod +x "$ZAPRET2_ROOT/init.d/sysv/keenetic-policy.sh"
  fi
  if fwtype_nft_available; then
    sed -i 's/^FWTYPE=iptables$/FWTYPE=nftables/' "$ZAPRET2_ROOT/config.default"
  fi
# cache
mkdir -p "$ZATOR_ROOT/extra_strats/cache"

}

#Удаление старого запрета, если есть
client_scope_enabled_from_active_config() {
 if [ "${CLIENT_SCOPE_ENABLE+x}" = "x" ]; then
  [ "$CLIENT_SCOPE_ENABLE" = "1" ]
  return
 fi
 [ -f "$ZAPRET2_ROOT/config" ] || return 1
 grep -Eq '^[[:space:]]*CLIENT_SCOPE_ENABLE[[:space:]]*=[[:space:]]*1([[:space:]]*#.*)?$' "$ZAPRET2_ROOT/config"
}

remove_zapret() {
 if client_scope_enabled_from_active_config && [ -x "$ZATOR_ROOT/firewall/client-scope-iptables.sh" ]; then
     "$ZATOR_ROOT/firewall/client-scope-iptables.sh" cleanup || true
 fi
 if [ -f "$ZAPRET2_INIT" ] && [ -f "$ZAPRET2_ROOT/config" ]; then
 	z2r_service_action stop
 fi
 if [ -f "$ZAPRET2_ROOT/config" ] && [ -f "$ZAPRET2_ROOT/uninstall_easy.sh" ]; then
     echo "Выполняем zapret2/uninstall_easy.sh"
     sh "$ZAPRET2_ROOT/uninstall_easy.sh"
     echo "Скрипт uninstall_easy.sh выполнен."
 else
     echo "zapret2 не инсталлирован в систему. Переходим к следующему шагу."
 fi
 # Удаляем ТОЛЬКО zapret2-native ($ZAPRET2_ROOT). zator-контент ($ZATOR_ROOT)
 # НЕ трогается — он переживает обновление/переустановку zapret2.
 if [ -d "$ZAPRET2_ROOT" ]; then
     echo "Удаляем папку zapret2"
     webui_stop_service >/dev/null 2>&1 || true
     strategy_validator_remove_service
     rm -rf "$ZAPRET2_ROOT"
 else
     echo "Папка zapret2 не существует."
 fi
 if [[ "$OSystem" == "entware" ]]; then
 	if [ -f /opt/etc/ndm/netfilter.d/000-zapret.sh ] \
 	   && grep -q 'zapret2' /opt/etc/ndm/netfilter.d/000-zapret.sh 2>/dev/null; then
 		rm -fv /opt/etc/ndm/netfilter.d/000-zapret.sh
 	fi
 	rm -fv /opt/etc/init.d/S90-zapret /opt/etc/init.d/S90-zapret2 /opt/etc/ndm/netfilter.d/000-zapret2.sh /opt/etc/init.d/S00fix
 fi
}

# Полное удаление zator-контента ($ZATOR_ROOT): Web-панель, lua, листы,
# фиксы стратегий, кэш оркестра. Бэкапы НЕ трогаем — они в /opt/zator_backup.
# Точки отказа обработаны: функция не роняет вызывающий код под set -e.
zator_remove() {
  if [ ! -d "$ZATOR_ROOT" ]; then
    echo -e "${yellow}Каталог zator не существует: $ZATOR_ROOT${plain}"
    return 0
  fi
  strategy_validator_remove_service || true
  webui_remove || true
  if ! rm -rf "$ZATOR_ROOT" 2>/dev/null; then
    echo -e "${red}Не удалось полностью удалить $ZATOR_ROOT${plain}"
    return 1
  fi
  echo -e "${green}Каталог zator удалён: $ZATOR_ROOT${plain}"
}

#Запрос желаемой версии zapret2
version_select() {
   if [ -n "${ZAPRET2_VERSION:-}" ]; then
    if ! printf '%s\n' "$ZAPRET2_VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
      echo -e "${red}Некорректная версия zapret2 из архива: $ZAPRET2_VERSION${plain}"
      return 1
    fi
    VER="$ZAPRET2_VERSION"
    echo -e "${green}Из архива выбрана версия zapret2: $VER${plain}"
    return 0
   fi
   while true; do
	read -re -p $'\033[0;32mВведите желаемую версию zapret2 (Enter для новейшей версии): \033[0m' VER
    # Если пустой ввод — берем значение по умолчанию
	if [ -z "$VER" ]; then
		lastest_release="https://api.github.com/repos/bol-van/zapret2/releases/latest"
	    # проверяем результаты по порядку
		echo -e "${yellow}Поиск последней версии...${plain}"
    	VER1=$(curl -sL $lastest_release | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
		if [ ${#VER1} -ge 2 ]; then
			VER="$VER1"
			echo -e "${green}Выбрано: $VER (метод: sed -E)${plain}"
		else
			VER2=$(curl -sL $lastest_release | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | sed 's/^v//')
			if [ ${#VER2} -ge 2 ]; then
				VER="$VER2"
				echo -e "${green}Выбрано: $VER (метод: grep+cut)${plain}"
			else
				VER3=$(curl -sL $lastest_release | grep '"tag_name":' | sed -r 's/.*"v([^"]+)".*/\1/')
				if [ ${#VER3} -ge 2 ]; then
					VER="$VER3"
					echo -e "${green}Выбрано: $VER (метод: sed -r)${plain}"
				else
					VER4=$(curl -sL $lastest_release | grep '"tag_name":' | awk -F'"' '{print $4}' | sed 's/^v//')
					if [ ${#VER4} -ge 2 ]; then
						VER="$VER4"
						echo -e "${green}Выбрано: $VER (метод: awk)${plain}"
					else
						echo -e "${yellow}Не удалось получить информацию о последней версии с GitHub. Будет использоваться версия $DEFAULT_VER.${plain}"
						VER="$DEFAULT_VER"
					fi
				fi
			fi
    	fi
    	break
	fi
    #Считаем длину
    LEN=${#VER}
    #Проверка длины и простая валидация формата (цифры и точки)
    if [ "$LEN" -gt 5 ]; then
        echo "Некорректный ввод. Максимальная длина — 5 символов. Попробуйте снова."
        continue
    elif ! echo "$VER" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
        echo "Некорректный формат версии. Пример: 0.8.2"
        continue
    fi
    echo "Будет использоваться версия: $VER"
    break
done
}

z2r_validate_tar_archive() {
 local archive="$1"
 local entry

 if ! tar -tzf "$archive" >/dev/null 2>&1; then
  return 1
 fi
 while IFS= read -r entry; do
  case "$entry" in
   /*|../*|*/../*|*/..) return 1 ;;
  esac
 done < <(tar -tzf "$archive")
 return 0
}

#Скачивание, распаковка архива zapret2, очистка от ненуных бинарей
zapret_get() {
 local archive
 local extract_dir
 local workdir
 if [[ "$OSystem" == "WRT" ]]; then
     tarfile="zapret2-v$VER-openwrt-embedded.tar.gz"
 else
     tarfile="zapret2-v$VER.tar.gz"
 fi

 archive="/tmp/z2r_${tarfile}_$$"
 if [ -n "${ZAPRET2_ARCHIVE_DIR:-}" ]; then
     local bundled_archive="$ZAPRET2_ARCHIVE_DIR/$tarfile"
     if [ ! -f "$bundled_archive" ]; then
         echo -e "${red}В установочном архиве нет подходящей зависимости: $tarfile.${plain}"
         echo -e "${yellow}Для этой платформы требуется файл $bundled_archive${plain}"
         return 1
     fi
     cp -f "$bundled_archive" "$archive" || return 1
 elif ! z2r_download_zapret2_release "$archive" "$VER" "$tarfile"; then
     echo -e "${red}Не удалось скачать архив zapret2 $tarfile.${plain}"
     echo -e "${yellow}Если есть зеркало release-архивов, задайте ZAPRET2_RELEASE_MIRROR_BASE с базовым URL вида https://mirror/path.${plain}"
     rm -f "$archive"
     return 1
 fi
 if ! z2r_validate_tar_archive "$archive"; then
     echo -e "${red}Архив zapret2 повреждён или содержит небезопасные пути: $tarfile.${plain}"
     rm -f "$archive"
     return 1
 fi
 workdir="/tmp/z2r_zapret2_$$"
 rm -rf "$workdir"
 mkdir -p "$workdir"
 if ! tar -xzf "$archive" -C "$workdir"; then
     echo -e "${red}Архив zapret2 повреждён или не является tar.gz: $tarfile.${plain}"
     rm -f "$archive"
     rm -rf "$workdir"
     return 1
 fi
 rm -f "$archive"

 if [ -d "$workdir/zapret2-v$VER" ]; then
     extract_dir="$workdir/zapret2-v$VER"
 else
     extract_dir="$(find "$workdir" -maxdepth 1 -type d -name 'zapret2-v*' | head -n1)"
 fi
 if [ -z "$extract_dir" ] || [ ! -d "$extract_dir" ]; then
     echo -e "${red}После распаковки не найден каталог zapret2-v*.${plain}"
     rm -rf "$workdir"
     return 1
 fi
 if [ "$(basename "$extract_dir")" != "zapret2-v$VER" ]; then
     echo -e "${yellow}Используется архив zapret2 из Яндекс.Диска: $(basename "$extract_dir") вместо выбранной версии $VER.${plain}"
 fi
 mv "$extract_dir" "$workdir/zapret2"
 if [ ! -f "$workdir/zapret2/install_bin.sh" ] || [ ! -f "$workdir/zapret2/install_easy.sh" ]; then
     echo -e "${red}Архив zapret2 распакован некорректно: нет install_bin.sh или install_easy.sh.${plain}"
     rm -rf "$workdir"
     return 1
 fi
 sh "$workdir/zapret2/install_bin.sh"
 find "$workdir/zapret2/binaries"/* -maxdepth 0 -type d ! -name "$(basename "$(dirname "$(readlink "$workdir/zapret2/nfq2/nfqws2")")")" -exec rm -rf {} +
 z2r_prune_staged_binaries "$workdir/zapret2"
 z2r_prune_staged_sources "$workdir/zapret2"
 rm -rf "$workdir/zapret2/docs"
 rm -f "$workdir/zapret2/files/fake"/*
 # Заменяем только zapret2-native; zator-контент в $ZATOR_ROOT не затрагивается.
 rm -rf "$ZAPRET2_ROOT"
 mv "$workdir/zapret2" "$ZAPRET2_ROOT"
 rm -rf "$workdir"
 if [ ! -f "$ZAPRET2_ROOT/install_easy.sh" ]; then
     echo -e "${red}zapret2 установлен некорректно: нет $ZAPRET2_ROOT/install_easy.sh.${plain}"
     return 1
 fi
 set_zapret2_init
}

z2r_prune_staged_binaries() {
 local base="$1"
 local link target src keep_file
 local keep_list=""
 local arch_dir=""
 local file

 for link in "$base/nfq2/nfqws2" "$base/ip2net/ip2net" "$base/mdig/mdig"; do
  [ -L "$link" ] || continue
  target="$(readlink "$link")" || continue
  case "$target" in
   /*) src="$target" ;;
   *) src="$(dirname "$link")/$target" ;;
  esac
  [ -f "$src" ] || continue
  arch_dir="$(dirname "$src")"
  keep_file="$(basename "$src")"
  case " $keep_list " in
   *" $keep_file "*) ;;
   *) keep_list="$keep_list $keep_file" ;;
  esac
 done

 [ -n "$arch_dir" ] || return 0
 [ -d "$arch_dir" ] || return 0

 for file in "$arch_dir"/*; do
  [ -f "$file" ] || continue
  case " $keep_list " in
   *" $(basename "$file") "*) ;;
   *) rm -f "$file" ;;
  esac
 done

 echo -e "${green}В $ZAPRET2_ROOT/binaries будет оставлен только выбранный набор:$(printf '%s' "$keep_list").${plain}"
}

z2r_prune_staged_sources() {
 local base="$1"

 find "$base/nfq2" -mindepth 1 ! -name nfqws2 -exec rm -rf {} + 2>/dev/null || true
 find "$base/ip2net" -mindepth 1 ! -name ip2net -exec rm -rf {} + 2>/dev/null || true
 find "$base/mdig" -mindepth 1 ! -name mdig -exec rm -rf {} + 2>/dev/null || true
 rm -f "$base/Makefile"
}

#Запуск установочных скриптов и перезагрузка
install_zapret_reboot() {
 sh -i "$ZAPRET2_ROOT/install_easy.sh"
 cleanup_zapret2_init_dirs
 z2r_service_action restart
 if pidof nfqws2 >/dev/null; then
  check_access_list
  echo -e "${green}zapret2 перезапущен и полностью установлен\n${yellow}Открываю меню управления. Если меню закрылось или что-то пошло не так — просто напишите 'z2r' в терминале. Саппорт: tg: zee4r${plain}"
 else
  echo -e "${yellow}zapret2 полностью установлен, но не обнаружен после запуска в исполняемых задачах через pidof\nСаппорт: tg: zee4r${plain}"
  pause_enter
 fi
}

#Для Entware Keenetic + merlin
entware_fixes() {
 if [ "$hardware" = "keenetic" ]; then
  z2r_download_project_file "$ZAPRET2_ROOT/init.d/sysv/zapret2" "Entware/zapret" || return 1
  chmod +x "$ZAPRET2_ROOT/init.d/sysv/zapret2"
  echo "Права выданы $ZAPRET2_ROOT/init.d/sysv/zapret2"
  if [ -f /opt/etc/ndm/netfilter.d/000-zapret.sh ] \
     && grep -q 'zapret2' /opt/etc/ndm/netfilter.d/000-zapret.sh 2>/dev/null; then
    rm -fv /opt/etc/ndm/netfilter.d/000-zapret.sh
  fi
  z2r_download_project_file /opt/etc/ndm/netfilter.d/000-zapret2.sh "Entware/000-zapret2.sh" || return 1
  chmod +x /opt/etc/ndm/netfilter.d/000-zapret2.sh
  echo "Права выданы /opt/etc/ndm/netfilter.d/000-zapret2.sh"
  z2r_download_project_file /opt/etc/init.d/S00fix "Entware/S00fix" || return 1
  chmod +x /opt/etc/init.d/S00fix
  echo "Права выданы /opt/etc/init.d/S00fix"
  if [ -f "$ZAPRET2_ROOT/init.d/custom.d.examples.linux/10-keenetic-udp-fix" ]; then
    cp -a "$ZAPRET2_ROOT/init.d/custom.d.examples.linux/10-keenetic-udp-fix" "$ZAPRET2_ROOT/init.d/sysv/custom.d/10-keenetic-udp-fix"
  else
    z2r_download_upstream_file "$ZAPRET2_ROOT/init.d/sysv/custom.d/10-keenetic-udp-fix" "init.d/custom.d.examples.linux/10-keenetic-udp-fix" || return 1
  fi
  echo "10-keenetic-udp-fix скопирован"
 elif [ "$hardware" = "merlin" ]; then
  if sed -n '167p' "$ZAPRET2_ROOT/install_easy.sh" | grep -q '^nfqws_opt_validat'; then
	sed -i '172s/return 1/return 0/' "$ZAPRET2_ROOT/install_easy.sh"
  fi
	grep -qxF "$ZAPRET2_INIT restart-fw" /jffs/scripts/firewall-start || echo "$ZAPRET2_INIT restart-fw" >> /jffs/scripts/firewall-start
	chmod +x /jffs/scripts/firewall-start
 fi

 sh "$ZAPRET2_ROOT/install_bin.sh"

 # #Раскомменчивание юзера под keenetic или merlin
 change_user
 #Патчинг на некоторых merlin $ZAPRET2_ROOT/common/linux_fw.sh
 if command -v sysctl >/dev/null 2>&1; then
  echo "sysctl доступен. Патч linux_fw.sh не требуется"
 else
  echo "sysctl отсутствует. MerlinWRT? Патчим $ZAPRET2_ROOT/common/linux_fw.sh"
  sed -i 's|sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=\$1|echo \$1 > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal|' "$ZAPRET2_ROOT/common/linux_fw.sh"
  sed -i 's|sysctl -q -w net.ipv4.conf.\$1.route_localnet="\$enable"|echo "\$enable" > /proc/sys/net/ipv4/conf/\$1/route_localnet|' "$ZAPRET2_ROOT/common/linux_iphelper.sh"
 fi
 #sed для пропуска запроса на прочтение readme, т.к. система entware. Дабы скрипт отрабатывал далее на Enter
 sed -i 's/if \[ -n "\$1" \] || ask_yes_no N "do you want to continue";/if true;/' "$ZAPRET2_ROOT/common/installer.sh"
 ln -fs "$ZAPRET2_INIT" /opt/etc/init.d/S90-zapret2
 echo "Добавлено в автозагрузку: /opt/etc/init.d/S90-zapret2 > $ZAPRET2_INIT"
}

#Патчи апстримного procd-инициализатора под OpenWRT (см. AGENTS.md, High-Risk Areas)
wrt_fixes() {
 local f="$ZAPRET2_ROOT/init.d/openwrt/zapret2"
 [ -f "$f" ] || { echo -e "${yellow}init.d/openwrt/zapret2 не найден — патчи OpenWRT пропущены.${plain}"; return 0; }
 cp -a "$f" "$f.z2r_bak" || return 1
 if ! grep -q 'procd_set_param stderr 1' "$f"; then
  sed -i '/procd_set_param pidfile/a\	procd_set_param stderr 1' "$f" || true
 fi
 if ! grep -q '^contains()' "$f"; then
  sed -i '/^\. "\$ZAPRET_BASE\/init\.d\/openwrt\/functions"/a\contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }' "$f" || true
 fi
 if ! sh -n "$f"; then
  echo -e "${red}Патч OpenWRT сломал синтаксис init-скрипта — откат.${plain}"
  mv -f "$f.z2r_bak" "$f"
  return 1
 fi
 rm -f "$f.z2r_bak"
 echo "Патчи OpenWRT применены (stderr->syslog, линейный contains)."
}

#Запрос на установку 3x-ui или аналогов
get_panel() {
 read -re -p $'\033[33mУстановить ПО для туннелирования?\033[0m \033[32m(3xui, marzban, wg, 3proxy или Enter для пропуска): \033[0m' answer_panel
 # Удаляем лишние символы и пробелы, приводим к верхнему регистру
 clean_answer=$(echo "$answer_panel" | tr '[:lower:]' '[:upper:]')
 if [[ -z "$clean_answer" ]]; then
     echo "Пропуск установки ПО туннелирования."
 elif [[ "$clean_answer" == "3XUI" ]]; then
     echo "Установка 3x-ui панели."
     bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
 elif [[ "$clean_answer" == "WG" ]]; then
     echo "Установка WG (by angristan)"
     bash <(curl -Ls https://raw.githubusercontent.com/angristan/wireguard-install/refs/heads/master/wireguard-install.sh)
 elif [[ "$clean_answer" == "3PROXY" ]]; then
     echo "Установка 3proxy (by SnoyIatk). Доустановка с apt build-essential для сборки (debian/ubuntu)"
	 apt update && apt install build-essential
     bash <(curl -Ls https://raw.githubusercontent.com/SnoyIatk/3proxy/master/3proxyinstall.sh)
     z2r_download_project_file /etc/3proxy/.proxyauth "del.proxyauth"
     z2r_download_project_file /etc/3proxy/3proxy.cfg "3proxy.cfg"
 elif [[ "$clean_answer" == "MARZBAN" ]]; then
     echo "Установка Marzban"
     bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install
 else
     echo "Пропуск установки ПО туннелирования."
 fi
}

#Меню, проверка состояний и вывод с чтением ответа
WEBUI_PORT="17682"
WEBUI_ROOT="$ZATOR_ROOT/webui"
WEBUI_WWW="$WEBUI_ROOT/www"
WEBUI_CGI="$WEBUI_ROOT/cgi-bin"
WEBUI_RUNNER="$WEBUI_ROOT/run-webui.sh"
WEBUI_STATUS_CACHE="$ZATOR_ROOT/extra_strats/cache/webui"
WEBUI_PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin"

webui_repo_fetch() {
  local rel="$1"
  local dest="$2"
  local local_src="$SCRIPT_DIR/webui/$rel"

  mkdir -p "$(dirname "$dest")"
  if [ -f "$local_src" ]; then
    cp -f "$local_src" "$dest"
    return 0
  fi
  z2r_download_project_file "$dest" "webui/$rel" && return 0
  echo -e "${red}Нет curl или wget для загрузки web UI.${plain}"
  return 1
}

webui_has_busybox_httpd() {
  PATH="$WEBUI_PATH" command -v busybox >/dev/null 2>&1 || return 1
  if ! PATH="$WEBUI_PATH" busybox --list 2>/dev/null | grep -qx 'httpd'; then
    return 1
  fi
}

webui_server_type() {
  if PATH="$WEBUI_PATH" command -v uhttpd >/dev/null 2>&1; then
    echo "uhttpd"
    return
  fi
  if PATH="$WEBUI_PATH" command -v uhttpd_kn >/dev/null 2>&1; then
    echo "uhttpd_kn"
    return
  fi
  if PATH="$WEBUI_PATH" command -v httpd >/dev/null 2>&1; then
    echo "httpd"
    return
  fi
  if webui_has_busybox_httpd; then
    echo "busybox"
    return
  fi
  echo "none"
}

webui_ensure_server_binary() {
  if [ "$(webui_server_type)" != "none" ]; then
    return 0
  fi

  if command -v apk >/dev/null 2>&1; then
    apk update 2>/dev/null || true
    apk add uhttpd busybox 2>/dev/null || apk add busybox 2>/dev/null || true
  elif command -v opkg >/dev/null 2>&1; then
    PATH="$WEBUI_PATH" opkg install uhttpd 2>/dev/null || true
    [ "$(webui_server_type)" != "none" ] || PATH="$WEBUI_PATH" opkg install uhttpd_kn 2>/dev/null || true
    [ "$(webui_server_type)" != "none" ] || PATH="$WEBUI_PATH" opkg install uhttpd-kn 2>/dev/null || true
    [ "$(webui_server_type)" != "none" ] || PATH="$WEBUI_PATH" opkg install busybox-httpd 2>/dev/null || true
    [ "$(webui_server_type)" != "none" ] || PATH="$WEBUI_PATH" opkg install busybox 2>/dev/null || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update 2>/dev/null || true
    apt-get install -y busybox-static 2>/dev/null || apt-get install -y busybox 2>/dev/null || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm busybox 2>/dev/null || true
  fi

  if [ "$(webui_server_type)" = "none" ]; then
    echo -e "${red}Не удалось найти или установить uhttpd/busybox httpd для web UI.${plain}"
    return 1
  fi
  return 0
}

webui_ensure_runtime_deps() {
  if PATH="$WEBUI_PATH" command -v nohup >/dev/null 2>&1; then
    return 0
  fi
  if PATH="$WEBUI_PATH" command -v busybox >/dev/null 2>&1 && PATH="$WEBUI_PATH" busybox --list 2>/dev/null | grep -qx 'nohup'; then
    return 0
  fi

  if command -v apk >/dev/null 2>&1; then
    apk update 2>/dev/null || true
    apk add coreutils-nohup 2>/dev/null || apk add coreutils 2>/dev/null || true
  elif command -v opkg >/dev/null 2>&1; then
    PATH="$WEBUI_PATH" opkg update 2>/dev/null || true
    PATH="$WEBUI_PATH" opkg install coreutils-nohup 2>/dev/null || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update 2>/dev/null || true
    apt-get install -y coreutils 2>/dev/null || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm coreutils 2>/dev/null || true
  fi

  if ! PATH="$WEBUI_PATH" command -v nohup >/dev/null 2>&1; then
    if PATH="$WEBUI_PATH" command -v busybox >/dev/null 2>&1 && PATH="$WEBUI_PATH" busybox --list 2>/dev/null | grep -qx 'nohup'; then
      return 0
    fi
    echo -e "${red}Не удалось найти или установить nohup для web UI.${plain}"
    [ "$OSystem" = "entware" ] && echo -e "${yellow}Для Keenetic/Entware нужен пакет coreutils-nohup.${plain}"
    [ "$OSystem" = "WRT" ] && echo -e "${yellow}Для OpenWrt нужен пакет coreutils-nohup или BusyBox с applet nohup.${plain}"
    return 1
  fi

  return 0
}

webui_install_files() {
  mkdir -p "$WEBUI_ROOT" "$WEBUI_WWW" "$WEBUI_CGI" "$WEBUI_STATUS_CACHE"

  webui_repo_fetch "index.html" "$WEBUI_WWW/index.html" || return 1
  webui_repo_fetch "styles.css" "$WEBUI_WWW/styles.css" || return 1
  webui_repo_fetch "app.js" "$WEBUI_WWW/app.js" || return 1
  webui_repo_fetch "favicon.svg" "$WEBUI_WWW/favicon.svg" || return 1
  webui_repo_fetch "run-webui.sh" "$WEBUI_RUNNER" || return 1
  webui_repo_fetch "cgi-bin/_lib.sh" "$WEBUI_CGI/_lib.sh" || return 1
  webui_repo_fetch "cgi-bin/status.cgi" "$WEBUI_CGI/status.cgi" || return 1
  webui_repo_fetch "cgi-bin/set-lock.cgi" "$WEBUI_CGI/set-lock.cgi" || return 1
  webui_repo_fetch "cgi-bin/clear-lock.cgi" "$WEBUI_CGI/clear-lock.cgi" || return 1
  webui_repo_fetch "cgi-bin/service.cgi" "$WEBUI_CGI/service.cgi" || return 1
  webui_repo_fetch "cgi-bin/check.cgi" "$WEBUI_CGI/check.cgi" || return 1
  webui_repo_fetch "cgi-bin/domains.cgi" "$WEBUI_CGI/domains.cgi" || return 1
  webui_repo_fetch "cgi-bin/settings.cgi" "$WEBUI_CGI/settings.cgi" || return 1
  webui_repo_fetch "cgi-bin/backups.cgi" "$WEBUI_CGI/backups.cgi" || return 1

  chmod +x "$WEBUI_RUNNER" "$WEBUI_CGI"/*.sh "$WEBUI_CGI"/*.cgi
  webui_fix_interpreters
  ln -sfn ../cgi-bin "$WEBUI_WWW/cgi-bin"
}

webui_fix_interpreters() {
  local bash_bin="" f

  [ -x /opt/bin/bash ] && bash_bin="/opt/bin/bash"
  [ -n "$bash_bin" ] || return 0

  for f in "$WEBUI_RUNNER" "$WEBUI_CGI"/*.sh "$WEBUI_CGI"/*.cgi; do
    [ -f "$f" ] || continue
    sed -i "1s|^#!.*bash$|#!$bash_bin|" "$f" 2>/dev/null || true
    chmod +x "$f" 2>/dev/null || true
  done
}

webui_install_service() {
  mkdir -p "$WEBUI_STATUS_CACHE"

  case "$OSystem" in
    "WRT")
      cat > /etc/init.d/z2r-webui <<'EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
PATH=/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

start_service() {
  procd_open_instance
  procd_set_param command bash @ZATOR_ROOT@/webui/run-webui.sh run
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}

stop_service() {
  bash @ZATOR_ROOT@/webui/run-webui.sh stop >/dev/null 2>&1 || true
}
EOF
      sed -i "s#@ZATOR_ROOT@#$ZATOR_ROOT#g" /etc/init.d/z2r-webui
      chmod +x /etc/init.d/z2r-webui
      /etc/init.d/z2r-webui enable 2>/dev/null || true
      ;;
    "entware")
      cat > /opt/etc/init.d/S92z2r-webui <<'EOF'
#!/bin/sh
PATH=/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
case "$1" in
  start)   sh @ZATOR_ROOT@/webui/run-webui.sh start >/dev/null 2>&1 & ;;
  stop)    sh @ZATOR_ROOT@/webui/run-webui.sh stop ;;
  restart) sh @ZATOR_ROOT@/webui/run-webui.sh restart ;;
  status)  sh @ZATOR_ROOT@/webui/run-webui.sh status ;;
  *) echo "usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
      sed -i "s#@ZATOR_ROOT@#$ZATOR_ROOT#g" /opt/etc/init.d/S92z2r-webui
      chmod +x /opt/etc/init.d/S92z2r-webui
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/z2r-webui.service <<'EOF'
[Unit]
Description=z2r Web UI
After=network.target

[Service]
Type=simple
Environment=PATH=/opt/bin:/opt/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=bash @ZATOR_ROOT@/webui/run-webui.sh run
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        sed -i "s#@ZATOR_ROOT@#$ZATOR_ROOT#g" /etc/systemd/system/z2r-webui.service
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable z2r-webui.service 2>/dev/null || true
      else
        cat > "$WEBUI_ROOT/run.sh" <<'EOF'
#!/bin/sh
PATH=/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
bash @ZATOR_ROOT@/webui/run-webui.sh start
EOF
        sed -i "s#@ZATOR_ROOT@#$ZATOR_ROOT#g" "$WEBUI_ROOT/run.sh"
        chmod +x "$WEBUI_ROOT/run.sh"
      fi
      ;;
  esac
}

webui_start_service() {
  case "$OSystem" in
    "WRT")
      /etc/init.d/z2r-webui start
      ;;
    "entware")
      /opt/etc/init.d/S92z2r-webui start
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/z2r-webui.service ]; then
        systemctl restart z2r-webui.service
      else
        bash "$WEBUI_RUNNER" restart >/dev/null 2>&1 || bash "$WEBUI_RUNNER" start >/dev/null 2>&1
      fi
      ;;
  esac
}

webui_stop_service() {
  case "$OSystem" in
    "WRT")
      [ -f /etc/init.d/z2r-webui ] && /etc/init.d/z2r-webui stop >/dev/null 2>&1 || true
      ;;
    "entware")
      [ -f /opt/etc/init.d/S92z2r-webui ] && /opt/etc/init.d/S92z2r-webui stop >/dev/null 2>&1 || true
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/z2r-webui.service ]; then
        systemctl stop z2r-webui.service >/dev/null 2>&1 || true
      fi
      [ -x "$WEBUI_RUNNER" ] && "$WEBUI_RUNNER" stop >/dev/null 2>&1 || true
      ;;
  esac
}

webui_restart() {
  webui_stop_service || true
  if ! webui_start_service; then
    echo -e "${red}Не удалось запустить Web UI после перезапуска.${plain}"
    return 1
  fi
  echo -e "${green}Web UI перезапущен.${plain}"
}

webui_status_text() {
  if [ -x "$WEBUI_RUNNER" ]; then
    "$WEBUI_RUNNER" status 2>/dev/null || echo "stopped:none:${WEBUI_PORT}"
  else
    echo "stopped:none:${WEBUI_PORT}"
  fi
}

webui_print_urls() {
  if [ -x "$WEBUI_RUNNER" ]; then
    "$WEBUI_RUNNER" urls 2>/dev/null || true
  else
    echo "http://$(hostname 2>/dev/null || echo 127.0.0.1):${WEBUI_PORT}"
  fi
}

webui_show_status() {
  local status_line
  status_line="$(webui_status_text)"
  echo -e "${yellow}Web UI: ${plain}${status_line}"
  echo -e "${yellow}URL примеры:${plain}"
  webui_print_urls
}

webui_install() {
  webui_ensure_runtime_deps || return 1
  webui_ensure_server_binary || return 1
  webui_install_files || return 1
  webui_install_service || return 1
  webui_start_service || return 1
  echo -e "${green}Web UI установлен.${plain}"
  webui_show_status
}

webui_remove() {
  webui_stop_service
  case "$OSystem" in
    "WRT")
      [ -f /etc/init.d/z2r-webui ] && rm -f /etc/init.d/z2r-webui
      ;;
    "entware")
      [ -f /opt/etc/init.d/S92z2r-webui ] && rm -f /opt/etc/init.d/S92z2r-webui
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/z2r-webui.service ]; then
        systemctl disable z2r-webui.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/z2r-webui.service
        systemctl daemon-reload >/dev/null 2>&1 || true
      fi
      ;;
  esac
  rm -rf "$WEBUI_ROOT" 2>/dev/null || echo -e "${red}Не удалось полностью удалить $WEBUI_ROOT${plain}"
  echo -e "${green}Web UI удалён.${plain}"
}

webui_submenu() {
  local status_line webui_running
  while true; do
    clear -x
    status_line="$(webui_status_text)"
    webui_running=0
    case "$status_line" in
      running:*) webui_running=1 ;;
    esac
    echo -e "${cyan}--- Web UI ---${plain}"
    echo -e "${yellow}Состояние: ${plain}${status_line}"
    echo ""
    submenu_item "1" "Установить/обновить Web UI"
    submenu_item "2" "Показать статус и URL"
    if [ "$webui_running" = "1" ]; then
      submenu_item "3" "Перезапустить Web UI"
      submenu_item "4" "Удалить Web UI"
    else
      submenu_item "3" "Удалить Web UI"
    fi
    submenu_item "0" "Назад"
    echo ""
    read -re -p "Ваш выбор: " webui_answer
    case "$webui_answer" in
      "1")
        webui_install || echo -e "${red}Установка/запуск Web UI не удался.${plain}"
        pause_enter
        ;;
      "2")
        webui_show_status
        pause_enter
        ;;
      "3")
        if [ "$webui_running" = "1" ]; then
          webui_restart || echo -e "${red}Перезапуск Web UI не удался.${plain}"
          webui_show_status || true
        else
          webui_remove || true
        fi
        pause_enter
        ;;
      "4")
        if [ "$webui_running" = "1" ]; then
          webui_remove || true
        else
          echo -e "${yellow}Неверный ввод.${plain}"
          sleep 1
        fi
        ;;
      "0"|"")
        return
        ;;
      *)
        echo -e "${yellow}Неверный ввод.${plain}"
        sleep 1
        ;;
    esac
  done
}

get_menu() {
    TITLE_MENU_LINE=""
    if [[ -s "$PREMIUM_TITLE_FILE" ]]; then
      TITLE_MENU_LINE="\n${pink}Титул:${plain} $(cat "$PREMIUM_TITLE_FILE")${yellow}\n"
    fi
    provider_init_once
    init_telemetry
    update_recommendations  
  while true; do
  	local strategies_status
    strategies_status=$(get_orchestra_locks_info)
    local _cfg_file
    _cfg_file="$(config_get_file 2>/dev/null)" || _cfg_file=""
    menu_config_snapshot "$_cfg_file"
    MENU_ERR_LINE=""
    MENU_ERR_STATE=""
    if [ -s /tmp/nfqws2_1.err ] && grep -v '^seccomp:' /tmp/nfqws2_1.err 2>/dev/null | grep -q .; then
      MENU_ERR_N="$(grep -v '^seccomp:' /tmp/nfqws2_1.err 2>/dev/null | grep -c .)"
      MENU_ERR_LINE="${red}Ошибки nfqws2: ${MENU_ERR_N} — посмотрите п.666 меню${yellow}
"
      MENU_ERR_STATE="${red} (ошибок: ${MENU_ERR_N})${yellow}"
    fi
	TITLE_MENU_LINE=""
    if [[ -s "$PREMIUM_TITLE_FILE" ]]; then
      TITLE_MENU_LINE="\n${pink}Титул:${plain} $(cat "$PREMIUM_TITLE_FILE")${yellow}\n"
    fi
    clear -x
    echo -e "${cyan}========================================${plain}"
    echo -e "${Fcyan}            zeefeer4rocket             ${plain}"
    echo -e "${Fgreen}         z2r - zapret2 Manager          ${plain}"
    echo -e "${cyan}========================================${plain}"
    echo ""
    
    echo -e "
${Fcyan}+-----------------------------------------------------------------+
${Fyellow}     _____     ____ │  ${Fgreen}1 MB / 10 GB${Fyellow}        ${Fpink}⏳${Fyellow}  ETA: КТТС         │
${Fyellow}    /      \  |  o |│  [====>          ]                         │
${Fyellow}   |        |/ ___\|│     ${Fpink}(_o_)${Fyellow} ---->  ${Fcyan}z a t o r${Fyellow}  <---- ${Fpink}(_o_)${Fyellow}    │
${Fyellow}   |_________/      │                                            │
${Fyellow}   |_|_| |_|_|      │  ${Fgreen}speed: 0.0001 Mb/s${Fyellow}   stability: возможно  │
${Fcyan}+-----------------------------------------------------------------+
${plain}
${green}Я черепашка Дейв. И я медленный.${yellow}
${green}Прямо как твой интернет.${yellow}
Город/провайдер: ${plain}${PROVIDER_MENU}${yellow}
Версия config файла от: ${plain}${MENU_CONFIG_DATE}${yellow}
${MENU_ERR_LINE}${TITLE_MENU_LINE}
${green}Выберите необходимое действие:${yellow}
Enter (без цифр) - переустановка/обновление zapret2
${Fyellow}0.${yellow} Выход
${Fcyan}001.${yellow} CDN тест (test.sh)
${Fcyan}01.${yellow} Проверить доступность сервисов (Тест не точен)
${Fcyan}1.${yellow} Фиксация стратегии профиля/безразборного блока. Текущие: ${plain}[ ${strategies_status} ]${yellow} (fallback TLS: ${plain}[$(fallback_strategy_text)]${yellow}, HTTP: ${plain}[$(fallback_http_strategy_text)]${yellow})
${Fcyan}2.${yellow} Стоп/старт zapret2, ${Fcyan}22${yellow} - рестарт (сейчас: $(pidof nfqws2 >/dev/null && echo "${green}Запущен${yellow}" || echo "${red}Остановлен${yellow}"))
${Fcyan}3.${yellow} Запуск blockcheck2 и сохранение SUMMARY
${Fcyan}4.${yellow} Удаление zator и zapret2, ${Fcyan} 44.${yellow} Удаление zapret2
${Fcyan}5.${yellow} Обновить стратегии, сбросить листы подбора стратегий и исключений (есть бэкап)
${Fcyan}6.${yellow} Управление доменами
${Fcyan}7.${yellow} Открыть в редакторе config (Установит nano редактор ~250kb)
${Fcyan}9.${yellow} Переключатель zapret2 на nftables/iptables. Актуально для OpenWRT 21+. Может помочь с войсами. Сейчас: ${plain}[${MENU_FWTYPE}]${yellow}
${Fcyan}10.${yellow} (Де)активировать обход UDP на 1026-65531 портах (BF6, Fifa и т.п.). Сейчас: ${plain}[${MENU_UDP_GAMES}]${yellow}
${Fcyan}11.${yellow} Управление аппаратным ускорением zapret2. Может увеличить скорость на роутере. Сейчас: ${plain}[${MENU_FLOWOFFLOAD}]${yellow}
${Fcyan}12.${yellow} Режим фильтра hostlist/autohostlist. Сейчас: ${plain}[${MENU_HOSTLIST}]${yellow}
${Fcyan}13.${yellow} Безразборный режим (fallback). Сейчас: ${plain}[${MENU_FALLBACK}]${yellow}
${Fcyan}14.${yellow} Web-панель управления (установка/обновление, ~3МБ места)
${Fcyan}15.${yellow} Провайдер
${Fcyan}16.${yellow} Сменить TLS blob (--blob=maxru). Сейчас: ${plain}[${MENU_TLS_BLOB}]${yellow}
${Fcyan}18.${yellow} Защита от RST-инъекций. (BETA) Сейчас: ${plain}[${MENU_RST_GUARD}]${yellow}
${Fcyan}19.${yellow} Доп. настройки (reasm, WG, QUIC-fakes, keenetic)
${Fcyan}20.${yellow} Управление портами NFQWS2 (TCP/UDP). Сейчас: ${plain}[${MENU_PORTS}]${yellow}
${Fcyan}21.${yellow} Управление бэкапами (создание/восстановление/удаление архивов)
${Fcyan}666.${yellow} Ошибки nfqws2 — журнал последнего запуска${MENU_ERR_STATE}
${Fcyan}777.${yellow} Активировать zeefeer premium (Нажимать только Valery ProD, avg97, Xoz, GeGunT, blagodarenya, mikhyan, Xoz, andric62, Whoze, Necronicle, Andrei_5288515371, Nomand, Dina_turat, Nergalss, Александру, АлександруП, vecheromholodno, ЕвгениюГ, Dyadyabo, skuwakin, izzzgoy, Grigaraz, Reconnaissance, comandante1928, umad, rudnev2028, rutakote, railwayfx, vtokarev1604, Grigaraz, a40letbezurojaya и subzeero452 и остальным поддержавшим проект. Но если очень хочется - можно нажать и другим)${plain}"
	echo -e "${Bred}${Fplain}17. Не знаешь, с чего начать? Есть проблемы? Жми сюда!${plain}"
	if [[ -f "$PREMIUM_FLAG" ]]; then
      echo -e "${red}999. Секретный пункт. Нажимать на свой страх и риск${plain}"
    fi
  read -re -p "" answer_menu
    case "$answer_menu" in
  "")
    echo -e "${yellow}Вы уверены, что хотите переустановить/обновить zapret2?${plain}"
    echo -e "${yellow}5 - Да, Enter/0 - Нет (вернуться в меню)${plain}"
    read -r ans
    if [ "$ans" = "5" ] || [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
      # подтверждение: выходим из get_menu и уходим в “тело” (переустановка/обновление)
      return 0
    else
      # отмена: остаёмся в меню, цикл while true продолжится
      :
    fi
    ;;

  "0")
    echo "Выход выполнен"
    exit 0
    ;;

  "01")
    check_access_list
    pause_enter
    ;;

  "001")
    run_cdn_test
    pause_enter
    ;;

  "1")
    strategies_submenu
    ;;

  "2")
    if pidof nfqws2 >/dev/null; then
      ensure_nfqws2_stopped
      echo -e "${green}Выполнена команда остановки zapret2${plain}"
    else
      z2r_service_action start
      echo -e "${green}Выполнена команда запуска zapret2${plain}"
    fi
    pause_enter
    ;;

  "22")
    ensure_nfqws2_stopped
    z2r_service_action start
    echo -e "${green}Выполнена быстрая перезагрузка zapret2 (остановка + запуск)${plain}"
    pause_enter
    ;;

  "3")
    blockcheck2_run_summary
    pause_enter
    ;;

  "4")
    echo -e "${yellow}Внимание! Это приведёт к полному удалению zator и zapret2.${plain}"
    read -re -p $'\033[33mВы действительно хотите удалить zator и zapret2? Введите 5 - подтвердить удаление, 0 - отмена: \033[0m' del_confirm
    case "$del_confirm" in
      "5")
        backup_helper_ask_and_create
        remove_zapret || echo -e "${red}Удаление zapret2 завершилось с ошибкой.${plain}"
        zator_remove || echo -e "${red}Удаление zator завершилось с ошибкой.${plain}"
        echo -e "${yellow}Удаление zator и zapret2 завершено${plain}"
        ;;
      *)
        echo -e "${green}Удаление отменено.${plain}"
        ;;
    esac
    pause_enter
    ;;

  "44")
    echo -e "${yellow}Внимание! Это удалит только zapret2 (каталог zator и его данные, включая Web-панель, останутся).${plain}"
    read -re -p $'\033[33mВы действительно хотите удалить zapret2? Введите 5 - подтвердить удаление, 0 - отмена: \033[0m' del_confirm
    case "$del_confirm" in
      "5")
        backup_helper_ask_and_create
        WEBUI_WAS_RUNNING=0
        webui_status_text 2>/dev/null | grep -q '^running' && WEBUI_WAS_RUNNING=1
        remove_zapret || echo -e "${red}Удаление zapret2 завершилось с ошибкой.${plain}"
        if [ "$WEBUI_WAS_RUNNING" = "1" ]; then
          webui_start_service >/dev/null 2>&1 || true
        fi
        echo -e "${yellow}zapret2 удалён${plain}"
        ;;
      *)
        echo -e "${green}Удаление отменено.${plain}"
        ;;
    esac
    pause_enter
    ;;

  "5")
    backup_helper_ask_and_create
    # Сетевые сбои не должны ронять меню (set -e): модули не критичны,
    # прежние версии продолжают работать.
    locked_lua_update_from_repo || echo -e "${yellow}locked.lua не обновлён (сеть недоступна).${plain}"
    circular_runtime_update_from_repo || echo -e "${yellow}Lua-модули circular не обновлены (сеть недоступна).${plain}"
    strategy_validator_install_service || true
    mkdir -p "$ORCH_DIR"
    chmod 777 "$ORCH_DIR" 2>/dev/null || true
    menu_action_update_config_reset || true
    backup_update_offer_restore
    pause_enter
    ;;

  "6")
    domains_submenu   # сабменю само в цикле и выходит через return
    ;;

  "7")
    if [[ "$OSystem" == "VPS" ]]; then
      apt install nano
    else
      opkg remove nano 2>/dev/null || apk del nano 2>/dev/null
      opkg install nano-full 2>/dev/null || apk add nano-full 2>/dev/null
    fi
    nano "$ZAPRET2_ROOT/config"
    # после выхода из nano
    ;;

  "9")
    fwtype_submenu
    ;;

  "10")
    menu_action_toggle_udp_range
    pause_enter
    ;;

  "11")
    flowoffload_submenu   # сабменю само в цикле и выходит через return
    ;;

  "12")
    toggle_hostlist_mode
    if pidof nfqws2 >/dev/null; then
      z2r_service_action restart
      echo -e "${green}zapret2 перезапущен для применения режима${plain}"
    fi
    pause_enter
    ;;

  "13")
    toggle_fallback_mode
    if pidof nfqws2 >/dev/null; then
      z2r_service_action restart
      echo -e "${green}zapret2 перезапущен для применения режима${plain}"
    fi
    pause_enter
    ;;

  "14")
    webui_submenu
    ;;

  "15")
    provider_submenu      # сабменю само в цикле и выходит через return
    ;;

  "16")
    menu_action_set_tls_blob
    ;;
	
  "17")
    beginner_guide_menu
    ;;

  "18")
    if toggle_rst_guard_mode && pidof nfqws2 >/dev/null; then
      z2r_service_action restart
      echo -e "${green}zapret2 перезапущен для применения RST-защиты${plain}"
    fi
    echo -e "${green}RST-защита: $(config_mode_text rst_guard).${plain}"
    pause_enter
    ;;

  "19")
    advanced_settings_submenu
    ;;

  "20")
    ports_submenu
    ;;

  "21")
    backup_submenu
    ;;

  "666")
    echo "--- Ошибки nfqws2 (последний запуск) ---"
    if [ -s /tmp/nfqws2_1.err ] && grep -v '^seccomp:' /tmp/nfqws2_1.err 2>/dev/null | grep -q .; then
      grep -v '^seccomp:' /tmp/nfqws2_1.err
      echo ""
      echo -e "${yellow}Файл целиком: /tmp/nfqws2_1.err (очищается при каждом перезапуске zapret2)${plain}"
    elif command -v logread >/dev/null 2>&1 \
      && logread 2>/dev/null | grep -i 'nfqws2' | grep -v 'seccomp:' | grep -q .; then
      logread 2>/dev/null | grep -i 'nfqws2' | grep -v 'seccomp:' | tail -20
      echo ""
      echo -e "${yellow}Источник: syslog (logread), последние 20 строк.${plain}"
    else
      echo -e "${green}Ошибок нет: конфиг обработан без замечаний.${plain}"
      command -v logread >/dev/null 2>&1 && echo -e "${yellow}Если проблемы точно есть, а здесь пусто — обновите zapret2 ещё раз (wrt_fixes включает журнал ошибок).${plain}"
    fi
    pause_enter
    ;;

  "777")
   echo -e "${green}Специальный zeefeer premium для Valery ProD, avg97, Xoz, GeGunT, blagodarenya, mikhyan, andric62, Whoze, Necronicle, Andrei_5288515371, Nomand, Dina_turat, Nergalss, Александра, АлександраП, vecheromholodno, ЕвгенияГ, Dyadyabo, skuwakin, izzzgoy, Grigaraz, Reconnaissance, comandante1928, rudnev2028, umad, rutakote, railwayfx, vtokarev1604, Grigaraz, a40letbezurojaya и subzeero452 активирован. Наверное. Так же благодарю поддержавших проект hey_enote, VssA, vladdrazz, Alexey_Tob, Bor1sBr1tva, Azamatstd, iMLT, Qu3Bee, SasayKudasay1, alexander_novikoff, MarsKVV, porfenon123, bobrishe_dazzle, kotov38, Levonkas, DA00001, trin4ik, geodomin, I_ZNA_I, CMyTHblN PacKoJlbHNK и анонимов${plain}"
   zefeer_premium_777
   exit_to_menu
   ;;
  "999")
    zefeer_space_999
    pause_enter
    ;;

  *)
    echo -e "${yellow}Неверный ввод.${plain}"
    sleep 1
    ;;
esac

  done
}

#___Само выполнение скрипта начинается тут____


detect_os
set_zapret2_init
z2r_archive_preflight

#Инфа о времени обновления скрпта
if [ "${Z2R_OFFLINE:-0}" = "1" ]; then
    echo -e "${yellow}zator запущен из локального установочного архива.${plain}"
else
 commit_date="$(z2r_github_commit_date z2r.sh 30)"
 if [[ -z "$commit_date" ]]; then
    echo -e "${red}Не был получен доступ к api.github.com (таймаут 30 сек). Возможны проблемы при установке.${plain}"
	if [ "$hardware" = "keenetic" ]; then
		echo "Добавляем ip с от DNS 1.1.1.1 к api.github.com и пытаемся снова"
		ndmc -c "ip host api.github.com $(nslookup api.github.com 1.1.1.1 | sed -n 's/^Address [0-9]*: \([0-9.]*\).*/\1/p' | tail -n1)"
		echo -e "${yellow}zeefeer обновлен (UTC +0): $(z2r_github_commit_date z2r.sh) ${plain}"
	fi
else
    echo -e "${yellow}zeefeer обновлен (UTC +0): $commit_date ${plain}"
 fi
fi

#Выполнение общего для всех ОС кода с ответвлениями под ОС
#Запрос на установку 3x-ui или аналогов для VPS
if [[ "$OSystem" == "VPS" ]] && [ ! $1 ]; then
 get_panel
fi

#Меню и быстрый запуск подбора стратегии
 if [ -d "$ZATOR_ROOT/extra_strats" ] && [ -f "$ZAPRET2_ROOT/config" ]; then
	if [ $1 ]; then
		Strats_Tryer $1
	fi
    get_menu
 fi
 
while true; do
 #entware keenetic and merlin preinstal env.
 if [ "$hardware" = "keenetic" ]; then
  opkg install coreutils-sort coreutils-nohup grep gzip ipset iptables xtables-addons_legacy 2>/dev/null || apk add coreutils grep gzip ipset iptables xtables-addons_legacy 2>/dev/null
  opkg install kmod_ndms 2>/dev/null || apk add kmod_ndms 2>/dev/null || echo -e "${red}Не удалось установить kmod_ndms. Если у вас не keenetic - игнорируйте.${plain}"
 elif [ "$hardware" = "merlin" ]; then
  opkg install coreutils-sort coreutils-nohup grep gzip ipset iptables xtables-addons_legacy 2>/dev/null || apk add coreutils grep gzip ipset iptables xtables-addons_legacy 2>/dev/null
 fi
 
 #Проверка наличия каталога opt и его создание при необходиомости (для некоторых роутеров), переход в tmp
 mkdir -p /opt
 cd /tmp
 
 if [ -f "$ZAPRET2_ROOT/config" ]; then
   backup_helper_ask_and_create
 fi
 WEBUI_WAS_RUNNING=0
 webui_status_text 2>/dev/null | grep -q '^running' && WEBUI_WAS_RUNNING=1
 
 remove_zapret
 
 #Запрос желаемой версии zapret2
 if [ "${Z2R_OFFLINE:-0}" = "1" ]; then
  echo -e "${yellow}Конфиг будет установлен из локального архива.${plain}"
 else
  echo -e "${yellow}Конфиг обновлен (UTC +0): $(z2r_github_commit_date config.default) ${plain}"
 fi
 version_select
 
 #Скачивание, распаковка архива zapret2 и его удаление
 zapret_get
 
 #Создаём папки и забираем файлы папок lists, fake, extra_strats, копируем конфиг, скрипты для войсов DS, WA, TG
 get_repo
 if [ ! -s "$ORCH_LUA_LOCKED" ]; then
   echo "Повторная попытка загрузки locked.lua..."
   if locked_lua_update_from_repo; then
     echo -e "${green}Повторная загрузка locked.lua успешна.${plain}"
   else
     echo -e "${red}Повторная загрузка locked.lua не удалась.${plain}"
   fi
 fi
 
 # Web-панель: при наличии — обновление, при отсутствии — установка
 if [ -d "$WEBUI_ROOT" ]; then
   read -re -p $'\033[33mWeb-панель управления уже установлена. Обновить её файлы из репозитория? 1 - Да, Enter - нет\033[0m\n' webui_answer
   case "$webui_answer" in
     "1")
       webui_install
     ;;
     *)
       echo "Пропуск обновления Web-панели (текущие файлы не тронуты)"
     ;;
   esac
 else
   read -re -p $'\033[33mУстановить Web-панель управления (~3МБ места)? 1 - Да, Enter - нет\033[0m\n' webui_answer
   case "$webui_answer" in
     "1")
       webui_install
     ;;
     *)
       echo "Пропуск установки Web-панели"
     ;;
   esac
 fi
 
 if [ "$WEBUI_WAS_RUNNING" = "1" ]; then
   webui_start_service >/dev/null 2>&1 || true
 fi
 
 #Для Keenetic и merlin
 if [[ "$OSystem" == "entware" ]]; then
  entware_fixes
  # На Keenetic прописываем IFACE_WAN по default route до запуска install_easy.sh.
  config_keenetic_set_wan_iface_all
 fi

 if [[ "$OSystem" == "WRT" ]]; then
  wrt_fixes || true
 fi
 
 profile_apply_all "$ZAPRET2_ROOT/config.default"
 
 #Для x-wrt
 if [[ "$release" == "x-wrt" ]]; then
 	sed -i 's/kmod-nft-nat kmod-nft-offload/kmod-nft-nat/' "$ZAPRET2_ROOT/common/installer.sh"
 fi
 
 #Запуск установочных скриптов и перезагрузка
 if [ "$hardware" = "keenetic" ]; then
 	 ensure_keenetic_policy_config "$ZAPRET2_ROOT/config.default"
 fi
 install_zapret_reboot
 get_menu
done
