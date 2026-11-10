#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/z2r-googlevideo.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export ZATOR_ROOT="$TMP/zator"
export GOOGLEVIDEO_IPS_FILE="$TMP/zator/lists/googlevideo-ipv4.txt"
export Z2R_GOOGLEVIDEO_IPS_CACHE_TTL=0
source "$ROOT/lib/googlevideo_ips.sh"
MOCK_SET="$TMP/kernel-set"
: > "$MOCK_SET"
MOCK_FWTYPE=iptables
MOCK_NFT_SET="$TMP/nft-set"
: > "$MOCK_NFT_SET"
NFT_CREATED=0
NFT_CALLS="$TMP/nft-calls"
: > "$NFT_CALLS"
unset ZAPRET_NFT_TABLE
MOCK_NFT_TABLE=""
MOCK_EXPECT_NFT_TABLE=zapret2
config_get_var() {
  case "$2" in
    FWTYPE) echo "$MOCK_FWTYPE" ;;
    ZAPRET_NFT_TABLE) printf '%s\n' "$MOCK_NFT_TABLE" ;;
  esac
  return 0
}
dnsmasq() { printf 'Dnsmasq version 2.91\nCompile time options: IPv6 DHCP %s\n' "${MOCK_DNSMASQ_FEATURES:-nftset ipset}"; }
uci() { return 1; }
ipset() {
  case "$1" in
    create) return 0 ;;
    restore)
      while IFS= read -r row; do
        case "$row" in add\ z2r_googlevideo4\ *) ip=${row#add z2r_googlevideo4 }; ip=${ip%% *}; grep -Fxq "$ip" "$MOCK_SET" || echo "$ip" >> "$MOCK_SET" ;; esac
      done
      return 0 ;;
    save) awk '{print "add z2r_googlevideo4 " $1 " timeout 600"}' "$MOCK_SET" ;;
  esac
}
nft() {
  printf '%s\n' "$*" >> "$NFT_CALLS"
  if [ "$2" = set ] && { [ "$1" = list ] || [ "$1" = add ]; }; then
    [ "$3" = inet ] && [ "$4" = "$MOCK_EXPECT_NFT_TABLE" ] || {
      echo "unexpected nft table: $*" >&2
      return 2
    }
  fi
  if [ "$1" = list ] && [ "$2" = set ]; then
    [ "$NFT_CREATED" = 1 ] || return 1
    [ ! -s "$MOCK_NFT_SET" ] || { printf 'elements = { '; paste -sd, "$MOCK_NFT_SET"; printf ' }\n'; }
    return 0
  fi
  if [ "$1" = add ] && [ "$2" = set ]; then NFT_CREATED=1; return 0; fi
  if [ "$1" = -f ]; then
    sed -n 's/.*{ \(.*\) }/\1/p' "$2" | tr ',' '\n' | tr -d ' ' >> "$MOCK_NFT_SET"
    sort -u "$MOCK_NFT_SET" -o "$MOCK_NFT_SET"
    return 0
  fi
  return 2
}

curl() {
  local output=""; while [ "$#" -gt 0 ]; do
    case "$1" in -o) output="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "$output" ] || return 2
  cp "$GOOGLEVIDEO_TEST_PAYLOAD" "$output"
}

GOOGLEVIDEO_TEST_PAYLOAD="$TMP/valid.txt"
printf '# googlevideo IPv4; generated=2026-11-10T00:00:00Z; max_age=604800s\n\n8.8.8.8\n' > "$GOOGLEVIDEO_TEST_PAYLOAD"
googlevideo_ips_update
[ "$(googlevideo_ips_count)" = 1 ]
grep -Fxq 8.8.8.8 "$MOCK_SET"

# Central cache updates are merged live and a router batch contains only local
# DNS members, is consent-gated, and is throttled rather than sent per address.
GOOGLEVIDEO_TEST_PAYLOAD="$TMP/invalid.txt"
printf '# googlevideo IPv4; generated=2026-11-10T00:00:00Z; max_age=604800s\n10.0.0.1\n' > "$GOOGLEVIDEO_TEST_PAYLOAD"
if googlevideo_ips_update; then exit 1; fi
grep -Fxq 8.8.8.8 "$GOOGLEVIDEO_IPS_FILE"
GOOGLEVIDEO_TEST_PAYLOAD="$TMP/valid2.txt"
printf '# googlevideo IPv4; generated=2026-11-10T00:00:00Z; max_age=604800s\n8.8.8.9\n' > "$GOOGLEVIDEO_TEST_PAYLOAD"
googlevideo_ips_update
grep -Fxq 8.8.8.8 "$MOCK_SET"
grep -Fxq 8.8.8.9 "$MOCK_SET"

echo 9.9.9.9 >> "$MOCK_SET"
[ "$(googlevideo_local_kernel_ips)" = $'8.8.8.8\n8.8.8.9\n9.9.9.9' ]
UPLOAD_CALLS=0
UPLOAD_DATA=
curl() {
  UPLOAD_CALLS=$((UPLOAD_CALLS + 1))
  while [ "$#" -gt 0 ]; do
    case "$1" in --data-urlencode) case "$2" in ips=*) UPLOAD_DATA=${2#ips=} ;; esac; shift 2 ;; *) shift ;; esac
  done
  return 0
}
tel_enabled=0 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid
[ "$UPLOAD_CALLS" = 0 ]
tel_enabled=1 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid
[ "$UPLOAD_CALLS" = 1 ]
[ "$UPLOAD_DATA" = '8.8.8.8,8.8.8.9,9.9.9.9' ]
tel_enabled=1 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid
[ "$UPLOAD_CALLS" = 1 ]

printf '# googlevideo IPv4; generated=x\n192.168.1.1\n' > "$TMP/private.txt"
if googlevideo_ips_validate "$TMP/private.txt"; then exit 1; fi
printf '# googlevideo IPv4; generated=x\n203.0.113.1\n' > "$TMP/documentation.txt"
if googlevideo_ips_validate "$TMP/documentation.txt"; then exit 1; fi
printf '# googlevideo IPv4; generated=x\n008.008.008.008\n' > "$TMP/noncanonical.txt"
if googlevideo_ips_validate "$TMP/noncanonical.txt"; then exit 1; fi
printf '# googlevideo IPv4; generated=x\n8.8.8.8\nyoutube.com\n' > "$TMP/malformed.txt"
if googlevideo_ips_validate "$TMP/malformed.txt"; then exit 1; fi

MOCK_FWTYPE=nftables
printf '# googlevideo IPv4; generated=test\n8.8.8.8\n' > "$GOOGLEVIDEO_IPS_FILE"
googlevideo_kernel_set_sync
grep -Fq 'add set inet zapret2 z2r_googlevideo4' "$NFT_CALLS"
grep -Fxq 8.8.8.8 "$MOCK_NFT_SET"
printf '# googlevideo IPv4; generated=test\n8.8.4.4\n' > "$GOOGLEVIDEO_IPS_FILE"
googlevideo_kernel_set_sync
grep -Fxq 8.8.8.8 "$MOCK_NFT_SET"
grep -Fxq 8.8.4.4 "$MOCK_NFT_SET"
MOCK_NFT_TABLE=custom_fw
MOCK_EXPECT_NFT_TABLE=custom_fw
googlevideo_kernel_set_sync
grep -Fq 'list set inet custom_fw z2r_googlevideo4' "$NFT_CALLS"
printf 'nftset=/googlevideo.com/4#inet#zapret2#z2r_googlevideo4\n' > "$TMP/dnsmasq.conf"
googlevideo_dnsmasq_has_feature nftset
googlevideo_dnsmasq_rule_present nftables zapret2 "$TMP/dnsmasq.conf"
! googlevideo_dnsmasq_rule_present nftables custom_fw "$TMP/dnsmasq.conf"
MOCK_DNSMASQ_FEATURES='IPv6 no-nftset no-ipset'
! googlevideo_dnsmasq_has_feature nftset
! googlevideo_dnsmasq_has_feature ipset
OSystem=WRT
if googlevideo_openwrt_dnsmasq setup; then
  echo 'setup accepted dnsmasq without nftset support' >&2
  exit 1
fi
printf 'ipset=/googlevideo.com/z2r_googlevideo4\n' > "$TMP/dnsmasq-ipset.conf"
googlevideo_dnsmasq_rule_present iptables ignored "$TMP/dnsmasq-ipset.conf"
echo 'googlevideo IP cache and batch smoke ok'
