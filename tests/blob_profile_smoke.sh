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
printf 'QUICWG' > "$ROOT/files/fake/wg_initial_fake_2.bin"
printf 'DUDP' > "$ROOT/files/fake/discord_udp_1.bin"
printf 'STUN' > "$ROOT/files/fake/stun.bin"

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
ACTIONS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/actions.sh")"
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
assert_contains "$LOCKED_LUa_SRC" 'z2r_blob_override_swap\(profile_key, saved_blob\)' \
  "хук подменяет источники через z2r_blob_override_swap (blob=)"
assert_contains "$LOCKED_LUa_SRC" 'z2r_blob_override_swap\(profile_key, saved_fake_blob\)' \
  "хук подменяет источники через z2r_blob_override_swap (fake_blob=)"
assert_contains "$LOCKED_LUa_SRC" 'Z2R_BLOB_SWAP_TLS = \{ maxru = true, fake_default_tls = true \}' \
  "TLS-источники подмены: maxru|fake_default_tls"
assert_contains "$LOCKED_LUa_SRC" 'Z2R_BLOB_SWAP_QUIC' "нет таблицы QUIC-источников подмены"
assert_contains "$LOCKED_LUa_SRC" 'instance\.arg\.blob = saved_blob' "хук не восстанавливает instance.arg"
assert_contains "$LOCKED_LUa_SRC" 'blob_exist\(desync, name\)' "хук не проверяет объявлено ли имя"
assert_contains "$DETECTOR_SRC" 'blob_override_execute\(desync, verdict, instance, desync\.arg\.key\)' \
  "circular_quality не использует хук"

for p in 1 2 3 4 5 8; do
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

# --- 1b. Живой прогон быстрого парсера GET tls_blob (регрессия PR#83) ------
# off-by-one срезал первую букву имени (z2r_prof_1 -> 2r_prof_1 -> слот не
# находился), значением отдавался полный путь — панель ждёт ИМЯ файла.
(
  eval "$(sed -n '/^api_tls_blob_profile_blobs_json()/,/^}/p' "$REPO_DIR/webui/cgi-bin/_lib.sh")"
  json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  # свой файл переопределений — не трогаем общий ORCH_BLOB_FILE последующих сценариев
  ORCH_BLOB_FILE="$TMP_DIR/blob_override.parser.tsv"
  printf '1\tz2r_prof_1\n2\tfake_default_tls\n4\ttls5\n5\tquic5\n' > "$ORCH_BLOB_FILE"
  cfg="$CFG"
  _pb_out="$(api_tls_blob_profile_blobs_json)"
  [ "$_pb_out" = '"1":"tls_clienthello_max_ru.bin","2":"fake_default_tls","3":"","4":"tls_clienthello_5.bin","5":"quic_5.bin","8":""' ] \
    || fail "api_tls_blob_profile_blobs_json: $_pb_out"
)

assert_contains "$TUTORIAL_SRC" 'Блоб на профиль' "TUTORIAL §8 без раздела про профиль"
assert_contains "$AGENTS_SRC" 'blob_override\.tsv' "AGENTS.md не упоминает blob_override.tsv"

assert_contains "$ACTIONS_SRC" 'blob_files_apply "\$root/config\.default"' \
  "config_apply_from_default не ре-применяет blob_files.tsv"
assert_contains "$Z2R_SRC" 'blob_files_apply "\$ZAPRET2_ROOT/config\.default"' \
  "установочный поток z2r.sh не ре-применяет blob_files.tsv"

z2r_backup_state_files | grep -q 'extra_strats/cache/orchestra/blob_override.tsv' \
  || fail "z2r_backup_state_files не бэкапит blob_override.tsv"
z2r_backup_state_files | grep -q 'extra_strats/cache/orchestra/blob_files.tsv' \
  || fail "z2r_backup_state_files не бэкапит blob_files.tsv"

# --- 2. Хелперы blob_override_* --------------------------------------------

[ "$(blob_override_supported_profiles | tr '\n' ' ')" = "1 2 3 4 5 8 " ] \
  || fail "blob_override_supported_profiles != '1 2 3 4 5 8'"

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
  fail "file_valid: quic-файл не должен проходить без профиля (TLS-режим по умолчанию)"
fi
if blob_override_file_valid tls_missing.bin; then
  fail "file_valid: несуществующий файл не должен проходить"
fi

# --- 2a. QUIC-профиль 5: слот, источники, файлы-кандидаты ---------------------

blob_override_set 5 "$(blob_override_slot 5)" || fail "set профиль 5 (QUIC)"
[ "$(blob_override_name 5)" = "z2r_prof_5" ] || fail "профиль 5 не записался"
[ "$(blob_override_get 5 "$CFG")" = "quic_initial_www_google_com.bin" ] \
  || fail "слот z2r_prof_5 должен раскрываться в quic_initial_www_google_com.bin"
blob_override_clear 5

blob_override_file_valid quic_initial_test.bin 5 || fail "file_valid(5): quic_*.bin должен проходить"
blob_override_file_valid wg_initial_fake_2.bin 5 || fail "file_valid(5): wg_initial_fake_*.bin должен проходить"
blob_override_file_valid discord_udp_1.bin 5 || fail "file_valid(5): discord_udp_*.bin должен проходить"
blob_override_file_valid stun.bin 5 || fail "file_valid(5): stun*.bin должен проходить"
if blob_override_file_valid tls_clienthello_test_a.bin 5; then
  fail "file_valid(5): tls-файл не должен проходить для QUIC-профиля"
fi
if blob_override_file_valid quic_missing.bin 5; then
  fail "file_valid(5): несуществующий файл не должен проходить"
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

# --- 4. Персист выбора блобов (blob_files.tsv) --------------------------------
# Регрессия: выбор блоба жил только в живом конфиге и терялся при 5 -> 7
# (локи из locked.tsv переживали, блобы — нет). Теперь blob_files.tsv —
# источник истины, ре-применяемый во все пути регенерации конфига.

blob_files_set z2r_prof_1 custom_tls.bin || fail "blob_files_set не пишет строку"
[ "$(blob_files_get z2r_prof_1)" = "custom_tls.bin" ] || fail "blob_files_get не читает"
blob_files_set z2r_prof_1 tls_clienthello_test_a.bin || fail "upsert не перезаписал"
[ "$(awk 'END {print NR}' "$ORCH_BLOB_FILES_TSV")" = "1" ] || fail "upsert оставил дубль"
blob_files_clear z2r_prof_1 || fail "blob_files_clear"
[ -z "$(blob_files_get z2r_prof_1)" ] || fail "clear не удалил"
if blob_files_set "bad name" x.bin 2>/dev/null; then fail "set принял имя с пробелом"; fi
if blob_files_set maxru "../etc/passwd" 2>/dev/null; then fail "set принял путь"; fi

# tls_blob_profile_apply_file персистит выбор слота (CLI и WebUI共用)
tls_blob_profile_apply_file "$CFG" 2 custom_tls.bin || fail "apply_file профиль 2"
[ "$(blob_files_get z2r_prof_2)" = "custom_tls.bin" ] \
  || fail "apply_file не записал выбор в blob_files.tsv"

# apply на СВЕЖЕМ config.default (симуляция 5 -> 7): гугловский блоб возвращается
CFG_FRESH="$TMP_DIR/config.fresh"
tr -d '\r' < "$REPO_DIR/config.default" | sed -e "s#/opt/zapret2#$ROOT#g" > "$CFG_FRESH"
blob_files_set maxru custom_tls.bin
blob_files_set z2r_prof_2 tls_clienthello_test_a.bin
blob_files_set z2r_prof_5 quic_initial_test.bin
blob_files_apply "$CFG_FRESH" 2>"$TMP_DIR/blobfiles.err" || fail "blob_files_apply rc!=0"
grep -q -- '--blob=maxru:@/opt/zator/files/fake/custom_tls.bin' "$CFG_FRESH" \
  || fail "apply: глобальный maxru не восстановлен"
grep -q -- '--blob=z2r_prof_2:@/opt/zator/files/fake/tls_clienthello_test_a.bin' "$CFG_FRESH" \
  || fail "apply: слот z2r_prof_2 не восстановлен"
grep -q -- '--blob=z2r_prof_5:@/opt/zator/files/fake/quic_initial_test.bin' "$CFG_FRESH" \
  || fail "apply: слот z2r_prof_5 не восстановлен"

# режим fake_default_tls: ссылки -> fake_default_tls (штатный вид эталона),
# декларация --blob=maxru не трогается (обратное переключение)
blob_files_clear maxru
blob_files_set maxru fake_default_tls
blob_files_apply "$CFG_FRESH" || fail "apply (режим fake_default_tls)"
grep -q -- '--lua-desync=fake:blob=fake_default_tls:tcp_seq=-3000:tcp_ack=-66000:repeats=2:strategy=20' "$CFG_FRESH" \
  || fail "apply: режим fake_default_tls не переключил ссылки"
grep -q -- '--blob=maxru:@/opt/zator/files/fake/custom_tls.bin' "$CFG_FRESH" \
  || fail "apply: декларация maxru не должна меняться в режиме fake_default_tls"

# обратное переключение на файл возвращает режим maxru
blob_files_set maxru custom_tls.bin
blob_files_apply "$CFG_FRESH" || fail "apply (обратно на файл)"
grep -q -- '--lua-desync=fake:blob=maxru:tcp_seq=-3000:tcp_ack=-66000:repeats=2:strategy=20' "$CFG_FRESH" \
  || fail "apply: режим maxru не вернулся"

# отсутствующий файл — пропуск с warning, конфиг не сломан, rc=0
blob_files_set z2r_prof_3 nofile.bin
grep -q -- '--blob=z2r_prof_3:@/opt/zator/files/fake/tls_clienthello_max_ru.bin' "$CFG_FRESH"
before_md5="$(md5sum "$CFG_FRESH" | cut -d' ' -f1)"
blob_files_apply "$CFG_FRESH" 2>"$TMP_DIR/blobfiles2.err" || fail "apply с битым файлом rc!=0"
grep -q 'отсутствует' "$TMP_DIR/blobfiles2.err" || fail "apply: нет warning о битом файле"
after_md5="$(md5sum "$CFG_FRESH" | cut -d' ' -f1)"
[ "$before_md5" = "$after_md5" ] || fail "apply с битым файлом изменил конфиг"
blob_files_clear z2r_prof_3

# имя, которого нет в старом конфиге, молча пропускается
grep -v 'z2r_prof_8' "$CFG_FRESH" > "$TMP_DIR/no8" && mv -f "$TMP_DIR/no8" "$CFG_FRESH"
blob_files_set z2r_prof_8 custom_tls.bin
blob_files_apply "$CFG_FRESH" 2>>"$TMP_DIR/blobfiles2.err" || fail "apply без декларации rc!=0"

ls "$ORCH_DIR" | grep -q '\.tmp\.' && fail "остались .tmp файлы после blob_files"

echo "blob profile smoke ok"
