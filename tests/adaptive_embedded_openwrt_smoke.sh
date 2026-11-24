#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZAPRET2_ROOT="${ZAPRET2_ROOT:-/opt/zapret2}"
NFQWS2_BIN="${NFQWS2_BIN:-$ZAPRET2_ROOT/nfq2/nfqws2}"
ZAPRET_LUA="${ZAPRET_LUA:-$ZAPRET2_ROOT/lua/zapret-lib.lua.gz}"
[[ -x "$NFQWS2_BIN" && -r "$ZAPRET_LUA" ]] || {
  echo 'Set NFQWS2_BIN and ZAPRET_LUA to the OpenWrt nfqws2 build and its zapret-lib.lua[.gz]' >&2
  exit 2
}
[[ "$(id -u)" = 0 ]] || { echo 'Run this isolated embedded-Lua smoke as root' >&2; exit 2; }

ws_user="$(awk -F= '$1=="WS_USER" {gsub(/["[:space:]]/, "", $2); print $2; exit}' "$ZAPRET2_ROOT/config" 2>/dev/null)"
[[ -n "$ws_user" ]] || ws_user=nobody
uid="$(id -u "$ws_user" 2>/dev/null)"
gid="$(id -g "$ws_user" 2>/dev/null)"
[[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || { echo "Invalid WS_USER: $ws_user" >&2; exit 2; }

tmp="$(mktemp -d /tmp/z2r-adaptive-embedded.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
chmod 755 "$tmp"
data="$tmp/data"
mkdir -p "$data/extra_strats/cache/adaptive"
printf 'AUTO\n' > "$data/extra_strats/cache/adaptive/mode"
printf 's\tmark:2\tstale\n' > "$data/events.tsv"
: > "$data/quic-health.tsv"
chown "$uid:$gid" "$data/events.tsv" "$data/quic-health.tsv"
chmod 600 "$data/events.tsv" "$data/quic-health.tsv"
chmod 644 "$data/extra_strats/cache/adaptive/mode"

env \
  ZATOR_ROOT="$data" \
  Z2R_ADAPTIVE_DIR="$data" \
  Z2R_ADAPTIVE_EVENTS_FILE="$data/events.tsv" \
  Z2R_ADAPTIVE_RULES_FILE="$data/rules.tsv" \
  Z2R_ADAPTIVE_BROWSER_TRIALS_FILE="$data/browser/trials.tsv" \
  Z2R_ADAPTIVE_BROWSER_FLOW_DIR="$data/browser/flows" \
  Z2R_ADAPTIVE_QUIC_HEALTH_FILE="$data/quic-health.tsv" \
  Z2R_ADAPTIVE_RAMP_TARGETS_FILE="$data/ramp-targets.tsv" \
  "$NFQWS2_BIN" --user="$ws_user" --intercept=0 \
    "--lua-init=@$ZAPRET_LUA" \
    "--lua-init=@$ROOT/orchestra/locked.lua" \
    "--lua-init=@$ROOT/tests/adaptive_embedded_openwrt_smoke.lua"
