#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_BROWSER_DIR="$tmp/runtime/browser"
mkdir -p "$ZATOR_ROOT/extra_strats/cache/adaptive" "$ZATOR_ROOT/extra_strats/cache" "$tmp/mockbin"
printf '#!/bin/sh\nexit 127\n' > "$tmp/mockbin/od"
. "$ROOT/lib/adaptive_browser.sh"

attempt=abcdefabcdefabcdefabcdefabcdefab
client=0123456789abcdef0123456789abcdef
now="$(date +%s)"
fingerprint="sha256:$(printf '%064d' 0 | tr 0 a)"
adaptive_browser_attempt_write "$attempt" "$client" 192.168.1.42 mark:7 example.org 8.8.8.8 1 tls main_frame_network_failure CONFIRMED_SUCCESS 2 "$fingerprint" "$now" "$((now + 45))" 1
adaptive_browser_stats_queue_attempt "$attempt"
[[ ! -e "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-queue.tsv" ]] || { echo 'browser outcomes queued without consent' >&2; exit 1; }

printf 'MTS - Test City\n' > "$ZATOR_ROOT/extra_strats/cache/provider.txt"
printf '%s\n' 'test-client-token-abcdefghijklmnopqrstuvwxyz_1234567890' > "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-upload-token"
printf '1\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-upload-opt-in"
chmod 600 "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-upload-token" "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-upload-opt-in"
adaptive_browser_stats_queue_attempt "$attempt"
queue="$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-queue.tsv"
[[ "$(wc -l < "$queue")" = 1 && "$(stat -c '%a' "$queue")" = 600 ]]
! grep -q 'example.org\|8\.8\.8\.8\|192\.168\.1\.42\|browser-token' "$queue"

fallback_attempt=abcdefabcdefabcdefabcdefabcdefac
adaptive_browser_attempt_write "$fallback_attempt" "$client" 192.168.1.42 mark:7 rr1---sn-a.googlevideo.com 8.8.8.8 5 quic main_frame_network_failure TCP_FALLBACK 2 "$fingerprint" "$now" "$((now + 45))" 2
adaptive_browser_stats_queue_attempt "$fallback_attempt"
[[ "$(wc -l < "$queue")" = 2 ]]
h3_attempt=abcdefabcdefabcdefabcdefabcdefad
adaptive_browser_attempt_write "$h3_attempt" "$client" 192.168.1.42 mark:7 rr1---sn-a.googlevideo.com 8.8.8.8 5 quic main_frame_network_failure CONFIRMED_SUCCESS 2 "$fingerprint" "$now" "$((now + 45))" 3
adaptive_browser_stats_queue_attempt "$h3_attempt"
[[ "$(wc -l < "$queue")" = 3 ]]

cat > "$tmp/mockbin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -eu
config=''; payload=''; response=''; url=''
while (($#)); do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    --data-binary) payload="${2#@}"; shift 2 ;;
    -o) response="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "$Z2R_TEST_STATS_URL"
cp "$config" "$Z2R_TEST_STATS_CURL_CONFIG"
cp "$payload" "$Z2R_TEST_STATS_PAYLOAD"
[[ "${Z2R_TEST_STATS_FAIL:-0}" != 1 ]] || exit 22
printf '{"ok": true, "accepted": 1, "source": "browser_flow"}\n' > "$response"
MOCK_CURL
chmod +x "$tmp/mockbin/curl" "$tmp/mockbin/od"
export PATH="$tmp/mockbin:$PATH"
export Z2R_TEST_STATS_URL="$tmp/upload-url" Z2R_TEST_STATS_CURL_CONFIG="$tmp/curl.conf" Z2R_TEST_STATS_PAYLOAD="$tmp/payload.json"
if Z2R_TEST_STATS_FAIL=1 adaptive_browser_stats_flush; then echo 'failed upload was reported as success' >&2; exit 1; fi
[[ -s "$queue" ]] || { echo 'failed upload discarded queued results' >&2; exit 1; }
[[ "$(wc -l < "$tmp/upload-url")" = 1 ]] || { echo 'unexpected upload count after one failed request' >&2; exit 1; }
rm -f "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-upload-opt-in"
adaptive_browser_stats_flush
[[ -s "$queue" && "$(wc -l < "$tmp/upload-url")" = 1 ]] || { echo 'withdrawn consent allowed upload or discarded local rows' >&2; exit 1; }
printf '1\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-upload-opt-in"
chmod 600 "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-upload-opt-in"
adaptive_browser_stats_flush
[[ ! -e "$queue" ]] || { echo 'accepted upload did not clear sent result' >&2; exit 1; }
[[ "$(wc -l < "$tmp/upload-url")" = 2 && "$(tail -n1 "$tmp/upload-url")" = 'https://alooflibra.fun/z4r/adaptive-v2/browser-flow' ]]
grep -q 'Authorization: Bearer test-client-token-' "$tmp/curl.conf"
grep -q '"provider":"MTS"' "$tmp/payload.json"
grep -q '"state":"CONFIRMED_SUCCESS"' "$tmp/payload.json"
grep -q '"protocol_proven":true' "$tmp/payload.json"
grep -q '"state":"TCP_FALLBACK"' "$tmp/payload.json"
grep -q '"protocol":"quic"' "$tmp/payload.json"
grep -q '"protocol":"quic".*"state":"CONFIRMED_SUCCESS".*"protocol_proven":true' "$tmp/payload.json"
! grep -Eq 'example\.org|8\.8\.8\.8|192\.168\.1\.42|test-client-token' "$tmp/payload.json"
rm -f "$ZATOR_ROOT/extra_strats/cache/adaptive/browser-flow-upload-opt-in"
adaptive_browser_stats_flush

echo 'adaptive browser stats smoke: OK'
