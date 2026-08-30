#!/bin/sh
set -eu
REPO_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. "$REPO_DIR/lib/config.sh"

old="$TMP/old"; new="$TMP/new"
printf '%s\n' 'DESYNC_MARK=0x40000000' 'DESYNC_MARK_POSTNAT=0x20000000' > "$old"
cp "$old" "$new"
config_client_scope_ensure "$new"
grep -q '^CLIENT_SCOPE_ENABLE=0$' "$new"
grep -q '^CLIENT_SCOPE_MARK_MASK=$' "$new"
grep -q '^CLIENT_SCOPE_MARK_SHIFT=0$' "$new"
grep -q '^CLIENT_SCOPE_MARK_MAX=255$' "$new"

# Empty mask is the documented disabled no-op, not malformed state.
config_set_var "$new" CLIENT_SCOPE_ENABLE 0
config_set_var "$new" CLIENT_SCOPE_MARK_MASK ''
config_client_scope_ensure "$new"
grep -q '^CLIENT_SCOPE_ENABLE=0$' "$new"

cat >> "$old" <<'EOF'
CLIENT_SCOPE_ENABLE=1
CLIENT_SCOPE_MARK_MASK=0x100
CLIENT_SCOPE_MARK_SHIFT=2
CLIENT_SCOPE_MARK_MAX=255
EOF
config_client_scope_apply "$old" "$new"
grep -q '^CLIENT_SCOPE_ENABLE=1$' "$new"
grep -q '^CLIENT_SCOPE_MARK_MASK=0x100$' "$new"

config_set_var "$old" CLIENT_SCOPE_MARK_MASK 0x40000000
config_client_scope_apply "$old" "$new"
grep -q '^CLIENT_SCOPE_ENABLE=0$' "$new"

# Conflicts are checked against the actual DESYNC_* values in the config.
config_set_var "$old" CLIENT_SCOPE_ENABLE 1
config_set_var "$old" CLIENT_SCOPE_MARK_MASK 0x100
config_set_var "$old" DESYNC_MARK 0x100
config_set_var "$new" DESYNC_MARK 0x100
config_client_scope_apply "$old" "$new"
grep -q '^CLIENT_SCOPE_ENABLE=0$' "$new"

export ZATOR_ROOT="$TMP/zator"
mkdir -p "$ZATOR_ROOT/lua"
client_scope_lua_config_sync "$new"
grep -q '^CLIENT_SCOPE_ENABLE=0$' "$ZATOR_ROOT/lua/client-scope-config.lua"
grep -q '^CLIENT_SCOPE_MARK_MASK=256$' "$ZATOR_ROOT/lua/client-scope-config.lua"
grep -q '^DESYNC_MARK=256$' "$ZATOR_ROOT/lua/client-scope-config.lua"
config_set_var "$new" CLIENT_SCOPE_ENABLE 1
config_set_var "$new" CLIENT_SCOPE_MARK_MASK 0xff00
config_set_var "$new" CLIENT_SCOPE_MARK_SHIFT 8
client_scope_lua_config_sync "$new"
grep -q '^CLIENT_SCOPE_ENABLE=1$' "$ZATOR_ROOT/lua/client-scope-config.lua"
grep -q '^CLIENT_SCOPE_MARK_MASK=65280$' "$ZATOR_ROOT/lua/client-scope-config.lua"
printf 'client scope config smoke ok\n'