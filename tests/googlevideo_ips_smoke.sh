#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/z2r-googlevideo.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export ZATOR_ROOT="$TMP/zator"
export GOOGLEVIDEO_IPS_FILE="$TMP/zator/lists/googlevideo-ipv4.txt"
export GOOGLEVIDEO_LOCAL_FILE="$TMP/local.tsv"
export GOOGLEVIDEO_PENDING_FILE="$TMP/pending.tsv" Z2R_GV_TMPDIR="$TMP/upload-state" Z2R_GOOGLEVIDEO_UPLOAD_INTERVAL=10800
export GOOGLEVIDEO_REPORTED_FILE="$TMP/reported.tsv"
export GOOGLEVIDEO_LOG_FILE="$TMP/collector.log"
export Z2R_GOOGLEVIDEO_IPS_CACHE_TTL=0
source "$ROOT/lib/googlevideo_ips.sh"
[[ "$(googlevideo_local_last_observation)" = 'нет наблюдений' ]]
obs_now="$(date +%s)"
printf 'old.googlevideo.com\t9.9.9.8\t%s\t%s\nnew.googlevideo.com\t9.9.9.9\t%s\t%s\n' \
  "$((obs_now + 60))" "$((obs_now - 20))" "$((obs_now + 60))" "$((obs_now - 3))" > "$GOOGLEVIDEO_LOCAL_FILE"
[[ "$(googlevideo_local_last_observation)" = "new.googlevideo.com → 9.9.9.9; 3 с назад" ]]
rm -f "$GOOGLEVIDEO_LOCAL_FILE"
MOCK_SET="$TMP/kernel-set"
: > "$MOCK_SET"
MOCK_FWTYPE=iptables
MOCK_NFT_SET="$TMP/nft-set"
: > "$MOCK_NFT_SET"
NFT_CREATED=0
NFT_FAIL=0
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
    test) grep -Fxq "$3" "$MOCK_SET" ;;
    add) grep -Fxq "$3" "$MOCK_SET" || echo "$3" >> "$MOCK_SET" ;;
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
  [ "$NFT_FAIL" = 0 ] || return 1
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

googlevideo_observe_local rr1---sn-h5gtov-n8vl.googlevideo.com 9.9.9.9 1200 A
googlevideo_observe_local rr1---sn-h5gtov-n8vl.googlevideo.com 9.9.9.9 1200 A
googlevideo_observe_local rr2---sn-h5gtov-n8vl.googlevideo.com 9.9.9.9 1200 A
googlevideo_observe_local rr3---sn-h5gtov-n8vl.googlevideo.com 8.8.8.9 1200 A
googlevideo_observe_local rr2.googlevideo.com 192.168.1.1 1200 A && exit 1
googlevideo_observe_local youtube.com 9.9.9.8 1200 A && exit 1
grep -Fxq 9.9.9.9 "$MOCK_SET"
[ "$(wc -l < "$MOCK_SET")" -eq 3 ]
[ "$(wc -l < "$GOOGLEVIDEO_LOCAL_FILE")" -eq 3 ]
grep -q 'result=queued' "$GOOGLEVIDEO_LOG_FILE"
grep -q 'result=already_queued' "$GOOGLEVIDEO_LOG_FILE"
[ "$(googlevideo_local_kernel_ips)" = 9.9.9.9 ]
awk -F '\t' -v now="$(date +%s)" 'BEGIN {OFS="\t"} {print $1,$2,now-900}' "$GOOGLEVIDEO_LOCAL_FILE" > "$TMP/expired-local.tsv"
mv "$TMP/expired-local.tsv" "$GOOGLEVIDEO_LOCAL_FILE"
[ -z "$(googlevideo_local_kernel_ips)" ]
grep -q '^9\.9\.9\.9[[:space:]]' "$GOOGLEVIDEO_PENDING_FILE"
UPLOAD_CALLS=0
UPLOAD_DATA=
UPLOAD_RC=0
UPLOAD_CALLS_FILE="$TMP/upload-calls"
UPLOAD_DATA_FILE="$TMP/upload-data"
UPLOAD_OBSERVATIONS_FILE="$TMP/upload-observations"
: > "$UPLOAD_CALLS_FILE"
: > "$UPLOAD_DATA_FILE"
: > "$UPLOAD_OBSERVATIONS_FILE"
upload_calls() { wc -l < "$UPLOAD_CALLS_FILE" | tr -d ' '; }
# Keenetic Entware does not necessarily ship `paste`; uploads must still work.
paste() { echo 'unexpected paste dependency' >&2; return 127; }
curl() {
  UPLOAD_CALLS=$((UPLOAD_CALLS + 1))
  printf 'call\n' >> "$UPLOAD_CALLS_FILE"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --data-urlencode)
        case "$2" in
          ips=*) UPLOAD_DATA=${2#ips=}; printf '%s' "$UPLOAD_DATA" > "$UPLOAD_DATA_FILE" ;;
          observations=*) printf '%s' "${2#observations=}" > "$UPLOAD_OBSERVATIONS_FILE" ;;
        esac
        shift 2 ;;
      -w) echo 200; shift 2 ;;
      *) shift ;;
    esac
  done
  return "$UPLOAD_RC"
}
tel_enabled=0 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid
[ "$(upload_calls)" = 0 ]
tel_enabled=1 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid
[ "$(upload_calls)" = 1 ]
[ -z "$(cat "$UPLOAD_DATA_FILE")" ]
expected_pairs='rr1---sn-h5gtov-n8vl.googlevideo.com=9.9.9.9,rr2---sn-h5gtov-n8vl.googlevideo.com=9.9.9.9,rr3---sn-h5gtov-n8vl.googlevideo.com=8.8.8.9'
[ "$(cat "$UPLOAD_OBSERVATIONS_FILE")" = "$expected_pairs" ]
grep -q 'upload result=accepted http=200' "$GOOGLEVIDEO_LOG_FILE"
grep -q '^rr1---sn-h5gtov-n8vl.googlevideo.com[[:space:]]9\.9\.9\.9[[:space:]]' "$GOOGLEVIDEO_REPORTED_FILE"
googlevideo_observe_local rr1---sn-h5gtov-n8vl.googlevideo.com 9.9.9.9 1200 A
! [ -s "$GOOGLEVIDEO_PENDING_FILE" ] || ! grep -q '^9\.9\.9\.9[[:space:]].*rr1---sn-h5gtov-n8vl.googlevideo.com$' "$GOOGLEVIDEO_PENDING_FILE"
! [ -s "$GOOGLEVIDEO_PENDING_FILE" ]
tel_enabled=1 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid
[ "$(upload_calls)" = 1 ]

# Pending observations outlive DNS TTL, are throttled to three hours, and retry
# from tmpfs after a failed batch without losing the queued addresses.
now="$(date +%s)"
printf '1.1.1.1\t%s\n8.8.8.9\t%s\n' "$((now - 900))" "$((now - 900))" > "$GOOGLEVIDEO_PENDING_FILE"
printf '%s\n' "$((now - 10799))" > "$TMP/upload-state/googlevideo-upload.ts"
tel_enabled=1 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid
[ "$(upload_calls)" = 1 ]
printf '%s\n' "$((now - 10800))" > "$TMP/upload-state/googlevideo-upload.ts"
UPLOAD_RC=22
if tel_enabled=1 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid; then exit 1; fi
retry_files=( "$TMP"/pending.retry.* )
[ -s "${retry_files[0]}" ]
UPLOAD_RC=0
tel_enabled=1 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid
[ "$(upload_calls)" = 3 ]
[ "$(cat "$UPLOAD_DATA_FILE")" = '1.1.1.1' ]
if googlevideo_local_spool_has_pending; then exit 1; fi

# Manual force upload bypasses only the three-hour timer; consent and central
# feed deduplication still apply.
now="$(date +%s)"
printf '2.2.2.2\t%s\n8.8.8.9\t%s\n' "$now" "$now" > "$GOOGLEVIDEO_PENDING_FILE"
printf '%s\n' "$now" > "$TMP/upload-state/googlevideo-upload.ts"
tel_enabled=0 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid force
[ "$(upload_calls)" = 3 ] && [ "$GOOGLEVIDEO_UPLOAD_LAST_STATUS" = consent_or_token_missing ]
tel_enabled=1 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid
[ "$(upload_calls)" = 3 ] && [ "$GOOGLEVIDEO_UPLOAD_LAST_STATUS" = throttled ]
tel_enabled=1 STATS_TOKEN=testtoken googlevideo_upload_local_batch testuuid force
[ "$(upload_calls)" = 4 ] && [ "$(cat "$UPLOAD_DATA_FILE")" = '2.2.2.2' ]
[ "$GOOGLEVIDEO_UPLOAD_LAST_COUNT" = 1 ] && [ "$GOOGLEVIDEO_UPLOAD_LAST_STATUS" = uploaded ]
if googlevideo_local_spool_has_pending; then exit 1; fi

# The manual path reconciles local.tsv into the queue without refreshing DNS
# observation timestamps, including rows written by older three-column builds.
saved_local_file="$GOOGLEVIDEO_LOCAL_FILE"
saved_pending_file="$GOOGLEVIDEO_PENDING_FILE"
GOOGLEVIDEO_LOCAL_FILE="$TMP/reconcile-local.tsv"
GOOGLEVIDEO_PENDING_FILE="$TMP/reconcile-pending.tsv"
now="$(date +%s)"
printf 'rr.googlevideo.com\t8.8.8.9\t%s\t%s\nrr.googlevideo.com\t3.3.3.3\t%s\t%s\nrr.googlevideo.com\t4.4.4.4\t%s\nrr.googlevideo.com\t5.5.5.5\t%s\n' \
  "$((now + 300))" "$((now - 60))" "$((now + 300))" "$((now - 1000))" "$((now + 1000))" "$((now - 1000))" "$((now - 1000))" > "$GOOGLEVIDEO_LOCAL_FILE"
googlevideo_queue_local_observations
[ "$GOOGLEVIDEO_QUEUED_LOCAL_COUNT" = 3 ]
awk -F '\t' -v ts="$((now - 1000))" '$1=="3.3.3.3" && $2==ts {ok=1} END {exit !ok}' "$GOOGLEVIDEO_PENDING_FILE"
awk -F '\t' -v ts="$((now - 603800))" '$1=="4.4.4.4" && $2==ts {ok=1} END {exit !ok}' "$GOOGLEVIDEO_PENDING_FILE"
grep -q '^8\.8\.8\.9[[:space:]].*rr.googlevideo.com$' "$GOOGLEVIDEO_PENDING_FILE"
! grep -q '^5\.5\.5\.5[[:space:]]' "$GOOGLEVIDEO_PENDING_FILE"
googlevideo_queue_local_observations
[ "$(wc -l < "$GOOGLEVIDEO_PENDING_FILE")" -eq 3 ]
GOOGLEVIDEO_LOCAL_FILE="$saved_local_file"
GOOGLEVIDEO_PENDING_FILE="$saved_pending_file"

# Keep the DNS observation visible even if the router temporarily rejects the
# kernel-set update; the next DNS answer can retry that update.
NFT_FAIL=1 GOOGLEVIDEO_KERNEL_FWTYPE=nftables googlevideo_observe_local rr4---sn-h5gtov-n8vl.googlevideo.com 9.9.9.10 300 A && exit 1
grep -Fq 'rr4---sn-h5gtov-n8vl.googlevideo.com' "$GOOGLEVIDEO_LOCAL_FILE"
grep -q '^9\.9\.9\.10[[:space:]]' "$GOOGLEVIDEO_PENDING_FILE"
NFT_FAIL=0

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
