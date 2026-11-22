#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ZATOR_ROOT="$tmp/zator"
export Z2R_ADAPTIVE_DIR="$tmp/state"
source "$ROOT/lib/adaptive_browser.sh"

now="$(date +%s)"
host=rr1---sn-a5mekn6e.googlevideo.com
ip=142.250.72.3
scope=default
client=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
strategy=7
fingerprint="sha256:$(printf '%064d' 1)"
ids=(11111111111111111111111111111111 22222222222222222222222222222222 33333333333333333333333333333333 44444444444444444444444444444444)
for i in 0 1 2 3; do
  treatment=bypassed; ack=unknown
  if (( i == 0 || i == 3 )); then treatment=applied; ack=confirmed; fi
  adaptive_browser_media_quality_write "${ids[i]}" 1 "$client" "$scope" "$host" "$ip" \
    2 googlevideo-tcp "$strategy" "$fingerprint" "$treatment" "$ack" healthy \
    8000 6000 0 1 240 "$((now - 3 + i))"
done
id_list="$(IFS=,; printf '%s' "${ids[*]}")"
proof="$(adaptive_browser_ramp_canary_validate "$host" "$ip" "$scope" "$id_list" "$now")"
[[ "$proof" =~ ^[a-f0-9]{64}$ ]] || { echo 'healthy ordered Ramp/Plain/Plain/Ramp evidence was rejected' >&2; exit 1; }

evidence="$(adaptive_browser_state_dir)/media-quality/evidence.tsv"
sed -i $'3s/\\thealthy\\t/\\tdegraded\\t/' "$evidence"
if adaptive_browser_ramp_canary_validate "$host" "$ip" "$scope" "$id_list" "$now" >/dev/null; then
  echo 'degraded plain media was accepted as a Ramp canary' >&2; exit 1
fi
sed -i $'3s/\\tdegraded\\t/\\thealthy\\t/' "$evidence"
sed -i '4s/\t7\t/\t8\t/' "$evidence"
if adaptive_browser_ramp_canary_validate "$host" "$ip" "$scope" "$id_list" "$now" >/dev/null; then
  echo 'strategy mismatch was accepted as one controlled canary' >&2; exit 1
fi
if adaptive_browser_ramp_canary_validate "$host" "$ip" "$scope" "${ids[0]},${ids[1]},${ids[1]},${ids[3]}" "$now" >/dev/null 2>&1; then
  echo 'duplicate observation ID was accepted' >&2; exit 1
fi
echo 'adaptive browser Ramp canary evidence smoke: OK'
