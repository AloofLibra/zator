#!/bin/bash
# Shared local observer: UBus events on OpenWrt, passive packet source elsewhere.
ROOT="${Z2R_GV_ROOT:-/opt/zator}"
LIB="$ROOT/z2r_lib/googlevideo_ips.sh"
default_sniffer="$ROOT/tools/bin/googlevideo-dns-sniffer"
SNIFFER="${Z2R_GV_SNIFFER:-$default_sniffer}"
CONFIG="${Z2R_GV_CONFIG:-/opt/zapret2/config}"
PIDFILE="${Z2R_GV_PIDFILE:-/var/run/z2r-googlevideo-dns.pid}"
LOG="${Z2R_GV_LOG:-/tmp/z2r-googlevideo-dns.log}"

enabled() {
  [ -r "$CONFIG" ] || return 1
  NFQWS2_ENABLE=0 Z2R_WSSIZE_RAMP_ENABLE=0
  . "$CONFIG"
  [ "${NFQWS2_ENABLE:-0}" = 1 ] && [ "${Z2R_WSSIZE_RAMP_ENABLE:-0}" = 1 ]
}

googlevideo_dns_event_parse() {
  local json="$1" key out
  [[ "$json" == *'"dns_result"'* ]] || return 1
  for key in name type address; do
    if [[ "$json" =~ \"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
      printf -v "$key" '%s' "${BASH_REMATCH[1]}"
    else
      return 1
    fi
  done
  if [[ "$json" =~ \"ttl\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    ttl="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  [ "$type" = A ]
}

observe_local() {
  local host="${1,,}" ip="$2" ttl="$3" type="${4:-A}" key now
  case "$ttl" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#ttl}" -le 6 ] || ttl=604800
  ttl=$((10#$ttl)); [ "$ttl" -gt 0 ] || return 1; [ "$ttl" -le 604800 ] || ttl=604800
  key="$host|$ip"; now=$SECONDS
  [ "${recent[$key]:-0}" -gt "$now" ] && return 0
  recent[$key]=$((now + ttl)); seen_count=$((seen_count + 1))
  if [ "$seen_count" -gt 8192 ]; then unset recent; declare -A recent=(); seen_count=0; fi
  GOOGLEVIDEO_LOCAL_FILE="${Z2R_GV_LOCAL_FILE:-/tmp/z2r-googlevideo/local.tsv}" googlevideo_observe_local "$host" "$ip" "$ttl" "$type"
}

maybe_upload_local_batch() {
  [ "${SECONDS:-0}" -ge "${next_upload_check:-0}" ] || return 0
  next_upload_check=$((SECONDS + ${Z2R_GV_UPLOAD_CHECK_INTERVAL:-60}))
  googlevideo_local_spool_has_pending || return 0
  local telemetry_cfg="${Z2R_GV_TELEMETRY_CFG:-$ROOT/z2r_lib/telemetry.config}"
  [ -r "$telemetry_cfg" ] && grep -Fxq 'tel_enabled=1' "$telemetry_cfg" || return 0
  [ -z "${upload_worker:-}" ] || kill -0 "$upload_worker" 2>/dev/null || upload_worker=""
  [ -z "${upload_worker:-}" ] || return 0
  (
    tel_enabled=0 tel_uuid=
    [ -r "$ROOT/z2r_lib/telemetry.sh" ] && . "$ROOT/z2r_lib/telemetry.sh"
    TELEMETRY_CFG="${Z2R_GV_TELEMETRY_CFG:-$ROOT/z2r_lib/telemetry.config}"
    [ -r "$TELEMETRY_CFG" ] && . "$TELEMETRY_CFG"
    googlevideo_upload_local_batch "${tel_uuid:-}" || :
  ) >/dev/null 2>&1 &
  upload_worker=$!
}

run_ubus_source() {
  local fifo="${Z2R_GV_TMPDIR:-/tmp/z2r-googlevideo}/ubus.fifo" subscriber= event
  [ -p "$fifo" ] || { rm -f "$fifo"; mkfifo "$fifo"; }
  exec 3<>"$fifo"
  while enabled; do
    "${Z2R_GV_UBUS:-ubus}" subscribe dnsmasq.dns > "$fifo" 2>/dev/null & subscriber=$!
    while kill -0 "$subscriber" 2>/dev/null; do
      if IFS= read -r -t 1 event <&3; then
        if [ -n "$event" ] && googlevideo_dns_event_parse "$event"; then
          observe_local "$name" "$address" "$ttl" "$type" || :
        fi
      fi
      maybe_upload_local_batch
    done
    kill "$subscriber" 2>/dev/null || :; wait "$subscriber" 2>/dev/null || :
    sleep 1
  done
}

run_packet_source() {
  local fifo="${Z2R_GV_TMPDIR:-/tmp/z2r-googlevideo}/packet.fifo" child row host ip ttl
  [ -x "$SNIFFER" ] || return 0
  [ -p "$fifo" ] || { rm -f "$fifo"; mkfifo "$fifo"; }
  exec 3<>"$fifo"
  while enabled; do
    "$SNIFFER" > "$fifo" 2>>"$LOG" & child=$!
    while kill -0 "$child" 2>/dev/null; do
      if IFS= read -r -t 1 row <&3; then
        IFS="$(printf '\t')" read -r host ip ttl <<< "$row"
        if [ -n "$host" ] && [ -n "$ip" ] && [ -n "$ttl" ]; then
          observe_local "$host" "$ip" "$ttl" A || :
        fi
      fi
      maybe_upload_local_batch
    done
    kill "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :
    sleep 1
  done
}

run_listener() {
  . "$ROOT/z2r_lib/config.sh" || return 1
  GOOGLEVIDEO_PENDING_FILE="${Z2R_GOOGLEVIDEO_PENDING_FILE:-${Z2R_GV_TMPDIR:-/tmp/z2r-googlevideo}/pending.tsv}"
  . "$LIB" || return 1
  mkdir -p "${Z2R_GV_TMPDIR:-/tmp/z2r-googlevideo}"
  echo $$ > "$PIDFILE"
  declare -A recent=(); seen_count=0
  next_upload_check=0; upload_worker=""
  # The upload worker is a short one-shot (curl timeout 8s). Let it finish if
  # the listener is stopped so a successful server response cannot be lost.
  stop_listener() { [ -z "${child:-}" ] || kill "$child" 2>/dev/null || :; [ -z "${subscriber:-}" ] || kill "$subscriber" 2>/dev/null || :; rm -f "$PIDFILE"; exit 0; }
  trap stop_listener TERM INT HUP
  if [ -r "${Z2R_GV_OPENWRT_RELEASE:-/etc/openwrt_release}" ] && command -v ubus >/dev/null 2>&1; then
    run_ubus_source
  elif [ -x "$SNIFFER" ]; then
    run_packet_source
  fi
  rm -f "$PIDFILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
case "${1:-start}" in
  start)
    enabled || exit 0
    if [ -r "${Z2R_GV_OPENWRT_RELEASE:-/etc/openwrt_release}" ]; then
      command -v ubus >/dev/null 2>&1 || exit 0
      "${Z2R_GV_UBUS:-ubus}" list 2>/dev/null | grep -Fxq dnsmasq.dns || exit 0
    else
      [ -x "$SNIFFER" ] || exit 0
    fi
    if [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then exit 0; fi
    mkdir -p "${Z2R_GV_TMPDIR:-/tmp/z2r-googlevideo}"
    "$0" run >> "$LOG" 2>&1 </dev/null &
    echo $! > "$PIDFILE"
    ;;
  stop)
    if [ -s "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || :; rm -f "$PIDFILE"; fi
    ;;
  status)
    [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
    ;;
  run) run_listener ;;
  *) exit 2 ;;
esac
fi
