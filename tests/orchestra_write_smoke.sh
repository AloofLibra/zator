#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export ORCH_DIR="$TMP/state" ORCH_LOCK_FILE="$TMP/state/locked.tsv"
source lib/orchestra_state.sh
mkdir -p "$ORCH_DIR"
# Widen the real awk read/modify/rename window; both calls must survive.
awk() { sleep 0.1; command awk "$@"; }
for ((round=0; round<3; round++)); do
    : > "$ORCH_LOCK_FILE"
    orch_scoped_locked_set default 1 tls 2 & a=$!
    orch_scoped_locked_set default 2 tls 3 & b=$!
    wait "$a"; wait "$b"
    [ "$(orch_locked_state_get 1 tls)" = 2 ]
    [ "$(orch_locked_state_get 2 tls)" = 3 ]
    orch_scoped_locked_clear default 1 tls & a=$!
    orch_scoped_locked_set default 3 tls 4 & b=$!
    wait "$a"; wait "$b"
    [ "$(orch_locked_state_get 1 tls)" = auto ]
    [ "$(orch_locked_state_get 3 tls)" = 4 ]
done
# Failed writers release the lock; auto->clear must not deadlock recursively.
! orch_scoped_locked_set bad 1 tls 2 2>/dev/null
orch_scoped_locked_set default 2 tls auto
[ ! -d "${ORCH_LOCK_FILE}.write-lock" ]
echo 'orchestra write smoke ok'
