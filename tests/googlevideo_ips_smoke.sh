#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/z2r-googlevideo.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export ZATOR_ROOT="$TMP/zator"
export GOOGLEVIDEO_IPS_FILE="$TMP/zator/lists/googlevideo-ipv4.txt"
export Z2R_GOOGLEVIDEO_IPS_CACHE_TTL=0
source "$ROOT/lib/googlevideo_ips.sh"

curl() {
  local output=""; while [ "$#" -gt 0 ]; do
    case "$1" in -o) output="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "$output" ] || return 2
  cp "$GOOGLEVIDEO_TEST_PAYLOAD" "$output"
}

GOOGLEVIDEO_TEST_PAYLOAD="$TMP/valid.txt"
printf '# googlevideo IPv4; generated=2026-11-10T00:00:00Z; max_age=604800s\n\n8.8.8.8\n' > "$GOOGLEVIDEO_TEST_PAYLOAD"
googlevideo_ips_update
[ "$(googlevideo_ips_count)" = 1 ]

GOOGLEVIDEO_TEST_PAYLOAD="$TMP/invalid.txt"
printf '# googlevideo IPv4; generated=2026-11-10T00:00:00Z; max_age=604800s\n10.0.0.1\n' > "$GOOGLEVIDEO_TEST_PAYLOAD"
if googlevideo_ips_update; then exit 1; fi
grep -Fxq 8.8.8.8 "$GOOGLEVIDEO_IPS_FILE"

printf '# googlevideo IPv4; generated=x\n192.168.1.1\n' > "$TMP/private.txt"
if googlevideo_ips_validate "$TMP/private.txt"; then exit 1; fi
printf '# googlevideo IPv4; generated=x\n203.0.113.1\n' > "$TMP/documentation.txt"
if googlevideo_ips_validate "$TMP/documentation.txt"; then exit 1; fi
printf '# googlevideo IPv4; generated=x\n008.008.008.008\n' > "$TMP/noncanonical.txt"
if googlevideo_ips_validate "$TMP/noncanonical.txt"; then exit 1; fi
printf '# googlevideo IPv4; generated=x\n8.8.8.8\nyoutube.com\n' > "$TMP/malformed.txt"
if googlevideo_ips_validate "$TMP/malformed.txt"; then exit 1; fi
echo 'googlevideo IP cache smoke ok'
