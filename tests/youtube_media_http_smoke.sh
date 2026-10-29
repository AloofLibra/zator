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
export MEDIA_TEST_CURL=${MEDIA_TEST_CURL:-$(command -v curl)} MEDIA_TEST_CA="$tmp/cert.pem" MEDIA_TEST_PORT="$port"
cat > "$tmp/bin/curl" <<'WRAPPER'
#!/bin/sh
exec "$MEDIA_TEST_CURL" -q --cacert "$MEDIA_TEST_CA" --connect-to "rr1---sn-example.googlevideo.com:443:127.0.0.1:$MEDIA_TEST_PORT" "$@"
WRAPPER
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" Z2R_SUPERSWEEP_DIR="$tmp/run"
for limiter in native stream; do
    [ "${MEDIA_TEST_LEGACY_ONLY:-0}:$limiter" != 1:native ] || continue
    if [ "$limiter" = stream ]; then touch "$tmp/cache/curl-stream-limit"; else rm -f "$tmp/cache/curl-stream-limit"; fi
for scenario in ok truncate text ignore chunked chunked_oversize; do
    jq --arg s "$scenario" '.streamingData.adaptiveFormats[].url += ("&scenario="+$s)' tests/fixtures/youtube-media/player.json > "$tmp/player.json"
    z2r_media_select "$tmp/player.json" aqz-KE-bpKQ 0123456789abcdef "$tmp/cache"
    result=$(z2r_media_probe "$tmp/cache" video 1048576 1)
    case "$scenario" in
        ok|chunked) [[ "$result" == OK\|media_range\|0\|206\|1048576\|* ]] ;;
        truncate) [[ "$result" == FAIL\|incomplete_transfer\|18\|* || "$result" == FAIL\|incomplete_transfer\|56\|* ]] ;;
        text|ignore) [[ "$result" == UNKNOWN\|* ]] ;;
        chunked_oversize) [[ "$result" != OK\|* ]] ;;
    esac
    test ! -e "$tmp/cache/body.fifo"
done
jq '.streamingData.adaptiveFormats[].url += "&scenario=stall"' tests/fixtures/youtube-media/player.json > "$tmp/player.json"
z2r_media_select "$tmp/player.json" aqz-KE-bpKQ 0123456789abcdef "$tmp/cache"
z2r_media_probe "$tmp/cache" video 1048576 0 > "$tmp/result" &
pid=$!
sleep 1
touch "$tmp/run/cancel"
wait "$pid"
grep -q '^UNKNOWN|cancelled|' "$tmp/result"
test ! -e "$tmp/cache/body.fifo"
rm "$tmp/run/cancel"
done
# Старый curl: chunked API не заполняет tmpfs; пустой ответ/ошибка не подвешивают FIFO.
touch "$tmp/cache/curl-stream-limit"
echo '{}' > "$tmp/request"
rc=0
z2r_media_api 'https://rr1---sn-example.googlevideo.com/api?scenario=oversize' "$tmp/request" "$tmp/cache/response" > "$tmp/code" || rc=$?
test "$rc" != 0
test "$(wc -c < "$tmp/cache/response")" -le 262145
test ! -e "$tmp/cache/body.fifo"
z2r_media_api 'https://rr1---sn-example.googlevideo.com/api?scenario=empty' "$tmp/request" "$tmp/cache/response" > "$tmp/code"
test "$(cat "$tmp/code")" = 204
test ! -s "$tmp/cache/response"
rc=0
_z2r_media_curl "$tmp/cache" 4096 "$tmp/cache/response" -q -s --noproxy '*' --max-time 2 https://127.0.0.1:1/ > /dev/null 2>&1 || rc=$?
test "$rc" != 0
test ! -e "$tmp/cache/body.fifo"
result=$(MEDIA_TEST_PORT=1 z2r_media_probe "$tmp/cache" video 4096 0)
[[ "$result" == FAIL\|network_error\|7\|* ]]
test ! -e "$tmp/cache/body.fifo"
echo 'youtube media http smoke ok'
