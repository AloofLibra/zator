#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MOCK="$TMP/bin"
mkdir -p "$MOCK"
STATE="$TMP/iptables.state"
cat > "$MOCK/iptables" <<'MOCK'
#!/usr/bin/env bash
state=${IPTABLES_STATE:?}
[ "$1" = -t ] && shift 2
args="$*"
case "$1" in
  -N) grep -Fxq "chain:$2" "$state" 2>/dev/null || printf 'chain:%s\n' "$2" >> "$state" ;;
  -C) grep -Fxq "rule:-A ${args#-C }" "$state" ;;
  -A) printf 'rule:-A %s\n' "${args#-A }" >> "$state" ;;
  -D) line="rule:-A ${args#-D }"; tmp="${state}.tmp"; awk -v x="$line" '$0 != x { print }' "$state" > "$tmp"; mv "$tmp" "$state" ;;
  -S) chain=${2:-}; sed -n "s/^rule:-A ${chain} /-A ${chain} /p" "$state" | sed 's/--comment zator-client-scope/--comment "zator-client-scope"/g' ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$MOCK/iptables"
export PATH="$MOCK:$PATH" IPTABLES_STATE="$STATE" CLIENT_SCOPE_ENABLE=1
export CLIENT_SCOPE_MAP_FILE="$TMP/clients.tsv" CLIENT_SCOPE_CHAIN=ZATOR_CLIENT_SCOPE
cat > "$CLIENT_SCOPE_MAP_FILE" <<'MAP'
mark:1	192.0.2.10
mark:2	198.51.100.20
MAP
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[ -f "$ROOT/firewall/client-scope-iptables.sh" ] || fail 'firewall integration script missing'
# shellcheck source=/dev/null
source "$ROOT/firewall/client-scope-iptables.sh"
apply
count=$(grep -c '^rule:' "$STATE" || true)
[ "$count" -eq 3 ] || fail "expected jump plus 2 client rules, got $count"
apply
count2=$(grep -c '^rule:' "$STATE" || true)
[ "$count2" -eq "$count" ] || fail 'apply/apply duplicated rules'
grep -q '192.0.2.10' "$STATE" || fail 'first client missing'
grep -q '198.51.100.20' "$STATE" || fail 'second client missing'
# Foreign chain/rule must survive cleanup.
printf 'chain:FOREIGN\nrule:FOREIGN -s 203.0.113.5 -j ACCEPT\n' >> "$STATE"
cleanup
! grep -q '^rule:.*ZATOR_CLIENT_SCOPE' "$STATE" || fail 'owned rules remain after cleanup'
grep -q 'FOREIGN' "$STATE" || fail 'foreign rules were removed'
CLIENT_SCOPE_ENABLE=0 apply
[ "$(grep -c '^rule:' "$STATE" || true)" -eq 1 ] || fail 'disabled mode changed firewall'
PATH="$TMP/empty" apply || fail 'missing iptables was not a safe no-op'

# Lifecycle integration: remove_zapret must honor the active config even when
# CLIENT_SCOPE_ENABLE is not exported by the caller.
CONFIG_ROOT="$TMP/config-root"
mkdir -p "$CONFIG_ROOT"
printf 'CLIENT_SCOPE_ENABLE=1\n' > "$CONFIG_ROOT/config"
unset CLIENT_SCOPE_ENABLE
eval "$(sed -n '/^client_scope_enabled_from_active_config() {/,/^}/p' "$ROOT/z2r.sh")"
ZAPRET2_ROOT="$CONFIG_ROOT"
client_scope_enabled_from_active_config || fail 'active config enable was not detected'
printf 'CLIENT_SCOPE_ENABLE=0\n' > "$CONFIG_ROOT/config"
if client_scope_enabled_from_active_config; then
  fail 'disabled active config was treated as enabled'
fi
REMOVE_BLOCK=$(sed -n '/^remove_zapret() {/,/^}/p' "$ROOT/z2r.sh")
printf '%s\n' "$REMOVE_BLOCK" | grep -q 'client_scope_enabled_from_active_config' \
  || fail 'remove_zapret does not use active config gate'
printf 'client scope firewall smoke ok\n'
