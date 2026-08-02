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

# Optional updater state. На первом этапе эти значения только описывают
# выбранный источник; существующий legacy URL flow ниже не меняется.
Z2R_DEFAULT_SOURCE_RAW_BASE="https://raw.githubusercontent.com/AloofLibra/zator"
Z2R_DEFAULT_SOURCE_REF="zator"
Z2R_UPDATE_DIR="${Z2R_UPDATE_DIR:-/opt/etc/z2r}"
Z2R_UPDATE_CONFIG="${Z2R_UPDATE_CONFIG:-$Z2R_UPDATE_DIR/update.conf}"
Z2R_ORCHESTRA_SNAPSHOT_DIR="${Z2R_ORCHESTRA_SNAPSHOT_DIR:-$Z2R_UPDATE_DIR/orchestra-runtime}"
Z2R_ENV_SOURCE_RAW_BASE="${Z2R_PROJECT_RAW_BASE-}"
Z2R_ENV_SOURCE_REF="${Z2R_BRANCH-}"
Z2R_ENV_SOURCE_REPOSITORY="${Z2R_REPOSITORY-}"
Z2R_ENV_SOURCE_COMMIT="${Z2R_COMMIT-}"

# z2r.sh выполняется из /opt, а рабочие функции — из runtime-каталога.
# Держим список в одном месте: он нужен и для preflight перед удалением
# старого runtime, и для его последующего развёртывания.
Z2R_RUNTIME_LIBRARIES=(
  ui.sh provider.sh telemetry.sh recommendations.sh netcheck.sh premium.sh
  strategies.sh submenus.sh actions.sh config.sh orchestra_state.sh updater.sh
)

z2r_source_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

z2r_source_validate_repository() {
  local repository="$1" owner name
  case "$repository" in */*) ;; *) return 1 ;; esac
  owner="${repository%%/*}"
  name="${repository#*/}"
  [ -n "$owner" ] && [ -n "$name" ] || return 1
  [ "$repository" = "$owner/$name" ] || return 1
  case "$owner$name" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
}

z2r_source_validate_ref() {
  local ref="$1"
  [ -n "$ref" ] || return 1
  case "$ref" in
    [.-]*|[.-]|*/|/*|*//*) return 1 ;;
    *[!A-Za-z0-9._/-]*) return 1 ;;
    *..*|*@\{*|*'/./'*|*'/../'*|./*|../*|*/.|*/..) return 1 ;;
  esac
}

z2r_source_validate_sha() {
  [ "${#1}" -eq 40 ] || return 1
  case "$1" in *[!A-Fa-f0-9]*) return 1 ;; esac
}

z2r_source_validate_base() {
  local base="$1"
  if z2r_source_validate_repository "$base" 2>/dev/null; then
    return 0
  fi
  case "$base" in
    *[[:space:]]*|*\;*|*\&*|*\|*|*\`*|*\$*|*\(*|*\)*|*\<*|*\>*) return 1 ;;
    [A-Za-z][A-Za-z0-9+.-]*://*) return 0 ;;
    *) return 1 ;;
  esac
}

z2r_source_config_error() {
  echo "Ошибка в $Z2R_UPDATE_CONFIG: $1" >&2
  return 1
}

# Читает update.conf как данные. Файл намеренно не source-ится и не eval-ится.
# Z2R_REPOSITORY/Z2R_COMMIT принимаются как совместимые aliases из раннего
# формата proposal, но canonical запись использует raw base + installation ref.
z2r_source_load_config() {
  local raw_base="$Z2R_DEFAULT_SOURCE_RAW_BASE"
  local ref="$Z2R_DEFAULT_SOURCE_REF"
  local repository="" commit="" line key value legacy_path config_present=0

  if [ -f "$Z2R_UPDATE_CONFIG" ]; then
    config_present=1
    while IFS= read -r line || [ -n "$line" ]; do
      line="$(z2r_source_trim "$line")"
      [ -z "$line" ] && continue
      case "$line" in \#*) continue ;; esac
      case "$line" in *=*) ;; *) z2r_source_config_error "ожидался KEY=VALUE"; return 1 ;; esac
      key="$(z2r_source_trim "${line%%=*}")"
      value="$(z2r_source_trim "${line#*=}")"
      case "$key" in
        Z2R_PROJECT_RAW_BASE|Z2R_BRANCH|Z2R_REPOSITORY|Z2R_COMMIT) ;;
        *) z2r_source_config_error "неизвестный ключ $key"; return 1 ;;
      esac
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
        *[[:space:]]*|*\"*|*\'*|*\\*|*\$*|*\`*|*\;*|*\(*|*\)*|*\&*|*\|*)
          z2r_source_config_error "небезопасное значение для $key"; return 1 ;;
      esac
      case "$key" in
        Z2R_PROJECT_RAW_BASE) raw_base="$value" ;;
        Z2R_BRANCH) ref="$value" ;;
        Z2R_REPOSITORY) repository="$value" ;;
        Z2R_COMMIT) commit="$value" ;;
      esac
    done < "$Z2R_UPDATE_CONFIG"
  fi

  [ -n "$repository" ] && raw_base="https://raw.githubusercontent.com/$repository"
  [ -n "$commit" ] && ref="$commit"
  [ -n "$Z2R_ENV_SOURCE_RAW_BASE" ] && raw_base="$Z2R_ENV_SOURCE_RAW_BASE"
  [ -n "$Z2R_ENV_SOURCE_REPOSITORY" ] && raw_base="https://raw.githubusercontent.com/$Z2R_ENV_SOURCE_REPOSITORY"
  [ -n "$Z2R_ENV_SOURCE_REF" ] && ref="$Z2R_ENV_SOURCE_REF"
  [ -n "$Z2R_ENV_SOURCE_COMMIT" ] && ref="$Z2R_ENV_SOURCE_COMMIT"

  # Старый контракт позволял передать уже собранный raw URL, включая ref.
  # Если отдельный Z2R_BRANCH не задан, извлекаем его и приводим base к root.
  if [ -z "$Z2R_ENV_SOURCE_REF" ] && [ -z "$Z2R_ENV_SOURCE_COMMIT" ]; then
    case "$raw_base" in
      https://raw.githubusercontent.com/*/*/*|http://raw.githubusercontent.com/*/*/*)
        legacy_path="${raw_base#*://}"
        legacy_path="${legacy_path#*/}"
        legacy_path="${legacy_path#*/}"
        legacy_path="${legacy_path#*/}"
        if [ -n "$legacy_path" ]; then
          ref="$legacy_path"
          raw_base="${raw_base%/$legacy_path}"
        fi
        ;;
    esac
  fi

  z2r_source_validate_base "$raw_base" || { z2r_source_config_error "некорректный project source"; return 1; }
  z2r_source_validate_ref "$ref" || { z2r_source_config_error "некорректный installation ref"; return 1; }
  [ -z "$repository" ] || z2r_source_validate_repository "$repository" || {
    z2r_source_config_error "repository должен иметь вид owner/name"; return 1;
  }
  if [ -n "$commit" ]; then
    z2r_source_validate_sha "$commit" || { z2r_source_config_error "commit должен быть полным 40-символьным SHA"; return 1; }
  fi
  if [ -n "$Z2R_ENV_SOURCE_COMMIT" ]; then
    z2r_source_validate_sha "$Z2R_ENV_SOURCE_COMMIT" || { z2r_source_config_error "Z2R_COMMIT должен быть полным 40-символьным SHA"; return 1; }
  fi

  Z2R_SOURCE_RAW_BASE="$raw_base"
  Z2R_SOURCE_REF="$ref"
  Z2R_SOURCE_CONFIG_PRESENT="$config_present"
  if [ -n "$Z2R_ENV_SOURCE_RAW_BASE" ] || [ -n "$Z2R_ENV_SOURCE_REF" ] || [ -n "$Z2R_ENV_SOURCE_REPOSITORY" ] || [ -n "$Z2R_ENV_SOURCE_COMMIT" ]; then
    Z2R_SOURCE_CONFIG_ORIGIN="environment"
  elif [ "$config_present" -eq 1 ]; then
    Z2R_SOURCE_CONFIG_ORIGIN="config"
  else
    Z2R_SOURCE_CONFIG_ORIGIN="default"
  fi
  export Z2R_SOURCE_RAW_BASE Z2R_SOURCE_REF Z2R_SOURCE_CONFIG_PRESENT Z2R_SOURCE_CONFIG_ORIGIN
}

z2r_source_write_config() {
  local raw_base="$1" ref="$2" tmp="${Z2R_UPDATE_CONFIG}.tmp.$$" old_umask
  z2r_source_validate_base "$raw_base" || { echo "Некорректный project source: $raw_base" >&2; return 1; }
  z2r_source_validate_ref "$ref" || { echo "Некорректный installation ref: $ref" >&2; return 1; }
  mkdir -p "$Z2R_UPDATE_DIR" || return 1
  old_umask="$(umask)"
  umask 077
  {
    printf 'Z2R_PROJECT_RAW_BASE="%s"\n' "$raw_base"
    printf 'Z2R_BRANCH="%s"\n' "$ref"
  } > "$tmp" || { umask "$old_umask"; rm -f "$tmp"; return 1; }
  umask "$old_umask"
  if [ -f "$Z2R_UPDATE_CONFIG" ] && cmp -s "$tmp" "$Z2R_UPDATE_CONFIG"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$Z2R_UPDATE_CONFIG"
  fi
}

if ! z2r_source_load_config; then
  exit 1
fi


z2r_github_commit_date() {
  local path="$1" timeout="${2:-10}"
  curl -s --max-time "$timeout" "https://api.github.com/repos/AloofLibra/zator/commits?path=${path}&per_page=1" \
    | grep '"date"' | head -n1 | cut -d'"' -f4
}

Z2R_BRANCH="${Z2R_BRANCH:-zator}"
Z2R_PROJECT_RAW_BASE="${Z2R_PROJECT_RAW_BASE:-https://raw.githubusercontent.com/AloofLibra/zator/${Z2R_BRANCH}}"
Z2R_PROJECT_MIRROR_BASE="${Z2R_PROJECT_MIRROR_BASE:-https://git.px.rkn.quest/AloofLibra/plain}"
Z2R_INSTALLER_URL="${Z2R_INSTALLER_URL:-${Z2R_PROJECT_RAW_BASE}/z2r.sh}"
Z2R_LEGACY_INSTALLER_URL="${Z2R_LEGACY_INSTALLER_URL:-https://git.px.rkn.quest/AloofLibra/plain/z2r.sh?h=zator}"
ZAPRET2_UPSTREAM_RAW_BASE="${ZAPRET2_UPSTREAM_RAW_BASE:-https://raw.githubusercontent.com/bol-van/zapret2/master}"
ZAPRET2_UPSTREAM_MIRROR_BASE="${ZAPRET2_UPSTREAM_MIRROR_BASE:-https://git.px.rkn.quest/zapret2/plain}"
ZAPRET2_RELEASE_BASE="${ZAPRET2_RELEASE_BASE:-https://github.com/bol-van/zapret2/releases/download}"
ZAPRET2_RELEASE_MIRROR_BASE="${ZAPRET2_RELEASE_MIRROR_BASE:-}"
ZAPRET2_YANDEX_0952="${ZAPRET2_YANDEX_0952:-https://disk.yandex.ru/d/M26CLc7XCEV_og}"
ZAPRET2_YANDEX_0952_OPENWRT="${ZAPRET2_YANDEX_0952_OPENWRT:-https://disk.yandex.ru/d/ER1R2TNw8f7KYA}"

z2r_mirror_url() {
  printf '%s/%s?h=%s' "$Z2R_PROJECT_MIRROR_BASE" "$1" "$Z2R_BRANCH"
}

z2r_fetch_url_to_file() {
  local dest="$1"
  local url="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" "$url"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
    return $?
  fi
  return 127
}

z2r_fetch_url_stdout() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
    return $?
  fi
  return 127
}

z2r_source_repository_from_base() {
  local base="$1" rest owner repository
  case "$base" in
    */*) ;;
    *) return 1 ;;
  esac

  case "$base" in
    https://github.com/*|http://github.com/*|https://www.github.com/*|http://www.github.com/*)
      rest="${base#*://}"
      rest="${rest#*/}"
      ;;
    https://raw.githubusercontent.com/*|http://raw.githubusercontent.com/*)
      rest="${base#*://}"
      rest="${rest#*/}"
      ;;
    [A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*)
      z2r_source_validate_repository "$base" || return 1
      printf '%s\n' "$base"
      return 0
      ;;
    *) return 1 ;;
  esac

  owner="${rest%%/*}"
  rest="${rest#*/}"
  repository="${rest%%/*}"
  [ -n "$owner" ] && [ -n "$repository" ] || return 1
  z2r_source_validate_repository "$owner/$repository" || return 1
  printf '%s/%s\n' "$owner" "$repository"
}

z2r_source_raw_root() {
  local repository="$1" raw_base="$2"
  if [ -n "$repository" ]; then
    printf 'https://raw.githubusercontent.com/%s\n' "$repository"
  else
    printf '%s\n' "${raw_base%/}"
  fi
}

z2r_source_resolve_ref() {
  local repository="$1" ref="$2" response commit

  if z2r_source_validate_sha "$ref"; then
    printf '%s\n' "$ref"
    return 0
  fi
  [ -n "$repository" ] || return 1

  response="$(z2r_fetch_url_stdout "${Z2R_GITHUB_API_BASE:-https://api.github.com}/repos/${repository}/commits/${ref}")" || return 1
  commit="$(printf '%s\n' "$response" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([A-Fa-f0-9][A-Fa-f0-9]*\)".*/\1/p' | head -n 1)"
  z2r_source_validate_sha "$commit" || return 1
  printf '%s\n' "$commit"
}

z2r_source_prepare() {
  local repository raw_root commit
  repository="$(z2r_source_repository_from_base "$Z2R_SOURCE_RAW_BASE" 2>/dev/null || true)"
  raw_root="$(z2r_source_raw_root "$repository" "$Z2R_SOURCE_RAW_BASE")"
  commit="$(z2r_source_resolve_ref "$repository" "$Z2R_SOURCE_REF")" || {
    echo "Не удалось разрешить installation ref '$Z2R_SOURCE_REF' в точный commit." >&2
    return 1
  }

  Z2R_SOURCE_REPOSITORY="$repository"
  Z2R_SOURCE_RAW_ROOT="$raw_root"
  Z2R_SOURCE_RESOLVED_COMMIT="$commit"
  Z2R_SOURCE_STRICT=1
  export Z2R_SOURCE_REPOSITORY Z2R_SOURCE_RAW_ROOT Z2R_SOURCE_RESOLVED_COMMIT Z2R_SOURCE_STRICT
}

z2r_source_raw_url() {
  local rel="$1"
  case "$rel" in ''|/*|*'..'*) return 1 ;; esac
  [ -n "${Z2R_SOURCE_RAW_ROOT:-}" ] || return 1
  [ -n "${Z2R_SOURCE_RESOLVED_COMMIT:-}" ] || return 1
  printf '%s/%s/%s\n' "$Z2R_SOURCE_RAW_ROOT" "$Z2R_SOURCE_RESOLVED_COMMIT" "$rel"
}

z2r_launcher_path() {
  local launcher="${1:-$0}" target attempts=0
  if [ "$#" -eq 0 ] && [ -n "${Z2R_LAUNCHER_PATH:-}" ]; then
    printf '%s\n' "$Z2R_LAUNCHER_PATH"
    return 0
  fi
  if [ "${launcher#*/}" = "$launcher" ]; then
    launcher="$(command -v "$launcher" 2>/dev/null)" || return 1
  fi
  while [ -L "$launcher" ] && [ "$attempts" -lt 8 ]; do
    target="$(readlink "$launcher" 2>/dev/null)" || return 1
    case "$target" in
      /*) launcher="$target" ;;
      *) launcher="$(dirname -- "$launcher")/$target" ;;
    esac
    attempts=$((attempts + 1))
  done
  [ ! -L "$launcher" ] || return 1
  cd -- "$(dirname -- "$launcher")" 2>/dev/null || return 1
  printf '%s/%s\n' "$(pwd)" "$(basename -- "$launcher")"
}

z2r_bootstrap_refresh_launcher() {
  local launcher tmp url shell_bin
  [ "${Z2R_DISABLE_SELF_REFRESH:-0}" = "1" ] && return 0
  [ "${Z2R_SELF_REFRESHED:-0}" = "1" ] && return 0
  launcher="$(z2r_launcher_path)" || return 0
  case "$launcher" in
    /opt/*) ;;
    "${Z2R_SELF_REFRESH_ROOT:-/nonexistent}"/*) [ -n "${Z2R_SELF_REFRESH_ROOT:-}" ] || return 0 ;;
    *) return 0 ;;
  esac
  if [ -z "${Z2R_LAUNCHER_PATH:-}" ] && [ "$(basename -- "$launcher")" != "z2r.sh" ]; then
    return 0
  fi
  z2r_source_prepare >/dev/null 2>&1 || return 0
  url="$(z2r_source_raw_url z2r.sh)" || return 0
  tmp="${launcher}.new.$$"
  rm -f "$tmp"
  z2r_fetch_url_to_file "$tmp" "$url" || { rm -f "$tmp"; return 0; }
  bash -n "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 0; }
  if cmp -s "$tmp" "$launcher"; then
    rm -f "$tmp"
    return 0
  fi
  chmod 755 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$launcher" || { rm -f "$tmp"; return 0; }
  shell_bin="$(command -v bash 2>/dev/null || true)"
  [ -n "$shell_bin" ] || return 0
  Z2R_SELF_REFRESHED=1 exec "$shell_bin" "$launcher" "$@"
}

z2r_install_persistent_launcher() {
  local command_launcher="${Z2R_COMMAND_LAUNCHER:-/opt/bin/z2r}"
  local runtime_launcher="${Z2R_RUNTIME_LAUNCHER:-/opt/z2r.sh}"
  local backup="${Z2R_UPDATE_DIR}/legacy-bootstrap.z2r"
  local shell_bin tmp old_umask

  [ "${Z2R_DISABLE_PERSISTENT_LAUNCHER:-0}" = "1" ] && return 0
  [ -x "$runtime_launcher" ] || return 0
  mkdir -p "$(dirname "$command_launcher")" "$Z2R_UPDATE_DIR" || return 1
  shell_bin="$(command -v bash 2>/dev/null || true)"
  [ -n "$shell_bin" ] || return 0
  if [ -f "$command_launcher" ] && grep -F '# z2r persistent launcher' "$command_launcher" >/dev/null 2>&1; then
    return 0
  fi
  if [ -f "$command_launcher" ] && [ ! -e "$backup" ]; then
    cp -p "$command_launcher" "$backup" || return 1
  fi
  tmp="${command_launcher}.new.$$"
  old_umask="$(umask)"
  umask 022
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# z2r persistent launcher'
    printf 'exec "%s" "%s" "$@"\n' "$shell_bin" "$runtime_launcher"
  } > "$tmp" || { umask "$old_umask"; rm -f "$tmp"; return 1; }
  umask "$old_umask"
  chmod 755 "$tmp" || { rm -f "$tmp"; return 1; }
  if cmp -s "$tmp" "$command_launcher"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$command_launcher"
  fi
}

z2r_download_project_file() {
  local dest="$1"
  local rel="$2"
  local tmp="${dest}.tmp.$$"
  local primary="${Z2R_PROJECT_RAW_BASE}/${rel}"
  local mirror

  if [ "${Z2R_SOURCE_STRICT:-0}" != "1" ]; then
    z2r_source_prepare || return 1
  fi
  if [ "${Z2R_SOURCE_STRICT:-0}" = "1" ]; then
    primary="$(z2r_source_raw_url "$rel")" || return 1
    mirror=""
  else
    mirror="$(z2r_mirror_url "$rel")"
  fi
  mkdir -p "$(dirname "$dest")"
  rm -f "$tmp"
  if type z2r_source_cache_restore >/dev/null 2>&1 && z2r_source_cache_restore "$rel" "$tmp"; then
    mv -f "$tmp" "$dest"
    type z2r_source_track_file >/dev/null 2>&1 && z2r_source_track_file "$dest" "$rel"
    return 0
  fi
  if z2r_fetch_url_to_file "$tmp" "$primary"; then
    type z2r_source_cache_store >/dev/null 2>&1 && z2r_source_cache_store "$rel" "$tmp" || true
    mv -f "$tmp" "$dest"
    type z2r_source_track_file >/dev/null 2>&1 && z2r_source_track_file "$dest" "$rel"
    return 0
  fi
  [ -n "$mirror" ] || { rm -f "$tmp"; return 1; }
  echo -e "${yellow}GitHub недоступен для $rel. Пробую зеркало.${plain}" >&2
  rm -f "$tmp"
  if z2r_fetch_url_to_file "$tmp" "$mirror"; then
    mv -f "$tmp" "$dest"
    return 0
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
  local installer_url="" shell_bin
  local tmp="/tmp/z2r_installer_$$"

  if z2r_source_prepare >/dev/null 2>&1; then
    installer_url="$(z2r_source_raw_url z2r.sh)"
    if z2r_fetch_url_to_file "$tmp" "$installer_url"; then
      shell_bin="$(command -v bash 2>/dev/null || true)"
      [ -n "$shell_bin" ] && exec "$shell_bin" "$tmp" "$@"
    fi
  fi
  if [ "$Z2R_SOURCE_CONFIG_ORIGIN" = "default" ] && z2r_fetch_url_to_file "$tmp" "$Z2R_LEGACY_INSTALLER_URL"; then
    shell_bin="$(command -v bash 2>/dev/null || true)"
    [ -n "$shell_bin" ] && exec "$shell_bin" "$tmp" "$@"
  fi
  rm -f "$tmp"
  echo "Ошибка: не удалось загрузить внешний z2r."
  exit 1
}

#___Проверка на наличие необходимых библиотек___#

#Определяем путь скрипта, подгружаем функции
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

# Проверяем наличие всех нужных lib-файлов, иначе запускаем внешний скрипт
missing_libs=0
LIB_DIR="$SCRIPT_DIR/zapret2/z2r_lib"
for lib in ui.sh provider.sh telemetry.sh recommendations.sh netcheck.sh premium.sh strategies.sh submenus.sh actions.sh config.sh orchestra_state.sh; do
  if [ ! -f "$LIB_DIR/$lib" ]; then
    missing_libs=1
    break
  fi
done

if [ "$missing_libs" -ne 0 ]; then
  echo "Не найдены нужные файлы в $LIB_DIR. Запускаю внешний z2r..."
  z2r_exec_external_installer "$@"
fi

z2r_bootstrap_sync_updater_module() {
  local dest="$LIB_DIR/updater.sh" tmp url
  [ -d "$LIB_DIR" ] || return 1
  [ -s "$dest" ] && return 0
  z2r_source_prepare >/dev/null 2>&1 || return 1
  url="$(z2r_source_raw_url lib/updater.sh)" || return 1
  tmp="${dest}.tmp.$$"
  rm -f "$tmp"
  z2r_fetch_url_to_file "$tmp" "$url" || { rm -f "$tmp"; return 1; }
  bash -n "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
}

z2r_bootstrap_sync_updater_module || true
if [ -s "$LIB_DIR/updater.sh" ]; then
  # shellcheck disable=SC1090
  source "$LIB_DIR/updater.sh"
elif [ -s "$SCRIPT_DIR/lib/updater.sh" ]; then
  # Удобно для запуска из checkout; на роутере используется только runtime-копия.
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/lib/updater.sh"
fi

#___Общие вспомогательные функции____

# Нормализация введённого значения в чистый домен.
# Убираем пробелы, схему (http/https/ftp), userinfo, путь, порт, крайние точки.
# Глобальная функция: используется и в меню z2r.sh, и в lib/strategies.sh.
# Возвращает 0 и печатает чистый домен, либо 1 (мусор/пусто).
z2r_normalize_domain() {
  local d="$1"
  # обрезаем пробелы по краям
  d="${d#"${d%%[![:space:]]*}"}"
  d="${d%"${d##*[![:space:]]}"}"
  [ -z "$d" ] && return 1
  # приводим к нижнему регистру без классов tr: BusyBox tr для совместимости с OpenWRT
  d="$(printf '%s' "$d" | sed 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/')"
  # убираем схему (http://, https://, ftp:// ...)
  d="${d#*://}"
  # убираем userinfo (всё до последнего @)
  d="${d##*@}"
  # убираем путь (всё после первого /)
  d="${d%%/*}"
  # убираем порт (всё после :)
  d="${d%%:*}"
  # убираем ведущую точку (.ru -> ru)
  d="${d#.}"
  # убираем завершающую точку (example.com. -> example.com)
  d="${d%.}"
  # пусто — отбрасываем
  [ -z "$d" ] && return 1
  # только допустимые символы: a-z 0-9 . -
  case "$d" in *[!a-z0-9.-]*) return 1 ;; esac
  # должен быть хотя бы один буквенно-цифровой символ
  case "$d" in *[a-z0-9]*) : ;; *) return 1 ;; esac
  printf '%s\n' "$d"
}

#___Сначала идут анонсы функций____

# UI helpers (пауза/печать пунктов меню/совместимость старого кода)
# Функции: pause_enter, submenu_item, exit_to_menu
source "$SCRIPT_DIR/zapret2/z2r_lib/ui.sh" 

# Определение провайдера/города + ручная установка/сброс кэша
# Функции: provider_init_once, provider_force_redetect, provider_set_manual_menu
# (внутр.: _detect_api_simple)
source "$SCRIPT_DIR/zapret2/z2r_lib/provider.sh" 

# Телеметрия (вкл/выкл один раз + отправка статистики в Google Forms)
# Функции: init_telemetry, send_stats
source "$SCRIPT_DIR/zapret2/z2r_lib/telemetry.sh" 

# Общий API для чтения и правки /opt/zapret2/config
source "$SCRIPT_DIR/zapret2/z2r_lib/config.sh"

# Общий API ручных локов стратегий
source "$SCRIPT_DIR/zapret2/z2r_lib/orchestra_state.sh"

# База подсказок по стратегиям (скачивание + вывод подсказки по провайдеру)
# Функции: update_recommendations, show_hint
source "$SCRIPT_DIR/zapret2/z2r_lib/recommendations.sh" 

# Проверка доступности ресурсов/сети (TLS 1.2/1.3) + получение домена кластера youtube (googlevideo)
# Функции: get_yt_cluster_domain, check_access, check_access_list
source "$SCRIPT_DIR/zapret2/z2r_lib/netcheck.sh"

# “Premium” пункты 777/999 и их вспомогательные эффекты (рандом, спиннер, титулы)
# Функции: rand_from_list, spinner_for_seconds, premium_get_or_set_title, zefeer_premium_777, zefeer_space_999
source "$SCRIPT_DIR/zapret2/z2r_lib/premium.sh" 

# Логика стратегий: статус, lock-файлы, быстрый подбор
# Функции: get_current_strategies_info, orch_profile_try, Strats_Tryer
source "$SCRIPT_DIR/zapret2/z2r_lib/strategies.sh" 

# Подменю (UI-обвязка стратегий + доп. меню управления: FLOWOFFLOAD, TCP443, провайдер)
# Функции: strategies_submenu, flowoffload_submenu, tcp443_submenu, provider_submenu, beginner_guide_menu
source "$SCRIPT_DIR/zapret2/z2r_lib/submenus.sh" 

# Действия меню (бэкапы/сбросы/переключатели)
# Функции: backup_strats, menu_action_update_config_reset,
#          menu_action_toggle_fwtype, menu_action_toggle_udp_range, menu_action_set_tls_blob
source "$SCRIPT_DIR/zapret2/z2r_lib/actions.sh" 

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
  if [ "$OSystem" = "WRT" ] && [ -f "/opt/zapret2/init.d/openwrt/zapret2" ]; then
    ZAPRET2_INIT="/opt/zapret2/init.d/openwrt/zapret2"
  else
    ZAPRET2_INIT="/opt/zapret2/init.d/sysv/zapret2"
  fi
  export ZAPRET2_INIT
}

cleanup_zapret2_init_dirs() {
  local init_dir="/opt/zapret2/init.d"

  [ -d "$init_dir" ] || return 0

  if [ "$OSystem" = "WRT" ]; then
    rm -rf "$init_dir/sysv"
  else
    rm -rf "$init_dir/openwrt"
  fi
}

ORCH_DIR="/opt/zapret2/extra_strats/cache/orchestra"
ORCH_LUA_LOCKED="/opt/zapret2/lua/locked.lua"
RST_GUARD_LUA="/opt/zapret2/lua/rst-guard.lua"

locked_lua_update_from_repo() {
  mkdir -p "$ORCH_DIR" "$(dirname "$ORCH_LUA_LOCKED")"
  if ! z2r_download_project_file "$ORCH_LUA_LOCKED" "orchestra/locked.lua"; then
    echo -e "${red}Не удалось скачать locked.lua.${plain}"
    return 1
  fi
  echo -e "${green}locked.lua обновлен из репозитория.${plain}"
}

rst_guard_lua_update_from_repo() {
  mkdir -p "$(dirname "$RST_GUARD_LUA")"
  if ! z2r_download_project_file "$RST_GUARD_LUA" "lua/rst-guard.lua"; then
    echo -e "${red}Не удалось скачать rst-guard.lua.${plain}"
    return 1
  fi
  echo -e "${green}rst-guard.lua обновлен из репозитория.${plain}"
}

# Проверяем locked.lua, при отсутствии пробуем скачать из репозитория
if [ -f /opt/zapret2/config ]; then
  if [ ! -s "$ORCH_LUA_LOCKED" ]; then
    echo "Не найден locked.lua. Пытаюсь скачать из репозитория..."
    locked_lua_update_from_repo || true
  fi
  if [ ! -s "$RST_GUARD_LUA" ]; then
    echo "Не найден rst-guard.lua. Пытаюсь скачать из репозитория..."
    rst_guard_lua_update_from_repo || true
  fi
fi

_fallback_strategy_text() {
  local profile="$1" proto="$2"
  local file="/opt/zapret2/extra_strats/cache/orchestra/locked.manual.tsv"
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

set_fallback_strategy() {
  local file="/opt/zapret2/extra_strats/cache/orchestra/locked.manual.tsv"
  local tmp="${file}.tmp"
  if type check_access >/dev/null 2>&1; then
    check_access "https://5fd8bdae.nip.io/1MB.bin"
  fi
  read -re -p "Введите номер стратегии для безразборного блока: " strategy_num
  mkdir -p /opt/zapret2/extra_strats/cache/orchestra
  if [ -z "$strategy_num" ]; then
    echo "Ввод пустой, ничего не изменено"
  elif ! echo "$strategy_num" | grep -Eq '^[0-9]+$'; then
    echo -e "${red}Некорректный номер стратегии.${plain}"
  else
    if [ -f "$file" ]; then
      awk -F '\t' '$1!="8" || $2!="tls"' "$file" > "$tmp"
    else
      : > "$tmp"
    fi
    printf "8\ttls\t%s\n" "$strategy_num" >> "$tmp"
    mv "$tmp" "$file"
    echo -e "${green}Стратегия $strategy_num закреплена для безразборного блока.${plain}"
  fi
}

_fallback_profile_try() {
  local profile="$1" title="$2" proto="$3" test_url="$4"
  local prev_lock_file="${ORCH_LOCK_FILE:-/opt/zapret2/extra_strats/cache/orchestra/locked.tsv}"
  ORCH_LOCK_FILE="/opt/zapret2/extra_strats/cache/orchestra/locked.manual.tsv"
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
   if /opt/zapret2/nfq2/nfqws2 --dry-run --user="nobody" 2>&1 | grep -q "queue"; then
    echo "WS_USER=nobody"
	sed -i 's/^#\(WS_USER=nobody\)/\1/' /opt/zapret2/config.default
   elif /opt/zapret2/nfq2/nfqws2 --dry-run --user="$(head -n1 /etc/passwd | cut -d: -f1)" 2>&1 | grep -q "queue"; then
    echo "WS_USER=$(head -n1 /etc/passwd | cut -d: -f1)"
    sed -i "s/^#WS_USER=nobody$/WS_USER=$(head -n1 /etc/passwd | cut -d: -f1)/" "/opt/zapret2/config.default"
   else
    echo -e "${yellow}WS_USER не подошёл. Скорее всего будут проблемы. Если что - пишите в саппорт${plain}"
   fi
}

ensure_nfqws2_stopped() {
  "$ZAPRET2_INIT" stop
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
  local blockcheck_path="/opt/zapret2/blockcheck2.sh"
  local test_name="z4r"
  local default_target="static.rutracker.cc/templates/v1/min/4e695e8ea9cf5a1dcc7aed231b887c51.lib.min.js"
  local test_target="${Z2R_BLOCKCHECK2_DOMAINS:-$default_target}"
  local log_dir="/tmp/zapret2/cache/blockcheck2"
  local provider_file="/opt/zapret2/extra_strats/cache/provider.txt"
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
  summary_public="/opt/zapret2/blockcheck2_summary.txt"

  echo -e "${yellow}Запускаю blockcheck2 TEST=$test_name для $test_target...${plain}"
  start_ts="$(date +%s)"
  CURL_HTTPS_GET=1 BATCH=1 TEST="$test_name" DOMAINS="$test_target" ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=1 ENABLE_HTTPS_TLS13=1 ENABLE_HTTP3=0 BC2_PROGRESS_FILE="$progress_file" ZAPRET_BASE=/opt/zapret2 "$blockcheck_path" >"$log_file" 2>&1 &
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
    "$ZAPRET2_INIT" restart
    echo -e "${green}zapret2 восстановлен (restart)${plain}"
  fi

  return $rc
}

blockcheck2_prepare_z4r_test() {
  local test_dir="/opt/zapret2/blockcheck2.d/z4r"
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
              -H "Range: bytes=0-${thr}" \
              --connect-timeout 5 \
              --max-time 5 \
              -o /dev/null \
              -w '%{size_download} %{http_code}' \
              "$url")

          total=$((total+bytes))
      done

      avg=$((total/times))

      if (( avg >= thr )) && [[ "$code" =~ ^2|3 ]]; then
          echo -e "${GREEN}$id OK${NC} ${avg}b [$provider]"
          echo OK >> /tmp/cdn_ok
      else
          echo -e "${RED}$id FAIL${NC} ${avg}b code=$code [$provider]"
          echo FAIL >> /tmp/cdn_fail
      fi
  }

  export -f check_one
  export BIN_THR_BYTES PARALLEL GREEN RED YELLOW NC

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

# Скачивает обязательный набор zator в SHA-scoped cache до удаления runtime.
# Так сетевой сбой не оставляет пользователя без уже работавшего /opt/zapret2.
z2r_stage_project_core() {
  local stage_dir rel safe_rel
  local -a project_files=(
    "orchestra/locked.lua"
    "lua/rst-guard.lua"
    "lists/cloudflare-ipset.txt"
    "lists/cloudflare-ipset_v6.txt"
    "lists/netrogat.txt"
    "lists/russia-discord.txt"
    "lists/russia-youtube-rtmps.txt"
    "lists/russia-youtube.txt"
    "lists/russia-youtubeQ.txt"
    "lists/tg_cidr.txt"
    "fake_files.tar.gz"
    "fake/custom_tls.bin"
    "extra_strats/UDP/YT/List.txt"
    "extra_strats/TCP/RKN/List.txt"
    "extra_strats/TCP/RKN/Custom.txt"
    "extra_strats/TCP/YT/List.txt"
    "extra_strats/TCP/RKN/Discord.txt"
    "extra_strats/TCP/RKN/Domains_By_Substring.txt"
    "blockcheck2.d/z4r/10-list.sh"
    "blockcheck2.d/z4r/list_https_tls12.txt"
    "blockcheck2.d/z4r/list_https_tls13.txt"
    "config.default"
  )

  for rel in "${Z2R_RUNTIME_LIBRARIES[@]}"; do
    project_files+=("lib/$rel")
  done

  [ "$hardware" = "keenetic" ] && project_files+=("Entware/keenetic-policy.sh")
  [ "$OSystem" = "entware" ] && project_files+=("Entware/zapret" "Entware/000-zapret.sh" "Entware/S00fix")
  stage_dir="$(mktemp -d /tmp/z2r-project-stage.XXXXXX)" || return 1
  for rel in "${project_files[@]}"; do
    safe_rel="$(printf '%s' "$rel" | tr '/' '@')"
    if ! z2r_download_project_file "$stage_dir/$safe_rel" "$rel"; then
      rm -rf "$stage_dir"
      echo "Не удалось подготовить $rel из выбранного source." >&2
      return 1
    fi
  done
  rm -rf "$stage_dir"
}

#Создаём папки и забираем файлы папок lists, fake, extra_strats, копируем конфиг
get_repo() {
  local fake_archive="/tmp/z2r_fake_files_$$.tar.gz"

  z2r_source_prepare || return 1
  if type z2r_source_track_begin >/dev/null 2>&1; then
    z2r_source_track_begin || return 1
  fi
  mkdir -p /opt/zapret2/lists /opt/zapret2/extra_strats /opt/zapret2/extra_strats/cache /opt/zapret2/files/fake
  mkdir -p /opt/zapret2/extra_strats/cache/orchestra
  mkdir -p /opt/zapret2/z2r_lib
  for lib in "${Z2R_RUNTIME_LIBRARIES[@]}"; do
    z2r_download_project_file "/opt/zapret2/z2r_lib/$lib" "lib/$lib" || return 1
  done
  chmod 777 /opt/zapret2/extra_strats/cache/orchestra 2>/dev/null || true
  locked_lua_update_from_repo || true
  rst_guard_lua_update_from_repo || true
  for listfile in cloudflare-ipset.txt cloudflare-ipset_v6.txt netrogat.txt russia-discord.txt russia-youtube-rtmps.txt russia-youtube.txt russia-youtubeQ.txt tg_cidr.txt; do
    z2r_download_project_file "/opt/zapret2/lists/$listfile" "lists/$listfile" || return 1
  done
  z2r_download_project_file "$fake_archive" "fake_files.tar.gz" || return 1
  tar -xzf "$fake_archive" -C /opt/zapret2/files/fake || {
    rm -f "$fake_archive"
    return 1
  }
  rm -f "$fake_archive"
  z2r_download_project_file /opt/zapret2/extra_strats/UDP_YT_list.txt "extra_strats/UDP/YT/List.txt" || return 1
  z2r_download_project_file /opt/zapret2/extra_strats/TCP_RKN_list.txt "extra_strats/TCP/RKN/List.txt" || return 1
  z2r_download_project_file /opt/zapret2/extra_strats/TCP_Custom.txt "extra_strats/TCP/RKN/Custom.txt" || return 1
  z2r_download_project_file /opt/zapret2/extra_strats/TCP_YT_list.txt "extra_strats/TCP/YT/List.txt" || return 1
  z2r_download_project_file /opt/zapret2/extra_strats/TCP_Discord.txt "extra_strats/TCP/RKN/Discord.txt" || return 1
  blockcheck2_prepare_z4r_test || return 1
  if [ ! -f /opt/zapret2/files/fake/custom_tls.bin ]; then
    mkdir -p /opt/zapret2/files/fake
    if ! z2r_download_project_file /opt/zapret2/files/fake/custom_tls.bin "fake/custom_tls.bin"; then
      echo -e "${yellow}Не удалось скачать custom_tls.bin: нет curl/wget.${plain}"
    fi
  fi
  touch /opt/zapret2/lists/autohostlist.txt
  if [ -d /opt/extra_strats ]; then
    rm -rf /opt/zapret2/extra_strats
    mv /opt/extra_strats /opt/zapret2/
    echo "Востановление настроек подбора из резерва выполнено."
  fi
  if [ ! -f /opt/zapret2/extra_strats/TCP_Custom.txt ]; then
    mkdir -p /opt/zapret2/extra_strats
    z2r_download_project_file /opt/zapret2/extra_strats/TCP_Custom.txt "extra_strats/TCP/RKN/Custom.txt" || touch /opt/zapret2/extra_strats/TCP_Custom.txt
  fi
  if [ ! -f /opt/zapret2/extra_strats/TCP_RKN_domains_by_substring.txt ]; then
    mkdir -p /opt/zapret2/extra_strats
    z2r_download_project_file /opt/zapret2/extra_strats/TCP_RKN_domains_by_substring.txt "extra_strats/TCP/RKN/Domains_By_Substring.txt" || touch /opt/zapret2/extra_strats/TCP_RKN_domains_by_substring.txt
  fi
  if [ -f "/opt/netrogat.txt" ]; then
    mv -f /opt/netrogat.txt /opt/zapret2/lists/netrogat.txt
    echo "Востановление листа исключений выполнено."
  fi
  #Копирование нашего конфига на замену стандартному
 z2r_download_project_file /opt/zapret2/config.default "config.default" || return 1
  if [ "$hardware" = "keenetic" ]; then
    z2r_download_project_file /opt/zapret2/init.d/sysv/keenetic-policy.sh "Entware/keenetic-policy.sh" || return 1
    chmod +x /opt/zapret2/init.d/sysv/keenetic-policy.sh
  fi
  if command -v nft >/dev/null 2>&1; then
    sed -i 's/^FWTYPE=iptables$/FWTYPE=nftables/' "/opt/zapret2/config.default"
  fi
# cache
mkdir -p /opt/zapret2/extra_strats/cache

}

#Удаление старого запрета, если есть
remove_zapret() {
 if [ -f "$ZAPRET2_INIT" ] && [ -f "/opt/zapret2/config" ]; then
 	"$ZAPRET2_INIT" stop
 fi
 if [ -f "/opt/zapret2/config" ] && [ -f "/opt/zapret2/uninstall_easy.sh" ]; then
     echo "Выполняем zapret2/uninstall_easy.sh"
     sh /opt/zapret2/uninstall_easy.sh
     echo "Скрипт uninstall_easy.sh выполнен."
 else
     echo "zapret2 не инсталлирован в систему. Переходим к следующему шагу."
 fi
 if [ -d "/opt/zapret2" ]; then
     echo "Удаляем папку zapret2"
     webui_remove >/dev/null 2>&1 || true
     rm -rf /opt/zapret2
 else
     echo "Папка zapret2 не существует."
 fi
 if [[ "$OSystem" == "entware" ]]; then
 	rm -fv /opt/etc/init.d/S90-zapret /opt/etc/ndm/netfilter.d/000-zapret.sh /opt/etc/init.d/S00fix
 fi
 read -re -p $'\033[33mУдалить функционал доступа в меню через браузер (web-ssh)? Enter - Да, 1 - нет\033[0m\n' ttyd_answer_del
 case "$ttyd_answer_del" in
     "1")
         echo "Пропущено"
     ;;
     *)
 		apk del ttyd 2>/dev/null || true
 		opkg remove ttyd 2>/dev/null || true
 		rm -f /usr/bin/ttyd
 		echo "Процесс удаления завершён"
     ;;
  esac
}

#Запрос желаемой версии zapret2
version_select() {
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
 if ! z2r_download_zapret2_release "$archive" "$VER" "$tarfile"; then
     echo -e "${red}Не удалось скачать архив zapret2 $tarfile.${plain}"
     echo -e "${yellow}Если есть зеркало release-архивов, задайте ZAPRET2_RELEASE_MIRROR_BASE с базовым URL вида https://mirror/path.${plain}"
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
 rm -rf /opt/zapret2
 mv "$workdir/zapret2" /opt/zapret2
 rm -rf "$workdir"
 if [ ! -f /opt/zapret2/install_easy.sh ]; then
     echo -e "${red}zapret2 установлен некорректно: нет /opt/zapret2/install_easy.sh.${plain}"
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

 echo -e "${green}В /opt/zapret2/binaries будет оставлен только выбранный набор:$(printf '%s' "$keep_list").${plain}"
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
 sh -i /opt/zapret2/install_easy.sh
 cleanup_zapret2_init_dirs
 "$ZAPRET2_INIT" restart
 if pidof nfqws2 >/dev/null; then
  check_access_list
  echo -e "\033[32mzapret2 перезапущен и полностью установлен\n\033[33mЕсли требуется меню (например не работают какие-то ресурсы) - введите скрипт ещё раз или просто напишите "z2r" в терминале. Саппорт: tg: zee4r\033[0m"
 else
  echo -e "${yellow}zapret2 полностью установлен, но не обнаружен после запуска в исполняемых задачах через pidof\nСаппорт: tg: zee4r${plain}"
 fi
}

#Для Entware Keenetic + merlin
entware_fixes() {
 if [ "$hardware" = "keenetic" ]; then
  z2r_download_project_file /opt/zapret2/init.d/sysv/zapret2 "Entware/zapret" || return 1
  chmod +x /opt/zapret2/init.d/sysv/zapret2
  echo "Права выданы /opt/zapret2/init.d/sysv/zapret2"
  z2r_download_project_file /opt/etc/ndm/netfilter.d/000-zapret.sh "Entware/000-zapret.sh" || return 1
  chmod +x /opt/etc/ndm/netfilter.d/000-zapret.sh
  echo "Права выданы /opt/etc/ndm/netfilter.d/000-zapret.sh"
  z2r_download_project_file /opt/etc/init.d/S00fix "Entware/S00fix" || return 1
  chmod +x /opt/etc/init.d/S00fix
  echo "Права выданы /opt/etc/init.d/S00fix"
  if [ -f /opt/zapret2/init.d/custom.d.examples.linux/10-keenetic-udp-fix ]; then
    cp -a /opt/zapret2/init.d/custom.d.examples.linux/10-keenetic-udp-fix /opt/zapret2/init.d/sysv/custom.d/10-keenetic-udp-fix
  else
    z2r_download_upstream_file /opt/zapret2/init.d/sysv/custom.d/10-keenetic-udp-fix "init.d/custom.d.examples.linux/10-keenetic-udp-fix" || return 1
  fi
  echo "10-keenetic-udp-fix скопирован"
 elif [ "$hardware" = "merlin" ]; then
  if sed -n '167p' /opt/zapret2/install_easy.sh | grep -q '^nfqws_opt_validat'; then
	sed -i '172s/return 1/return 0/' /opt/zapret2/install_easy.sh
  fi
	grep -qxF "$ZAPRET2_INIT restart-fw" /jffs/scripts/firewall-start || echo "$ZAPRET2_INIT restart-fw" >> /jffs/scripts/firewall-start
	chmod +x /jffs/scripts/firewall-start
 fi
 
 sh /opt/zapret2/install_bin.sh
 
 # #Раскомменчивание юзера под keenetic или merlin
 change_user
 #Патчинг на некоторых merlin /opt/zapret2/common/linux_fw.sh
 if command -v sysctl >/dev/null 2>&1; then
  echo "sysctl доступен. Патч linux_fw.sh не требуется"
 else
  echo "sysctl отсутствует. MerlinWRT? Патчим /opt/zapret2/common/linux_fw.sh"
  sed -i 's|sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=\$1|echo \$1 > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal|' /opt/zapret2/common/linux_fw.sh
  sed -i 's|sysctl -q -w net.ipv4.conf.\$1.route_localnet="\$enable"|echo "\$enable" > /proc/sys/net/ipv4/conf/\$1/route_localnet|' /opt/zapret2/common/linux_iphelper.sh
 fi
 #sed для пропуска запроса на прочтение readme, т.к. система entware. Дабы скрипт отрабатывал далее на Enter
 sed -i 's/if \[ -n "\$1" \] || ask_yes_no N "do you want to continue";/if true;/' /opt/zapret2/common/installer.sh
 ln -fs "$ZAPRET2_INIT" /opt/etc/init.d/S90-zapret2
 echo "Добавлено в автозагрузку: /opt/etc/init.d/S90-zapret2 > $ZAPRET2_INIT"
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
WEBUI_ROOT="/opt/zapret2/webui"
WEBUI_WWW="$WEBUI_ROOT/www"
WEBUI_CGI="$WEBUI_ROOT/cgi-bin"
WEBUI_RUNNER="$WEBUI_ROOT/run-webui.sh"
WEBUI_STATUS_CACHE="/opt/zapret2/extra_strats/cache/webui"
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
  webui_repo_fetch "run-webui.sh" "$WEBUI_RUNNER" || return 1
  webui_repo_fetch "cgi-bin/_lib.sh" "$WEBUI_CGI/_lib.sh" || return 1
  webui_repo_fetch "cgi-bin/status.cgi" "$WEBUI_CGI/status.cgi" || return 1
  webui_repo_fetch "cgi-bin/set-lock.cgi" "$WEBUI_CGI/set-lock.cgi" || return 1
  webui_repo_fetch "cgi-bin/clear-lock.cgi" "$WEBUI_CGI/clear-lock.cgi" || return 1
  webui_repo_fetch "cgi-bin/service.cgi" "$WEBUI_CGI/service.cgi" || return 1
  webui_repo_fetch "cgi-bin/check.cgi" "$WEBUI_CGI/check.cgi" || return 1

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
  procd_set_param command bash /opt/zapret2/webui/run-webui.sh run
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}

stop_service() {
  bash /opt/zapret2/webui/run-webui.sh stop >/dev/null 2>&1 || true
}
EOF
      chmod +x /etc/init.d/z2r-webui
      /etc/init.d/z2r-webui enable 2>/dev/null || true
      ;;
    "entware")
      cat > /opt/etc/init.d/S92z2r-webui <<'EOF'
#!/bin/sh
PATH=/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
case "$1" in
  start) bash /opt/zapret2/webui/run-webui.sh start ;;
  stop) bash /opt/zapret2/webui/run-webui.sh stop ;;
  restart) bash /opt/zapret2/webui/run-webui.sh restart ;;
  status) bash /opt/zapret2/webui/run-webui.sh status ;;
  *) echo "usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
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
ExecStart=bash /opt/zapret2/webui/run-webui.sh run
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable z2r-webui.service 2>/dev/null || true
      else
        cat > "$WEBUI_ROOT/run.sh" <<'EOF'
#!/bin/sh
PATH=/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
bash /opt/zapret2/webui/run-webui.sh start
EOF
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
    echo "http://127.0.0.1:${WEBUI_PORT}"
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
  rm -rf "$WEBUI_ROOT"
  echo -e "${green}Web UI удалён.${plain}"
}

webui_submenu() {
  while true; do
    clear -x
    echo -e "${cyan}--- Web UI ---${plain}"
    echo -e "${yellow}Состояние: ${plain}$(webui_status_text)"
    echo ""
    submenu_item "1" "Установить/обновить Web UI"
    submenu_item "2" "Показать статус и URL"
    submenu_item "3" "Удалить Web UI"
    submenu_item "0" "Назад"
    echo ""
    read -re -p "Ваш выбор: " webui_answer
    case "$webui_answer" in
      "1")
        webui_install
        pause_enter
        ;;
      "2")
        webui_show_status
        pause_enter
        ;;
      "3")
        webui_remove
        pause_enter
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
    local source_status
    strategies_status=$(get_orchestra_locks_info)
	if type z2r_source_status_line >/dev/null 2>&1; then
	  source_status="$(z2r_source_status_line)"
	else
	  source_status="${Z2R_SOURCE_RAW_BASE} @ ${Z2R_SOURCE_REF}"
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
    
    echo -e '
'"${Fcyan}"'+-----------------------------------------------------------------+
'"${Fyellow}"'     _____     ____ │  '"${Fgreen}"'1 MB / 10 GB'"${Fyellow}"'        '"${Fpink}"'⏳'"${Fyellow}"'  ETA: КТТС         │
'"${Fyellow}"'    /      \  |  o |│  [====>          ]                         │
'"${Fyellow}"'   |        |/ ___\|│     '"${Fpink}"'(_o_)'"${Fyellow}"' ---->  '"${Fcyan}"'z a t o r'"${Fyellow}"'  <---- '"${Fpink}"'(_o_)'"${Fyellow}"'    │
'"${Fyellow}"'   |_________/      │                                            │
'"${Fyellow}"'   |_|_| |_|_|      │  '"${Fgreen}"'speed: 0.0001 Mb/s'"${Fyellow}"'   stability: возможно  │
'"${Fcyan}"'+-----------------------------------------------------------------+
'"${plain}"'
'"\033[32mЯ черепашка Дейв. И я медленный.\033[33m"'
'"\033[32mПрямо как твой интернет.\033[33m"'

'"${yellow}"'Источник zator: '"${plain}${source_status}${yellow}"'

'"Город/провайдер: ${plain}${PROVIDER_MENU}${yellow}"'
'"${TITLE_MENU_LINE}"'
\033[32mВыберите необходимое действие:\033[33m
Enter (без цифр) - переустановка/обновление zapret2
'"${Fyellow}"'0.'"${yellow}"' Выход
'"${Fcyan}"'001.'"${yellow}"' CDN тест (test.sh)
'"${Fcyan}"'01.'"${yellow}"' Проверить доступность сервисов (Тест не точен)
'"${Fcyan}"'1.'"${yellow}"' Фиксация стратегии профиля/безразборного блока. Текущие: '"${plain}"'[ '"${strategies_status}"' ]'"${yellow}"' (fallback TLS: '"${plain}"'['"$(fallback_strategy_text)"']'"${yellow}"', HTTP: '"${plain}"'['"$(fallback_http_strategy_text)"']'"${yellow}"')
'"${Fcyan}"'2.'"${yellow}"' Стоп/старт zapret2, 22 - рестарт (сейчас: '"$(pidof nfqws2 >/dev/null && echo "${green}Запущен${yellow}" || echo "${red}Остановлен${yellow}")"')
'"${Fcyan}"'3.'"${yellow}"' Запуск blockcheck2 и сохранение SUMMARY
'"${Fcyan}"'4.'"${yellow}"' Удалить zapret2
'"${Fcyan}"'5.'"${yellow}"' Обновить стратегии, сбросить листы подбора стратегий и исключений (есть бэкап)
'"${Fcyan}"'6.'"${yellow}"' Управление доменами
'"${Fcyan}"'7.'"${yellow}"' Открыть в редакторе config (Установит nano редактор ~250kb)
'"${Fcyan}"'9.'"${yellow}"' Переключатель zapret2 на nftables/iptables (На всё жать Enter). Актуально для OpenWRT 21+. Может помочь с войсами. Сейчас: '"${plain}"'['"$(config_mode_text fwtype)"']'"${yellow}"'
'"${Fcyan}"'10.'"${yellow}"' (Де)активировать обход UDP на 1026-65531 портах (BF6, Fifa и т.п.). Сейчас: '"${plain}"'['"$(config_mode_text udp_games)"']'"${yellow}"'
'"${Fcyan}"'11.'"${yellow}"' Управление аппаратным ускорением zapret2. Может увеличить скорость на роутере. Сейчас: '"${plain}"'['"$(config_mode_text flowoffload)"']'"${yellow}"'
'"${Fcyan}"'12.'"${yellow}"' Режим фильтра hostlist/autohostlist. Сейчас: '"${plain}"'['"$(config_mode_text hostlist)"']'"${yellow}"'
'"${Fcyan}"'13.'"${yellow}"' Безразборный режим (fallback). Сейчас: '"${plain}"'['"$(config_mode_text fallback)"']'"${yellow}"'
'"${Fcyan}"'14.'"${yellow}"' Активировать доступ в меню через браузер (~3мб места)
'"${Fcyan}"'15.'"${yellow}"' Провайдер
'"${Fcyan}"'16.'"${yellow}"' Сменить TLS blob (--blob=maxru). Сейчас: '"${plain}"'['"$(config_mode_text tls_blob_menu)"']'"${yellow}"'
'"${Fcyan}"'18.'"${yellow}"' Защита от RST-инъекций. (BETA) Сейчас: '"${plain}"'['"$(config_mode_text rst_guard)"']'"${yellow}"'
'"${Fcyan}"'19.'"${yellow}"' Дополнительные настройки
'"${Fcyan}"'20.'"${yellow}"' Управление портами NFQWS2 (TCP/UDP). Сейчас: '"${plain}"'['"$(ports_menu_status)"']'"${yellow}"'
'"${Fcyan}"'21.'"${yellow}"' Управление бэкапами (создание/восстановление/удаление архивов)
'"${Fcyan}"'777.'"${yellow}"' Активировать zeefeer premium (Нажимать только Valery ProD, avg97, Xoz, GeGunT, blagodarenya, mikhyan, Xoz, andric62, Whoze, Necronicle, Andrei_5288515371, Nomand, Dina_turat, Nergalss, Александру, АлександруП, vecheromholodno, ЕвгениюГ, Dyadyabo, skuwakin, izzzgoy, Grigaraz, Reconnaissance, comandante1928, umad, rudnev2028, rutakote, railwayfx, vtokarev1604, Grigaraz, a40letbezurojaya и subzeero452 и остальным поддержавшим проект. Но если очень хочется - можно нажать и другим)\033[0m'
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
      "$ZAPRET2_INIT" start
      echo -e "${green}Выполнена команда запуска zapret2${plain}"
    fi
    pause_enter
    ;;

  "22")
    ensure_nfqws2_stopped
    "$ZAPRET2_INIT" start
    echo -e "${green}Выполнена быстрая перезагрузка zapret2 (остановка + запуск)${plain}"
    pause_enter
    ;;

  "3")
    blockcheck2_run_summary
    pause_enter
    ;;

  "4")
    echo -e "${yellow}Внимание! Это приведёт к полному удалению zapret2.${plain}"
    read -re -p $'\033[33mВы действительно хотите удалить zapret2? Введите 5 - подтвердить удаление, 0 - отмена: \033[0m' del_confirm
    case "$del_confirm" in
      "5")
        backup_helper_ask_and_create
        remove_zapret
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
    locked_lua_update_from_repo
    mkdir -p /opt/zapret2/extra_strats/cache/orchestra
    chmod 777 /opt/zapret2/extra_strats/cache/orchestra 2>/dev/null || true
    menu_action_update_config_reset
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
    nano /opt/zapret2/config
    # после выхода из nano
    ;;

  "9")
    menu_action_toggle_fwtype
    pause_enter
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
      "$ZAPRET2_INIT" restart
      echo -e "${green}zapret2 перезапущен для применения режима${plain}"
    fi
    pause_enter
    ;;

  "13")
    toggle_fallback_mode
    if pidof nfqws2 >/dev/null; then
      "$ZAPRET2_INIT" restart
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
      "$ZAPRET2_INIT" restart
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

if [ "${1:-}" = "source" ]; then
  if type z2r_source_command >/dev/null 2>&1; then
    z2r_source_command "${@:2}"
    exit $?
  fi
  echo "Модуль updater ещё не установлен. Выполните полное обновление z2r при доступной сети." >&2
  exit 1
fi

z2r_bootstrap_refresh_launcher "$@" || true
z2r_install_persistent_launcher || \
  echo -e "${yellow}Не удалось обновить постоянный launcher z2r; текущий запуск продолжится.${plain}" >&2


detect_os
set_zapret2_init

#Инфа о времени обновления скрпта
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

#Выполнение общего для всех ОС кода с ответвлениями под ОС
#Запрос на установку 3x-ui или аналогов для VPS
if [[ "$OSystem" == "VPS" ]] && [ ! $1 ]; then
 get_panel
fi

#Меню и быстрый запуск подбора стратегии
 if [ -d /opt/zapret2/extra_strats ] && [ -f "/opt/zapret2/config" ]; then
	if [ $1 ]; then
		Strats_Tryer $1
	fi
    get_menu
 fi
 
#entware keenetic and merlin preinstal env.
if [ "$hardware" = "keenetic" ]; then
 opkg install coreutils-sort coreutils-nohup grep gzip ipset iptables xtables-addons_legacy 2>/dev/null || apk add coreutils grep gzip ipset iptables xtables-addons_legacy 2>/dev/null
 opkg install kmod_ndms 2>/dev/null || apk add kmod_ndms 2>/dev/null || echo -e "\033[31mНе удалось установить kmod_ndms. Если у вас не keenetic - игнорируйте.\033[0m"
elif [ "$hardware" = "merlin" ]; then
 opkg install coreutils-sort coreutils-nohup grep gzip ipset iptables xtables-addons_legacy 2>/dev/null || apk add coreutils grep gzip ipset iptables xtables-addons_legacy 2>/dev/null
fi

#Проверка наличия каталога opt и его создание при необходиомости (для некоторых роутеров), переход в tmp
mkdir -p /opt
cd /tmp

# До удаления текущего runtime убеждаемся, что все project-файлы будут взяты из
# одного exact commit выбранного источника.
if ! z2r_source_prepare; then
  echo -e "${red}Обновление отменено: источник zator недоступен или ref не разрешён.${plain}" >&2
  exit 1
fi
if ! z2r_stage_project_core; then
  echo -e "${red}Обновление отменено: не удалось подготовить файлы выбранного source.${plain}" >&2
  exit 1
fi
if ! orch_runtime_state_snapshot "$ORCH_DIR" "$Z2R_ORCHESTRA_SNAPSHOT_DIR"; then
  echo -e "${red}Обновление отменено: не удалось сохранить состояния стратегий.${plain}" >&2
  exit 1
fi

#Удаление старого запрета, если есть
remove_zapret

#Запрос желаемой версии zapret2
echo -e "${yellow}Конфиг обновлен (UTC +0): $(z2r_github_commit_date config.default) ${plain}"
version_select

#Запрос на установку web-ssh
read -re -p $'\033[33mАктивировать доступ в меню через браузер (~3мб места)? 1 - Да, Enter - нет\033[0m\n' ttyd_answer
case "$ttyd_answer" in
	"1")
		webui_install
	;;
	*)
		echo "Пропуск (пере)установки web-терминала"
	;;
esac 
 
#Скачивание, распаковка архива zapret2 и его удаление
zapret_get

#Создаём папки и забираем файлы папок lists, fake, extra_strats, копируем конфиг, скрипты для войсов DS, WA, TG
get_repo
if ! orch_runtime_state_restore "$ORCH_DIR" "$Z2R_ORCHESTRA_SNAPSHOT_DIR"; then
  echo -e "${red}Не удалось восстановить состояния стратегий после обновления.${plain}" >&2
  exit 1
fi
if [ ! -s "$ORCH_LUA_LOCKED" ]; then
  echo "Повторная попытка загрузки locked.lua..."
  if locked_lua_update_from_repo; then
    echo -e "${green}Повторная загрузка locked.lua успешна.${plain}"
  else
    echo -e "${red}Повторная загрузка locked.lua не удалась.${plain}"
  fi
fi

#Для Keenetic и merlin
if [[ "$OSystem" == "entware" ]]; then
 entware_fixes
 # На Keenetic прописываем IFACE_WAN по default route до запуска install_easy.sh.
 config_keenetic_set_wan_iface_all
fi

profile_apply_all /opt/zapret2/config.default

#Для x-wrt
if [[ "$release" == "x-wrt" ]]; then
	sed -i 's/kmod-nft-nat kmod-nft-offload/kmod-nft-nat/' /opt/zapret2/common/installer.sh
fi

#Запуск установочных скриптов и перезагрузка
if [ "$hardware" = "keenetic" ]; then
 ensure_keenetic_policy_config /opt/zapret2/config.default
fi
if type z2r_source_track_finish >/dev/null 2>&1; then
  z2r_source_track_finish || exit 1
fi
install_zapret_reboot
