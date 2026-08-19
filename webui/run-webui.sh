#!/usr/bin/env bash

set -eu

PATH="/opt/bin:/opt/sbin:$PATH"
export PATH

WEBUI_ROOT="/opt/zator/webui"
WEBUI_WWW="$WEBUI_ROOT/www"
WEBUI_RUN="$WEBUI_ROOT/run"
PID_FILE="$WEBUI_RUN/webui.pid"
LOG_FILE="$WEBUI_RUN/webui.log"
PORT="${WEBUI_PORT:-17682}"

ensure_dirs() {
  mkdir -p "$WEBUI_RUN"
}

has_busybox_httpd() {
  if ! command -v busybox >/dev/null 2>&1; then
    return 1
  fi
  busybox --list 2>/dev/null | grep -qx 'httpd'
}

available_servers() {
  command -v uhttpd >/dev/null 2>&1 && echo "uhttpd"
  command -v uhttpd_kn >/dev/null 2>&1 && echo "uhttpd_kn"
  command -v httpd >/dev/null 2>&1 && echo "httpd"
  has_busybox_httpd && echo "busybox"
}

first_server() {
  available_servers | sed -n '1p'
}

server_patterns() {
  printf '%s\n' \
    "uhttpd_kn.*${WEBUI_WWW}" \
    "uhttpd.*${WEBUI_WWW}" \
    "httpd.*${WEBUI_WWW}" \
    "busybox httpd.*${WEBUI_WWW}"
}

is_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

has_port_listener() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q "[\:\.]${PORT}[[:space:]]"
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q "[\:\.]${PORT}[[:space:]]"
    return
  fi
  return 1
}

has_matching_process() {
  local pattern
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r pattern; do
      pgrep -f "$pattern" >/dev/null 2>&1 && return 0
    done <<EOF
$(server_patterns)
EOF
  fi
  if command -v ps >/dev/null 2>&1; then
    ps w 2>/dev/null | grep -F "$WEBUI_WWW" | grep -E "uhttpd_kn|uhttpd|(^|[[:space:]])httpd|busybox httpd" | grep -v grep >/dev/null 2>&1 && return 0
  fi
  return 1
}

is_running_any() {
  is_running && return 0
  has_matching_process && return 0
  has_port_listener && return 0
  return 1
}

run_server_once() {
  local server="$1"
  case "$server" in
    uhttpd_kn)
      exec uhttpd_kn -f -p "0.0.0.0:${PORT}" -h "$WEBUI_WWW" -x /cgi-bin
      ;;
    uhttpd)
      exec uhttpd -f -p "0.0.0.0:${PORT}" -h "$WEBUI_WWW" -x /cgi-bin
      ;;
    httpd)
      exec httpd -f -p "0.0.0.0:${PORT}" -h "$WEBUI_WWW"
      ;;
    busybox)
      exec busybox httpd -f -p "0.0.0.0:${PORT}" -h "$WEBUI_WWW"
      ;;
    *)
      echo "No supported web server found" >&2
      exit 1
      ;;
  esac
}

run_server() {
  local server
  server="$(first_server)"
  if [ -z "$server" ]; then
    echo "No supported web server found" >&2
    exit 1
  fi
  echo "Trying web server: $server" >&2
  run_server_once "$server"
}

start_detached() {
  if command -v nohup >/dev/null 2>&1; then
    nohup bash "$0" run >>"$LOG_FILE" 2>&1 &
    return
  fi
  if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx 'nohup'; then
    busybox nohup bash "$0" run >>"$LOG_FILE" 2>&1 &
    return
  fi
  bash "$0" run >>"$LOG_FILE" 2>&1 &
}

start_server() {
  ensure_dirs
  if is_running_any; then
    echo "already running"
    return 0
  fi
  start_detached
  echo $! > "$PID_FILE"
  sleep 1
  if ! is_running; then
    echo "failed to start"
    return 1
  fi
  echo "started"
}

stop_server() {
  local pattern
  if is_running; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    sleep 1
    if is_running; then
      kill -9 "$(cat "$PID_FILE")" 2>/dev/null || true
    fi
  fi
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r pattern; do
      pgrep -f "$pattern" >/dev/null 2>&1 && pkill -f "$pattern" 2>/dev/null || true
    done <<EOF
$(server_patterns)
EOF
  fi
  rm -f "$PID_FILE"
  echo "stopped"
}

status_server() {
  local server
  server="$(first_server)"
  [ -n "$server" ] || server="none"
  if is_running_any; then
    echo "running:${server}:${PORT}"
  else
    echo "stopped:${server}:${PORT}"
  fi
}

detect_lan_ip() {
  local iface iface_ip
  if command -v ip >/dev/null 2>&1; then
    for iface in br-lan br0; do
      iface_ip="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
      if [ -n "$iface_ip" ]; then
        echo "$iface_ip"
        return 0
      fi
    done
  fi
  hostname -I 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | head -n 1
}

print_urls() {
  local hostname lan_ip
  hostname="$(hostname 2>/dev/null || true)"
  [ "$hostname" = "localhost" ] && hostname=""
  lan_ip="$(detect_lan_ip || true)"
  if [ -n "$lan_ip" ]; then
    echo "http://${lan_ip}:${PORT}"
  fi
  if [ -n "$hostname" ]; then
    echo "http://${hostname}:${PORT}"
  fi
  if [ -z "$lan_ip" ] && [ -z "$hostname" ]; then
    echo "http://127.0.0.1:${PORT}"
  fi
}

case "${1:-}" in
  run)
    run_server
    ;;
  start)
    start_server
    ;;
  stop)
    stop_server
    ;;
  restart)
    stop_server
    start_server
    ;;
  status)
    status_server
    ;;
  urls)
    print_urls
    ;;
  *)
    echo "usage: $0 {run|start|stop|restart|status|urls}" >&2
    exit 1
    ;;
esac
