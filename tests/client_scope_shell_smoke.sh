#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/zator-client-scope-shell.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

export ORCH_DIR="$TMP_DIR/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export CONFIG_FILE="$TMP_DIR/config"
export ZATOR_ROOT="$TMP_DIR/zator"
export CLIENT_SCOPE_MAP_FILE="$ZATOR_ROOT/extra_strats/cache/client_scope.tsv"
mkdir -p "$ORCH_DIR" "$(dirname "$CLIENT_SCOPE_MAP_FILE")"
tr -d '\r' < "$REPO_DIR/config.default" > "$CONFIG_FILE"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/strategies.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() { "$@" >/dev/null 2>&1 && fail "expected failure: $*" || :; }

orch_scoped_locked_set default 2 tls 3 || fail "default set"
[ "$(orch_scoped_locked_get default 2 tls)" = 3 ] || fail "default get"
orch_scoped_locked_set mark:101 2 tls 4 || fail "mark set"
[ "$(orch_scoped_locked_get mark:101 2 tls)" = 4 ] || fail "mark get"
[ "$(orch_scoped_locked_get default 2 tls)" = 3 ] || fail "scopes leaked"

orch_scoped_locked_set mark:101 2 tls auto || fail "auto clear"
[ "$(orch_scoped_locked_get mark:101 2 tls)" = 0 ] || fail "auto did not clear"
orch_scoped_locked_set mark:101 2 tls 0 || fail "zero set"
[ "$(orch_scoped_locked_get mark:101 2 tls)" = 0 ] || fail "zero get"
orch_scoped_locked_clear mark:101 2 tls || fail "clear"

expect_fail orch_scope_validate $'mark:1\t'
expect_fail orch_scope_validate 'mark:1
2'
expect_fail orch_scope_validate mark:-1
expect_fail orch_scoped_locked_set mark:1 2 udp 999999
expect_fail orch_scoped_locked_set nope 2 tls 1

# Every persisted row must be tab-separated and writes must be complete.
orch_scoped_locked_set mark:7 2 tls 5
awk -F '\t' '$1 ~ /^mark:/ && NF != 4 { exit 1 }' "$ORCH_LOCK_FILE" || fail "scoped row is not 4-column TSV"

# Every persisted row must be tab-separated and writes must be complete.
client_scope_ip_set 192.0.2.10 mark:101 || fail "IP mapping set"
[ "$(client_scope_ip_get 192.0.2.10)" = "mark:101" ] || fail "IP mapping get"
client_scope_ip_set 192.0.2.10 mark:102 || fail "IP mapping update"
[ "$(client_scope_ip_get 192.0.2.10)" = "mark:102" ] || fail "IP mapping update failed"
client_scope_ip_set 2001:db8::10 mark:103 || fail "IPv6 mapping set"
expect_fail client_scope_ip_set 999.1.1.1 mark:104
expect_fail client_scope_ip_set 192.0.2.11 default
client_scope_ip_clear 192.0.2.10 || fail "IP mapping clear"
[ -z "$(client_scope_ip_get 192.0.2.10)" ] || fail "IP mapping clear failed"

# Legacy custom-domain keys remain valid and their old two-column TLS rows
# are removed by the compatibility clear wrapper.
orch_locked_set example.org tls 7 || fail "custom-domain set"
[ "$(orch_locked_get example.org tls)" = 7 ] || fail "custom-domain get"
expect_fail orch_locked_set example.org http 7
expect_fail orch_locked_set example.org tls 999999
orch_locked_clear example.org http || fail "custom-domain http cleanup"
orch_locked_clear example.org udp || fail "custom-domain udp cleanup"
printf 'example.org\t7\n' >> "$ORCH_LOCK_FILE"
orch_locked_clear example.org tls || fail "custom-domain clear"
if grep -q '^example\.org\t' "$ORCH_LOCK_FILE"; then
  fail "custom-domain rows were not cleared"
fi

printf 'client scope shell smoke ok\n'
