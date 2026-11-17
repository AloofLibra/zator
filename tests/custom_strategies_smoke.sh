#!/usr/bin/env bash

# Тест кастомных пользовательских стратегий (lib/custom_strategies.sh):
# нормализация/валидация, TSV CRUD, инжект в конфиг (маркеры, номера после
# максимума блока, идемпотентность), ремап локов при смещении номеров,
# бэкап-список, wiring меню/хуков. Работает только во временной директории
# в /tmp: не пишет в /opt, не запускает настоящий zapret2.

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

TMP_DIR="$(mktemp -d /tmp/zator-custom-strats.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT="$TMP_DIR/zapret2"   # играет роль и /opt/zapret2, и /opt/zator
CFG="$ROOT/config"
export ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export ZATOR_ROOT="$ROOT"
export ZAPRET2_ROOT="$ROOT"
export Z2R_BLOB_FAKE_DIR="$ROOT/files/fake"
export CUSTOM_STRATS_FILE="$ORCH_DIR/custom_strategies.tsv"

mkdir -p "$ORCH_DIR" "$ROOT/files/fake"
tr -d '\r' < "$REPO_DIR/config.default" | sed -e "s#/opt/zapret2#$ROOT#g" > "$CFG"
printf 'WGFAKE' > "$ROOT/files/fake/wg_initial_fake_2.bin"

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

# --- 0. Синтаксис -------------------------------------------------------------

for f in lib/custom_strategies.sh lib/actions.sh lib/submenus.sh z2r.sh; do
  bash -n "$REPO_DIR/$f" || fail "bash -n: $f"
done

# --- 1. Статический wiring ----------------------------------------------------

CUSTOM_SRC="$(tr -d '\r' < "$REPO_DIR/lib/custom_strategies.sh")"
CONFIG_SRC="$(tr -d '\r' < "$REPO_DIR/config.default")"
Z2R_SRC="$(tr -d '\r' < "$REPO_DIR/z2r.sh")"
ACTIONS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/actions.sh")"
SUBMENUS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/submenus.sh")"
LOCKED_LUA_SRC="$(tr -d '\r' < "$REPO_DIR/orchestra/locked.lua")"

assert_contains "$Z2R_SRC" 'Z2R_LIB_FILES=.*custom_strategies\.sh' \
  "z2r.sh не source-ит custom_strategies.sh"
# Z2R_LIB_FILES проверяет только наличие файлов: сами либы сорсятся явными
# source-строками — без неё пункт 14 падает в «модуль недоступен» (живой кейс ВМ).
assert_contains "$Z2R_SRC" '^source "\$LIB_DIR/custom_strategies\.sh"' \
  "z2r.sh нет явного source custom_strategies.sh (п.14 будет «модуль недоступен»)"
for blk in TPL P4 P5 P6 P7; do
  assert_contains "$CONFIG_SRC" "^#Z2R_CUSTOM_${blk}_BEGIN" "config.default нет маркера BEGIN $blk"
  assert_contains "$CONFIG_SRC" "^#Z2R_CUSTOM_${blk}_END" "config.default нет маркера END $blk"
done
assert_contains "$ACTIONS_SRC" 'config_apply_from_default\(\)' "нет config_apply_from_default"
assert_contains "$ACTIONS_SRC" 'custom_strategies_apply_file "\$root/config\.default"' \
  "config_apply_from_default не переинжектит кастомные стратегии"
assert_contains "$Z2R_SRC" 'custom_strategies_apply_file "\$ZAPRET2_ROOT/config\.default"' \
  "установочный поток z2r.sh не инжектит кастомные стратегии"
assert_contains "$ACTIONS_SRC" 'extra_strats/cache/orchestra/custom_strategies\.tsv' \
  "z2r_backup_state_files не бэкапит custom_strategies.tsv"
assert_contains "$SUBMENUS_SRC" 'submenu_item "14" "Кастомные стратегии пользователя"' \
  "подменю стратегий без пункта 14"
assert_contains "$SUBMENUS_SRC" 'custom_strategies_submenu' "пункт 14 не открывает подменю"

z2r_backup_state_files | grep -q 'extra_strats/cache/orchestra/custom_strategies.tsv' \
  || fail "z2r_backup_state_files не отдаёт custom_strategies.tsv"

# --- 2. Нормализация ----------------------------------------------------------

n="$(custom_strategies_normalize \
  '--lua-desync=fake:blob=fakewgblob:ipfrag:ipfrag_pos_udp=8:ipfrag_disorder:repeats=3:out_range=-d10:strategy=33')"
[ "$n" = "fake:blob=fakewgblob:ipfrag:ipfrag_pos_udp=8:ipfrag_disorder:repeats=3:out_range=-d10" ] \
  || fail "normalize: суффикс :strategy=33 не срезан ($n)"

n="$(custom_strategies_normalize \
  'fake:blob=stun_fake:repeats=3:strategy=1 --lua-desync=fake:blob=discord_fake:repeats=3:strategy=1')"
[ "$n" = "fake:blob=stun_fake:repeats=3 --lua-desync=fake:blob=discord_fake:repeats=3" ] \
  || fail "normalize: комбо-группы обработаны неверно ($n)"

if custom_strategies_normalize 'fake:blob=x:strategy=5:repeats=2' >/dev/null 2>&1; then
  fail "normalize: strategy= в середине группы должен давать ошибку"
fi

# --- 3. Валидация -------------------------------------------------------------

custom_strategies_validate p5 \
  'fake:blob=fakewgblob:ipfrag:ipfrag_pos_udp=8:ipfrag_disorder:repeats=3:out_range=-d10' \
  || fail "validate: пример QUIC fakewgblob должен проходить"
custom_strategies_validate p5 \
  'fake:blob=fakewgblob:ipfrag:ipfrag_pos_udp=16:ipfrag_disorder:repeats=1:out_range=-d10' \
  || fail "validate: второй пример QUIC должен проходить"
custom_strategies_validate tpl \
  'multidisorder:pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1' \
  || fail "validate: пример TLS multidisorder должен проходить"
custom_strategies_validate tpl \
  'fake:blob=stun_fake:badsum:repeats=2 --lua-desync=fake:blob=fake_default_tls:badsum:repeats=2' \
  || fail "validate: комбо-стратегия с двумя группами должна проходить"
custom_strategies_validate p6 \
  'udplen:increment=4:min=20 --lua-desync=fake:blob=0x00:repeats=2:out_range=-d10' \
  || fail "validate: комбо udplen+fake с hex-литералом должна проходить"
custom_strategies_validate p7 'send:repeats=2:ip_autottl=1,3-20' \
  || fail "validate: send с диапазоном autottl должен проходить"
custom_strategies_validate p4 'fake:ip_id=zero:blob=fakewgblob:repeats=12:ip_autottl=-1,4-20:ip6_autottl=-1,4-20' \
  || fail "validate: пример с ip_id=zero должен проходить"

if custom_strategies_validate tpl 'nonexistentprim:repeats=2' 2>/dev/null; then
  fail "validate: неизвестный примитив должен падать"
fi
if custom_strategies_validate tpl 'fake:repeats=abc' 2>/dev/null; then
  fail "validate: нечисловой repeats должен падать"
fi
if custom_strategies_validate tpl 'fake:blob=nosuchblob:repeats=2' 2>/dev/null; then
  fail "validate: необъявленный блоб должен падать"
fi
if custom_strategies_validate p5 'multisplit:pos=2' 2>/dev/null; then
  fail "validate: TCP-примитив в UDP-блоке должен падать"
fi
if custom_strategies_validate tpl 'udplen:increment=4:min=20' 2>/dev/null; then
  fail "validate: UDP-примитив в TCP-блоке должен падать"
fi
if custom_strategies_validate tpl 'fake:blob=fakewgblob:repeats=2; rm -rf /' 2>/dev/null; then
  fail "validate: спецсимволы должны падать"
fi
if custom_strategies_validate tpl "fake:blob=\$(reboot):repeats=2" 2>/dev/null; then
  fail "validate: shell-подстановка должна падать"
fi
if custom_strategies_validate tpl 'fake:unknownkey=1:repeats=2' 2>/dev/null; then
  fail "validate: неизвестный ключ должен падать (строгий режим)"
fi
if custom_strategies_validate tpl 'fake:newflag:repeats=2' 2>/dev/null; then
  fail "validate: неизвестный флаг должен падать (строгий режим)"
fi
Z2R_CUSTOM_STRICT=0 custom_strategies_validate tpl 'fake:unknownkey=1:repeats=2' 2>/dev/null \
  || fail "validate: Z2R_CUSTOM_STRICT=0 должен пропускать неизвестные ключи с warning"

# --- 4. TSV CRUD --------------------------------------------------------------

id1="$(custom_strategies_add p5 \
  'fake:blob=fakewgblob:ipfrag:ipfrag_pos_udp=8:ipfrag_disorder:repeats=3:out_range=-d10' \
  'QUIC wg 3x')" || fail "add: первая QUIC-стратегия"
[ "$id1" = "1" ] || fail "add: первый id должен быть 1"
custom_strategies_add p5 \
  'fake:blob=fakewgblob:ipfrag:ipfrag_pos_udp=16:ipfrag_disorder:repeats=1:out_range=-d10' \
  'QUIC wg 1x' >/dev/null || fail "add: вторая QUIC-стратегия"
custom_strategies_add tpl \
  'multidisorder:pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1' \
  'TLS multidisorder' >/dev/null || fail "add: TLS-стратегия"
[ "$(custom_strategies_count)" = "3" ] || fail "list: должно быть 3 записи"

if custom_strategies_add p5 'fake:blob=nosuchblob:repeats=2' 'плохой блоб' 2>/dev/null; then
  fail "add: кривая стратегия не должна добавляться"
fi
[ "$(custom_strategies_count)" = "3" ] || fail "add: кривая запись всё же добавилась"

custom_strategies_set_enabled 2 0 || fail "set_enabled: выключить запись 2"
custom_strategies_set_enabled 2 1 || fail "set_enabled: включить запись 2"

custom_strategies_replace 3 tpl \
  'multidisorder:pos=1,sniext+1,midsld+2,endhost-1' 1 'TLS multidisorder v2' \
  || fail "replace: обновление записи 3"

# --- 5. Инжект -----------------------------------------------------------------

custom_strategies_apply_file "$CFG" 2>"$TMP_DIR/apply.log" || fail "apply_file: rc!=0"

grep -qxF -- '--lua-desync=fake:blob=fakewgblob:ipfrag:ipfrag_pos_udp=8:ipfrag_disorder:repeats=3:out_range=-d10:strategy=33' "$CFG" \
  || fail "apply: QUIC-стратегия №33 не в конфиге"
grep -qxF -- '--lua-desync=fake:blob=fakewgblob:ipfrag:ipfrag_pos_udp=16:ipfrag_disorder:repeats=1:out_range=-d10:strategy=34' "$CFG" \
  || fail "apply: QUIC-стратегия №34 не в конфиге"
grep -qxF -- '--lua-desync=multidisorder:pos=1,sniext+1,midsld+2,endhost-1:strategy=45' "$CFG" \
  || fail "apply: TLS-стратегия №45 (после шаблонного max=44) не в конфиге"

# маркеры и порядок: стратегии внутри маркеров ДО следующего --new
awk '/^#Z2R_CUSTOM_P5_BEGIN$/ {inb=1; next} /^#Z2R_CUSTOM_P5_END$/ {inb=0}
     inb && /^--lua-desync=/ {n++} /^--new$/ && !seen && n {if (n==2) ok=1; seen=1}
     END {exit !ok}' "$CFG" || fail "apply: между P5-маркерами должно быть ровно 2 стратегии до --new"

# динамический max для меню/суперсвипа/QAUIc-перебора
[ "$(config_profile_max_strategy 5 "$CFG")" = "34" ] \
  || fail "config_profile_max_strategy(5) != 34 (получено $(config_profile_max_strategy 5 "$CFG"))"
[ "$(config_profile_max_strategy 1 "$CFG")" = "45" ] \
  || fail "config_profile_max_strategy(1) != 45 (получено $(config_profile_max_strategy 1 "$CFG"))"

# assigned обновился в TSV
awk -F '\t' '$1==1 {exit !($6==33)}' "$CUSTOM_STRATS_FILE" || fail "apply: assigned записи 1 != 33"
awk -F '\t' '$1==3 {exit !($6==45)}' "$CUSTOM_STRATS_FILE" || fail "apply: assigned записи 3 != 45"

# идемпотентность
md5a="$(md5sum "$CFG" | cut -d' ' -f1)"
custom_strategies_apply_file "$CFG" 2>/dev/null || fail "apply: второй прогон rc!=0"
md5b="$(md5sum "$CFG" | cut -d' ' -f1)"
[ "$md5a" = "$md5b" ] || fail "apply: не идемпотентен"

# --- 6. Ремап локов при смещении номеров --------------------------------------

printf '5\tudp\t33\n' > "$ORCH_LOCK_FILE"
printf '1\ttls\t45\n' >> "$ORCH_LOCK_FILE"
printf 'quic\tsomehost\t33\n' > "$ORCH_DIR/auto_locked.tsv"

# имитируем апдейт апстрима: новая штатная стратегия 33 в QUIC-блоке и 45 в шаблоне
sed -i 's/^#Z2R_CUSTOM_P5_BEGIN$/--lua-desync=fake:blob=quic_google:repeats=1:out_range=-d2:strategy=33\n#Z2R_CUSTOM_P5_BEGIN/' "$CFG"
sed -i 's/^#Z2R_CUSTOM_TPL_BEGIN$/--lua-desync=multisplit:pos=2:strategy=45\n#Z2R_CUSTOM_TPL_BEGIN/' "$CFG"

custom_strategies_apply_file "$CFG" 2>>"$TMP_DIR/apply.log" || fail "apply после сдвига: rc!=0"

grep -qxF -- '--lua-desync=fake:blob=fakewgblob:ipfrag:ipfrag_pos_udp=8:ipfrag_disorder:repeats=3:out_range=-d10:strategy=34' "$CFG" \
  || fail "remap: QUIC-стратегия должна была сместиться на 34"
grep -qxF -- '--lua-desync=multidisorder:pos=1,sniext+1,midsld+2,endhost-1:strategy=46' "$CFG" \
  || fail "remap: TLS-стратегия должна была сместиться на 46"

awk -F '\t' '$1==5 && $2=="udp" {exit !($3==34)}' "$ORCH_LOCK_FILE" \
  || fail "remap: лок 5/udp не сместился 33 -> 34"
awk -F '\t' '$1==1 && $2=="tls" {exit !($3==46)}' "$ORCH_LOCK_FILE" \
  || fail "remap: лок 1/tls не сместился 45 -> 46"
awk -F '\t' '$1=="quic" {exit !($3==34)}' "$ORCH_DIR/auto_locked.tsv" \
  || fail "remap: auto_locked quic не сместился 33 -> 34"
awk -F '\t' '$1==1 {exit !($6==34)}' "$CUSTOM_STRATS_FILE" || fail "remap: assigned записи 1 != 34"

# --- 7. Выключение/удаление и сброс зависших локов ----------------------------

printf '5\tudp\t34\n' > "$ORCH_LOCK_FILE"
custom_strategies_set_enabled 2 0 >/dev/null || fail "set_enabled 2 off"
custom_strategies_delete 1 >/dev/null || fail "delete записи 1"

custom_strategies_apply_file "$CFG" 2>>"$TMP_DIR/apply.log" || fail "apply после удаления: rc!=0"

# записи 1 нет, запись 2 выключена: в P5-блоке нет кастомных стратегий
awk '/^#Z2R_CUSTOM_P5_BEGIN$/ {inb=1; next} /^#Z2R_CUSTOM_P5_END$/ {inb=0}
     inb && /^--lua-desync=/ {n++} END {exit !(n==0)}' "$CFG" \
  || fail "apply: выключенные/удалённые записи не должны попадать в конфиг"

# зависший лок 5/udp/34 (за пределами max=33) сброшен в auto
[ ! -s "$ORCH_LOCK_FILE" ] || [ -z "$(awk -F '\t' '$1==5' "$ORCH_LOCK_FILE")" ] \
  || fail "apply: лок за пределами диапазона должен сбрасываться в auto"

# id уплотнены: было 1,2,3 -> стало 1,2
[ "$(custom_strategies_count)" = "2" ] || fail "delete: id не уплотнены ($(custom_strategies_count))"

# --- 8. Маркеры в конфиге без них (старые установки) --------------------------

# чистый config.default без маркеров = живой конфиг до обновления затора
tr -d '\r' < "$REPO_DIR/config.default" | sed -e "s#/opt/zapret2#$ROOT#g" \
  | grep -v '^#Z2R_CUSTOM_' > "$TMP_DIR/pristine"
CFG_NOM="$TMP_DIR/config.nomarkers"
cp -f "$TMP_DIR/pristine" "$CFG_NOM"
CUSTOM_STRATS_FILE_BAK="$CUSTOM_STRATS_FILE"
export CUSTOM_STRATS_FILE="$TMP_DIR/custom2.tsv"
printf '# header\n' > "$CUSTOM_STRATS_FILE"
printf '1\tp5\tfake:blob=quic_google:repeats=9:out_range=-d2\t1\tвосстанов\t\n' >> "$CUSTOM_STRATS_FILE"
custom_strategies_apply_file "$CFG_NOM" 2>/dev/null || fail "apply на конфиге без маркеров: rc!=0"
for blk in TPL P4 P5 P6 P7; do
  grep -q "^#Z2R_CUSTOM_${blk}_BEGIN$" "$CFG_NOM" || fail "ensure_markers: нет BEGIN $blk"
done
grep -qxF -- '--lua-desync=fake:blob=quic_google:repeats=9:out_range=-d2:strategy=33' "$CFG_NOM" \
  || fail "ensure_markers+apply: стратегия не вставлена в восстановленный конфиг"
export CUSTOM_STRATS_FILE="$CUSTOM_STRATS_FILE_BAK"

# --- 9. Отсутствие TSV = чистый конфиг ----------------------------------------

rm -f "$CUSTOM_STRATS_FILE"
cp -f "$TMP_DIR/pristine" "$CFG"
custom_strategies_apply_file "$CFG" 2>/dev/null || fail "apply без TSV: rc!=0"
[ "$(grep -c '^#Z2R_CUSTOM_' "$CFG")" = "10" ] || fail "apply без TSV: маркеры должны остаться пустыми"
[ ! -f "$CUSTOM_STRATS_FILE" ] || fail "apply без TSV не должен создавать TSV"

# --- 9a. Бэкап-раунд: TSV едут в архив и возвращаются в конфиг ----------------
# Живая регрессия проды: кастомные стратегии и выбор блобов обязаны переживать
# «бэкап -> катастрофа -> восстановление состояния -> ре-инжект в конфиг».
export Z2R_BACKUP_DIR="$TMP_DIR/backups"
mkdir -p "$Z2R_BACKUP_DIR"
rm -f "$CUSTOM_STRATS_FILE"
custom_strategies_add p5 'fake:blob=quic_google:repeats=9:out_range=-d2' 'бекап-тест' >/dev/null   || fail "add для бэкап-раунда"
blob_files_set maxru wg_initial_fake_2.bin || fail "blob_files_set для раунда"
custom_strategies_apply_file "$CFG" 2>/dev/null || fail "apply перед бэкапом"
grep -qE 'fake:blob=quic_google:repeats=9:out_range=-d2:strategy=33' "$CFG"   || fail "кастом в конфиге перед бэкапом"
backup_create_core >/dev/null || fail "backup_create_core"
ARCHIVE="$(ls -1t "$Z2R_BACKUP_DIR"/z2r_backup_*.tar 2>/dev/null | head -n1)"
[ -n "$ARCHIVE" ] || fail "архив бэкапа не создан"
TAR_BIN="$(z2r_pick_tar)"
"$TAR_BIN" -tf "$ARCHIVE" | grep -q 'custom_strategies.tsv' || fail "custom_strategies.tsv не в архиве"
"$TAR_BIN" -tf "$ARCHIVE" | grep -q 'blob_files.tsv' || fail "blob_files.tsv не в архиве"
"$TAR_BIN" -tf "$ARCHIVE" | grep -qE '\./config$' || fail "config не в архиве"
# катастрофа: TSV снесены, конфиг снова эталонный
rm -f "$CUSTOM_STRATS_FILE" "$ORCH_BLOB_FILES_TSV"
grep -vE 'quic_google:repeats=9' "$CFG" > "$TMP_DIR/cfg.nocustom" && cp -f "$TMP_DIR/cfg.nocustom" "$CFG"
# восстановление состояния циклом из menu_action_backup_restore + ре-инжект хуками
RD="$TMP_DIR/rd"; mkdir -p "$RD"
"$TAR_BIN" -xf "$ARCHIVE" -C "$RD" || fail "распаковка архива"
z2r_backup_state_files > "$TMP_DIR/state.list"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$RD/$rel" ] || continue
  mkdir -p "$ZATOR_ROOT/$(dirname "$rel")"
  cp -f "$RD/$rel" "$ZATOR_ROOT/$rel" || fail "восстановление $rel"
done < "$TMP_DIR/state.list"
[ -f "$CUSTOM_STRATS_FILE" ] || fail "custom_strategies.tsv не восстановлен"
custom_strategies_apply_file "$CFG" 2>/dev/null || fail "ре-инжект после восстановления"
blob_files_apply "$CFG" || fail "blob_files_apply после восстановления"
grep -qE 'fake:blob=quic_google:repeats=9:out_range=-d2:strategy=33' "$CFG"   || fail "кастом не вернулся в конфиг после восстановления"
[ "$(blob_files_get maxru)" = "wg_initial_fake_2.bin" ]   || fail "выбор блоба не восстановился: $(blob_files_get maxru)"
grep -q -- '--blob=maxru:@/opt/zator/files/fake/wg_initial_fake_2.bin' "$CFG"   || fail "блоб не вернулся в декларацию конфига"

# --- 10. Контракт диалогов: stdout — только ответ (меню ловит $(...)) -------

clear() { :; }  # диалоги зовут clear -x; в песочнице — заглушка
# цвета определены в z2r.sh (не в ui.sh) — в песочнице это пустые заглушки
cyan=""; plain=""; green=""; red=""; yellow=""; Fcyan=""; Fyellow=""; Fgreen=""; Fpink=""

out="$(printf '1
' | _custom_pick_block 2>/dev/null)" || out=""
[ "$out" = "tpl" ] || fail "pick_block: stdout должен быть только 'tpl' (получено: $out)"
out="$(printf '0
' | _custom_pick_block 2>/dev/null)" || out=""
[ -z "$out" ] || fail "pick_block: отмена должна давать пустой stdout (получено: $out)"
out="$(printf '3
' | _custom_pick_block 2>/dev/null)" || out=""
[ "$out" = "p5" ] || fail "pick_block: выбор 3 должен давать 'p5' (получено: $out)"

_CUSTOM_BLOCK=p5
out="$(printf '%s
' 'fake:blob=quic_google:repeats=7:out_range=-d10' | _custom_ask_spec 2>/dev/null)" || out=""
[ "$out" = "fake:blob=quic_google:repeats=7:out_range=-d10" ]   || fail "ask_spec: stdout должен быть только spec (получено: $out)"

_CUSTOM_BLOCK=tpl
_combo_in='--lua-desync=multisplit:blob=maxru:tcp_md5:pos=2:nodrop:strategy=10 --lua-desync=fakeddisorder:pos=midsld:tcp_md5:nofake3:strategy=10'
_combo_want='multisplit:blob=maxru:tcp_md5:pos=2:nodrop --lua-desync=fakeddisorder:pos=midsld:tcp_md5:nofake3'
out="$(printf '%s
' "$_combo_in" | _custom_ask_spec 2>/dev/null)" || out=""
[ "$out" = "$_combo_want" ]   || fail "ask_spec: комбо-строка из конфига должна срезать :strategy=N (получено: $out)"

out="$(printf '
' | _custom_ask_spec 2>/dev/null)" || out=""
[ -z "$out" ] || fail "ask_spec: отмена должна давать пустой stdout"
out="$(printf '%s
%s
' 'badprim:x=1' '' | _custom_ask_spec 2>/dev/null)" || out=""
[ -z "$out" ] || fail "ask_spec: кривая строка + отмена должны давать пустой stdout"

unset -f clear

echo "custom strategies smoke ok"
