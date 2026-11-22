#!/usr/bin/env bash
# Mock-only: no root, packet routing, or real firewall changes.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zator-adaptive-transport.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
. "$REPO_DIR/lib/supersweep_transport.sh"
. "$REPO_DIR/lib/adaptive_lan_transport.sh"
Z2R_SUPERSWEEP_DIR="$TMP_DIR/sweep"
Z2R_ADAPTIVE_QUEUE_FILE="$TMP_DIR/queues"
Z2R_ADAPTIVE_PROC_ROOT="$TMP_DIR/proc"
Z2R_ADAPTIVE_BOOT_ID_FILE="$TMP_DIR/boot_id"
Z2R_ADAPTIVE_NFQWS2_PID=2000000000
FWTYPE=iptables
DESYNC_MARK=0x40000000
IPT_MAIN_CHAIN=0
IPT_POST_CHAIN=0
printf 'boot-test\n' > "$Z2R_ADAPTIVE_BOOT_ID_FILE"
mkdir -p "$Z2R_ADAPTIVE_PROC_ROOT/2000000000"
mkdir -p "$Z2R_SUPERSWEEP_DIR/probe"
touch "$Z2R_SUPERSWEEP_DIR/probe/locked.lua"
printf '%s\0%s\0%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=65535' '--uid=65533:65533' "--lua-init=@$Z2R_SUPERSWEEP_DIR/probe/locked.lua" > "$Z2R_ADAPTIVE_PROC_ROOT/2000000000/cmdline"
printf '65535 2000000000 0 2 0 0 0 0 1\n' > "$Z2R_ADAPTIVE_QUEUE_FILE"
adaptive_lan_lease_write "$TMP_DIR/leases" probe1 192.168.1.20 62000 142.250.72.14 2000000000 1999999999 tls-http1-v1
calls="$TMP_DIR/iptables.log"
iptables() {
  printf '%s\n' "$*" >> "$calls"
  if [[ "$*" == *'-L Z2R_ADAPTIVE_LAN -n -v -x'* ]]; then
    printf '%s\n' 'pkts bytes target prot opt in out source destination' \
      '3 1000 NFQUEUE tcp -- * * 192.168.1.20 142.250.72.14 NFQUEUE num 65535' \
      '2 500 NFQUEUE tcp -- * * 192.168.1.20 142.250.72.14 NFQUEUE num 65535'
    return 0
  fi
  case "$*" in
    *' -N Z2R_ADAPTIVE_LAN_POST'*) IPT_POST_CHAIN=1 ;;
    *' -N Z2R_ADAPTIVE_LAN'*) IPT_MAIN_CHAIN=1 ;;
    *' -X Z2R_ADAPTIVE_LAN_POST'*) IPT_POST_CHAIN=0 ;;
    *' -X Z2R_ADAPTIVE_LAN'*) IPT_MAIN_CHAIN=0 ;;
  esac
  if [[ "${FOREIGN_QUEUE_RULE:-0}" == 1 && "$*" == *' -S'* && "$*" != *'-S Z2R_ADAPTIVE_LAN'* ]]; then
    printf '%s\n' '-A POSTROUTING -j NFQUEUE --queue-num 65535'
    return 0
  fi
  if [[ "${STALE_RULES:-0}" == 1 && "$*" == *' -S'* ]]; then
    printf '%s\n' '-A FORWARD -m comment --comment z2r-adaptive-lan -j Z2R_ADAPTIVE_LAN'
    return 0
  fi
  if [[ "$*" == *'-S Z2R_ADAPTIVE_LAN_POST' ]]; then [[ "$IPT_POST_CHAIN" == 1 || "${EXISTING_POST_CHAIN:-0}" == 1 ]]; return; fi
  if [[ "$*" == *'-S Z2R_ADAPTIVE_LAN' ]]; then [[ "$IPT_MAIN_CHAIN" == 1 || "${EXISTING_CHAIN:-0}" == 1 ]]; return; fi
  return 0
}
adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999
[[ "$(adaptive_lan_transport_queue_bytes)" = 1500 ]] || { echo 'isolated queue byte counters were not summed' >&2; exit 1; }
grep -q -- '-I FORWARD 1 -m conntrack --ctdir REPLY .*z2r-adaptive-lan-reply -j Z2R_ADAPTIVE_LAN' "$calls" || { echo 'reply hook is not before the production queue' >&2; exit 1; }
grep -q -- '-A FORWARD -m conntrack --ctdir ORIGINAL .*z2r-adaptive-lan-original -j Z2R_ADAPTIVE_LAN' "$calls" || { echo 'original hook is not after existing mangle processing' >&2; exit 1; }
grep -q -- '-I POSTROUTING 1 .*Z2R_ADAPTIVE_LAN_POST' "$calls" || { echo 'exact-tuple production-queue bypass hook not installed first' >&2; exit 1; }
grep -q -- '--ctorigsrc 192.168.1.20 --ctorigsrcport 62000 --ctorigdst 142.250.72.14 --ctorigdstport 443' "$calls" || { echo 'outbound lease tuple missing' >&2; exit 1; }
grep -q -- '--ctdir REPLY --ctorigsrc 192.168.1.20 --ctorigsrcport 62000 --ctorigdst 142.250.72.14 --ctorigdstport 443' "$calls" || { echo 'reply lease tuple missing' >&2; exit 1; }
grep -q -- '--queue-num 65535' "$calls" || { echo 'test NFQUEUE not selected' >&2; exit 1; }
[[ "$(grep -c -- '--set-xmark 0x10000000/0x10000000' "$calls")" == 2 ]] || { echo 'probe packets do not use the dynamically selected isolation mark' >&2; exit 1; }
[[ "$(grep -c -- '-m mark ! --mark 0x40000000/0x40000000 -m mark ! --mark 0x10000000/0x10000000 -m conntrack --ctdir' "$calls")" == 2 ]] || { echo 'probe mark setter does not preserve production and isolation marks' >&2; exit 1; }
[[ "$(grep -c -- '-m mark --mark 0x10000000/0x10000000 -m conntrack --ctdir' "$calls")" == 5 ]] || { echo 'test-marked packets do not queue once and leave the adaptive chain after reinjection' >&2; exit 1; }
[[ "$(grep -c -- '--set-xmark 0x40000000/0x40000000' "$calls")" == 1 ]] || { echo 'exact postrouting bypass mark missing' >&2; exit 1; }
grep -q -- '-A Z2R_ADAPTIVE_LAN_POST -p tcp -m conntrack --ctdir ORIGINAL --ctorigsrc 192.168.1.20 --ctorigsrcport 62000 --ctorigdst 142.250.72.14 --ctorigdstport 443 -j MARK --set-xmark 0x40000000/0x40000000' "$calls" || { echo 'production bypass mark is not restricted to the leased original tuple' >&2; exit 1; }
awk '/-A Z2R_ADAPTIVE_LAN / {
  target=""
  for (i=1; i<NF; i++) if ($i == "-j") target=$(i+1)
  direction=""
  for (i=1; i<NF; i++) if ($i == "--ctdir") direction=$(i+1)
  if (target == "MARK") mark[direction]=NR
  if (target == "NFQUEUE") queue[direction]=NR
  if (target == "RETURN") ret[direction]=NR
  if (target == "ACCEPT") accept[direction,++accepts[direction]]=NR
} END {
  if (!mark["ORIGINAL"] || !queue["ORIGINAL"] || !ret["ORIGINAL"]) exit 1
  if (!mark["REPLY"] || !queue["REPLY"] || accepts["REPLY"] != 2) exit 1
  if (!(ret["ORIGINAL"] < mark["ORIGINAL"] && mark["ORIGINAL"] < queue["ORIGINAL"])) exit 1
  if (!(accept["REPLY",1] < mark["REPLY"] && mark["REPLY"] < queue["REPLY"] && queue["REPLY"] < accept["REPLY",2])) exit 1
}' "$calls" || { echo 'original/reply NFQUEUE rules do not preserve production traversal' >&2; exit 1; }
adaptive_lan_transport_stop
grep -q -- '-D FORWARD -m conntrack --ctdir REPLY .*z2r-adaptive-lan-reply -j Z2R_ADAPTIVE_LAN' "$calls" || { echo 'reply hook not removed' >&2; exit 1; }
grep -q -- '-D FORWARD -m conntrack --ctdir ORIGINAL .*z2r-adaptive-lan-original -j Z2R_ADAPTIVE_LAN' "$calls" || { echo 'original hook not removed' >&2; exit 1; }
grep -q -- '-D POSTROUTING .*Z2R_ADAPTIVE_LAN_POST' "$calls" || { echo 'postrouting bypass hook not removed' >&2; exit 1; }
grep -q -- '-X Z2R_ADAPTIVE_LAN_POST' "$calls" || { echo 'postrouting bypass chain not removed' >&2; exit 1; }
[[ ! -e "$Z2R_SUPERSWEEP_DIR.lock" ]] || { echo 'probe mutex leaked' >&2; exit 1; }
calls_udp="$TMP_DIR/iptables-udp.log"
calls="$calls_udp"
adaptive_lan_lease_write "$TMP_DIR/leases" probe-udp 192.168.1.20 62001 142.250.72.14 2000000000 1999999999 googlevideo-quic-h3-media-v1
adaptive_lan_transport_start "$TMP_DIR/leases" probe-udp 1999999999
grep -q -- '-A Z2R_ADAPTIVE_LAN -p udp .*--queue-num 65535' "$calls_udp" || { echo 'QUIC lease did not route UDP through isolated queue 65535' >&2; exit 1; }
grep -q -- '-A Z2R_ADAPTIVE_LAN_POST -p udp .*--set-xmark 0x40000000/0x40000000' "$calls_udp" || { echo 'QUIC lease lacks exact UDP production-queue bypass' >&2; exit 1; }
! grep -q -- '-A Z2R_ADAPTIVE_LAN -p tcp ' "$calls_udp" || { echo 'UDP lease also captured TCP' >&2; exit 1; }
adaptive_lan_transport_stop
calls="$TMP_DIR/iptables.log"
Z2R_ADAPTIVE_LOCK_DIR="$TMP_DIR/shared-sweep.lock"
adaptive_lan_probe_lock_acquire
[[ -d "$Z2R_ADAPTIVE_LOCK_DIR" && ! -e "$Z2R_SUPERSWEEP_DIR.lock" ]] || { echo 'adaptive probe did not use the shared lock override' >&2; exit 1; }
adaptive_lan_probe_lock_release
[[ ! -e "$Z2R_ADAPTIVE_LOCK_DIR" ]] || { echo 'shared adaptive lock leaked' >&2; exit 1; }
unset Z2R_ADAPTIVE_LOCK_DIR
printf '%s\0%s\0%s\0%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=65535' '--uid=65533' '65533' "--lua-init=@$Z2R_SUPERSWEEP_DIR/probe/locked.lua" > "$Z2R_ADAPTIVE_PROC_ROOT/2000000000/cmdline"
if ! adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  echo 'transport rejected nfqws2 normalized UID/GID argv' >&2
  exit 1
fi
adaptive_lan_transport_stop
printf '%s\0%s\0%s\0%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=65535' '--uid=65533' '0' "--lua-init=@$Z2R_SUPERSWEEP_DIR/probe/locked.lua" > "$Z2R_ADAPTIVE_PROC_ROOT/2000000000/cmdline"
before="$(grep -Ec ' -[NAI] ' "$calls" || true)"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'transport accepted normalized UID with a non-isolated GID' >&2
  exit 1
fi
[[ "$(grep -Ec ' -[NAI] ' "$calls" || true)" == "$before" ]] || { echo 'firewall touched for non-isolated UID/GID' >&2; exit 1; }
printf '%s\0%s\0%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=65535' '--uid=65533:65533' "--lua-init=@$Z2R_SUPERSWEEP_DIR/probe/locked.lua" > "$Z2R_ADAPTIVE_PROC_ROOT/2000000000/cmdline"
FOREIGN_QUEUE_RULE=1
before="$(grep -Ec ' -[NAI] ' "$calls" || true)"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'transport adopted a queue rule owned by another chain' >&2
  exit 1
fi
[[ "$(grep -Ec ' -[NAI] ' "$calls" || true)" == "$before" ]] || { echo 'firewall changed with a foreign queue rule' >&2; exit 1; }
unset FOREIGN_QUEUE_RULE
Z2R_ADAPTIVE_NFQWS2_PID=2000000001
before="$(wc -l < "$calls")"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'transport accepted an unowned NFQUEUE process' >&2
  exit 1
fi
[[ "$(wc -l < "$calls")" == "$before" ]] || { echo 'firewall touched for unowned NFQUEUE' >&2; exit 1; }
Z2R_ADAPTIVE_NFQWS2_PID=2000000000
if adaptive_lan_transport_run "$TMP_DIR/leases" probe1 1999999999 bash -c 'exit 7'; then
  echo 'probe command failure was lost' >&2; exit 1
else
  [[ "$?" = 7 ]] || { echo 'probe command exit status changed' >&2; exit 1; }
fi
[[ ! -e "$Z2R_SUPERSWEEP_DIR.lock" ]] || { echo 'run wrapper leaked probe lock' >&2; exit 1; }
if adaptive_lan_transport_run "$TMP_DIR/leases" probe1 1999999999 bash -c 'kill -TERM "$PPID"; sleep 0.1'; then
  echo 'TERM was not propagated' >&2; exit 1
else
  [[ "$?" = 143 ]] || { echo 'TERM exit status changed' >&2; exit 1; }
fi
[[ ! -e "$Z2R_SUPERSWEEP_DIR.lock" ]] || { echo 'TERM cleanup leaked probe lock' >&2; exit 1; }
printf '%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=655350' > "$Z2R_ADAPTIVE_PROC_ROOT/2000000000/cmdline"
before="$(wc -l < "$calls")"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'queue 655350 accepted as queue 65535' >&2
  exit 1
fi
[[ "$(wc -l < "$calls")" == "$before" ]] || { echo 'firewall touched for wrong queue' >&2; exit 1; }
printf '%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=65535' > "$Z2R_ADAPTIVE_PROC_ROOT/2000000000/cmdline"
before="$(grep -Ec ' -[NAI] ' "$calls" || true)"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'queue owner without private UID/lock args accepted' >&2
  exit 1
fi
[[ "$(grep -Ec ' -[NAI] ' "$calls" || true)" == "$before" ]] || { echo 'firewall touched for non-isolated queue owner' >&2; exit 1; }
printf '%s\0%s\0%s\0%s\0' '/opt/zapret2/nfq2/nfqws2' '--qnum=65535' '--uid=65533:65533' "--lua-init=@$Z2R_SUPERSWEEP_DIR/probe/locked.lua" > "$Z2R_ADAPTIVE_PROC_ROOT/2000000000/cmdline"
unset DESYNC_MARK
before="$(wc -l < "$calls")"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'transport started without configured production mark' >&2
  exit 1
fi
[[ "$(wc -l < "$calls")" == "$before" ]] || { echo 'firewall touched without configured production mark' >&2; exit 1; }
DESYNC_MARK=0x100000000
before="$(wc -l < "$calls")"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'out-of-range production mark accepted' >&2
  exit 1
fi
[[ "$(wc -l < "$calls")" == "$before" ]] || { echo 'firewall touched with out-of-range mark' >&2; exit 1; }
DESYNC_MARK=0x40000000
EXISTING_CHAIN=1
before="$(grep -c -- '-N Z2R_ADAPTIVE_LAN' "$calls" || true)"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then echo 'foreign chain adopted' >&2; exit 1; fi
[[ ! -e "$Z2R_SUPERSWEEP_DIR.lock" ]] || { echo 'lock leaked after foreign-chain rejection' >&2; exit 1; }
[[ "$(grep -c -- '-N Z2R_ADAPTIVE_LAN' "$calls" || true)" == "$before" ]] || { echo 'foreign chain create attempted' >&2; exit 1; }
unset EXISTING_CHAIN
EXISTING_POST_CHAIN=1
before="$(grep -Ec ' -[NAI] ' "$calls" || true)"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then adaptive_lan_transport_stop || true; echo 'foreign postrouting chain adopted' >&2; exit 1; fi
[[ "$(grep -Ec ' -[NAI] ' "$calls" || true)" == "$before" ]] || { echo 'foreign postrouting chain mutated' >&2; exit 1; }
unset EXISTING_POST_CHAIN
mv "$Z2R_ADAPTIVE_QUEUE_FILE" "$Z2R_ADAPTIVE_QUEUE_FILE.off"
before="$(wc -l < "$calls")"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then echo 'probe started without registered queue' >&2; exit 1; fi
[[ "$(wc -l < "$calls")" == "$before" ]] || { echo 'firewall touched without a registered queue' >&2; exit 1; }
mv "$Z2R_ADAPTIVE_QUEUE_FILE.off" "$Z2R_ADAPTIVE_QUEUE_FILE"
mkdir "$Z2R_SUPERSWEEP_DIR.lock"
printf 'adaptive-lan\t2000000000\tboot-test\n' > "$Z2R_SUPERSWEEP_DIR.lock/owner"
STALE_RULES=1
if adaptive_lan_probe_lock_acquire; then echo 'stale lock reclaimed while firewall rules remain' >&2; exit 1; fi
[[ -d "$Z2R_SUPERSWEEP_DIR.lock" ]] || { echo 'stale firewall lock removed' >&2; exit 1; }
FWTYPE=nftables
nft_calls="$TMP_DIR/nft.log"
nft() {
  printf 'CALL %s\n' "$*" >> "$nft_calls"
  case "$*" in
    '-a list ruleset')
      case "${NFT_FOREIGN_QUEUE:-0}" in
        1) printf '%s\n' 'queue flags bypass to 65535' ;;
        range) printf '%s\n' 'queue flags bypass to 65530-65540' ;;
      esac
      return 0 ;;
    '-a list chain inet zapret2 postnat_hook')
      if [[ -e "$TMP_DIR/nft-active" ]]; then printf '%s\n' 'jump z2r_adaptive_lan comment "z2r_adaptive_lan_post" # handle 101'; else printf '%s\n' 'chain postnat_hook {'; fi
      return 0 ;;
    '-a list chain inet zapret2 prenat_hook')
      if [[ -e "$TMP_DIR/nft-active" ]]; then printf '%s\n' 'jump z2r_adaptive_lan comment "z2r_adaptive_lan_pre" # handle 102'; else printf '%s\n' 'chain prenat_hook {'; fi
      return 0 ;;
    '-a list chain inet zapret2 z2r_adaptive_lan')
      [[ -e "$TMP_DIR/nft-active" ]] || return 1
      printf '%s\n' 'table inet zapret2 {' ' chain z2r_adaptive_lan { # handle 200'
      for h in 201 202 203 204 205 206; do printf 'meta l4proto %s comment "z2r_adaptive_lan" # handle %s\n' "${NFT_L4PROTO:-tcp}" "$h"; done
      printf '%s\n' ' }' '}'
      return 0 ;;
    'list chain inet zapret2 postnat_hook'|'list chain inet zapret2 prenat_hook') return 0 ;;
    'list chain inet zapret2 z2r_adaptive_lan')
      [[ "${NFT_EXISTING_CHAIN:-0}" == 1 || -e "$TMP_DIR/nft-active" ]] ;;
    '-f -')
      : > "$TMP_DIR/nft-batch"
      while IFS= read -r line; do
        printf '%s\n' "$line" >> "$TMP_DIR/nft-batch"
        printf 'RULE %s\n' "$line" >> "$nft_calls"
      done
      if grep -q '^add chain ' "$TMP_DIR/nft-batch"; then touch "$TMP_DIR/nft-active"; fi
      if grep -q '^delete chain ' "$TMP_DIR/nft-batch"; then rm -f "$TMP_DIR/nft-active"; fi
      return 0 ;;
    *) return 0 ;;
  esac
}
adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999
grep -q 'add chain inet zapret2 z2r_adaptive_lan' "$nft_calls" || { echo 'nft probe chain not created' >&2; exit 1; }
grep -q 'insert rule inet zapret2 postnat_hook jump z2r_adaptive_lan' "$nft_calls" || { echo 'nft outbound production hook not bypassed' >&2; exit 1; }
grep -q 'insert rule inet zapret2 prenat_hook jump z2r_adaptive_lan' "$nft_calls" || { echo 'nft reply production hook not bypassed' >&2; exit 1; }
grep -q 'queue flags bypass to 65535' "$nft_calls" || { echo 'nft test queue not selected safely' >&2; exit 1; }
grep -q 'meta mark set meta mark | 0x10000000' "$nft_calls" || { echo 'nft probe packets do not use the dynamically selected isolation mark' >&2; exit 1; }
! grep -q 'meta mark set meta mark | 0x40000000' "$nft_calls" || { echo 'nft probe packets reused nfqws2 --fwmark' >&2; exit 1; }
grep -q 'z2r_adaptive_lan meta l4proto tcp ct direction original .* queue flags bypass to 65535' "$nft_calls" || { echo 'nft outbound flow is not queued exactly at the post-NAT hook' >&2; exit 1; }
grep -q 'z2r_adaptive_lan meta l4proto tcp ct direction reply .* queue flags bypass to 65535' "$nft_calls" || { echo 'nft return flow is not queued exactly at the pre-NAT hook' >&2; exit 1; }
[[ "$(grep -c '^RULE add rule inet zapret2 z2r_adaptive_lan .*queue flags bypass to 65535' "$nft_calls")" == 2 ]] || { echo 'nft transport must install exactly two direction-specific queue rules' >&2; exit 1; }
adaptive_lan_transport_stop || { echo 'nft cleanup rejected table-wrapped chain output' >&2; exit 1; }
grep -q 'delete rule inet zapret2 postnat_hook handle 101' "$nft_calls" || { echo 'nft outbound hook not removed' >&2; exit 1; }
grep -q 'delete rule inet zapret2 prenat_hook handle 102' "$nft_calls" || { echo 'nft reply hook not removed' >&2; exit 1; }
[[ ! -e "$Z2R_SUPERSWEEP_DIR.lock" ]] || { echo 'nft cleanup leaked probe lock' >&2; exit 1; }
NFT_L4PROTO=udp
: > "$nft_calls"
adaptive_lan_transport_start "$TMP_DIR/leases" probe-udp 1999999999
grep -q 'meta l4proto udp ct direction original .* queue flags bypass to 65535' "$nft_calls" || { echo 'nft QUIC lease lacks exact outbound UDP queue rule' >&2; exit 1; }
grep -q 'meta l4proto udp ct direction reply .* queue flags bypass to 65535' "$nft_calls" || { echo 'nft QUIC lease lacks exact return UDP queue rule' >&2; exit 1; }
! grep -q 'RULE add rule .*meta l4proto tcp ' "$nft_calls" || { echo 'nft QUIC lease also captured TCP' >&2; exit 1; }
adaptive_lan_transport_stop || { echo 'nft UDP cleanup failed' >&2; exit 1; }
unset NFT_L4PROTO
POSTNAT=0
POSTNAT_ALL=0
adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999
grep -q 'insert rule inet zapret2 postrouting_hook jump z2r_adaptive_lan' "$nft_calls" || { echo 'nft postrouting mode hook missing' >&2; exit 1; }
grep -q 'insert rule inet zapret2 prerouting_hook jump z2r_adaptive_lan' "$nft_calls" || { echo 'nft prerouting mode hook missing' >&2; exit 1; }
adaptive_lan_transport_stop || { echo 'nft cleanup failed in postrouting mode' >&2; exit 1; }
unset POSTNAT POSTNAT_ALL
NFT_FOREIGN_QUEUE=1
before="$(grep -c '^RULE ' "$nft_calls" || true)"
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'nft transport adopted a foreign queue 65535 rule' >&2
  exit 1
fi
[[ "$(grep -c '^RULE ' "$nft_calls" || true)" == "$before" ]] || { echo 'nft mutated with a foreign queue 65535 rule' >&2; exit 1; }
NFT_FOREIGN_QUEUE=range
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'nft transport adopted a foreign queue-balance range containing 65535' >&2
  exit 1
fi
[[ "$(grep -c '^RULE ' "$nft_calls" || true)" == "$before" ]] || { echo 'nft mutated with a foreign queue-balance range' >&2; exit 1; }
unset NFT_FOREIGN_QUEUE
NFT_EXISTING_CHAIN=1
if adaptive_lan_transport_start "$TMP_DIR/leases" probe1 1999999999; then
  adaptive_lan_transport_stop || true
  echo 'nft transport adopted a pre-existing chain' >&2
  exit 1
fi
[[ "$(grep -c '^RULE ' "$nft_calls" || true)" == "$before" ]] || { echo 'nft mutated with a pre-existing chain' >&2; exit 1; }
unset NFT_EXISTING_CHAIN
echo 'adaptive LAN transport smoke ok'
