#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/adaptive"
mkdir -p "$ZATOR_ROOT/extra_strats/cache/adaptive" "$Z2R_ADAPTIVE_DIR"
source "$ROOT/lib/adaptive_queue.sh"
host=cdn.example.org ip=93.184.216.34 now="$(date +%s)"
printf '1\tseen\t%s\t%s\t1\ttls\tdefault\t%s\n' "$host" "$ip" "$now" > "$Z2R_ADAPTIVE_DIR/events.tsv"
if adaptive_queue_request "$host" "$ip" 1 default >/dev/null 2>&1; then echo 'request accepted outside TEST_ONLY' >&2; exit 1; fi
printf 'TEST_ONLY\n' > "$ZATOR_ROOT/extra_strats/cache/adaptive/mode"
request_id="$(adaptive_queue_request "$host" "$ip" 1 default)"
[[ "$request_id" =~ ^[a-f0-9]{32}$ && "$(wc -l < "$Z2R_ADAPTIVE_DIR/requests.tsv")" = 1 ]] || { echo 'request was not queued in bounded file' >&2; exit 1; }
if adaptive_queue_request "$host" "$ip" 1 default >/dev/null 2>&1; then echo 'request cooldown was ignored' >&2; exit 1; fi
adaptive_queue_ack "$request_id"
[[ ! -s "$Z2R_ADAPTIVE_DIR/requests.tsv" ]] || { echo 'acknowledged request remained queued' >&2; exit 1; }
if adaptive_queue_ack "$request_id"; then :; else echo 'duplicate ack should be idempotent' >&2; exit 1; fi
adaptive_queue_event_ack "$host" "$ip" 1 default
[[ -s "$Z2R_ADAPTIVE_DIR/processed.tsv" ]] || { echo 'event cooldown was not persisted' >&2; exit 1; }
adaptive_queue_clear
[[ ! -e "$Z2R_ADAPTIVE_DIR/processed.tsv" ]] || { echo 'clear did not reset event cooldown' >&2; exit 1; }
if adaptive_queue_request "$host" 192.168.1.1 1 default >/dev/null 2>&1; then echo 'private target was accepted' >&2; exit 1; fi
echo 'adaptive queue smoke: ok'
