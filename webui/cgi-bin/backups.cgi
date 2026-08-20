#!/usr/bin/env bash
. /opt/zator/webui/cgi-bin/_lib.sh

case "${REQUEST_METHOD:-GET}" in
  GET)
    parse_params
    api_backups_list
    ;;
  POST)
    parse_params
    case "${PARAM_ACTION:-}" in
      create)
        api_backups_create
        ;;
      *)
        send_error "400 Bad Request" "Неизвестное действие"
        ;;
    esac
    ;;
  *)
    send_error "405 Method Not Allowed" "Метод не поддерживается"
    ;;
esac
