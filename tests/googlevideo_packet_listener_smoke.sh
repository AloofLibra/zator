#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/z2r-packet-smoke.XXXXXX)"
trap 'kill "${LISTENER_PID:-}" 2>/dev/null || true; wait "${LISTENER_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/z2r_lib" "$TMP/root/tools" "$TMP/bin" "$TMP/run"
cp "$ROOT/lib/googlevideo_ips.sh" "$ROOT/lib/config.sh" "$TMP/root/z2r_lib/"
cat > "$TMP/root/tools/googlevideo-dns-sniffer" <<'EOF'
#!/bin/sh
printf 'rr9---sn-h5gtov-n8vl.googlevideo.com\t9.9.9.97\t300\n'
printf 'rr9---sn-h5gtov-n8vl.googlevideo.com\t9.9.9.97\t300\n'
exec sleep 30
EOF
cat > "$TMP/bin/nft" <<'EOF'
#!/bin/sh
echo "$*" >> "$NFT_CALLS"
case "$1" in
  add) printf '%s\n' "$*" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' >> "$NFT_ELEMENTS" ;;
  list) [ -f "$NFT_ELEMENTS" ] && { printf 'elements = { '; paste -sd, "$NFT_ELEMENTS"; printf ' }\n'; } ;;
esac
EOF
chmod +x "$TMP/root/tools/googlevideo-dns-sniffer" "$TMP/bin/nft"
printf 'FWTYPE=nftables\nZ2R_WSSIZE_RAMP_ENABLE=1\nNFQWS2_ENABLE=1\n' > "$TMP/config"
: > "$TMP/nft-elements"; : > "$TMP/nft-calls"
export PATH="$TMP/bin:$PATH" NFT_CALLS="$TMP/nft-calls" NFT_ELEMENTS="$TMP/nft-elements"
export Z2R_GV_ROOT="$TMP/root" Z2R_GV_CONFIG="$TMP/config" Z2R_GV_OPENWRT_RELEASE="$TMP/no-openwrt"
export Z2R_GV_SNIFFER="$TMP/root/tools/googlevideo-dns-sniffer"
export Z2R_GV_LISTENER="$ROOT/tools/googlevideo-dns-listener.sh"
export Z2R_GV_TMPDIR="$TMP/run" Z2R_GV_PIDFILE="$TMP/run/listener.pid" Z2R_GV_LOG="$TMP/run/listener.log"
export Z2R_GV_LOCAL_FILE="$TMP/run/local.tsv" GOOGLEVIDEO_LOCAL_FILE="$TMP/run/local.tsv"
export GOOGLEVIDEO_IPS_FILE="$TMP/central.txt" GOOGLEVIDEO_KERNEL_FWTYPE=nftables
source "$ROOT/lib/googlevideo_ips.sh"
uname() { echo aarch64; }
[[ "$(googlevideo_openwrt_dnsmasq_state)" = disabled ]]
bash "$ROOT/tools/googlevideo-dns-listener.sh" run & LISTENER_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/run/local.tsv" ] && break; sleep 0.1; done
[[ "$(googlevideo_openwrt_dnsmasq_state)" = enabled ]]
kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=
[ "$(wc -l < "$TMP/run/local.tsv")" -eq 1 ]
[ "$(wc -l < "$TMP/nft-elements")" -eq 1 ]
grep -Fq '9.9.9.97 timeout 300s' "$TMP/nft-calls"
[ ! -f "$TMP/run/listener.pid" ]
[[ "$(googlevideo_openwrt_dnsmasq_state)" = disabled ]]
echo 'googlevideo packet listener and dedup smoke ok'
