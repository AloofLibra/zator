#!/usr/bin/env bash

# Тест пользовательских блобов (lib/custom_blobs.sh + blobs.cgi): валидация
# имён/файлов, TSV CRUD, переименование с правкой ссылок в «Своих стратегиях»,
# инжект деклараций --blob= между #Z2R_CUSTOM_BLOBS_BEGIN/END (маркеры на старых
# конфигах, идемпотентность), загрузка файлов, бэкап-раунд, статический wiring
# (z2r.sh/lib/config.default/панель). Только временная директория в /tmp.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local text="$1" pattern="$2" message="$3"
  grep -Eq -- "$pattern" <<<"$text" || fail "$message"
}

TMP_DIR="$(mktemp -d /tmp/zator-custom-blobs.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT="$TMP_DIR/zapret2"   # играет роль и /opt/zapret2, и /opt/zator
CFG="$ROOT/config"
export ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export ZATOR_ROOT="$ROOT"
export ZAPRET2_ROOT="$ROOT"
export CUSTOM_STRATS_FILE="$ORCH_DIR/custom_strategies.tsv"
export CUSTOM_BLOBS_FILE="$ORCH_DIR/custom_blobs.tsv"

mkdir -p "$ORCH_DIR" "$ROOT/files/fake/custom_blob"
tr -d '\r' < "$REPO_DIR/config.default" | sed -e "s#/opt/zapret2#$ROOT#g" > "$CFG"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/actions.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/ui.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/custom_strategies.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/custom_blobs.sh"

# --- 0. Синтаксис -------------------------------------------------------------

for f in lib/custom_blobs.sh lib/custom_strategies.sh lib/actions.sh \
         webui/cgi-bin/blobs.cgi webui/cgi-bin/_lib.sh z2r.sh; do
  bash -n "$REPO_DIR/$f" || fail "bash -n: $f"
done

# --- 1. Статический wiring ----------------------------------------------------

Z2R_SRC="$(tr -d '\r' < "$REPO_DIR/z2r.sh")"
ACTIONS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/actions.sh")"
CONFIG_SRC="$(tr -d '\r' < "$REPO_DIR/config.default")"
BLOBS_CGI_SRC="$(tr -d '\r' < "$REPO_DIR/webui/cgi-bin/blobs.cgi")"
LIB_SRC="$(tr -d '\r' < "$REPO_DIR/webui/cgi-bin/_lib.sh")"

assert_contains "$Z2R_SRC" 'Z2R_LIB_FILES=.*custom_blobs\.sh' \
  "z2r.sh: custom_blobs.sh не в Z2R_LIB_FILES"
assert_contains "$Z2R_SRC" '^source "\$LIB_DIR/custom_blobs\.sh"' \
  "z2r.sh нет явного source custom_blobs.sh"
assert_contains "$Z2R_SRC" 'custom_blobs_apply_file "\$ZAPRET2_ROOT/config\.default"' \
  "установочный поток z2r.sh не инжектит пользовательские блобы"
assert_contains "$Z2R_SRC" 'webui_repo_fetch "cgi-bin/blobs\.cgi"' \
  "z2r.sh: blobs.cgi не в webui_install_files (raw-установки останутся без него)"
assert_contains "$ACTIONS_SRC" 'custom_blobs_apply_file "\$root/config\.default"' \
  "config_apply_from_default не переинжектит пользовательские блобы"
assert_contains "$ACTIONS_SRC" 'custom_blobs\.tsv' \
  "z2r_backup_state_files не бэкапит custom_blobs.tsv"
assert_contains "$ACTIONS_SRC" 'files/fake/custom_blob' \
  "z2r_backup_state_files не бэкапит каталог custom_blob"
assert_contains "$LIB_SRC" 'custom_blobs\.sh' \
  "_lib.sh не source-ит custom_blobs.sh"
for m in BEGIN END; do
  assert_contains "$CONFIG_SRC" "^#Z2R_CUSTOM_BLOBS_${m}\$*" "config.default нет маркера BLOBS $m"
done
for act in add edit delete apply; do
  assert_contains "$BLOBS_CGI_SRC" "$act)" "blobs.cgi нет действия $act"
done
assert_contains "$BLOBS_CGI_SRC" '\*action=upload\*' "blobs.cgi нет действия upload"

z2r_backup_state_files | grep -q '^extra_strats/cache/orchestra/custom_blobs\.tsv$' \
  || fail "z2r_backup_state_files не отдаёт custom_blobs.tsv"
z2r_backup_state_files | grep -q '^files/fake/custom_blob$' \
  || fail "z2r_backup_state_files не отдаёт files/fake/custom_blob"

# --- 2. Валидация имён и файлов -----------------------------------------------

custom_blobs_name_wellformed my_fake_tls || fail "wellformed: my_fake_tls должен проходить"
custom_blobs_name_wellformed _priv || fail "wellformed: _priv должен проходить"
custom_blobs_name_wellformed my2 || fail "wellformed: my2 должен проходить"
custom_blobs_name_wellformed 2fast 2>/dev/null && fail "wellformed: 2fast должен падать"
custom_blobs_name_wellformed 0xdeadbeef 2>/dev/null && fail "wellformed: 0x… должен падать"
custom_blobs_name_wellformed "my fake" 2>/dev/null && fail "wellformed: пробел должен падать"
custom_blobs_name_wellformed "$(printf 'a%.0s' {1..40})" 2>/dev/null && fail "wellformed: >32 символов должен падать"

custom_blobs_file_wellformed my_fake.bin || fail "file: my_fake.bin должен проходить"
custom_blobs_file_wellformed my_fake 2>/dev/null || fail "file: без расширения должен проходить"
custom_blobs_file_wellformed ../evil.bin 2>/dev/null && fail "file: .. должен падать"
custom_blobs_file_wellformed "sub/dir.bin" 2>/dev/null && fail "file: путь должен падать"
custom_blobs_file_wellformed "" 2>/dev/null && fail "file: пусто должно падать"

if custom_blobs_validate_name maxru "$CFG" 2>/dev/null; then
  fail "validate: штатное имя maxru должно падать"
fi
if custom_blobs_validate_name clone_vk 2>/dev/null; then
  fail "validate: builtin clone_vk должен падать"
fi

# --- 3. Загрузка файлов --------------------------------------------------------

printf 'FAKEBLOB1' > "$TMP_DIR/up1.bin"
custom_blobs_upload_file "$TMP_DIR/up1.bin" my_fake.bin || fail "upload: валидная загрузка"
[ -f "$ROOT/files/fake/custom_blob/my_fake.bin" ] || fail "upload: файла нет в custom_blob/"
if custom_blobs_upload_file "$TMP_DIR/up1.bin" "sub/dir.bin" 2>/dev/null; then
  fail "upload: путь должен падать"
fi
if custom_blobs_upload_file "$TMP_DIR/up1.bin" ".hidden" 2>/dev/null; then
  fail "upload: имя с точки должно падать"
fi
head -c 262145 /dev/zero > "$TMP_DIR/big.bin" 2>/dev/null || printf 'x%.0s' $(seq 1 262145) > "$TMP_DIR/big.bin"
if custom_blobs_upload_file "$TMP_DIR/big.bin" big.bin 2>/dev/null; then
  fail "upload: >256 КиБ должен падать"
fi

# --- 4. TSV CRUD + ссылки ------------------------------------------------------

id1="$(custom_blobs_add my_fake my_fake.bin 'мой фейк')" || fail "add: валидная запись"
[ "$id1" = "1" ] || fail "add: первый id = 1"
if custom_blobs_add my_fake my_fake.bin 2>/dev/null; then
  fail "add: дублирование имени должно падать"
fi
printf 'FAKEBLOB2' > "$ROOT/files/fake/custom_blob/second.bin"
id2="$(custom_blobs_add second second.bin)" || fail "add: вторая запись"
if custom_blobs_add nosuch nosuchfile.bin 2>/dev/null; then
  fail "add: несуществующий файл должен падать"
fi

# ссылка в пользовательской стратегии: только точное значение блоб-ключей
printf '%s\t%s\t%s\t%s\t%s\t%s\n' 1 tpl \
  'multisplit:blob=my_fake:tcp_md5:pos=2:nodrop --lua-desync=fakeddisorder:pos=midsld:pattern=my_fake:nofake3' \
  1 'тест' '' >> "$CUSTOM_STRATS_FILE"
[ "$(custom_strategies_blob_ref_rows my_fake)" = "1" ] \
  || fail "ref_rows: одна запись с my_fake (получено $(custom_strategies_blob_ref_rows my_fake))"
[ "$(custom_strategies_blob_ref_rows second)" = "0" ] \
  || fail "ref_rows: second не должен иметь ссылок"

if custom_blobs_delete 1 2>/dev/null; then
  fail "delete: блоб со ссылками должен отказывать"
fi

# --- 5. Переименование с правкой стратегий ------------------------------------

custom_blobs_replace 1 renamed_fake my_fake.bin 'переименован' || fail "replace: переименование"
awk -F '\t' '$1==1 {exit !($2=="renamed_fake")}' "$CUSTOM_BLOBS_FILE" \
  || fail "replace: имя не обновлено"
awk -F '\t' '$1==1 {exit !($3 ~ /blob=renamed_fake:tcp_md5/ && $3 ~ /pattern=renamed_fake:nofake3/)}' "$CUSTOM_STRATS_FILE" \
  || fail "rename: ссылки в стратегиях не переписаны"

# замена не задевает похожие имена и литералы
printf '%s\t%s\t%s\t%s\t%s\t%s\n' 2 tpl \
  'tls_client_hello_clone:blob=renamed_fake:fallback=maxru --lua-desync=fake:blob=0x00:repeats=2 --lua-desync=multisplit:blob=xrenamed_fake:pos=2' \
  1 '' '' >> "$CUSTOM_STRATS_FILE"
custom_blobs_replace 1 third_fake my_fake.bin '' || fail "replace: второе переименование"
awk -F '\t' '$1==2 {exit !($3 ~ /blob=third_fake:fallback=maxru/ && $3 ~ /fake:blob=0x00:repeats=2/ && $3 ~ /blob=xrenamed_fake/)}' "$CUSTOM_STRATS_FILE" \
  || fail "rename: задеты чужие имена или литералы"

# --- 6. Инжект -----------------------------------------------------------------

custom_blobs_apply_file "$CFG" || fail "apply: rc!=0"
awk '/^#Z2R_CUSTOM_BLOBS_BEGIN$/ {inb=1; next} /^#Z2R_CUSTOM_BLOBS_END$/ {inb=0}
     inb && /^--blob=third_fake:@/ {n++}
     inb && /^--blob=second:@/ {m++}
     END {exit !(n==1 && m==1)}' "$CFG" \
  || fail "apply: декларации не между маркерами"
grep -q -- '--blob=third_fake:@'"$ROOT"'/files/fake/custom_blob/my_fake.bin' "$CFG" \
  || fail "apply: строка декларации не совпала"
# маркеры стоят выше --template
awk '/^#Z2R_CUSTOM_BLOBS_END$/ {end=NR}
     /^--template=z2r_tcp_tls_common/ && !tpl {tpl=NR}
     END {exit !(end && tpl && end < tpl)}' "$CFG" \
  || fail "apply: маркеры должны быть выше --template"

md5a="$(md5sum "$CFG" | cut -d' ' -f1)"
custom_blobs_apply_file "$CFG" || fail "apply: второй прогон"
md5b="$(md5sum "$CFG" | cut -d' ' -f1)"
[ "$md5a" = "$md5b" ] || fail "apply: не идемпотентен"

# --- 7. Маркеры в конфиге без них (старые установки) ---------------------------

CFG_NOM="$TMP_DIR/config.nomarkers"
tr -d '\r' < "$REPO_DIR/config.default" | sed -e "s#/opt/zapret2#$ROOT#g" \
  | grep -v '^#Z2R_CUSTOM_BLOBS_' > "$CFG_NOM"
custom_blobs_apply_file "$CFG_NOM" || fail "apply без маркеров: rc!=0"
grep -qxF '#Z2R_CUSTOM_BLOBS_BEGIN' "$CFG_NOM" || fail "ensure: нет BEGIN"
grep -qxF '#Z2R_CUSTOM_BLOBS_END' "$CFG_NOM" || fail "ensure: нет END"
grep -q -- '--blob=third_fake:@' "$CFG_NOM" || fail "ensure: декларация не вставлена"

# --- 8. Удаление и уплотнение --------------------------------------------------

custom_blobs_delete 2 || fail "delete: блоб без ссылок"
[ "$(custom_blobs_count)" = "1" ] || fail "delete: count != 1"
[ ! -f "$ROOT/files/fake/custom_blob/second.bin" ] || fail "delete: файл не удалён"

# --- 9. Бэкап-раунд ------------------------------------------------------------

export Z2R_BACKUP_DIR="$TMP_DIR/backups"
mkdir -p "$Z2R_BACKUP_DIR"
backup_create_core >/dev/null || fail "backup_create_core"
ARCHIVE="$(ls -1t "$Z2R_BACKUP_DIR"/z2r_backup_*.tar 2>/dev/null | head -n1)"
[ -n "$ARCHIVE" ] || fail "архив бэкапа не создан"
TAR_BIN="$(z2r_pick_tar)"
"$TAR_BIN" -tf "$ARCHIVE" | grep -q 'custom_blobs.tsv' || fail "custom_blobs.tsv не в архиве"
"$TAR_BIN" -tf "$ARCHIVE" | grep -q 'custom_blob/my_fake.bin' || fail "файл блоба не в архиве"
"$TAR_BIN" -tf "$ARCHIVE" | grep -q 'custom_blob/second.bin' && \
  fail "удалённый файл блоба не должен быть в архиве"

# --- 10. CLI-подменю (п.16 -> «Свои блобы») ------------------------------------
# Статический wiring: пункт в tls_blob_submenu + диспетч-case.
SUBMENUS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/submenus.sh")"
assert_contains "$SUBMENUS_SRC" 'Свои блобы — декларации --blob= \(custom_blob\)' \
  "п.16: нет пункта «Свои блобы»"
assert_contains "$SUBMENUS_SRC" 'custom_blobs_submenu' "п.16: пункт не открывает custom_blobs_submenu"

# Сквозной прогон подменю на поданном stdin под set -e.
clear() { :; }
cyan=""; plain=""; green=""; red=""; yellow=""; Fcyan=""; Fyellow=""; Fgreen=""; Fpink=""

_blobs_submenu_drive() { # stdin; результаты в REPLY_OUT/REPLY_ERR/REPLY_RC
  local input="$1" out rc=0
  out="$(set -e; printf '%s' "$input" | custom_blobs_submenu 2>"$TMP_DIR/cb.err")" || rc=$?
  REPLY_OUT="$out"; REPLY_ERR="$(cat "$TMP_DIR/cb.err")"; REPLY_RC=$rc
}

# добавление: файл 1, имя по умолчанию (Enter), комментарий (Enter)
# (сообщения верхнеуровневого подменю печатаются в stdout)
printf 'BKDATA' > "$ROOT/files/fake/custom_blob/cli_test.bin"
_blobs_submenu_drive $'1\n1\n\n\n'
[ "$REPLY_RC" = "0" ] || fail "CLI п.16: rc=$REPLY_RC на добавлении"
grep -qF 'Добавлено' <<<"$REPLY_OUT" || fail "CLI п.16: нет «Добавлено»"
awk -F '\t' '$2=="cli_test" {exit !($3=="cli_test.bin")}' "$CUSTOM_BLOBS_FILE" \
  || fail "CLI п.16: декларация cli_test не добавлена"

# ссылка из пользовательской стратегии + переименование через подменю
# (cli_test — id 2: id 1 занят third_fake из секции 8)
custom_strategies_add tpl 'fake:blob=cli_test:tcp_seq=-3000' 'ссылка' >/dev/null \
  || fail "CLI п.16: не добавлена тестовая стратегия"
_blobs_submenu_drive $'2\n2\ncli_renamed\n\n\n'
grep -qF 'обновлены' <<<"$REPLY_OUT" || fail "CLI п.16: переименование не отозвалось в стратегиях"
awk -F '\t' '$3 ~ /blob=cli_renamed/ {found=1} END {exit !found}' "$CUSTOM_STRATS_FILE" \
  || fail "CLI п.16: ссылка в стратегии не переписана"

# удаление используемого блоба отказывает
_blobs_submenu_drive $'3\n2\n'
grep -qF 'используется' <<<"$REPLY_OUT" \
  || fail "CLI п.16: удаление используемого блоба должно отказывать"

# отмена на выборе файла/записи и выход
_blobs_submenu_drive $'1\n0\n'
grep -qF 'Неверный ввод' <<<"$REPLY_ERR" \
  && fail "CLI п.16: 0 на выборе файла должен отменять"
_blobs_submenu_drive $'2\n0\n'
grep -qF 'Неверный ввод' <<<"$REPLY_ERR" \
  && fail "CLI п.16: 0 на выборе записи должен отменять"
_blobs_submenu_drive $'0\n'
[ "$REPLY_RC" = "0" ] || fail "CLI п.16: rc=$REPLY_RC на выходе"

# применение к конфигу (без рестарта)
_blobs_submenu_drive $'4\n\n'
[ "$REPLY_RC" = "0" ] || fail "CLI п.16: rc=$REPLY_RC на apply"
grep -q -- '--blob=cli_renamed:@'"$ROOT"'/files/fake/custom_blob/cli_test.bin' "$CFG" \
  || fail "CLI п.16: декларация не в конфиге после apply"

unset -f clear

echo "custom blobs smoke ok"
