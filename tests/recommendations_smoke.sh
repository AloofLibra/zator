#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zator-recs.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
source "$REPO_DIR/lib/recommendations.sh"
PROVIDER_CACHE="$TMP_DIR/provider.txt"
RECS_FILE="$TMP_DIR/recommendations.tsv"
printf 'TestNet - Town\n' > "$PROVIDER_CACHE"
: > "$TMP_DIR/calls"
calls() { wc -l < "$TMP_DIR/calls" | tr -d '[:space:]'; }
curl() {
  printf '1\n' >> "$TMP_DIR/calls"
  local out="" prev=""
  for arg in "$@"; do [ "$prev" != -o ] || out="$arg"; prev="$arg"; done
  [ "${CURL_FAIL:-0}" = 0 ] || return 22
  cp "$TMP_DIR/response.tsv" "$out"
}
response() {
  printf 'meta\t1\t%s\t%s\t1700000000\n' "$1" "$2" > "$TMP_DIR/response.tsv"
  for p in 1 2 3 4; do
    printf 'profile\t%s\t%s\t%s\t40\t70\n' "$p" "$2" "$3" >> "$TMP_DIR/response.tsv"
    if [ "$2" -ge 10 ]; then
      printf 'strategy\t%s\t7\t80\t10\tmixed\n' "$p" >> "$TMP_DIR/response.tsv"
      printf 'strategy\t%s\t2\t70\t9\tclassic\n' "$p" >> "$TMP_DIR/response.tsv"
      printf 'strategy\t%s\t9\t60\t8\tclone\n' "$p" >> "$TMP_DIR/response.tsv"
    fi
  done
}
response 'TestNet - Town' 10 1
update_recommendations
[ "$(calls)" = 1 ]
update_recommendations
[ "$(calls)" = 1 ] || { echo 'Daily cache made a second request'; exit 1; }
json="$(recommendations_json)"
[[ "$json" == *'"status":"ready"'* ]] || { echo 'Expected ready recommendations JSON'; exit 1; }
[[ "$json" == *'"strategy":7'* && "$json" == *'"clone_recommended":true'* ]]
hint="$(show_hint TCP)"
[[ "$hint" == *7* && "$hint" == *ClientHello* ]]
mode_override_get() { printf clone; }
[[ "$(show_hint TCP)" != *'Попробуйте включить'* ]]
unset -f mode_override_get
# Cache is tied to the full provider, not an arbitrary substring or old ISP.
printf 'OtherNet - Town\n' > "$PROVIDER_CACHE"
response 'OtherNet - Town' 9 0
update_recommendations
[ "$(calls)" = 2 ]
json="$(recommendations_json)"
[[ "$json" == *'"status":"insufficient"'* && "$json" != *'"strategy":'* ]]
[[ "$(show_hint RKN)" == *'недостаточно'* ]]
# A failed request must preserve old data and throttle retry attempts too.
touch -t 202001010000 "${RECS_FILE}.request"
CURL_FAIL=1
update_recommendations
[ "$(calls)" = 3 ]
update_recommendations
[ "$(calls)" = 3 ]
[[ "$(recommendations_json)" == *'"status":"stale"'* ]]
[ -s "$RECS_FILE" ]
# Malformed/unbounded responses never reach the cache or CGI JSON.
CURL_FAIL=0
response 'OtherNet - Town' 10 0
printf 'strategy\t1\t1\t101\t10\tclassic\n' >> "$TMP_DIR/response.tsv"
touch -t 202001010000 "${RECS_FILE}.request"
update_recommendations
[[ "$(recommendations_json)" == *'"samples":9'* ]]
printf 'NoData\n' > "$PROVIDER_CACHE"
CURL_FAIL=1
[[ "$(recommendations_json)" == *'"status":"unavailable"'* ]]
printf 'Не определён\n' > "$PROVIDER_CACHE"
before="$(calls)"
[[ "$(recommendations_json)" == *'"status":"unknown_provider"'* ]]
[ "$(calls)" = "$before" ]
# Provider names are opaque data even when they contain quotes/backslashes.
printf '%s\n' 'ISP "quoted" \ edge' > "$PROVIDER_CACHE"
response 'ISP "quoted" \ edge' 10 0
CURL_FAIL=0
update_recommendations
[[ "$(recommendations_json)" == *'ISP \"quoted\" \\ edge'* ]]
# Concurrent CLI/CGI readers share a single request and atomic response.
rm -f "${RECS_FILE}.request"
before="$(calls)"
update_recommendations & p1=$!
update_recommendations & p2=$!
wait "$p1" "$p2"
[ "$(calls)" = "$((before + 1))" ]
if command -v busybox >/dev/null 2>&1; then
  busybox sh -c 'awk() { busybox awk "$@"; }; . "$1"; PROVIDER_CACHE="$2"; RECS_FILE="$3"; recommendations_json' \
    sh "$REPO_DIR/lib/recommendations.sh" "$PROVIDER_CACHE" "$RECS_FILE" > "$TMP_DIR/busybox.json"
  grep -q '"status":"ready"' "$TMP_DIR/busybox.json"
fi
# Exercise the exact CGI handler with the shared engine, not a mock response.
eval "$(sed -n '/^send_json()/,/^}/p; /^api_recommendations_get()/,/^}/p' "$REPO_DIR/webui/cgi-bin/_lib.sh")"
api_recommendations_get > "$TMP_DIR/cgi.txt"
grep -q 'Status: 200 OK' "$TMP_DIR/cgi.txt"
grep -q '"strategy":7' "$TMP_DIR/cgi.txt"
grep -q 'api_recommendations_get' "$REPO_DIR/webui/cgi-bin/settings.cgi"
grep -q 'show_hint "\$profile"' "$REPO_DIR/lib/strategies.sh"
bash -n "$REPO_DIR/lib/recommendations.sh" "$REPO_DIR/webui/cgi-bin/_lib.sh"
echo 'recommendations smoke ok'
