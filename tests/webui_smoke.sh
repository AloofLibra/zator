#!/usr/bin/env bash
#
# Smoke-тест Web-панели (Web UI) в z2r.sh: терминология, подменю и
# ЛОКАЛИЗАЦИЯ СБОЕВ (z2r.sh работает под set -e — любой незащищённый сбой
# роняет весь скрипт, поэтому каждая точка отказа webui-кода проверяется).
#
# Покрывает:
#   0. bash -n z2r.sh, отсутствие легаси-терминов (web-ssh/ttyd/web-терминал),
#      статические инварианты: промпт удаления под guard'ом [ -d "$WEBUI_ROOT" ],
#      вызов webui_remove защищён (|| true), метки «Web-панель управления».
#   1. webui_restart: сбой запуска локализован — обработчик меню под set -e
#      продолжает работу, пользователь видит сообщение об ошибке.
#   2. webui_restart: сбой остановки игнорируется (|| true).
#   3. Реальный webui_start_service через раннер (fallback-ветка без systemd):
#      раннер падает / оживает со второго вызова / отсутствует.
#   4. webui_remove: штатное удаление и неудаляемый каталог (ro-родитель).
#   5. webui_status_text: fallback stopped:none:<port>.
#   6. webui_submenu: пункт «Перезапустить Web UI» показывается только при running.
#   7. webui_submenu: UX сбоя и успеха перезапуска, «4» при stopped.
#
# ИЗОЛЯЦИЯ:
#   • Всё во временной папке /tmp (trap EXIT); реальный /opt не затрагивается.
#   • webui-функции извлекаются из z2r.sh sed-диапазонами (объявлены от колонки 0)
#     и выполняются с заглушками цветов/путей; моки переопределяются точечно
#     и восстанавливаются из сохранённых копий.
#   • Мок `clear` (no-op) в PATH: подменю не зависит от терминала.
#   • systemd-ветка webui_start_service недостижима без root (проверяет
#     [ -f /etc/systemd/system/z2r-webui.service ], файл не создаётся),
#     поэтому сбой запуска в ней покрыт моком на уровне функции (п. 1).
#
# Возврат: 0 — успех, 1 — любая ошибка (с сообщением "FAIL: ...").
# Запуск:  bash tests/webui_smoke.sh

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

# --- Заглушки глобалей z2r.sh, нужных webui-функциям ---
plain=""; cyan=""; green=""; red=""; yellow=""
Fcyan=""; Fyellow=""
OSystem="VPS"
WEBUI_PORT="17682"

TMP_DIR="$(mktemp -d /tmp/zator-webui-smoke.XXXXXX 2>/dev/null || fail "mktemp failed")"
cleanup() {
  MOCK_RM_FAIL_PATH=""
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

WEBUI_ROOT="$TMP_DIR/webui"
WEBUI_RUNNER="$WEBUI_ROOT/run-webui.sh"
export MOCK_RUNNER_LOG="$TMP_DIR/runner.log"
export MOCK_RUNNER_COUNT="$TMP_DIR/runner.count"
export MOCK_RUNNER_STATUS_FAIL="$TMP_DIR/runner.statusfail"

mkdir -p "$WEBUI_ROOT" "$TMP_DIR/bin"

# Мок clear (no-op): подменю вызывает `clear -x`.
printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/clear"
chmod +x "$TMP_DIR/bin/clear"

# Настоящий rm нужен моку для сквозного пропуска остальных вызовов.
REAL_RM="$(command -v rm)"
[ -n "$REAL_RM" ] || fail "rm не найден в PATH"

# Мок rm: детерминированный сбой удаления пути из $MOCK_RM_FAIL_PATH,
# остальные вызовы идут в настоящий rm. Имитация неудачного
# rm -rf "$WEBUI_ROOT" на любой платформе (chmod-защита от rm работает
# не везде: MSYS/Windows её игнорирует).
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

# shellcheck source=/dev/null
. "$REPO_DIR/lib/ui.sh"   # submenu_item / pause_enter

# --- Извлечение webui-функций из монолита z2r.sh ---
WEBUI_FNS="webui_start_service webui_stop_service webui_restart webui_status_text webui_print_urls webui_show_status webui_remove webui_submenu"

extract_fn() {
  sed -n "/^$1() {/,/^}/p" "$REPO_DIR/z2r.sh"
}

for fn in $WEBUI_FNS; do
  extract_fn "$fn" > "$TMP_DIR/$fn.fn"
  [ -s "$TMP_DIR/$fn.fn" ] || fail "функция $fn не найдена в z2r.sh (ожидается объявление от колонки 0)"
done

load_real() {
  local fn
  for fn in $WEBUI_FNS; do
    # shellcheck source=/dev/null
    . "$TMP_DIR/$fn.fn"
  done
}
load_real

# Фейковый раннер run-webui.sh: пишет аргументы в лог.
# Режимы: ok (всё успешно), fail (всё падает), failfirst (1-й вызов падает).
# Для сбоя status: touch "$MOCK_RUNNER_STATUS_FAIL".
make_runner() {
  {
    printf '#!/bin/sh\n'
    printf 'echo "$1" >> "$MOCK_RUNNER_LOG"\n'
    printf 'if [ "$1" = "status" ]; then\n'
    printf '  [ ! -f "$MOCK_RUNNER_STATUS_FAIL" ] || exit 1\n'
    printf '  echo "running:uhttpd:17682"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    case "$1" in
      fail)
        printf 'exit 1\n'
        ;;
      failfirst)
        printf 'n="$(cat "$MOCK_RUNNER_COUNT" 2>/dev/null || echo 0)"\n'
        printf 'n=$((n + 1)); echo "$n" > "$MOCK_RUNNER_COUNT"\n'
        printf '[ "$n" -ge 2 ] || exit 1\n'
        ;;
    esac
    printf 'exit 0\n'
  } > "$WEBUI_RUNNER"
  chmod +x "$WEBUI_RUNNER" || fail "chmod +x раннера"
}

# ===========================================================================
# 0. Синтаксис, терминология и статические инварианты
# ===========================================================================
echo "== 0. Синтаксис и терминология =="
bash -n "$REPO_DIR/z2r.sh" || fail "bash -n failed for z2r.sh"
if grep -qiE 'web-ssh|webssh|ttyd|web-терминал' "$REPO_DIR/z2r.sh"; then
  fail "в z2r.sh остались легаси-термины (web-ssh/ttyd/web-терминал)"
fi
grep -qF 'Web-панель управления (установка/обновление, ~3МБ места)' "$REPO_DIR/z2r.sh" \
  || fail "пункт меню 14 не говорит про Web-панель"
grep -qF 'Установить Web-панель управления (~3МБ места)? 1 - Да, Enter - нет' "$REPO_DIR/z2r.sh" \
  || fail "промпт установки не говорит про Web-панель"
grep -qF 'submenu_item "3" "Перезапустить Web UI"' "$REPO_DIR/z2r.sh" \
  || fail "в подменю нет пункта перезапуска Web UI"
grep -qF 'submenu_item "4" "Удалить Web UI"' "$REPO_DIR/z2r.sh" \
  || fail "в подменю нет сдвига удаления на 4 при running"
grep -qF 'webui_restart || echo -e "${red}Перезапуск Web UI не удался.${plain}"' "$REPO_DIR/z2r.sh" \
  || fail "вызов webui_restart в подменю не защищён (|| echo)"

# Промпт удаления — только под guard'ом существования /opt/zator/webui.
RP_BLOCK="$(sed -n '/^remove_zapret() {/,/^}/p' "$REPO_DIR/z2r.sh")"
[ -n "$RP_BLOCK" ] || fail "не найдена функция remove_zapret в z2r.sh"
printf '%s\n' "$RP_BLOCK" | grep -qF 'if [ -d "$WEBUI_ROOT" ]; then' \
  || fail "промпт удаления Web-панели не под guard'ом [ -d \$WEBUI_ROOT ]"
printf '%s\n' "$RP_BLOCK" | grep -qF 'Удалить Web-панель управления (webui)?' \
  || fail "в remove_zapret нет промпта удаления Web-панели"
printf '%s\n' "$RP_BLOCK" | grep -qF 'webui_remove || true' \
  || fail "вызов webui_remove в remove_zapret не защищён (|| true)"
printf '%s\n' "$RP_BLOCK" | awk '
  /if \[ -d "\$WEBUI_ROOT" \]; then/ {guard=NR}
  /Удалить Web-панель управления/    {prompt=NR}
  END {exit !(guard > 0 && prompt > guard)}
' || fail "guard [ -d \$WEBUI_ROOT ] должен идти ДО промпта удаления"

# webui_restart обязан локализовать сбои.
RR_BLOCK="$(cat "$TMP_DIR/webui_restart.fn")"
printf '%s\n' "$RR_BLOCK" | grep -qF 'webui_stop_service || true' \
  || fail "webui_restart не защищает остановку (|| true)"
printf '%s\n' "$RR_BLOCK" | grep -qF 'return 1' \
  || fail "webui_restart не возвращает 1 при сбое запуска"
ok "bash -n, терминология и статические инварианты webui-кода"

# ===========================================================================
# 1. webui_restart: сбой запуска локализован (z2r.sh под set -e)
# ===========================================================================
echo "== 1. webui_restart: сбой запуска локализован =="
webui_start_service() { return 1; }
webui_restart >/dev/null 2>&1
[ $? -eq 1 ] || fail "webui_restart должен вернуть 1 при сбое запуска"

# Имитация обработчика меню под set -e: сбой пойман, цикл меню продолжается.
out="$( ( set -e; webui_restart || echo "CAUGHT"; echo "LOOP_CONTINUES" ) 2>&1 )"
printf '%s\n' "$out" | grep -q 'Не удалось запустить Web UI' \
  || fail "webui_restart не сообщил пользователю о сбое запуска"
printf '%s\n' "$out" | grep -q 'CAUGHT' \
  || fail "обработчик меню не поймал сбой (set -e убил бы скрипт)"
printf '%s\n' "$out" | grep -q 'LOOP_CONTINUES' \
  || fail "меню не продолжило работу после сбоя перезапуска"
ok "сбой запуска: сообщение видно, set -e не роняет меню, rc=1"
load_real

# ===========================================================================
# 2. webui_restart: сбой остановки игнорируется
# ===========================================================================
echo "== 2. webui_restart: сбой остановки игнорируется =="
webui_stop_service() { return 1; }
webui_start_service() { return 0; }
out="$(webui_restart 2>&1)"
[ $? -eq 0 ] || fail "webui_restart не должен падать из-за сбоя остановки"
printf '%s\n' "$out" | grep -q 'Web UI перезапущен' \
  || fail "webui_restart не отчитался об успехе при сбое stop"
ok "сбой stop проглочен (|| true), перезапуск успешен"
load_real

# ===========================================================================
# 3. Реальный webui_start_service через раннер (fallback-ветка)
# ===========================================================================
echo "== 3. webui_start_service: раннер падает / оживает / отсутствует =="
rm -f "$MOCK_RUNNER_STATUS_FAIL"

# 3a. Раннер всегда падает: пробованы restart и start, ветка вернула ошибку.
: > "$MOCK_RUNNER_LOG"
make_runner fail
webui_start_service >/dev/null 2>&1 && fail "webui_start_service должен вернуть ошибку при падающем раннере"
grep -q '^restart$' "$MOCK_RUNNER_LOG" || fail "раннер не получил команду restart"
grep -q '^start$' "$MOCK_RUNNER_LOG" || fail "раннер не получил команду start (fallback после restart)"
ok "падающий раннер: обе попытки сделаны, ошибка возвращена"

# 3b. Полный отказ запуска через webui_restart локализован (реальный код).
out="$( ( set -e; webui_restart || echo "CAUGHT"; echo "LOOP_CONTINUES" ) 2>&1 )"
printf '%s\n' "$out" | grep -q 'Не удалось запустить Web UI' \
  || fail "webui_restart не сообщил о сбое при падающем раннере"
printf '%s\n' "$out" | grep -q 'LOOP_CONTINUES' \
  || fail "set -e: сбой раннера уронил вызывающий код"
ok "реальный сбой запуска локализован в webui_restart"

# 3c. Раннер оживает со второго вызова: restart падает, start вытягивает.
: > "$MOCK_RUNNER_LOG"; : > "$MOCK_RUNNER_COUNT"
make_runner failfirst
webui_start_service >/dev/null 2>&1 || fail "webui_start_service не спасся fallback-запуском start"
ok "раннер с падающим restart восстановился через start"

# 3d. Успешный перезапуск: stop -> restart, пользователь видит успех.
: > "$MOCK_RUNNER_LOG"
make_runner ok
out="$(webui_restart 2>&1)"
[ $? -eq 0 ] || fail "webui_restart вернул ошибку при рабочем раннере"
printf '%s\n' "$out" | grep -q 'Web UI перезапущен' || fail "webui_restart не отчитался об успехе"
awk '/^stop$/{s=NR} /^restart$/{r=NR} END{exit !(s>0 && r>0 && s<r)}' "$MOCK_RUNNER_LOG" \
  || fail "порядок stop->restart не соблюдён (log: $(cat "$MOCK_RUNNER_LOG" | tr '\n' ' '))"
ok "успешный перезапуск: stop -> restart, сообщение об успехе"

# 3e. Раннер отсутствует: ошибка возвращена, не молчание.
rm -f "$WEBUI_RUNNER"
webui_start_service >/dev/null 2>&1 && fail "отсутствующий раннер должен давать ошибку запуска"
ok "отсутствующий раннер: ошибка запуска возвращена"

# ===========================================================================
# 4. webui_remove: штатное удаление и неудаляемый каталог
# ===========================================================================
echo "== 4. webui_remove: удаление и сбой rm =="
mkdir -p "$WEBUI_ROOT/www"
echo x > "$WEBUI_ROOT/www/index.html"
out="$(webui_remove 2>&1)"
[ $? -eq 0 ] || fail "webui_remove вернул ошибку при штатном удалении (rc=$?)"
[ ! -d "$WEBUI_ROOT" ] || fail "webui_remove не удалил каталог панели"
printf '%s\n' "$out" | grep -q 'Web UI удалён' || fail "webui_remove не отчитался об удалении"
ok "штатное удаление: каталог снесён, rc=0"

# Неудаляемый каталог (мок rm): сбой rm не роняет вызывающий код,
# пользователь видит предупреждение. Детерминированно на любой платформе.
RO_TARGET="$TMP_DIR/undeletable"
mkdir -p "$RO_TARGET"
echo f > "$RO_TARGET/file.txt"
WEBUI_ROOT_SAVED="$WEBUI_ROOT"
WEBUI_ROOT="$RO_TARGET"
MOCK_RM_FAIL_PATH="$RO_TARGET"
export MOCK_RM_FAIL_PATH
out="$( ( set -e; webui_remove; echo "SURVIVED" ) 2>&1 )"
MOCK_RM_FAIL_PATH=""
WEBUI_ROOT="$WEBUI_ROOT_SAVED"
[ -d "$RO_TARGET" ] || fail "мок rm не перехватил удаление (каталог исчез)"
printf '%s\n' "$out" | grep -q 'SURVIVED' || fail "set -e: неудачный rm уронил вызывающий код"
printf '%s\n' "$out" | grep -q 'Не удалось полностью удалить' \
  || fail "нет предупреждения о неудалённом каталоге (пользователь не видит фейл)"
printf '%s\n' "$out" | grep -q 'Web UI удалён' || fail "webui_remove не завершился штатно при сбое rm"
ok "сбой rm локализован, предупреждение видно пользователю"
mkdir -p "$WEBUI_ROOT"

# ===========================================================================
# 5. webui_status_text: fallback без раннера и при его сбое
# ===========================================================================
echo "== 5. webui_status_text: fallback =="
rm -f "$WEBUI_RUNNER" "$MOCK_RUNNER_STATUS_FAIL"
[ "$(webui_status_text)" = "stopped:none:17682" ] \
  || fail "без раннера статус должен быть stopped:none:17682 (got: $(webui_status_text))"
make_runner ok
[ "$(webui_status_text)" = "running:uhttpd:17682" ] \
  || fail "рабочий раннер должен отдавать running:uhttpd:17682 (got: $(webui_status_text))"
touch "$MOCK_RUNNER_STATUS_FAIL"
[ "$(webui_status_text)" = "stopped:none:17682" ] \
  || fail "сбой раннера должен давать fallback stopped:none:17682 (got: $(webui_status_text))"
rm -f "$MOCK_RUNNER_STATUS_FAIL"
ok "статус: раннер есть/нет/падает — все ветки корректны"

# ===========================================================================
# 6. webui_submenu: пункт перезапуска только при running
# ===========================================================================
echo "== 6. Подменю: отрисовка по состоянию =="
webui_status_text() { echo "running:uhttpd:17682"; }
out="$(printf '0\n' | webui_submenu 2>&1)"
printf '%s\n' "$out" | grep -q 'Состояние: running:uhttpd:17682' || fail "подменю не показывает статус"
printf '%s\n' "$out" | grep -q '3. Перезапустить Web UI' || fail "при running нет пункта 3 (Перезапустить)"
printf '%s\n' "$out" | grep -q '4. Удалить Web UI' || fail "при running нет пункта 4 (Удалить)"

webui_status_text() { echo "stopped:none:17682"; }
out="$(printf '0\n' | webui_submenu 2>&1)"
printf '%s\n' "$out" | grep -q '3. Удалить Web UI' || fail "при stopped нет пункта 3 (Удалить)"
if printf '%s\n' "$out" | grep -q 'Перезапустить'; then
  fail "при stopped не должно быть пункта перезапуска"
fi
ok "отрисовка: перезапуск показывается только при running"
load_real

# ===========================================================================
# 7. webui_submenu: UX перезапуска (успех/сбой) и «4» при stopped
# ===========================================================================
echo "== 7. Подменю: UX перезапуска =="
# 7a. Реальный код: раннер работает, выбор 3 перезапускает и показывает статус.
make_runner ok
: > "$MOCK_RUNNER_LOG"
out="$(printf '3\n\n0\n' | webui_submenu 2>&1)"
printf '%s\n' "$out" | grep -q 'Web UI перезапущен' || fail "выбор 3 не привёл к перезапуску"
printf '%s\n' "$out" | grep -q 'running:uhttpd:17682' || fail "после перезапуска не показан статус"
printf '3\n\n0\n' | webui_submenu >/dev/null 2>&1
[ $? -eq 0 ] || fail "подменю упало после перезапуска (rc=$?)"
ok "выбор 3 при running: перезапуск + статус, выход штатный"

# 7b. Перезапуск падает: пользователь видит ошибку, меню продолжает работу.
webui_restart() { echo "MOCK_RESTART_FAIL"; return 1; }
out="$(printf '3\n\n0\n' | webui_submenu 2>&1)"
rc=$?
[ $rc -eq 0 ] || fail "подменю упало после сбоя перезапуска (rc=$rc)"
printf '%s\n' "$out" | grep -q 'MOCK_RESTART_FAIL' || fail "перезапуск не вызывался"
printf '%s\n' "$out" | grep -q 'Перезапуск Web UI не удался' || fail "нет сообщения о сбое перезапуска"
load_real

# 7c. «4» при stopped — неверный ввод (пункт сдвигается только при running).
webui_status_text() { echo "stopped:none:17682"; }
out="$(printf '4\n0\n' | webui_submenu 2>&1)"
printf '%s\n' "$out" | grep -q 'Неверный ввод' || fail "4 при stopped должен быть неверным вводом"
load_real

ok "UX: сбой перезапуска виден пользователю, меню живо; 4 при stopped отклонён"

# 8. статика: промпт установки панели знает о её наличии (обновить/установить)
grep -q 'Web-панель управления уже установлена' "$REPO_DIR/z2r.sh" \
  || fail "нет промпта обновления уже установленной Web-панели"
grep -q 'Пропуск обновления Web-панели' "$REPO_DIR/z2r.sh" \
  || fail "нет ветки пропуска обновления Web-панели"
ok "промпт Web-панели зависит от её наличия"

echo ""
echo "============================="
printf 'webui smoke ok (assertions: %d)\n' "$PASS"
