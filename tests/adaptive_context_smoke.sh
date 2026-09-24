#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/ip" <<'MOCK_IP'
#!/bin/sh
case "$*" in
  "-4 route show default") printf 'default via %s dev eth0\n' "${TEST_GATEWAY:-192.0.2.1}" ;;
  "-6 route show default") : ;;
  "-o addr show dev eth0 scope global") printf '2: eth0 inet 192.0.2.10/24 scope global eth0\n' ;;
  *) : ;;
esac
MOCK_IP
cat > "$TMP/bin/pidof" <<'MOCK_PIDOF'
#!/bin/sh
[ "$1" = nfqws2 ]
MOCK_PIDOF
chmod +x "$TMP/bin/ip" "$TMP/bin/pidof"

PATH="$TMP/bin:/usr/bin:/bin"
export PATH
export Z2R_ADAPTIVE_STATE_DIR="$TMP/state"
. "$ROOT/lib/adaptive_context.sh"

first="$(adaptive_network_context_snapshot)"
second="$(adaptive_network_context_snapshot)"
epoch_first="$(printf '%s\n' "$first" | awk -F '\t' '{print $4}')"
epoch_second="$(printf '%s\n' "$second" | awk -F '\t' '{print $4}')"
[ "$epoch_first" = 1 ] || { echo "first epoch should be 1, got $epoch_first" >&2; exit 1; }
[ "$epoch_second" = "$epoch_first" ] || { echo "unchanged network advanced epoch" >&2; exit 1; }
[ "$(printf '%s\n' "$first" | awk -F '\t' '{print NF}')" = 13 ] || { echo "bad snapshot field count" >&2; exit 1; }

TEST_GATEWAY=192.0.2.254
export TEST_GATEWAY
third="$(adaptive_network_context_snapshot)"
epoch_third="$(printf '%s\n' "$third" | awk -F '\t' '{print $4}')"
[ "$epoch_third" = 2 ] || { echo "routing change did not advance epoch: $epoch_third" >&2; exit 1; }
printf '%s\n' "adaptive context smoke ok"
