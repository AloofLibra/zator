#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/zator-client-scope-menu.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

export ZATOR_ROOT="$TMP_DIR/zator"
export ZAPRET2_ROOT="$TMP_DIR/zapret2"
export CLIENT_SCOPE_MAP_FILE="$ZATOR_ROOT/extra_strats/cache/client_scope.tsv"
export ORCH_DIR="$ZATOR_ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
mkdir -p "$ZATOR_ROOT/extra_strats/cache" "$ZAPRET2_ROOT"
printf '%s\n' \
  'CLIENT_SCOPE_ENABLE=0' \
  'CLIENT_SCOPE_MARK_MASK=' \
  'CLIENT_SCOPE_MARK_SHIFT=0' \
  'CLIENT_SCOPE_MARK_MAX=255' > "$ZAPRET2_ROOT/config"

plain=''
red=''
yellow=''
green=''
cyan=''
Fcyan=''
Fyellow=''
pause_enter() { :; }
clear() { :; }
ui_invalid_input() { :; }
FIREWALL_EVENTS="$TMP_DIR/firewall.events"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/ui.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/submenus.sh"

client_scope_firewall_action() { printf '%s\n' "$1" >> "$FIREWALL_EVENTS"; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

client_scope_ip_add 192.0.2.10 mark:101 || fail 'mapping set'
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 0 ] || fail 'adding mapping enabled Beta unexpectedly'
[ ! -s "$FIREWALL_EVENTS" ] || fail 'adding mapping applied firewall while disabled'

toggle_client_scope_mode || fail 'enable toggle failed'
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 1 ] || fail 'enable toggle did not persist'
grep -q '^CLIENT_SCOPE_ENABLE=1$' "$ZATOR_ROOT/lua/client-scope-config.lua" || fail 'Lua config was not synced'
grep -qx apply "$FIREWALL_EVENTS" || fail 'enable toggle did not apply firewall'

toggle_client_scope_mode || fail 'disable toggle failed'
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 0 ] || fail 'disable toggle did not persist'
grep -q '^CLIENT_SCOPE_ENABLE=0$' "$ZATOR_ROOT/lua/client-scope-config.lua" || fail 'Lua config disable was not synced'
grep -qx cleanup "$FIREWALL_EVENTS" || fail 'disable toggle did not cleanup firewall'

client_scope_ip_remove 192.0.2.10 || fail 'mapping clear'
[ ! -s "$FIREWALL_EVENTS" ] || [ "$(tail -n1 "$FIREWALL_EVENTS")" = cleanup ] || fail 'mapping clear changed disabled firewall incorrectly'

printf 'client scope menu smoke ok\n'
