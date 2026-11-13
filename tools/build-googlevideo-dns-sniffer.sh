#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-"$ROOT/tools/bin/googlevideo-dns-sniffer-$(uname -m)"}
CC=${CC:-cc}
STRIP=${STRIP:-strip}
MAX_BYTES=${Z2R_GV_SNIFFER_MAX_BYTES:-139264}
TMP="${OUT}.tmp.$$"
trap 'rm -f "$TMP"' EXIT HUP INT TERM
mkdir -p "$(dirname "$OUT")"
"$CC" -std=c99 -Os -Wall -Wextra -Werror -static -fno-ident \
  -ffunction-sections -fdata-sections -Wl,--gc-sections -Wl,--build-id=none \
  ${Z2R_GV_SNIFFER_CFLAGS:-} ${Z2R_GV_SNIFFER_LDFLAGS:-} \
  -o "$TMP" "$ROOT/tools/googlevideo-dns-sniffer.c"
"$STRIP" "$TMP"
size=$(wc -c < "$TMP" | tr -d ' ')
[ "$size" -le "$MAX_BYTES" ] || { echo "sniffer is ${size} bytes (limit ${MAX_BYTES})" >&2; exit 1; }
mv -f "$TMP" "$OUT"
echo "$OUT: $size bytes"
