#!/usr/bin/env bash

# Смоук суперавтопрогона (lib/supersweep.sh): параллельный подбор стратегий
# профилей 1/2/4 + карта покрытий РКН-доменов. Только /tmp, без /opt и без
# настоящей сети: curl замокан и отвечает зелёным/красным в зависимости от
# РЕАЛЬНОГО текущего лока в locked.tsv — так сквозно проверяется весь путь
# «воркер -> cmd-файл -> координатор -> orch_locked_set -> движок z2r_tls_*».

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/zator-supersweep.XXXXXX)"
trap 'test "${SMOKE_KEEP:-0}" = 1 || rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

# --- мок curl: стратегия берётся из живого lock-файла ----------------------

cat > "$TMP_DIR/bin/curl" <<'MOCK'
#!/bin/sh
[ -n "${MOCK_DELAY:-}" ] && sleep "$MOCK_DELAY" 2>/dev/null
url=""
hdr=""
head=0
prev=""
for arg in "$@"; do
  [ "$prev" = "-D" ] && hdr="$arg"
  [ "$arg" = "-I" ] && head=1
  case "$arg" in
    https://*) url="$arg" ;;
    --tlsv1.3) ver=13 ;;
    --tlsv1.2) ver=12 ;;
  esac
  prev="$arg"
done
host="$(printf '%s' "$url" | sed -e 's#^[a-z]*://##' -e 's#/.*##' -e 's/:.*//')"
prof=""
case "$host" in
  *googlevideo.com*) prof=2 ;;
  *youtube.com*)     prof=1 ;;
  *discord.com*)     prof=4 ;;
esac
if [ -n "$prof" ]; then
  strat="$(awk -F'\t' -v p="$prof" '$1==p && $2=="tls" {print $3; exit}' "$ORCH_LOCK_FILE" 2>/dev/null)"
else
  strat="$(awk -F'\t' -v h="$host" '$1==h {if (NF>=3 && $2=="tls") print $3; else if (NF==2) print $2; exit}' "$ORCH_LOCK_FILE" 2>/dev/null)"
fi
ok=""
tag=""
if [ -n "$prof" ]; then
  eval "ok=\${MOCK_OK_P${prof}:-}"
else
  tag="$(printf '%s' "$host" | tr '.' '_')"
  eval "ok=\${MOCK_OK_${tag}:-}"
fi
green=0
if [ -n "$strat" ]; then
  case " $ok " in
    *" $strat "*) green=1 ;;
  esac
fi
# partial mode: tls 1.2 times out, tls 1.3 answers -> engine sees WARN
half=0
if [ -z "$prof" ] && [ -n "$tag" ]; then
  eval "half=\${MOCK_HALF_${tag}:-0}"
fi
if [ "$head" = 1 ]; then
  # partial mode: tls 1.2 times out even when the strategy is green
  okhead=0
  if [ "$green" = 1 ]; then
    if [ "$half" != 1 ] || [ "$ver" = 13 ]; then okhead=1; fi
  fi
  if [ "$okhead" = 1 ]; then
    [ -n "$hdr" ] && printf 'HTTP/2 200\r\n' >"$hdr"
    echo "0.800 192.0.2.10"
    exit 0
  fi
  echo "8.004 -"
  exit 28
fi
if [ "$green" = 1 ]; then
  t="$(awk -v s="${strat:-0}" 'BEGIN{printf "%.3f", 2.6 - 0.1 * s}')"
  echo "206 65536 $t"
  exit 0
fi
echo "000 0 12.002"
exit 28
MOCK
mkdir -p "$TMP_DIR/bin"
chmod +x "$TMP_DIR/bin/curl" 2>/dev/null || true
export PATH="$TMP_DIR/bin:$PATH"
export TMPDIR="$TMP_DIR"

# --- окружение --------------------------------------------------------------

ROOT="$TMP_DIR/zapret2"
CFG="$ROOT/config"
ORCH="$ROOT/orchestra"
export ORCH_DIR="$ORCH"
export ORCH_LOCK_FILE="$ORCH/locked.tsv"
export CONFIG_FILE="$CFG"
export ZATOR_ROOT="$TMP_DIR/zator"
export Z2R_SUPERSWEEP_DIR="$TMP_DIR/supersweep"
export Z2R_SUPERSWEEP_ARCHIVE_DIR="$TMP_DIR/archives"
export Z2R_SUPERSWEEP_SETTLE=0
# статистику не шлём (дефолтный URL теперь боевой сервер автора) и играем
# телеметрию-заглушку для uuid в имени архива и meta.tsv
export Z2R_SUPERSWEEP_STATS_URL=""
export TELEMETRY_CFG="$TMP_DIR/telemetry.config"
printf 'tel_enabled=1\ntel_uuid=deadbeef\n' > "$TELEMETRY_CFG"
export Z2R_SWEEP_PAUSE=0
# зелёный ускоритель в тестах выключен: паузы остаются нулевыми
export Z2R_SUPERSWEEP_GREEN_PAUSE=0
export Z2R_SUPERSWEEP_ARCHIVE_KEEP=3
mkdir -p "$ORCH" "$ROOT" "$ZATOR_ROOT/extra_strats"
: > "$ORCH_LOCK_FILE"

# урезанный конфиг: стратегии 1-5 в шаблоне и во всех блоках (быстрый прогон)
trim_config() {
  tr -d '\r' < "$REPO_DIR/config.default" \
    | sed -E '/strategy=(6|7|8|9|[1-3][0-9]|4[0-3])([^0-9]|$)/d' > "$1"
}
trim_config "$CFG"

plain="" green="" yellow="" red="" cyan="" Fgreen="" Fcyan="" Fyellow=""
export plain green yellow red cyan Fgreen Fcyan Fyellow

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/ui.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/netcheck.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/strategies.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/supersweep.sh"

# конфиг живёт во временной папке: get_config_file без аргументов ищет /opt
get_config_file() { printf '%s\n' "$CFG"; }

lock_state() { orch_locked_state_get "$1" "$2"; }

# == 0. синтаксис и статический wiring ==

for f in lib/supersweep.sh z2r.sh lib/submenus.sh; do
  bash -n "$REPO_DIR/$f" || fail "синтаксис $f"
done
grep -q '^Z2R_LIB_FILES=".*supersweep\.sh' "$REPO_DIR/z2r.sh" || fail "Z2R_LIB_FILES не содержит supersweep.sh"
grep -q 'source "$LIB_DIR/supersweep.sh"' "$REPO_DIR/z2r.sh" || fail "z2r.sh не source-ит supersweep.sh"
grep -q 'supersweep_menu' "$REPO_DIR/lib/submenus.sh" || fail "подменю стратегий не зовёт supersweep_menu"
grep -q 'Суперавтопрогон' "$REPO_DIR/lib/submenus.sh" || fail "подменю стратегий без пункта Суперавтопрогон"
grep -q 'MENU_AUTO_MODE' "$REPO_DIR/lib/supersweep.sh" || fail "supersweep_menu не проверяет авторотацию"
grep -q 'zapret2_running' "$REPO_DIR/lib/supersweep.sh" || fail "supersweep_menu не проверяет nfqws2"
# голый wait в воркерах запрещён (bash 5.3+ спамит по собранным джобам)
if grep -nEq '^[[:space:]]*wait[[:space:]]*$' "$REPO_DIR/lib/supersweep.sh"; then
  fail "supersweep.sh: голый wait — ждать можно только по явным pid"
fi
# строка-продолжление текста без echo/команды — валидный синтаксис, но
# падает в рантайме («command not found», ловили на живом роутере)
if grep -nE '^[[:space:]]*"[^"]*"[[:space:]]*$' "$REPO_DIR/lib/supersweep.sh"; then
  fail "supersweep.sh: голая строка в кавычках без команды — потерян echo?"
fi
# гейт подмены DNS сверяет ЭТАЛОННЫЙ домен (rutracker.org), а не первый
# пользовательский — набор доменов меняется, эталон нет (регрессия 2026-10)
grep -q 'z2r_dns_spoof_gate "${Z2R_DNS_REF_DOMAIN:-rutracker.org}"' "$REPO_DIR/lib/supersweep.sh" \
  || fail "гейт DNS должен вызываться по эталонному домену, а не по первому пользовательскому"
# отмена прогона не роняет меню: вызов защищён от возврата 1 под глобальным
# set -e z2r.sh, повторный Ctrl+C в сводке/паузе глушится trap'ом
grep -q 'supersweep_run "$tls_pref" "$pause" "$ds_pause" "$rkn_pause" 1 $domains || ss_run_rc=$?' \
  "$REPO_DIR/lib/supersweep.sh" || fail "вызов supersweep_run не защищён от возврата 1 (set -e)"
grep -q "trap ':' INT" "$REPO_DIR/lib/supersweep.sh" || fail "нет глушения INT после прерывания прогона"
grep -q '_supersweep_estimate_total' "$REPO_DIR/lib/supersweep.sh" \
  || fail "нет единой формулы оценки времени (меню и шапка считают одним кодом)"
grep -q 'pacing.tsv' "$REPO_DIR/lib/supersweep.sh" || fail "нет pacing-файла фактических пауз воркеров"
# архивация/отправка ДО интерактивного вопроса про жёлтые: пользователь может
# не отвечать сколько угодно — результаты уже на сервере
arc_ln="$(grep -n 'Архив результатов: ' "$REPO_DIR/lib/supersweep.sh" | cut -d: -f1 | head -n1)"
sum_ln="$(grep -n 'автоматическое применение лучших стратегий' "$REPO_DIR/lib/supersweep.sh" | cut -d: -f1 | head -n1)"
[ -n "$arc_ln" ] && [ -n "$sum_ln" ] && [ "$arc_ln" -lt "$sum_ln" ] \
  || fail "архив результатов должен печататься до сводки (и вопроса про жёлтые)"
# совет перезагрузки при полном красе YouTube: общая функция в netcheck,
# зовут её оба прогона; WAN-порт — из config_get_iface_wan
grep -q 'z2r_youtube_reboot_advice()' "$REPO_DIR/lib/netcheck.sh" \
  || fail "нет функции совета перезагрузки в netcheck.sh"
grep -q 'z2r_youtube_reboot_advice' "$REPO_DIR/lib/supersweep.sh" \
  || fail "суперавтопрогон не зовёт совет перезагрузки"
grep -q 'z2r_youtube_reboot_advice' "$REPO_DIR/lib/strategies.sh" \
  || fail "автопрогон не зовёт совет перезагрузки"
grep -q 'config_get_iface_wan' "$REPO_DIR/lib/netcheck.sh" \
  || fail "совет перезагрузки не показывает WAN-порт"

# == 1. полный прогон: применение лучших + карта + восстановление доменов ==

[ "$(config_profile_max_strategy 1 "$CFG")" = 5 ] || fail "мок-конфиг: профиль 1 должен иметь 5 стратегий"
[ "$(config_profile_max_strategy 4 "$CFG")" = 5 ] || fail "мок-конфиг: профиль 4 должен иметь 5 стратегий"

# прежние локи: профиль 1 = 3, meduza = 1 (остальных нет)
orch_locked_set 1 tls 3
orch_locked_set meduza.io tls 1
# режим фейков профиля 4 в клонах: должен попасть в meta.tsv архива (mode_4)
mode_override_set 4 clone

# зелёные стратегии: у профилей и доменов разные наборы; скорость докачки
# растёт с номером стратегии (2.6 - 0.1*N) — «лучшая» = максимальный зелёный
export MOCK_OK_P1="2 4" MOCK_OK_P2="3" MOCK_OK_P4="1 5"
export MOCK_OK_meduza_io="1 2" MOCK_OK_xhamster_com="2" MOCK_OK_chess_com="2"

out="$(supersweep_run both 0 0 0 2 meduza.io xhamster.com chess.com 2>&1)" || {
  printf '%s\n' "$out" >&2
  fail "сценарий 1: supersweep_run вернул ошибку"
}

[ "$(lock_state 1 tls)" = 4 ] || fail "сценарий 1: профиль 1 должен получить стратегию 4, а не $(lock_state 1 tls)"
[ "$(lock_state 1 http)" = 4 ] || fail "сценарий 1: профиль 1/http должен получить 4"
[ "$(lock_state 2 tls)" = 3 ] || fail "сценарий 1: профиль 2 должен получить стратегию 3"
[ "$(lock_state 4 tls)" = 5 ] || fail "сценарий 1: профиль 4 должен получить стратегию 5"
# пер-доменное применение + профильная строка максимума покрытия: каждый
# домен получает свою зелёную стратегию, профиль 3 — победителя покрытия
# (медуза: зелёные 1 и 2, у меньшего номера выше скорость докачки в моке;
# стратегия 2 зелёная на всех трёх доменах)
[ "$(lock_state 3 tls)" = 2 ] || fail "сценарий 1: профиль 3 должен получить max-coverage стратегию 2, а не $(lock_state 3 tls)"
[ "$(lock_state meduza.io tls)" = 2 ] || fail "сценарий 1: meduza.io должен получить свой победитель 2 (быстрейший зелёный), а не $(lock_state meduza.io tls)"
[ "$(lock_state xhamster.com tls)" = 2 ] || fail "сценарий 1: xhamster.com должен получить стратегию 2, а не $(lock_state xhamster.com tls)"
[ "$(lock_state chess.com tls)" = 2 ] || fail "сценарий 1: chess.com должен получить стратегию 2, а не $(lock_state chess.com tls)"

# прогресс-файлы для веб-панели
[ -f "$Z2R_SUPERSWEEP_DIR/status" ] || fail "сценарий 1: нет status-файла"
grep -q '^state=done$' "$Z2R_SUPERSWEEP_DIR/status" || fail "сценарий 1: state != done"
[ "$(wc -l < "$Z2R_SUPERSWEEP_DIR/workers.tsv")" = 4 ] || fail "сценарий 1: workers.tsv должен иметь 4 воркера"
[ "$(wc -l < "$Z2R_SUPERSWEEP_DIR/progress.yt.tsv")" = 5 ] || fail "сценарий 1: progress.yt.tsv должен иметь 5 строк (по числу стратегий)"
[ "$(awk -F'\t' 'NF!=9' "$Z2R_SUPERSWEEP_DIR/progress.yt.tsv" | wc -l)" = 0 ] \
  || fail "сценарий 1: строки progress.yt.tsv должны иметь 9 колонок"
# полная матрица (рекомендация автора): каждая стратегия x каждый домен
[ "$(wc -l < "$Z2R_SUPERSWEEP_DIR/coverage.tsv")" = 15 ] || fail "сценарий 1: coverage.tsv = 5 стратегий x 3 домена = 15 строк, а не $(wc -l < "$Z2R_SUPERSWEEP_DIR/coverage.tsv")"
[ "$(awk -F'\t' '$3 >= 1 && $3 <= 5' "$Z2R_SUPERSWEEP_DIR/coverage.tsv" | wc -l)" = 15 ] \
  || fail "сценарий 1: все стратегии 1-5 должны быть на всех доменах"
grep -q '^winner=2$' "$Z2R_SUPERSWEEP_DIR/best.rkn" || fail "сценарий 1: winner должен быть 2"
grep -q '^winner_cover=3$' "$Z2R_SUPERSWEEP_DIR/best.rkn" || fail "сценарий 1: winner_cover должен быть 3"
grep -q '^winner_total=3$' "$Z2R_SUPERSWEEP_DIR/best.rkn" || fail "сценарий 1: winner_total должен быть 3"
grep -q $'profile\t1\t4' "$Z2R_SUPERSWEEP_DIR/summary.tsv" || fail "сценарий 1: summary.tsv без profile 1 -> 4"
grep -q $'profile\t3\t2' "$Z2R_SUPERSWEEP_DIR/summary.tsv" || fail "сценарий 1: summary.tsv без profile 3 -> 2"
grep -q 'Применена стратегия 4' <<<"$out" || fail "сценарий 1: нет строки применения для профиля 1"
grep -q 'воркер завершён' <<<"$out" || fail "сценарий 1: применение не помечено как немедленное"
grep -q 'РКН: домен meduza.io — применена стратегия 2' <<<"$out" || fail "сценарий 1: нет пер-доменного применения meduza"
grep -q 'РКН: домен xhamster.com — применена стратегия 2' <<<"$out" || fail "сценарий 1: нет пер-доменного применения xhamster"
grep -q 'Персональные стратегии применены' <<<"$out" || fail "сценарий 1: нет сводки пер-доменных применений"
[ "$(wc -l < "$Z2R_SUPERSWEEP_DIR/applied.tsv" 2>/dev/null || echo 0)" = 7 ] \
  || fail "сценарий 1: applied.tsv должен иметь 7 строк (3 профиля + профильная РКН + 3 домена)"
grep -q $'profile\t1\t4' "$Z2R_SUPERSWEEP_DIR/applied.tsv" || fail "сценарий 1: applied.tsv без profile 1 -> 4"
grep -q $'profile\t3\t2' "$Z2R_SUPERSWEEP_DIR/applied.tsv" || fail "сценарий 1: applied.tsv без profile 3 -> 2 (max-coverage)"
grep -q $'domain	meduza.io	2' "$Z2R_SUPERSWEEP_DIR/applied.tsv" || fail "сценарий 1: applied.tsv без domain meduza.io -> 2"
grep -q $'domain\txhamster.com\t2' "$Z2R_SUPERSWEEP_DIR/applied.tsv" || fail "сценарий 1: applied.tsv без domain xhamster.com -> 2"
grep -q 'РКН: домен chess.com — применена стратегия 2' <<<"$out" || fail "сценарий 1: нет пер-доменного применения chess"
grep -q 'Профиль 3 (РКН): применена стратегия 2' <<<"$out" || fail "сценарий 1: нет применения профильной стратегии РКН"
grep -q 'Профильная стратегия РКН (дефолт всего списка): 2' <<<"$out" || fail "сценарий 1: сводка без профильной стратегии РКН"
grep -q 'медуза\|meduza.io' <<<"$out" || fail "сценарий 1: в отчёте нет рекомендаций по доменам"
grep -q 'Зелёные\|Рабочие' <<<"$out" || fail "сценарий 1: в отчёте нет списков рабочих стратегий"
# pacing-файл: фактические паузы воркеров. Пауза 0 + ускоритель выключен
# (GREEN_PAUSE=0 = обычная пауза) -> все нули; yt пишет по строке на каждую
# стратегию, кроме последней
[ -f "$Z2R_SUPERSWEEP_DIR/pacing.tsv" ] || fail "сценарий 1: нет pacing.tsv"
[ "$(awk -F'\t' '$1=="yt"' "$Z2R_SUPERSWEEP_DIR/pacing.tsv" | wc -l)" = 4 ] \
  || fail "сценарий 1: yt-воркер должен записать 4 паузы (все стратегии, кроме последней)"
[ "$(awk -F'\t' '$1=="yt" && $3!="0"' "$Z2R_SUPERSWEEP_DIR/pacing.tsv" | wc -l)" = 0 ] \
  || fail "сценарий 1: при паузе 0 и выключенном ускорителе все паузы должны быть 0"
[ "$(awk -F'\t' '$1=="rkn"' "$Z2R_SUPERSWEEP_DIR/pacing.tsv" | wc -l)" = 15 ] \
  || fail "сценарий 1: rkn-воркер должен записать 15 пауз (5 стратегий x 3 домена)"
# зелёные есть — совета перезагрузки быть не должно
if grep -q 'ПЕРЕЗАГРУЗИТЬ РОУТЕР' <<<"$out"; then
  fail "сценарий 1: совет перезагрузки появился при зелёных стратегиях"
fi

# архив результатов (с prev.tsv внутри) появился
archives="$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tar 2>/dev/null || true)"
[ -n "$archives" ] || fail "сценарий 1: архив результатов не создан"
tgz="$(printf '%s\n' "$archives" | head -n1)"
# список во временный файл: grep -q в трубе роняет tar по SIGPIPE (pipefail)
tar -tf "$tgz" > "$TMP_DIR/tarlist.txt" 2>/dev/null || fail "сценарий 1: архив не читается"
grep -q 'prev.tsv' "$TMP_DIR/tarlist.txt" || fail "сценарий 1: в архиве нет prev.tsv"
grep -q 'coverage.tsv' "$TMP_DIR/tarlist.txt" || fail "сценарий 1: в архиве нет coverage.tsv"

# == 2. отмена: прежние локи восстановлены, статус cancelled ==

: > "$ORCH_LOCK_FILE"
orch_locked_set 1 tls 3
orch_locked_set 2 tls 2
# старый каталог прогона убираем ДО старта: цикл ниже ждёт progress-файл
# именно нового запуска (иначе ловится остаток сценария 1)
rm -rf "$Z2R_SUPERSWEEP_DIR"
# каждый curl чуть медленнее — прогон из 5 стратегий гарантированно длиннее
# ожидания отмены (детерминизм на быстрых машинах)
export MOCK_DELAY=0.2
export MOCK_OK_P1="2 4 6" MOCK_OK_P2="3 7" MOCK_OK_P4="1 5"
export MOCK_OK_meduza_io="1 2" MOCK_OK_xhamster_com="2" MOCK_OK_chess_com="2"

supersweep_run both 0 0 0 1 meduza.io xhamster.com chess.com >"$TMP_DIR/cancel.log" 2>&1 &
RUN_PID=$!
# ждём первых результатов и отменяем внешним механизмом (как сделает веб-панель)
n=0
while [ "$n" -lt 200 ]; do
  [ -s "$Z2R_SUPERSWEEP_DIR/progress.yt.tsv" ] && break
  sleep 0.1 2>/dev/null || sleep 1
  n=$((n + 1))
done
[ -s "$Z2R_SUPERSWEEP_DIR/progress.yt.tsv" ] || fail "сценарий 2: прогон не начал писать progress"
supersweep_cancel_running || fail "сценарий 2: supersweep_cancel_running не создал cancel-файл"
rc=0
wait "$RUN_PID" || rc=$?
[ "$rc" = 1 ] || fail "сценарий 2: отменённый прогон должен вернуть 1, вернул $rc"

[ "$(lock_state 1 tls)" = 3 ] || fail "сценарий 2: профиль 1 не восстановлен ($(lock_state 1 tls))"
[ "$(lock_state 2 tls)" = 2 ] || fail "сценарий 2: профиль 2 не восстановлен ($(lock_state 2 tls))"
[ "$(lock_state 4 tls)" = auto ] || fail "сценарий 2: профиль 4 должен быть auto ($(lock_state 4 tls))"
[ "$(lock_state meduza.io tls)" = auto ] || fail "сценарий 2: meduza.io должен быть auto ($(lock_state meduza.io tls))"
[ "$(lock_state xhamster.com tls)" = auto ] || fail "сценарий 2: xhamster.com должен быть auto ($(lock_state xhamster.com tls))"
# профиль 3 в отменённом прогоне не применялся и не менялся
[ "$(lock_state 3 tls)" = auto ] || fail "сценарий 2: профиль 3 должен остаться auto ($(lock_state 3 tls))"
grep -q '^state=cancelled$' "$Z2R_SUPERSWEEP_DIR/status" || fail "сценарий 2: state != cancelled"
grep -q 'откатлены\|возвращаю прежние' "$TMP_DIR/cancel.log" || fail "сценарий 2: нет сообщения об откате"
# пустой прерванный прогон НЕ архивируется и НЕ отправляется (регрессия:
# «Архив отправлен на сервер статистики» уходил даже при пустой сводке и
# полном откате)
grep -q 'ничего не отправлено' "$TMP_DIR/cancel.log" \
  || fail "сценарий 2: пустой прерванный прогон должен сообщить об отсутствии отправки"
new_archives="$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tar 2>/dev/null | wc -l)"
[ "$new_archives" = 1 ] \
  || fail "сценарий 2: пустой прерванный прогон не должен создавать архив (архивов: $new_archives)"

# ротация архивов: KEEP=3, наделаем пустышек и проверим уборку
for i in 1 2 3 4; do
  : > "$Z2R_SUPERSWEEP_ARCHIVE_DIR/supersweep-2000010${i}-000000.tar"
done
ls -1t "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tar >/dev/null 2>&1
supersweep_results_archive >/dev/null || fail "сценарий 2: архиватор упал"
[ "$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tar | wc -l)" = 3 ] \
  || fail "сценарий 2: ротация архивов не держит лимит KEEP=3"

# == 4. архив: PATH-tar без create (busybox) -> fallback на явный tar ==

# лимит поднят: ротация не должна съедать сам проверяемый архив
export Z2R_SUPERSWEEP_ARCHIVE_KEEP=10
REAL_TAR="$(command -v tar)"
mkdir -p "$TMP_DIR/bin2"
cat > "$TMP_DIR/bin2/tar" <<'TARMOCK'
#!/bin/sh
# fake busybox tar: create mode is not compiled in
echo "tar: invalid option -- 'c'" >&2
exit 1
TARMOCK
chmod +x "$TMP_DIR/bin2/tar"
before="$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tar 2>/dev/null | wc -l)"
# имя архива с точностью до секунды: гарантируем новое, а не перезапись
sleep 1.1 2>/dev/null || sleep 2
fb_out="$(PATH="$TMP_DIR/bin2:$PATH" Z2R_SUPERSWEEP_TAR="$REAL_TAR" supersweep_results_archive)" \
  || fail "сценарий 4: fallback-цепочка tar не сработала"
fb_tgz="$(printf '%s' "$fb_out" | cut -f1)"
[ -n "$fb_tgz" ] && [ -f "$fb_tgz" ] || fail "сценарий 4: fallback-архив не создан"
after="$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tar 2>/dev/null | wc -l)"
[ "$after" = "$((before + 1))" ] || fail "сценарий 4: архив через fallback не добавлен (${before} -> ${after})"
tar -tf "$fb_tgz" > "$TMP_DIR/tarlist2.txt" 2>/dev/null || fail "сценарий 4: fallback-архив не читается"
# прогон перед этим был отменён рано: coverage мог не успеть появиться,
# поэтому сверяем гарантированно существующие файлы прогона
grep -q 'status' "$TMP_DIR/tarlist2.txt" || fail "сценарий 4: в fallback-архиве нет status"
grep -q 'progress.yt.tsv' "$TMP_DIR/tarlist2.txt" || fail "сценарий 4: в fallback-архиве нет progress.yt.tsv"

# == 5. свежий архив результатов едет в регулярном бэкапе ==
# z2r_backup_state_files (lib/actions.sh) добавляет самый новый supersweep-*.tar
# к списку файлов бэкапа рядом с locked.tsv; проверяем на извлечённой функции
# (как webui_smoke гоняет функции z2r.sh) — без /opt и без всего actions.sh
eval "$(sed -n '/^z2r_backup_state_files()/,/^}/p' "$REPO_DIR/lib/actions.sh")" \
  || fail "сценарий 5: не удалось извлечь z2r_backup_state_files"
ss_arc_dir="$ZATOR_ROOT/extra_strats/cache/orchestra/supersweep"
mkdir -p "$ss_arc_dir"
: > "$ss_arc_dir/supersweep-20000101-000000.tar"
touch -t 202001010000 "$ss_arc_dir/supersweep-20000101-000000.tar"
: > "$ss_arc_dir/supersweep-20000202-020202.tar"
touch -t 202002020202 "$ss_arc_dir/supersweep-20000202-020202.tar"
bl="$(z2r_backup_state_files)"
grep -q '^extra_strats/cache/orchestra/locked.tsv$' <<<"$bl" || fail "сценарий 5: в списке бэкапа нет locked.tsv"
grep -q '^extra_strats/cache/orchestra/supersweep/supersweep-20000202-020202\.tar$' <<<"$bl" \
  || fail "сценарий 5: свежий supersweep-архив не попал в список бэкапа"
[ "$(grep -c 'supersweep/' <<<"$bl")" = 1 ] \
  || fail "сценарий 5: в списке бэкапа больше одного supersweep-архива (нужен только последний)"
# без архивов список не меняется
rm -rf "$ss_arc_dir"
bl2="$(z2r_backup_state_files)"
[ "$(grep -c 'supersweep' <<<"$bl2")" = 0 ] || fail "сценарий 5: без архивов supersweep-строки быть не должно"

# == 6. диалог своих доменов: нормализация + добавление в TCP_Custom ==

rm -f "$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
sel="$(printf 'mydom.ru https://bad domain-name.example\n' | supersweep_ask_own_domains "meduza.io" 2>/dev/null)" || \
  fail "сценарий 6: ask_own_domains упал"
[ "$sel" = "meduza.io mydom.ru domain-name.example" ] \
  || fail "сценарий 6: stdout диалога обязан нести ТОЛЬКО домены, получено: [$sel]"
[ "$(grep -c 'domain-name.example' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt")" = 1 ] \
  || fail "сценарий 6: домен не записан в TCP_Custom.txt ровно один раз"
[ "$(grep -c '^bad$\|^mydom.ru$' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt")" = 1 ] \
  || fail "сценарий 6: в TCP_Custom должен попасть только mydom.ru, а не bad"

# == 7. контракт диалогов: stdout несёт ТОЛЬКО ответ, весь текст — в stderr ==
# регрессия: заголовок «Домены РКН для карты покрытий» однажды попадал в
# захваченный stdout и превращался в «домены» прогона (Invalid lock profile)

d_all="$(printf '\n' | supersweep_ask_domains 2>/dev/null)" || fail "сценарий 7: ask_domains упал"
[ "$d_all" = "xhamster.com anidub.com amnezia.org" ] \
  || fail "сценарий 7: Enter должен вернуть дефолтный набор автора (3 домена), получено: [$d_all]"
d_sub="$(printf '1 3\n' | supersweep_ask_domains 2>/dev/null)" || fail "сценарий 7: ask_domains (1 3) упал"
[ "$d_sub" = "xhamster.com amnezia.org" ] \
  || fail "сценарий 7: выбор 1 3 должен вернуть xhamster.com amnezia.org, получено: [$d_sub]"
d_zero_rc=0
printf '0\n' | supersweep_ask_domains >/dev/null 2>&1 || d_zero_rc=$?
[ "$d_zero_rc" != 0 ] || fail "сценарий 7: 0 должен отменять выбор доменов"

# санитайзер движка: мусор отбрасывается с предупреждением, дублики схлопываются
san="$(supersweep_sanitize_domains 'Домены meduza.io РКН https://xhamster.com/x 1. meduza.io' 2>/dev/null)" \
  || fail "сценарий 7: sanitize упал"
[ "$san" = "meduza.io xhamster.com" ] \
  || fail "сценарий 7: санитайзер должен оставить meduza.io xhamster.com, получено: [$san]"
san_warn="$(supersweep_sanitize_domains 'Домены meduza.io' 2>&1 >/dev/null)"
printf '%s' "$san_warn" | grep -q 'Отброшены' || fail "сценарий 7: нет предупреждения об отброшенном мусоре"

# == 8. только жёлтые (частичный TLS 1.3): победителя нет, ничего не применяется ==
# регрессия с живого прогона: сплошные WARN пропадали из отчёта («Ни одна
# стратегия не открыла ни один домен»), а счётчик доменов печатался пустым

: > "$ORCH_LOCK_FILE"
orch_locked_set 3 tls 4
export MOCK_OK_P1="" MOCK_OK_P2="" MOCK_OK_P4=""
export MOCK_OK_meduza_io="1 2 3 4 5" MOCK_HALF_meduza_io=1
rm -rf "$Z2R_SUPERSWEEP_DIR"
out8="$(supersweep_run both 0 0 0 1 meduza.io </dev/null 2>&1)" || {
  printf '%s\n' "$out8" >&2
  fail "сценарий 8: supersweep_run упал на только-жёлтом прогоне"
}
[ "$(lock_state 3 tls)" = 4 ] || fail "сценарий 8: профиль 3 не должен меняться без зелёных ($(lock_state 3 tls))"
grep -q '^winner=$' "$Z2R_SUPERSWEEP_DIR/best.rkn" || fail "сценарий 8: winner должен быть пуст"
grep -q '^warn_winner=5$' "$Z2R_SUPERSWEEP_DIR/best.rkn" || fail "сценарий 8: warn_winner должен быть 5 (самая быстрая жёлтая)"
grep -q '^reference=meduza.io$' "$Z2R_SUPERSWEEP_DIR/best.rkn" || fail "сценарий 8: reference должен быть meduza.io"
grep -q 'Зелёных пер-доменных результатов нет' <<<"$out8" || fail "сценарий 8: нет сообщения об отсутствии зелёных"
grep -q 'не применялись' <<<"$out8" || fail "сценарий 8: жёлтые не помечены как неприменённые"
grep -q 'деградацию канала' <<<"$out8" || fail "сценарий 8: нет подсказки о деградации канала"
grep -q 'доменов в прогоне: 1' <<<"$out8" || fail "сценарий 8: счётчик доменов пуст/неверен"
# вне интерактивного терминала вопроса про применение частичной быть не должноgrep -q 'Применить частичную' <<<"$out8" && fail "сценарий 8: tty-вопрос применения частичной появился без терминала"
grep -q 'Корреляция с YouTube' <<<"$out8" || fail "сценарий 8: нет строки корреляции с YouTube"
grep -q 'полный проход стратегий на каждый' <<<"$out8" || fail "сценарий 8: нет пояснения пер-доменного прохода"
grep -q 'Профильная стратегия РКН не менялась' <<<"$out8" || fail "сценарий 8: нет пояснения о незаменённой профильной РКН"
grep -q 'Без персональной стратегии' <<<"$out8" || fail "сценарий 8: нет пометки домена без персональной стратегии"
# профиль 1 весь красный, прогон завершён — большая рекомендация перезагрузки
grep -q 'ПОПРОБУЙТЕ ПЕРЕЗАГРУЗИТЬ РОУТЕР' <<<"$out8" \
  || fail "сценарий 8: нет совета перезагрузки при полном красе YouTube"
# архив результатов печатается ДО блока жёлтых (и вопроса про них):
# статистика не должна ждать ответа пользователя
arc_ln="$(grep -n 'Архив результатов' <<<"$out8" | cut -d: -f1 | head -n1)"
warn_ln="$(grep -n 'Жёлтые (только одна версия' <<<"$out8" | cut -d: -f1 | head -n1)"
[ -n "$arc_ln" ] && [ -n "$warn_ln" ] && [ "$arc_ln" -lt "$warn_ln" ] \
  || fail "сценарий 8: архив (строка ${arc_ln:-?}) должен идти до жёлтых (строка ${warn_ln:-?})"
# все 5 строк карты — жёлтые
[ "$(awk -F'\t' '$4=="warn"' "$Z2R_SUPERSWEEP_DIR/coverage.tsv" | wc -l)" = 5 ] \
  || fail "сценарий 8: все 5 строк эталона должны быть warn"
unset MOCK_HALF_meduza_io

# == 9. пауза: минимум 15 сек (профили) и 30 сек (РКН) ==
p="$(printf '
' | supersweep_ask_pause 2>/dev/null)" || fail "сценарий 9: ask_pause упал"
[ "$p" = "5" ] || fail "сценарий 9: Enter должен давать 5, получено [$p]"
p="$(printf '3
20
' | supersweep_ask_pause 2>/dev/null)" || fail "сценарий 9: ask_pause (3/20) упал"
[ "$p" = "20" ] || fail "сценарий 9: 3 должно отбрасываться (минимум 5), затем 20, получено [$p]"
p="$(printf '
' | supersweep_ask_ds_pause 2>/dev/null)" || fail "сценарий 9: ask_ds_pause упал"
[ "$p" = "15" ] || fail "сценарий 9: Enter должен давать 15 для Discord, получено [$p]"
p="$(printf '5
25
' | supersweep_ask_ds_pause 2>/dev/null)" || fail "сценарий 9: ask_ds_pause (5/25) упал"
[ "$p" = "25" ] || fail "сценарий 9: 5 должно отбрасываться (минимум 15), затем 25, получено [$p]"
p="$(printf '
' | supersweep_ask_rkn_pause 2>/dev/null)" || fail "сценарий 9: ask_rkn_pause упал"
[ "$p" = "60" ] || fail "сценарий 9: Enter должен давать 60 для РКН, получено [$p]"
p="$(printf '15
45
' | supersweep_ask_rkn_pause 2>/dev/null)" || fail "сценарий 9: ask_rkn_pause (15/45) упал"
[ "$p" = "45" ] || fail "сценарий 9: 15 должно отбрасываться (минимум 30), затем 45, получено [$p]"

# == 9a. имя архива и meta.tsv несут телеметрийный uuid + блобы ==
# (архив сценария 1 уже создан: в нём лежит meta.tsv с uuid=deadbeef)
arc9="$(ls -1t "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tar 2>/dev/null | head -n1)"
basename "$arc9" | grep -q -- '-deadbeef\.tar$' \
  || fail "сценарий 9a: имя архива без uuid: $(basename "$arc9")"
tar -tf "$arc9" > "$TMP_DIR/tarlist9.txt" 2>/dev/null || fail "сценарий 9a: архив не читается"
grep -q 'meta.tsv' "$TMP_DIR/tarlist9.txt" || fail "сценарий 9a: в архиве нет meta.tsv"
tar -xf "$arc9" -C "$TMP_DIR" ./meta.tsv 2>/dev/null || fail "сценарий 9a: meta.tsv не извлекается"
grep -q $'^uuid\tdeadbeef$' "$TMP_DIR/meta.tsv" || fail "сценарий 9a: meta.tsv без uuid"
grep -q $'^blob_global\t' "$TMP_DIR/meta.tsv" || fail "сценарий 9a: meta.tsv без blob_global"
grep -q $'^provider\t' "$TMP_DIR/meta.tsv" || fail "сценарий 9a: meta.tsv без provider"
# режим фейков по профилям: clone из mode_override.tsv, отсутствие строки = classic
grep -q $'^mode_4\tclone$' "$TMP_DIR/meta.tsv" || fail "сценарий 9a: meta.tsv без mode_4=clone"
grep -q $'^mode_1\tclassic$' "$TMP_DIR/meta.tsv" || fail "сценарий 9a: meta.tsv без mode_1=classic (нет строки = classic)"
grep -q $'^mode_8\tclassic$' "$TMP_DIR/meta.tsv" || fail "сценарий 9a: meta.tsv без mode_8"
rm -f "$TMP_DIR/meta.tsv"

# == 10. отмена после применения профиля: применённое не откатывается ==
# профильные воркеры завершаются раньше длинной РКН-карты: их лучшие уже
# применены, и Ctrl+C на карте не должен их откатывать

: > "$ORCH_LOCK_FILE"
orch_locked_set 1 tls 3
rm -rf "$Z2R_SUPERSWEEP_DIR"
export MOCK_DELAY=0.05
export MOCK_OK_P1="2 4" MOCK_OK_P2="3" MOCK_OK_P4="1 5"
export MOCK_OK_meduza_io="1 2" MOCK_OK_xhamster_com="2" MOCK_OK_chess_com="2"

supersweep_run both 0 0 0 1 meduza.io xhamster.com chess.com >"$TMP_DIR/cancel2.log" 2>&1 &
RUN2_PID=$!
# ждём: yt-воркер отработал и координатор применил его лучший лок,
# и стартовал этап 2 карты (первые домены кроме эталона)
n=0
while [ "$n" -lt 400 ]; do
  [ -f "$Z2R_SUPERSWEEP_DIR/applied.done.yt" ] \
    && [ "$(awk -F'\t' '$2 != "meduza.io"' "$Z2R_SUPERSWEEP_DIR/coverage.tsv" 2>/dev/null | wc -l)" -ge 1 ] \
    && break
  sleep 0.1 2>/dev/null || sleep 1
  n=$((n + 1))
done
[ -f "$Z2R_SUPERSWEEP_DIR/applied.done.yt" ] || fail "сценарий 10: yt-воркер не успел завершиться до отмены"
: > "$Z2R_SUPERSWEEP_DIR/cancel"
rc2=0
wait "$RUN2_PID" || rc2=$?
[ "$rc2" = 1 ] || fail "сценарий 10: отменённый прогон должен вернуть 1, вернул $rc2"
[ "$(lock_state 1 tls)" = 4 ] || fail "сценарий 10: применённый лок профиля 1 откатился ($(lock_state 1 tls))"
[ "$(lock_state meduza.io tls)" = auto ] || fail "сценарий 10: доменные пробы должны откатиться ($(lock_state meduza.io tls))"
grep -q 'оставлена применённая стратегия 4' "$TMP_DIR/cancel2.log" \
  || fail "сценарий 10: нет сообщения об оставленной применённой стратегии"
# частичный, но заполненный прогон архивируется (в отличие от пустого — сц.2)
grep -q 'Архив результатов' "$TMP_DIR/cancel2.log" \
  || fail "сценарий 10: заполненный прерванный прогон должен архивироваться"
unset MOCK_DELAY

# == 11. свой домен подбора профиля 3: 0-выход, хитрые URL, списки ==

grep -q 'rkn_trial_domain_pick' "$REPO_DIR/lib/strategies.sh" || fail "сценарий 11: нет rkn_trial_domain_pick"
grep -q 'rkn_trial_domain_pick' "$REPO_DIR/lib/submenus.sh" || fail "сценарий 11: подменю не зовёт rkn_trial_domain_pick"
# принцип меню: 0 = выход; экран очищается перед диалогом
grep -q 'clear -x' <(sed -n "$(grep -n '^rkn_trial_domain_pick' "$REPO_DIR/lib/strategies.sh" | cut -d: -f1),+30p" "$REPO_DIR/lib/strategies.sh") \
  || fail "сценарий 11: диалог не очищает экран"
printf 'meduza.io\nexample.com\n' > "$ZATOR_ROOT/extra_strats/TCP_RKN_list.txt"
: > "$ZATOR_ROOT/extra_strats/TCP_Custom.txt"

# 0 — отмена (принцип всех меню)
printf '0\n' > "$TMP_DIR/in11.txt"
if rkn_trial_domain_pick < "$TMP_DIR/in11.txt" >/dev/null 2>&1; then
  fail "сценарий 11: 0 должен отменять подбор"
fi

# Enter — базовый домен
RKN_TRIAL_DOMAIN=""
rkn_trial_domain_pick </dev/null >/dev/null 2>&1 \
  || fail "сценарий 11: Enter должен давать базовый домен"
[ "$RKN_TRIAL_DOMAIN" = "meduza.io" ] || fail "сценарий 11: Enter -> базовый, получено [$RKN_TRIAL_DOMAIN]"

# хитрый URL: схема/путь/регистр + родительский суффикс в списке
# (stdin из файла, не пайпом: функция должна остаться в текущем шелле,
# иначе глобал RKN_TRIAL_DOMAIN не дойдёт до ассерта)
printf 'https://Sub.Example.COM/watch?v=dQw4w9WgXcQ\n' > "$TMP_DIR/in11.txt"
rkn_trial_domain_pick < "$TMP_DIR/in11.txt" >/dev/null 2>&1 \
  || fail "сценарий 11: URL с схемой/путём (родитель в списке) должен проходить"
[ "$RKN_TRIAL_DOMAIN" = "sub.example.com" ] || fail "сценарий 11: URL не нормализован [$RKN_TRIAL_DOMAIN]"

# хитрый URL с портом, точное совпадение после нормализации
printf 'HTTP://example.com:443/some/path\n' > "$TMP_DIR/in11.txt"
rkn_trial_domain_pick < "$TMP_DIR/in11.txt" >/dev/null 2>&1 \
  || fail "сценарий 11: URL с портом (точное совпадение) должен проходить"
[ "$RKN_TRIAL_DOMAIN" = "example.com" ] || fail "сценарий 11: порт не срезан [$RKN_TRIAL_DOMAIN]"

# домена нет + согласие на добавление (хитрый ввод) -> пишется в TCP_Custom.txt
printf '  https://Fresh.ru:443/x  \n1\n' > "$TMP_DIR/in11.txt"
rkn_trial_domain_pick < "$TMP_DIR/in11.txt" >/dev/null 2>&1 \
  || fail "сценарий 11: домен с добавлением должен проходить"
[ "$RKN_TRIAL_DOMAIN" = "fresh.ru" ] || fail "сценарий 11: добавленный домен не выбран [$RKN_TRIAL_DOMAIN]"
grep -Fxq 'fresh.ru' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" \
  || fail "сценарий 11: fresh.ru не добавлен в TCP_Custom.txt"

# домена нет + отказ (0 и Enter) -> отмена
printf 'nope.ru\n0\n' > "$TMP_DIR/in11.txt"
if rkn_trial_domain_pick < "$TMP_DIR/in11.txt" >/dev/null 2>&1; then
  fail "сценарий 11: отказ (0) от добавления должен отменять подбор"
fi
printf 'nope.ru\n\n' > "$TMP_DIR/in11.txt"
if rkn_trial_domain_pick < "$TMP_DIR/in11.txt" >/dev/null 2>&1; then
  fail "сценарий 11: отказ (Enter) от добавления должен отменять подбор"
fi

# мусорный ввод -> отмена
printf 'bad domain!\n' > "$TMP_DIR/in11.txt"
if rkn_trial_domain_pick < "$TMP_DIR/in11.txt" >/dev/null 2>&1; then
  fail "сценарий 11: некорректный домен должен отбрасываться"
fi

# == 12. дефолтный набор РКН автора + пауза без эскалации + зелёный ускоритель ==

# эскалации паузы больше нет
grep -q 'red_streak\|GENTLE' "$REPO_DIR/lib/supersweep.sh" \
  && fail "сценарий 12: остатки эскалации паузы (gentle) в supersweep.sh"
grep -q 'Z2R_SUPERSWEEP_GREEN_PAUSE' "$REPO_DIR/lib/supersweep.sh" \
  || fail "сценарий 12: нет зелёного ускорителя паузы"
grep -q 'z2r_tls_code_ok' "$REPO_DIR/lib/supersweep.sh" \
  || fail "сценарий 12: ускоритель не проверяет обе версии TLS"
# жёсткого лимита доменов нет: только дефолтный набор
grep -q 'RKN_DOMAINS_MAX\|supersweep_cap_domains' "$REPO_DIR/lib/supersweep.sh" \
  && fail "сценарий 12: остался хвост жёсткого лимита доменов"

# дефолтный набор автора: три домена, без meduza (она — дефолт ручного подбора)
d="$(printf '\n' | supersweep_ask_domains 2>/dev/null)"
[ "$d" = "xhamster.com anidub.com amnezia.org" ] \
  || fail "сценарий 12: Enter должен давать дефолтный набор автора [$d]"

# выбор подмножества
d="$(printf '1 3\n' | supersweep_ask_domains 2>/dev/null)"
[ "$d" = "xhamster.com amnezia.org" ] || fail "сценарий 12: выбор подмножества сломан [$d]"

# диалог: 0 = отмена
printf '0\n' | supersweep_ask_domains 2>/dev/null | grep -q . \
  && fail "сценарий 12: 0 в диалоге доменов должен отменять (пустой вывод)"

# свои домены дописываются свободно (без ограничений количества)
: > "$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
d="$(printf 'fresh1.ru fresh2.ru\n' | supersweep_ask_own_domains 'a.com b.com c.com' 2>/dev/null)"
[ "$d" = "a.com b.com c.com fresh1.ru fresh2.ru" ] \
  || fail "сценарий 12: свои домены должны дописываться свободно [$d]"

# == 13. отменённый прогон не роняет меню под set -e; паузы воркеров ==
# Регрессия с боевого прогона: supersweep_run возвращал 1 при отмене, а
# глобальный set -e z2r.sh убивал скрипт сразу после сводки — пользователь
# выпадал в шелл. Меню обязано пережить отменённый прогон и вернуться.

rm -rf "$Z2R_SUPERSWEEP_DIR"
rm -f "$TMP_DIR/gate13.args"
printf '\n\n\n\n\n\n\n' > "$TMP_DIR/in13.txt"
export MOCK_DELAY=0.2
export MOCK_OK_P1="1 3"
(
  set -e
  clear() { :; }
  zapret2_running() { return 0; }
  menu_config_snapshot() { return 0; }
  telemetry_notify() { :; }
  pause_enter() { :; }
  z2r_dns_spoof_gate() { printf '%s\n' "$*" >> "$TMP_DIR/gate13.args"; echo "тест: гейт пройден"; return 0; }
  Z2R_SUPERSWEEP_GREEN_PAUSE=2
  export Z2R_SUPERSWEEP_GREEN_PAUSE
  Z2R_SUPERSWEEP_SETTLE=2
  export Z2R_SUPERSWEEP_SETTLE
  supersweep_menu < "$TMP_DIR/in13.txt"
  echo MENU_ALIVE
) > "$TMP_DIR/menu13.log" 2>&1 &
M13_PID=$!
n=0
while [ "$n" -lt 400 ]; do
  [ "$(awk -F'\t' '$1=="yt"' "$Z2R_SUPERSWEEP_DIR/pacing.tsv" 2>/dev/null | wc -l)" -ge 2 ] && break
  sleep 0.1 2>/dev/null || sleep 1
  n=$((n + 1))
done
[ "$(awk -F'\t' '$1=="yt"' "$Z2R_SUPERSWEEP_DIR/pacing.tsv" 2>/dev/null | wc -l)" -ge 2 ] \
  || fail "сценарий 13: прогон не дошёл до второй паузы"
supersweep_cancel_running || fail "сценарий 13: не создан cancel-файл"
rc13=0
wait "$M13_PID" || rc13=$?
[ "$rc13" = 0 ] || { cat "$TMP_DIR/menu13.log" >&2; fail "сценарий 13: меню не пережило отменённый прогон под set -e (rc=$rc13)"; }
grep -q 'MENU_ALIVE' "$TMP_DIR/menu13.log" || fail "сценарий 13: меню не вернулось после отмены"
grep -q 'Прервано пользователем' "$TMP_DIR/menu13.log" || fail "сценарий 13: нет сообщения о прерывании"
# пустой прерванный прогон пропускает архивацию и отправку (виден и из меню)
grep -q 'ничего не отправлено' "$TMP_DIR/menu13.log" \
  || fail "сценарий 13: пустой прерванный прогон должен пропустить отправку статистики"
# гейт перед прогоном зовётся по ЭТАЛОННОМУ домену, а не по первому выбранному
grep -q 'rutracker.org' "$TMP_DIR/gate13.args" \
  || fail "сценарий 13: гейт получил не эталонный домен: $(cat "$TMP_DIR/gate13.args")"
# паузы воркера: зелёная стратегия -> ускоритель (2с), красная -> фазовая
# пауза минус выдержка (5 - 2 = 3с); выдержка входит в паузу
[ "$(awk -F'\t' '$1=="yt" && $2=="1" {print $3}' "$Z2R_SUPERSWEEP_DIR/pacing.tsv")" = "2" ] \
  || fail "сценарий 13: зелёная стратегия должна дать паузу ускорителя 2с"
[ "$(awk -F'\t' '$1=="yt" && $2=="2" {print $3}' "$Z2R_SUPERSWEEP_DIR/pacing.tsv")" = "3" ] \
  || fail "сценарий 13: красная стратегия должна дать паузу 5с минус выдержка 2с = 3с"
unset MOCK_DELAY MOCK_OK_P1

echo "supersweep smoke ok"
