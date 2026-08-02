#!/bin/bash

# Runtime-часть updater. Bootstrap-функции чтения source state и разрешения
# ref находятся в z2r.sh: они нужны до того, как этот модуль станет доступен.

Z2R_RUNTIME_ROOT="${Z2R_RUNTIME_ROOT:-/opt}"

z2r_sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    return 127
  fi
}

z2r_source_cache_namespace() {
  local identity
  identity="${Z2R_SOURCE_REPOSITORY:-${Z2R_SOURCE_RAW_ROOT:-$Z2R_SOURCE_RAW_BASE}}"
  printf '%s' "$identity" | sed 's/[^A-Za-z0-9._-]/_/g'
}

z2r_source_validate_rel_path() {
  local rel="$1"
  case "$rel" in ''|/*|*'..'*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
}

z2r_source_cache_path() {
  local rel="$1" namespace safe_rel
  z2r_source_validate_rel_path "$rel" || return 1
  [ -n "${Z2R_SOURCE_RESOLVED_COMMIT:-}" ] || return 1
  namespace="$(z2r_source_cache_namespace)" || return 1
  safe_rel="$(printf '%s' "$rel" | tr '/' '@')"
  printf '%s/update-state/%s/%s/%s\n' \
    "$Z2R_UPDATE_DIR" "$namespace" "$Z2R_SOURCE_RESOLVED_COMMIT" "$safe_rel"
}

z2r_source_cache_restore() {
  local rel="$1" dest="$2" cache checksum expected actual
  cache="$(z2r_source_cache_path "$rel")" || return 1
  checksum="${cache}.sha256"
  [ -s "$cache" ] && [ -s "$checksum" ] || return 1
  expected="$(sed -n '1p' "$checksum")"
  actual="$(z2r_sha256_file "$cache" 2>/dev/null || true)"
  if [ "$actual" != "$expected" ]; then
    rm -f "$cache" "$checksum"
    return 1
  fi
  cp -f "$cache" "$dest"
}

z2r_source_cache_store() {
  local rel="$1" source_file="$2" cache checksum tmp checksum_tmp sha
  cache="$(z2r_source_cache_path "$rel")" || return 1
  checksum="${cache}.sha256"
  tmp="${cache}.tmp.$$"
  checksum_tmp="${checksum}.tmp.$$"
  mkdir -p "$(dirname "$cache")" || return 1
  cp -f "$source_file" "$tmp" || { rm -f "$tmp"; return 1; }
  sha="$(z2r_sha256_file "$tmp")" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$sha" > "$checksum_tmp" || { rm -f "$tmp" "$checksum_tmp"; return 1; }
  mv -f "$tmp" "$cache" || { rm -f "$tmp" "$checksum_tmp"; return 1; }
  mv -f "$checksum_tmp" "$checksum"
}

z2r_source_track_begin() {
  mkdir -p "$Z2R_UPDATE_DIR" || return 1
  Z2R_SOURCE_TRACK_FILE="$Z2R_UPDATE_DIR/.deployed-files.tmp.$$"
  : > "$Z2R_SOURCE_TRACK_FILE"
  export Z2R_SOURCE_TRACK_FILE
}

z2r_source_track_file() {
  local dest="$1" rel="$2" deployed_sha remote_sha cache tmp
  [ -n "${Z2R_SOURCE_TRACK_FILE:-}" ] || return 0
  z2r_source_validate_rel_path "$rel" || return 1
  case "$dest" in "$Z2R_RUNTIME_ROOT"/*) ;; *) return 0 ;; esac
  deployed_sha="$(z2r_sha256_file "$dest")" || return 1
  cache="$(z2r_source_cache_path "$rel" 2>/dev/null || true)"
  remote_sha="$(sed -n '1p' "${cache}.sha256" 2>/dev/null || true)"
  [ -n "$remote_sha" ] || remote_sha="$deployed_sha"
  tmp="${Z2R_SOURCE_TRACK_FILE}.next"
  awk -F '\t' -v path="$dest" '$1 != path { print }' "$Z2R_SOURCE_TRACK_FILE" > "$tmp" || return 1
  printf '%s\t%s\t%s\t%s\n' "$dest" "$rel" "$remote_sha" "$deployed_sha" >> "$tmp" || return 1
  mv -f "$tmp" "$Z2R_SOURCE_TRACK_FILE"
}

z2r_source_track_finish() {
  local manifest files tmp old_umask installed_at
  [ -n "${Z2R_SOURCE_TRACK_FILE:-}" ] || return 0
  [ -f "$Z2R_SOURCE_TRACK_FILE" ] || return 1
  manifest="$Z2R_UPDATE_DIR/deployed.manifest"
  files="$Z2R_UPDATE_DIR/deployed.files"
  tmp="${manifest}.tmp.$$"
  installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  old_umask="$(umask)"
  umask 077
  {
    printf 'repository=%s\n' "${Z2R_SOURCE_REPOSITORY:-}"
    printf 'raw_base=%s\n' "${Z2R_SOURCE_RAW_ROOT:-$Z2R_SOURCE_RAW_BASE}"
    printf 'requested_ref=%s\n' "$Z2R_SOURCE_REF"
    printf 'resolved_commit=%s\n' "$Z2R_SOURCE_RESOLVED_COMMIT"
    printf 'installed_at=%s\n' "$installed_at"
  } > "$tmp" || { umask "$old_umask"; rm -f "$tmp"; return 1; }
  umask "$old_umask"
  mv -f "$tmp" "$manifest" || return 1
  mv -f "$Z2R_SOURCE_TRACK_FILE" "$files" || return 1
  unset Z2R_SOURCE_TRACK_FILE
}

z2r_source_manifest_value() {
  local key="$1" manifest="$Z2R_UPDATE_DIR/deployed.manifest"
  [ -f "$manifest" ] || return 1
  sed -n "s/^${key}=//p" "$manifest" | head -n 1
}

z2r_source_local_change_count() {
  local files="$Z2R_UPDATE_DIR/deployed.files" dest rel remote_sha deployed_sha actual count=0
  [ -f "$files" ] || { printf 'unknown\n'; return 0; }
  while IFS=$'\t' read -r dest rel remote_sha deployed_sha; do
    [ -n "$dest" ] || continue
    if [ ! -f "$dest" ]; then
      count=$((count + 1))
      continue
    fi
    actual="$(z2r_sha256_file "$dest" 2>/dev/null || true)"
    [ "$actual" = "$deployed_sha" ] || count=$((count + 1))
  done < "$files"
  printf '%s\n' "$count"
}

z2r_source_status_line() {
  local installed changes source
  source="${Z2R_SOURCE_REPOSITORY:-$Z2R_SOURCE_RAW_BASE}"
  installed="$(z2r_source_manifest_value resolved_commit 2>/dev/null || true)"
  changes="$(z2r_source_local_change_count)"
  [ -n "$installed" ] || installed="неизвестно"
  case "$changes" in
    0) changes="чисто" ;;
    unknown) changes="неизвестно" ;;
    *) changes="изменено: $changes" ;;
  esac
  printf '%s @ %s; установлено: %.12s; runtime: %s' \
    "$source" "$Z2R_SOURCE_REF" "$installed" "$changes"
}

z2r_source_show() {
  local installed installed_at changes source
  source="${Z2R_SOURCE_REPOSITORY:-$Z2R_SOURCE_RAW_BASE}"
  installed="$(z2r_source_manifest_value resolved_commit 2>/dev/null || true)"
  installed_at="$(z2r_source_manifest_value installed_at 2>/dev/null || true)"
  changes="$(z2r_source_local_change_count)"
  echo "Настроенный источник: $source"
  echo "Запрошенный ref: $Z2R_SOURCE_REF"
  echo "Источник настроек: $Z2R_SOURCE_CONFIG_ORIGIN"
  echo "Установленный commit: ${installed:-нет manifest}"
  echo "Дата установки: ${installed_at:-неизвестно}"
  case "$changes" in
    0) echo "Локальные изменения runtime: нет" ;;
    unknown) echo "Локальные изменения runtime: неизвестно (нет manifest)" ;;
    *) echo "Локальные изменения runtime: да ($changes файлов)" ;;
  esac
}

z2r_source_set() {
  local repository="$1" ref="$2"
  z2r_source_validate_repository "$repository" || {
    echo "Repository должен иметь вид owner/name." >&2
    return 1
  }
  z2r_source_validate_ref "$ref" || {
    echo "Некорректный installation ref." >&2
    return 1
  }
  z2r_source_write_config "$repository" "$ref"
  echo "Источник сохранён. Обновление начнётся при следующей подтверждённой установке/обновлении."
}

z2r_source_pin() {
  local commit="${1:-}"
  if [ -z "$commit" ]; then
    z2r_source_prepare || return 1
    commit="$Z2R_SOURCE_RESOLVED_COMMIT"
  fi
  z2r_source_validate_sha "$commit" || {
    echo "Commit должен быть полным 40-символьным SHA." >&2
    return 1
  }
  z2r_source_write_config "$Z2R_SOURCE_RAW_BASE" "$commit"
  echo "Источник закреплён на commit $commit."
}

z2r_source_reconcile_files() {
  local files="$Z2R_UPDATE_DIR/deployed.files" dest rel remote_sha deployed_sha
  [ -f "$files" ] || {
    echo "Нет списка установленных файлов: выполните полное обновление zapret2." >&2
    return 1
  }
  z2r_source_track_begin || return 1
  while IFS=$'\t' read -r dest rel remote_sha deployed_sha; do
    [ -n "$dest" ] || continue
    case "$dest" in "$Z2R_RUNTIME_ROOT"/*) ;; *) continue ;; esac
    z2r_source_validate_rel_path "$rel" || return 1
    z2r_download_project_file "$dest" "$rel" || return 1
  done < "$files"
  z2r_source_track_finish
}

z2r_source_reset() {
  local old_namespace old_state
  old_namespace="$(z2r_source_cache_namespace)"
  old_state="$Z2R_UPDATE_DIR/update-state/$old_namespace"
  z2r_source_write_config "$Z2R_DEFAULT_SOURCE_RAW_BASE" "$Z2R_DEFAULT_SOURCE_REF" || return 1
  if [ -n "$old_namespace" ] && [ -d "$old_state" ]; then
    rm -rf "$old_state"
  fi
  z2r_source_load_config || return 1
  z2r_source_prepare || return 1
  z2r_source_reconcile_files
  echo "Источник сброшен на штатный и отслеживаемые файлы синхронизированы."
}

z2r_source_command() {
  local action="${1:-show}"
  shift || true
  case "$action" in
    show) z2r_source_show ;;
    set)
      [ "${1:-}" = "custom" ] && shift
      [ "$#" -eq 2 ] || {
        echo "Использование: z2r source set owner/repository branch|tag|sha" >&2
        return 1
      }
      z2r_source_set "$1" "$2"
      ;;
    pin)
      [ "$#" -le 1 ] || { echo "Использование: z2r source pin [commit-sha]" >&2; return 1; }
      z2r_source_pin "${1:-}"
      ;;
    reset)
      [ "$#" -eq 0 ] || { echo "Использование: z2r source reset" >&2; return 1; }
      z2r_source_reset
      ;;
    *)
      echo "Использование: z2r source {show|set|pin|reset}" >&2
      return 1
      ;;
  esac
}
