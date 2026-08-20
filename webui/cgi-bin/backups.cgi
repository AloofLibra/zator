#!/usr/bin/env bash
. /opt/zator/webui/cgi-bin/_lib.sh

case "${REQUEST_METHOD:-GET}" in
  GET)
    parse_params
    case "${PARAM_ACTION:-}" in
      download)
        api_backups_download
        ;;
      *)
        api_backups_list
        ;;
    esac
    ;;
  POST)
    case "${QUERY_STRING:-}" in
      *action=upload*)
        api_backups_upload
        ;;
      *)
        parse_params
        case "${PARAM_ACTION:-}" in
          create)
            api_backups_create
            ;;
          delete)
            api_backups_delete
            ;;
          *)
            send_error "400 Bad Request" "Неизвестное действие"
            ;;
        esac
        ;;
    esac
    ;;
  *)
    send_error "405 Method Not Allowed" "Метод не поддерживается"
    ;;
esac
