#!/usr/bin/env bash
# Единый раннер смоук-тестов zator для человека и агентов.
#
# Зачем: полный набор гонять на каждой правке дорого (~25 мин), а у каждого
# агента свой «а какие тесты запускать» — раннер фиксирует это в одном месте
# и выдаёт компактный результат, который не жалко вставлять в контекст.
#
# Контракт вывода (стабилен, для машин):
#   OK   <имя> <сек>     — тест прошёл, деталей нет
#   FAIL <имя> <сек>     — далее до 8 последних строк его вывода
#   FAIL <имя> ?s        — потерянный результат: обёртка теста умерла, не
#                          дописав .res; потеря никогда не считается успехом
#   RUNNER: mode=<режим> pass=N fail=M elapsed=<сек>
#   Код возврата 0 — все тесты прошли, 1 — есть отказ или потеря.
#   Сводка печатается всегда, включая ранние отказы статических проверок.
#
# Режимы:
#   quick  (~5с)   синтаксис всех shell/lua (псевдотест syntax) + дешёвые
#                  статические тесты. Запускать после любой правки.
#   shell  (~3мин) всё, что смотрит в z2r.sh / lib / config.default (параллельно).
#   webui  (~2мин) панель: сборка артефактов, CGI, мок-сервер (параллельно).
#   full   (~25мин→~8мин) весь набор параллельно; перед коммитом в zator/релизом.
#
# Примеры:
#   bash tests/run.sh            # quick
#   bash tests/run.sh shell
#   bash tests/run.sh full -v    # -v: полный вывод каждого теста в конец
#
# Переменные: RUNNER_JOBS=N — число параллельных задач (по умолчанию 4).

set -u
cd "$(dirname "$0")/.."

mode="quick"
verbose=0
for a in "$@"; do
  case "$a" in
    quick|shell|webui|full) mode="$a" ;;
    -v|--verbose) verbose=1 ;;
    *) echo "usage: tests/run.sh [quick|shell|webui|full] [-v]" >&2; exit 2 ;;
  esac
done

all_tests() {
  ls tests/*_smoke.sh | sort
}

QUICK_STATIC='blob_profile client_scope_webui flavor telemetry ui_validation uninstall webui_build'
QUICK_FILES='z2r.sh lib/*.sh lua/*.lua orchestra/*.lua webui/cgi-bin/*.cgi webui/cgi-bin/_lib.sh'

selection=""
case "$mode" in
  quick)
    for t in $QUICK_STATIC; do
      [ -f "tests/${t}_smoke.sh" ] && selection="$selection tests/${t}_smoke.sh"
    done
    ;;
  shell)
    selection="$(all_tests | grep -Ev 'webui_|ui_validation|supersweep|tls_check|client_scope_menu' | tr '\n' ' ')"
    ;;
  webui)
    selection="$(all_tests | grep -E 'webui_|ui_validation' | tr '\n' ' ')"
    ;;
  full)
    selection="$(all_tests | tr '\n' ' ')"
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expected=0

if [ "$mode" = quick ]; then
  expected=$((expected+1))
  st=OK
  : > "$tmp/syntax.log"
  for f in $QUICK_FILES; do
    [ -f "$f" ] || continue
    case "$f" in
      *.lua)
        command -v luac >/dev/null 2>&1 || continue
        luac -p "$f" >>"$tmp/syntax.log" 2>&1 || st=FAIL
        ;;
      *)
        bash -n "$f" >>"$tmp/syntax.log" 2>&1 || st=FAIL
        ;;
    esac
  done
  printf '%s syntax 0\n' "$st" > "$tmp/syntax.res"
fi

jobs="${RUNNER_JOBS:-4}"
running=0
for t in $selection; do
  expected=$((expected+1))
  name="$(basename "$t")"
  (
    start=$(date +%s)
    if bash "$t" >"$tmp/$name.log" 2>&1; then st=OK; else st=FAIL; fi
    end=$(date +%s)
    printf '%s %s %s\n' "$st" "$name" "$((end-start))" > "$tmp/$name.res"
  ) &
  running=$((running+1))
  if [ "$running" -ge "$jobs" ]; then
    wait -n 2>/dev/null || wait
    running=$((running-1))
  fi
done
wait

pass=0
fail=0
print_res() {
  local st n el
  read -r st n el < "$1" || { fail=$((fail+1)); printf 'FAIL %s ?s\n' "$1"; return; }
  if [ "$st" = OK ]; then
    pass=$((pass+1))
    printf 'OK   %s %ss\n' "$n" "$el"
  else
    fail=$((fail+1))
    printf 'FAIL %s %ss\n' "$n" "$el"
    if [ "$verbose" = 1 ]; then
      cat "$tmp/$n.log" 2>/dev/null
    else
      tail -n 8 "$tmp/$n.log" 2>/dev/null | sed 's/^/    /'
    fi
  fi
}

[ -f "$tmp/syntax.res" ] && print_res "$tmp/syntax.res"

for t in $selection; do
  name="$(basename "$t")"
  if [ -f "$tmp/$name.res" ]; then
    print_res "$tmp/$name.res"
  else
    fail=$((fail+1))
    printf 'FAIL %s ?s\n' "$name"
    printf '    потерянный результат: обёртка теста умерла; повтор: bash tests/%s\n' "$name"
  fi
done

elapsed=$SECONDS
echo "RUNNER: mode=$mode pass=$pass fail=$fail expected=$expected elapsed=${elapsed}s"
[ "$fail" = 0 ]
