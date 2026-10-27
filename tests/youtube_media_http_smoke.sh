#!/usr/bin/env bash
# Настоящий curl к локальному HTTPS-серверу; ни одного обращения к YouTube.
set -euo pipefail
cd "$(dirname "$0")/.."
for cmd in jq curl openssl python3; do command -v "$cmd" >/dev/null || { echo "FAIL: test prerequisite $cmd missing"; exit 1; }; done
source lib/youtube_media.sh
tmp=$(mktemp -d)
server=
trap 'if [ -n "$server" ]; then kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; fi; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cache" "$tmp/bin" "$tmp/run"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=rr1---sn-example.googlevideo.com' \
    -addext 'subjectAltName=DNS:rr1---sn-example.googlevideo.com' \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
python3 tests/fixtures/youtube-media/server.py "$tmp/cert.pem" "$tmp/key.pem" "$tmp/port" > "$tmp/server.log" 2>&1 &
server=$!
for ((i=0;i<50;i++)); do [ ! -s "$tmp/port" ] || break; sleep .1; done
port=$(cat "$tmp/port")
export MEDIA_TEST_CURL=$(command -v curl) MEDIA_TEST_CA="$tmp/cert.pem" MEDIA_TEST_PORT="$port"
cat > "$tmp/bin/curl" <<'WRAPPER'
#!/bin/sh
exec "$MEDIA_TEST_CURL" -q --cacert "$MEDIA_TEST_CA" --connect-to "rr1---sn-example.googlevideo.com:443:127.0.0.1:$MEDIA_TEST_PORT" "$@"
WRAPPER
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" Z2R_SUPERSWEEP_DIR="$tmp/run"
for scenario in ok truncate text ignore; do
    jq --arg s "$scenario" '.streamingData.adaptiveFormats[].url += ("&scenario="+$s)' tests/fixtures/youtube-media/player.json > "$tmp/player.json"
    z2r_media_select "$tmp/player.json" aqz-KE-bpKQ 0123456789abcdef "$tmp/cache"
    result=$(z2r_media_probe "$tmp/cache" video 1048576 1)
    case "$scenario" in
        ok) [[ "$result" == OK\|media_range\|0\|206\|1048576\|* ]] ;;
        truncate) [[ "$result" == FAIL\|incomplete_transfer\|18\|* || "$result" == FAIL\|incomplete_transfer\|56\|* ]] ;;
        text|ignore) [[ "$result" == UNKNOWN\|* ]] ;;
    esac
done
jq '.streamingData.adaptiveFormats[].url += "&scenario=stall"' tests/fixtures/youtube-media/player.json > "$tmp/player.json"
z2r_media_select "$tmp/player.json" aqz-KE-bpKQ 0123456789abcdef "$tmp/cache"
z2r_media_probe "$tmp/cache" video 1048576 0 > "$tmp/result" &
pid=$!
sleep 1
touch "$tmp/run/cancel"
wait "$pid"
grep -q '^UNKNOWN|cancelled|' "$tmp/result"
echo 'youtube media http smoke ok'
