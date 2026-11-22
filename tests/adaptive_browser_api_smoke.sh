#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2"
export Z2R_ADAPTIVE_BROWSER_CLIENTS_FILE="$tmp/zator/extra_strats/cache/adaptive/browser-clients.tsv"
export Z2R_ADAPTIVE_BROWSER_DIR="$tmp/runtime/browser" Z2R_ADAPTIVE_DIR="$tmp/runtime"
export CLIENT_SCOPE_MAP_FILE="$tmp/zator/extra_strats/cache/client_scope.tsv"
mkdir -p "$tmp/zator/extra_strats/cache/adaptive" "$tmp/zapret2" "$tmp/runtime"
printf 'AGENT_BETA\n' > "$tmp/zator/extra_strats/cache/adaptive/mode"
printf 'CLIENT_SCOPE_ENABLE=1\n' > "$tmp/zapret2/config"
printf 'mark:7\t192.168.1.42\n' > "$CLIENT_SCOPE_MAP_FILE"
config_get_var() { awk -F= -v k="$2" '$1==k {print $2; exit}' "$1"; }
. "$ROOT/lib/adaptive_browser.sh"

token="$(printf '%064d' 0 | tr 0 a)"
hash="$(printf '%s' "$token" | sha256sum | awk '{print $1}')"
client_id=0123456789abcdef0123456789abcdef
printf '1\t%s\t%s\t192.168.1.42\tmark:7\t%s\n' "$client_id" "$hash" "$(( $(date +%s) + 3600 ))" > "$Z2R_ADAPTIVE_BROWSER_CLIENTS_FILE"
chmod 600 "$Z2R_ADAPTIVE_BROWSER_CLIENTS_FILE"

adaptive_browser_client_auth "$token" 192.168.1.42 chrome-extension://abcdefghijklmnopabcdefghijklmnop
[[ "$ADAPTIVE_BROWSER_CLIENT_ID" = "$client_id" && "$ADAPTIVE_BROWSER_CLIENT_SCOPE" = mark:7 ]]
if adaptive_browser_client_auth "$token" 192.168.1.43 chrome-extension://abcdefghijklmnopabcdefghijklmnop; then exit 1; fi
if adaptive_browser_client_auth "$token" 192.168.1.42 https://example.org; then exit 1; fi

attempt=abcdefabcdefabcdefabcdefabcdefab
adaptive_browser_attempt_write "$attempt" "$client_id" 192.168.1.42 mark:7 example.org 203.0.113.10 1 tls main_frame_network_failure WAIT_NEW_FLOW 2 - "$(date +%s)" "$(( $(date +%s) + 30 ))" 1
line="$(adaptive_browser_attempt_read "$attempt")"
[[ "$line" = $'1\t'"$attempt"$'\t'"$client_id"*WAIT_NEW_FLOW* ]]
if adaptive_browser_attempt_write ../bad "$client_id" 192.168.1.42 mark:7 example.org - 1 tls main_frame_network_failure WAIT_NEW_FLOW 2 - 1 2 1; then exit 1; fi

bash -n "$ROOT/webui/cgi-bin/adaptive-browser.cgi" "$ROOT/lib/adaptive_browser.sh" "$ROOT/tools/adaptive-browser-pair.sh"
grep -q 'browser_hello' "$ROOT/webui/cgi-bin/adaptive-browser.cgi"
grep -q 'browser_cancel_attempt' "$ROOT/webui/cgi-bin/adaptive-browser.cgi"
! grep -q 'TOKEN_FILE=.*adaptive/token$' "$ROOT/webui/cgi-bin/adaptive-browser.cgi"
echo 'adaptive browser API smoke: OK'
