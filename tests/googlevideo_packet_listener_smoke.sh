#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/z2r-packet-smoke.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/run" "$TMP/root/lists" "$TMP/root/z2r_lib" "$TMP/root/tools"
CC=${CC:-cc}
"$CC" -std=c99 -Os -Wall -Wextra -Werror -o "$TMP/sniffer" "$ROOT/tools/googlevideo-dns-sniffer.c"
cat > "$TMP/bin/nft" <<'EOF'
#!/bin/sh
echo "$*" >> "$NFT_CALLS"
ip=$(printf '%s\n' "$*" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
case "$1 $2" in
  'add element') grep -Fxq "$ip" "$NFT_ELEMENTS" && exit 1; echo "$ip" >> "$NFT_ELEMENTS"; exit 0 ;;
  'get element') grep -Fxq "$ip" "$NFT_ELEMENTS" ;;
  'delete element') grep -Fvx "$ip" "$NFT_ELEMENTS" > "$NFT_ELEMENTS.tmp"; mv "$NFT_ELEMENTS.tmp" "$NFT_ELEMENTS" ;;
esac
EOF
chmod +x "$TMP/bin/nft"
printf 'FWTYPE=nftables\nZ2R_WSSIZE_RAMP_ENABLE=1\nNFQWS2_ENABLE=1\n' > "$TMP/config"
: > "$TMP/nft-elements"; : > "$TMP/nft-calls"
export PATH="$TMP/bin:$PATH" NFT_CALLS="$TMP/nft-calls" NFT_ELEMENTS="$TMP/nft-elements"
export Z2R_GV_ROOT="$TMP/root" Z2R_GV_CONFIG="$TMP/config" Z2R_GV_TMPDIR="$TMP/run"
export Z2R_GV_LOCAL_FILE="$TMP/run/local.tsv" Z2R_GOOGLEVIDEO_PENDING_FILE="$TMP/run/pending.tsv"
export Z2R_GV_REPORTED_FILE="$TMP/run/reported.tsv" Z2R_GV_LOG_FILE="$TMP/run/collector.log"
export Z2R_GOOGLEVIDEO_IPS_FILE="$TMP/root/lists/googlevideo-ipv4.txt" Z2R_GV_PIDFILE="$TMP/run/listener.pid"
printf '9.9.9.97\n' > "$Z2R_GOOGLEVIDEO_IPS_FILE"
printf 'rr9---sn-h5gtov-n8vl.googlevideo.com\t9.9.9.97\t300\nrr9---sn-h5gtov-n8vl.googlevideo.com\t9.9.9.97\t300\nrr8---sn-h5gtov-n8vl.googlevideo.com\t9.9.9.97\t300\nrr7---sn-h5gtov-n8vl.googlevideo.com\t9.9.9.96\t300\nnot-googlevideo.example\t9.9.9.98\t300\nrr8.googlevideo.com\t10.0.0.1\t300\n' \
  | "$TMP/sniffer" --ingest-stream
[ "$(wc -l < "$TMP/run/local.tsv")" -eq 3 ]
[ "$(wc -l < "$TMP/run/pending.tsv")" -eq 3 ]
[ "$(wc -l < "$TMP/nft-elements")" -eq 2 ]
grep -Fq '9.9.9.97 timeout 604800s' "$TMP/nft-calls"
grep -Fq '9.9.9.96 timeout 3600s' "$TMP/nft-calls"
# A repeated answer already reported to telemetry still repairs the kernel set.
printf 'rr9---sn-h5gtov-n8vl.googlevideo.com\t9.9.9.97\t%s\n' "$(date +%s)" > "$Z2R_GV_REPORTED_FILE"
printf 'rr9---sn-h5gtov-n8vl.googlevideo.com\t9.9.9.97\t300\n' | "$TMP/sniffer" --ingest-stream
grep -Fq 'delete element inet zapret2 z2r_googlevideo4 { 9.9.9.97 }' "$NFT_CALLS"
grep -Fq '9.9.9.97 timeout 604800s' "$NFT_CALLS"
echo 'googlevideo C collector packet/observation path smoke ok'
