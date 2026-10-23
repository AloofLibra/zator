#!/usr/bin/env bash
# Быстрый путь для setting=supersweep: отчёт самодостаточен, а сорсинг всех
# библиотек CGI на mipsel стоит больше полусекунды. Путь эмулирует контракт
# api_supersweep_get из _lib.sh (заголовки и коды ошибок идентичны).
if [ "${REQUEST_METHOD:-GET}" = GET ] && [ "${QUERY_STRING:-}" = "setting=supersweep" ]; then
  lib_dir=""
  for dir in /opt/zator/z2r_lib /opt/zapret2/z2r_lib "$(dirname -- "$0")/../../z2r_lib"; do
    if [ -f "$dir/supersweep.sh" ]; then lib_dir="$dir"; break; fi
  done
  if [ -z "$lib_dir" ]; then
    printf 'Status: 503 Service Unavailable\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'
    printf '{"error":"missing z2r runtime libs"}\n'
    exit 0
  fi
  . "$lib_dir/supersweep.sh"
  if ! type supersweep_report_json >/dev/null 2>&1; then
    printf 'Status: 503 Service Unavailable\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'
    printf '{"error":"Для просмотра суперавтопрогона обновите Core zator."}\n'
    exit 0
  fi
  if ! body="$(supersweep_report_json)"; then
    printf 'Status: 500 Internal Server Error\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'
    printf '{"error":"Не удалось прочитать отчёт суперавтопрогона."}\n'
    exit 0
  fi
  printf 'Cache-Control: no-store\r\n'
  printf 'Status: 200 OK\r\n'
  printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'
  printf '%s\n' "$body"
  exit 0
fi
. /opt/zator/webui/cgi-bin/_lib.sh

case "${REQUEST_METHOD:-GET}" in
  GET)
    parse_params
    case "${PARAM_SETTING:-}" in
      wg_blob)
        api_wg_blob_get
        ;;
      wg_state)
        api_wg_state_get
        ;;
      fallback)
        api_fallback_get
        ;;
      udp-games)
        api_udp_games_get
        ;;
      auto_mode)
        api_auto_mode_get
        ;;
      hostlist)
        api_hostlist_get
        ;;
      rst_guard)
        api_rst_guard_get
        ;;
      reasm)
        api_reasm_get
        ;;
      quic443)
        api_quic443_get
        ;;
      dns_desync)
        api_dns_desync_get
        ;;
      ports)
        api_ports_get
        ;;
      provider)
        api_provider_get
        ;;
      recommendations)
        api_recommendations_get
        ;;
      supersweep)
        api_supersweep_get
        ;;
      update_check)
        api_update_check
        ;;
      *)
        api_tls_blob_get
        ;;
    esac
    ;;
  POST)
    parse_params
    case "${PARAM_SETTING:-}" in
      tls_blob)
        api_tls_blob_set
        ;;
      tls_blob_profile)
        api_tls_blob_profile_set
        ;;
      fake_mode)
        api_fake_mode_set
        ;;
      clone_size)
        api_clone_size_set
        ;;
      wg_blob)
        api_wg_blob_set
        ;;
      wg_repeats)
        api_wg_repeats_set
        ;;
      wg_state)
        api_wg_state_set
        ;;
      fallback_state)
        api_fallback_state_set
        ;;
      udp_games_state)
        api_udp_games_set
        ;;
      auto_mode_state)
        api_auto_mode_set
        ;;
      hostlist_state)
        api_hostlist_set
        ;;
      rst_guard_state)
        api_rst_guard_set
        ;;
      reasm_state)
        api_reasm_set
        ;;
      quic443_state)
        api_quic443_set
        ;;
      dns_desync_state)
        api_dns_desync_set
        ;;
      ports_add)
        api_ports_add
        ;;
      ports_remove)
        api_ports_remove
        ;;
      provider_set)
        api_provider_set
        ;;
      provider_redetect)
        api_provider_redetect
        ;;
      *)
        send_error "400 Bad Request" "Неизвестная настройка"
        ;;
    esac
    ;;
  *)
    send_error "405 Method Not Allowed" "Метод не поддерживается"
    ;;
esac
