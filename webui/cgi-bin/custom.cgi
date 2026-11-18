#!/usr/bin/env bash
. /opt/zator/webui/cgi-bin/_lib.sh
case "${REQUEST_METHOD:-GET}" in
  GET)
    api_custom_list
    ;;
  POST)
    api_custom_action
    ;;
  *)
    send_error "405 Method Not Allowed" "Метод не поддерживается"
    ;;
esac
