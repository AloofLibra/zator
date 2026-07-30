#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local pattern="$2"
  local message="$3"

  printf '%s\n' "$text" | grep -Eq -- "$pattern" || fail "$message"
}

assert_not_contains() {
  local text="$1"
  local pattern="$2"
  local message="$3"

  ! printf '%s\n' "$text" | grep -Eq -- "$pattern" || fail "$message"
}

file_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    cksum "$1" | awk '{print $1 ":" $2}'
  fi
}

TMP_DIR="$(mktemp -d /tmp/zator-profile-lock.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT="$TMP_DIR/zapret2"
CFG="$ROOT/config"
export ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export PROFILE_STATE_FILE="$TMP_DIR/profile.lock"
export ZAPRET2_INIT="$ROOT/init.d/sysv/zapret2"

mkdir -p "$ORCH_DIR" "$ROOT/init.d/sysv"
sed "s#/opt/zapret2#$ROOT#g" "$REPO_DIR/config.default" > "$CFG"
printf '#!/bin/sh\nexit 0\n' > "$ZAPRET2_INIT"
chmod +x "$ZAPRET2_INIT"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"

for file in \
  "$REPO_DIR/z2r.sh" \
  "$REPO_DIR/lib/config.sh" \
  "$REPO_DIR/lib/orchestra_state.sh" \
  "$REPO_DIR/lib/strategies.sh" \
  "$REPO_DIR/lib/submenus.sh" \
  "$REPO_DIR/lib/actions.sh" \
  "$REPO_DIR/webui/cgi-bin/_lib.sh"; do
  bash -n "$file"
done

grep -q 'locked == 0' "$REPO_DIR/orchestra/locked.lua" || fail "locked.lua does not handle explicit 0 lock"
grep -q 'profile disabled by lock 0' "$REPO_DIR/orchestra/locked.lua" || fail "locked.lua 0 path is not logged"
grep -q 'string.find(host, needle, 1, true)' "$REPO_DIR/orchestra/locked.lua" || fail "substring matching must be literal"
grep -q 'lua_state.substring_hostlists' "$REPO_DIR/orchestra/locked.lua" || fail "substring decision is not cached per connection"
grep -q 'lua_cutoff(ctx)' "$REPO_DIR/orchestra/locked.lua" || fail "non-matching substring traffic is not cut off from Lua"
grep -q '^function fakemultidisorder(ctx, desync)' "$REPO_DIR/orchestra/locked.lua" || fail "fakemultidisorder is not bundled into locked.lua"
grep -q '^function fakemultisplit(ctx, desync)' "$REPO_DIR/orchestra/locked.lua" || fail "fakemultisplit is not bundled into locked.lua"
grep -q 'file_stat = stat(path)' "$REPO_DIR/orchestra/locked.lua" || fail "substring list changes are not checked by the nfqws2 C stat function"
grep -q 'circular_locked:key=3:.*include_substrings=/opt/zapret2/extra_strats/TCP_RKN_domains_by_substring.txt' "$REPO_DIR/config.default" || fail "substring list is not wired into RKN strategies"
[ "$(grep -c 'include_substrings=' "$REPO_DIR/config.default")" -eq 1 ] || fail "substring filtering must have only one RKN routing profile"
[ "$(grep -c 'route_key=3:route_substrings=/opt/zapret2/extra_strats/TCP_RKN_domains_by_substring.txt' "$REPO_DIR/config.default")" -eq 1 ] || fail "fallback does not route substring matches to RKN"
[ -f "$REPO_DIR/extra_strats/TCP/RKN/Domains_By_Substring.txt" ] || fail "substring list source is missing"

[ "$(profile_state_get 3 tls)" = "auto" ] || fail "missing state must be auto"

orch_locked_set 2 tls 5
[ "$(profile_state_get 2 tls)" = "5" ] || fail "effective state must read existing orchestra lock"
[ "$(profile_state_stored_get 2 tls)" = "auto" ] || fail "existing orchestra lock must not create persistent state"
orch_locked_clear 2 tls

profile_state_set 3 tls 0
[ "$(profile_state_stored_get 3 tls)" = "0" ] || fail "RKN 0 was not stored"
[ "$(profile_state_display 3 tls)" = "0" ] || fail "0 must be displayed as 0"
grep -Eq '^3[[:space:]]+tls[[:space:]]+0$' "$PROFILE_STATE_FILE" || fail "RKN 0 row is missing"
profile_apply_all "$CFG"
[ "$(orch_locked_get 3 tls)" = "0" ] || fail "RKN 0 was not rehydrated into orchestra lock"
[ "$(orch_locked_state_get 3 tls)" = "0" ] || fail "explicit 0 lock must be distinguishable from auto"

sum_before="$(file_sha "$CFG")"
profile_apply_all "$CFG"
sum_after="$(file_sha "$CFG")"
[ "$sum_before" = "$sum_after" ] || fail "profile_apply_all is not idempotent"

profile_state_set 4 tls 2
profile_apply_all "$CFG"
[ "$(orch_locked_get 4 tls)" = "2" ] || fail "Discord TCP orchestra lock was not restored"

profile_state_set 6 udp 0
udp_ports_before="$(config_get_var "$CFG" NFQWS2_PORTS_UDP)"
profile_apply_all "$CFG"
[ "$(orch_locked_get 6 udp)" = "0" ] || fail "VOICE 0 was not rehydrated into orchestra lock"
profile_config_voice_ports_changed 6 "$CFG" "$udp_ports_before" || fail "VOICE port removal was not detected"
udp_ports_line="$(config_get_var "$CFG" NFQWS2_PORTS_UDP)"
assert_not_contains "$udp_ports_line" '(^|,)50000-50099(,|$)' "VOICE ports are still in NFQWS2_PORTS_UDP"
profile_state_set 6 udp 2
profile_apply_all "$CFG"
udp_ports_line="$(config_get_var "$CFG" NFQWS2_PORTS_UDP)"
assert_contains "$udp_ports_line" '(^|,)50000-50099(,|$)' "VOICE ports were not restored"
[ "$(orch_locked_get 6 udp)" = "2" ] || fail "VOICE orchestra lock was not restored"
udp_ports_before="$udp_ports_line"
profile_config_apply_state 6 udp 1 "$CFG"
if profile_config_voice_ports_changed 6 "$CFG" "$udp_ports_before"; then
  fail "VOICE strategy change was mistaken for a port change"
fi

profile_state_set 8 tls 0
profile_apply_all "$CFG"
manual_lock="$ORCH_DIR/locked.manual.tsv"
[ -f "$manual_lock" ] || fail "manual fallback lock file was not created"
grep -Eq '^8[[:space:]]+tls[[:space:]]+0$' "$manual_lock" || fail "fallback TLS 0 was not written to locked.manual.tsv"

profile_state_set_and_apply 3 "tls" auto "$CFG"
[ "$(profile_state_stored_get 3 tls)" = "auto" ] || fail "RKN state was not cleared to auto"
[ "$(orch_locked_state_get 3 tls)" = "auto" ] || fail "RKN orchestra lock was not cleared on auto"

orch_locked_set 3 tls 1
prev_lock="$(orch_locked_state_get 3 tls)"
[ "$prev_lock" = "1" ] || fail "test setup failed to set RKN runtime lock"
prev_lock="0"
if [ "$prev_lock" = "0" ]; then
  orch_locked_set 3 tls 0
else
  orch_locked_clear 3 tls
fi
[ "$(orch_locked_state_get 3 tls)" = "0" ] || fail "explicit 0 lock was not restored after cancel"

sed "s#/opt/zapret2#$ROOT#g" "$REPO_DIR/config.default" > "$CFG"
profile_apply_all "$CFG"
[ "$(orch_locked_get 6 udp)" = "2" ] || fail "stored VOICE N was not rehydrated into orchestra lock"
assert_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)50000-50099(,|$)' "stored VOICE N did not restore voice ports on fresh config"
grep -Eq '^8[[:space:]]+tls[[:space:]]+0$' "$manual_lock" || fail "stored fallback TLS 0 was not rehydrated"

printf '5\tudp\t99\n' > "$PROFILE_STATE_FILE"
profile_apply_all "$CFG" >/dev/null
printf '5\tudp\tbad\n' > "$PROFILE_STATE_FILE"
profile_apply_all "$CFG" >/dev/null

saved_orch_lock_file="$ORCH_LOCK_FILE"
broken_lock_parent="$TMP_DIR/locked-parent-is-file"
printf 'not a directory\n' > "$broken_lock_parent"
ORCH_LOCK_FILE="$broken_lock_parent/locked.tsv"
printf '3\ttls\t0\n' > "$PROFILE_STATE_FILE"
if profile_apply_all "$CFG" >/dev/null 2>&1; then
  fail "profile_apply_all masked an orchestra lock write error"
fi
ORCH_LOCK_FILE="$saved_orch_lock_file"

echo "profile_lock smoke ok"
