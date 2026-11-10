#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/z2r-ubus-smoke.XXXXXX)"
trap 'kill "${LISTENER_PID:-}" 2>/dev/null || true; wait "${LISTENER_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/z2r_lib" "$TMP/bin" "$TMP/run"
cp "$REPO_ROOT/lib/googlevideo_ips.sh" "$REPO_ROOT/lib/config.sh" "$TMP/root/z2r_lib/"
printf 'FWTYPE=nftables\nZ2R_WSSIZE_RAMP_ENABLE=1\nNFQWS2_ENABLE=1\n' > "$TMP/config"
: > "$TMP/nft-elements"; : > "$TMP/nft-calls"
echo 0 > "$TMP/subscriptions"
cat > "$TMP/bin/ubus" <<'EOF'
#!/bin/sh
case "$1" in
  list) echo dnsmasq.dns ;;
  subscribe)
    n=$(cat "$SUBSCRIPTIONS"); n=$((n + 1)); echo "$n" > "$SUBSCRIPTIONS"
    echo '{"dns_result":{"name":"rr9---sn-h5gtov-n8vl.googlevideo.com","type":"A","address":"9.9.9.99","ttl":1200}}'
    sleep 0.1
    echo '{"dns_result":{"name":"rr9---sn-h5gtov-n8vl.googlevideo.com","type":"A","address":"9.9.9.99","ttl":1200}}'
    [ "$n" -gt 1 ] && sleep 10
    ;;
esac
EOF
cat > "$TMP/bin/nft" <<'EOF'
#!/bin/sh
echo "$*" >> "$NFT_CALLS"
case "$1" in
  add) printf '%s\n' "$*" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' >> "$NFT_ELEMENTS" ;;
  list) [ -f "$NFT_ELEMENTS" ] && { printf 'elements = { '; paste -sd, "$NFT_ELEMENTS"; printf ' }\n'; } ;;
esac
EOF
chmod +x "$TMP/bin/ubus" "$TMP/bin/nft"
export PATH="$TMP/bin:$PATH" NFT_CALLS="$TMP/nft-calls" NFT_ELEMENTS="$TMP/nft-elements" SUBSCRIPTIONS="$TMP/subscriptions"
export Z2R_GV_ROOT="$TMP/root" Z2R_GV_CONFIG="$TMP/config" Z2R_GV_OPENWRT_RELEASE="$TMP/openwrt_release"
export Z2R_GV_TMPDIR="$TMP/run" Z2R_GV_PIDFILE="$TMP/run/listener.pid"
export Z2R_GV_LOCAL_FILE="$TMP/run/local.tsv" GOOGLEVIDEO_IPS_FILE="$TMP/central.txt"
export ZAPRET2_ROOT="$TMP"; touch "$TMP/openwrt_release"
source "$REPO_ROOT/lib/config.sh"
config_get_var() { [ "$2" = FWTYPE ] && echo nftables || :; }
source "$REPO_ROOT/lib/googlevideo_ips.sh"
source "$REPO_ROOT/tools/googlevideo-dns-listener.sh"
name= type= address= ttl=
googlevideo_dns_event_parse '{"dns_result":{"name":"rr9.sn-h5gtov-n8vl.googlevideo.com","type":"A","address":"9.9.9.99","ttl":1200}}'
[ "$name:$type:$address:$ttl" = 'rr9.sn-h5gtov-n8vl.googlevideo.com:A:9.9.9.99:1200' ]
! googlevideo_dns_event_parse '{"dns_result":{"name":"rr9.googlevideo.com","type":"AAAA","address":"2001:db8::1","ttl":10}}'

bash "$REPO_ROOT/tools/googlevideo-dns-listener.sh" run & LISTENER_PID=$!
for _ in $(seq 1 50); do [ "$(cat "$TMP/subscriptions")" -gt 1 ] && break; sleep 0.1; done
kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=
[ "$(wc -l < "$TMP/run/local.tsv")" -eq 1 ]
[ "$(wc -l < "$TMP/nft-elements")" -eq 1 ]
[ "$(cat "$TMP/subscriptions")" -gt 1 ]
[ ! -f "$TMP/run/listener.pid" ]
! grep -Eiq 'add rule|delete rule|nfqws' "$TMP/nft-calls"
grep -Fq '9.9.9.99 timeout 1200s' "$TMP/nft-calls"
grep -q 'procd_open_instance z2r_googlevideo_dns' "$REPO_ROOT/tools/wssize-ramp-firewall.sh"
echo 'googlevideo UBus event and dedup smoke ok'
