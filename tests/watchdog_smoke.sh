#!/usr/bin/env bash
#
# Smoke-тест watchdog zapret2 (файлы Entware/zapret2-watchdog и
# init.d/openwrt/zapret2-watchdog, пункт меню 19-6, блок событий в п.666).
#
# Покрывает:
#   • watchdog_status_text — недоступно (чужая платформа) / не установлен /
#     работает / выключен, для entware и WRT;
#   • watchdog_toggle (entware) — включение: докачка при отсутствии,
#     обёртка автозапуска, запуск; выключение: stop + удаление обёртки,
#     скачанные файлы остаются; повторное включение — без докачки;
#   • watchdog_toggle (WRT) — enable+start при включении, stop+disable
#     при выключении, init-файл остаётся;
#   • частичные сбои toggle — упавший enable/start/stop даёт ненулевой код
#     возврата и откат (WRT: disable; entware: удаление обёртки), без
#     сообщения об успехе (регрессии ревью PR#35);
#   • watchdog_uninstall (меню 4/44) — полная зачистка: демон останавливается
#     (TERM → 3с → KILL, только после сверки cmdline), файлы/конфиг/обёртка
#     удалены; pidfile с переиспользованным pid чужого процесса не приводит
#     к kill постороннего; сирота (демон жив, файлов нет) тоже останавливается;
#   • watchdog_ensure_running (тело установщика) — поднимает включённый
#     watchdog после переустановки, молчит при живом/выключенном;
#   • procd (WRT) — start_service передаёт procd 'command $initscript run'
#     (не $0 = /etc/rc.common), respawn; без init zapret2 — ошибка;
#   • OOM (WRT) — только НОВЫЕ строки в syslog/logread, вытеснение буфера,
#     чужие процессы не считаются; do_restart не трогает err-логи;
#   • nfqws2_state — pidfile с переиспользованным pid чужого процесса = crash
#     (а не «работает»), живой nfqws2 = run (сверка /proc/<pid>/cmdline);
#   • safe_err_files — только обычные файлы владельца, симлинки/чужие мимо;
#   • do_restart (entware) — старые маркеры OOM снимаются ДО рестарта, код
#     возврата init попадает в лог, cooldown держит;
#   • жизненный цикл реального entware-скрипта в песочнице — start ждёт
#     pidfile от демона, без init zapret2 возвращает ошибку, status/stop;
#   • статика: bash -n (z2r.sh, lib/submenus.sh), sh -n (оба watchdog-файла),
#     блок «События watchdog» в п.666, пункт 6 и обработчик в подменю,
#     env-override путей автозапуска.
#
# ИЗОЛЯЦИЯ: тест не пишет в /opt и не запускает настоящий watchdog —
# ZATOR_ROOT и пути init (Z2R_ENTWARE_INIT/Z2R_WRT_INIT) указывают во
# временную папку, скачивание подменяется моком, вместо реального
# watchdog-скрипта ставится мок, логирующий вызовы.
#
# Возврат: 0 — успех («watchdog smoke ok»), 1 — любая ошибка (FAIL: ...).
# Запуск:  bash tests/watchdog_smoke.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() {
  printf '  [PASS] %s\n' "$1"
}
assert_eq() {
  local got="$1" want="$2" msg="$3"
  [ "$got" = "$want" ] || fail "$msg (получено: '$got', ожидалось: '$want')"
}
assert_contains() {
  local text="$1" pattern="$2" msg="$3"
  printf '%s\n' "$text" | grep -Eq -- "$pattern" || fail "$msg"
}

# --- Статика: синтаксис и wiring ---

bash -n "$REPO_DIR/z2r.sh" || fail "bash -n z2r.sh"
bash -n "$REPO_DIR/lib/submenus.sh" || fail "bash -n lib/submenus.sh"
sh -n "$REPO_DIR/Entware/zapret2-watchdog" || fail "sh -n Entware/zapret2-watchdog"
sh -n "$REPO_DIR/init.d/openwrt/zapret2-watchdog" || fail "sh -n init.d/openwrt/zapret2-watchdog"
ok "синтаксис z2r.sh, lib/submenus.sh и обоих watchdog-файлов"

grep -q 'События watchdog' "$REPO_DIR/z2r.sh" || fail "в z2r.sh нет блока событий watchdog (п.666)"
grep -qF 'zapret2-watchdog.log" | tail -15' "$REPO_DIR/z2r.sh" || fail "п.666 не показывает последние события watchdog"
grep -qF 'watchdog_toggle || true' "$REPO_DIR/lib/submenus.sh" || fail "в подменю нет обработчика пункта 6 (watchdog_toggle)"
grep -qF 'submenu_status_item "6" "Watchdog zapret2' "$REPO_DIR/lib/submenus.sh" || fail "в подменю нет пункта 6 (статус watchdog)"
grep -qF 'pidfile остался' "$REPO_DIR/Entware/zapret2-watchdog" || fail "в watchdog нет pidfile-эвристики (падение vs штатная остановка)"
grep -qF 'Z2R_ENTWARE_INIT' "$REPO_DIR/lib/submenus.sh" || fail "путь entware-автозапуска не переопределяется через env"
grep -qF 'Z2R_WRT_INIT' "$REPO_DIR/lib/submenus.sh" || fail "путь wrt-автозапуска не переопределяется через env"
ok "wiring: п.666, пункт 19-6, pidfile-эвристика, env-override"

# Регрессии ревью PR#35: procd обязан запускать $initscript (не $0 = rc.common),
# живость pid сверяется по cmdline, OOM на OpenWRT берётся из syslog (logread)
grep -qF 'procd_set_param command "$initscript" run' "$REPO_DIR/init.d/openwrt/zapret2-watchdog" \
  || fail "start_service должен запускать \$initscript, а не \$0 (под rc.common \$0 = /etc/rc.common)"
if grep -qF 'procd_set_param command "$0"' "$REPO_DIR/init.d/openwrt/zapret2-watchdog"; then
  fail "start_service не должен использовать \$0 — под rc.common это /etc/rc.common, сервис не стартует"
fi
grep -q '^is_nfqws2_pid()' "$REPO_DIR/init.d/openwrt/zapret2-watchdog" \
  || fail "в openwrt-watchdog нет сверки идентичности pid по /proc/cmdline"
grep -q '^is_nfqws2_pid()' "$REPO_DIR/Entware/zapret2-watchdog" \
  || fail "в entware-watchdog нет сверки идентичности pid по /proc/cmdline"
grep -q '^pid_is_watchdog()' "$REPO_DIR/Entware/zapret2-watchdog" \
  || fail "в entware-watchdog нет сверки идентичности собственного pid (kill чужого процесса)"
grep -q '^safe_err_files()' "$REPO_DIR/Entware/zapret2-watchdog" \
  || fail "в entware-watchdog нет безопасной проходки по err-логам (/tmp записываем всеми)"
grep -qF 'Z2R_WATCHDOG_PIDFILE' "$REPO_DIR/Entware/zapret2-watchdog" \
  || fail "пути watchdog не переопределяются через env (нужны для smoke-тестов)"
grep -q '^wd_pid_is_ours()' "$REPO_DIR/lib/submenus.sh" \
  || fail "в lib/submenus.sh нет сверки идентичности pid перед kill (wd_pid_is_ours)"
# лог watchdog — в root-owned каталоге: «проверил симлинк — открыл» в
# world-writable /tmp не закрывает TOCTOU и прозрачный nohup >> до запуска
grep -qF 'LOGFILE="${Z2R_WATCHDOG_LOGFILE:-/opt/zator/z2r_lib/zapret2-watchdog.log}"' "$REPO_DIR/Entware/zapret2-watchdog" \
  || fail "лог watchdog (entware) должен лежать в root-owned /opt/zator/z2r_lib, а не в world-writable /tmp"
grep -qF 'LOGFILE="${Z2R_WATCHDOG_LOGFILE:-/opt/zator/z2r_lib/zapret2-watchdog.log}"' "$REPO_DIR/init.d/openwrt/zapret2-watchdog" \
  || fail "лог watchdog (WRT) должен лежать в root-owned /opt/zator/z2r_lib, а не в world-writable /tmp"
grep -qF '"$ZATOR_ROOT/z2r_lib/zapret2-watchdog.log"' "$REPO_DIR/z2r.sh" \
  || fail "п.666 должен читать события watchdog из root-owned $ZATOR_ROOT/z2r_lib/zapret2-watchdog.log"
grep -qF 'if ! "$init" enable' "$REPO_DIR/lib/submenus.sh" \
  || fail "watchdog_toggle должен проверять код возврата enable (частичный успех недопустим)"
grep -qF 'if ! "$script" stop' "$REPO_DIR/lib/submenus.sh" \
  || fail "watchdog_toggle должен проверять код возврата stop (частичный успех недопустим)"
grep -q '^oom_scan()' "$REPO_DIR/init.d/openwrt/zapret2-watchdog" \
  || fail "в openwrt-watchdog нет OOM-курсора syslog (oom_scan)"
grep -q 'OOM_CURSOR' "$REPO_DIR/init.d/openwrt/zapret2-watchdog" \
  || fail "openwrt-watchdog должен хранить курсор syslog, а не сравнивать количество строк (кольцевой буфер обманывает счётчик)"
grep -q 'logread' "$REPO_DIR/init.d/openwrt/zapret2-watchdog" \
  || fail "openwrt-watchdog должен искать OOM в syslog (logread): stderr nfqws2 идёт туда, а не в /tmp/nfqws2_*.err"
ok "статика: \$initscript в procd, is_nfqws2_pid, OOM из logread"

# --- Динамическая часть: watchdog_*-функции из lib/submenus.sh ---

TMP_DIR="$(mktemp -d /tmp/zator-watchdog.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

export ZATOR_ROOT="$TMP_DIR/zator"
export Z2R_ENTWARE_INIT="$TMP_DIR/etc-init.d/S91zapret2-watchdog"
export Z2R_WRT_INIT="$TMP_DIR/wrt-init.d/zapret2-watchdog"
ENT_SCRIPT="$ZATOR_ROOT/z2r_lib/zapret2-watchdog"
ENT_CALLS="$TMP_DIR/ent.calls"
WRT_CALLS="$TMP_DIR/wrt.calls"
STATUS_MODE="$TMP_DIR/status.mode"
DOWNLOAD_LOG="$TMP_DIR/download.log"
mkdir -p "$ZATOR_ROOT/z2r_lib"
: >"$ENT_CALLS"
: >"$WRT_CALLS"
: >"$DOWNLOAD_LOG"
echo stopped >"$STATUS_MODE"

# Заглушки цветов (нужны только для сообщений watchdog_toggle).
plain=""; cyan=""; green=""; red=""; yellow=""

# Извлекаем блок watchdog-функций: от комментария «--- Watchdog zapret2»
# до advanced_settings_submenu (функции объявлены от колонки 0).
awk '/^# --- Watchdog zapret2/{f=1} /^advanced_settings_submenu\(\)/{f=0} f' \
  "$REPO_DIR/lib/submenus.sh" >"$TMP_DIR/watchdog_funcs.sh"
grep -q '^watchdog_toggle()' "$TMP_DIR/watchdog_funcs.sh" \
  || fail "не извлеклись watchdog-функции из lib/submenus.sh"
# shellcheck source=/dev/null
source "$TMP_DIR/watchdog_funcs.sh"

# Мок watchdog-скрипта: логирует действия ($3, кроме пробы status),
# status отвечает по файлу режима $2 (run → 0, иначе 1), остальные
# команды — 0. Если задан файл $4, перечисленные в нём команды (по одной
# в строке) завершаются ошибкой — имитация частичных сбоев меню.
# Реальный watchdog в тесте не запускается.
make_mock_script() {
  local path="$1" mode_file="$2" calls_file="$3" fail_file="${4:-}"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<MOCK
#!/bin/sh
if [ "\$1" != "status" ]; then
  echo "\$1" >>"$calls_file"
fi
if [ -n "$fail_file" ] && grep -qxF "\$1" "$fail_file" 2>/dev/null; then
  exit 1
fi
case "\$1" in
  status)
    [ "\$(cat "$mode_file" 2>/dev/null)" = "run" ] && exit 0
    exit 1
    ;;
esac
exit 0
MOCK
  chmod +x "$path"
}

# Мок z2r_download_project_file(dest, rel): фиксирует rel и ставит мок-скрипт.
z2r_download_project_file() {
  printf '%s\n' "$2" >>"$DOWNLOAD_LOG"
  case "$2" in
    Entware/zapret2-watchdog) make_mock_script "$1" "$STATUS_MODE" "$ENT_CALLS" ;;
    init.d/openwrt/zapret2-watchdog) make_mock_script "$1" "$STATUS_MODE" "$WRT_CALLS" ;;
    *) return 1 ;;
  esac
}

calls() { tr '\n' ',' <"$1" | sed 's/,$//'; }

# --- OpenWRT: start_service обязан запускать $initscript, а не $0 ---
# Под «#!/bin/sh /etc/rc.common» $0 указывает на /etc/rc.common: procd получал
# бы не тот скрипт, и сервис никогда бы не стартовал. Эмулируем окружение
# rc.common и перехватываем аргументы procd_set_param.

WRT_TEST_CONF="$TMP_DIR/wrt-test.conf"
: >"$WRT_TEST_CONF"                # чтобы «[ -f $CONF ] && . $CONF» при source не вернул 1 под set -e
Z2R_WATCHDOG_CONF="$WRT_TEST_CONF"
Z2R_WATCHDOG_LOGFILE="$TMP_DIR/wrt-sourced.log"
initscript="$Z2R_WRT_INIT"         # эту переменную задаёт rc.common
FAKE_ZAPRET2_INIT="$TMP_DIR/fake-zapret2-init"
printf '#!/bin/sh\necho "$1" >>"%s"\nexit 0\n' "$TMP_DIR/zapret2-init.calls" >"$FAKE_ZAPRET2_INIT"
chmod +x "$FAKE_ZAPRET2_INIT"
WATCH_INIT_CMD="$FAKE_ZAPRET2_INIT"

PROCD_PARAMS="$TMP_DIR/procd.params"
procd_open_instance() { :; }
procd_set_param() { printf '%s\n' "$*" >>"$PROCD_PARAMS"; }
procd_close_instance() { :; }
: >"$PROCD_PARAMS"
# shellcheck disable=SC1090
source "$REPO_DIR/init.d/openwrt/zapret2-watchdog"
start_service || fail "wrt start_service: должен завершаться успехом при доступном init"
grep -qF "command $Z2R_WRT_INIT run" "$PROCD_PARAMS" \
  || fail "wrt start_service: procd должен получить 'command <initscript> run', получено: $(tr '\n' ';' <"$PROCD_PARAMS")"
grep -qF 'respawn 3600 5 5' "$PROCD_PARAMS" || fail "wrt start_service: procd должен получить respawn 3600 5 5"
ok "wrt start_service: procd запускает \$initscript run с respawn"

if [ ! -x /etc/init.d/zapret2 ] && [ ! -x /opt/etc/init.d/S90-zapret2 ]; then
  WATCH_INIT_CMD=""
  : >"$PROCD_PARAMS"
  if start_service >/dev/null 2>&1; then
    fail "wrt start_service: без init zapret2 должен завершаться ошибкой"
  fi
  if [ -s "$PROCD_PARAMS" ]; then
    fail "wrt start_service: без init zapret2 procd-параметры задаваться не должны"
  fi
  ok "wrt start_service: без init zapret2 — ошибка, параметров нет"
else
  ok "wrt start_service: пропуск негативного сценария (на машине есть init zapret2)"
fi

# --- OpenWRT: OOM-детект по syslog (logread) — курсор последней строки ---
# Счётчик количества здесь не работает: кольцевой буфер может вытеснить одну
# старую OOM-строку ровно в момент появления новой, количество не меняется и
# новый OOM пропускался (замечание второго ревью).

awk '/^oom_scan\(\)/{f=1} f{print} f&&/^}$/{f=0}' \
  "$REPO_DIR/init.d/openwrt/zapret2-watchdog" >"$TMP_DIR/wrt_oom_funcs.sh"
grep -q '^oom_scan()' "$TMP_DIR/wrt_oom_funcs.sh" || fail "не извлеклась oom_scan из openwrt-watchdog"
# shellcheck disable=SC1090
source "$TMP_DIR/wrt_oom_funcs.sh"

mkdir -p "$TMP_DIR/fakebin"
LOGREAD_LINES="$TMP_DIR/logread.fixture"
printf '#!/bin/sh\ncat "%s" 2>/dev/null\n' "$LOGREAD_LINES" >"$TMP_DIR/fakebin/logread"
chmod +x "$TMP_DIR/fakebin/logread"
PATH="$TMP_DIR/fakebin:$PATH"

cat >"$LOGREAD_LINES" <<'FIX'
Jan  1 00:00:00 router user.info nfqws2[123]: nfqws2 started
Jan  1 00:00:05 router user.err nfqws2[123]: LUA PANIC: not enough memory
FIX

OOM_CURSOR=""
oom_scan
[ "$OOM_NEW_MATCH" = 0 ] || fail "wrt oom: пустой курсор (первый запуск) не должен срабатывать на истории"
[ "$OOM_CURSOR" = "Jan  1 00:00:05 router user.err nfqws2[123]: LUA PANIC: not enough memory" ] \
  || fail "wrt oom: курсор должен встать на последнюю строку буфера, получено: $OOM_CURSOR"

printf 'Jan  1 00:00:07 router user.info nfqws2[123]: reload ok\n' >>"$LOGREAD_LINES"
printf 'Jan  1 00:00:08 router user.err nfqws2[123]: NOT ENOUGH MEMORY in lua alloc\n' >>"$LOGREAD_LINES"
oom_scan
[ "$OOM_NEW_MATCH" -gt 0 ] || fail "wrt oom: новая OOM-строка (в другом регистре) должна срабатывать"

oom_scan
[ "$OOM_NEW_MATCH" = 0 ] || fail "wrt oom: без новых строк триггера быть не должно"

# ключевой сценарий ревью: старая OOM-строка вытеснена, новая появилась —
# количество совпадений не изменилось (1 → 1), но триггер обязан прозвучать
cat >"$LOGREAD_LINES" <<'FIX'
Jan  1 00:00:00 router user.info nfqws2[123]: nfqws2 started
Jan  1 00:00:09 router user.err nfqws2[123]: LUA PANIC: not enough memory
FIX
oom_scan
[ "$OOM_NEW_MATCH" -gt 0 ] || fail "wrt oom: «минус старая OOM-строка, плюс новая» должно срабатывать (счётчик это пропускал)"

printf 'Jan  1 00:00:10 router user.err other[1]: LUA PANIC: not enough memory\n' >>"$LOGREAD_LINES"
oom_scan
[ "$OOM_NEW_MATCH" = 0 ] || fail "wrt oom: OOM-строка чужого процесса не должна считаться"

# курсор вытеснен целиком: все строки буфера считаются новыми
cat >"$LOGREAD_LINES" <<'FIX'
Jan  1 00:00:11 router user.err nfqws2[123]: LUA PANIC: not enough memory again
FIX
OOM_CURSOR="Jan  1 00:00:00 router user.info ancient: marker evicted long ago"
oom_scan
[ "$OOM_NEW_MATCH" -gt 0 ] || fail "wrt oom: после вытеснения курсора новые строки должны считаться"
ok "wrt oom: курсор syslog, сценарий «минус старая плюс новая», чужие процессы"

# --- OpenWRT: do_restart — код возврата init в логе, err-логи не трогаются ---

awk '/^wlog\(\)/{f=1} /^do_restart\(\)/{f=1} f{print} f&&/^}$/{f=0}' \
  "$REPO_DIR/init.d/openwrt/zapret2-watchdog" >"$TMP_DIR/wrt_restart_funcs.sh"
grep -q '^do_restart()' "$TMP_DIR/wrt_restart_funcs.sh" || fail "не извлекся do_restart из openwrt-watchdog"
# shellcheck disable=SC1090
source "$TMP_DIR/wrt_restart_funcs.sh"

LOGFILE="$TMP_DIR/wrt-restart.log"
: >"$LOGFILE"
WRT_INIT_CALLS="$TMP_DIR/wrt-init.calls"
printf '#!/bin/sh\necho "$1" >>"%s"\n' "$WRT_INIT_CALLS" >"$TMP_DIR/fake-init-ok.sh"
printf '#!/bin/sh\necho "$1" >>"%s"\nexit 1\n' "$WRT_INIT_CALLS" >"$TMP_DIR/fake-init-fail.sh"
chmod +x "$TMP_DIR/fake-init-ok.sh" "$TMP_DIR/fake-init-fail.sh"
WATCH_INIT="$TMP_DIR/fake-init-ok.sh"
LAST_RESTART=0
WATCH_COOLDOWN=60

do_restart "тест: успех"
grep -qxF 'restart' "$WRT_INIT_CALLS" || fail "wrt do_restart: init должен вызваться с restart"
grep -qF 'рестарт zapret2 выполнен' "$LOGFILE" || fail "wrt do_restart: успех рестарта должен попадать в лог"

WATCH_INIT="$TMP_DIR/fake-init-fail.sh"
LAST_RESTART=0
do_restart "тест: неудача"
grep -qF 'рестарт zapret2 завершился с ошибкой' "$LOGFILE" \
  || fail "wrt do_restart: неудача рестарта должна попадать в лог (раньше код возврата игнорировался)"

: >"$WRT_INIT_CALLS"
do_restart "тест: cooldown"
if [ -s "$WRT_INIT_CALLS" ]; then
  fail "wrt do_restart: в cooldown init вызываться не должен"
fi

# WRT-вариант не имеет права трогать /tmp/nfqws2_*.err — их источник syslog
WRT_ERRDIR="$TMP_DIR/wrt-err"
mkdir -p "$WRT_ERRDIR"
echo 'LUA PANIC: not enough memory' >"$WRT_ERRDIR/nfqws2_1.err"
WATCH_INIT="$TMP_DIR/fake-init-ok.sh"
LAST_RESTART=0
do_restart "тест: err не трогаем"
grep -q 'LUA PANIC' "$WRT_ERRDIR/nfqws2_1.err" \
  || fail "wrt do_restart: не должен очищать /tmp/nfqws2_*.err (на OpenWRT это не источник, свежие логи терялись)"
ok "wrt do_restart: rc рестарта в логе, cooldown, err-логи не трогаются"

# --- Entware: nfqws2_state — pidfile с переиспользованным pid это падение ---
# Раньше живость определялась фактом существования /proc/<pid>: после падения
# nfqws2 и переиспользования pid посторонним процессом (sleep и т.п.) watchdog
# считал демона «работает» и не замечал реального падения.

awk '/^is_nfqws2_pid\(\)/{f=1} /^nfqws2_state\(\)/{f=1} f{print} f&&/^}$/{f=0}' \
  "$REPO_DIR/Entware/zapret2-watchdog" >"$TMP_DIR/ent_state_funcs.sh"
grep -q '^nfqws2_state()' "$TMP_DIR/ent_state_funcs.sh" || fail "не извлеклись state-функции из entware-watchdog"
# shellcheck disable=SC1090
source "$TMP_DIR/ent_state_funcs.sh"

ENT_RUNDIR="$TMP_DIR/ent/run"
mkdir -p "$ENT_RUNDIR"
RUNDIR="$ENT_RUNDIR"

state=$(nfqws2_state)
[ "$state" = "stopped" ] || fail "nfqws2_state: пустой rundir должен давать stopped, получено: $state"

sleep 120 &
FOREIGN_PID=$!
disown "$FOREIGN_PID" 2>/dev/null || true
echo "$FOREIGN_PID" >"$ENT_RUNDIR/nfqws2_1.pid"
state=$(nfqws2_state)
[ "$state" = "crash" ] || fail "nfqws2_state: pidfile с живым чужим pid (переиспользование) должен давать crash, получено: $state"

mkdir -p "$TMP_DIR/ent/fakebin"
FAKE_NFQ2="$TMP_DIR/ent/fakebin/nfqws2"
# строго argv[0]: настоящий nfqws2 — бинарник, его argv[0] — путь с именем
# nfqws2. Имитируем через exec -a (shebang-скрипт дал бы интерпретатор
# первым аргументом, как и настоящий бинарный демон никогда не выглядит).
bash -c 'exec -a "$1" sleep 300' _ "$FAKE_NFQ2" &
NFQ2_PID=$!
disown "$NFQ2_PID" 2>/dev/null || true
echo "$NFQ2_PID" >"$ENT_RUNDIR/nfqws2_1.pid"
state=$(nfqws2_state)
case "$state" in
  run*" $NFQ2_PID") : ;;
  *) fail "nfqws2_state: живой nfqws2 должен давать run с его pid, получено: $state" ;;
esac
kill "$FOREIGN_PID" "$NFQ2_PID" 2>/dev/null || true
ok "nfqws2_state: переиспользованный pid = crash, настоящий nfqws2 = run"

# --- Entware: safe_err_files — только обычные root-файлы, симлинки мимо ---

awk '/^wlog\(\)/{f=1} /^safe_err_files\(\)/{f=1} f{print} f&&/^}$/{f=0}' \
  "$REPO_DIR/Entware/zapret2-watchdog" >"$TMP_DIR/ent_safe_funcs.sh"
grep -q '^safe_err_files()' "$TMP_DIR/ent_safe_funcs.sh" || fail "не извлеклась safe_err_files из entware-watchdog"
# shellcheck disable=SC1090
source "$TMP_DIR/ent_safe_funcs.sh"

ENT_ERRDIR="$TMP_DIR/ent/err"
mkdir -p "$ENT_ERRDIR"
ERRDIR="$ENT_ERRDIR"
LOGFILE="$TMP_DIR/ent/wlog.log"

echo 'LUA PANIC: not enough memory' >"$ENT_ERRDIR/nfqws2_1.err"
safe=$(safe_err_files | tr '\n' ' ')
case "$safe" in
  *nfqws2_1.err*) : ;;
  *) fail "safe_err_files: обычный файл владельца должен попадать в выборку, получено: $safe" ;;
esac
# nativestrict: MSYS2 по умолчанию копирует вместо symlink — тогда сценарий пропускается
if MSYS=winsymlinks:nativestrict ln -sf /etc/passwd "$ENT_ERRDIR/nfqws2_2.err" 2>/dev/null; then
  safe=$(safe_err_files | tr '\n' ' ')
  case "$safe" in
    *nfqws2_2.err*) fail "safe_err_files: симлинк не должен попадать в выборку" ;;
    *) : ;;
  esac
fi
# чужой владелец игнорируется (только если chown реально сменил uid:
# MSYS2 может вернуть успех без смены владельца)
if echo x >"$ENT_ERRDIR/nfqws2_3.err" \
   && chown 1:1 "$ENT_ERRDIR/nfqws2_3.err" 2>/dev/null \
   && [ "$(stat -c '%u' "$ENT_ERRDIR/nfqws2_3.err" 2>/dev/null)" != "$(id -u 2>/dev/null)" ]; then
  safe=$(safe_err_files | tr '\n' ' ')
  case "$safe" in
    *nfqws2_3.err*) fail "safe_err_files: файл чужого владельца не должен попадать в выборку" ;;
    *) : ;;
  esac
fi
ok "safe_err_files: обычные файлы берём, симлинки и чужих владельцев игнорируем"

# --- Entware: do_restart — старые маркеры ДО рестарта, код возврата в лог ---

awk '/^wlog\(\)/{f=1} /^safe_err_files\(\)/{f=1} /^do_restart\(\)/{f=1} f{print} f&&/^}$/{f=0}' \
  "$REPO_DIR/Entware/zapret2-watchdog" >"$TMP_DIR/ent_restart_funcs.sh"
grep -q '^do_restart()' "$TMP_DIR/ent_restart_funcs.sh" || fail "не извлекся do_restart из entware-watchdog"
# shellcheck disable=SC1090
source "$TMP_DIR/ent_restart_funcs.sh"

LOGFILE="$TMP_DIR/ent/restart.log"
: >"$LOGFILE"
ENT_INIT_CALLS="$TMP_DIR/ent/init.calls"
printf '#!/bin/sh\necho "$1" >>"%s"\nexit 1\n' "$ENT_INIT_CALLS" >"$TMP_DIR/ent/init-fail.sh"
chmod +x "$TMP_DIR/ent/init-fail.sh"
WATCH_INIT="$TMP_DIR/ent/init-fail.sh"
LAST_RESTART=0
WATCH_COOLDOWN=60

echo 'LUA PANIC: not enough memory' >"$ENT_ERRDIR/nfqws2_1.err"
do_restart "тест: неудача"
if [ -s "$ENT_ERRDIR/nfqws2_1.err" ]; then
  fail "do_restart: старый маркер OOM должен сниматься ДО рестарта, иначе сработает повторно"
fi
grep -qxF 'restart' "$ENT_INIT_CALLS" || fail "do_restart: init должен вызваться с restart"
grep -qF 'рестарт zapret2 завершился с ошибкой' "$LOGFILE" \
  || fail "do_restart: неудача рестарта должна попадать в лог (раньше код возврата игнорировался)"
: >"$ENT_INIT_CALLS"
do_restart "тест: cooldown"
if [ -s "$ENT_INIT_CALLS" ]; then
  fail "do_restart: в cooldown init вызываться не должен"
fi
ok "entware do_restart: старые маркеры сняты до рестарта, код возврата в логе, cooldown"

# --- Entware: жизненный цикл реального скрипта — start ждёт готовности демона ---

ENT_REAL="$REPO_DIR/Entware/zapret2-watchdog"
ENT_PIDFILE="$TMP_DIR/ent/wd.pid"
ENT_LOG="$TMP_DIR/ent/wd.log"
export Z2R_WATCHDOG_PIDFILE="$ENT_PIDFILE"
export Z2R_WATCHDOG_LOGFILE="$ENT_LOG"
export Z2R_WATCHDOG_CONF="$TMP_DIR/ent/wd.conf"
export Z2R_WATCHDOG_RUNDIR="$ENT_RUNDIR"
export Z2R_WATCHDOG_ERRDIR="$ENT_ERRDIR"
export WATCH_INIT_CMD
printf 'WATCH_INTERVAL=1\n' >"$Z2R_WATCHDOG_CONF"
printf '#!/bin/sh\necho "$1" >>"%s"\nexit 0\n' "$ENT_INIT_CALLS" >"$TMP_DIR/ent/zapret2-init.sh"
chmod +x "$TMP_DIR/ent/zapret2-init.sh"

# демону некуда смотреть init zapret2 — start обязан честно вернуть ошибку.
# watch_init считает WATCH_INIT_CMD годным без проверки существования, поэтому
# негативный сценарий — именно пустой WATCH_INIT_CMD и отсутствие реальных
# init-путей на машине.
if [ -x /opt/etc/init.d/S90-zapret2 ] || [ -x /etc/init.d/zapret2 ]; then
  ok "start: негативный сценарий пропущен (на машине есть настоящий init zapret2)"
else
  WATCH_INIT_CMD=""
  if sh "$ENT_REAL" start >/dev/null 2>&1; then
    fail "start: без init zapret2 должен завершаться ошибкой (раньше возвращал 0 вслепую)"
  fi
  if [ -e "$ENT_PIDFILE" ]; then
    fail "start: после неудачи pidfile должен подчищаться"
  fi
  grep -q 'init-скрипт zapret2 не найден' "$ENT_LOG" \
    || fail "start: причина неудачи должна попадать в лог watchdog"
  ok "start: без init zapret2 — ошибка, pidfile подчищен, причина в логе"
fi

# успешный старт: pidfile пишет сам демон, статус running, stop завершает процесс
WATCH_INIT_CMD="$TMP_DIR/ent/zapret2-init.sh"
sh "$ENT_REAL" start || fail "start: должен завершаться успехом"
[ -s "$ENT_PIDFILE" ] || fail "start: pidfile должен быть записан демоном"
wd_status=$(sh "$ENT_REAL" status) || fail "status: должен быть running после start"
case "$wd_status" in running*) : ;; *) fail "status: ожидался running, получено: $wd_status" ;; esac
grep -q 'watchdog запущен' "$ENT_LOG" || fail "демон должен логировать свой запуск"
sh "$ENT_REAL" stop || fail "stop: должен завершаться успехом"
if [ -e "$ENT_PIDFILE" ]; then
  fail "stop: pidfile должен удаляться"
fi
if sh "$ENT_REAL" status >/dev/null 2>&1; then
  fail "status: после stop должен быть stopped"
fi
ok "entware жизненный цикл: start ждёт pidfile, статус/stop, неудача стартa рапортуется"

# --- Платформа без watchdog: недоступно и отказ ---

OSystem="vps"
assert_eq "$(watchdog_status_text)" "недоступно" "vps: статус должен быть «недоступно»"
if watchdog_toggle >/dev/null 2>&1; then
  fail "vps: watchdog_toggle должен отказать"
fi
ok "чужая платформа: недоступно, toggle отказывает"

# --- Entware: статусы ---

OSystem="entware"
assert_eq "$(watchdog_status_text)" "не установлен" "entware без скрипта: должен быть «не установлен»"

# --- Entware: включение из ничего (докачка + обёртка + запуск) ---

out="$(watchdog_toggle)"
assert_contains "$out" "включён" "entware: сообщение о включении"
assert_contains "$out" "Скачиваю watchdog с репозитория" "entware: ход докачки должен печататься"
assert_contains "$out" "запускаю watchdog" "entware: ход запуска должен печататься"
assert_eq "$(cat "$DOWNLOAD_LOG")" "Entware/zapret2-watchdog" "entware: должна быть ровно одна докачка скрипта"
[ -x "$ENT_SCRIPT" ] || fail "entware: скрипт не установлен после включения"
[ -x "$Z2R_ENTWARE_INIT" ] || fail "entware: обёртка автозапуска не создана"
assert_contains "$(cat "$Z2R_ENTWARE_INIT")" "$ENT_SCRIPT" "entware: обёртка должна запускать скрипт watchdog"
sh -n "$Z2R_ENTWARE_INIT" || fail "entware: обёртка автозапуска сломана синтаксически"
assert_eq "$(calls "$ENT_CALLS")" "start" "entware: при включении вызван start"
ok "entware включение: докачка, обёртка автозапуска, start"

echo run >"$STATUS_MODE"
assert_eq "$(watchdog_status_text)" "работает" "entware: статус «работает»"

# --- Entware: выключение (stop + снятие автозагрузки, файлы остаются) ---

out="$(watchdog_toggle)"
assert_contains "$out" "остановлен и убран" "entware: сообщение о выключении"
assert_contains "$out" "Останавливаю watchdog" "entware: остановка должна объявляться до неё"
assert_contains "$out" "не зависание" "entware: должно быть предупреждение о долгой остановке"
assert_eq "$(calls "$ENT_CALLS")" "start,stop" "entware: при выключении вызван stop"
[ ! -e "$Z2R_ENTWARE_INIT" ] || fail "entware: обёртка автозапуска должна быть удалена"
[ -x "$ENT_SCRIPT" ] || fail "entware: скачанный скрипт должен остаться"
echo stopped >"$STATUS_MODE"
assert_eq "$(watchdog_status_text)" "выключен" "entware: статус «выключен»"
ok "entware выключение: stop, обёртка удалена, файлы остались"

# --- Entware: повторное включение без докачки ---

out="$(watchdog_toggle)"
assert_contains "$out" "включён" "entware: повторное включение"
assert_eq "$(cat "$DOWNLOAD_LOG")" "Entware/zapret2-watchdog" "entware: повторное включение не должно качать заново"
assert_eq "$(calls "$ENT_CALLS")" "start,stop,start" "entware: повторный start"
ok "entware повторное включение: без докачки"

# --- WRT: статусы и переключатель ---

OSystem="WRT"
assert_eq "$(watchdog_status_text)" "не установлен" "wrt без init: должен быть «не установлен»"

out="$(watchdog_toggle)"
assert_contains "$out" "включён" "wrt: сообщение о включении"
assert_contains "$out" "Скачиваю watchdog с репозитория" "wrt: ход докачки должен печататься"
assert_contains "$out" "запускаю watchdog" "wrt: ход запуска должен печататься"
assert_eq "$(cat "$DOWNLOAD_LOG" | tail -1)" "init.d/openwrt/zapret2-watchdog" "wrt: докачан init-скрипт"
[ -x "$Z2R_WRT_INIT" ] || fail "wrt: init-скрипт не установлен"
assert_eq "$(calls "$WRT_CALLS")" "enable,start" "wrt: при включении enable и start"
echo run >"$STATUS_MODE"
assert_eq "$(watchdog_status_text)" "работает" "wrt: статус «работает»"

out="$(watchdog_toggle)"
assert_contains "$out" "остановлен и убран" "wrt: сообщение о выключении"
assert_contains "$out" "Останавливаю watchdog" "wrt: остановка должна объявляться до неё"
assert_eq "$(calls "$WRT_CALLS")" "enable,start,stop,disable" "wrt: при выключении stop и disable"
[ -x "$Z2R_WRT_INIT" ] || fail "wrt: init-файл должен остаться (выключение ≠ удаление)"
echo stopped >"$STATUS_MODE"
assert_eq "$(watchdog_status_text)" "выключен" "wrt: статус «выключен»"
ok "wrt: включение (enable+start) и выключение (stop+disable), файл остался"

# --- Частичные сбои: пункт 19-6 не должен рапортовать успех частичного ---
# применения: вызывающий код использует «watchdog_toggle || true», поэтому
# рассчитывать на set -e нельзя — проверяем коды возврата каждого шага и откат.

FAIL_CMDS="$TMP_DIR/fail.cmds"

OSystem="WRT"
echo stopped >"$STATUS_MODE"
printf 'enable\n' >"$FAIL_CMDS"
make_mock_script "$Z2R_WRT_INIT" "$STATUS_MODE" "$WRT_CALLS" "$FAIL_CMDS"
: >"$WRT_CALLS"
if watchdog_toggle >/dev/null 2>&1; then
  fail "wrt toggle: упавший enable должен давать ненулевой код возврата"
fi
assert_eq "$(calls "$WRT_CALLS")" "enable" "wrt toggle: при упавшем enable start не вызывается"
ok "wrt toggle: ошибка enable → отказ без start"

echo stopped >"$STATUS_MODE"
printf 'start\n' >"$FAIL_CMDS"
make_mock_script "$Z2R_WRT_INIT" "$STATUS_MODE" "$WRT_CALLS" "$FAIL_CMDS"
: >"$WRT_CALLS"
if watchdog_toggle >/dev/null 2>&1; then
  fail "wrt toggle: неудачный start должен давать ненулевой код возврата"
fi
assert_eq "$(calls "$WRT_CALLS")" "enable,start,disable" "wrt toggle: после неудачного start автозапуск откатывается (disable)"
ok "wrt toggle: неудачный start → откат enable"

OSystem="entware"
echo stopped >"$STATUS_MODE"
printf 'start\n' >"$FAIL_CMDS"
make_mock_script "$ENT_SCRIPT" "$STATUS_MODE" "$ENT_CALLS" "$FAIL_CMDS"
: >"$ENT_CALLS"
if watchdog_toggle >/dev/null 2>&1; then
  fail "entware toggle: неудачный start должен давать ненулевой код возврата"
fi
assert_eq "$(calls "$ENT_CALLS")" "start" "entware toggle: при неудачном start вызван только start"
[ ! -e "$Z2R_ENTWARE_INIT" ] || fail "entware toggle: обёртка автозапуска должна откатываться при неудачном start"
ok "entware toggle: неудачный start → отказ и откат обёртки"

echo run >"$STATUS_MODE"
printf 'stop\n' >"$FAIL_CMDS"
make_mock_script "$ENT_SCRIPT" "$STATUS_MODE" "$ENT_CALLS" "$FAIL_CMDS"
printf '#!/bin/sh\nexec "%s" "$1"\n' "$ENT_SCRIPT" >"$Z2R_ENTWARE_INIT"
chmod +x "$Z2R_ENTWARE_INIT"
: >"$ENT_CALLS"
if watchdog_toggle >/dev/null 2>&1; then
  fail "entware toggle: неудачный stop должен давать ненулевой код возврата"
fi
assert_eq "$(calls "$ENT_CALLS")" "stop" "entware toggle: при неудачном stop вызван stop"
[ -e "$Z2R_ENTWARE_INIT" ] || fail "entware toggle: при неудачном stop обёртка не должна удаляться"
echo stopped >"$STATUS_MODE"
ok "entware toggle: неудачный stop → отказ, обёртка на месте"

# --- Удаление (меню 4/44): полная зачистка watchdog ---

OSystem="entware"
# «демон» живёт по каноническому пути нашего скрипта: wd_pid_is_ours сверяет
# строго argv[0] с $(watchdog_entware_script)
printf '#!/bin/sh\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' >"$ENT_SCRIPT"
chmod +x "$ENT_SCRIPT"
# процесс с тем же basename, но из другого каталога — «нашим» не считается
mkdir -p "$TMP_DIR/fakewd"
printf '#!/bin/sh\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' >"$TMP_DIR/fakewd/zapret2-watchdog"
chmod +x "$TMP_DIR/fakewd/zapret2-watchdog"

"$ENT_SCRIPT" watch &
WDPID=$!
disown "$WDPID" 2>/dev/null || true
echo "$WDPID" >"$TMP_DIR/watchdog.pid"
Z2R_WATCHDOG_PIDFILE="$TMP_DIR/watchdog.pid"
touch "$ENT_SCRIPT.conf"
out="$(watchdog_uninstall)"
assert_contains "$out" "остановлен и удалён" "uninstall entware: сообщение"
[ ! -e "$ENT_SCRIPT" ] || fail "uninstall entware: скрипт не удалён"
[ ! -e "$ENT_SCRIPT.conf" ] || fail "uninstall entware: конфиг не удалён"
[ ! -e "$Z2R_ENTWARE_INIT" ] || fail "uninstall entware: обёртка автозапуска не удалена"
[ ! -e "$TMP_DIR/watchdog.pid" ] || fail "uninstall entware: pidfile не удалён"
kill -0 "$WDPID" 2>/dev/null && fail "uninstall entware: демон не остановлен"
ok "uninstall entware: демон остановлен, файлы удалены"

# процесс из другого каталога с тем же basename: argv[0] не совпал —
# сигналить ему нельзя (файлы при этом зачищаются)
"$TMP_DIR/fakewd/zapret2-watchdog" watch &
SAMEBASE_PID=$!
disown "$SAMEBASE_PID" 2>/dev/null || true
echo "$SAMEBASE_PID" >"$TMP_DIR/watchdog.pid"
out="$(watchdog_uninstall)"
kill -0 "$SAMEBASE_PID" 2>/dev/null || fail "uninstall entware: процесс с тем же basename из чужого каталога убивать нельзя"
[ ! -e "$TMP_DIR/watchdog.pid" ] || fail "uninstall entware: pidfile должен зачищаться"
ok "uninstall entware: тот же basename из чужого каталога не тронут"
kill "$SAMEBASE_PID" 2>/dev/null || true

# pidfile с переиспользованным pid постороннего процесса: чужой процесс не
# убивается (раньше по pidfile отправлялись TERM и KILL вслепую), но сам
# pidfile и файлы установки зачищаются
sleep 120 &
SLEEP_PID=$!
disown "$SLEEP_PID" 2>/dev/null || true
echo "$SLEEP_PID" >"$TMP_DIR/watchdog.pid"
make_mock_script "$ENT_SCRIPT" "$STATUS_MODE" "$ENT_CALLS"
out="$(watchdog_uninstall)"
assert_contains "$out" "остановлен и удалён" "uninstall entware: сообщение при файлах на месте"
kill -0 "$SLEEP_PID" 2>/dev/null || fail "uninstall entware: посторонний процесс (переиспользованный pid) убивать нельзя"
[ ! -e "$TMP_DIR/watchdog.pid" ] || fail "uninstall entware: pidfile должен зачищаться даже с чужим pid"
ok "uninstall entware: чужой pid не тронут, pidfile зачищен"
kill "$SLEEP_PID" 2>/dev/null || true

# сирота: демон жив, pidfile есть, а файлы установки уже частично удалены —
# раньше ветка зачистки не выполнялась вовсе и демон оставался висеть
printf '#!/bin/sh\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' >"$ENT_SCRIPT"
chmod +x "$ENT_SCRIPT"
"$ENT_SCRIPT" watch &
WDPID=$!
disown "$WDPID" 2>/dev/null || true
echo "$WDPID" >"$TMP_DIR/watchdog.pid"
out="$(watchdog_uninstall)"
assert_contains "$out" "остановлен и удалён" "uninstall entware: сообщение о сироте"
kill -0 "$WDPID" 2>/dev/null && fail "uninstall entware: осиротевший демон должен останавливаться"
[ ! -e "$TMP_DIR/watchdog.pid" ] || fail "uninstall entware: pidfile сироты должен удаляться"
ok "uninstall entware: сирота (демон жив, файлов установки нет) остановлен"

OSystem="WRT"
make_mock_script "$Z2R_WRT_INIT" "$STATUS_MODE" "$WRT_CALLS"
: >"$WRT_CALLS"
out="$(watchdog_uninstall)"
assert_contains "$out" "остановлен и удалён" "uninstall wrt: сообщение"
[ ! -e "$Z2R_WRT_INIT" ] || fail "uninstall wrt: init-файл не удалён"
assert_eq "$(calls "$WRT_CALLS")" "stop,disable" "uninstall wrt: stop и disable"
ok "uninstall wrt: stop+disable, init-файл удалён"

OSystem="vps"
out="$(watchdog_uninstall)"
[ -z "$out" ] || fail "uninstall на чужой платформе должен молчать"
ok "uninstall: чужая платформа — тихий no-op"

# --- После переустановки (тело установщика): поднять выживший watchdog ---

OSystem="entware"
out="$(watchdog_ensure_running)"
[ -z "$out" ] || fail "ensure_running без watchdog должен молчать"

make_mock_script "$ENT_SCRIPT" "$STATUS_MODE" "$ENT_CALLS"
make_mock_script "$Z2R_ENTWARE_INIT" "$STATUS_MODE" "$ENT_CALLS"
echo stopped >"$STATUS_MODE"
: >"$ENT_CALLS"
out="$(watchdog_ensure_running)"
assert_contains "$out" "снова запущен" "ensure_running entware: сообщение о подъёме"
assert_eq "$(calls "$ENT_CALLS")" "start" "ensure_running entware: вызван start"

echo run >"$STATUS_MODE"
: >"$ENT_CALLS"
out="$(watchdog_ensure_running)"
[ -z "$out" ] || fail "ensure_running при работающем демоне должен молчать"
[ -z "$(cat "$ENT_CALLS")" ] || fail "ensure_running при работающем не должен звать start"

rm -f "$Z2R_ENTWARE_INIT"
: >"$ENT_CALLS"
out="$(watchdog_ensure_running)"
[ -z "$out" ] || fail "ensure_running без обёртки (был выключен) должен молчать"
[ -z "$(cat "$ENT_CALLS")" ] || fail "ensure_running без обёртки не должен звать start"
ok "ensure_running entware: подъём после паузы, молчит при живом/выключенном"

OSystem="WRT"
make_mock_script "$Z2R_WRT_INIT" "$STATUS_MODE" "$WRT_CALLS"
echo stopped >"$STATUS_MODE"
: >"$WRT_CALLS"
out="$(watchdog_ensure_running)"
assert_contains "$out" "снова запущен" "ensure_running wrt: сообщение о подъёме"
assert_eq "$(calls "$WRT_CALLS")" "enabled,start" "ensure_running wrt: вызван start"
ok "ensure_running wrt: подъём после паузы"

# --- ensure_running: неудачный start не должен молчать (раньше rc=0, пусто) ---

OSystem="entware"
echo stopped >"$STATUS_MODE"
printf 'start\n' >"$FAIL_CMDS"
make_mock_script "$ENT_SCRIPT" "$STATUS_MODE" "$ENT_CALLS" "$FAIL_CMDS"
make_mock_script "$Z2R_ENTWARE_INIT" "$STATUS_MODE" "$ENT_CALLS" "$FAIL_CMDS"
if out="$(watchdog_ensure_running)"; then
  fail "ensure_running entware: неудачный start должен давать ненулевой код возврата"
fi
assert_contains "$out" "НЕ смог запуститься" "ensure_running entware: предупреждение о неудаче"
ok "ensure_running entware: неудачный start — предупреждение и ошибка"

OSystem="WRT"
make_mock_script "$Z2R_WRT_INIT" "$STATUS_MODE" "$WRT_CALLS" "$FAIL_CMDS"
echo stopped >"$STATUS_MODE"
: >"$WRT_CALLS"
if out="$(watchdog_ensure_running)"; then
  fail "ensure_running wrt: неудачный start должен давать ненулевой код возврата"
fi
assert_contains "$out" "НЕ смог запуститься" "ensure_running wrt: предупреждение о неудаче"
ok "ensure_running wrt: неудачный start — предупреждение и ошибка"

# --- uninstall: неполная зачистка = ненулевой код возврата и предупреждение ---

# rm, отказывающийся удалять файлы watchdog: раньше функция всё равно
# рапортовала успех и возвращала 0
OSystem="entware"
echo stopped >"$STATUS_MODE"
make_mock_script "$ENT_SCRIPT" "$STATUS_MODE" "$ENT_CALLS"
make_mock_script "$Z2R_ENTWARE_INIT" "$STATUS_MODE" "$ENT_CALLS"
touch "$ENT_SCRIPT.conf"
rm() {
  case "$*" in
    *zapret2-watchdog*) return 1 ;;
  esac
  command rm "$@"
}
if out="$(watchdog_uninstall)"; then
  fail "uninstall entware: сбой rm должен давать ненулевой код возврата"
fi
unset -f rm
assert_contains "$out" "не полностью" "uninstall entware: предупреждение о неполной зачистке"
[ -e "$ENT_SCRIPT" ] || fail "uninstall entware: при сбое rm скрипт должен был остаться"
[ -e "$Z2R_ENTWARE_INIT" ] || fail "uninstall entware: при сбое rm обёртка должна была остаться"
[ -e "$ENT_SCRIPT.conf" ] || fail "uninstall entware: при сбое rm конфиг должен был остаться"
[ ! -e "$TMP_DIR/watchdog.pid" ] || fail "uninstall entware: pidfile (не попавший под сбой rm) должен удаляться"
ok "uninstall entware: сбой rm — предупреждение и ошибка, состояние честное"

# WRT: падающий stop/disable больше не игнорируются (живой procd-инстанс)
OSystem="WRT"
printf 'stop\ndisable\n' >"$FAIL_CMDS"
make_mock_script "$Z2R_WRT_INIT" "$STATUS_MODE" "$WRT_CALLS" "$FAIL_CMDS"
: >"$WRT_CALLS"
if out="$(watchdog_uninstall)"; then
  fail "uninstall wrt: сбой stop/disable должен давать ненулевой код возврата"
fi
assert_contains "$out" "не полностью" "uninstall wrt: предупреждение о неполной зачистке"
assert_eq "$(calls "$WRT_CALLS")" "stop,disable" "uninstall wrt: после сбоя stop disable всё равно вызывается"
[ ! -e "$Z2R_WRT_INIT" ] || fail "uninstall wrt: init-файл (rm прошёл) должен быть удалён"
ok "uninstall wrt: сбой stop/disable — предупреждение и ошибка"

# повторная зачистка после сбоя: init-файл уже удалён в прошлом сценарии —
# тихий успех без сообщений
OSystem="WRT"
out="$(watchdog_uninstall)"
[ -z "$out" ] || fail "uninstall wrt: повторная зачистка пустой установки должна молчать"
ok "uninstall wrt: повторный вызов на чистой системе — тихий успех"

# осиротевший конфиг: init-файла уже нет, общий конфиг остался —
# WRT-ветка тоже должна удалить его при полном снятии watchdog
OSystem="WRT"
WRT_CONF="$ZATOR_ROOT/z2r_lib/zapret2-watchdog.conf"
touch "$WRT_CONF"
out="$(watchdog_uninstall)"
assert_contains "$out" "остановлен и удалён" "uninstall wrt: сообщение при единственном осиротевшем конфиге"
[ ! -e "$WRT_CONF" ] || fail "uninstall wrt: осиротевший конфиг должен удаляться"
ok "uninstall wrt: orphan-conf удаляется безусловно"

# То же поведение для Entware: скрипта и обёртки уже нет, ${script}.conf остался
OSystem="entware"
command rm -f "$ENT_SCRIPT" "$Z2R_ENTWARE_INIT" "$ENT_SCRIPT.conf"
touch "$ENT_SCRIPT.conf"
out="$(watchdog_uninstall)"
assert_contains "$out" "остановлен и удалён" "uninstall entware: сообщение при единственном осиротевшем конфиге"
[ ! -e "$ENT_SCRIPT.conf" ] || fail "uninstall entware: осиротевший конфиг должен удаляться"
ok "uninstall entware: orphan-conf удаляется безусловно"

echo "watchdog smoke ok"
