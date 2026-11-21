#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk '
  /^adaptive_controller_no_result_reason\(\) \{/ { copying=1; depth=0 }
  copying {
    print
    line=$0
    opens=gsub(/\{/, "{", line)
    closes=gsub(/\}/, "}", line)
    depth += opens - closes
    if (depth == 0) exit
  }
' "$ROOT/tools/adaptive-controller.sh" > "$tmp/reason.sh"
grep -q '^adaptive_controller_no_result_reason()' "$tmp/reason.sh" || {
  echo 'no-result classifier not found' >&2; exit 1;
}

. "$tmp/reason.sh"
assert_reason() {
  local expected="$1" actual
  shift
  actual="$(adaptive_controller_no_result_reason "$@")"
  [[ "$actual" = "$expected" ]] || {
    printf 'expected %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

assert_reason cancelled 1 0 1 0
assert_reason route_unverified 0 1 1 0
assert_reason probe_error 0 0 0 0
assert_reason expired 0 0 1 1
assert_reason transport_timeout 0 0 1 0
if adaptive_controller_no_result_reason 0 0 maybe 0 >/dev/null 2>&1; then
  echo 'invalid classifier input was accepted' >&2; exit 1
fi
awk '
  /^adaptive_controller_save_status\(\) \{/ { copying=1; depth=0 }
  copying {
    print
    line=$0
    opens=gsub(/\{/, "{", line)
    closes=gsub(/\}/, "}", line)
    depth += opens - closes
    if (depth == 0) exit
  }
' "$ROOT/tools/adaptive-controller.sh" > "$tmp/status.sh"
grep -q '^adaptive_controller_save_status()' "$tmp/status.sh" || {
  echo 'status writer not found' >&2; exit 1;
}
. "$tmp/status.sh"
mkdir -p "$tmp/run"
adaptive_controller_save_status "$tmp/run" "$(date +%s)" "$(date +%s)" SUCCESS media_ok \
  googlevideo-tcp-media-v1 standard 2 mark:4 9 true true true 1048576 2000000 524 12 || {
  echo 'valid last-result summary was rejected' >&2; exit 1;
}
IFS=$'\t' read -r -a status_fields < "$tmp/run/status.tsv"
[[ ${#status_fields[@]} = 17 && "${status_fields[3]}" = SUCCESS && "${status_fields[4]}" = media_ok &&
   "${status_fields[14]}" = 2000000 && "$(stat -c '%a' "$tmp/run/status.tsv")" = 600 ]] || {
  echo 'last-result summary fields or privacy mode are incorrect' >&2; exit 1;
}
if adaptive_controller_save_status "$tmp/run" "$(date +%s)" "$(date +%s)" SUCCESS media_ok \
  googlevideo-tcp-media-v1 standard 2 mark:65536 9 true true true 1048576 2000000 524 12 >/dev/null 2>&1; then
  echo 'status writer accepted an out-of-range client mark' >&2; exit 1;
fi
echo 'adaptive controller no-result classification passed'
