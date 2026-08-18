#!/usr/bin/env bash
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
      *)
        send_error "400 Bad Request" "Неизвестная настройка"
        ;;
    esac
    ;;
  *)
    send_error "405 Method Not Allowed" "Метод не поддерживается"
    ;;
esac
