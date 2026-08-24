#!/usr/bin/env bash
#
# Smoke-тест удаления: пункты меню 4 (zator + zapret2) и 44 (только zapret2),
# функция zator_remove() и локализация её сбоев (z2r.sh работает под set -e).
#
# Покрывает:
#   0. bash -n z2r.sh + статические инварианты: метки 4/44, обработчик 4
#      вызывает remove_zapret + zator_remove, обработчик 44 — только
#      remove_zapret, вызовы обёрнуты в || echo (безопасный вывод ошибки).
#   1. zator_remove: штатное удаление — сносится $ZATOR_ROOT, заодно
#      останавливаются сервисы (strategy validator, Web-панель), rc=0.
#   2. zator_remove: каталога нет — rc=0, сообщение, сервисы не трогаются.
#   3. zator_remove: сбой rm (мок) — rc=1, предупреждение пользователю,
#      set -e не роняет вызывающий код.
#
# ИЗОЛЯЦИЯ:
#   • Всё во временной папке /tmp (trap EXIT); реальный /opt не затрагивается
#     (ZATOR_ROOT переопределяется на временную папку ДО sourcing функции).
#   • zator_remove извлекается из z2r.sh sed-диапазоном (объявлена от колонки 0);
#     strategy_validator_remove_service и webui_remove подменяются логирующими
#     моками — проверяется сам факт их вызова.
#   • Мок rm: детерминированный сбой удаления пути из $MOCK_RM_FAIL_PATH,
#     остальные вызовы идут в настоящий rm (chmod-защита от rm работает
#     не везде: MSYS/Windows её игнорирует).
#
# Возврат: 0 — успех, 1 — любая ошибка (с сообщением "FAIL: ...").
# Запуск:  bash tests/uninstall_smoke.sh

# Намеренно БЕЗ `set -e`: тестируемые функции могут возвращать ненулевой код.
# Поведение под set -e проверяется явно, в subshell с имитацией обработчика меню.

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

TMP_DIR="$(mktemp -d /tmp/zator-uninstall-smoke.XXXXXX 2>/dev/null || fail "mktemp failed")"
cleanup() {
  MOCK_RM_FAIL_PATH=""
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# --- Заглушки глобалей z2r.sh (ZATOR_ROOT — env-переопределяемый) ---
plain=""; cyan=""; green=""; red=""; yellow=""
ZATOR_ROOT="$TMP_DIR/zator"
WEBUI_ROOT="$ZATOR_ROOT/webui"
WEBUI_RUNNER="$WEBUI_ROOT/run-webui.sh"
OSystem="VPS"
MOCK_SVC_LOG="$TMP_DIR/services.log"
: > "$MOCK_SVC_LOG"

mkdir -p "$TMP_DIR/bin"

# Мок clear (no-op) — на случай расширения теста интерактивными меню.
printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/clear"
chmod +x "$TMP_DIR/bin/clear"

# Настоящий rm нужен моку для сквозного пропуска остальных вызовов.
REAL_RM="$(command -v rm)"
[ -n "$REAL_RM" ] || fail "rm не найден в PATH"
{
  printf '#!/bin/sh\n'
  printf 'for arg in "$@"; do\n'
  printf '  [ -z "$MOCK_RM_FAIL_PATH" ] || [ "$arg" != "$MOCK_RM_FAIL_PATH" ] || exit 1\n'
  printf 'done\n'
  printf 'exec "%s" "$@"\n' "$REAL_RM"
} > "$TMP_DIR/bin/rm"
chmod +x "$TMP_DIR/bin/rm"
export MOCK_RM_FAIL_PATH=""
export PATH="$TMP_DIR/bin:$PATH"

# --- Извлечение zator_remove из монолита z2r.sh ---
extract_fn() {
  sed -n "/^$1() {/,/^}/p" "$REPO_DIR/z2r.sh"
}
extract_fn zator_remove > "$TMP_DIR/zator_remove.fn"
[ -s "$TMP_DIR/zator_remove.fn" ] \
  || fail "функция zator_remove не найдена в z2r.sh (ожидается объявление от колонки 0)"

# Логирующие моки сервисов, которые zator_remove обязан остановить.
strategy_validator_remove_service() {
  echo "validator" >> "$MOCK_SVC_LOG"
  return 0
}
webui_remove() {
  echo "webui" >> "$MOCK_SVC_LOG"
  return 0
}

# shellcheck source=/dev/null
. "$TMP_DIR/zator_remove.fn"

# ===========================================================================
# 0. Синтаксис и статические инварианты меню 4/44
# ===========================================================================
echo "== 0. Синтаксис и инварианты пунктов 4/44 =="
bash -n "$REPO_DIR/z2r.sh" || fail "bash -n failed for z2r.sh"

grep -qF '4.${yellow} Удаление zator и zapret2' "$REPO_DIR/z2r.sh" \
  || fail "в меню нет пункта 4 (Удаление zator и zapret2)"
grep -qF '44.${yellow} Удаление zapret2' "$REPO_DIR/z2r.sh" \
  || fail "в меню нет пункта 44 (Удаление zapret2)"

# Обработчик 4 (два пробела от колонки — как в главном меню; в подменю webui
# своя "4" с шестью пробелами, она отсекается анкором): полный снос.
FOUR_BLOCK="$(sed -n '/^  "4")/,/^    ;;/p' "$REPO_DIR/z2r.sh")"
[ -n "$FOUR_BLOCK" ] || fail "не найден обработчик главного меню 4"
printf '%s\n' "$FOUR_BLOCK" | grep -q 'remove_zapret' \
  || fail "обработчик 4 не удаляет zapret2"
printf '%s\n' "$FOUR_BLOCK" | grep -q 'zator_remove' \
  || fail "обработчик 4 не удаляет zator"
printf '%s\n' "$FOUR_BLOCK" | grep -qF 'remove_zapret || echo' \
  || fail "в обработчике 4 вызов remove_zapret не защищён (|| echo)"
printf '%s\n' "$FOUR_BLOCK" | grep -qF 'zator_remove || echo' \
  || fail "в обработчике 4 вызов zator_remove не защищён (|| echo)"

# Обработчик 44: только zapret2, zator не трогается.
FORTYFOUR_BLOCK="$(sed -n '/^  "44")/,/^    ;;/p' "$REPO_DIR/z2r.sh")"
[ -n "$FORTYFOUR_BLOCK" ] || fail "не найден обработчик 44"
printf '%s\n' "$FORTYFOUR_BLOCK" | grep -q 'remove_zapret' \
  || fail "обработчик 44 не удаляет zapret2"
if printf '%s\n' "$FORTYFOUR_BLOCK" | grep -q 'zator_remove'; then
  fail "обработчик 44 не должен трогать zator"
fi
printf '%s\n' "$FORTYFOUR_BLOCK" | grep -qF 'remove_zapret || echo' \
  || fail "в обработчике 44 вызов remove_zapret не защищён (|| echo)"

# Внутри zator_remove сервисы остановлены безопасно.
ZR_BLOCK="$(cat "$TMP_DIR/zator_remove.fn")"
printf '%s\n' "$ZR_BLOCK" | grep -qF 'strategy_validator_remove_service || true' \
  || fail "zator_remove не защищил остановку validator (|| true)"
printf '%s\n' "$ZR_BLOCK" | grep -qF 'webui_remove || true' \
  || fail "zator_remove не защитил удаление Web-панели (|| true)"
printf '%s\n' "$ZR_BLOCK" | grep -qF 'return 1' \
  || fail "zator_remove не возвращает 1 при сбое rm"
ok "bash -n, метки 4/44 и защита вызовов"

# ===========================================================================
# 1. zator_remove: штатное удаление
# ===========================================================================
echo "== 1. zator_remove: штатное удаление =="
mkdir -p "$ZATOR_ROOT/extra_strats/cache/orchestra" "$ZATOR_ROOT/webui"
echo lock > "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv"
echo index > "$ZATOR_ROOT/webui/index.html"
: > "$MOCK_SVC_LOG"

out="$(zator_remove 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "zator_remove вернул rc=$rc при штатном удалении"
[ ! -d "$ZATOR_ROOT" ] || fail "zator_remove не снёс $ZATOR_ROOT"
printf '%s\n' "$out" | grep -q 'Каталог zator удалён' \
  || fail "zator_remove не отчитался об удалении"
grep -q '^validator$' "$MOCK_SVC_LOG" \
  || fail "zator_remove не остановил сервис strategy validator"
grep -q '^webui$' "$MOCK_SVC_LOG" \
  || fail "zator_remove не удалил Web-панель"
ok "штатное удаление: каталог снесён, сервисы остановлены, rc=0"

# ===========================================================================
# 2. zator_remove: каталога нет
# ===========================================================================
echo "== 2. zator_remove: каталога нет =="
: > "$MOCK_SVC_LOG"
out="$(zator_remove 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "zator_remove вернул rc=$rc при отсутствии каталога"
printf '%s\n' "$out" | grep -q 'Каталог zator не существует' \
  || fail "zator_remove не сообщил об отсутствии каталога"
[ ! -s "$MOCK_SVC_LOG" ] \
  || fail "при отсутствии каталога zator_remove не должен трогать сервисы"
ok "каталога нет: rc=0, сервисы не тронуты"

# ===========================================================================
# 3. zator_remove: сбой rm не роняет вызывающий код
# ===========================================================================
echo "== 3. zator_remove: сбой rm локализован =="
mkdir -p "$ZATOR_ROOT"
echo f > "$ZATOR_ROOT/file.txt"
MOCK_RM_FAIL_PATH="$ZATOR_ROOT"
export MOCK_RM_FAIL_PATH
out="$( ( set -e; zator_remove || echo "CAUGHT"; echo "LOOP_CONTINUES" ) 2>&1 )"
MOCK_RM_FAIL_PATH=""
[ -d "$ZATOR_ROOT" ] || fail "мок rm не перехватил удаление (каталог исчез)"
printf '%s\n' "$out" | grep -q 'Не удалось полностью удалить' \
  || fail "нет предупреждения о неудалённом каталоге (пользователь не видит фейл)"
printf '%s\n' "$out" | grep -q 'CAUGHT' \
  || fail "обработчик меню не поймал сбой (set -e убил бы скрипт)"
printf '%s\n' "$out" | grep -q 'LOOP_CONTINUES' \
  || fail "меню не продолжило работу после сбоя удаления"
grep -q '^webui$' "$MOCK_SVC_LOG" \
  || fail "при сбое rm панель всё равно должна быть остановлена"
ok "сбой rm локализован: предупреждение видно, меню живо"

# ===========================================================================
# 4. статика: перед сносом zapret2 в теле установщика предлагается бэкап
# ===========================================================================
echo "== 4. статика: бэкап перед remove_zapret в теле установщика =="
ctx="$(grep -B6 -E '^[[:space:]]*remove_zapret$' "$REPO_DIR/z2r.sh")"
printf '%s\n' "$ctx" | grep -q 'backup_helper_ask_and_create' \
  || fail "переустановка сносит /opt/zapret2/config без предложения бэкапа"
printf '%s\n' "$ctx" | grep -q 'ZAPRET2_ROOT/config' \
  || fail "предложение бэкапа не ограничено наличием config"
ok "бэкап предлагается до удаления zapret2 (только при наличии config)"

echo ""
echo "============================="
printf 'uninstall smoke ok (assertions: %d)\n' "$PASS"
