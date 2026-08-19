#!/usr/bin/env bash
#
# Smoke-тест умного восстановления (режим 3) и бэкап-менеджера (п.21).
#
# Покрывает:
#   1. Целостность tar-архива (round-trip create/extract + сверка хэшей),
#      как это делает menu_action_backup_create / menu_action_backup_restore.
#   2. backup_smart_apply_ports  — точечный перенос NFQWS2_PORTS_TCP/UDP + RKN.
#   3. backup_smart_apply_blobs  — сопоставление blob'ов по именам
#      (совпадение → перенос; несовпадение имени → пропуск;
#       отсутствие файла в /opt/zator/files/fake/ → пропуск;
#       синхронизация режима maxru ↔ fake_default_tls).
#   4. backup_smart_apply_flags  — флаги п.13/18/19/20 (Anti-RST, fallback,
#      reasm, WireGuard, QUIC443, игровой UDP, FWTYPE, FLOWOFFLOAD, MODE_FILTER).
#   5. menu_action_backup_restore_smart — сквозной неразрушающий перенос.
#   6. backup_check_blobs — валидация наличия blob-файлов (режим 1 импорта).
#   7. Идемпотентность повторного применения + сохранность синтаксиса config.
#
# ИЗОЛЯЦИЯ:
#   • Все конфиги создаются во временной папке /tmp и удаляются через trap EXIT.
#   • Реальный /opt/zapret2/config НЕ затрагивается.
#   • Единственная уступка хардкоду исходников: функции backup_smart_apply_blobs
#     и backup_check_blobs проверяют существование файлов по абсолютному пути
#     /opt/zator/files/fake/. Поэтому тест создаёт там несколько
#     УНИКАЛЬНО-ИМЕНОВАННЫХ blob-файлов (z2r_smoke_*.bin) и удаляет ровно их
#     в trap. Ни один реальный ассет не перезаписывается.
#
# Возврат: 0 — успех, 1 — любая ошибка (с сообщением "FAIL: ...").
# Запуск:  bash tests/backup_smart_smoke.sh

# Намеренно БЕЗ `set -e`: тестируемые функции могут возвращать ненулевой код
# (например backup_check_blobs при отсутствии blob'а), что является нормой.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PASS=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() {
  printf '  [PASS] %s\n' "$1"
  PASS=$((PASS + 1))
}

# --- Заглушки глобалей, нужных только при source lib/*.sh ---
plain=""; cyan=""; green=""; red=""; yellow=""
Fcyan=""; Fyellow=""
ZAPRET2_INIT="/bin/true"
hardware="vps"

# shellcheck source=/dev/null
. "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
. "$REPO_DIR/lib/actions.sh"

# Синтаксис библиотек не должен быть сломан.
for f in "$REPO_DIR/lib/config.sh" "$REPO_DIR/lib/actions.sh"; do
  bash -n "$f" || fail "bash -n failed for $f"
done

# ===========================================================================
# Изоляция: временное окружение в /tmp
# ===========================================================================
TMP_DIR="$(mktemp -d /tmp/zator-backup-smoke.XXXXXX 2>/dev/null || fail "mktemp failed")"

# Хардкод путей в backup_smart_apply_blobs / backup_check_blobs требует реальных
# файлов в /opt/zator/files/fake/. Создаём УНИКАЛЬНЫЕ имена и удаляем только их.
FAKE_DIR="/opt/zator/files/fake"
BLOB_MAXRU="z2r_smoke_maxru.bin"
BLOB_TLS4="z2r_smoke_tls4.bin"
BLOB_MISSING="z2r_smoke_missing.bin"   # намеренно НЕ создаётся (negative path)

cleanup() {
  rm -f "$FAKE_DIR/$BLOB_MAXRU" "$FAKE_DIR/$BLOB_TLS4" "$FAKE_DIR/$BLOB_MISSING"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ENV="$TMP_DIR/env"
mkdir -p "$ENV"

# Создаём тестовые blob-файлы по хардкод-пути (только уникальные имена).
if ! mkdir -p "$FAKE_DIR" 2>/dev/null; then
  fail "невозможно создать $FAKE_DIR — тесту нужен доступ на запись в /opt/zator/files/fake (хардкод исходников)"
fi
printf 'Z2R_SMOKE_MAXRU_PAYLOAD_V1' > "$FAKE_DIR/$BLOB_MAXRU" || fail "cannot write $BLOB_MAXRU"
printf 'Z2R_SMOKE_TLS4_PAYLOAD_V1'   > "$FAKE_DIR/$BLOB_TLS4" || fail "cannot write $BLOB_TLS4"
# $BLOB_MISSING НЕ создаём — для проверки защитного skip.

# ===========================================================================
# Подготовка OLD (пользовательский конфиг) и NEW (свежий дефолт)
# ===========================================================================
OLD="$ENV/old_config"
NEW="$ENV/new_config"
cp "$REPO_DIR/config.default" "$OLD"
cp "$REPO_DIR/config.default" "$NEW"

ereg="$(config_sed_ereg)"

# --- OLD: пользовательские порты ---
config_set_var "$OLD" NFQWS2_PORTS_TCP "123,456,80,443,2053,2083,2087,2096,8443"
config_set_var "$OLD" NFQWS2_PORTS_UDP "7777,1026-65531,443,2408"

# --- OLD: пользовательские blob-декларации ---
# maxru -> существующий тестовый blob (будет перенесён в NEW).
sed -i "s#--blob=maxru:@/opt/zator/files/fake/tls_clienthello_max_ru.bin#--blob=maxru:@/opt/zator/files/fake/$BLOB_MAXRU#" "$OLD"
# tls4 -> НЕсуществующий blob (защитный skip: перенос недопустим).
sed -i "s#--blob=tls4:@/opt/zator/files/fake/tls_clienthello_4.bin#--blob=tls4:@/opt/zator/files/fake/$BLOB_MISSING#" "$OLD"
# Имя блоба, которого НЕТ в NEW → должен быть пропущен (несовпадение имени).
sed -i "s#--blob=custom:@/opt/zator/files/fake/custom_tls.bin#--blob=zzz_only_in_old:@/opt/zator/files/fake/$BLOB_MAXRU\n--blob=custom:@/opt/zator/files/fake/custom_tls.bin#" "$OLD"

# --- OLD: режим maxru (fake_default_tls → maxru в --lua-desync, кроме strategy=26) ---
sed -i $ereg '/--lua-desync=/ { /strategy=26/! s#(blob=)fake_default_tls#\1maxru#g; }' "$OLD"

# --- OLD: флаги через штатные сеттеры (те же, что и в backup_smart_apply_flags) ---
backup_smart_set_rst_guard   "$OLD" 1
backup_smart_set_fallback    "$OLD" 1
backup_smart_set_reasm       "$OLD" 1
backup_smart_set_wireguard   "$OLD" 1
backup_smart_set_quic443     "$OLD" 1
backup_smart_set_udp_games   "$OLD" 1
backup_smart_set_hostlist    "$OLD" 1
config_set_var "$OLD" FWTYPE      nftables
config_set_var "$OLD" FLOWOFFLOAD software

# ===========================================================================
# 1. Целостность tar-архива (бэкап-менеджер, п.21)
# ===========================================================================
echo "== 1. Целостность tar-архива =="
STAGE="$TMP_DIR/stage"
mkdir -p "$STAGE/extra_strats/cache/orchestra"
cp "$OLD" "$STAGE/config"
printf '3\ttls\t0\n' > "$STAGE/extra_strats/cache/orchestra/locked.tsv"
printf 'netrogat-domain.example\n' > "$STAGE/netrogat_sample.txt"

ARCH="$TMP_DIR/test_backup.tar"
tar -cf "$ARCH" -C "$STAGE" . 2>/dev/null || fail "tar -cf (создание архива) завершился ошибкой"
[ -s "$ARCH" ] || fail "архив пуст после tar -cf"

REST="$TMP_DIR/restore"
mkdir -p "$REST"
tar -xf "$ARCH" -C "$REST" 2>/dev/null || fail "tar -xf (распаковка архива) завершился ошибкой"

# Сверка содержимого round-trip.
h_stage_cfg="$(sha256sum "$STAGE/config" | awk '{print $1}')"
h_rest_cfg="$(sha256sum "$REST/config" | awk '{print $1}')"
[ "$h_stage_cfg" = "$h_rest_cfg" ] || fail "config изменился после tar round-trip (stage=$h_stage_cfg rest=$h_rest_cfg)"

[ -f "$REST/extra_strats/cache/orchestra/locked.tsv" ] || fail "архив не сохранил вложенный файл locked.tsv"
[ "$(cat "$REST/extra_strats/cache/orchestra/locked.tsv")" = "$(cat "$STAGE/extra_strats/cache/orchestra/locked.tsv")" ] \
  || fail "содержимое locked.tsv не совпадает после распаковки"

# Состав архива должен содержать ожидаемые члены (как menu_action_backup_create).
tar -tf "$ARCH" | grep -Eq '^(\./)?config$'         || fail "в архиве нет члена config"
tar -tf "$ARCH" | grep -Eq 'locked\.tsv$'           || fail "в архиве нет члена locked.tsv"
ok "tar round-trip: config и вложенные файлы прошли без потерь"

# ===========================================================================
# 2. Умный перенос портов (backup_smart_apply_ports)
# ===========================================================================
echo "== 2. Перенос портов NFQWS2_PORTS_TCP/UDP =="
backup_smart_apply_ports "$OLD" "$NEW"

new_tcp="$(config_get_var "$NEW" NFQWS2_PORTS_TCP)"
new_udp="$(config_get_var "$NEW" NFQWS2_PORTS_UDP)"
[ "$new_tcp" = "123,456,80,443,2053,2083,2087,2096,8443" ] \
  || fail "NFQWS2_PORTS_TCP не перенесён (got: $new_tcp)"
[ "$new_udp" = "7777,1026-65531,443,2408" ] || fail "NFQWS2_PORTS_UDP не перенесён (got: $new_udp)"
ok "пользовательские TCP/UDP порты перенесены в новый config"

# Пользовательские TCP-порты должны попасть в --filter-tcp блока RKN.
if sed -n '/#Стратегии для RKN/,/^[[:space:]]*--new[[:space:]]*$/p' "$NEW" \
   | grep -q 'filter-tcp=123,456,80,443'; then
  ok "RKN --filter-tcp синхронизирован с пользовательскими портами"
else
  fail "RKN --filter-tcp не содержит пользовательские порты 123,456"
fi

# ===========================================================================
# 3. Синхронизация blob'ов (backup_smart_apply_blobs)
# ===========================================================================
echo "== 3. Синхронизация blob'ов по совпадению имён =="
backup_smart_apply_blobs "$OLD" "$NEW"

# 3a. Совпадающий blob (maxru), файл существует → перенос.
maxru_new="$(sed -n -E 's#.*--blob=maxru:@/opt/zator/files/fake/([^[:space:]]+).*#\1#p' "$NEW" | head -n1)"
[ "$maxru_new" = "$BLOB_MAXRU" ] \
  || fail "blob maxru не перенесён к существующему файлу (got: $maxru_new)"
ok "совпадающий blob (maxru) обновлён на файл из бэкапа"

# 3b. Имя совпадает (tls4), но файл НЕ существует → защитный skip, дефолт сохранён.
tls4_new="$(sed -n -E 's#.*--blob=tls4:@/opt/zator/files/fake/([^[:space:]]+).*#\1#p' "$NEW" | head -n1)"
[ "$tls4_new" = "tls_clienthello_4.bin" ] \
  || fail "blob tls4 с несуществующим файлом не должен переноситься (got: $tls4_new)"
ok "blob с отсутствующим файлом НЕ перенесён (защитный skip)"

# 3c. Имя блоба есть только в OLD → не должен появиться в NEW.
if grep -q 'zzz_only_in_old' "$NEW"; then
  fail "blob с именем, отсутствующим в новом config, не должен переноситься"
fi
ok "blob с несовпадающим именем пропущен"

# 3d. Блобы NEW, не затронутые переносом, остаются нетронутыми (дефолт).
wg_new="$(sed -n -E 's#.*--blob=fakewgblob:@/opt/zator/files/fake/([^[:space:]]+).*#\1#p' "$NEW" | head -n1)"
[ "$wg_new" = "wg_initial_fake_1.bin" ] \
  || fail "blob fakewgblob должен остаться дефолтным (got: $wg_new)"
ok "непереносимые blob'ы нового config остались нетронутыми"

# 3e. Режим maxru синхронизирован (NEW переключён в maxru, кроме strategy=26).
old_mode="$(config_tls_blob_mode_value "$OLD")"
new_mode="$(config_tls_blob_mode_value "$NEW")"
[ "$old_mode" = "$new_mode" ] || fail "режим blob не синхронизирован (old=$old_mode new=$new_mode)"
[ "$new_mode" = "maxru" ] || fail "NEW должен быть в режиме maxru (got: $new_mode)"
# strategy=26 не должен переключаться на maxru (инвариант menu_action_set_tls_blob).
if sed -n 's/.*strategy=26.*//p' "$NEW" | grep -q .; then :; fi  # no-op guard
if grep 'strategy=26' "$NEW" | grep -q 'blob=maxru'; then
  fail "strategy=26 не должна переключаться в режим maxru"
fi
ok "режим blob синхронизирован в maxru (strategy=26 защищена)"

# ===========================================================================
# 4. Применение флагов (backup_smart_apply_flags)
# ===========================================================================
echo "== 4. Перенос флагов п.13/18/19/20 =="
backup_smart_apply_flags "$OLD" "$NEW"

# Anti-RST (п.18): rst_guard_locked должен появиться.
if grep -q -- '--lua-desync=rst_guard_locked:key=' "$NEW"; then
  ok "Пункт 18: Anti-RST включён (rst_guard_locked)"
else
  fail "Пункт 18: Anti-RST не включён"
fi

# Безразборный режим (п.13): --skip в fallback убран.
if { sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$NEW"
     sed -n '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/p' "$NEW"; } \
   | grep -q '^[[:space:]]*--skip'; then
  fail "Пункт 13: безразборный режим не включён (--skip остался)"
else
  ok "Пункт 13: безразборный режим включён (--skip убран)"
fi

# --reasm-disable (п.19): строка добавлена в NFQWS2_OPT.
if sed -n '/^NFQWS2_OPT="/,/^"$/p' "$NEW" | grep -q '^[[:space:]]*--reasm-disable'; then
  ok "Пункт 19: --reasm-disable добавлен"
else
  fail "Пункт 19: --reasm-disable не добавлен"
fi

# WireGuard (п.19): --skip убран.
if sed -n '/#Z2R_WG_BEGIN/,/#Z2R_WG_END/p' "$NEW" \
   | grep -Eq '^[[:space:]]*--filter-l7=wireguard[[:space:]]*$'; then
  ok "Пункт 19: WireGuard включён"
else
  fail "Пункт 19: WireGuard не включён"
fi

# QUIC443 (п.19): --skip убран.
if sed -n '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/p' "$NEW" \
   | grep -Eq '^[[:space:]]*--filter-udp=443[[:space:]]*$'; then
  ok "Пункт 19: QUIC443 включён"
else
  fail "Пункт 19: QUIC443 не включён"
fi

# Игровой UDP (п.19): состояние определяется наличием диапазона 1026-65531 в
# NFQWS2_PORTS_UDP (см. config_mode_text udp_games). После переноса портов
# состояние NEW должно совпадать с OLD. Точечный toggle --skip — в блоке 4b.
udp_old="$(config_mode_text udp_games "$OLD")"
udp_new="$(config_mode_text udp_games "$NEW")"
[ "$udp_old" = "$udp_new" ] || fail "состояние игрового UDP не совпало (old=$udp_old new=$udp_new)"
[ "$udp_old" = "Включен" ] || fail "OLD игровой UDP должен быть 'Включен' (got: $udp_old)"
ok "Пункт 19: состояние игрового UDP синхронизировано ($udp_new)"

# FWTYPE / FLOWOFFLOAD (переменные).
[ "$(config_get_var "$NEW" FWTYPE)" = "nftables" ] \
  || fail "FWTYPE не перенесён (got: $(config_get_var "$NEW" FWTYPE))"
[ "$(config_get_var "$NEW" FLOWOFFLOAD)" = "software" ] \
  || fail "FLOWOFFLOAD не перенесён (got: $(config_get_var "$NEW" FLOWOFFLOAD))"
ok "FWTYPE/FLOWOFFLOAD перенесены"

# MODE_FILTER (п.19/20): autohostlist.
[ "$(config_get_var "$NEW" MODE_FILTER)" = "autohostlist" ] \
  || fail "MODE_FILTER не перенесён (got: $(config_get_var "$NEW" MODE_FILTER))"
ok "MODE_FILTER=autohostlist перенесён"

# ===========================================================================
# 4b. Прямой тест сеттеров/тумблеров backup_smart_set_* (round-trip вкл↔выкл)
#     Каждый сеттер проверяется на свежей копии config.default, чтобы изолировать
#     его от переносов портов и взаимодействий с другими флагами.
# ===========================================================================
echo "== 4b. Прямой тест сеттеров backup_smart_set_* =="
T="$ENV/setter_cfg"

# Игровой UDP: toggle --skip в блоке (detector config_mode_text смотрит на порты,
# поэтому здесь проверяем сам блок напрямую).
cp "$REPO_DIR/config.default" "$T"
backup_smart_set_udp_games "$T" 1
sed -n '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/p' "$T" \
  | grep -Eq '^[[:space:]]*--filter-udp=1026' \
  || fail "set_udp_games 1: --filter-udp=1026 должен быть без --skip"
! sed -n '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/p' "$T" \
  | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-udp=1026' \
  || fail "set_udp_games 1: --skip не убран"
backup_smart_set_udp_games "$T" 0
sed -n '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/p' "$T" \
  | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-udp=1026' \
  || fail "set_udp_games 0: --skip не возвращён"
ok "set_udp_games: round-trip вкл↔выкл корректен"

# WireGuard: detector backup_smart_wg_state.
cp "$REPO_DIR/config.default" "$T"
backup_smart_set_wireguard "$T" 1
[ "$(backup_smart_wg_state "$T")" = "1" ] || fail "set_wireguard 1 не сработал (state=$(backup_smart_wg_state "$T"))"
backup_smart_set_wireguard "$T" 0
[ "$(backup_smart_wg_state "$T")" = "0" ] || fail "set_wireguard 0 не сработал (state=$(backup_smart_wg_state "$T"))"
ok "set_wireguard: round-trip вкл↔выкл корректен"

# QUIC443: detector backup_smart_quic443_state.
cp "$REPO_DIR/config.default" "$T"
backup_smart_set_quic443 "$T" 1
[ "$(backup_smart_quic443_state "$T")" = "1" ] || fail "set_quic443 1 не сработал"
backup_smart_set_quic443 "$T" 0
[ "$(backup_smart_quic443_state "$T")" = "0" ] || fail "set_quic443 0 не сработал"
ok "set_quic443: round-trip вкл↔выкл корректен"

# Fallback / RST-guard / reasm / hostlist: detector config_mode_text.
cp "$REPO_DIR/config.default" "$T"
backup_smart_set_fallback "$T" 1
[ "$(config_mode_text fallback "$T")" = "включен" ] || fail "set_fallback 1 не сработал"
backup_smart_set_fallback "$T" 0
[ "$(config_mode_text fallback "$T")" = "выключен" ] || fail "set_fallback 0 не сработал"
ok "set_fallback: round-trip вкл↔выкл корректен"

cp "$REPO_DIR/config.default" "$T"
backup_smart_set_rst_guard "$T" 1
[ "$(config_mode_text rst_guard "$T")" = "включен" ] || fail "set_rst_guard 1 не сработал"
backup_smart_set_rst_guard "$T" 0
[ "$(config_mode_text rst_guard "$T")" = "выключен" ] || fail "set_rst_guard 0 не сработал"
ok "set_rst_guard: round-trip вкл↔выкл корректен"

cp "$REPO_DIR/config.default" "$T"
backup_smart_set_reasm "$T" 1
[ "$(config_mode_text reasm_disable "$T")" = "включено" ] || fail "set_reasm 1 не сработал"
backup_smart_set_reasm "$T" 0
[ "$(config_mode_text reasm_disable "$T")" = "выключено" ] || fail "set_reasm 0 не сработал"
ok "set_reasm: round-trip вкл↔выкл корректен"

cp "$REPO_DIR/config.default" "$T"
backup_smart_set_hostlist "$T" 1
[ "$(config_mode_text hostlist "$T")" = "авто" ] || fail "set_hostlist 1 не сработал"
backup_smart_set_hostlist "$T" 0
[ "$(config_mode_text hostlist "$T")" = "по листам" ] || fail "set_hostlist 0 не сработал"
ok "set_hostlist: round-trip вкл↔выкл корректен"

# ===========================================================================
# 5. Сквозной неразрушающий перенос (menu_action_backup_restore_smart)
# ===========================================================================
echo "== 5. Сквозной menu_action_backup_restore_smart =="
NEW2="$ENV/new2_config"
cp "$REPO_DIR/config.default" "$NEW2"
# NEW2 не должен измениться по ссылке: проверяем, что живой config не заменяется.
menu_action_backup_restore_smart "$OLD" "$NEW2" >/dev/null \
  || fail "menu_action_backup_restore_smart завершился ошибкой"
[ "$(config_get_var "$NEW2" NFQWS2_PORTS_TCP)" = "123,456,80,443,2053,2083,2087,2096,8443" ] \
  || fail "smart-перенос не перенёс порты в NEW2"
[ "$(config_get_var "$NEW2" FLOWOFFLOAD)" = "software" ] \
  || fail "smart-перенос не перенёс FLOWOFFLOAD в NEW2"
ok "menu_action_backup_restore_smart: порты и флаги перенесены, config не заменён"

# ===========================================================================
# 6. backup_check_blobs — валидация наличия blob-файлов (режим 1 импорта)
# ===========================================================================
echo "== 6. backup_check_blobs (валидация импорта) =="
CHK_OK="$ENV/blob_check_ok.cfg"
CHK_BAD="$ENV/blob_check_bad.cfg"
{
  printf -- '--blob=maxru:@/opt/zator/files/fake/%s\n' "$BLOB_MAXRU"
  printf -- '--blob=tls4:@/opt/zator/files/fake/%s\n' "$BLOB_TLS4"
} > "$CHK_OK"
{
  printf -- '--blob=maxru:@/opt/zator/files/fake/%s\n' "$BLOB_MAXRU"
  printf -- '--blob=ghost:@/opt/zator/files/fake/%s\n' "$BLOB_MISSING"
} > "$CHK_BAD"

if backup_check_blobs "$CHK_OK" >/dev/null; then
  ok "все blob-файлы существуют → импорт разрешён (rc=0)"
else
  fail "backup_check_blobs ошибочно заблокировал валидный config"
fi

if backup_check_blobs "$CHK_BAD" >/dev/null; then
  fail "backup_check_blobs не обнаружил отсутствующий blob (должен rc=1)"
else
  ok "отсутствующий blob блокирует импорт (rc=1)"
fi

# ===========================================================================
# 7. Идемпотентность + сохранность синтаксиса config
# ===========================================================================
echo "== 7. Идемпотентность и сохранность структуры =="
NEW3="$ENV/new3_config"
cp "$REPO_DIR/config.default" "$NEW3"
backup_smart_apply_ports "$OLD" "$NEW3"
backup_smart_apply_blobs "$OLD" "$NEW3"
backup_smart_apply_flags "$OLD" "$NEW3"
# Повторное применение не должно ломать конфиг.
backup_smart_apply_flags "$OLD" "$NEW3"
backup_smart_apply_flags "$OLD" "$NEW3"

# Структурные маркеры присутствуют ровно по одному разу.
for marker in '#Z2R_FALLBACK_BEGIN' '#Z2R_FALLBACK_END' '#Z2R_FALLBACK_HTTP_BEGIN' \
              '#Z2R_FALLBACK_HTTP_END' '#Z2R_WG_BEGIN' '#Z2R_WG_END' \
              '#Z2R_QUIC443_BEGIN' '#Z2R_QUIC443_END'; do
  n="$(grep -c -- "$marker" "$NEW3")"
  [ "$n" -eq 1 ] || fail "маркер $marker встречается $n раз (ожидалась 1) — структура сломана"
done
ok "все структурные маркеры #Z2R_* присутствуют ровно по одному разу"

# Блок NFQWS2_OPT сбалансирован: ровно одно открытие и одно закрытие кавычки.
[ "$(grep -c '^NFQWS2_OPT="$' "$NEW3")" -eq 1 ] || fail "NFQWS2_OPT=\" должен открываться ровно 1 раз"
[ "$(grep -c '^"$' "$NEW3")" -ge 1 ] || fail "блок NFQWS2_OPT не закрыт кавычкой"
ok "блок NFQWS2_OPT структурно сбалансирован"

# Повторное применение флагов стабильно (fallback не сломан двойным накатом).
if { sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$NEW3"
     sed -n '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/p' "$NEW3"; } \
   | grep -q '^[[:space:]]*--skip'; then
  fail "идемпотентность: повторное применение сломало fallback (--skip вернулся)"
else
  ok "идемпотентность: повторное применение флагов стабильно"
fi

echo ""
echo "============================="
printf 'backup_smart smoke ok (assertions: %d)\n' "$PASS"
