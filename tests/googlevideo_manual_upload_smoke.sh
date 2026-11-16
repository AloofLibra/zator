#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/z2r-googlevideo-manual.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/lib/submenus.sh"
yellow='' green='' plain=''
grep -Fq 'submenu_item "10" "Принудительно отправить новые локальные IP на сервер"' "$ROOT/lib/submenus.sh"
grep -A2 '"10")' "$ROOT/lib/submenus.sh" | grep -Fq 'googlevideo_upload_local_manual'
export Z2R_GV_TELEMETRY_CFG="$TMP/telemetry.config"
: > "$TMP/calls"
HAS_PENDING=0 FEED_RC=0 UPLOAD_RC=0 UPLOAD_STATUS=uploaded
googlevideo_local_spool_has_pending() { [ "$HAS_PENDING" = 1 ]; }
googlevideo_ips_update() { printf 'feed:%s\n' "$1" >> "$TMP/calls"; return "$FEED_RC"; }
googlevideo_queue_local_observations() { echo queue >> "$TMP/calls"; return 0; }
googlevideo_upload_local_batch() {
  printf 'upload:%s:%s\n' "$1" "$2" >> "$TMP/calls"
  GOOGLEVIDEO_UPLOAD_LAST_STATUS="$UPLOAD_STATUS"
  GOOGLEVIDEO_UPLOAD_LAST_COUNT=2
  return "$UPLOAD_RC"
}

printf 'tel_enabled=0\ntel_uuid=test-uuid\n' > "$Z2R_GV_TELEMETRY_CFG"
if googlevideo_upload_local_manual > "$TMP/out"; then exit 1; fi
grep -q 'Телеметрия выключена' "$TMP/out"
[ ! -s "$TMP/calls" ]

printf 'tel_enabled=1\ntel_uuid=test-uuid\n' > "$Z2R_GV_TELEMETRY_CFG"
googlevideo_upload_local_manual > "$TMP/out"
grep -q 'Очередь локальных наблюдений пуста' "$TMP/out"
[ ! -s "$TMP/calls" ]

HAS_PENDING=1 FEED_RC=1
if googlevideo_upload_local_manual > "$TMP/out"; then exit 1; fi
grep -q 'Не удалось обновить центральный список' "$TMP/out"
grep -Fxq 'feed:force' "$TMP/calls"
[ "$(wc -l < "$TMP/calls")" -eq 1 ]

FEED_RC=0
googlevideo_upload_local_manual > "$TMP/out"
grep -A2 -F 'feed:force' "$TMP/calls" | grep -Fxq queue
grep -Fxq 'upload:test-uuid:force' "$TMP/calls"
grep -q 'Отправлено новых IP: 2' "$TMP/out"

UPLOAD_STATUS=no-new
googlevideo_upload_local_manual > "$TMP/out"
grep -q 'Новых IP относительно центрального списка нет' "$TMP/out"

UPLOAD_RC=1
if googlevideo_upload_local_manual > "$TMP/out"; then exit 1; fi
grep -q 'очередь сохранена для повтора' "$TMP/out"
echo 'googlevideo manual upload smoke ok'
