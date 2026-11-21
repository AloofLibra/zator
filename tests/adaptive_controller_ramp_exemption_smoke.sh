#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk '
  /^adaptive_ramp_control_exemptions\(\) \{/ { copying=1; depth=0 }
  copying {
    print
    line=$0
    opens=gsub(/\{/, "{", line)
    closes=gsub(/\}/, "}", line)
    depth += opens - closes
    if (depth == 0) exit
  }
' "$ROOT/tools/adaptive-controller.sh" > "$tmp/helper.sh"
grep -q '^adaptive_ramp_control_exemptions()' "$tmp/helper.sh"

source "$tmp/helper.sh"
BASE="$tmp/base"
run="$tmp/run"
host='rr2-index.googlevideo.com'
dst_ip='188.244.8.77'
scope='default'
treatment='gv_tcp_ramp'
mkdir -p "$BASE" "$run/probe"
now="$(date +%s)"
printf '1\t%s\t%s\t%s\t%s\t%s\n1\tother.googlevideo.com\t188.244.8.78\tdefault\t%s\t%s\n' \
  "$host" "$dst_ip" "$scope" "$((now + 600))" "$(printf target | sha256sum | cut -d' ' -f1)" \
  "$((now + 600))" "$(printf other | sha256sum | cut -d' ' -f1)" > "$BASE/ramp-exempt.tsv"
adaptive_ramp_control_exemptions
[[ -n "${Z2R_ADAPTIVE_RAMP_EXEMPT_FILE:-}" && -r "$Z2R_ADAPTIVE_RAMP_EXEMPT_FILE" ]]
[[ "$(wc -l < "$Z2R_ADAPTIVE_RAMP_EXEMPT_FILE")" -eq 1 ]]
grep -q $'other.googlevideo.com\t188.244.8.78' "$Z2R_ADAPTIVE_RAMP_EXEMPT_FILE"
[[ "$(stat -c '%a' "$Z2R_ADAPTIVE_RAMP_EXEMPT_FILE")" = 644 ]]
grep -Fq "$(printf '1\t%s\t%s\t%s\t' "$host" "$dst_ip" "$scope")" "$BASE/ramp-exempt.tsv"

unset Z2R_ADAPTIVE_RAMP_EXEMPT_FILE
treatment='gv_tcp_plain'
adaptive_ramp_control_exemptions
[[ -z "${Z2R_ADAPTIVE_RAMP_EXEMPT_FILE:-}" ]]
echo 'adaptive Ramp control exemption isolation passed'
