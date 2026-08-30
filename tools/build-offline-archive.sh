#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$(pwd)"
RELEASE_BASE="${ZAPRET2_RELEASE_BASE:-https://github.com/bol-van/zapret2/releases/download}"
LATEST_API_URL="${ZAPRET2_LATEST_API_URL:-https://api.github.com/repos/bol-van/zapret2/releases/latest}"
Z2R_BRANCH="${Z2R_BRANCH:-zator}"
PROJECT_ARCHIVE_URL="${Z2R_PROJECT_ARCHIVE_URL:-https://github.com/AloofLibra/zator/archive/refs/heads/${Z2R_BRANCH}.tar.gz}"

usage() {
  cat >&2 <<EOF
Использование: $0 [параметры]
  --version VERSION          версия zapret2; по умолчанию latest
  --platform TARGET         standard, openwrt или both; по умолчанию both
  --zapret2 FILE            локальный standard release вместо скачивания
  --zapret2-openwrt FILE    локальный OpenWrt release вместо скачивания
  --project-dir DIR         локальный checkout zator вместо автоопределения
  --output FILE             путь итогового zator-offline-VERSION.tar.gz
EOF
  exit 2
}

fail() {
  echo "Ошибка: $*" >&2
  exit 1
}

fetch_stdout() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    fail "для загрузки release-архивов требуется curl или wget"
  fi
}

download_file() {
  local dest="$1" url="$2"
  echo "Загрузка: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" "$url" || fail "не удалось скачать $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url" || fail "не удалось скачать $url"
  else
    fail "для загрузки release-архивов требуется curl или wget"
  fi
}

normalize_version() {
  local value="${1#v}"
  printf '%s\n' "$value" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || return 1
  printf '%s' "$value"
}

archive_version() {
  local name
  name="$(basename -- "$1")"
  if [[ "$name" =~ ^zapret2-v([0-9]+(\.[0-9]+)*)\.tar\.gz$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

openwrt_archive_version() {
  local name
  name="$(basename -- "$1")"
  if [[ "$name" =~ ^zapret2-v([0-9]+(\.[0-9]+)*)-openwrt-embedded\.tar\.gz$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

validate_tar() {
  local archive="$1" version="$2" entry

  tar -tzf "$archive" >/dev/null || fail "повреждён tar.gz: $archive"
  while IFS= read -r entry; do
    case "$entry" in
      /*|../*|*/../*|*/..) fail "небезопасный путь в архиве $archive: $entry" ;;
    esac
  done < <(tar -tzf "$archive")

  tar -tzf "$archive" | grep -Fx "zapret2-v$version/install_bin.sh" >/dev/null || \
    fail "в $archive отсутствует install_bin.sh"
  tar -tzf "$archive" | grep -Fx "zapret2-v$version/install_easy.sh" >/dev/null || \
    fail "в $archive отсутствует install_easy.sh"
}

strip_windows_binaries() {
  local archive="$1" version="$2" base strip_root win_dir listing
  base="$(basename -- "$archive")"
  strip_root="$work_dir/strip-$base"
  rm -rf "$strip_root"
  mkdir -p "$strip_root"
  listing="$(tar -tzf "$archive" 2>/dev/null || true)"
  case "$listing" in
    *"zapret2-v${version}/binaries/windows-"*) ;;
    *)
      rm -rf "$strip_root"
      return 0
      ;;
  esac
  tar -xzf "$archive" -C "$strip_root" || fail "не удалось распаковать $archive для удаления windows-бинарников"
  for win_dir in "$strip_root"/zapret2-v"$version"/binaries/windows-*; do
    [ -e "$win_dir" ] || continue
    rm -rf "$win_dir"
  done
  tar -czf "$archive" -C "$strip_root" "zapret2-v$version" || fail "не удалось пересобрать $archive без windows-бинарников"
  rm -rf "$strip_root"
}

project_tree_is_valid() {
  local root="$1" dir file

  [ -f "$root/offline/z2r" ] || return 1
  for dir in blockcheck2.d data Entware extra_strats fake firewall init.d lib lists lua orchestra webui; do
    [ -d "$root/$dir" ] || return 1
  done
  for file in z2r.sh config.default fake_files.tar.gz recommendations.txt \
    3proxy.cfg del.proxyauth user_test2.sh merlin_wan_restart_zapret.sh README.md; do
    [ -f "$root/$file" ] || return 1
  done
}

validate_archive_paths() {
  local archive="$1" entry

  tar -tzf "$archive" >/dev/null || fail "повреждён tar.gz: $archive"
  while IFS= read -r entry; do
    case "$entry" in
      /*|../*|*/../*|*/..) fail "небезопасный путь в архиве $archive: $entry" ;;
    esac
  done < <(tar -tzf "$archive")
}

zapret2_archive=""
openwrt_archive=""
project_dir=""
project_dir_was_set=0
requested_version="latest"
version_was_set=0
platform="both"
platform_was_set=0
output=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || usage
      requested_version="$2"
      version_was_set=1
      shift 2
      ;;
    --platform)
      [ "$#" -ge 2 ] || usage
      platform="$2"
      platform_was_set=1
      shift 2
      ;;
    --zapret2)
      [ "$#" -ge 2 ] || usage
      zapret2_archive="$2"
      shift 2
      ;;
    --zapret2-openwrt)
      [ "$#" -ge 2 ] || usage
      openwrt_archive="$2"
      shift 2
      ;;
    --project-dir)
      [ "$#" -ge 2 ] || usage
      project_dir="$2"
      project_dir_was_set=1
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || usage
      output="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [ "$platform_was_set" -eq 0 ] && { [ -n "$zapret2_archive" ] || [ -n "$openwrt_archive" ]; }; then
  if [ -n "$zapret2_archive" ] && [ -n "$openwrt_archive" ]; then
    platform="both"
  elif [ -n "$zapret2_archive" ]; then
    platform="standard"
  else
    platform="openwrt"
  fi
fi

case "$platform" in
  standard) want_standard=1; want_openwrt=0 ;;
  openwrt) want_standard=0; want_openwrt=1 ;;
  both) want_standard=1; want_openwrt=1 ;;
  *) fail "неизвестная платформа '$platform'; ожидается standard, openwrt или both" ;;
esac
[ "$want_standard" -eq 1 ] || [ -z "$zapret2_archive" ] || \
  fail "--zapret2 не соответствует --platform $platform"
[ "$want_openwrt" -eq 1 ] || [ -z "$openwrt_archive" ] || \
  fail "--zapret2-openwrt не соответствует --platform $platform"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/zator-offline.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
download_dir="$work_dir/downloads"
mkdir -p "$download_dir"

if [ -z "$project_dir" ]; then
  project_dir="$DEFAULT_REPO_DIR"
fi
if ! project_tree_is_valid "$project_dir"; then
  if [ "$project_dir_was_set" -eq 1 ]; then
    fail "в --project-dir отсутствует полный checkout zator: $project_dir"
  fi
  echo "Локальный checkout zator не найден. Загрузка ветки $Z2R_BRANCH..."
  project_archive="$download_dir/zator-$Z2R_BRANCH.tar.gz"
  project_extract_dir="$work_dir/project"
  download_file "$project_archive" "$PROJECT_ARCHIVE_URL"
  validate_archive_paths "$project_archive"
  mkdir -p "$project_extract_dir"
  tar -xzf "$project_archive" -C "$project_extract_dir"
  project_dir=""
  for candidate in "$project_extract_dir"/*; do
    if [ -d "$candidate" ]; then
      project_dir="$candidate"
      break
    fi
  done
  [ -n "$project_dir" ] && project_tree_is_valid "$project_dir" || \
    fail "скачанный snapshot ветки $Z2R_BRANCH не содержит полный проект zator"
fi
REPO_DIR="$(cd -- "$project_dir" && pwd)"
version=""

if [ -n "$zapret2_archive" ]; then
  [ -f "$zapret2_archive" ] || fail "не найден $zapret2_archive"
  version="$(archive_version "$zapret2_archive")" || \
    fail "ожидалось имя zapret2-vVERSION.tar.gz"
fi
if [ -n "$openwrt_archive" ]; then
  [ -f "$openwrt_archive" ] || fail "не найден $openwrt_archive"
  openwrt_version="$(openwrt_archive_version "$openwrt_archive")" || \
    fail "ожидалось имя zapret2-vVERSION-openwrt-embedded.tar.gz"
  [ -z "$version" ] || [ "$openwrt_version" = "$version" ] || \
    fail "версии локальных архивов zapret2 не совпадают: $version и $openwrt_version"
  [ -n "$version" ] || version="$openwrt_version"
fi

if [ "$version_was_set" -eq 1 ] && [ "$requested_version" != "latest" ]; then
  pinned_version="$(normalize_version "$requested_version")" || \
    fail "некорректная версия zapret2: $requested_version"
  [ -z "$version" ] || [ "$version" = "$pinned_version" ] || \
    fail "локальный архив имеет версию $version, запрошена $pinned_version"
  version="$pinned_version"
fi

if [ -z "$version" ]; then
  if [ "$requested_version" = "latest" ]; then
    echo "Определение последней версии zapret2..."
    latest_json="$(fetch_stdout "$LATEST_API_URL")" || fail "не удалось получить latest release zapret2"
    latest_tag="$(printf '%s\n' "$latest_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    version="$(normalize_version "$latest_tag")" || fail "GitHub API вернул некорректный tag_name"
  else
    version="$(normalize_version "$requested_version")" || \
      fail "некорректная версия zapret2: $requested_version"
  fi
fi

if [ "$want_standard" -eq 1 ] && [ -z "$zapret2_archive" ]; then
  zapret2_archive="$download_dir/zapret2-v$version.tar.gz"
  download_file "$zapret2_archive" "$RELEASE_BASE/v$version/zapret2-v$version.tar.gz"
fi
if [ "$want_openwrt" -eq 1 ] && [ -z "$openwrt_archive" ]; then
  openwrt_archive="$download_dir/zapret2-v$version-openwrt-embedded.tar.gz"
  download_file "$openwrt_archive" "$RELEASE_BASE/v$version/zapret2-v$version-openwrt-embedded.tar.gz"
fi

if [ -n "$zapret2_archive" ]; then
  validate_tar "$zapret2_archive" "$version"
  strip_windows_binaries "$zapret2_archive" "$version"
fi
if [ -n "$openwrt_archive" ]; then
  validate_tar "$openwrt_archive" "$version"
  strip_windows_binaries "$openwrt_archive" "$version"
fi

bundle_name="zator-offline-$version"
bundle_dir="$work_dir/$bundle_name"
payload_dir="$bundle_dir/payload"
mkdir -p "$payload_dir" "$bundle_dir/vendor"

cp -f "$REPO_DIR/offline/z2r" "$bundle_dir/z2r"
for dir in blockcheck2.d data Entware extra_strats fake firewall init.d lib lists lua orchestra webui; do
  cp -R "$REPO_DIR/$dir" "$payload_dir/$dir"
done
for file in z2r.sh config.default fake_files.tar.gz recommendations.txt \
  3proxy.cfg del.proxyauth user_test2.sh merlin_wan_restart_zapret.sh README.md; do
  cp -f "$REPO_DIR/$file" "$payload_dir/$file"
done
if [ -n "$zapret2_archive" ]; then
  cp -f "$zapret2_archive" "$bundle_dir/vendor/$(basename -- "$zapret2_archive")"
fi
if [ -n "$openwrt_archive" ]; then
  cp -f "$openwrt_archive" "$bundle_dir/vendor/$(basename -- "$openwrt_archive")"
fi
chmod +x "$bundle_dir/z2r" "$payload_dir/z2r.sh"

(
  cd "$bundle_dir"
  find payload vendor -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    size="$(wc -c < "$file" | tr -d '[:space:]')"
    printf '%s %s\n' "$size" "$file"
  done > MANIFEST.files
)

if [ -z "$output" ]; then
  output="$CALLER_DIR/$bundle_name.tar.gz"
fi
tar -czf "$output" -C "$work_dir" "$bundle_name"
echo "Создан готовый архив для публикации: $output"
