#!/usr/bin/env bash

# Тест двойного режима фейков (classic/clone, mode_override.tsv): хелперы
# lib/orchestra_state.sh, рантайм-хук locked.lua (клон CH пользователя),
# подменю п.16, бэкап-лист. Инвариант: режим меняет только рантайм-поведение
# (TSV + Lua на лету), живой конфиг не трогается.
# Работает только во временной директории в /tmp: не пишет в /opt, не
# запускает настоящий zapret2.

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

  grep -Eq -- "$pattern" <<<"$text" || fail "$message"
}

TMP_DIR="$(mktemp -d /tmp/zator-fake-mode.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT="$TMP_DIR/zapret2"   # играет роль и /opt/zapret2, и /opt/zator
CFG="$ROOT/config"
export ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export ZATOR_ROOT="$ROOT"
export ZAPRET2_ROOT="$ROOT"

mkdir -p "$ORCH_DIR"
tr -d '\r' < "$REPO_DIR/config.default" | sed -e "s#/opt/zapret2#$ROOT#g" > "$CFG"
cfg_before="$(md5sum "$CFG" | cut -d' ' -f1)"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/actions.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/ui.sh"

# --- 0. Синтаксис -----------------------------------------------------------

for f in lib/orchestra_state.sh lib/actions.sh lib/submenus.sh \
  webui/cgi-bin/_lib.sh webui/cgi-bin/settings.cgi; do
  bash -n "$REPO_DIR/$f" || fail "bash -n: $f"
done
python -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' \
  "$REPO_DIR/webui/dev/fake_router_server.py" 2>/dev/null \
  || python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' \
    "$REPO_DIR/webui/dev/fake_router_server.py" \
  || fail "python: fake_router_server.py"

# --- 1. Статический wiring locked.lua ---------------------------------------

LOCKED_LUA_SRC="$(tr -d '\r' < "$REPO_DIR/orchestra/locked.lua")"
SUBMENUS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/submenus.sh")"
ACTIONS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/actions.sh")"
AGENTS_SRC="$(tr -d '\r' < "$REPO_DIR/AGENTS.md")"

assert_contains "$LOCKED_LUA_SRC" 'mode_override.tsv' "locked.lua не читает mode_override.tsv"
assert_contains "$LOCKED_LUA_SRC" 'function mode_override_parse_line' "locked.lua нет парсера режима"
assert_contains "$LOCKED_LUA_SRC" 'load_mode_override_file\(MODE_OVERRIDE_PATH\)' \
  "load_locked_tables не перезагружает режим"
assert_contains "$LOCKED_LUA_SRC" 'fields\[2\] ~= "clone" and fields\[2\] ~= "classic"' \
  "парсер режима принимает значения кроме clone|classic"
assert_contains "$LOCKED_LUA_SRC" 'function locked_load_mode_override_for_tests' "нет тестового сеттера режима"

# клон: только ClientHello, невинный SNI с дефолтом, формула sni_del+sni_first
assert_contains "$LOCKED_LUA_SRC" 'l7payload ~= "tls_client_hello"' \
  "клон строится не только на ClientHello"
assert_contains "$LOCKED_LUA_SRC" 'pcall\(tls_client_hello_mod' \
  "построение клона не защищено pcall"
assert_contains "$LOCKED_LUA_SRC" 'sni_del = true' "клон не вычищает настоящий SNI"
assert_contains "$LOCKED_LUA_SRC" 'sni_snt_new = 0' "клон не задаёт тип нового имени SNI"
assert_contains "$LOCKED_LUA_SRC" '"www.google.com"' "нет невинного дефолта SNI клона"
assert_contains "$LOCKED_LUA_SRC" 'desync\[Z2R_CLONE_FIELD\] = clone_data' \
  "клон не кладётся в рантайм-поле desync"

# хук: порядок режим -> клон -> блоб-override; множество значений прежнее
assert_contains "$LOCKED_LUA_SRC" 'MODE_OVERRIDES\[tostring\(profile_key\)\]' \
  "хук не читает режим по profile_key"
assert_contains "$LOCKED_LUA_SRC" 'clone_data and Z2R_CLONE_FIELD or name' \
  "клон не выигрывает у блоба-override"
assert_contains "$LOCKED_LUA_SRC" 'saved_blob == "maxru" or saved_blob == "fake_default_tls"' \
  "хук подменяет только maxru|fake_default_tls"
assert_contains "$LOCKED_LUA_SRC" 'instance\.arg\.blob = saved_blob' "хук не восстанавливает instance.arg"
assert_contains "$LOCKED_LUA_SRC" 'blob_override_execute\(desync, verdict, instance, base_profile\)' \
  "circular_locked не передаёт base_profile в хук"
# sni_first-подмена конфиг-клонов не задета режимом
assert_contains "$LOCKED_LUA_SRC" 'instance\.arg\.sni_first = saved_sni' \
  "sni_first не восстанавливается"

# --- 2. Статический wiring меню и бэкапов -----------------------------------

assert_contains "$SUBMENUS_SRC" '^fake_mode_submenu\(\)' "нет подменю fake_mode_submenu"
assert_contains "$SUBMENUS_SRC" '^fake_mode_profile_pick\(\)' "нет экрана профиля fake_mode_profile_pick"
assert_contains "$SUBMENUS_SRC" 'mode_override_supported_profiles' "подменю не строится по поддерживаемым профилям"
assert_contains "$SUBMENUS_SRC" 'mode_override_set "\$p" clone' "нет включения клонов всем профилям"
assert_contains "$SUBMENUS_SRC" 'mode_override_clear "\$p"' "нет сброса режима всем профилям"
assert_contains "$SUBMENUS_SRC" 'fake_mode_submenu' "tls_blob_submenu не открывает подменю режима"
assert_contains "$SUBMENUS_SRC" 'sni_override_get "\$1"' "экран режима не показывает SNI клона"

z2r_backup_state_files 2>/dev/null | grep -q 'extra_strats/cache/orchestra/mode_override.tsv' \
  || fail "z2r_backup_state_files не бэкапит mode_override.tsv"
z2r_backup_state_files 2>/dev/null | grep -q 'extra_strats/cache/orchestra/sni_override.tsv' \
  || fail "z2r_backup_state_files не бэкапит sni_override.tsv"
assert_contains "$AGENTS_SRC" 'mode_override\.tsv' "AGENTS.md не упоминает mode_override.tsv"

# --- 2b. Статический wiring WebUI --------------------------------------------

LIB_SH_SRC="$(tr -d '\r' < "$REPO_DIR/webui/cgi-bin/_lib.sh")"
SETTINGS_CGI_SRC="$(tr -d '\r' < "$REPO_DIR/webui/cgi-bin/settings.cgi")"
FAKE_SRV_SRC="$(tr -d '\r' < "$REPO_DIR/webui/dev/fake_router_server.py")"
CONTRACT_SRC="$(tr -d '\r' < "$REPO_DIR/webui/dev/API_CONTRACT.md")"
WEBUI_SRC_ALL="$(find "$REPO_DIR/webui-src/src" -type f \( -name '*.vue' -o -name '*.ts' \) -exec cat {} + | tr -d '\r')"

assert_contains "$LIB_SH_SRC" '^api_fake_mode_set\(\)' "_lib.sh нет api_fake_mode_set"
assert_contains "$LIB_SH_SRC" '^api_fake_mode_modes_json\(\)' "_lib.sh нет билдера режимов"
assert_contains "$LIB_SH_SRC" '^api_fake_mode_snis_json\(\)' "_lib.sh нет билдера SNI"
assert_contains "$LIB_SH_SRC" 'mode_override_supported_profiles' "api не валидирует профиль"
assert_contains "$LIB_SH_SRC" 'mode_override_clear "\$profile"' "classic не сбрасывает строку"
assert_contains "$LIB_SH_SRC" 'mode_override_set "\$profile" clone' "clone не пишет строку"
assert_contains "$LIB_SH_SRC" '"profile_modes"' "GET/state не отдаёт profile_modes"
assert_contains "$LIB_SH_SRC" '"profile_snis"' "GET/state не отдаёт profile_snis"
assert_contains "$SETTINGS_CGI_SRC" 'fake_mode\)' "settings.cgi не знает fake_mode"

assert_contains "$WEBUI_SRC_ALL" 'fake-mode-form' "webui-src нет формы fake-mode-form"
assert_contains "$WEBUI_SRC_ALL" 'fake-mode-\$\{p\.id\}' "webui-src нет селектов по профилям"
assert_contains "$WEBUI_SRC_ALL" 'profile_modes' "webui-src не читает profile_modes"
assert_contains "$WEBUI_SRC_ALL" 'profile_snis' "webui-src не читает profile_snis"
assert_contains "$WEBUI_SRC_ALL" "setting: 'fake_mode'" "webui-src не зовёт fake_mode"

assert_contains "$FAKE_SRV_SRC" 'def apply_fake_mode' "fake_router_server нет apply_fake_mode"
assert_contains "$FAKE_SRV_SRC" '"profile_modes"' "fake_router_server не отдаёт profile_modes"
assert_contains "$FAKE_SRV_SRC" '"profile_snis"' "fake_router_server не отдаёт profile_snis"
assert_contains "$FAKE_SRV_SRC" 'setting == "fake_mode"' "fake_router_server POST не знает fake_mode"

assert_contains "$CONTRACT_SRC" '`fake_mode`' "API_CONTRACT без fake_mode"
assert_contains "$CONTRACT_SRC" '"profile_modes"' "API_CONTRACT без profile_modes"
assert_contains "$CONTRACT_SRC" '"profile_snis"' "API_CONTRACT без profile_snis"

# --- 3. Хелперы mode_override_* ---------------------------------------------

[ "$(mode_override_supported_profiles | tr '\n' ' ')" = "1 2 3 4 8 " ] \
  || fail "mode_override_supported_profiles != '1 2 3 4 8'"

[ -z "$(mode_override_get 1)" ] || fail "нет строки = пусто (classic)"

mode_override_set 1 clone || fail "mode_override_set не пишет строку"
[ "$(mode_override_get 1)" = "clone" ] || fail "mode_override_get не читает строку"

mode_override_set 1 classic || fail "mode_override_set не перезаписывает строку"
[ "$(mode_override_get 1)" = "classic" ] || fail "upsert не заменил значение"
[ "$(awk 'END {print NR}' "$ORCH_MODE_FILE")" = "1" ] || fail "upsert оставил дубль строки"

mode_override_set 3 clone || fail "set профиль 3"
mode_override_clear 1 || fail "clear профиль 1"
[ -z "$(mode_override_get 1)" ] || fail "clear не удалил строку"
[ "$(mode_override_get 3)" = "clone" ] || fail "clear задел чужую строку"
mode_override_clear 3

# классический ряд (= нет строки) эквивалентен явному classic
mode_override_set 2 classic
mode_override_clear 2
[ -z "$(mode_override_get 2)" ] || fail "clear не убрал явный classic"

# хелпер общий: любой числовой профиль допустим
mode_override_set 99 clone || fail "set отклонил числовой профиль"
mode_override_clear 99
if mode_override_set abc clone 2>/dev/null; then
  fail "set принял нечисловой профиль"
fi
if mode_override_set 1 turbo 2>/dev/null; then
  fail "set принял режим вне clone|classic"
fi
if mode_override_set 1 "" 2>/dev/null; then
  fail "set принял пустой режим"
fi
mode_override_valid clone || fail "valid: clone должен проходить"
mode_override_valid classic || fail "valid: classic должен проходить"
if mode_override_valid Clone; then
  fail "valid: регистр должен учитываться"
fi

ls "$ORCH_DIR" | grep -q '\.tmp\.' && fail "остались .tmp файлы после upsert"

# --- 4. Инвариант: режим не меняет конфиг ------------------------------------

mode_override_set 1 clone
mode_override_set 4 clone
mode_override_clear 1
[ "$(md5sum "$CFG" | cut -d' ' -f1)" = "$cfg_before" ] \
  || fail "mode_override_* изменил живой конфиг (режим обязан быть рантайм-only)"
grep -q -- "--blob=z2r_prof_1:@/opt/zator/files/fake/tls_clienthello_max_ru.bin" "$CFG" \
  || fail "конфиг повреждён (слот z2r_prof_1)"
mode_override_clear 4

echo "fake mode smoke ok"
