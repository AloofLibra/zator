#!/bin/sh
# Thin lifecycle wrapper. The long-lived DNS collector is the small C binary.
ROOT=${Z2R_GV_ROOT:-/opt/zator}
SNIFFER=${Z2R_GV_SNIFFER:-$ROOT/tools/bin/googlevideo-dns-sniffer}
CONFIG=${Z2R_GV_CONFIG:-/opt/zapret2/config}
PIDFILE=${Z2R_GV_PIDFILE:-/var/run/z2r-googlevideo-dns.pid}
LOG=${Z2R_GV_LOG:-${Z2R_GV_LOG_FILE:-/tmp/z2r-googlevideo-dns.log}}

enabled() {
  [ -r "$CONFIG" ] || return 1
  NFQWS2_ENABLE=0 Z2R_WSSIZE_RAMP_ENABLE=0
  . "$CONFIG"
  [ "${NFQWS2_ENABLE:-0}" = 1 ] && [ "${Z2R_WSSIZE_RAMP_ENABLE:-0}" = 1 ]
}

upload_once() {
  bash_bin=
  for candidate in /opt/bin/bash /bin/bash /usr/bin/bash; do
    if [ -x "$candidate" ]; then bash_bin=$candidate; break; fi
  done
  [ -n "$bash_bin" ] || bash_bin=$(command -v bash 2>/dev/null || true)
  [ -n "$bash_bin" ] || exit 127
  exec "$bash_bin" -c '
    ROOT=${Z2R_GV_ROOT:-/opt/zator}
    . "$ROOT/z2r_lib/config.sh" || exit 1
    GOOGLEVIDEO_LOCAL_FILE=${Z2R_GV_LOCAL_FILE:-${Z2R_GV_TMPDIR:-/tmp/z2r-googlevideo}/local.tsv}
    GOOGLEVIDEO_PENDING_FILE=${Z2R_GOOGLEVIDEO_PENDING_FILE:-${Z2R_GV_TMPDIR:-/tmp/z2r-googlevideo}/pending.tsv}
    . "$ROOT/z2r_lib/googlevideo_ips.sh" || exit 1
    tel_enabled=0 tel_uuid=
    [ -r "$ROOT/z2r_lib/telemetry.sh" ] && . "$ROOT/z2r_lib/telemetry.sh"
    TELEMETRY_CFG=${Z2R_GV_TELEMETRY_CFG:-$ROOT/z2r_lib/telemetry.config}
    [ -r "$TELEMETRY_CFG" ] && . "$TELEMETRY_CFG"
    googlevideo_upload_local_batch "${tel_uuid:-}"
  '
}

case ${1:-start} in
  upload-once) upload_once ;;
  start)
    enabled || exit 0
    [ -x "$SNIFFER" ] || { echo "Googlevideo collector binary missing: $SNIFFER" >&2; exit 1; }
    if [ -s "$PIDFILE" ]; then
      old=$(cat "$PIDFILE" 2>/dev/null || true)
      case $old in *[!0-9]*|'') ;; *) kill -0 "$old" 2>/dev/null && exit 0 ;; esac
    fi
    mkdir -p "$(dirname "$PIDFILE")" "${Z2R_GV_TMPDIR:-/tmp/z2r-googlevideo}"
    rm -f "$PIDFILE"
    "$SNIFFER" --collector >>"$LOG" 2>&1 </dev/null &
    ;;
  run)
    [ -x "$SNIFFER" ] || exit 127
    exec "$SNIFFER" --collector
    ;;
  stop)
    if [ -s "$PIDFILE" ]; then
      pid=$(cat "$PIDFILE" 2>/dev/null || true)
      case $pid in
        *[!0-9]*|'') ;;
        *)
          if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || :
            tries=0
            while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 3 ]; do sleep 1; tries=$((tries + 1)); done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || :
          fi
          ;;
      esac
      rm -f "$PIDFILE"
    fi
    ;;
  status)
    [ -s "$PIDFILE" ] || exit 1
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    case $pid in *[!0-9]*|'') exit 1 ;; esac
    kill -0 "$pid" 2>/dev/null
    ;;
  *) echo "usage: $0 {start|run|stop|status|upload-once}" >&2; exit 2 ;;
esac
