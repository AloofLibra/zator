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
#   • watchdog_uninstall (меню 4/44) — полная зачистка: демон остановлен
#     (TERM → 3с → KILL по pidfile), файлы/конфиг/обёртка удалены;
#   • watchdog_ensure_running (тело установщика) — поднимает включённый
#     watchdog после переустановки, молчит при живом/выключенном;
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

PASS=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() {
  printf '  [PASS] %s\n' "$1"
  PASS=$((PASS + 1))
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
grep -qF 'zapret2-watchdog.log | tail -15' "$REPO_DIR/z2r.sh" || fail "п.666 не показывает последние события watchdog"
grep -qF 'watchdog_toggle || true' "$REPO_DIR/lib/submenus.sh" || fail "в подменю нет обработчика пункта 6 (watchdog_toggle)"
grep -qF 'submenu_status_item "6" "Watchdog zapret2' "$REPO_DIR/lib/submenus.sh" || fail "в подменю нет пункта 6 (статус watchdog)"
grep -qF 'pidfile остался' "$REPO_DIR/Entware/zapret2-watchdog" || fail "в watchdog нет pidfile-эвристики (падение vs штатная остановка)"
grep -qF 'Z2R_ENTWARE_INIT' "$REPO_DIR/lib/submenus.sh" || fail "путь entware-автозапуска не переопределяется через env"
grep -qF 'Z2R_WRT_INIT' "$REPO_DIR/lib/submenus.sh" || fail "путь wrt-автозапуска не переопределяется через env"
ok "wiring: п.666, пункт 19-6, pidfile-эвристика, env-override"

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
# команды — 0. Реальный watchdog в тесте не запускается.
make_mock_script() {
  local path="$1" mode_file="$2" calls_file="$3"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<MOCK
#!/bin/sh
case "\$1" in
  status)
    [ "\$(cat "$mode_file" 2>/dev/null)" = "run" ] && exit 0
    exit 1
    ;;
  *)
    echo "\$1" >>"$calls_file"
    exit 0
    ;;
esac
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

# --- Удаление (меню 4/44): полная зачистка watchdog ---

OSystem="entware"
# живой «демон»: реальный фоновый процесс + pidfile (путь через env)
sleep 300 &
WDPID=$!
disown "$WDPID" 2>/dev/null || true
echo "$WDPID" >"$TMP_DIR/watchdog.pid"
Z2R_WATCHDOG_PIDFILE="$TMP_DIR/watchdog.pid"
touch "$ENT_SCRIPT.conf"
out="$(watchdog_uninstall)"
kill "$WDPID" 2>/dev/null || true
assert_contains "$out" "остановлен и удалён" "uninstall entware: сообщение"
[ ! -e "$ENT_SCRIPT" ] || fail "uninstall entware: скрипт не удалён"
[ ! -e "$ENT_SCRIPT.conf" ] || fail "uninstall entware: конфиг не удалён"
[ ! -e "$Z2R_ENTWARE_INIT" ] || fail "uninstall entware: обёртка автозапуска не удалена"
[ ! -e "$TMP_DIR/watchdog.pid" ] || fail "uninstall entware: pidfile не удалён"
kill -0 "$WDPID" 2>/dev/null && fail "uninstall entware: демон не остановлен"
ok "uninstall entware: демон остановлен, файлы удалены"

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

echo "watchdog smoke ok"
