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
# shellcheck source=/dev/null
source "$REPO_DIR/lib/actions.sh"

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
[ "$(grep -c 'include_substrings=' "$REPO_DIR/config.default")" -eq 2 ] || fail "standard and auto substring profiles are not paired"
grep -q 'circular_quality:key=3:.*include_substrings=/opt/zapret2/extra_strats/TCP_RKN_domains_by_substring.txt' "$REPO_DIR/config.default" || fail "auto substring profile lost include routing"
[ "$(grep -c 'route_key=3:route_substrings=/opt/zapret2/extra_strats/TCP_RKN_domains_by_substring.txt' "$REPO_DIR/config.default")" -eq 2 ] || fail "standard and auto fallback routes are not paired"
grep -q 'circular_quality:key=8:.*route_key=3:route_substrings=/opt/zapret2/extra_strats/TCP_RKN_domains_by_substring.txt' "$REPO_DIR/config.default" || fail "auto fallback lost substring routing"
grep -q 'include_substrings auto counterpart must cut off non-matching host' "$REPO_DIR/tests/provisional_tcp_success.lua" || fail "auto substring routing regression is missing"
grep -q 'allow_nohost route must use route_key' "$REPO_DIR/tests/provisional_tcp_success.lua" || fail "auto fallback routing regression is missing"
[ -f "$REPO_DIR/extra_strats/TCP/RKN/Domains_By_Substring.txt" ] || fail "substring list source is missing"

for runtime_file in \
  lua/strategy-lock-manager.lua \
  lua/combined-detector.lua \
  lua/silent-drop-detector.lua \
  lua/strategy-validator.sh \
  init.d/openwrt/z2r-strategy-validator \
  Entware/z2r-strategy-validator; do
  [ -f "$REPO_DIR/$runtime_file" ] || fail "circular runtime asset is missing: $runtime_file"
done
sh -n "$REPO_DIR/lua/strategy-validator.sh"
sh -n "$REPO_DIR/init.d/openwrt/z2r-strategy-validator"
sh -n "$REPO_DIR/Entware/z2r-strategy-validator"
grep -q '"lua/combined-detector.lua"' "$REPO_DIR/z2r.sh" || fail "combined detector is not deployed"
grep -q '"lua/silent-drop-detector.lua"' "$REPO_DIR/z2r.sh" || fail "silent-drop detector is not deployed"
grep -q '"lua/strategy-lock-manager.lua"' "$REPO_DIR/z2r.sh" || fail "strategy lock manager is not deployed"
grep -q '"lua/strategy-validator.sh"' "$REPO_DIR/z2r.sh" || fail "strategy validator is not deployed"
grep -q '"init.d/openwrt/z2r-strategy-validator"' "$REPO_DIR/z2r.sh" || fail "strategy validator service is not deployed"
grep -q '"Entware/z2r-strategy-validator"' "$REPO_DIR/z2r.sh" || fail "Entware strategy validator service is not deployed"
grep -q 'chmod +x "$STRATEGY_VALIDATOR_WORKER"' "$REPO_DIR/z2r.sh" || fail "strategy validator worker is not executable after deploy"
grep -q 'validator=/opt/zapret2/lua/strategy-validator.sh' "$REPO_DIR/config.default" || fail "auto profile does not reference the deployed validator"
[ "$(grep -c '^--lua-init=@/opt/zapret2/lua/strategy-lock-manager.lua$' "$REPO_DIR/config.default")" -eq 1 ] || fail "strategy lock manager lua-init is missing or duplicated"
[ "$(grep -c '^--lua-init=@/opt/zapret2/lua/combined-detector.lua$' "$REPO_DIR/config.default")" -eq 1 ] || fail "combined detector lua-init is missing or duplicated"
[ "$(grep -c '^--lua-init=@/opt/zapret2/lua/silent-drop-detector.lua$' "$REPO_DIR/config.default")" -eq 1 ] || fail "silent-drop detector lua-init is missing or duplicated"
awk '
  /lua-init=@\/opt\/zapret2\/lua\/strategy-lock-manager\.lua/ {manager=NR}
  /lua-init=@\/opt\/zapret2\/lua\/combined-detector\.lua/ {combined=NR}
  /lua-init=@\/opt\/zapret2\/lua\/silent-drop-detector\.lua/ {silent=NR}
  END {exit !(manager < combined && combined < silent)}
' "$REPO_DIR/config.default" || fail "circular lua-init order is invalid"

auto_pair_block() {
  local cfg="$1" kind="$2" id="$3"
  sed -n "/^#Z2R_AUTO_${kind}${id}_BEGIN$/,/^#Z2R_AUTO_${kind}${id}_END$/p" "$cfg"
}

auto_pair_signature() {
  auto_pair_block "$1" "$2" "$3" | sed -E \
    -e '/^[[:space:]]*#/d' \
    -e 's/^--skip[[:space:]]+//' \
    -e '/--lua-desync=(circular_locked|rst_guard_locked|circular_quality):key=/c\--ENGINE'
}

auto_pair_state() {
  local filter_line
  filter_line="$(auto_pair_block "$1" "$2" "$3" | grep -- '--filter-tcp=' | head -n1)"
  case "$filter_line" in
    --skip\ *) echo skipped ;;
    --*) echo active ;;
    *) echo invalid ;;
  esac
}

auto_assert_no_double_skip() {
  ! grep -Eq '^--skip[[:space:]]+--skip[[:space:]]+--.*--filter-tcp=' "$1" || fail "auto-mode toggle produced duplicate --skip"
}

auto_udp_snapshot() {
  grep -E '^(NFQWS2_PORTS_UDP=|--(skip[[:space:]]+)?--?filter-udp=|--filter-udp=|--lua-desync=.*proto=udp|--payload=(quic_initial|discord_ip_discovery,stun))' "$1"
}

profile_max_snapshot() {
  local profile
  for profile in 1 2 3 4 5 6 7 8 9; do
    printf '%s:%s\n' "$profile" "$(config_profile_max_strategy "$profile" "$1")"
  done
}

AUTO_IDS="1 2 3 4 8 3S 9"
[ "$(grep -Ec '^#Z2R_AUTO_STANDARD_(1|2|3|4|8|3S|9)_BEGIN$' "$CFG")" -eq 7 ] || fail "standard TCP/HTTP auto-pair coverage is incomplete"
[ "$(grep -Ec '^#Z2R_AUTO_(1|2|3|4|8|3S|9)_BEGIN$' "$CFG")" -eq 7 ] || fail "automatic TCP/HTTP pair coverage is incomplete"
for id in $AUTO_IDS; do
  expected_key="$id"
  [ "$id" = "3S" ] && expected_key=3
  [ "$(grep -c "^#Z2R_AUTO_STANDARD_${id}_BEGIN$" "$CFG")" -eq 1 ] || fail "missing standard auto pair $id"
  [ "$(grep -c "^#Z2R_AUTO_${id}_BEGIN$" "$CFG")" -eq 1 ] || fail "missing automatic pair $id"
  assert_contains "$(auto_pair_block "$CFG" STANDARD_ "$id")" "circular_locked:key=${expected_key}([^0-9]|$)" "standard profile $id changed logical key"
  assert_contains "$(auto_pair_block "$CFG" "" "$id")" "circular_quality:key=${expected_key}([^0-9]|$)" "auto profile $id changed logical key"
  [ "$(auto_pair_signature "$CFG" STANDARD_ "$id")" = "$(auto_pair_signature "$CFG" "" "$id")" ] || fail "standard and auto profile $id differ outside the engine"
done

strategy_menu="$(sed -n '/^strategies_submenu()/,/^}/p' "$REPO_DIR/lib/submenus.sh")"
for menu_id in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(printf '%s\n' "$strategy_menu" | grep -Ec "submenu_item \"[[:space:]]*${menu_id}\"[[:space:]]")" -eq 1 ] || fail "strategy menu item $menu_id changed numbering"
done

for mapping in '1 tls http' '2 tls' '3 tls' '4 tls' '5 udp' '6 udp' '7 udp' '8 tls' '9 http'; do
  set -- $mapping
  [ "$(config_profile_proto_list "$1")" = "${mapping#* }" ] || fail "logical profile $1 protocol mapping changed"
done

udp_before="$(auto_udp_snapshot "$CFG")"
profile_max_before="$(profile_max_snapshot "$CFG")"
[ "$(config_mode_text fallback "$CFG")" = "выключен" ] || fail "fallback must be disabled by default"
[ "$(config_mode_text auto_mode "$CFG")" = "выключен" ] || fail "auto mode must be disabled by default"
for id in 1 2 3 4 3S; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = active ] || fail "standard profile $id must be active by default"
  [ "$(auto_pair_state "$CFG" "" "$id")" = skipped ] || fail "auto profile $id must be skipped by default"
done
for id in 8 9; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "standard fallback $id must be skipped by default"
  [ "$(auto_pair_state "$CFG" "" "$id")" = skipped ] || fail "auto fallback $id must be skipped by default"
done
auto_assert_no_double_skip "$CFG"

config_set_auto_mode "$CFG" 1 || fail "auto mode could not be enabled"
[ "$(config_mode_text auto_mode "$CFG")" = "включен" ] || fail "enabled auto mode is not detected"
for id in 1 2 3 4 3S; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "standard profile $id remained active in auto mode"
  [ "$(auto_pair_state "$CFG" "" "$id")" = active ] || fail "auto profile $id was not enabled"
done
for id in 8 9; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "standard fallback $id became active"
  [ "$(auto_pair_state "$CFG" "" "$id")" = skipped ] || fail "auto mode enabled fallback $id without permission"
done
auto_assert_no_double_skip "$CFG"

sum_before="$(file_sha "$CFG")"
config_set_auto_mode "$CFG" 1
sum_after="$(file_sha "$CFG")"
[ "$sum_before" = "$sum_after" ] || fail "enabling auto mode is not idempotent"

AUTO_OLD_CFG="$TMP_DIR/auto-old.conf"
AUTO_NEW_CFG="$TMP_DIR/auto-new.conf"
cp "$CFG" "$AUTO_OLD_CFG"
sed "s#/opt/zapret2#$ROOT#g" "$REPO_DIR/config.default" > "$AUTO_NEW_CFG"
backup_smart_apply_flags "$AUTO_OLD_CFG" "$AUTO_NEW_CFG"
[ "$(config_mode_text auto_mode "$AUTO_NEW_CFG")" = "включен" ] || fail "smart restore did not preserve auto mode"
[ "$(config_mode_text fallback "$AUTO_NEW_CFG")" = "выключен" ] || fail "smart restore enabled fallback while preserving auto mode"

backup_smart_set_fallback "$CFG" 1
[ "$(config_mode_text fallback "$CFG")" = "включен" ] || fail "fallback could not be enabled in auto mode"
for id in 8 9; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "standard fallback $id activated in auto mode"
  [ "$(auto_pair_state "$CFG" "" "$id")" = active ] || fail "auto fallback $id did not follow fallback toggle"
done
auto_assert_no_double_skip "$CFG"

config_set_auto_mode "$CFG" 0 || fail "auto mode could not be disabled"
[ "$(config_mode_text auto_mode "$CFG")" = "выключен" ] || fail "disabled auto mode is not detected"
for id in 1 2 3 4 3S 8 9; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = active ] || fail "standard profile $id was not restored"
  [ "$(auto_pair_state "$CFG" "" "$id")" = skipped ] || fail "auto profile $id remained active"
done
auto_assert_no_double_skip "$CFG"
sum_before="$(file_sha "$CFG")"
config_set_auto_mode "$CFG" 0
sum_after="$(file_sha "$CFG")"
[ "$sum_before" = "$sum_after" ] || fail "disabling auto mode is not idempotent"
backup_smart_set_fallback "$CFG" 0
for id in 8 9; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "standard fallback $id was not disabled"
  [ "$(auto_pair_state "$CFG" "" "$id")" = skipped ] || fail "disabled auto fallback $id changed unexpectedly"
done
[ "$(auto_udp_snapshot "$CFG")" = "$udp_before" ] || fail "auto-mode toggle changed UDP/QUIC/voice/game profiles"
[ "$(profile_max_snapshot "$CFG")" = "$profile_max_before" ] || fail "auto-mode blocks changed logical profile numbering"

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
