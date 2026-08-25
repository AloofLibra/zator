#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/zator-client-scope-shell.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

export ORCH_DIR="$TMP_DIR/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export CONFIG_FILE="$TMP_DIR/config"
mkdir -p "$ORCH_DIR"
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

printf 'client scope shell smoke ok\n'
