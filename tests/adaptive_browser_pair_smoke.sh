#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export ZATOR_ROOT="$TMP_DIR/zator" ZAPRET2_ROOT="$TMP_DIR/zapret2"
export CLIENT_SCOPE_MAP_FILE="$ZATOR_ROOT/extra_strats/cache/client_scope.tsv"
mkdir -p "$ZATOR_ROOT/z2r_lib" "$ZATOR_ROOT/tools" "$ZATOR_ROOT/extra_strats/cache/adaptive" "$ZAPRET2_ROOT" "$TMP_DIR/bin"
cp "$ROOT/tools/adaptive-browser-pair.sh" "$ZATOR_ROOT/tools/adaptive-browser-pair.sh"
cp "$ROOT/lib/config.sh" "$ROOT/lib/orchestra_state.sh" "$ROOT/lib/adaptive_browser.sh" "$ZATOR_ROOT/z2r_lib/"
printf 'CLIENT_SCOPE_ENABLE=1\nCLIENT_SCOPE_MARK_MAX=65535\n' > "$ZAPRET2_ROOT/config"
printf 'mark:7\t192.168.1.42\nmark:8\t192.168.1.43\n' > "$CLIENT_SCOPE_MAP_FILE"

# The production CLI is root-only. Keep the test isolated and provide only the
# identity query it uses; the rest of the process still runs as the test user.
cat > "$TMP_DIR/bin/id" <<'ID'
#!/bin/sh
if [ "${1:-}" = -u ]; then printf '0\n'; else exec /usr/bin/id "$@"; fi
ID
chmod +x "$TMP_DIR/bin/id"
export PATH="$TMP_DIR/bin:$PATH"

CLI="$ZATOR_ROOT/tools/adaptive-browser-pair.sh"
TOKEN_FILE="$ZATOR_ROOT/extra_strats/cache/adaptive/browser-clients.tsv"

create_output="$(bash "$CLI" create 192.168.1.42 mark:7)"
client_id="$(sed -n 's/^Browser client ID: //p' <<< "$create_output")"
old_token="$(sed -n 's/^Browser token (shown once): //p' <<< "$create_output")"
[[ "$client_id" =~ ^[a-f0-9]{32}$ && "$old_token" =~ ^[a-f0-9]{64}$ ]] || {
  echo 'create did not issue one valid browser client and token' >&2; exit 1;
}
[[ "$(stat -c %a "$TOKEN_FILE")" = 600 ]] || { echo 'browser token hash store is not private' >&2; exit 1; }

. "$ZATOR_ROOT/z2r_lib/config.sh"
. "$ZATOR_ROOT/z2r_lib/adaptive_browser.sh"
origin=chrome-extension://abcdefghijklmnopabcdefghijklmnop
adaptive_browser_context_valid "$client_id" 192.168.1.42 mark:7 || {
  echo 'created browser client scope did not validate' >&2; exit 1;
}
adaptive_browser_client_auth "$old_token" 192.168.1.42 "$origin" || {
  echo 'new browser token did not authenticate' >&2; exit 1;
}

rotate_output="$(bash "$CLI" rotate "$client_id")"
new_token="$(sed -n 's/^Browser token rotated (shown once): //p' <<< "$rotate_output")"
[[ "$new_token" =~ ^[a-f0-9]{64}$ && "$new_token" != "$old_token" ]] || {
  echo 'rotate did not issue a new one-time token' >&2; exit 1;
}
if adaptive_browser_client_auth "$old_token" 192.168.1.42 "$origin"; then
  echo 'rotated browser token remained valid' >&2; exit 1;
fi
adaptive_browser_client_auth "$new_token" 192.168.1.42 "$origin" || {
  echo 'replacement browser token did not authenticate' >&2; exit 1;
}
list_output="$(bash "$CLI" list)"
grep -Fq "$client_id" <<< "$list_output"
grep -Fq '192.168.1.42' <<< "$list_output"
! grep -Fq "$new_token" <<< "$list_output" || { echo 'list leaked the browser token' >&2; exit 1; }

bash "$CLI" revoke "$client_id" >/dev/null
if adaptive_browser_client_auth "$new_token" 192.168.1.42 "$origin"; then
  echo 'revoked browser token remained valid' >&2; exit 1;
fi
grep -Fq 'No browser clients paired.' <(bash "$CLI" list)

create_one="$(bash "$CLI" create 192.168.1.42 mark:7)"
create_two="$(bash "$CLI" create 192.168.1.43 mark:8)"
id_one="$(sed -n 's/^Browser client ID: //p' <<< "$create_one")"
id_two="$(sed -n 's/^Browser client ID: //p' <<< "$create_two")"
[[ "$id_one" =~ ^[a-f0-9]{32}$ && "$id_two" =~ ^[a-f0-9]{32}$ ]]
bash "$CLI" revoke-all >/dev/null
grep -Fq 'No browser clients paired.' <(bash "$CLI" list)

echo 'adaptive browser pairing smoke: ok'
