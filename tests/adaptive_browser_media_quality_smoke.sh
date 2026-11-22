#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export Z2R_ADAPTIVE_BROWSER_DIR="$tmp/browser"
. "$ROOT/lib/adaptive_browser.sh"

now="$(date +%s)"
dir="$Z2R_ADAPTIVE_BROWSER_DIR/media-quality"
mkdir -p "$dir"
file="$dir/evidence.tsv"
fingerprint="sha256:$(printf '%064d' 0 | tr 0 c)"
for i in $(seq 1 63); do
  printf '1\t%032x\t%s\t0123456789abcdef0123456789abcdef\tmark:7\trr1---sn-a5mekn6e.googlevideo.com\t8.8.8.8\t2\tgooglevideo-tcp\t4\t%s\tapplied\tconfirmed\thealthy\t8000\t7000\t0\t1\t240\t%s\n' \
    "$i" "$i" "$fingerprint" "$now" >> "$file"
done

chmod 600 "$file"
attempt="$(printf '%032x' 64)"
adaptive_browser_media_quality_write "$attempt" 64 0123456789abcdef0123456789abcdef mark:7 \
  rr1---sn-a5mekn6e.googlevideo.com 8.8.8.8 2 googlevideo-tcp 4 \
  "$fingerprint" applied confirmed healthy 8000 7000 0 1 240 "$now"
[[ "$(wc -l < "$file")" = 64 ]]
[[ "$(stat -c '%a' "$file")" = 600 ]]
[[ "$(stat -c '%a' "$(dirname "$file")")" = 700 ]]
! grep -q 'videoplayback\|signature\|secret' "$file"
if adaptive_browser_media_quality_write "$attempt" 64 0123456789abcdef0123456789abcdef mark:7 \
  rr1---sn-a5mekn6e.googlevideo.com 8.8.8.8 2 googlevideo-tcp 4 \
  "$fingerprint" applied confirmed healthy 8000 7000 0 1 240 "$now"; then
  echo 'media evidence replay overwrote an existing attempt' >&2
  exit 1
else
  [[ "$?" = 3 ]]
fi

if adaptive_browser_media_quality_write "$(printf '%032x' 65)" 65 0123456789abcdef0123456789abcdef mark:7 \
  rr1---sn-a5mekn6e.googlevideo.com 8.8.8.8 2 googlevideo-tcp 4 \
  "$fingerprint" applied confirmed healthy 8000 7000 0 1 240 "$now"; then
  echo 'media quality store exceeded its 64-row cap' >&2
  exit 1
fi
[[ "$(wc -l < "$file")" = 64 ]]

if adaptive_browser_media_quality_write "$(printf '%032x' 65)" 65 0123456789abcdef0123456789abcdef mark:7 \
  rr1---sn-a5mekn6e.googlevideo.com 8.8.8.8 2 googlevideo-tcp 4 \
  "$fingerprint" applied confirmed healthy 4000 1000 0 1 240 "$now"; then
  echo 'weak healthy evidence passed the media store gate' >&2
  exit 1
fi

echo 'adaptive browser media quality smoke: PASS'
