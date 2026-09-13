#!/usr/bin/env bash

# Тест per-profile TLS blob: blob_override.tsv (lib/orchestra_state.sh), sed слота
# (lib/actions.sh), хук в locked.lua/combined-detector.lua, wiring CLI/WebUI.
# Работает только во временной директории в /tmp: не пишет в /opt, не запускает
# настоящий zapret2.

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

TMP_DIR="$(mktemp -d /tmp/zator-blob-profile.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT="$TMP_DIR/zapret2"   # играет роль и /opt/zapret2, и /opt/zator
CFG="$ROOT/config"
export ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export ZATOR_ROOT="$ROOT"
export ZAPRET2_ROOT="$ROOT"
export Z2R_BLOB_FAKE_DIR="$ROOT/files/fake"

mkdir -p "$ORCH_DIR" "$ROOT/files/fake"
# /opt/zator НЕ подменяем: blob_override_get/tls_blob_profile_apply_file работают с
# каноническими путями деклараций.
tr -d '\r' < "$REPO_DIR/config.default" | sed -e "s#/opt/zapret2#$ROOT#g" > "$CFG"
printf 'FAKE1' > "$ROOT/files/fake/tls_clienthello_test_a.bin"
printf 'FAKE2' > "$ROOT/files/fake/custom_tls.bin"
printf 'QUIC' > "$ROOT/files/fake/quic_initial_test.bin"

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

# --- 1. Статический wiring --------------------------------------------------

LOCKED_LUa_SRC="$(tr -d '\r' < "$REPO_DIR/orchestra/locked.lua")"
DETECTOR_SRC="$(tr -d '\r' < "$REPO_DIR/lua/combined-detector.lua")"
CONFIG_SRC="$(tr -d '\r' < "$REPO_DIR/config.default")"
SUBMENUS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/submenus.sh")"
Z2R_SRC="$(tr -d '\r' < "$REPO_DIR/z2r.sh")"
LIB_SH_SRC="$(tr -d '\r' < "$REPO_DIR/webui/cgi-bin/_lib.sh")"
SETTINGS_CGI_SRC="$(tr -d '\r' < "$REPO_DIR/webui/cgi-bin/settings.cgi")"
FAKE_SRV_SRC="$(tr -d '\r' < "$REPO_DIR/webui/dev/fake_router_server.py")"
WEBUI_SRC_ALL="$(find "$REPO_DIR/webui-src/src" -type f \( -name '*.vue' -o -name '*.ts' \) -exec cat {} + | tr -d '\r')"
TUTORIAL_SRC="$(tr -d '\r' < "$REPO_DIR/docs/TUTORIAL.md")"
AGENTS_SRC="$(tr -d '\r' < "$REPO_DIR/AGENTS.md")"

assert_contains "$LOCKED_LUa_SRC" 'blob_override\.tsv' "locked.lua не читает blob_override.tsv"
assert_contains "$LOCKED_LUa_SRC" 'function blob_override_execute' "locked.lua нет blob_override_execute"
assert_contains "$LOCKED_LUa_SRC" 'blob_override_execute\(desync, verdict, instance, base_profile\)' \
  "circular_locked не передаёт base_profile в хук"
assert_contains "$LOCKED_LUa_SRC" 'saved_blob == "maxru" or saved_blob == "fake_default_tls"' \
  "хук подменяет только maxru|fake_default_tls"
assert_contains "$LOCKED_LUa_SRC" 'instance\.arg\.blob = saved_blob' "хук не восстанавливает instance.arg"
assert_contains "$LOCKED_LUa_SRC" 'blob_exist\(desync, name\)' "хук не проверяет объявлено ли имя"
assert_contains "$DETECTOR_SRC" 'blob_override_execute\(desync, verdict, instance, desync\.arg\.key\)' \
  "circular_quality не использует хук"

for p in 1 2 3 4 8; do
  assert_contains "$CONFIG_SRC" "^--blob=z2r_prof_${p}:@/opt/zator/files/fake/" \
    "config.default не объявляет слот z2r_prof_${p}"
done

assert_contains "$SUBMENUS_SRC" '^tls_blob_submenu\(\)' "нет подменю tls_blob_submenu"
assert_contains "$SUBMENUS_SRC" '^tls_blob_profile_pick\(\)' "нет экрана профиля tls_blob_profile_pick"
assert_contains "$SUBMENUS_SRC" 'blob_override_slot' "подменю не использует blob_override_slot"
assert_contains "$Z2R_SRC" '"16"\)[[:space:]]*$' "z2r.sh: пункт 16 потерян"
assert_contains "$Z2R_SRC" 'tls_blob_submenu' "z2r.sh: п.16 не открывает подменю"

assert_contains "$LIB_SH_SRC" 'api_tls_blob_profile_set' "_lib.sh нет api_tls_blob_profile_set"
assert_contains "$LIB_SH_SRC" 'blob_override_file_valid' "api не валидирует файл"
assert_contains "$LIB_SH_SRC" '"profile_blobs"' "GET не отдаёт profile_blobs"
assert_contains "$SETTINGS_CGI_SRC" 'tls_blob_profile' "settings.cgi не знает tls_blob_profile"

assert_contains "$WEBUI_SRC_ALL" 'tls-blob-profile-form' "webui-src нет формы tls-blob-profile-form"
assert_contains "$WEBUI_SRC_ALL" 'tls-blob-profile-\$\{p\.id\}' "webui-src нет селектов по профилям"
assert_contains "$WEBUI_SRC_ALL" "id: '4'" "webui-src в PROFILE_ITEMS нет профиля 4 (Discord)"
assert_contains "$WEBUI_SRC_ALL" "id: '8'" "webui-src в PROFILE_ITEMS нет профиля 8"
assert_contains "$WEBUI_SRC_ALL" 'tls_blob_profile' "webui-src не зовёт tls_blob_profile"

assert_contains "$FAKE_SRV_SRC" 'def apply_tls_blob_profile' "fake_router_server нет apply_tls_blob_profile"
assert_contains "$FAKE_SRV_SRC" '"profile_blobs"' "fake_router_server не отдаёт profile_blobs"

assert_contains "$TUTORIAL_SRC" 'Блоб на профиль' "TUTORIAL §8 без раздела про профиль"
assert_contains "$AGENTS_SRC" 'blob_override\.tsv' "AGENTS.md не упоминает blob_override.tsv"

z2r_backup_state_files | grep -q 'extra_strats/cache/orchestra/blob_override.tsv' \
  || fail "z2r_backup_state_files не бэкапит blob_override.tsv"

# --- 2. Хелперы blob_override_* --------------------------------------------

[ "$(blob_override_supported_profiles | tr '\n' ' ')" = "1 2 3 4 8 " ] \
  || fail "blob_override_supported_profiles != '1 2 3 4 8'"

blob_override_set 2 fake_default_tls || fail "blob_override_set не пишет строку"
[ "$(blob_override_name 2)" = "fake_default_tls" ] || fail "blob_override_name не читает строку"
[ "$(blob_override_get 2 "$CFG")" = "fake_default_tls" ] \
  || fail "get: встроенный блоб должен отдаваться как есть"

blob_override_set 2 "$(blob_override_slot 2)" || fail "blob_override_set не перезаписывает строку"
[ "$(blob_override_name 2)" = "z2r_prof_2" ] || fail "upsert не заменил значение"
[ "$(awk 'END {print NR}' "$ORCH_BLOB_FILE")" = "1" ] || fail "upsert оставил дубль строки"
[ "$(blob_override_get 2 "$CFG")" = "tls_clienthello_max_ru.bin" ] \
  || fail "get: слот должен раскрываться в файл из декларации"

blob_override_set 1 fake_default_tls || fail "set профиль 1"
blob_override_clear 2 || fail "clear профиль 2"
[ -z "$(blob_override_name 2)" ] || fail "clear не удалил строку"
[ "$(blob_override_name 1)" = "fake_default_tls" ] || fail "clear задел чужую строку"
blob_override_clear 1

# Хелпер общий (как orch_locked_set): любой числовой профиль допустим, имя — [%w_]+.
# Ограничение «только 1/2/3/8» живёт в api_tls_blob_profile_set и подменю.
blob_override_set 99 "$(blob_override_slot 99)" || fail "set отклонил числовой профиль"
blob_override_clear 99
if blob_override_set abc z2r_prof_1 2>/dev/null; then
  fail "set принял нечисловой профиль"
fi
if blob_override_set 1 'bad name!' 2>/dev/null; then
  fail "set принял имя с пробелами"
fi

blob_override_file_valid tls_clienthello_test_a.bin || fail "file_valid: tls_*.bin должен проходить"
blob_override_file_valid custom_tls.bin || fail "file_valid: custom_tls.bin должен проходить"
if blob_override_file_valid quic_initial_test.bin; then
  fail "file_valid: quic-файл не должен проходить"
fi
if blob_override_file_valid tls_missing.bin; then
  fail "file_valid: несуществующий файл не должен проходить"
fi

ls "$ORCH_DIR" | grep -q '\.tmp\.' && fail "остались .tmp файлы после upsert"

# --- 3. sed слота z2r_prof_N ------------------------------------------------

tls_blob_profile_apply_file "$CFG" 1 tls_clienthello_test_a.bin \
  || fail "tls_blob_profile_apply_file не применился к конфигу со слотом"
grep -q -- "--blob=z2r_prof_1:@/opt/zator/files/fake/tls_clienthello_test_a.bin" "$CFG" \
  || fail "путь слота z2r_prof_1 не переписан"

CFG_NO_SLOT="$TMP_DIR/config.no_slot"
grep -v 'z2r_prof_3' "$CFG" > "$CFG_NO_SLOT"
if tls_blob_profile_apply_file "$CFG_NO_SLOT" 3 tls_clienthello_test_a.bin; then
  fail "apply_file должен отказывать без декларации слота"
fi

echo "blob profile smoke ok"
