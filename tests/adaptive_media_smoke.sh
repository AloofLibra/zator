#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
. "$ROOT/lib/youtube_media.sh"
. "$ROOT/lib/adaptive_media.sh"

now="$(date +%s)"
host='rr1---sn-a5mekn6e.googlevideo.com'
url="https://$host/videoplayback?expire=$((now + 600))&clen=2097152&mime=video%2Fmp4&sig=opaque"
mkdir -m 700 "$tmp/cache"
printf 'url = "%s"\n' "$url" > "$tmp/cache/video.curl"
printf '2097152|video/mp4|%s|%s\n' "$host" "$((now + 600))" > "$tmp/cache/video.params"
printf '%s\n' "$((now + 600))" > "$tmp/cache/expires"
chmod 600 "$tmp/cache/"*

actual="$(adaptive_media_url_from_cache "$tmp/cache" video "$host")"
[[ "$actual" = "$url" ]] || { echo 'exact signed media URL was not returned' >&2; exit 1; }
if adaptive_media_url_from_cache "$tmp/cache" video 'rr2---sn-a5mekn6e.googlevideo.com' >/dev/null 2>&1; then
  echo 'media URL accepted for a different observed hostname' >&2; exit 1
fi
if adaptive_media_url_from_cache "$tmp/cache" video 'example.org' >/dev/null 2>&1; then
  echo 'non-Googlevideo target accepted' >&2; exit 1
fi

printf 'url = "%s"\n' "${url/expire=$((now + 600))/expire=$((now + 60))}" > "$tmp/cache/video.curl"
printf '2097152|video/mp4|%s|%s\n' "$host" "$((now + 60))" > "$tmp/cache/video.params"
if adaptive_media_url_from_cache "$tmp/cache" video "$host" >/dev/null 2>&1; then
  echo 'near-expiry signed URL accepted' >&2; exit 1
fi

resolver_calls=0
resolver_now="$now"
resolver_count_file="$tmp/resolver-count"
z2r_media_resolve() {
  local video_id="$1" dir="$2" expires=$((resolver_now + 3600)) resolved_host="rr1-index.googlevideo.com"
  resolver_calls="$(cat "$resolver_count_file" 2>/dev/null || printf '0')"
  resolver_calls=$((resolver_calls + 1))
  printf '%s\n' "$resolver_calls" > "$resolver_count_file"
  local resolved_url="https://$resolved_host/videoplayback?id=$video_id&expire=$expires&sig=private"
  printf 'url = "%s"\n' "$resolved_url" > "$dir/video.curl"
  printf '1048576|video/mp4|%s|%s\n' "$resolved_host" "$expires" > "$dir/video.params"
  printf '%s\n' "$expires" > "$dir/expires"
}
mkdir -m 700 "$tmp/probe1" "$tmp/probe2" "$tmp/probe3"
hash1="$(adaptive_media_prepare_ramp_cache "$tmp/ramp-cache" rr1-index.googlevideo.com 142.250.72.14 BPk1uJ4txPc "$tmp/probe1" "$now")"
hash2="$(adaptive_media_prepare_ramp_cache "$tmp/ramp-cache" rr1-index.googlevideo.com 142.250.72.14 BPk1uJ4txPc "$tmp/probe2" "$((now + 300))")"
[[ "$(cat "$resolver_count_file")" = 1 && "$hash1" = "$hash2" && "$hash1" =~ ^[a-f0-9]{64}$ ]] || {
  echo 'Ramp comparison did not reuse the same exact-target signed media URL' >&2; exit 1;
}
[[ "$(adaptive_media_url_from_cache "$tmp/probe2" video rr1-index.googlevideo.com)" = "$(adaptive_media_url_from_cache "$tmp/probe1" video rr1-index.googlevideo.com)" ]] || {
  echo 'Ramp cache hash matched different signed URLs' >&2; exit 1;
}
adaptive_media_prepare_ramp_cache "$tmp/ramp-cache" rr1-index.googlevideo.com 142.250.72.15 BPk1uJ4txPc "$tmp/probe3" "$((now + 301))" >/dev/null
[[ "$(cat "$resolver_count_file")" = 2 ]] || { echo 'Ramp signed URL cache crossed destination IPs' >&2; exit 1; }
resolver_now=$((now + 1300))
mkdir -m 700 "$tmp/probe4"
adaptive_media_prepare_ramp_cache "$tmp/ramp-cache" rr1-index.googlevideo.com 142.250.72.14 BPk1uJ4txPc "$tmp/probe4" "$resolver_now" >/dev/null
[[ "$(cat "$resolver_count_file")" = 3 ]] || { echo 'expired Ramp signed URL cache was reused' >&2; exit 1; }

printf 'adaptive media cache checks passed\n'
