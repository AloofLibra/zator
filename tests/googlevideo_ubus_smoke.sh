#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/z2r-ubus-smoke.XXXXXX)"
LISTENER_PID=
cleanup() { [ -z "$LISTENER_PID" ] || kill "$LISTENER_PID" 2>/dev/null || true; [ -z "$LISTENER_PID" ] || wait "$LISTENER_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/root/z2r_lib" "$TMP/root/tools" "$TMP/root/lists" "$TMP/bin" "$TMP/run"
"${CC:-cc}" -std=c99 -Os -Wall -Wextra -Werror -o "$TMP/root/tools/googlevideo-dns-sniffer" "$REPO_ROOT/tools/googlevideo-dns-sniffer.c"
printf 'FWTYPE=nftables\nZ2R_WSSIZE_RAMP_ENABLE=1\nNFQWS2_ENABLE=1\n' > "$TMP/config"
: > "$TMP/nft-elements"; : > "$TMP/nft-calls"; echo 0 > "$TMP/subscriptions"
touch "$TMP/openwrt_release"
cat > "$TMP/bin/ubus" <<'EOF'
#!/bin/sh
case "$1" in
  subscribe)
    n=$(cat "$SUBSCRIPTIONS"); n=$((n + 1)); echo "$n" > "$SUBSCRIPTIONS"
    echo '{"dns_result":{"name":"rr9---sn-h5gtov-n8vl.googlevideo.com","type":"A","address":"9.9.9.99","ttl":1200}}'
    [ "$n" -gt 1 ] && sleep 20
    ;;
esac
EOF
cat > "$TMP/bin/nft" <<'EOF'
#!/bin/sh
echo "$*" >> "$NFT_CALLS"
case "$1" in
  add) printf '%s\n' "$*" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' >> "$NFT_ELEMENTS"; exit 0 ;;
  get) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/ubus" "$TMP/bin/nft"
export PATH="$TMP/bin:$PATH" NFT_CALLS="$TMP/nft-calls" NFT_ELEMENTS="$TMP/nft-elements" SUBSCRIPTIONS="$TMP/subscriptions"
export Z2R_GV_ROOT="$TMP/root" Z2R_GV_CONFIG="$TMP/config" Z2R_GV_OPENWRT_RELEASE="$TMP/openwrt_release"
export Z2R_GV_TMPDIR="$TMP/run" Z2R_GV_PIDFILE="$TMP/run/listener.pid" Z2R_GV_SNIFFER="$TMP/root/tools/googlevideo-dns-sniffer"
export Z2R_GV_LOCAL_FILE="$TMP/run/local.tsv" Z2R_GOOGLEVIDEO_PENDING_FILE="$TMP/run/pending.tsv" Z2R_GOOGLEVIDEO_IPS_FILE="$TMP/root/lists/googlevideo-ipv4.txt"
"$TMP/root/tools/googlevideo-dns-sniffer" --collector & LISTENER_PID=$!
"$TMP/root/tools/googlevideo-dns-sniffer" --collector & duplicate_pid=$!
for _ in $(seq 1 100); do [ -f "$TMP/run/local.tsv" ] && [ "$(cat "$TMP/subscriptions")" -ge 2 ] && break; sleep 0.1; done
[ "$(wc -l < "$TMP/run/local.tsv")" -eq 1 ]
[ "$(wc -l < "$TMP/run/pending.tsv")" -eq 1 ]
[ "$(wc -l < "$TMP/nft-elements")" -eq 1 ]
[ "$(cat "$TMP/subscriptions")" -ge 2 ]
sleep 1
first_pid=$(cat "$TMP/run/listener.pid")
if [ "$first_pid" = "$LISTENER_PID" ]; then loser=$duplicate_pid; else loser=$LISTENER_PID; fi
wait "$loser" 2>/dev/null || true
kill -0 "$first_pid"
! grep -Eiq 'add rule|delete rule|nfqws' "$TMP/nft-calls"
grep -Fq '9.9.9.99 timeout 1200s' "$TMP/nft-calls"
[ "$(cat "$TMP/run/listener.pid")" = "$first_pid" ]
kill "$first_pid"; wait "$first_pid" || true
LISTENER_PID=
[ ! -f "$TMP/run/listener.pid" ]
Z2R_GV_SNIFFER="$TMP/root/tools/googlevideo-dns-sniffer" "$REPO_ROOT/tools/googlevideo-dns-listener.sh" start
for _ in $(seq 1 50); do [ -s "$TMP/run/listener.pid" ] && break; sleep 0.1; done
Z2R_GV_SNIFFER="$TMP/root/tools/googlevideo-dns-sniffer" "$REPO_ROOT/tools/googlevideo-dns-listener.sh" status
Z2R_GV_SNIFFER="$TMP/root/tools/googlevideo-dns-sniffer" "$REPO_ROOT/tools/googlevideo-dns-listener.sh" stop
for _ in $(seq 1 30); do [ ! -e "$TMP/run/listener.pid" ] && break; sleep 0.1; done
[ ! -e "$TMP/run/listener.pid" ]
echo 'googlevideo C UBus event, reconnect and dedup smoke ok'
