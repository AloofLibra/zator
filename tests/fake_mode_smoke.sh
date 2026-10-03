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

# --- 1b. Лимит клонов (clonesize.tsv) + кап TLS-фейков 1200 ------------------

assert_contains "$LOCKED_LUA_SRC" 'clonesize\.tsv' "locked.lua не читает clonesize.tsv"
assert_contains "$LOCKED_LUA_SRC" 'function clone_size_parse_line' "locked.lua нет парсера лимита клонов"
assert_contains "$LOCKED_LUA_SRC" 'load_clone_size_file\(CLONESIZE_PATH\)' \
  "load_locked_tables не перезагружает лимиты клонов"
assert_contains "$LOCKED_LUA_SRC" 'size < 64 or size > 1200' \
  "парсер лимита принимает значения вне 64..1200"
assert_contains "$LOCKED_LUA_SRC" 'function locked_load_clone_size_for_tests' "нет тестового сеттера лимитов"
# кап TLS-фейков: только fake/fakemultisplit/fakemultidisorder, не-TLS не трогаем
assert_contains "$LOCKED_LUA_SRC" 'Z2R_TLS_FAKE_LIMIT_MAX = 1200' "нет верхней границы ТСПУ 1200"
assert_contains "$LOCKED_LUA_SRC" 'func == "fake" then return "blob"' "кап не знает fake()"
assert_contains "$LOCKED_LUA_SRC" 'func == "fakemultisplit" or func == "fakemultidisorder" then return "fake_blob"' \
  "кап не знает fake_blob-методы"
assert_contains "$LOCKED_LUA_SRC" 'fname ~= Z2R_CLONE_FIELD' "кап режет уже порезанный клон"
# согласованная резка: группы расширений, сохранение SNI/versions/sig_algs
assert_contains "$LOCKED_LUA_SRC" '\[51\] = true, \[10\] = true, \[11\] = true' \
  "key_share/supported_groups/ec_point_formats не согласованы в одну группу"
assert_contains "$LOCKED_LUA_SRC" '\[0xfe0d\] = true' "ECH не вырезается группой"
assert_contains "$LOCKED_LUA_SRC" '\[45\] = true, \[41\] = true, \[42\] = true' \
  "psk_key_exchange_modes/pre_shared_key/early_data не согласованы"
assert_contains "$LOCKED_LUA_SRC" 'z2r_clone_semantic_cut' "нет согласованной резки клона"
assert_contains "$LOCKED_LUA_SRC" 'z2r_tls_record_cut' "нет сырой резки TLS-рекордов"
assert_contains "$LOCKED_LUA_SRC" 'string\.char\(math\.floor\(space / 256\)\)' \
  "сырая резка не чинит длину последнего рекорда"
# клон живёт только целым: не влез в лимит — штатный блоб (резаный клон ТСПУ
# режет вместе с потоком, живой тест 03.10)
assert_contains "$LOCKED_LUA_SRC" 'using config blob profile=' \
  "превышение лимита клона не откатывается на штатный блоб"

# --- 2. Статический wiring меню и бэкапов -----------------------------------

assert_contains "$SUBMENUS_SRC" '^fake_mode_submenu\(\)' "нет подменю fake_mode_submenu"
assert_contains "$SUBMENUS_SRC" '^fake_mode_profile_pick\(\)' "нет экрана профиля fake_mode_profile_pick"
assert_contains "$SUBMENUS_SRC" 'mode_override_supported_profiles' "подменю не строится по поддерживаемым профилям"
assert_contains "$SUBMENUS_SRC" 'mode_override_set "\$p" clone' "нет включения клонов всем профилям"
assert_contains "$SUBMENUS_SRC" 'mode_override_clear "\$p"' "нет сброса режима всем профилям"
assert_contains "$SUBMENUS_SRC" 'fake_mode_submenu' "tls_blob_submenu не открывает подменю режима"
assert_contains "$SUBMENUS_SRC" 'sni_override_get "\$1"' "экран режима не показывает SNI клона"
# размер клонов: подменю рядом с режимом, лимит виден в экране режима
assert_contains "$SUBMENUS_SRC" '^clone_size_submenu\(\)' "нет подменю clone_size_submenu"
assert_contains "$SUBMENUS_SRC" '^clone_size_profile_pick\(\)' "нет экрана профиля clone_size_profile_pick"
assert_contains "$SUBMENUS_SRC" 'clone_size_supported_profiles' "подменю лимитов не строится по профилям"
assert_contains "$SUBMENUS_SRC" 'clone_size_submenu' "tls_blob_submenu не открывает подменю лимитов"
assert_contains "$SUBMENUS_SRC" 'clone_size_display "\$profile"' "экран режима не показывает лимит клона"

z2r_backup_state_files 2>/dev/null | grep -q 'extra_strats/cache/orchestra/mode_override.tsv' \
  || fail "z2r_backup_state_files не бэкапит mode_override.tsv"
z2r_backup_state_files 2>/dev/null | grep -q 'extra_strats/cache/orchestra/sni_override.tsv' \
  || fail "z2r_backup_state_files не бэкапит sni_override.tsv"
z2r_backup_state_files 2>/dev/null | grep -q 'extra_strats/cache/orchestra/clonesize.tsv' \
  || fail "z2r_backup_state_files не бэкапит clonesize.tsv"
assert_contains "$AGENTS_SRC" 'mode_override\.tsv' "AGENTS.md не упоминает mode_override.tsv"

SUPERSSWEEP_SRC="$(tr -d '\r' < "$REPO_DIR/lib/supersweep.sh")"
assert_contains "$SUPERSSWEEP_SRC" 'size_%s\\t%s' "meta.tsv суперавтопрогона не пишет size_<profile>"
assert_contains "$SUPERSSWEEP_SRC" 'clone_size_get' "meta.tsv не читает clone_size_get"

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
assert_contains "$LIB_SH_SRC" '"profile_sizes"' "GET/state не отдаёт profile_sizes"
assert_contains "$LIB_SH_SRC" '^api_clone_size_set\(\)' "_lib.sh нет api_clone_size_set"
assert_contains "$LIB_SH_SRC" '^api_clone_size_sizes_json\(\)' "_lib.sh нет билдера лимитов"
assert_contains "$LIB_SH_SRC" 'clone_size_valid "\$value"' "api не валидирует размер 64..1200"
assert_contains "$LIB_SH_SRC" 'clone_size_clear "\$profile"' "сброс лимита не удаляет строку"
assert_contains "$SETTINGS_CGI_SRC" 'fake_mode\)' "settings.cgi не знает fake_mode"
assert_contains "$SETTINGS_CGI_SRC" 'clone_size\)' "settings.cgi не знает clone_size"

assert_contains "$WEBUI_SRC_ALL" 'fake-mode-form' "webui-src нет формы fake-mode-form"
assert_contains "$WEBUI_SRC_ALL" 'fake-mode-\$\{p\.id\}' "webui-src нет селектов по профилям"
assert_contains "$WEBUI_SRC_ALL" 'profile_modes' "webui-src не читает profile_modes"
assert_contains "$WEBUI_SRC_ALL" 'profile_snis' "webui-src не читает profile_snis"
assert_contains "$WEBUI_SRC_ALL" 'profile_sizes' "webui-src не читает profile_sizes"
assert_contains "$WEBUI_SRC_ALL" "setting: 'fake_mode'" "webui-src не зовёт fake_mode"
assert_contains "$WEBUI_SRC_ALL" 'clone-size-form' "webui-src нет формы clone-size-form"
assert_contains "$WEBUI_SRC_ALL" 'clone-size-\$\{p\.id\}' "webui-src нет селектов лимитов"
assert_contains "$WEBUI_SRC_ALL" "setting: 'clone_size'" "webui-src не зовёт clone_size"

assert_contains "$FAKE_SRV_SRC" 'def apply_fake_mode' "fake_router_server нет apply_fake_mode"
assert_contains "$FAKE_SRV_SRC" '"profile_modes"' "fake_router_server не отдаёт profile_modes"
assert_contains "$FAKE_SRV_SRC" '"profile_snis"' "fake_router_server не отдаёт profile_snis"
assert_contains "$FAKE_SRV_SRC" '"profile_sizes"' "fake_router_server не отдаёт profile_sizes"
assert_contains "$FAKE_SRV_SRC" 'def apply_clone_size' "fake_router_server нет apply_clone_size"
assert_contains "$FAKE_SRV_SRC" 'setting == "fake_mode"' "fake_router_server POST не знает fake_mode"
assert_contains "$FAKE_SRV_SRC" 'setting == "clone_size"' "fake_router_server POST не знает clone_size"

assert_contains "$CONTRACT_SRC" '`fake_mode`' "API_CONTRACT без fake_mode"
assert_contains "$CONTRACT_SRC" '"profile_modes"' "API_CONTRACT без profile_modes"
assert_contains "$CONTRACT_SRC" '"profile_snis"' "API_CONTRACT без profile_snis"
assert_contains "$CONTRACT_SRC" '`clone_size`' "API_CONTRACT без clone_size"
assert_contains "$CONTRACT_SRC" '"profile_sizes"' "API_CONTRACT без profile_sizes"

# --- 2c. Адаптер дефолтного блоба в сборке (универсальный config.default) ---

CONFIG_SRC="$(tr -d '\r' < "$REPO_DIR/config.default")"
Z2R_SRC="$(tr -d '\r' < "$REPO_DIR/z2r.sh")"

assert_contains "$CONFIG_SRC" '^--lua-init=@/opt/zator/lua/fake-adapt\.lua$' \
  "config.default не подключает адаптер fake-adapt.lua"
[ "$(grep -c '^--lua-init=@/opt/zator/lua/fake-adapt.lua$' "$REPO_DIR/config.default")" -eq 1 ] \
  || fail "config.default: lua-init адаптера дублирован"
assert_contains "$Z2R_SRC" 'FAKE_ADAPT_LUA="\$ZATOR_ROOT/lua/fake-adapt\.lua"' \
  "z2r.sh нет переменной FAKE_ADAPT_LUA"
assert_contains "$Z2R_SRC" 'z2r_download_project_file "\$FAKE_ADAPT_LUA" "lua/fake-adapt\.lua"' \
  "z2r.sh не докачивает fake-adapt.lua"
assert_contains "$Z2R_SRC" 'silent-drop-detector\.lua dns-clone\.lua fake-adapt\.lua strategy-validator\.sh' \
  "миграция z2r.sh не переносит fake-adapt.lua"
assert_contains "$Z2R_SRC" 's#/opt/zapret2/lua/fake-adapt\.lua#/opt/zator/lua/fake-adapt\.lua#g' \
  "миграция z2r.sh не переписывает путь fake-adapt.lua"

# --- 2d. SNI клона: свой домен принимает хитрые URL (нормализация как в диалоге) ---

bash -n "$REPO_DIR/lib/strategies.sh" || fail "bash -n: lib/strategies.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/strategies.sh"
awk '/Домен или ссылка/,/pause_enter/' "$REPO_DIR/lib/submenus.sh" | grep -q 'z2r_normalize_domain' \
  || fail "sni_profile_pick не нормализует свой домен (хитрые URL)"
awk '/Домен или ссылка/,/pause_enter/' "$REPO_DIR/lib/submenus.sh" | grep -q '"\$domain" = "0"' \
  || fail "sni_profile_pick: нет отмены по 0"
for probe in 'https://VK.ru/watch?v=1' 'HTTP://Max.ru:443/path' '  www.Example.COM.  ' 'https://user@hcaptcha.com/x'; do
  d="$(z2r_normalize_domain "$probe")" \
    || fail "нормализация не осилила: $probe"
  sni_override_valid "$d" \
    || fail "после нормализации домен невалиден для SNI: $probe -> $d"
done
[ "$(z2r_normalize_domain 'https://VK.ru/watch?v=1')" = "vk.ru" ] \
  || fail "URL не приводится к домену"
sni_override_set 1 "$(z2r_normalize_domain 'https://VK.ru/watch?v=1')" \
  || fail "sni_override_set не принял нормализованный домен"
[ "$(sni_override_get 1)" = "vk.ru" ] || fail "sni_override: сохранился не домен"
sni_override_clear 1

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

# --- 3b. Хелперы clone_size_* -------------------------------------------------

[ "$(clone_size_supported_profiles | tr '\n' ' ')" = "1 2 3 4 8 " ] \
  || fail "clone_size_supported_profiles != '1 2 3 4 8'"

[ -z "$(clone_size_get 1)" ] || fail "нет строки = пусто (без ограничения)"

if clone_size_set 1 1201 2>/dev/null; then fail "set принял размер > 1200"; fi
if clone_size_set 1 63 2>/dev/null; then fail "set принял размер < 64"; fi
if clone_size_set 1 abc 2>/dev/null; then fail "set принял нечисловой размер"; fi
if clone_size_set abc 512 2>/dev/null; then fail "set принял нечисловой профиль"; fi
clone_size_set 1 964 || fail "set не пишет строку"
[ "$(clone_size_get 1)" = "964" ] || fail "get не читает строку"
clone_size_set 1 512 || fail "set не перезаписал"
[ "$(awk 'END {print NR}' "$ORCH_CLONESIZE_FILE")" = "1" ] || fail "upsert оставил дубль"
clone_size_set 4 1200 || fail "set профиль 4"
clone_size_clear 1 || fail "clear"
[ -z "$(clone_size_get 1)" ] || fail "clear не удалил строку"
[ "$(clone_size_get 4)" = "1200" ] || fail "clear задел чужую строку"
clone_size_clear 4
clone_size_valid 64 || fail "valid: 64 должен проходить"
clone_size_valid 1200 || fail "valid: 1200 должен проходить"
if clone_size_valid 0 2>/dev/null; then fail "valid: 0 не должен проходить"; fi

# --- 4. Инвариант: режим/лимиты не меняют конфиг --------------------------------

mode_override_set 1 clone
mode_override_set 4 clone
mode_override_clear 1
clone_size_set 2 512
clone_size_clear 2
[ "$(md5sum "$CFG" | cut -d' ' -f1)" = "$cfg_before" ] \
  || fail "mode_override_* изменил живой конфиг (режим обязан быть рантайм-only)"
grep -q -- "--blob=z2r_prof_1:@/opt/zator/files/fake/tls_clienthello_max_ru.bin" "$CFG" \
  || fail "конфиг повреждён (слот z2r_prof_1)"
mode_override_clear 4

# --- 5. Временный гейт: клоны Discord включаются только явным согласием -----
# Клоны некорректно работают с Discord (формулировка владельца). Функционал
# не режем: классика->клоны на профиле 4 требует явного «1», массовое
# «Клоны всем» по отказу включает всем, кроме 4.

# shellcheck source=/dev/null
source "$REPO_DIR/lib/submenus.sh"
clear() { :; }
pause_enter() { :; }
telemetry_notify() { :; }
# цветовые глобали диалогов: в z2r.sh их задаёт шапка, под set -u теста
# они должны существовать явно (грабля прошлых сессий)
plain="" red="" green="" yellow="" cyan="" Fgreen="" Fcyan="" Fyellow=""
export plain red green yellow cyan Fgreen Fcyan Fyellow

fm_cleanup_modes() {
  local pp
  for pp in 1 2 3 4 8; do mode_override_clear "$pp" 2>/dev/null || true; done
}

# одиночный экран: отказ (Enter на подтверждении) — режим не меняется
rc5=0
out5="$(printf '2\n\n0\n' | fake_mode_profile_pick 4 "Discord" 2>&1)" || rc5=$?
[ "$rc5" = 0 ] || fail "сценарий 5: диалог профиля 4 упал при отказе"
assert_contains "$out5" "не корректно работают с Discord" "сценарий 5: нет предупреждения про Discord"
[ -z "$(mode_override_get 4)" ] || fail "сценарий 5: отказ должен оставить классику"

# одиночный экран: настаивание (1) — клоны включаются
out5="$(printf '2\n1\n0\n' | fake_mode_profile_pick 4 "Discord" 2>&1)"
assert_contains "$out5" "Профиль 4: клоны" "сценарий 5: подтверждённые клоны не применились"
[ "$(mode_override_get 4)" = "clone" ] || fail "сценарий 5: clone не записан после подтверждения"
fm_cleanup_modes

# другие профили переключаются без предупреждения
out5="$(printf '2\n0\n' | fake_mode_profile_pick 1 "YouTube" 2>&1)"
assert_contains "$out5" "Профиль 1: клоны" "сценарий 5: профиль 1 должен переключиться молча"
if grep -q "не корректно работают с Discord" <<<"$out5"; then
  fail "сценарий 5: предупреждение про Discord показано не для Discord"
fi
[ "$(mode_override_get 1)" = "clone" ] || fail "сценарий 5: профиль 1 не переключился"
fm_cleanup_modes

# массовое «Клоны всем» (пункт 6 при 5 профилях): отказ -> всем, кроме 4
out5="$(printf '6\n\n0\n' | fake_mode_submenu 2>&1)"
assert_contains "$out5" "кроме Discord" "сценарий 5: массовое включение не сообщило про пропуск Discord"
[ "$(mode_override_get 1)" = "clone" ] || fail "сценарий 5: массовое включение не задело профиль 1"
[ "$(mode_override_get 8)" = "clone" ] || fail "сценарий 5: массовое включение не задело профиль 8"
[ -z "$(mode_override_get 4)" ] || fail "сценарий 5: массовое включение не должно трогать Discord без согласия"

# массовое «Клоны всем» с согласием -> включая Discord
out5="$(printf '6\n1\n0\n' | fake_mode_submenu 2>&1)"
[ "$(mode_override_get 4)" = "clone" ] || fail "сценарий 5: согласие должно включить клоны и для Discord"
fm_cleanup_modes

echo "fake mode smoke ok"
