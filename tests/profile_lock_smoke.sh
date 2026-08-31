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
tr -d '\r' < "$REPO_DIR/config.default" | sed -e "s#/opt/zapret2#$ROOT#g" -e "s#/opt/zator#$ROOT#g" > "$CFG"
tr -d '\r' < "$REPO_DIR/config.default" > "$TMP_DIR/config.default.lf"
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
grep -q 'circular_locked:key=3:.*include_substrings=/opt/zator/extra_strats/TCP_RKN_domains_by_substring.txt' "$REPO_DIR/config.default" || fail "substring list is not wired into the standard RKN router"
grep -q 'include_substrings auto counterpart must cut off non-matching host' "$REPO_DIR/tests/provisional_tcp_success.lua" || fail "auto substring routing regression is missing"
grep -q 'allow_nohost route must use route_key' "$REPO_DIR/tests/provisional_tcp_success.lua" || fail "auto fallback routing regression is missing"
[ -f "$REPO_DIR/extra_strats/TCP/RKN/Domains_By_Substring.txt" ] || fail "substring list source is missing"

nfqws2_opt="$(sed -n '/^NFQWS2_OPT="/,/^"$/p' "$REPO_DIR/config.default")"
assert_not_contains "$nfqws2_opt" '(^|[[:space:]])--qnum([=[:space:]]|$)' "NFQWS2_OPT must not contain an in-block --qnum"

for runtime_file in \
  lua/strategy-lock-manager.lua \
  lua/combined-detector.lua \
  lua/silent-drop-detector.lua \
  lua/dns-clone.lua \
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
grep -q '"lua/dns-clone.lua"' "$REPO_DIR/z2r.sh" || fail "dns-clone is not deployed"
grep -q '"lua/strategy-lock-manager.lua"' "$REPO_DIR/z2r.sh" || fail "strategy lock manager is not deployed"
grep -q '"lua/strategy-validator.sh"' "$REPO_DIR/z2r.sh" || fail "strategy validator is not deployed"
grep -q '"init.d/openwrt/z2r-strategy-validator"' "$REPO_DIR/z2r.sh" || fail "strategy validator service is not deployed"
grep -q '"Entware/z2r-strategy-validator"' "$REPO_DIR/z2r.sh" || fail "Entware strategy validator service is not deployed"
grep -q 'chmod +x "$STRATEGY_VALIDATOR_WORKER"' "$REPO_DIR/z2r.sh" || fail "strategy validator worker is not executable after deploy"
grep -q 'validator=/opt/zator/lua/strategy-validator.sh' "$TMP_DIR/config.default.lf" || fail "auto profile does not reference the deployed validator"
[ "$(grep -c '^--lua-init=@/opt/zator/lua/strategy-lock-manager.lua$' "$TMP_DIR/config.default.lf")" -eq 1 ] || fail "strategy lock manager lua-init is missing or duplicated"
[ "$(grep -c '^--lua-init=@/opt/zator/lua/combined-detector.lua$' "$TMP_DIR/config.default.lf")" -eq 1 ] || fail "combined detector lua-init is missing or duplicated"
[ "$(grep -c '^--lua-init=@/opt/zator/lua/silent-drop-detector.lua$' "$TMP_DIR/config.default.lf")" -eq 1 ] || fail "silent-drop detector lua-init is missing or duplicated"
[ "$(grep -c '^--lua-init=@/opt/zator/lua/dns-clone.lua$' "$TMP_DIR/config.default.lf")" -eq 1 ] || fail "dns-clone lua-init is missing or duplicated"
awk '
  /lua-init=@\/opt\/zator\/lua\/strategy-lock-manager\.lua/ {manager=NR}
  /lua-init=@\/opt\/zator\/lua\/combined-detector\.lua/ {combined=NR}
  /lua-init=@\/opt\/zator\/lua\/silent-drop-detector\.lua/ {silent=NR}
  /lua-init=@\/opt\/zator\/lua\/dns-clone\.lua/ {dnsclone=NR}
  END {exit !(manager < combined && combined < silent && silent < dnsclone)}
' "$REPO_DIR/config.default" || fail "circular lua-init order is invalid"

# --- Профиль 10 (антиспуф DNS): маркеры и структура блока ---
# Проверки с якорями — по нормализованной LF-копии (checkout может быть CRLF).
[ "$(grep -c '^#Z2R_DNS_BEGIN$' "$TMP_DIR/config.default.lf")" -eq 1 ] || fail "Z2R_DNS_BEGIN marker is missing or duplicated"
[ "$(grep -c '^#Z2R_DNS_END$' "$TMP_DIR/config.default.lf")" -eq 1 ] || fail "Z2R_DNS_END marker is missing or duplicated"
dns_block="$(sed -n '/^#Z2R_DNS_BEGIN$/,/^#Z2R_DNS_END$/p' "$TMP_DIR/config.default.lf")"
assert_contains "$dns_block" '^--skip --filter-udp=53$' "DNS profile must be disabled by default"
assert_contains "$dns_block" 'circular_locked:key=10:proto=udp:allow_nohost=1' "DNS profile orchestrator changed"
# Один номер стратегии = один TTL клона (1->8, 2->4, 3->2), без веера на одном номере.
[ "$(printf '%s\n' "$dns_block" | grep -c 'dnsclone:ttl=8:ip_id=rnd:resend=1:strategy=1$')" -eq 1 ] || fail "DNS strategy 1 must be the canonical ttl=8 clone"
[ "$(printf '%s\n' "$dns_block" | grep -c 'dnsclone:ttl=4:ip_id=rnd:resend=1:strategy=2$')" -eq 1 ] || fail "DNS strategy 2 must be ttl=4"
[ "$(printf '%s\n' "$dns_block" | grep -c 'dnsclone:ttl=2:ip_id=rnd:resend=1:strategy=3$')" -eq 1 ] || fail "DNS strategy 3 must be ttl=2"
[ "$(printf '%s\n' "$dns_block" | grep -c 'dnsclone:ttl=8:pad=8:ip_id=rnd:resend=1:strategy=4$')" -eq 1 ] || fail "DNS strategy 4 must be ttl=8 with padding"
assert_not_contains "$dns_block" 'strategy=1.*strategy=1' "DNS strategy numbers must not repeat on one line"
if printf '%s\n' "$dns_block" | grep -Eq '^[[:space:]]*#.*--'; then
  fail "DNS block comments must not contain -- tokens (they stay active inside NFQWS2_OPT)"
fi

auto_pair_block() {
  local cfg="$1" kind="$2" id="$3"
  sed -n "/^#Z2R_AUTO_${kind}${id}_BEGIN$/,/^#Z2R_AUTO_${kind}${id}_END$/p" "$cfg"
}

auto_pair_signature() {
  auto_pair_block "$1" "$2" "$3" | sed -E 's/^--skip[[:space:]]+//'
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
  for profile in 1 2 3 4 5 6 7 8 9 10; do
    printf '%s:%s\n' "$profile" "$(config_profile_max_strategy "$profile" "$1")"
  done
}

STANDARD_IDS="$(config_auto_pair_ids "$CFG" standard | paste -sd ' ' -)"
AUTO_IDS="$(config_auto_pair_ids "$CFG" | paste -sd ' ' -)"
[ "$STANDARD_IDS" = "1 2 3 4 8 3S 9" ] || fail "standard TCP/HTTP profile markers changed"
[ "$AUTO_IDS" = "3 4 9" ] || fail "automatic profile set must be exactly 3, 4, 9"
for marker in Z2R_AUTO_STANDARD_1 Z2R_AUTO_9; do
  BAD_LAYOUT_CFG="$TMP_DIR/bad-${marker}.conf"
  cp "$CFG" "$BAD_LAYOUT_CFG"
  sed -i "/^#${marker}_BEGIN$/d; /^#${marker}_END$/d" "$BAD_LAYOUT_CFG"
  sum_before="$(file_sha "$BAD_LAYOUT_CFG")"
  if config_set_auto_mode "$BAD_LAYOUT_CFG" 1; then
    fail "auto mode accepted missing marker pair $marker"
  fi
  [ "$(file_sha "$BAD_LAYOUT_CFG")" = "$sum_before" ] || fail "auto mode mutated invalid layout $marker"
done
for id in $AUTO_IDS; do
  [ "$(grep -c "^#Z2R_AUTO_STANDARD_${id}_BEGIN$" "$CFG")" -eq 1 ] || fail "missing standard auto pair $id"
  [ "$(grep -c "^#Z2R_AUTO_${id}_BEGIN$" "$CFG")" -eq 1 ] || fail "missing automatic pair $id"
  assert_contains "$(auto_pair_block "$CFG" STANDARD_ "$id")" "circular_locked:key=${id}([^0-9]|$)" "standard profile $id changed logical key"
  assert_contains "$(auto_pair_block "$CFG" "" "$id")" "circular_quality:key=${id}([^0-9]|$)" "auto profile $id changed logical key"
done
assert_not_contains "$(auto_pair_block "$CFG" "" 3)" '^--hostlist=' "AUTO_3 must not inherit standard RKN hostlists"
assert_not_contains "$(auto_pair_block "$CFG" "" 9)" 'circular_quality:key=9:.*allow_nohost' "AUTO_9 must not use allow_nohost"

strategy_menu="$(sed -n '/^strategies_submenu()/,/^}/p' "$REPO_DIR/lib/submenus.sh")"
for menu_id in 1 2 3 4 5 6 7 8 9 10 11; do
  [ "$(printf '%s\n' "$strategy_menu" | grep -Ec "submenu_item \"[[:space:]]*${menu_id}\"[[:space:]]")" -eq 1 ] || fail "strategy menu item $menu_id changed numbering"
done
assert_contains "$strategy_menu" 'Профиль 10: DNS антиспуф' "strategy menu item 10 must be the DNS profile"
assert_contains "$strategy_menu" 'submenu_item "11" "Авторотация TCP/HTTP' "strategy menu item 11 must be autorotation"
assert_contains "$strategy_menu" 'включите антиспуф DNS, п.8' "DNS menu item must be guarded by the main menu toggle"
assert_contains "$strategy_menu" 'orch_profile_try "10"' "DNS menu item must run the profile 10 trial"
assert_contains "$strategy_menu" 'if \[ "\$auto_enabled" = "1" \]' "strategy menu does not hide manual TCP actions in auto mode"
assert_contains "$strategy_menu" '1\|2\|3\|4\|8\|9\)' "strategy menu does not guard manual TCP choices in auto mode"
for menu_id in 5 6 7; do
  assert_contains "$strategy_menu" "submenu_item \"[[:space:]]*${menu_id}\"" "UDP strategy menu item $menu_id is unavailable in auto mode"
done
fallback_toggle="$(sed -n '/^toggle_fallback_mode()/,/^}/p' "$REPO_DIR/lib/actions.sh")"
assert_contains "$fallback_toggle" 'config_mode_text auto_mode' "fallback menu action is not guarded in auto mode"
assert_contains "$fallback_toggle" 'return 0' "fallback menu action does not stop in auto mode"

for mapping in '1 tls http' '2 tls' '3 tls' '4 tls' '5 udp' '6 udp' '7 udp' '8 tls' '9 http' '10 udp'; do
  set -- $mapping
  [ "$(config_profile_proto_list "$1")" = "${mapping#* }" ] || fail "logical profile $1 protocol mapping changed"
done

udp_before="$(auto_udp_snapshot "$CFG")"
unpaired_content_before="$(for id in 1 2 8 3S; do auto_pair_signature "$CFG" STANDARD_ "$id"; done)"
profile_max_before="$(profile_max_snapshot "$CFG")"
[ "$(config_mode_text fallback "$CFG")" = "выключен" ] || fail "fallback must be disabled by default"
[ "$(config_mode_text auto_mode "$CFG")" = "выключен" ] || fail "auto mode must be disabled by default"
for id in 1 2 3 4 3S; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = active ] || fail "standard profile $id must be active by default"
done
for id in 8 9; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "standard fallback $id must be skipped by default"
done
for id in $AUTO_IDS; do
  [ "$(auto_pair_state "$CFG" "" "$id")" = skipped ] || fail "auto profile $id must be skipped by default"
done
auto_assert_no_double_skip "$CFG"

config_set_auto_mode "$CFG" 1 || fail "auto mode could not be enabled"
[ "$(config_mode_text auto_mode "$CFG")" = "включен" ] || fail "enabled auto mode is not detected"
[ "$(config_mode_text fallback "$CFG")" = "недоступен" ] || fail "fallback must be unavailable in auto mode"
for id in $STANDARD_IDS; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "standard profile $id remained active in auto mode"
done
for id in $AUTO_IDS; do
  [ "$(auto_pair_state "$CFG" "" "$id")" = active ] || fail "auto profile $id was not enabled"
done
[ "$(for id in 1 2 8 3S; do auto_pair_signature "$CFG" STANDARD_ "$id"; done)" = "$unpaired_content_before" ] || fail "auto mode changed unpaired standard profile content"
[ "$(auto_udp_snapshot "$CFG")" = "$udp_before" ] || fail "auto mode changed UDP/QUIC/voice/game profiles"
auto_assert_no_double_skip "$CFG"

sum_before="$(file_sha "$CFG")"
config_set_auto_mode "$CFG" 1
sum_after="$(file_sha "$CFG")"
[ "$sum_before" = "$sum_after" ] || fail "enabling auto mode is not idempotent"

AUTO_OLD_CFG="$TMP_DIR/auto-old.conf"
AUTO_NEW_CFG="$TMP_DIR/auto-new.conf"
cp "$CFG" "$AUTO_OLD_CFG"
sed -e "s#/opt/zapret2#$ROOT#g" -e "s#/opt/zator#$ROOT#g" "$REPO_DIR/config.default" > "$AUTO_NEW_CFG"
backup_smart_apply_flags "$AUTO_OLD_CFG" "$AUTO_NEW_CFG"
[ "$(config_mode_text auto_mode "$AUTO_NEW_CFG")" = "включен" ] || fail "smart restore did not preserve auto mode"
config_set_auto_mode "$AUTO_NEW_CFG" 0 || fail "smart-restored auto mode could not be disabled"
for id in 8 9; do
  [ "$(auto_pair_state "$AUTO_NEW_CFG" STANDARD_ "$id")" = skipped ] || fail "smart restore lost disabled fallback state for $id"
done

AUTO_ON_OLD_CFG="$TMP_DIR/auto-on-old.conf"
AUTO_ON_NEW_CFG="$TMP_DIR/auto-on-new.conf"
sed -e "s#/opt/zapret2#$ROOT#g" -e "s#/opt/zator#$ROOT#g" "$REPO_DIR/config.default" > "$AUTO_ON_OLD_CFG"
backup_smart_set_fallback "$AUTO_ON_OLD_CFG" 1
config_set_auto_mode "$AUTO_ON_OLD_CFG" 1 || fail "smart restore setup could not enable auto mode"
sed -e "s#/opt/zapret2#$ROOT#g" -e "s#/opt/zator#$ROOT#g" "$REPO_DIR/config.default" > "$AUTO_ON_NEW_CFG"
backup_smart_apply_flags "$AUTO_ON_OLD_CFG" "$AUTO_ON_NEW_CFG"
[ "$(config_mode_text auto_mode "$AUTO_ON_NEW_CFG")" = "включен" ] || fail "smart restore lost auto mode with saved fallback"
config_set_auto_mode "$AUTO_ON_NEW_CFG" 0 || fail "smart-restored saved fallback could not leave auto mode"
for id in 8 9; do
  [ "$(auto_pair_state "$AUTO_ON_NEW_CFG" STANDARD_ "$id")" = active ] || fail "smart restore lost enabled fallback state for $id"
done

sum_before="$(file_sha "$CFG")"
backup_smart_set_fallback "$CFG" 1
sum_after="$(file_sha "$CFG")"
[ "$sum_before" = "$sum_after" ] || fail "fallback setter must be a no-op in auto mode"

config_set_auto_mode "$CFG" 0 || fail "auto mode could not be disabled"
[ "$(config_mode_text auto_mode "$CFG")" = "выключен" ] || fail "disabled auto mode is not detected"
for id in 1 2 3 4 3S; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = active ] || fail "standard profile $id was not restored"
done
for id in 8 9; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "disabled fallback state was not restored for $id"
done
for id in $AUTO_IDS; do
  [ "$(auto_pair_state "$CFG" "" "$id")" = skipped ] || fail "auto profile $id remained active"
done
auto_assert_no_double_skip "$CFG"
sum_before="$(file_sha "$CFG")"
config_set_auto_mode "$CFG" 0
sum_after="$(file_sha "$CFG")"
[ "$sum_before" = "$sum_after" ] || fail "disabling auto mode is not idempotent"

backup_smart_set_fallback "$CFG" 1
[ "$(config_mode_text fallback "$CFG")" = "включен" ] || fail "fallback could not be enabled"
for id in 8 9; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = active ] || fail "standard fallback $id was not enabled"
done

config_set_auto_mode "$CFG" 1 || fail "auto mode could not be re-enabled"
for id in $STANDARD_IDS; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "standard profile $id remained active after re-enabling auto mode"
done
for id in $AUTO_IDS; do
  [ "$(auto_pair_state "$CFG" "" "$id")" = active ] || fail "auto profile $id was not re-enabled"
done
sum_before="$(file_sha "$CFG")"
backup_smart_set_fallback "$CFG" 0
sum_after="$(file_sha "$CFG")"
[ "$sum_before" = "$sum_after" ] || fail "fallback setter changed saved state in auto mode"

config_set_auto_mode "$CFG" 0 || fail "auto mode could not be disabled after saved fallback test"
for id in $STANDARD_IDS; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = active ] || fail "enabled fallback state was not restored for standard profile $id"
done
for id in $AUTO_IDS; do
  [ "$(auto_pair_state "$CFG" "" "$id")" = skipped ] || fail "auto profile $id remained active after saved fallback test"
done

backup_smart_set_fallback "$CFG" 0
for id in 8 9; do
  [ "$(auto_pair_state "$CFG" STANDARD_ "$id")" = skipped ] || fail "standard fallback $id was not disabled"
done
[ "$(auto_udp_snapshot "$CFG")" = "$udp_before" ] || fail "auto-mode toggle changed UDP/QUIC/voice/game profiles"
[ "$(profile_max_snapshot "$CFG")" = "$profile_max_before" ] || fail "auto-mode blocks changed logical profile numbering"

PORT_CFG="$TMP_DIR/ports.conf"
sed -e "s#/opt/zapret2#$ROOT#g" -e "s#/opt/zator#$ROOT#g" "$REPO_DIR/config.default" > "$PORT_CFG"
config_set_auto_mode "$PORT_CFG" 1 || fail "port routing test could not enable auto mode"
ports_set_rkn_filter "$PORT_CFG" "12345"
assert_contains "$(auto_pair_block "$PORT_CFG" STANDARD_ 3)" '^--skip --filter-tcp=12345,80,443,' "RKN port setter did not update skipped standard profile 3"
assert_contains "$(auto_pair_block "$PORT_CFG" "" 3)" '^--filter-tcp=12345,80,443,' "RKN port setter did not update active AUTO_3"

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

sed -e "s#/opt/zapret2#$ROOT#g" -e "s#/opt/zator#$ROOT#g" "$REPO_DIR/config.default" > "$CFG"
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

# --- Профиль 10: антиспуф DNS (тумблер, порт 53, локи, снапшот меню) ---
[ "$(config_profile_max_strategy 10 "$CFG")" = "6" ] || fail "DNS profile max strategy must be 6"
[ "$(config_mode_text dns_desync "$CFG")" = "Выключен" ] || fail "DNS antispoof must be disabled by default"
assert_not_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53(,|$)' "port 53 must not be in NFQWS2_PORTS_UDP by default"

backup_smart_set_dns_desync "$CFG" 1
config_profile_dns_ports_apply "$CFG" 1
[ "$(config_mode_text dns_desync "$CFG")" = "Включен" ] || fail "DNS antispoof could not be enabled"
assert_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53(,|$)' "toggle did not add port 53"

# повторное включение идемпотентно (порт не дублируется)
backup_smart_set_dns_desync "$CFG" 1
config_profile_dns_ports_apply "$CFG" 1
assert_not_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53,53(,|$)' "toggle duplicated port 53"

backup_smart_set_dns_desync "$CFG" 0
config_profile_dns_ports_apply "$CFG" 0
[ "$(config_mode_text dns_desync "$CFG")" = "Выключен" ] || fail "DNS antispoof could not be disabled"
assert_not_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53(,|$)' "toggle did not remove port 53"

# smart restore сохраняет состояние тумблера между конфигами
DNS_OLD_CFG="$TMP_DIR/dns-old.conf"
DNS_NEW_CFG="$TMP_DIR/dns-new.conf"
cp "$CFG" "$DNS_OLD_CFG"
backup_smart_set_dns_desync "$DNS_OLD_CFG" 1
config_profile_dns_ports_apply "$DNS_OLD_CFG" 1
sed -e "s#/opt/zapret2#$ROOT#g" -e "s#/opt/zator#$ROOT#g" "$REPO_DIR/config.default" > "$DNS_NEW_CFG"
backup_smart_apply_flags "$DNS_OLD_CFG" "$DNS_NEW_CFG"
[ "$(config_mode_text dns_desync "$DNS_NEW_CFG")" = "Включен" ] || fail "smart restore lost DNS antispoof state"

# сохранённый лок профиля 10 реанимируется на свежем config
printf '10\tudp\t2\n' > "$PROFILE_STATE_FILE"
profile_apply_all "$CFG" >/dev/null
[ "$(orch_locked_get 10 udp)" = "2" ] || fail "stored DNS lock was not rehydrated into orchestra lock"
printf '10\tudp\t99\n' > "$PROFILE_STATE_FILE"
profile_apply_all "$CFG" >/dev/null
[ "$(orch_locked_get 10 udp)" = "2" ] || fail "out-of-range DNS lock must be skipped, not applied"

# снапшот главного меню: лимит профиля 10 и состояние тумблера
menu_config_snapshot "$CFG"
[ "$MENU_PROFILE_MAX_10" = "6" ] || fail "menu snapshot did not fill MENU_PROFILE_MAX_10"
[ "$MENU_DNS_DESINC" = "Выключен" ] || fail "menu snapshot did not fill MENU_DNS_DESINC"
menu_config_snapshot "$DNS_NEW_CFG"
[ "$MENU_DNS_DESINC" = "Включен" ] || fail "menu snapshot did not detect enabled DNS antispoof"

# --- Дата изменения config (# Last modified) для главного меню ---
grep -q '^# Last modified: ' "$REPO_DIR/config.default" \
  || fail "config.default lost its Last modified header"
stamp="$(config_last_modified "$REPO_DIR/config.default")"
assert_contains "$stamp" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC$' \
  "Last modified stamp has unexpected format: $stamp"

menu_config_snapshot "$CFG"
[ "$MENU_CONFIG_DATE" = "$(config_last_modified "$CFG")" ] \
  || fail "menu_config_snapshot did not fill MENU_CONFIG_DATE from config"

no_hdr_cfg="$TMP_DIR/no-header.cfg"
sed '/^# Last modified: /d' "$CFG" > "$no_hdr_cfg"
[ "$(config_last_modified "$no_hdr_cfg")" = "Неизвестно" ] \
  || fail "config_last_modified must return Неизвестно without header"
menu_config_snapshot "$no_hdr_cfg"
[ "$MENU_CONFIG_DATE" = "Неизвестно" ] \
  || fail "menu_config_snapshot must default MENU_CONFIG_DATE without header"
menu_config_snapshot "$TMP_DIR/missing-$$.cfg"
[ "$MENU_CONFIG_DATE" = "Неизвестно" ] \
  || fail "menu_config_snapshot must default MENU_CONFIG_DATE for missing file"

grep -qF 'Версия config файла от: ${plain}${MENU_CONFIG_DATE}' "$REPO_DIR/z2r.sh" \
  || fail "main menu does not show config file date"

echo "profile_lock smoke ok"
