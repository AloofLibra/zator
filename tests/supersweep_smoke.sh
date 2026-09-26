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
trap 'rm -rf "$TMP_DIR"' EXIT
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
if [ "$head" = 1 ]; then
  if [ "$green" = 1 ]; then
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
export Z2R_SWEEP_PAUSE=0
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

# == 1. полный прогон: применение лучших + карта + восстановление доменов ==

[ "$(config_profile_max_strategy 1 "$CFG")" = 5 ] || fail "мок-конфиг: профиль 1 должен иметь 5 стратегий"
[ "$(config_profile_max_strategy 4 "$CFG")" = 5 ] || fail "мок-конфиг: профиль 4 должен иметь 5 стратегий"

# прежние локи: профиль 1 = 3, meduza = 1 (остальных нет)
orch_locked_set 1 tls 3
orch_locked_set meduza.io tls 1

# зелёные стратегии: у профилей и доменов разные наборы; скорость докачки
# растёт с номером стратегии (2.6 - 0.1*N) — «лучшая» = максимальный зелёный
export MOCK_OK_P1="2 4" MOCK_OK_P2="3" MOCK_OK_P4="1 5"
export MOCK_OK_meduza_io="1 2" MOCK_OK_xhamster_com="2" MOCK_OK_chess_com="2"

out="$(supersweep_run both 0 2 meduza.io xhamster.com chess.com 2>&1)" || {
  printf '%s\n' "$out" >&2
  fail "сценарий 1: supersweep_run вернул ошибку"
}

[ "$(lock_state 1 tls)" = 4 ] || fail "сценарий 1: профиль 1 должен получить стратегию 4, а не $(lock_state 1 tls)"
[ "$(lock_state 1 http)" = 4 ] || fail "сценарий 1: профиль 1/http должен получить 4"
[ "$(lock_state 2 tls)" = 3 ] || fail "сценарий 1: профиль 2 должен получить стратегию 3"
[ "$(lock_state 4 tls)" = 5 ] || fail "сценарий 1: профиль 4 должен получить стратегию 5"
[ "$(lock_state 3 tls)" = 2 ] || fail "сценарий 1: профиль 3 должен получить стратегию 2 (макс. покрытие), а не $(lock_state 3 tls)"
# пер-доменные пробы временные: meduza возвращается к прежнему локу 1,
# xhamster/chess (не имели лока) возвращаются к auto
[ "$(lock_state meduza.io tls)" = 1 ] || fail "сценарий 1: meduza.io должен вернуться к локу 1, а не $(lock_state meduza.io tls)"
[ "$(lock_state xhamster.com tls)" = auto ] || fail "сценарий 1: xhamster.com должен быть auto после отката, а не $(lock_state xhamster.com tls)"
[ "$(lock_state chess.com tls)" = auto ] || fail "сценарий 1: chess.com должен быть auto после отката"

# прогресс-файлы для веб-панели
[ -f "$Z2R_SUPERSWEEP_DIR/status" ] || fail "сценарий 1: нет status-файла"
grep -q '^state=done$' "$Z2R_SUPERSWEEP_DIR/status" || fail "сценарий 1: state != done"
[ "$(wc -l < "$Z2R_SUPERSWEEP_DIR/workers.tsv")" = 4 ] || fail "сценарий 1: workers.tsv должен иметь 4 воркера"
[ "$(wc -l < "$Z2R_SUPERSWEEP_DIR/progress.yt.tsv")" = 5 ] || fail "сценарий 1: progress.yt.tsv должен иметь 5 строк (по числу стратегий)"
[ "$(awk -F'\t' 'NF!=9' "$Z2R_SUPERSWEEP_DIR/progress.yt.tsv" | wc -l)" = 0 ] \
  || fail "сценарий 1: строки progress.yt.tsv должны иметь 9 колонок"
[ "$(wc -l < "$Z2R_SUPERSWEEP_DIR/coverage.tsv")" = 15 ] || fail "сценарий 1: coverage.tsv = 5 стратегий x 3 домена = 15 строк"
grep -q '^winner=2$' "$Z2R_SUPERSWEEP_DIR/best.rkn" || fail "сценарий 1: winner должен быть 2"
grep -q '^winner_cover=3$' "$Z2R_SUPERSWEEP_DIR/best.rkn" || fail "сценарий 1: winner_cover должен быть 3"
grep -q '^winner_total=3$' "$Z2R_SUPERSWEEP_DIR/best.rkn" || fail "сценарий 1: winner_total должен быть 3"
grep -q $'profile\t1\t4' "$Z2R_SUPERSWEEP_DIR/summary.tsv" || fail "сценарий 1: summary.tsv без profile 1 -> 4"
grep -q $'profile\t3\t2' "$Z2R_SUPERSWEEP_DIR/summary.tsv" || fail "сценарий 1: summary.tsv без profile 3 -> 2"
grep -q 'Применена стратегия 4' <<<"$out" || fail "сценарий 1: нет строки применения для профиля 1"
grep -q 'Применена стратегия 2 для профиля 3' <<<"$out" || fail "сценарий 1: нет строки применения для профиля 3"
grep -q 'медуза\|meduza.io' <<<"$out" || fail "сценарий 1: в отчёте нет рекомендаций по доменам"
grep -q 'Зелёные\|Рабочие' <<<"$out" || fail "сценарий 1: в отчёте нет списков рабочих стратегий"

# архив результатов (с prev.tsv внутри) появился
archives="$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tgz 2>/dev/null || true)"
[ -n "$archives" ] || fail "сценарий 1: архив результатов не создан"
tgz="$(printf '%s\n' "$archives" | head -n1)"
# список во временный файл: grep -q в трубе роняет tar по SIGPIPE (pipefail)
tar -tzf "$tgz" > "$TMP_DIR/tarlist.txt" 2>/dev/null || fail "сценарий 1: архив не читается"
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

supersweep_run both 0 1 meduza.io xhamster.com chess.com >"$TMP_DIR/cancel.log" 2>&1 &
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
grep -q '^state=cancelled$' "$Z2R_SUPERSWEEP_DIR/status" || fail "сценарий 2: state != cancelled"
grep -q 'откатлены\|возвращаю прежние' "$TMP_DIR/cancel.log" || fail "сценарий 2: нет сообщения об откате"
# архив собирается и для отменённого прогона («что собралось и откатилось»)
new_archives="$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tgz 2>/dev/null | wc -l)"
[ "$new_archives" -ge 2 ] || fail "сценарий 2: архив отменённого прогона не создан"

# ротация архивов: KEEP=3, наделаем пустышек и проверим уборку
for i in 1 2 3 4; do
  : > "$Z2R_SUPERSWEEP_ARCHIVE_DIR/supersweep-2000010${i}-000000.tgz"
done
ls -1t "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tgz >/dev/null 2>&1
supersweep_results_archive >/dev/null || fail "сценарий 2: архиватор упал"
[ "$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tgz | wc -l)" = 3 ] \
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
before="$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tgz 2>/dev/null | wc -l)"
# имя архива с точностью до секунды: гарантируем новое, а не перезапись
sleep 1.1 2>/dev/null || sleep 2
fb_out="$(PATH="$TMP_DIR/bin2:$PATH" Z2R_SUPERSWEEP_TAR="$REAL_TAR" supersweep_results_archive)" \
  || fail "сценарий 4: fallback-цепочка tar не сработала"
fb_tgz="$(printf '%s' "$fb_out" | cut -f1)"
[ -n "$fb_tgz" ] && [ -f "$fb_tgz" ] || fail "сценарий 4: fallback-архив не создан"
after="$(ls -1 "$Z2R_SUPERSWEEP_ARCHIVE_DIR"/supersweep-*.tgz 2>/dev/null | wc -l)"
[ "$after" = "$((before + 1))" ] || fail "сценарий 4: архив через fallback не добавлен (${before} -> ${after})"
tar -tzf "$fb_tgz" > "$TMP_DIR/tarlist2.txt" 2>/dev/null || fail "сценарий 4: fallback-архив не читается"
# прогон перед этим был отменён рано: coverage мог не успеть появиться,
# поэтому сверяем гарантированно существующие файлы прогона
grep -q 'status' "$TMP_DIR/tarlist2.txt" || fail "сценарий 4: в fallback-архиве нет status"
grep -q 'progress.yt.tsv' "$TMP_DIR/tarlist2.txt" || fail "сценарий 4: в fallback-архиве нет progress.yt.tsv"

# == 5. диалог своих доменов: нормализация + добавление в TCP_Custom ==

rm -f "$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
sel="$(printf 'mydom.ru https://bad domain-name.example\n' | supersweep_ask_own_domains "meduza.io")" || \
  fail "сценарий 3: ask_own_domains упал"
grep -q 'meduza.io' <<<"$sel" || fail "сценарий 3: потерян исходный домен"
grep -q 'mydom.ru' <<<"$sel" || fail "сценарий 3: свой домен не добавлен в выбор"
grep -q 'domain-name.example' <<<"$sel" || fail "сценарий 3: домен с дефисами не принят"
[ "$(grep -c 'domain-name.example' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt")" = 1 ] \
  || fail "сценарий 3: домен не записан в TCP_Custom.txt ровно один раз"

echo "supersweep smoke ok"
