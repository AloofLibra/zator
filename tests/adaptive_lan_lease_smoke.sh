#!/usr/bin/env bash
# No root, network, nft or iptables binary required.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zator-adaptive-lease.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
grep -q 'Z2R_LIB_FILES=.*adaptive_lan_transport\.sh' "$REPO_DIR/z2r.sh" || { echo 'adaptive LAN module is not deployed' >&2; exit 1; }
. "$REPO_DIR/lib/adaptive_lan_transport.sh"
valid=(192.168.1.20 62000 142.250.72.14 443 2000000000 1999999999)
adaptive_lan_lease_valid "${valid[@]}" || { echo 'valid lease rejected' >&2; exit 1; }
_adaptive_lan_public_ipv4_valid 142.250.72.14 || { echo 'public IPv4 destination rejected' >&2; exit 1; }
for private_target in 10.0.0.1 127.0.0.1 169.254.1.1 172.16.0.1 192.168.1.1 192.0.2.1 198.51.100.1 203.0.113.1 224.0.0.1; do
  if _adaptive_lan_public_ipv4_valid "$private_target"; then
    printf 'non-public target accepted: %s\n' "$private_target" >&2
    exit 1
  fi
done
for bad in \
  '192.168.1.20 0 142.250.72.14 443 2000000000 1999999999' \
  '192.168.1.20 65536 142.250.72.14 443 2000000000 1999999999' \
  '192.168.001.20 62000 142.250.72.14 443 2000000000 1999999999' \
  '256.168.1.20 62000 142.250.72.14 443 2000000000 1999999999' \
  '192.168.1.20 62000 2001:db8::1 443 2000000000 1999999999' \
  '192.168.1.20 62000 142.250.72.14 80 2000000000 1999999999' \
  '192.168.1.20 62000 142.250.72.14 443 nope 1999999999' \
  '192.168.1.20 62000 142.250.72.14 443 1999999999 1999999999'; do
  # Intentional word splitting passes the six lease fields to the validator.
  if adaptive_lan_lease_valid $bad; then
    printf 'invalid lease accepted: %s\n' "$bad" >&2
    exit 1
  fi
done
for port in 61999 63000; do
  if adaptive_lan_lease_valid 192.168.1.20 "$port" 142.250.72.14 443 2000000000 1999999999; then
    echo "unreserved source port accepted: $port" >&2
    exit 1
  fi
done
if adaptive_lan_lease_write "$TMP_DIR/leases" test-1 192.168.1.20 62000 142.250.72.14 2000000000 1999999999 tls-http1-v1; then
  IFS=$'\t' read -r id src sport dst dport expiry recipe < "$TMP_DIR/leases/test-1.tsv"
  [[ "$id:$src:$sport:$dst:$dport:$expiry:$recipe" == 'test-1:192.168.1.20:62000:142.250.72.14:443:2000000000:tls-http1-v1' ]] || { echo 'lease record mismatch' >&2; exit 1; }
else
  echo 'valid lease write rejected' >&2
  exit 1
fi
if adaptive_lan_lease_write "$TMP_DIR/leases" '../bad' 192.168.1.20 62000 142.250.72.14 2000000000 1999999999 tls-http1-v1; then
  echo 'path-traversal lease id accepted' >&2
  exit 1
fi
readback="$(adaptive_lan_lease_read "$TMP_DIR/leases" test-1 1999999999)" || { echo 'valid lease read rejected' >&2; exit 1; }
[[ "$readback" == 'test-1 192.168.1.20 62000 142.250.72.14 443 2000000000 tls-http1-v1' ]] || { echo 'lease read mismatch' >&2; exit 1; }
if adaptive_lan_lease_read "$TMP_DIR/leases" test-1 2000000000; then
  echo 'expired lease read accepted' >&2
  exit 1
fi
printf 'test-1\t192.168.1.20\t62000\t999.250.72.14\t443\t2000000000\ttls-http1-v1\n' > "$TMP_DIR/leases/test-1.tsv"
if adaptive_lan_lease_read "$TMP_DIR/leases" test-1 1999999999; then
  echo 'tampered lease read accepted' >&2
  exit 1
fi
adaptive_lan_lease_remove "$TMP_DIR/leases" test-1 || { echo 'lease removal failed' >&2; exit 1; }
[[ ! -e "$TMP_DIR/leases/test-1.tsv" ]] || { echo 'lease removal left file' >&2; exit 1; }
Z2R_SUPERSWEEP_DIR="$TMP_DIR/sweep"
adaptive_lan_probe_lock_acquire || { echo 'probe lock acquire failed' >&2; exit 1; }
IFS=$'\t' read -r lock_owner lock_pid lock_boot < "$Z2R_SUPERSWEEP_DIR.lock/owner"
[[ "$lock_owner" == adaptive-lan && "$lock_pid" == "$$" ]] || { echo 'probe lock owner mismatch' >&2; exit 1; }
adaptive_lan_probe_lock_acquire || { echo 'same-owner probe lock reacquire failed' >&2; exit 1; }
adaptive_lan_probe_lock_release || { echo 'probe lock release failed' >&2; exit 1; }
[[ ! -e "$Z2R_SUPERSWEEP_DIR.lock" ]] || { echo 'probe lock leaked' >&2; exit 1; }
printf 'boot-a\n' > "$TMP_DIR/boot_id"
Z2R_ADAPTIVE_BOOT_ID_FILE="$TMP_DIR/boot_id"
mkdir "$Z2R_SUPERSWEEP_DIR.lock"
printf 'adaptive-lan\t2000000000\tboot-a\n' > "$Z2R_SUPERSWEEP_DIR.lock/owner"
iptables() { return 0; }
adaptive_lan_probe_lock_acquire || { echo 'stale adaptive probe lock not recovered' >&2; exit 1; }
adaptive_lan_probe_lock_release || { echo 'recovered probe lock release failed' >&2; exit 1; }
echo 'adaptive LAN lease smoke ok'
