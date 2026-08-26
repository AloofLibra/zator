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
{
  printf '%s\n' \
    'CLIENT_SCOPE_ENABLE=0' \
    'CLIENT_SCOPE_MARK_MASK=' \
    'CLIENT_SCOPE_MARK_SHIFT=0' \
    'CLIENT_SCOPE_MARK_MAX=255'
  # Минимальный NFQWS2_OPT-блок, чтобы config_profile_max_strategy читал реальные max.
  printf '%s\n' \
    'NFQWS2_OPT="' \
    '--lua-desync=circular_locked:key=1:proto=tls:strategy=1' \
    '--lua-desync=circular_locked:key=1:proto=tls:strategy=2' \
    '--lua-desync=circular_locked:key=1:proto=tls:strategy=3' \
    '--lua-desync=circular_locked:key=2:proto=tls:strategy=1' \
    '--lua-desync=circular_locked:key=5:proto=udp:strategy=1' \
    '--lua-desync=circular_locked:key=5:proto=udp:strategy=2' \
    '"'
} > "$ZAPRET2_ROOT/config"

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
SERVICE_EVENTS="$TMP_DIR/service.events"
RUNNING_FLAG="$TMP_DIR/daemon.running"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/ui.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/submenus.sh"

# Валидация lock-стратегий (orch_scope_validate) читает max из CONFIG_FILE.
export CONFIG_FILE="$ZAPRET2_ROOT/config"

client_scope_firewall_action() { printf '%s\n' "$1" >> "$FIREWALL_EVENTS"; }
SERVICE_RC=0
SERVICE_FAIL_ONCE=0
SERVICE_RESTORE_RUNNING=0
z2r_service_action() {
  printf '%s\n' "$1" >> "$SERVICE_EVENTS"
  if [ "${SERVICE_FAIL_ONCE:-0}" = 1 ]; then
    SERVICE_FAIL_ONCE=0
    rm -f "$RUNNING_FLAG"
    return 42
  fi
  [ "${SERVICE_RESTORE_RUNNING:-0}" = 1 ] && touch "$RUNNING_FLAG"
  return "${SERVICE_RC:-0}"
}
zapret2_running() { [ -f "$RUNNING_FLAG" ]; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- Фаза A: базовые toggle (исторические проверки) ---
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

# --- Фаза B: client_scope_next_mark ---
[ "$(client_scope_next_mark)" = "mark:1" ] || fail 'next_mark empty should be mark:1'
client_scope_ip_set 192.0.2.60 mark:1 || fail 'set mark:1'
[ "$(client_scope_next_mark)" = "mark:2" ] || fail 'next_mark should skip used mark:1'
client_scope_ip_set 192.0.2.61 mark:2 || fail 'set mark:2'
[ "$(client_scope_next_mark)" = "mark:3" ] || fail 'next_mark should be mark:3'
client_scope_ip_set 192.0.2.62 mark:3 || fail 'set mark:3'
# Граничный случай: все mark до MAX заняты -> ошибка.
# MAX берётся из config (CLIENT_SCOPE_MARK_MAX), временно снижаем до 3.
config_set_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_MARK_MAX 3 || fail 'set MARK_MAX=3'
if client_scope_next_mark >/dev/null 2>&1; then
  fail 'next_mark should fail when all marks up to MAX are used'
fi
config_set_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_MARK_MAX 255 || fail 'restore MARK_MAX=255'
[ "$(client_scope_next_mark)" = "mark:4" ] || fail 'next_mark after restore should be mark:4'
client_scope_ip_remove 192.0.2.60 || fail 'clear mark:1'
client_scope_ip_remove 192.0.2.61 || fail 'clear mark:2'
client_scope_ip_remove 192.0.2.62 || fail 'clear mark:3'

# Мастер должен явно сообщать об исчерпании mark, а не предлагать пустой default.
config_set_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_MARK_MAX 2 || fail 'set exhausted MARK_MAX=2'
client_scope_ip_set 192.0.2.60 mark:1 || fail 'set mark:1 for exhausted wizard'
client_scope_ip_set 192.0.2.61 mark:2 || fail 'set mark:2 for exhausted wizard'
exhausted_out="$(printf '192.0.2.63\n' | client_scopes_wizard_add 2>&1 || true)"
printf '%s' "$exhausted_out" | grep -q 'Нет свободных scope' || fail 'wizard should report exhausted marks'
[ -z "$(client_scope_ip_get 192.0.2.63)" ] || fail 'exhausted wizard must not create mapping'
client_scope_ip_remove 192.0.2.60 || fail 'remove exhausted mark:1'
client_scope_ip_remove 192.0.2.61 || fail 'remove exhausted mark:2'
config_set_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_MARK_MAX 255 || fail 'restore exhausted MARK_MAX=255'

# --- Фаза C: client_scope_table / lock_summary ---
client_scope_ip_set 192.0.2.30 mark:2 || fail 'set mark:2 ip'
client_scope_ip_set 192.0.2.40 mark:10 || fail 'set mark:10 ip'
client_scope_ip_set 192.0.2.41 mark:10 || fail 'set mark:10 second ip'
orch_scoped_locked_set default 1 tls 3 || fail 'default lock'
orch_scoped_locked_set mark:10 5 udp 2 || fail 'mark:10 lock'
[ "$(client_scope_lock_summary default)" = "1/tls=3" ] || fail 'default lock summary'
[ "$(client_scope_lock_summary mark:10)" = "5/udp=2" ] || fail 'mark:10 lock summary'
[ -z "$(client_scope_lock_summary mark:2)" ] || fail 'mark:2 lock summary should be empty'
table="$(client_scope_table)"
[ "$(printf '%s\n' "$table" | sed -n 1p)" = "$(printf 'default\t\t1/tls=3')" ] || fail "table default row: $(printf '%s' "$table" | sed -n 1p)"
[ "$(printf '%s\n' "$table" | sed -n 2p)" = "$(printf 'mark:2\t192.0.2.30\t')" ] || fail "table mark:2 row (numeric order): $(printf '%s\n' "$table" | sed -n 2p)"
[ "$(printf '%s\n' "$table" | sed -n 3p)" = "$(printf 'mark:10\t192.0.2.40,192.0.2.41\t5/udp=2')" ] || fail "table mark:10 row: $(printf '%s\n' "$table" | sed -n 3p)"
client_scopes_print_table | grep -q '192.0.2.40,192.0.2.41' || fail 'print_table should show joined IPs'
client_scope_ip_remove 192.0.2.30 || fail 'clear mark:2 ip'
client_scope_ip_remove 192.0.2.40 || fail 'clear mark:10 ip'
client_scope_ip_remove 192.0.2.41 || fail 'clear mark:10 ip'
orch_scoped_locked_clear default 1 tls || fail 'clear default lock'
orch_scoped_locked_clear mark:10 5 udp || fail 'clear mark:10 lock'

# --- Фаза D: mode_set без маппингов запрещён ---
if client_scope_mode_set 1 >/dev/null 2>&1; then
  fail 'mode_set 1 should fail without mappings'
fi
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 0 ] || fail 'mode_set 1 must not persist without mappings'

# Setter откатывает config при ошибке подготовки и не оставляет режим включённым.
client_scope_ip_set 192.0.2.64 mark:1 || fail 'mapping for prepare rollback'
original_prepare="$(declare -f client_scope_config_prepare)"
client_scope_config_prepare() { return 9; }
if client_scope_mode_set 1 >/dev/null 2>&1; then
  fail 'mode_set should fail when prepare fails'
fi
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 0 ] || fail 'prepare failure must roll back config'
eval "$original_prepare"

# Setter пробрасывает ошибку рестарта и откатывает config/Lua/firewall.
export ZAPRET2_INIT="$TMP_DIR/init.sh"
touch "$RUNNING_FLAG"
SERVICE_FAIL_ONCE=1
SERVICE_RESTORE_RUNNING=1
if client_scope_mode_set 1 >/dev/null 2>&1; then
  fail 'mode_set should fail when daemon restart fails'
fi
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 0 ] || fail 'restart failure must roll back config'
grep -q '^CLIENT_SCOPE_ENABLE=0$' "$ZATOR_ROOT/lua/client-scope-config.lua" || fail 'restart failure must roll back Lua config'
[ -f "$RUNNING_FLAG" ] || fail 'restart failure rollback must restore previously running daemon'
SERVICE_RESTORE_RUNNING=0
rm -f "$RUNNING_FLAG"
unset ZAPRET2_INIT
client_scope_ip_remove 192.0.2.64 || fail 'clear rollback mapping'

# --- Фаза E: client_scope_daemon_reload ---
export ZAPRET2_INIT="$TMP_DIR/init.sh"
touch "$RUNNING_FLAG"
client_scope_daemon_reload
grep -qx restart "$SERVICE_EVENTS" || fail 'daemon_reload should restart running daemon'
rm -f "$RUNNING_FLAG"
: > "$SERVICE_EVENTS"
client_scope_daemon_reload
[ ! -s "$SERVICE_EVENTS" ] || fail 'daemon_reload must not restart a stopped daemon'
unset ZAPRET2_INIT
client_scope_daemon_reload
[ ! -s "$SERVICE_EVENTS" ] || fail 'daemon_reload must be a no-op without ZAPRET2_INIT'

# --- Фаза F: wizard_add базовый (авто-mark, без lock, без включения) ---
: > "$FIREWALL_EVENTS"
printf '192.0.2.20\n\nn\nn\n' | client_scopes_wizard_add || fail 'wizard_add basic'
[ "$(client_scope_ip_get 192.0.2.20)" = mark:1 ] || fail 'wizard_add should auto-assign mark:1'
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 0 ] || fail 'wizard_add must not enable mode on "n"'
[ ! -s "$FIREWALL_EVENTS" ] || fail 'wizard_add while disabled must not touch firewall'
[ "$(client_scope_next_mark)" = mark:2 ] || fail 'next_mark after wizard_add'

# --- Фаза G: wizard_add с lock (профиль 1 → tls → стратегия 2) ---
printf '192.0.2.21\n\nn\ny\n1\n1\n2\n' | client_scopes_wizard_add || fail 'wizard_add with lock'
[ "$(client_scope_ip_get 192.0.2.21)" = mark:2 ] || fail 'wizard_add lock client should get mark:2'
[ "$(orch_scoped_locked_get mark:2 1 tls)" = 2 ] || fail 'wizard_add lock should store mark:2/1/tls=2'
[ "$(client_scope_lock_summary mark:2)" = "1/tls=2" ] || fail 'lock summary after wizard_add'

# --- Фаза H: wizard_add с включением режима (демон запущен → рестарт) ---
export ZAPRET2_INIT="$TMP_DIR/init.sh"
touch "$RUNNING_FLAG"
: > "$FIREWALL_EVENTS"; : > "$SERVICE_EVENTS"
printf '192.0.2.22\n\ny\nn\n' | client_scopes_wizard_add || fail 'wizard_add with enable'
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 1 ] || fail 'wizard_add enable should persist'
grep -q '^CLIENT_SCOPE_ENABLE=1$' "$ZATOR_ROOT/lua/client-scope-config.lua" || fail 'wizard_add enable should sync Lua'
grep -qx apply "$FIREWALL_EVENTS" || fail 'wizard_add enable should apply firewall'
grep -qx restart "$SERVICE_EVENTS" || fail 'wizard_add enable should restart running daemon'
unset ZAPRET2_INIT
rm -f "$RUNNING_FLAG"

# --- Фаза I: wizard_lock отдельный (профиль 5, один протокол udp) ---
client_scope_ip_set 192.0.2.70 mark:10 || fail 'set mark:10 for lock test'
printf 'mark:10\n5\n1\n' | client_scopes_wizard_lock || fail 'wizard_lock standalone'
[ "$(orch_scoped_locked_get mark:10 5 udp)" = 1 ] || fail 'wizard_lock should store mark:10/5/udp=1'

# --- Фаза J: wizard_remove (IP + lock'и; режим гаснет только на последнем) ---
printf 'mark:2\ny\ny\n' | client_scopes_wizard_remove || fail 'wizard_remove mark:2'
[ -z "$(client_scope_ip_get 192.0.2.21)" ] || fail 'wizard_remove should clear IP'
[ "$(orch_scoped_locked_get mark:2 1 tls)" = 0 ] || fail 'wizard_remove should clear locks'
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 1 ] || fail 'wizard_remove must keep mode while other mappings exist'
# Последний маппинг → режим выключается автоматически.
printf 'mark:10\ny\nn\n' | client_scopes_wizard_remove || fail 'wizard_remove mark:10'
printf 'mark:1\ny\nn\n' | client_scopes_wizard_remove || fail 'wizard_remove mark:1'
export ZAPRET2_INIT="$TMP_DIR/init.sh"
touch "$RUNNING_FLAG"
SERVICE_FAIL_ONCE=1
SERVICE_RESTORE_RUNNING=1
if printf 'mark:3\ny\nn\n' | client_scopes_wizard_remove; then
  fail 'last-client removal should report first restart failure'
fi
[ -f "$RUNNING_FLAG" ] || fail 'last-client removal rollback must restore previously running daemon'
SERVICE_FAIL_ONCE=0
SERVICE_RESTORE_RUNNING=0
rm -f "$RUNNING_FLAG"
unset ZAPRET2_INIT
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 0 ] || fail 'removing last mapping should disable mode'
[ ! -s "$CLIENT_SCOPE_MAP_FILE" ] || fail 'mapping file should be empty after removing all clients'

# --- Фаза K: меню 11 (сводка + мастера) ---
# Ручной ввод разрешает только существующий scope.
if printf 'mark:999\nq\n' | client_scopes_ask_scope >/dev/null 2>&1; then
  fail 'ask_scope must reject a non-existent mark'
fi
printf '9\n0\n' | client_scopes_submenu || fail 'submenu should exit on 0 after invalid input'
printf '1\n192.0.2.50\n\nn\nn\n\n0\n' | client_scopes_submenu || fail 'submenu wizard_add roundtrip'
[ "$(client_scope_ip_get 192.0.2.50)" = mark:1 ] || fail 'submenu wizard_add should persist mapping'
# Пункт 4: включение без маппингов не должно сработать.
client_scope_ip_remove 192.0.2.50 || fail 'clear for toggle test'
printf '4\ny\n\n0\n' | client_scopes_submenu || fail 'submenu toggle roundtrip'
[ "$(config_get_var "$ZAPRET2_ROOT/config" CLIENT_SCOPE_ENABLE)" = 0 ] || fail 'submenu toggle must not enable without mappings'

printf 'client scope menu smoke ok\n'
