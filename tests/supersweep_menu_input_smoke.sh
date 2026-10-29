#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/supersweep.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
Z2R_SUPERSWEEP_DIR="$TMP/run"
config_get_file() { printf '%s/config\n' "$TMP"; }
menu_config_snapshot() { MENU_AUTO_MODE=выключен; }
zapret2_running() { return 0; }
clear() { :; }
pause_enter() { :; }
supersweep_ask_domains() { printf 'example.com\n'; }
supersweep_ask_own_domains() { printf '%s\n' "$1"; }
orch_ask_sweep_tls_pref() { printf 'both\n'; }
supersweep_ask_pause() { printf '15\n'; }
supersweep_ask_ds_pause() { printf '15\n'; }
supersweep_ask_rkn_pause() { printf '60\n'; }
config_profile_max_strategy() { printf '1\n'; }
_supersweep_estimate_total() { printf '1\n'; }
z2r_dns_spoof_gate() { printf 'gate\n' >> "$TMP/actions"; }
expected_video=BPk1uJ4txPc
supersweep_background_start() { test "$Z2R_MEDIA_VIDEO_ID" = "$expected_video"; printf 'background\n' >> "$TMP/actions"; }
supersweep_run() { test "$Z2R_MEDIA_VIDEO_ID" = "$expected_video"; printf 'foreground\n' >> "$TMP/actions"; }
for letter in b B в В б Б; do
    : > "$TMP/actions"
    printf '\n%s\n' "$letter" > "$TMP/input"
    supersweep_menu < "$TMP/input" > "$TMP/output" 2>&1
    grep -qx background "$TMP/actions" || { printf 'FAIL: background input %s\n' "$letter" >&2; exit 1; }
    ! grep -qx foreground "$TMP/actions"
done
: > "$TMP/actions"
printf '\nневерно\n?\nВ\n' > "$TMP/input"
supersweep_menu < "$TMP/input" > "$TMP/output" 2>&1
[ "$(grep -cx gate "$TMP/actions")" = 1 ]
grep -qx background "$TMP/actions"
! grep -qx foreground "$TMP/actions"
grep -q 'Не удалось распознать ввод' "$TMP/output"
: > "$TMP/actions"
printf '\nошибка\n\n' > "$TMP/input"
supersweep_menu < "$TMP/input" > "$TMP/output" 2>&1
grep -qx foreground "$TMP/actions"
! grep -qx background "$TMP/actions"
for input in '0' 'ошибка\n0' 'ошибка'; do
    : > "$TMP/actions"
    printf '\n%b\n' "$input" > "$TMP/input"
    supersweep_menu < "$TMP/input" > "$TMP/output" 2>&1
    [ ! -s "$TMP/actions" ]
done
: > "$TMP/input"
supersweep_menu < "$TMP/input" > "$TMP/output" 2>&1
[ ! -s "$TMP/actions" ]
expected_video=M7lc1UVf-VE
: > "$TMP/actions"
printf 'https://www.youtube.com/watch?v=M7lc1UVf-VE&feature=shared\nB\n' > "$TMP/input"
supersweep_menu < "$TMP/input" > "$TMP/output" 2>&1
grep -qx background "$TMP/actions"
printf 'supersweep menu input smoke ok\n'
